import XCTest
@testable import LegadoCore

final class BookshelfSyncTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func engine(_ device: String, _ storage: MemoryShelfStorage) -> BookshelfSyncEngine {
        .init(storage: storage, stateURL: folder.appendingPathComponent(device + "/state.json"),
              now: { Date(timeIntervalSince1970: 1_000) })
    }
    private func input(_ device: String, _ books: [Book] = [], groups: [BookGroup] = []) -> BookshelfSyncInput {
        .init(books: books, groups: groups, localDirectory: folder.appendingPathComponent(device + "/books"))
    }
    private func book(_ key: String = "one", chapter: Int = 0, time: Int64 = 0) -> Book {
        var book = Book(bookUrl: "https://books.test/" + key, name: key, origin: "https://books.test")
        book.durChapterIndex = chapter; book.durChapterTime = time; book.durChapterPos = chapter * 100
        return book
    }
    @discardableResult
    private func sync(_ engine: BookshelfSyncEngine, _ input: BookshelfSyncInput) async throws -> BookshelfSyncResult {
        let result = try await engine.synchronize(input)
        try await engine.acknowledge(result)
        return result
    }

    func testTwoDevicesMergeBooksAndNewestProgressIncludingBackwardsReading() async throws {
        let storage = MemoryShelfStorage()
        let first = engine("a", storage), second = engine("b", storage)
        try await sync(first, input("a", [book(chapter: 8, time: 1_000)]))
        let imported = try await sync(second, input("b"))
        XCTAssertEqual(imported.books.first?.durChapterIndex, 8)
        var backwards = imported.books[0]
        backwards.durChapterIndex = 2; backwards.durChapterTime = 2_000; backwards.durChapterPos = 30
        try await sync(second, input("b", [backwards, book("two")]))
        let merged = try await sync(first, input("a", [book(chapter: 8, time: 1_000)]))
        XCTAssertEqual(Set(merged.books.map(\.name)), ["one", "two"])
        let progress = try XCTUnwrap(merged.books.first { $0.name == "one" })
        XCTAssertEqual(progress.durChapterIndex, 2)
        XCTAssertEqual(progress.durChapterPos, 30)
    }

    func testConcurrentWritersConvergeWithoutOverwritingSnapshots() async throws {
        let storage = MemoryShelfStorage()
        let a = engine("a", storage), b = engine("b", storage)
        let inputA = input("a", [book("a")]), inputB = input("b", [book("b")])
        async let first = a.synchronize(inputA)
        async let second = b.synchronize(inputB)
        let (ra, rb) = try await (first, second)
        try await a.acknowledge(ra); try await b.acknowledge(rb)
        let mergedA = try await sync(a, input("a", ra.books))
        let mergedB = try await sync(b, input("b", rb.books))
        XCTAssertEqual(Set(mergedA.books.map(\.name)), ["a", "b"])
        XCTAssertEqual(Set(mergedB.books.map(\.name)), ["a", "b"])
        let count = await storage.snapshotCount
        XCTAssertEqual(count, 2)
    }

    func testDeletionPropagatesAndStaleProgressDoesNotResurrectBook() async throws {
        let storage = MemoryShelfStorage()
        let a = engine("a", storage), b = engine("b", storage)
        try await sync(a, input("a", [book(chapter: 4, time: 100)]))
        let initial = try await sync(b, input("b"))
        try await sync(a, input("a"))
        var stale = initial.books[0]
        stale.durChapterIndex = 5; stale.durChapterTime = 200
        let deleted = try await sync(b, input("b", [stale]))
        XCTAssertTrue(deleted.books.isEmpty)
        let readded = try await sync(a, input("a", [book(time: 300)]))
        XCTAssertEqual(readded.books.count, 1)
        let restored = try await sync(b, input("b"))
        XCTAssertEqual(restored.books.count, 1)
    }

    func testMetadataAndProgressMergeIndependently() async throws {
        let storage = MemoryShelfStorage()
        let a = engine("a", storage), b = engine("b", storage)
        try await sync(a, input("a", [book(time: 100)]))
        let initial = try await sync(b, input("b"))
        var renamed = book(time: 100); renamed.name = "New title"
        try await sync(a, input("a", [renamed]))
        var reading = initial.books[0]; reading.durChapterIndex = 7; reading.durChapterTime = 200
        let merged = try await sync(b, input("b", [reading]))
        XCTAssertEqual(merged.books.first?.name, "New title")
        XCTAssertEqual(merged.books.first?.durChapterIndex, 7)
    }

    func testProgressChangesWithinOneMillisecondAreNotDropped() async throws {
        let storage = MemoryShelfStorage()
        let a = engine("a", storage), b = engine("b", storage)
        let initial = try await sync(a, input("a", [book(time: 100)]))
        var moved = initial.books[0]; moved.durChapterPos = 42
        let updated = try await sync(a, input("a", [moved]))
        XCTAssertEqual(updated.books.first?.durChapterPos, 42)
        let remote = try await sync(b, input("b"))
        XCTAssertEqual(remote.books.first?.durChapterPos, 42)
    }

    func testLocalBooksUseContentIdentityAndTransferOriginalFile() async throws {
        let storage = MemoryShelfStorage()
        let a = engine("a", storage), b = engine("b", storage)
        let directory = input("a").localDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("original.txt")
        let data = Data("第一章 开始\n\n这是用来测试同步的正文。".utf8)
        try data.write(to: url)
        var local = Book(bookUrl: url.absoluteString, name: "Local book")
        local.originName = "original.txt"; local.durChapterTime = 100; local.durChapterPos = 17
        try await sync(a, input("a", [local]))
        let pulled = try await sync(b, input("b"))
        let imported = try XCTUnwrap(pulled.books.first)
        let importedURL = try XCTUnwrap(URL(string: imported.bookUrl))
        XCTAssertNotEqual(importedURL, url)
        XCTAssertEqual(try Data(contentsOf: importedURL), data)
        XCTAssertEqual(imported.name, "Local book")
        XCTAssertEqual(imported.durChapterPos, 17)
        // Renaming the same bytes must not create a second shelf identity.
        let renamedURL = directory.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: url, to: renamedURL)
        local.bookUrl = renamedURL.absoluteString; local.originName = "renamed.txt"
        try await sync(a, input("a", [local]))
        let merged = try await sync(b, input("b", pulled.books))
        XCTAssertEqual(merged.books.count, 1)
        XCTAssertEqual(merged.books[0].originName, "renamed.txt")
        let assets = await storage.assetCount
        XCTAssertEqual(assets, 1)
    }

    func testEPUBLocatorSurvivesMergeAndDevicePathsAreNotUploaded() async throws {
        let storage = MemoryShelfStorage()
        var reading = book(time: 100)
        reading.readConfig = .init()
        reading.readConfig?.epubLocation = #"{"href":"OEBPS/chapter2.xhtml","locations":{"progression":0.4}}"#
        reading.variable = #"{"private":"do not sync"}"#
        reading.customCoverUrl = "file:///private/device/cover.png"
        try await sync(engine("a", storage), input("a", [reading]))
        let imported = try await sync(engine("b", storage), input("b"))
        XCTAssertEqual(imported.books.first?.readConfig?.epubLocation, reading.readConfig?.epubLocation)
        XCTAssertNil(imported.books.first?.variable)
        let snapshots = await storage.snapshotData
        XCTAssertFalse(snapshots.contains { String(decoding: $0, as: UTF8.self).contains("/private/device/") })
        XCTAssertFalse(snapshots.contains { String(decoding: $0, as: UTF8.self).contains("do not sync") })
    }

    func testGroupMasksAreRemappedAcrossDevices() async throws {
        let storage = MemoryShelfStorage()
        var science = book("science"); science.group = 1
        let sciGroup = BookGroup(groupId: 1, groupName: "科幻")
        try await sync(engine("a", storage), input("a", [science], groups: [sciGroup]))
        var history = book("history"); history.group = 1
        let historyGroup = BookGroup(groupId: 1, groupName: "历史")
        let result = try await sync(engine("b", storage), input("b", [history], groups: [historyGroup]))
        XCTAssertEqual(result.groups.count, 2)
        for book in result.books {
            let expected = book.name == "science" ? "科幻" : "历史"
            XCTAssertEqual(result.groups.first(where: { $0.groupId == book.group })?.groupName, expected)
        }
    }

    func testGroupRenameDuringTransferPreservesBookMembership() async throws {
        let storage = MemoryShelfStorage()
        var reading = book(); reading.group = 1
        let group = BookGroup(groupId: 1, groupName: "Before")
        try await sync(engine("a", storage), input("a", [reading], groups: [group]))
        let base = input("b", [reading], groups: [group])
        let incoming = try await engine("b", storage).synchronize(base)
        var renamed = group; renamed.groupName = "After"
        let current = input("b", [reading], groups: [renamed])
        let result = try BookshelfSyncReconciler.reconcile(base: base, current: current, incoming: incoming)
        XCTAssertEqual(result.groups.map(\.groupName), ["After"])
        XCTAssertEqual(result.books.first?.group, 1)
    }

    func testUnchangedShelfDoesNotPublishRepeatedSnapshots() async throws {
        let storage = MemoryShelfStorage()
        let engine = engine("real", storage)
        let first = try await sync(engine, input("real", [book()]))
        let unchanged = try await sync(engine, input("real", first.books, groups: first.groups))
        XCTAssertFalse(unchanged.uploaded)
        let count = await storage.snapshotCount
        XCTAssertEqual(count, 1)
    }

    func testFailedUploadCanRetryWithoutLosingLocalChange() async throws {
        let storage = MemoryShelfStorage()
        let service = self.engine("real", storage)
        await storage.setFailUploads(true)
        do { _ = try await service.synchronize(input("real", [book()])); XCTFail("Expected upload failure") } catch {}
        await storage.setFailUploads(false)
        let retry = try await sync(self.engine("real", storage), input("real", [book()]))
        XCTAssertEqual(retry.books.count, 1)
        let imported = try await sync(self.engine("b", storage), input("b"))
        XCTAssertEqual(imported.books.count, 1)
    }

    func testUnacknowledgedImportIsRetriedRatherThanTurnedIntoDeletion() async throws {
        let storage = MemoryShelfStorage()
        try await sync(engine("a", storage), input("a", [book()]))
        let service = engine("b", storage)
        let first = try await service.synchronize(input("b"))
        XCTAssertEqual(first.books.count, 1)
        // Simulate a failed local database save: do not acknowledge the result.
        let retry = try await sync(engine("b", storage), input("b"))
        XCTAssertEqual(retry.books.count, 1)
        let count = await storage.snapshotCount
        XCTAssertEqual(count, 1)
    }

    func testRejectsCorruptSnapshotsAndMissingLocalFiles() async throws {
        let storage = MemoryShelfStorage()
        let id = UUID().uuidString.lowercased()
        await storage.insert(Data(#"{"version":99}"#.utf8),
                             at: BookshelfSyncEngine.directory + "/snapshots/" + id + "_00000000000000000001_x.json")
        do { _ = try await engine("a", storage).synchronize(input("a")); XCTFail("Must reject corrupt data") } catch {}
        let missing = Book(bookUrl: input("b").localDirectory.appendingPathComponent("missing.txt").absoluteString, name: "Missing")
        do { _ = try await engine("b", storage).synchronize(input("b", [missing])); XCTFail("Must reject missing local file") } catch {}
    }

    func testReconciliationPreservesEditsAndRemovalsDuringNetworkTransfer() async throws {
        let storage = MemoryShelfStorage()
        var remote = book(time: 200); remote.name = "Remote title"
        try await sync(engine("a", storage), input("a", [remote, book("removed")]))
        let original = book(time: 100), removed = book("removed")
        let base = input("b", [original, removed])
        let incoming = try await engine("b", storage).synchronize(base)
        var edited = original; edited.name = "Edited while syncing"; edited.durChapterTime = 300; edited.durChapterPos = 99
        let current = input("b", [edited, book("added")])
        let rebased = try BookshelfSyncReconciler.reconcile(base: base, current: current, incoming: incoming)
        XCTAssertFalse(rebased.books.contains { $0.name == "removed" })
        XCTAssertTrue(rebased.books.contains { $0.name == "added" })
        let kept = try XCTUnwrap(rebased.books.first { $0.bookUrl == original.bookUrl })
        XCTAssertEqual(kept.name, "Edited while syncing")
        XCTAssertEqual(kept.durChapterPos, 99)
    }
}

private actor MemoryShelfStorage: BookshelfSyncStorage {
    private var objects: [String: Data] = [:]
    private var directories = Set<String>()
    private var failUploads = false
    var snapshotCount: Int { objects.keys.filter { $0.contains("/snapshots/") }.count }
    var assetCount: Int { objects.keys.filter { $0.contains("/files/") }.count }
    var snapshotData: [Data] { objects.filter { $0.key.contains("/snapshots/") }.map(\.value) }
    func setFailUploads(_ value: Bool) { failUploads = value }
    func insert(_ data: Data, at path: String) { objects[path] = data }
    func list(_ path: String) throws -> [RemoteFile] {
        guard directories.contains(path) else { throw RemoteStorageError.http(404) }
        return objects.keys.filter { ($0 as NSString).deletingLastPathComponent == path }.map {
            .init(path: $0, name: ($0 as NSString).lastPathComponent, isDirectory: false)
        }
    }
    func download(_ path: String) throws -> Data {
        guard let data = objects[path] else { throw RemoteStorageError.http(404) }
        return data
    }
    func upload(_ data: Data, to path: String) throws {
        if failUploads { throw RemoteStorageError.http(503) }
        guard objects[path] == nil else { throw RemoteStorageError.http(412) }
        objects[path] = data
    }
    func createDirectory(_ path: String) throws {
        guard directories.insert(path).inserted else { throw RemoteStorageError.http(409) }
    }
}
