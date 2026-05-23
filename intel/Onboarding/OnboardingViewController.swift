//
//  OnboardingViewController.swift
//  Loop (iOS)
//
//  First-run flow described by intel/Specs/3_ios_onboarding_spec.md.
//  Three steps:
//   1. Welcome — explains Loop's three pillars (learns over time, BYO tokens,
//      customizable). Matches the Mac welcome card so cross-device users see
//      the same framing.
//   2. Action button — sends the user to Settings → Action Button to add the
//      `Start Dictation` shortcut, then waits for them to swipe back. We auto-
//      advance once the app returns to the foreground.
//   3. First message — prompts the user to press the Action Button on the
//      left edge of their iPhone. The hardware press fires our StartDictation
//      App Intent, which routes through SceneDelegate.handleMicURL. We
//      intercept that on step 3, dismiss the onboarding (revealing the live
//      recorder UI on MessagingVC), and mark onboarding complete.
//

import UIKit

final class OnboardingViewController: UIViewController {

    enum Step: Int, CaseIterable { case welcome, actionButton, firstMessage }

    /// Fires once the user finishes the flow. SceneDelegate uses this to clear
    /// its reference and surface the underlying MessagingVC.
    var onCompleted: (() -> Void)?

    private(set) var currentStep: Step = .welcome

    private let contentContainer = UIView()
    private let stepDots = UIStackView()

    private var didObserveForeground = false

    init() {
        super.init(nibName: nil, bundle: nil)
        let resumed = Step(rawValue: max(0, min(Step.firstMessage.rawValue, OnboardingState.lastStep))) ?? .welcome
        self.currentStep = resumed
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureContent()
        render()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleForeground),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public hooks

    /// Called by SceneDelegate when the Start Dictation App Intent fires. If
    /// we're on the first-message step, treat the press as the completion
    /// signal: complete onboarding and let the dismissal reveal the live
    /// recorder on MessagingVC. Returns true if we consumed the trigger so the
    /// caller can decide whether to also route the URL to the messaging view.
    @discardableResult
    func handleActionButtonPressed() -> Bool {
        guard currentStep == .firstMessage else { return false }
        complete()
        return true
    }

    // MARK: - Layout

    private func configureContent() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        stepDots.axis = .horizontal
        stepDots.spacing = 8
        stepDots.alignment = .center
        stepDots.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stepDots)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            contentContainer.bottomAnchor.constraint(equalTo: stepDots.topAnchor, constant: -16),

            stepDots.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stepDots.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            stepDots.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    private func renderStepDots() {
        for sub in stepDots.arrangedSubviews {
            stepDots.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        for step in Step.allCases {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = 4
            dot.backgroundColor = step == currentStep ? .label : .tertiaryLabel
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
            stepDots.addArrangedSubview(dot)
        }
    }

    // MARK: - Step rendering

    private func render() {
        OnboardingState.lastStep = currentStep.rawValue
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        let stepView: UIView
        switch currentStep {
        case .welcome:      stepView = buildWelcomeView()
        case .actionButton: stepView = buildActionButtonView()
        case .firstMessage: stepView = buildFirstMessageView()
        }
        stepView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(stepView)
        NSLayoutConstraint.activate([
            stepView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            stepView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            stepView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            stepView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        renderStepDots()
    }

    private func advance() {
        if let next = Step(rawValue: currentStep.rawValue + 1) {
            currentStep = next
            render()
        } else {
            complete()
        }
    }

    private func complete() {
        OnboardingState.isComplete = true
        // Cross-dissolve back to the underlying MessagingVC. The action-button
        // case relies on this happening *fast* so the user sees the live
        // recorder UI as soon as their press goes through.
        dismiss(animated: true) { [weak self] in
            self?.onCompleted?()
        }
    }

    // MARK: - Step 1: Welcome

    private func buildWelcomeView() -> UIView {
        let avatar = AvatarView(gridW: 17, gridH: 17, pixelSize: 10, baseRadius: 5.0)
        avatar.mode = .idle

        let title = makeTitle("Loop is your general agent")
        let subtitle = makeSubtitle("Bring your own keys, teach Loop what you care about, and shape it to your workflow.")

        let pillars = UIStackView(arrangedSubviews: [
            makePillar(symbol: "brain.head.profile",
                       title: "Learns with time",
                       body: "Loop remembers what you tell it, across iPhone and Mac."),
            makePillar(symbol: "key.fill",
                       title: "Bring your own tokens",
                       body: "Use your own Deepgram, OpenAI, ElevenLabs, and other API keys."),
            makePillar(symbol: "slider.horizontal.3",
                       title: "Customizable",
                       body: "Add your own skills, voices, and prompts as Loop grows with you."),
        ])
        pillars.axis = .vertical
        pillars.alignment = .fill
        pillars.spacing = 16

        let cta = makePrimaryButton(title: "Get started") { [weak self] in self?.advance() }

        let stack = UIStackView(arrangedSubviews: [centeredRow(avatar), title, subtitle, pillars, UIView(), cta])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16
        stack.setCustomSpacing(20, after: subtitle)
        stack.setCustomSpacing(24, after: pillars)
        return stack
    }

    /// Wraps a view in a horizontal stack that centers it on screen while
    /// keeping the outer vertical stack's `.fill` alignment intact.
    private func centeredRow(_ view: UIView) -> UIView {
        let row = UIStackView(arrangedSubviews: [UIView(), view, UIView()])
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .equalCentering
        return row
    }

    private func makePillar(symbol: String, title: String, body: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
        ])

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label

        let bodyLabel = UILabel()
        bodyLabel.text = body
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [icon, textStack])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 14
        return row
    }

    // MARK: - Step 2: Action button

    private func buildActionButtonView() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "iphone.gen3.radiowaves.left.and.right"))
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 80),
            icon.heightAnchor.constraint(equalToConstant: 80),
        ])

        let title = makeTitle("Bind Loop to your Action Button")
        let body = makeSubtitle("Add the “Start Dictation” shortcut so a single squeeze of the Action Button starts a Loop conversation.")

        let steps = UIStackView(arrangedSubviews: [
            makeNumberedStep(1, "Tap Open Settings, then open Action Button. If Settings opens elsewhere, go back to the main list and tap Action Button.",
                             preview: makeMockSettingsRow(image: UIImage(named: "ActionButtonGlyph"),
                                                          title: "Action Button",
                                                          tileColor: .systemBlue)),
            makeNumberedStep(2, "Swipe to the Shortcut option.",
                             preview: makeMockShortcutCard()),
            makeNumberedStep(3, "Choose Shortcut → Loop → Start Dictation.",
                             preview: makeMockChooseShortcutPill()),
            makeNumberedStep(4, "Swipe back to Loop when you’re done."),
        ])
        steps.axis = .vertical
        steps.alignment = .fill
        steps.spacing = 10

        let openButton = makeSecondaryButton(title: "Open Settings") { [weak self] in
            self?.openActionButtonSettings()
        }
        let continueButton = makePrimaryButton(title: "I’ve added it") { [weak self] in
            self?.advance()
        }

        let iconRow = UIStackView(arrangedSubviews: [UIView(), icon, UIView()])
        iconRow.axis = .horizontal
        iconRow.alignment = .center
        iconRow.distribution = .equalCentering

        let stack = UIStackView(arrangedSubviews: [iconRow, title, body, steps, UIView(), openButton, continueButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        stack.setCustomSpacing(20, after: body)
        stack.setCustomSpacing(24, after: steps)
        stack.setCustomSpacing(10, after: openButton)
        return stack
    }

    private func makeNumberedStep(_ n: Int, _ text: String, preview: UIView? = nil) -> UIView {
        let badge = UILabel()
        badge.text = "\(n)"
        badge.font = .systemFont(ofSize: 13, weight: .bold)
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = .systemBlue
        badge.layer.cornerRadius = 11
        badge.layer.masksToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
        ])

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14)
        label.textColor = .label
        label.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [badge, label])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12

        guard let preview else { return row }

        // Indent the preview so it lines up under the text column, not the
        // number badge (22pt badge + 12pt spacing).
        let previewRow = UIStackView(arrangedSubviews: [preview])
        previewRow.axis = .horizontal
        previewRow.isLayoutMarginsRelativeArrangement = true
        previewRow.layoutMargins = UIEdgeInsets(top: 0, left: 34, bottom: 0, right: 0)

        let column = UIStackView(arrangedSubviews: [row, previewRow])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 8
        return column
    }

    // MARK: - Settings facsimiles
    //
    // These are static mock-ups of what the user will see in iOS Settings.
    // They are illustrative only — none of them are interactive, because
    // there is no API to configure the Action Button from within the app.

    /// A facsimile of an iOS Settings list row (icon tile, title, chevron) so
    /// the user recognizes the "Action Button" row to tap.
    private func makeMockSettingsRow(image: UIImage?, title: String, tileColor: UIColor) -> UIView {
        let tile = UIView()
        tile.backgroundColor = tileColor
        tile.layer.cornerRadius = 6
        tile.layer.cornerCurve = .continuous
        tile.layer.masksToBounds = true
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 28),
            tile.heightAnchor.constraint(equalToConstant: 28),
        ])

        let glyph = UIImageView(image: image?.withRenderingMode(.alwaysTemplate))
        glyph.tintColor = .white
        glyph.contentMode = .scaleAspectFit
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 17),
            glyph.heightAnchor.constraint(equalToConstant: 17),
        ])

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 15)
        label.textColor = .label

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [tile, label, UIView(), chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 9, left: 12, bottom: 9, right: 14)
        row.backgroundColor = .secondarySystemGroupedBackground
        row.layer.cornerRadius = 10
        row.layer.cornerCurve = .continuous
        row.layer.borderWidth = 1
        row.layer.borderColor = UIColor.systemGray3.cgColor
        return row
    }

    /// The "Shortcut" mode of the Action Button carousel, drawn as the
    /// on-screen vertical capsule (white glyph on indigo) with faint
    /// chevrons hinting that the user swipes between modes to reach it.
    private func makeMockShortcutCard() -> UIView {
        let pill = UIView()
        pill.backgroundColor = .systemIndigo
        pill.layer.cornerRadius = 23
        pill.layer.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pill.widthAnchor.constraint(equalToConstant: 46),
            pill.heightAnchor.constraint(equalToConstant: 84),
        ])

        let icon = UIImageView(image: UIImage(systemName: "square.stack.3d.up.fill"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])

        let left = UIImageView(image: UIImage(systemName: "chevron.left"))
        left.tintColor = .quaternaryLabel
        left.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)

        let right = UIImageView(image: UIImage(systemName: "chevron.right"))
        right.tintColor = .quaternaryLabel
        right.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)

        let pillRow = UIStackView(arrangedSubviews: [left, pill, right])
        pillRow.axis = .horizontal
        pillRow.alignment = .center
        pillRow.spacing = 18

        let caption = UILabel()
        caption.text = "Shortcut"
        caption.font = .systemFont(ofSize: 14, weight: .semibold)
        caption.textColor = .label
        caption.textAlignment = .center

        let column = UIStackView(arrangedSubviews: [pillRow, caption])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 8
        return column
    }

    /// The blue "Choose a Shortcut" pill shown under the Shortcut mode.
    private func makeMockChooseShortcutPill() -> UIView {
        let plus = UIImageView(image: UIImage(systemName: "plus.circle.fill"))
        plus.tintColor = .systemBlue
        plus.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)

        let label = UILabel()
        label.text = "Choose a Shortcut"
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .systemBlue

        let pill = UIStackView(arrangedSubviews: [plus, label])
        pill.axis = .horizontal
        pill.spacing = 6
        pill.alignment = .center
        pill.isLayoutMarginsRelativeArrangement = true
        pill.layoutMargins = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 16)
        pill.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        pill.layer.cornerRadius = 16
        pill.layer.cornerCurve = .continuous

        // Hug the pill to its content and left-align it under the step text.
        let wrap = UIStackView(arrangedSubviews: [pill, UIView()])
        wrap.axis = .horizontal
        return wrap
    }

    /// Best-effort deep link into Settings → Action Button. There is no
    /// public API for this. On iOS 17 the private `prefs:root=ACTION_BUTTON`
    /// form reaches the page; on iOS 18+ Apple removed Settings sub-path
    /// support, so these URLs degrade to Loop's own Settings page (and still
    /// report success). We try the most-correct form first; the on-screen
    /// numbered steps are written to carry the user from wherever they land.
    private func openActionButtonSettings() {
        let candidates = [
            "settings-navigation://",
            "prefs://",
            "prefs:root=ACTION_BUTTON",
            "App-Prefs:root=ACTION_BUTTON",
            "App-Prefs:ACTION_BUTTON",
            "settings-navigation://com.apple.Settings.ActionButton",
        ]
        tryOpenActionButton(candidates)
    }

    private func tryOpenActionButton(_ candidates: [String]) {
        var remaining = candidates
        guard !remaining.isEmpty else { return }
        let next = remaining.removeFirst()
        guard let url = URL(string: next) else {
            tryOpenActionButton(remaining)
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            if !success { self?.tryOpenActionButton(remaining) }
        }
    }

    // MARK: - Step 3: First message

    private func buildFirstMessageView() -> UIView {
        let avatar = AvatarView(gridW: 21, gridH: 21, pixelSize: 12, baseRadius: 6.0)
        avatar.mode = .listening
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 252),
            avatar.heightAnchor.constraint(equalToConstant: 252),
        ])

        // Mirror the live mic amplitude through the shared coordinator so the
        // orb pulses as soon as the Action Button press starts capturing.
        VoiceLoopCoordinator.shared.onAmplitude = { [weak avatar] amp in
            avatar?.amplitude = amp
        }

        let title = makeTitle("Press your Action Button")
        let body = makeSubtitle("Hold the Action Button on the left side of your iPhone and say something. Whatever you say becomes the first message in this conversation.")

        let hint = makeHint("Waiting for your first message…")

        let avatarRow = UIStackView(arrangedSubviews: [UIView(), avatar, UIView()])
        avatarRow.axis = .horizontal
        avatarRow.alignment = .center
        avatarRow.distribution = .equalCentering

        let stack = UIStackView(arrangedSubviews: [avatarRow, title, body, UIView(), hint])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16
        return stack
    }

    // MARK: - Foreground hook

    @objc private func handleForeground() {
        // While the user is on the action-button step we expect them to leave
        // for Settings and come back. Nothing to do automatically — we keep
        // the explicit "I've added it" button as the advance signal so we don't
        // jump ahead just because they peeked at another app. The hook is
        // here so future copy/UX tweaks have a place to react.
        _ = didObserveForeground
        didObserveForeground = true
    }

    // MARK: - Builders

    private func makeTitle(_ s: String) -> UILabel {
        let label = UILabel()
        label.text = s
        label.font = .systemFont(ofSize: 26, weight: .bold)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    private func makeSubtitle(_ s: String) -> UILabel {
        let label = UILabel()
        label.text = s
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    private func makeHint(_ s: String) -> UILabel {
        let label = UILabel()
        label.text = s
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        return label
    }

    private func makePrimaryButton(title: String, action: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton(title: title, action: action)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .large
        config.baseBackgroundColor = .label
        config.baseForegroundColor = .systemBackground
        var attrs = AttributeContainer()
        attrs.font = .systemFont(ofSize: 16, weight: .semibold)
        config.attributedTitle = AttributedString(title, attributes: attrs)
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        button.configuration = config
        return button
    }

    private func makeSecondaryButton(title: String, action: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton(title: title, action: action)
        var config = UIButton.Configuration.gray()
        config.title = title
        config.cornerStyle = .large
        var attrs = AttributeContainer()
        attrs.font = .systemFont(ofSize: 16, weight: .semibold)
        config.attributedTitle = AttributedString(title, attributes: attrs)
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        button.configuration = config
        return button
    }
}

/// UIButton that owns its tap closure. Avoids the target/selector boilerplate
/// when each step builds buttons inline with different actions.
final class ClosureButton: UIButton {
    private let actionClosure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.actionClosure = action
        super.init(frame: .zero)
        addTarget(self, action: #selector(invoke), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { actionClosure() }
}
