//
//  MainVC.swift
//  Loop
//
//  Created by Ash Bhat on 12/30/25.
//
import UIKit

class MainVC: MessagingVC {

    /// Compact pixel-art avatar that lives in the navigation bar — vertically
    /// centered with the rest of the bar items.
    private(set) var avatar: AvatarView?

    /// Large pixel-art avatar shown on the empty-state hero (the slot the old
    /// LifeView used to occupy). Fades out on first message sent and stays
    /// hidden while a conversation is live; the nav-bar avatar is the
    /// running indicator from that point on.
    private(set) var heroAvatar: AvatarView?

    /// Tracks the previous empty/non-empty state of the conversation so
    /// `refreshAvatarVisibility` only runs the 3D pop on actual transitions.
    /// The initial viewDidLoad call passes `animated: false` regardless;
    /// later calls run the pop when this flips.
    private var lastVisibilityEmpty: Bool?

    /// Retained transitioning delegate that drives the 3D pop between the
    /// nav-bar avatar and `AgentLargeVC`. UIKit holds it weakly during a
    /// presentation, so MainVC keeps the strong reference alive across
    /// present and dismiss.
    private var avatarTransition: AvatarPopTransitionDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()

        setupAvatarTitleView()
        setupHeroAvatar()

        wireAvatarToVoiceLoop()

        // Hero owns the empty state, nav-bar avatar owns the conversation
        // state. Exactly one is shown at a time, driven by whether there's
        // anything visible in the chat (system message and other invisibles
        // don't count — onboarding cards do).
        refreshAvatarVisibility(animated: false)
    }

    /// Builds the navigation bar's titleView: just the AvatarView, sized to
    /// fit inside the bar so it vertically centers with the bar buttons.
    private func setupAvatarTitleView() {
        // 11×11 cells at 4pt = 44×44pt — matches the nav bar height so the
        // orb reads at the same visual weight as the round speaker / edit
        // buttons flanking it. Bumped baseRadius so the filled portion of
        // the orb grows with the larger grid.
        let av = AvatarView(gridW: 11, gridH: 11, pixelSize: 4, baseRadius: 3.2)
        av.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(av)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 44),
            container.heightAnchor.constraint(equalToConstant: 44),
            av.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            av.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            av.widthAnchor.constraint(equalToConstant: 44),
            av.heightAnchor.constraint(equalToConstant: 44),
        ])

        // Tap the nav-bar orb to expand into the immersive AgentLargeVC.
        // The gesture lives on the container so the tap target is the full
        // 44pt square — the orb pixels only fill the center, and a tap on
        // empty corner space should still count.
        container.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(presentAgentLargeView))
        container.addGestureRecognizer(tap)

        self.navigationItem.titleView = container
        self.avatar = av
    }

    /// Push the immersive agent view as a full-screen modal. Uses a custom
    /// `AvatarPopTransitionDelegate` so the small nav-bar orb visually
    /// "pops" through space into the AgentLargeView's 300pt hero orb,
    /// rather than the old plain crossfade. The same delegate drives the
    /// reverse pop on dismiss.
    @objc func presentAgentLargeView() {
        let vc = AgentLargeVC()
        vc.modalPresentationStyle = .fullScreen
        let delegate = AvatarPopTransitionDelegate(sourceAvatar: avatar) { presented in
            (presented as? AgentLargeVC)?.agentView.avatar
        }
        vc.transitioningDelegate = delegate
        // Loading the view here forces AgentLargeView (and its avatar) into
        // existence before the animator runs — the present animator samples
        // the destination avatar's frame inside `animateTransition`.
        _ = vc.view
        self.avatarTransition = delegate
        present(vc, animated: true)
    }

    /// Hero avatar that fills the empty-state slot above the message box.
    /// Same component as the nav-bar avatar at a larger scale — both drive
    /// off the shared VoiceLoopCoordinator, so they animate in lock-step.
    private func setupHeroAvatar() {
        // 21×21 cells at 12pt = 252×252pt. Lands roughly in the upper half of
        // the screen, leaving room for the message box below.
        let big = AvatarView(gridW: 21, gridH: 21, pixelSize: 12, baseRadius: 6.0)
        big.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(big)

        NSLayoutConstraint.activate([
            big.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            // Sit a bit above the safe-area center so the orb feels anchored
            // to the upper third of the screen rather than competing with
            // the message box for vertical attention.
            big.centerYAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerYAnchor, constant: -90),
            big.widthAnchor.constraint(equalToConstant: 252),
            big.heightAnchor.constraint(equalToConstant: 252),
        ])

        self.heroAvatar = big
    }

    /// Subscribes both avatars to the shared VoiceLoopCoordinator. Same
    /// state→mode mapping the Mac uses on its conversation window.
    private func wireAvatarToVoiceLoop() {
        let coord = VoiceLoopCoordinator.shared
        coord.onStateChange = { [weak self] state in
            let mode: AvatarView.Mode
            switch state {
            case .idle:         mode = .idle
            case .recording:    mode = .listening
            case .transcribing: mode = .thinking
            case .thinking:     mode = .thinking
            case .speaking:     mode = .speaking
            }
            self?.avatar?.mode = mode
            self?.heroAvatar?.mode = mode
        }
        coord.onAmplitude = { [weak self] amp in
            self?.avatar?.amplitude = amp
            self?.heroAvatar?.amplitude = amp
        }
        // TTS output amplitude feeds the same `amplitude` property — the
        // AvatarView's mode-dependent draw picks listening vs speaking
        // formulas, so the single value can serve both.
        coord.onOutputAmplitude = { [weak self] amp in
            self?.avatar?.amplitude = amp
            self?.heroAvatar?.amplitude = amp
        }
        // Pulse both avatars when the coordinator posts an acknowledge
        // event (user just sent, or assistant just finished). Same hook
        // shape as the existing onStateChange / onAmplitude callbacks but
        // via NotificationCenter so AgentLargeView can subscribe too.
        NotificationCenter.default.addObserver(
            forName: .voiceLoopAcknowledgePulse,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.avatar?.pulse()
            self?.heroAvatar?.pulse()
        }
    }

    private func setHeroVisible(_ visible: Bool, animated: Bool = true) {
        guard let hero = heroAvatar else { return }
        if visible {
            hero.isHidden = false
        }
        let block = { hero.alpha = visible ? 1 : 0 }
        if animated {
            UIView.animate(withDuration: 0.3, animations: block) { _ in
                if !visible { hero.isHidden = true }
            }
        } else {
            block()
            if !visible { hero.isHidden = true }
        }
    }

    /// Show the nav-bar avatar only while a conversation is on screen. While
    /// the hero is doing its job in the empty state, the bar stays neutral
    /// so the two orbs don't compete for attention.
    private func setNavAvatarVisible(_ visible: Bool, animated: Bool = true) {
        guard let av = avatar else { return }
        if visible {
            av.isHidden = false
        }
        let block = { av.alpha = visible ? 1 : 0 }
        if animated {
            UIView.animate(withDuration: 0.25, animations: block) { _ in
                if !visible { av.isHidden = true }
            }
        } else {
            block()
            if !visible { av.isHidden = true }
        }
    }

    override func keyboardWillShow(_ notification: Notification) {
        super.keyboardWillShow(notification)
        // Intentionally don't touch hero visibility here — the hero owns the
        // empty-state slot until the user actually sends a message, and
        // making it vanish just because they tapped into the message box
        // reads as "the orb is broken." The `safeAreaLayoutGuide` center
        // the hero is pinned to already shifts up with the keyboard, so it
        // floats clear of the input bar on its own. Visibility flips happen
        // in `refreshAvatarVisibility`, driven off `visible_messages`.
    }

    override func keyboardWillHide(_ notification: Notification) {
        super.keyboardWillHide(notification)
        // Counterpart no-op — `refreshAvatarVisibility` is the single source
        // of truth for hero on/off, and it's already correct (visible while
        // `visible_messages.isEmpty`). Forcing visibility here was only
        // needed to undo the keyboardWillShow hide we removed above.
    }

    override func rightBarButtonTapped() {
        super.rightBarButtonTapped()
        refreshAvatarVisibility()
    }

    override func newMessageSent() {
        refreshAvatarVisibility()
    }

    override func loadConversation(_ conversation: SimpleConversation) {
        super.loadConversation(conversation)
        refreshAvatarVisibility()
    }

    /// Single source of truth for hero ↔ nav-avatar handoff. The hero owns
    /// the empty state; once anything visible lands in the chat (a real
    /// message, an onboarding card, an attachment bubble), it collapses into
    /// the nav-bar avatar. Driven off `visible_messages` so the system
    /// message and bare function calls don't count as "there's a chat."
    ///
    /// On a real state transition (and when motion isn't reduced) we run a
    /// 3D "pop" via `AvatarPopAnimator` so the orb appears to fly between
    /// the two slots. Initial visibility, Reduce Motion, and non-animated
    /// callers take the plain alpha-fade path.
    private func refreshAvatarVisibility(animated: Bool = true) {
        let isEmpty = self.visible_messages.isEmpty
        let previous = lastVisibilityEmpty
        lastVisibilityEmpty = isEmpty

        let isInitial = (previous == nil)
        let changed = previous != isEmpty
        let canPop = animated
            && changed
            && !isInitial
            && !UIAccessibility.isReduceMotionEnabled
            && view.window != nil

        guard canPop else {
            setHeroVisible(isEmpty, animated: animated && !isInitial)
            setNavAvatarVisible(!isEmpty, animated: animated && !isInitial)
            return
        }

        // Make sure both avatars are present in the view hierarchy with the
        // right alpha before sampling frames — they're the source/dest of
        // the snapshot flight, and a hidden-but-alpha-0 view still has a
        // valid frame, but `isHidden = true` collapses some hit-testing
        // pieces we rely on for `convert(_:to:)`.
        heroAvatar?.isHidden = false
        avatar?.isHidden = false
        heroAvatar?.alpha = 1
        avatar?.alpha = 1
        view.layoutIfNeeded()
        navigationController?.navigationBar.layoutIfNeeded()

        guard let hero = heroAvatar,
              let nav = avatar,
              let window = view.window
        else {
            setHeroVisible(isEmpty, animated: true)
            setNavAvatarVisible(!isEmpty, animated: true)
            return
        }

        let source: UIView = isEmpty ? nav : hero
        let dest: UIView   = isEmpty ? hero : nav

        AvatarPopAnimator.play(from: source, to: dest, in: window) { [weak self] in
            guard let self = self else { return }
            // Final visibility: hero shows on empty, nav-bar shows on
            // non-empty. The animator restored isHidden on both, so we set
            // the canonical end state here without re-animating.
            self.setHeroVisible(isEmpty, animated: false)
            self.setNavAvatarVisible(!isEmpty, animated: false)
        }
    }
}
