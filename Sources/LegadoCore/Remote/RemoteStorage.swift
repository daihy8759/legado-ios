import Foundation
import CryptoKit

public struct RemoteFile: Identifiable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var bytes: Int64?
    public var modified: Date?
    public var id: String { path }
    public init(path: String, name: String, isDirectory: Bool, bytes: Int64? = nil, modified: Date? = nil) {
        self.path = path; self.name = name; self.isDirectory = isDirectory
        self.bytes = bytes; self.modified = modified
    }
}

public enum RemoteStorageError: Error, LocalizedError {
    case invalidConfiguration(String), invalidPath, invalidResponse, http(Int), tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .invalidPath: "远端路径无效，不能包含 .、..、反斜杠或控制字符。"
        case .invalidResponse: "服务器返回了无法识别的文件列表。"
        case .http(let status):
            switch status {
            case 401, 403: "认证失败或权限不足（HTTP \(status)），请检查凭据及目录权限。"
            case 404: "远端文件、目录或存储桶不存在（HTTP 404）。"
            case 409, 412: "远端已存在同名文件或目录，请更换名称。"
            case 429: "请求过于频繁，请稍后重试。"
            default: "远端请求失败（HTTP \(status)）。"
            }
        case .tooLarge: "单个文件不能超过 150 MB。"
        }
    }
}

// Remote credentials never pass through the book-source transport, its logs,
// cookie jar or optional certificate-validation bypass.
public final class RemoteHTTPTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }
    public func data(for request: URLRequest) async throws -> HTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (location, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: location) }
        guard let response = response as? HTTPURLResponse else { throw RemoteStorageError.invalidResponse }
        let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= RemoteStorageClient.maximumFileSize else { throw RemoteStorageError.tooLarge }
        return .init(data: try Data(contentsOf: location, options: .mappedIfSafe), statusCode: response.statusCode,
                     headers: [:], finalURL: response.url ?? request.url!)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? { nil }
}

public struct RemoteStorageClient: Sendable {
    public static let maximumFileSize = 150_000_000
    let server: Server
    let transport: any HTTPTransport
    let now: @Sendable () -> Date

    public init(server: Server, transport: any HTTPTransport = RemoteHTTPTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.server = try server.validatedForRemoteStorage()
        self.transport = transport
        self.now = now
    }

    public func list(_ path: String = "") async throws -> [RemoteFile] {
        let path = try Self.path(path)
        let files: [RemoteFile]
        switch server.type {
        case .webDAV: files = try await webDAVList(path)
        case .s3: files = try await s3List(path)
        case .dropbox: files = try await dropboxList(path)
        }
        return files.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func download(_ path: String) async throws -> Data {
        let path = try Self.path(path, allowEmpty: false)
        let response: HTTPResponse
        switch server.type {
        case .webDAV: response = try await send(webDAVRequest("GET", path))
        case .s3: response = try await send(s3Request("GET", path))
        case .dropbox:
            response = try await send(dropboxRequest("download", arguments: ["path": dropboxPath(path)], content: Data(), download: true))
        }
        guard response.data.count <= Self.maximumFileSize else { throw RemoteStorageError.tooLarge }
        return response.data
    }

    public func upload(_ data: Data, to path: String) async throws {
        guard data.count <= Self.maximumFileSize else { throw RemoteStorageError.tooLarge }
        let path = try Self.path(path, allowEmpty: false)
        var request: URLRequest
        switch server.type {
        case .webDAV:
            request = try webDAVRequest("PUT", path, body: data)
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .s3:
            request = try s3Request("PUT", path, body: data, additionalHeaders: ["if-none-match": "*"])
        case .dropbox:
            request = try dropboxRequest("upload", arguments: [
                "path": dropboxPath(path), "mode": "add", "autorename": false, "strict_conflict": true
            ], content: data)
        }
        _ = try await send(request)
    }

    public func createDirectory(_ path: String) async throws {
        let path = try Self.path(path, allowEmpty: false)
        switch server.type {
        case .webDAV: _ = try await send(webDAVRequest("MKCOL", path + "/"))
        case .s3:
            _ = try await send(s3Request("PUT", path + "/", body: Data(), additionalHeaders: ["if-none-match": "*"]))
        case .dropbox: _ = try await send(dropboxRequest("create_folder_v2", arguments: ["path": dropboxPath(path), "autorename": false]))
        }
    }

    public static func path(_ value: String, allowEmpty: Bool = true) throws -> String {
        guard !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw RemoteStorageError.invalidPath }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }), allowEmpty || !parts.isEmpty else {
            throw RemoteStorageError.invalidPath
        }
        return parts.joined(separator: "/")
    }

    static func encode(_ value: String, slash: Bool = false) -> String {
        value.utf8.map { byte -> String in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || [45, 46, 95, 126].contains(byte) || (slash && byte == 47) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let response = try await transport.data(for: request)
        guard (200...299).contains(response.statusCode) else { throw RemoteStorageError.http(response.statusCode) }
        return response
    }

    func webDAVRequest(_ method: String, _ path: String, body: Data? = nil) throws -> URLRequest {
        let config = server.webDAVConfig!
        var components = URLComponents(string: config.url)!
        components.percentEncodedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty ? "/" : components.percentEncodedPath
        if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        components.percentEncodedPath += Self.encode(path, slash: true)
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Basic " + Data("\(config.username):\(config.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return request
    }

    func webDAVList(_ path: String) async throws -> [RemoteFile] {
        var request = try webDAVRequest("PROPFIND", path.isEmpty ? "" : path + "/")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
        """.utf8)
        let response = try await send(request)
        let document = try RemoteXML.parse(response.data)
        guard document.name == "multistatus" else { throw RemoteStorageError.invalidResponse }
        let base = request.url!
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return try document.children.filter { $0.name == "response" }.compactMap { item in
            guard let href = item.value("href"), let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.scheme == base.scheme, url.host == base.host, url.port == base.port,
                  url.path.hasPrefix(basePath) else { return nil }
            let suffix = String(url.path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !suffix.isEmpty, !suffix.contains("/") else { return nil }
            let childPath = try Self.path([path, suffix].filter { !$0.isEmpty }.joined(separator: "/"), allowEmpty: false)
            let properties = item.children.filter { $0.name == "propstat" }.filter {
                ($0.value("status") ?? "").split(separator: " ").dropFirst().first == "200"
            }.compactMap { $0.child("prop") }
            guard !properties.isEmpty else { return nil }
            let directory = properties.contains { $0.child("resourcetype")?.child("collection") != nil }
            let length = properties.compactMap { $0.value("getcontentlength").flatMap(Int64.init) }.first
            let date = properties.compactMap { $0.value("getlastmodified").flatMap(Self.httpDate) }.first
            return .init(path: childPath, name: suffix, isDirectory: directory, bytes: length, modified: date)
        }
    }

    func s3Request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                   additionalHeaders: [String: String] = [:]) throws -> URLRequest {
        let config = server.s3Config!
        var components = URLComponents(string: config.endpoint)!
        let prefix = try Self.path(config.prefix)
        let key = query["list-type"] == nil ? [prefix, path].filter { !$0.isEmpty }.joined(separator: "/") : ""
        var basePath = components.percentEncodedPath
        if !basePath.hasSuffix("/") { basePath += "/" }
        if config.pathStyle { basePath += Self.encode(config.bucket) + "/" }
        else { components.host = config.bucket + "." + (components.host ?? "") }
        components.percentEncodedPath = basePath + Self.encode(key, slash: true)
        let encodedQuery: [(String, String)] = query.map { (Self.encode($0.key), Self.encode($0.value)) }
        let sortedQuery = encodedQuery.sorted { left, right in
            left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
        }
        components.percentEncodedQuery = query.isEmpty ? nil : sortedQuery.map { pair in
            pair.0 + "=" + pair.1
        }.joined(separator: "&")
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body
        Self.signS3(&request, config: config, at: now(), additionalHeaders: additionalHeaders)
        return request
    }

    static func signS3(_ request: inout URLRequest, config: Server.S3Config, at date: Date,
                       additionalHeaders: [String: String] = [:]) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date), day = String(timestamp.prefix(8))
        let url = request.url!, parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let hash = sha256(request.httpBody ?? Data())
        var headers = additionalHeaders
        headers["host"] = (url.host ?? "") + (url.port.map { ":\($0)" } ?? "")
        headers["x-amz-date"] = timestamp; headers["x-amz-content-sha256"] = hash
        if !config.sessionToken.isEmpty { headers["x-amz-security-token"] = config.sessionToken }
        let keys = headers.keys.sorted()
        let canonicalHeaders = keys.map { "\($0):\(headers[$0]!.split(whereSeparator: \.isWhitespace).joined(separator: " "))\n" }.joined()
        let signedHeaders = keys.joined(separator: ";")
        let canonical = [request.httpMethod ?? "GET", parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath,
                         parts.percentEncodedQuery ?? "", canonicalHeaders, signedHeaders, hash].joined(separator: "\n")
        let scope = "\(day)/\(config.region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(sha256(Data(canonical.utf8)))"
        var key = Data(("AWS4" + config.secretKey).utf8)
        for value in [day, config.region, "s3", "aws4_request"] { key = hmac(key, value) }
        let signature = hmac(key, stringToSign).map { String(format: "%02x", $0) }.joined()
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(config.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hmac(_ key: Data, _ value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }

    func s3List(_ path: String) async throws -> [RemoteFile] {
        let root = try Self.path(server.s3Config!.prefix)
        let folder = [root, path].filter { !$0.isEmpty }.joined(separator: "/")
        let prefix = folder.isEmpty ? "" : folder + "/"
        var files: [RemoteFile] = [], seen = Set<String>()
        var cursor: String?
        repeat {
            var query = ["list-type": "2", "delimiter": "/", "prefix": prefix, "encoding-type": "url"]
            if let cursor { query["continuation-token"] = cursor }
            let response = try await send(s3Request("GET", "", query: query))
            let document = try RemoteXML.parse(response.data)
            guard document.name == "ListBucketResult" else { throw RemoteStorageError.invalidResponse }
            for item in document.children where item.name == "Contents" || item.name == "CommonPrefixes" {
                guard let encoded = item.value(item.name == "Contents" ? "Key" : "Prefix"),
                      let key = encoded.removingPercentEncoding, key.hasPrefix(prefix), key != prefix else { continue }
                let name = String(key.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !name.isEmpty, !name.contains("/") else { continue }
                let relative = try Self.path([path, name].filter { !$0.isEmpty }.joined(separator: "/"))
                files.append(.init(path: relative, name: name, isDirectory: item.name == "CommonPrefixes",
                                   bytes: item.value("Size").flatMap(Int64.init),
                                   modified: item.value("LastModified").flatMap(Self.isoDate)))
            }
            cursor = document.value("IsTruncated") == "true" ? document.value("NextContinuationToken") : nil
            if document.value("IsTruncated") == "true" {
                guard let cursor, !cursor.isEmpty, seen.insert(cursor).inserted else { throw RemoteStorageError.invalidResponse }
            }
        } while cursor != nil
        return files
    }

    func dropboxPath(_ path: String) -> String {
        let root = server.dropboxConfig!.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let combined = [root, path].filter { !$0.isEmpty }.joined(separator: "/")
        return combined.isEmpty ? "" : "/" + combined
    }

    func dropboxRequest(_ route: String, arguments: [String: Any], content: Data? = nil, download: Bool = false) throws -> URLRequest {
        let host = content == nil ? "api.dropboxapi.com" : "content.dropboxapi.com"
        var request = URLRequest(url: URL(string: "https://\(host)/2/files/\(route)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + server.dropboxConfig!.accessToken, forHTTPHeaderField: "Authorization")
        let json = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        if let content {
            // Dropbox requires non-ASCII JSON in HTTP headers to be escaped.
            let ascii = String(decoding: json, as: UTF8.self).utf16.map { unit -> String in
                unit > 127 ? String(format: "\\u%04x", unit) : String(UnicodeScalar(unit)!)
            }.joined()
            request.setValue(ascii, forHTTPHeaderField: "Dropbox-API-Arg")
            if !download { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
            request.httpBody = download ? nil : content
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = json
        }
        return request
    }

    func dropboxList(_ path: String) async throws -> [RemoteFile] {
        var request = try dropboxRequest("list_folder", arguments: ["path": dropboxPath(path), "recursive": false])
        var files: [RemoteFile] = [], seen = Set<String>()
        while true {
            let response = try await send(request)
            guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let entries = json["entries"] as? [[String: Any]], let more = json["has_more"] as? Bool else {
                throw RemoteStorageError.invalidResponse
            }
            for item in entries {
                guard let tag = item[".tag"] as? String, ["file", "folder"].contains(tag),
                      let name = item["name"] as? String, !name.contains("/") else { continue }
                let relative = try Self.path([path, name].filter { !$0.isEmpty }.joined(separator: "/"), allowEmpty: false)
                files.append(.init(path: relative, name: name, isDirectory: tag == "folder",
                                   bytes: (item["size"] as? NSNumber)?.int64Value,
                                   modified: (item["server_modified"] as? String).flatMap(Self.isoDate)))
            }
            if !more { return files }
            guard let cursor = json["cursor"] as? String, !cursor.isEmpty, seen.insert(cursor).inserted else {
                throw RemoteStorageError.invalidResponse
            }
            request = try dropboxRequest("list_folder/continue", arguments: ["cursor": cursor])
        }
    }

    static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

extension Server {
    public func synchronizationIdentity() throws -> String {
        let value = try validatedForRemoteStorage()
        let identity: String
        switch value.type {
        case .webDAV:
            let config = value.webDAVConfig!
            identity = "dav|\(config.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")))|\(config.username)"
        case .s3:
            let config = value.s3Config!
            identity = "s3|\(config.endpoint)|\(config.bucket)|\(config.prefix)"
        case .dropbox:
            // Tokens can represent different Dropbox accounts or app roots.
            let config = value.dropboxConfig!
            identity = "dropbox|\(config.accessToken)|\(config.rootPath)"
        }
        return RemoteStorageClient.sha256(Data(identity.utf8))
    }

    public func validatedForRemoteStorage() throws -> Self {
        var server = self
        server.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.name.isEmpty else { throw RemoteStorageError.invalidConfiguration("请输入存储名称。") }
        func endpoint(_ value: String) throws -> String {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URLComponents(string: value), url.scheme == "https" || url.scheme == "http",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, url.url != nil else {
                throw RemoteStorageError.invalidConfiguration("请输入不含账号、查询参数的 HTTP / HTTPS 服务器地址。")
            }
            if let port = url.port, !(1...65535).contains(port) { throw RemoteStorageError.invalidConfiguration("服务器端口无效。") }
            return value
        }
        func credential(_ value: String) throws {
            guard !value.isEmpty, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw RemoteStorageError.invalidConfiguration("请填写有效的认证凭据。")
            }
        }
        switch type {
        case .webDAV:
            guard var config = webDAVConfig else { throw RemoteStorageError.invalidConfiguration("WebDAV 配置无效。") }
            config.url = try endpoint(config.url)
            guard !config.username.contains(":"), !config.username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !config.password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw RemoteStorageError.invalidConfiguration("WebDAV 用户名或密码格式无效。")
            }
            try server.setConfiguration(config)
        case .s3:
            guard var config = s3Config else { throw RemoteStorageError.invalidConfiguration("S3 配置无效。") }
            config.endpoint = try endpoint(config.endpoint)
            config.region = config.region.trimmingCharacters(in: .whitespacesAndNewlines)
            config.bucket = config.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !config.region.isEmpty, config.region.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  !config.bucket.isEmpty, config.bucket.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else {
                throw RemoteStorageError.invalidConfiguration("请填写有效的 Region 和 Bucket 名称。")
            }
            try credential(config.accessKey); try credential(config.secretKey)
            if !config.sessionToken.isEmpty { try credential(config.sessionToken) }
            config.prefix = try RemoteStorageClient.path(config.prefix)
            try server.setConfiguration(config)
        case .dropbox:
            guard var config = dropboxConfig else { throw RemoteStorageError.invalidConfiguration("Dropbox 配置无效。") }
            try credential(config.accessToken)
            config.rootPath = try RemoteStorageClient.path(config.rootPath)
            try server.setConfiguration(config)
        }
        return server
    }
}

final class RemoteXML: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        var text = ""
        var children: [Node] = []
        init(_ name: String) { self.name = name }
        func child(_ name: String) -> Node? { children.first { $0.name == name } }
        func value(_ name: String) -> String? { child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    var stack: [Node] = []
    var root: Node?
    static func parse(_ data: Data) throws -> Node {
        let delegate = RemoteXML(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { throw RemoteStorageError.invalidResponse }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard stack.count < 64 else { parser.abortParsing(); return }
        let node = Node(elementName)
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}
