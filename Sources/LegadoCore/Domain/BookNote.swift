import Foundation

/// 一条笔记 / 划线。以「段落锚点」定位，而不是字符偏移：
/// 字号、字体、主题、分页方式变化后，字符偏移会失效，段落文本仍然稳定。
public struct BookNote: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Int, Codable, Sendable {
        /// 仅划线条，没有想法
        case highlight = 0
        /// 划线条 + 想法
        case note = 1
    }

    public var id: String
    public var bookUrl: String
    public var bookName: String
    public var bookAuthor: String
    public var chapterIndex: Int
    public var chapterName: String
    /// 段落在该章正文中的序号（从 0 开始）。EPUB 原排版下为 -1，用 epubLocation 定位。
    public var paragraphIndex: Int
    /// 划线原文，用于重新定位与展示
    public var quote: String
    /// 用户想法
    public var note: String
    public var kind: Kind
    /// 0 默认黄，1 绿，2 蓝，3 粉，4 紫
    public var color: Int
    public var epubLocation: String?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var startOffset: Int?
    public var endOffset: Int?

    public init(
        id: String = UUID().uuidString,
        bookUrl: String,
        bookName: String = "",
        bookAuthor: String = "",
        chapterIndex: Int = 0,
        chapterName: String = "",
        paragraphIndex: Int = -1,
        quote: String = "",
        note: String = "",
        kind: Kind = .highlight,
        color: Int = 0,
        epubLocation: String? = nil,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        updatedAt: Int64? = nil,
        startOffset: Int? = nil,
        endOffset: Int? = nil
    ) {
        self.id = id
        self.bookUrl = bookUrl
        self.bookName = bookName
        self.bookAuthor = bookAuthor
        self.chapterIndex = chapterIndex
        self.chapterName = chapterName
        self.paragraphIndex = paragraphIndex
        self.quote = quote
        self.note = note
        self.kind = kind
        self.color = color
        self.epubLocation = epubLocation
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.startOffset = startOffset
        self.endOffset = endOffset
    }

    private enum CodingKeys: String, CodingKey {
        case id, bookUrl, bookName, bookAuthor, chapterIndex, chapterName, paragraphIndex
        case quote, note, kind, color, epubLocation, createdAt, updatedAt, startOffset, endOffset
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        bookUrl = try values.decodeIfPresent(String.self, forKey: .bookUrl) ?? ""
        bookName = try values.decodeIfPresent(String.self, forKey: .bookName) ?? ""
        bookAuthor = try values.decodeIfPresent(String.self, forKey: .bookAuthor) ?? ""
        chapterIndex = try values.decodeIfPresent(Int.self, forKey: .chapterIndex) ?? 0
        chapterName = try values.decodeIfPresent(String.self, forKey: .chapterName) ?? ""
        paragraphIndex = try values.decodeIfPresent(Int.self, forKey: .paragraphIndex) ?? -1
        quote = try values.decodeIfPresent(String.self, forKey: .quote) ?? ""
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .highlight
        color = try values.decodeIfPresent(Int.self, forKey: .color) ?? 0
        epubLocation = try values.decodeIfPresent(String.self, forKey: .epubLocation)
        createdAt = try values.decodeIfPresent(Int64.self, forKey: .createdAt)
            ?? Int64(Date().timeIntervalSince1970 * 1_000)
        updatedAt = try values.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
        startOffset = try values.decodeIfPresent(Int.self, forKey: .startOffset)
        endOffset = try values.decodeIfPresent(Int.self, forKey: .endOffset)
    }

    public var isEmptyIdea: Bool {
        note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 导出为 Markdown 片段
    public func markdown() -> String {
        var lines: [String] = []
        if !quote.isEmpty {
            let quoted = quote
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            lines.append(quoted)
        }
        if !isEmptyIdea { lines.append(note) }
        let day = Date(timeIntervalSince1970: Double(createdAt) / 1_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("—— \(formatter.string(from: day))" + (chapterName.isEmpty ? "" : " · \(chapterName)"))
        return lines.joined(separator: "\n\n")
    }
}
