//
//  MCPRegistry.swift
//  Loop
//
//  Installs and tracks remote MCP servers (Hirey, etc.) the way
//  DynamicSkillRegistry installs and tracks user-authored JS skills.
//
//  Each installed server is a JSON record under Workspace/MCPServers/<slug>.json.
//  Bearer tokens live in the Keychain at the `mcp.<slug>.token` account so the
//  on-disk record stays safe in iCloud Drive.
//
//  The registry exposes the same five methods the harness uses on
//  DynamicSkillRegistry — `handles`, `handle`, `toolSchemas`,
//  `systemPromptFragment`, `reload` — so AgentHarness can wire it up at the
//  exact same call sites with no special-casing.
//
//  Tool names are namespaced as `<slug>__<tool>` to avoid collisions when two
//  servers expose tools with the same name. The model sees them as ordinary
//  functions; the registry splits the prefix back off on dispatch.
//

import CryptoKit
import Foundation
import Security

final class MCPRegistry {

    static let shared = MCPRegistry()

    /// Folder name under Workspace/ that holds server JSON records.
    static let foldername = "MCPServers"

    /// Separator between the server slug and the upstream tool name. Kept to
    /// double-underscore so it survives most JSON-Schema function-name
    /// validators (which only allow `[A-Za-z0-9_-]`).
    static let toolNameSeparator = "__"

    /// Called whenever the set of servers / tools changes so AgentHarness can
    /// refresh its `toolSchemas` and the TOOLS.md fragment.
    var didReload: (() -> Void)?

    private(set) var servers: [MCPServerRecord] = []

    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "loop.mcpregistry", qos: .userInitiated)
    /// One long-lived MCPClient per installed server so the `initialize`
    /// handshake fires once per session instead of once per tool call. Keyed
    /// by slug; the entry is dropped on uninstall/disable so a stale session
    /// can't outlive the record.
    private var clients: [String: MCPClient] = [:]
    private let clientsLock = NSLock()
    /// Keychain service for MCP bearer tokens. Lives in its own service so
    /// the existing KeyStore keychain bucket (which enumerates a fixed Key
    /// enum) doesn't need to know about per-server slugs.
    private static let keychainService = "com.bhat.intel.mcp"

    private init() {
        loadFromDisk()
    }

    // MARK: - Folder + persistence

    /// Root folder for server JSON records. Created on first access.
    var rootURL: URL {
        let url = Workspace.shared.rootURL.appendingPathComponent(Self.foldername,
                                                                  isDirectory: true)
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Pull every <slug>.json off disk into memory. Called at init and after
    /// any mutation so the in-memory list stays the source of truth.
    private func loadFromDisk() {
        let root = rootURL
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) else {
            return
        }
        var loaded: [MCPServerRecord] = []
        for entry in entries where entry.pathExtension == "json" {
            try? Workspace.shared.ensureDownloaded(entry)
            guard let data = try? Data(contentsOf: entry),
                  let record = try? JSONDecoder().decode(MCPServerRecord.self, from: data) else {
                print("MCPRegistry: skipping malformed record at \(entry.lastPathComponent)")
                continue
            }
            loaded.append(record)
        }
        loaded.sort { $0.name.lowercased() < $1.name.lowercased() }
        servers = loaded
    }

    private func writeToDisk(_ record: MCPServerRecord) throws {
        let url = rootURL.appendingPathComponent("\(record.slug).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: url, options: [.atomic])
    }

    private func removeFromDisk(slug: String) {
        let url = rootURL.appendingPathComponent("\(slug).json")
        try? fm.removeItem(at: url)
    }

    // MARK: - Install / update / remove

    /// Install a new server by URL. Runs `initialize` + `tools/list` once to
    /// fetch the server's name and tool catalog; throws if either fails so a
    /// bad URL / wrong token surfaces immediately instead of as a silent
    /// "installed but empty" row.
    func install(urlString: String,
                 bearerToken: String?,
                 displayName: String? = nil,
                 completion: @escaping (Result<MCPServerRecord, Error>) -> Void) {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            completion(.failure(MCPClientError.invalidURL)); return
        }

        let slug = resolveSlug(forURL: urlString, parsedURL: url)

        // Pre-write the token to Keychain so the client can pick it up via
        // the same path live edits use. Empty token deletes any prior value.
        Self.writeToken(bearerToken, slug: slug)

        let client = MCPClient(url: url, bearerToken: bearerToken)
        client.initialize { [weak self] initResult in
            guard let self = self else { return }
            switch initResult {
            case .failure(let e):
                completion(.failure(e))
            case .success(let serverInfo):
                client.listTools { listResult in
                    switch listResult {
                    case .failure(let e):
                        completion(.failure(e))
                    case .success(let tools):
                        let record = MCPServerRecord(
                            slug: slug,
                            name: displayName ?? (serverInfo.name.isEmpty ? (url.host ?? slug) : serverInfo.name),
                            url: urlString,
                            enabled: true,
                            cachedTools: tools,
                            installedAt: ISO8601DateFormatter().string(from: Date())
                        )
                        do {
                            try self.writeToDisk(record)
                            self.queue.sync { self.upsert(record) }
                            self.didReload?()
                            completion(.success(record))
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    /// Remove a server by slug. Drops the on-disk JSON, deletes the token
    /// from Keychain, and refreshes the harness.
    func uninstall(slug: String) {
        queue.sync {
            servers.removeAll { $0.slug == slug }
        }
        removeFromDisk(slug: slug)
        Self.writeToken(nil, slug: slug)
        dropClient(slug: slug)
        didReload?()
    }

    /// Flip `enabled` for a server. Disabled servers stay installed but their
    /// tools disappear from the schema until re-enabled.
    func setEnabled(_ enabled: Bool, slug: String) {
        var changed: MCPServerRecord?
        queue.sync {
            guard let idx = servers.firstIndex(where: { $0.slug == slug }) else { return }
            servers[idx].enabled = enabled
            changed = servers[idx]
        }
        if let r = changed {
            try? writeToDisk(r)
            // Disable drops the cached client so the next enable rebuilds it
            // against the current token + a fresh session.
            if !enabled { dropClient(slug: slug) }
            didReload?()
        }
    }

    /// Re-fetch every enabled server's `tools/list` and update the cache.
    /// Called from AgentHarness on each turn; cheap enough since most users
    /// will have 0–2 servers installed.
    ///
    /// Fully non-blocking — kicks off the per-server fetches and returns
    /// immediately. Updates land via `didReload` (and `completion`, if
    /// supplied) when every fetch settles. The current turn always uses
    /// the cached tools; a slow server just delays its own next-turn
    /// refresh instead of stalling any thread.
    func reload(completion: (() -> Void)? = nil) {
        // Snapshot on the queue so this is safe to call from any thread.
        let snapshot = queue.sync { servers }
        let enabledServers = snapshot.filter { $0.enabled }
        guard !enabledServers.isEmpty else {
            if let c = completion { DispatchQueue.main.async(execute: c) }
            return
        }

        let group = DispatchGroup()
        let updatesLock = NSLock()
        var updates: [String: [MCPTool]] = [:]

        for server in enabledServers {
            guard let client = self.client(for: server) else { continue }
            group.enter()
            // Reuses the cached session if one is live; only handshakes if
            // the client is new or the session was invalidated by a 404.
            // The 5s timeout on `listTools` keeps the hung-server guarantee:
            // a slow server fails its catalog fetch fast without affecting
            // in-flight `tools/call` requests on the same client.
            client.ensureInitialized { [weak self] initResult in
                if case .failure(let e) = initResult {
                    self?.handleSessionError(e, slug: server.slug)
                    group.leave(); return
                }
                client.listTools(timeout: 5) { [weak self] listResult in
                    switch listResult {
                    case .success(let tools):
                        updatesLock.lock()
                        updates[server.slug] = tools
                        updatesLock.unlock()
                    case .failure(let e):
                        self?.handleSessionError(e, slug: server.slug)
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: queue) { [weak self] in
            guard let self = self else {
                if let c = completion { DispatchQueue.main.async(execute: c) }
                return
            }
            var anyChange = false
            for (slug, tools) in updates {
                guard let idx = self.servers.firstIndex(where: { $0.slug == slug }) else { continue }
                if !Self.tools(tools, equal: self.servers[idx].cachedTools) {
                    self.servers[idx].cachedTools = tools
                    try? self.writeToDisk(self.servers[idx])
                    anyChange = true
                }
            }
            if anyChange { self.didReload?() }
            if let c = completion { DispatchQueue.main.async(execute: c) }
        }
    }

    private func upsert(_ record: MCPServerRecord) {
        if let idx = servers.firstIndex(where: { $0.slug == record.slug }) {
            servers[idx] = record
        } else {
            servers.append(record)
        }
        servers.sort { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Harness integration (mirrors DynamicSkillRegistry's surface)

    /// OpenAI/Anthropic-style function schemas for every enabled tool on
    /// every enabled server, with names namespaced as `<slug>__<tool>`.
    func toolSchemas() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for server in servers where server.enabled {
            for tool in server.cachedTools {
                let namespaced = "\(server.slug)\(Self.toolNameSeparator)\(tool.name)"
                var parameters: [String: Any]
                if let schemaAny = tool.inputSchema?.toAny() as? [String: Any] {
                    parameters = schemaAny
                } else {
                    parameters = [
                        "type": "object",
                        "properties": [String: Any](),
                        "required": [String]()
                    ]
                }
                // Force `type: object` so providers that hard-reject schemas
                // without it (some Anthropic validators) still accept the
                // declaration.
                if parameters["type"] == nil { parameters["type"] = "object" }
                out.append([
                    "type": "function",
                    "function": [
                        "name": namespaced,
                        "description": tool.description ?? "Remote tool from \(server.name)",
                        "parameters": parameters
                    ]
                ])
            }
        }
        return out
    }

    /// TOOLS.md fragment — one bullet per installed remote tool so the model
    /// knows what's available without needing to inspect the schema.
    func systemPromptFragment() -> String {
        let active = servers.filter { $0.enabled && !$0.cachedTools.isEmpty }
        guard !active.isEmpty else { return "" }
        var lines: [String] = [
            "You also have access to these remote tools, installed by the user "
            + "from MCP servers (treat them as ordinary tools):"
        ]
        for server in active {
            lines.append("")
            lines.append("From `\(server.name)`:")
            for tool in server.cachedTools {
                let namespaced = "\(server.slug)\(Self.toolNameSeparator)\(tool.name)"
                let desc = tool.description ?? "(no description)"
                lines.append("- `\(namespaced)`: \(desc)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// True if `functionName` is one of our namespaced tools and the host
    /// server is still installed + enabled.
    func handles(functionName: String) -> Bool {
        return resolve(functionName: functionName) != nil
    }

    /// Shimmer-bar status text shown while a tool is in flight.
    func statusText(for call: FunctionCallStruct) -> String? {
        guard let (server, tool) = resolve(functionName: call.name) else { return nil }
        return "calling \(tool) on \(server.name)"
    }

    /// Dispatch a namespaced tool call to the right server, then shape the
    /// MCP response into a function-role MessageStruct.
    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        guard let (server, tool) = resolve(functionName: functionCall.name) else {
            completion(Self.functionMessage(
                name: functionCall.name,
                payload: ["status": "error", "error": "Unknown MCP tool \(functionCall.name)"]
            ))
            return
        }
        guard let client = self.client(for: server) else {
            completion(Self.functionMessage(
                name: functionCall.name,
                payload: ["status": "error", "error": "Invalid server URL \(server.url)"]
            ))
            return
        }
        // Cached client: `ensureInitialized` is a no-op after the first
        // successful handshake, so subsequent tool calls skip the extra
        // round-trip entirely. If the server has since invalidated the
        // session (HTTP 404 per MCP spec), `callOnce` retries once after
        // forcing a fresh handshake.
        callOnce(server: server,
                 client: client,
                 functionCall: functionCall,
                 tool: tool,
                 allowSessionRetry: true,
                 completion: completion)
    }

    /// Run one initialize+callTool pair. If the call fails with a
    /// session-expired signal and `allowSessionRetry` is true, invalidates
    /// the cached session and retries once. Beyond that, surfaces the error
    /// to the model.
    private func callOnce(server: MCPServerRecord,
                          client: MCPClient,
                          functionCall: FunctionCallStruct,
                          tool: String,
                          allowSessionRetry: Bool,
                          completion: @escaping (MessageStruct) -> Void) {
        client.ensureInitialized { [weak self, weak client] initResult in
            guard let client = client else { return }
            if case .failure(let e) = initResult {
                if allowSessionRetry, self?.isSessionExpired(e) == true {
                    client.invalidateSession()
                    self?.callOnce(server: server,
                                   client: client,
                                   functionCall: functionCall,
                                   tool: tool,
                                   allowSessionRetry: false,
                                   completion: completion)
                    return
                }
                completion(Self.functionMessage(
                    name: functionCall.name,
                    payload: ["status": "error", "error": e.localizedDescription]
                ))
                return
            }
            client.callTool(name: tool, arguments: functionCall.arguments) { [weak self] callResult in
                switch callResult {
                case .failure(let e):
                    if allowSessionRetry, self?.isSessionExpired(e) == true {
                        client.invalidateSession()
                        self?.callOnce(server: server,
                                       client: client,
                                       functionCall: functionCall,
                                       tool: tool,
                                       allowSessionRetry: false,
                                       completion: completion)
                        return
                    }
                    completion(Self.functionMessage(
                        name: functionCall.name,
                        payload: ["status": "error", "error": e.localizedDescription]
                    ))
                case .success(let result):
                    var payload: [String: Any] = [
                        "status": "success",
                        "tool": functionCall.name,
                        "server": server.name
                    ]
                    // MCP returns `content: [{type, text|json|...}]`. Splat the
                    // text blocks into a single `summary` for the model and
                    // pass the raw content through for any structured reader.
                    if let content = result["content"] as? [[String: Any]] {
                        let texts = content.compactMap { $0["text"] as? String }
                        if !texts.isEmpty { payload["summary"] = texts.joined(separator: "\n") }
                        payload["content"] = content
                    } else {
                        // Some servers return `structuredContent` instead.
                        for (k, v) in result { payload[k] = v }
                    }
                    if let isError = result["isError"] as? Bool, isError {
                        payload["status"] = "error"
                    }
                    completion(Self.functionMessage(name: functionCall.name, payload: payload))
                }
            }
        }
    }

    // MARK: - Helpers

    /// Split a namespaced function name (`<slug>__<tool>`) back into the
    /// server record + upstream tool name. Returns nil for names that don't
    /// match any installed-and-enabled server.
    private func resolve(functionName: String) -> (server: MCPServerRecord, tool: String)? {
        guard let range = functionName.range(of: Self.toolNameSeparator) else { return nil }
        let slug = String(functionName[..<range.lowerBound])
        let tool = String(functionName[range.upperBound...])
        let snapshot = queue.sync { servers }
        guard let server = snapshot.first(where: { $0.slug == slug && $0.enabled }) else { return nil }
        // Confirm the tool is one the server advertises so a stale call
        // name (after the server removed a tool) fails cleanly.
        guard server.cachedTools.contains(where: { $0.name == tool }) else { return nil }
        return (server, tool)
    }

    /// Pick a slug for a newly-installed URL. Reuses the existing slug on a
    /// same-URL reinstall, returns the base slug if it's free, and otherwise
    /// appends a stable 6-char URL hash so two distinct URLs that happen to
    /// derive the same base slug (e.g. `mcp.foo/x` and `mcp-foo/x` both
    /// collapse to `mcp_foo_x`) cannot overwrite each other's records.
    func resolveSlug(forURL urlString: String, parsedURL: URL) -> String {
        let base = Self.slug(from: parsedURL)
        let snapshot = queue.sync { servers }
        if let existing = snapshot.first(where: { $0.url == urlString }) {
            return existing.slug
        }
        if !snapshot.contains(where: { $0.slug == base }) {
            return base
        }
        return "\(base)_\(Self.shortHash(of: urlString))"
    }

    /// Lowercase base slug derived from the URL host + path. Non-alphanumeric
    /// characters collapse to underscore; two distinct URLs CAN produce the
    /// same base slug, which is why `resolveSlug` layers a URL-hash suffix on
    /// top of this when needed.
    static func slug(from url: URL) -> String {
        let host = url.host ?? "server"
        let pathPart = url.path
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let raw = pathPart.isEmpty ? host : "\(host)_\(pathPart)"
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        return String(raw.lowercased().unicodeScalars.compactMap { s in
            let ch = Character(s)
            return allowed.contains(ch) ? ch : "_"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// First 6 hex chars of SHA256(string). Enough entropy (~16M) that a
    /// collision between two real-world MCP URLs is effectively impossible
    /// while keeping the suffix short enough to stay inside typical
    /// function-name length limits.
    static func shortHash(of string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Client cache

    /// Returns the cached client for `server`, lazily creating one on first
    /// use. The bearer token is refreshed from Keychain on every access so a
    /// freshly-edited token applies on the very next call without dropping
    /// the live session.
    private func client(for server: MCPServerRecord) -> MCPClient? {
        guard let url = URL(string: server.url) else { return nil }
        clientsLock.lock(); defer { clientsLock.unlock() }
        if let existing = clients[server.slug], existing.url == url {
            existing.bearerToken = Self.readToken(slug: server.slug)
            return existing
        }
        let fresh = MCPClient(url: url, bearerToken: Self.readToken(slug: server.slug))
        clients[server.slug] = fresh
        return fresh
    }

    /// Drop the cached client (and its session) for `slug`. Called on
    /// uninstall and on disable so a stale session can't outlive the record.
    private func dropClient(slug: String) {
        clientsLock.lock(); defer { clientsLock.unlock() }
        clients.removeValue(forKey: slug)
    }

    /// True if the error indicates the server no longer accepts the cached
    /// session id. Per MCP spec, that's HTTP 404 on a request that carried a
    /// `Mcp-Session-Id` header.
    private func isSessionExpired(_ error: Error) -> Bool {
        guard let mcpError = error as? MCPClientError else { return false }
        if case .http(let status, _) = mcpError, status == 404 { return true }
        return false
    }

    /// Invalidate the cached client's session on a session-expired signal so
    /// the next call re-handshakes from scratch. Other errors are left alone
    /// — they don't necessarily mean the session is dead.
    private func handleSessionError(_ error: Error, slug: String) {
        guard isSessionExpired(error) else { return }
        clientsLock.lock()
        let cached = clients[slug]
        clientsLock.unlock()
        cached?.invalidateSession()
    }

    private static func tools(_ a: [MCPTool], equal b: [MCPTool]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.name != y.name || x.description != y.description { return false }
        }
        return true
    }

    private static func functionMessage(name: String, payload: Any) -> MessageStruct {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "{}"
        }
        return MessageStruct(role: "function", content: json, name: name)
    }

    // MARK: - Keychain

    /// Account name in the MCP keychain bucket. One token per installed
    /// server slug.
    private static func tokenAccount(slug: String) -> String { "mcp.\(slug).token" }

    /// Read the bearer token for `slug`. Returns nil if none is stored.
    static func readToken(slug: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount(slug: slug),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        _ = query  // silence unused warning if we ever simplify
        return s
    }

    /// Write or delete the bearer token for `slug`. Passing nil/empty clears
    /// any stored value.
    @discardableResult
    static func writeToken(_ token: String?, slug: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount(slug: slug),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecUseDataProtectionKeychain as String: true
        ]
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = trimmed, !v.isEmpty {
            let data = Data(v.utf8)
            let updateStatus = SecItemUpdate(base as CFDictionary,
                                             [kSecValueData as String: data] as CFDictionary)
            if updateStatus == errSecSuccess { return true }
            var addAttrs = base
            addAttrs[kSecValueData as String] = data
            addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addAttrs as CFDictionary, nil) == errSecSuccess
        } else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
    }
}
