//
//  SpecBuilderSkill.swift
//  Loop
//
//  Built from LoopIOS/Specs/spec_builder_spec.md.
//
//  Drives an interactive "let's write a spec" flow. The model interviews the
//  user using the meta_spec layout (Context, Guidance, Key Result), then
//  publishes the finished markdown as a Notion page via
//  `publish_spec_to_notion`. The publish tool calls NotionClient directly with
//  the user's integration token (see Settings → Keys → Notion Integration
//  Token) and returns a notion.so URL so the model can share it back as a
//  tappable markdown link.
//

import Foundation

struct SpecBuilderSkill {
    static let shared = SpecBuilderSkill()

    // MARK: - System prompt fragment

    static let systemPromptFragment: String = """
You can help the user author new specs for Loop itself. A spec follows the
meta_spec template:

```
# <Title> Spec

**Context**
<1–2 paragraphs describing what this feature is and why it exists.>

**Guidance**
<Bulleted or prose-level direction for the engineer/agent who will build it.>

**Key Result**
The key result is when the feature makes this user story true

(A) ...
(B) ...
(C) ...
```

When the user asks to "write a spec", "draft a spec", "build a spec", or
similar, run this interview:

1. Confirm the topic in one sentence ("So we're speccing X — yes?").
2. Draft the **Context** together. Ask what problem it solves and who uses it.
   Propose draft language; let the user redline.
3. Draft the **Guidance**. Ask what the implementation should touch (files,
   tools, integrations). Keep it actionable, not exhaustive.
4. Draft the **Key Result** as a numbered user story (A, B, C, …). Each step
   should be observable behavior, not internal mechanics.
5. Show the assembled markdown and ask "ready to publish?"
6. On confirmation, call `publish_spec_to_notion(title, content, parent_id)`.
   The response includes a `url` — share it back to the user as a markdown
   link like `[Title Spec](url)`.

Tips:
- Brainstorm when the user is fuzzy — offer 2–3 angles and let them pick.
- Keep one section in focus at a time; don't dump the whole template at once.
- Notion's API requires a parent — before publishing, ask the user where the
  spec should live (e.g. "under your 'Specs' page?") and use `find_notion_page`
  or `list_notion_pages` to get the parent's id, then pass it as `parent_id`.
- If publishing returns `{"error":"notion_not_connected"}`, tell the user to
  paste their `ntn_…` integration token in Settings → Keys → Notion
  Integration Token before retrying.
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "publish_spec_to_notion",
                "description": "Publish a finished spec as a new Notion page. Pass the full markdown body as `content`. Returns the new page id and a notion.so url which you should share back to the user as a markdown link.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Title of the spec page (e.g. 'Calendar Skill Spec')."
                        ],
                        "content": [
                            "type": "string",
                            "description": "Full markdown body of the spec, following the meta_spec template (Context, Guidance, Key Result)."
                        ],
                        "parent_id": [
                            "type": "string",
                            "description": "Notion page id to nest under. Required — Notion's API rejects pages with no parent. Use find_notion_page or list_notion_pages to discover one."
                        ]
                    ],
                    "required": ["title", "content", "parent_id"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "publish_spec_to_notion"
    ]

    func handles(functionName: String) -> Bool {
        return SpecBuilderSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "publish_spec_to_notion":
            if let title = call.arguments["title"] as? String, !title.isEmpty {
                return "publishing \(title) to Notion"
            }
            return "publishing spec to Notion"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "publish_spec_to_notion":
            publishSpec(args: functionCall.arguments, completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the spec-builder tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handlers

    private func publishSpec(args: [String: Any],
                             completion: @escaping (MessageStruct) -> Void) {
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            completion(SpecBuilderSkill.functionMessage(
                name: "publish_spec_to_notion",
                payload: ["status": "error", "error": "title is required"]
            ))
            return
        }
        guard let content = args["content"] as? String, !content.isEmpty else {
            completion(SpecBuilderSkill.functionMessage(
                name: "publish_spec_to_notion",
                payload: ["status": "error", "error": "content is required"]
            ))
            return
        }
        guard let parentId = (args["parent_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentId.isEmpty else {
            completion(SpecBuilderSkill.functionMessage(
                name: "publish_spec_to_notion",
                payload: [
                    "status": "error",
                    "error": "missing_parent_id",
                    "hint": "Notion's API requires a parent page. Use find_notion_page or list_notion_pages to discover one, then pass its id as parent_id."
                ]
            ))
            return
        }

        let children = NotionMarkdown.blocks(fromMarkdown: content)
        NotionClient.shared.createPage(title: title,
                                       parentId: parentId,
                                       children: children) { result in
            switch result {
            case .success(let page):
                let id = (page["id"] as? String) ?? ""
                let url = (page["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? SpecBuilderSkill.notionURL(forPageId: id)
                    ?? ""
                var payload: [String: Any] = [
                    "status": "success",
                    "title": title,
                    "page": page
                ]
                if !id.isEmpty { payload["id"] = id }
                if !url.isEmpty { payload["url"] = url }
                completion(SpecBuilderSkill.functionMessage(
                    name: "publish_spec_to_notion",
                    payload: payload
                ))
            case .failure(let err):
                completion(SpecBuilderSkill.functionMessage(
                    name: "publish_spec_to_notion",
                    payload: ["status": "error",
                              "error": err.code,
                              "hint": err.hint]
                ))
            }
        }
    }

    // MARK: - Helpers

    private static func notionURL(forPageId rawId: String) -> String? {
        let stripped = rawId.replacingOccurrences(of: "-", with: "")
        guard stripped.count == 32,
              stripped.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "https://www.notion.so/\(stripped)"
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
}
