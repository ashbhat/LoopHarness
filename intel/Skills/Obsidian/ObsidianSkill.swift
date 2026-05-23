//
//  ObsidianSkill.swift
//  Loop
//
//  Lets Loop drive the user's Obsidian vault: create today's note, read /
//  update / move / delete notes, browse folders, and search. Talks to the
//  bearer-auth relay (see `intel/Specs/obsidian_integration_guide.md`).
//
//  The MVP user story (`/today/note`) intentionally goes first in the system
//  prompt so the model defaults to dropping new notes into today's day-folder.
//

import Foundation

struct ObsidianSkill {
    static let shared = ObsidianSkill()

    static let systemPromptFragment: String = """
You can manage the user's Obsidian vault through this set of tools:
- create_obsidian_today_note: create a new note in TODAY's day folder. Use this whenever the user asks for a note without a specific path — it auto-files into the right week/day folder. Pass `title` and `content` (markdown).
- create_obsidian_note: create a note at an explicit vault-relative path (e.g. `0. private/inbox/idea.md`).
- read_obsidian_note: read a note's markdown by its vault-relative path.
- update_obsidian_note: overwrite or append to an existing note. `mode` = "overwrite" (default) or "append".
- delete_obsidian_note: remove a note by path.
- move_obsidian_note: move/rename a note (`from`, `to`).
- find_obsidian_notes: full-text search; returns matches with short context snippets.
- list_obsidian_folder: list files + subfolders at a path. Empty path = vault root.
- create_obsidian_folder: create a folder at a path (idempotent).
- delete_obsidian_folder: delete a folder. Pass `recursive: true` to wipe contents.
- move_obsidian_folder: move/rename a folder.
- find_obsidian_folders: search folder names.
- get_obsidian_layout: nested tree of the vault (or a subtree). Use to orient yourself before bulk edits.
- get_obsidian_today: returns today's day-folder path so you can build paths relative to it.

Workflow tips:
– when adding a note to a folder, prepend it with a number . and then the note name to enforce order. An example would be "1. Cursor Spec.md" in todays folder if "0. Meta" already exists
- Default new notes to `create_obsidian_today_note` unless the user names a destination — that matches the user's daily-note workflow.
- Vault-relative paths never start with a slash and use the convention `0. private/<week-folder>/<day-folder>/<note>.md` where the week uses an en-dash (`–`).
- The relay runs in safe mode by default — destructive ops (delete, move, overwrite update) may return `forbidden_in_safe_mode`. Surface that politely and confirm before retrying.
- After creating a note, share the resulting `path` back to the user so they can find it in Obsidian.
– When writing a spec, call spec builder skill to format the spec in a conversation with a user before creating the markdown file
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "create_obsidian_today_note",
                "description": "Create a new markdown note in TODAY's day folder in the user's Obsidian vault (e.g. `0. private/17. May 03 – May 09/6. Sat, May 09/<title>.md`). Use this when the user asks to create a note without specifying a destination.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Short title — becomes the filename. No need to include `.md`."
                        ],
                        "content": [
                            "type": "string",
                            "description": "Markdown body of the note."
                        ]
                    ],
                    "required": ["title", "content"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "create_obsidian_note",
                "description": "Create a note at an explicit vault-relative path (no leading slash). Parents are auto-created.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Vault-relative path ending in `.md`."],
                        "content": ["type": "string", "description": "Markdown body."]
                    ],
                    "required": ["path", "content"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "read_obsidian_note",
                "description": "Read a note's markdown content by its vault-relative path.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Vault-relative path to the note."]
                    ],
                    "required": ["path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "update_obsidian_note",
                "description": "Update a note. `mode` = \"overwrite\" (default) replaces the file; \"append\" adds to the end.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Vault-relative path to the note."
                        ],
                        "content": [
                            "type": "string",
                            "description": "Markdown content to write."
                        ],
                        "mode": [
                            "type": "string",
                            "description": "overwrite | append",
                            "enum": ["overwrite", "append"]
                        ]
                    ],
                    "required": ["path", "content"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "delete_obsidian_note",
                "description": "Delete a note. Safe-mode-gated on the relay — may return forbidden_in_safe_mode.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Vault-relative path to the note to delete."
                        ]
                    ],
                    "required": ["path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "move_obsidian_note",
                "description": "Move or rename a note. Safe-mode-gated.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "from": [
                            "type": "string",
                            "description": "Current vault-relative path of the note."
                        ],
                        "to": [
                            "type": "string",
                            "description": "Destination vault-relative path."
                        ]
                    ],
                    "required": ["from", "to"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "find_obsidian_notes",
                "description": "Full-text search across the vault. Returns matches with short context snippets.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Search query — matched against note contents."
                        ],
                        "context_length": [
                            "type": "integer",
                            "description": "Optional snippet length (chars)."
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_obsidian_folder",
                "description": "List files and subfolders at a vault path. Empty `path` lists the vault root.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Vault-relative folder path. Empty = root."]
                    ],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "create_obsidian_folder",
                "description": "Create a folder at a vault path. Idempotent.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Vault-relative folder path to create."
                        ]
                    ],
                    "required": ["path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "delete_obsidian_folder",
                "description": "Delete a folder. Pass `recursive: true` to wipe contents. Safe-mode-gated.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Vault-relative folder path to delete."
                        ],
                        "recursive": [
                            "type": "boolean",
                            "description": "If true, delete the folder's contents as well."
                        ]
                    ],
                    "required": ["path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "move_obsidian_folder",
                "description": "Move or rename a folder. Safe-mode-gated.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "from": [
                            "type": "string",
                            "description": "Current vault-relative folder path."
                        ],
                        "to": [
                            "type": "string",
                            "description": "Destination vault-relative folder path."
                        ]
                    ],
                    "required": ["from", "to"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "find_obsidian_folders",
                "description": "Search folder names by query under an optional root.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Substring matched against folder names (case-insensitive)."
                        ],
                        "root": [
                            "type": "string",
                            "description": "Optional vault-relative folder to limit the search to."
                        ],
                        "max_depth": [
                            "type": "integer",
                            "description": "Optional max recursion depth from `root`."
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "get_obsidian_layout",
                "description": "Return a nested layout tree of the vault under `root` up to `max_depth`.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "root": [
                            "type": "string",
                            "description": "Optional vault-relative folder to start from. Empty = vault root."
                        ],
                        "max_depth": [
                            "type": "integer",
                            "description": "Optional max recursion depth (default 4)."
                        ]
                    ],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "get_obsidian_today",
                "description": "Return today's vault paths: { path, week_folder, day_folder }.",
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "create_obsidian_today_note",
        "create_obsidian_note",
        "read_obsidian_note",
        "update_obsidian_note",
        "delete_obsidian_note",
        "move_obsidian_note",
        "find_obsidian_notes",
        "list_obsidian_folder",
        "create_obsidian_folder",
        "delete_obsidian_folder",
        "move_obsidian_folder",
        "find_obsidian_folders",
        "get_obsidian_layout",
        "get_obsidian_today"
    ]

    func handles(functionName: String) -> Bool {
        return ObsidianSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "create_obsidian_today_note":
            if let title = call.arguments["title"] as? String, !title.isEmpty {
                return "writing \"\(title)\" to today's Obsidian folder"
            }
            return "creating note in Obsidian"
        case "create_obsidian_note":
            return "creating Obsidian note"
        case "read_obsidian_note":
            return "reading Obsidian note"
        case "update_obsidian_note":
            return "updating Obsidian note"
        case "delete_obsidian_note":
            return "deleting Obsidian note"
        case "move_obsidian_note":
            return "moving Obsidian note"
        case "find_obsidian_notes":
            if let q = call.arguments["query"] as? String, !q.isEmpty {
                return "searching Obsidian for \(q)"
            }
            return "searching Obsidian"
        case "list_obsidian_folder":
            return "browsing Obsidian"
        case "create_obsidian_folder":
            return "creating Obsidian folder"
        case "delete_obsidian_folder":
            return "deleting Obsidian folder"
        case "move_obsidian_folder":
            return "moving Obsidian folder"
        case "find_obsidian_folders":
            return "searching Obsidian folders"
        case "get_obsidian_layout":
            return "mapping your Obsidian vault"
        case "get_obsidian_today":
            return "checking today's folder"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        let name = functionCall.name

        switch name {

        case "create_obsidian_today_note":
            guard let title = args["title"] as? String,
                  let content = args["content"] as? String else {
                completion(missingArgs(for: name, expected: "title, content")); return
            }
            ObsidianClient.shared.createTodayNote(title: title, content: content) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't create today's Obsidian note.", completion: completion)
            }

        case "create_obsidian_note":
            guard let path = args["path"] as? String,
                  let content = args["content"] as? String else {
                completion(missingArgs(for: name, expected: "path, content")); return
            }
            ObsidianClient.shared.createNote(path: path, content: content) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't create the Obsidian note.", completion: completion)
            }

        case "read_obsidian_note":
            guard let path = args["path"] as? String else {
                completion(missingArgs(for: name, expected: "path")); return
            }
            ObsidianClient.shared.readNote(path: path) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't read that Obsidian note.", completion: completion)
            }

        case "update_obsidian_note":
            guard let path = args["path"] as? String,
                  let content = args["content"] as? String else {
                completion(missingArgs(for: name, expected: "path, content")); return
            }
            let mode = args["mode"] as? String
            ObsidianClient.shared.updateNote(path: path, content: content, mode: mode) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't update that Obsidian note.", completion: completion)
            }

        case "delete_obsidian_note":
            guard let path = args["path"] as? String else {
                completion(missingArgs(for: name, expected: "path")); return
            }
            ObsidianClient.shared.deleteNote(path: path) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't delete that Obsidian note.", completion: completion)
            }

        case "move_obsidian_note":
            guard let from = args["from"] as? String,
                  let to = args["to"] as? String else {
                completion(missingArgs(for: name, expected: "from, to")); return
            }
            ObsidianClient.shared.moveNote(from: from, to: to) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't move that Obsidian note.", completion: completion)
            }

        case "find_obsidian_notes":
            guard let query = args["query"] as? String else {
                completion(missingArgs(for: name, expected: "query")); return
            }
            let ctx = ObsidianSkill.intArg(args["context_length"])
            ObsidianClient.shared.findNotes(query: query, contextLength: ctx) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't search Obsidian.", completion: completion)
            }

        case "list_obsidian_folder":
            let path = (args["path"] as? String) ?? ""
            ObsidianClient.shared.listFolder(path: path) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't list that Obsidian folder.", completion: completion)
            }

        case "create_obsidian_folder":
            guard let path = args["path"] as? String else {
                completion(missingArgs(for: name, expected: "path")); return
            }
            ObsidianClient.shared.createFolder(path: path) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't create that Obsidian folder.", completion: completion)
            }

        case "delete_obsidian_folder":
            guard let path = args["path"] as? String else {
                completion(missingArgs(for: name, expected: "path")); return
            }
            let recursive = (args["recursive"] as? Bool) ?? false
            ObsidianClient.shared.deleteFolder(path: path, recursive: recursive) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't delete that Obsidian folder.", completion: completion)
            }

        case "move_obsidian_folder":
            guard let from = args["from"] as? String,
                  let to = args["to"] as? String else {
                completion(missingArgs(for: name, expected: "from, to")); return
            }
            ObsidianClient.shared.moveFolder(from: from, to: to) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't move that Obsidian folder.", completion: completion)
            }

        case "find_obsidian_folders":
            guard let query = args["query"] as? String else {
                completion(missingArgs(for: name, expected: "query")); return
            }
            let root = args["root"] as? String
            let depth = ObsidianSkill.intArg(args["max_depth"])
            ObsidianClient.shared.findFolders(query: query, root: root, maxDepth: depth) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't search Obsidian folders.", completion: completion)
            }

        case "get_obsidian_layout":
            let root = args["root"] as? String
            let depth = ObsidianSkill.intArg(args["max_depth"])
            ObsidianClient.shared.layout(root: root, maxDepth: depth) { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't load your Obsidian layout.", completion: completion)
            }

        case "get_obsidian_today":
            ObsidianClient.shared.today { json, error in
                ObsidianSkill.respond(name: name, json: json, error: error, errorPrefix: "I couldn't get today's Obsidian path.", completion: completion)
            }

        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Obsidian tool '\(name)'."
            ))
        }
    }

    // MARK: - Helpers

    private func missingArgs(for name: String, expected: String) -> MessageStruct {
        return MessageStruct(
            role: "assistant",
            content: "I need \(expected) to call \(name). Please provide them."
        )
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    /// Pack the relay's JSON payload into a `function`-role message so the
    /// model can react. On error, fall back to a plain assistant message.
    private static func respond(name: String,
                                json: [String: Any]?,
                                error: Error?,
                                errorPrefix: String,
                                completion: @escaping (MessageStruct) -> Void) {
        if let json = json {
            let serialized: String
            if let data = try? JSONSerialization.data(withJSONObject: json, options: []),
               let str = String(data: data, encoding: .utf8) {
                serialized = str
            } else {
                serialized = "{}"
            }
            completion(MessageStruct(role: "function", content: serialized, name: name))
            return
        }
        let detail = error?.localizedDescription ?? "Unknown error"
        completion(MessageStruct(role: "assistant", content: "\(errorPrefix) \(detail)"))
    }
}
