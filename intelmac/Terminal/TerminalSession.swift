//
//  TerminalSession.swift
//  LoopMac
//
//  A single long-running shell, backed by a pseudoterminal so the child
//  process has a real TTY (job control works, prompts render correctly,
//  programs like `claude` that detect a TTY take their interactive path).
//
//  One session = one shell. Sessions live for the lifetime of the app once
//  spawned — the spec wants them to persist after the task is done so the
//  user can come back and review or continue. Killing is explicit, either
//  via `terminate()` from the skill or the "Stop" button in the terminal
//  window.
//
//  The output buffer holds raw bytes as they arrive (after a light ANSI
//  scrub so the visible scrollback isn't full of escape codes). Tools read
//  from it via offset markers so the model can ask "what's new since the
//  last time I checked" without dragging the whole transcript through the
//  context window each turn.
//

import AppKit
import Darwin
import Foundation

/// Notification posted whenever a session's output buffer grows or its
/// running state changes. UserInfo carries the session id so observers
/// (terminal window, pill) can filter cheaply.
extension Notification.Name {
    static let terminalSessionDidUpdate = Notification.Name("terminalSessionDidUpdate")
    static let terminalSessionDidExit = Notification.Name("terminalSessionDidExit")
}

final class TerminalSession {

    /// Stable per-app-run identifier. Tools refer to sessions by this id;
    /// the store's conversation→session map also keys on it.
    let id: String
    /// Conversation this session belongs to (captured at spawn time so the
    /// pill knows whether to show for the currently-visible conversation).
    /// Nil for sessions created outside a conversation context — those still
    /// work, the pill just won't auto-attach.
    let conversationId: String?
    /// Absolute path the shell starts in. Stored for the UI title and for
    /// the "Working dir: …" line in the confirmation surface.
    let workingDir: String

    /// VT100-ish screen buffer for what should be DISPLAYED. Re-rendered
    /// on every output update; rendering reflects \r overwrites, erase
    /// sequences, and cursor motion, so spinners and progress bars
    /// redraw in place instead of stacking. Mutations happen on the
    /// session's read queue and are serialized via `bufferLock`.
    private let screen = TerminalScreenBuffer()

    /// Snapshot of the current screen for the in-app terminal window.
    /// Callers get a fresh String each access — the underlying buffer
    /// can shrink (erase / overwrite) so they should re-read on every
    /// `terminalSessionDidUpdate` notification rather than diffing.
    var displayOutput: String {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return screen.render()
    }

    /// Running flag. Goes false once the shell exits (user typed `exit`,
    /// we sent SIGTERM, or the process crashed). Sessions stay in the
    /// store after exit so the user can still open the terminal window and
    /// review what happened — see the spec: "should persist after the task
    /// is done."
    private(set) var isRunning: Bool = false

    /// Posted with the exit notification once the child reaps.
    private(set) var exitCode: Int32?

    // MARK: - Private state

    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    /// Watches the child for termination. Posix process source fires on
    /// `.exit`, which is exactly when we want to flip `isRunning` to false
    /// and reap the zombie.
    private var procSource: DispatchSourceProcess?
    private let bufferLock = NSLock()

    // MARK: - Init

    /// Designated init. Doesn't start the shell — call `start()` after the
    /// session is stashed in the store so the store's lookup is non-racy.
    init(id: String = UUID().uuidString,
         conversationId: String?,
         workingDir: String) {
        self.id = id
        self.conversationId = conversationId
        self.workingDir = workingDir
    }

    deinit {
        // Defensive cleanup. The store owns sessions for the app lifetime,
        // so deinit usually only fires during teardown.
        terminate()
    }

    // MARK: - Lifecycle

    /// Spawns the user's login shell inside a fresh pty. Returns false if
    /// the fork failed (filesystem out of fds, sandbox refusal, etc.).
    @discardableResult
    func start() -> Bool {
        guard masterFD == -1 else { return true }

        // 80×24 is the conventional "fits a real terminal window" default;
        // resizing later (TIOCSWINSZ) is a follow-up if the in-app window
        // ever lets the user widen scroll.
        var win = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        var amaster: Int32 = 0
        let pid = forkpty(&amaster, nil, nil, &win)
        if pid < 0 { return false }

        if pid == 0 {
            // Child. forkpty has already set up the controlling tty, so
            // we just need to chdir, fix up env, and exec the shell.
            _ = workingDir.withCString { Darwin.chdir($0) }

            // A GUI app's child inherits an environment with no TERM
            // set, which makes zsh skip prompt rendering and various
            // CLI tools (`less`, `git`, `claude`) misbehave. Set a
            // conservative default — xterm-256color is what every
            // modern terminal emulator advertises and it gets us full
            // color support with zero false signals about exotic
            // capabilities. LANG/LC_ALL ensure unicode renders cleanly
            // through the pty.
            _ = "xterm-256color".withCString { Darwin.setenv("TERM", $0, 1) }
            _ = "en_US.UTF-8".withCString { Darwin.setenv("LANG", $0, 1) }
            _ = "en_US.UTF-8".withCString { Darwin.setenv("LC_ALL", $0, 1) }

            // Login shell so the user's ~/.zprofile / PATH tweaks apply —
            // matters for tools installed under /opt/homebrew/bin like
            // `claude`. arg0 is conventionally "-zsh" / "-bash" to signal
            // login mode.
            let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let shellName = (shellPath as NSString).lastPathComponent
            let arg0 = "-\(shellName)"

            // execv wants `[char* const argv[]]`. We strdup so the lifetime
            // outlives the Swift bridging (the parent process never sees
            // these allocations, so leaking them on exec is fine). The
            // explicit `-i` forces interactive mode even when the shell
            // can't otherwise tell — belt and suspenders alongside the
            // controlling tty forkpty just set up.
            let arg0C = strdup(arg0)
            let interactiveC = strdup("-i")
            var argv: [UnsafeMutablePointer<CChar>?] = [arg0C, interactiveC, nil]
            shellPath.withCString { shellPathC in
                _ = execv(shellPathC, &argv)
            }
            // If we get here, exec failed.
            _exit(127)
        }

        masterFD = amaster
        childPID = pid
        isRunning = true

        // Make the master fd non-blocking so the read source can drain
        // every available byte each fire without us guessing how much is
        // pending. The pty also occasionally yields EAGAIN under load —
        // a non-blocking fd lets us handle that cleanly.
        let flags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        // Read source: fires on the dispatch queue every time the kernel
        // has bytes for us. We drain until EAGAIN, then yield.
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD,
                                                    queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            self?.drainPendingOutput()
        }
        source.setCancelHandler { [masterFD] in
            // Closing the master fd is what eventually delivers EOF to the
            // shell, so we only close it during full teardown — not when
            // the read source is just being replaced. Guard so a re-cancel
            // doesn't double-close.
            if masterFD >= 0 { _ = close(masterFD) }
        }
        readSource = source
        source.resume()

        // Process source: fires when the child exits, so we can flip the
        // running flag, reap, and post the exit notification. Without this
        // a session would still read as "running" after `exit`.
        let proc = DispatchSource.makeProcessSource(identifier: pid,
                                                     eventMask: .exit,
                                                     queue: DispatchQueue.main)
        proc.setEventHandler { [weak self] in
            self?.handleChildExit()
        }
        procSource = proc
        proc.resume()

        return true
    }

    /// Send raw bytes to the shell's stdin (which is the pty master from
    /// our side). Used by `runCommand(_:)` to inject a command line, and
    /// by the terminal window's input field for the take-over path.
    @discardableResult
    func write(_ text: String) -> Bool {
        guard masterFD != -1, isRunning else { return false }
        let bytes = Array(text.utf8)
        var offset = 0
        return bytes.withUnsafeBufferPointer { buf -> Bool in
            while offset < bytes.count {
                let n = Darwin.write(masterFD, buf.baseAddress! + offset, bytes.count - offset)
                if n < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    /// Convenience: write `command` followed by a single `\r`. We use \r
    /// (not \n) because that's what a real terminal sends on Enter — the
    /// line discipline turns it into the newline the shell expects.
    @discardableResult
    func runCommand(_ command: String) -> Bool {
        return write(command + "\r")
    }

    /// Read raw output (ANSI-stripped, but with overwrites and cursor
    /// motion preserved as plain bytes) since `marker`. Pass nil to
    /// read everything. The byte-offset marker is honest because
    /// `appendedRaw` only ever grows — overwrites and erases only
    /// affect the display buffer.
    ///
    /// Note: for spinner-heavy commands the raw transcript will be
    /// noisier than what the user sees in the terminal window, since
    /// each frame appends bytes here. Agents that hit that pattern
    /// should keep a tight `since_marker` cadence and report summaries.
    func read(since marker: Int? = nil) -> (text: String, marker: Int) {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return screen.readAppendedRaw(since: marker)
    }

    /// Cached byte length of the appended raw buffer. Used by callers
    /// that want a "no new output past this point" marker without
    /// pulling the full string.
    var appendedRawByteCount: Int {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return screen.appendedRawByteCount
    }

    /// Polite shutdown. Sends SIGHUP first (shells usually clean up and
    /// exit cleanly on hup), and if the child is still around after a
    /// short grace period we follow up with SIGKILL.
    func terminate() {
        guard childPID > 0 else { return }
        let pid = childPID
        kill(pid, SIGHUP)
        // Don't block: the process source's exit handler will flip
        // isRunning and post the notification when the shell really exits.
        // Schedule a SIGKILL fallback in case the shell ignored HUP.
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    /// Hard cancel — used by the terminal window's "Stop Loop" button.
    /// Same as `terminate()` from the session's point of view; the higher
    /// layers interpret it as "stop the agent's automation, leave the
    /// shell alive for the user to take over." That's handled in the
    /// skill / window controller; the session itself doesn't track agent
    /// vs user state.
    func stop() { terminate() }

    // MARK: - Private

    private func drainPendingOutput() {
        // 4KB is a typical pty read chunk; larger reads would just block
        // on EAGAIN sooner without helping throughput.
        var buf = [UInt8](repeating: 0, count: 4096)
        var appended = ""
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                return Darwin.read(masterFD, ptr.baseAddress!, ptr.count)
            }
            if n > 0 {
                let chunk = String(decoding: buf[0..<n], as: UTF8.self)
                appended += chunk
                continue
            }
            if n == 0 {
                // EOF on the master — shell exited and the pty is closed.
                // The process source will follow up with the exit event;
                // we just stop draining here.
                break
            }
            // n < 0: errno tells us why.
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            if errno == EINTR { continue }
            // EIO on the master is the normal "child closed its end" signal
            // on Darwin. Treat as EOF.
            break
        }
        guard !appended.isEmpty else { return }
        let sessionId = self.id
        bufferLock.lock()
        screen.write(appended)
        bufferLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .terminalSessionDidUpdate,
                object: nil,
                userInfo: ["sessionId": sessionId]
            )
        }
    }

    private func handleChildExit() {
        guard isRunning else { return }
        isRunning = false
        // waitpid reaps the zombie so we don't leak a process table entry.
        // WNOHANG because the process source already told us the child
        // exited; this just collects the status.
        var status: Int32 = 0
        _ = waitpid(childPID, &status, WNOHANG)
        if (status & 0x7f) == 0 {
            exitCode = (status >> 8) & 0xff
        } else {
            // Signal-killed: report as 128 + signo, matching shell conventions.
            exitCode = 128 + (status & 0x7f)
        }
        readSource?.cancel()
        readSource = nil
        procSource = nil
        masterFD = -1
        childPID = -1
        let sessionId = self.id
        NotificationCenter.default.post(
            name: .terminalSessionDidExit,
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }

    // ANSI handling lives in TerminalScreenBuffer now — both display
    // rendering and the raw byte stream go through it. The old
    // stateless scrubber was removed when the screen buffer landed.
}
