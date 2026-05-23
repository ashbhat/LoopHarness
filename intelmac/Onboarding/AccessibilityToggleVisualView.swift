//
//  AccessibilityToggleVisualView.swift
//  LoopMac
//
//  Animated preview of the LoopMac row inside System Settings → Privacy &
//  Security → Accessibility. Shown on the onboarding accessibility step so
//  the user knows exactly what to look for once they open the pane: an app
//  icon, the "LoopMac" label, and a toggle to flip on.
//

import AppKit
import QuartzCore

final class AccessibilityToggleVisualView: NSView {

    private let cardLayer = CALayer()
    private let cardBorderLayer = CALayer()
    private let iconImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "LoopMac")
    private let toggleView = ToggleSwitchView()
    private var cycleTimer: Timer?
    private var pendingWork: [DispatchWorkItem] = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        wantsLayer = true

        cardLayer.cornerRadius = 10
        layer?.addSublayer(cardLayer)
        cardBorderLayer.cornerRadius = 10
        cardBorderLayer.borderWidth = 1
        cardBorderLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(cardBorderLayer)

        let icon: NSImage = NSImage(named: NSImage.applicationIconName)
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
            ?? NSImage()
        iconImageView.image = icon
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        toggleView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconImageView)
        addSubview(nameLabel)
        addSubview(toggleView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            widthAnchor.constraint(equalToConstant: 320),

            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 32),
            iconImageView.heightAnchor.constraint(equalToConstant: 32),

            nameLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            toggleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toggleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleView.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 12),
        ])

        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 320, height: 56) }

    override func layout() {
        super.layout()
        cardLayer.frame = bounds
        cardBorderLayer.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            cardLayer.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
            cardBorderLayer.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startAnimating() } else { stopAnimating() }
    }

    deinit { stopAnimating() }

    private func startAnimating() {
        stopAnimating()
        toggleView.setOn(false, animated: false)
        runCycle()
        // ~3.2s per loop: 0.6s off → animate on → ~2s held → snap off → loop.
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 3.2, repeats: true) { [weak self] _ in
            self?.runCycle()
        }
    }

    private func stopAnimating() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        pendingWork.forEach { $0.cancel() }
        pendingWork.removeAll()
    }

    private func runCycle() {
        toggleView.setOn(false, animated: false)
        schedule(after: 0.6) { self.toggleView.setOn(true) }
    }

    private func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        let item = DispatchWorkItem(block: block)
        pendingWork.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

/// Toggle switch styled to match the system NSSwitch — track recolors to the
/// accent color when on, knob slides across with a soft shadow.
private final class ToggleSwitchView: NSView {

    private let trackLayer = CALayer()
    private let knobLayer = CALayer()
    private let intrinsicW: CGFloat = 42
    private let intrinsicH: CGFloat = 26
    private let knobInset: CGFloat = 2
    private var on = false

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 42, height: 26))
        wantsLayer = true
        layer?.masksToBounds = false

        trackLayer.cornerRadius = intrinsicH / 2
        layer?.addSublayer(trackLayer)

        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.22
        knobLayer.shadowRadius = 1.5
        knobLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(knobLayer)

        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: intrinsicW, height: intrinsicH) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.cornerRadius = bounds.height / 2
        layoutKnob()
        CATransaction.commit()
    }

    private func layoutKnob() {
        let knobSize = bounds.height - knobInset * 2
        let knobX = on ? bounds.width - knobSize - knobInset : knobInset
        knobLayer.frame = CGRect(x: knobX, y: knobInset, width: knobSize, height: knobSize)
        knobLayer.cornerRadius = knobSize / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            trackLayer.backgroundColor = on
                ? NSColor.controlAccentColor.cgColor
                : NSColor.tertiaryLabelColor.cgColor
        }
    }

    func setOn(_ value: Bool, animated: Bool = true) {
        on = value
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.30)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut)
            )
        } else {
            CATransaction.setDisableActions(true)
        }
        layoutKnob()
        applyAppearance()
        CATransaction.commit()
    }
}
