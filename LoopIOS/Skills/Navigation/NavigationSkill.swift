//
//  NavigationSkill.swift
//  Loop
//
//  Lets the model open Loop's own panels by name — "show me the files",
//  "open settings", "let me see my scheduled tasks" — instead of describing
//  where to tap. Mirrors IntegrationSkill's pattern: the skill itself never
//  imports UIKit/AppKit; it posts a notification and the platform host
//  (MessagingVC on iOS, AppDelegate on Mac) routes to the right surface.
//

import Foundation

/// Posted by NavigationSkill when the model invokes `open_panel`. The
/// platform host listens and decides how to present the requested panel.
///
/// `userInfo` keys:
/// - `"panel"`: stable panel ID (see NavigationSkill.systemPromptFragment for
///   the catalog). Hosts ignore IDs they don't have a surface for.
/// - `"tab"`: optional sub-selector. For side-drawer panels this picks the
///   initial tab (`conversations` / `files` / `skills`).
extension Notification.Name {
    static let navigationSkillOpenPanel =
        Notification.Name("loop.navigation.openPanelRequested")
}

final class NavigationSkill {

    static let shared = NavigationSkill()
    private init() {}

    // MARK: - System prompt

    static let systemPromptFragment: String = """
You can open Loop's own panels for the user with `open_panel`. Use this when the user says things like "show me my files", "open settings", "let me see my skills", "take me to integrations". Don't describe where to tap — call the tool.

Panel IDs you can pass:
- workspace / files: the workspace file browser (iOS: opens the side drawer on the Files tab).
- skills: the list of available skills (iOS: side drawer, Skills tab).
- conversations: the conversation history list (iOS: side drawer, Conversations tab).
- settings: the root Settings screen.
- integrations: Settings → Integrations.
- keys: Settings → API Keys.
- subagents: Settings → Subagents (history of native + cloud agent runs).
- scheduled: Settings → Scheduled Tasks.
- model: Settings → Model picker (iOS only).
- microphone: the microphone settings panel (Mac only).
- agent: the immersive Agent view (iOS only — large orb / voice state).

Tips:
- Just call open_panel; don't narrate "I'll open settings now" before calling.
- If the user asks for something you don't have a panel for, say so — don't pick an unrelated panel.
"""

    // MARK: - Tool catalog

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "open_panel",
                "description": "Open a specific Loop panel/screen by name. Use when the user asks to see workspace files, skills, conversations, settings (or a sub-page like integrations / keys / subagents / scheduled / model), the microphone panel (Mac), or the immersive agent view (iOS).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "panel": [
                            "type": "string",
                            "description": "Panel identifier. One of: workspace, files, skills, conversations, settings, integrations, keys, subagents, scheduled, model, microphone, agent."
                        ],
                        "tab": [
                            "type": "string",
                            "description": "Optional sub-selector. For side-drawer panels: conversations | files | skills. Ignored for other panels."
                        ]
                    ],
                    "required": ["panel"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["open_panel"]

    func handles(functionName: String) -> Bool {
        return Self.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        guard call.name == "open_panel" else { return nil }
        if let p = call.arguments["panel"] as? String, !p.isEmpty {
            return "opening \(prettyName(for: p))"
        }
        return "opening panel"
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let name = functionCall.name
        let args = functionCall.arguments

        switch name {
        case "open_panel":
            guard let raw = args["panel"] as? String, !raw.isEmpty else {
                completion(Self.functionMessage(name: name, payload: [
                    "error": "missing_panel",
                    "hint": "Pass a panel id. Known: \(Self.knownPanels.sorted().joined(separator: ", "))."
                ]))
                return
            }
            let canonical = Self.canonicalPanel(from: raw)
            guard Self.knownPanels.contains(canonical) else {
                completion(Self.functionMessage(name: name, payload: [
                    "error": "unknown_panel",
                    "panel": raw,
                    "hint": "Known panels: \(Self.knownPanels.sorted().joined(separator: ", "))."
                ]))
                return
            }
            let tab = (args["tab"] as? String).flatMap(Self.canonicalTab(from:))

            var userInfo: [String: Any] = ["panel": canonical]
            if let tab = tab { userInfo["tab"] = tab }

            // Bounce to main — observers will touch UIKit / AppKit.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .navigationSkillOpenPanel,
                    object: nil,
                    userInfo: userInfo
                )
            }

            var payload: [String: Any] = ["ok": true, "panel": canonical]
            if let tab = tab { payload["tab"] = tab }
            completion(Self.functionMessage(name: name, payload: payload))

        default:
            completion(MessageStruct(role: "assistant",
                                     content: "I don't know how to handle the navigation tool '\(name)'."))
        }
    }

    // MARK: - Catalog

    /// Stable set of panel IDs the skill advertises. Hosts may quietly map a
    /// few of these to no-ops (e.g. Mac has no immersive `agent` view), but
    /// the dispatch side never lies about what was requested.
    static let knownPanels: Set<String> = [
        "workspace", "files", "skills", "conversations",
        "settings", "integrations", "keys", "subagents",
        "scheduled", "model", "microphone", "agent"
    ]

    /// Fold a few user/model-friendly synonyms into the canonical IDs the
    /// hosts switch on. Comparison is case- and whitespace-insensitive.
    private static func canonicalPanel(from raw: String) -> String {
        let n = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch n {
        case "workspace", "file", "files":                 return "files"
        case "skill", "skills":                            return "skills"
        case "conversation", "conversations", "history":  return "conversations"
        case "setting", "settings":                        return "settings"
        case "integration", "integrations":                return "integrations"
        case "key", "keys", "api_keys", "api keys":        return "keys"
        case "subagent", "subagents", "agents":            return "subagents"
        case "scheduled", "schedule", "scheduled_tasks",
             "scheduled tasks":                            return "scheduled"
        case "model", "model_picker", "models":            return "model"
        case "microphone", "mic":                          return "microphone"
        case "agent", "avatar", "orb":                     return "agent"
        default:                                           return n
        }
    }

    private static func canonicalTab(from raw: String) -> String? {
        let n = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch n {
        case "conversation", "conversations", "history": return "conversations"
        case "file", "files", "workspace":               return "files"
        case "skill", "skills":                          return "skills"
        default:                                         return nil
        }
    }

    private func prettyName(for panel: String) -> String {
        switch Self.canonicalPanel(from: panel) {
        case "files":         return "the workspace"
        case "skills":        return "skills"
        case "conversations": return "conversation history"
        case "settings":      return "settings"
        case "integrations":  return "integrations"
        case "keys":          return "API keys"
        case "subagents":     return "subagents"
        case "scheduled":     return "scheduled tasks"
        case "model":         return "the model picker"
        case "microphone":    return "microphone settings"
        case "agent":         return "the agent view"
        default:              return panel
        }
    }

    // MARK: - Helpers

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
