import Foundation

/// 一条跨章 / 跨书搜索命中。
public struct ChapterSearchHit: Codable, Hashable, Identifiable, Sendable {
    public var bookURL: String
    public var bookName: String
    public var chapterIndex: Int
    public var chapterName: String
    public var snippet: String
    public var position: Int = 0

    public var id: String { "\(bookURL)#\(chapterIndex)" }

    public init(
        bookURL: String,
        bookName: String,
        chapterIndex: Int,
        chapterName: String,
        snippet: String,
        position: Int = 0
    ) {
        self.bookURL = bookURL
        self.bookName = bookName
        self.chapterIndex = chapterIndex
        self.chapterName = chapterName
        self.snippet = snippet
        self.position = position == NSNotFound ? 0 : max(position, 0)
    }

    /// 截取命中位置前后的一小段正文，折叠换行与连续空白。
    public static func snippet(in content: String, matching query: String, radius: Int = 36) -> String {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard let range = normalized.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            let head = normalized.prefix(radius * 2)
            return head.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let lower = normalized.index(range.lowerBound, offsetBy: -radius, limitedBy: normalized.startIndex)
            ?? normalized.startIndex
        let upper = normalized.index(range.upperBound, offsetBy: radius, limitedBy: normalized.endIndex)
            ?? normalized.endIndex
        let window = String(normalized[lower..<upper])
        let collapsed = window.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let prefix = lower > normalized.startIndex ? "…" : ""
        let suffix = upper < normalized.endIndex ? "…" : ""
        return prefix + collapsed + suffix
    }
}

/// 章节正文索引 + 搜索。索引落在主库 `chapter_text` 表，
/// 不依赖章节缓存目录（缓存可能被系统清理，索引不会）。
public actor BookSearchIndex {
    private let database: LegadoDatabase

    public init(database: LegadoDatabase) { self.database = database }

    public static func live() -> BookSearchIndex? {
#if SWIFT_PACKAGE
        nil
#else
        (try? LegadoDatabase(url: LegadoDatabase.defaultURL())).map { BookSearchIndex(database: $0) }
#endif
    }

    public func indexAvailableContent(
        book: Book, chapters: [BookChapter], rules: [ReplaceRule] = [],
        cache: ChapterContentCache = .live(), localService: LocalBookService = .live()
    ) async throws {
        for chapter in chapters where !chapter.isVolume {
            try Task.checkCancellation()
            let content: String?
            if book.origin == "local" {
                content = try localService.loadContent(book: book, chapter: chapter).content
            } else {
                let cached = try await cache.load(bookURL: book.bookUrl, chapterURL: chapter.url)
                content = cached?.sourceID == nil || cached?.sourceID == book.origin ? cached?.content : nil
            }
            if let content {
                let processed = ContentSanitizer().process(book: book, chapter: chapter, content: content, rules: rules)
                try await index(bookURL: book.bookUrl, bookName: book.name, chapterIndex: chapter.index,
                                chapterName: processed.title, content: processed.content)
            }
        }
    }

    public func index(
        bookURL: String,
        bookName: String,
        chapterIndex: Int,
        chapterName: String,
        content: String
    ) async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await database.indexChapterText(
            bookURL: bookURL,
            bookName: bookName,
            chapterIndex: chapterIndex,
            chapterName: chapterName,
            content: trimmed
        )
    }

    public func remove(bookURL: String) async throws {
        try await database.removeChapterText(bookURL: bookURL)
    }

    public func search(_ query: String, bookURL: String? = nil, limit: Int = 50) async throws -> [ChapterSearchHit] {
        try await database.searchChapterText(query: query, bookURL: bookURL, limit: limit)
    }

    public func indexedChapterCount(bookURL: String? = nil) async throws -> Int {
        try await database.chapterTextCount(bookURL: bookURL)
    }
}
