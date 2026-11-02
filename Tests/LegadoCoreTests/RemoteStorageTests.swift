import XCTest
@testable import LegadoCore

final class RemoteStorageTests: XCTestCase {
    private func server(_ type: Server.ServerType = .webDAV) throws -> Server {
        var value = Server(id: 17, name: "Test", type: type)
        switch type {
        case .webDAV: try value.setConfiguration(Server.WebDAVConfig(url: "https://dav.example/dav/books/", username: "reader", password: "password"))
        case .s3: try value.setConfiguration(Server.S3Config(endpoint: "https://s3.example:9000", bucket: "books", accessKey: "key", secretKey: "secret", prefix: "library"))
        case .dropbox: try value.setConfiguration(Server.DropboxConfig(accessToken: "test-token", rootPath: "/Books"))
        }
        return value
    }

    func testRejectsTraversalAndUnsafeEndpoints() throws {
        for path in ["../book", "folder/../book", ".", "a\\b", "a\nb", "a/\0b"] {
            XCTAssertThrowsError(try RemoteStorageClient.path(path))
        }
        XCTAssertEqual(try RemoteStorageClient.path("/书籍/小说/"), "书籍/小说")
        for url in ["file:///tmp/books", "https://user:password@example.com/", "https://example.com/?token=secret", "https://example.com/#folder"] {
            var value = try server()
            try value.setConfiguration(Server.WebDAVConfig(url: url, username: "", password: ""))
            XCTAssertThrowsError(try RemoteStorageClient(server: value))
        }
    }

    func testWebDAVParsesOnlySuccessfulImmediateChildren() async throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dav/books/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/books/%E4%B9%A6%20%23%25.txt</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>42</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>novels/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/books/denied.txt</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat></d:response>
        <d:response><d:href>https://evil.example/dav/books/evil.txt</d:href></d:response>
        <d:response><d:href>/dav/books/sub/deep.txt</d:href></d:response>
        </d:multistatus>
        """
        let transport = RemoteTestTransport([.init(status: 207, body: xml)])
        let client = try RemoteStorageClient(server: server(), transport: transport)
        let files = try await client.list()
        XCTAssertEqual(files.map(\.name), ["novels", "书 #%.txt"])
        XCTAssertEqual(files.last?.bytes, 42)
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.httpMethod, "PROPFIND")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Depth"), "1")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("reader:password".utf8).base64EncodedString())
    }

    func testWebDAVUploadEscapesNamesAndPreventsOverwrite() async throws {
        let transport = RemoteTestTransport([.init(status: 201)])
        let client = try RemoteStorageClient(server: server(), transport: transport)
        try await client.upload(Data("hello".utf8), to: "书 #%.txt")
        let request = await transport.requests.first!
        XCTAssertEqual(request.url?.absoluteString, "https://dav.example/dav/books/%E4%B9%A6%20%23%25.txt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertEqual(request.httpBody, Data("hello".utf8))
    }

    // Published AWS SigV4 GET Object example, using public example credentials.
    // https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html
    func testS3SignatureMatchesAWSReferenceVector() throws {
        let config = Server.S3Config(region: "us-east-1", accessKey: "AKIAIOSFODNN7EXAMPLE",
                                     secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"
        RemoteStorageClient.signS3(&request, config: config, at: ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!,
                                   additionalHeaders: ["range": "bytes=0-9"])
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.hasSuffix(
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))
    }

    func testS3ListsBucketWithPrefixAndPagination() async throws {
        let first = """
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><EncodingType>url</EncodingType>
        <CommonPrefixes><Prefix>library/%E5%B0%8F%E8%AF%B4/</Prefix></CommonPrefixes>
        <IsTruncated>true</IsTruncated><NextContinuationToken>a+/=</NextContinuationToken></ListBucketResult>
        """
        let second = """
        <ListBucketResult><Contents><Key>library/%E4%B9%A6%20%25.txt</Key><Size>88</Size><LastModified>2026-11-01T00:00:00.000Z</LastModified></Contents>
        <IsTruncated>false</IsTruncated></ListBucketResult>
        """
        let transport = RemoteTestTransport([.init(body: first), .init(body: second)])
        let files = try await RemoteStorageClient(server: server(.s3), transport: transport).list()
        XCTAssertEqual(files.map(\.path), ["小说", "书 %.txt"])
        XCTAssertEqual(files.last?.bytes, 88)
        XCTAssertNotNil(files.last?.modified)
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.path, "/books")
        XCTAssertTrue(requests[0].url!.absoluteString.contains("prefix=library%2F"))
        XCTAssertTrue(requests[1].url!.absoluteString.contains("continuation-token=a%2B%2F%3D"))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Host"), "s3.example:9000")
    }

    func testS3VirtualHostAndSessionToken() async throws {
        var value = try server(.s3)
        var config = value.s3Config!
        config.pathStyle = false; config.sessionToken = "temporary-token"
        try value.setConfiguration(config)
        let transport = RemoteTestTransport([.init(body: "book")])
        _ = try await RemoteStorageClient(server: value, transport: transport).download("书.txt")
        let request = await transport.requests.first!
        XCTAssertEqual(request.url?.host, "books.s3.example")
        XCTAssertEqual(request.url?.path, "/library/书.txt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-security-token"), "temporary-token")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains("x-amz-security-token"))
    }

    func testS3CreateDirectoryUsesTrailingSlashAndConditionalWrite() async throws {
        let transport = RemoteTestTransport([.init()])
        try await RemoteStorageClient(server: server(.s3), transport: transport).createDirectory("新目录")
        let request = await transport.requests.first!
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("/library/%E6%96%B0%E7%9B%AE%E5%BD%95/"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
    }

    func testDropboxPaginationAndDownloadHeaderForChineseAndEmoji() async throws {
        let transport = RemoteTestTransport([
            .init(body: #"{"entries":[{".tag":"folder","name":"小说"}],"has_more":true,"cursor":"next"}"#),
            .init(body: #"{"entries":[{".tag":"file","name":"书📖.txt","size":12}],"has_more":false,"cursor":"end"}"#),
            .init(body: "text")
        ])
        let client = try RemoteStorageClient(server: server(.dropbox), transport: transport)
        let files = try await client.list()
        XCTAssertEqual(files.map(\.name), ["小说", "书📖.txt"])
        let data = try await client.download(files[1].path)
        XCTAssertEqual(data, Data("text".utf8))
        let requests = await transport.requests
        XCTAssertEqual(requests[1].url?.path, "/2/files/list_folder/continue")
        XCTAssertEqual(try json(requests[0].httpBody!)["path"] as? String, "/Books")
        XCTAssertEqual(requests[2].url?.host, "content.dropboxapi.com")
        let header = requests[2].value(forHTTPHeaderField: "Dropbox-API-Arg")!
        XCTAssertTrue(header.unicodeScalars.allSatisfy { $0.isASCII })
        XCTAssertEqual(try json(Data(header.utf8))["path"] as? String, "/Books/书📖.txt")
    }

    func testDropboxUploadPreventsOverwrite() async throws {
        let transport = RemoteTestTransport([.init(body: "{}")])
        try await RemoteStorageClient(server: server(.dropbox), transport: transport).upload(Data("book".utf8), to: "a.txt")
        let request = await transport.requests.first!
        let args = try json(Data(request.value(forHTTPHeaderField: "Dropbox-API-Arg")!.utf8))
        XCTAssertEqual(args["mode"] as? String, "add")
        XCTAssertEqual(args["autorename"] as? Bool, false)
        XCTAssertEqual(args["strict_conflict"] as? Bool, true)
    }

    func testRejectsFailedResponsesAndMalformedLists() async throws {
        for type in Server.ServerType.allCases {
            for reply in [RemoteTestTransport.Reply(status: 401), .init(body: "<html>Login</html>")] {
                let client = try RemoteStorageClient(server: server(type), transport: RemoteTestTransport([reply]))
                do { _ = try await client.list(); XCTFail("Must reject failed or malformed response") }
                catch { XCTAssertFalse(error.localizedDescription.contains("test-token")) }
            }
        }
    }

    func testRejectsRepeatedPaginationCursor() async throws {
        for type in [Server.ServerType.s3, .dropbox] {
            let body = type == .s3
                ? "<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>same</NextContinuationToken></ListBucketResult>"
                : #"{"entries":[],"has_more":true,"cursor":"same"}"#
            let transport = RemoteTestTransport([.init(body: body), .init(body: body)])
            let client = try RemoteStorageClient(server: server(type), transport: transport)
            do { _ = try await client.list(); XCTFail("Must reject repeated cursor") } catch {}
            let count = await transport.requests.count
            XCTAssertEqual(count, 2)
        }
    }

    func testServerStorePersistsCredentialsOutsideDatabaseAndMigratesLegacy() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try LegadoDatabase(url: folder.appendingPathComponent("test.sqlite"))
        let legacy = try server()
        try await database.replaceServers([legacy])
        let vault = RemoteTestVault()
        let store = RemoteServerStore(database: database, vault: vault)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [legacy])
        var second = try server(.dropbox); second.id = 18
        try await store.save(second)
        let raw = try await database.loadServers()
        XCTAssertTrue(raw.allSatisfy { $0.config == nil })
        let hydrated = try await store.load()
        XCTAssertEqual(hydrated.first?.webDAVConfig?.password, "password")
        XCTAssertEqual(hydrated.last?.dropboxConfig?.accessToken, "test-token")
        try await store.delete(18)
        XCTAssertNil(try vault.read(18))
        let remaining = try await store.load()
        XCTAssertEqual(remaining.map(\.id), [17])
    }

    func testVaultFailureKeepsDatabaseAndPreviousCredentials() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try LegadoDatabase(url: folder.appendingPathComponent("test.sqlite"))
        let vault = RemoteTestVault()
        let store = RemoteServerStore(database: database, vault: vault)
        try await store.save(server())
        let original = try vault.read(17)
        vault.failID = 18
        var second = try server(.s3); second.id = 18
        do { try await store.save(second); XCTFail("Must fail") } catch {}
        XCTAssertEqual(try vault.read(17), original)
        let raw = try await database.loadServers()
        XCTAssertEqual(raw.map(\.id), [17])
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor RemoteTestTransport: HTTPTransport {
    struct Reply: Sendable {
        var status = 200
        var body = ""
    }
    var requests: [URLRequest] = []
    var replies: [Reply]
    init(_ replies: [Reply]) { self.replies = replies }
    func data(for request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw RemoteStorageError.invalidResponse }
        let reply = replies.removeFirst()
        return .init(data: Data(reply.body.utf8), statusCode: reply.status, headers: [:], finalURL: request.url!)
    }
}

private final class RemoteTestVault: RemoteCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64: Data] = [:]
    var failID: Int64?
    func read(_ id: Int64) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[id]
    }
    func write(_ data: Data?, for id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        if id == failID { throw RemoteStorageError.invalidConfiguration("Vault unavailable") }
        values[id] = data
    }
}
