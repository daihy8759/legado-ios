import Foundation
import Testing
import ZIPFoundation
@testable import LegadoCore

@Suite struct BookNoteTests {
    private func makeDatabase() throws -> (LegadoDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        return (database, directory)
    }

    @Test func upsertLoadDeleteRoundTrip() async throws {
        let (database, directory) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SQLiteBookNoteRepository(database: database)

        var note = BookNote(bookUrl: "book", bookName: "书", chapterIndex: 2, chapterName: "第三章",
                            paragraphIndex: 5, quote: "原文一句", note: "想法", kind: .note, color: 2)
        try await repository.upsert(note)
        var loaded = try await repository.load(bookURL: "book")
        #expect(loaded.count == 1)
        #expect(loaded.first?.quote == "原文一句")
        #expect(loaded.first?.kind == .note)

        note.note = "改过的想法"
        note.updatedAt += 1
        try await repository.upsert(note)
        loaded = try await repository.load(bookURL: "book")
        #expect(loaded.count == 1, "同一 id 应覆盖而不是新增")
        #expect(loaded.first?.note == "改过的想法")

        try await repository.delete(id: note.id)
        #expect(try await repository.loadAll().isEmpty)
    }

    @Test func replacingAllKeepsOtherBooksThenFilters() async throws {
        let (database, directory) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SQLiteBookNoteRepository(database: database)

        try await repository.replaceAll([
            BookNote(bookUrl: "a", chapterIndex: 0, quote: "A"),
            BookNote(bookUrl: "b", chapterIndex: 0, quote: "B")
        ])
        #expect(try await repository.loadAll().count == 2)
        #expect(try await repository.load(bookURL: "a").count == 1)
        try await repository.deleteAll(bookURL: "a")
        #expect(try await repository.loadAll().map(\.bookUrl) == ["b"])
    }

    @Test func legacyPayloadWithoutNewFieldsDecodes() throws {
        let json = Data(#"{"bookUrl":"b","quote":"q"}"#.utf8)
        let note = try JSONDecoder().decode(BookNote.self, from: json)
        #expect(note.bookUrl == "b")
        #expect(note.color == 0)
        #expect(note.kind == .highlight)
        #expect(!note.id.isEmpty)
    }

    @Test func markdownContainsQuoteAndNote() {
        let note = BookNote(bookUrl: "b", bookName: "书", chapterIndex: 1, chapterName: "第一章",
                            quote: "第一行\n第二行", note: "想法")
        let text = note.markdown()
        #expect(text.contains("> 第一行\n> 第二行"))
        #expect(text.contains("想法"))
        #expect(text.contains("第一章"))
    }
}

@Suite struct BookSearchIndexTests {
    private func makeIndex() throws -> (BookSearchIndex, LegadoDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let database = try LegadoDatabase(url: directory.appending(path: "legado.sqlite3"))
        return (BookSearchIndex(database: database), database, directory)
    }

    @Test func indexesAndFindsAcrossChaptersAndBooks() async throws {
        let (index, _, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await index.index(bookURL: "a", bookName: "书甲", chapterIndex: 0,
                              chapterName: "第一章", content: "少年推门而入，山中一夜雨。")
        try await index.index(bookURL: "a", bookName: "书甲", chapterIndex: 1,
                              chapterName: "第二章", content: "他记得那一夜雨声很大。")
        try await index.index(bookURL: "b", bookName: "书乙", chapterIndex: 0,
                              chapterName: "序", content: "无关内容。")

        let hits = try await index.search("雨", limit: 20)
        #expect(hits.count == 2)
        #expect(hits.allSatisfy { $0.bookURL == "a" })
        #expect(hits.first?.snippet.contains("雨") == true)

        let scoped = try await index.search("雨", bookURL: "b")
        #expect(scoped.isEmpty)
        #expect(try await index.indexedChapterCount() == 3)
    }

    @Test func reindexingSameChapterDoesNotDuplicate() async throws {
        let (index, _, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.index(bookURL: "a", bookName: "书", chapterIndex: 0, chapterName: "一", content: "旧内容")
        try await index.index(bookURL: "a", bookName: "书", chapterIndex: 0, chapterName: "一", content: "新内容含关键词")
        #expect(try await index.indexedChapterCount() == 1)
        #expect(try await index.search("关键词").count == 1)
        #expect(try await index.search("旧内容").isEmpty)
    }

    @Test func emptyQueryReturnsNothing() async throws {
        let (index, _, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.index(bookURL: "a", bookName: "书", chapterIndex: 0, chapterName: "一", content: "内容")
        #expect(try await index.search("   ").isEmpty)
        #expect(try await index.search("%").isEmpty)
    }

    @Test func trigramAndLiteralSearchStayConsistentAfterEditsAndDeletion() async throws {
        let (index, _, directory) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.index(bookURL: "a", bookName: "甲", chapterIndex: 1, chapterName: "第二章",
                              content: "开头😀山中一夜雨，进度100%，路径\\file_name")
        let hits = try await index.search("山中一夜雨")
        #expect(hits.count == 1)
        #expect(hits.first?.position == 4)
        #expect(try await index.search("100%").count == 1)
        #expect(try await index.search("\\file_").count == 1)
        #expect(try await index.search("\" OR \"").isEmpty)
        #expect(try await index.search("山", limit: 0).isEmpty)
        try await index.remove(bookURL: "a")
        #expect(try await index.search("山中一夜雨").isEmpty)
    }
}

@Suite struct BackupServiceTests {
    private func makePayload() -> BackupPayload {
        var payload = BackupPayload()
        var source = BookSource(bookSourceUrl: "https://source.example", bookSourceName: "示例源")
        source.customOrder = 3
        payload.bookSources = [source]
        var book = Book(bookUrl: "https://source.example/book/1", name: "书", author: "作者")
        book.durChapterIndex = 7
        book.durChapterPos = 128
        payload.books = [book]
        payload.bookGroups = [BookGroup(groupId: 1, groupName: "分组")]
        payload.bookmarks = [Bookmark(time: 1_000, bookName: "书")]
        payload.readRecords = [ReadRecord(deviceId: "device", bookName: "书", readTime: 60_000)]
        payload.bookNotes = [BookNote(bookUrl: book.bookUrl, bookName: "书", quote: "原文", note: "想法")]
        payload.replaceRules = [ReplaceRule(id: 1, name: "规则", pattern: "a", replacement: "b")]
        var settings = ApplicationSettings()
        settings.userAgent = "UA"
        payload.settings = settings
        return payload
    }

    @Test func exportThenReadRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "backup.zip")
        let service = BackupService()
        let payload = makePayload()
        try service.export(payload, to: url, appVersion: "test")

        #expect(FileManager.default.fileExists(atPath: url.path))
        let restored = try service.read(from: url)
        #expect(restored.bookSources.first?.bookSourceUrl == "https://source.example")
        #expect(restored.books.first?.durChapterPos == 128)
        #expect(restored.bookNotes.first?.note == "想法")
        #expect(restored.settings?.userAgent == "UA")
    }

    @Test func readingNonArchiveFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "bad.zip")
        try Data("not a zip".utf8).write(to: url)
        #expect(throws: BackupError.self) { try BackupService().read(from: url) }
    }

    @Test func markdownGroupsByBook() {
        let notes = [
            BookNote(bookUrl: "a", bookName: "书甲", chapterIndex: 0, chapterName: "一", quote: "Q1", note: "N1"),
            BookNote(bookUrl: "a", bookName: "书甲", chapterIndex: 1, chapterName: "二", quote: "Q2", note: "N2"),
            BookNote(bookUrl: "b", bookName: "书乙", chapterIndex: 0, chapterName: "序", quote: "Q3", note: "N3")
        ]
        let text = BackupService().markdownNotes(notes)
        #expect(text.contains("## 书甲"))
        #expect(text.contains("## 书乙"))
        #expect(text.contains("N1") && text.contains("N3"))
    }

    @Test func databaseRestoreRollsBackAllTablesAfterLateFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("db.sqlite"))
        let initial = makePayload()
        try await database.restoreBackup(initial)
        var broken = BackupPayload()
        broken.bookmarks = [Bookmark(time: 42, bookName: "a"), Bookmark(time: 42, bookName: "b")]
        do {
            try await database.restoreBackup(broken)
            Issue.record("Duplicate bookmark keys should fail the restore")
        } catch {}
        let restored = try await database.backupPayload()
        #expect(restored.books == initial.books)
        #expect(restored.bookSources.map(\.bookSourceUrl) == initial.bookSources.map(\.bookSourceUrl))
        #expect(restored.bookmarks == initial.bookmarks)
        #expect(restored.bookNotes == initial.bookNotes)
    }

    @Test func emptyBackupAndRSSRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackupService()
        let url = directory.appendingPathComponent("empty.zip")
        try service.export(BackupPayload(), to: url)
        #expect(try service.read(from: url).isEmpty)
        var payload = BackupPayload()
        payload.rssSources = [RssSource(sourceUrl: "https://rss.test", sourceName: "RSS")]
        try service.export(payload, to: url)
        #expect(try service.read(from: url).rssSources.first?.sourceUrl == "https://rss.test")
    }

    @Test func corruptRecognizedSectionCannotSilentlyBecomeAnEmptyRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("corrupt.zip")
        let archive = try Archive(url: url, accessMode: .create)
        let files = ["manifest.json": try JSONEncoder().encode(BackupManifest()),
                     "books.json": Data(#"{"wrong":"shape"}"#.utf8)]
        for (name, data) in files {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { offset, size in
                data.subdata(in: Int(offset)..<min(Int(offset) + size, data.count))
            }
        }
        #expect(throws: BackupError.invalidArchive) { try BackupService().read(from: url) }
    }

    @Test func androidNamedSectionsImportFromNestedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("android.zip")
        let archive = try Archive(url: url, accessMode: .create)
        let source = Data(#"[{"bookSourceUrl":"https://a.test","bookSourceName":"安卓源","futureField":42}]"#.utf8)
        let files = ["backup/bookSource.json": source,
                     "backup/bookshelf.json": Data(#"[{"bookUrl":"https://a.test/1","name":"安卓书","origin":"https://a.test","durChapterIndex":7,"durChapterPos":32}]"#.utf8)]
        for (name, data) in files {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { offset, size in
                data.subdata(in: Int(offset)..<min(Int(offset) + size, data.count))
            }
        }
        let payload = try BackupService().read(from: url)
        #expect(payload.books.first?.durChapterIndex == 7)
        #expect(payload.bookSources.first?.bookSourceName == "安卓源")
        let encoded = try JSONEncoder().encode(payload.bookSources)
        #expect(String(decoding: encoded, as: UTF8.self).contains("futureField"))
    }

    @Test func localBookAndNoteMoveTogetherWhenRestoringOnAnotherDevice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.txt")
        let content = "第一章\n本地正文与书摘"
        try Data(content.utf8).write(to: original)
        var payload = BackupPayload()
        payload.books = [Book(bookUrl: original.absoluteString, name: "本地书", origin: "local")]
        payload.bookNotes = [BookNote(bookUrl: original.absoluteString, quote: "正文")]
        let service = BackupService()
        let backup = directory.appendingPathComponent("backup.zip")
        try service.export(service.includingLocalFiles(payload), to: backup)
        try FileManager.default.removeItem(at: original)
        let loaded = try service.read(from: backup)
        let restored = try service.materializeLocalFiles(loaded, in: directory.appendingPathComponent("another-device"))
        let restoredString = try #require(restored.payload.books.first?.bookUrl)
        let restoredURL = try #require(URL(string: restoredString))
        #expect(try String(contentsOf: restoredURL, encoding: .utf8) == content)
        #expect(restored.payload.bookNotes.first?.bookUrl == restored.payload.books.first?.bookUrl)
        #expect(restored.created.count == 1)
        let repeated = try service.materializeLocalFiles(loaded, in: directory.appendingPathComponent("another-device"))
        #expect(repeated.created.isEmpty)
    }

    @Test func preferencesRoundTripExcludesIdentityAndCredentials() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(27, forKey: "textSize")
        defaults.set("device-secret", forKey: "readingDeviceID")
        let service = BackupService()
        let preferences = try service.capturePreferences(from: defaults)
        #expect(preferences["textSize"] == .number(27))
        #expect(preferences["readingDeviceID"] == nil)
        defaults.set(16, forKey: "textSize")
        try service.restorePreferences(preferences.merging(["readingDeviceID": .string("foreign")]) { _, incoming in incoming }, to: defaults)
        #expect(defaults.integer(forKey: "textSize") == 27)
        #expect(defaults.string(forKey: "readingDeviceID") == "device-secret")
    }

    @Test func mergingBackupRemapsCollidingGroupMasks() throws {
        var current = BackupPayload()
        var oldBook = Book(bookUrl: "old", name: "旧书")
        oldBook.group = 1
        current.books = [oldBook]
        current.bookGroups = [BookGroup(groupId: 1, groupName: "旧分组")]
        var incoming = BackupPayload()
        var newBook = Book(bookUrl: "new", name: "新书")
        newBook.group = 1
        incoming.books = [newBook]
        incoming.bookGroups = [BookGroup(groupId: 1, groupName: "新分组")]
        let merged = try current.merging(incoming)
        #expect(merged.bookGroups.count == 2)
        #expect(merged.books.first { $0.bookUrl == "old" }?.group == 1)
        #expect(merged.books.first { $0.bookUrl == "new" }?.group == 2)
    }
}

@Suite struct ChapterNotificationScheduleTests {
    @Test func quietHoursCoverMidnightAndSameDayWithoutDelayingDaytime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 23)))
        let schedule = ChapterNotificationSchedule(quietHoursEnabled: true, startHour: 22, endHour: 8)
        let delivery = try #require(schedule.deliveryDate(after: evening, calendar: calendar))
        #expect(calendar.component(.day, from: delivery) == 3)
        #expect(calendar.component(.hour, from: delivery) == 8)
        let noon = evening.addingTimeInterval(-11 * 3_600)
        #expect(schedule.deliveryDate(after: noon, calendar: calendar) == nil)
        let daySchedule = ChapterNotificationSchedule(quietHoursEnabled: true, startHour: 10, endHour: 14)
        #expect(calendar.component(.hour, from: try #require(daySchedule.deliveryDate(after: noon, calendar: calendar))) == 14)
        #expect(ChapterNotificationSchedule(quietHoursEnabled: false).deliveryDate(after: evening) == nil)
    }
}
