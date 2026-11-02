import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct BookshelfSyncApplicationTests {
    private func book(_ name: String, time: Int64 = 0) -> Book {
        var book = Book(bookUrl: "https://sync.test/" + name, name: name, origin: "https://sync.test")
        book.durChapterTime = time
        return book
    }
    private func setup(_ books: [Book]) async -> BookLibraryModel {
        let model = BookLibraryModel(repository: InMemoryBookRepository(books: books),
                                     chapterRepository: InMemoryBookChapterRepository(),
                                     progressDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.load()
        return model
    }

    @Test func applyingRemoteShelfPreservesConcurrentReadingAddsAndRemovals() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = book("reading", time: 100), removed = book("removed")
        let model = await setup([original, removed])
        let base = try await model.synchronizationSnapshot()
        let storage = ApplicationSyncStorage()
        let remote = BookshelfSyncEngine(storage: storage, stateURL: folder.appendingPathComponent("remote.json"))
        var reading = original; reading.durChapterTime = 200; reading.durChapterPos = 20
        _ = try await remote.synchronize(.init(books: [reading, removed, book("remote-added")], groups: [], localDirectory: folder))
        let local = BookshelfSyncEngine(storage: storage, stateURL: folder.appendingPathComponent("local.json"))
        let result = try await local.synchronize(base)
        await model.updateProgress(for: original, chapter: .init(url: "/chapter", title: "New chapter", bookUrl: original.bookUrl, index: 3), position: 99)
        await model.remove(bookURL: removed.bookUrl)
        await model.addOrUpdate(book("local-added"))
        try await model.applySynchronizedShelf(result, startedWith: base)
        #expect(!model.books.contains { $0.bookUrl == removed.bookUrl })
        #expect(model.books.contains { $0.name == "local-added" })
        #expect(model.books.contains { $0.name == "remote-added" })
        #expect(model.books.first { $0.bookUrl == original.bookUrl }?.durChapterPos == 99)
    }

    @Test func failedLocalShelfSaveLeavesOriginalBooksAndImportCanRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = book("original")
        let model = BookLibraryModel(repository: SyncFailingRepository(books: [original]), chapterRepository: InMemoryBookChapterRepository(),
                                     progressDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.load()
        let base = try await model.synchronizationSnapshot()
        let storage = ApplicationSyncStorage()
        let remote = BookshelfSyncEngine(storage: storage, stateURL: folder.appendingPathComponent("remote.json"))
        _ = try await remote.synchronize(.init(books: [book("remote")], groups: [], localDirectory: folder))
        let local = BookshelfSyncEngine(storage: storage, stateURL: folder.appendingPathComponent("local.json"))
        let result = try await local.synchronize(base)
        do {
            try await model.applySynchronizedShelf(result, startedWith: base)
            Issue.record("Expected local save to fail")
        } catch {}
        #expect(model.books == [original])
        // The coordinator must not acknowledge a result after the failed save.
        let retry = try await local.synchronize(try await model.synchronizationSnapshot())
        #expect(retry.books.contains { $0.name == "remote" })
        #expect(retry.books.contains { $0.name == "original" })
    }

    @Test func failedInitialLoadCannotPublishAnEmptyShelf() async throws {
        let model = BookLibraryModel(repository: SyncFailingRepository(books: [], failsLoad: true))
        await model.load()
        do {
            _ = try await model.synchronizationSnapshot()
            Issue.record("A failed database load must block synchronization")
        } catch {}
    }
}

private actor SyncFailingRepository: BookRepository {
    var books: [Book]
    var failsLoad = false
    init(books: [Book], failsLoad: Bool = false) { self.books = books; self.failsLoad = failsLoad }
    func load() throws -> [Book] {
        if failsLoad { throw LocalFileError.saveFailed("Disk unavailable") }
        return books
    }
    func save(_ books: [Book]) throws { throw LocalFileError.saveFailed("Disk full") }
}

private actor ApplicationSyncStorage: BookshelfSyncStorage {
    var values: [String: Data] = [:]
    var folders = Set<String>()
    func list(_ path: String) -> [RemoteFile] {
        values.keys.filter { ($0 as NSString).deletingLastPathComponent == path }.map {
            .init(path: $0, name: ($0 as NSString).lastPathComponent, isDirectory: false)
        }
    }
    func download(_ path: String) throws -> Data {
        guard let data = values[path] else { throw RemoteStorageError.http(404) }
        return data
    }
    func upload(_ data: Data, to path: String) throws {
        guard values[path] == nil else { throw RemoteStorageError.http(412) }
        values[path] = data
    }
    func createDirectory(_ path: String) { folders.insert(path) }
}
