//
//  SubAgent.swift
//  Loop
//
//  Models a single sub-agent — an autonomous execution context spawned by the
//  primary conversation. See intel/Specs/8_sub_agent_runtime_spec.md.
//

import Foundation

/// Lifecycle states a sub-agent can be in. The UI uses these to choose
/// glyph + color in the runtime inspector and the top status bar.
enum SubAgentState: String, Codable {
    /// Currently making a model call or dispatching a tool.
    case active
    /// Idle but alive — waiting on an external timer or hand-off.
    case sleeping
    /// Stopped pending user input (not used in v1, reserved).
    case waitingForInput = "waiting_for_input"
    /// Finished — `result` holds the summary message that was posted back.
    case completed
    /// Aborted because a tool errored, the model failed, or the user killed it.
    case failed
}

/// Coarse classification of what a sub-agent is doing. Drives the icon shown
/// in the inspector list and lets the spec's "research" / "coding" buckets
/// surface in UI without parsing the task string.
enum SubAgentKind: String, Codable {
    case research
    case coding
    case general
}

/// A single line in a sub-agent's event log. Lightweight — the inspector
/// renders these in reverse chronological order; we keep them in memory
/// only (the final transcript persists to disk via the parent conversation
/// when the sub-agent completes).
struct SubAgentLogEntry: Identifiable {
    enum Kind {
        /// Agent picked a tool to run.
        case toolCall
        /// Tool returned a result.
        case toolResult
        /// Plain assistant reasoning between tools.
        case thought
        /// Internal status (state transitions, errors, retries).
        case system
    }
    let id: String
    let timestamp: Date
    let kind: Kind
    /// One-line summary suitable for the inspector list. Longer detail can
    /// be tucked into `detail` for an expandable view later.
    let summary: String
    let detail: String?

    init(kind: Kind, summary: String, detail: String? = nil) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }
}

/// Snapshot of a running (or finished) sub-agent. Mutated in place by
/// `SubAgentManager`; the manager fires `subAgentsDidChange` whenever any
/// observable field flips so the UI can react.
final class SubAgent {
    let id: String
    /// The conversation that spawned this sub-agent. On completion we post a
    /// summary message back here so the primary thread sees the outcome.
    let parentConversationId: String
    /// What the user asked for. This becomes the seed user message inside the
    /// sub-agent's isolated context.
    let task: String
    let kind: SubAgentKind
    let startedAt: Date

    /// Current lifecycle state. Mutating this from the manager fires a
    /// `subAgentsDidChange` broadcast.
    var state: SubAgentState
    /// Human-readable description of what the agent is doing right now —
    /// e.g. "searching the web for X" or "writing build script". Drives the
    /// per-row subtitle in the inspector.
    var currentStep: String
    /// Event log, append-only. Capped at `maxLogEntries` so a runaway agent
    /// doesn't blow memory.
    private(set) var logs: [SubAgentLogEntry] = []
    /// Isolated message history the sub-agent reasons over. Starts with a
    /// system prompt + the user task, then grows with every model turn and
    /// tool result.
    var messages: [MessageStruct] = []
    /// Summary string posted back into the parent conversation on completion.
    /// Nil while the agent is still running.
    var result: String?
    /// Error message captured at the point of failure. Nil unless `state` is
    /// `.failed`.
    var error: String?
    /// When the agent finished, regardless of outcome. Nil while running.
    var finishedAt: Date?

    /// Hard cap on log entries; older entries get dropped from the head.
    /// Sub-agents that ran 50+ tool calls would otherwise dominate the
    /// inspector and bloat memory.
    static let maxLogEntries = 200

    init(parentConversationId: String,
         task: String,
         kind: SubAgentKind = .general,
         initialStep: String = "Starting up") {
        self.id = UUID().uuidString
        self.parentConversationId = parentConversationId
        self.task = task
        self.kind = kind
        self.startedAt = Date()
        self.state = .active
        self.currentStep = initialStep
    }

    /// Append a log entry, trimming the oldest if we've hit the cap. The
    /// manager is responsible for firing the notification after this returns.
    func appendLog(_ entry: SubAgentLogEntry) {
        logs.append(entry)
        if logs.count > Self.maxLogEntries {
            logs.removeFirst(logs.count - Self.maxLogEntries)
        }
    }

    /// Best-effort short label of the agent for the inspector row title.
    /// Trims and truncates the task so multi-line prompts collapse nicely.
    var displayTitle: String {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(77)) + "…"
    }

    /// Duration the sub-agent has been alive, in seconds. Used by the
    /// inspector to render "12s" / "3m 04s" runtime labels.
    var runtime: TimeInterval {
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Convenience for the UI: whether this agent is still doing work.
    var isAlive: Bool {
        switch state {
        case .active, .sleeping, .waitingForInput: return true
        case .completed, .failed: return false
        }
    }
}
