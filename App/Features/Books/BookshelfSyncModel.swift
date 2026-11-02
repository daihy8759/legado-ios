import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class BookshelfSyncModel: ObservableObject {
    static let serverKey = "bookshelfSyncServerID"
    static let automaticKey = "bookshelfSyncAutomatic"
    @Published private(set) var isSynchronizing = false
    @Published private(set) var status: String?
    @Published private(set) var lastSync: Date?
    @Published var selectedServerID: String {
        didSet {
            defaults.set(selectedServerID, forKey: Self.serverKey)
            status = nil; lastSync = defaults.object(forKey: lastSyncKey) as? Date
        }
    }
    @Published var automatic: Bool {
        didSet { defaults.set(automatic, forKey: Self.automaticKey) }
    }
    private let defaults: UserDefaults
    private var ready = false
    private let allowsAutomatic: Bool
    private var scheduled: Task<Void, Never>?
    private var applying = false
    private var changesDuringSync = false
#if canImport(UIKit)
    private var backgroundTime: UIBackgroundTaskIdentifier = .invalid
#endif
    private var lastSyncKey: String { "bookshelfSyncLastSuccess." + selectedServerID }

    init(defaults: UserDefaults = .standard, allowsAutomatic: Bool = true) {
        self.defaults = defaults
        self.allowsAutomatic = allowsAutomatic
        selectedServerID = defaults.string(forKey: Self.serverKey) ?? ""
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        lastSync = defaults.object(forKey: "bookshelfSyncLastSuccess." + selectedServerID) as? Date
    }

    func start(_ library: BookLibraryModel) async {
        ready = true
        await synchronizeIfAutomatic(library)
    }

    func schedule(_ library: BookLibraryModel) {
        guard ready, allowsAutomatic, automatic, !selectedServerID.isEmpty, !applying else { return }
        if isSynchronizing { changesDuringSync = true; return }
        guard scheduled == nil else { return }
        scheduled = Task { [weak self, weak library] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            self?.scheduled = nil
            guard let self, let library, self.automatic else { return }
            await self.synchronize(library)
        }
    }

    func synchronizeIfAutomatic(_ library: BookLibraryModel) async {
        guard ready, allowsAutomatic, automatic, !selectedServerID.isEmpty else { return }
        await synchronize(library)
    }

    func enteringBackground(_ library: BookLibraryModel) async {
        guard ready, allowsAutomatic, automatic, Int64(selectedServerID) != nil else { return }
#if canImport(UIKit)
        if backgroundTime == .invalid {
            backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "BookshelfSync") { [weak self] in
                Task { @MainActor in self?.endBackgroundTime() }
            }
        }
#endif
        await synchronize(library)
    }

    private func endBackgroundTime() {
#if canImport(UIKit)
        if backgroundTime != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTime)
            backgroundTime = .invalid
        }
#endif
    }

    func synchronize(_ library: BookLibraryModel) async {
        guard !isSynchronizing, let id = Int64(selectedServerID) else { return }
        scheduled?.cancel(); scheduled = nil
        isSynchronizing = true; status = nil; changesDuringSync = false
        defer {
            isSynchronizing = false
            endBackgroundTime()
            if changesDuringSync { schedule(library) }
        }
        do {
            let store = RemoteServerStore(database: try LegadoDatabase(url: LegadoDatabase.defaultURL()))
            guard let server = try await store.load().first(where: { $0.id == id }) else {
                throw RemoteStorageError.invalidConfiguration("同步存储已被移除，请重新选择。")
            }
            // Each endpoint has its own baseline, even when editing a server
            // redirects an existing configuration to another bucket or folder.
            let identity = try server.synchronizationIdentity()
            let baseDirectory = LegadoDatabase.defaultURL().deletingLastPathComponent()
                .appendingPathComponent("ShelfSync", isDirectory: true)
            let engine = BookshelfSyncEngine(storage: try RemoteStorageClient(server: server),
                                             stateURL: baseDirectory.appendingPathComponent(identity + ".json"))
            let input = try await library.synchronizationSnapshot()
            let result = try await engine.synchronize(input)
            applying = true
            defer { applying = false }
            try await library.applySynchronizedShelf(result, startedWith: input)
            let applied = try await library.synchronizationSnapshot()
            if Set(applied.books) != Set(result.books) || Set(applied.groups) != Set(result.groups) {
                changesDuringSync = true
            }
            try await engine.acknowledge(result)
            lastSync = Date()
            defaults.set(lastSync, forKey: lastSyncKey)
            status = "同步完成，书架共 \(library.books.count) 本。"
        } catch {
            // Leave the baseline untouched so the next attempt retries local
            // changes and remote imports after a failed transfer or disk save.
            status = "同步失败：\(error.localizedDescription)"
            changesDuringSync = false
        }
    }
}
