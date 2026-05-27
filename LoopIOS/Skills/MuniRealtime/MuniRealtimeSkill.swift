//
//  MuniRealtimeSkill.swift
//  Loop
//
//  Real-time SF Muni arrival predictions via the 511 SF Bay API
//  (api.511.org). Reads the user's API key from KeyStore
//  (Settings → Keys → 511 SF Bay). The key is free — register at
//  https://511.org/open-data/token to get one.
//
//  The skill exposes one tool:
//  - muni_arrivals: given a stop and/or route, returns upcoming arrival
//    predictions with minutes until each bus/train. Both `route` and
//    `stop_id` are optional — pass `location` to look up the nearest
//    stop (and optionally restrict to a specific route).
//
//  The 511 StopMonitoring endpoint returns SIRI-format JSON. This skill
//  parses the MonitoredStopVisit array and formats a human-readable
//  summary the model can relay directly.
//

import Foundation
import CoreLocation

struct MuniRealtimeSkill {
    static let shared = MuniRealtimeSkill()

    private static let baseURL = "https://api.511.org/transit"
    private static let agency = "SF"

    // MARK: - System prompt

    static let systemPromptFragment: String = """
You can look up real-time SF Muni bus and train arrivals:
- muni_arrivals: returns upcoming arrivals at a stop. Pass any combination of:
  - `stop_id` — the numeric SFMTA stop code (e.g. "15553") if you know it
  - `location` — a street address or "lat,lng" string; the skill finds the nearest stop
  - `route` — restrict results to a specific route (e.g. "5R", "N", "38"). Optional; omit to see all arrivals at the stop.

When to call:
- The user asks "when is the next 5R?" → pass `route` + (`location` or `stop_id`).
- The user asks "what buses are near me?" → call `get_current_location` first, then pass that as `location` with no route.
- You need transit info for trip planning in San Francisco.

Tips:
- If the user has not specified a location, call `get_current_location` first and pass the returned "lat,lng" as `location`.
- Common routes: 5/5R (Fulton), 14/14R (Mission), 22 (Fillmore), 28/28R (19th Ave), 38/38R (Geary), N (Judah), KT (Ingleside–Third), J (Church), L (Taraval), M (Ocean View).
- If the tool returns an API-key error, tell the user to add their free 511 API key in Settings → Keys → 511 SF Bay. They can get one at https://511.org/open-data/token.
"""

    // MARK: - Tool schema

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "muni_arrivals",
                "description": "Get real-time SF Muni arrival predictions. Pass `stop_id` if known, or `location` (address or \"lat,lng\") to find the nearest stop. `route` is optional — omit to see all arrivals at the stop.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "route": [
                            "type": "string",
                            "description": "Optional. Muni route name to filter by — e.g. \"5R\", \"N\", \"38\", \"KT\". Omit to see all arrivals at the stop."
                        ],
                        "stop_id": [
                            "type": "string",
                            "description": "Numeric SFMTA stop code (e.g. \"15553\"). Provide this OR location."
                        ],
                        "location": [
                            "type": "string",
                            "description": "Street address or \"lat,lng\" to resolve the nearest stop. Provide this OR stop_id."
                        ]
                    ],
                    "required": []
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["muni_arrivals"]

    func handles(functionName: String) -> Bool {
        return MuniRealtimeSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        guard call.name == "muni_arrivals" else { return nil }
        if let route = call.arguments["route"] as? String, !route.isEmpty {
            return "checking \(route) arrivals"
        }
        return "checking Muni arrivals"
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        guard functionCall.name == "muni_arrivals" else {
            completion(MessageStruct(
                role: "function",
                content: "{\"status\":\"error\",\"error\":\"Unknown tool \(functionCall.name)\"}",
                name: functionCall.name
            ))
            return
        }

        if MuniRealtimeSkill.apiKey == nil {
            completion(MuniRealtimeSkill.noApiKeyMessage(for: functionCall.name))
            return
        }

        let args = functionCall.arguments
        let route = (args["route"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stopId = (args["stop_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let location = (args["location"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedRoute = (route?.isEmpty == false) ? route : nil

        if let stopId = stopId, !stopId.isEmpty {
            fetchArrivals(route: normalizedRoute, stopCode: stopId, completion: completion)
        } else if let location = location, !location.isEmpty {
            resolveAndFetch(route: normalizedRoute, location: location, completion: completion)
        } else {
            completion(MessageStruct(
                role: "assistant",
                content: "I need either a `stop_id` or a `location` (address or \"lat,lng\") to look up Muni arrivals."
            ))
        }
    }

    // MARK: - Location → coords → nearest stop → arrivals

    private func resolveAndFetch(route: String?,
                                 location: String,
                                 completion: @escaping (MessageStruct) -> Void) {
        if let coord = Self.parseLatLng(location) {
            findNearestAndFetch(route: route,
                                latitude: coord.latitude,
                                longitude: coord.longitude,
                                completion: completion)
            return
        }

        CLGeocoder().geocodeAddressString(location) { placemarks, error in
            guard let coordinate = placemarks?.first?.location?.coordinate else {
                let detail = error?.localizedDescription ?? "No results"
                completion(MessageStruct(
                    role: "function",
                    content: "Could not geocode \"\(location)\": \(detail). Try passing coordinates as \"lat,lng\" or a numeric stop_id instead.",
                    name: "muni_arrivals"
                ))
                return
            }
            self.findNearestAndFetch(route: route,
                                     latitude: coordinate.latitude,
                                     longitude: coordinate.longitude,
                                     completion: completion)
        }
    }

    private func findNearestAndFetch(route: String?,
                                     latitude: Double,
                                     longitude: Double,
                                     completion: @escaping (MessageStruct) -> Void) {
        // If a route is specified, fetch the route's pattern first so we can
        // restrict the nearest-stop search to stops that actually serve that
        // route. The /stops endpoint doesn't carry per-stop line info, so
        // without this step we'd just pick the closest stop regardless of
        // whether the route stops there.
        if let route = route {
            fetchAllowedStopIds(route: route) { allowedRefs in
                if allowedRefs == nil {
                    // Pattern fetch failed — fall back to nearest stop overall
                    // and rely on the StopMonitoring route filter to surface
                    // arrivals (or its absence).
                    self.fetchNearestStop(latitude: latitude,
                                          longitude: longitude,
                                          restrictTo: nil) { stop in
                        self.completeForStop(stop, route: route, completion: completion)
                    }
                    return
                }
                self.fetchNearestStop(latitude: latitude,
                                      longitude: longitude,
                                      restrictTo: allowedRefs) { stop in
                    self.completeForStop(stop, route: route, completion: completion)
                }
            }
        } else {
            fetchNearestStop(latitude: latitude,
                             longitude: longitude,
                             restrictTo: nil) { stop in
                let noRoute: String? = nil
                self.completeForStop(stop, route: noRoute, completion: completion)
            }
        }
    }

    private func completeForStop(_ stop: NearestStop?,
                                 route: String?,
                                 completion: @escaping (MessageStruct) -> Void) {
        guard let stop = stop else {
            let where_ = route.map { "for route \($0) " } ?? ""
            completion(MessageStruct(
                role: "function",
                content: "No Muni stops found \(where_)near that location. Double-check the route name or try a more specific address.",
                name: "muni_arrivals"
            ))
            return
        }
        fetchArrivals(route: route,
                      stopCode: stop.code,
                      stopName: stop.name,
                      completion: completion)
    }

    // MARK: - /patterns: which stops serve a route

    /// Returns the set of `ScheduledStopPointRef` strings that serve the given
    /// route (across all directions). Returns nil on any failure so the caller
    /// can fall back to "nearest stop overall".
    private func fetchAllowedStopIds(route: String,
                                     completion: @escaping (Set<String>?) -> Void) {
        guard let apiKey = MuniRealtimeSkill.apiKey,
              let encodedRoute = route.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion(nil)
            return
        }

        let urlString = "\(MuniRealtimeSkill.baseURL)/patterns"
            + "?api_key=\(apiKey)"
            + "&operator_id=\(MuniRealtimeSkill.agency)"
            + "&line_id=\(encodedRoute)"
            + "&format=json"

        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = MuniRealtimeSkill.stripBOM(data),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let patterns = json["journeyPatterns"] as? [[String: Any]] else {
                completion(nil)
                return
            }

            var refs = Set<String>()
            for pattern in patterns {
                guard let points = pattern["PointsInSequence"] as? [String: Any],
                      let stops = points["StopPointInJourneyPattern"] as? [[String: Any]] else {
                    continue
                }
                for stop in stops {
                    if let ref = stop["ScheduledStopPointRef"] as? String {
                        refs.insert(ref)
                    }
                }
            }
            completion(refs.isEmpty ? nil : refs)
        }.resume()
    }

    // MARK: - /stops: nearest stop by distance

    private struct NearestStop {
        let code: String
        let name: String
        let distance: Double
    }

    private func fetchNearestStop(latitude: Double,
                                  longitude: Double,
                                  restrictTo: Set<String>?,
                                  completion: @escaping (NearestStop?) -> Void) {
        guard let apiKey = MuniRealtimeSkill.apiKey else {
            completion(nil)
            return
        }

        let urlString = "\(MuniRealtimeSkill.baseURL)/stops"
            + "?api_key=\(apiKey)"
            + "&operator_id=\(MuniRealtimeSkill.agency)"
            + "&format=json"

        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = MuniRealtimeSkill.stripBOM(data),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contents = json["Contents"] as? [String: Any],
                  let dataObjects = contents["dataObjects"] as? [String: Any],
                  let scheduledStopPoints = dataObjects["ScheduledStopPoint"] as? [[String: Any]] else {
                completion(nil)
                return
            }

            let target = CLLocation(latitude: latitude, longitude: longitude)
            var best: NearestStop?

            for stop in scheduledStopPoints {
                guard let code = stop["id"] as? String else { continue }
                if let restrictTo = restrictTo, !restrictTo.contains(code) {
                    continue
                }
                guard let loc = stop["Location"] as? [String: Any],
                      let latStr = loc["Latitude"] as? String,
                      let lonStr = loc["Longitude"] as? String,
                      let lat = Double(latStr),
                      let lon = Double(lonStr) else {
                    continue
                }
                let name = (stop["Name"] as? String) ?? code
                let dist = target.distance(from: CLLocation(latitude: lat, longitude: lon))
                if best == nil || dist < best!.distance {
                    best = NearestStop(code: code, name: name, distance: dist)
                }
            }

            completion(best)
        }.resume()
    }

    // MARK: - StopMonitoring

    private func fetchArrivals(route: String?,
                               stopCode: String,
                               stopName: String? = nil,
                               completion: @escaping (MessageStruct) -> Void) {
        guard let apiKey = MuniRealtimeSkill.apiKey else {
            completion(MuniRealtimeSkill.noApiKeyMessage(for: "muni_arrivals"))
            return
        }

        let urlString = "\(MuniRealtimeSkill.baseURL)/StopMonitoring"
            + "?api_key=\(apiKey)"
            + "&agency=\(MuniRealtimeSkill.agency)"
            + "&stopCode=\(stopCode)"
            + "&format=json"

        guard let url = URL(string: urlString) else {
            completion(MuniRealtimeSkill.errorResult("Bad StopMonitoring URL."))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = MuniRealtimeSkill.stripBOM(data) else {
                let detail = error?.localizedDescription ?? "No data"
                completion(MuniRealtimeSkill.errorResult(
                    "StopMonitoring request failed (HTTP \(status)): \(detail)"
                ))
                return
            }

            if status == 401 || status == 403 {
                completion(MuniRealtimeSkill.errorResult(
                    "511 API key was rejected (HTTP \(status)). "
                    + "Check that the key in Settings → Keys → 511 SF Bay is correct, "
                    + "or generate a new one at https://511.org/open-data/token."
                ))
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                completion(MuniRealtimeSkill.errorResult(
                    "StopMonitoring returned non-JSON (HTTP \(status)): \(snippet)"
                ))
                return
            }

            let visits = Self.extractVisits(from: json)
            let arrivals: [[String: Any]]
            if let route = route {
                arrivals = visits.filter { visit in
                    guard let ref = visit["LineRef"] as? String else { return false }
                    return ref.caseInsensitiveCompare(route) == .orderedSame
                }
            } else {
                arrivals = visits
            }

            let summary = Self.formatArrivals(arrivals,
                                              route: route,
                                              stopCode: stopCode,
                                              stopName: stopName)
            completion(MessageStruct(
                role: "function",
                content: summary,
                name: "muni_arrivals"
            ))
        }.resume()
    }

    // MARK: - SIRI JSON parsing

    private static func extractVisits(from json: [String: Any]) -> [[String: Any]] {
        guard let delivery = json["ServiceDelivery"] as? [String: Any],
              let monitoring = delivery["StopMonitoringDelivery"] as? [String: Any] else {
            return []
        }
        guard let visits = monitoring["MonitoredStopVisit"] as? [[String: Any]] else {
            return []
        }
        return visits.compactMap { visit in
            guard let journey = visit["MonitoredVehicleJourney"] as? [String: Any] else {
                return nil
            }
            var result: [String: Any] = [:]
            result["LineRef"] = journey["LineRef"]
            result["DirectionRef"] = journey["DirectionRef"]
            if let dest = journey["DestinationName"] as? [String]  {
                result["Destination"] = dest.first
            } else if let dest = journey["DestinationName"] as? String {
                result["Destination"] = dest
            }
            if let monCall = journey["MonitoredCall"] as? [String: Any] {
                result["StopPointName"] = monCall["StopPointName"]
                result["AimedArrivalTime"] = monCall["AimedArrivalTime"]
                result["ExpectedArrivalTime"] = monCall["ExpectedArrivalTime"]
                result["AimedDepartureTime"] = monCall["AimedDepartureTime"]
                result["ExpectedDepartureTime"] = monCall["ExpectedDepartureTime"]
            }
            return result
        }
    }

    private static func formatArrivals(_ arrivals: [[String: Any]],
                                       route: String?,
                                       stopCode: String,
                                       stopName: String?) -> String {
        let stopLabel: String
        if let name = stopName, !name.isEmpty {
            stopLabel = "\(name) (stop \(stopCode))"
        } else {
            stopLabel = "stop \(stopCode)"
        }
        let header: String
        if let route = route {
            header = "Arrivals for route \(route) at \(stopLabel):"
        } else {
            header = "Arrivals at \(stopLabel):"
        }

        guard !arrivals.isEmpty else {
            if let route = route {
                return "\(header)\nNo upcoming \(route) arrivals at this stop. The route may not be running right now, or it may not serve this stop."
            }
            return "\(header)\nNo upcoming arrivals at this stop right now."
        }

        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        // Pre-compute ETAs so we can sort by them. Visits without a parseable
        // time sink to the bottom.
        let enriched: [(eta: Int?, line: String, dest: String, dir: String)] = arrivals.map { arrival in
            let line = (arrival["LineRef"] as? String) ?? (route ?? "?")
            let dest = (arrival["Destination"] as? String) ?? "?"
            let direction = (arrival["DirectionRef"] as? String) ?? ""
            let dirLabel = direction == "IB" ? "Inbound" : direction == "OB" ? "Outbound" : direction
            let timeStr = (arrival["ExpectedDepartureTime"] as? String)
                ?? (arrival["ExpectedArrivalTime"] as? String)
                ?? (arrival["AimedDepartureTime"] as? String)
                ?? (arrival["AimedArrivalTime"] as? String)
            var eta: Int?
            if let timeStr = timeStr,
               let date = iso.date(from: timeStr) ?? isoBasic.date(from: timeStr) {
                eta = Int(date.timeIntervalSince(now) / 60)
            }
            return (eta, line, dest, dirLabel)
        }.sorted { a, b in
            switch (a.eta, b.eta) {
            case let (l?, r?): return l < r
            case (nil, _?):    return false
            case (_?, nil):    return true
            default:           return false
            }
        }

        var lines: [String] = [header]
        for (i, item) in enriched.prefix(8).enumerated() {
            let etaText: String
            if let mins = item.eta {
                if mins <= 0 { etaText = "arriving now" }
                else if mins == 1 { etaText = "1 min" }
                else { etaText = "\(mins) min" }
            } else {
                etaText = "time unknown"
            }
            var entry = "\(i + 1). \(item.line) → \(item.dest)"
            if !item.dir.isEmpty { entry += " (\(item.dir))" }
            entry += " — \(etaText)"
            lines.append(entry)
        }

        if enriched.count > 8 {
            lines.append("(\(enriched.count - 8) more not shown)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static var apiKey: String? {
        return KeyStore.shared.value(for: .sfBayTransit)
    }

    private static func noApiKeyMessage(for functionName: String) -> MessageStruct {
        let content = KeyStore.missingKeyInstruction(
            for: [.sfBayTransit],
            purpose: "SF Muni real-time arrivals (511 SF Bay). A free key is available at https://511.org/open-data/token"
        )
        return MessageStruct(role: "function", content: content, name: functionName)
    }

    private static func errorResult(_ message: String) -> MessageStruct {
        return MessageStruct(role: "function",
                             content: message,
                             name: "muni_arrivals")
    }

    /// Parse a "lat,lng" or "lat, lng" string. Returns nil if either component
    /// can't be parsed as a finite coordinate.
    private static func parseLatLng(_ s: String) -> CLLocationCoordinate2D? {
        let parts = s.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2,
              let lat = Double(parts[0]),
              let lon = Double(parts[1]),
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// The 511 API prepends a UTF-8 BOM to JSON responses, which makes
    /// JSONSerialization fail. Strip it if present.
    private static func stripBOM(_ data: Data?) -> Data? {
        guard var data = data else { return nil }
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if data.count >= 3, data.prefix(3).elementsEqual(bom) {
            data = data.dropFirst(3)
        }
        return data
    }
}
