//
//  ExaSkill.swift
//  Loop
//
//  Built from LoopIOS/Specs/spec_exa.md.
//

import Foundation

/// Lets Loop search the web and read web page contents through Exa
/// (https://exa.ai). Implemented locally — calls Exa's REST API directly
/// from the device using the EXA_API_KEY in Info.plist, so this skill does
/// not depend on the backend.
///
/// Tools the model sees:
/// - exa_search: natural-language web search; returns title, url, and a
///   short snippet for each result.
/// - exa_get_contents: fetch the full text of one or more URLs (or Exa
///   result ids) so the model can quote/summarize them.
/// - exa_list_websets: list the user's Exa Websets.
///
/// Typical flow: exa_search → pick result(s) → exa_get_contents → answer.
struct ExaSkill {
    static let shared = ExaSkill()

    private static let baseURL = "https://api.exa.ai"

    static let systemPromptFragment: String = """
You can search and read the web through Exa with these tools:
- exa_search: natural-language web search. Pass a `query` and optional `num_results` (default 3, max 5). Returns a small list of {title, url, snippet}.
- exa_get_contents: fetch a short readable excerpt of a page. Pass exactly one url in `urls` per call — do not batch. Call again for additional pages only if needed.
- exa_list_websets: list the user's Exa Websets (curated collections).

Workflow tips:
- Snippets are intentionally short; if you need more, follow up with exa_get_contents on the single most relevant url, then answer.
- Keep payloads small — avoid asking for many results or many urls at once.
- Cite the url(s) you used in your reply so the user can verify.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "exa_search",
                "description": "Search the web with Exa using a natural-language query. Returns title, url, and a short snippet for each result.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Natural-language search query."
                        ],
                        "num_results": [
                            "type": "integer",
                            "description": "How many results to return (default 3, max 5)."
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "exa_get_contents",
                "description": "Fetch a short readable excerpt of one web page via Exa. Pass exactly one URL in `urls` per call.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "urls": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "URLs to fetch — pass one at a time. Also accepts Exa result ids from a prior exa_search."
                        ]
                    ],
                    "required": ["urls"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "exa_list_websets",
                "description": "List the user's Exa Websets (curated collections). Returns id, name, and creation time for each.",
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "exa_search",
        "exa_get_contents",
        "exa_list_websets"
    ]

    func handles(functionName: String) -> Bool {
        return ExaSkill.toolNames.contains(functionName)
    }

    /// Human-readable status string for the shimmer label while a tool runs.
    /// Returns nil when this skill doesn't own the call.
    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "exa_search":
            if let q = (call.arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !q.isEmpty {
                return "searching for \(q)"
            }
            return "searching the web"
        case "exa_get_contents":
            if let urls = call.arguments["urls"] as? [String], let first = urls.first,
               let host = URL(string: first)?.host {
                return "reading \(host)"
            }
            return "reading through results"
        case "exa_list_websets":
            return "loading your Websets"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        // Short-circuit before any network call if the user hasn't configured
        // an Exa key yet — return a function-role message that prompts the
        // model to explain the situation and offer to store one securely.
        if ExaSkill.apiKey == nil {
            completion(ExaSkill.noApiKeyMessage(for: functionCall.name))
            return
        }
        let args = functionCall.arguments
        switch functionCall.name {
        case "exa_search":
            guard let query = args["query"] as? String, !query.isEmpty else {
                completion(missingArgs(for: "exa_search", expected: "query"))
                return
            }
            let n = intArg(args["num_results"]) ?? 3
            exa_search(query: query, numResults: max(1, min(5, n)), completion: completion)
        case "exa_get_contents":
            let urls = (args["urls"] as? [String]) ?? []
            let ids = (args["ids"] as? [String]) ?? []
            guard !urls.isEmpty || !ids.isEmpty else {
                completion(missingArgs(for: "exa_get_contents", expected: "urls or ids"))
                return
            }
            exa_get_contents(urls: urls, ids: ids, completion: completion)
        case "exa_list_websets":
            exa_list_websets(completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Exa tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handlers

    private func exa_search(query: String,
                            numResults: Int,
                            completion: @escaping (MessageStruct) -> Void) {
        let body: [String: Any] = [
            "query": query,
            "type": "auto",
            "numResults": numResults,
            // Ask Exa for a brief inline snippet so the model has a hook
            // without us having to call /contents for every result.
            "contents": [
                "text": ["maxCharacters": 240]
            ]
        ]
        post(path: "/search", body: body) { json, error in
            guard let json = json,
                  let results = json["results"] as? [[String: Any]] else {
                completion(ExaSkill.errorMessage("I was unable to search Exa.", error: error))
                return
            }
            // Plain-text payload. Stringified JSON in the function content
            // was being rejected by some models.
            var lines: [String] = ["Search results for \"\(query)\":"]
            for (i, r) in results.enumerated() {
                let title = ExaSkill.truncate((r["title"] as? String) ?? "(no title)", to: 140)
                let url = (r["url"] as? String) ?? ""
                // Per Exa docs: results carry `text` when contents were
                // requested, `snippet` otherwise. Take whichever is present.
                let raw = (r["text"] as? String) ?? (r["snippet"] as? String) ?? ""
                let snippet = ExaSkill.truncate(raw, to: 240)
                var entry = "\(i + 1). \(title)\n   \(url)"
                if !snippet.isEmpty { entry += "\n   \(snippet)" }
                lines.append(entry)
            }
            completion(MessageStruct(
                role: "function",
                content: lines.joined(separator: "\n\n"),
                name: "exa_search"
            ))
        }
    }

    private func exa_get_contents(urls: [String],
                                  ids: [String],
                                  completion: @escaping (MessageStruct) -> Void) {
        // Per Exa /contents docs: the `urls` field is the single accepted
        // input and is backward-compatible with ids — it accepts both raw
        // URLs and Exa result ids. Merge them into one array.
        let combined = Array((urls + ids).prefix(2))

        let body: [String: Any] = [
            "urls": combined,
            // Server-side truncation so we don't pay for bytes we'd discard.
            "text": ["maxCharacters": 2000]
        ]

        post(path: "/contents", body: body) { json, error in
            guard let json = json,
                  let results = json["results"] as? [[String: Any]] else {
                completion(ExaSkill.errorMessage("I was unable to fetch contents from Exa.", error: error))
                return
            }
            var sections: [String] = []
            for r in results {
                let url = (r["url"] as? String) ?? ""
                let title = ExaSkill.truncate((r["title"] as? String) ?? "", to: 140)
                let text = ExaSkill.truncate((r["text"] as? String) ?? "", to: 2000)
                var section = "URL: \(url)"
                if !title.isEmpty { section += "\nTitle: \(title)" }
                section += "\n---\n\(text)"
                sections.append(section)
            }
            let body = sections.isEmpty ? "No content returned." : sections.joined(separator: "\n\n===\n\n")
            completion(MessageStruct(
                role: "function",
                content: body,
                name: "exa_get_contents"
            ))
        }
    }

    private func exa_list_websets(completion: @escaping (MessageStruct) -> Void) {
        get(path: "/websets/v0/websets") { json, error in
            guard let json = json else {
                completion(ExaSkill.errorMessage("I was unable to list Exa Websets.", error: error))
                return
            }
            // Per Websets docs: response is `{ data: [...], hasMore, nextCursor }`
            // and each webset has `title` (not `name`).
            let raw = (json["data"] as? [[String: Any]]) ?? []
            var lines: [String] = ["Websets (\(raw.count)):"]
            for w in raw {
                let id = (w["id"] as? String) ?? ""
                let title = (w["title"] as? String) ?? "(untitled)"
                let status = (w["status"] as? String).map { " — \($0)" } ?? ""
                lines.append("- \(title)\(status) [id: \(id)]")
            }
            completion(MessageStruct(
                role: "function",
                content: raw.isEmpty ? "No websets found." : lines.joined(separator: "\n"),
                name: "exa_list_websets"
            ))
        }
    }

    // MARK: - HTTP

    private static var apiKey: String? {
        return KeyStore.shared.value(for: .exa)
    }

    private func post(path: String,
                      body: [String: Any],
                      completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard let apiKey = ExaSkill.apiKey else {
            completion(nil, NSError(domain: "ExaSkill", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "No Exa API key configured."]))
            return
        }
        guard let url = URL(string: ExaSkill.baseURL + path) else {
            completion(nil, NSError(domain: "ExaSkill", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "Bad Exa URL"]))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        URLSession.shared.dataTask(with: request) { data, response, error in
            ExaSkill.parse(data: data, response: response, error: error, completion: completion)
        }.resume()
    }

    private func get(path: String,
                     completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard let apiKey = ExaSkill.apiKey else {
            completion(nil, NSError(domain: "ExaSkill", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "No Exa API key configured."]))
            return
        }
        guard let url = URL(string: ExaSkill.baseURL + path) else {
            completion(nil, NSError(domain: "ExaSkill", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "Bad Exa URL"]))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        URLSession.shared.dataTask(with: request) { data, response, error in
            ExaSkill.parse(data: data, response: response, error: error, completion: completion)
        }.resume()
    }

    private static func parse(data: Data?,
                              response: URLResponse?,
                              error: Error?,
                              completion: @escaping ([String: Any]?, Error?) -> Void) {
        if let error = error {
            completion(nil, error)
            return
        }
        guard let data = data else {
            completion(nil, NSError(domain: "ExaSkill", code: -3,
                                    userInfo: [NSLocalizedDescriptionKey: "Empty Exa response"]))
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            completion(nil, NSError(domain: "ExaSkill", code: status,
                                    userInfo: [NSLocalizedDescriptionKey: "Exa returned non-JSON (status \(status)): \(snippet)"]))
            return
        }
        if status >= 400 {
            let msg = (json["error"] as? String)
                ?? (json["message"] as? String)
                ?? "Exa request failed (status \(status))"
            completion(nil, NSError(domain: "ExaSkill", code: status,
                                    userInfo: [NSLocalizedDescriptionKey: msg]))
            return
        }
        completion(json, nil)
    }

    // MARK: - Helpers

    private func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func missingArgs(for name: String, expected: String) -> MessageStruct {
        return MessageStruct(
            role: "assistant",
            content: "I need \(expected) to call \(name). Please provide them."
        )
    }

    private static func truncate(_ s: String, to max: Int) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx]) + "…"
    }

    private static func errorMessage(_ prefix: String, error: Error?) -> MessageStruct {
        let detail = error?.localizedDescription ?? "Unknown error"
        return MessageStruct(role: "assistant", content: "\(prefix) \(detail)")
    }

    /// Returned as the function result when no Exa API key is configured.
    /// Sent as a function-role message so the model phrases the ask to the
    /// user instead of us hard-coding a string into the chat.
    private static func noApiKeyMessage(for functionName: String) -> MessageStruct {
        let content = KeyStore.missingKeyInstruction(
            for: [.exa],
            purpose: "web search (Exa). A free key is available at https://exa.ai"
        )
        return MessageStruct(role: "function", content: content, name: functionName)
    }
}
