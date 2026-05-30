//
//  LoopRunnerPollerTests.swift
//  LoopIOSTests
//
//  Unit tests for LoopRunnerPoller. Verifies since-cursor advancement,
//  notification deduplication, and runner-notification classification.
//

import XCTest
@testable import Loop

final class LoopRunnerPollerTests: XCTestCase {

    private let testRunnerId = "test-runner-\(UUID().uuidString)"

    override func tearDown() {
        LoopRunnerPoller.shared.clearState(for: testRunnerId)
        super.tearDown()
    }

    // MARK: - Since cursor

    func testLastSinceDefaultsToDistantPast() {
        let since = LoopRunnerPoller.shared.lastSince(for: testRunnerId, kind: "turns")
        XCTAssertEqual(since, Date.distantPast)
    }

    func testSetAndReadLastSince() {
        let now = Date()
        LoopRunnerPoller.shared.setLastSince(now, for: testRunnerId, kind: "turns")
        let stored = LoopRunnerPoller.shared.lastSince(for: testRunnerId, kind: "turns")
        XCTAssertEqual(stored.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.01)
    }

    func testTurnsAndJobsCursorsAreIndependent() {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let poller = LoopRunnerPoller.shared

        poller.setLastSince(date1, for: testRunnerId, kind: "turns")
        poller.setLastSince(date2, for: testRunnerId, kind: "jobs")

        XCTAssertEqual(
            poller.lastSince(for: testRunnerId, kind: "turns").timeIntervalSince1970,
            1000, accuracy: 0.01
        )
        XCTAssertEqual(
            poller.lastSince(for: testRunnerId, kind: "jobs").timeIntervalSince1970,
            2000, accuracy: 0.01
        )
    }

    func testClearStateRemovesCursors() {
        let poller = LoopRunnerPoller.shared
        poller.setLastSince(Date(), for: testRunnerId, kind: "turns")
        poller.setLastSince(Date(), for: testRunnerId, kind: "jobs")

        poller.clearState(for: testRunnerId)

        XCTAssertEqual(poller.lastSince(for: testRunnerId, kind: "turns"), Date.distantPast)
        XCTAssertEqual(poller.lastSince(for: testRunnerId, kind: "jobs"), Date.distantPast)
    }

    // MARK: - Notification classification

    func testIsRunnerNotificationForTurn() {
        let userInfo: [AnyHashable: Any] = [
            "type": "runner_turn",
            "runner_id": "r1",
            "turn_id": "t1",
        ]
        XCTAssertTrue(LoopRunnerPoller.isRunnerNotification(userInfo))
    }

    func testIsRunnerNotificationForJob() {
        let userInfo: [AnyHashable: Any] = [
            "type": "runner_job",
            "runner_id": "r1",
            "job_id": "j1",
            "turn_id": "t1",
        ]
        XCTAssertTrue(LoopRunnerPoller.isRunnerNotification(userInfo))
    }

    func testIsNotRunnerNotificationForScheduler() {
        let userInfo: [AnyHashable: Any] = [
            "type": "scheduler",
            "job_id": "j1",
        ]
        XCTAssertFalse(LoopRunnerPoller.isRunnerNotification(userInfo))
    }

    func testIsNotRunnerNotificationForEmpty() {
        XCTAssertFalse(LoopRunnerPoller.isRunnerNotification([:]))
    }

    // MARK: - UserInfo extraction

    func testTurnIdExtraction() {
        let userInfo: [AnyHashable: Any] = ["turn_id": "t-42"]
        XCTAssertEqual(LoopRunnerPoller.turnId(from: userInfo), "t-42")
    }

    func testRunnerIdExtraction() {
        let userInfo: [AnyHashable: Any] = ["runner_id": "r-7"]
        XCTAssertEqual(LoopRunnerPoller.runnerId(from: userInfo), "r-7")
    }

    func testMissingKeysReturnNil() {
        XCTAssertNil(LoopRunnerPoller.turnId(from: [:]))
        XCTAssertNil(LoopRunnerPoller.runnerId(from: [:]))
    }

    // MARK: - RunnerConfig model

    func testRunnerConfigGeneratesSecretRef() {
        let config = RunnerConfig(nickname: "Test", baseURL: "https://example.com")
        XCTAssertTrue(config.secretRef.hasPrefix("com.loop.runner.secret."))
        XCTAssertEqual(config.lastSeenTurnCount, 0)
    }

    func testRunnerConfigEquality() {
        let a = RunnerConfig(id: "x", nickname: "A", baseURL: "https://a.com")
        var b = RunnerConfig(id: "x", nickname: "A", baseURL: "https://a.com")
        b.lastSeenTurnCount = 5
        // Different lastSeenTurnCount → not equal
        XCTAssertNotEqual(a, b)
    }
}
