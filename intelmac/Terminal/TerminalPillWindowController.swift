//
//  TerminalPillWindowController.swift
//  LoopMac
//
//  A small floating pill that sits just above the recorder bar (the
//  "orb"). Visible whenever the currently-active conversation has a
//  terminal session attached — running or recently exited. Tapping the
//  pill brings the in-app terminal window forward.
//
//  We deliberately make this a separate NSPanel rather than wedging it
//  inside the recorder bar's content view: the recorder is a non-
//  activating panel and shows/hides on its own schedule (click-away,
//  focus follows fn+ctrl, etc). Keeping the pill in its own panel means
//  it can stay visible when the recorder hides — which matters for the
//  "I can come back later and review" case where the chat surface might
//  not be active any more.
//

import AppKit
import Foundation

final class TerminalPillWindowController: NSWindowController {

    /// Recorder bar we anchor above. Weak — AppDelegate owns the recorder.
    private weak var recorder: RecorderWindowController?

    private let pill = NSView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "Terminal")
    private let chevron = NSImageView()

    /// Cached current session id so a click can open the matching window
    /// without re-querying the store mid-click.
    private var currentSessionId: String?

    init(recorder: RecorderWindowController) {
        self.recorder = recorder

        let rect = NSRect(x: 0, y: 0, width: 140, height: 30)
        let panel = TerminalPillPanel(contentRect: rect,
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered,
                                       defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        super.init(window: panel)
        configureContent()
        observe()
        panel.orderOut(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Content

    private func configureContent() {
        guard let window = window else { return }

        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 15
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.separatorColor.cgColor
        window.contentView = backdrop

        pill.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(pill)

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        pill.addSubview(dot)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        pill.addSubview(label)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Open terminal")
        chevron.contentTintColor = .secondaryLabelColor
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        pill.addSubview(chevron)

        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            pill.topAnchor.constraint(equalTo: backdrop.topAnchor),
            pill.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),

            dot.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            chevron.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            chevron.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 14),
            chevron.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])

        // The dot would overlap the chevron in this layout — hide it.
        // We keep the dot's view around so a future "active vs idle"
        // distinction can swap which symbol is visible without re-laying-
        // out the whole pill.
        dot.isHidden = true

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        pill.addGestureRecognizer(click)
    }

    // MARK: - Observation

    private func observe() {
        // Recorder bar visibility: the pill is anchored to the bar, so
        // when the bar dismisses (click-away, Escape, onboarding
        // suppression) the pill should disappear with it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChange),
            name: .recorderBarVisibilityChanged,
            object: nil
        )
        // Reposition the pill when the recorder bar grows/shrinks (the
        // bar resizes itself vertically as the user types multi-line
        // input). Tied to the recorder's specific window so we don't
        // react to unrelated windows resizing.
        if let recorderWindow = recorder?.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleStoreChange),
                name: NSWindow.didResizeNotification,
                object: recorderWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleStoreChange),
                name: NSWindow.didMoveNotification,
                object: recorderWindow
            )
        }
        // Session-level events: a new session was created or exited for
        // some conversation. Always re-check whether ours has one now.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChange),
            name: .terminalSessionStoreDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChange),
            name: .terminalSessionDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChange),
            name: .terminalSessionDidExit,
            object: nil
        )
        // Explicit "the active conversation switched" signal posted by
        // SimpleConversationManager whenever its currentConversation id
        // changes — fires on Mac tab switches, sidebar picks, scheduled-
        // task tap routing, anywhere currentConversation is reassigned.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChange),
            name: .activeConversationDidChange,
            object: nil
        )
    }

    @objc private func handleStoreChange() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    // MARK: - Visibility / placement

    func refresh() {
        // The pill is anchored to the recorder bar. When the bar isn't
        // on screen, the pill has nothing to hang off of — hide it
        // unconditionally rather than leave a floating chip with no
        // visible parent.
        guard let recorderVisible = recorder?.window?.isVisible, recorderVisible else {
            hide()
            return
        }
        // Always derive the conversation from the active tab — the user
        // expects the pill to follow whichever conversation they're
        // looking at, not some long-ago stashed value.
        guard let convId = SimpleConversationManager.shared.currentConversation?.id else {
            hide()
            return
        }
        // We show the pill if there's any primary session for this
        // conversation — running OR exited — because the spec says the
        // user should be able to come back and review history even after
        // the task is done.
        guard let session = TerminalSessionStore.shared.primarySession(forConversation: convId) else {
            hide()
            return
        }
        currentSessionId = session.id
        if session.isRunning {
            label.stringValue = "Terminal — running"
            chevron.contentTintColor = NSColor.systemGreen
        } else {
            label.stringValue = "Terminal — review"
            chevron.contentTintColor = NSColor.secondaryLabelColor
        }
        show()
    }

    private func show() {
        guard let window = window, let recorder = recorder else { return }
        guard let recorderWindow = recorder.window else { return }
        let recorderFrame = recorderWindow.frame
        let pillFrame = window.frame
        // Park the pill just above the recorder bar, horizontally centered.
        // The recorder bar tops out at recorderFrame.maxY; an 8pt gap
        // separates the two so they read as related but distinct surfaces.
        let originX = recorderFrame.midX - pillFrame.width / 2
        let originY = recorderFrame.maxY + 8
        window.setFrameOrigin(NSPoint(x: originX, y: originY))
        window.orderFrontRegardless()
    }

    private func hide() {
        window?.orderOut(nil)
    }

    // MARK: - Click → open terminal window

    @objc private func handleClick() {
        guard let sid = currentSessionId,
              let session = TerminalSessionStore.shared.session(id: sid) else { return }
        TerminalWindowController.show(for: session)
    }
}

/// A clone of `RecorderPanel`'s "can become key but never main" behavior.
/// Without this the borderless panel can't receive the click gesture in
/// some focus states (NSPanel-with-no-key-window swallows mouse events).
final class TerminalPillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
