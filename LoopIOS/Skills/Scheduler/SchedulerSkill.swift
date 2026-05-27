//
//  SchedulerSkill.swift
//  Loop
//
//  Built from LoopIOS/Specs/7_background_scheduler_spec.md.
//
//  Agent-facing surface for BackgroundScheduler. Exposes:
//   - schedule_task     — discriminated payload (prompt | skill)
//   - list_tasks
//   - delete_task
//   - run_task_now      — fire a task immediately, for testing or on demand
//   - schedule_cron     — legacy alias; routed to schedule_task(payload=prompt)
//   - list_crons        — legacy alias for list_tasks
//   - delete_cron       — legacy alias for delete_task
//

import Foundation

final class SchedulerSkill {

    static let shared = SchedulerSkill()

    private init() {}

    // MARK: - System prompt fragment

    static let systemPromptFragment: String = """
You can schedule background tasks for the user with these tools:

- schedule_task: register a recurring or one-off task. Each task fires around a chosen hh:mm and produces a push notification when it runs.
  - Pick the right payload:
    - `payload.kind = "prompt"` (most common) for natural-language jobs the agent should think about — e.g. "every morning review my calendar and tell me about my day". Put the user-language prompt in `payload.user`. The model (you) will run with full skill access at fire time.
    - `payload.kind = "skill"` when the user explicitly named a known tool — e.g. "every morning at 8am call fetch_calendar_events". Pass `payload.name` + `payload.arguments` (as a JSON object).
  - Schedule:
    - "every day at 9am" → hour=9, minute=0 (default — daily, forever).
    - "tomorrow at 7am" → resolve to YYYY-MM-DD using today's date and pass `date` + `occurrences=1`.
    - "for the next 8 days at 7am" → `occurrences=8`.
  - weekdays (optional): array of integers specifying which days the task is allowed to fire. 1=Sunday, 2=Monday, …, 7=Saturday. Omit for every day.
    - "only on weekdays" → weekdays=[2,3,4,5,6] (Mon–Fri).
    - "weekends only" → weekdays=[1,7] (Sat–Sun).
    - When a fire time lands on a day not in the list, the task silently skips to the next allowed day.
  - prefetch_window_hours (optional, default 4): how far before fire time iOS is allowed to pre-generate the body so the notification lands with rich content.
    - 6–8 for content stable across the night (calendars, morning quotes, weekly digests). Maximizes happy-path delivery.
    - 2–4 for things that drift a bit (news summaries, market recaps). Default.
    - ≤1 for genuinely time-sensitive content ("what's on my calendar in the next 15 minutes"). Warn the user that they may need to tap the notification to load fresh content — iOS rarely runs background tasks inside such a tight window.
    - Allowed range: 0.5–12.
- list_tasks: list every scheduled task.
- delete_task: remove a task by id (use list_tasks to find ids).
- run_task_now: fire a task immediately. Useful when the user asks to preview what their morning briefing would say.

After scheduling, briefly confirm to the user what was set (don't list the id).
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "schedule_task",
                "description": "Schedule a recurring or one-off background task. A task fires around a chosen hh:mm local time. The result is delivered as a push notification; tapping it opens a conversation with the agent transcript.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "A short, user-facing label (e.g. 'morning briefing')."
                        ],
                        "hour": [
                            "type": "integer",
                            "description": "Hour of day to fire (0-23, local time)."
                        ],
                        "minute": [
                            "type": "integer",
                            "description": "Minute of the hour to fire (0-59)."
                        ],
                        "payload": [
                            "type": "object",
                            "description": "What to run at fire time. Use kind='prompt' to run a full agent turn over a user-language prompt with all skills available, or kind='skill' to invoke a specific named tool directly.",
                            "properties": [
                                "kind": [
                                    "type": "string",
                                    "enum": ["prompt", "skill"],
                                    "description": "'prompt' for natural-language jobs the agent should reason about. 'skill' for direct tool invocation."
                                ],
                                "user": [
                                    "type": "string",
                                    "description": "(kind=prompt) The user-language instruction the agent should follow at fire time."
                                ],
                                "system": [
                                    "type": "string",
                                    "description": "(kind=prompt, optional) Extra system context for this task only."
                                ],
                                "name": [
                                    "type": "string",
                                    "description": "(kind=skill) The exact tool/function name to invoke."
                                ],
                                "arguments": [
                                    "type": "object",
                                    "description": "(kind=skill) Arguments to pass to the named tool, shaped exactly like that tool's normal parameters."
                                ]
                            ],
                            "required": ["kind"]
                        ],
                        "occurrences": [
                            "type": "integer",
                            "description": "How many times to fire. Omit for unbounded daily repetition. Pass 1 for a one-time reminder. Max 60."
                        ],
                        "date": [
                            "type": "string",
                            "description": "Optional anchor date YYYY-MM-DD for the first firing."
                        ],
                        "weekdays": [
                            "type": "array",
                            "items": ["type": "integer"],
                            "description": "Days of the week the task is allowed to fire. 1=Sunday, 2=Monday, 3=Tuesday, 4=Wednesday, 5=Thursday, 6=Friday, 7=Saturday. Omit for every day. Example: [2,3,4,5,6] for Monday–Friday."
                        ],
                        "prefetch_window_hours": [
                            "type": "number",
                            "description": "How far before fire time iOS may pre-generate the body. Default 4. Range 0.5-12. Larger windows maximize happy-path delivery; smaller windows for time-sensitive content. Warn the user when picking ≤1."
                        ]
                    ],
                    "required": ["title", "hour", "minute", "payload"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_tasks",
                "description": "List every scheduled task with its title, next fire time, and last result.",
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
                "name": "delete_task",
                "description": "Delete a scheduled task by id.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "The id of the task to delete."
                        ]
                    ],
                    "required": ["id"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "run_task_now",
                "description": "Fire a scheduled task immediately (without waiting for its next scheduled time). Useful when the user asks to preview the next run.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "The id of the task to run."
                        ]
                    ],
                    "required": ["id"]
                ]
            ]
        ],
        // Legacy aliases — kept so prior `schedule_cron` calls (and existing
        // user habits) continue to work. Route to schedule_task / list_tasks /
        // delete_task with sensible defaults. One release of carry-over.
        //
        // The backend validates every property has a non-empty `description`
        // (Pydantic schema), so each entry below must spell one out — even
        // for legacy aliases where the field names are self-evident.
        [
            "type": "function",
            "function": [
                "name": "schedule_cron",
                "description": "Legacy alias for schedule_task with payload.kind='prompt'. Prefer schedule_task for new code.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Short label for the cron (e.g. 'morning quotes')."
                        ],
                        "prompt": [
                            "type": "string",
                            "description": "Natural-language description of what the notification body should say. Routed into payload.user on schedule_task."
                        ],
                        "hour": [
                            "type": "integer",
                            "description": "Hour of day to fire (0-23, local time)."
                        ],
                        "minute": [
                            "type": "integer",
                            "description": "Minute of the hour to fire (0-59)."
                        ],
                        "regenerate": [
                            "type": "boolean",
                            "description": "If true, the body regenerates each day. Only meaningful for unbounded crons (no occurrences)."
                        ],
                        "occurrences": [
                            "type": "integer",
                            "description": "How many times to fire. Omit for unbounded daily repetition. Pass 1 for one-shot, ≤60 for bounded."
                        ],
                        "date": [
                            "type": "string",
                            "description": "Optional anchor date YYYY-MM-DD (local time) for the first firing."
                        ]
                    ],
                    "required": ["title", "prompt", "hour", "minute"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_crons",
                "description": "Legacy alias for list_tasks.",
                "parameters": ["type": "object", "properties": [:], "required": []]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "delete_cron",
                "description": "Legacy alias for delete_task.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "The id of the cron/task to delete. Use list_crons or list_tasks to find ids."
                        ]
                    ],
                    "required": ["id"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "schedule_task", "list_tasks", "delete_task", "run_task_now"
    ]

    static let legacyToolNames: Set<String> = [
        "schedule_cron", "list_crons", "delete_cron"
    ]

    static let allToolNames: Set<String> = toolNames.union(legacyToolNames)

    func handles(functionName: String) -> Bool {
        return SchedulerSkill.allToolNames.contains(functionName)
    }

    // MARK: - Status text

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "schedule_task", "schedule_cron":
            if let title = call.arguments["title"] as? String, !title.isEmpty {
                return "scheduling \(title)"
            }
            return "scheduling a task"
        case "list_tasks", "list_crons":
            return "looking up your scheduled tasks"
        case "delete_task", "delete_cron":
            return "removing scheduled task"
        case "run_task_now":
            return "running task now"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "schedule_task":
            schedule_task(args: functionCall.arguments, completion: completion)
        case "schedule_cron":
            schedule_cron_legacy(args: functionCall.arguments, completion: completion)
        case "list_tasks", "list_crons":
            list_tasks(completion: completion)
        case "delete_task", "delete_cron":
            delete_task(args: functionCall.arguments, completion: completion)
        case "run_task_now":
            run_task_now(args: functionCall.arguments, completion: completion)
        default:
            completion(SchedulerSkill.functionMessage(
                name: functionCall.name,
                payload: ["status": "error", "error": "Unknown scheduler tool '\(functionCall.name)'."]
            ))
        }
    }

    // MARK: - schedule_task

    private func schedule_task(args: [String: Any],
                               completion: @escaping (MessageStruct) -> Void) {
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let hour = intArg(args["hour"]),
              let minute = intArg(args["minute"]) else {
            completion(missingArgs(for: "schedule_task",
                                   expected: "title, hour, minute, payload"))
            return
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            completion(SchedulerSkill.functionMessage(
                name: "schedule_task",
                payload: ["status": "error",
                          "error": "hour must be 0-23 and minute must be 0-59"]
            ))
            return
        }

        guard let payloadDict = args["payload"] as? [String: Any] else {
            completion(SchedulerSkill.functionMessage(
                name: "schedule_task",
                payload: ["status": "error",
                          "error": "payload is required"]
            ))
            return
        }

        let payload: Payload
        let kind = (payloadDict["kind"] as? String) ?? "prompt"
        switch kind {
        case "prompt":
            guard let user = (payloadDict["user"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !user.isEmpty else {
                completion(SchedulerSkill.functionMessage(
                    name: "schedule_task",
                    payload: ["status": "error",
                              "error": "payload.user is required for kind='prompt'"]
                ))
                return
            }
            let system = payloadDict["system"] as? String
            payload = .prompt(user: user, system: system)

        case "skill":
            guard let name = (payloadDict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                completion(SchedulerSkill.functionMessage(
                    name: "schedule_task",
                    payload: ["status": "error",
                              "error": "payload.name is required for kind='skill'"]
                ))
                return
            }
            let argsObj = payloadDict["arguments"] as? [String: Any] ?? [:]
            let json: String
            if let data = try? JSONSerialization.data(withJSONObject: argsObj, options: []),
               let str = String(data: data, encoding: .utf8) {
                json = str
            } else {
                json = "{}"
            }
            payload = .skill(name: name, argumentsJSON: json)

        default:
            completion(SchedulerSkill.functionMessage(
                name: "schedule_task",
                payload: ["status": "error",
                          "error": "Unknown payload.kind '\(kind)'. Use 'prompt' or 'skill'."]
            ))
            return
        }

        // Optional occurrences (≤60).
        var occurrences: Int? = nil
        if let raw = args["occurrences"], !(raw is NSNull) {
            guard let n = intArg(raw), n >= 1 else {
                completion(SchedulerSkill.functionMessage(
                    name: "schedule_task",
                    payload: ["status": "error",
                              "error": "occurrences must be an integer >= 1"]
                ))
                return
            }
            guard n <= 60 else {
                completion(SchedulerSkill.functionMessage(
                    name: "schedule_task",
                    payload: ["status": "error",
                              "error": "occurrences may not exceed 60"]
                ))
                return
            }
            occurrences = n
        }

        // Optional anchor date.
        var firstDate: Date? = nil
        if let raw = args["date"] as? String, !raw.isEmpty {
            guard let parsed = SchedulerSkill.parseDate(raw, hour: hour, minute: minute) else {
                completion(SchedulerSkill.functionMessage(
                    name: "schedule_task",
                    payload: ["status": "error",
                              "error": "date must be YYYY-MM-DD and not in the past"]
                ))
                return
            }
            firstDate = parsed
        }

        // Optional weekdays filter.
        var weekdays: [Int]? = nil
        if let raw = args["weekdays"] {
            if let arr = raw as? [Any] {
                let parsed = arr.compactMap { intArg($0) }.filter { (1...7).contains($0) }
                if !parsed.isEmpty {
                    weekdays = Array(Set(parsed)).sorted()
                }
            }
        }

        // Optional prefetch window (clamped to allowed range).
        var window = ScheduledJob.defaultPrefetchHours
        if let raw = args["prefetch_window_hours"], !(raw is NSNull) {
            if let v = doubleArg(raw) {
                window = max(ScheduledJob.minPrefetchHours,
                             min(ScheduledJob.maxPrefetchHours, v))
            }
        }

        let job = ScheduledJob(
            id: UUID().uuidString,
            title: title,
            trigger: Trigger(
                hour: hour,
                minute: minute,
                occurrences: occurrences,
                firstDate: firstDate,
                regenerate: kind == "prompt",
                weekdays: weekdays
            ),
            payload: payload,
            prefetchWindowHours: window,
            voiceDelivery: false,
            createdAt: Date(),
            lastRunAt: nil,
            lastResult: nil,
            firingsCompleted: 0
        )

        BackgroundScheduler.shared.addJob(job)

        completion(SchedulerSkill.functionMessage(
            name: "schedule_task",
            payload: [
                "status": "success",
                "id": job.id,
                "title": job.title,
                "schedule": BackgroundScheduler.shared.scheduleDescription(for: job),
                "prefetch_window_hours": window,
                "message": "Scheduled '\(job.title)' — \(BackgroundScheduler.shared.scheduleDescription(for: job))."
            ]
        ))
    }

    // MARK: - schedule_cron (legacy)

    /// Maps the old `schedule_cron` shape onto `schedule_task` with
    /// payload.kind="prompt". Keeps prior model habits and prior conversation
    /// history working without forcing a re-train.
    private func schedule_cron_legacy(args: [String: Any],
                                      completion: @escaping (MessageStruct) -> Void) {
        guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
            completion(missingArgs(for: "schedule_cron",
                                   expected: "title, prompt, hour, minute"))
            return
        }
        var translated = args
        translated["payload"] = [
            "kind": "prompt",
            "user": prompt
        ]
        translated.removeValue(forKey: "prompt")
        translated.removeValue(forKey: "regenerate")  // handled at trigger level
        schedule_task(args: translated, completion: completion)
    }

    // MARK: - list_tasks

    private func list_tasks(completion: @escaping (MessageStruct) -> Void) {
        let jobs = BackgroundScheduler.shared.loadJobs()
        let tasks: [[String: Any]] = jobs.map { job in
            var entry: [String: Any] = [
                "id": job.id,
                "title": job.title,
                "schedule": BackgroundScheduler.shared.scheduleDescription(for: job),
                "prefetch_window_hours": job.prefetchWindowHours
            ]
            if let last = job.lastResult { entry["last_result"] = last }
            if let lastAt = job.lastRunAt {
                entry["last_run_at"] = ISO8601DateFormatter().string(from: lastAt)
            }
            if let wd = job.trigger.weekdays, !wd.isEmpty {
                entry["weekdays"] = wd
            }
            switch job.payload {
            case .prompt(let user, _):
                entry["payload_kind"] = "prompt"
                entry["payload_preview"] = String(user.prefix(80))
            case .skill(let name, _):
                entry["payload_kind"] = "skill"
                entry["payload_preview"] = name
            }
            return entry
        }
        completion(SchedulerSkill.functionMessage(
            name: "list_tasks",
            payload: ["count": tasks.count, "tasks": tasks]
        ))
    }

    // MARK: - delete_task

    private func delete_task(args: [String: Any],
                             completion: @escaping (MessageStruct) -> Void) {
        guard let id = args["id"] as? String, !id.isEmpty else {
            completion(missingArgs(for: "delete_task", expected: "id"))
            return
        }
        if let removed = BackgroundScheduler.shared.deleteJob(id: id) {
            completion(SchedulerSkill.functionMessage(
                name: "delete_task",
                payload: ["status": "success", "id": id, "title": removed.title,
                          "message": "Deleted '\(removed.title)'."]
            ))
        } else {
            completion(SchedulerSkill.functionMessage(
                name: "delete_task",
                payload: ["status": "not_found", "id": id]
            ))
        }
    }

    // MARK: - run_task_now

    private func run_task_now(args: [String: Any],
                              completion: @escaping (MessageStruct) -> Void) {
        guard let id = args["id"] as? String, !id.isEmpty,
              let job = BackgroundScheduler.shared.loadJobs().first(where: { $0.id == id }) else {
            completion(SchedulerSkill.functionMessage(
                name: "run_task_now",
                payload: ["status": "not_found", "id": args["id"] ?? ""]
            ))
            return
        }
        // Use the next scheduled fire date so the resulting PrefetchedResult
        // satisfies the next firing too — if the user previews their morning
        // briefing at 11pm, the 6am notification can simply reuse this body.
        let fireDate = BackgroundScheduler.shared.nextFireDate(for: job.trigger)
        BackgroundScheduler.shared.prefetch(job: job, fireDate: fireDate) { result in
            switch result {
            case .success(let body, _):
                completion(SchedulerSkill.functionMessage(
                    name: "run_task_now",
                    payload: ["status": "success", "id": id, "title": job.title,
                              "body": body]
                ))
            case .failure(let reason):
                completion(SchedulerSkill.functionMessage(
                    name: "run_task_now",
                    payload: ["status": "error", "id": id, "error": reason]
                ))
            }
        }
    }

    // MARK: - Helpers

    private func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func doubleArg(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func missingArgs(for name: String, expected: String) -> MessageStruct {
        return MessageStruct(
            role: "function",
            content: "{\"status\":\"error\",\"error\":\"Missing arguments for \(name): \(expected)\"}",
            name: name
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

    private static func parseDate(_ raw: String, hour: Int, minute: Int) -> Date? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]),
              let m = Int(parts[1]),
              let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard let date = Calendar.current.date(from: comps), date > Date() else {
            return nil
        }
        return date
    }
}
