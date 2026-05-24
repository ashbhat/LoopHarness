//
//  DynamicSkillRegistry.swift
//  Loop
//
//  Built from LoopIOS/Specs/2. Loop Local Runtime Spec.md.
//
//  Loads user-authored skills from Workspace/Skills/<name>/ and exposes them
//  to the agent harness as ordinary OpenAI-style tools. Each skill folder
//  contains:
//
//      skill.json   — { name, description, parameters: { type, properties, required } }
//      skill.js     — top-level `async function run(args, host) { ... }`
//
//  The registry mirrors the shape of the bundled Skills (NotionSkill, CronSkill,
//  etc.) — `handles(functionName:)`, `statusText(for:)`, `handle(functionCall:,
//  completion:)` — so MessagingVC can route to it the same way. Hot-reload is
//  cheap: at every chat turn the registry stats every skill folder; mtime
//  changes pull the file back into memory and bump the schema.
//

import Foundation

final class DynamicSkillRegistry {

    static let shared = DynamicSkillRegistry()

    /// A skill the registry knows how to invoke. `source` is the raw JS;
    /// `manifest` is the parsed skill.json. We hold onto the manifest dict
    /// verbatim so we can echo it back to MessagingVC for status text and
    /// re-emit the parameters block into the harness's tool schemas.
    struct LoadedSkill {
        let name: String
        let description: String
        let parameters: [String: Any]
        let source: String
        let folder: URL
        let manifestMTime: Date?
        let scriptMTime: Date?
    }

    /// Folder name inside the workspace root that holds every skill.
    static let skillsFolderName = "Skills"

    private(set) var skills: [String: LoadedSkill] = [:]

    /// Callback fired whenever a skill streams `host.log(...)` while running.
    /// Wired from MessagingVC so the shimmer label can reflect live progress.
    var logHandler: ((_ skillName: String, _ message: String) -> Void)?

    /// Callback fired whenever the registry reloads — adds, removes, or
    /// updates a skill. The harness uses this to refresh `toolSchemas` and
    /// the TOOLS.md fragment so the model immediately sees new tools.
    var didReload: (() -> Void)?

    private let runtime = JSRuntime()
    private let fm = FileManager.default

    private init() {}

    // MARK: - Discovery

    /// Root folder for user-authored skills. Created on first access so the
    /// rest of the registry can assume it exists.
    var skillsRoot: URL {
        let url = Workspace.shared.rootURL.appendingPathComponent(Self.skillsFolderName,
                                                                  isDirectory: true)
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Re-scan the skills folder. Cheap to call on every chat turn — we only
    /// re-parse skill.json / skill.js when their mtime has shifted, and the
    /// resulting dictionary is identity-stable for unchanged entries.
    /// Returns true if anything actually changed.
    @discardableResult
    func reload() -> Bool {
        let root = skillsRoot
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) else {
            return false
        }

        var next: [String: LoadedSkill] = [:]
        var changed = false

        for folder in entries where folder.hasDirectoryPath {
            let manifestURL = folder.appendingPathComponent("skill.json")
            let scriptURL   = folder.appendingPathComponent("skill.js")
            guard fm.fileExists(atPath: manifestURL.path),
                  fm.fileExists(atPath: scriptURL.path) else { continue }

            try? Workspace.shared.ensureDownloaded(manifestURL)
            try? Workspace.shared.ensureDownloaded(scriptURL)

            let manifestMTime = (try? fm.attributesOfItem(atPath: manifestURL.path)[.modificationDate]) as? Date
            let scriptMTime   = (try? fm.attributesOfItem(atPath: scriptURL.path)[.modificationDate]) as? Date

            // Reuse an existing entry if both files look unchanged on disk.
            if let existing = skills[folder.lastPathComponent],
               existing.manifestMTime == manifestMTime,
               existing.scriptMTime == scriptMTime {
                next[existing.name] = existing
                continue
            }

            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any],
                  let name = manifest["name"] as? String,
                  let desc = manifest["description"] as? String,
                  let source = try? String(contentsOf: scriptURL, encoding: .utf8) else {
                print("DynamicSkillRegistry: skipping malformed skill at \(folder.lastPathComponent)")
                continue
            }

            // Parameters block is optional; default to an empty object schema
            // so the model can still call zero-arg skills.
            let params = (manifest["parameters"] as? [String: Any]) ?? [
                "type": "object",
                "properties": [String: Any](),
                "required": [String]()
            ]

            next[name] = LoadedSkill(name: name,
                                     description: desc,
                                     parameters: params,
                                     source: source,
                                     folder: folder,
                                     manifestMTime: manifestMTime,
                                     scriptMTime: scriptMTime)
            changed = true
        }

        // Detect deletions too.
        if next.keys.sorted() != skills.keys.sorted() { changed = true }
        skills = next

        if changed { didReload?() }
        return changed
    }

    // MARK: - Tool schema export

    /// OpenAI-style function schemas for every loaded skill. The harness
    /// appends these to its `toolSchemas` so the model sees them as regular
    /// tools alongside CronSkill / ExaSkill / etc.
    func toolSchemas() -> [[String: Any]] {
        return skills.values
            .sorted { $0.name < $1.name }
            .map { skill -> [String: Any] in
                return [
                    "type": "function",
                    "function": [
                        "name": skill.name,
                        "description": skill.description,
                        "parameters": skill.parameters
                    ]
                ]
            }
    }

    /// Natural-language fragment for TOOLS.md — one bullet per skill so the
    /// model knows what's available without needing to read the parameter
    /// schema in detail.
    func systemPromptFragment() -> String {
        guard !skills.isEmpty else { return "" }
        let bullets = skills.values
            .sorted { $0.name < $1.name }
            .map { "- `\($0.name)`: \($0.description)" }
            .joined(separator: "\n")
        return """
You also have access to these user-authored skills (generated locally and
hot-loaded from disk; treat them as ordinary tools):

\(bullets)

When a skill is running, narrate its progress briefly. If the result includes a
`summary` field, lean on that for your reply. Skills are persistent — the user
can rerun them at any time.
"""
    }

    // MARK: - Skill protocol parity (matches CronSkill, ExaSkill, etc.)

    func handles(functionName: String) -> Bool {
        return skills[functionName] != nil
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        guard skills[call.name] != nil else { return nil }
        let pretty = call.name.replacingOccurrences(of: "_", with: " ")
        return "running \(pretty)"
    }

    /// Dispatch a tool call to the right skill, run it through the JS
    /// runtime, and shape the result into a function-role MessageStruct. The
    /// shape (`status`, `summary`/`error`) mirrors the bundled skills so the
    /// model has consistent fields to read on the way back.
    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        guard let skill = skills[functionCall.name] else {
            completion(Self.functionMessage(
                name: functionCall.name,
                payload: ["status": "error", "error": "Unknown skill \(functionCall.name)"]
            ))
            return
        }

        let skillName = skill.name
        runtime.run(source: skill.source,
                    args: functionCall.arguments,
                    logHandler: { [weak self] msg in
            self?.logHandler?(skillName, msg)
        }) { result in
            switch result {
            case .success(let value):
                var payload: [String: Any] = ["status": "success", "skill": skillName]
                // If the skill returned a dict, splat it in (so `summary`,
                // `data`, etc. land at the top level the model can read).
                // Otherwise stash whatever it returned under `result`.
                if let dict = value as? [String: Any] {
                    for (k, v) in dict { payload[k] = v }
                } else if !(value is NSNull) {
                    payload["result"] = value
                }
                completion(Self.functionMessage(name: skillName, payload: payload))

            case .failure(let error):
                completion(Self.functionMessage(
                    name: skillName,
                    payload: [
                        "status": "error",
                        "skill": skillName,
                        "error": error.localizedDescription
                    ]
                ))
            }
        }
    }

    // MARK: - Mutators (used by SkillBuilderSkill)

    /// Write a freshly authored skill to disk under Workspace/Skills/<name>/
    /// and reload the registry so it becomes immediately callable.
    @discardableResult
    func writeSkill(name: String,
                    description: String,
                    parameters: [String: Any],
                    source: String) throws -> URL {
        let safeName = Self.sanitize(name)
        let folder = skillsRoot.appendingPathComponent(safeName, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "name": safeName,
            "description": description,
            "parameters": parameters,
            "created_at": ISO8601DateFormatter().string(from: Date())
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest,
                                                     options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: folder.appendingPathComponent("skill.json"),
                               options: [.atomic])
        try source.write(to: folder.appendingPathComponent("skill.js"),
                         atomically: true, encoding: .utf8)
        reload()
        return folder
    }

    /// Remove a skill folder and reload. Used by `delete_skill` if the user
    /// asks to clean one up.
    func deleteSkill(name: String) throws {
        guard let skill = skills[name] else { return }
        try fm.removeItem(at: skill.folder)
        reload()
    }

    // MARK: - Helpers

    /// Skill names become folder + tool names + JS function call sites, so we
    /// normalize aggressively: lowercase, snake_case, ascii-only.
    static func sanitize(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        let lowered = raw.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        let filtered = lowered.unicodeScalars.compactMap { scalar -> Character? in
            let ch = Character(scalar)
            return allowed.contains(ch) ? ch : nil
        }
        let result = String(filtered)
        return result.isEmpty ? "skill_\(Int(Date().timeIntervalSince1970))" : result
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
