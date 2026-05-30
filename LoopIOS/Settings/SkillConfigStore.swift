//
//  SkillConfigStore.swift
//  Loop
//
//  Central store for runtime configuration values that user-authored skills
//  can read via `host.getConfig(key)`. This provides a safe bridge: skills
//  can access connection parameters (relay URLs, non-secret identifiers) but
//  never raw secrets like private keys or API tokens.
//
//  Allowed keys are explicitly enumerated — skills cannot read arbitrary
//  Keychain entries or UserDefaults values.
//

import Foundation

final class SkillConfigStore {

    static let shared = SkillConfigStore()
    private init() {}

    /// Keys that skills are allowed to read via `host.getConfig(key)`.
    /// Add new entries here to expose additional configuration to the
    /// JS skill runtime.
    enum ConfigKey: String, CaseIterable {
        // SSH relay connection (non-secret parts)
        case sshRelayHost = "ssh_relay_host"
        case sshRelayPort = "ssh_relay_port"
        case sshRelayUser = "ssh_relay_user"

        /// User-facing label for the Settings UI.
        var displayName: String {
            switch self {
            case .sshRelayHost: return "SSH Relay Host"
            case .sshRelayPort: return "SSH Relay Port"
            case .sshRelayUser: return "SSH Relay Username"
            }
        }

        var subtitle: String {
            switch self {
            case .sshRelayHost: return "Hostname for the SSH relay (e.g. relay.example.com). Used by skills like claude_code."
            case .sshRelayPort: return "Port for the SSH relay (default: 22)."
            case .sshRelayUser: return "Username for the SSH relay connection."
            }
        }
    }

    private static let userDefaultsPrefix = "loop.skillconfig."

    private let defaults = UserDefaults.standard

    // MARK: - Public interface

    /// Read a config value by key. Returns nil if unset.
    func get(_ key: ConfigKey) -> String? {
        defaults.string(forKey: Self.userDefaultsPrefix + key.rawValue)
    }

    /// Write a config value.
    func set(_ key: ConfigKey, value: String?) {
        if let value = value, !value.isEmpty {
            defaults.set(value, forKey: Self.userDefaultsPrefix + key.rawValue)
        } else {
            defaults.removeObject(forKey: Self.userDefaultsPrefix + key.rawValue)
        }
    }

    /// Retrieve a config value by its raw string key name (for use from JS).
    /// Returns nil if the key is not in the allowed set or has no value.
    func get(rawKey: String) -> String? {
        guard let key = ConfigKey(rawValue: rawKey) else { return nil }
        return get(key)
    }

    /// Returns all configured values as a dictionary (for diagnostics, never
    /// logged with secrets). Only non-nil entries are included.
    func allConfigured() -> [String: String] {
        var result: [String: String] = [:]
        for key in ConfigKey.allCases {
            if let val = get(key) {
                result[key.rawValue] = val
            }
        }
        return result
    }

    /// Convenience: populate SSH relay config from the existing SSHConfigStore
    /// so skills can access relay host/port/user without re-entering them.
    /// Called on app launch if SSH is configured.
    func syncFromSSHConfig() {
        let ssh = SSHConfigStore.shared.config
        if !ssh.host.isEmpty {
            set(.sshRelayHost, value: ssh.host)
        }
        if ssh.port != 0 {
            set(.sshRelayPort, value: String(ssh.port))
        }
        if !ssh.username.isEmpty {
            set(.sshRelayUser, value: ssh.username)
        }
    }
}
