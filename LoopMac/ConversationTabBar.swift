//
//  ConversationTabBar.swift
//  LoopMac
//
//  Tab-bar surface that lives between the toolbar and the avatar in the
//  conversation window. Each tab represents an independently-running
//  VoiceLoopCoordinator (with its own SimpleConversation), so the user can
//  start a turn in one tab, switch to another, and the first tab's chat
//  finishes in the background.
//
//  Visible only when 2+ tabs exist. Horizontally scrollable when the cells
//  overflow. ⌘+N labels appear on the right of each tab for tabs 1-9.
//

import AppKit

// MARK: - ConversationTab

/// One open tab. Owns the SimpleConversation it displays plus the coordinator
/// driving its in-flight turn. The window keeps the array; the coordinator
/// keeps running even when the tab isn't visible.
final class ConversationTab {
    let id = UUID()
    var conversation: SimpleConversation
    let coordinator: VoiceLoopCoordinator
    /// Tab owns the per-tab presenter wrapper because the coordinator's
    /// `conversationPresenter` is weak (it doesn't claim ownership). Keeping
    /// this strong reference here means the wrapper lives exactly as long
    /// as the tab — close the tab, the wrapper goes too.
    var presenter: TabConversationPresenter?
    /// Last `setThinking` value this tab's coordinator pushed at us. Tracked
    /// per-tab so a background tab's "Thinking…" label doesn't bleed into
    /// the foreground tab's bottom hint, and so switching back to that tab
    /// restores its own thinking state instead of whatever was last visible.
    var isThinking: Bool = false
    var thinkingLabel: String?

    init(conversation: SimpleConversation, coordinator: VoiceLoopCoordinator) {
        self.conversation = conversation
        self.coordinator = coordinator
    }
}

// MARK: - Tab bar view

protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelectTabAt index: Int)
    func tabBar(_ bar: TabBarView, didCloseTabAt index: Int)
}

/// Horizontal strip of TabCellViews wrapped in a borderless NSScrollView so the
/// cells can overflow into a horizontal scroll once enough tabs are open. The
/// view itself collapses to zero intrinsic height when it has < 2 tabs, so the
/// conversation window's layout doesn't carry a visible blank band on the
/// single-tab path.
final class TabBarView: NSView {
    weak var delegate: TabBarViewDelegate?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    /// Per-tab cells, in display order. Owned here so reconfigure can mutate
    /// state without rebuilding from scratch on every tab swap.
    private var cells: [TabCellView] = []
    /// Drives the collapse-to-zero animation when we drop below 2 tabs. Held
    /// as a stored constraint so reconfigure can flip the constant without
    /// fighting AutoLayout's intrinsic-size fallback.
    private var heightConstraint: NSLayoutConstraint!

    private static let barHeight: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        // Wrap the stack in a flipped document view so NSScrollView can
        // resize its bounds correctly when cells are added or removed —
        // otherwise the scroll content keeps an old width and tabs near the
        // trailing edge end up clipped.
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scrollView.documentView = doc

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        // High priority so it definitively wins over the stack's intrinsic
        // height — without this the inner 24pt cell would push our outer
        // view past 0 when we want it collapsed.
        heightConstraint.priority = .required - 1

        NSLayoutConstraint.activate([
            heightConstraint,

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    /// Refresh the visible cells from the supplied tabs. Cheap to call after
    /// every state change — we diff length and re-bind metadata rather than
    /// recreating cells unless the count moved.
    func reconfigure(tabs: [ConversationTab], activeIndex: Int) {
        // Resize the cell pool to match.
        while cells.count > tabs.count {
            let cell = cells.removeLast()
            stack.removeArrangedSubview(cell)
            cell.removeFromSuperview()
        }
        while cells.count < tabs.count {
            let cell = TabCellView()
            cell.onSelect = { [weak self, weak cell] in
                guard let self = self, let cell = cell,
                      let idx = self.cells.firstIndex(where: { $0 === cell }) else { return }
                self.delegate?.tabBar(self, didSelectTabAt: idx)
            }
            cell.onClose = { [weak self, weak cell] in
                guard let self = self, let cell = cell,
                      let idx = self.cells.firstIndex(where: { $0 === cell }) else { return }
                self.delegate?.tabBar(self, didCloseTabAt: idx)
            }
            cells.append(cell)
            stack.addArrangedSubview(cell)
        }

        for (i, tab) in tabs.enumerated() {
            let shortcutLabel = (i < 9) ? "⌘\(i + 1)" : ""
            cells[i].configure(
                title: tab.conversation.title,
                shortcut: shortcutLabel,
                isActive: i == activeIndex,
                isRunning: tab.coordinator.state == .thinking
                    || tab.coordinator.state == .transcribing
            )
        }

        // Collapse the entire band to zero when there's only one tab — the
        // strip is meant to disappear, not just hide its cells.
        heightConstraint.constant = (cells.count < 2) ? 0 : Self.barHeight
        isHidden = cells.count < 2
    }
}

// MARK: - Tab cell

/// One row in the tab bar. Three visual pieces:
///  - Title label (truncated to fit).
///  - ⌘N shortcut hint on the right (grey, monospace digit).
///  - Close (×) button that fades in on hover.
final class TabCellView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let runningDot = NSView()

    private var isActive: Bool = false
    private var isHovering: Bool = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        runningDot.translatesAutoresizingMaskIntoConstraints = false
        runningDot.wantsLayer = true
        runningDot.layer?.cornerRadius = 3
        runningDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        runningDot.isHidden = true
        addSubview(runningDot)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        shortcutLabel.textColor = .tertiaryLabelColor
        addSubview(shortcutLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Close Tab")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),

            runningDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            runningDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            runningDot.widthAnchor.constraint(equalToConstant: 6),
            runningDot.heightAnchor.constraint(equalToConstant: 6),

            titleLabel.leadingAnchor.constraint(equalTo: runningDot.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -6),

            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        applyAppearance()
    }

    private var isRunning: Bool = false

    func configure(title: String, shortcut: String, isActive: Bool, isRunning: Bool) {
        titleLabel.stringValue = title.isEmpty ? "Untitled" : title
        shortcutLabel.stringValue = shortcut
        self.isActive = isActive
        self.isRunning = isRunning
        applyAppearance()
    }

    private func applyAppearance() {
        if isActive {
            // Filled state — accent-tinted background, primary-color text.
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            titleLabel.textColor = .labelColor
            titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        } else {
            layer?.backgroundColor = isHovering
                ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
                : NSColor.clear.cgColor
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        }
        // The close button and the "running" dot share the left-side slot.
        // Close (visible on hover or for the active tab) takes precedence —
        // hide the dot underneath so the icon doesn't sit on a colored speck.
        let showClose = isHovering || isActive
        closeButton.isHidden = !showClose
        runningDot.isHidden = !isRunning || showClose
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        // Single-click anywhere in the cell (except on the close button —
        // AppKit consumes its click) activates the tab.
        onSelect?()
    }

    @objc private func closeTapped() {
        onClose?()
    }
}
