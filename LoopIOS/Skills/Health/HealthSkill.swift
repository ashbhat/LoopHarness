//
//  HealthSkill.swift
//  Loop
//
//  Read-only Apple Health integration. Surfaces three agent tools:
//    - health_today_summary: today's steps, distance, active energy, workouts
//    - health_active_workout: current in-progress workout (or "none")
//    - health_query: generic metric over a time range
//
//  Privacy: Health values are returned to the model as structured JSON
//  for on-device relay to the user. They MUST NOT be logged, persisted,
//  or sent to analytics/telemetry.
//
//  iOS-only — HealthKit is unavailable on macOS.
//

#if canImport(HealthKit) && os(iOS)
import Foundation
import HealthKit

final class HealthSkill {

    static let shared = HealthSkill()
    private let mgr = HealthKitManager.shared
    private init() {}

    // MARK: - System prompt fragment

    static let systemPromptFragment: String = """
    You can read the user's Apple Health data (read-only) through these tools:
    - health_today_summary: returns today's steps, distance (km), active energy burned (kcal), and a list of workouts so far. Use for "how many steps today?", "how active have I been?", etc.
    - health_active_workout: if a workout is currently in progress (or was very recently started and not yet finished), returns its type, elapsed time, distance, and heart rate. If no workout is active, returns {"active_workout": null}. Use for "am I working out right now?" or "what's my current heart rate during this run?"
    - health_query: generic read of a specific HealthKit metric over a time range. Supported metrics: steps, distance, active_energy, heart_rate, resting_heart_rate, sleep, body_mass, workouts. Supported ranges: today, yesterday, this_week, last_7_days, or custom ISO 8601 start/end. Use for "how did I sleep last night?", "what was my resting heart rate this week?", "how far did I run yesterday?"

    Tips:
    - If Health access has not been granted, the tools return {"error":"health_not_authorized"} — tell the user to connect Apple Health in Settings → Integrations.
    - Never log or relay raw Health values to external services. Data stays on device.
    - For sleep queries, "last night" maps to yesterday's date range (sleep samples usually span the overnight window).
    """

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "health_today_summary",
                "description": "Get today's health summary: steps, distance (km), active energy burned (kcal), and workouts completed so far.",
                "parameters": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String]
                ]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "health_active_workout",
                "description": "Check if a workout is currently in progress. Returns type, elapsed time, distance, and heart rate if active; null if not.",
                "parameters": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String]
                ]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "health_query",
                "description": "Query a specific health metric over a time range. Use for targeted questions about steps, distance, energy, heart rate, sleep, body mass, or workouts.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "metric": [
                            "type": "string",
                            "description": "The metric to query. One of: steps, distance, active_energy, heart_rate, resting_heart_rate, sleep, body_mass, workouts."
                        ] as [String: Any],
                        "range": [
                            "type": "string",
                            "description": "Time range. One of: today, yesterday, this_week, last_7_days, or \"custom\" (requires start_iso and end_iso)."
                        ] as [String: Any],
                        "start_iso": [
                            "type": "string",
                            "description": "ISO 8601 start datetime for a custom range (e.g. \"2026-05-20T00:00:00-07:00\"). Required when range is \"custom\"."
                        ] as [String: Any],
                        "end_iso": [
                            "type": "string",
                            "description": "ISO 8601 end datetime for a custom range. Required when range is \"custom\"."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["metric", "range"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    ]

    static let toolNames: Set<String> = [
        "health_today_summary",
        "health_active_workout",
        "health_query"
    ]

    func handles(functionName: String) -> Bool {
        Self.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "health_today_summary":   return "checking your health summary"
        case "health_active_workout":  return "checking for an active workout"
        case "health_query":
            if let m = call.arguments["metric"] as? String {
                let pretty = m.replacingOccurrences(of: "_", with: " ")
                return "querying \(pretty)"
            }
            return "querying health data"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        guard mgr.currentAuthorizationStatus != .unavailable else {
            completion(errorMessage(call: functionCall.name, code: "health_unavailable",
                                    hint: "HealthKit is not available on this device."))
            return
        }
        guard mgr.currentAuthorizationStatus == .authorized else {
            completion(errorMessage(call: functionCall.name, code: "health_not_authorized",
                                    hint: "Apple Health access has not been granted. Ask the user to connect Apple Health in Settings \u{2192} Integrations."))
            return
        }

        switch functionCall.name {
        case "health_today_summary":
            handleTodaySummary(completion: completion)
        case "health_active_workout":
            handleActiveWorkout(completion: completion)
        case "health_query":
            handleQuery(args: functionCall.arguments, completion: completion)
        default:
            completion(errorMessage(call: functionCall.name, code: "unknown_health_tool",
                                    hint: "Unknown health tool."))
        }
    }

    // MARK: - health_today_summary

    private func handleTodaySummary(completion: @escaping (MessageStruct) -> Void) {
        let range = HealthKitManager.todayRange()
        let group = DispatchGroup()

        var steps: Double?
        var distance: Double?
        var energy: Double?
        var workoutList: [[String: Any]] = []

        group.enter()
        mgr.cumulativeStat(for: .stepCount, unit: .count(),
                           start: range.start, end: range.end) { val in
            steps = val; group.leave()
        }
        group.enter()
        mgr.cumulativeStat(for: .distanceWalkingRunning, unit: .meterUnit(with: .kilo),
                           start: range.start, end: range.end) { val in
            distance = val; group.leave()
        }
        group.enter()
        mgr.cumulativeStat(for: .activeEnergyBurned, unit: .kilocalorie(),
                           start: range.start, end: range.end) { val in
            energy = val; group.leave()
        }
        group.enter()
        mgr.workouts(start: range.start, end: range.end) { ws in
            workoutList = ws.map { Self.workoutDict($0) }
            group.leave()
        }

        group.notify(queue: .main) {
            let payload: [String: Any] = [
                "date": Self.isoDateOnly(Date()),
                "steps": steps.map { Int($0) } as Any,
                "distance_km": distance.map { round($0 * 100) / 100 } as Any,
                "active_energy_kcal": energy.map { round($0 * 10) / 10 } as Any,
                "workouts": workoutList
            ]
            completion(Self.functionMessage(name: "health_today_summary", payload: payload))
        }
    }

    // MARK: - health_active_workout

    private func handleActiveWorkout(completion: @escaping (MessageStruct) -> Void) {
        // Heuristic: a workout that started within the last 4 hours and has
        // no endDate, or ended less than 60 seconds ago, is "active".
        let fourHoursAgo = Date().addingTimeInterval(-4 * 3600)
        mgr.workouts(start: fourHoursAgo, end: Date(), limit: 5) { [weak self] ws in
            guard let self else { return }
            let active = ws.first(where: { w in
                // HKWorkout always has an endDate, but if it equals startDate
                // or the duration is still ticking, it's likely in progress.
                // The safest heuristic is a workout that ended very recently
                // (within 60s) or is extremely fresh.
                let elapsed = Date().timeIntervalSince(w.endDate)
                return elapsed < 60
            })

            if let w = active {
                var dict = Self.workoutDict(w)
                // Try to get current heart rate
                self.mgr.mostRecentSample(for: .heartRate,
                                          unit: HKUnit(from: "count/min")) { hr, hrDate in
                    if let hr, let hrDate, Date().timeIntervalSince(hrDate) < 300 {
                        dict["current_heart_rate_bpm"] = Int(hr)
                    }
                    completion(Self.functionMessage(name: "health_active_workout",
                                                    payload: ["active_workout": dict]))
                }
            } else {
                completion(Self.functionMessage(name: "health_active_workout",
                                                payload: ["active_workout": NSNull()]))
            }
        }
    }

    // MARK: - health_query

    private func handleQuery(args: [String: Any],
                             completion: @escaping (MessageStruct) -> Void) {
        guard let metric = args["metric"] as? String else {
            completion(errorMessage(call: "health_query", code: "missing_metric",
                                    hint: "Provide a 'metric' parameter."))
            return
        }
        guard let rangeName = args["range"] as? String else {
            completion(errorMessage(call: "health_query", code: "missing_range",
                                    hint: "Provide a 'range' parameter."))
            return
        }

        let range: (start: Date, end: Date)
        if rangeName.lowercased() == "custom" {
            guard let s = args["start_iso"] as? String,
                  let e = args["end_iso"] as? String,
                  let r = HealthKitManager.customRange(startISO: s, endISO: e) else {
                completion(errorMessage(call: "health_query", code: "invalid_custom_range",
                                        hint: "Custom range requires valid start_iso and end_iso in ISO 8601."))
                return
            }
            range = r
        } else if let r = HealthKitManager.rangeFor(rangeName) {
            range = r
        } else {
            completion(errorMessage(call: "health_query", code: "invalid_range",
                                    hint: "Range must be one of: today, yesterday, this_week, last_7_days, custom."))
            return
        }

        switch metric.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "steps":
            mgr.cumulativeStat(for: .stepCount, unit: .count(),
                               start: range.start, end: range.end) { val in
                completion(Self.functionMessage(name: "health_query", payload: [
                    "metric": "steps", "value": val.map { Int($0) } as Any,
                    "unit": "count",
                    "range_start": Self.isoFull(range.start),
                    "range_end": Self.isoFull(range.end)
                ]))
            }
        case "distance":
            mgr.cumulativeStat(for: .distanceWalkingRunning, unit: .meterUnit(with: .kilo),
                               start: range.start, end: range.end) { val in
                completion(Self.functionMessage(name: "health_query", payload: [
                    "metric": "distance", "value": val.map { round($0 * 100) / 100 } as Any,
                    "unit": "km",
                    "range_start": Self.isoFull(range.start),
                    "range_end": Self.isoFull(range.end)
                ]))
            }
        case "active_energy":
            mgr.cumulativeStat(for: .activeEnergyBurned, unit: .kilocalorie(),
                               start: range.start, end: range.end) { val in
                completion(Self.functionMessage(name: "health_query", payload: [
                    "metric": "active_energy", "value": val.map { round($0 * 10) / 10 } as Any,
                    "unit": "kcal",
                    "range_start": Self.isoFull(range.start),
                    "range_end": Self.isoFull(range.end)
                ]))
            }
        case "heart_rate":
            mgr.discreteAverage(for: .heartRate,
                                unit: HKUnit(from: "count/min"),
                                start: range.start, end: range.end) { val in
                completion(Self.functionMessage(name: "health_query", payload: [
                    "metric": "heart_rate", "value": val.map { round($0 * 10) / 10 } as Any,
                    "unit": "bpm (average)",
                    "range_start": Self.isoFull(range.start),
                    "range_end": Self.isoFull(range.end)
                ]))
            }
        case "resting_heart_rate":
            mgr.discreteAverage(for: .restingHeartRate,
                                unit: HKUnit(from: "count/min"),
                                start: range.start, end: range.end) { val in
                completion(Self.functionMessage(name: "health_query", payload: [
                    "metric": "resting_heart_rate", "value": val.map { round($0 * 10) / 10 } as Any,
                    "unit": "bpm (average)",
                    "range_start": Self.isoFull(range.start),
                    "range_end": Self.isoFull(range.end)
                ]))
            }
        case "body_mass":
            mgr.discreteAverage(for: .bodyMass, unit: .gramUnit(with: .kilo),
                                start: range.start, end: range.end) { val in
                completion(Self.functionMessage(name: "health_query", payload: [
                    "metric": "body_mass", "value": val.map { round($0 * 10) / 10 } as Any,
                    "unit": "kg",
                    "range_start": Self.isoFull(range.start),
                    "range_end": Self.isoFull(range.end)
                ]))
            }
        case "sleep":
            mgr.sleepSamples(start: range.start, end: range.end) { samples in
                let entries: [[String: Any]] = samples.map { s in
                    let category: String
                    if #available(iOS 16.0, *) {
                        switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                        case .asleepCore:       category = "core"
                        case .asleepDeep:       category = "deep"
                        case .asleepREM:        category = "rem"
                        case .awake:            category = "awake"
                        case .asleepUnspecified: category = "asleep"
                        case .inBed:            category = "in_bed"
                        default:                category = "unknown"
                        }
                    } else {
                        switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                        case .inBed:  category = "in_bed"
                        case .asleep: category = "asleep"
                        case .awake:  category = "awake"
                        default:      category = "unknown"
                        }
                    }
                    return [
                        "category": category,
                        "start": Self.isoFull(s.startDate),
                        "end": Self.isoFull(s.endDate),
                        "duration_minutes": Int(s.endDate.timeIntervalSince(s.startDate) / 60)
                    ]
                }
                let totalMinutes = samples.reduce(0) { acc, s in
                    let val = HKCategoryValueSleepAnalysis(rawValue: s.value)
                    let isSleep: Bool
                    if #available(iOS 16.0, *) {
                        isSleep = val == .asleepCore || val == .asleepDeep || val == .asleepREM || val == .asleepUnspecified
                    } else {
                        isSleep = val == .asleep
                    }
                    return isSleep ? acc + s.endDate.timeIntervalSince(s.startDate) / 60 : acc
                }
                completion(Self.functionMessage(name: "health_query", payload: [
                    "metric": "sleep",
                    "total_sleep_minutes": Int(totalMinutes),
                    "total_sleep_hours": round(totalMinutes / 60 * 10) / 10,
                    "entries": entries,
                    "range_start": Self.isoFull(range.start),
                    "range_end": Self.isoFull(range.end)
                ]))
            }
        case "workouts":
            mgr.workouts(start: range.start, end: range.end) { ws in
                let list = ws.map { Self.workoutDict($0) }
                completion(Self.functionMessage(name: "health_query", payload: [
                    "metric": "workouts", "workouts": list,
                    "count": list.count,
                    "range_start": Self.isoFull(range.start),
                    "range_end": Self.isoFull(range.end)
                ]))
            }
        default:
            completion(errorMessage(call: "health_query", code: "unknown_metric",
                                    hint: "Supported metrics: steps, distance, active_energy, heart_rate, resting_heart_rate, sleep, body_mass, workouts."))
        }
    }

    // MARK: - Helpers

    private static func workoutDict(_ w: HKWorkout) -> [String: Any] {
        var d: [String: Any] = [
            "type": HealthKitManager.workoutTypeName(w),
            "start": isoFull(w.startDate),
            "end": isoFull(w.endDate),
            "duration": HealthKitManager.formatDuration(w.duration)
        ]
        if let dist = w.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)) {
            d["distance_km"] = round(dist * 100) / 100
        }
        if let energy = w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
            d["energy_kcal"] = round(energy * 10) / 10
        }
        return d
    }

    private func errorMessage(call: String, code: String, hint: String) -> MessageStruct {
        let payload: [String: Any] = ["error": code, "hint": hint]
        return Self.functionMessage(name: call, payload: payload)
    }

    private static func functionMessage(name: String, payload: Any) -> MessageStruct {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "{}"
        }
        return MessageStruct(role: "function", content: json, name: name)
    }

    private static let isoFullFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func isoFull(_ date: Date) -> String {
        isoFullFormatter.string(from: date)
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func isoDateOnly(_ date: Date) -> String {
        dateOnlyFormatter.string(from: date)
    }
}
#endif
