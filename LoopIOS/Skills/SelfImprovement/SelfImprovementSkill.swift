//
//  SelfImprovementSkill.swift
//  Loop
//
//  Built from LoopIOS/Specs/self_improvment_spec.md.
//
//  Lets the agent rewrite its own context — SOUL, USER, MEMORY, AGENTS,
//  HEARTBEAT — during a conversation. Each tool call mutates the live copy
//  on AgentHarness.shared and persists to a markdown file under
//  Documents/loop_self/, so the next chat (and the next cold start) sees
//  the updated content.
//

import Foundation

final class SelfImprovementSkill {
    static let shared = SelfImprovementSkill()

    // MARK: - System prompt fragment

    static let systemPromptFragment: String = """
You can rewrite your own context — the SOUL, USER, MEMORY, AGENTS, and HEARTBEAT
sections at the top of this system prompt are living documents. When you learn
something durable about the user or yourself, persist it with these tools:

- update_self_doc(name, content): replace one of the docs with new markdown.
  - "soul" — your identity, tone, values. Update when the user changes how they
    want you to behave ("use you to manage my life" → broaden your role).
  - "user" — facts about the human. Update when you learn their name, location,
    preferences, job, etc.
  - "memory" — long-term knowledge, decisions, key facts you should remember
    across sessions.
  - "agents" — operational rules / playbook for how you work.
  - "heartbeat" — what to do when idle or on a periodic check-in.
  - Pass the FULL new contents of the doc, not a diff. Preserve anything
    already there that's still relevant.
- read_self_doc(name): re-read a doc verbatim if you need to see it before
  updating. (The current contents are already in the system prompt above, so
  you usually don't need this.)

Update silently when something natural to remember comes up — don't ask the
user for permission. After updating, briefly acknowledge what you saved
("Got it, I'll remember that").
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "update_self_doc",
                "description": "Replace one of the agent's self-context markdown documents (soul, user, memory, agents, heartbeat) with new content. Pass the full document body — not a diff.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "enum": ["soul", "user", "memory", "agents", "heartbeat"],
                            "description": "Which document to update."
                        ],
                        "content": [
                            "type": "string",
                            "description": "The full new markdown content for the document. Preserve anything previously there that's still relevant."
                        ]
                    ],
                    "required": ["name", "content"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "read_self_doc",
                "description": "Read the current contents of one of the self-context documents.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "enum": ["soul", "user", "memory", "agents", "heartbeat"],
                            "description": "Which document to read."
                        ]
                    ],
                    "required": ["name"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "update_self_doc",
        "read_self_doc"
    ]

    func handles(functionName: String) -> Bool {
        return SelfImprovementSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "update_self_doc":
            if let name = call.arguments["name"] as? String {
                return "updating \(name).md"
            }
            return "updating self context"
        case "read_self_doc":
            if let name = call.arguments["name"] as? String {
                return "reading \(name).md"
            }
            return "reading self context"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "update_self_doc":
            update_self_doc(args: functionCall.arguments, completion: completion)
        case "read_self_doc":
            read_self_doc(args: functionCall.arguments, completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the self-improvement tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handlers

    private func update_self_doc(args: [String: Any],
                                 completion: @escaping (MessageStruct) -> Void) {
        guard let rawName = args["name"] as? String,
              let doc = AgentHarness.SelfDoc(rawValue: rawName.lowercased()) else {
            completion(SelfImprovementSkill.functionMessage(
                name: "update_self_doc",
                payload: ["status": "error",
                          "error": "name must be one of: soul, user, memory, agents, heartbeat"]
            ))
            return
        }
        guard let content = args["content"] as? String else {
            completion(SelfImprovementSkill.functionMessage(
                name: "update_self_doc",
                payload: ["status": "error",
                          "error": "content (full markdown body) is required"]
            ))
            return
        }

        AgentHarness.shared.updateSelfDoc(doc, content: content)

        completion(SelfImprovementSkill.functionMessage(
            name: "update_self_doc",
            payload: [
                "status": "success",
                "name": doc.rawValue,
                "bytes": content.count,
                "message": "Updated \(doc.rawValue).md — the next message will use the new content."
            ]
        ))
    }

    private func read_self_doc(args: [String: Any],
                               completion: @escaping (MessageStruct) -> Void) {
        guard let rawName = args["name"] as? String,
              let doc = AgentHarness.SelfDoc(rawValue: rawName.lowercased()) else {
            completion(SelfImprovementSkill.functionMessage(
                name: "read_self_doc",
                payload: ["status": "error",
                          "error": "name must be one of: soul, user, memory, agents, heartbeat"]
            ))
            return
        }

        let content = AgentHarness.shared.readSelfDoc(doc)
        completion(SelfImprovementSkill.functionMessage(
            name: "read_self_doc",
            payload: [
                "status": "success",
                "name": doc.rawValue,
                "content": content
            ]
        ))
    }

    // MARK: - Helpers

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
