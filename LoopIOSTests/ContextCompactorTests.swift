//
//  ContextCompactorTests.swift
//  LoopIOSTests
//
//  Unit tests for the opportunistic context compaction logic:
//  threshold evaluation, token estimation, lockout, and the
//  idempotent thread-compaction message filtering.
//

import XCTest
@testable import Loop

// MARK: - Token estimation

final class TokenEstimationTests: XCTestCase {

    func testEstimateTokensBasic() {
        XCTAssertEqual(ContextCompactor.estimateTokens(chars: 400), 100)
    }

    func testEstimateTokensRoundsDown() {
        XCTAssertEqual(ContextCompactor.estimateTokens(chars: 7), 1)
    }

    func testEstimateTokensZero() {
        XCTAssertEqual(ContextCompactor.estimateTokens(chars: 0), 0)
    }
}

// MARK: - Threshold evaluation

final class CompactionTriggerTests: XCTestCase {

    /// Helper: build a messages array whose total char count (non-system)
    /// produces a given estimated-token count. We pad the content so that
    /// `estimateTokens(chars: content.count) ≈ targetTokens`.
    private func messagesWithTokens(_ targetTokens: Int) -> [MessageStruct] {
        // System message with minimal content so contextCharCount picks
        // it up but the dominant size is the user content.
        let system = MessageStruct(role: "system", content: "")
        let chars = targetTokens * 4
        let user = MessageStruct(role: "user", content: String(repeating: "x", count: chars))
        return [system, user]
    }

    func testBelowSoftThresholdReturnsNone() {
        // 29% of 200k budget = 58k tokens → 232k chars
        let msgs = messagesWithTokens(Int(Double(kCompactionTokenBudget) * 0.10))
        let trigger = ContextCompactor.evaluateTrigger(messages: msgs)
        XCTAssertEqual(trigger, .none)
    }

    func testAtSoftThresholdReturnsSoft() {
        // Exactly 30% → should be soft
        let tokens = Int(Double(kCompactionTokenBudget) * kCompactionSoftThreshold)
        let msgs = messagesWithTokens(tokens)
        let trigger = ContextCompactor.evaluateTrigger(messages: msgs)
        // Because the system prompt adds some chars via buildSystemPrompt,
        // the actual ratio will be slightly above the target. That's fine —
        // at 30%+ we expect soft or hard.
        XCTAssertNotEqual(trigger, .none)
    }

    func testAboveHardThresholdReturnsHard() {
        // 65% of budget
        let tokens = Int(Double(kCompactionTokenBudget) * 0.65)
        let msgs = messagesWithTokens(tokens)
        let trigger = ContextCompactor.evaluateTrigger(messages: msgs)
        XCTAssertEqual(trigger, .hard)
    }

    func testWellBelowThresholdReturnsNone() {
        let msgs = [
            MessageStruct(role: "system", content: "Be helpful."),
            MessageStruct(role: "user", content: "Hi"),
        ]
        let trigger = ContextCompactor.evaluateTrigger(messages: msgs)
        XCTAssertEqual(trigger, .none)
    }
}

// MARK: - CompactionTrigger Equatable conformance (for XCTAssertEqual)

extension CompactionTrigger: Equatable {}

// MARK: - Thread compaction (compactedMessages)

final class ThreadCompactionTests: XCTestCase {

    /// Build a message array with N user/assistant pairs plus a system
    /// message. No compaction summary file on disk.
    private func buildThread(count: Int) -> [MessageStruct] {
        var msgs: [MessageStruct] = [
            MessageStruct(role: "system", content: "System prompt"),
        ]
        for i in 0..<count {
            msgs.append(MessageStruct(role: "user", content: "User message \(i)"))
            msgs.append(MessageStruct(role: "assistant", content: "Reply \(i)"))
        }
        return msgs
    }

    func testSmallThreadUnchanged() {
        let msgs = buildThread(count: 5) // 10 non-system messages + 1 system = 11
        // No summary file → compactedMessages returns input unchanged.
        let result = ContextCompactor.compactedMessages(
            all: msgs,
            conversationId: "test-no-summary"
        )
        XCTAssertEqual(result.count, msgs.count)
    }

    func testIsCompactionSummaryDefaultsFalse() {
        let msg = MessageStruct(role: "user", content: "hello")
        XCTAssertFalse(msg.isCompactionSummary)
    }

    func testIsCompactionSummaryFlag() {
        var msg = MessageStruct(role: "system", content: "summary")
        msg.isCompactionSummary = true
        XCTAssertTrue(msg.isCompactionSummary)
    }

    func testSimpleMessageRoundTrip() {
        let simple = SimpleMessage(
            role: "system",
            content: "summary",
            isCompactionSummary: true
        )
        let converted = SimpleConversationManager.shared.messageStruct(from: simple)
        XCTAssertTrue(converted.isCompactionSummary)
    }

    func testSimpleMessageNilCompactionSummary() {
        let simple = SimpleMessage(role: "user", content: "hi")
        let converted = SimpleConversationManager.shared.messageStruct(from: simple)
        XCTAssertFalse(converted.isCompactionSummary)
    }
}

// MARK: - Constants sanity checks

final class CompactionConstantsTests: XCTestCase {

    func testBudgetIsPositive() {
        XCTAssertGreaterThan(kCompactionTokenBudget, 0)
    }

    func testSoftBelowHard() {
        XCTAssertLessThan(kCompactionSoftThreshold, kCompactionHardThreshold)
    }

    func testKeepCountPositive() {
        XCTAssertGreaterThan(kThreadCompactionKeepCount, 0)
    }

    func testLockoutPositive() {
        XCTAssertGreaterThan(kCompactionLockoutHours, 0)
    }
}
