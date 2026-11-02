import Foundation
import ZIPFoundation
import CryptoKit

public enum BackupError: Error, LocalizedError, Equatable {
    case cannotCreateArchive
    case invalidArchive
    case emptyBackup
    case unsupportedVersion(Int)
    case missingLocalFile(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateArchive: "无法创建备份文件"
        case .invalidArchive: "备份文件已损坏或不是有效的备份压缩包"
        case .emptyBackup: "备份文件中没有可识别的数据"
        case .unsupportedVersion(let version): "备份格式版本 \(version) 高于当前支持版本"
        case .missingLocalFile(let name): "本地书《\(name)》原文件缺失或超过 150 MB，请重新导入后再备份"
        }
    }
}

public struct BackupManifest: Codable, Sendable {
    public var format: String = "legado-ios-backup"
    public var version: Int = 1
    public var createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    public var appVersion: String = ""
    public var counts: [String: Int] = [:]

    public init() {}
}

/// 备份内容。所有字段都可为空：旧备份、安卓备份可能只包含其中一部分。
public struct BackupPayload: Sendable {
    public var bookSources: [BookSource] = []
    public var books: [Book] = []
    public var bookGroups: [BookGroup] = []
    public var bookmarks: [Bookmark] = []
    public var readRecords: [ReadRecord] = []
    public var bookNotes: [BookNote] = []
    public var replaceRules: [ReplaceRule] = []
    public var txtTocRules: [TxtTocRule] = []
    public var httpTTS: [HttpTTS] = []
    public var ruleSubs: [RuleSub] = []
    public var settings: ApplicationSettings?
    public var rssSources: [RssSource] = []
    public var localBookFiles: [String: Data] = [:]
    public var preferences: [String: JSONValue]?

    public init() {}

    public var isEmpty: Bool {
        bookSources.isEmpty && books.isEmpty && bookGroups.isEmpty && bookmarks.isEmpty
            && readRecords.isEmpty && bookNotes.isEmpty && replaceRules.isEmpty
            && txtTocRules.isEmpty && httpTTS.isEmpty && ruleSubs.isEmpty && rssSources.isEmpty && settings == nil
    }

    public var summary: [String: Int] {
        [
            "书源": bookSources.count,
            "书籍": books.count,
            "分组": bookGroups.count,
            "书签": bookmarks.count,
            "阅读记录": readRecords.count,
            "笔记": bookNotes.count,
            "净化规则": replaceRules.count,
            "TXT 目录规则": txtTocRules.count,
            "在线朗读": httpTTS.count,
            "规则订阅": ruleSubs.count,
            "RSS 源": rssSources.count
        ]
    }

    public func merging(_ incoming: BackupPayload) throws -> BackupPayload {
        func merged<Value, Key: Hashable>(_ current: [Value], _ additions: [Value], key: (Value) -> Key) -> [Value] {
            var values = current
            var indices = Dictionary(current.enumerated().map { (key($0.element), $0.offset) }, uniquingKeysWith: { _, last in last })
            for value in additions {
                if let index = indices[key(value)] { values[index] = value }
                else { indices[key(value)] = values.count; values.append(value) }
            }
            return values
        }
        var result = self
        var imported = incoming
        var groups = bookGroups
        var used = bookGroups.filter { $0.groupId > 0 }.reduce(Int64(0)) { $0 | $1.groupId }
            | books.reduce(Int64(0)) { $0 | $1.group }
        var groupMappings: [Int64: Int64] = [:]
        for var group in incoming.bookGroups {
            let originalID = group.groupId
            if originalID > 0 {
                if let existing = groups.first(where: { $0.groupId > 0 && $0.groupName == group.groupName }) {
                    group.groupId = existing.groupId
                } else if used & originalID != 0 || originalID.nonzeroBitCount != 1 {
                    guard let free = (0..<63).map({ Int64(1) << $0 }).first(where: { used & $0 == 0 }) else {
                        throw BookshelfSyncError.tooManyGroups
                    }
                    group.groupId = free
                }
                used |= group.groupId
                groupMappings[originalID] = group.groupId
            }
            groups = merged(groups, [group], key: \.groupId)
        }
        for index in imported.books.indices {
            let mask = imported.books[index].group
            imported.books[index].group = groupMappings.reduce(Int64(0)) { value, mapping in
                mask & mapping.key != 0 ? value | mapping.value : value
            }
        }
        result.bookSources = merged(bookSources, incoming.bookSources, key: \.bookSourceUrl)
        result.books = merged(books, imported.books, key: \.bookUrl)
        result.bookGroups = groups
        result.bookmarks = merged(bookmarks, incoming.bookmarks, key: \.time)
        result.bookNotes = merged(bookNotes, incoming.bookNotes, key: \.id)
        result.txtTocRules = merged(txtTocRules, incoming.txtTocRules, key: \.id)
        result.httpTTS = merged(httpTTS, incoming.httpTTS, key: \.id)
        result.ruleSubs = merged(ruleSubs, incoming.ruleSubs, key: \.id)
        result.rssSources = merged(rssSources, incoming.rssSources, key: \.sourceUrl)
        result.replaceRules = ReplaceRuleImporter().merge(incoming.replaceRules, into: replaceRules)
        result.settings = incoming.settings ?? settings
        result.localBookFiles.merge(incoming.localBookFiles) { _, incoming in incoming }
        if let preferences = incoming.preferences {
            result.preferences = (self.preferences ?? [:]).merging(preferences) { _, incoming in incoming }
        }
        result.readRecords = merged(readRecords, incoming.readRecords.map { record in
            guard let old = readRecords.first(where: { $0.deviceId == record.deviceId && $0.bookName == record.bookName }) else { return record }
            return ReadRecord(deviceId: record.deviceId, bookName: record.bookName,
                              readTime: max(old.readTime, record.readTime), lastRead: max(old.lastRead, record.lastRead),
                              dailyReadTimes: old.dailyReadTimes.merging(record.dailyReadTimes) { max($0, $1) })
        }, key: { "\($0.deviceId)\u{0}\($0.bookName)" })
        return result
    }
}

/// 备份包的读写。只负责"打包 / 解包"，不负责写库；
/// 写库与合并策略由调用方决定，便于失败回滚。
public struct BackupService: Sendable {
    public struct FileNames {
        public static let manifest = "manifest.json"
        public static let bookSources = "bookSources.json"
        public static let books = "books.json"
        public static let bookGroups = "bookGroups.json"
        public static let bookmarks = "bookmarks.json"
        public static let readRecords = "readRecords.json"
        public static let bookNotes = "bookNotes.json"
        public static let replaceRules = "replaceRules.json"
        public static let txtTocRules = "txtTocRules.json"
        public static let httpTTS = "httpTTS.json"
        public static let ruleSubs = "ruleSubs.json"
        public static let settings = "settings.json"
        public static let rssSources = "rssSources.json"
        public static let localBookFiles = "localBookFiles.json"
        public static let preferences = "preferences.json"
    }

    public init() {}

    // MARK: - 导出

    public func export(_ payload: BackupPayload, to url: URL, appVersion: String = "") throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let archive = try? Archive(url: url, accessMode: .create, pathEncoding: nil) else {
            throw BackupError.cannotCreateArchive
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var manifest = BackupManifest()
        manifest.appVersion = appVersion
        manifest.counts = payload.summary
        try write(manifest, named: FileNames.manifest, to: archive, encoder: encoder)
        try write(payload.bookSources, named: FileNames.bookSources, to: archive, encoder: encoder)
        try write(payload.books, named: FileNames.books, to: archive, encoder: encoder)
        try write(payload.bookGroups, named: FileNames.bookGroups, to: archive, encoder: encoder)
        try write(payload.bookmarks, named: FileNames.bookmarks, to: archive, encoder: encoder)
        try write(payload.readRecords, named: FileNames.readRecords, to: archive, encoder: encoder)
        try write(payload.bookNotes, named: FileNames.bookNotes, to: archive, encoder: encoder)
        try write(payload.replaceRules, named: FileNames.replaceRules, to: archive, encoder: encoder)
        try write(payload.txtTocRules, named: FileNames.txtTocRules, to: archive, encoder: encoder)
        try write(payload.httpTTS, named: FileNames.httpTTS, to: archive, encoder: encoder)
        try write(payload.ruleSubs, named: FileNames.ruleSubs, to: archive, encoder: encoder)
        try write(payload.rssSources, named: FileNames.rssSources, to: archive, encoder: encoder)
        var localFiles: [String: String] = [:]
        for (bookURL, data) in payload.localBookFiles {
            guard let original = URL(string: bookURL), LocalBookService.supports(original),
                  data.count <= RemoteStorageClient.maximumFileSize else { throw BackupError.invalidArchive }
            let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "." + original.pathExtension.lowercased()
            if archive["files/" + name] == nil {
                try archive.addEntry(with: "files/" + name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                    data.subdata(in: Int(position)..<min(Int(position) + size, data.count))
                }
            }
            localFiles[bookURL] = name
        }
        try write(localFiles, named: FileNames.localBookFiles, to: archive, encoder: encoder)
        if let settings = payload.settings {
            try write(settings, named: FileNames.settings, to: archive, encoder: encoder)
        }
        if let preferences = payload.preferences {
            try write(preferences, named: FileNames.preferences, to: archive, encoder: encoder)
        }
        guard archive.reduce(UInt64(0), { $0 + $1.uncompressedSize }) <= 512 * 1_024 * 1_024 else {
            throw BackupError.invalidArchive
        }
    }

    private func write<T: Encodable>(
        _ value: T,
        named name: String,
        to archive: Archive,
        encoder: JSONEncoder
    ) throws {
        let data = try encoder.encode(value)
        try archive.addEntry(
            with: name,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            let end = min(start + size, data.count)
            return data.subdata(in: start..<end)
        }
    }

    // MARK: - 读取本应用备份

    public func read(from url: URL) throws -> BackupPayload {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else {
            throw BackupError.invalidArchive
        }
        var files: [String: Data] = [:]
        for entry in archive where entry.type == .file {
            guard entry.uncompressedSize <= RemoteStorageClient.maximumFileSize else { throw BackupError.invalidArchive }
            var data = Data()
            do {
                _ = try archive.extract(entry) { chunk in
                    guard data.count + chunk.count <= RemoteStorageClient.maximumFileSize else { throw BackupError.invalidArchive }
                    data.append(chunk)
                }
            } catch {
                throw BackupError.invalidArchive
            }
            let name = (entry.path as NSString).lastPathComponent
            guard files[name] == nil,
                  files.values.reduce(data.count, { $0 + $1.count }) <= 512 * 1_024 * 1_024 else {
                throw BackupError.invalidArchive
            }
            files[name] = data
        }
        guard !files.isEmpty else { throw BackupError.invalidArchive }

        if let manifestData = files[FileNames.manifest] {
            guard let manifest = try? JSONDecoder().decode(BackupManifest.self, from: manifestData),
                  manifest.format == "legado-ios-backup", manifest.version >= 1 else {
                throw BackupError.invalidArchive
            }
            if manifest.version > 1 {
                throw BackupError.unsupportedVersion(manifest.version)
            }
            let recognized = [FileNames.bookSources, FileNames.books, FileNames.bookGroups, FileNames.bookmarks,
                              FileNames.readRecords, FileNames.bookNotes, FileNames.replaceRules, FileNames.txtTocRules,
                              FileNames.httpTTS, FileNames.ruleSubs, FileNames.rssSources, FileNames.settings]
            for name in recognized {
                if let data = files[name] {
                    guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw BackupError.invalidArchive }
                }
            }
        } else {
            return try readLegadoBackup(from: url)
        }

        let decoder = JSONDecoder()
        func read<Value: Decodable>(_ type: Value.Type, _ name: String, fallback: Value) throws -> Value {
            guard let data = files[name] else { return fallback }
            do { return try decoder.decode(type, from: data) }
            catch { throw BackupError.invalidArchive }
        }
        var payload = BackupPayload()
        payload.bookSources = try read([BookSource].self, FileNames.bookSources, fallback: [])
        payload.books = try read([Book].self, FileNames.books, fallback: [])
        payload.bookGroups = try read([BookGroup].self, FileNames.bookGroups, fallback: [])
        payload.bookmarks = try read([Bookmark].self, FileNames.bookmarks, fallback: [])
        payload.readRecords = try read([ReadRecord].self, FileNames.readRecords, fallback: [])
        payload.bookNotes = try read([BookNote].self, FileNames.bookNotes, fallback: [])
        payload.replaceRules = try read([ReplaceRule].self, FileNames.replaceRules, fallback: [])
        payload.txtTocRules = try read([TxtTocRule].self, FileNames.txtTocRules, fallback: [])
        payload.httpTTS = try read([HttpTTS].self, FileNames.httpTTS, fallback: [])
        payload.ruleSubs = try read([RuleSub].self, FileNames.ruleSubs, fallback: [])
        payload.rssSources = try read([RssSource].self, FileNames.rssSources, fallback: [])
        payload.settings = decode(ApplicationSettings.self, from: files[FileNames.settings], decoder: decoder)
        if files[FileNames.preferences] != nil {
            payload.preferences = try read([String: JSONValue].self, FileNames.preferences, fallback: [:])
        }
        let localFiles = try read([String: String].self, FileNames.localBookFiles, fallback: [:])
        for (bookURL, name) in localFiles {
            guard name == (name as NSString).lastPathComponent, let data = files[name],
                  let original = URL(string: bookURL), LocalBookService.supports(original),
                  name == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() + "." + original.pathExtension.lowercased() else {
                throw BackupError.invalidArchive
            }
            payload.localBookFiles[bookURL] = data
        }
        let expectedCounts = try JSONDecoder().decode(BackupManifest.self, from: files[FileNames.manifest]!).counts
        guard expectedCounts.allSatisfy({ payload.summary[$0.key] == nil || payload.summary[$0.key] == $0.value }),
              files[FileNames.settings] == nil || payload.settings != nil else { throw BackupError.invalidArchive }
        return payload
    }

    public func includingLocalFiles(_ payload: BackupPayload) throws -> BackupPayload {
        var result = payload
        for book in payload.books where book.origin == "local" {
            guard let url = URL(string: book.bookUrl), url.isFileURL, LocalBookService.supports(url),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= RemoteStorageClient.maximumFileSize else { throw BackupError.missingLocalFile(book.name) }
            result.localBookFiles[book.bookUrl] = try Data(contentsOf: url, options: .mappedIfSafe)
        }
        return result
    }

    public static let preferenceKeys: Set<String> = [
        "themeMode", "bookshelfLayout", "textSize", "letterSpacing", "lineSpacingExtra", "paragraphSpacing",
        "paragraphIndent", "paddingLeft", "paddingRight", "paddingTop", "paddingBottom", "textBold", "textFont",
        "titleMode", "titleSize", "titleTopSpacing", "titleBottomSpacing", "underlineMode", "headerMode", "footerMode",
        "headerPaddingBottom", "headerPaddingLeft", "headerPaddingRight", "headerPaddingTop",
        "footerPaddingBottom", "footerPaddingLeft", "footerPaddingRight", "footerPaddingTop",
        "showHeaderLine", "showFooterLine", "tipHeaderLeft", "tipHeaderMiddle", "tipHeaderRight",
        "tipFooterLeft", "tipFooterMiddle", "tipFooterRight", "readerTheme", "readerPreviousDayTheme",
        "autoReadSpeed", "autoFlipSpeed", "ttsFollowSys", "ttsSpeechRate", "appTtsEngine", "systemTtsVoice",
        "readAloudByPage", "streamReadAloudAudio", "readAloudWakeLock", "ignoreAudioFocus", "pauseReadAloudWhilePhoneCalls",
        "mediaButtonPerNext", "ttsTimer", "readerFullJustify", "readerKeepScreenOn", "readerHideHomeIndicator",
        "readerHideStatusBar", "readerShowBrightness", "readerBrightness", "enableReadRecord", "screenOrientation",
        "clickActionTopLeft", "clickActionTopCenter", "clickActionTopRight", "clickActionMiddleLeft", "clickActionMiddleRight",
        "clickActionBottomLeft", "clickActionBottomCenter", "clickActionBottomRight",
        "epubFontScale", "epubScroll", "epubPublisherStyles", "epubTheme", "auto_refresh", "onlyUpdateRead", "defaultHomePage"
    ]

    public func capturePreferences(from defaults: UserDefaults) throws -> [String: JSONValue] {
        let values = defaults.dictionaryRepresentation().filter { Self.preferenceKeys.contains($0.key) }
        let data = try JSONSerialization.data(withJSONObject: values)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    public func restorePreferences(_ preferences: [String: JSONValue], to defaults: UserDefaults) throws {
        let data = try JSONEncoder().encode(preferences.filter { Self.preferenceKeys.contains($0.key) })
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BackupError.invalidArchive }
        for key in Self.preferenceKeys {
            if let value = values[key], !(value is NSNull) { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }

    public func materializeLocalFiles(_ payload: BackupPayload, in directory: URL) throws -> (payload: BackupPayload, created: [URL]) {
        var result = payload
        var created: [URL] = []
        var mappings: [String: String] = [:]
        do {
            for (original, data) in payload.localBookFiles {
                guard let source = URL(string: original), LocalBookService.supports(source) else { throw BackupError.invalidArchive }
                let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "." + source.pathExtension.lowercased()
                let destination = directory.appendingPathComponent("backup-" + name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    guard try Data(contentsOf: destination) == data else { throw BackupError.invalidArchive }
                } else {
                    try data.write(to: destination, options: .atomic)
                    created.append(destination)
                }
                mappings[original] = destination.absoluteString
            }
            for index in result.books.indices {
                guard let url = mappings[result.books[index].bookUrl] else { continue }
                result.books[index].bookUrl = url
                result.books[index].tocUrl = url
                result.books[index].coverUrl = nil
                result.books[index].customCoverUrl = nil
            }
            for index in result.bookNotes.indices {
                if let url = mappings[result.bookNotes[index].bookUrl] { result.bookNotes[index].bookUrl = url }
            }
            return (result, created)
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    // MARK: - 读取安卓版 Legado 备份（尽力而为）

    /// 安卓版备份的文件名与结构随版本变化，这里按文件名关键字做宽松匹配，
    /// 解不出来的类别直接跳过，不影响其余数据的导入。
    public func readLegadoBackup(from url: URL) throws -> BackupPayload {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else {
            throw BackupError.invalidArchive
        }
        var files: [(name: String, data: Data)] = []
        for entry in archive where entry.type == .file {
            guard entry.uncompressedSize <= 64 * 1_024 * 1_024 else { throw BackupError.invalidArchive }
            var data = Data()
            do {
                _ = try archive.extract(entry) { chunk in
                    guard data.count + chunk.count <= 64 * 1_024 * 1_024 else { throw BackupError.invalidArchive }
                    data.append(chunk)
                }
            } catch { throw BackupError.invalidArchive }
            guard files.reduce(data.count, { $0 + $1.data.count }) <= 256 * 1_024 * 1_024 else { throw BackupError.invalidArchive }
            files.append(((entry.path as NSString).lastPathComponent, data))
        }
        guard !files.isEmpty else { throw BackupError.invalidArchive }

        let decoder = JSONDecoder()
        var payload = BackupPayload()
        for file in files {
            let name = file.name.lowercased()
            if name.contains("booksource") || name.contains("book_source") {
                if let values = decode([BookSource].self, from: file.data, decoder: decoder) {
                    payload.bookSources.append(contentsOf: values)
                }
            } else if name.contains("bookshelf") {
                if let values = decode([Book].self, from: file.data, decoder: decoder) {
                    payload.books.append(contentsOf: values)
                }
            } else if name.contains("bookgroup") {
                if let values = decode([BookGroup].self, from: file.data, decoder: decoder) {
                    payload.bookGroups.append(contentsOf: values)
                }
            } else if name.contains("bookmark") {
                if let values = decode([Bookmark].self, from: file.data, decoder: decoder) {
                    payload.bookmarks.append(contentsOf: values)
                }
            } else if name.contains("readrecord") {
                if let values = decode([ReadRecord].self, from: file.data, decoder: decoder) {
                    payload.readRecords.append(contentsOf: values)
                }
            } else if name.contains("booknote") || name.contains("note") {
                if let values = decode([BookNote].self, from: file.data, decoder: decoder) {
                    payload.bookNotes.append(contentsOf: values)
                }
            } else if name.contains("replacerule") {
                if let values = decode([ReplaceRule].self, from: file.data, decoder: decoder) {
                    payload.replaceRules.append(contentsOf: values)
                }
            } else if name.contains("txttocrule") {
                if let values = decode([TxtTocRule].self, from: file.data, decoder: decoder) {
                    payload.txtTocRules.append(contentsOf: values)
                }
            } else if name.contains("httptts") || name.contains("tts") {
                if let values = decode([HttpTTS].self, from: file.data, decoder: decoder) {
                    payload.httpTTS.append(contentsOf: values)
                }
            } else if name.contains("rsssource") {
                payload.rssSources += decode([RssSource].self, from: file.data, decoder: decoder) ?? []
            } else if name.contains("rulesub") {
                payload.ruleSubs += decode([RuleSub].self, from: file.data, decoder: decoder) ?? []
            }
        }
        guard !payload.isEmpty else { throw BackupError.emptyBackup }
        return payload
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data?, decoder: JSONDecoder) -> T? {
        guard let data, !data.isEmpty else { return nil }
        let bom = Data([0xEF, 0xBB, 0xBF])
        let cleaned = data.starts(with: bom) ? Data(data.dropFirst(3)) : data
        return try? decoder.decode(type, from: cleaned)
    }

    // MARK: - 笔记导出

    public func markdownNotes(_ notes: [BookNote]) -> String {
        let grouped = Dictionary(grouping: notes) { "\($0.bookName.isEmpty ? $0.bookUrl : $0.bookName)" }
        var lines: [String] = ["# 读书笔记", ""]
        for bookName in grouped.keys.sorted() {
            guard let items = grouped[bookName] else { continue }
            lines.append("## \(bookName)")
            lines.append("")
            for note in items.sorted(by: { ($0.chapterIndex, $0.createdAt) < ($1.chapterIndex, $1.createdAt) }) {
                if !note.chapterName.isEmpty {
                    lines.append("### \(note.chapterName)")
                    lines.append("")
                }
                lines.append(note.markdown())
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}
