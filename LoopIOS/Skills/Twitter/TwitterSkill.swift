//
//  TwitterSkill.swift
//  Loop
//
//  Posts tweets via the X (Twitter) API v2 using OAuth 1.0a. Reads four
//  credentials from KeyStore: X_API_KEY, X_API_SECRET, X_ACCESS_TOKEN,
//  X_ACCESS_TOKEN_SECRET. The write tool — post_tweet — routes through
//  TwitterSkillHost so the chat surface can present a confirmation alert
//  before the tweet fires (same pattern as SlackSkillHost / GitHubSkillHost).
//

import Foundation
import CommonCrypto

/// Host plumbing that lets the skill ask the UI layer to confirm a tweet
/// before hitting POST /2/tweets. MessagingVC (iOS) and
/// ConversationWindowController (macOS) conform.
protocol TwitterSkillHost: AnyObject {
    func twitterSkill(requestPostConfirmation text: String,
                      completion: @escaping (Bool) -> Void)
}

final class TwitterSkill {

    static let shared = TwitterSkill()

    /// Set by the chat-surface host on launch so post_tweet can request a
    /// confirmation alert. Nil in headless contexts (BackgroundScheduler,
    /// SubAgentRuntime) — the tool refuses rather than posting silently.
    weak var host: TwitterSkillHost?

    private init() {}

    // MARK: - System prompt

    static let systemPromptFragment: String = """
    You can post tweets to X (Twitter) on the user's behalf:
    - post_tweet: post a tweet (max 280 characters). This pops a confirmation alert on the user's device — the user's Post tap IS the checkpoint, so don't ask again in chat. If the tool returns `cancelled`, drop the draft.

    Workflow tips:
    - Keep tweets within 280 characters. The tool rejects anything longer.
    - If a tool returns `{"error":"x_not_connected"}`, tell the user to add their X API keys in Settings → Keys → X (Twitter).
    - The user must supply four keys: API Key, API Secret, Access Token, and Access Token Secret. These come from the X Developer Portal (developer.x.com).
    """

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "post_tweet",
                "description": "Post a tweet to X (Twitter). Maximum 280 characters. Pops a confirmation alert before posting — the user's Post tap IS the confirmation, do not ask again in chat.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "text": [
                            "type": "string",
                            "description": "The tweet text. Must be 1–280 characters."
                        ]
                    ],
                    "required": ["text"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["post_tweet"]

    func handles(functionName: String) -> Bool {
        return TwitterSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        guard call.name == "post_tweet" else { return nil }
        return "posting tweet"
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        switch functionCall.name {
        case "post_tweet":
            guard let text = args["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                completion(missingArgs(for: "post_tweet", expected: "text"))
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= 280 else {
                completion(Self.functionMessage(
                    name: "post_tweet",
                    payload: [
                        "status": "error",
                        "error": "tweet_too_long",
                        "hint": "Tweet is \(trimmed.count) characters — the limit is 280. Shorten it and try again."
                    ]
                ))
                return
            }
            postTweet(text: trimmed, completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Twitter tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handler

    private func postTweet(text: String,
                           completion: @escaping (MessageStruct) -> Void) {
        guard let host else {
            completion(Self.functionMessage(
                name: "post_tweet",
                payload: [
                    "status": "blocked",
                    "reason": "no_confirmation_host",
                    "hint": "Posting is blocked in headless / scheduled contexts because no UI is available to confirm."
                ]
            ))
            return
        }

        DispatchQueue.main.async {
            host.twitterSkill(requestPostConfirmation: text) { [weak self] approved in
                guard let self else { return }
                guard approved else {
                    completion(Self.functionMessage(
                        name: "post_tweet",
                        payload: ["status": "cancelled"]
                    ))
                    return
                }
                self.executePostTweet(text: text, completion: completion)
            }
        }
    }

    private func executePostTweet(text: String,
                                  completion: @escaping (MessageStruct) -> Void) {
        guard let apiKey = KeyStore.shared.value(for: .xAPIKey),
              let apiSecret = KeyStore.shared.value(for: .xAPISecret),
              let accessToken = KeyStore.shared.value(for: .xAccessToken),
              let accessTokenSecret = KeyStore.shared.value(for: .xAccessTokenSecret),
              !apiKey.isEmpty, !apiSecret.isEmpty,
              !accessToken.isEmpty, !accessTokenSecret.isEmpty else {
            completion(Self.functionMessage(
                name: "post_tweet",
                payload: [
                    "error": "x_not_connected",
                    "hint": "Ask the user to add their X API keys in Settings → Keys → X (Twitter). Four values are needed: API Key, API Secret, Access Token, Access Token Secret."
                ]
            ))
            return
        }

        let urlString = "https://api.twitter.com/2/tweets"
        guard let url = URL(string: urlString) else {
            completion(Self.functionMessage(
                name: "post_tweet",
                payload: ["status": "error", "error": "invalid_url"]
            ))
            return
        }

        let bodyDict: [String: Any] = ["text": text]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict, options: []) else {
            completion(Self.functionMessage(
                name: "post_tweet",
                payload: ["status": "error", "error": "json_encode_failed"]
            ))
            return
        }

        let authHeader = Self.oauthHeader(
            httpMethod: "POST",
            url: urlString,
            consumerKey: apiKey,
            consumerSecret: apiSecret,
            token: accessToken,
            tokenSecret: accessTokenSecret
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(Self.functionMessage(
                        name: "post_tweet",
                        payload: [
                            "status": "error",
                            "error": "network_error",
                            "detail": error.localizedDescription
                        ]
                    ))
                    return
                }

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let snippet = data.flatMap { String(data: $0.prefix(300), encoding: .utf8) } ?? ""
                    completion(Self.functionMessage(
                        name: "post_tweet",
                        payload: [
                            "status": "error",
                            "error": "invalid_response",
                            "http_status": statusCode,
                            "body": snippet
                        ]
                    ))
                    return
                }

                if statusCode == 429 {
                    completion(Self.functionMessage(
                        name: "post_tweet",
                        payload: [
                            "status": "error",
                            "error": "rate_limited",
                            "hint": "X rate-limited the request. Wait a moment and try again."
                        ]
                    ))
                    return
                }

                if statusCode == 401 || statusCode == 403 {
                    let detail = (json["detail"] as? String)
                        ?? (json["title"] as? String)
                        ?? "Authentication failed"
                    completion(Self.functionMessage(
                        name: "post_tweet",
                        payload: [
                            "status": "error",
                            "error": "auth_failed",
                            "http_status": statusCode,
                            "detail": detail,
                            "hint": "Check the X API keys in Settings → Keys → X (Twitter). The token may be expired or lack write permissions."
                        ]
                    ))
                    return
                }

                guard statusCode == 201,
                      let tweetData = json["data"] as? [String: Any],
                      let tweetId = tweetData["id"] as? String else {
                    let detail = (json["detail"] as? String)
                        ?? (json["title"] as? String)
                        ?? "Unexpected response"
                    completion(Self.functionMessage(
                        name: "post_tweet",
                        payload: [
                            "status": "error",
                            "error": "api_error",
                            "http_status": statusCode,
                            "detail": detail
                        ]
                    ))
                    return
                }

                let tweetURL = "https://x.com/i/status/\(tweetId)"
                completion(Self.functionMessage(
                    name: "post_tweet",
                    payload: [
                        "status": "posted",
                        "tweet_id": tweetId,
                        "tweet_url": tweetURL,
                        "summary": "Tweet posted successfully: \(tweetURL)"
                    ]
                ))
            }
        }.resume()
    }

    // MARK: - OAuth 1.0a

    /// Build the OAuth 1.0a `Authorization` header value for a request.
    /// Implements the full signature base string + HMAC-SHA1 signing flow
    /// per https://developer.x.com/en/docs/authentication/oauth-1-0a.
    private static func oauthHeader(httpMethod: String,
                                    url: String,
                                    consumerKey: String,
                                    consumerSecret: String,
                                    token: String,
                                    tokenSecret: String) -> String {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let timestamp = String(Int(Date().timeIntervalSince1970))

        var params: [String: String] = [
            "oauth_consumer_key":     consumerKey,
            "oauth_nonce":            nonce,
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_timestamp":        timestamp,
            "oauth_token":            token,
            "oauth_version":          "1.0"
        ]

        // Build the signature base string.
        let paramString = params
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")

        let baseString = [
            httpMethod.uppercased(),
            percentEncode(url),
            percentEncode(paramString)
        ].joined(separator: "&")

        let signingKey = "\(percentEncode(consumerSecret))&\(percentEncode(tokenSecret))"
        let signature = hmacSHA1(key: signingKey, data: baseString)
        params["oauth_signature"] = signature

        let header = params
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\"\(percentEncode($0.value))\"" }
            .joined(separator: ", ")

        return "OAuth \(header)"
    }

    /// RFC 3986 percent encoding (uppercase hex, unreserved chars exempt).
    private static func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// HMAC-SHA1 via CommonCrypto, returns a Base64-encoded digest.
    private static func hmacSHA1(key: String, data: String) -> String {
        let keyData = Array(key.utf8)
        let dataBytes = Array(data.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))

        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
               keyData, keyData.count,
               dataBytes, dataBytes.count,
               &digest)

        return Data(digest).base64EncodedString()
    }

    // MARK: - Response helpers

    private func missingArgs(for name: String, expected: String) -> MessageStruct {
        return MessageStruct(
            role: "assistant",
            content: "I need \(expected) to call \(name). Please provide it."
        )
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
