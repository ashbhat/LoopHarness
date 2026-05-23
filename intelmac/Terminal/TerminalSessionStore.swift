//
//  TerminalSessionStore.swift
//  LoopMac
//
//  Process-wide registry of TerminalSessions, keyed both by stable session
//  id and by conversation id. The conversation map enforces the spec's
//  "one session per conversation, reused on follow-up requests" rule —
//  when the model calls `start_terminal_session` from a chat that already
//  has a live session, we hand back the existing one instead of forking
//  a second shell.
//
//  Sessions live for the lifetime of the app once spawned. Exited
//  sessions stick around (isRunning = false) so the user can still open
//  the terminal window and look at history; the store evicts them lazily
//  when a new session is created in the same conversation.
//

import Foundation

extension Notification.Name {
    /// Posted any time the store mutates (new session, session exited,
    /// conversation-primary swap). The pill / windows watch this to
    /// refresh visibility — UserInfo is intentionally empty since the
    /// few observers we have just snapshot the full state on tick.
    static let terminalSessionStoreDidChange = Notification.Name("terminalSessionStoreDidChange")
}

final class TerminalSessionStore {

    static let shared = TerminalSessionStore()

    private let lock = NSLock()
    private var sessionsById: [String: TerminalSession] = [:]
    /// Conversation id → primary session id. "Primary" = the session the
    /// next tool call from this conversation should target. Re-running
    /// `start_terminal_session` in the same conversation reuses this slot;
    /// a fresh start_terminal_session with `replace:true` would bump it,
    /// but v1 just refuses to spawn a second when one exists.
    private var primaryByConversation: [String: String] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExit(_:)),
            name: .terminalSessionDidExit,
            object: nil
        )
    }

    // MARK: - Lookup

    /// Snapshot of all known sessions, running or exited, in insertion
    /// order is not preserved — callers that want a stable list should
    /// sort by `id` themselves.
    var allSessions: [TerminalSession] {
        lock.lock(); defer { lock.unlock() }
        return Array(sessionsById.values)
    }

    func session(id: String) -> TerminalSession? {
        lock.lock(); defer { lock.unlock() }
        return sessionsById[id]
    }

    /// Returns the running session attached to a conversation, if any.
    /// Falls back to nil if the conversation has no primary, or the
    /// primary has exited (the store keeps exited sessions reachable by
    /// id, but they don't count as "active for this conversation" any
    /// more — the next start spawns a fresh shell).
    func runningSession(forConversation conversationId: String) -> TerminalSession? {
        lock.lock()
        let primaryId = primaryByConversation[conversationId]
        let session = primaryId.flatMap { sessionsById[$0] }
        lock.unlock()
        if let s = session, s.isRunning { return s }
        return nil
    }

    /// Any session (running or finished) currently flagged as primary for
    /// this conversation. Used by the terminal window's "Open last session
    /// for this conversation" path so post-completion review still works.
    func primarySession(forConversation conversationId: String) -> TerminalSession? {
        lock.lock(); defer { lock.unlock() }
        return primaryByConversation[conversationId].flatMap { sessionsById[$0] }
    }

    // MARK: - Mutators

    /// Spawn (or hand back) a session for `conversationId`. If a running
    /// primary exists and the caller didn't ask to replace it, the
    /// existing session is returned untouched and `created` is false —
    /// that's what implements the "same session reused on follow-ups"
    /// rule. Returns nil if the fork failed.
    @discardableResult
    func createOrReuse(conversationId: String?,
                       workingDir: String,
                       replace: Bool = false) -> (session: TerminalSession, created: Bool)? {
        if let convId = conversationId, !replace,
           let existing = runningSession(forConversation: convId) {
            return (existing, false)
        }
        let session = TerminalSession(conversationId: conversationId,
                                       workingDir: workingDir)
        guard session.start() else { return nil }

        lock.lock()
        sessionsById[session.id] = session
        if let convId = conversationId {
            // If a previous exited session was the primary, the new one
            // takes its slot. The exited session stays in `sessionsById`
            // so a session-id-targeted read still works for review.
            primaryByConversation[convId] = session.id
        }
        lock.unlock()

        postChange()
        return (session, true)
    }

    /// Hard kill plus removal of the primary slot. Used by
    /// `stop_terminal_session` and by the terminal window's "Stop session"
    /// menu (not the "Stop Loop" button — that one leaves the shell
    /// running so the user can take over).
    func terminate(sessionId: String) {
        guard let session = session(id: sessionId) else { return }
        session.terminate()
        lock.lock()
        if let convId = session.conversationId,
           primaryByConversation[convId] == sessionId {
            primaryByConversation.removeValue(forKey: convId)
        }
        lock.unlock()
        postChange()
    }

    // MARK: - Notification fan-out

    @objc private func handleExit(_ note: Notification) {
        // Clear the primary slot once the session exits — a future
        // start_terminal_session call from the same conversation should
        // spawn a fresh shell rather than try to drive a dead one.
        guard let sessionId = note.userInfo?["sessionId"] as? String,
              let session = session(id: sessionId) else { return }
        lock.lock()
        if let convId = session.conversationId,
           primaryByConversation[convId] == sessionId {
            primaryByConversation.removeValue(forKey: convId)
        }
        lock.unlock()
        postChange()
    }

    private func postChange() {
        // Hop to main so AppKit observers (the pill, the terminal window)
        // don't have to re-dispatch themselves. NotificationCenter is
        // thread-safe but UIKit-side handlers expect main-queue delivery.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .terminalSessionStoreDidChange,
                                             object: nil)
        }
    }
}
