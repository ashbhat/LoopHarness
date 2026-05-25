//
//  MacAppSkill.swift
//  LoopMac
//
//  Lets the agent open URLs and launch Mac apps. The user story:
//    1) Agent creates a Notion doc — function returns a notion.so URL
//    2) User says "open it"
//    3) Agent calls open_url(url) → NSWorkspace launches Notion / browser
//
//  Same skill handles `open_mac_app("Ghostty")` for arbitrary installed apps,
//  resolved via NSWorkspace + LaunchServices. Mac-only — not registered on
//  iOS, where there's no general "open another app" affordance.
//

import AppKit
import Foundation

struct MacAppSkill {
    static let shared = MacAppSkill()

    /// System-prompt fragment. Wired into the harness via register() below.
    static let systemPromptFragment: String = """
You can drive the user's Mac through this set of tools (Mac only):
- open_url: open a URL (notion.so links, https links, file://, mailto:, etc.). Use this right after creating a Notion page or whenever the user asks you to "open" something you just produced a link to.
- open_mac_app: launch any app installed on the Mac by name (e.g. "Ghostty", "Terminal", "Safari", "Notion"). Case-insensitive; matches partial names.
- list_installed_mac_apps: list every .app bundle the user has installed. Use sparingly — only when the user asks what's available, or after a failed open_mac_app to figure out the right name.

Workflow tips:
- Whenever the user asks you to "open" something that has a URL (Notion page just created, Notion page found via find_notion_page, an Exa result, a file://, an https link in your last reply), call open_url with that URL directly. Do NOT tell the user to tap the link — call the tool. open_url IS connected and available right now in this environment.
- When you create or find a Notion page, surface the link AND, if the user shows any intent to open it, call open_url immediately.
- For app launches ("open my terminal", "launch Ghostty"), call open_mac_app. Prefer Ghostty if installed; fall back to Terminal.
- Don't say "I can't open it" or "tap the link" — those are wrong. You have open_url and open_mac_app right now.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "open_url",
                "description": "Open a URL on the user's Mac. The system routes the URL to the appropriate app (Notion app for notion.so links if installed, browser for https, Mail for mailto, etc.). Use this to open links you just produced — Notion pages, Exa results, anything web.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "url": [
                            "type": "string",
                            "description": "The full URL to open (e.g. https://www.notion.so/abc123, file:///Users/me/file.pdf, mailto:foo@bar.com)."
                        ]
                    ],
                    "required": ["url"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "open_mac_app",
                "description": "Launch a Mac app by name. Matches case-insensitively against the bundle display name; partial matches accepted (\"chrome\" → Google Chrome). Returns success or a list of close matches if no exact match.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "The app's display name as it appears in /Applications (e.g. \"Ghostty\", \"Terminal\", \"Notion\", \"Safari\")."
                        ]
                    ],
                    "required": ["name"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_installed_mac_apps",
                "description": "List every .app bundle installed on the user's Mac (across /Applications, ~/Applications, and /System/Applications). Use only when the user asks what's available, or after open_mac_app failed.",
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        ]
    ]

    private static let toolNames: Set<String> = [
        "open_url", "open_mac_app", "list_installed_mac_apps"
    ]

    func handles(functionName: String) -> Bool {
        return MacAppSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "open_url":
            if let u = call.arguments["url"] as? String, let host = URL(string: u)?.host {
                return "opening \(host)"
            }
            return "opening URL"
        case "open_mac_app":
            if let name = call.arguments["name"] as? String, !name.isEmpty {
                return "opening \(name)"
            }
            return "opening Mac app"
        case "list_installed_mac_apps":
            return "listing installed apps"
        default:
            return nil
        }
    }

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "open_url":
            handleOpenURL(args: functionCall.arguments, completion: completion)
        case "open_mac_app":
            handleOpenApp(args: functionCall.arguments, completion: completion)
        case "list_installed_mac_apps":
            handleListApps(completion: completion)
        default:
            completion(MessageStruct(role: "function",
                                     content: "Unknown function \(functionCall.name)",
                                     name: functionCall.name))
        }
    }

    // MARK: - open_url

    private func handleOpenURL(args: [String: Any],
                               completion: @escaping (MessageStruct) -> Void) {
        guard let raw = args["url"] as? String, !raw.isEmpty,
              let url = URL(string: raw) else {
            completion(MessageStruct(role: "function",
                                     content: "Missing or invalid 'url' argument.",
                                     name: "open_url"))
            return
        }
        DispatchQueue.main.async {
            let opened = NSWorkspace.shared.open(url)
            let result = opened
                ? "Opened \(raw)"
                : "Could not open \(raw) — no app on this Mac handles that URL scheme."
            completion(MessageStruct(role: "function", content: result, name: "open_url"))
        }
    }

    // MARK: - open_mac_app

    private func handleOpenApp(args: [String: Any],
                               completion: @escaping (MessageStruct) -> Void) {
        guard let rawName = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            completion(MessageStruct(role: "function",
                                     content: "Missing 'name' argument.",
                                     name: "open_mac_app"))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let apps = MacAppSkill.discoverInstalledApps()
            let needle = rawName.lowercased()

            // Exact (case-insensitive) match wins.
            if let exact = apps.first(where: { $0.name.lowercased() == needle }) {
                self.launch(at: exact.url, displayName: exact.name, completion: completion)
                return
            }
            // Otherwise prefix > contains > fuzzy.
            if let prefix = apps.first(where: { $0.name.lowercased().hasPrefix(needle) }) {
                self.launch(at: prefix.url, displayName: prefix.name, completion: completion)
                return
            }
            let contains = apps.filter { $0.name.lowercased().contains(needle) }
            if let single = contains.first, contains.count == 1 {
                self.launch(at: single.url, displayName: single.name, completion: completion)
                return
            }
            // Ambiguous or no match — return suggestions so the model can ask
            // the user to disambiguate.
            let suggestions = contains.map(\.name).prefix(8).joined(separator: ", ")
            let message: String
            if contains.isEmpty {
                message = "No app found matching '\(rawName)'. Try list_installed_mac_apps to see what's available."
            } else {
                message = "Multiple apps match '\(rawName)': \(suggestions). Ask the user which one or call open_mac_app with the exact name."
            }
            DispatchQueue.main.async {
                completion(MessageStruct(role: "function", content: message, name: "open_mac_app"))
            }
        }
    }

    private func launch(at url: URL,
                        displayName: String,
                        completion: @escaping (MessageStruct) -> Void) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            DispatchQueue.main.async {
                let content: String
                if let error = error {
                    content = "Failed to launch \(displayName): \(error.localizedDescription)"
                } else {
                    content = "Launched \(displayName)."
                }
                completion(MessageStruct(role: "function", content: content, name: "open_mac_app"))
            }
        }
    }

    // MARK: - list_installed_mac_apps

    private func handleListApps(completion: @escaping (MessageStruct) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = MacAppSkill.discoverInstalledApps()
            // Drop sandbox helpers and frameworks the user wouldn't recognize.
            let names = apps.map(\.name).sorted { $0.lowercased() < $1.lowercased() }
            let content = names.isEmpty
                ? "No apps found."
                : "Installed apps:\n" + names.joined(separator: "\n")
            DispatchQueue.main.async {
                completion(MessageStruct(role: "function", content: content, name: "list_installed_mac_apps"))
            }
        }
    }

    // MARK: - Discovery
    //
    // Spotlight-backed enumeration. The previous implementation walked
    // /Applications, ~/Applications, /System/Applications directly, which
    // the App Sandbox forbids. NSMetadataQuery runs against the metadata
    // daemon out-of-process, so sandboxed apps can still see every .app
    // bundle on the volume; we then hand the URLs off to LaunchServices
    // (NSWorkspace.openApplication), which sandboxed apps are allowed to
    // call.

    private struct DiscoveredApp {
        let name: String
        let url: URL
    }

    private static func discoverInstalledApps() -> [DiscoveredApp] {
        let sem = DispatchSemaphore(value: 0)
        var results: [DiscoveredApp] = []

        // NSMetadataQuery requires a run loop; bounce to main, kick off
        // the query, and signal back when gathering finishes.
        DispatchQueue.main.async {
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryLocalComputerScope]
            query.predicate = NSPredicate(
                format: "kMDItemContentTypeTree == 'com.apple.application-bundle'"
            )

            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { _ in
                query.disableUpdates()
                query.stop()
                var seen = Set<String>()
                for i in 0..<query.resultCount {
                    guard let item = query.result(at: i) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
                    else { continue }
                    let url = URL(fileURLWithPath: path)
                    let name = url.deletingPathExtension().lastPathComponent
                    if seen.insert(name).inserted {
                        results.append(DiscoveredApp(name: name, url: url))
                    }
                }
                if let observer = observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                sem.signal()
            }
            query.start()
        }

        // Bounded wait — if Spotlight is rebuilding its index this can be
        // slow; 8s is enough on a healthy machine and prevents the tool
        // from hanging the agent loop.
        _ = sem.wait(timeout: .now() + 8.0)
        return results
    }
}
