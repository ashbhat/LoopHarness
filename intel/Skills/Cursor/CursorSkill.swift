//
//  CursorSkill.swift
//  Loop
//
//  Lets Loop hand a coding task to a Cursor cloud agent, which works on a
//  GitHub repo autonomously and opens a pull request. Thin tool wrapper —
//  `CursorAgentService` owns the dispatch, persistence, polling, and the
//  post-the-PR-link-back-into-the-conversation contract.
//
//  Tools the model sees:
//  - cursor_dispatch_agent: kick off an agent on a repo (returns immediately
//    with an agent id; the PR link auto-posts here when it finishes).
//  - cursor_check_agent: poll one dispatched agent on demand.
//  - cursor_list_agents: list the agents we're currently tracking.
//

import Foundation

struct CursorSkill {
    static let shared = CursorSkill()

    static let systemPromptFragment: String = """
You can delegate a coding task to a Cursor cloud agent. It runs autonomously on a GitHub repository and opens a pull request — use it when the user wants code written/changed and shipped as a PR, not for quick local edits (use the File System / Git tools for those).
- cursor_dispatch_agent: pass a clear, self-contained `task` and the `repository` (full GitHub URL, e.g. https://github.com/owner/name) — required every call; there is no default repo. Optional `ref` (base branch) and `auto_create_pr` (default true). Returns right away with an agent id; you do NOT wait — the agent's PR link is posted back into this conversation automatically when it's done.
- cursor_check_agent: pass `agent_id` to get the live status / PR link on demand.
- cursor_list_agents: list agents currently being tracked.

Important: the target repository must already be connected to the user's Cursor account/GitHub (done on Cursor's side). If a dispatch fails with an auth/permissions error, tell the user to connect the repo in Cursor. After dispatching, tell the user it's running and that you'll surface the PR link here when it lands — don't claim the PR exists yet.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "cursor_dispatch_agent",
                "description": "Hand a coding task to a Cursor cloud agent that works on a GitHub repo and opens a pull request. Returns immediately with an agent id; the PR link is posted back into the conversation when the agent finishes.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "task": [
                            "type": "string",
                            "description": "Clear, self-contained instruction for the coding agent (what to change and why)."
                        ],
                        "repository": [
                            "type": "string",
                            "description": "Full GitHub repository URL, e.g. https://github.com/owner/name. Required — there is no default."
                        ],
                        "ref": [
                            "type": "string",
                            "description": "Optional base branch/ref to start from (defaults to the repo's default branch)."
                        ],
                        "auto_create_pr": [
                            "type": "boolean",
                            "description": "Whether the agent should open a pull request when done (default true)."
                        ]
                    ],
                    "required": ["task", "repository"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "cursor_check_agent",
                "description": "Get the current status (and PR link, if ready) of a dispatched Cursor agent.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "agent_id": [
                            "type": "string",
                            "description": "The agent id returned by cursor_dispatch_agent."
                        ]
                    ],
                    "required": ["agent_id"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "cursor_list_agents",
                "description": "List the Cursor agents currently being tracked, with their status and PR link if available.",
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "cursor_dispatch_agent",
        "cursor_check_agent",
        "cursor_list_agents"
    ]

    func handles(functionName: String) -> Bool {
        return CursorSkill.toolNames.contains(functionName)
    }

    /// Shimmer label while a tool runs. nil when this skill doesn't own it.
    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "cursor_dispatch_agent":
            if let repo = call.arguments["repository"] as? String {
                return "dispatching Cursor on \(CursorAgentService.repoShortName(repo))"
            }
            return "dispatching a Cursor agent"
        case "cursor_check_agent":
            return "checking the Cursor agent"
        case "cursor_list_agents":
            return "listing Cursor agents"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        switch functionCall.name {
        case "cursor_dispatch_agent":
            dispatch(args: args, completion: completion)
        case "cursor_check_agent":
            check(args: args, completion: completion)
        case "cursor_list_agents":
            list(completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Cursor tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - cursor_dispatch_agent

    private func dispatch(args: [String: Any],
                          completion: @escaping (MessageStruct) -> Void) {
        guard let task = (args["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !task.isEmpty else {
            completion(Self.functionMessage("cursor_dispatch_agent",
                                            ["status": "error", "error": "task is required"]))
            return
        }
        guard let repository = (args["repository"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repository.isEmpty else {
            completion(Self.functionMessage("cursor_dispatch_agent",
                                            ["status": "error", "error": "repository (full GitHub URL) is required"]))
            return
        }
        let ref = (args["ref"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let autoCreatePR = (args["auto_create_pr"] as? Bool) ?? true

        // Resolve the conversation to post the PR link back into — same
        // resilient ordering SubAgentSkill uses (currentConversation →
        // last persisted → fresh) so the outcome never gets dropped.
        let manager = SimpleConversationManager.shared
        let conversationId: String
        if let current = manager.currentConversation {
            conversationId = current.id
        } else if let last = manager.loadLastConversation() {
            conversationId = last.id
        } else {
            let fresh = manager.createConversation(title: "Cursor results")
            manager.currentConversation = fresh
            conversationId = fresh.id
        }

        CursorAgentService.shared.dispatch(
            task: task,
            repository: repository,
            ref: (ref?.isEmpty == false) ? ref : nil,
            autoCreatePR: autoCreatePR,
            conversationId: conversationId
        ) { result in
            switch result {
            case .success(let job):
                completion(Self.functionMessage("cursor_dispatch_agent", [
                    "status": "dispatched",
                    "agent_id": job.agentId,
                    "repository": job.repository,
                    "dashboard_url": job.dashboardURL ?? "",
                    "message": "Cursor agent kicked off — it will work on the repo and the PR link will be posted back into this conversation when it finishes. Don't wait; let the user know it's running."
                ]))
            case .failure(let reason):
                completion(Self.functionMessage("cursor_dispatch_agent",
                                                ["status": "error", "error": reason]))
            }
        }
    }

    // MARK: - cursor_check_agent

    private func check(args: [String: Any],
                       completion: @escaping (MessageStruct) -> Void) {
        guard let id = (args["agent_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            completion(Self.functionMessage("cursor_check_agent",
                                            ["status": "error", "error": "agent_id is required"]))
            return
        }
        CursorAgentService.shared.refresh(agentId: id) { job in
            guard let job = job else {
                completion(Self.functionMessage("cursor_check_agent",
                                                ["status": "error",
                                                 "error": "No tracked Cursor agent with id \(id)"]))
                return
            }
            completion(Self.functionMessage("cursor_check_agent", Self.summary(job)))
        }
    }

    // MARK: - cursor_list_agents

    private func list(completion: @escaping (MessageStruct) -> Void) {
        let jobs = CursorAgentService.shared.loadJobs()
            .sorted { $0.createdAt > $1.createdAt }
        completion(Self.functionMessage("cursor_list_agents", [
            "count": jobs.count,
            "agents": jobs.map { Self.summary($0) }
        ]))
    }

    // MARK: - Helpers

    private static func summary(_ job: CursorAgentJob) -> [String: Any] {
        return [
            "agent_id": job.agentId,
            "repository": job.repository,
            "status": job.status,
            "pr_url": job.prURL ?? "",
            "dashboard_url": job.dashboardURL ?? ""
        ]
    }

    private static func functionMessage(_ name: String,
                                        _ payload: [String: Any]) -> MessageStruct {
        let content: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            content = str
        } else {
            content = "{\"status\":\"error\",\"error\":\"failed to encode result\"}"
        }
        return MessageStruct(role: "function", content: content, name: name)
    }
}
