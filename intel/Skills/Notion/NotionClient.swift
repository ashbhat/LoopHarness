//
//  NotionClient.swift
//  Loop
//
//  Direct client for api.notion.com/v1. Uses the user-supplied integration
//  token from KeyStore — no Loop backend in the path. Mirrors SlackSkill's
//  networking shape: one private request helper, typed errors, a hint string
//  per error code that the skill can relay to the model.
//
//  Shared between NotionSkill and SpecBuilderSkill so both skills hit Notion
//  the same way.
//

import Foundation

/// Thin wrapper around the Notion REST API. Methods return raw `[String: Any]`
/// payloads so callers can shape them however the model wants — markdown
/// conversion lives in NotionMarkdown, not here.
final class NotionClient {

    static let shared = NotionClient()

    /// Notion's required version header. Bump when the API changes.
    static let apiVersion = "2026-03-11"

    /// Notion's published cap on appended block children per request.
    static let appendChunkSize = 100

    private static let baseURL = "https://api.notion.com/v1"

    /// Dedicated URLSession so request/resource timeouts don't depend on the
    /// shared session config. Matches AnthropicChat's pattern.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Errors

    enum NotionError: Error {
        case notConnected
        case transport
        case malformedResponse
        /// Non-2xx response. `code` is Notion's machine-readable string
        /// (e.g. "unauthorized", "object_not_found"); `message` is their
        /// human-readable detail.
        case api(status: Int, code: String, message: String)

        /// One-liner the skill can pass back through `function` role so the
        /// model has something concrete to relay to the user.
        var hint: String {
            switch self {
            case .notConnected:
                return "Notion isn't connected. Ask the user to paste their `ntn_…` integration token in Settings → Keys → Notion Integration Token."
            case .transport:
                return "Network error talking to api.notion.com. Suggest retrying."
            case .malformedResponse:
                return "Notion returned an unexpected response shape."
            case .api(_, let code, _):
                return NotionClient.recoveryHint(for: code)
            }
        }

        /// Short stable error code for the JSON payload back to the model.
        var code: String {
            switch self {
            case .notConnected:        return "notion_not_connected"
            case .transport:           return "notion_transport_failed"
            case .malformedResponse:   return "notion_malformed_response"
            case .api(_, let c, _):    return c
            }
        }
    }

    private static func recoveryHint(for apiCode: String) -> String {
        switch apiCode {
        case "unauthorized":
            return "The Notion token is invalid or revoked. Mint a fresh `ntn_…` token from notion.so/profile/integrations and paste it in Settings → Keys → Notion Integration Token."
        case "restricted_resource":
            return "The integration doesn't have access to this page. Open it in Notion → ••• → Connections → add the integration."
        case "object_not_found":
            return "Page id not found, or it isn't shared with the integration. Share the parent page with the integration in Notion."
        case "rate_limited":
            return "Notion rate-limited the call (about 3 req/s). Wait a moment and retry."
        case "validation_error":
            return "Notion rejected the payload. Usually a malformed block — try simpler markdown."
        case "conflict_error":
            return "Notion saw a conflicting concurrent edit. Retry shortly."
        default:
            return "See https://developers.notion.com/reference/status-codes for this error code."
        }
    }

    // MARK: - Endpoints

    /// POST /v1/search. Pass nil `query` to list every page the integration
    /// can see (closest analogue to "list root pages").
    func search(query: String?,
                pageSize: Int = 20,
                completion: @escaping (Result<[[String: Any]], NotionError>) -> Void) {
        var body: [String: Any] = [
            "filter": ["value": "page", "property": "object"],
            "page_size": min(max(pageSize, 1), 100)
        ]
        if let query, !query.isEmpty { body["query"] = query }
        request(method: "POST", path: "/search", body: body) { result in
            completion(result.map { ($0["results"] as? [[String: Any]]) ?? [] })
        }
    }

    /// GET /v1/blocks/{block_id}/children — single page of blocks.
    func listBlockChildren(blockId: String,
                           startCursor: String?,
                           pageSize: Int = 100,
                           completion: @escaping (Result<(blocks: [[String: Any]], nextCursor: String?), NotionError>) -> Void) {
        var query = "?page_size=\(min(max(pageSize, 1), 100))"
        if let cursor = startCursor, !cursor.isEmpty,
           let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query += "&start_cursor=\(encoded)"
        }
        let path = "/blocks/\(idPathComponent(blockId))/children\(query)"
        request(method: "GET", path: path, body: nil) { result in
            completion(result.map { dict in
                let blocks = (dict["results"] as? [[String: Any]]) ?? []
                let next = dict["next_cursor"] as? String
                return (blocks: blocks, nextCursor: (next?.isEmpty == false) ? next : nil)
            })
        }
    }

    /// GET /v1/blocks/{block_id}/children — auto-paginates and returns every
    /// block. Used by read_notion_page where we always want the full body.
    func listAllBlockChildren(blockId: String,
                              completion: @escaping (Result<[[String: Any]], NotionError>) -> Void) {
        var collected: [[String: Any]] = []
        func step(cursor: String?) {
            listBlockChildren(blockId: blockId, startCursor: cursor) { result in
                switch result {
                case .failure(let err):
                    completion(.failure(err))
                case .success(let page):
                    collected.append(contentsOf: page.blocks)
                    if let next = page.nextCursor {
                        step(cursor: next)
                    } else {
                        completion(.success(collected))
                    }
                }
            }
        }
        step(cursor: nil)
    }

    /// Same as listAllBlockChildren but also walks any block whose `has_children`
    /// is true (toggles, tables, callouts, columns, synced blocks, nested lists,
    /// …), attaching the resolved sub-blocks under a synthetic `_loop_children`
    /// key. The markdown renderer reads that key to inline content the flat
    /// listing would otherwise drop on the floor — table rows live as children
    /// of the table block, table contents live as children of toggles, etc.
    func listAllBlockChildrenRecursive(blockId: String,
                                       maxDepth: Int = 5,
                                       completion: @escaping (Result<[[String: Any]], NotionError>) -> Void) {
        listAllBlockChildren(blockId: blockId) { [weak self] result in
            guard let self else { completion(.success([])); return }
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success(let blocks):
                self.attachChildren(to: blocks, depthRemaining: maxDepth, completion: completion)
            }
        }
    }

    /// Walk `blocks` serially; for each entry with `has_children: true` recurse
    /// into the API and stash the result under `_loop_children`. Serial (not
    /// parallel) so we stay under Notion's ~3 req/s ceiling without bookkeeping.
    private func attachChildren(to blocks: [[String: Any]],
                                depthRemaining: Int,
                                completion: @escaping (Result<[[String: Any]], NotionError>) -> Void) {
        guard depthRemaining > 0 else { completion(.success(blocks)); return }
        var output = blocks
        func process(_ index: Int) {
            if index >= output.count { completion(.success(output)); return }
            let block = output[index]
            guard (block["has_children"] as? Bool) == true,
                  let id = block["id"] as? String, !id.isEmpty else {
                process(index + 1); return
            }
            self.listAllBlockChildren(blockId: id) { [weak self] result in
                switch result {
                case .failure(let err):
                    completion(.failure(err))
                case .success(let kids):
                    guard let self else { completion(.success(output)); return }
                    self.attachChildren(to: kids, depthRemaining: depthRemaining - 1) { recResult in
                        switch recResult {
                        case .failure(let err):
                            completion(.failure(err))
                        case .success(let withGrandkids):
                            var copy = block
                            copy["_loop_children"] = withGrandkids
                            output[index] = copy
                            process(index + 1)
                        }
                    }
                }
            }
        }
        process(0)
    }

    /// GET /v1/pages/{page_id}.
    func retrievePage(pageId: String,
                      completion: @escaping (Result<[String: Any], NotionError>) -> Void) {
        request(method: "GET",
                path: "/pages/\(idPathComponent(pageId))",
                body: nil,
                completion: completion)
    }

    /// POST /v1/pages. Requires a parent page id — Notion's API rejects
    /// pages with no parent unless the token has workspace-create scope, which
    /// internal integrations typically don't have.
    func createPage(title: String,
                    parentId: String,
                    children: [[String: Any]],
                    completion: @escaping (Result<[String: Any], NotionError>) -> Void) {
        let body: [String: Any] = [
            "parent": ["type": "page_id", "page_id": parentId],
            "properties": [
                "title": [
                    "title": [
                        ["type": "text", "text": ["content": title]]
                    ]
                ]
            ],
            "children": Array(children.prefix(Self.appendChunkSize))
        ]
        request(method: "POST", path: "/pages", body: body) { [weak self] result in
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success(let page):
                // Notion caps children at 100 per request. If the caller sent
                // more, append the remainder to the freshly-created page.
                let remainder = Array(children.dropFirst(Self.appendChunkSize))
                guard !remainder.isEmpty,
                      let pageId = page["id"] as? String,
                      let self else {
                    completion(.success(page)); return
                }
                self.appendBlockChildrenChunked(blockId: pageId, children: remainder) { appendResult in
                    switch appendResult {
                    case .failure(let err): completion(.failure(err))
                    case .success:          completion(.success(page))
                    }
                }
            }
        }
    }

    /// PATCH /v1/blocks/{block_id}/children — chunked to respect Notion's
    /// 100-block-per-request cap.
    func appendBlockChildrenChunked(blockId: String,
                                    children: [[String: Any]],
                                    completion: @escaping (Result<Void, NotionError>) -> Void) {
        guard !children.isEmpty else { completion(.success(())); return }
        let chunks = stride(from: 0, to: children.count, by: Self.appendChunkSize).map {
            Array(children[$0..<min($0 + Self.appendChunkSize, children.count)])
        }
        func step(index: Int) {
            if index >= chunks.count { completion(.success(())); return }
            let body: [String: Any] = ["children": chunks[index]]
            request(method: "PATCH",
                    path: "/blocks/\(idPathComponent(blockId))/children",
                    body: body) { result in
                switch result {
                case .failure(let err): completion(.failure(err))
                case .success:          step(index: index + 1)
                }
            }
        }
        step(index: 0)
    }

    /// PATCH /v1/pages/{page_id} — moves a page by rewriting its `parent`.
    func movePage(pageId: String,
                  newParentId: String,
                  completion: @escaping (Result<Void, NotionError>) -> Void) {
        let body: [String: Any] = [
            "parent": ["type": "page_id", "page_id": newParentId]
        ]
        request(method: "PATCH",
                path: "/pages/\(idPathComponent(pageId))",
                body: body) { result in
            completion(result.map { _ in () })
        }
    }

    // MARK: - Request plumbing

    private func request(method: String,
                         path: String,
                         body: [String: Any]?,
                         completion: @escaping (Result<[String: Any], NotionError>) -> Void) {
        guard let token = KeyStore.shared.value(for: .notionIntegrationToken),
              !token.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.notConnected)) }
            return
        }
        guard let url = URL(string: NotionClient.baseURL + path) else {
            DispatchQueue.main.async { completion(.failure(.transport)) }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(NotionClient.apiVersion, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            // The Notion API rejects requests with a body on GET, so we only
            // attach one when the caller actually provided fields.
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let task = session.dataTask(with: req) { data, response, error in
            // Bubble everything back on main to match SlackSkill / Cloud.
            DispatchQueue.main.async {
                if error != nil { completion(.failure(.transport)); return }
                guard let http = response as? HTTPURLResponse,
                      let data else { completion(.failure(.transport)); return }
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if (200..<300).contains(http.statusCode) {
                    completion(.success(json ?? [:]))
                } else {
                    let code = (json?["code"] as? String) ?? "http_\(http.statusCode)"
                    let message = (json?["message"] as? String) ?? "HTTP \(http.statusCode)"
                    completion(.failure(.api(status: http.statusCode, code: code, message: message)))
                }
            }
        }
        task.resume()
    }

    /// Notion ids are 32-char hex with optional dashes — both forms work in
    /// URLs, but percent-encode just in case the model passes something weird.
    private func idPathComponent(_ id: String) -> String {
        return id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }
}
