//
//  KimiChat.swift
//  Loop
//
//  Direct client-side Moonshot/Kimi path. Used by AgentHarness when the
//  selected model's provider is `.kimi` and the user has a KIMI_API_KEY set
//  in the Keys panel (or bundled via Secrets.xcconfig). Talks straight to
//  api.moonshot.ai/v1/chat/completions with the user's own key — no backend.
//
//  Wire format is OpenAI-compatible: same `messages` shape, same
//  `{type:"function", function:{…}}` tool schemas, same `tool_calls` ↔
//  `role:"tool"` + `tool_call_id` pairing. So this client delegates message
//  mapping and tool-call sanitisation to `OpenAIChat` and only differs in:
//    • endpoint (api.moonshot.ai instead of api.openai.com)
//    • model id default (kimi-k2.6)
//    • token cap parameter name (`max_completion_tokens`, per Kimi docs —
//      `max_tokens` is deprecated on Kimi K2.6)
//    • error domain so a failure surfaces as "Kimi API error: …" not OpenAI.
//

import Foundation

final class KimiChat {

    static let shared = KimiChat()
    private init() {}

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private let endpoint = URL(string: "https://api.moonshot.ai/v1/chat/completions")!

    /// Generous cap so long agent turns (multiple tool calls, recap, follow-up
    /// prose) aren't truncated; Kimi K2.6 happily streams much more if asked.
    private let maxCompletionTokens = 4096

    func chat(messages: [MessageStruct],
              tools: [[String: Any]]? = nil,
              completion: @escaping (MessageStruct?, Error?) -> Void) {

        guard let apiKey = KeyStore.shared.value(for: .kimi),
              !apiKey.isEmpty else {
            completion(nil, Self.error(
                "Kimi K2.6 is selected but no Kimi key is set. Add KIMI_API_KEY in Settings ▸ Keys, or switch the model in Settings ▸ Model."))
            return
        }

        let modelID = ModelSelectionStore.current.apiModelID ?? "kimi-k2.6"

        var body: [String: Any] = [
            "model": modelID,
            "messages": OpenAIChat.wireMessages(from: messages),
            "max_completion_tokens": maxCompletionTokens,
        ]
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil, Self.error("Failed to encode the Kimi request body."))
            return
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        req.timeoutInterval = 120

        print("KimiChat: POST \(endpoint) model=\(modelID) tools=\((tools ?? []).count)")
        let task = session.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(nil, Self.error("Network error talking to Kimi: \(error.localizedDescription)"))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                let detail = Self.errorDetail(from: bodyStr) ?? "HTTP \(http.statusCode)"
                completion(nil, Self.error("Kimi API error: \(detail)"))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                completion(nil, Self.error("Kimi returned an unexpected payload."))
                return
            }

            // Same tool_calls shape as OpenAI: an array on the assistant turn,
            // each entry carrying its own id so the matching `role:"tool"`
            // reply can pair back via `tool_call_id` on the next user turn.
            let calls: [FunctionCallStruct]
            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                calls = toolCalls.compactMap { entry in
                    guard let fn = entry["function"] as? [String: Any],
                          let name = fn["name"] as? String else { return nil }
                    let argsString = fn["arguments"] as? String ?? "{}"
                    var argsDict: [String: Any] = [:]
                    if let d = argsString.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        argsDict = parsed
                    }
                    let id = entry["id"] as? String
                    return FunctionCallStruct(name: name, arguments: argsDict, callId: id)
                }
            } else {
                calls = []
            }
            let content = (message["content"] as? String) ?? ""
            let msg = MessageStruct(
                role: "assistant",
                content: content,
                model: ModelSelectionStore.current.stampedMessageModel,
                functions: calls)
            completion(msg, nil)
        }
        task.resume()
    }

    // MARK: - Errors

    private static func error(_ message: String) -> NSError {
        NSError(domain: "KimiChat", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Pulls `error.message` (or `error.code`/`message`) out of a Moonshot
    /// error body. Same envelope shape OpenAI uses.
    private static func errorDetail(from bodyStr: String) -> String? {
        guard let data = bodyStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let err = json["error"] as? [String: Any] {
            if let msg = err["message"] as? String { return msg }
            if let code = err["code"] as? String { return code }
        }
        return json["message"] as? String
    }
}
