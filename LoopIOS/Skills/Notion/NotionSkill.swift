//
//  NotionSkill.swift
//  Loop
//
//  Lets Loop drive the user's Notion through their own internal-integration
//  token (Settings → Keys → Notion Integration Token). All HTTP work happens
//  in NotionClient; markdown ↔ block conversion lives in NotionMarkdown.
//  This file just shapes args, calls NotionClient, and returns a
//  MessageStruct with role "function" so the model can react to results.
//

import Foundation

struct NotionSkill {
    static let shared = NotionSkill()

    /// System-prompt fragment describing the skill to the model. Concatenated
    /// into the chat system prompt so the model knows what tools it has.
    static let systemPromptFragment: String = """
You can manage the user's Notion through this set of tools:
- list_notion_pages: list child pages under a parent (omit parent_id to list every page the integration can see).
- create_notion_page: create a new page nested under another page. parent_id is required (Notion's API rejects pages with no parent).
- read_notion_page: read the markdown content of a page by id.
- append_to_notion_page: append markdown content to an existing page.
- move_notion_page: move a page to live under a new parent page.
- find_notion_page: search for pages by title query; returns matches with ids.

Workflow tips:
- Every page result includes a `url` field (e.g. `https://www.notion.so/<id>`).
  When you create or find a page, share that link back to the user as a
  markdown link like `[Page title](url)` so they can tap to open it.
- IDs come from list_notion_pages / find_notion_page / create_notion_page responses — chain calls when needed.
- When the user asks about a named page, use find_notion_page first to get the id, then read.
- If create_notion_page needs a parent_id and you don't have one, call list_notion_pages (no args) or find_notion_page first to discover one.
- If a tool returns `{"error":"notion_not_connected"}`, tell the user to paste their `ntn_…` integration token in Settings → Keys → Notion Integration Token.
- If a tool returns `{"error":"restricted_resource"}` or `{"error":"object_not_found"}`, the integration isn't shared on that page — tell the user to open the page in Notion → ••• → Connections → add the integration.
"""

    /// OpenAI-style function tool schemas the model will see in the chat
    /// request. Add new tools here and a matching case in `handle(...)`.
    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "list_notion_pages",
                "description": "List the child pages under a Notion parent page. Omit parent_id to list every page the integration can see (closest analogue to the workspace root).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "parent_id": [
                            "type": "string",
                            "description": "Optional Notion page id of the parent. Omit to list every page the integration has access to."
                        ]
                    ],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "create_notion_page",
                "description": "Create a new Notion page nested under another page. Optionally include initial markdown content. parent_id is required.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Title of the new page."
                        ],
                        "content": [
                            "type": "string",
                            "description": "Optional initial markdown content for the new page."
                        ],
                        "parent_id": [
                            "type": "string",
                            "description": "Notion page id of the parent. Required — Notion's API rejects pages with no parent. Use list_notion_pages or find_notion_page to discover one."
                        ]
                    ],
                    "required": ["title", "parent_id"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "read_notion_page",
                "description": "Read the markdown content of a Notion page by its id.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "page_id": [
                            "type": "string",
                            "description": "The Notion page id to read."
                        ]
                    ],
                    "required": ["page_id"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "append_to_notion_page",
                "description": "Append markdown content to the bottom of an existing Notion page.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "page_id": [
                            "type": "string",
                            "description": "The Notion page id to append to."
                        ],
                        "content": [
                            "type": "string",
                            "description": "Markdown content to append."
                        ]
                    ],
                    "required": ["page_id", "content"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "move_notion_page",
                "description": "Move a Notion page so that it becomes a child of a different parent page.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "page_id": [
                            "type": "string",
                            "description": "The Notion page id to move."
                        ],
                        "new_parent_id": [
                            "type": "string",
                            "description": "The Notion page id of the new parent."
                        ]
                    ],
                    "required": ["page_id", "new_parent_id"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "find_notion_page",
                "description": "Search Notion for pages whose title matches a query. Returns id + title for each match.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Title query to search for."
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        ]
    ]

    /// Names of every function this skill owns. Callers use this to decide
    /// whether to delegate a function call to the skill.
    static let toolNames: Set<String> = [
        "list_notion_pages",
        "create_notion_page",
        "read_notion_page",
        "append_to_notion_page",
        "move_notion_page",
        "find_notion_page"
    ]

    func handles(functionName: String) -> Bool {
        return NotionSkill.toolNames.contains(functionName)
    }

    /// Human-readable status string for the shimmer label while a tool runs.
    /// Returns nil when this skill doesn't own the call.
    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "list_notion_pages":
            return "browsing your Notion pages"
        case "create_notion_page":
            if let title = call.arguments["title"] as? String, !title.isEmpty {
                return "creating Notion page \(title)"
            }
            return "creating a Notion page"
        case "read_notion_page":
            return "reading Notion page"
        case "append_to_notion_page":
            return "writing to Notion"
        case "move_notion_page":
            return "moving Notion page"
        case "find_notion_page":
            if let q = call.arguments["query"] as? String, !q.isEmpty {
                return "searching Notion for \(q)"
            }
            return "searching Notion"
        default:
            return nil
        }
    }

    /// Dispatch a model-emitted function call. The completion always fires
    /// with a MessageStruct ready to be fed back through processMessage(...).
    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        switch functionCall.name {
        case "list_notion_pages":
            list_notion_pages(parentId: args["parent_id"] as? String, completion: completion)
        case "create_notion_page":
            guard let title = args["title"] as? String, !title.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "title")); return
            }
            create_notion_page(title: title,
                               content: args["content"] as? String,
                               parentId: args["parent_id"] as? String,
                               completion: completion)
        case "read_notion_page":
            guard let pageId = args["page_id"] as? String, !pageId.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "page_id")); return
            }
            read_notion_page(pageId: pageId, completion: completion)
        case "append_to_notion_page":
            guard let pageId = args["page_id"] as? String, !pageId.isEmpty,
                  let content = args["content"] as? String, !content.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "page_id, content")); return
            }
            append_to_notion_page(pageId: pageId, content: content, completion: completion)
        case "move_notion_page":
            guard let pageId = args["page_id"] as? String, !pageId.isEmpty,
                  let newParentId = args["new_parent_id"] as? String, !newParentId.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "page_id, new_parent_id")); return
            }
            move_notion_page(pageId: pageId, newParentId: newParentId, completion: completion)
        case "find_notion_page":
            guard let query = args["query"] as? String, !query.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "query")); return
            }
            find_notion_page(query: query, completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Notion tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handlers

    /// `list_notion_pages` — if `parentId` is given, list the page's direct
    /// children (filtering for `child_page` blocks). Otherwise call /search
    /// with no query so the model sees every page the integration can reach.
    private func list_notion_pages(parentId: String?,
                                   completion: @escaping (MessageStruct) -> Void) {
        if let parentId, !parentId.isEmpty {
            NotionClient.shared.listAllBlockChildren(blockId: parentId) { result in
                switch result {
                case .failure(let err):
                    completion(NotionSkill.errorMessage(for: "list_notion_pages", error: err))
                case .success(let blocks):
                    let pages: [[String: Any]] = blocks.compactMap { block in
                        guard (block["type"] as? String) == "child_page",
                              let id = block["id"] as? String else { return nil }
                        let title = (block["child_page"] as? [String: Any])?["title"] as? String ?? ""
                        return NotionSkill.withURL(["id": id, "title": title])
                    }
                    completion(NotionSkill.functionMessage(
                        name: "list_notion_pages",
                        payload: ["pages": pages]
                    ))
                }
            }
        } else {
            NotionClient.shared.search(query: nil, pageSize: 100) { result in
                switch result {
                case .failure(let err):
                    completion(NotionSkill.errorMessage(for: "list_notion_pages", error: err))
                case .success(let results):
                    let pages = NotionSkill.pageSummaries(from: results)
                    completion(NotionSkill.functionMessage(
                        name: "list_notion_pages",
                        payload: ["pages": pages]
                    ))
                }
            }
        }
    }

    private func create_notion_page(title: String,
                                    content: String?,
                                    parentId: String?,
                                    completion: @escaping (MessageStruct) -> Void) {
        guard let parentId, !parentId.isEmpty else {
            completion(NotionSkill.functionMessage(
                name: "create_notion_page",
                payload: [
                    "error": "missing_parent_id",
                    "hint": "Notion's API requires a parent page. Call list_notion_pages or find_notion_page first to discover one, then pass its id as parent_id."
                ]
            ))
            return
        }
        let children = (content?.isEmpty == false)
            ? NotionMarkdown.blocks(fromMarkdown: content!)
            : []
        NotionClient.shared.createPage(title: title,
                                       parentId: parentId,
                                       children: children) { result in
            switch result {
            case .failure(let err):
                completion(NotionSkill.errorMessage(for: "create_notion_page", error: err))
            case .success(let page):
                let enriched = NotionSkill.summarize(page: page, fallbackTitle: title)
                var payload: [String: Any] = ["status": "success", "page": enriched]
                if let url = enriched["url"] as? String { payload["url"] = url }
                completion(NotionSkill.functionMessage(
                    name: "create_notion_page",
                    payload: payload
                ))
            }
        }
    }

    private func read_notion_page(pageId: String,
                                  completion: @escaping (MessageStruct) -> Void) {
        // Resolve title + url from /pages, body from /blocks/{id}/children.
        NotionClient.shared.retrievePage(pageId: pageId) { metaResult in
            switch metaResult {
            case .failure(let err):
                completion(NotionSkill.errorMessage(for: "read_notion_page", error: err))
            case .success(let meta):
                NotionClient.shared.listAllBlockChildrenRecursive(blockId: pageId) { bodyResult in
                    switch bodyResult {
                    case .failure(let err):
                        completion(NotionSkill.errorMessage(for: "read_notion_page", error: err))
                    case .success(let blocks):
                        let markdown = NotionMarkdown.markdown(fromBlocks: blocks)
                        var payload = NotionSkill.summarize(page: meta, fallbackTitle: "")
                        payload["content"] = markdown
                        completion(NotionSkill.functionMessage(
                            name: "read_notion_page",
                            payload: payload
                        ))
                    }
                }
            }
        }
    }

    private func append_to_notion_page(pageId: String,
                                       content: String,
                                       completion: @escaping (MessageStruct) -> Void) {
        let children = NotionMarkdown.blocks(fromMarkdown: content)
        guard !children.isEmpty else {
            completion(NotionSkill.functionMessage(
                name: "append_to_notion_page",
                payload: ["status": "no_op", "message": "Markdown was empty — nothing appended."]
            ))
            return
        }
        NotionClient.shared.appendBlockChildrenChunked(blockId: pageId, children: children) { result in
            switch result {
            case .failure(let err):
                completion(NotionSkill.errorMessage(for: "append_to_notion_page", error: err))
            case .success:
                completion(NotionSkill.functionMessage(
                    name: "append_to_notion_page",
                    payload: ["status": "success",
                              "message": "Appended \(children.count) block\(children.count == 1 ? "" : "s")."]
                ))
            }
        }
    }

    private func move_notion_page(pageId: String,
                                  newParentId: String,
                                  completion: @escaping (MessageStruct) -> Void) {
        NotionClient.shared.movePage(pageId: pageId, newParentId: newParentId) { result in
            switch result {
            case .failure(let err):
                completion(NotionSkill.errorMessage(for: "move_notion_page", error: err))
            case .success:
                completion(NotionSkill.functionMessage(
                    name: "move_notion_page",
                    payload: ["status": "success", "message": "Page moved."]
                ))
            }
        }
    }

    private func find_notion_page(query: String,
                                  completion: @escaping (MessageStruct) -> Void) {
        NotionClient.shared.search(query: query, pageSize: 20) { result in
            switch result {
            case .failure(let err):
                completion(NotionSkill.errorMessage(for: "find_notion_page", error: err))
            case .success(let results):
                completion(NotionSkill.functionMessage(
                    name: "find_notion_page",
                    payload: ["results": NotionSkill.pageSummaries(from: results)]
                ))
            }
        }
    }

    // MARK: - Response shaping

    /// Trim a full Notion page object down to the id/title/url shape the model
    /// has been seeing. Title comes from the `title` property's rich_text;
    /// fall back to the supplied label (used right after create when the user
    /// gave us a title) and finally to "Untitled".
    private static func summarize(page: [String: Any], fallbackTitle: String) -> [String: Any] {
        let id = (page["id"] as? String) ?? ""
        var out: [String: Any] = ["id": id]
        let title = titleFromProperties(page["properties"]) ?? fallbackTitle
        out["title"] = title.isEmpty ? "Untitled" : title
        if let url = page["url"] as? String, !url.isEmpty {
            out["url"] = url
        } else if let derived = notionURL(forPageId: id) {
            out["url"] = derived
        }
        return out
    }

    private static func pageSummaries(from results: [[String: Any]]) -> [[String: Any]] {
        return results.compactMap { obj in
            guard (obj["object"] as? String) == "page" else { return nil }
            return summarize(page: obj, fallbackTitle: "")
        }
    }

    private static func titleFromProperties(_ raw: Any?) -> String? {
        guard let props = raw as? [String: Any] else { return nil }
        // Find whichever property has type:"title" — its key is usually
        // "title" or "Name" but can be anything if the schema renamed it.
        for value in props.values {
            guard let prop = value as? [String: Any],
                  (prop["type"] as? String) == "title",
                  let segments = prop["title"] as? [[String: Any]] else { continue }
            let text = segments.compactMap { seg -> String? in
                if let plain = seg["plain_text"] as? String { return plain }
                if let inner = seg["text"] as? [String: Any],
                   let content = inner["content"] as? String { return content }
                return nil
            }.joined()
            return text
        }
        return nil
    }

    // MARK: - URL helpers
    //
    // Notion page URLs are deterministic from the page id: strip dashes and
    // prepend `https://www.notion.so/`. We prefer the `url` Notion returns
    // (which includes a slug) but fall back to deriving one when missing.

    /// Build a notion.so URL from a Notion page id (with or without dashes).
    /// Returns nil if the id doesn't look like a 32-char hex string.
    static func notionURL(forPageId rawId: String) -> String? {
        let stripped = rawId.replacingOccurrences(of: "-", with: "")
        guard stripped.count == 32,
              stripped.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return "https://www.notion.so/\(stripped)"
    }

    /// Add a `url` field to a page dict if missing. Kept for SpecBuilderSkill,
    /// which still constructs its own minimal page dict.
    static func withURL(_ page: [String: Any]) -> [String: Any] {
        var out = page
        if (out["url"] as? String)?.isEmpty == false { return out }
        let id = (out["id"] as? String) ?? (out["page_id"] as? String) ?? ""
        if !id.isEmpty, let url = notionURL(forPageId: id) {
            out["url"] = url
        }
        return out
    }

    // MARK: - Message helpers

    private func missingArgs(for name: String, expected: String) -> MessageStruct {
        return MessageStruct(
            role: "assistant",
            content: "I need \(expected) to call \(name). Please provide them."
        )
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

    private static func errorMessage(for tool: String,
                                     error: NotionClient.NotionError) -> MessageStruct {
        let payload: [String: Any] = [
            "error": error.code,
            "hint": error.hint
        ]
        return functionMessage(name: tool, payload: payload)
    }
}
