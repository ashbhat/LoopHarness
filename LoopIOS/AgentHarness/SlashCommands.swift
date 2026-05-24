//
//  SlashCommands.swift
//  Loop
//
//  Built from LoopIOS/Specs/slash_command_spec.md.
//

import Foundation

/// Side-effect surface used by AgentHarness to apply slash-command actions
/// that mutate the visible UI/conversation state. The host (typically the
/// MessagingVC instance) implements these on the main thread.
///
/// Kept narrow on purpose: every method is a single user-visible action
/// triggered by exactly one command.
protocol SlashCommandHost: AnyObject {
    /// Same effect as tapping the "new chat" button.
    func slashCommandDidRequestNewChat()
    /// Clear the active chat in memory (system message preserved).
    func slashCommandDidRequestReset()
    /// Replace the active message history with a trimmed list. The first
    /// element is the system message; everything after is the kept tail.
    func slashCommandDidRequestCompact(_ compactedMessages: [MessageStruct])
}

/// Parses and executes /slash commands at the start of a user message before
/// any inference call is made. AgentHarness routes here from `chat()`.
///
/// Recognized commands:
/// - /status   — model + token usage, deterministic.
/// - /compact  — drop oldest non-system messages until the conversation is
///               under a token target. Reports what was trimmed.
/// - /new      — open a fresh chat thread (same as the new-chat button).
/// - /reset    — clear the active chat (system message preserved).
struct SlashCommands {

    enum Command: String, CaseIterable {
        case status, compact, new, reset
    }

    /// Returns the matched command if `text` begins with `/<known>`. Anything
    /// else (including unknown slash commands like `/foo`) returns nil so the
    /// message goes through the normal LLM path.
    static func parse(_ text: String) -> Command? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let firstToken = trimmed.dropFirst()
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map { String($0).lowercased() } ?? ""
        return Command(rawValue: firstToken)
    }

    /// Run the command. Side effects are dispatched through `host` first so
    /// that by the time the deterministic reply is delivered, the UI has
    /// already updated (e.g. the new-chat conversation is current, or the
    /// chat has been cleared) and the reply lands in the resulting view.
    static func handle(_ command: Command,
                       harness: AgentHarness,
                       messages: [MessageStruct],
                       host: SlashCommandHost?) -> MessageStruct {
        switch command {
        case .status:
            return statusMessage(harness: harness, messages: messages)
        case .new:
            host?.slashCommandDidRequestNewChat()
            return reply("Started a new chat.")
        case .reset:
            host?.slashCommandDidRequestReset()
            return reply("Cleared the conversation.")
        case .compact:
            return compactMessage(harness: harness, messages: messages, host: host)
        }
    }

    // MARK: - Token estimation

    /// OpenAI-tokenizer rule of thumb: ~4 characters per token for English
    /// prose. Slightly conservative (real-world is closer to 3.5) so we
    /// don't under-report usage.
    private static let charsPerToken = 4.0

    /// Context window the spec calls out for /status reporting.
    private static let contextWindow = 1_000_000

    private static func estimateTokens(_ text: String) -> Int {
        return Int((Double(text.count) / charsPerToken).rounded())
    }

    // MARK: - /status

    private static func statusMessage(harness: AgentHarness,
                                      messages: [MessageStruct]) -> MessageStruct {
        // Rebuild the system prompt the same way chat() does so the count
        // matches what the model would actually receive. The base
        // instructions are whatever's in the existing system message.
        let baseSystem = messages.first(where: { $0.role == "system" })?.content ?? ""
        let composedSystem = harness.buildSystemPrompt(base: baseSystem)
        let nonSystem = messages.filter { $0.role != "system" }

        let systemTokens = estimateTokens(composedSystem)
        let messageTokens = nonSystem.reduce(0) { $0 + estimateTokens($1.content) }
        let total = systemTokens + messageTokens
        let percent = Double(total) / Double(contextWindow) * 100.0

        // Most recent assistant message carries the live model label that
        // came back from the proxy. Falls back to the struct default.
        let model = nonSystem.last(where: { $0.role == "assistant" })?.model
            ?? messages.last?.model
            ?? "GPT 5.5 Instant"

        let nonSystemCount = nonSystem.count
        let systemStr = systemTokens.formatted()
        let messageStr = messageTokens.formatted()
        let totalStr = total.formatted()
        let windowStr = contextWindow.formatted()
        let percentStr = String(format: "%.2f%%", percent)

        let body = """
        📊 Status

        Model: \(model)
        Messages: 1 system + \(nonSystemCount) conversation
        System prompt: ~\(systemStr) tokens
        Conversation:  ~\(messageStr) tokens
        Total: ~\(totalStr) / \(windowStr) (\(percentStr))
        """
        return reply(body)
    }

    // MARK: - /compact

    /// Stop trimming once estimated total drops below this. Conservative —
    /// we want headroom for the next few turns, not just to barely fit.
    private static let compactionTokenTarget = 50_000

    /// Always preserve at least this many of the most recent messages so
    /// the active context survives a /compact even if older turns alone
    /// exceed the target.
    private static let compactionKeepRecent = 20

    private static func compactMessage(harness: AgentHarness,
                                       messages: [MessageStruct],
                                       host: SlashCommandHost?) -> MessageStruct {
        let baseSystem = messages.first(where: { $0.role == "system" })?.content ?? ""
        let systemMessage = messages.first(where: { $0.role == "system" })
        var nonSystem = messages.filter { $0.role != "system" }
        let composedSystem = harness.buildSystemPrompt(base: baseSystem)
        let systemTokens = estimateTokens(composedSystem)

        let beforeMessages = nonSystem.count
        let beforeTokens = systemTokens + nonSystem.reduce(0) { $0 + estimateTokens($1.content) }

        var dropped = 0
        while nonSystem.count > compactionKeepRecent {
            let totalTokens = systemTokens + nonSystem.reduce(0) { $0 + estimateTokens($1.content) }
            if totalTokens <= compactionTokenTarget { break }
            nonSystem.removeFirst()
            dropped += 1
        }

        let afterTokens = systemTokens + nonSystem.reduce(0) { $0 + estimateTokens($1.content) }
        let saved = max(0, beforeTokens - afterTokens)

        // Reassemble: system at slot 0 (matching the rest of the codebase's
        // assumption), then the trimmed conversation tail.
        var compacted: [MessageStruct] = []
        if let system = systemMessage { compacted.append(system) }
        compacted.append(contentsOf: nonSystem)
        host?.slashCommandDidRequestCompact(compacted)

        let targetStr = compactionTokenTarget.formatted()
        let beforeTokensStr = beforeTokens.formatted()
        let afterTokensStr = afterTokens.formatted()
        let savedStr = saved.formatted()
        let afterCount = nonSystem.count

        let body: String
        if dropped == 0 {
            body = """
            🧹 Compact

            Nothing to drop — already under \(targetStr) tokens.
            \(beforeMessages) messages, ~\(beforeTokensStr) tokens.
            """
        } else {
            body = """
            🧹 Compact

            Dropped \(dropped) of the oldest messages.
            Before: \(beforeMessages) msgs, ~\(beforeTokensStr) tokens
            After:  \(afterCount) msgs, ~\(afterTokensStr) tokens
            Saved:  ~\(savedStr) tokens
            """
        }
        return reply(body)
    }

    // MARK: - Reply helper

    private static func reply(_ content: String) -> MessageStruct {
        // "Slash Command" model label so the UI can distinguish these from
        // real LLM responses if it wants to (currently shown verbatim under
        // each message bubble).
        return MessageStruct(role: "assistant", content: content, model: "Slash Command")
    }
}
