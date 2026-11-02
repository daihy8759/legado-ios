import Foundation
import Security

public protocol RemoteCredentialVault: Sendable {
    func read(_ id: Int64) throws -> Data?
    func write(_ data: Data?, for id: Int64) throws
}

public struct KeychainRemoteCredentialVault: RemoteCredentialVault {
    private let service: String
    public init(service: String = "Legado.RemoteStorage") { self.service = service }
    private func query(_ id: Int64) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: String(id)]
    }
    public func read(_ id: Int64) throws -> Data? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultError(status: status) }
        return result as? Data
    }
    public func write(_ data: Data?, for id: Int64) throws {
        let query = query(id)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError(status: status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VaultError(status: status) }
    }
    private struct VaultError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法访问远端存储凭据（钥匙串 \(status)）。请解锁设备后重试。" }
    }
}

public actor RemoteServerStore {
    private let database: LegadoDatabase
    private let vault: any RemoteCredentialVault
    // Serialize read-modify-write operations across awaits on the database actor.
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(database: LegadoDatabase, vault: any RemoteCredentialVault = KeychainRemoteCredentialVault()) {
        self.database = database; self.vault = vault
    }

    public func load() async throws -> [Server] {
        await acquire()
        defer { release() }
        return try await hydratedServers()
    }

    public func save(_ server: Server) async throws {
        let server = try server.validatedForRemoteStorage()
        await acquire()
        defer { release() }
        var values = try await hydratedServers()
        if let index = values.firstIndex(where: { $0.id == server.id }) { values[index] = server }
        else { values.append(server) }
        try await persist(values)
    }

    public func delete(_ id: Int64) async throws {
        await acquire()
        defer { release() }
        let values = try await hydratedServers().filter { $0.id != id }
        // Remove the database reference first; a failed Keychain deletion can
        // leave only an orphan credential, never a broken live configuration.
        try await persist(values)
        try vault.write(nil, for: id)
    }

    private func hydratedServers() async throws -> [Server] {
        try await database.loadServers().map { stored in
            var value = stored
            if let data = try vault.read(stored.id) { value.config = String(decoding: data, as: UTF8.self) }
            // Old WebDAV rows still work and migrate on the next save.
            return value
        }
    }

    private func persist(_ servers: [Server]) async throws {
        var previous: [Int64: Data] = [:]
        var written: [Int64] = []
        do {
            var sanitized: [Server] = []
            for server in servers {
                previous[server.id] = try vault.read(server.id)
                try vault.write(server.config.map { Data($0.utf8) }, for: server.id)
                written.append(server.id)
                var row = server
                // All connection details live in Keychain, including usernames.
                row.config = nil
                sanitized.append(row)
            }
            try await database.replaceServers(sanitized)
        } catch {
            for id in written { try? vault.write(previous[id], for: id) }
            throw error
        }
    }

    private func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { locked = false }
        else { waiters.removeFirst().resume() }
    }
}
