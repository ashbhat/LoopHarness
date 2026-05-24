//
//  DevinSkill.swift
//  Loop
//
//  Lets Loop hand a coding task to a Devin cloud agent, which works on a
//  GitHub repo autonomously and opens a pull request. Thin tool wrapper —
//  `DevinAgentService` owns the dispatch, persistence, polling, post-back,
//  and the live transcript the user can inspect from Settings ▸ Subagents.
//
//  Tools the model sees:
//  - devin_dispatch_agent: kick off a Devin session (returns immediately with
//    a session id; the PR link auto-posts here when it finishes).
//  - devin_check_agent: poll one dispatched session on demand.
//  - devin_list_agents: list the sessions we're currently tracking.
//

import Foundation

struct DevinSkill {
    static let shared = DevinSkill()

    static let systemPromptFragment: String = """
You can delegate a coding task to a Devin cloud agent (Devin v3 API). It runs autonomously, can work on a GitHub repository, and opens a pull request — use it when the user wants code written/changed and shipped as a PR, not for quick local edits (use the File System / Git tools for those).
- devin_dispatch_agent: pass a clear, self-contained `task` (the prompt Devin will work on). Optional `repository` (e.g. "owner/name" or full GitHub URL) — Devin uses this to pick the right repo. Optional `title` (short label shown in lists) and `tags` (array of strings). Returns right away with a session id; you do NOT wait — the PR link is posted back into this conversation automatically when Devin finishes.
- devin_check_agent: pass `session_id` to get the live status / PR link on demand.
- devin_list_agents: list Devin sessions currently being tracked.

Setup: Devin v3 needs TWO things — a cog_… service-user API key and an org-… Organization ID. Both go in Settings ▸ Integrations ▸ Devin.AI (or Keys). If a dispatch fails with a "Devin … missing" error, surface that message verbatim and tell the user to set the missing field.
Important: the target repository must already be connected to the user's Devin workspace (done on Devin's side). After dispatching, tell the user it's running and that they can tap the Subagents cell in Settings to watch the live transcript; the PR link will land in this chat when Devin is done. Don't claim the PR exists yet.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "devin_dispatch_agent",
                "description": "Hand a coding task to a Devin cloud agent that works on a GitHub repo and opens a pull request. Returns immediately with a session id; the PR link is posted back into the conversation when the agent finishes.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "task": [
                            "type": "string",
                            "description": "Clear, self-contained instruction for the coding agent (what to change and why). Mention the repository URL in the prompt if relevant."
                        ],
                        "repository": [
                            "type": "string",
                            "description": "Optional repository hint. Pass `owner/name` (e.g. `cognition-ai/devin`) — Devin v3 takes this as the repos parameter on session create. A full GitHub URL also works; both formats are sent through. Used to label the row in the Subagents list too."
                        ],
                        "title": [
                            "type": "string",
                            "description": "Optional short label shown in the Subagents list and at the top of the live view. If omitted, the task is used as the row title."
                        ],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional list of tags Devin will attach to the session."
                        ]
                    ],
                    "required": ["task"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "devin_check_agent",
                "description": "Get the current status (and PR link, if ready) of a dispatched Devin session.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "session_id": [
                            "type": "string",
                            "description": "The session id returned by devin_dispatch_agent."
                        ]
                    ],
                    "required": ["session_id"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "devin_list_agents",
                "description": "List the Devin sessions currently being tracked, with their status and PR link if available.",
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "devin_dispatch_agent",
        "devin_check_agent",
        "devin_list_agents"
    ]

    func handles(functionName: String) -> Bool {
        return DevinSkill.toolNames.contains(functionName)
    }

    /// Shimmer label while a tool runs. nil when this skill doesn't own it.
    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "devin_dispatch_agent":
            if let repo = call.arguments["repository"] as? String, !repo.isEmpty {
                return "dispatching Devin on \(Self.repoShortName(repo))"
            }
            return "dispatching a Devin agent"
        case "devin_check_agent":
            return "checking the Devin agent"
        case "devin_list_agents":
            return "listing Devin agents"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        switch functionCall.name {
        case "devin_dispatch_agent":
            dispatch(args: args, completion: completion)
        case "devin_check_agent":
            check(args: args, completion: completion)
        case "devin_list_agents":
            list(completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Devin tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - devin_dispatch_agent

    private func dispatch(args: [String: Any],
                          completion: @escaping (MessageStruct) -> Void) {
        guard let task = (args["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !task.isEmpty else {
            completion(Self.functionMessage("devin_dispatch_agent",
                                            ["status": "error", "error": "task is required"]))
            return
        }
        let repository = (args["repository"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = args["tags"] as? [String]

        // Resolve the conversation to post the PR link back into — same
        // resilient ordering CursorSkill uses so the outcome never gets
        // dropped if the user switches threads mid-flight.
        let manager = SimpleConversationManager.shared
        let conversationId: String
        if let current = manager.currentConversation {
            conversationId = current.id
        } else if let last = manager.loadLastConversation() {
            conversationId = last.id
        } else {
            let fresh = manager.createConversation(title: "Devin results")
            manager.currentConversation = fresh
            conversationId = fresh.id
        }

        // Mention the repo in the prompt so Devin has it directly, then also
        // store it on the job for the list-row label.
        let prompt: String = {
            if let repo = repository, !repo.isEmpty, !task.contains(repo) {
                return task + "\n\nRepository: \(repo)"
            }
            return task
        }()

        DevinAgentService.shared.dispatch(
            task: prompt,
            repository: (repository?.isEmpty == false) ? repository : nil,
            title: (title?.isEmpty == false) ? title : nil,
            tags: tags,
            conversationId: conversationId
        ) { result in
            switch result {
            case .success(let job):
                completion(Self.functionMessage("devin_dispatch_agent", [
                    "status": "dispatched",
                    "session_id": job.sessionId,
                    "dashboard_url": job.dashboardURL ?? "",
                    "message": "Devin session kicked off — open Settings ▸ Subagents to watch the live transcript. The PR link will be posted back here when it finishes; don't wait."
                ]))
            case .failure(let reason):
                completion(Self.functionMessage("devin_dispatch_agent",
                                                ["status": "error", "error": reason]))
            }
        }
    }

    // MARK: - devin_check_agent

    private func check(args: [String: Any],
                       completion: @escaping (MessageStruct) -> Void) {
        guard let id = (args["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            completion(Self.functionMessage("devin_check_agent",
                                            ["status": "error", "error": "session_id is required"]))
            return
        }
        DevinAgentService.shared.refresh(sessionId: id) { job in
            guard let job = job else {
                completion(Self.functionMessage("devin_check_agent",
                                                ["status": "error",
                                                 "error": "No tracked Devin session with id \(id)"]))
                return
            }
            completion(Self.functionMessage("devin_check_agent", Self.summary(job)))
        }
    }

    // MARK: - devin_list_agents

    private func list(completion: @escaping (MessageStruct) -> Void) {
        let jobs = DevinAgentService.shared.allJobs()
        completion(Self.functionMessage("devin_list_agents", [
            "count": jobs.count,
            "agents": jobs.map { Self.summary($0) }
        ]))
    }

    // MARK: - Helpers

    private static func summary(_ job: DevinAgentJob) -> [String: Any] {
        return [
            "session_id": job.sessionId,
            "title": job.displayTitle,
            "repository": job.repository ?? "",
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

    /// Best-effort short name for the row label, e.g. "owner/name" from a full
    /// GitHub URL. Falls back to the raw string for non-URL inputs.
    static func repoShortName(_ repo: String) -> String {
        let trimmed = repo.hasSuffix("/") ? String(repo.dropLast()) : repo
        let path = URL(string: trimmed)?.path ?? trimmed
        let parts = path.split(separator: "/").suffix(2)
        let name = parts.joined(separator: "/")
        let stripped = name.replacingOccurrences(of: ".git", with: "")
        return stripped.isEmpty ? trimmed : stripped
    }
}
