//
//  MCPClient.swift
//  Loop
//
//  Minimal Model Context Protocol client over the Streamable-HTTP transport.
//  Implements only the subset Loop needs to install a remote skill provider
//  (Hirey, etc.): `initialize` handshake, `tools/list`, and `tools/call`.
//
//  We deliberately don't support stdio MCP servers — they'd require subprocess
//  spawning, which iOS forbids and which we don't need for the install-by-URL
//  use case. Auth is a Bearer token (OAuth 2.1 support is a follow-up).
//
//  The Streamable-HTTP transport sends each JSON-RPC request as a POST to the
//  endpoint, and accepts either an `application/json` single-response or a
//  `text/event-stream` stream. For tools/list and tools/call we only care
//  about the final response, so we collect events until we see one matching
//  our request id and resolve with that.
//

import Foundation

/// One installed MCP server. Persisted to disk as JSON; the bearer token
/// lives separately in the Keychain so the file is safe to keep in iCloud.
struct MCPServerRecord: Codable {
    /// Stable slug derived from the server URL. Used as both the on-disk
    /// filename and the tool-name prefix (`<slug>__<toolname>`).
    let slug: String
    /// User-facing display name. Defaults to the server's `serverInfo.name`
    /// from initialize, or the host portion of the URL.
    var name: String
    /// Streamable-HTTP endpoint, e.g. `https://mcp.hirey.ai/mcp`.
    var url: String
    /// User can disable a server without uninstalling so the tools come out
    /// of the schema but the server stays configured for one-tap re-enable.
    var enabled: Bool
    /// Last `tools/list` response we got, cached so the tools appear in the
    /// schema offline / before the first refresh of a new session.
    var cachedTools: [MCPTool]
    /// ISO8601 install timestamp, surfaced in the UI for "Installed X ago".
    var installedAt: String
}

/// One tool exposed by an MCP server. Mirrors the MCP `tools/list` shape but
/// kept Codable-only so we can round-trip it through the on-disk cache.
struct MCPTool: Codable {
    let name: String
    let description: String?
    /// Raw JSON Schema describing the tool's input. Stored verbatim and
    /// re-emitted into the harness's `toolSchemas`.
    let inputSchema: JSONValue?
}

/// Tiny Codable JSON wrapper so we can persist the `inputSchema` blob without
/// committing to a specific Swift type. `toAny()` converts it back into the
/// `[String: Any]` shape the harness's tool dispatch expects.
enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                  { self = .null;   return }
        if let v = try? c.decode(Bool.self)               { self = .bool(v);   return }
        if let v = try? c.decode(Double.self)             { self = .number(v); return }
        if let v = try? c.decode(String.self)             { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self)        { self = .array(v);  return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let v):    try c.encode(v)
        case .number(let v):  try c.encode(v)
        case .string(let v):  try c.encode(v)
        case .array(let v):   try c.encode(v)
        case .object(let v):  try c.encode(v)
        }
    }

    func toAny() -> Any {
        switch self {
        case .null:           return NSNull()
        case .bool(let v):    return v
        case .number(let v):
            // Preserve integer-ness when the value round-trips losslessly so
            // schemas with integer `minimum` / `maximum` keep the right type.
            if v == v.rounded(), abs(v) < 1e15 { return Int(v) }
            return v
        case .string(let v):  return v
        case .array(let a):   return a.map { $0.toAny() }
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, v) in o { out[k] = v.toAny() }
            return out
        }
    }

    static func from(_ any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let v = any as? Bool { return .bool(v) }
        if let v = any as? Int { return .number(Double(v)) }
        if let v = any as? Double { return .number(v) }
        if let v = any as? String { return .string(v) }
        if let v = any as? [Any] { return .array(v.map { from($0) }) }
        if let v = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, val) in v { out[k] = from(val) }
            return .object(out)
        }
        return .null
    }
}

enum MCPClientError: Error, LocalizedError {
    case invalidURL
    case transport(String)
    case http(Int, String)
    case rpcError(code: Int, message: String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:               return "Server URL is not a valid HTTPS URL."
        case .transport(let m):         return "Network error: \(m)"
        case .http(let s, let m):       return "HTTP \(s): \(m)"
        case .rpcError(let c, let m):   return "MCP error \(c): \(m)"
        case .malformedResponse(let m): return "Malformed MCP response: \(m)"
        }
    }
}

/// Streamable-HTTP MCP client. One instance per call site is fine — internal
/// state (session id) is held per-URL on the registry side, not here.
final class MCPClient {

    /// Protocol version we advertise during `initialize`. MCP servers
    /// negotiate downward if they speak an older version.
    static let protocolVersion = "2025-03-26"

    let url: URL
    /// Optional bearer token. The registry reads it from Keychain before
    /// each call so a freshly-edited token applies immediately.
    var bearerToken: String?
    /// Session id from the `Mcp-Session-Id` response header on `initialize`,
    /// echoed back on subsequent requests. Some servers require it; others
    /// don't issue one. We round-trip whatever they hand us.
    var sessionId: String?
    /// Per-request URLSession timeout. Defaults to 30s (long enough for an
    /// actual `tools/call`); callers doing background catalog refreshes pass
    /// a much shorter value so a single hung server can't pin the request.
    let timeoutInterval: TimeInterval

    /// True once `initialize` has completed successfully for this client. The
    /// registry caches one client per server slug so the handshake fires once
    /// per session instead of once per tool call.
    private var initialized = false
    private var initializing = false
    private var pendingInit: [(Result<Void, Error>) -> Void] = []
    private let initLock = NSLock()

    init(url: URL, bearerToken: String? = nil, timeoutInterval: TimeInterval = 30) {
        self.url = url
        self.bearerToken = bearerToken
        self.timeoutInterval = timeoutInterval
    }

    /// Run `initialize` if it hasn't already succeeded for this client;
    /// otherwise complete synchronously. Concurrent callers coalesce — only
    /// one handshake fires and every waiter gets the same result.
    func ensureInitialized(completion: @escaping (Result<Void, Error>) -> Void) {
        initLock.lock()
        if initialized {
            initLock.unlock()
            completion(.success(()))
            return
        }
        pendingInit.append(completion)
        if initializing {
            initLock.unlock()
            return
        }
        initializing = true
        initLock.unlock()

        initialize { [weak self] result in
            guard let self = self else { return }
            self.initLock.lock()
            let waiting = self.pendingInit
            self.pendingInit = []
            self.initializing = false
            if case .success = result { self.initialized = true }
            self.initLock.unlock()

            let mapped: Result<Void, Error>
            switch result {
            case .success:        mapped = .success(())
            case .failure(let e): mapped = .failure(e)
            }
            for c in waiting { c(mapped) }
        }
    }

    /// Drop the cached session so the next `ensureInitialized` re-handshakes.
    /// Per the MCP spec, servers return HTTP 404 once a session id is no
    /// longer valid — the registry calls this on that signal so a subsequent
    /// tool call recovers instead of looping on the dead session.
    func invalidateSession() {
        initLock.lock()
        initialized = false
        sessionId = nil
        initLock.unlock()
    }

    // MARK: - Public RPC surface

    /// Run the initialize handshake. Returns the negotiated server info
    /// (name, version) so the UI can show it. Also stashes the session id
    /// for subsequent requests.
    func initialize(completion: @escaping (Result<(name: String, version: String), Error>) -> Void) {
        let params: [String: Any] = [
            "protocolVersion": Self.protocolVersion,
            "clientInfo": [
                "name": "Loop",
                "version": "1.0"
            ],
            "capabilities": [
                "tools": [String: Any]()
            ]
        ]
        send(method: "initialize", params: params, isNotification: false) { [weak self] result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let payload):
                // Fire-and-forget the `notifications/initialized` follow-up
                // some servers require before they'll respond to tools/list.
                self?.send(method: "notifications/initialized", params: [:], isNotification: true) { _ in }
                guard let result = payload["result"] as? [String: Any],
                      let info = result["serverInfo"] as? [String: Any] else {
                    completion(.failure(MCPClientError.malformedResponse("missing serverInfo")))
                    return
                }
                let name = (info["name"] as? String) ?? self?.url.host ?? "MCP Server"
                let version = (info["version"] as? String) ?? ""
                completion(.success((name: name, version: version)))
            }
        }
    }

    /// Fetch the catalog of tools the server exposes. `timeout` overrides the
    /// client's default per-request timeout — the registry's background
    /// catalog refresh passes a short value so a hung server fails fast
    /// without affecting in-flight tool calls on the same shared client.
    func listTools(timeout: TimeInterval? = nil,
                   completion: @escaping (Result<[MCPTool], Error>) -> Void) {
        send(method: "tools/list", params: [:], isNotification: false, timeoutOverride: timeout) { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let payload):
                guard let result = payload["result"] as? [String: Any],
                      let toolsArr = result["tools"] as? [[String: Any]] else {
                    completion(.failure(MCPClientError.malformedResponse("missing result.tools")))
                    return
                }
                let tools: [MCPTool] = toolsArr.compactMap { dict in
                    guard let name = dict["name"] as? String else { return nil }
                    let desc = dict["description"] as? String
                    let schema = dict["inputSchema"].map { JSONValue.from($0) }
                    return MCPTool(name: name, description: desc, inputSchema: schema)
                }
                completion(.success(tools))
            }
        }
    }

    /// Invoke a tool. Returns the raw `result` block from the server — the
    /// registry shapes it into a function-role message for the harness.
    func callTool(name: String,
                  arguments: [String: Any],
                  completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let params: [String: Any] = [
            "name": name,
            "arguments": arguments
        ]
        send(method: "tools/call", params: params, isNotification: false) { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let payload):
                guard let result = payload["result"] as? [String: Any] else {
                    completion(.failure(MCPClientError.malformedResponse("missing result")))
                    return
                }
                completion(.success(result))
            }
        }
    }

    // MARK: - JSON-RPC transport

    /// Send one JSON-RPC message. Notifications get no id and don't wait for
    /// a response payload; regular calls block until a matching response
    /// (matched by `id`) arrives over the chosen Streamable-HTTP framing.
    /// `timeoutOverride` lets a specific call cap its URLSession timeout
    /// below the client's default (used by the catalog-refresh path).
    private func send(method: String,
                      params: [String: Any],
                      isNotification: Bool,
                      timeoutOverride: TimeInterval? = nil,
                      completion: @escaping (Result<[String: Any], Error>) -> Void) {

        let id = isNotification ? nil : Int.random(in: 1...Int.max)
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if !params.isEmpty { payload["params"] = params }
        if let id = id     { payload["id"] = id }

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            completion(.failure(MCPClientError.malformedResponse("could not encode request")))
            return
        }

        var request = URLRequest(url: url, timeoutInterval: timeoutOverride ?? timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Streamable HTTP: accept either a JSON one-shot or an SSE stream.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token = bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let session = sessionId, !session.isEmpty {
            request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                completion(.failure(MCPClientError.transport(error.localizedDescription)))
                return
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0

            // Capture a session id if one was issued. Servers can issue it on
            // any response (most commonly initialize), and we echo it back on
            // every subsequent request.
            if let newSession = http?.value(forHTTPHeaderField: "Mcp-Session-Id"),
               !newSession.isEmpty {
                self.sessionId = newSession
            }

            // Notifications return 202 with no body — done.
            if isNotification {
                if status >= 200 && status < 300 {
                    completion(.success([:]))
                } else {
                    let snippet = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    completion(.failure(MCPClientError.http(status, snippet)))
                }
                return
            }

            guard let data = data, !data.isEmpty else {
                completion(.failure(MCPClientError.malformedResponse("empty response body")))
                return
            }

            if status < 200 || status >= 300 {
                let snippet = String(data: data, encoding: .utf8) ?? "<binary>"
                completion(.failure(MCPClientError.http(status, snippet)))
                return
            }

            let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let payload: [String: Any]?
            if contentType.contains("text/event-stream") {
                payload = Self.parseSSE(data: data, matchingId: id)
            } else {
                payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }

            guard let payload = payload else {
                let snippet = String(data: data, encoding: .utf8) ?? ""
                completion(.failure(MCPClientError.malformedResponse("could not parse: \(snippet.prefix(200))")))
                return
            }

            // Surface JSON-RPC application errors as Swift errors so the UI
            // can show them and the agent can read the text.
            if let err = payload["error"] as? [String: Any] {
                let code = (err["code"] as? Int) ?? -32603
                let msg  = (err["message"] as? String) ?? "Unknown MCP error"
                completion(.failure(MCPClientError.rpcError(code: code, message: msg)))
                return
            }

            completion(.success(payload))
        }.resume()
    }

    /// Walk an SSE body and return the first `message` event whose JSON-RPC
    /// `id` matches the request we sent. Servers may interleave other events
    /// (progress, logs) before the final response.
    private static func parseSSE(data: Data, matchingId: Int?) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                // End of event — try to parse the accumulated data.
                if !current.isEmpty {
                    if let bytes = current.data(using: .utf8),
                       let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
                        // For notifications without an id, accept any payload
                        // with a `result` or `error` key. For id-bearing
                        // requests, only match by id.
                        if let want = matchingId {
                            if let got = obj["id"] as? Int, got == want { return obj }
                        } else if obj["result"] != nil || obj["error"] != nil {
                            return obj
                        }
                    }
                    current = ""
                }
                continue
            }
            if line.hasPrefix("data:") {
                let chunk = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if !current.isEmpty { current += "\n" }
                current += chunk
            }
            // Other SSE fields (event:, id:, retry:) ignored — we only care
            // about the data payload.
        }
        // No blank line terminator at end of stream — try the buffer anyway.
        if !current.isEmpty,
           let bytes = current.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
            return obj
        }
        return nil
    }
}
