//
//  ObsidianDateHelpers.swift
//  Loop
//
//  Week / day folder math that mirrors the user's vault convention.
//  Kept in lockstep with `scripts/obsidian_relay.py`'s `_today_paths` so the
//  iOS client can label tool calls ("creating note in 6. Sat, May 09")
//  without a round trip to the relay.
//

import Foundation

/// Vault-relative root folder for the user's private notes.
let OBSIDIAN_VAULT_ROOT = "0. private"

/// Pure-Swift mirror of the relay's day/week folder naming.
///
/// - Week: `<idx>. <Sun MMM dd> – <Sat MMM dd>` (en-dash, U+2013, days zero-padded).
/// - Day:  `<dayIdx>. <Ddd>, <Mmm dd>` where Sun=0…Sat=6.
enum ObsidianDateHelpers {

    /// Sunday on or before `date`, normalized to midnight in the device tz.
    static func sunday(of date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1  // Sunday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }

    /// 0-indexed Sunday-anchored week within the calendar year.
    /// May 3 2026 (Sun) → 17, matching the user's `17. May 03 – May 09` folder.
    static func weekIndex(of date: Date) -> Int {
        let sun = sunday(of: date)
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: sun)
        let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? sun
        let firstSunday = sunday(of: jan1)
        let days = cal.dateComponents([.day], from: firstSunday, to: sun).day ?? 0
        return days / 7
    }

    static func weekFolderName(for date: Date = Date()) -> String {
        let cal = Calendar(identifier: .gregorian)
        let sun = sunday(of: date)
        let sat = cal.date(byAdding: .day, value: 6, to: sun) ?? sun

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM dd"

        return "\(weekIndex(of: date)). \(f.string(from: sun)) – \(f.string(from: sat))"
    }

    static func dayFolderName(for date: Date = Date()) -> String {
        let cal = Calendar(identifier: .gregorian)
        // Calendar.weekday: Sun=1..Sat=7 → we want Sun=0..Sat=6.
        let dayIdx = cal.component(.weekday, from: date) - 1

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM dd"

        return "\(dayIdx). \(f.string(from: date))"
    }

    /// Vault-relative path to today's day folder, e.g.
    /// `0. private/17. May 03 – May 09/6. Sat, May 09`.
    static func dayFolderPath(for date: Date = Date()) -> String {
        return "\(OBSIDIAN_VAULT_ROOT)/\(weekFolderName(for: date))/\(dayFolderName(for: date))"
    }
}
