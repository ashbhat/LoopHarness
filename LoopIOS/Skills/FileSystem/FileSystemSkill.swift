//
//  FileSystemSkill.swift
//  Loop
//
//  Built from LoopIOS/Specs/file_system_spec.md.
//
//  Exposes nine file-system tools to the agent, all rooted in Workspace.shared:
//  file_read, file_write, file_edit, file_append, file_delete, file_move,
//  file_list, file_search, folder_create.
//
//  Every path argument is resolved through Workspace.resolve(_:) which sandboxes
//  the call to the workspace root and rejects path traversal.
//

import Foundation

final class FileSystemSkill {
    static let shared = FileSystemSkill()

    /// File extensions we treat as text (UTF-8 read/write). Anything else is
    /// returned as base64 from file_read and rejected by file_edit/file_append.
    private static let textExtensions: Set<String> = [
        "md", "txt", "json", "yaml", "yml", "csv", "log",
        "swift", "py", "js", "ts", "html", "css", "xml", "toml", "ini", "sh"
    ]

    // MARK: - System prompt fragment

    static let systemPromptFragment: String = """
You have a persistent file system rooted at the user's iCloud Drive workspace.
This is your "hard drive" — anything you save here survives across conversations
and is also visible to the user in the iOS Files app.

This workspace is your default save location. Unless the user explicitly asks
for a different place, save any files you create — notes, downloads, generated
documents — here rather than anywhere else.

**Code goes through a sub-agent, not the primary chat.**
If the user asks for code (any language, any size — even a one-line script),
call `spawn_sub_agent` with `kind: "coding"` and a clear task; do NOT call
`file_write` / `file_edit` on a code file from the primary chat. The file
tools listed below are still the right primitives — but a coding sub-agent
should be the one calling them. The exception is text files that aren't code
(notes, memory entries, plain documents) — those are fine to write inline.

Conventions:
- All paths are relative to the workspace root. No leading "/", no "..".
- The root holds the canonical context files (SOUL.md, USER.md, MEMORY.md,
  AGENTS.md, HEARTBEAT.md). These also auto-load into the system prompt.
- Use folders to organize: `memory/2026-05-08.md` for daily logs,
  `notes/<topic>.md` for notes, `downloads/...` for fetched content.

Tools:
- file_read(path) → contents (text) or base64 (binary).
- file_write(path, content, mode?) → create or overwrite. `mode` defaults to "write"; pass "append" to add to the end of an existing text file (for logs / running memory). Parents auto-created either way.
- file_edit(path, find, replace) → targeted find/replace inside an existing file.
- file_delete(path) → delete a file or empty folder.
- file_move(from, to) → move or rename.
- file_list(path?, recursive?) → directory contents with type / size / modified.
- file_search(query, scope?, path?) → find by filename or content.
- folder_create(path) → mkdir -p.
- share_file(path) → render the file as a rich card (title, kind badge, snippet
  preview, tap-to-open) in the chat. Use this whenever the user asks to see,
  preview, render, attach, or share a file. Don't `file_read` and then paste
  the contents into a fenced code block — call `share_file(path)` and let the
  card handle the visual. For multiple files, call once per file. A tiny
  follow-up sentence is fine ("Here you go.") but don't restate the contents.

When you save user-facing context (their preferences, decisions, recurring
facts), prefer the canonical context files via update_self_doc rather than
file_write — those are loaded into every system prompt automatically.
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "file_read",
                "description": "Read a file from the workspace. Returns text content for text files; base64 for binary.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Relative path from workspace root."]
                    ],
                    "required": ["path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "file_write",
                "description": "Create / overwrite / append a text file. Parent directories are created automatically.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path":    ["type": "string", "description": "Relative path from workspace root."],
                        "content": ["type": "string", "description": "Text content to write or append."],
                        "mode": [
                            "type": "string",
                            "description": "\"write\" (default) creates / overwrites. \"append\" adds to the end of an existing text file (creates it if missing).",
                            "enum": ["write", "append"]
                        ]
                    ],
                    "required": ["path", "content"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "file_edit",
                "description": "Make a targeted find/replace edit inside an existing text file. Errors if `find` is missing or appears more than once.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path":    ["type": "string", "description": "Relative path from workspace root."],
                        "find":    ["type": "string", "description": "Exact substring to find. Must match exactly once."],
                        "replace": ["type": "string", "description": "Replacement text."]
                    ],
                    "required": ["path", "find", "replace"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "file_delete",
                "description": "Delete a file or empty folder.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Relative path from workspace root."]
                    ],
                    "required": ["path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "file_move",
                "description": "Move or rename a file or folder.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "from": ["type": "string", "description": "Current relative path."],
                        "to":   ["type": "string", "description": "Destination relative path. Parent directories are created."]
                    ],
                    "required": ["from", "to"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "file_list",
                "description": "List contents of a directory. Each entry includes name, path, type, size, and modified timestamp.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path":      ["type": "string", "description": "Directory path. Defaults to workspace root."],
                        "recursive": ["type": "boolean", "description": "Include subdirectories. Default false."]
                    ],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "file_search",
                "description": "Search files by filename or content. Returns matching paths and a relevant snippet for content matches.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search term."],
                        "scope": [
                            "type": "string",
                            "enum": ["name", "content", "both"],
                            "description": "Where to search. Default both."
                        ],
                        "path": ["type": "string", "description": "Limit to a subdirectory. Default whole workspace."]
                    ],
                    "required": ["query"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "folder_create",
                "description": "Create a folder, including any intermediate directories.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Folder path to create."]
                    ],
                    "required": ["path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "share_file",
                "description": "Surface a workspace file as a rich card in the chat — title, type badge, snippet preview, tap-to-open. Use this whenever the user asks to see, preview, render, attach, or share a file. Do NOT call `file_read` and inline the contents in a fenced code block — call `share_file(path)` instead. Multiple files: call once per file.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Workspace-relative path of the file to share."]
                    ],
                    "required": ["path"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "file_read", "file_write", "file_edit",
        "file_delete", "file_move", "file_list", "file_search",
        "folder_create", "share_file"
    ]

    func handles(functionName: String) -> Bool {
        return FileSystemSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        let path = (call.arguments["path"] as? String)
            ?? (call.arguments["from"] as? String)
            ?? ""
        let label = path.isEmpty ? "workspace" : path
        switch call.name {
        case "file_read":     return "reading \(label)"
        case "file_write":
            let mode = (call.arguments["mode"] as? String)?.lowercased()
            return mode == "append" ? "appending to \(label)" : "writing \(label)"
        case "file_edit":     return "editing \(label)"
        case "file_delete":   return "deleting \(label)"
        case "file_move":
            if let to = call.arguments["to"] as? String, !to.isEmpty {
                return "moving \(label) → \(to)"
            }
            return "moving \(label)"
        case "file_list":     return path.isEmpty ? "listing workspace" : "listing \(label)"
        case "file_search":
            if let q = call.arguments["query"] as? String, !q.isEmpty {
                return "searching for \(q)"
            }
            return "searching workspace"
        case "folder_create": return "creating folder \(label)"
        case "share_file":    return "sharing \(label)"
        default:              return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let work = { [weak self] in
            guard let self = self else { return }
            print("FileSystemSkill: → \(functionCall.name) args=\(functionCall.arguments) backend=\(Workspace.shared.backend) root=\(Workspace.shared.rootURL.path)")
            // share_file builds a MessageStruct directly (with fileAttachment
            // set) instead of returning a JSON payload — its whole purpose is
            // the rendered card. Route it before the JSON-payload switch.
            if functionCall.name == "share_file" {
                let message = self.shareFile(functionCall.arguments,
                                             conversationId: functionCall.conversationId)
                DispatchQueue.main.async {
                    completion(message)
                }
                return
            }
            let result: [String: Any]
            switch functionCall.name {
            case "file_read":     result = self.fileRead(functionCall.arguments)
            case "file_write":
                let mode = (functionCall.arguments["mode"] as? String)?.lowercased()
                result = mode == "append"
                    ? self.fileAppend(functionCall.arguments)
                    : self.fileWrite(functionCall.arguments)
            case "file_edit":     result = self.fileEdit(functionCall.arguments)
            case "file_delete":   result = self.fileDelete(functionCall.arguments)
            case "file_move":     result = self.fileMove(functionCall.arguments)
            case "file_list":     result = self.fileList(functionCall.arguments)
            case "file_search":   result = self.fileSearch(functionCall.arguments)
            case "folder_create": result = self.folderCreate(functionCall.arguments)
            default:
                result = ["status": "error", "error": "unknown tool '\(functionCall.name)'"]
            }
            print("FileSystemSkill: ← \(functionCall.name) \(result)")
            DispatchQueue.main.async {
                completion(FileSystemSkill.functionMessage(name: functionCall.name, payload: result))
            }
        }
        // Disk + iCloud-download work — keep off the main thread.
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    // MARK: - share_file

    /// Build a FileAttachment from a workspace file and return a function-role
    /// message that carries it. The chat cell renders the attachment as a
    /// FilePreviewCardView (markdown / text / generic kinds) or an inline
    /// image / PDF bubble, with tap-to-open routed through the existing
    /// per-kind handler. The model gets a short text confirmation so it knows
    /// the share landed and doesn't try to also inline the contents.
    private func shareFile(_ args: [String: Any],
                           conversationId: String?) -> MessageStruct {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return FileSystemSkill.functionMessage(
                name: "share_file",
                payload: ["status": "error", "error": "path is required"])
        }
        let url: URL
        do {
            url = try Workspace.shared.resolve(path)
            try Workspace.shared.ensureDownloaded(url)
        } catch {
            return FileSystemSkill.functionMessage(
                name: "share_file",
                payload: ["status": "error",
                          "error": "could not resolve \(path): \(error.localizedDescription)"])
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return FileSystemSkill.functionMessage(
                name: "share_file",
                payload: ["status": "error", "error": "no such file: \(path)"])
        }
        if isDir.boolValue {
            return FileSystemSkill.functionMessage(
                name: "share_file",
                payload: ["status": "error",
                          "error": "\(path) is a folder — share_file only handles individual files"])
        }
        let attachment: FileAttachment
        do {
            attachment = try AttachmentStore.shared.saveFromFileURL(url)
        } catch {
            return FileSystemSkill.functionMessage(
                name: "share_file",
                payload: ["status": "error",
                          "error": "couldn't snapshot \(path): \(error.localizedDescription)"])
        }
        // Body the LLM sees as the result. Short on purpose — the visible
        // surface is the rendered card. Mentioning the path keeps the model
        // grounded if it wants to follow up with edits.
        let body = "Shared \(attachment.fileName) with the user as an attachment card."
        var msg = MessageStruct(role: "function",
                                content: body,
                                name: "share_file",
                                fileAttachment: attachment)
        msg.callId = nil
        _ = conversationId  // currently unused — FileAttachment has no conversation field
        return msg
    }

    // MARK: - Tool handlers

    private func fileRead(_ args: [String: Any]) -> [String: Any] {
        guard let path = args["path"] as? String else {
            return ["status": "error", "error": "path is required"]
        }
        do {
            let url = try Workspace.shared.resolve(path)
            try Workspace.shared.ensureDownloaded(url)
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return ["status": "error", "error": "no such file: \(path)"]
            }
            if isDir.boolValue {
                return ["status": "error", "error": "\(path) is a folder — use file_list"]
            }

            let attrs = try fm.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? Int) ?? 0
            if size > Workspace.maxFileBytes {
                return [
                    "status": "error",
                    "error": "file is \(size) bytes — over the \(Workspace.maxFileBytes)-byte read cap"
                ]
            }

            let isText = FileSystemSkill.isTextExtension(url.pathExtension)
            let data = try Data(contentsOf: url)
            if isText, let text = String(data: data, encoding: .utf8) {
                return [
                    "status": "success",
                    "path": Workspace.shared.relativePath(of: url),
                    "encoding": "utf8",
                    "size": size,
                    "content": text
                ]
            } else {
                return [
                    "status": "success",
                    "path": Workspace.shared.relativePath(of: url),
                    "encoding": "base64",
                    "size": size,
                    "content": data.base64EncodedString()
                ]
            }
        } catch {
            return ["status": "error", "error": error.localizedDescription]
        }
    }

    private func fileWrite(_ args: [String: Any]) -> [String: Any] {
        guard let path = args["path"] as? String else {
            return ["status": "error", "error": "path is required"]
        }
        guard let content = args["content"] as? String else {
            return ["status": "error", "error": "content is required"]
        }
        if content.utf8.count > Workspace.maxFileBytes {
            return ["status": "error",
                    "error": "content is \(content.utf8.count) bytes — over the \(Workspace.maxFileBytes)-byte write cap"]
        }
        do {
            let url = try Workspace.shared.resolve(path)
            try ensureParentDirectory(for: url)
            // Parent might be an unmaterialized iCloud stub on iOS — make sure
            // it's locally present before trying to create a child in it.
            try Workspace.shared.ensureDownloaded(url.deletingLastPathComponent())
            try Workspace.shared.coordinatedWrite(to: url) { writeURL in
                try content.write(to: writeURL, atomically: true, encoding: .utf8)
            }
            Self.notifyHarnessIfContextDoc(at: url, content: content)
            return [
                "status": "success",
                "path": Workspace.shared.relativePath(of: url),
                "size": content.utf8.count
            ]
        } catch {
            return ["status": "error", "error": error.localizedDescription]
        }
    }

    private func fileEdit(_ args: [String: Any]) -> [String: Any] {
        guard let path = args["path"] as? String else {
            return ["status": "error", "error": "path is required"]
        }
        guard let find = args["find"] as? String, !find.isEmpty else {
            return ["status": "error", "error": "find is required and may not be empty"]
        }
        guard let replace = args["replace"] as? String else {
            return ["status": "error", "error": "replace is required (use empty string to delete)"]
        }
        do {
            let url = try Workspace.shared.resolve(path)
            try Workspace.shared.ensureDownloaded(url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ["status": "error", "error": "no such file: \(path)"]
            }
            guard FileSystemSkill.isTextExtension(url.pathExtension) else {
                return ["status": "error", "error": "file_edit only works on text files"]
            }
            let original = try String(contentsOf: url, encoding: .utf8)
            let occurrences = original.components(separatedBy: find).count - 1
            if occurrences == 0 {
                return ["status": "error", "error": "find string not present in file"]
            }
            if occurrences > 1 {
                return ["status": "error",
                        "error": "find string appears \(occurrences) times — be more specific so it matches exactly once"]
            }
            let updated = original.replacingOccurrences(of: find, with: replace)
            if updated.utf8.count > Workspace.maxFileBytes {
                return ["status": "error",
                        "error": "result would be \(updated.utf8.count) bytes — over the \(Workspace.maxFileBytes)-byte cap"]
            }
            try Workspace.shared.coordinatedWrite(to: url) { writeURL in
                try updated.write(to: writeURL, atomically: true, encoding: .utf8)
            }
            Self.notifyHarnessIfContextDoc(at: url, content: updated)
            return [
                "status": "success",
                "path": Workspace.shared.relativePath(of: url),
                "size": updated.utf8.count
            ]
        } catch {
            return ["status": "error", "error": error.localizedDescription]
        }
    }

    private func fileAppend(_ args: [String: Any]) -> [String: Any] {
        guard let path = args["path"] as? String else {
            return ["status": "error", "error": "path is required"]
        }
        guard let content = args["content"] as? String else {
            return ["status": "error", "error": "content is required"]
        }
        do {
            let url = try Workspace.shared.resolve(path)
            try ensureParentDirectory(for: url)

            let fm = FileManager.default
            var existing = ""
            if fm.fileExists(atPath: url.path) {
                try Workspace.shared.ensureDownloaded(url)
                if !FileSystemSkill.isTextExtension(url.pathExtension) {
                    return ["status": "error", "error": "file_write mode \"append\" only works on text files"]
                }
                existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            let combined = existing + content
            if combined.utf8.count > Workspace.maxFileBytes {
                return ["status": "error",
                        "error": "result would be \(combined.utf8.count) bytes — over the \(Workspace.maxFileBytes)-byte cap"]
            }
            try Workspace.shared.coordinatedWrite(to: url) { writeURL in
                try combined.write(to: writeURL, atomically: true, encoding: .utf8)
            }
            Self.notifyHarnessIfContextDoc(at: url, content: combined)
            return [
                "status": "success",
                "path": Workspace.shared.relativePath(of: url),
                "size": combined.utf8.count,
                "appended_bytes": content.utf8.count
            ]
        } catch {
            return ["status": "error", "error": error.localizedDescription]
        }
    }

    private func fileDelete(_ args: [String: Any]) -> [String: Any] {
        guard let path = args["path"] as? String else {
            return ["status": "error", "error": "path is required"]
        }
        do {
            let url = try Workspace.shared.resolve(path)
            if url.standardizedFileURL.path == Workspace.shared.rootURL.standardizedFileURL.path {
                return ["status": "error", "error": "cannot delete the workspace root"]
            }
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return ["status": "error", "error": "no such file: \(path)"]
            }
            if isDir.boolValue {
                let children = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                if !children.isEmpty {
                    return ["status": "error",
                            "error": "folder is not empty — delete its contents first"]
                }
            }
            try Workspace.shared.coordinatedRemove(url)
            return [
                "status": "success",
                "path": Workspace.shared.relativePath(of: url),
                "type": isDir.boolValue ? "folder" : "file"
            ]
        } catch {
            return ["status": "error", "error": error.localizedDescription]
        }
    }

    private func fileMove(_ args: [String: Any]) -> [String: Any] {
        guard let from = args["from"] as? String else {
            return ["status": "error", "error": "from is required"]
        }
        guard let to = args["to"] as? String else {
            return ["status": "error", "error": "to is required"]
        }
        do {
            let src = try Workspace.shared.resolve(from)
            let dst = try Workspace.shared.resolve(to)
            let fm = FileManager.default
            guard fm.fileExists(atPath: src.path) else {
                return ["status": "error", "error": "no such file: \(from)"]
            }
            if fm.fileExists(atPath: dst.path) {
                return ["status": "error", "error": "destination already exists: \(to)"]
            }
            try ensureParentDirectory(for: dst)
            try Workspace.shared.coordinatedMove(from: src, to: dst)
            return [
                "status": "success",
                "from": Workspace.shared.relativePath(of: src),
                "to":   Workspace.shared.relativePath(of: dst)
            ]
        } catch {
            return ["status": "error", "error": error.localizedDescription]
        }
    }

    private func fileList(_ args: [String: Any]) -> [String: Any] {
        let path = (args["path"] as? String) ?? ""
        let recursive = (args["recursive"] as? Bool) ?? false
        do {
            let dir = try Workspace.shared.resolve(path)
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                return ["status": "error", "error": "not a directory: \(path)"]
            }

            var entries: [[String: Any]] = []
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

            if recursive {
                guard let enumerator = fm.enumerator(at: dir,
                                                     includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else {
                    return ["status": "error", "error": "could not enumerate \(path)"]
                }
                for case let url as URL in enumerator {
                    entries.append(self.makeEntry(url: url))
                }
            } else {
                let urls = try fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles])
                for url in urls {
                    entries.append(self.makeEntry(url: url))
                }
            }

            entries.sort { (lhs, rhs) -> Bool in
                let lp = (lhs["path"] as? String) ?? ""
                let rp = (rhs["path"] as? String) ?? ""
                return lp < rp
            }

            return [
                "status": "success",
                "path": Workspace.shared.relativePath(of: dir),
                "count": entries.count,
                "entries": entries
            ]
        } catch {
            return ["status": "error", "error": error.localizedDescription]
        }
    }

    private func fileSearch(_ args: [String: Any]) -> [String: Any] {
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return ["status": "error", "error": "query is required"]
        }
        let scope = (args["scope"] as? String)?.lowercased() ?? "both"
        let basePath = (args["path"] as? String) ?? ""
        let lowerQuery = query.lowercased()
        do {
            let dir = try Workspace.shared.resolve(basePath)
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                return ["status": "error", "error": "not a directory: \(basePath)"]
            }

            guard let enumerator = fm.enumerator(at: dir,
                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles]) else {
                return ["status": "error", "error": "could not enumerate \(basePath)"]
            }

            let searchName    = scope == "name" || scope == "both"
            let searchContent = scope == "content" || scope == "both"
            var hits: [[String: Any]] = []
            let maxHits = 50

            for case let url as URL in enumerator {
                if hits.count >= maxHits { break }
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if v?.isDirectory == true { continue }

                var hit: [String: Any]?
                if searchName, url.lastPathComponent.lowercased().contains(lowerQuery) {
                    hit = [
                        "path": Workspace.shared.relativePath(of: url),
                        "match": "name"
                    ]
                }

                if searchContent, hit == nil, FileSystemSkill.isTextExtension(url.pathExtension) {
                    let attrs = try? fm.attributesOfItem(atPath: url.path)
                    let size = (attrs?[.size] as? Int) ?? 0
                    if size > Workspace.maxFileBytes { continue }
                    if let text = try? String(contentsOf: url, encoding: .utf8),
                       let range = text.range(of: query, options: .caseInsensitive) {
                        hit = [
                            "path": Workspace.shared.relativePath(of: url),
                            "match": "content",
                            "snippet": Self.snippet(around: range, in: text)
                        ]
                    }
                }

                if let hit = hit { hits.append(hit) }
            }

            return [
                "status": "success",
                "query": query,
                "scope": scope,
                "count": hits.count,
                "results": hits,
                "truncated": hits.count >= maxHits
            ]
        } catch {
            return ["status": "error", "error": error.localizedDescription]
        }
    }

    private func folderCreate(_ args: [String: Any]) -> [String: Any] {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ["status": "error", "error": "path is required"]
        }
        do {
            let url = try Workspace.shared.resolve(path)
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return [
                        "status": "success",
                        "path": Workspace.shared.relativePath(of: url),
                        "message": "folder already exists"
                    ]
                }
                return ["status": "error", "error": "a file already exists at that path"]
            }
            try Workspace.shared.coordinatedCreateDirectory(at: url)
            return [
                "status": "success",
                "path": Workspace.shared.relativePath(of: url)
            ]
        } catch {
            return ["status": "error", "error": error.localizedDescription]
        }
    }

    // MARK: - Helpers

    private func ensureParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try Workspace.shared.coordinatedCreateDirectory(at: parent)
    }

    private func makeEntry(url: URL) -> [String: Any] {
        let v = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey
        ])
        let isDir = v?.isDirectory ?? false
        var entry: [String: Any] = [
            "name": url.lastPathComponent,
            "path": Workspace.shared.relativePath(of: url),
            "type": isDir ? "folder" : "file"
        ]
        if !isDir, let size = v?.fileSize {
            entry["size"] = size
        }
        if let modified = v?.contentModificationDate {
            entry["modified"] = ISO8601DateFormatter().string(from: modified)
        }
        return entry
    }

    private static func isTextExtension(_ ext: String) -> Bool {
        if ext.isEmpty { return true }   // no extension → assume text
        return textExtensions.contains(ext.lowercased())
    }

    /// Build a one-line snippet of context around the match for file_search
    /// results.
    private static func snippet(around range: Range<String.Index>, in text: String) -> String {
        let radius = 60
        let startIdx = text.index(range.lowerBound,
                                  offsetBy: -radius,
                                  limitedBy: text.startIndex) ?? text.startIndex
        let endIdx = text.index(range.upperBound,
                                offsetBy: radius,
                                limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[startIdx..<endIdx])
        s = s.replacingOccurrences(of: "\n", with: " ")
        if startIdx != text.startIndex { s = "…" + s }
        if endIdx != text.endIndex     { s = s + "…" }
        return s
    }

    /// If the model just rewrote one of the canonical context files via
    /// file_write/file_edit/file_append, mirror that change into the
    /// AgentHarness in-memory copy so the next chat() picks it up immediately.
    private static func notifyHarnessIfContextDoc(at url: URL, content: String) {
        let name = url.lastPathComponent
        guard url.deletingLastPathComponent().standardizedFileURL.path
                == Workspace.shared.rootURL.standardizedFileURL.path else {
            return
        }
        let key = name.lowercased().replacingOccurrences(of: ".md", with: "")
        guard let doc = AgentHarness.SelfDoc(rawValue: key) else { return }
        AgentHarness.shared.updateSelfDoc(doc, content: content, persist: false)
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
