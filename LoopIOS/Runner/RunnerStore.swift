//
//  RunnerStore.swift
//  Loop
//
//  Keychain-backed persistence for runner configurations. Secrets (shared
//  secrets) live in individual Keychain entries; the runner list itself is
//  stored as a JSON blob under a dedicated service name. Mirrors KeyStore's
//  Keychain helpers but is scoped entirely to the runner feature so it
//  doesn't pollute the existing key namespace.
//

import Foundation
import Security
import os

final class RunnerStore {

    static let shared = RunnerStore()

    static let didChangeNotification = Notification.Name("RunnerStoreDidChange")

    private static let service = "com.loop.runner.configs"
    private static let account = "runners"
    private static let secretService = "com.loop.runner.secrets"

    private static let log = Logger(subsystem: "com.bhat.intel", category: "RunnerStore")

    private init() {}

    // MARK: - Runner list CRUD

    func loadRunners() -> [RunnerConfig] {
        guard let data = readKeychain(service: Self.service, account: Self.account) else {
            return []
        }
        return (try? JSONDecoder().decode([RunnerConfig].self, from: data)) ?? []
    }

    @discardableResult
    func saveRunners(_ runners: [RunnerConfig]) -> Bool {
        guard let data = try? JSONEncoder().encode(runners) else { return false }
        let ok = writeKeychain(data: data, service: Self.service, account: Self.account)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return ok
    }

    @discardableResult
    func addRunner(_ runner: RunnerConfig) -> Bool {
        var runners = loadRunners()
        runners.append(runner)
        return saveRunners(runners)
    }

    @discardableResult
    func updateRunner(_ runner: RunnerConfig) -> Bool {
        var runners = loadRunners()
        guard let idx = runners.firstIndex(where: { $0.id == runner.id }) else { return false }
        runners[idx] = runner
        return saveRunners(runners)
    }

    @discardableResult
    func deleteRunner(id: String) -> Bool {
        var runners = loadRunners()
        guard let idx = runners.firstIndex(where: { $0.id == id }) else { return false }
        let removed = runners.remove(at: idx)
        deleteSecret(for: removed.secretRef)
        LoopRunnerPoller.shared.clearState(for: id)
        return saveRunners(runners)
    }

    // MARK: - Per-runner shared secret

    func secret(for ref: String) -> String? {
        guard let data = readKeychain(service: Self.secretService, account: ref) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func setSecret(_ value: String, for ref: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return writeKeychain(data: data, service: Self.secretService, account: ref)
    }

    @discardableResult
    func deleteSecret(for ref: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.secretService,
            kSecAttrAccount as String: ref,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Keychain helpers

    private func readKeychain(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func writeKeychain(data: Data, service: String, account: String) -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            Self.log.error("Keychain write failed for \(account): \(status)")
        }
        return status == errSecSuccess
    }
}
