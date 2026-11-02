import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class RemoteServersModel: ObservableObject {
    @Published var servers: [Server] = []
    @Published var message: String?
    @Published var isWorking = false
    private var store: RemoteServerStore?

    private func repository() throws -> RemoteServerStore {
        if let store { return store }
        let value = RemoteServerStore(database: try LegadoDatabase(url: LegadoDatabase.defaultURL()))
        store = value
        return value
    }
    func load() async {
        do { servers = try await repository().load() }
        catch { message = error.localizedDescription }
    }
    func save(_ server: Server) async throws {
        isWorking = true
        defer { isWorking = false }
        try await repository().save(server)
        servers = try await repository().load()
    }
    func delete(_ server: Server) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await repository().delete(server.id)
            servers = try await repository().load()
        } catch { message = error.localizedDescription }
    }
}

struct RemoteStorageView: View {
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sync: BookshelfSyncModel
    @StateObject private var model = RemoteServersModel()
    @State private var editing: Server?
    @State private var deleting: Server?

    var body: some View {
        List {
            Section {
                Picker("同步存储", selection: $sync.selectedServerID) {
                    Text("未启用").tag("")
                    ForEach(model.servers) { server in Text(server.name).tag(String(server.id)) }
                }
                Toggle("自动同步书架与进度", isOn: $sync.automatic).disabled(sync.selectedServerID.isEmpty)
                Button {
                    Task { await sync.synchronize(library) }
                } label: {
                    HStack {
                        Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if sync.isSynchronizing { ProgressView() }
                    }
                }.disabled(sync.selectedServerID.isEmpty || sync.isSynchronizing)
                if let date = sync.lastSync {
                    Text("上次成功：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let status = sync.status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("书架与阅读进度") } footer: {
                Text("各设备选择同一存储目录后合并书架、分组、删除记录及 TXT / EPUB 阅读位置，并传输本地书原文件。自动同步在启动、回到前台及书架变化后执行；退出前台时尝试完成上传。在线书所需书源请在各设备分别导入。")
            }
            Section {
                if model.servers.isEmpty {
                    Text("添加远端存储，浏览文件并下载 TXT / EPUB 到书架。").foregroundStyle(.secondary)
                }
                ForEach(model.servers) { server in
                    NavigationLink {
                        RemoteFilesView(server: server)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.name)
                                Text(server.type.title).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "externaldrive.connected.to.line.below") }
                    }
                    .contextMenu {
                        Button("编辑", systemImage: "pencil") { editing = server }
                        Button("移除配置", systemImage: "trash", role: .destructive) { deleting = server }
                    }
                    .swipeActions {
                        Button("移除", role: .destructive) { deleting = server }
                        Button("编辑") { editing = server }.tint(.blue)
                    }
                }
            } header: { Text("我的存储") } footer: {
                Text("支持 WebDAV、AWS S3 及兼容服务、Dropbox。凭据保存在本机钥匙串。")
            }
            Section {
                ForEach(Server.ServerType.allCases, id: \.self) { type in
                    Button("添加 \(type.title)", systemImage: "plus") {
                        editing = Server(id: Int64.random(in: 1...Int64.max), name: type.title, type: type)
                    }
                }
            }
        }
        .navigationTitle("远端存储")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.isWorking || sync.isSynchronizing)
        .task { await model.load() }
        .onChange(of: sync.selectedServerID) { _ in Task { await sync.synchronizeIfAutomatic(library) } }
        .onChange(of: sync.automatic) { enabled in
            if enabled { Task { await sync.synchronizeIfAutomatic(library) } }
        }
        .sheet(item: $editing) { server in
            RemoteServerEditor(server: server) { value in try await model.save(value) }
        }
        .confirmationDialog("移除存储配置？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("移除配置", role: .destructive) {
                if let server = deleting {
                    Task {
                        await model.delete(server)
                        if !model.servers.contains(where: { $0.id == server.id }), sync.selectedServerID == String(server.id) {
                            sync.selectedServerID = ""
                        }
                    }
                }
                deleting = nil
            }
        } message: { Text("移除本机配置和凭据，远端文件保留。") }
        .alert("操作失败", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

private struct RemoteServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var server: Server
    let save: (Server) async throws -> Void
    @State private var webDAV = Server.WebDAVConfig(url: "", username: "", password: "")
    @State private var s3 = Server.S3Config()
    @State private var dropbox = Server.DropboxConfig()
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section("存储") {
                    TextField("名称", text: $server.name)
                    HStack { Text("类型"); Spacer(); Text(server.type.title).foregroundStyle(.secondary) }
                }
                connectionFields
                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("测试连接")
                            if isWorking { Spacer(); ProgressView() }
                        }
                    }
                } footer: {
                    Text("连接测试读取目录列表。单个文件上限 150 MB；上传不覆盖同名文件。")
                }
            }
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .navigationTitle(server.config == nil ? "添加远端存储" : "编辑远端存储")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            isWorking = true
                            defer { isWorking = false }
                            do {
                                let value = try configured()
                                try await save(value)
                                dismiss()
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(isWorking)
                }
            }
            .disabled(isWorking)
            .interactiveDismissDisabled(isWorking)
            .onAppear {
                webDAV = server.webDAVConfig ?? webDAV
                s3 = server.s3Config ?? s3
                dropbox = server.dropboxConfig ?? dropbox
            }
            .alert("连接与配置", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
        }
    }

    @ViewBuilder private var connectionFields: some View {
        switch server.type {
        case .webDAV:
            Section {
                TextField("https://example.com/dav/books/", text: $webDAV.url).keyboardType(.URL).accessibilityLabel("WebDAV 地址")
                TextField("用户名", text: $webDAV.username)
                SecureField("密码或应用专用密码", text: $webDAV.password)
            } header: { Text("WebDAV") } footer: {
                Text("填写已存在的根目录地址。推荐 HTTPS；HTTP 会明文传输凭据与文件。")
            }
        case .s3:
            Section {
                TextField("https://s3.us-east-1.amazonaws.com", text: $s3.endpoint).keyboardType(.URL).accessibilityLabel("S3 Endpoint")
                TextField("Region", text: $s3.region)
                TextField("Bucket", text: $s3.bucket)
                TextField("Access Key ID", text: $s3.accessKey)
                SecureField("Secret Access Key", text: $s3.secretKey)
                SecureField("Session Token（可选）", text: $s3.sessionToken)
                TextField("目录前缀（可选）", text: $s3.prefix)
                Toggle("使用 Path-style 地址", isOn: $s3.pathStyle)
            } header: { Text("S3 / 兼容服务") } footer: {
                Text("填写服务商提供的 Endpoint 和 Region。支持 MinIO 等兼容服务；关闭 Path-style 时使用 Bucket.Endpoint 地址。推荐 HTTPS。")
            }
        case .dropbox:
            Section {
                SecureField("Access Token", text: $dropbox.accessToken)
                TextField("根目录（可选）", text: $dropbox.rootPath)
                Link("打开 Dropbox 应用管理", destination: URL(string: "https://www.dropbox.com/developers/apps")!)
            } header: { Text("Dropbox") } footer: {
                Text("使用你自己的 Dropbox 应用访问令牌，需 files.metadata.read、files.content.read 和 files.content.write 权限。根目录留空使用应用可访问的根目录；短期令牌过期后需在此更新。")
            }
        }
    }
    private func configured() throws -> Server {
        var value = server
        switch value.type {
        case .webDAV: try value.setConfiguration(webDAV)
        case .s3: try value.setConfiguration(s3)
        case .dropbox: try value.setConfiguration(dropbox)
        }
        return try value.validatedForRemoteStorage()
    }
    @MainActor private func testConnection() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let client = try RemoteStorageClient(server: configured())
            let files = try await client.list()
            message = "连接成功，当前目录共 \(files.count) 项。"
        } catch { message = error.localizedDescription }
    }
}

private struct RemoteFilesView: View {
    @EnvironmentObject private var library: BookLibraryModel
    let server: Server
    var path = ""
    @State private var files: [RemoteFile] = []
    @State private var isWorking = false
    @State private var loaded = false
    @State private var message: String?
    @State private var importsFile = false
    @State private var exportDocument = RemoteFileDocument(data: Data())
    @State private var exportName = ""
    @State private var exportsFile = false
    @State private var createsDirectory = false
    @State private var directoryName = ""

    var body: some View {
        List {
            if files.isEmpty && loaded {
                Text("此目录为空").foregroundStyle(.secondary)
            }
            ForEach(files) { file in
                if file.isDirectory {
                    NavigationLink {
                        RemoteFilesView(server: server, path: file.path)
                    } label: { fileLabel(file) }
                } else {
                    Menu {
                        if ["txt", "epub"].contains((file.name as NSString).pathExtension.lowercased()) {
                            Button("下载并加入书架", systemImage: "books.vertical") { Task { await download(file, toLibrary: true) } }
                        }
                        Button("下载到文件", systemImage: "square.and.arrow.down") { Task { await download(file, toLibrary: false) } }
                    } label: { fileLabel(file) }
                }
            }
        }
        .navigationTitle(path.isEmpty ? server.name : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await reload() } }
                    Button("上传文件", systemImage: "square.and.arrow.up") { importsFile = true }
                    Button("新建文件夹", systemImage: "folder.badge.plus") { directoryName = ""; createsDirectory = true }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("远端文件操作") }
            }
        }
        .disabled(isWorking)
        .overlay { if isWorking { ProgressView("正在处理…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task { if !loaded { await reload() } }
        .refreshable { await reload() }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                let picked = urls.map { LocalBookImportFile(url: $0) }
                Task { await upload(picked) }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exportsFile, document: exportDocument, contentType: .data, defaultFilename: exportName) { result in
            if case .failure(let error) = result { message = error.localizedDescription }
            exportDocument = .init(data: Data())
        }
        .sheet(isPresented: $createsDirectory) {
            ReadingNavigationStack {
                Form {
                    TextField("文件夹名称", text: $directoryName).textInputAutocapitalization(.never).disableAutocorrection(true)
                }
                .navigationTitle("新建文件夹")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { createsDirectory = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("创建") { createsDirectory = false; Task { await createDirectory() } }
                            .disabled(directoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .alert("远端存储", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func fileLabel(_ file: RemoteFile) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).foregroundStyle(.primary)
                if !file.isDirectory, let bytes = file.bytes {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: { Image(systemName: file.isDirectory ? "folder" : "doc.text") }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    @MainActor private func reload() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            files = try await RemoteStorageClient(server: server).list(path)
            loaded = true
        } catch { message = error.localizedDescription }
    }
    private func destination(_ name: String) throws -> String {
        guard !name.contains("/"), !name.isEmpty else { throw RemoteStorageError.invalidPath }
        return try RemoteStorageClient.path([path, name].filter { !$0.isEmpty }.joined(separator: "/"), allowEmpty: false)
    }
    @MainActor private func upload(_ picked: [LocalBookImportFile]) async {
        guard !isWorking, let file = picked.first else { return }
        isWorking = true
        defer { isWorking = false; withExtendedLifetime(picked) {} }
        do {
            let target = try destination(file.url.lastPathComponent)
            let data = try await Task.detached {
                let size = try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= RemoteStorageClient.maximumFileSize else { throw RemoteStorageError.tooLarge }
                return try Data(contentsOf: file.url, options: .mappedIfSafe)
            }.value
            let client = try RemoteStorageClient(server: server)
            try await client.upload(data, to: target)
            files = try await client.list(path)
            message = "文件已上传。"
        } catch { message = error.localizedDescription }
    }
    @MainActor private func download(_ file: RemoteFile, toLibrary: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            guard (file.bytes ?? 0) <= RemoteStorageClient.maximumFileSize else { throw RemoteStorageError.tooLarge }
            let data = try await RemoteStorageClient(server: server).download(file.path)
            if toLibrary {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let url = folder.appendingPathComponent(file.name)
                try await Task.detached { try data.write(to: url, options: .atomic) }.value
                await library.importLocalFiles([url])
                if let error = library.errorMessage { message = error; library.clearError() }
                else { message = "已加入书架。" }
            } else {
                exportName = file.name
                exportDocument = .init(data: data)
                exportsFile = true
            }
        } catch { message = error.localizedDescription }
    }
    @MainActor private func createDirectory() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let client = try RemoteStorageClient(server: server)
            try await client.createDirectory(destination(directoryName.trimmingCharacters(in: .whitespacesAndNewlines)))
            files = try await client.list(path)
            loaded = true
        } catch { message = error.localizedDescription }
    }
}

private struct RemoteFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
