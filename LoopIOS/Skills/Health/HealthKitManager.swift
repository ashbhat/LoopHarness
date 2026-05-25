//
//  HealthKitManager.swift
//  Loop
//
//  Thin wrapper around HKHealthStore that centralises authorisation state,
//  read-only queries, and the set of data types Loop is interested in.
//  Privacy: values returned by query helpers are intended for on-device
//  consumption by the agent — callers MUST NOT log, persist, or send
//  them to analytics/telemetry.
//
//  iOS-only. HealthKit is unavailable on macOS.
//

#if canImport(HealthKit) && os(iOS)
import Foundation
import HealthKit

final class HealthKitManager {

    static let shared = HealthKitManager()

    let store = HKHealthStore()

    // MARK: - Data types we request READ access to

    static let readTypes: Set<HKObjectType> = {
        var types: Set<HKObjectType> = []
        // Quantity types
        let quantityIds: [HKQuantityTypeIdentifier] = [
            .stepCount,
            .distanceWalkingRunning,
            .activeEnergyBurned,
            .heartRate,
            .restingHeartRate,
            .bodyMass,
        ]
        for id in quantityIds {
            if let t = HKQuantityType.quantityType(forIdentifier: id) {
                types.insert(t)
            }
        }
        // Category types
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        // Workouts
        types.insert(HKObjectType.workoutType())
        return types
    }()

    private init() {
        // If the user authorized in a previous app version (before we
        // started persisting `hasRequestedAuthorization`), iOS still
        // remembers the prompt was answered — `getRequestStatusForAuthorization`
        // returns `.unnecessary` for the requested types. Backfill the flag
        // so the agent recognises access without forcing the user to re-tap
        // "Connect Apple Health".
        if !hasRequestedAuthorization, HKHealthStore.isHealthDataAvailable() {
            store.getRequestStatusForAuthorization(toShare: [], read: Self.readTypes) { [weak self] status, _ in
                if status == .unnecessary {
                    self?.hasRequestedAuthorization = true
                }
            }
        }
    }

    // MARK: - Authorisation

    /// Current combined authorisation status.
    ///
    /// iOS gotcha: `HKHealthStore.authorizationStatus(for:)` deliberately
    /// returns `.sharingDenied` for *read-only* requests regardless of
    /// whether the user granted access — Apple's design prevents apps from
    /// inferring user data from auth state. The status API is only meaningful
    /// for share/write permissions. Since Loop only requests read access,
    /// the per-type status is useless for "did the user grant read".
    ///
    /// The best signal we have is "have we successfully presented the
    /// HealthKit prompt at least once". We persist that as a UserDefaults
    /// flag set when `requestAuthorization` completes without error.
    /// After that, we treat the integration as `.authorized` — actual
    /// per-type denial just shows up as empty query results, which the
    /// agent surfaces honestly as "no data".
    enum AuthStatus: String {
        case authorized
        case denied
        case notDetermined
        case unavailable
    }

    private static let hasRequestedKey = "HealthKit.hasRequestedAuthorization"

    private var hasRequestedAuthorization: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasRequestedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasRequestedKey) }
    }

    var currentAuthorizationStatus: AuthStatus {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        // Any explicit `.sharingAuthorized` (only possible for share/write
        // types — kept for future-proofing) counts as authorized.
        for t in Self.readTypes
        where store.authorizationStatus(for: t) == .sharingAuthorized {
            return .authorized
        }
        // For read-only types iOS won't tell us if the user granted access.
        // Fall back to "have we asked yet" — see comment on the enum.
        return hasRequestedAuthorization ? .authorized : .notDetermined
    }

    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, nil)
            return
        }
        store.requestAuthorization(toShare: nil, read: Self.readTypes) { [weak self] ok, err in
            // `ok == true` means the prompt completed without error, not
            // that every type was granted. That's the only signal we get
            // for read-only access — record it so subsequent queries are
            // allowed through.
            if ok, err == nil {
                self?.hasRequestedAuthorization = true
            }
            DispatchQueue.main.async { completion(ok, err) }
        }
    }

    // MARK: - Cumulative stat query (steps, distance, energy)

    func cumulativeStat(for identifier: HKQuantityTypeIdentifier,
                        unit: HKUnit,
                        start: Date,
                        end: Date,
                        completion: @escaping (Double?) -> Void) {
        guard let qType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            completion(nil); return
        }
        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let q = HKStatisticsQuery(quantityType: qType,
                                  quantitySamplePredicate: pred,
                                  options: .cumulativeSum) { _, stats, _ in
            let val = stats?.sumQuantity()?.doubleValue(for: unit)
            DispatchQueue.main.async { completion(val) }
        }
        store.execute(q)
    }

    // MARK: - Discrete average query (heart rate, resting HR, body mass)

    func discreteAverage(for identifier: HKQuantityTypeIdentifier,
                         unit: HKUnit,
                         start: Date,
                         end: Date,
                         completion: @escaping (Double?) -> Void) {
        guard let qType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            completion(nil); return
        }
        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let q = HKStatisticsQuery(quantityType: qType,
                                  quantitySamplePredicate: pred,
                                  options: .discreteAverage) { _, stats, _ in
            let val = stats?.averageQuantity()?.doubleValue(for: unit)
            DispatchQueue.main.async { completion(val) }
        }
        store.execute(q)
    }

    // MARK: - Most recent sample

    func mostRecentSample(for identifier: HKQuantityTypeIdentifier,
                          unit: HKUnit,
                          completion: @escaping (Double?, Date?) -> Void) {
        guard let qType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            completion(nil, nil); return
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let q = HKSampleQuery(sampleType: qType,
                              predicate: nil,
                              limit: 1,
                              sortDescriptors: [sort]) { _, samples, _ in
            let sample = samples?.first as? HKQuantitySample
            let val = sample?.quantity.doubleValue(for: unit)
            DispatchQueue.main.async { completion(val, sample?.endDate) }
        }
        store.execute(q)
    }

    // MARK: - Workout queries

    func workouts(start: Date, end: Date, limit: Int = 50,
                  completion: @escaping ([HKWorkout]) -> Void) {
        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let q = HKSampleQuery(sampleType: .workoutType(),
                              predicate: pred,
                              limit: limit,
                              sortDescriptors: [sort]) { _, samples, _ in
            let ws = (samples as? [HKWorkout]) ?? []
            DispatchQueue.main.async { completion(ws) }
        }
        store.execute(q)
    }

    // MARK: - Sleep analysis

    func sleepSamples(start: Date, end: Date,
                      completion: @escaping ([HKCategorySample]) -> Void) {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion([]); return
        }
        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let q = HKSampleQuery(sampleType: sleepType,
                              predicate: pred,
                              limit: HKObjectQueryNoLimit,
                              sortDescriptors: [sort]) { _, samples, _ in
            let cs = (samples as? [HKCategorySample]) ?? []
            DispatchQueue.main.async { completion(cs) }
        }
        store.execute(q)
    }

    // MARK: - Date range helpers

    static func todayRange() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = Date()
        return (start, end)
    }

    static func yesterdayRange() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -1, to: todayStart)!
        return (start, todayStart)
    }

    static func thisWeekRange() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let start = cal.date(from: comps)!
        return (start, now)
    }

    static func last7DaysRange() -> (start: Date, end: Date) {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        return (start, now)
    }

    static func rangeFor(_ name: String) -> (start: Date, end: Date)? {
        switch name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "today":        return todayRange()
        case "yesterday":    return yesterdayRange()
        case "this_week":    return thisWeekRange()
        case "last_7_days":  return last7DaysRange()
        default:             return nil
        }
    }

    /// Parse an ISO 8601 custom range from two strings.
    static func customRange(startISO: String, endISO: String) -> (start: Date, end: Date)? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        guard let s = f.date(from: startISO) ?? f2.date(from: startISO),
              let e = f.date(from: endISO) ?? f2.date(from: endISO) else { return nil }
        return (s, e)
    }

    // MARK: - Workout formatting

    static func workoutTypeName(_ workout: HKWorkout) -> String {
        switch workout.workoutActivityType {
        case .running:               return "Running"
        case .walking:               return "Walking"
        case .cycling:               return "Cycling"
        case .swimming:              return "Swimming"
        case .hiking:                return "Hiking"
        case .yoga:                  return "Yoga"
        case .functionalStrengthTraining: return "Strength Training"
        case .traditionalStrengthTraining: return "Strength Training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .elliptical:            return "Elliptical"
        case .rowing:                return "Rowing"
        case .stairClimbing:         return "Stair Climbing"
        case .dance:                 return "Dance"
        case .cooldown:              return "Cooldown"
        case .coreTraining:          return "Core Training"
        case .flexibility:           return "Flexibility"
        case .pilates:               return "Pilates"
        case .crossTraining:         return "Cross Training"
        case .mixedCardio:           return "Mixed Cardio"
        case .jumpRope:              return "Jump Rope"
        case .kickboxing:            return "Kickboxing"
        case .soccer:                return "Soccer"
        case .basketball:            return "Basketball"
        case .tennis:                return "Tennis"
        case .tableTennis:           return "Table Tennis"
        case .golf:                  return "Golf"
        case .americanFootball:      return "American Football"
        case .baseball:              return "Baseball"
        case .cricket:               return "Cricket"
        case .hockey:                return "Hockey"
        case .lacrosse:              return "Lacrosse"
        case .rugby:                 return "Rugby"
        case .volleyball:            return "Volleyball"
        case .waterPolo:             return "Water Polo"
        case .boxing:                return "Boxing"
        case .martialArts:           return "Martial Arts"
        case .wrestling:             return "Wrestling"
        case .surfingSports:         return "Surfing"
        case .downhillSkiing:        return "Downhill Skiing"
        case .crossCountrySkiing:    return "Cross-Country Skiing"
        case .snowboarding:          return "Snowboarding"
        case .skatingSports:         return "Skating"
        case .paddleSports:          return "Paddle Sports"
        case .handball:              return "Handball"
        case .badminton:             return "Badminton"
        case .squash:                return "Squash"
        case .racquetball:           return "Racquetball"
        case .fishing:               return "Fishing"
        case .climbing:              return "Climbing"
        case .archery:               return "Archery"
        case .equestrianSports:      return "Equestrian Sports"
        default:                     return "Other"
        }
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let mins = Int(interval / 60)
        let hrs = mins / 60
        let rem = mins % 60
        if hrs > 0 { return "\(hrs)h \(rem)m" }
        return "\(mins)m"
    }
}
#endif
