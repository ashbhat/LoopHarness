//
//  SSHConfigStore.swift
//  Loop
//
//  Persists the user's SSH connection settings (host, port, username,
//  private key, passphrase) so the ssh_client skill can read them at
//  runtime. Non-secret fields live in UserDefaults; the private key and
//  passphrase are stored in the Keychain via the same helper pattern
//  KeyStore uses.
//

import Foundation
import Security

struct SSHConfig {
    var host: String
    var port: Int
    var username: String
    var privateKey: String
    var passphrase: String

    var isConfigured: Bool {
        !host.isEmpty && !username.isEmpty && !privateKey.isEmpty
    }
}

final class SSHConfigStore {

    static let shared = SSHConfigStore()

    private static let hostKey = "loop.ssh.host"
    private static let portKey = "loop.ssh.port"
    private static let usernameKey = "loop.ssh.username"
    private static let privateKeyAccount = "loop.ssh.privateKey"
    private static let passphraseAccount = "loop.ssh.passphrase"

    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Public interface

    var config: SSHConfig {
        get {
            SSHConfig(
                host: defaults.string(forKey: Self.hostKey) ?? "",
                port: defaults.integer(forKey: Self.portKey).nonZero ?? 22,
                username: defaults.string(forKey: Self.usernameKey) ?? "",
                privateKey: readKeychain(account: Self.privateKeyAccount) ?? "",
                passphrase: readKeychain(account: Self.passphraseAccount) ?? ""
            )
        }
        set {
            defaults.set(newValue.host, forKey: Self.hostKey)
            defaults.set(newValue.port, forKey: Self.portKey)
            defaults.set(newValue.username, forKey: Self.usernameKey)
            writeKeychain(account: Self.privateKeyAccount, value: newValue.privateKey)
            writeKeychain(account: Self.passphraseAccount, value: newValue.passphrase)
        }
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
        guard status == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychain(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        // Delete existing, then add — simpler than update-or-add branching.
        SecItemDelete(query as CFDictionary)
        if !value.isEmpty {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - Int helper

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
