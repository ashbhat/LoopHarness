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

    override func viewDidLoad() {
        super.viewDidLoad()

        setupAvatarTitleView()
        setupHeroAvatar()

        wireAvatarToVoiceLoop()

        // Initial visibility — the hero owns the empty state, the nav-bar
        // avatar owns the conversation state. Exactly one is shown at a time.
        let hasConversation = self.messages.count > 1
        if hasConversation {
            heroAvatar?.isHidden = true
            heroAvatar?.alpha = 0
        }
        setNavAvatarVisible(hasConversation)
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

    /// Push the immersive agent view as a full-screen modal. Crossfade so the
    /// nav-bar orb visually expands into the hero orb — both are the same
    /// component, just at different sizes.
    @objc private func presentAgentLargeView() {
        let vc = AgentLargeVC()
        vc.modalPresentationStyle = .fullScreen
        vc.modalTransitionStyle = .crossDissolve
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
        setHeroVisible(false)
    }

    override func keyboardWillHide(_ notification: Notification) {
        super.keyboardWillHide(notification)
        if self.messages.count <= 1 {
            setHeroVisible(true)
        }
    }

    override func rightBarButtonTapped() {
        super.rightBarButtonTapped()
        if self.messages.count <= 1 && !self.messageBox.textView.isFirstResponder {
            setHeroVisible(true)
            setNavAvatarVisible(false)
        }
    }

    override func newMessageSent() {
        if self.messages.count > 1 {
            setHeroVisible(false)
            setNavAvatarVisible(true)
        }
    }

    override func loadConversation(_ conversation: SimpleConversation) {
        super.loadConversation(conversation)
        let hasConversation = self.messages.count > 1
        setHeroVisible(!hasConversation)
        setNavAvatarVisible(hasConversation)
    }
}
