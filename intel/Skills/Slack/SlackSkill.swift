//
//  SlackSkill.swift
//  Loop
//
//  Personal-only Slack integration. Reads the user's `xoxp-` token from
//  KeyStore (Settings → Keys → Slack User Token) and talks directly to the
//  Slack Web API — no Loop backend in the path, no OAuth dance. Multi-user
//  OAuth is a Phase 2 swap of the token source.
//
//  Tools mirror NotionSkill's shape so SkillDispatcher routes calls the same
//  way. The one side-effecting tool — send_slack_message — routes through
//  SlackSkillHost so the iOS / Mac chat surface can present a confirmation
//  alert before chat.postMessage fires (same pattern as CalendarSkillHost).
//

import Foundation

/// Host plumbing that lets the skill ask the UI layer to confirm a Slack
/// send before hitting `chat.postMessage`. MessagingVC (iOS) and
/// ConversationWindowController (macOS) conform.
protocol SlackSkillHost: AnyObject {
    func slackSkill(requestSendConfirmation channelLabel: String,
                    text: String,
                    completion: @escaping (Bool) -> Void)
}

final class SlackSkill {

    static let shared = SlackSkill()

    /// Set by the chat-surface host on launch so write tools can request a
    /// confirmation alert. Nil in headless contexts (BackgroundScheduler,
    /// SubAgentRuntime) — send tools refuse rather than fire silently.
    weak var host: SlackSkillHost?

    private init() {}

    // MARK: - System prompt

    static let systemPromptFragment: String = """
You can read and act on the user's personal Slack workspace through these tools:
- list_slack_channels: list public channels, private channels, DMs, and group DMs the user is a member of. Returns id + name + type for each.
- slack_channel_history: read recent messages from a channel by id. Pass `limit` to cap the count (default 30, max 200). Pass `oldest` (Slack ts string) for paging.
- slack_thread_replies: read messages in a thread. Needs the channel id + parent message `ts`.
- find_slack_user: resolve a display name / real name to a Slack user id. Returns id, name, real_name for the top matches.
- search_slack: run a Slack search query (supports Slack syntax — `from:@tanay`, `in:#general`, `after:yesterday`, etc).
- slack_mentions: shortcut for "what mentions am I getting" — searches for messages mentioning the connected user across the workspace.
- open_slack_dm: open (or get) the DM channel id with a given user id. Use this to turn a user id from `find_slack_user` into a channel id you can post to.
- send_slack_message: post a message to a channel id (channel, DM, or thread). This pops a confirmation alert on the user's device — the user's Send tap IS the checkpoint, so don't ask again in chat. If the tool returns `cancelled`, drop the draft.

Workflow tips:
- IDs come from list_slack_channels / find_slack_user / open_slack_dm. Chain calls — never guess channel or user ids.
- When the user names a person ("DM Tanay"), call find_slack_user first, then open_slack_dm to get the channel id, then send_slack_message.
- If a tool returns `{"error":"slack_not_connected"}`, tell the user to paste an xoxp- token in Settings → Keys → Slack User Token before retrying.
- This is a single-workspace personal integration — there's only one Slack signed in at a time.
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "list_slack_channels",
                "description": "List Slack conversations the user can see: public channels, private channels, DMs, and group DMs. Returns id + name + type for each.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "types": [
                            "type": "string",
                            "description": "Optional CSV of conversation types to include. Any of: public_channel, private_channel, im, mpim. Defaults to all four."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum conversations to return per page. Default 200, max 1000."
                        ]
                    ],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "slack_channel_history",
                "description": "Read recent messages from a Slack channel, DM, or group DM by id.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "channel": [
                            "type": "string",
                            "description": "Slack channel id (starts with C, G, D, or M). Use list_slack_channels to discover ids."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "How many messages to return. Default 30, max 200."
                        ],
                        "oldest": [
                            "type": "string",
                            "description": "Optional Slack ts cursor (e.g. \"1715300000.000100\"). Only messages newer than this are returned. Use for paging."
                        ]
                    ],
                    "required": ["channel"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "slack_thread_replies",
                "description": "Read all replies in a Slack thread, given the channel id and the parent message ts.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "channel": [
                            "type": "string",
                            "description": "Slack channel id containing the thread."
                        ],
                        "ts": [
                            "type": "string",
                            "description": "Slack ts of the parent message that started the thread."
                        ]
                    ],
                    "required": ["channel", "ts"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "find_slack_user",
                "description": "Resolve a person's display name or real name to a Slack user id. Returns the top matches with id, name, real_name. Case-insensitive substring match.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Name or partial name to search for (e.g. \"tanay\", \"Tanay Pradhan\")."
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "search_slack",
                "description": "Run a Slack workspace search. Supports Slack search syntax: `from:@tanay`, `in:#general`, `after:yesterday`, `has:link`, etc. Returns the top matching messages with channel, user, text, ts, permalink.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Slack search query string."
                        ],
                        "count": [
                            "type": "integer",
                            "description": "How many matches to return. Default 20, max 100."
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "slack_mentions",
                "description": "List recent messages mentioning the connected Slack user. Shortcut for search_slack with the user's own <@USERID> as the query.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "count": [
                            "type": "integer",
                            "description": "How many mentions to return. Default 20, max 100."
                        ]
                    ],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "open_slack_dm",
                "description": "Open (or get) the DM channel id for a given Slack user id. Returns the channel id usable with send_slack_message / slack_channel_history.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "user_id": [
                            "type": "string",
                            "description": "Slack user id (starts with U or W). Use find_slack_user to resolve a name first."
                        ]
                    ],
                    "required": ["user_id"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "send_slack_message",
                "description": "Post a message to a Slack channel id (channel, DM, or thread). Pops a confirmation alert before sending — the user's Send tap IS the confirmation checkpoint, do not ask again in chat. Returns sent / cancelled / blocked.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "channel": [
                            "type": "string",
                            "description": "Slack channel id to post into."
                        ],
                        "text": [
                            "type": "string",
                            "description": "Message text. Plain text or Slack mrkdwn."
                        ],
                        "thread_ts": [
                            "type": "string",
                            "description": "Optional parent ts to post as a thread reply."
                        ]
                    ],
                    "required": ["channel", "text"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "list_slack_channels",
        "slack_channel_history",
        "slack_thread_replies",
        "find_slack_user",
        "search_slack",
        "slack_mentions",
        "open_slack_dm",
        "send_slack_message"
    ]

    func handles(functionName: String) -> Bool {
        return SlackSkill.toolNames.contains(functionName)
    }

    /// Shimmer label shown while a tool runs.
    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "list_slack_channels":   return "listing Slack channels"
        case "slack_channel_history": return "reading Slack messages"
        case "slack_thread_replies":  return "reading Slack thread"
        case "find_slack_user":
            if let q = call.arguments["query"] as? String, !q.isEmpty {
                return "finding Slack user \(q)"
            }
            return "finding Slack user"
        case "search_slack":
            if let q = call.arguments["query"] as? String, !q.isEmpty {
                return "searching Slack for \(q)"
            }
            return "searching Slack"
        case "slack_mentions":        return "checking Slack mentions"
        case "open_slack_dm":         return "opening Slack DM"
        case "send_slack_message":    return "sending Slack message"
        default:                      return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        switch functionCall.name {
        case "list_slack_channels":
            listChannels(types: args["types"] as? String,
                         limit: SlackSkill.intArg(args["limit"]),
                         completion: completion)
        case "slack_channel_history":
            guard let channel = args["channel"] as? String, !channel.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "channel")); return
            }
            channelHistory(channel: channel,
                           limit: SlackSkill.intArg(args["limit"]),
                           oldest: args["oldest"] as? String,
                           completion: completion)
        case "slack_thread_replies":
            guard let channel = args["channel"] as? String, !channel.isEmpty,
                  let ts = args["ts"] as? String, !ts.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "channel, ts")); return
            }
            threadReplies(channel: channel, ts: ts, completion: completion)
        case "find_slack_user":
            guard let query = args["query"] as? String, !query.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "query")); return
            }
            findUser(query: query, completion: completion)
        case "search_slack":
            guard let query = args["query"] as? String, !query.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "query")); return
            }
            searchMessages(query: query,
                           count: SlackSkill.intArg(args["count"]),
                           completion: completion)
        case "slack_mentions":
            slackMentions(count: SlackSkill.intArg(args["count"]),
                          completion: completion)
        case "open_slack_dm":
            guard let userId = args["user_id"] as? String, !userId.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "user_id")); return
            }
            openDM(userId: userId, completion: completion)
        case "send_slack_message":
            guard let channel = args["channel"] as? String, !channel.isEmpty,
                  let text = args["text"] as? String, !text.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "channel, text")); return
            }
            sendMessage(channel: channel,
                        text: text,
                        threadTs: args["thread_ts"] as? String,
                        completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Slack tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handlers

    private func listChannels(types: String?,
                              limit: Int?,
                              completion: @escaping (MessageStruct) -> Void) {
        var body: [String: Any] = [
            "types": types ?? "public_channel,private_channel,mpim,im",
            "limit": min(max(limit ?? 200, 1), 1000)
        ]
        // Slack omits archived by default but be explicit.
        body["exclude_archived"] = true
        slackPOST(method: "conversations.list", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                completion(self.errorMessage(for: "list_slack_channels", error: err))
            case .success(let dict):
                let raw = dict["channels"] as? [[String: Any]] ?? []
                let trimmed: [[String: Any]] = raw.map { c in
                    var out: [String: Any] = [
                        "id": c["id"] as? String ?? "",
                        "name": Self.channelName(from: c),
                        "type": Self.channelType(from: c)
                    ]
                    if let isMember = c["is_member"] as? Bool { out["is_member"] = isMember }
                    if let userId = c["user"] as? String { out["dm_user_id"] = userId }
                    return out
                }
                completion(Self.functionMessage(
                    name: "list_slack_channels",
                    payload: ["channels": trimmed]
                ))
            }
        }
    }

    private func channelHistory(channel: String,
                                limit: Int?,
                                oldest: String?,
                                completion: @escaping (MessageStruct) -> Void) {
        var body: [String: Any] = [
            "channel": channel,
            "limit": min(max(limit ?? 30, 1), 200)
        ]
        if let oldest, !oldest.isEmpty { body["oldest"] = oldest }
        slackPOST(method: "conversations.history", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                completion(self.errorMessage(for: "slack_channel_history", error: err))
            case .success(let dict):
                let messages = (dict["messages"] as? [[String: Any]] ?? []).map(Self.trimMessage)
                completion(Self.functionMessage(
                    name: "slack_channel_history",
                    payload: ["messages": messages,
                              "has_more": dict["has_more"] as? Bool ?? false]
                ))
            }
        }
    }

    private func threadReplies(channel: String,
                               ts: String,
                               completion: @escaping (MessageStruct) -> Void) {
        let body: [String: Any] = ["channel": channel, "ts": ts]
        slackPOST(method: "conversations.replies", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                completion(self.errorMessage(for: "slack_thread_replies", error: err))
            case .success(let dict):
                let messages = (dict["messages"] as? [[String: Any]] ?? []).map(Self.trimMessage)
                completion(Self.functionMessage(
                    name: "slack_thread_replies",
                    payload: ["messages": messages]
                ))
            }
        }
    }

    private func findUser(query: String,
                          completion: @escaping (MessageStruct) -> Void) {
        loadUsers { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                completion(self.errorMessage(for: "find_slack_user", error: err))
            case .success(let users):
                let needle = query.lowercased()
                let matches = users.filter { u in
                    let name = (u["name"] as? String ?? "").lowercased()
                    let real = (u["real_name"] as? String ?? "").lowercased()
                    let display = ((u["profile"] as? [String: Any])?["display_name"] as? String ?? "").lowercased()
                    return name.contains(needle) || real.contains(needle) || display.contains(needle)
                }.prefix(10).map { u -> [String: Any] in
                    [
                        "id": u["id"] as? String ?? "",
                        "name": u["name"] as? String ?? "",
                        "real_name": u["real_name"] as? String ?? "",
                        "display_name": (u["profile"] as? [String: Any])?["display_name"] as? String ?? ""
                    ]
                }
                completion(Self.functionMessage(
                    name: "find_slack_user",
                    payload: ["matches": Array(matches)]
                ))
            }
        }
    }

    private func searchMessages(query: String,
                                count: Int?,
                                completion: @escaping (MessageStruct) -> Void) {
        let body: [String: Any] = [
            "query": query,
            "count": min(max(count ?? 20, 1), 100),
            "sort": "timestamp",
            "sort_dir": "desc"
        ]
        slackPOST(method: "search.messages", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                completion(self.errorMessage(for: "search_slack", error: err))
            case .success(let dict):
                let matchesRaw = (dict["messages"] as? [String: Any])?["matches"] as? [[String: Any]] ?? []
                let matches: [[String: Any]] = matchesRaw.map { m in
                    [
                        "channel_id": (m["channel"] as? [String: Any])?["id"] as? String ?? "",
                        "channel_name": (m["channel"] as? [String: Any])?["name"] as? String ?? "",
                        "user": m["user"] as? String ?? "",
                        "username": m["username"] as? String ?? "",
                        "text": m["text"] as? String ?? "",
                        "ts": m["ts"] as? String ?? "",
                        "permalink": m["permalink"] as? String ?? ""
                    ]
                }
                completion(Self.functionMessage(
                    name: "search_slack",
                    payload: ["matches": matches]
                ))
            }
        }
    }

    private func slackMentions(count: Int?,
                               completion: @escaping (MessageStruct) -> Void) {
        authedUserId { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                completion(self.errorMessage(for: "slack_mentions", error: err))
            case .success(let userId):
                self.searchMessages(query: "<@\(userId)>", count: count) { msg in
                    // Re-tag under the right tool name.
                    completion(MessageStruct(role: "function",
                                             content: msg.content,
                                             name: "slack_mentions"))
                }
            }
        }
    }

    private func openDM(userId: String,
                        completion: @escaping (MessageStruct) -> Void) {
        let body: [String: Any] = ["users": userId]
        slackPOST(method: "conversations.open", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                completion(self.errorMessage(for: "open_slack_dm", error: err))
            case .success(let dict):
                let channel = (dict["channel"] as? [String: Any])?["id"] as? String ?? ""
                completion(Self.functionMessage(
                    name: "open_slack_dm",
                    payload: ["channel_id": channel]
                ))
            }
        }
    }

    private func sendMessage(channel: String,
                             text: String,
                             threadTs: String?,
                             completion: @escaping (MessageStruct) -> Void) {
        guard let host else {
            completion(Self.functionMessage(
                name: "send_slack_message",
                payload: ["status": "blocked",
                          "reason": "no_confirmation_host",
                          "hint": "Sends are blocked in headless / scheduled contexts because no UI is available to confirm."]
            ))
            return
        }
        resolveChannelLabel(channel: channel) { [weak self] label in
            guard let self else { return }
            DispatchQueue.main.async {
                host.slackSkill(requestSendConfirmation: label, text: text) { approved in
                    guard approved else {
                        completion(Self.functionMessage(
                            name: "send_slack_message",
                            payload: ["status": "cancelled",
                                      "channel": channel]
                        ))
                        return
                    }
                    var body: [String: Any] = ["channel": channel, "text": text]
                    if let threadTs, !threadTs.isEmpty { body["thread_ts"] = threadTs }
                    self.slackPOST(method: "chat.postMessage", body: body) { result in
                        switch result {
                        case .failure(let err):
                            completion(self.errorMessage(for: "send_slack_message", error: err))
                        case .success(let dict):
                            completion(Self.functionMessage(
                                name: "send_slack_message",
                                payload: ["status": "sent",
                                          "channel": channel,
                                          "ts": dict["ts"] as? String ?? ""]
                            ))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Caches

    /// `users.list` is rate-limit Tier 2 and heavy; cache the full snapshot
    /// for 5 minutes so consecutive find_slack_user calls don't re-page.
    private var usersCache: (loadedAt: Date, users: [[String: Any]])?
    private let usersCacheTTL: TimeInterval = 300

    /// `auth.test` resolves the connected user's own id, needed for the
    /// mentions-search query. Cache for the process lifetime.
    private var authedUserIdCache: String?

    private func loadUsers(completion: @escaping (Result<[[String: Any]], SlackError>) -> Void) {
        if let cache = usersCache, Date().timeIntervalSince(cache.loadedAt) < usersCacheTTL {
            completion(.success(cache.users)); return
        }
        // Page through users.list.
        var collected: [[String: Any]] = []
        func fetch(cursor: String?) {
            var body: [String: Any] = ["limit": 200]
            if let cursor, !cursor.isEmpty { body["cursor"] = cursor }
            slackPOST(method: "users.list", body: body) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let err): completion(.failure(err))
                case .success(let dict):
                    let page = dict["members"] as? [[String: Any]] ?? []
                    collected.append(contentsOf: page)
                    let nextCursor = (dict["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
                    if !nextCursor.isEmpty {
                        fetch(cursor: nextCursor)
                    } else {
                        self.usersCache = (Date(), collected)
                        completion(.success(collected))
                    }
                }
            }
        }
        fetch(cursor: nil)
    }

    private func authedUserId(completion: @escaping (Result<String, SlackError>) -> Void) {
        if let cached = authedUserIdCache { completion(.success(cached)); return }
        slackPOST(method: "auth.test", body: [:]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success(let dict):
                guard let userId = dict["user_id"] as? String, !userId.isEmpty else {
                    completion(.failure(.slackError("auth.test missing user_id"))); return
                }
                self.authedUserIdCache = userId
                completion(.success(userId))
            }
        }
    }

    /// Render a human label for the confirmation alert ("#general", "DM with
    /// Tanay", or just the raw id if we can't resolve it cheaply).
    private func resolveChannelLabel(channel: String,
                                     completion: @escaping (String) -> Void) {
        let body: [String: Any] = ["channel": channel]
        slackPOST(method: "conversations.info", body: body) { result in
            switch result {
            case .failure:
                completion(channel)
            case .success(let dict):
                guard let info = dict["channel"] as? [String: Any] else {
                    completion(channel); return
                }
                if info["is_im"] as? Bool == true {
                    if let user = info["user"] as? String {
                        completion("DM with \(user)")
                    } else {
                        completion("Direct message")
                    }
                } else if let name = info["name"] as? String, !name.isEmpty {
                    completion("#\(name)")
                } else {
                    completion(channel)
                }
            }
        }
    }

    // MARK: - Network

    private enum SlackError: Error {
        case notConnected
        case transport
        case malformedResponse
        case slackError(String)
    }

    private func slackPOST(method: String,
                           body: [String: Any],
                           completion: @escaping (Result<[String: Any], SlackError>) -> Void) {
        guard let token = KeyStore.shared.value(for: .slackUserToken),
              !token.isEmpty else {
            completion(.failure(.notConnected)); return
        }
        guard let url = URL(string: "https://slack.com/api/\(method)") else {
            completion(.failure(.transport)); return
        }
        // Request.postRequest already sets Content-Type: application/json
        // (which Slack accepts as UTF-8 by default), so we only add the
        // Bearer header here — addValue would duplicate Content-Type.
        let headers: [String: String] = [
            "Authorization": "Bearer \(token)"
        ]
        Request.shared.postRequest(data: body, to: url, headers: headers) { response, error in
            if error != nil {
                DispatchQueue.main.async { completion(.failure(.transport)) }
                return
            }
            guard let dict = response as? [String: Any] else {
                DispatchQueue.main.async { completion(.failure(.malformedResponse)) }
                return
            }
            if (dict["ok"] as? Bool) == true {
                DispatchQueue.main.async { completion(.success(dict)) }
            } else {
                let reason = (dict["error"] as? String) ?? "unknown_slack_error"
                DispatchQueue.main.async { completion(.failure(.slackError(reason))) }
            }
        }
    }

    // MARK: - Response helpers

    /// Trim a Slack message dict down to the fields the model actually needs,
    /// so we don't blow context with avatar urls, edited blobs, etc.
    private static func trimMessage(_ m: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [
            "user": m["user"] as? String ?? "",
            "username": m["username"] as? String ?? "",
            "text": m["text"] as? String ?? "",
            "ts": m["ts"] as? String ?? ""
        ]
        if let thread = m["thread_ts"] as? String { out["thread_ts"] = thread }
        if let reply = m["reply_count"] as? Int { out["reply_count"] = reply }
        if let subtype = m["subtype"] as? String { out["subtype"] = subtype }
        return out
    }

    private static func channelName(from c: [String: Any]) -> String {
        if let name = c["name"] as? String, !name.isEmpty { return name }
        if (c["is_im"] as? Bool) == true {
            if let user = c["user"] as? String { return "DM with \(user)" }
            return "DM"
        }
        return c["id"] as? String ?? ""
    }

    private static func channelType(from c: [String: Any]) -> String {
        if (c["is_im"] as? Bool) == true { return "im" }
        if (c["is_mpim"] as? Bool) == true { return "mpim" }
        if (c["is_private"] as? Bool) == true { return "private_channel" }
        return "public_channel"
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    // MARK: - Message construction

    private func errorMessage(for tool: String, error: SlackError) -> MessageStruct {
        let payload: [String: Any]
        switch error {
        case .notConnected:
            payload = [
                "error": "slack_not_connected",
                "hint": "Ask the user to paste their xoxp- user token in Settings → Keys → Slack User Token."
            ]
        case .transport:
            payload = ["error": "slack_transport_failed",
                       "hint": "Network error talking to slack.com. Suggest retrying."]
        case .malformedResponse:
            payload = ["error": "slack_malformed_response"]
        case .slackError(let reason):
            payload = [
                "error": reason,
                "hint": Self.recoveryHint(for: reason)
            ]
        }
        return Self.functionMessage(name: tool, payload: payload)
    }

    /// Map Slack's canonical error strings to a one-line nudge so the model
    /// has something concrete to relay back to the user.
    private static func recoveryHint(for slackError: String) -> String {
        switch slackError {
        case "invalid_auth", "not_authed", "token_revoked", "token_expired":
            return "The Slack token is invalid or revoked. Ask the user to mint a fresh xoxp- token and paste it in Settings → Keys → Slack User Token."
        case "missing_scope":
            return "The token is missing a required scope. See Specs/3. Integrations Spec.md for the full scope list."
        case "channel_not_found":
            return "Couldn't find that channel id. Call list_slack_channels to refresh ids."
        case "user_not_found":
            return "Couldn't find that user id. Call find_slack_user to resolve a name first."
        case "ratelimited":
            return "Slack rate-limited the call. Wait a moment and retry, or batch fewer requests."
        default:
            return "See https://api.slack.com/methods for this error code."
        }
    }

    private func missingArgs(for name: String, expected: String) -> MessageStruct {
        return MessageStruct(
            role: "assistant",
            content: "I need \(expected) to call \(name). Please provide them."
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
