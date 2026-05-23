//
//  LocationSkill.swift
//  Loop
//
//  Built from intel/Specs/location_spec.md.
//

import Foundation
import CoreLocation

/// Lets Loop fetch the device's current location through CoreLocation. The
/// skill owns a CLLocationManager and resolves a single coordinate per call,
/// optionally reverse-geocoding it into a human-readable address so the
/// model can mention a place name instead of raw lat/lon.
///
/// Tools the model sees:
/// - get_current_location: returns lat/lon, horizontal accuracy, timestamp,
///   and (if include_address is true) a reverse-geocoded address.
struct LocationSkill {
    static let shared = LocationSkill()

    static let systemPromptFragment: String = """
You can read the user's current device location with this tool:
- get_current_location: returns the user's lat/lon, accuracy, timestamp, and (by default) a reverse-geocoded address. Pass `include_address: false` if you only need coordinates (slightly faster, no network round-trip).

When to call:
- The user asks something location-relative ("places near me", "what's the weather", "how far to X").
- You need a starting point for an exa_search ("coffee shops in <neighborhood>").

Notes:
- The first call in a session may prompt the user for permission. If permission is denied or location services are off, the tool returns an error string — relay it to the user and ask them to enable location in Settings.
- Coordinates are device-private; do not log them outside the conversation or share them with third-party tools without consent.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "get_current_location",
                "description": "Get the user's current location from the device. Returns coordinates, accuracy, timestamp, and (by default) a reverse-geocoded human-readable address.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "include_address": [
                            "type": "boolean",
                            "description": "Whether to reverse-geocode the coordinates into a human-readable address. Defaults to true. Set false to skip the geocoder round-trip when you only need lat/lon."
                        ]
                    ],
                    "required": []
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "get_current_location"
    ]

    func handles(functionName: String) -> Bool {
        return LocationSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "get_current_location":
            return "checking your location"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "get_current_location":
            let includeAddress = (functionCall.arguments["include_address"] as? Bool) ?? true
            getCurrentLocation(includeAddress: includeAddress, completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Location tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handler

    private func getCurrentLocation(includeAddress: Bool,
                                    completion: @escaping (MessageStruct) -> Void) {
        // The fetcher owns its own lifecycle: holds CLLocationManager + the
        // CLGeocoder, retains itself until the delegate fires, then releases.
        // Caller doesn't need to keep a reference.
        let fetcher = OneShotLocationFetcher()
        fetcher.fetch(includeAddress: includeAddress) { result in
            let body: String
            switch result {
            case .success(let payload):
                body = payload
            case .failure(let message):
                body = message
            }
            completion(MessageStruct(
                role: "function",
                content: body,
                name: "get_current_location"
            ))
        }
    }
}

// MARK: - One-shot location fetcher
//
// CLLocationManager is delegate-based and async. This class wraps the
// authorization → request → reverse-geocode flow into a single closure
// callback and self-retains for the duration of the request so callers
// don't have to manage its lifetime.

private final class OneShotLocationFetcher: NSObject, CLLocationManagerDelegate {

    enum Outcome {
        case success(String)
        case failure(String)
    }

    /// Created lazily on the main thread inside fetch(). CLLocationManager
    /// dispatches its delegate callbacks via the run loop of the thread it
    /// was created on; if the skill's handle() runs on a background queue
    /// without a run loop, callbacks silently never fire. Constructing
    /// on-main from fetch() avoids that trap.
    private var manager: CLLocationManager?
    private var completion: ((Outcome) -> Void)?
    private var includeAddress: Bool = true
    private var didFinish = false
    private var didRequestLocation = false
    private var selfRetain: OneShotLocationFetcher?
    private var watchdog: DispatchWorkItem?

    func fetch(includeAddress: Bool, completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        self.includeAddress = includeAddress
        self.selfRetain = self  // keep alive while CLLocationManager runs

        // 20s upper bound — handles cases where neither delegate callback
        // fires (e.g. simulator with no location set, or extreme low signal).
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Last-ditch: see if the manager has *any* cached fix sitting
            // around. Better than failing if the user is just in a weak-signal
            // pocket but recently had a fix.
            if let cached = self.manager?.location, cached.horizontalAccuracy >= 0 {
                print("LocationSkill: watchdog firing but cached fix available — using it")
                self.deliver(cached)
            } else {
                self.finish(.failure("Location request timed out after 20s. Check iOS Location Services is on, the app permission is set to While Using, and you have signal/network. Then try again."))
            }
        }
        self.watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.setupManagerIfNeeded()
            self.dispatchAfterAuthorization()
        }
    }

    /// Build the CLLocationManager on the main thread so its run loop is the
    /// main run loop and delegate callbacks will actually fire.
    private func setupManagerIfNeeded() {
        guard manager == nil else { return }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // distanceFilter = none so the very first fix triggers
        // didUpdateLocations rather than being filtered out as too small.
        m.distanceFilter = kCLDistanceFilterNone
        manager = m
    }

    private func dispatchAfterAuthorization() {
        guard let manager = manager else {
            finish(.failure("Location manager unavailable."))
            return
        }
        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            // First use — kick off the OS prompt. The result lands in
            // locationManagerDidChangeAuthorization, which calls back here.
            manager.requestWhenInUseAuthorization()
        case .restricted:
            finish(.failure("Location services are restricted on this device (parental controls or MDM). I can't read your location."))
        case .denied:
            finish(.failure("Location access was denied for this app. Open Settings → Privacy → Location Services → Loop to grant access."))
        case .authorizedWhenInUse, .authorizedAlways:
            beginLocationRequest()
        @unknown default:
            finish(.failure("Unknown location authorization state."))
        }
    }

    /// Use startUpdatingLocation rather than requestLocation. requestLocation
    /// is one-shot but flakier in the wild — if it can't get a fix within its
    /// internal window it may silently fail to deliver. startUpdatingLocation
    /// keeps trying until we stop it, and we stop on the first usable fix.
    /// Also opportunistically deliver a cached `manager.location` if it's
    /// recent enough so the user doesn't wait for a fresh GPS lock.
    private func beginLocationRequest() {
        guard let manager = manager, !didRequestLocation else { return }
        didRequestLocation = true

        if let cached = manager.location,
           cached.horizontalAccuracy >= 0,
           cached.horizontalAccuracy <= 200,
           Date().timeIntervalSince(cached.timestamp) < 60 {
            // Fresh enough — skip waiting on a new fix.
            deliver(cached)
            return
        }
        manager.startUpdatingLocation()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Re-enter the dispatch flow once the user answers the prompt.
        guard !didFinish else { return }
        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            return  // still waiting on the user
        case .authorizedWhenInUse, .authorizedAlways:
            beginLocationRequest()
        case .denied:
            finish(.failure("Location access was denied. Open Settings → Privacy → Location Services → Loop to grant access."))
        case .restricted:
            finish(.failure("Location services are restricted on this device."))
        @unknown default:
            finish(.failure("Unknown location authorization state."))
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        guard !didFinish else { return }
        // Filter out invalid fixes (negative accuracy = error sentinel) and
        // anything older than 30s (stale cached). Take the freshest valid fix.
        let usable = locations.filter {
            $0.horizontalAccuracy >= 0
                && Date().timeIntervalSince($0.timestamp) < 30
        }
        guard let loc = usable.last ?? locations.last else { return }
        manager.stopUpdatingLocation()
        deliver(loc)
    }

    private func deliver(_ loc: CLLocation) {
        guard !didFinish else { return }
        if includeAddress {
            reverseGeocode(loc) { [weak self] addressLine in
                self?.finish(.success(LocationSkillFormatter.format(loc, address: addressLine)))
            }
        } else {
            finish(.success(LocationSkillFormatter.format(loc, address: nil)))
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error) {
        guard !didFinish else { return }
        let detail = (error as? CLError).map { describe(clError: $0) } ?? error.localizedDescription
        finish(.failure("Location fetch failed: \(detail)"))
    }

    private func reverseGeocode(_ loc: CLLocation,
                                completion: @escaping (String?) -> Void) {
        // Best-effort — if geocoding fails, we still return coordinates. The
        // geocoder is rate-limited per-app, so a failure here is recoverable.
        CLGeocoder().reverseGeocodeLocation(loc) { placemarks, _ in
            guard let p = placemarks?.first else {
                completion(nil)
                return
            }
            var parts: [String] = []
            if let name = p.name, name != p.thoroughfare { parts.append(name) }
            if let thoroughfare = p.thoroughfare {
                if let sub = p.subThoroughfare {
                    parts.append("\(sub) \(thoroughfare)")
                } else {
                    parts.append(thoroughfare)
                }
            }
            if let locality = p.locality { parts.append(locality) }
            if let admin = p.administrativeArea { parts.append(admin) }
            if let postal = p.postalCode { parts.append(postal) }
            if let country = p.country { parts.append(country) }
            let unique = parts.reduce(into: [String]()) { acc, x in
                if acc.last != x { acc.append(x) }
            }
            completion(unique.isEmpty ? nil : unique.joined(separator: ", "))
        }
    }

    private func describe(clError: CLError) -> String {
        switch clError.code {
        case .denied:        return "permission denied"
        case .locationUnknown: return "location unknown — try moving to an area with better signal"
        case .network:       return "network unavailable"
        case .headingFailure: return "heading unavailable"
        case .rangingUnavailable, .rangingFailure: return "ranging unavailable"
        case .regionMonitoringDenied,
             .regionMonitoringFailure,
             .regionMonitoringSetupDelayed,
             .regionMonitoringResponseDelayed: return "region monitoring failure"
        default: return "code \(clError.code.rawValue)"
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !didFinish else { return }
        didFinish = true
        watchdog?.cancel()
        watchdog = nil
        // Stop any active streaming so we don't keep the GPS hot.
        manager?.stopUpdatingLocation()
        let cb = completion
        completion = nil
        DispatchQueue.main.async {
            cb?(outcome)
        }
        // Drop the self-retain so we deallocate after the callback fires.
        DispatchQueue.main.async { [weak self] in
            self?.selfRetain = nil
        }
    }
}

private enum LocationSkillFormatter {
    /// Plain-text payload for the function-result message — mirrors ExaSkill's
    /// approach (the proxy currently rejects stringified JSON in function
    /// content, so we hand the model a readable string instead).
    static func format(_ loc: CLLocation, address: String?) -> String {
        let lat = String(format: "%.6f", loc.coordinate.latitude)
        let lon = String(format: "%.6f", loc.coordinate.longitude)
        let acc = loc.horizontalAccuracy >= 0
            ? String(format: "%.0fm", loc.horizontalAccuracy)
            : "unknown"
        let iso = ISO8601DateFormatter().string(from: loc.timestamp)
        var lines: [String] = [
            "Latitude: \(lat)",
            "Longitude: \(lon)",
            "Accuracy: \(acc)",
            "Timestamp: \(iso)"
        ]
        if let address = address, !address.isEmpty {
            lines.append("Address: \(address)")
        }
        return lines.joined(separator: "\n")
    }
}
