//
//  ConversationScopingTests.swift
//  LoopIOSTests
//
//  Unit tests verifying multi-conversation isolation: message scoping,
//  running-indicator computation, preview content, and conversation
//  switching. These exercise the pure-logic data layer and tracker
//  without requiring a live UI host.
//

import XCTest
@testable import Loop

// MARK: - ActiveRequestTracker

final class ActiveRequestTrackerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset shared state between tests.
        ActiveRequestTracker.shared.markIdle("conv-A")
        ActiveRequestTracker.shared.markIdle("conv-B")
    }

    func testMarkActiveAndIdle() {
        let tracker = ActiveRequestTracker.shared
        XCTAssertFalse(tracker.isActive(for: "conv-A"))
        tracker.markActive("conv-A")
        XCTAssertTrue(tracker.isActive(for: "conv-A"))
        XCTAssertFalse(tracker.isActive(for: "conv-B"))
        tracker.markIdle("conv-A")
        XCTAssertFalse(tracker.isActive(for: "conv-A"))
    }

    func testMultipleConversationsIndependent() {
        let tracker = ActiveRequestTracker.shared
        tracker.markActive("conv-A")
        tracker.markActive("conv-B")
        XCTAssertTrue(tracker.isActive(for: "conv-A"))
        XCTAssertTrue(tracker.isActive(for: "conv-B"))
        tracker.markIdle("conv-A")
        XCTAssertFalse(tracker.isActive(for: "conv-A"))
        XCTAssertTrue(tracker.isActive(for: "conv-B"))
    }

    func testIdempotentMarkIdle() {
        let tracker = ActiveRequestTracker.shared
        tracker.markIdle("conv-X")
        XCTAssertFalse(tracker.isActive(for: "conv-X"))
    }
}

// MARK: - Conversation struct isRunning

final class ConversationIsRunningTests: XCTestCase {

    func testDefaultIsNotRunning() {
        let c = Conversation(id: "1", title: "Test", lastMessage: "", timestamp: Date())
        XCTAssertFalse(c.isRunning)
    }

    func testExplicitRunningFlag() {
        let c = Conversation(id: "2", title: "Test", lastMessage: "", timestamp: Date(), isRunning: true)
        XCTAssertTrue(c.isRunning)
    }
}

// MARK: - conversationStruct projection

final class ConversationStructProjectionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ActiveRequestTracker.shared.markIdle("proj-A")
    }

    override func tearDown() {
        ActiveRequestTracker.shared.markIdle("proj-A")
        super.tearDown()
    }

    func testProjectionIncludesLastMessage() {
        let msg = SimpleMessage(role: "assistant", content: "Hello there")
        let sc = SimpleConversation(id: "proj-A", title: "Chat", messages: [msg])
        let projected = SimpleConversationManager.shared.conversationStruct(from: sc)
        XCTAssertEqual(projected.lastMessage, "Hello there")
        XCTAssertEqual(projected.title, "Chat")
    }

    func testProjectionReflectsActiveTracker() {
        let sc = SimpleConversation(id: "proj-A", title: "Chat")
        ActiveRequestTracker.shared.markActive("proj-A")
        let projected = SimpleConversationManager.shared.conversationStruct(from: sc)
        XCTAssertTrue(projected.isRunning)
    }

    func testProjectionIdleWhenNoActivity() {
        let sc = SimpleConversation(id: "proj-A", title: "Chat")
        let projected = SimpleConversationManager.shared.conversationStruct(from: sc)
        // No sub-agents and no active request → not running.
        XCTAssertFalse(projected.isRunning)
    }
}

// MARK: - Message isolation

final class MessageIsolationTests: XCTestCase {

    func testMessagesAppendOnlyToTargetConversation() {
        let manager = SimpleConversationManager.shared
        let convA = manager.createConversation(title: "Conv A (test)")
        let convB = manager.createConversation(title: "Conv B (test)")

        let msgA = MessageStruct(role: "user", content: "Hello A")
        let msgB = MessageStruct(role: "user", content: "Hello B")

        manager.addMessage(msgA, to: convA)
        manager.addMessage(msgB, to: convB)

        let msgsA = manager.getMessages(for: convA)
        let msgsB = manager.getMessages(for: convB)
        XCTAssertTrue(msgsA.contains(where: { $0.content == "Hello A" }))
        XCTAssertFalse(msgsA.contains(where: { $0.content == "Hello B" }))
        XCTAssertTrue(msgsB.contains(where: { $0.content == "Hello B" }))
        XCTAssertFalse(msgsB.contains(where: { $0.content == "Hello A" }))

        // Cleanup
        manager.deleteConversation(convA)
        manager.deleteConversation(convB)
    }
}
