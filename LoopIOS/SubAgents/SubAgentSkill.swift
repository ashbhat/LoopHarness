//
//  SubAgentSkill.swift
//  Loop
//
//  Exposes `spawn_sub_agent`, `list_sub_agents`, and `cancel_sub_agent` to the
//  primary agent so it can intentionally delegate long-running work. Spawned
//  sub-agents run asynchronously; this skill returns immediately so the primary
//  conversation isn't blocked.
//

import Foundation

final class SubAgentSkill {
    static let shared = SubAgentSkill()
    private init() {}

    // MARK: - System prompt fragment

    static let systemPromptFragment: String = """
You can delegate long-running work to a sub-agent — an autonomous execution
context that runs in the background while you keep chatting with the user.

**Hard rule: code work always goes through a sub-agent.**
If the user asks you to write, edit, generate, refactor, or scaffold any code
(or any other "make me a thing" task — scripts, configs, snippets, etc.),
spawn a sub-agent with `kind: "coding"` instead of writing the code yourself.
This applies to:
- Any call to `file_write` (write or append mode) or `file_edit` on a code file.
- Any `run_terminal_command` that builds, tests, lints, formats, or runs code.
- Any "draft me a function / module / config / Dockerfile / SQL" request,
  no matter how short.
Reason: the sub-agent runs in its own context, can iterate (read → edit →
test → re-read) without consuming the user's primary turn budget, and posts
back a tight summary. Writing code in the primary chat bloats the user's
context window and makes follow-ups slower.

When else to spawn:
- Research tasks that need multiple searches + synthesis.
- Anything you expect to take more than ~30s of tool-heavy work.
- Anything the user explicitly asks you to "do in the background", "kick off",
  or "go research".

When NOT to spawn:
- A direct question you can answer from context (no tools needed).
- Read-only inspection (a single `file_read` or `file_list` to look something
  up before answering).
- Anything that needs a live back-and-forth with the user.

Tools:
- spawn_sub_agent: kick off a new sub-agent. Provide `task` (the prompt the
  sub-agent will execute) and `kind` ("research", "coding", or "general").
  Make the task self-contained — the sub-agent runs detached and can't ask
  for clarification. Include the workspace path you want it to work in, what
  success looks like, and any constraints (e.g. "use the existing venv at
  .venv", "don't touch files outside my-api/"). Returns the sub-agent id
  immediately. The user will see a runtime indicator at the top of the app;
  when the sub-agent finishes, its summary is posted back into the
  conversation as a normal assistant message.
- list_sub_agents: list active and recent sub-agents with their state and
  current step. Use when the user asks "what are you running?" or similar.
- cancel_sub_agent: stop a running sub-agent by `id`. Use when the user says
  "cancel that agent", "kill the sub-agent", "stop the background task", etc.
  If you don't know the id, call list_sub_agents first to find the active one,
  then call cancel_sub_agent with its id. Gracefully handles already-finished
  agents and invalid ids.

After spawning, tell the user briefly what you kicked off and that it'll
post back when done. Don't include the id in your reply.
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "spawn_sub_agent",
                "description": "Spawn a sub-agent that runs the given task in the background. Returns immediately; the sub-agent posts its summary into the conversation when done.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "task": [
                            "type": "string",
                            "description": "The full prompt the sub-agent should execute. Be specific — the sub-agent runs detached from this conversation and cannot ask clarifying questions."
                        ],
                        "kind": [
                            "type": "string",
                            "enum": ["research", "coding", "general"],
                            "description": "What kind of work the sub-agent is doing. Drives its system prompt and the icon shown in the runtime inspector."
                        ]
                    ],
                    "required": ["task"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_sub_agents",
                "description": "List active and recently-finished sub-agents with state, current step, and runtime.",
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "cancel_sub_agent",
                "description": "Cancel/stop a running sub-agent by id. Use list_sub_agents first if you need to find the id. Gracefully handles already-finished agents and invalid ids.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "The id of the sub-agent to cancel (from list_sub_agents)."
                        ]
                    ],
                    "required": ["id"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["spawn_sub_agent", "list_sub_agents", "cancel_sub_agent"]

    func handles(functionName: String) -> Bool {
        return SubAgentSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "spawn_sub_agent": return "spawning a sub-agent"
        case "list_sub_agents": return "checking on sub-agents"
        case "cancel_sub_agent": return "cancelling a sub-agent"
        default: return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "spawn_sub_agent":
            spawn(call: functionCall, completion: completion)
        case "list_sub_agents":
            list(completion: completion)
        case "cancel_sub_agent":
            cancel(call: functionCall, completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "Unknown sub-agent tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - spawn_sub_agent

    private func spawn(call: FunctionCallStruct,
                       completion: @escaping (MessageStruct) -> Void) {
        let args = call.arguments
        guard let task = (args["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !task.isEmpty else {
            completion(Self.functionMessage(
                name: "spawn_sub_agent",
                payload: ["status": "error", "error": "task is required"]
            ))
            return
        }
        let kind: SubAgentKind = {
            switch (args["kind"] as? String)?.lowercased() {
            case "research": return .research
            case "coding": return .coding
            default: return .general
            }
        }()
        // Resolve the parent conversation. Prefer the conversation id
        // stamped on the call by the dispatching coordinator — that's
        // the conversation the model was actually talking to when it
        // emitted spawn_sub_agent, which is the one the user expects to
        // receive the summary. The global `currentConversation` is the
        // fallback, but it follows the active tab on Mac and can drift
        // between spawn-call and dispatch-handler if the user switches
        // tabs mid-turn. Last-ditch: most-recent persisted, or mint a
        // fresh one so the result is never silently dropped.
        let manager = SimpleConversationManager.shared
        let parentId: String
        if let stamped = call.conversationId,
           manager.getConversation(by: stamped) != nil {
            parentId = stamped
        } else if let current = manager.currentConversation {
            parentId = current.id
        } else if let last = manager.loadLastConversation() {
            parentId = last.id
        } else {
            let fresh = manager.createConversation(title: "Sub-agent results")
            manager.currentConversation = fresh
            parentId = fresh.id
        }
        let agent = SubAgentManager.shared.spawn(task: task,
                                                  kind: kind,
                                                  parentConversationId: parentId)
        completion(Self.functionMessage(
            name: "spawn_sub_agent",
            payload: [
                "status": "spawned",
                "id": agent.id,
                "kind": kind.rawValue,
                "task": task,
                "message": "Sub-agent kicked off — will post its summary back into this conversation when done."
            ]
        ))
    }

    // MARK: - list_sub_agents

    private func list(completion: @escaping (MessageStruct) -> Void) {
        let agents = SubAgentManager.shared.allAgents
        let rows: [[String: Any]] = agents.map { agent -> [String: Any] in
            return [
                "id": agent.id,
                "task": agent.displayTitle,
                "kind": agent.kind.rawValue,
                "state": agent.state.rawValue,
                "step": agent.currentStep,
                "runtime_seconds": Int(agent.runtime)
            ]
        }
        completion(Self.functionMessage(
            name: "list_sub_agents",
            payload: ["count": rows.count, "sub_agents": rows]
        ))
    }

    // MARK: - cancel_sub_agent

    private func cancel(call: FunctionCallStruct,
                        completion: @escaping (MessageStruct) -> Void) {
        guard let id = (call.arguments["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            completion(Self.functionMessage(
                name: "cancel_sub_agent",
                payload: ["status": "error", "error": "id is required"]
            ))
            return
        }
        guard let agent = SubAgentManager.shared.agent(id: id) else {
            completion(Self.functionMessage(
                name: "cancel_sub_agent",
                payload: ["status": "error", "error": "No sub-agent found with id \(id)"]
            ))
            return
        }
        guard agent.isAlive else {
            completion(Self.functionMessage(
                name: "cancel_sub_agent",
                payload: [
                    "status": "already_done",
                    "id": id,
                    "state": agent.state.rawValue,
                    "message": "Sub-agent already finished (\(agent.state.rawValue))."
                ]
            ))
            return
        }
        SubAgentManager.shared.kill(id: id, reason: "Cancelled by user")
        completion(Self.functionMessage(
            name: "cancel_sub_agent",
            payload: [
                "status": "cancelled",
                "id": id,
                "message": "Sub-agent has been cancelled."
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
