import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class BookNotesModel: ObservableObject {
    @Published private(set) var notes: [BookNote] = []
    @Published var errorMessage: String?

    private let repository: any BookNoteRepository

    init(repository: any BookNoteRepository) { self.repository = repository }

    static func live() -> BookNotesModel {
        if let database = try? LegadoDatabase(url: LegadoDatabase.defaultURL()) {
            return BookNotesModel(repository: SQLiteBookNoteRepository(database: database))
        }
        return BookNotesModel(repository: InMemoryBookNoteRepository())
    }

    func load(bookURL: String) async {
        do { notes = try await repository.load(bookURL: bookURL) }
        catch { errorMessage = error.localizedDescription }
    }

    func loadAll() async {
        do { notes = try await repository.loadAll() }
        catch { errorMessage = error.localizedDescription }
    }

    func save(_ note: BookNote) async {
        do {
            try await repository.upsert(note)
            if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note }
            else { notes.append(note) }
            notes.sort { ($0.chapterIndex, $0.createdAt) < ($1.chapterIndex, $1.createdAt) }
            NotificationCenter.default.post(name: Notification.Name("legado.libraryDataDidChange"), object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ note: BookNote) async {
        do {
            try await repository.delete(id: note.id)
            notes.removeAll { $0.id == note.id }
            NotificationCenter.default.post(name: Notification.Name("legado.libraryDataDidChange"), object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func notes(bookURL: String, chapterIndex: Int) -> [BookNote] {
        notes.filter { $0.bookUrl == bookURL && $0.chapterIndex == chapterIndex }
    }

    func highlights(bookURL: String, chapterIndex: Int) -> [ReaderHighlight] {
        notes(bookURL: bookURL, chapterIndex: chapterIndex)
            .filter { !$0.quote.isEmpty }
            .map { ReaderHighlight(quote: $0.quote, color: $0.color, startOffset: $0.startOffset) }
    }
}

// MARK: - 本书笔记

struct BookNotesView: View {
    let book: Book
    let chapter: BookChapter?
    let paragraphs: [ReaderParagraph]
    @ObservedObject var model: BookNotesModel
    var onChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var editing: BookNote?
    @State private var showsComposer = false
    @State private var pendingDelete: BookNote?
    @State private var exportText = ""
    @State private var exportsNotes = false

    private var grouped: [(chapterIndex: Int, chapterName: String, notes: [BookNote])] {
        let buckets = Dictionary(grouping: model.notes.filter { $0.bookUrl == book.bookUrl }) { $0.chapterIndex }
        return buckets.keys.sorted().map { index in
            let items = (buckets[index] ?? []).sorted { $0.createdAt < $1.createdAt }
            return (index, items.first?.chapterName ?? "第 \(index + 1) 章", items)
        }
    }

    var body: some View {
        ReadingNavigationStack {
            Group {
                if grouped.isEmpty {
                    ReadingUnavailableView(
                        "还没有笔记",
                        systemImage: "highlighter",
                        description: Text("长按正文高亮或写想法，也可以点右上角添加笔记。")
                    )
                } else {
                    List {
                        ForEach(grouped, id: \.chapterIndex) { section in
                            Section(section.chapterName) {
                                ForEach(section.notes) { note in
                                    Button { editing = note } label: {
                                        noteRow(note)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions {
                                        Button("删除", role: .destructive) { pendingDelete = note }
                                        Button("想法") { editing = note }
                                            .tint(ReadingTheme.accent)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("本书笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsComposer = true
                    } label: {
                        Label("添加笔记", systemImage: "square.and.pencil")
                    }
                    .disabled(paragraphs.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        exportText = BackupService().markdownNotes(model.notes.filter { $0.bookUrl == book.bookUrl })
                        exportsNotes = true
                    } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .disabled(model.notes.isEmpty)
                }
            }
            .fileExporter(isPresented: $exportsNotes, document: NotesTextDocument(text: exportText),
                          contentType: UTType(filenameExtension: "md") ?? .plainText, defaultFilename: "\(book.name)-笔记.md") { _ in }
            .sheet(isPresented: $showsComposer) {
                NoteComposerView(
                    book: book,
                    chapter: chapter,
                    paragraphs: paragraphs,
                    existing: nil
                ) { note in
                    Task {
                        await model.save(note)
                        onChanged()
                    }
                }
            }
            .sheet(item: $editing) { note in
                NoteComposerView(
                    book: book,
                    chapter: chapter,
                    paragraphs: paragraphs,
                    existing: note
                ) { updated in
                    Task {
                        await model.save(updated)
                        onChanged()
                    }
                }
            }
            .confirmationDialog(
                "删除这条笔记？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let note = pendingDelete {
                        Task {
                            await model.delete(note)
                            onChanged()
                        }
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
            .alert("笔记操作失败", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("好") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .task { await model.load(bookURL: book.bookUrl) }
        }
    }

    private func noteRow(_ note: BookNote) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(uiColor: ReaderHighlight.uiColor(note.color)))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(note.quote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if !note.isEmptyIdea {
                    Text(note.note)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                Text(Date(timeIntervalSince1970: Double(note.createdAt) / 1_000)
                    .formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - 全部笔记

struct AllNotesView: View {
    @StateObject private var model = BookNotesModel.live()
    @State private var searchText = ""
    @State private var exportsNotes = false
    @State private var exportText = ""
    @State private var editing: BookNote?
    @State private var orderByDate = false

    private var filtered: [BookNote] {
        let key = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return model.notes }
        return model.notes.filter {
            $0.quote.localizedCaseInsensitiveContains(key)
                || $0.note.localizedCaseInsensitiveContains(key)
                || $0.bookName.localizedCaseInsensitiveContains(key)
        }
    }

    private var grouped: [(key: String, book: String, notes: [BookNote])] {
        if orderByDate {
            let buckets = Dictionary(grouping: filtered) {
                Date(timeIntervalSince1970: Double($0.createdAt) / 1_000).formatted(.iso8601.year().month().day().dateSeparator(.dash))
            }
            return buckets.keys.sorted(by: >).map { ($0, $0, buckets[$0] ?? []) }
        }
        let buckets = Dictionary(grouping: filtered, by: \.bookUrl)
        return buckets.keys.sorted().map { key in
            let items = buckets[key] ?? []
            return (key, items.first?.bookName.isEmpty == false ? items[0].bookName : key, items)
        }
    }

    var body: some View {
        Group {
            if model.notes.isEmpty {
                ReadingUnavailableView(
                    "还没有笔记",
                    systemImage: "highlighter",
                    description: Text("在阅读页长按正文记录想法，所有书的笔记都会汇总到这里。")
                )
            } else if filtered.isEmpty {
                ReadingUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(grouped, id: \.key) { group in
                        Section(group.book) {
                            ForEach(group.notes.sorted { $0.createdAt > $1.createdAt }) { note in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(note.quote).font(.subheadline).lineLimit(2)
                                        .foregroundStyle(.secondary)
                                    if !note.isEmptyIdea {
                                        Text(note.note).font(.body)
                                    }
                                    HStack {
                                        Text(note.chapterName).font(.caption2).foregroundStyle(.tertiary)
                                        Spacer()
                                        Text(Date(timeIntervalSince1970: Double(note.createdAt) / 1_000)
                                            .formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day()))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .onTapGesture { editing = note }
                                .swipeActions {
                                    Button("删除", role: .destructive) { Task { await model.delete(note) } }
                                    Button("编辑") { editing = note }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $searchText, prompt: "搜索笔记")
            }
        }
        .navigationTitle("笔记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("按书籍分组") { orderByDate = false }
                    Button("按日期分组") { orderByDate = true }
                } label: { Label("分组", systemImage: "line.3.horizontal.decrease.circle") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportText = BackupService().markdownNotes(model.notes)
                    exportsNotes = true
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(model.notes.isEmpty)
            }
        }
        .fileExporter(
            isPresented: $exportsNotes,
            document: NotesTextDocument(text: exportText),
            contentType: UTType(filenameExtension: "md") ?? .plainText,
            defaultFilename: "读书笔记.md"
        ) { _ in }
        .task { await model.loadAll() }
        .sheet(item: $editing) { note in
            NoteComposerView(book: Book(bookUrl: note.bookUrl, name: note.bookName, author: note.bookAuthor),
                             chapter: nil, paragraphs: [], existing: note) { updated in
                Task { await model.save(updated) }
            }
        }
    }
}

private struct NotesTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, UTType(filenameExtension: "md") ?? .plainText] }
    static var writableContentTypes: [UTType] { readableContentTypes }

    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - 写笔记

struct NoteComposerView: View {
    let book: Book
    let chapter: BookChapter?
    let paragraphs: [ReaderParagraph]
    let existing: BookNote?
    var onSave: (BookNote) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedParagraphIndex: Int
    @State private var quote: String
    @State private var note: String
    @State private var color: Int

    init(
        book: Book,
        chapter: BookChapter?,
        paragraphs: [ReaderParagraph],
        existing: BookNote?,
        onSave: @escaping (BookNote) -> Void
    ) {
        self.book = book
        self.chapter = chapter
        self.paragraphs = paragraphs
        self.existing = existing
        self.onSave = onSave
        _selectedParagraphIndex = State(initialValue: existing?.paragraphIndex ?? 0)
        _quote = State(initialValue: existing?.quote ?? paragraphs.first?.text ?? "")
        _note = State(initialValue: existing?.note ?? "")
        _color = State(initialValue: existing?.color ?? 0)
    }

    private var trimmedQuote: String { quote.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ReadingNavigationStack {
            Form {
                if existing == nil, !paragraphs.isEmpty {
                    Section("选择正文段落") {
                        Picker("段落", selection: $selectedParagraphIndex) {
                            ForEach(paragraphs) { paragraph in
                                Text(paragraphLabel(paragraph))
                                    .tag(paragraph.id)
                            }
                        }
                        .onChange(of: selectedParagraphIndex) { newValue in
                            if let paragraph = paragraphs.first(where: { $0.id == newValue }) {
                                quote = paragraph.text
                            }
                        }
                    }
                }
                Section("划线原文") {
                    TextEditor(text: $quote)
                        .accessibilityLabel("划线原文")
                        .frame(minHeight: 90)
                        .font(.callout)
                }
                Section("想法") {
                    TextEditor(text: $note)
                        .accessibilityLabel("笔记想法")
                        .frame(minHeight: 120)
                }
                Section("颜色") {
                    HStack(spacing: 14) {
                        ForEach(0..<ReaderHighlight.palette.count, id: \.self) { index in
                            Button {
                                color = index
                            } label: {
                                Circle()
                                    .fill(Color(uiColor: ReaderHighlight.uiColor(index)))
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        Circle().strokeBorder(
                                            color == index ? ReadingTheme.selectionBorder : .clear,
                                            lineWidth: 2
                                        )
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("颜色 \(index + 1)")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(existing == nil ? "添加笔记" : "编辑笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(trimmedQuote.isEmpty && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func paragraphLabel(_ paragraph: ReaderParagraph) -> String {
        let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 24 ? String(text.prefix(24)) + "…" : text
    }

    private func save() {
        var result = existing ?? BookNote(bookUrl: book.bookUrl)
        result.bookUrl = book.bookUrl
        result.bookName = book.name
        result.bookAuthor = book.author
        result.chapterIndex = existing?.chapterIndex ?? chapter?.index ?? 0
        result.chapterName = existing?.chapterName ?? chapter?.title ?? ""
        result.paragraphIndex = selectedParagraphIndex
        result.quote = trimmedQuote
        result.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        result.kind = result.note.isEmpty ? .highlight : .note
        result.color = color
        result.updatedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        onSave(result)
        dismiss()
    }
}
