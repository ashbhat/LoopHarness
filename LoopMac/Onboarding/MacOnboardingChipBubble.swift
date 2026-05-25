//
//  MacOnboardingChipBubble.swift
//  LoopMac
//
//  Renders a single onboarding message bubble for the Mac chat — the same
//  shared `OnboardingCoordinator` script that drives iOS posts these here.
//  Two layouts:
//   - `.suggestions(options:)` — bubble text + wrapping chip row below.
//     Chip tap fires `.choiceSelected(...)` through the delegate.
//   - `.answered` — bubble text only (chips collapsed after the user replied).
//
//  Mac doesn't get the `.actionButtonWalkthrough` step because the Mac chat
//  has no Action Button to bind (`OnboardingCoordinator.skipActionButtonStep`
//  routes past it). If a future change reintroduces a Mac walkthrough we'd
//  add the rendering here.
//

import AppKit

/// Tap callbacks bubble up here. `ConversationWindowController` adopts this
/// and forwards events to `OnboardingCoordinator.handleCardEvent(_:)`.
protocol MacOnboardingChipDelegate: AnyObject {
    func macOnboardingChipDidFire(_ event: OnboardingCardEvent)
}

enum MacOnboardingChipBubble {

    /// Build the assistant bubble row for an onboarding message. The prose
    /// renders the same as a regular assistant bubble; the chip row sits
    /// under it inside the same vertical column.
    static func makeBubble(text: String,
                           card: OnboardingCardKind,
                           delegate: MacOnboardingChipDelegate?) -> NSView {
        let bubble = NSView()
        bubble.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: bubble.trailingAnchor, constant: -4),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])

        let bottomAnchorView: NSView
        switch card {
        case .suggestions(let options):
            let chipRow = makeChipRow(options: options, delegate: delegate)
            bubble.addSubview(chipRow)
            NSLayoutConstraint.activate([
                chipRow.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
                chipRow.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 4),
                chipRow.trailingAnchor.constraint(lessThanOrEqualTo: bubble.trailingAnchor, constant: -4),
                chipRow.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            ])
            bottomAnchorView = chipRow

        case .actionButtonWalkthrough:
            // Mac shouldn't see this — `skipActionButtonStep` redirects past
            // it. If it slips through, render text only as a safe fallback
            // rather than crashing.
            bottomAnchorView = label

        case .answered:
            bottomAnchorView = label
        }

        bubble.bottomAnchor.constraint(equalTo: bottomAnchorView.bottomAnchor, constant: 4).isActive = true

        // Left-align the assistant bubble row, matching the existing
        // `makeBubble(role:text:model:)` layout shape in
        // `ConversationWindowController` so onboarding bubbles look native.
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        row.addArrangedSubview(bubble)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }

    // MARK: - Chip layout

    /// Builds a wrapping chip row by chunking chips into horizontal stacks
    /// at a width budget. Matches the iOS card's chip-flow behavior with
    /// AppKit primitives.
    private static func makeChipRow(options: [OnboardingChoiceOption],
                                    delegate: MacOnboardingChipDelegate?) -> NSView {
        let outer = NSStackView()
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8

        let rowWidthBudget: CGFloat = 380
        let chipSpacing: CGFloat = 8

        var rows: [[NSView]] = [[]]
        var rowWidth: CGFloat = 0
        for option in options {
            let chip = makeChip(label: option.label) { [weak delegate] in
                delegate?.macOnboardingChipDidFire(
                    .choiceSelected(optionId: option.id, label: option.label))
            }
            let chipWidth = chip.fittingSize.width
            let widthIfAppended = rows[rows.count - 1].isEmpty
                ? chipWidth
                : rowWidth + chipSpacing + chipWidth
            if !rows[rows.count - 1].isEmpty && widthIfAppended > rowWidthBudget {
                rows.append([chip])
                rowWidth = chipWidth
            } else {
                rows[rows.count - 1].append(chip)
                rowWidth = widthIfAppended
            }
        }

        for chipsInRow in rows where !chipsInRow.isEmpty {
            let row = NSStackView(views: chipsInRow)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = chipSpacing
            outer.addArrangedSubview(row)
        }
        return outer
    }

    /// One pill-shaped tappable chip. NSButton with a custom cell so we can
    /// fully control the corner radius, fill, and text color — AppKit's
    /// stock `bezelStyle = .rounded` looks too "control-y" for an inline
    /// chat chip.
    private static func makeChip(label: String, action: @escaping () -> Void) -> NSView {
        let button = ChipButton(title: label, action: action)
        return button
    }
}

// MARK: - ChipButton

/// A pill-shaped chip rendered with a custom NSButtonCell so it matches the
/// chat's tonal palette in both light and dark mode. Owns its tap closure
/// to keep the call sites in `MacOnboardingChipBubble` declarative.
private final class ChipButton: NSButton {

    private let actionClosure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.actionClosure = action
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.title = title
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 12
        self.layer?.cornerCurve = .continuous
        self.contentTintColor = .labelColor
        self.font = .systemFont(ofSize: 13, weight: .medium)
        self.target = self
        self.action = #selector(invoke)
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        // Add capsule padding to the system intrinsic size.
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 22, height: 26)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    @objc private func invoke() { actionClosure() }

    private func applyTint() {
        // A custom mid-tone chip color. `.controlColor` looks too high-
        // contrast (matches push buttons); a custom NSColor that resolves
        // to a soft gray in both modes feels right at home in chat.
        let isDark = (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.06)).cgColor
    }
}
