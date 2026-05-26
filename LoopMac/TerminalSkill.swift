//
//  TerminalSkill.swift
//  LoopMac
//
//  Drives the in-app PTY-backed terminal (see LoopMac/Terminal/). One
//  session per conversation by default — once a session is spawned, the
//  agent keeps using it across follow-up turns, matching the spec's
//  "for future requests after a terminal has been created in a
//  conversation, the same session should be used by the agent" rule.
//
//  Tools:
//    - start_terminal_session(working_dir?, replace?) → session_id
//    - run_terminal_command(command, session_id?) → runs in the session
//    - read_terminal_output(session_id?, since_marker?, wait_seconds?)
//        → reads new output, optionally waiting briefly for the shell to
//          flush before returning
//    - stop_terminal_session(session_id?) → kills the shell
//    - list_terminal_sessions() → snapshot of known sessions
//    - open_external_terminal(command, working_dir?, terminal_app?)
//        → legacy "spawn Terminal.app / Ghostty" path, kept around for
//          the explicit "open my real terminal" ask.
//
//  All tools are best-effort about session lookup: if no session_id is
//  passed, we resolve to the running session attached to the current
//  conversation; if none exists, the tool either spawns one
//  (run_terminal_command, by design — the model often forgets the
//  bootstrap step) or returns a structured error the model can read.
//

import AppKit
import Foundation

struct TerminalSkill {
    static let shared = TerminalSkill()

    /// True when the process is running inside the macOS App Sandbox.
    /// The PTY-backed in-app shell (`forkpty`/`execv` of the user's login
    /// shell) and the NSAppleScript automation of Terminal.app both fall
    /// over under the sandbox — the child process inherits the sandbox
    /// (so it can't access the user's files anyway) and Apple Events
    /// targeting another app require a temporary-exception entitlement
    /// that Mac App Store / TestFlight builds can't ship. We therefore
    /// hide every terminal tool from the model and refuse to handle any
    /// of them when sandboxed; the rest of the app keeps working.
    static let isSandboxed: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// Tools visible to the model. Empty array under sandbox so the
    /// agent doesn't see terminal tools it can't actually drive.
    static var tools: [[String: Any]] { isSandboxed ? [] : _tools }

    /// System-prompt fragment registered alongside the tools. Empty
    /// under sandbox to avoid confusing the model about capabilities
    /// that aren't wired up in this build.
    static var systemPromptFragment: String { isSandboxed ? "" : _systemPromptFragment }

    /// Underlying system-prompt fragment used when not sandboxed.
    private static let _systemPromptFragment: String = """
You have access to a real shell on the user's Mac via an in-app terminal session that's tied to the current conversation. The user can see a pill above the recorder bar whenever a session is alive, tap it to watch you work, and "Stop Loop" any time to take over.

**Default behavior — primary agents must delegate terminal work:**
If you are the primary agent in this conversation (the one talking to the user), DO NOT call terminal tools directly. Instead, spawn a sub-agent via `spawn_sub_agent` with `kind: "coding"` and a clear, self-contained task describing what you want the shell to accomplish. The sub-agent will drive the terminal session, tail the output, and post a summary back when it's done. Polling a long-running session inside the primary chat wastes the user's context window and slows their next turn.

Phrase the sub-agent task as a goal, not a single command — e.g. "List the files in the user's iCloud workspace and report what you find" or "Build a small FastAPI server in workspace/my-api with one /hello endpoint, install dependencies in a venv, and confirm it runs." The sub-agent will figure out which tools to call.

For coding tasks specifically: the coding sub-agent's default workflow is to delegate the actual writing to `claude` (Claude Code) inside its terminal session — much more efficient than cycling through file_write/read inside the sub-agent loop. You don't need to mention `claude` in the task; the sub-agent knows. Just describe what should be built and any constraints.

You may call terminal tools yourself ONLY when:
- You ARE a sub-agent (the kind block in your system prompt says so), or
- The user explicitly says something like "do it inline" / "don't use a sub-agent" / "just run X here".

**Tool reference (used by sub-agents and inline calls):**
- start_terminal_session(working_dir?) opens a fresh shell. **Working_dir defaults to the user's iCloud workspace** — that's where `file_write` saves, where cloned repos live, and where you should keep all generated project files. Relative working_dir values resolve against the workspace too (e.g. `working_dir: "my-project"` → workspace/my-project). Only pass an absolute path outside the workspace when the user explicitly asks for a specific location on their machine. At most one active session per conversation — running starts return the existing id.
- run_terminal_command(command, session_id?) sends one command line (no trailing newline needed). Returns output captured so far + a marker for the next read.
- read_terminal_output(session_id?, since_marker?, wait_seconds?) tails the session. Pass back the marker from the previous call to get only the new bytes. wait_seconds (max 8) lets the shell flush before you read.
- stop_terminal_session(session_id?) kills the shell. Use sparingly — sessions persist for review by default.
- open_external_terminal(command, working_dir?, terminal_app?) opens Terminal.app instead. ONLY when the user asks for their real terminal, or for a heavily interactive TUI the in-app renderer can't handle.

**SSH support — including exe.dev:**
The in-app terminal has a real PTY, so SSH sessions work natively. Host-key acceptance for exe.dev (and *.exe.xyz VMs) is handled automatically — no manual "yes" prompt.
- `ssh exe.dev` connects to the exe.dev lobby, an interactive REPL for VM management (ls, new, rm, etc.). It is NOT a regular shell — scp/sftp don't work against it.
- `ssh <vm>.exe.xyz` connects to a specific VM and gives you a full shell (scp, sftp, port forwarding all work).
- After running an SSH command, use read_terminal_output with wait_seconds=4..6 — SSH connection setup takes longer than a local command.
- The session stays interactive: send follow-up input via run_terminal_command (e.g. `ls` inside the exe.dev lobby or shell commands inside a VM).

Workflow tips for the sub-agent (or inline use):
- Use wait_seconds=2..4 the first time you read after firing a command — shells flush prompts asynchronously.
- Don't chain destructive commands (rm -rf, sudo, anything outside the working dir) without an explicit user instruction in this turn.
"""

    private static let _tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "start_terminal_session",
                "description": "Open an in-app terminal session for the current conversation. Returns the existing session id if one is already running (use replace=true to force a fresh shell). The user sees a pill above the recorder bar while the session is alive and can tap it to watch or take over.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "working_dir": [
                            "type": "string",
                            "description": "Absolute path to start the shell in. Defaults to the user's home directory."
                        ],
                        "replace": [
                            "type": "boolean",
                            "description": "Set to true to kill any existing session for this conversation and start a fresh one. Defaults to false."
                        ]
                    ],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "run_terminal_command",
                "description": "Send a command line into the in-app terminal session. If no session is specified or running for this conversation, one is started automatically. Returns the output captured up to the moment the call returns, plus a marker you can pass to read_terminal_output to continue tailing.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "The shell command to run, exactly as it would be typed at a prompt (e.g. \"ls -la\", \"git status\", \"claude 'fix the failing test'\"). Don't include a trailing newline — the tool adds the Enter for you."
                        ],
                        "session_id": [
                            "type": "string",
                            "description": "Target a specific session by id. Omit to use (or auto-spawn) the conversation's current session."
                        ],
                        "working_dir": [
                            "type": "string",
                            "description": "Absolute path to start a fresh shell in when no session exists yet. Ignored if a session is already running."
                        ]
                    ],
                    "required": ["command"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "read_terminal_output",
                "description": "Read output from an in-app terminal session. Returns the bytes appended since `since_marker`, plus a fresh marker for the next call. Optionally waits up to `wait_seconds` for the shell to produce more output before returning.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "session_id": [
                            "type": "string",
                            "description": "Target session id. Omit to use the conversation's current session."
                        ],
                        "since_marker": [
                            "type": "integer",
                            "description": "Byte offset returned by a previous call. Omit (or pass 0) to read the whole buffer."
                        ],
                        "wait_seconds": [
                            "type": "number",
                            "description": "Seconds to wait for fresh output before returning. Capped at 8. Defaults to 0 (return immediately)."
                        ]
                    ],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "stop_terminal_session",
                "description": "Terminate an in-app terminal session. The terminal window stays open for review; only the running shell is killed. Use sparingly — sessions are supposed to persist for the user to come back to.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "session_id": [
                            "type": "string",
                            "description": "Target session id. Omit to stop the conversation's current session."
                        ]
                    ],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_terminal_sessions",
                "description": "List all known terminal sessions (running and recently exited). Useful for picking up a previously-orphaned session by id.",
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "open_external_terminal",
                "description": "Open the user's real terminal app (Terminal.app by default) and run a command there. Use only when the user explicitly asks for their real terminal, or for an interactive TUI program the in-app terminal can't render cleanly.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "The shell command to execute, exactly as it would be typed at a prompt."
                        ],
                        "working_dir": [
                            "type": "string",
                            "description": "Absolute path to cd into. Defaults to the user's home directory."
                        ],
                        "terminal_app": [
                            "type": "string",
                            "description": "Which terminal to use. Defaults to \"Terminal\". Pass \"Ghostty\" only if the user asks for it.",
                            "enum": ["Ghostty", "Terminal"]
                        ]
                    ],
                    "required": ["command"]
                ]
            ]
        ]
    ]

    private static let toolNames: Set<String> = [
        "start_terminal_session",
        "run_terminal_command",
        "read_terminal_output",
        "stop_terminal_session",
        "list_terminal_sessions",
        "open_external_terminal",
        // Legacy alias — the older "start a Claude Code session in
        // Terminal.app" tool. Kept handled so old scheduled-job payloads
        // don't break, but the system prompt no longer advertises it.
        "start_claude_code_session",
    ]

    func handles(functionName: String) -> Bool {
        if TerminalSkill.isSandboxed { return false }
        return TerminalSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "start_terminal_session":
            return "opening terminal"
        case "run_terminal_command":
            if let cmd = call.arguments["command"] as? String, !cmd.isEmpty {
                if TerminalSkill.isSSHCommand(cmd) {
                    if TerminalSkill.isExeDevSSH(cmd) {
                        return "connecting to exe.dev"
                    }
                    return "opening SSH connection"
                }
                let short = cmd.count > 40 ? String(cmd.prefix(40)) + "…" : cmd
                return "running `\(short)`"
            }
            return "running command"
        case "read_terminal_output":
            return "reading terminal output"
        case "stop_terminal_session":
            return "stopping terminal"
        case "list_terminal_sessions":
            return "listing terminal sessions"
        case "open_external_terminal":
            return "opening Terminal.app"
        case "start_claude_code_session":
            return "starting Claude Code session"
        default:
            return nil
        }
    }

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        // Prefer the call's stamped conversation id (set by the
        // dispatching coordinator) over the global currentConversation,
        // which can drift on multi-tab Mac if the user switches tabs
        // between the model emitting the tool call and the skill
        // handling it.
        let convId = functionCall.conversationId ?? TerminalSkill.currentConversationId()
        switch functionCall.name {
        case "start_terminal_session":
            handleStart(args: functionCall.arguments, conversationId: convId, name: functionCall.name, completion: completion)
        case "run_terminal_command":
            handleRunInSession(args: functionCall.arguments, conversationId: convId, name: functionCall.name, completion: completion)
        case "read_terminal_output":
            handleRead(args: functionCall.arguments, conversationId: convId, name: functionCall.name, completion: completion)
        case "stop_terminal_session":
            handleStop(args: functionCall.arguments, conversationId: convId, name: functionCall.name, completion: completion)
        case "list_terminal_sessions":
            handleList(name: functionCall.name, completion: completion)
        case "open_external_terminal":
            handleExternal(args: functionCall.arguments, name: functionCall.name, completion: completion)
        case "start_claude_code_session":
            handleLegacyClaudeCode(args: functionCall.arguments, name: functionCall.name, completion: completion)
        default:
            completion(MessageStruct(role: "function",
                                     content: "Unknown function \(functionCall.name)",
                                     name: functionCall.name))
        }
    }

    // MARK: - start_terminal_session

    private func handleStart(args: [String: Any],
                             conversationId: String?,
                             name: String,
                             completion: @escaping (MessageStruct) -> Void) {
        let workingDir = TerminalSkill.resolveWorkingDir(args["working_dir"] as? String)
        let replace = (args["replace"] as? Bool) ?? false

        DispatchQueue.main.async {
            guard let result = TerminalSessionStore.shared.createOrReuse(
                conversationId: conversationId,
                workingDir: workingDir,
                replace: replace
            ) else {
                completion(self.errorResult(name: name,
                                            message: "Failed to spawn shell at \(workingDir)"))
                return
            }
            let session = result.session
            let payload: [String: Any] = [
                "status": "ok",
                "session_id": session.id,
                "working_dir": session.workingDir,
                "created": result.created,
                "conversation_id": conversationId ?? NSNull(),
                "marker": session.displayOutput.utf8.count,
                "hint": result.created
                    ? "New shell started. Use run_terminal_command with this session_id to send a command."
                    : "Reused the conversation's existing session.",
            ]
            completion(self.jsonResult(name: name, payload: payload))
        }
    }

    // MARK: - run_terminal_command

    private func handleRunInSession(args: [String: Any],
                                    conversationId: String?,
                                    name: String,
                                    completion: @escaping (MessageStruct) -> Void) {
        guard let command = (args["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            completion(errorResult(name: name, message: "Missing or empty 'command' argument."))
            return
        }
        let explicitSessionId = args["session_id"] as? String
        let workingDir = TerminalSkill.resolveWorkingDir(args["working_dir"] as? String)

        DispatchQueue.main.async {
            let session: TerminalSession?
            var created = false
            if let sid = explicitSessionId,
               let existing = TerminalSessionStore.shared.session(id: sid) {
                session = existing
            } else if let convId = conversationId,
                      let existing = TerminalSessionStore.shared.runningSession(forConversation: convId) {
                session = existing
            } else if let result = TerminalSessionStore.shared.createOrReuse(
                        conversationId: conversationId,
                        workingDir: workingDir,
                        replace: false) {
                session = result.session
                created = result.created
            } else {
                session = nil
            }
            guard let session = session else {
                completion(self.errorResult(name: name,
                                            message: "No session available and couldn't spawn a new shell."))
                return
            }
            guard session.isRunning else {
                completion(self.errorResult(name: name,
                                            message: "Session \(session.id) has exited. Start a new one with start_terminal_session."))
                return
            }
            // Snapshot the buffer offset before we fire the command so the
            // returned "output" only contains bytes that came back as a
            // result of this command, not stuff that was already on the
            // scrollback. The same value is returned as the next-read
            // marker.
            let markerBefore = session.displayOutput.utf8.count

            // SSH commands that target exe.dev or *.exe.xyz need the host-
            // key auto-accepted before the real connection attempt,
            // otherwise the interactive "Are you sure…" prompt hangs
            // inside the agent loop with no human to type "yes". We
            // provision a minimal ~/.ssh/config stanza once (idempotent)
            // and give SSH commands a longer initial wait because TCP
            // handshake + key exchange is slower than a local shell built-in.
            let isSSH = TerminalSkill.isSSHCommand(command)
            if isSSH {
                TerminalSkill.ensureExeDevSSHConfig()
            }

            guard session.runCommand(command) else {
                completion(self.errorResult(name: name,
                                            content: "Failed to write to session \(session.id)."))
                return
            }
            // Give the shell a moment to start producing output. SSH
            // commands get 3.5s (connection setup is slower); everything
            // else keeps 1.2s to avoid stalling the model loop.
            let waitTime: Double = isSSH ? 3.5 : 1.2
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + waitTime) {
                let (delta, marker) = session.read(since: markerBefore)
                var hint = "If the output looks incomplete, call read_terminal_output with this marker and wait_seconds=3 to grab the rest."
                if isSSH {
                    hint = "SSH session started. The connection is interactive — send follow-up commands via run_terminal_command. Use read_terminal_output with wait_seconds=4..6 to tail output."
                }
                let payload: [String: Any] = [
                    "status": "ok",
                    "session_id": session.id,
                    "created": created,
                    "command": command,
                    "output": TerminalSkill.trimForModel(delta),
                    "marker": marker,
                    "running": session.isRunning,
                    "hint": hint,
                ]
                completion(self.jsonResult(name: name, payload: payload))
            }
        }
    }

    // MARK: - read_terminal_output

    private func handleRead(args: [String: Any],
                            conversationId: String?,
                            name: String,
                            completion: @escaping (MessageStruct) -> Void) {
        let explicitSessionId = args["session_id"] as? String
        let since = (args["since_marker"] as? Int)
            ?? (args["since_marker"] as? NSNumber)?.intValue
        let waitSeconds = TerminalSkill.clamp(
            (args["wait_seconds"] as? Double)
                ?? (args["wait_seconds"] as? NSNumber)?.doubleValue
                ?? 0,
            min: 0, max: 8
        )

        DispatchQueue.main.async {
            let session: TerminalSession?
            if let sid = explicitSessionId {
                session = TerminalSessionStore.shared.session(id: sid)
            } else if let convId = conversationId {
                // Allow reading from an exited session — the user may want
                // to ask the model about the tail of a session that just
                // finished, and we keep those reachable by id.
                session = TerminalSessionStore.shared.primarySession(forConversation: convId)
            } else {
                session = nil
            }
            guard let session = session else {
                completion(self.errorResult(name: name,
                                            message: "No matching session. Call list_terminal_sessions to see what's available."))
                return
            }

            let respond = {
                let (delta, marker) = session.read(since: since)
                let payload: [String: Any] = [
                    "status": "ok",
                    "session_id": session.id,
                    "output": TerminalSkill.trimForModel(delta),
                    "marker": marker,
                    "running": session.isRunning,
                    "exit_code": session.exitCode as Any? ?? NSNull(),
                ]
                completion(self.jsonResult(name: name, payload: payload))
            }
            if waitSeconds <= 0 {
                respond()
            } else {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + waitSeconds) {
                    respond()
                }
            }
        }
    }

    // MARK: - stop_terminal_session

    private func handleStop(args: [String: Any],
                            conversationId: String?,
                            name: String,
                            completion: @escaping (MessageStruct) -> Void) {
        let explicitSessionId = args["session_id"] as? String
        DispatchQueue.main.async {
            let session: TerminalSession?
            if let sid = explicitSessionId {
                session = TerminalSessionStore.shared.session(id: sid)
            } else if let convId = conversationId {
                session = TerminalSessionStore.shared.primarySession(forConversation: convId)
            } else {
                session = nil
            }
            guard let session = session else {
                completion(self.errorResult(name: name, message: "No session to stop."))
                return
            }
            TerminalSessionStore.shared.terminate(sessionId: session.id)
            let payload: [String: Any] = [
                "status": "ok",
                "session_id": session.id,
                "message": "Session terminated. The terminal window is still open for review.",
            ]
            completion(self.jsonResult(name: name, payload: payload))
        }
    }

    // MARK: - list_terminal_sessions

    private func handleList(name: String,
                            completion: @escaping (MessageStruct) -> Void) {
        DispatchQueue.main.async {
            let sessions = TerminalSessionStore.shared.allSessions
            let items: [[String: Any]] = sessions.map { s in
                [
                    "session_id": s.id,
                    "conversation_id": s.conversationId ?? NSNull(),
                    "working_dir": s.workingDir,
                    "running": s.isRunning,
                    "exit_code": s.exitCode as Any? ?? NSNull(),
                    "marker": s.displayOutput.utf8.count,
                ]
            }
            let payload: [String: Any] = [
                "status": "ok",
                "sessions": items,
            ]
            completion(self.jsonResult(name: name, payload: payload))
        }
    }

    // MARK: - open_external_terminal (legacy)

    private func handleExternal(args: [String: Any],
                                name: String,
                                completion: @escaping (MessageStruct) -> Void) {
        guard let command = (args["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            completion(errorResult(name: name, message: "Missing or empty 'command' argument."))
            return
        }
        let workingDir = TerminalSkill.resolveWorkingDir(args["working_dir"] as? String)
        let requestedApp = (args["terminal_app"] as? String) ?? ""
        let app = TerminalSkill.resolveTerminalApp(preferred: requestedApp)
        executeExternal(command: command,
                        workingDir: workingDir,
                        app: app,
                        functionName: name,
                        completion: completion)
    }

    private func handleLegacyClaudeCode(args: [String: Any],
                                        name: String,
                                        completion: @escaping (MessageStruct) -> Void) {
        guard let repo = (args["repo_path"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !repo.isEmpty else {
            completion(errorResult(name: name, message: "Missing 'repo_path' argument."))
            return
        }
        let workingDir = TerminalSkill.resolveWorkingDir(repo)
        let prompt = (args["initial_prompt"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command: String
        if prompt.isEmpty {
            command = "claude"
        } else {
            let escaped = prompt.replacingOccurrences(of: "'", with: "'\\''")
            command = "claude '\(escaped)'"
        }
        let app = TerminalSkill.resolveTerminalApp(preferred: "")
        executeExternal(command: command,
                        workingDir: workingDir,
                        app: app,
                        functionName: name,
                        completion: completion)
    }

    private enum TerminalApp: String { case ghostty = "Ghostty", terminal = "Terminal" }

    private func executeExternal(command: String,
                                 workingDir: String,
                                 app: TerminalApp,
                                 functionName: String,
                                 completion: @escaping (MessageStruct) -> Void) {
        DispatchQueue.main.async {
            let approved = TerminalSkill.confirmExternal(command: command,
                                                          workingDir: workingDir,
                                                          app: app)
            guard approved else {
                completion(MessageStruct(
                    role: "function",
                    content: "User declined to run `\(command)`. Ask what they'd like to do instead — don't retry the same command.",
                    name: functionName))
                return
            }

            let result: Result<Void, Error>
            switch app {
            case .ghostty:
                result = TerminalSkill.launchGhostty(command: command, workingDir: workingDir)
            case .terminal:
                result = TerminalSkill.launchTerminal(command: command, workingDir: workingDir)
            }

            switch result {
            case .success:
                let msg = "Started in \(app.rawValue): `\(command)` (working dir: \(workingDir)). The terminal window is open and the user can take over the session there."
                completion(MessageStruct(role: "function", content: msg, name: functionName))
            case .failure(let error):
                let msg = "Failed to launch \(app.rawValue): \(error.localizedDescription)"
                completion(MessageStruct(role: "function", content: msg, name: functionName))
            }
        }
    }

    // MARK: - External launch helpers (carried over from the old skill)

    private static func confirmExternal(command: String,
                                        workingDir: String,
                                        app: TerminalApp) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Run command in \(app.rawValue)?"
        alert.informativeText = """
        \(command)

        Working directory: \(workingDir)
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func launchGhostty(command: String, workingDir: String) -> Result<Void, Error> {
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = """
        cd \(shellQuote(workingDir)) 2>/dev/null
        \(command)
        exec \(shellQuote(userShell)) -l
        """
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = [
            "-na", "Ghostty",
            "--args",
            "-e", "/bin/bash", "-c", script
        ]
        do {
            try process.run()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private static func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func launchTerminal(command: String, workingDir: String) -> Result<Void, Error> {
        let escapedDir = workingDir.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedCmd = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "cd \\"\(escapedDir)\\" && \(escapedCmd)"
        end tell
        """
        var errorInfo: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&errorInfo)
            if let info = errorInfo,
               let msg = info[NSAppleScript.errorMessage] as? String {
                return .failure(NSError(domain: "TerminalSkill",
                                        code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: msg]))
            }
            return .success(())
        }
        return .failure(NSError(domain: "TerminalSkill",
                                code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Could not compile AppleScript"]))
    }

    // MARK: - SSH helpers

    /// Returns true when the command line looks like an SSH invocation.
    /// Covers `ssh exe.dev`, `ssh user@host`, `ssh -i key host`, etc.
    static func isSSHCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fast path: starts with "ssh " or is exactly "ssh"
        if trimmed == "ssh" || trimmed.hasPrefix("ssh ") {
            return true
        }
        // Pipe / chain: `… | ssh …`, `… && ssh …`, `… ; ssh …`
        let operators = ["|", "&&", ";"]
        for op in operators {
            if let range = trimmed.range(of: "\(op) ssh ") ?? trimmed.range(of: "\(op) ssh") {
                _ = range // suppress unused warning
                return true
            }
        }
        return false
    }

    /// Returns true when the SSH command targets exe.dev or *.exe.xyz.
    static func isExeDevSSH(_ command: String) -> Bool {
        let lower = command.lowercased()
        return lower.contains("exe.dev") || lower.contains(".exe.xyz")
    }

    /// Idempotent: ensures `~/.ssh/config` has a stanza that auto-accepts
    /// new host keys for exe.dev and *.exe.xyz. Without this, the first
    /// connection from a fresh machine prompts "Are you sure you want to
    /// continue connecting (yes/no/[fingerprint])?", which blocks inside
    /// the agent loop because no human is typing "yes".
    ///
    /// The stanza uses `StrictHostKeyChecking accept-new` rather than `no`
    /// so known_hosts TOFU still works — a changed key still raises an
    /// error, protecting against MITM after the initial connection.
    static func ensureExeDevSSHConfig() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sshDir = (home as NSString).appendingPathComponent(".ssh")
        let configPath = (sshDir as NSString).appendingPathComponent("config")
        let fm = FileManager.default

        // Ensure ~/.ssh exists with correct permissions.
        if !fm.fileExists(atPath: sshDir) {
            try? fm.createDirectory(atPath: sshDir,
                                    withIntermediateDirectories: true)
            chmod(sshDir, 0o700)
        }

        let marker = "# Loop-managed: exe.dev host-key auto-accept"
        let stanza = """
        \n\(marker)
        Host exe.dev *.exe.xyz
            StrictHostKeyChecking accept-new
            UserKnownHostsFile ~/.ssh/known_hosts
        """

        if fm.fileExists(atPath: configPath),
           let existing = try? String(contentsOfFile: configPath, encoding: .utf8) {
            if existing.contains(marker) { return }
            // Append to existing config.
            try? (existing + stanza).write(toFile: configPath,
                                           atomically: true,
                                           encoding: .utf8)
        } else {
            // Create new config.
            try? stanza.write(toFile: configPath,
                              atomically: true,
                              encoding: .utf8)
            chmod(configPath, 0o600)
        }
    }

    // MARK: - Shared helpers

    private static func resolveWorkingDir(_ raw: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Default landing zone is the user's iCloud workspace — that's
        // where file_write / file_edit put files, where cloned repos
        // live, and where the user expects code work to happen. Falling
        // back to $HOME instead would scatter generated files across
        // the user's machine in places they'd never look.
        let workspaceRoot = Workspace.shared.rootURL.path

        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return workspaceRoot
        }
        if raw == "~" { return home }
        if raw.hasPrefix("~/") {
            return home + String(raw.dropFirst(1))
        }
        // Relative paths are interpreted against the workspace, not the
        // home dir — so "my-project/.venv/bin/activate" works without
        // the agent having to know the absolute iCloud path.
        if !raw.hasPrefix("/") {
            return (workspaceRoot as NSString).appendingPathComponent(raw)
        }
        return raw
    }

    private static func resolveTerminalApp(preferred: String) -> TerminalApp {
        if preferred.caseInsensitiveCompare("Ghostty") == .orderedSame {
            return ghosttyInstalled() ? .ghostty : .terminal
        }
        return .terminal
    }

    private static func ghosttyInstalled() -> Bool {
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil
            || FileManager.default.fileExists(atPath: "/Applications/Ghostty.app")
    }

    /// Cap on how much terminal output we feed back to the model in a
    /// single result. Most tools want < 16k tokens of structured context,
    /// and pty output bloats fast — 16KB of bytes is a reasonable ceiling
    /// that fits a several-hundred-line `ls`, a typical `git status`, or a
    /// few seconds of compiler chatter. The tool result includes the
    /// marker, so the model can read more in follow-up calls if needed.
    private static let maxOutputBytes = 16_384

    /// If the output exceeds the cap, trim from the start (the most useful
    /// bytes are usually the tail — fresh prompt, error message, exit
    /// banner) and prepend an explicit "[…truncated…]" marker so the model
    /// knows there's more to fetch.
    static func trimForModel(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > maxOutputBytes else { return text }
        let tail = bytes.suffix(maxOutputBytes)
        let tailString = String(decoding: tail, as: UTF8.self)
        return "[…truncated \(bytes.count - maxOutputBytes) earlier bytes; call read_terminal_output with a smaller since_marker to fetch them…]\n" + tailString
    }

    private static func clamp(_ value: Double, min lo: Double, max hi: Double) -> Double {
        return max(lo, min(hi, value))
    }

    /// Best-effort lookup of the conversation that's driving the current
    /// turn. SimpleConversationManager's "currentConversation" follows
    /// the active tab on Mac, which is the right answer for tool-call
    /// routing: the call originated from the conversation the user is
    /// looking at.
    static func currentConversationId() -> String? {
        return SimpleConversationManager.shared.currentConversation?.id
    }

    // MARK: - Result helpers

    private func jsonResult(name: String, payload: [String: Any]) -> MessageStruct {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let s = String(data: data, encoding: .utf8) {
            json = s
        } else {
            json = "{\"status\":\"error\",\"error\":\"Failed to serialize tool result\"}"
        }
        return MessageStruct(role: "function", content: json, name: name)
    }

    private func errorResult(name: String, message: String) -> MessageStruct {
        return jsonResult(name: name, payload: [
            "status": "error",
            "error": message,
        ])
    }

    /// Back-compat with one accidental call-site that used `content:` —
    /// keep it routed through errorResult.
    private func errorResult(name: String, content: String) -> MessageStruct {
        return errorResult(name: name, message: content)
    }
}
