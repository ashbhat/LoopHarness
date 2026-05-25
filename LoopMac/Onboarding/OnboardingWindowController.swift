//
//  OnboardingWindowController.swift
//  LoopMac
//
//  First-run flow described by LoopIOS/Specs/3_mac_onboarding_spec.md.
//  Four steps:
//   1. Welcome — explains Loop's three pillars (learns over time, BYO
//      tokens, customizable).
//   2. Accessibility — guides the user to grant the global hotkey
//      monitor's required permission. Polls `AXIsProcessTrusted` so
//      Continue lights up the moment the system flips it.
//   3. Launch at login — registers Loop with `SMAppService.mainApp`.
//   4. First command — pre-shows the recorder bar at the bottom of the
//      screen and waits for the user to hold fn + ⌃ and send their first
//      turn. As soon as that turn reaches `.thinking`, onboarding
//      completes and the conversation window takes over.
//

import AppKit
import ApplicationServices
import ServiceManagement

final class OnboardingWindowController: NSWindowController {

    enum Step: Int, CaseIterable { case welcome, accessibility, launchAtLogin, firstCommand }

    /// Coordinator we observe in step 4 to detect the first sent turn.
    private weak var coordinator: VoiceLoopCoordinator?
    /// Recorder we pre-show / unsuppress in step 4.
    private weak var recorder: RecorderWindowController?

    /// Fires once the user finishes (or, in a future iteration, skips) the
    /// flow. AppDelegate uses this to hand control back to the steady-state
    /// recorder/conversation surfaces.
    var onCompleted: (() -> Void)?

    private var currentStep: Step = .welcome
    private let contentContainer = NSView()
    private let stepDots = NSStackView()

    // Per-step state we hang onto across renders.
    private var accessibilityPollTimer: Timer?
    private var launchPollTimer: Timer?
    private var stateObserver: ((VoiceLoopCoordinator.State) -> Void)?
    private var previousOnStateChange: ((VoiceLoopCoordinator.State) -> Void)?
    /// Listener token for `.voiceLoopUserMessageSubmitted`. Kept around so
    /// step 4 can dismiss itself when the user's first message lands —
    /// including the case where the conversational onboarding consumes the
    /// text inline (which means `state` never transitions through
    /// `.thinking`, so the state-observer branch alone misses it).
    private var firstTurnSubmitObserver: NSObjectProtocol?
    /// Step 4 popup + its "menu about to open" observer, so we can repopulate
    /// the device list each time the user clicks the chevron.
    private weak var micPopup: NSPopUpButton?
    private var micPopupObserver: NSObjectProtocol?

    init(coordinator: VoiceLoopCoordinator, recorder: RecorderWindowController) {
        self.coordinator = coordinator
        self.recorder = recorder

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Loop"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()

        super.init(window: window)

        // Resume where the user left off. Step 4 (firstCommand) is safe to
        // resume into — the recorder + hotkey are ready by the time
        // applicationDidFinishLaunching reaches us, and the step just shows
        // its instructions again until the user sends a message.
        let maxStep = Step.allCases.last!.rawValue
        let resumed = Step(rawValue: max(0, min(maxStep, MacOnboardingState.lastStep))) ?? .welcome
        self.currentStep = resumed

        configureContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Public entry

    func start() {
        // Park the recorder bar while the welcome / accessibility / launch
        // steps own the screen.
        recorder?.isSuppressed = true
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        render()
    }

    // MARK: - Layout

    private func configureContent() {
        guard let window = window, let root = window.contentView else { return }

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentContainer)

        stepDots.orientation = .horizontal
        stepDots.spacing = 8
        stepDots.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stepDots)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: 56),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            contentContainer.bottomAnchor.constraint(equalTo: stepDots.topAnchor, constant: -16),

            stepDots.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stepDots.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
    }

    private func renderStepDots() {
        for view in stepDots.arrangedSubviews {
            stepDots.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for step in Step.allCases {
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.layer?.backgroundColor = step == currentStep
                ? NSColor.labelColor.cgColor
                : NSColor.tertiaryLabelColor.cgColor
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
            stepDots.addArrangedSubview(dot)
        }
    }

    // MARK: - Step rendering

    private func render() {
        MacOnboardingState.lastStep = currentStep.rawValue
        // Tear down any per-step observers from the prior render.
        accessibilityPollTimer?.invalidate(); accessibilityPollTimer = nil
        launchPollTimer?.invalidate(); launchPollTimer = nil
        if let obs = micPopupObserver {
            NotificationCenter.default.removeObserver(obs)
            micPopupObserver = nil
        }
        micPopup = nil
        if let prev = previousOnStateChange {
            coordinator?.onStateChange = prev
            previousOnStateChange = nil
        }
        if let obs = firstTurnSubmitObserver {
            NotificationCenter.default.removeObserver(obs)
            firstTurnSubmitObserver = nil
        }

        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        let stepView: NSView
        switch currentStep {
        case .welcome:        stepView = buildWelcomeView()
        case .accessibility:  stepView = buildAccessibilityView()
        case .launchAtLogin:  stepView = buildLaunchAtLoginView()
        case .firstCommand:   stepView = buildFirstCommandView()
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
        window?.title = title(for: currentStep)
        applyStepSideEffects()
    }

    /// Side effects tied to entering a step (vs. building its view). Runs on
    /// every render, so a relaunch that resumes mid-flow re-applies them
    /// instead of relying on the `advance()` path.
    private func applyStepSideEffects() {
        switch currentStep {
        case .welcome, .accessibility, .launchAtLogin:
            recorder?.isSuppressed = true
        case .firstCommand:
            recorder?.isSuppressed = false
            recorder?.showBar()
            observeFirstTurn()
        }
    }

    private func title(for step: Step) -> String {
        switch step {
        case .welcome:        return "Welcome to Loop"
        case .accessibility:  return "Allow the global hotkey"
        case .launchAtLogin:  return "Launch at login"
        case .firstCommand:   return "Send your first message"
        }
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
        // Idempotent — both the `.thinking` state change AND the
        // `.voiceLoopUserMessageSubmitted` notification can fire for the
        // same turn (typed → LLM path). The `isComplete` guard means the
        // second call returns immediately rather than running teardown
        // twice or invoking `onCompleted` a second time.
        guard !MacOnboardingState.isComplete else { return }
        MacOnboardingState.isComplete = true
        // Restore any callback we hijacked while watching for the first turn.
        if let prev = previousOnStateChange {
            coordinator?.onStateChange = prev
            previousOnStateChange = nil
        }
        if let obs = micPopupObserver {
            NotificationCenter.default.removeObserver(obs)
            micPopupObserver = nil
        }
        if let obs = firstTurnSubmitObserver {
            NotificationCenter.default.removeObserver(obs)
            firstTurnSubmitObserver = nil
        }
        recorder?.isSuppressed = false
        onCompleted?()
        close()
    }

    // MARK: - Step 1: Welcome

    private func buildWelcomeView() -> NSView {
        let avatar = AvatarView(gridW: 17, gridH: 17, pixelSize: 8, baseRadius: 5.0)
        avatar.mode = .idle
        avatar.translatesAutoresizingMaskIntoConstraints = false

        let title = makeTitle("Loop is your general agent")
        let subtitle = makeSubtitle("Bring your own keys, teach Loop what you care about, and shape it to your workflow.")

        let pillars = NSStackView(views: [
            makePillar(symbol: "brain.head.profile", title: "Learns with time", body: "Loop remembers what you tell it, across iPhone and Mac."),
            makePillar(symbol: "key.fill", title: "Bring your own tokens", body: "Use your own Deepgram, OpenAI, ElevenLabs, and other API keys."),
            makePillar(symbol: "slider.horizontal.3", title: "Customizable", body: "Add your own skills, voices, and prompts as Loop grows with you."),
        ])
        pillars.orientation = .vertical
        pillars.alignment = .leading
        pillars.spacing = 14
        pillars.translatesAutoresizingMaskIntoConstraints = false

        let cta = makePrimaryButton(title: "Get started") { [weak self] in self?.advance() }

        let stack = NSStackView(views: [avatar, title, subtitle, pillars, NSView(), cta])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(20, after: subtitle)
        stack.setCustomSpacing(20, after: pillars)
        return stack
    }

    private func makePillar(symbol: String, title: String, body: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [titleLabel, bodyLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        return row
    }

    // MARK: - Step 2: Accessibility

    private func buildAccessibilityView() -> NSView {
        let title = makeTitle("Allow the fn + ⌃ hotkey")
        let body = makeSubtitle("Loop listens for fn + ⌃ from anywhere on your Mac so you can talk to it without switching apps. macOS only allows that with Accessibility access.")

        let stepsLabel = NSTextField(wrappingLabelWithString:
            "1. Open System Settings → Privacy & Security → Accessibility.\n" +
            "2. Find LoopMac in the list and turn its switch on."
        )
        stepsLabel.font = .systemFont(ofSize: 12)
        stepsLabel.textColor = .secondaryLabelColor
        stepsLabel.alignment = .left
        stepsLabel.maximumNumberOfLines = 4
        stepsLabel.translatesAutoresizingMaskIntoConstraints = false

        let togglePreview = AccessibilityToggleVisualView()
        togglePreview.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let openButton = makeSecondaryButton(title: "Open System Settings") { [weak self] in
            self?.openAccessibilityPane()
        }

        let continueButton = makePrimaryButton(title: "Continue") { [weak self] in self?.advance() }
        continueButton.isEnabled = AXIsProcessTrusted()

        let buttons = NSStackView(views: [openButton, continueButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [title, body, togglePreview, stepsLabel, statusLabel, NSView(), buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(16, after: togglePreview)

        var lastTrust: Bool? = nil
        let refresh: () -> Void = { [weak self] in
            let granted = AXIsProcessTrusted()
            // Detect the false → true edge *before* we overwrite lastTrust so
            // we can pull the onboarding window back to the front the moment
            // the user finishes toggling the switch in System Settings.
            let transitionedToGranted = (lastTrust == false && granted == true)
            if lastTrust != granted {
                // One log per state transition so the console isn't spammy
                // but we can still see grant state flip in real time.
                print("Onboarding/AX: AXIsProcessTrusted = \(granted) — bundle: \(Bundle.main.bundlePath)")
                lastTrust = granted
            }
            statusLabel.stringValue = granted
                ? "✓ Accessibility access granted."
                : "Waiting for the LoopMac switch to be turned on…"
            statusLabel.textColor = granted ? .systemGreen : .secondaryLabelColor
            continueButton.isEnabled = granted

            if transitionedToGranted {
                NSApp.activate(ignoringOtherApps: true)
                self?.window?.makeKeyAndOrderFront(nil)
            }
        }
        refresh()

        // Poll while the step is on screen — there's no public notification
        // when the user toggles Accessibility, and even the AX trust value
        // itself is only refreshed for *this* process at observation
        // boundaries, so a 1Hz check is the cleanest way to react.
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in refresh() }

        // Don't fire the system "would like to control this computer" alert
        // here — our own panel has the same instructions and an "Open System
        // Settings" button, so the system alert just stacks on top and forces
        // an extra Deny/Open click before the user can act.
        return stack
    }

    private func openAccessibilityPane() {
        // Direct deep-link to the Accessibility pane; falls back to the
        // generic Privacy & Security pane if the deep link breaks (e.g. on a
        // future macOS rename).
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Step 3: Launch at login

    private func buildLaunchAtLoginView() -> NSView {
        let title = makeTitle("Keep Loop ready in the background")
        let body = makeSubtitle("Loop launches at login so it's always one keystroke away. You can change this any time in System Settings → Login Items.")

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let enableButton = makeSecondaryButton(title: "Enable launch at login") { [weak self] in
            self?.attemptEnableLaunchAtLogin(statusLabel: statusLabel)
        }

        let continueButton = makePrimaryButton(title: "Continue") { [weak self] in self?.advance() }
        continueButton.isEnabled = LaunchAtLoginManager.isEnabled

        let buttons = NSStackView(views: [enableButton, continueButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [title, body, statusLabel, NSView(), buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14

        let refresh: () -> Void = {
            let enabled = LaunchAtLoginManager.isEnabled
            statusLabel.stringValue = enabled
                ? "✓ Loop will launch when you sign in."
                : "Not enabled yet."
            statusLabel.textColor = enabled ? .systemGreen : .secondaryLabelColor
            enableButton.title = enabled ? "Already enabled" : "Enable launch at login"
            enableButton.isEnabled = !enabled
            continueButton.isEnabled = enabled
        }
        refresh()

        // SMAppService can move to .enabled asynchronously after the user
        // confirms in System Settings (when the registration triggers a
        // .requiresApproval state). Poll so Continue lights up without a
        // manual refresh.
        launchPollTimer?.invalidate()
        launchPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in refresh() }

        return stack
    }

    private func attemptEnableLaunchAtLogin(statusLabel: NSTextField) {
        do {
            let status = try LaunchAtLoginManager.enable()
            switch status {
            case .enabled:
                statusLabel.stringValue = "✓ Loop will launch when you sign in."
                statusLabel.textColor = .systemGreen
            case .requiresApproval:
                statusLabel.stringValue = "Approve Loop in System Settings → General → Login Items."
                statusLabel.textColor = .systemOrange
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            default:
                statusLabel.stringValue = "Couldn't register Loop as a login item (status: \(status.rawValue))."
                statusLabel.textColor = .systemOrange
            }
        } catch {
            statusLabel.stringValue = "Couldn't enable launch at login: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }

    // MARK: - Step 4: First command

    private func buildFirstCommandView() -> NSView {
        let avatar = AvatarView(gridW: 13, gridH: 13, pixelSize: 8, baseRadius: 4.0)
        avatar.mode = .listening
        avatar.translatesAutoresizingMaskIntoConstraints = false
        // Mirror the recorder bar's amplitude so the onboarding orb pulses in
        // sync with the live mic — adds a "Loop is hearing you" beat to the
        // moment the user first holds fn+ctrl.
        coordinator?.onAmplitude = { [weak avatar] amp in
            avatar?.amplitude = amp
        }

        let title = makeTitle("Hold fn + ⌃ and say something")
        let hotkeyVisual = HotkeyVisualView()
        hotkeyVisual.translatesAutoresizingMaskIntoConstraints = false
        let body = makeSubtitle("The bar at the bottom of your screen is Loop. Hold fn + ⌃ from anywhere — even another app — and start talking. Release when you're done. Whatever you say becomes your first message.")

        let micRow = buildMicPickerRow()
        let hint = makeStepHint("Waiting for your first message…")

        let stack = NSStackView(views: [avatar, title, hotkeyVisual, body, micRow, NSView(), hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(18, after: hotkeyVisual)
        stack.setCustomSpacing(18, after: body)
        return stack
    }

    /// "Microphone: [▼ Device]" row shown on the first-command step so the
    /// user can confirm or switch their input before recording their first
    /// turn. Selection writes through to `MicrophoneManager.shared.selectedUID`,
    /// which the recorder's audio engine reads on the next session.
    private func buildMicPickerRow() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Microphone")
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        rebuildMicPopup(popup)
        popup.target = self
        popup.action = #selector(micPopupChanged(_:))
        // CoreAudio hot-plug events arrive on a different code path
        // (MicrophoneSettings owns its own listener). Onboarding is short, so
        // instead of installing a CoreAudio listener here, we just rebuild
        // the menu each time it's about to open — covers the "user plugs in
        // a USB mic mid-onboarding" case without extra plumbing.
        micPopupObserver = NotificationCenter.default.addObserver(
            forName: NSPopUpButton.willPopUpNotification,
            object: popup,
            queue: .main
        ) { [weak self, weak popup] _ in
            guard let popup else { return }
            self?.rebuildMicPopup(popup)
        }
        micPopup = popup

        let row = NSStackView(views: [icon, label, popup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func rebuildMicPopup(_ popup: NSPopUpButton) {
        let prevSelectedUID = MicrophoneManager.shared.selectedUID
        popup.removeAllItems()

        let devices = MicrophoneManager.shared.inputDevices()
        let defaultDevice = MicrophoneManager.shared.systemDefaultInput()
        let defaultTitle = defaultDevice.map { "System default — \($0.name)" } ?? "System default"
        popup.addItem(withTitle: defaultTitle)
        popup.lastItem?.representedObject = nil as String?

        for device in devices {
            popup.addItem(withTitle: device.name)
            popup.lastItem?.representedObject = device.uid
        }

        let restoreIdx: Int
        if let prevUID = prevSelectedUID,
           let match = (0..<popup.numberOfItems).first(where: {
               (popup.item(at: $0)?.representedObject as? String) == prevUID
           }) {
            restoreIdx = match
        } else {
            restoreIdx = 0
        }
        popup.selectItem(at: restoreIdx)
    }

    @objc private func micPopupChanged(_ sender: NSPopUpButton) {
        let uid = sender.selectedItem?.representedObject as? String
        MicrophoneManager.shared.selectedUID = uid
    }

    /// Subscribes to coordinator state for the lifetime of step 4. We watch
    /// two signals because they don't overlap:
    ///
    /// - `state == .thinking` covers the LLM-bound path (typed message
    ///   submitted to the model, voice transcript routed through Cloud).
    /// - `voiceLoopUserMessageSubmitted` covers the case where the
    ///   conversational onboarding script consumes the text inline — the
    ///   coordinator's state never leaves `.idle` in that flow, so a
    ///   state-only observer would never dismiss this window.
    ///
    /// Either fires the same `complete()` path; the second fire is a no-op
    /// because `complete()` is idempotent (tears down both observers).
    private func observeFirstTurn() {
        guard let coord = coordinator else { return }
        previousOnStateChange = coord.onStateChange
        coord.onStateChange = { [weak self] state in
            // Forward to the existing handler so the recorder bar still
            // updates its UI in lockstep.
            self?.previousOnStateChange?(state)
            if state == .thinking {
                DispatchQueue.main.async { self?.complete() }
            }
        }
        firstTurnSubmitObserver = NotificationCenter.default.addObserver(
            forName: .voiceLoopUserMessageSubmitted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.complete()
        }
    }

    // MARK: - Builders

    private func makeTitle(_ s: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: s)
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        return label
    }

    private func makeSubtitle(_ s: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: s)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 4
        return label
    }

    private func makeStepHint(_ s: String) -> NSTextField {
        let label = NSTextField(labelWithString: s)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        return label
    }

    private func makePrimaryButton(title: String, action: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        return button
    }

    private func makeSecondaryButton(title: String, action: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        return button
    }
}

/// NSButton that owns its action closure. Avoids the target/selector
/// boilerplate when each step builds buttons inline with different actions.
final class ClosureButton: NSButton {
    private var actionClosure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.actionClosure = action
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(invoke)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { actionClosure() }
}
