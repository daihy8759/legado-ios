import SwiftUI
import UIKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class BackupRestoreModel: ObservableObject {
    @Published var isWorking = false
    @Published var message: String?
    @Published var pendingImport: BackupPayload?
    @Published var pendingImportURL: URL?
    @Published var summary: [String: Int] = [:]
    @Published var exportURL: URL?
    @Published var isImporterPresented = false
    @Published var errorMessage: String?
    @Published var servers: [Server] = []
    @Published var selectedServerID: Int64 = 0
    @Published var remoteBackups: [RemoteFile] = []

    private let database: LegadoDatabase?

    init() { database = try? LegadoDatabase(url: LegadoDatabase.defaultURL()) }

    private var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
    }

    // MARK: - 读取当前数据

    private func currentPayload() async throws -> BackupPayload {
        guard let database else { throw BackupError.invalidArchive }
        var payload = try await database.backupPayload()
        payload.replaceRules = try await FileReplaceRuleRepository(
            fileURL: baseDirectory.appendingPathComponent("replace-rules.json")
        ).load()
        payload.settings = ApplicationSettingsStore.shared.settings
        payload.preferences = try BackupService().capturePreferences(from: .standard)
        return payload
    }

    func refreshSummary() async {
        do { summary = try await currentPayload().summary }
        catch { errorMessage = error.localizedDescription }
        if let database {
            servers = (try? await RemoteServerStore(database: database).load()) ?? []
            if selectedServerID == 0 { selectedServerID = servers.first?.id ?? 0 }
        }
    }

    func uploadBackup() async {
        guard let server = servers.first(where: { $0.id == selectedServerID }) else { return }
        await export(appVersion: BackupRestoreView.appVersion)
        guard let exportURL else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let client = try RemoteStorageClient(server: server)
            do { try await client.createDirectory("LegadoBackups") }
            catch RemoteStorageError.http(let code) where [405, 409, 412].contains(code) {
                _ = try await client.list("LegadoBackups")
            }
            try await client.upload(Data(contentsOf: exportURL), to: "LegadoBackups/" + exportURL.lastPathComponent)
            message = "备份已上传到 \(server.name)。"
            remoteBackups = try await client.list("LegadoBackups").filter { !$0.isDirectory && $0.name.hasSuffix(".zip") }
        } catch { errorMessage = error.localizedDescription }
    }

    func listRemoteBackups() async {
        guard let server = servers.first(where: { $0.id == selectedServerID }) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            remoteBackups = try await RemoteStorageClient(server: server).list("LegadoBackups")
                .filter { !$0.isDirectory && $0.name.hasSuffix(".zip") }.sorted { $0.name > $1.name }
        } catch { errorMessage = error.localizedDescription }
    }

    func downloadBackup(_ file: RemoteFile) async {
        guard let server = servers.first(where: { $0.id == selectedServerID }) else { return }
        isWorking = true
        do {
            let data = try await RemoteStorageClient(server: server).download(file.path)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            try data.write(to: url, options: .atomic)
            await prepareImport(url)
            try? FileManager.default.removeItem(at: url)
        } catch { errorMessage = error.localizedDescription }
        isWorking = false
    }

    // MARK: - 导出

    func export(appVersion: String) async {
        exportURL = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let current = try await currentPayload()
            let payload = try await Task.detached { try BackupService().includingLocalFiles(current) }.value
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("小浣熊阅读备份-\(Self.stamp())-\(UUID().uuidString.prefix(8)).zip")
            try BackupService().export(payload, to: url, appVersion: appVersion)
            exportURL = url
            message = "备份已生成，包含 \(payload.summary.values.reduce(0, +)) 条记录。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 读取备份文件

    func prepareImport(_ url: URL) async {
        isWorking = true
        defer { isWorking = false }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).zip")
            try data.write(to: staged, options: .atomic)
            let service = BackupService()
            let payload = try service.read(from: staged)
            pendingImport = payload
            pendingImportURL = staged
            message = "识别到备份：\(payload.summary.filter { $0.value > 0 }.map { "\($0.key) \($0.value)" }.joined(separator: "、"))"
        } catch {
            errorMessage = "无法读取备份：\(error.localizedDescription)"
        }
    }

    // MARK: - 应用备份

    func applyPendingImport(overwrite: Bool) async {
        guard !isWorking, let payload = pendingImport, let database else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let previous = try await currentPayload()
            let merged = overwrite ? payload : try previous.merging(payload)
            let materialized = try BackupService().materializeLocalFiles(merged, in: baseDirectory.appendingPathComponent("LocalBooks"))
            let restored = materialized.payload
            let rules = FileReplaceRuleRepository(fileURL: baseDirectory.appendingPathComponent("replace-rules.json"))
            do {
                try await rules.save(restored.replaceRules)
                if let settings = restored.settings { try ApplicationSettingsStore.shared.save(settings) }
                if let preferences = restored.preferences { try BackupService().restorePreferences(preferences, to: .standard) }
                try await database.restoreBackup(restored)
            } catch {
                for url in materialized.created { try? FileManager.default.removeItem(at: url) }
                try await rules.save(previous.replaceRules)
                if let settings = previous.settings { try ApplicationSettingsStore.shared.save(settings) }
                if let preferences = previous.preferences { try BackupService().restorePreferences(preferences, to: .standard) }
                throw error
            }
            NotificationCenter.default.post(name: .legadoDataDidImport, object: nil)
            message = overwrite ? "已覆盖导入，正在刷新数据。" : "已合并导入，正在刷新数据。"
            pendingImport = nil
            if let url = pendingImportURL { try? FileManager.default.removeItem(at: url) }
            pendingImportURL = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}

extension Notification.Name {
    static let legadoDataDidImport = Notification.Name("legado.data.didImport")
}

// MARK: - 页面

struct BackupRestoreView: View {
    @StateObject private var model = BackupRestoreModel()
    @State private var confirmsOverwrite = false
    @State private var importMode: ImportMode?

    private enum ImportMode: Identifiable {
        case merge, overwrite
        var id: Int { self == .merge ? 0 : 1 }
    }

    var body: some View {
        List {
            Section {
                ForEach(model.summary.keys.sorted(), id: \.self) { key in
                    ReadingLabeledContent(key) { Text("\(model.summary[key] ?? 0)") }
                }
            } header: {
                Text("当前数据")
            } footer: {
                Text("备份包含书源、书籍与分组、本地书原文件、阅读进度、书签、笔记、净化规则、TXT 目录规则、在线朗读、RSS 源、规则订阅与网络设置。登录态、Cookie 和章节缓存不在备份内。")
            }

            Section("备份") {
                Button {
                    Task { await model.export(appVersion: Self.appVersion) }
                } label: {
                    Label("生成备份文件", systemImage: "doc.badge.plus")
                }
                .disabled(model.isWorking)
                if let url = model.exportURL {
                    ReadingShareLink(item: url) {
                        Label("分享或存储备份文件", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section {
                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("从备份文件导入", systemImage: "square.and.arrow.down")
                }
                .disabled(model.isWorking)
            } header: {
                Text("恢复")
            } footer: {
                Text("支持本应用的备份包，也会尽力识别安卓版「阅读」的备份压缩包。导入前会先读取并显示内容清单。")
            }

            if !model.servers.isEmpty {
                Section("远端备份") {
                    Picker("存储位置", selection: $model.selectedServerID) {
                        ForEach(model.servers) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: model.selectedServerID) { _ in model.remoteBackups = [] }
                    Button("备份并上传") { Task { await model.uploadBackup() } }
                    Button("查看远端备份") { Task { await model.listRemoteBackups() } }
                    ForEach(model.remoteBackups, id: \.path) { file in
                        Button(file.name) { Task { await model.downloadBackup(file) } }
                    }
                }
                .disabled(model.isWorking)
            }

            if let message = model.message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }

            if model.isWorking {
                Section { HStack { ProgressView(); Text("正在处理…") } }
            }
        }
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshSummary() }
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: [.zip, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await model.prepareImport(url) }
        }
        .confirmationDialog(
            "导入这份备份？",
            isPresented: Binding(get: { model.pendingImport != nil && importMode == nil && !model.isWorking }, set: { _ in }),
            titleVisibility: .visible
        ) {
            Button("合并到当前数据") { importMode = .merge }
            Button("覆盖当前数据", role: .destructive) { importMode = .overwrite }
            Button("取消", role: .cancel) { model.pendingImport = nil }
        } message: {
            if let payload = model.pendingImport {
                Text(payload.summary.filter { $0.value > 0 }.map { "\($0.key)：\($0.value)" }.joined(separator: "，"))
            }
        }
        .confirmationDialog(
            "覆盖会先清空现有书源、书籍、笔记等数据，确定继续？",
            isPresented: $confirmsOverwrite,
            titleVisibility: .visible
        ) {
            Button("确定覆盖", role: .destructive) {
                Task {
                    await model.applyPendingImport(overwrite: true)
                    await model.refreshSummary()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: importMode) { value in
            guard let value else { return }
            if value == .overwrite { confirmsOverwrite = true }
            else {
                Task {
                    await model.applyPendingImport(overwrite: false)
                    await model.refreshSummary()
                    importMode = nil
                }
            }
        }
        .onChange(of: confirmsOverwrite) { value in
            if !value { importMode = nil }
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

extension BackupRestoreView {
    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}
