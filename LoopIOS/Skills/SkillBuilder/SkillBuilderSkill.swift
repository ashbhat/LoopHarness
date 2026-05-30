//
//  SkillBuilderSkill.swift
//  Loop
//
//  Built from LoopIOS/Specs/2. Loop Local Runtime Spec.md.
//
//  The conversational "skill author" surface. Walks the user through naming
//  the skill, defining inputs, sketching outputs, then commits a finished
//  skill.js + skill.json into Workspace/Skills/<name>/. After the write the
//  skill is hot-loaded into DynamicSkillRegistry and a local notification
//  fires so the user knows it's ready even if the app has backgrounded.
//
//  Three tools:
//    - save_skill          → write + hot-load + notify
//    - list_skills         → enumerate everything the user has authored
//    - delete_skill        → remove by name
//
//  The interview itself is driven by the system prompt — the model asks the
//  questions, the user answers, then the model calls `save_skill`. No state
//  machine in Swift; the model owns the flow.
//

import Foundation
import UserNotifications

struct SkillBuilderSkill {
    static let shared = SkillBuilderSkill()

    // MARK: - System prompt fragment

    static let systemPromptFragment: String = """
You can author brand-new skills for Loop that run inside the on-device
JavaScript runtime. Skills are persistent — once authored they sit in
Workspace/Skills/<name>/ and are callable forever after, like any other tool.

The runtime exposes this `host` object to every skill:
- `host.log(msg)`          → live progress (shown to the user as a shimmer)
- `host.http(opts)`        → returns `{status, headers, body, json?}` Promise.
                             opts = { url, method?, headers?, body?, json? }
- `host.notify(title, body)` → fire a local push notification
- `host.sleep(ms)`         → Promise<void>; useful for pacing
- `host.callTool(name, args)` → invoke one of Loop's BUILT-IN tools and await
                             its result. Returns the tool's parsed JSON object
                             (e.g. `{status, stdout, stderr, exit_code}`). This
                             lets a skill orchestrate native capabilities it
                             couldn't reach over plain HTTP.

`host.callTool` reaches the same built-in tools the model can call directly —
for example:
- `ssh_client({command, timeout?})` → run a shell command on the host
  configured in Settings → SSH; returns `{status, stdout, stderr, exit_code}`.
- `git_*`, `github_*`, `exa_search`, `url_fetch`, `image_generate`, etc.
It can NOT call other user-authored skills (only built-ins), so don't try to
chain one custom skill into another through it.

Example — a "claude_code" skill that drives a structured Claude Code session
over SSH:
    async function run(args, host) {
      const prompt = args.prompt;
      host.log("launching claude code…");
      const res = await host.callTool("ssh_client", {
        command: `cd ${args.repo || "~"} && claude -p ${JSON.stringify(prompt)} --output-format json`,
        timeout: 120
      });
      if (res.status !== "ok" || res.exit_code !== 0) {
        return { summary: "Claude Code run failed", error: res.stderr || res.error };
      }
      return { summary: "Claude Code finished", output: res.stdout };
    }

The skill file must export a top-level `async function run(args, host)` that
returns a JSON-serializable object. Whatever object it returns is what you'll
see back as the tool result; include a `summary` field with a short
human-readable answer so the response to the user reads naturally.

When the user says anything like "create a skill that…", "build me a
tool that…", or "I want a skill for…" — run this interview:

1. Confirm the goal in one sentence ("Got it — a skill that does X, yes?").
2. Ask about inputs the skill should accept (none is fine; lots of skills
   are zero-arg). Confirm what each input means.
3. Ask about the data source: which API, URL, or page does it need to read?
   If you don't know the endpoint, ask the user; don't invent one.
4. Ask about output shape: what should the skill return? A summary string is
   the most useful default.
5. Ask about scheduling: should it run on demand, or every morning at 8am?
   (If scheduled, you'll call `schedule_cron` separately after the skill is saved.)
6. Pick a snake_case name (lowercase, underscores only) and a 1-sentence
   description.
7. Draft the JS body. Use `await host.http({...})`. Always handle non-200s.
   Keep it under 80 lines and don't import anything — the runtime has no
   module loader.
8. Show the user the final manifest + code and ask "Save it?"
9. On confirmation, call `save_skill(name, description, parameters, code)`.
   The response includes a `next_step` — surface it to the user (it usually
   says the skill is hot-loaded and ready to call).

Other useful tools in this family:
- `list_skills`  — show what the user has already authored.
- `delete_skill` — remove a skill by name.

Skill parameters must be an OpenAI-style JSON schema:
`{ type: "object", properties: { ... }, required: [...] }`.
If the skill takes no inputs, pass `{ type: "object", properties: {}, required: [] }`.

Never write skill code that calls `eval`, accesses the filesystem directly,
spawns workers, or tries to escape the runtime — none of that is exposed and
the skill will just error.
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "save_skill",
                "description": "Persist a new (or updated) skill to disk and hot-load it into the runtime. After this returns successfully the skill is immediately callable as a tool with the same `name`.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "snake_case identifier. Becomes the tool name and the folder name under Workspace/Skills/. Example: 'polymarket_trending'."
                        ],
                        "description": [
                            "type": "string",
                            "description": "One sentence describing what the skill does. Surfaced to the model so it knows when to call the skill."
                        ],
                        "parameters": [
                            "type": "object",
                            "description": "OpenAI-style JSON schema describing the skill's arguments. Pass `{type:'object',properties:{},required:[]}` for zero-arg skills."
                        ],
                        "code": [
                            "type": "string",
                            "description": "JS source. Must define `async function run(args, host) {...}` at top level. Use `host.http`, `host.log`, `host.notify`, `host.sleep` for I/O."
                        ]
                    ],
                    "required": ["name", "description", "parameters", "code"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_skills",
                "description": "List every user-authored skill currently loaded. Returns name, description, and the parameter schema for each.",
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
                "name": "delete_skill",
                "description": "Remove a user-authored skill by name. Deletes the folder under Workspace/Skills/<name>/ and unloads it from the runtime.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "The skill's name (same as the folder name)."
                        ]
                    ],
                    "required": ["name"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "save_skill", "list_skills", "delete_skill"
    ]

    func handles(functionName: String) -> Bool {
        return SkillBuilderSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "save_skill":
            if let name = call.arguments["name"] as? String, !name.isEmpty {
                return "writing skill \(name)"
            }
            return "saving new skill"
        case "list_skills":   return "listing your skills"
        case "delete_skill":  return "removing skill"
        default:              return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "save_skill":   save_skill(args: functionCall.arguments, completion: completion)
        case "list_skills":  list_skills(completion: completion)
        case "delete_skill": delete_skill(args: functionCall.arguments, completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the skill-builder tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handlers

    private func save_skill(args: [String: Any],
                            completion: @escaping (MessageStruct) -> Void) {
        guard let rawName = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            completion(Self.functionMessage(
                name: "save_skill",
                payload: ["status": "error", "error": "`name` is required"]
            ))
            return
        }
        guard let description = (args["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else {
            completion(Self.functionMessage(
                name: "save_skill",
                payload: ["status": "error", "error": "`description` is required"]
            ))
            return
        }
        guard let code = (args["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            completion(Self.functionMessage(
                name: "save_skill",
                payload: ["status": "error", "error": "`code` is required"]
            ))
            return
        }
        // Cheap sanity check: must declare run(...) at the top level. Without
        // this the runtime would just error at execution time, but catching it
        // here lets the model self-correct before we touch disk.
        guard code.range(of: #"function\s+run\s*\("#, options: .regularExpression) != nil ||
              code.range(of: #"run\s*=\s*(async\s*)?function\s*\("#, options: .regularExpression) != nil ||
              code.range(of: #"run\s*=\s*\("#, options: .regularExpression) != nil else {
            completion(Self.functionMessage(
                name: "save_skill",
                payload: [
                    "status": "error",
                    "error": "Skill must define a top-level `run(args, host)` function — the runtime looks for `run` as the entry point."
                ]
            ))
            return
        }

        let parameters = (args["parameters"] as? [String: Any]) ?? [
            "type": "object",
            "properties": [String: Any](),
            "required": [String]()
        ]

        do {
            let folder = try DynamicSkillRegistry.shared.writeSkill(
                name: rawName,
                description: description,
                parameters: parameters,
                source: code
            )
            let savedName = DynamicSkillRegistry.sanitize(rawName)

            // Notify the user that the skill is ready. The notification fires
            // immediately so the user gets a confirmation even if they've
            // switched away from the app while the model was generating code.
            Self.fireReadyNotification(name: savedName, description: description)

            completion(Self.functionMessage(
                name: "save_skill",
                payload: [
                    "status": "success",
                    "name": savedName,
                    "path": Workspace.shared.relativePath(of: folder),
                    "next_step": "Skill `\(savedName)` is saved and hot-loaded. You can call it now or rerun it later — tell the user it's ready and ask if they'd like to try it."
                ]
            ))
        } catch {
            completion(Self.functionMessage(
                name: "save_skill",
                payload: [
                    "status": "error",
                    "error": "Failed to save skill: \(error.localizedDescription)"
                ]
            ))
        }
    }

    private func list_skills(completion: @escaping (MessageStruct) -> Void) {
        DynamicSkillRegistry.shared.reload()
        let summaries = DynamicSkillRegistry.shared.skills.values
            .sorted { $0.name < $1.name }
            .map { skill -> [String: Any] in
                return [
                    "name": skill.name,
                    "description": skill.description,
                    "parameters": skill.parameters
                ]
            }
        completion(Self.functionMessage(
            name: "list_skills",
            payload: [
                "status": "success",
                "count": summaries.count,
                "skills": summaries
            ]
        ))
    }

    private func delete_skill(args: [String: Any],
                              completion: @escaping (MessageStruct) -> Void) {
        guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            completion(Self.functionMessage(
                name: "delete_skill",
                payload: ["status": "error", "error": "`name` is required"]
            ))
            return
        }
        do {
            try DynamicSkillRegistry.shared.deleteSkill(name: name)
            completion(Self.functionMessage(
                name: "delete_skill",
                payload: [
                    "status": "success",
                    "name": name,
                    "message": "Removed skill `\(name)`."
                ]
            ))
        } catch {
            completion(Self.functionMessage(
                name: "delete_skill",
                payload: [
                    "status": "error",
                    "error": "Failed to delete skill: \(error.localizedDescription)"
                ]
            ))
        }
    }

    // MARK: - Notification

    private static func fireReadyNotification(name: String, description: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            // `.ephemeral` is iOS-only; gate it so the macOS target compiles.
            let ok: Bool = {
                switch settings.authorizationStatus {
                case .authorized, .provisional: return true
                default: return false
                }
            }()
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = "New skill ready"
            content.body  = "\(name) — \(description)"
            content.sound = .default
            content.userInfo = ["kind": "skill_ready", "skill": name]
            let request = UNNotificationRequest(
                identifier: "skill.ready.\(name)",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
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
