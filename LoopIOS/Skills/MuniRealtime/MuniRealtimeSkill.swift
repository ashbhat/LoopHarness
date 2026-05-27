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
//  - muni_arrivals: given a route and stop, returns upcoming arrival
//    predictions with minutes until each bus/train.
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
- muni_arrivals: pass a `route` (e.g. "5R", "N", "38") and a `stop_id` \
(the numeric SFMTA stop code, e.g. "15553") **or** a `location` (street \
address or "lat,lng") to find the nearest stop. Returns upcoming arrivals \
with minutes until each vehicle.

When to call:
- The user asks "when is the next 5R?" or "next N Judah at Church and Duboce".
- You need transit info for trip planning in San Francisco.

Tips:
- If you don't know the stop_id, pass a `location` string and the skill will \
find the nearest stop on that route.
- Common routes: 5/5R (Fulton), 14/14R (Mission), 22 (Fillmore), 28/28R \
(19th Ave), 38/38R (Geary), N (Judah), KT (Ingleside–Third), J (Church), \
L (Taraval), M (Ocean View).
- If the tool returns an API-key error, tell the user to add their free 511 \
API key in Settings → Keys → 511 SF Bay. They can get one at \
https://511.org/open-data/token.
"""

    // MARK: - Tool schema

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "muni_arrivals",
                "description": "Get real-time SF Muni arrival predictions for a route and stop. Pass a stop_id (numeric SFMTA stop code) or a location (address / lat,lng) to find the nearest stop on the route.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "route": [
                            "type": "string",
                            "description": "Muni route name — e.g. \"5R\", \"N\", \"38\", \"KT\"."
                        ],
                        "stop_id": [
                            "type": "string",
                            "description": "Numeric SFMTA stop code (e.g. \"15553\"). Provide this OR location."
                        ],
                        "location": [
                            "type": "string",
                            "description": "Street address or \"lat,lng\" to resolve the nearest stop on the route. Provide this OR stop_id."
                        ]
                    ],
                    "required": ["route"]
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
        guard let route = (args["route"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !route.isEmpty else {
            completion(MessageStruct(
                role: "assistant",
                content: "I need a `route` (e.g. \"5R\", \"N\", \"38\") to look up Muni arrivals."
            ))
            return
        }

        let stopId = (args["stop_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let location = (args["location"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let stopId = stopId, !stopId.isEmpty {
            fetchArrivals(route: route, stopCode: stopId, completion: completion)
        } else if let location = location, !location.isEmpty {
            resolveAndFetch(route: route, location: location, completion: completion)
        } else {
            completion(MessageStruct(
                role: "assistant",
                content: "I need either a `stop_id` or a `location` to look up arrivals for the \(route)."
            ))
        }
    }

    // MARK: - Geocode → fetch

    private func resolveAndFetch(route: String,
                                 location: String,
                                 completion: @escaping (MessageStruct) -> Void) {
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(location) { placemarks, error in
            guard let coordinate = placemarks?.first?.location?.coordinate else {
                let detail = error?.localizedDescription ?? "No results"
                completion(MessageStruct(
                    role: "function",
                    content: "Could not geocode \"\(location)\": \(detail). Try passing a numeric stop_id instead.",
                    name: "muni_arrivals"
                ))
                return
            }
            self.fetchStopsNearby(route: route,
                                  latitude: coordinate.latitude,
                                  longitude: coordinate.longitude,
                                  completion: completion)
        }
    }

    /// Use the 511 stops endpoint to find the nearest stop on the given route,
    /// then fetch arrivals for that stop.
    private func fetchStopsNearby(route: String,
                                  latitude: Double,
                                  longitude: Double,
                                  completion: @escaping (MessageStruct) -> Void) {
        guard let apiKey = MuniRealtimeSkill.apiKey else {
            completion(MuniRealtimeSkill.noApiKeyMessage(for: "muni_arrivals"))
            return
        }

        let urlString = "\(MuniRealtimeSkill.baseURL)/stops"
            + "?api_key=\(apiKey)"
            + "&operator_id=\(MuniRealtimeSkill.agency)"
            + "&format=json"

        guard let url = URL(string: urlString) else {
            completion(MuniRealtimeSkill.errorResult("Bad URL for stops lookup."))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = self.stripBOM(data),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let detail = error?.localizedDescription ?? "Non-JSON response"
                completion(MuniRealtimeSkill.errorResult("Stops lookup failed: \(detail)"))
                return
            }

            guard let contents = json["Contents"] as? [String: Any],
                  let dataObjects = contents["dataObjects"] as? [String: Any],
                  let scheduledStopPoints = dataObjects["ScheduledStopPoint"] as? [[String: Any]] else {
                completion(MuniRealtimeSkill.errorResult("Unexpected stops response format."))
                return
            }

            let target = CLLocation(latitude: latitude, longitude: longitude)
            var bestStop: (code: String, name: String, distance: Double)?

            for stop in scheduledStopPoints {
                guard let loc = stop["Location"] as? [String: Any],
                      let latStr = loc["Latitude"] as? String,
                      let lonStr = loc["Longitude"] as? String,
                      let lat = Double(latStr),
                      let lon = Double(lonStr),
                      let extensions = stop["Extensions"] as? [String: Any],
                      let lines = extensions["LineRef"] as? [String] ?? (extensions["LineRef"] as? String).map({ [$0] }),
                      lines.contains(where: { $0.caseInsensitiveCompare(route) == .orderedSame }),
                      let code = stop["id"] as? String else {
                    continue
                }
                let name = (stop["Name"] as? String) ?? code
                let dist = target.distance(from: CLLocation(latitude: lat, longitude: lon))
                if bestStop == nil || dist < bestStop!.distance {
                    bestStop = (code, name, dist)
                }
            }

            guard let nearest = bestStop else {
                completion(MessageStruct(
                    role: "function",
                    content: "No stops found for route \(route) near that location. Check the route name and try again.",
                    name: "muni_arrivals"
                ))
                return
            }

            self.fetchArrivals(route: route,
                               stopCode: nearest.code,
                               stopName: nearest.name,
                               completion: completion)
        }.resume()
    }

    // MARK: - StopMonitoring

    private func fetchArrivals(route: String,
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

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = self.stripBOM(data),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let detail = error?.localizedDescription ?? "Non-JSON response"
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    completion(MuniRealtimeSkill.errorResult(
                        "511 API key was rejected (HTTP \(status)). "
                        + "Check that the key in Settings → Keys → 511 SF Bay is correct."
                    ))
                } else {
                    completion(MuniRealtimeSkill.errorResult(
                        "StopMonitoring request failed (HTTP \(status)): \(detail)"
                    ))
                }
                return
            }

            let visits = Self.extractVisits(from: json)
            let filtered = visits.filter { visit in
                guard let ref = visit["LineRef"] as? String else { return false }
                return ref.caseInsensitiveCompare(route) == .orderedSame
            }

            let arrivals = filtered.isEmpty ? visits : filtered
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
                                       route: String,
                                       stopCode: String,
                                       stopName: String?) -> String {
        let header: String
        if let name = stopName, !name.isEmpty {
            header = "Arrivals for route \(route) at \(name) (stop \(stopCode)):"
        } else {
            header = "Arrivals for route \(route) at stop \(stopCode):"
        }

        guard !arrivals.isEmpty else {
            return "\(header)\nNo upcoming arrivals found. The route may not be running right now, or the stop code may be incorrect."
        }

        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        var lines: [String] = [header]
        for (i, arrival) in arrivals.prefix(8).enumerated() {
            let line = (arrival["LineRef"] as? String) ?? route
            let dest = (arrival["Destination"] as? String) ?? "?"
            let direction = (arrival["DirectionRef"] as? String) ?? ""
            let dirLabel = direction == "IB" ? "Inbound" : direction == "OB" ? "Outbound" : direction

            let timeStr = (arrival["ExpectedDepartureTime"] as? String)
                ?? (arrival["ExpectedArrivalTime"] as? String)
                ?? (arrival["AimedDepartureTime"] as? String)
                ?? (arrival["AimedArrivalTime"] as? String)

            var minutesText = "time unknown"
            if let timeStr = timeStr,
               let date = iso.date(from: timeStr) ?? isoBasic.date(from: timeStr) {
                let mins = Int(date.timeIntervalSince(now) / 60)
                if mins <= 0 {
                    minutesText = "arriving now"
                } else if mins == 1 {
                    minutesText = "1 min"
                } else {
                    minutesText = "\(mins) min"
                }
            }

            var entry = "\(i + 1). \(line) → \(dest)"
            if !dirLabel.isEmpty { entry += " (\(dirLabel))" }
            entry += " — \(minutesText)"
            lines.append(entry)
        }

        if arrivals.count > 8 {
            lines.append("(\(arrivals.count - 8) more not shown)")
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

    /// The 511 API sometimes prepends a UTF-8 BOM to JSON responses, which
    /// causes JSONSerialization to fail. Strip it if present.
    private func stripBOM(_ data: Data?) -> Data? {
        guard var data = data else { return nil }
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if data.count >= 3, data.prefix(3).elementsEqual(bom) {
            data = data.dropFirst(3)
        }
        return data
    }
}
