//
//  SSHConfigStore.swift
//  Loop
//
//  Persists the user's SSH connections. Loop supports multiple saved
//  connections; the list is ordered and the *first* entry is the default —
//  the one the `ssh_client` skill and the Loop Runner transport connect to.
//
//  Non-secret fields (id, name, host, port, username) live in UserDefaults as
//  a JSON list; the private key and passphrase for each connection live in the
//  Keychain, keyed by the connection's UUID. `config` is a compatibility shim
//  that reads/writes the default connection, so existing single-config callers
//  keep working unchanged.
//

import Foundation
import Security

struct SSHConfig: Identifiable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var privateKey: String
    var passphrase: String

    init(id: UUID = UUID(),
         name: String = "",
         host: String = "",
         port: Int = 22,
         username: String = "",
         privateKey: String = "",
         passphrase: String = "") {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.privateKey = privateKey
        self.passphrase = passphrase
    }

    var isConfigured: Bool {
        !host.isEmpty && !username.isEmpty && !privateKey.isEmpty
    }

    /// Friendly label, falling back to the host (or a placeholder) when unnamed.
    var displayName: String {
        if !name.isEmpty { return name }
        if !host.isEmpty { return host }
        return "Untitled connection"
    }

    /// `user@host` (with `:port` when non-standard) for the list subtitle.
    var endpointSummary: String {
        let user = username.isEmpty ? "" : "\(username)@"
        let portPart = (port == 22 || port == 0) ? "" : ":\(port)"
        return "\(user)\(host)\(portPart)"
    }
}

final class SSHConfigStore {

    static let shared = SSHConfigStore()

    // MARK: - Storage keys

    private static let listKey = "loop.ssh.connections.v2"

    // Legacy single-config keys (migrated on first load).
    private static let legacyHostKey = "loop.ssh.host"
    private static let legacyPortKey = "loop.ssh.port"
    private static let legacyUsernameKey = "loop.ssh.username"
    private static let legacyKeyAccount = "loop.ssh.privateKey"
    private static let legacyPassAccount = "loop.ssh.passphrase"

    private let defaults = UserDefaults.standard

    /// Ordered connections; `connections[0]` is the default.
    private(set) var connections: [SSHConfig] = []

    private init() {
        load()
    }

    // MARK: - Default-connection shim (legacy single-config API)

    /// The default connection (first in the list). Reads return an empty,
    /// unconfigured config when none exist; writes upsert the default.
    var config: SSHConfig {
        get { connections.first ?? SSHConfig() }
        set {
            if var first = connections.first {
                first.host = newValue.host
                first.port = newValue.port
                first.username = newValue.username
                first.privateKey = newValue.privateKey
                first.passphrase = newValue.passphrase
                if first.name.isEmpty { first.name = newValue.host }
                connections[0] = first
            } else {
                var created = newValue
                if created.name.isEmpty { created.name = newValue.host }
                connections = [created]
            }
            save()
        }
    }

    // MARK: - Collection API

    func connection(id: UUID) -> SSHConfig? {
        connections.first { $0.id == id }
    }

    /// Inserts a new connection (appended) or updates an existing one in place.
    func addOrUpdate(_ connection: SSHConfig) {
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx] = connection
        } else {
            connections.append(connection)
        }
        save()
    }

    func delete(id: UUID) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        let removed = connections.remove(at: idx)
        deleteSecrets(for: removed.id)
        save()
    }

    /// Promotes a connection to the default position (top of the list).
    func makeDefault(id: UUID) {
        guard let idx = connections.firstIndex(where: { $0.id == id }), idx != 0 else { return }
        let item = connections.remove(at: idx)
        connections.insert(item, at: 0)
        save()
    }

    // MARK: - Persistence

    private struct Meta: Codable {
        let id: UUID
        let name: String
        let host: String
        let port: Int
        let username: String
    }

    private func load() {
        if let data = defaults.data(forKey: Self.listKey),
           let metas = try? JSONDecoder().decode([Meta].self, from: data) {
            connections = metas.map { meta in
                SSHConfig(
                    id: meta.id,
                    name: meta.name,
                    host: meta.host,
                    port: meta.port,
                    username: meta.username,
                    privateKey: readKeychain(account: Self.keyAccount(meta.id)) ?? "",
                    passphrase: readKeychain(account: Self.passAccount(meta.id)) ?? "")
            }
            return
        }
        migrateLegacyIfPresent()
    }

    private func save() {
        let metas = connections.map {
            Meta(id: $0.id, name: $0.name, host: $0.host, port: $0.port, username: $0.username)
        }
        if let data = try? JSONEncoder().encode(metas) {
            defaults.set(data, forKey: Self.listKey)
        }
        for c in connections {
            writeKeychain(account: Self.keyAccount(c.id), value: c.privateKey)
            writeKeychain(account: Self.passAccount(c.id), value: c.passphrase)
        }
    }

    /// One-time migration of the old single-connection layout into the list.
    private func migrateLegacyIfPresent() {
        let host = defaults.string(forKey: Self.legacyHostKey) ?? ""
        let username = defaults.string(forKey: Self.legacyUsernameKey) ?? ""
        let key = readKeychain(account: Self.legacyKeyAccount) ?? ""
        let pass = readKeychain(account: Self.legacyPassAccount) ?? ""

        guard !host.isEmpty || !username.isEmpty || !key.isEmpty else {
            connections = []
            return
        }

        let port = defaults.integer(forKey: Self.legacyPortKey)
        let migrated = SSHConfig(
            id: UUID(),
            name: host,
            host: host,
            port: port == 0 ? 22 : port,
            username: username,
            privateKey: key,
            passphrase: pass)
        connections = [migrated]
        save()

        // Clear legacy storage so it isn't re-read or left dangling.
        defaults.removeObject(forKey: Self.legacyHostKey)
        defaults.removeObject(forKey: Self.legacyPortKey)
        defaults.removeObject(forKey: Self.legacyUsernameKey)
        deleteKeychain(account: Self.legacyKeyAccount)
        deleteKeychain(account: Self.legacyPassAccount)
    }

    private static func keyAccount(_ id: UUID) -> String { "loop.ssh.key.\(id.uuidString)" }
    private static func passAccount(_ id: UUID) -> String { "loop.ssh.pass.\(id.uuidString)" }

    private func deleteSecrets(for id: UUID) {
        deleteKeychain(account: Self.keyAccount(id))
        deleteKeychain(account: Self.passAccount(id))
    }

    // MARK: - Keychain helpers

    private func readKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychain(account: String, value: String) {
        deleteKeychain(account: account)
        guard !value.isEmpty else { return }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    private func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
