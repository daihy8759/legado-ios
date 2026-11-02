import Foundation
import CryptoKit

public protocol BookshelfSyncStorage: Sendable {
    func list(_ path: String) async throws -> [RemoteFile]
    func download(_ path: String) async throws -> Data
    func upload(_ data: Data, to path: String) async throws
    func createDirectory(_ path: String) async throws
}

extension RemoteStorageClient: BookshelfSyncStorage {}

public enum BookshelfSyncError: Error, LocalizedError {
    case invalidSnapshot, missingLocalBook(String), tooManyGroups, busy
    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "书架同步数据无效或版本不受支持，本机书架未被替换。"
        case .missingLocalBook(let name): "本地书「\(name)」的原文件缺失或超出 150 MB，无法同步。请重新导入或将它移出书架。"
        case .tooManyGroups: "合并后的自定义分组超过 63 个，请先整理分组。"
        case .busy: "书架同步正在进行。"
        }
    }
}

public struct BookshelfSyncInput: Sendable {
    public var books: [Book]
    public var groups: [BookGroup]
    public var localDirectory: URL
    public init(books: [Book], groups: [BookGroup], localDirectory: URL) {
        self.books = books; self.groups = groups; self.localDirectory = localDirectory
    }
}

public struct BookshelfSyncResult: Sendable {
    public let books: [Book]
    public let groups: [BookGroup]
    public let uploaded: Bool
    fileprivate let checkpoint: ShelfSyncState
}

public enum BookshelfSyncReconciler {
    // Rebase a downloaded shelf onto changes made while network I/O suspended.
    public static func reconcile(base: BookshelfSyncInput, current: BookshelfSyncInput,
                                 incoming: BookshelfSyncResult) throws -> BookshelfSyncInput {
        var groups = current.groups.filter { group in
            group.groupId < 0 || !base.groups.contains(group) || incoming.groups.contains { $0.groupName == group.groupName }
        }
        for remote in incoming.groups where remote.groupId > 0 {
            if let index = groups.firstIndex(where: { $0.groupName == remote.groupName }) {
                if base.groups.contains(groups[index]) {
                    let id = groups[index].groupId
                    groups[index] = remote; groups[index].groupId = id
                }
            } else {
                // A group removed or renamed during the transfer stays removed.
                if let old = base.groups.first(where: { $0.groupName == remote.groupName }),
                   !current.groups.contains(where: { $0.groupId == old.groupId && $0.groupName == old.groupName }) { continue }
                let used = groups.filter { $0.groupId > 0 }.reduce(Int64(0)) { $0 | $1.groupId }
                guard let id = (0..<63).map({ Int64(1) << $0 }).first(where: { used & $0 == 0 }) else { throw BookshelfSyncError.tooManyGroups }
                var group = remote; group.groupId = id; groups.append(group)
            }
        }
        let baseBooks = Dictionary(base.books.map { ($0.bookUrl, $0) }, uniquingKeysWith: { first, _ in first })
        let currentBooks = Dictionary(current.books.map { ($0.bookUrl, $0) }, uniquingKeysWith: { first, _ in first })
        var books: [Book] = []
        for var remote in incoming.books {
            let old = baseBooks[remote.bookUrl]
            let local = currentBooks[remote.bookUrl]
            if old != nil && local == nil { continue }
            let names = incoming.groups.filter { $0.groupId > 0 && remote.group & $0.groupId != 0 }.map(\.groupName)
            remote.group = groups.filter { $0.groupId > 0 && names.contains($0.groupName) }.reduce(0) { $0 | $1.groupId }
            if let local {
                let localProgress = ShelfSyncProgress(local)
                let remoteProgress = ShelfSyncProgress(remote)
                if old == nil || metadata(local) != metadata(old!) { remote = local }
                if let old {
                    let before = Set(base.groups.filter { $0.groupId > 0 && old.group & $0.groupId != 0 }.map(\.groupName))
                    let after = Set(current.groups.filter { $0.groupId > 0 && local.group & $0.groupId != 0 }.map(\.groupName))
                    if before != after { remote.group = local.group }
                }
                let progressedDuringTransfer = old.map { ShelfSyncProgress($0) != localProgress } ?? true
                if progressedDuringTransfer && localProgress.time >= remoteProgress.time { localProgress.apply(to: &remote) }
                else { remoteProgress.apply(to: &remote) }
            }
            books.append(remote)
        }
        let incomingURLs = Set(incoming.books.map(\.bookUrl))
        books += current.books.filter { baseBooks[$0.bookUrl] == nil && !incomingURLs.contains($0.bookUrl) }
        return .init(books: books, groups: groups, localDirectory: current.localDirectory)
    }
    private static func metadata(_ book: Book) -> Book {
        var book = book
        ShelfSyncProgress(Book(bookUrl: "", name: "")).apply(to: &book)
        if book.readConfig == BookReadConfig() { book.readConfig = nil }
        return book
    }
}

struct ShelfSyncStamp: Codable, Equatable, Comparable, Sendable {
    var time: Int64
    var device: String
    var sequence: Int64 = 0
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.device < rhs.device
    }
}

struct ShelfSyncProgress: Codable, Equatable, Sendable {
    var chapter: Int
    var title: String?
    var position: Int
    var time: Int64
    var volume: Int
    var chapterInVolume: Int
    var epubLocation: String?
    init(_ book: Book) {
        chapter = book.durChapterIndex; title = book.durChapterTitle
        position = book.durChapterPos; time = book.durChapterTime
        volume = book.durVolumeIndex; chapterInVolume = book.chapterInVolumeIndex
        epubLocation = book.readConfig?.epubLocation
    }
    func apply(to book: inout Book) {
        book.durChapterIndex = chapter; book.durChapterTitle = title
        book.durChapterPos = position; book.durChapterTime = time
        book.durVolumeIndex = volume; book.chapterInVolumeIndex = chapterInVolume
        if book.readConfig == nil, epubLocation != nil { book.readConfig = .init() }
        book.readConfig?.epubLocation = epubLocation
    }
}

struct ShelfSyncBook: Codable, Equatable, Sendable {
    var metadata: Book
    var groupNames: [String]
    var asset: String?
    var metadataStamp: ShelfSyncStamp
    var progress: ShelfSyncProgress
    var progressStamp: ShelfSyncStamp
    var deleted: Bool
    var presenceStamp: ShelfSyncStamp

    func merging(_ other: Self) -> Self {
        var result = self
        if metadataStamp < other.metadataStamp {
            result.metadata = other.metadata; result.groupNames = other.groupNames
            result.asset = other.asset; result.metadataStamp = other.metadataStamp
        }
        if progressStamp < other.progressStamp { result.progress = other.progress; result.progressStamp = other.progressStamp }
        if presenceStamp < other.presenceStamp { result.deleted = other.deleted; result.presenceStamp = other.presenceStamp }
        return result
    }
    func sameMetadata(as other: Self) -> Bool {
        metadata == other.metadata && groupNames == other.groupNames && asset == other.asset
    }
}

struct ShelfSyncGroup: Codable, Equatable, Sendable {
    var group: BookGroup
    var deleted: Bool
    var stamp: ShelfSyncStamp
}

struct ShelfSyncSnapshot: Codable, Sendable {
    var version = 1
    var device: String
    var revision: Int64
    var books: [String: ShelfSyncBook]
    var groups: [String: ShelfSyncGroup]
}

struct ShelfSyncState: Codable, Sendable {
    var device = UUID().uuidString.lowercased()
    var clock: Int64 = 0
    var books: [String: ShelfSyncBook] = [:]
    var groups: [String: ShelfSyncGroup] = [:]
    var baselineBooks: [String: ShelfSyncBook] = [:]
    var baselineGroups: [String: BookGroup] = [:]
}

public actor BookshelfSyncEngine {
    public static let directory = "LegadoSync/v1"
    private let storage: any BookshelfSyncStorage
    private let stateURL: URL
    private let now: @Sendable () -> Date
    private var running = false

    public init(storage: any BookshelfSyncStorage, stateURL: URL,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.storage = storage; self.stateURL = stateURL; self.now = now
    }

    public func synchronize(_ input: BookshelfSyncInput) async throws -> BookshelfSyncResult {
        guard !running else { throw BookshelfSyncError.busy }
        running = true
        defer { running = false }
        let manager = FileManager.default
        var state = manager.fileExists(atPath: stateURL.path)
            ? try JSONDecoder().decode(ShelfSyncState.self, from: Data(contentsOf: stateURL)) : ShelfSyncState()
        guard state.clock >= 0, state.clock < Int64.max - 2 else { throw BookshelfSyncError.invalidSnapshot }
        let captured = try capture(input, device: state.device)
        let time = max(Int64(now().timeIntervalSince1970 * 1_000), state.clock + 1)
        state.clock = time
        // Reserve identity and a monotonic clock before publishing, including
        // retries after a failed local save or a device clock moving backwards.
        var reserved = state
        try save(reserved)
        let stamp = ShelfSyncStamp(time: time, device: state.device)
        var localChanges = false
        for (id, var record) in captured.books {
            let baseline = state.baselineBooks[id]
            let existing = state.books[id]
            record.metadataStamp = existing?.metadataStamp ?? stamp
            record.progressStamp = existing?.progressStamp ?? .init(time: record.progress.time, device: state.device)
            record.presenceStamp = existing?.presenceStamp ?? stamp
            if baseline == nil || !record.sameMetadata(as: baseline!) { record.metadataStamp = stamp; localChanges = true }
            if baseline == nil || baseline?.progress != record.progress {
                // A deliberate move backwards is still the newest read.
                record.progressStamp = .init(time: record.progress.time, device: state.device)
                if let existing, existing.progress.time == record.progress.time {
                    record.progressStamp.sequence = existing.progressStamp.sequence + 1
                }
                localChanges = true
            }
            if baseline == nil { record.presenceStamp = stamp; localChanges = true }
            state.books[id] = existing.map { $0.merging(record) } ?? record
        }
        for id in state.baselineBooks.keys where captured.books[id] == nil {
            if var record = state.books[id], !record.deleted {
                record.deleted = true; record.presenceStamp = stamp
                state.books[id] = record; localChanges = true
            }
        }
        for (name, group) in captured.groups where state.baselineGroups[name] != group {
            state.groups[name] = .init(group: group, deleted: false, stamp: stamp)
            localChanges = true
        }
        for name in state.baselineGroups.keys where captured.groups[name] == nil {
            if var record = state.groups[name], !record.deleted {
                record.deleted = true; record.stamp = stamp
                state.groups[name] = record; localChanges = true
            }
        }
        for folder in ["LegadoSync", Self.directory, Self.directory + "/files", Self.directory + "/snapshots"] {
            try await ensureDirectory(folder)
        }
        let listing = try await storage.list(Self.directory + "/snapshots")
        var latest: [String: (RemoteFile, Int64)] = [:]
        for file in listing where !file.isDirectory {
            let parts = file.name.split(separator: "_")
            guard parts.count == 3, UUID(uuidString: String(parts[0])) != nil,
                  let revision = Int64(parts[1]), revision >= 0, file.name.hasSuffix(".json") else { continue }
            let device = String(parts[0])
            if latest[device] == nil || latest[device]!.0.name < file.name { latest[device] = (file, revision) }
        }
        for (device, (file, revision)) in latest.sorted(by: { $0.key < $1.key }) {
            let data = try await storage.download(file.path)
            guard data.count <= 10_000_000 else { throw BookshelfSyncError.invalidSnapshot }
            let snapshot: ShelfSyncSnapshot
            do { snapshot = try JSONDecoder().decode(ShelfSyncSnapshot.self, from: data) }
            catch { throw BookshelfSyncError.invalidSnapshot }
            try validate(snapshot)
            guard snapshot.device == device, snapshot.revision == revision else { throw BookshelfSyncError.invalidSnapshot }
            for (id, record) in snapshot.books { state.books[id] = state.books[id].map { $0.merging(record) } ?? record }
            for (name, record) in snapshot.groups {
                if state.groups[name] == nil || state.groups[name]!.stamp < record.stamp { state.groups[name] = record }
            }
            state.clock = max(state.clock, snapshot.revision)
        }
        state.clock = max(state.clock, time)
        let assets = Set(try await storage.list(Self.directory + "/files").filter { !$0.isDirectory }.map(\.name))
        for (id, url) in captured.localURLs {
            guard let record = state.books[id], !record.deleted, let asset = record.asset, !assets.contains(asset) else { continue }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= RemoteStorageClient.maximumFileSize, Self.digest(data) + "." + url.pathExtension.lowercased() == asset else {
                throw BookshelfSyncError.missingLocalBook(record.metadata.name)
            }
            do { try await storage.upload(data, to: Self.directory + "/files/" + asset) }
            catch RemoteStorageError.http(let code) where code == 409 || code == 412 {
                let existing = try await storage.download(Self.directory + "/files/" + asset)
                guard Self.digest(existing) == Self.digest(data) else { throw BookshelfSyncError.invalidSnapshot }
            }
        }
        let materialized = try await materialize(state, input: input, localURLs: captured.localURLs)
        if localChanges {
            state.clock += 1
            reserved.clock = state.clock
            try save(reserved)
            let snapshot = ShelfSyncSnapshot(device: state.device, revision: state.clock, books: state.books, groups: state.groups)
            let data = try encode(snapshot)
            guard data.count <= 10_000_000 else { throw BookshelfSyncError.invalidSnapshot }
            let filename = state.device + "_" + String(format: "%020lld", state.clock) + "_" + UUID().uuidString.lowercased() + ".json"
            // Immutable per-device snapshots avoid cross-device overwrite races
            // on all three storage providers, without a server-side lock.
            try await storage.upload(data, to: Self.directory + "/snapshots/" + filename)
        }
        state.baselineBooks = state.books.filter { !$0.value.deleted }
        state.baselineGroups = state.groups.filter { !$0.value.deleted }.mapValues(\.group)
        return .init(books: materialized.books, groups: materialized.groups, uploaded: localChanges, checkpoint: state)
    }

    public func acknowledge(_ result: BookshelfSyncResult) throws { try save(result.checkpoint) }

    private func save(_ state: ShelfSyncState) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(state).write(to: stateURL, options: .atomic)
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func ensureDirectory(_ path: String) async throws {
        do { try await storage.createDirectory(path) }
        catch RemoteStorageError.http(let code) where [405, 409, 412].contains(code) {
            _ = try await storage.list(path)
        }
    }
    private struct Captured {
        var books: [String: ShelfSyncBook] = [:]
        var groups: [String: BookGroup] = [:]
        var localURLs: [String: URL] = [:]
    }
    private func capture(_ input: BookshelfSyncInput, device: String) throws -> Captured {
        var captured = Captured()
        for var group in input.groups where group.groupId > 0 {
            group.groupId = 0
            if group.cover?.hasPrefix("file:") == true { group.cover = nil }
            captured.groups[group.groupName] = group
        }
        for book in input.books {
            var asset: String?
            let id: String
            if book.origin == "local" {
                guard let url = URL(string: book.bookUrl), url.isFileURL, LocalBookService.supports(url),
                      url.standardizedFileURL.deletingLastPathComponent() == input.localDirectory.standardizedFileURL,
                      url.resolvingSymlinksInPath().deletingLastPathComponent() == input.localDirectory.resolvingSymlinksInPath(),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, (values.fileSize ?? .max) <= RemoteStorageClient.maximumFileSize else {
                    throw BookshelfSyncError.missingLocalBook(book.name)
                }
                asset = try Self.fileDigest(url) + "." + url.pathExtension.lowercased()
                id = "local:" + asset!
                captured.localURLs[id] = url
            } else {
                guard !book.bookUrl.isEmpty, !book.bookUrl.hasPrefix("file:") else { throw BookshelfSyncError.invalidSnapshot }
                id = "web:" + Self.digest(Data(book.bookUrl.utf8))
            }
            var metadata = book
            metadata.group = 0; metadata.variable = nil; metadata.readConfig = nil; metadata.syncTime = 0
            if book.origin == "local" {
                metadata.bookUrl = id; metadata.coverUrl = nil; metadata.customCoverUrl = nil
            }
            if metadata.tocUrl.hasPrefix("file:") { metadata.tocUrl = "" }
            if metadata.coverUrl?.hasPrefix("file:") == true { metadata.coverUrl = nil }
            if metadata.customCoverUrl?.hasPrefix("file:") == true { metadata.customCoverUrl = nil }
            ShelfSyncProgress(Book(bookUrl: "", name: "")).apply(to: &metadata)
            let names = input.groups.filter { $0.groupId > 0 && book.group & $0.groupId != 0 }.map(\.groupName).sorted()
            let stamp = ShelfSyncStamp(time: 0, device: device)
            let record = ShelfSyncBook(metadata: metadata, groupNames: names, asset: asset, metadataStamp: stamp,
                                       progress: .init(book), progressStamp: stamp, deleted: false, presenceStamp: stamp)
            if let old = captured.books[id] {
                captured.books[id] = old.progress.time > record.progress.time ? old : record
            } else { captured.books[id] = record }
        }
        return captured
    }
    private func materialize(_ state: ShelfSyncState, input: BookshelfSyncInput,
                             localURLs: [String: URL]) async throws -> (books: [Book], groups: [BookGroup]) {
        var groups = input.groups.filter { $0.groupId < 0 }
        var used: Int64 = 0
        var activeGroups: [BookGroup] = state.groups.values.filter { !$0.deleted }.map(\.group)
        activeGroups.sort { (left: BookGroup, right: BookGroup) -> Bool in
            if left.order == right.order { return left.groupName < right.groupName }
            return left.order < right.order
        }
        guard activeGroups.count <= 63 else { throw BookshelfSyncError.tooManyGroups }
        for var group in activeGroups {
            let existing = input.groups.first { $0.groupName == group.groupName && $0.groupId > 0 }?.groupId
            if let existing, used & existing == 0 { group.groupId = existing }
            else { group.groupId = (0..<63).map { Int64(1) << $0 }.first { used & $0 == 0 }! }
            used |= group.groupId; groups.append(group)
        }
        let masks = Dictionary(groups.filter { $0.groupId > 0 }.map { ($0.groupName, $0.groupId) }, uniquingKeysWith: { first, _ in first })
        var books: [Book] = []
        for (id, record) in state.books.sorted(by: { $0.key < $1.key }) where !record.deleted {
            var book = record.metadata
            var local: Book?
            if let asset = record.asset {
                let url: URL
                if let existing = localURLs[id] { url = existing }
                else {
                    let target = input.localDirectory.appendingPathComponent("sync-" + asset)
                    let manager = FileManager.default
                    try manager.createDirectory(at: input.localDirectory, withIntermediateDirectories: true)
                    guard target.resolvingSymlinksInPath().deletingLastPathComponent().path == input.localDirectory.resolvingSymlinksInPath().path else {
                        throw BookshelfSyncError.invalidSnapshot
                    }
                    if manager.fileExists(atPath: target.path) {
                        guard try Self.fileDigest(target) + "." + target.pathExtension.lowercased() == asset else { throw BookshelfSyncError.invalidSnapshot }
                    } else {
                        let data = try await storage.download(Self.directory + "/files/" + asset)
                        guard Self.digest(data) + "." + target.pathExtension.lowercased() == asset else { throw BookshelfSyncError.invalidSnapshot }
                        try manager.createDirectory(at: input.localDirectory, withIntermediateDirectories: true)
                        try data.write(to: target, options: .atomic)
                    }
                    url = target
                }
                local = input.books.first { $0.bookUrl == url.absoluteString }
                if local == nil { local = try LocalBookService.live().openFile(at: url).book }
                book.bookUrl = url.absoluteString
                if book.tocUrl.isEmpty { book.tocUrl = local!.tocUrl }
                book.coverUrl = local?.coverUrl; book.customCoverUrl = local?.customCoverUrl
            } else { local = input.books.first { $0.bookUrl == book.bookUrl } }
            book.variable = local?.variable
            book.readConfig = local?.readConfig
            record.progress.apply(to: &book)
            book.group = record.groupNames.reduce(Int64(0)) { $0 | (masks[$1] ?? 0) }
            books.append(book)
        }
        return (books.sorted { $0.order == $1.order ? $0.bookUrl < $1.bookUrl : $0.order < $1.order }, groups)
    }
    private func validate(_ snapshot: ShelfSyncSnapshot) throws {
        func valid(_ stamp: ShelfSyncStamp) -> Bool {
            stamp.time >= 0 && stamp.time < Int64.max - 2 && stamp.sequence >= 0
                && stamp.sequence < Int64.max - 2 && UUID(uuidString: stamp.device) != nil
        }
        guard snapshot.version == 1, snapshot.revision >= 0, snapshot.revision < Int64.max - 2,
              snapshot.books.count <= 20_000, snapshot.groups.count <= 10_000 else { throw BookshelfSyncError.invalidSnapshot }
        for (id, record) in snapshot.books {
            guard valid(record.metadataStamp), valid(record.progressStamp), valid(record.presenceStamp),
                  record.progress.chapter >= 0, record.progress.position >= 0, record.progress.time >= 0 else {
                throw BookshelfSyncError.invalidSnapshot
            }
            if let asset = record.asset {
                let parts = asset.split(separator: ".")
                guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy({ $0.isHexDigit }),
                      ["txt", "epub"].contains(String(parts[1])), id == "local:" + asset,
                      record.metadata.origin == "local", record.metadata.bookUrl == id else { throw BookshelfSyncError.invalidSnapshot }
            } else {
                guard record.metadata.origin != "local", !record.metadata.bookUrl.isEmpty, !record.metadata.bookUrl.hasPrefix("file:"),
                      id == "web:" + Self.digest(Data(record.metadata.bookUrl.utf8)) else { throw BookshelfSyncError.invalidSnapshot }
            }
        }
        for (name, record) in snapshot.groups {
            guard !name.isEmpty, record.group.groupName == name, valid(record.stamp) else { throw BookshelfSyncError.invalidSnapshot }
        }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
