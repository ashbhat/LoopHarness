//
//  MapsSkill.swift
//  Loop
//
//  Lets the model render a set of places as an inline map embed. The skill
//  itself does no searching — the model passes the structured list of places
//  (name + lat/lon + optional address) it already gathered (e.g. via
//  exa_search). The chat cell renders an MKMapView with one pin per place,
//  each pin's callout deep-links to Apple Maps.
//

import Foundation

struct MapsSkill {
    static let shared = MapsSkill()

    static let systemPromptFragment: String = """
You can render a set of places as an inline map embed with this tool:
- show_places_on_map: takes an array of `places` ({name, latitude, longitude, optional address}) plus an optional `title`. The chat surfaces a real map with one pin per place; each pin opens a callout with the name and an "Open in Maps" button.

When to call:
- The user is exploring places ("coffee shops near me", "interesting spots in Lisbon", "where are the climbing gyms") AND you have concrete lat/lon coordinates for each place.
- You searched the web (exa_search) and the results include latitude/longitude or a precise address you can resolve to coordinates. Skip the tool if you only have addresses without coordinates — make that explicit to the user instead of guessing.

Limits:
- Up to 20 places per call. Drop the long tail rather than truncating mid-list.
- Names should be short (the brand or place name), not full addresses.
- After calling the tool, you may add a one-liner to the chat ("Here are five spots within walking distance.") — don't restate the list, the map shows it.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "show_places_on_map",
                "description": "Render a set of geographic places as an inline map embed in the chat. Each place becomes a pin whose callout contains the place name and a button to open it in Apple Maps. Use only when you have concrete latitude/longitude for each place.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Optional caption shown above the map (e.g. \"Coffee near you\")."
                        ],
                        "places": [
                            "type": "array",
                            "description": "1–20 places to pin on the map. Order doesn't matter; the map auto-fits to show them all.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "name": [
                                        "type": "string",
                                        "description": "Short place name (brand / location), shown in the pin callout."
                                    ],
                                    "latitude": [
                                        "type": "number",
                                        "description": "Latitude in decimal degrees, WGS84."
                                    ],
                                    "longitude": [
                                        "type": "number",
                                        "description": "Longitude in decimal degrees, WGS84."
                                    ],
                                    "address": [
                                        "type": "string",
                                        "description": "Optional street address — shown under the name and passed to Apple Maps for a nicer destination label."
                                    ]
                                ],
                                "required": ["name", "latitude", "longitude"]
                            ]
                        ]
                    ],
                    "required": ["places"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "show_places_on_map"
    ]

    func handles(functionName: String) -> Bool {
        return MapsSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "show_places_on_map":
            return "drawing the map"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "show_places_on_map":
            handleShowPlaces(args: functionCall.arguments,
                             conversationId: functionCall.conversationId,
                             completion: completion)
        default:
            completion(MessageStruct(
                role: "function",
                content: "{\"error\":\"Unknown Maps tool '\(functionCall.name)'\"}",
                name: functionCall.name
            ))
        }
    }

    private func handleShowPlaces(args: [String: Any],
                                  conversationId: String?,
                                  completion: @escaping (MessageStruct) -> Void) {
        let title = (args["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = (args["places"] as? [[String: Any]]) ?? []
        // Cap to 20 — anything beyond and the map turns into a pin soup the
        // user can't tap. The system prompt warns the model; this is the hard
        // guard.
        let places: [MapPlace] = raw.prefix(20).compactMap { dict in
            guard let name = (dict["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            guard let lat = numericArg(dict["latitude"]),
                  let lon = numericArg(dict["longitude"]),
                  lat >= -90, lat <= 90, lon >= -180, lon <= 180 else {
                return nil
            }
            let address = (dict["address"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MapPlace(name: name,
                            latitude: lat,
                            longitude: lon,
                            address: (address?.isEmpty == false) ? address : nil)
        }
        guard !places.isEmpty else {
            completion(MessageStruct(
                role: "function",
                content: "{\"status\":\"error\",\"error\":\"No valid places to render. Each place needs a name and a latitude/longitude.\"}",
                name: "show_places_on_map"
            ))
            return
        }

        let attachment = MapAttachment(
            title: (title?.isEmpty == false) ? title : nil,
            places: places,
            conversationId: conversationId
        )

        // Body the model sees as the tool result. Short on purpose — the
        // user-visible content is the rendered map; we just confirm to the
        // LLM how many pins landed so it can write a tight follow-up.
        let body = "Rendered \(places.count) place\(places.count == 1 ? "" : "s") on a map for the user."

        completion(MessageStruct(
            role: "function",
            content: body,
            name: "show_places_on_map",
            mapAttachment: attachment
        ))
    }

    /// Coerce JSON-decoded numbers into Double. Some providers hand back
    /// Int / NSNumber / stringified numerics depending on serialization
    /// quirks, so we accept all three.
    private func numericArg(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
