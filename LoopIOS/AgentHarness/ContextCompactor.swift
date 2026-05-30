//
//  ContextCompactor.swift
//  Loop
//
//  Opportunistic context compaction. On every user turn, estimates the
//  assembled context size (system prompt + thread) and, when it crosses a
//  configurable threshold, spawns a background sub-agent to compact self-docs
//  and the conversation thread — without blocking the foreground reply.
//
//  See specs/opportunistic-context-compaction.md for the full spec.
//

import Foundation

// MARK: - Tuning constants

/// Maximum token budget for the context window. Tokens are estimated as
/// `chars / 4`.
let kCompactionTokenBudget: Int = 200_000

/// Ratio of estimated tokens to budget at which a silent (soft) compaction
/// fires in the background.
let kCompactionSoftThreshold: Double = 0.30

/// Ratio at which the assistant reply must include a brief compaction
/// notice alongside the silent background compaction.
let kCompactionHardThreshold: Double = 0.60

/// Minimum hours between compaction runs. Checked via the timestamp in
/// `memory/.last_compaction`.
let kCompactionLockoutHours: Double = 6.0

/// Number of most-recent messages to keep verbatim during thread
/// compaction. Everything older is rolled into a running summary.
let kThreadCompactionKeepCount: Int = 20

// MARK: - Compaction trigger level

enum CompactionTrigger {
    /// Context usage is below the soft threshold — no compaction needed.
    case none
    /// Context usage is ≥ soft threshold — compact silently.
    case soft
    /// Context usage is ≥ hard threshold — compact and mention it in reply.
    case hard
}

// MARK: - ContextCompactor

enum ContextCompactor {

    // MARK: - Token estimation

    /// Cheap char-length proxy: estimate tokens as `chars / 4`.
    static func estimateTokens(chars: Int) -> Int {
        return chars / 4
    }

    // MARK: - Context size measurement

    /// Compute the total character count of the assembled context that would
    /// be sent to the model: the composed system prompt plus every message in
    /// the thread.
    static func contextCharCount(messages: [MessageStruct]) -> Int {
        let systemPrompt = AgentHarness.shared.buildSystemPrompt(
            base: messages.first(where: { $0.role == "system" })?.content ?? ""
        )
        let threadChars = messages
            .filter { $0.role != "system" }
            .reduce(0) { $0 + $1.content.count }
        return systemPrompt.count + threadChars
    }

    // MARK: - Threshold evaluation

    /// Determine the compaction trigger level for the current context.
    static func evaluateTrigger(messages: [MessageStruct]) -> CompactionTrigger {
        let chars = contextCharCount(messages: messages)
        let tokens = estimateTokens(chars: chars)
        let ratio = Double(tokens) / Double(kCompactionTokenBudget)
        if ratio >= kCompactionHardThreshold { return .hard }
        if ratio >= kCompactionSoftThreshold { return .soft }
        return .none
    }

    // MARK: - Lockout

    /// Path (relative to workspace root) where the lockout timestamp lives.
    private static let lockoutRelativePath = "memory/.last_compaction"

    /// Returns `true` if a compaction ran within the lockout window.
    static func isLockedOut() -> Bool {
        guard let url = try? Workspace.shared.resolve(lockoutRelativePath) else {
            return false
        }
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let date = ISO8601DateFormatter().date(from: raw) else {
            return false
        }
        let elapsed = Date().timeIntervalSince(date)
        return elapsed < kCompactionLockoutHours * 3600
    }

    /// Write the current ISO 8601 timestamp to the lockout file.
    static func writeLockout() {
        guard let url = try? Workspace.shared.resolve(lockoutRelativePath) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? stamp.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Per-turn entry point

    /// Called on every user turn, BEFORE the foreground LLM call returns.
    /// If the context crosses a threshold and lockout is clear, spawns a
    /// background sub-agent to compact self-docs and the thread.
    ///
    /// - Parameters:
    ///   - messages: The full message array being sent to the model.
    ///   - conversationId: The id of the active conversation.
    /// - Returns: The `CompactionTrigger` so the caller can decide whether
    ///   to append a notice to the assistant reply.
    @discardableResult
    static func checkAndTrigger(messages: [MessageStruct],
                                conversationId: String) -> CompactionTrigger {
        let trigger = evaluateTrigger(messages: messages)
        guard trigger != .none else { return .none }
        guard !isLockedOut() else { return .none }

        spawnCompactionAgent(messages: messages, conversationId: conversationId)
        return trigger
    }

    // MARK: - Sub-agent dispatch

    /// Spawn the compaction sub-agent. It runs detached; the foreground
    /// turn is never blocked.
    private static func spawnCompactionAgent(messages: [MessageStruct],
                                             conversationId: String) {
        // Snapshot sizes for the completion message.
        let memoryChars = AgentHarness.shared.memory.count
        let agentsChars = AgentHarness.shared.agents.count
        let heartbeatChars = AgentHarness.shared.heartbeat.count
        let threadCount = messages.filter { $0.role != "system" }.count

        let taskPrompt = buildCompactionPrompt(
            memoryChars: memoryChars,
            agentsChars: agentsChars,
            heartbeatChars: heartbeatChars,
            threadCount: threadCount,
            conversationId: conversationId,
            messages: messages
        )

        SubAgentManager.shared.spawn(
            task: taskPrompt,
            kind: .general,
            parentConversationId: conversationId
        )
    }

    // MARK: - Compaction prompt

    /// Build the task prompt that instructs the sub-agent to compact
    /// self-docs and the conversation thread.
    private static func buildCompactionPrompt(
        memoryChars: Int,
        agentsChars: Int,
        heartbeatChars: Int,
        threadCount: Int,
        conversationId: String,
        messages: [MessageStruct]
    ) -> String {
        // Build a serialized snapshot of messages older than the keep window
        // so the sub-agent can summarize them without needing to read
        // the conversation store itself.
        let nonSystem = messages.filter { $0.role != "system" }
        let oldCount = max(0, nonSystem.count - kThreadCompactionKeepCount)
        let oldMessages: [MessageStruct] = oldCount > 0
            ? Array(nonSystem.prefix(oldCount))
            : []

        // Check if there's already a compaction summary in the thread.
        let existingSummary = nonSystem.first(where: { $0.isCompactionSummary })?.content ?? ""

        var oldMessagesSerialized = ""
        for msg in oldMessages where !msg.isCompactionSummary {
            oldMessagesSerialized += "[\(msg.role)] \(msg.content)\n---\n"
        }

        let archiveName = archiveFilename()
        let exampleTimestamp = ISO8601DateFormatter().string(from: Date())

        // Thread compaction section — only included when there are enough
        // messages to warrant summarization.
        let threadSection: String
        if oldCount > 0 {
            let priorNote = existingSummary.isEmpty
                ? ""
                : "There is an existing compaction summary that must be incorporated:\n\(existingSummary)\n\n"
            threadSection = """
            The oldest \(oldCount) messages need to be summarized.

            \(priorNote)Here are the messages to summarize (oldest first):
            \(oldMessagesSerialized)
            Produce a running conversation summary that preserves:
            - File paths and project names mentioned
            - Decisions made and their rationale
            - Specs created or referenced
            - Names, links, key numbers
            - Any other concrete artifacts

            Use `file_write` to write the summary to \
            `memory/.compaction_summary_\(conversationId).md` \
            (overwrite mode). This file will be picked up by the next foreground \
            turn automatically.
            """
        } else {
            threadSection = "No thread compaction needed (≤ \(kThreadCompactionKeepCount) messages)."
        }

        return """
        You are a context-compaction sub-agent. Your job is to reduce the \
        size of Loop's context window by compacting self-docs and the \
        conversation thread. Do both tasks, then post a single summary line.

        ## Task 1: Self-doc compaction

        Use `read_self_doc` to read MEMORY.md, AGENTS.md, and HEARTBEAT.md.
        For each:
        1. Deduplicate, cluster related items, and tighten prose while \
           preserving all meaning and concrete facts.
        2. Items that are stale, superseded, or no longer actionable should \
           be moved to an archive file. Use `file_write` with mode "append" \
           to append them to `memory/archive/\(archiveName).md` \
           (create if missing).
        3. Use `update_self_doc` to write the compacted version back.
        4. NEVER touch SOUL.md or USER.md — those are identity, not knowledge.

        Current sizes (chars):
        - MEMORY.md: \(memoryChars)
        - AGENTS.md: \(agentsChars)
        - HEARTBEAT.md: \(heartbeatChars)

        ## Task 2: Thread compaction

        The active conversation has \(threadCount) non-system messages.
        \(threadSection)

        ## Completion

        After finishing both tasks, use `file_write` to overwrite \
        `memory/.last_compaction` with the current ISO 8601 timestamp \
        (e.g. "\(exampleTimestamp)").

        Your final plain-text reply (which gets posted back to the user) \
        MUST be exactly one line in this format:
        Compacted: MEMORY Xk → Yk chars, AGENTS Xk → Yk chars, \
        HEARTBEAT Xk → Yk chars, thread N → M turns + summary
        (Use the actual before/after sizes. If a doc didn't change, still \
        list it with the same size on both sides. If no thread compaction \
        was done, say "thread: no change".)
        """
    }

    /// YYYY-MM filename for the archive.
    private static func archiveFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }

    // MARK: - Thread compaction helpers

    /// Read the compaction summary file for a conversation, if it exists.
    static func loadThreadSummary(conversationId: String) -> String? {
        let path = "memory/.compaction_summary_\(conversationId).md"
        guard let url = try? Workspace.shared.resolve(path),
              FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return content
    }

    /// Given all messages for a conversation, return the model-facing
    /// compacted form: compaction summary (if any) + the last N messages.
    /// The UI continues to show full history.
    static func compactedMessages(all messages: [MessageStruct],
                                  conversationId: String) -> [MessageStruct] {
        // Separate system messages from the rest.
        let systemMessages = messages.filter { $0.role == "system" }
        let nonSystem = messages.filter { $0.role != "system" }

        // If there's a persisted compaction summary and we have enough
        // messages to warrant using it, apply thread compaction.
        if let summary = loadThreadSummary(conversationId: conversationId),
           nonSystem.count > kThreadCompactionKeepCount {

            // Check if there's already a compaction summary message in the
            // thread (from a previous compaction run).
            var keptMessages = Array(nonSystem.suffix(kThreadCompactionKeepCount))

            // Remove any existing compaction summary from the kept window
            // (it shouldn't be there, but be safe).
            keptMessages.removeAll { $0.isCompactionSummary }

            // Build a synthetic system-style summary message.
            var summaryMessage = MessageStruct(
                role: "system",
                content: "# Conversation Summary (compacted)\n\n\(summary)"
            )
            summaryMessage.isCompactionSummary = true

            return systemMessages + [summaryMessage] + keptMessages
        }

        return messages
    }
}
