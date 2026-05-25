//
//  HealthKitManagerTests.swift
//  LoopIOSTests
//
//  Unit tests for the HealthKit integration layer. Because HKHealthStore
//  cannot be meaningfully instantiated in a test host that lacks the
//  HealthKit entitlement, these tests exercise the pure-logic helpers
//  (date range computation, workout formatting, ISO serialisation) and
//  verify the HealthSkill's routing / error handling with a lightweight
//  mock approach.
//
//  Privacy: no real Health data is involved.
//

#if canImport(HealthKit) && os(iOS)
import XCTest
import HealthKit
@testable import Loop

// MARK: - HealthKitManager date helpers

final class HealthKitManagerDateTests: XCTestCase {

    func testTodayRangeStartsAtMidnight() {
        let range = HealthKitManager.todayRange()
        let cal = Calendar.current
        XCTAssertEqual(cal.startOfDay(for: Date()), range.start)
        XCTAssertTrue(range.end <= Date().addingTimeInterval(1))
    }

    func testYesterdayRangeIsOneDayBehind() {
        let range = HealthKitManager.yesterdayRange()
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let expectedStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        XCTAssertEqual(range.start, expectedStart)
        XCTAssertEqual(range.end, todayStart)
    }

    func testLast7DaysRangeSpans7Days() {
        let range = HealthKitManager.last7DaysRange()
        let interval = range.end.timeIntervalSince(range.start)
        // Should be approximately 7 days (604800s), with minor clock skew tolerance.
        XCTAssertTrue(interval > 604790 && interval < 604810)
    }

    func testRangeForKnownNames() {
        XCTAssertNotNil(HealthKitManager.rangeFor("today"))
        XCTAssertNotNil(HealthKitManager.rangeFor("Yesterday"))
        XCTAssertNotNil(HealthKitManager.rangeFor("this_week"))
        XCTAssertNotNil(HealthKitManager.rangeFor("LAST_7_DAYS"))
        XCTAssertNil(HealthKitManager.rangeFor("next_month"))
    }

    func testCustomRangeParsingValidISO() {
        let r = HealthKitManager.customRange(
            startISO: "2026-05-20T00:00:00Z",
            endISO: "2026-05-21T00:00:00Z"
        )
        XCTAssertNotNil(r)
        if let r {
            XCTAssertEqual(r.end.timeIntervalSince(r.start), 86400, accuracy: 1)
        }
    }

    func testCustomRangeParsingInvalid() {
        let r = HealthKitManager.customRange(startISO: "not-a-date", endISO: "also-not")
        XCTAssertNil(r)
    }
}

// MARK: - Workout formatting

final class HealthKitManagerFormattingTests: XCTestCase {

    func testFormatDurationMinutesOnly() {
        XCTAssertEqual(HealthKitManager.formatDuration(1800), "30m")
    }

    func testFormatDurationHoursAndMinutes() {
        XCTAssertEqual(HealthKitManager.formatDuration(5400), "1h 30m")
    }

    func testFormatDurationZero() {
        XCTAssertEqual(HealthKitManager.formatDuration(0), "0m")
    }
}

// MARK: - HealthSkill routing

final class HealthSkillRoutingTests: XCTestCase {

    func testHandlesKnownToolNames() {
        let skill = HealthSkill.shared
        XCTAssertTrue(skill.handles(functionName: "health_today_summary"))
        XCTAssertTrue(skill.handles(functionName: "health_active_workout"))
        XCTAssertTrue(skill.handles(functionName: "health_query"))
    }

    func testDoesNotHandleUnknownNames() {
        XCTAssertFalse(HealthSkill.shared.handles(functionName: "list_upcoming_events"))
        XCTAssertFalse(HealthSkill.shared.handles(functionName: "health_write"))
    }

    func testStatusTextMapping() {
        let skill = HealthSkill.shared
        let summaryCall = FunctionCallStruct(name: "health_today_summary", arguments: [:])
        XCTAssertEqual(skill.statusText(for: summaryCall), "checking your health summary")

        let workoutCall = FunctionCallStruct(name: "health_active_workout", arguments: [:])
        XCTAssertEqual(skill.statusText(for: workoutCall), "checking for an active workout")

        let queryCall = FunctionCallStruct(name: "health_query",
                                           arguments: ["metric": "steps", "range": "today"])
        XCTAssertEqual(skill.statusText(for: queryCall), "querying steps")

        let unknownCall = FunctionCallStruct(name: "something_else", arguments: [:])
        XCTAssertNil(skill.statusText(for: unknownCall))
    }

    func testToolSchemasAreValid() {
        // Each schema entry must have "type" and "function" with a "name".
        for schema in HealthSkill.tools {
            XCTAssertEqual(schema["type"] as? String, "function")
            let fn = schema["function"] as? [String: Any]
            XCTAssertNotNil(fn)
            XCTAssertNotNil(fn?["name"] as? String)
            XCTAssertNotNil(fn?["parameters"] as? [String: Any])
        }
        XCTAssertEqual(HealthSkill.tools.count, 3)
    }

    /// When Health is not authorized the skill should return a structured
    /// error rather than crashing. On a test host (no entitlement),
    /// authorization status will be notDetermined or unavailable.
    func testUnavailableOrNotAuthorizedReturnsStructuredError() {
        let exp = expectation(description: "completion called")
        let call = FunctionCallStruct(name: "health_today_summary", arguments: [:])
        HealthSkill.shared.handle(functionCall: call) { msg in
            XCTAssertEqual(msg.role, "function")
            // Should contain an error field
            if let data = msg.content.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                XCTAssertNotNil(json["error"])
            }
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
    }
}

// MARK: - HealthKitManager read types

final class HealthKitManagerReadTypesTests: XCTestCase {

    func testReadTypesContainsExpectedTypes() {
        let types = HealthKitManager.readTypes
        // Should include step count, heart rate, workouts, sleep, etc.
        XCTAssertTrue(types.contains(HKObjectType.workoutType()))
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            XCTAssertTrue(types.contains(steps))
        }
        if let hr = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            XCTAssertTrue(types.contains(hr))
        }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            XCTAssertTrue(types.contains(sleep))
        }
        if let bm = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            XCTAssertTrue(types.contains(bm))
        }
    }
}

#endif
