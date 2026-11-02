import Foundation

public protocol BookNoteRepository: Sendable {
    func loadAll() async throws -> [BookNote]
    func load(bookURL: String) async throws -> [BookNote]
    func upsert(_ note: BookNote) async throws
    func delete(id: String) async throws
    func deleteAll(bookURL: String) async throws
    func replaceAll(_ notes: [BookNote]) async throws
}

public actor SQLiteBookNoteRepository: BookNoteRepository {
    private let database: LegadoDatabase

    public init(database: LegadoDatabase) { self.database = database }

    public func loadAll() async throws -> [BookNote] { try await database.loadBookNotes() }

    public func load(bookURL: String) async throws -> [BookNote] {
        try await database.loadBookNotes(bookURL: bookURL)
    }

    public func upsert(_ note: BookNote) async throws { try await database.upsertBookNote(note) }

    public func delete(id: String) async throws { try await database.deleteBookNote(id: id) }

    public func deleteAll(bookURL: String) async throws {
        try await database.deleteBookNotes(bookURL: bookURL)
    }

    public func replaceAll(_ notes: [BookNote]) async throws {
        try await database.replaceBookNotes(notes)
    }
}

public actor InMemoryBookNoteRepository: BookNoteRepository {
    private var values: [BookNote]

    public init(values: [BookNote] = []) { self.values = values }

    public func loadAll() -> [BookNote] { values.sorted { $0.createdAt < $1.createdAt } }

    public func load(bookURL: String) -> [BookNote] {
        values.filter { $0.bookUrl == bookURL }.sorted { $0.createdAt < $1.createdAt }
    }

    public func upsert(_ note: BookNote) {
        if let index = values.firstIndex(where: { $0.id == note.id }) { values[index] = note }
        else { values.append(note) }
    }

    public func delete(id: String) { values.removeAll { $0.id == id } }

    public func deleteAll(bookURL: String) { values.removeAll { $0.bookUrl == bookURL } }

    public func replaceAll(_ notes: [BookNote]) { values = notes }
}
