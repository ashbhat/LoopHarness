//
//  VisionSession.swift
//  LoopVision
//
//  The single observable model every visionOS surface binds to. It owns the
//  `VisionVoiceCoordinator` and republishes its callback stream as observable
//  state, so the orb, the floating caption, and the conversation window all
//  read one source of truth instead of each wiring its own closures.
//
//  Coordinator callbacks already arrive on the main queue (see
//  VisionVoiceCoordinator), so the @Observable mutations here are main-thread
//  and SwiftUI-safe. Like the coordinator, this is intentionally a plain
//  (non-@MainActor) class held to a main-queue discipline rather than actor
//  isolation — same rationale documented in VisionVoiceCoordinator.
//

import Foundation
import Observation

@Observable
final class VisionSession {

    // MARK: - Orb-facing state
    /// The orb's visual mode, mapped from the coordinator's pipeline state.
    private(set) var mode: OrbAvatar.Mode = .idle
    /// Mic RMS while listening / synthesized-speech RMS while speaking.
    private(set) var amplitude: Float = 0

    // MARK: - Caption-facing state
    /// Live partial transcript while the user is speaking.
    private(set) var partial: String = ""
    /// The user's finalized line for the current turn.
    private(set) var userLine: String = ""
    /// The assistant's latest reply as raw markdown (rendered formatted,
    /// spoken sanitized). Delivered before audio so the caption can reveal
    /// it as it's "generated".
    private(set) var assistantText: String = ""
    /// Non-empty while a tool runs, e.g. "Running web search…".
    private(set) var activity: String = ""

    // MARK: - Conversation window state
    /// All conversations for the split-view sidebar (newest first).
    private(set) var conversations: [SimpleConversation] = []
    /// The conversation voice turns are currently appended to.
    private(set) var currentConversationID: String?
    /// Bumps whenever the visible turn changes (new user/assistant text or a
    /// conversation switch) so the window can re-read the persisted store.
    private(set) var turnCounter: Int = 0

    private let coordinator = VisionVoiceCoordinator()

    /// Retain handles for the block-based notification observers added in
    /// `init()`. NotificationCenter's selector-based `removeObserver(self)`
    /// can't reach block observers (they're keyed by the returned token, not
    /// by `self`), so we explicitly tear them down in `deinit`.
    private var notificationObservers: [NSObjectProtocol] = []

    // MARK: - GitHub write-confirmation state
    /// When a GitHub write tool fires (merge, review, comment, create-PR,
    /// create-issue, close-issue), the skill calls our GitHubSkillHost
    /// conformance, which stores the request here. The orb (OrbVolumeView)
    /// observes this and presents a system alert. The user's tap resolves
    /// `callback`, which the skill is waiting on.
    struct PendingGitHubConfirmation: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let destructive: Bool
        let callback: (Bool) -> Void
    }
    private(set) var pendingGitHubConfirmation: PendingGitHubConfirmation?

    /// Called by the alert's button actions to resolve the pending request
    /// and clear the state. Idempotent — if the confirmation has already been
    /// resolved (e.g. by a second tool firing while one was up), the no-op
    /// branch protects us.
    func resolveGitHubConfirmation(_ approved: Bool) {
        guard let pending = pendingGitHubConfirmation else { return }
        pendingGitHubConfirmation = nil
        pending.callback(approved)
    }

    init() {
        wireCoordinator()
        currentConversationID = coordinator.currentConversationID
        reloadConversations()
        // The orb is the always-present surface in visionOS, so VisionSession
        // owns the host slot for GitHub writes. Confirmations are rendered by
        // OrbVolumeView observing `pendingGitHubConfirmation`.
        GitHubSkill.shared.host = self

        // External coding-agent completions (Cursor, Devin) post a new
        // assistant message into the originating conversation. ConversationView
        // re-reads the store whenever `turnCounter` changes, so bump it here
        // so the PR-link message appears in the transcript without needing a
        // voice turn or a manual reload.
        let bump: (Notification) -> Void = { [weak self] _ in
            self?.reloadConversations()
            self?.turnCounter &+= 1
        }
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .cursorAgentDidPostMessage, object: nil, queue: .main, using: bump))
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .devinAgentDidPostMessage, object: nil, queue: .main, using: bump))
    }

    deinit {
        for token in notificationObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Gesture entry points (forwarded from the orb's pinch)

    func pinchBegan() { coordinator.pinchBegan() }
    func pinchEnded() { coordinator.pinchEnded() }

    // MARK: - Conversation selection (from the split-view sidebar)

    /// Refresh the sidebar list from the shared (iCloud-synced) store.
    func reloadConversations() {
        conversations = SimpleConversationManager.shared
            .getAllConversations()
            .sorted { $0.updatedAt > $1.updatedAt }
        if currentConversationID == nil {
            currentConversationID = coordinator.currentConversationID
        }
    }

    /// Switch which conversation voice turns continue in, and reset the
    /// caption so stale text from the old context doesn't linger.
    func selectConversation(_ conv: SimpleConversation) {
        coordinator.useConversation(conv)
        currentConversationID = conv.id
        partial = ""; userLine = ""; assistantText = ""; activity = ""
        turnCounter &+= 1
    }

    // MARK: - Coordinator → observable state

    private func wireCoordinator() {
        coordinator.onStateChange = { [weak self] state in
            self?.mode = Self.mode(for: state)
        }
        coordinator.onAmplitude = { [weak self] amp in
            self?.amplitude = amp
        }
        coordinator.onPartial = { [weak self] text in
            self?.partial = text
        }
        coordinator.onUserTranscript = { [weak self] text in
            guard let self else { return }
            self.userLine = text
            // New turn — clear the previous reply and any tool chatter.
            self.assistantText = ""
            self.activity = ""
            self.turnCounter &+= 1
        }
        coordinator.onAssistantText = { [weak self] text in
            guard let self else { return }
            self.assistantText = text
            self.turnCounter &+= 1
        }
        coordinator.onActivity = { [weak self] label in
            self?.activity = label
        }
    }

    /// The same state→mode mapping the Mac conversation window applies.
    private static func mode(for state: VisionVoiceCoordinator.State) -> OrbAvatar.Mode {
        switch state {
        case .idle:                    return .idle
        case .recording:               return .listening
        case .transcribing, .thinking: return .thinking
        case .speaking:                return .speaking
        }
    }
}

// MARK: - GitHubSkillHost

extension VisionSession: GitHubSkillHost {
    /// Park the request on the session's observable state — OrbVolumeView
    /// reads `pendingGitHubConfirmation` and renders a SwiftUI alert. The
    /// user's tap on Confirm/Cancel calls `resolveGitHubConfirmation(_:)`
    /// which fires the stored callback the skill is awaiting.
    func githubSkill(requestConfirmation title: String,
                     detail: String,
                     destructive: Bool,
                     completion: @escaping (Bool) -> Void) {
        // If a confirmation was already in flight (shouldn't happen — the
        // model serialises tool calls — but defense in depth), resolve the
        // previous one as cancelled so the awaiting skill doesn't hang.
        if let stale = pendingGitHubConfirmation {
            pendingGitHubConfirmation = nil
            stale.callback(false)
        }
        pendingGitHubConfirmation = PendingGitHubConfirmation(
            title: title,
            detail: detail,
            destructive: destructive,
            callback: completion
        )
    }
}
