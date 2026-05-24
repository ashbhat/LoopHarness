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

    /// Drop everything. Called when the user starts a fresh conversation so
    /// stale tool calls don't bleed into the new context.
    func clear() {
        queue.sync { _entries.removeAll() }
        NotificationCenter.default.post(name: .agentActivityDidChange, object: nil)
    }
}
