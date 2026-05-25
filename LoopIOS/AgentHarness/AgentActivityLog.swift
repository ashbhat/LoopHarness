//
//  AgentActivityLog.swift
//  Loop
//
//  A ring-buffer of recent agent activity — tool calls, status pings, thoughts,
//  and sub-agent ticks. The large-mode AgentView observes this to render a
//  live, inspectable readout of what's happening inside the model loop.
//
//  Producers (MessagingVC, SubAgentRuntime) call `log(...)`; consumers
//  subscribe to `.agentActivityDidChange`. The log is intentionally
//  lightweight: events are summary strings + an optional detail blob, capped
//  at `maxEntries` so a long-running session can't bloat memory.
//

import Foundation

extension Notification.Name {
    /// Posted whenever a new entry is appended (or the log is cleared). The
    /// large-mode AgentView listens for this on the main queue to refresh its
    /// ticker.
    static let agentActivityDidChange = Notification.Name("agentActivityDidChange")
}

final class AgentActivityLog {
    static let shared = AgentActivityLog()

    enum Kind {
        /// Top-level shimmer / status flips ("Thinking…", "searching the web").
        case status
        /// The model picked a tool to run.
        case toolCall
        /// A tool returned a result (only the head, for the ticker).
        case toolResult
        /// Plain assistant reasoning between tools.
        case thought
        /// Sub-agent lifecycle / step ticks.
        case subAgent
    }

    struct Entry {
        let id: String
        let timestamp: Date
        let kind: Kind
        /// One-line summary, ticker-ready. Long blobs go in `detail`.
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

    /// Hard cap. The ticker only renders the last ~6 entries so older ones
    /// are dropped silently as new ones arrive.
    static let maxEntries = 80

    private let queue = DispatchQueue(label: "AgentActivityLog")
    private var _entries: [Entry] = []
    /// Insertion-ordered list of currently-running tool calls, keyed by the
    /// dispatcher's `callId`. The expanded AgentView reads this to drive its
    /// caption — without it the caption sticks on the first-logged call until
    /// the next LLM round, even if other parallel tools are still running.
    private var _activeCalls: [(callId: String, summary: String)] = []
    /// Most recent assistant message content, surfaced to the expanded
    /// AgentView as a readable transcript below the orb. Updated by
    /// MessagingVC when a plain assistant turn lands; nil means the orb
    /// should fall back to its idle hint.
    private var _assistantTranscript: String?

    private init() {}

    /// Snapshot of the current log, oldest-first. Safe to call from any queue.
    var entries: [Entry] { queue.sync { _entries } }

    /// Append a new entry and broadcast. Producers don't need to worry about
    /// dedupe — the ticker collapses identical summaries on render.
    func log(_ kind: Kind, _ summary: String, detail: String? = nil) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.sync {
            _entries.append(Entry(kind: kind, summary: trimmed, detail: detail))
            if _entries.count > Self.maxEntries {
                _entries.removeFirst(_entries.count - Self.maxEntries)
            }
        }
        NotificationCenter.default.post(name: .agentActivityDidChange, object: nil)
    }

    /// Mark a tool call as started. Appends a `.toolCall` entry to the ticker
    /// AND records the call as active so callers can render "running N tools"
    /// captions while the batch executes. `callId` must be unique per call —
    /// MessagingVC stamps it from the dispatcher so toolCall/toolResult can
    /// be paired.
    func beginToolCall(callId: String, summary: String, detail: String? = nil) {
        log(.toolCall, summary, detail: detail)
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.sync {
            _activeCalls.append((callId: callId, summary: trimmed))
        }
        NotificationCenter.default.post(name: .agentActivityDidChange, object: nil)
    }

    /// Mark a tool call as finished. Removes it from the active set and
    /// optionally appends a `.toolResult` entry to the ticker. Safe to call
    /// with an unknown callId (no-op on the active set, still logs the result).
    func endToolCall(callId: String, resultSummary: String? = nil) {
        queue.sync {
            _activeCalls.removeAll { $0.callId == callId }
        }
        if let resultSummary = resultSummary {
            log(.toolResult, resultSummary)
        } else {
            NotificationCenter.default.post(name: .agentActivityDidChange, object: nil)
        }
    }

    /// Number of tool calls currently in flight. Drives the caption's "running
    /// N tools" branch when more than one is parallel.
    var activeCallCount: Int { queue.sync { _activeCalls.count } }

    /// Summary of the most recently started in-flight call, or nil if nothing
    /// is running. Used as the caption when exactly one tool is active.
    var mostRecentActiveSummary: String? {
        queue.sync { _activeCalls.last?.summary }
    }

    /// Most recent assistant message text — what the orb is currently saying
    /// (or just finished saying). The expanded AgentView reads this to
    /// render a transcript directly below the orb so the user can read what
    /// the model is saying even with TTS muted.
    var assistantTranscript: String? {
        queue.sync { _assistantTranscript }
    }

    /// Publish the most recent assistant transcript. Pass an empty string or
    /// nil to clear (the AgentView falls back to its idle hint copy).
    /// Posts `.agentActivityDidChange` so observers refresh on the same
    /// notification they already use for ticker/active-call updates.
    func setAssistantTranscript(_ text: String?) {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.sync {
            _assistantTranscript = (normalized?.isEmpty == false) ? normalized : nil
        }
        NotificationCenter.default.post(name: .agentActivityDidChange, object: nil)
    }

    /// Drop everything. Called when the user starts a fresh conversation so
    /// stale tool calls don't bleed into the new context.
    func clear() {
        queue.sync {
            _entries.removeAll()
            _activeCalls.removeAll()
            _assistantTranscript = nil
        }
        NotificationCenter.default.post(name: .agentActivityDidChange, object: nil)
    }
}
