//
//  URLFetchSkill.swift
//  Loop
//
//  Built from intel/Specs/Saturday Spec C - Agent Infra.md (Task 7).
//
//  A key-free counterpart to ExaSkill.exa_get_contents. Exa's reader is gated
//  behind EXA_API_KEY; this skill just hits the URL directly with URLSession,
//  strips HTML down to readable text, and hands back a capped excerpt. Use it
//  when the user gives you a specific URL and you only need its contents — no
//  search, no API key required.
//
//  Implemented locally on-device (no backend dependency), same shape as every
//  other bundled skill: singleton, prompt fragment, tool schema, dispatch.
//

import Foundation

struct URLFetchSkill {
    static let shared = URLFetchSkill()

    /// Hard cap on the readable text we return. Keeps a giant page from
    /// blowing up the chat context — the model can ask the user to narrow
    /// down if it needs more than this.
    private static let maxOutputChars = 12_000

    /// Cap on raw bytes we'll even download before giving up. Avoids pulling
    /// a multi-megabyte asset into memory just to discard it.
    private static let maxDownloadBytes = 5_000_000

    static let systemPromptFragment: String = """
You can fetch the contents of a single web page directly with this tool:
- fetch_url: pass one `url`. Returns the page's readable text (HTML stripped
  to plain text), capped to a sane length. No API key required.

When to use it:
- The user hands you a specific link and asks what's on it / to summarize it.
- You already have a URL (from exa_search, a message, a file) and just need
  its text — fetch_url is the key-free path; prefer it over exa_get_contents
  unless you need Exa's cleaning specifically.

Notes:
- One URL per call. The result is truncated — if you need more, say so rather
  than calling repeatedly.
- Cite the URL you fetched in your reply.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "fetch_url",
                "description": "Fetch a single web page and return its readable text (HTML stripped to plain text), capped to a sane length. No API key required — use for a URL the user gave you.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "url": [
                            "type": "string",
                            "description": "The absolute URL to fetch (http or https)."
                        ]
                    ],
                    "required": ["url"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["fetch_url"]

    func handles(functionName: String) -> Bool {
        return URLFetchSkill.toolNames.contains(functionName)
    }

    /// Human-readable status string for the shimmer label while the fetch
    /// runs. Returns nil when this skill doesn't own the call.
    func statusText(for call: FunctionCallStruct) -> String? {
        guard call.name == "fetch_url" else { return nil }
        if let raw = call.arguments["url"] as? String,
           let host = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?.host {
            return "fetching \(host)"
        }
        return "fetching page"
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        guard functionCall.name == "fetch_url" else {
            completion(MessageStruct(
                role: "function",
                content: "{\"status\":\"error\",\"error\":\"Unknown tool \(functionCall.name)\"}",
                name: functionCall.name
            ))
            return
        }

        let raw = (functionCall.arguments["url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            completion(Self.functionResult(name: "fetch_url",
                                           body: "I need a `url` to fetch."))
            return
        }
        // Tolerate a bare host with no scheme by defaulting to https.
        let normalized = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            completion(Self.functionResult(name: "fetch_url",
                                           body: "'\(raw)' is not a valid http/https URL."))
            return
        }

        fetch(url: url, completion: completion)
    }

    // MARK: - Fetch

    private func fetch(url: URL,
                       completion: @escaping (MessageStruct) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        // Some sites 403 the default URLSession agent. A common browser UA
        // gets us the same HTML a user would see.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(Self.functionResult(
                    name: "fetch_url",
                    body: "Couldn't fetch \(url.absoluteString): \(error.localizedDescription)"))
                return
            }
            guard let data = data else {
                completion(Self.functionResult(
                    name: "fetch_url",
                    body: "No data returned from \(url.absoluteString)."))
                return
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status >= 400 {
                completion(Self.functionResult(
                    name: "fetch_url",
                    body: "\(url.absoluteString) returned HTTP \(status)."))
                return
            }
            if data.count > Self.maxDownloadBytes {
                completion(Self.functionResult(
                    name: "fetch_url",
                    body: "\(url.absoluteString) is \(data.count) bytes — too large to read inline."))
                return
            }

            let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            // Binary content we can't usefully turn into text.
            if Self.looksBinary(contentType: contentType) {
                completion(Self.functionResult(
                    name: "fetch_url",
                    body: "\(url.absoluteString) is a \(contentType.isEmpty ? "binary" : contentType) resource — not readable as text."))
                return
            }

            let body = Self.decode(data: data, contentType: contentType)
            let isHTML = contentType.contains("html")
                || body.range(of: "<html", options: .caseInsensitive) != nil
                || body.range(of: "<!doctype html", options: .caseInsensitive) != nil
            let extracted = isHTML ? Self.htmlToText(body) : body
            let title = isHTML ? Self.extractTitle(body) : nil

            let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                completion(Self.functionResult(
                    name: "fetch_url",
                    body: "Fetched \(url.absoluteString) but it had no readable text."))
                return
            }

            let (clamped, truncated) = Self.clamp(trimmed, to: Self.maxOutputChars)
            var out = "URL: \(url.absoluteString)"
            if let title = title, !title.isEmpty { out += "\nTitle: \(title)" }
            out += "\n---\n\(clamped)"
            if truncated { out += "\n\n[...truncated at \(Self.maxOutputChars) chars...]" }

            completion(Self.functionResult(name: "fetch_url", body: out))
        }.resume()
    }

    // MARK: - Decoding / HTML stripping

    /// Best-effort text decode. Honors a charset in the Content-Type header
    /// when present, otherwise tries UTF-8 then Latin-1 (which never fails,
    /// so we always get *something* back).
    private static func decode(data: Data, contentType: String) -> String {
        if let range = contentType.range(of: "charset="),
           let enc = String(contentType[range.upperBound...])
               .split(separator: ";").first?
               .trimmingCharacters(in: .whitespaces).lowercased() as String?,
           enc == "utf-8" || enc == "utf8" {
            if let s = String(data: data, encoding: .utf8) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    private static func looksBinary(contentType: String) -> Bool {
        let binaryHints = ["image/", "video/", "audio/", "application/pdf",
                           "application/octet-stream", "application/zip",
                           "font/"]
        return binaryHints.contains { contentType.contains($0) }
    }

    private static func extractTitle(_ html: String) -> String? {
        guard let r = html.range(of: "<title[^>]*>(.*?)</title>",
                                 options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let tag = String(html[r])
        let inner = tag.replacingOccurrences(
            of: "</?title[^>]*>", with: "",
            options: [.regularExpression, .caseInsensitive])
        return decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip HTML to readable plain text. Not a full parser — drops
    /// script/style/comments, converts block-level closers to newlines so
    /// paragraphs survive, removes the rest of the tags, decodes entities,
    /// and collapses whitespace.
    static func htmlToText(_ html: String) -> String {
        var s = html

        func stripRegex(_ pattern: String) {
            s = s.replacingOccurrences(
                of: pattern, with: " ",
                options: [.regularExpression, .caseInsensitive])
        }

        stripRegex("<!--.*?-->")
        stripRegex("<script[^>]*>.*?</script>")
        stripRegex("<style[^>]*>.*?</style>")
        stripRegex("<head[^>]*>.*?</head>")
        stripRegex("<noscript[^>]*>.*?</noscript>")

        // Turn block boundaries into newlines so the text doesn't run together.
        s = s.replacingOccurrences(
            of: "</(p|div|li|tr|h[1-6]|section|article|header|footer|ul|ol|table|blockquote)>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(
            of: "<br[^>]*>", with: "\n",
            options: [.regularExpression, .caseInsensitive])

        // Remaining tags → gone.
        s = s.replacingOccurrences(
            of: "<[^>]+>", with: "",
            options: [.regularExpression])

        s = decodeEntities(s)

        // Collapse horizontal whitespace, then squeeze blank-line runs.
        s = s.replacingOccurrences(
            of: "[ \\t\\x{00A0}]+", with: " ",
            options: [.regularExpression])
        s = s.replacingOccurrences(
            of: "\\n[ \\t]*\\n[ \\t\\n]*", with: "\n\n",
            options: [.regularExpression])

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode the handful of named entities that actually show up in body
    /// text, plus numeric (decimal + hex) entities.
    private static func decodeEntities(_ input: String) -> String {
        var s = input
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—",
            "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
            "&ldquo;": "“", "&rdquo;": "”", "&copy;": "©", "&reg;": "®",
            "&trade;": "™", "&deg;": "°", "&eacute;": "é"
        ]
        for (k, v) in named {
            s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive)
        }

        // Numeric: &#NNN; and &#xHH;
        guard s.contains("&#") else { return s }
        let pattern = "&#(x?[0-9A-Fa-f]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let token = ns.substring(with: m.range(at: 1))
            let scalarValue: UInt32?
            if token.lowercased().hasPrefix("x") {
                scalarValue = UInt32(token.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(token)
            }
            if let v = scalarValue, let scalar = Unicode.Scalar(v) {
                result += String(scalar)
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func clamp(_ s: String, to max: Int) -> (String, Bool) {
        if s.count <= max { return (s, false) }
        let idx = s.index(s.startIndex, offsetBy: max)
        return (String(s[..<idx]), true)
    }

    private static func functionResult(name: String, body: String) -> MessageStruct {
        return MessageStruct(role: "function", content: body, name: name)
    }
}
