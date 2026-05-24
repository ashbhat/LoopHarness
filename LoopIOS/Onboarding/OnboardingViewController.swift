//
//  OnboardingViewController.swift
//  Loop (iOS)
//
//  First-run flow described by LoopIOS/Specs/3_ios_onboarding_spec.md.
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

    private let scrollView = UIScrollView()
    private let contentContainer = UIView()
    private let bottomBar = UIView()
    private let stepDots = UIStackView()
    private let actionButtonPointer = UIView()
    private var actionButtonPointerArrow: UIImageView?
    private lazy var skipButton: ClosureButton = {
        let button = ClosureButton(title: "Skip") { [weak self] in self?.complete() }
        var config = UIButton.Configuration.plain()
        var attrs = AttributeContainer()
        attrs.font = .systemFont(ofSize: 14, weight: .medium)
        attrs.foregroundColor = UIColor.secondaryLabel
        config.attributedTitle = AttributedString("Skip", attributes: attrs)
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 0)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

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
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentContainer)

        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        configureActionButtonPointer()

        stepDots.axis = .horizontal
        stepDots.spacing = 8
        stepDots.alignment = .center
        stepDots.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stepDots)
        view.addSubview(skipButton)

        let contentHeight = contentContainer.heightAnchor.constraint(
            greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor)
        contentHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -12),

            contentContainer.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentContainer.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentHeight,

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            bottomBar.bottomAnchor.constraint(equalTo: stepDots.topAnchor, constant: -12),
            // Collapse to zero height when no footer is present so the scroll
            // view above can take the full space. Subviews pinned top+bottom
            // (see render()) override this with their own intrinsic height.
            {
                let c = bottomBar.heightAnchor.constraint(equalToConstant: 0)
                c.priority = .defaultLow
                return c
            }(),

            stepDots.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stepDots.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            stepDots.heightAnchor.constraint(equalToConstant: 10),

            skipButton.centerYAnchor.constraint(equalTo: stepDots.centerYAnchor),
            skipButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    /// Pinned overlay near the top-left edge of the screen that points to the
    /// physical Action Button. Visible only on `.firstMessage`. The arrow
    /// hops left/right to draw the eye toward the device edge.
    private func configureActionButtonPointer() {
        actionButtonPointer.translatesAutoresizingMaskIntoConstraints = false
        actionButtonPointer.isHidden = true
        view.addSubview(actionButtonPointer)

        let arrow = UIImageView(image: UIImage(systemName: "arrow.left"))
        arrow.tintColor = .systemBlue
        arrow.contentMode = .scaleAspectFit
        arrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .bold)
        actionButtonPointerArrow = arrow

        let caption = UILabel()
        caption.text = "Action Button"
        caption.font = .systemFont(ofSize: 13, weight: .semibold)
        caption.textColor = .systemBlue

        let row = UIStackView(arrangedSubviews: [arrow, caption])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        actionButtonPointer.addSubview(row)

        NSLayoutConstraint.activate([
            actionButtonPointer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            actionButtonPointer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 36),

            row.topAnchor.constraint(equalTo: actionButtonPointer.topAnchor),
            row.bottomAnchor.constraint(equalTo: actionButtonPointer.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: actionButtonPointer.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: actionButtonPointer.trailingAnchor),
        ])
    }

    private func updateActionButtonPointer(forStep step: Step) {
        let visible = (step == .firstMessage)
        actionButtonPointer.isHidden = !visible
        guard let arrow = actionButtonPointerArrow else { return }
        arrow.layer.removeAllAnimations()
        arrow.transform = .identity
        if visible {
            UIView.animate(withDuration: 0.7,
                           delay: 0,
                           options: [.repeat, .autoreverse, .curveEaseInOut],
                           animations: {
                arrow.transform = CGAffineTransform(translationX: -6, y: 0)
            })
        }
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
        bottomBar.subviews.forEach { $0.removeFromSuperview() }

        let parts: (content: UIView, footer: UIView?)
        switch currentStep {
        case .welcome:      parts = buildWelcomeView()
        case .actionButton: parts = buildActionButtonView()
        case .firstMessage: parts = buildFirstMessageView()
        }

        parts.content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(parts.content)
        NSLayoutConstraint.activate([
            parts.content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            parts.content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            parts.content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            parts.content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])

        if let footer = parts.footer {
            footer.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(footer)
            NSLayoutConstraint.activate([
                footer.topAnchor.constraint(equalTo: bottomBar.topAnchor),
                footer.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
                footer.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
                footer.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
            ])
        }

        renderStepDots()
        skipButton.isHidden = currentStep != .firstMessage
        updateActionButtonPointer(forStep: currentStep)
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

    private func buildWelcomeView() -> (content: UIView, footer: UIView?) {
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

        // The scroll view forces its content to be at least viewport-tall, so
        // something in this stack has to absorb the slack. Previously the orb
        // row was the lowest-hugging arranged subview and stretched — floating
        // the orb in dead space well above the title. Pin the orb row to its
        // intrinsic height and let a trailing spacer eat the leftover height
        // below the pillars instead, so the orb sits snug above the title.
        let orbRow = centeredRow(avatar)
        orbRow.setContentHuggingPriority(.required, for: .vertical)
        orbRow.setContentCompressionResistancePriority(.required, for: .vertical)

        let trailingSpacer = UIView()
        trailingSpacer.setContentHuggingPriority(.init(1), for: .vertical)

        let stack = UIStackView(arrangedSubviews: [orbRow, title, subtitle, pillars, trailingSpacer])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16
        stack.setCustomSpacing(24, after: orbRow)
        stack.setCustomSpacing(20, after: subtitle)
        stack.setCustomSpacing(24, after: pillars)
        return (stack, cta)
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

    private func buildActionButtonView() -> (content: UIView, footer: UIView?) {
        // Hero: the same icon the user is hunting for in Settings, rendered
        // as a Settings-app-style tinted tile. Builds visual continuity from
        // this screen straight into the Settings list.
        let hero = makeHeroTile(image: UIImage(named: "ActionButtonGlyph"),
                                background: .systemBlue,
                                size: 76,
                                cornerRadius: 18)

        let title = makeTitle("Bind Loop to your Action Button")
        let body = makeSubtitle("Add the “Start Dictation” shortcut so a single squeeze starts a Loop conversation.")

        let stepsCard = makeStepsCard([
            (1, "Open Settings, then tap Action Button.",
                makeMockSettingsRow(image: UIImage(named: "ActionButtonGlyph"),
                                    title: "Action Button",
                                    tileColor: .systemBlue)),
            (2, "Swipe the carousel to the Shortcut option.",
                makeMockShortcutChip()),
            (3, "Tap Choose a Shortcut, then pick Loop → Start Dictation.",
                makeMockChooseShortcutPill()),
            (4, "Swipe back to Loop when you’re done.", nil),
        ])

        let openButton = makeSecondaryButton(title: "Open Settings") { [weak self] in
            self?.openActionButtonSettings()
        }
        let continueButton = makePrimaryButton(title: "I’ve added it") { [weak self] in
            self?.advance()
        }

        let heroRow = UIStackView(arrangedSubviews: [UIView(), hero, UIView()])
        heroRow.axis = .horizontal
        heroRow.alignment = .center
        heroRow.distribution = .equalCentering

        let stack = UIStackView(arrangedSubviews: [heroRow, title, body, stepsCard])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        stack.setCustomSpacing(22, after: heroRow)
        stack.setCustomSpacing(20, after: body)

        let footer = UIStackView(arrangedSubviews: [openButton, continueButton])
        footer.axis = .vertical
        footer.alignment = .fill
        footer.spacing = 10
        return (stack, footer)
    }

    /// Settings-app-style icon tile: a colored rounded square with a centered
    /// white glyph and a soft same-color shadow underneath. Pretty enough to
    /// carry the hero slot on its own without an SF Symbol.
    private func makeHeroTile(image: UIImage?, background: UIColor, size: CGFloat, cornerRadius: CGFloat) -> UIView {
        let tile = UIView()
        tile.backgroundColor = background
        tile.layer.cornerRadius = cornerRadius
        tile.layer.cornerCurve = .continuous
        tile.layer.shadowColor = background.cgColor
        tile.layer.shadowOpacity = 0.28
        tile.layer.shadowRadius = 18
        tile.layer.shadowOffset = CGSize(width: 0, height: 10)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: size),
            tile.heightAnchor.constraint(equalToConstant: size),
        ])

        let glyph = UIImageView(image: image?.withRenderingMode(.alwaysTemplate))
        glyph.tintColor = .white
        glyph.contentMode = .scaleAspectFit
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: size * 0.55),
            glyph.heightAnchor.constraint(equalToConstant: size * 0.55),
        ])
        return tile
    }

    /// Steps inside a single grouped card. Each row is `number | text | preview?`,
    /// and adjacent rows are split by a hairline separator indented to align
    /// with the text column — same look as iOS Settings cells.
    private func makeStepsCard(_ steps: [(Int, String, UIView?)]) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])

        for (idx, step) in steps.enumerated() {
            stack.addArrangedSubview(makeStepRow(number: step.0, text: step.1, preview: step.2))
            if idx < steps.count - 1 {
                stack.addArrangedSubview(makeRowSeparator(leftInset: 16 + 26 + 12))
            }
        }
        return card
    }

    private func makeStepRow(number: Int, text: String, preview: UIView?) -> UIView {
        let badge = UILabel()
        badge.text = "\(number)"
        badge.font = .systemFont(ofSize: 13, weight: .bold)
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = .systemBlue
        badge.layer.cornerRadius = 13
        badge.layer.masksToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
        ])

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15)
        label.textColor = .label
        label.numberOfLines = 0

        let textRow = UIStackView(arrangedSubviews: [badge, label])
        textRow.axis = .horizontal
        textRow.alignment = .top
        textRow.spacing = 12

        let column: UIStackView
        if let preview {
            // Indent the preview under the text so it lines up under the
            // copy column rather than the number badge (26 + 12 = 38).
            let previewIndent = UIStackView(arrangedSubviews: [preview])
            previewIndent.axis = .horizontal
            previewIndent.isLayoutMarginsRelativeArrangement = true
            previewIndent.layoutMargins = UIEdgeInsets(top: 0, left: 38, bottom: 0, right: 0)

            column = UIStackView(arrangedSubviews: [textRow, previewIndent])
            column.axis = .vertical
            column.alignment = .fill
            column.spacing = 10
        } else {
            column = UIStackView(arrangedSubviews: [textRow])
            column.axis = .vertical
        }

        let wrap = UIView()
        column.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -14),
            column.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
        ])
        return wrap
    }

    private func makeRowSeparator(leftInset: CGFloat) -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true

        let wrap = UIView()
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: leftInset),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
        ])
        return wrap
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
        row.backgroundColor = .systemBackground
        row.layer.cornerRadius = 10
        row.layer.cornerCurve = .continuous
        return row
    }

    /// The "Shortcut" mode of the Action Button carousel as a compact chip:
    /// a small indigo capsule flanked by faint chevrons (you swipe to reach
    /// it) with the "Shortcut" caption to the right. Sized to live inside a
    /// step row rather than dominate the screen.
    private func makeMockShortcutChip() -> UIView {
        let pill = UIView()
        pill.backgroundColor = .systemIndigo
        pill.layer.cornerRadius = 15
        pill.layer.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pill.widthAnchor.constraint(equalToConstant: 30),
            pill.heightAnchor.constraint(equalToConstant: 54),
        ])

        let icon = UIImageView(image: UIImage(systemName: "square.stack.3d.up.fill"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])

        let left = UIImageView(image: UIImage(systemName: "chevron.left"))
        left.tintColor = .quaternaryLabel
        left.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)

        let right = UIImageView(image: UIImage(systemName: "chevron.right"))
        right.tintColor = .quaternaryLabel
        right.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)

        let caption = UILabel()
        caption.text = "Shortcut"
        caption.font = .systemFont(ofSize: 13, weight: .semibold)
        caption.textColor = .secondaryLabel

        let row = UIStackView(arrangedSubviews: [left, pill, right, caption, UIView()])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.setCustomSpacing(14, after: right)
        return row
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

    private func buildFirstMessageView() -> (content: UIView, footer: UIView?) {
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
        return (stack, nil)
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
