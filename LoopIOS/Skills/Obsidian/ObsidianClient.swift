//
//  ObsidianClient.swift
//  Loop
//
//  HTTP client for the bearer-auth Obsidian relay (Flask app on the user's
//  Mac, exposed via ngrok). Talks to it directly — does not go through the
//  Cloud backend, so the iPhone hits the relay over public TLS without any
//  app-server hop.
//
//  Reads `OBSIDIAN_BASE_URL` and `OBSIDIAN_API_KEY` from Info.plist (both
//  present on iOS and macOS targets).
//

import Foundation

/// Thin wrapper around the relay's REST API. Each method shapes a request,
/// awaits a JSON response, and surfaces either the parsed payload or an
/// `Error` carrying the relay's `error`/`detail` fields.
struct ObsidianClient {
    static let shared = ObsidianClient()

    // MARK: - Config

    private static var baseURL: String? {
        guard let raw = KeyStore.shared.value(for: .obsidianBaseURL) else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    private static var apiKey: String? {
        return KeyStore.shared.value(for: .obsidianAPI)
    }

    static var isConfigured: Bool {
        return baseURL != nil && apiKey != nil
    }

    // MARK: - High-level convenience (the MVP user-story endpoint)

    /// Creates `<today's day folder>/<title>.md`. The relay computes today's
    /// path server-side from the same convention `ObsidianDateHelpers` mirrors.
    func createTodayNote(title: String,
                         content: String,
                         completion: @escaping ([String: Any]?, Error?) -> Void) {
        post(path: "/today/note",
             body: ["title": title, "content": content],
             completion: completion)
    }

    func today(completion: @escaping ([String: Any]?, Error?) -> Void) {
        get(path: "/today", query: nil, completion: completion)
    }

    // MARK: - Notes (A–F from the spec)

    func createNote(path: String,
                    content: String,
                    completion: @escaping ([String: Any]?, Error?) -> Void) {
        post(path: "/notes",
             body: ["path": path, "content": content],
             completion: completion)
    }

    func readNote(path: String,
                  completion: @escaping ([String: Any]?, Error?) -> Void) {
        get(path: "/notes", query: ["path": path], completion: completion)
    }

    func updateNote(path: String,
                    content: String,
                    mode: String?,
                    completion: @escaping ([String: Any]?, Error?) -> Void) {
        var body: [String: Any] = ["path": path, "content": content]
        if let mode = mode { body["mode"] = mode }
        request(method: "PUT", path: "/notes", body: body,
                query: nil, completion: completion)
    }

    func deleteNote(path: String,
                    completion: @escaping ([String: Any]?, Error?) -> Void) {
        request(method: "DELETE", path: "/notes",
                body: ["path": path], query: nil, completion: completion)
    }

    func moveNote(from src: String,
                  to dst: String,
                  completion: @escaping ([String: Any]?, Error?) -> Void) {
        post(path: "/notes/move",
             body: ["from": src, "to": dst],
             completion: completion)
    }

    func findNotes(query: String,
                   contextLength: Int?,
                   completion: @escaping ([String: Any]?, Error?) -> Void) {
        var body: [String: Any] = ["query": query]
        if let n = contextLength { body["context_length"] = n }
        post(path: "/notes/find", body: body, completion: completion)
    }

    // MARK: - Folders (G–M from the spec)

    func listFolder(path: String,
                    completion: @escaping ([String: Any]?, Error?) -> Void) {
        get(path: "/folders", query: ["path": path], completion: completion)
    }

    func createFolder(path: String,
                      completion: @escaping ([String: Any]?, Error?) -> Void) {
        post(path: "/folders", body: ["path": path], completion: completion)
    }

    func deleteFolder(path: String,
                      recursive: Bool,
                      completion: @escaping ([String: Any]?, Error?) -> Void) {
        request(method: "DELETE", path: "/folders",
                body: ["path": path, "recursive": recursive],
                query: nil, completion: completion)
    }

    func moveFolder(from src: String,
                    to dst: String,
                    completion: @escaping ([String: Any]?, Error?) -> Void) {
        post(path: "/folders/move",
             body: ["from": src, "to": dst],
             completion: completion)
    }

    func findFolders(query: String,
                     root: String?,
                     maxDepth: Int?,
                     completion: @escaping ([String: Any]?, Error?) -> Void) {
        var body: [String: Any] = ["query": query]
        if let root = root { body["root"] = root }
        if let n = maxDepth { body["max_depth"] = n }
        post(path: "/folders/find", body: body, completion: completion)
    }

    func layout(root: String?,
                maxDepth: Int?,
                completion: @escaping ([String: Any]?, Error?) -> Void) {
        var query: [String: String] = [:]
        if let root = root { query["root"] = root }
        if let n = maxDepth { query["max_depth"] = String(n) }
        get(path: "/layout", query: query.isEmpty ? nil : query, completion: completion)
    }

    // MARK: - HTTP

    private func get(path: String,
                     query: [String: String]?,
                     completion: @escaping ([String: Any]?, Error?) -> Void) {
        request(method: "GET", path: path, body: nil, query: query, completion: completion)
    }

    private func post(path: String,
                      body: [String: Any],
                      completion: @escaping ([String: Any]?, Error?) -> Void) {
        request(method: "POST", path: path, body: body, query: nil, completion: completion)
    }

    private func request(method: String,
                         path: String,
                         body: [String: Any]?,
                         query: [String: String]?,
                         completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard let base = ObsidianClient.baseURL,
              let key = ObsidianClient.apiKey else {
            completion(nil, NSError(domain: "ObsidianClient", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Obsidian relay isn't configured."]))
            return
        }
        guard var components = URLComponents(string: base + path) else {
            completion(nil, NSError(domain: "ObsidianClient", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "Bad Obsidian URL"]))
            return
        }
        if let query = query, !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            completion(nil, NSError(domain: "ObsidianClient", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "Bad Obsidian URL"]))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 25
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        }

        URLSession.shared.dataTask(with: req) { data, response, error in
            ObsidianClient.parse(data: data,
                                 response: response,
                                 error: error,
                                 completion: completion)
        }.resume()
    }

    private static func parse(data: Data?,
                              response: URLResponse?,
                              error: Error?,
                              completion: @escaping ([String: Any]?, Error?) -> Void) {
        if let error = error {
            DispatchQueue.main.async { completion(nil, error) }
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let data = data else {
            DispatchQueue.main.async {
                completion(nil, NSError(domain: "ObsidianClient", code: status,
                                        userInfo: [NSLocalizedDescriptionKey: "Empty response (status \(status))"]))
            }
            return
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status >= 400 {
            let code = (json?["error"] as? String) ?? "http_\(status)"
            let detail = (json?["detail"] as? String)
                ?? (json?["error"] as? String)
                ?? (String(data: data.prefix(200), encoding: .utf8) ?? "request failed")
            DispatchQueue.main.async {
                completion(nil, NSError(domain: "ObsidianClient", code: status,
                                        userInfo: [NSLocalizedDescriptionKey: "\(code): \(detail)"]))
            }
            return
        }
        DispatchQueue.main.async { completion(json ?? [:], nil) }
    }
}
