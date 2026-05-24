//
//  HiggsFieldSkill.swift
//  Loop
//
//  Lets Loop generate cinematic videos through the Higgsfield Cloud API
//  (https://cloud.higgsfield.ai). Calls the REST API directly from the
//  device using the HIGGSFIELD_API_KEY stored in the Keychain, so this
//  skill does not depend on the backend.
//
//  The Higgsfield Cloud API is asynchronous — generation requests return a
//  request_id immediately, and the caller polls for completion. This skill
//  surfaces three tools:
//    - higgsfield_generate_video: kick off a video generation job.
//    - higgsfield_check_video: poll a running job's status.
//    - higgsfield_list_models: enumerate available models and presets.
//

import Foundation

struct HiggsFieldSkill {
    static let shared = HiggsFieldSkill()

    private static let baseURL = "https://platform.higgsfield.ai"

    // MARK: - System prompt

    static let systemPromptFragment: String = """
You can generate cinematic videos through Higgsfield Cloud with these tools:
- higgsfield_generate_video: start a video generation job. Pass a `prompt` (required), plus optional `model` (endpoint slug — see higgsfield_list_models), `aspect_ratio` (e.g. "16:9", "9:16", "1:1"), `reference_image_url`, and `duration_seconds`. Returns a `request_id` to poll.
- higgsfield_check_video: check the status of a running job. Pass `request_id`. Returns `{status, video_url?, thumbnail_url?, error?}`. Status is one of: queued, in_progress, completed, failed, nsfw.
- higgsfield_list_models: list available Higgsfield models (Sora 2, Veo 3, Kling, Seedance, DoP, etc.) and their endpoints.

Workflow:
1. Call higgsfield_generate_video with a prompt. You get back a request_id immediately.
2. Poll with higgsfield_check_video every few seconds until status is "completed" or terminal ("failed"/"nsfw").
3. When completed, the response includes video_url (and thumbnail_url for images).

Notes:
- The user must set HIGGSFIELD_API_KEY in Settings → Keys first (format: KEY_ID:KEY_SECRET from cloud.higgsfield.ai → API Keys).
- Pricing is credit-based on Higgsfield Cloud. Each generation deducts credits; failed/nsfw jobs are refunded.
- If the key is missing, the tool returns an error with a hint to set it.
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "higgsfield_generate_video",
                "description": "Start a video generation job on Higgsfield Cloud. Returns a request_id to poll with higgsfield_check_video. Requires HIGGSFIELD_API_KEY.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "prompt": [
                            "type": "string",
                            "description": "Descriptive prompt for the video to generate."
                        ],
                        "model": [
                            "type": "string",
                            "description": "Model endpoint slug (e.g. \"wan/i2v\", \"kling/v2.1/pro/image-to-video\", \"veo/3\"). Defaults to \"wan/i2v\". Use higgsfield_list_models to see all options."
                        ],
                        "aspect_ratio": [
                            "type": "string",
                            "description": "Aspect ratio, e.g. \"16:9\", \"9:16\", \"1:1\". Defaults to \"16:9\"."
                        ],
                        "reference_image_url": [
                            "type": "string",
                            "description": "Optional URL of a reference image for image-to-video generation."
                        ],
                        "duration_seconds": [
                            "type": "integer",
                            "description": "Desired duration in seconds. Availability depends on the model."
                        ]
                    ],
                    "required": ["prompt"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "higgsfield_check_video",
                "description": "Check the status of a Higgsfield video generation job. Returns status (queued/in_progress/completed/failed/nsfw), video_url, thumbnail_url, or error.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "request_id": [
                            "type": "string",
                            "description": "The request_id returned by higgsfield_generate_video."
                        ]
                    ],
                    "required": ["request_id"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "higgsfield_list_models",
                "description": "List available Higgsfield Cloud video/image generation models, their endpoint slugs, and capabilities.",
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "higgsfield_generate_video",
        "higgsfield_check_video",
        "higgsfield_list_models"
    ]

    func handles(functionName: String) -> Bool {
        return HiggsFieldSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "higgsfield_generate_video":
            if let p = (call.arguments["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !p.isEmpty {
                let short = p.count > 40 ? String(p.prefix(40)) + "…" : p
                return "generating video: \(short)"
            }
            return "generating video"
        case "higgsfield_check_video":
            return "checking video status"
        case "higgsfield_list_models":
            return "listing Higgsfield models"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        switch functionCall.name {
        case "higgsfield_generate_video":
            guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
                completion(missingArgs(for: "higgsfield_generate_video", expected: "prompt"))
                return
            }
            let model = (args["model"] as? String) ?? "wan/i2v"
            let aspectRatio = (args["aspect_ratio"] as? String) ?? "16:9"
            let refImage = args["reference_image_url"] as? String
            let duration = intArg(args["duration_seconds"])
            generateVideo(prompt: prompt,
                          model: model,
                          aspectRatio: aspectRatio,
                          referenceImageURL: refImage,
                          durationSeconds: duration,
                          completion: completion)

        case "higgsfield_check_video":
            guard let requestId = args["request_id"] as? String, !requestId.isEmpty else {
                completion(missingArgs(for: "higgsfield_check_video", expected: "request_id"))
                return
            }
            checkVideo(requestId: requestId, completion: completion)

        case "higgsfield_list_models":
            listModels(completion: completion)

        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Higgsfield tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handlers

    private func generateVideo(prompt: String,
                               model: String,
                               aspectRatio: String,
                               referenceImageURL: String?,
                               durationSeconds: Int?,
                               completion: @escaping (MessageStruct) -> Void) {
        guard let creds = HiggsFieldSkill.credentials else {
            completion(HiggsFieldSkill.notConnectedMessage(for: "higgsfield_generate_video"))
            return
        }

        // Build endpoint — the v2 API takes the model slug as the path.
        let endpoint = model.hasPrefix("/") ? model : "/\(model)"

        // Build request body matching the v2 API format (input fields at
        // the top level of the JSON body).
        var body: [String: Any] = [
            "prompt": prompt,
            "aspect_ratio": aspectRatio
        ]
        if let ref = referenceImageURL, !ref.isEmpty {
            body["input_images"] = [
                ["type": "image_url", "image_url": ref]
            ]
        }
        if let dur = durationSeconds {
            body["duration"] = dur
        }

        post(path: endpoint, credentials: creds, body: body) { json, error in
            guard let json = json else {
                completion(HiggsFieldSkill.errorMessage(
                    "Failed to start Higgsfield video generation.",
                    error: error,
                    toolName: "higgsfield_generate_video"))
                return
            }
            // The API returns { request_id, status, status_url, cancel_url }
            let requestId = (json["request_id"] as? String) ?? ""
            let status = (json["status"] as? String) ?? "queued"
            let statusURL = (json["status_url"] as? String) ?? ""

            var payload: [String: Any] = [
                "request_id": requestId,
                "status": status
            ]
            if !statusURL.isEmpty { payload["status_url"] = statusURL }

            completion(HiggsFieldSkill.functionMessage(
                name: "higgsfield_generate_video", payload: payload))
        }
    }

    private func checkVideo(requestId: String,
                            completion: @escaping (MessageStruct) -> Void) {
        guard let creds = HiggsFieldSkill.credentials else {
            completion(HiggsFieldSkill.notConnectedMessage(for: "higgsfield_check_video"))
            return
        }

        let path = "/requests/\(requestId)/status"
        get(path: path, credentials: creds) { json, error in
            guard let json = json else {
                completion(HiggsFieldSkill.errorMessage(
                    "Failed to check Higgsfield job status.",
                    error: error,
                    toolName: "higgsfield_check_video"))
                return
            }
            let status = (json["status"] as? String) ?? "unknown"
            var payload: [String: Any] = [
                "request_id": requestId,
                "status": status
            ]
            // Completed jobs include media URLs.
            if let video = json["video"] as? [String: Any],
               let url = video["url"] as? String {
                payload["video_url"] = url
            }
            if let images = json["images"] as? [[String: Any]],
               let first = images.first,
               let url = first["url"] as? String {
                payload["thumbnail_url"] = url
            }
            // Failed jobs may include an error message.
            if status == "failed" || status == "nsfw" {
                let errMsg = (json["error"] as? String)
                    ?? (json["message"] as? String)
                if let e = errMsg { payload["error"] = e }
            }
            completion(HiggsFieldSkill.functionMessage(
                name: "higgsfield_check_video", payload: payload))
        }
    }

    private func listModels(completion: @escaping (MessageStruct) -> Void) {
        // The Higgsfield Cloud platform exposes many models through
        // endpoint-based routing. This is a curated catalog of the
        // publicly documented endpoints — kept static so the tool
        // works even without network access and doesn't require an
        // API key.
        let models: [[String: Any]] = [
            ["name": "Wan I2V",          "endpoint": "wan/i2v",                             "type": "image-to-video",  "notes": "Wan model — fast image-to-video generation"],
            ["name": "Wan T2V",          "endpoint": "wan/t2v",                             "type": "text-to-video",   "notes": "Wan model — text-to-video generation"],
            ["name": "Kling 2.1 Pro",    "endpoint": "kling/v2.1/pro/image-to-video",       "type": "image-to-video",  "notes": "Kling v2.1 Pro — high-quality cinematic video"],
            ["name": "Kling 2.1 Std",    "endpoint": "kling/v2.1/standard/image-to-video",  "type": "image-to-video",  "notes": "Kling v2.1 Standard — faster, lower cost"],
            ["name": "Veo 3",            "endpoint": "veo/3",                               "type": "text-to-video",   "notes": "Google Veo 3 — high-fidelity video generation"],
            ["name": "Seedance 1.0",     "endpoint": "seedance/v1/image-to-video",          "type": "image-to-video",  "notes": "ByteDance Seedance — dance/motion-focused video"],
            ["name": "Sora 2",           "endpoint": "sora/v2",                             "type": "text-to-video",   "notes": "OpenAI Sora 2 — cinematic text-to-video"],
            ["name": "DoP Turbo",        "endpoint": "v1/image2video/dop",                  "type": "image-to-video",  "notes": "Higgsfield DoP Turbo — fast cinematic camera movement"],
            ["name": "Flux Kontext",     "endpoint": "flux-pro/kontext/max/text-to-image",  "type": "text-to-image",   "notes": "Flux Pro Kontext — high-quality text-to-image"],
            ["name": "Soul T2I",         "endpoint": "v1/text2image/soul",                  "type": "text-to-image",   "notes": "Higgsfield Soul — stylized text-to-image"],
        ]
        completion(HiggsFieldSkill.functionMessage(
            name: "higgsfield_list_models",
            payload: ["models": models]))
    }

    // MARK: - HTTP

    /// Parsed KEY_ID:KEY_SECRET pair.
    private struct Credentials {
        let keyID: String
        let keySecret: String
        var authHeader: String { "Key \(keyID):\(keySecret)" }
    }

    private static var credentials: Credentials? {
        guard let raw = KeyStore.shared.value(for: .higgsfield), !raw.isEmpty else {
            return nil
        }
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return Credentials(keyID: String(parts[0]), keySecret: String(parts[1]))
    }

    private func post(path: String,
                      credentials: Credentials,
                      body: [String: Any],
                      completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard let url = URL(string: HiggsFieldSkill.baseURL + path) else {
            completion(nil, NSError(domain: "HiggsFieldSkill", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "Bad Higgsfield URL"]))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        URLSession.shared.dataTask(with: request) { data, response, error in
            HiggsFieldSkill.parse(data: data, response: response, error: error, completion: completion)
        }.resume()
    }

    private func get(path: String,
                     credentials: Credentials,
                     completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard let url = URL(string: HiggsFieldSkill.baseURL + path) else {
            completion(nil, NSError(domain: "HiggsFieldSkill", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "Bad Higgsfield URL"]))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(credentials.authHeader, forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            HiggsFieldSkill.parse(data: data, response: response, error: error, completion: completion)
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
            completion(nil, NSError(domain: "HiggsFieldSkill", code: -3,
                                    userInfo: [NSLocalizedDescriptionKey: "Empty Higgsfield response"]))
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            completion(nil, NSError(domain: "HiggsFieldSkill", code: status,
                                    userInfo: [NSLocalizedDescriptionKey: "Higgsfield returned non-JSON (status \(status)): \(snippet)"]))
            return
        }
        if status >= 400 {
            let msg = (json["error"] as? String)
                ?? (json["detail"] as? String)
                ?? (json["message"] as? String)
                ?? "Higgsfield request failed (status \(status))"
            completion(nil, NSError(domain: "HiggsFieldSkill", code: status,
                                    userInfo: [NSLocalizedDescriptionKey: msg]))
            return
        }
        completion(json, nil)
    }

    // MARK: - Helpers

    private func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }

    private func missingArgs(for name: String, expected: String) -> MessageStruct {
        return MessageStruct(role: "assistant",
                             content: "I need \(expected) to call \(name). Please provide them.")
    }

    private static func notConnectedMessage(for toolName: String) -> MessageStruct {
        let payload: [String: Any] = [
            "error": "higgsfield_not_connected",
            "hint": "Set your Higgsfield API key (KEY_ID:KEY_SECRET) in Settings → Keys → Higgsfield. Get one at cloud.higgsfield.ai → API Keys."
        ]
        return functionMessage(name: toolName, payload: payload)
    }

    private static func errorMessage(_ fallback: String,
                                     error: Error?,
                                     toolName: String) -> MessageStruct {
        let msg = error?.localizedDescription ?? fallback
        return functionMessage(name: toolName, payload: ["error": msg])
    }

    private static func functionMessage(name: String, payload: Any) -> MessageStruct {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "{}"
        }
        return MessageStruct(role: "function", content: json, name: name)
    }
}
