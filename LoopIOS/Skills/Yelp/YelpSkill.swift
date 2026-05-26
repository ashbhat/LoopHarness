//
//  YelpSkill.swift
//  Loop
//
//  Lets Loop search for local businesses through the Yelp Fusion API.
//  Uses the YELP_API_KEY stored in the Keychain via Settings → Keys.
//
//  Tools the model sees:
//  - yelp_search_businesses: location-aware business search; returns name,
//    rating, review_count, price, categories, address, phone, url,
//    distance_miles, latitude, longitude for each result.
//

import Foundation

struct YelpSkill {
    static let shared = YelpSkill()

    private static let baseURL = "https://api.yelp.com/v3"

    static let systemPromptFragment: String = """
You can search for local businesses via Yelp with this tool:
- yelp_search_businesses: find restaurants, cafés, services, etc. Pass a `term` (what to search for) and either `location` (text like "San Francisco" or "NOPA, SF") or `latitude`/`longitude` for the search center. If the user says "near me", call get_current_location first, then pass the coordinates here.

Parameters:
- term (required): search query, e.g. "vegetarian dinner", "coffee", "dog-friendly brunch".
- location (optional): text location like "San Francisco, CA". Omit if passing lat/lon.
- latitude / longitude (optional): decimal coordinates. Use these when the user says "near me" (from get_current_location).
- radius_meters (optional): search radius in meters (max 40000, ~25mi). Default ~8000 (~5mi).
- limit (optional): max results, 1–10 (default 5).
- categories (optional): comma-separated Yelp category aliases, e.g. "vegan,vegetarian".
- price (optional): comma-separated price tiers, e.g. "1,2" for $ and $$.
- open_now (optional): true to show only currently open businesses.
- sort_by (optional): "best_match" (default), "rating", "review_count", or "distance".

Returns: a compact list of businesses with name, rating, review_count, price, categories, address, phone, url, distance_miles, and coordinates (latitude/longitude).

Tips:
- After getting results, call show_places_on_map with the returned coordinates to render a map.
- Keep limit small (3–5) for mobile readability.
- If Yelp is not configured, the tool tells you — ask the user to add a Yelp API key in Settings → Keys.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "yelp_search_businesses",
                "description": "Search for local businesses on Yelp. Returns name, rating, review_count, price, categories, address, phone, url, distance in miles, and coordinates for each result.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "term": [
                            "type": "string",
                            "description": "Search term, e.g. \"vegetarian dinner\", \"coffee shops\", \"plumber\"."
                        ],
                        "location": [
                            "type": "string",
                            "description": "Text location for the search (e.g. \"San Francisco, CA\"). Omit if passing latitude/longitude."
                        ],
                        "latitude": [
                            "type": "number",
                            "description": "Latitude of the search center in decimal degrees. Use with longitude instead of location."
                        ],
                        "longitude": [
                            "type": "number",
                            "description": "Longitude of the search center in decimal degrees. Use with latitude instead of location."
                        ],
                        "radius_meters": [
                            "type": "integer",
                            "description": "Search radius in meters (max 40000). Defaults to ~8000 (~5 miles)."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of results to return (1–10, default 5)."
                        ],
                        "categories": [
                            "type": "string",
                            "description": "Comma-separated Yelp category aliases to filter by (e.g. \"vegan,vegetarian\")."
                        ],
                        "price": [
                            "type": "string",
                            "description": "Comma-separated price tiers to filter by (e.g. \"1,2\" for $ and $$)."
                        ],
                        "open_now": [
                            "type": "boolean",
                            "description": "When true, only return businesses that are currently open."
                        ],
                        "sort_by": [
                            "type": "string",
                            "description": "Sort order: \"best_match\" (default), \"rating\", \"review_count\", or \"distance\"."
                        ]
                    ],
                    "required": ["term"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "yelp_search_businesses"
    ]

    func handles(functionName: String) -> Bool {
        return YelpSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "yelp_search_businesses":
            if let q = (call.arguments["term"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !q.isEmpty {
                return "searching Yelp for \(q)"
            }
            return "searching Yelp"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        if YelpSkill.apiKey == nil {
            completion(YelpSkill.noApiKeyMessage(for: functionCall.name))
            return
        }
        let args = functionCall.arguments
        switch functionCall.name {
        case "yelp_search_businesses":
            guard let term = args["term"] as? String, !term.isEmpty else {
                completion(missingArgs(for: "yelp_search_businesses", expected: "term"))
                return
            }
            searchBusinesses(term: term, args: args, completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Yelp tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handler

    private func searchBusinesses(term: String,
                                  args: [String: Any],
                                  completion: @escaping (MessageStruct) -> Void) {
        var params: [String: String] = ["term": term]

        if let loc = args["location"] as? String, !loc.isEmpty {
            params["location"] = loc
        }
        if let lat = doubleArg(args["latitude"]) {
            params["latitude"] = String(lat)
        }
        if let lon = doubleArg(args["longitude"]) {
            params["longitude"] = String(lon)
        }

        // Require at least one location signal.
        if params["location"] == nil && params["latitude"] == nil {
            completion(MessageStruct(
                role: "function",
                content: "{\"status\":\"error\",\"error\":\"Please provide either a `location` (text) or `latitude`/`longitude` coordinates. If the user said \\\"near me\\\", call get_current_location first.\"}",
                name: "yelp_search_businesses"
            ))
            return
        }

        if let r = intArg(args["radius_meters"]) {
            params["radius"] = String(min(max(r, 1), 40000))
        }

        let limit = intArg(args["limit"]) ?? 5
        params["limit"] = String(min(max(limit, 1), 10))

        if let cats = args["categories"] as? String, !cats.isEmpty {
            params["categories"] = cats
        }
        if let price = args["price"] as? String, !price.isEmpty {
            params["price"] = price
        }
        if let openNow = args["open_now"] as? Bool {
            params["open_now"] = openNow ? "true" : "false"
        }
        if let sort = args["sort_by"] as? String, !sort.isEmpty {
            params["sort_by"] = sort
        }

        get(path: "/businesses/search", params: params) { json, error in
            guard let json = json,
                  let businesses = json["businesses"] as? [[String: Any]] else {
                completion(YelpSkill.errorMessage("I was unable to search Yelp.", error: error))
                return
            }
            if businesses.isEmpty {
                completion(MessageStruct(
                    role: "function",
                    content: "No businesses found for \"\(term)\". Try broadening your search or changing the location.",
                    name: "yelp_search_businesses"
                ))
                return
            }
            var lines: [String] = ["Yelp results for \"\(term)\":"]
            for (i, biz) in businesses.enumerated() {
                let name = (biz["name"] as? String) ?? "(unknown)"
                let rating = biz["rating"] as? Double
                let reviewCount = biz["review_count"] as? Int
                let price = (biz["price"] as? String) ?? ""
                let url = (biz["url"] as? String) ?? ""
                let phone = (biz["display_phone"] as? String) ?? ""

                let cats = (biz["categories"] as? [[String: Any]])?
                    .compactMap { $0["title"] as? String }
                    .joined(separator: ", ") ?? ""

                let loc = biz["location"] as? [String: Any]
                let addr = (loc?["display_address"] as? [String])?.joined(separator: ", ") ?? ""

                let coords = biz["coordinates"] as? [String: Any]
                let lat = coords?["latitude"] as? Double
                let lon = coords?["longitude"] as? Double

                let distMeters = biz["distance"] as? Double
                let distMiles = distMeters.map { String(format: "%.1f mi", $0 / 1609.34) } ?? ""

                var entry = "\(i + 1). \(name)"
                if let r = rating { entry += " · ⭐ \(r)" }
                if let rc = reviewCount { entry += " (\(rc) reviews)" }
                if !price.isEmpty { entry += " · \(price)" }
                if !cats.isEmpty { entry += "\n   \(cats)" }
                if !addr.isEmpty { entry += "\n   📍 \(addr)" }
                if !distMiles.isEmpty { entry += " · \(distMiles)" }
                if !phone.isEmpty { entry += "\n   📞 \(phone)" }
                if let la = lat, let lo = lon {
                    entry += "\n   coords: \(la), \(lo)"
                }
                if !url.isEmpty { entry += "\n   \(url)" }
                lines.append(entry)
            }
            completion(MessageStruct(
                role: "function",
                content: lines.joined(separator: "\n\n"),
                name: "yelp_search_businesses"
            ))
        }
    }

    // MARK: - HTTP

    private static var apiKey: String? {
        return KeyStore.shared.value(for: .yelp)
    }

    private func get(path: String,
                     params: [String: String],
                     completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard let apiKey = YelpSkill.apiKey else {
            completion(nil, NSError(domain: "YelpSkill", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "No Yelp API key configured."]))
            return
        }
        var components = URLComponents(string: YelpSkill.baseURL + path)
        components?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else {
            completion(nil, NSError(domain: "YelpSkill", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "Bad Yelp URL"]))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            YelpSkill.parse(data: data, response: response, error: error, completion: completion)
        }.resume()
    }

    private static func parse(data: Data?,
                              response: URLResponse?,
                              error: Error?,
                              completion: @escaping ([String: Any]?, Error?) -> Void) {
        if let error = error {
            completion(nil, error)
            return
        }
        guard let data = data else {
            completion(nil, NSError(domain: "YelpSkill", code: -3,
                                    userInfo: [NSLocalizedDescriptionKey: "Empty Yelp response"]))
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            completion(nil, NSError(domain: "YelpSkill", code: status,
                                    userInfo: [NSLocalizedDescriptionKey: "Yelp returned non-JSON (status \(status)): \(snippet)"]))
            return
        }
        if status >= 400 {
            let errBody = json["error"] as? [String: Any]
            let msg = (errBody?["description"] as? String)
                ?? (json["error"] as? String)
                ?? "Yelp request failed (status \(status))"
            completion(nil, NSError(domain: "YelpSkill", code: status,
                                    userInfo: [NSLocalizedDescriptionKey: msg]))
            return
        }
        completion(json, nil)
    }

    // MARK: - Helpers

    private func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func doubleArg(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func missingArgs(for name: String, expected: String) -> MessageStruct {
        return MessageStruct(
            role: "assistant",
            content: "I need \(expected) to call \(name). Please provide them."
        )
    }

    private static func errorMessage(_ prefix: String, error: Error?) -> MessageStruct {
        let detail = error?.localizedDescription ?? "Unknown error"
        return MessageStruct(role: "assistant", content: "\(prefix) \(detail)")
    }

    private static func noApiKeyMessage(for functionName: String) -> MessageStruct {
        let content = KeyStore.missingKeyInstruction(
            for: [.yelp],
            purpose: "local business search (Yelp). Get a free API key at https://www.yelp.com/developers"
        )
        return MessageStruct(role: "function", content: content, name: functionName)
    }
}
