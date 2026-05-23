//
//  GitSkill.swift
//  Loop
//
//  Built from intel/Specs/Saturday Spec C - Agent Infra.md (Task 9).
//
//  Real git — clone repositories (with full history), pull, and check status —
//  into the agent's Workspace. Backed by SwiftGitX, a Swift wrapper around
//  libgit2 built from source via SPM (so it links for iOS device, the arm64
//  simulator, and native macOS alike). The spec originally named SwiftGit2;
//  its only SPM-viable binary ships no native-macOS / arm64-simulator slice,
//  so SwiftGitX is the documented substitute — same capability, different lib.
//
//  NOTE: libgit2 writes the working tree straight to disk. It deliberately
//  BYPASSES Workspace's NSFileCoordinator wrappers and the 1 MB
//  Workspace.maxFileBytes cap — a real repo has files larger than that and
//  thousands of them, and gating each object write through the workspace
//  helpers would be both wrong and unbearably slow. Repos therefore clone
//  fine at any size. The FileSystem skill's per-file read cap still applies
//  later, when the agent (or a coding sub-agent) reads individual files back.
//

import Foundation
import SwiftGitX

final class GitSkill {
    static let shared = GitSkill()
    private init() {}

    /// Everything clones under here so a repo is browsable in the Files app
    /// and reachable by the FileSystem tools using a `repos/<name>` path.
    private static let reposFolder = "repos"

    // MARK: - System prompt fragment

    static let systemPromptFragment: String = """
You can work with real git repositories inside your workspace:
- git_clone: clone a public (or private, with a token) repo into the
  workspace. Pass `url`; optionally `dest` (a folder name under `repos/`,
  defaults to the repo name) and `token` (a personal access token for
  private HTTPS repos — never echo it back). Clones the full history.
- git_status: show the working-tree status of a cloned repo. Pass `path`
  (the repo's workspace path, e.g. `repos/myrepo`).
- git_pull: fetch the latest commits for a cloned repo from its origin.
  Pass `path`.

After cloning, the repo lives at `repos/<name>` in the workspace, so you can
read and edit its files with the file tools (file_list, file_read,
file_edit, …) just like any other workspace content. Cloning a large repo
can take a little while and isn't subject to the 1 MB per-file workspace cap.
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "git_clone",
                "description": "Clone a git repository (full history) into the workspace under repos/<name>. Returns the workspace path it landed at.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "url": [
                            "type": "string",
                            "description": "The repository URL (https://… recommended; git:// / http:// also accepted)."
                        ],
                        "dest": [
                            "type": "string",
                            "description": "Optional destination folder name under repos/. Defaults to the repository name."
                        ],
                        "token": [
                            "type": "string",
                            "description": "Optional personal access token for a private HTTPS repo. Used only for this clone; never stored or echoed."
                        ]
                    ],
                    "required": ["url"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "git_status",
                "description": "Show the working-tree status (changed / untracked files) of a repository already cloned into the workspace.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Workspace path of the cloned repo, e.g. 'repos/myrepo'."
                        ]
                    ],
                    "required": ["path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "git_pull",
                "description": "Fetch the latest commits from origin for a repository already cloned into the workspace.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Workspace path of the cloned repo, e.g. 'repos/myrepo'."
                        ]
                    ],
                    "required": ["path"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["git_clone", "git_status", "git_pull"]

    func handles(functionName: String) -> Bool {
        return GitSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "git_clone":
            if let raw = call.arguments["url"] as? String,
               let name = GitSkill.repoName(fromURLString: raw) {
                return "cloning \(name)"
            }
            return "cloning repository"
        case "git_status":
            return "checking git status"
        case "git_pull":
            return "pulling latest commits"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "git_clone":
            clone(args: functionCall.arguments, completion: completion)
        case "git_status":
            status(args: functionCall.arguments, completion: completion)
        case "git_pull":
            pull(args: functionCall.arguments, completion: completion)
        default:
            completion(Self.result(
                name: functionCall.name,
                payload: ["status": "error", "error": "Unknown git tool \(functionCall.name)"]))
        }
    }

    // MARK: - git_clone

    private func clone(args: [String: Any],
                       completion: @escaping (MessageStruct) -> Void) {
        guard let rawURL = (args["url"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            completion(Self.result(name: "git_clone",
                                   payload: ["status": "error", "error": "url is required"]))
            return
        }

        guard let repoName = Self.repoName(fromURLString: rawURL) else {
            completion(Self.result(name: "git_clone",
                                   payload: ["status": "error", "error": "Couldn't parse a repository name from '\(rawURL)'"]))
            return
        }

        // Destination is always under repos/, sandboxed through Workspace so a
        // crafted `dest` can't escape the workspace root.
        let destName = (args["dest"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let relativeDest: String
        if let destName, !destName.isEmpty {
            relativeDest = "\(Self.reposFolder)/\(destName)"
        } else {
            relativeDest = "\(Self.reposFolder)/\(repoName)"
        }

        let targetURL: URL
        let parentURL: URL
        do {
            targetURL = try Workspace.shared.resolve(relativeDest)
            parentURL = try Workspace.shared.resolve(Self.reposFolder)
        } catch {
            completion(Self.result(name: "git_clone",
                                   payload: ["status": "error", "error": "Bad destination: \(error.localizedDescription)"]))
            return
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: targetURL.path) {
            completion(Self.result(name: "git_clone", payload: [
                "status": "error",
                "error": "'\(relativeDest)' already exists. Pick a different dest or delete it first."
            ]))
            return
        }

        // The parent (repos/) must exist; libgit2 creates the leaf dir itself.
        do {
            try Workspace.shared.coordinatedCreateDirectory(at: parentURL)
        } catch {
            completion(Self.result(name: "git_clone",
                                   payload: ["status": "error", "error": "Couldn't create repos/: \(error.localizedDescription)"]))
            return
        }

        // Token auth: embed the PAT in the HTTPS userinfo. SwiftGitX hands the
        // URL straight to libgit2, which honors the userinfo for basic auth —
        // so no credential callback is needed. The token is used only here and
        // is never written into any result we return.
        let token = (args["token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remoteURL = Self.cloneURL(from: rawURL, token: token) else {
            completion(Self.result(name: "git_clone",
                                   payload: ["status": "error", "error": "'\(rawURL)' is not a valid URL"]))
            return
        }

        Task {
            do {
                _ = try await Repository.clone(from: remoteURL, to: targetURL)
                completion(Self.result(name: "git_clone", payload: [
                    "status": "ok",
                    "path": relativeDest,
                    "repo": repoName,
                    "message": "Cloned into \(relativeDest). Read its files with the file tools."
                ]))
            } catch {
                // Don't let a token leak via the error string.
                completion(Self.result(name: "git_clone", payload: [
                    "status": "error",
                    "error": Self.scrub(Self.message(from: error), token: token)
                ]))
            }
        }
    }

    // MARK: - git_status

    private func status(args: [String: Any],
                        completion: @escaping (MessageStruct) -> Void) {
        guard let repoURL = resolveRepo(args["path"], name: "git_status", completion: completion) else {
            return
        }
        Task {
            do {
                let repo = try Repository.open(at: repoURL)
                let entries = try repo.status()
                if entries.isEmpty {
                    completion(Self.result(name: "git_status", payload: [
                        "status": "ok", "clean": true,
                        "message": "Working tree clean — no changes."
                    ]))
                    return
                }
                let rows = entries.prefix(200).map { entry -> String in
                    let code = Self.shortCode(for: entry.status)
                    let path = entry.workingTree?.newFile.path
                        ?? entry.index?.newFile.path
                        ?? entry.index?.oldFile.path
                        ?? entry.workingTree?.oldFile.path
                        ?? "(unknown)"
                    return "\(code) \(path)"
                }
                completion(Self.result(name: "git_status", payload: [
                    "status": "ok",
                    "clean": false,
                    "changed_files": entries.count,
                    "entries": Array(rows)
                ]))
            } catch {
                completion(Self.result(name: "git_status", payload: [
                    "status": "error", "error": Self.message(from: error)
                ]))
            }
        }
    }

    // MARK: - git_pull

    private func pull(args: [String: Any],
                      completion: @escaping (MessageStruct) -> Void) {
        guard let repoURL = resolveRepo(args["path"], name: "git_pull", completion: completion) else {
            return
        }
        Task {
            do {
                let repo = try Repository.open(at: repoURL)
                // Fetch updates the remote-tracking refs from origin. We don't
                // auto-merge into the working tree — a coding agent should
                // inspect/decide rather than have history rewritten under it.
                try await repo.fetch()
                completion(Self.result(name: "git_pull", payload: [
                    "status": "ok",
                    "message": "Fetched latest from origin. Remote-tracking refs are updated; working tree left as-is."
                ]))
            } catch {
                completion(Self.result(name: "git_pull", payload: [
                    "status": "error", "error": Self.message(from: error)
                ]))
            }
        }
    }

    // MARK: - Helpers

    /// Resolve + validate a `path` arg to an existing repo directory inside
    /// the workspace. Fires `completion` with an error and returns nil on any
    /// problem so callers can just `guard let`.
    private func resolveRepo(_ pathArg: Any?,
                             name: String,
                             completion: @escaping (MessageStruct) -> Void) -> URL? {
        guard let path = (pathArg as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            completion(Self.result(name: name, payload: ["status": "error", "error": "path is required"]))
            return nil
        }
        let url: URL
        do {
            url = try Workspace.shared.resolve(path)
        } catch {
            completion(Self.result(name: name, payload: ["status": "error", "error": "Bad path: \(error.localizedDescription)"]))
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            completion(Self.result(name: name, payload: [
                "status": "error",
                "error": "No repository at '\(path)'. Clone one first with git_clone."
            ]))
            return nil
        }
        return url
    }

    /// Derive a repo folder name from a URL string: last path component with
    /// any trailing `.git` removed.
    static func repoName(fromURLString raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let last = s.split(separator: "/").last else { return nil }
        var name = String(last)
        if name.hasSuffix(".git") { name.removeLast(4) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Build the URL handed to libgit2. When a token is supplied and the URL
    /// is HTTP(S), inject it as basic-auth userinfo (`https://<token>@host/…`).
    static func cloneURL(from raw: String, token: String?) -> URL? {
        guard let token, !token.isEmpty,
              var comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return URL(string: raw)
        }
        // Percent-encode so a token containing reserved chars stays intact.
        comps.user = token.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? token
        comps.password = ""
        return comps.url ?? URL(string: raw)
    }

    /// Replace a token with `***` anywhere it appears in a message we hand
    /// back to the model / user.
    private static func scrub(_ text: String, token: String?) -> String {
        guard let token, !token.isEmpty else { return text }
        return text.replacingOccurrences(of: token, with: "***")
    }

    /// SwiftGitXError carries a specific `.message`; everything else falls
    /// back to its localized description.
    private static func message(from error: Error) -> String {
        if let e = error as? SwiftGitXError { return e.message }
        return error.localizedDescription
    }

    /// Two-letter porcelain-ish code for a file's status set.
    private static func shortCode(for statuses: [StatusEntry.Status]) -> String {
        if statuses.contains(.workingTreeNew) || statuses.contains(.indexNew) { return "A " }
        if statuses.contains(.workingTreeDeleted) || statuses.contains(.indexDeleted) { return "D " }
        if statuses.contains(.workingTreeRenamed) || statuses.contains(.indexRenamed) { return "R " }
        if statuses.contains(.workingTreeModified) || statuses.contains(.indexModified) { return "M " }
        if statuses.contains(.conflicted) { return "U " }
        if statuses.contains(.ignored) { return "! " }
        return "??"
    }

    private static func result(name: String, payload: [String: Any]) -> MessageStruct {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "{\"status\":\"error\",\"error\":\"failed to serialize result\"}"
        }
        return MessageStruct(role: "function", content: json, name: name)
    }
}
