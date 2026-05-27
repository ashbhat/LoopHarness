//
//  SchedulerWeekdayTests.swift
//  LoopIOSTests
//
//  Unit tests for the weekday-filtering additions to BackgroundScheduler's
//  Trigger type.  These exercise pure-logic helpers (no real notifications,
//  no real BGTaskScheduler), so they run on any host.
//

import XCTest
@testable import Loop

final class SchedulerWeekdayTests: XCTestCase {

    // MARK: - Trigger.isAllowedWeekday

    func testIsAllowedWeekdayNilMeansEveryDay() {
        let trigger = Trigger(hour: 9, minute: 0, occurrences: nil,
                              firstDate: nil, regenerate: true, weekdays: nil)
        // Should be allowed on every day of the week.
        let cal = Calendar.current
        let monday = dateForWeekday(2)
        let saturday = dateForWeekday(7)
        let sunday = dateForWeekday(1)
        XCTAssertTrue(trigger.isAllowedWeekday(monday, calendar: cal))
        XCTAssertTrue(trigger.isAllowedWeekday(saturday, calendar: cal))
        XCTAssertTrue(trigger.isAllowedWeekday(sunday, calendar: cal))
    }

    func testIsAllowedWeekdayEmptyArrayMeansEveryDay() {
        let trigger = Trigger(hour: 9, minute: 0, occurrences: nil,
                              firstDate: nil, regenerate: true, weekdays: [])
        let saturday = dateForWeekday(7)
        XCTAssertTrue(trigger.isAllowedWeekday(saturday))
    }

    func testIsAllowedWeekdayMonThroughFri() {
        // 2=Mon, 3=Tue, 4=Wed, 5=Thu, 6=Fri
        let trigger = Trigger(hour: 9, minute: 0, occurrences: nil,
                              firstDate: nil, regenerate: true,
                              weekdays: [2, 3, 4, 5, 6])
        let monday    = dateForWeekday(2)
        let friday    = dateForWeekday(6)
        let saturday  = dateForWeekday(7)
        let sunday    = dateForWeekday(1)

        XCTAssertTrue(trigger.isAllowedWeekday(monday))
        XCTAssertTrue(trigger.isAllowedWeekday(friday))
        XCTAssertFalse(trigger.isAllowedWeekday(saturday))
        XCTAssertFalse(trigger.isAllowedWeekday(sunday))
    }

    // MARK: - nextFireDate skips disallowed days

    func testNextFireDateSkipsSaturdayAndSunday() {
        let scheduler = BackgroundScheduler.shared
        // Mon–Fri only
        let trigger = Trigger(hour: 9, minute: 0, occurrences: nil,
                              firstDate: nil, regenerate: true,
                              weekdays: [2, 3, 4, 5, 6])

        // Construct a Saturday at 08:00 so the scheduler must skip to Monday.
        let saturday8am = nextDateForWeekday(7, hour: 8, minute: 0)
        let fire = scheduler.nextFireDate(for: trigger, after: saturday8am)

        let cal = Calendar.current
        let wd = cal.component(.weekday, from: fire)
        // Should land on Monday (2).
        XCTAssertEqual(wd, 2, "Expected Monday (2) but got weekday \(wd)")
        XCTAssertEqual(cal.component(.hour, from: fire), 9)
        XCTAssertEqual(cal.component(.minute, from: fire), 0)
    }

    func testNextFireDateAllowedTodayDoesNotSkip() {
        let scheduler = BackgroundScheduler.shared
        // Wednesday only
        let trigger = Trigger(hour: 23, minute: 59, occurrences: nil,
                              firstDate: nil, regenerate: true,
                              weekdays: [4])

        let wednesday0800 = nextDateForWeekday(4, hour: 8, minute: 0)
        let fire = scheduler.nextFireDate(for: trigger, after: wednesday0800)

        let cal = Calendar.current
        XCTAssertEqual(cal.component(.weekday, from: fire), 4)
        XCTAssertEqual(cal.component(.hour, from: fire), 23)
    }

    // MARK: - Codable round-trip preserves weekdays

    func testTriggerCodableRoundTrip() throws {
        let original = Trigger(hour: 7, minute: 30, occurrences: 5,
                               firstDate: nil, regenerate: false,
                               weekdays: [2, 3, 4, 5, 6])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Trigger.self, from: data)
        XCTAssertEqual(decoded.weekdays, [2, 3, 4, 5, 6])
        XCTAssertEqual(decoded.hour, 7)
        XCTAssertEqual(decoded.minute, 30)
        XCTAssertEqual(decoded.occurrences, 5)
    }

    func testTriggerCodableNilWeekdays() throws {
        let original = Trigger(hour: 9, minute: 0, occurrences: nil,
                               firstDate: nil, regenerate: true,
                               weekdays: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Trigger.self, from: data)
        XCTAssertNil(decoded.weekdays)
    }

    // MARK: - scheduleDescription includes weekday suffix

    func testScheduleDescriptionMonFri() {
        let job = ScheduledJob(
            id: "test-1",
            title: "standup",
            trigger: Trigger(hour: 9, minute: 0, occurrences: nil,
                             firstDate: nil, regenerate: true,
                             weekdays: [2, 3, 4, 5, 6]),
            payload: .prompt(user: "standup", system: nil),
            prefetchWindowHours: 4,
            voiceDelivery: false,
            createdAt: Date(),
            lastRunAt: nil,
            lastResult: nil,
            firingsCompleted: 0
        )
        let desc = BackgroundScheduler.shared.scheduleDescription(for: job)
        XCTAssertTrue(desc.contains("Mon–Fri"), "Expected Mon–Fri in '\(desc)'")
        XCTAssertTrue(desc.contains("09:00"))
    }

    func testScheduleDescriptionAllDaysHasNoSuffix() {
        let job = ScheduledJob(
            id: "test-2",
            title: "daily",
            trigger: Trigger(hour: 8, minute: 0, occurrences: nil,
                             firstDate: nil, regenerate: true,
                             weekdays: nil),
            payload: .prompt(user: "daily", system: nil),
            prefetchWindowHours: 4,
            voiceDelivery: false,
            createdAt: Date(),
            lastRunAt: nil,
            lastResult: nil,
            firingsCompleted: 0
        )
        let desc = BackgroundScheduler.shared.scheduleDescription(for: job)
        XCTAssertEqual(desc, "daily at 08:00")
    }

    // MARK: - Helpers

    /// Return a Date that falls on the given weekday (1=Sun … 7=Sat) at noon,
    /// relative to the current week.
    private func dateForWeekday(_ weekday: Int) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let todayWD = cal.component(.weekday, from: today)
        let offset = (weekday - todayWD + 7) % 7
        var d = cal.date(byAdding: .day, value: offset == 0 ? 0 : offset, to: today)!
        d = cal.date(bySettingHour: 12, minute: 0, second: 0, of: d)!
        return d
    }

    /// Return a future Date on the given weekday at the specified hour:minute.
    private func nextDateForWeekday(_ weekday: Int, hour: Int, minute: Int) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let todayWD = cal.component(.weekday, from: today)
        // Always pick the *next* occurrence of this weekday (at least 1 day out)
        // so the test doesn't collide with "today."
        let diff = (weekday - todayWD + 7) % 7
        let daysToAdd = diff == 0 ? 7 : diff
        let target = cal.date(byAdding: .day, value: daysToAdd, to: today)!
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: target)!
    }
}
