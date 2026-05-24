//
//  TerminalWindowController.swift
//  LoopMac
//
//  In-app terminal window backed by a TerminalSession. Opens when the
//  user clicks the pill (or when the model's first command lands in a
//  conversation with no terminal yet) and stays around even after the
//  shell exits, so the user can come back and review what happened —
//  see "the terminal ui should also persist after the task is done."
//
//  Two interaction modes coexist:
//   1. Agent driving the session via `run_terminal_command` etc.
//   2. User typing directly into the input bar at the bottom.
//
//  Both write to the same pty master, so they appear interleaved in the
//  scrollback the way they would in a normal shared shell session. The
//  "Stop Loop" toolbar button doesn't kill the shell — it asks the agent
//  to back off, and the user can keep typing.
//

import AppKit
import Foundation

/// Per-session window: one TerminalWindowController per session so the
/// user can have multiple terminals open across different conversations.
final class TerminalWindowController: NSWindowController, NSTextFieldDelegate {

    let session: TerminalSession

    /// Output scrollback (monospaced text view inside a scroll view).
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    /// "Type here to take over" input bar at the bottom. Pressing Enter
    /// writes the typed line into the pty just as if the user were sitting
    /// in front of a normal Terminal.app window.
    private let inputField = NSTextField()
    /// Toolbar button that broadcasts the "user wants to take over"
    /// intent so any agent loop driving this session knows to stop
    /// sending commands. The shell stays alive.
    private let stopLoopButton = NSButton(title: "Stop Loop",
                                          target: nil,
                                          action: nil)
    /// Subtle status line above the input bar: "running" / "exited (code N)".
    private let statusLabel = NSTextField(labelWithString: "")

    /// One window per session — we keep a controller cache in
    /// `presentedControllers` keyed by session id so a second tap on the
    /// pill brings the existing window forward instead of cloning a new
    /// one.
    private static var presentedControllers: [String: TerminalWindowController] = [:]

    /// Open / bring-to-front entry point. Use this instead of the init
    /// directly so the cache is kept honest.
    @discardableResult
    static func show(for session: TerminalSession) -> TerminalWindowController {
        if let existing = presentedControllers[session.id] {
            existing.surface()
            return existing
        }
        let wc = TerminalWindowController(session: session)
        presentedControllers[session.id] = wc
        wc.surface()
        return wc
    }

    private init(session: TerminalSession) {
        self.session = session
        let rect = NSRect(x: 0, y: 0, width: 760, height: 480)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.title = TerminalWindowController.title(for: session)
        window.minSize = NSSize(width: 520, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureContent()
        observeSession()
        renderFullBuffer()
        refreshStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI

    private func configureContent() {
        guard let window = window else { return }

        let content = NSView()
        content.wantsLayer = true
        // Match the dark "terminal" aesthetic so the in-app surface reads
        // as a different mode than the chat windows. Background is the
        // labelColor's dark-mode complement; text gets a fixed off-white.
        content.layer?.backgroundColor = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1.0).cgColor

        // Standard NSScrollView + NSTextView setup. The textView is NOT
        // autolayout-managed — NSScrollView positions its documentView
        // manually based on its own contentSize, and the textView's
        // autoresizing mask handles width changes. The earlier version
        // here set `translatesAutoresizingMaskIntoConstraints = false`
        // without giving the textView any constraints, which left its
        // frame at 0×0 and its text container width at 0 — every line of
        // output went into the buffer but rendered to nothing.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(srgbRed: 0.92, green: 0.92, blue: 0.9, alpha: 1.0)
        textView.backgroundColor = .clear
        textView.allowsUndo = false
        textView.textContainer?.containerSize = NSSize(width: 1,
                                                        height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        // Don't wrap mid-word inside fixed-width lines of shell output.
        textView.textContainer?.lineBreakMode = .byCharWrapping
        scrollView.documentView = textView
        content.addSubview(scrollView)

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        inputField.placeholderString = "Type here to take over — Enter to send"
        inputField.backgroundColor = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)
        inputField.textColor = .white
        inputField.bezelStyle = .roundedBezel
        inputField.isBordered = false
        inputField.focusRingType = .none
        inputField.delegate = self
        content.addSubview(inputField)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor(srgbRed: 0.7, green: 0.7, blue: 0.7, alpha: 1.0)
        content.addSubview(statusLabel)

        stopLoopButton.translatesAutoresizingMaskIntoConstraints = false
        stopLoopButton.bezelStyle = .rounded
        stopLoopButton.controlSize = .small
        stopLoopButton.target = self
        stopLoopButton.action = #selector(stopLoopClicked)
        content.addSubview(stopLoopButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: stopLoopButton.leadingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -6),

            stopLoopButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stopLoopButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),

            inputField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            inputField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            inputField.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            inputField.heightAnchor.constraint(equalToConstant: 26),
        ])

        window.contentView = content
    }

    // MARK: - Surfacing

    func surface() {
        guard let window = window else { return }
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Drop focus straight into the input field — the most common reason
        // to open the terminal is to take over, and that should be a single
        // gesture (pill tap → start typing) not two.
        window.makeFirstResponder(inputField)
    }

    // MARK: - Observation

    private func observeSession() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionUpdate(_:)),
            name: .terminalSessionDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionExit(_:)),
            name: .terminalSessionDidExit,
            object: nil
        )
    }

    @objc private func handleSessionUpdate(_ note: Notification) {
        guard let sid = note.userInfo?["sessionId"] as? String, sid == session.id else { return }
        renderFullBuffer()
    }

    @objc private func handleSessionExit(_ note: Notification) {
        guard let sid = note.userInfo?["sessionId"] as? String, sid == session.id else { return }
        // Don't tear the window down — spec says it persists so the user
        // can come back and review. We just flip the status line.
        refreshStatus()
        // Keep the input field disabled once the shell is gone: writing
        // would silently no-op, which is more confusing than visibly
        // greying out the field.
        inputField.isEnabled = false
        inputField.placeholderString = "Session ended — review only"
    }

    // MARK: - Rendering

    /// Cheap and correct: rebuild the text view's contents from the
    /// session's display buffer on every update. The buffer is plain
    /// String, not attributed, so this is O(n) without per-frame
    /// allocation overhead worth worrying about for terminal-sized
    /// scrollback. Optimizing to incremental appends is a follow-up if
    /// large sessions start hitching.
    /// Rebuild the text view from the session's current display buffer.
    ///
    /// We can't do incremental appends here: the screen buffer
    /// processes \r overwrites and erase sequences, so its rendered
    /// output can SHRINK between ticks. A spinner that redraws on the
    /// same line shows up as a single line whose contents flip every
    /// frame — we have to replace the whole textStorage to reflect
    /// that.
    ///
    /// To keep the rebuild from disrupting the user mid-interaction we
    /// save/restore:
    ///   - text selection (clamped if the buffer shrank past it),
    ///   - "was near bottom" state — pinned to the bottom for live tail
    ///     when the user was already there, otherwise the previous
    ///     scroll position is preserved.
    private func renderFullBuffer() {
        let snapshot = session.displayOutput
        let pinnedToBottom = isScrolledNearBottom()
        let savedSelection = textView.selectedRange()
        let savedVisibleRect = scrollView.contentView.documentVisibleRect

        let attrs: [NSAttributedString.Key: Any] = [
            .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: textView.textColor ?? NSColor.white,
        ]
        if let storage = textView.textStorage {
            storage.setAttributedString(NSAttributedString(string: snapshot, attributes: attrs))
        } else {
            textView.string = snapshot
        }

        // Restore the user's view of the buffer.
        if pinnedToBottom {
            textView.scrollToEndOfDocument(nil)
        } else {
            scrollView.contentView.scroll(to: savedVisibleRect.origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        let newLen = (textView.string as NSString).length
        if savedSelection.location <= newLen {
            let clampedLen = min(savedSelection.length,
                                  max(0, newLen - savedSelection.location))
            textView.setSelectedRange(NSRange(location: savedSelection.location, length: clampedLen))
        }
    }

    /// True when the visible bottom of the scrollView's clipView is
    /// within ~40pt of the document's bottom. That's the threshold for
    /// "the user is following along" — outside it we assume they've
    /// scrolled up deliberately and leave their position alone.
    private func isScrolledNearBottom() -> Bool {
        guard let docView = scrollView.documentView else { return true }
        let visible = scrollView.contentView.documentVisibleRect
        let bottomGap = docView.bounds.maxY - visible.maxY
        return bottomGap < 40
    }

    private func refreshStatus() {
        if session.isRunning {
            statusLabel.stringValue = "● running · \(session.workingDir)"
            statusLabel.textColor = NSColor.systemGreen
        } else {
            let codeText = session.exitCode.map { " (exit \($0))" } ?? ""
            statusLabel.stringValue = "○ exited\(codeText) · \(session.workingDir)"
            statusLabel.textColor = NSColor.systemRed
        }
    }

    // MARK: - Input

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let text = inputField.stringValue
            inputField.stringValue = ""
            // runCommand writes the line + a carriage return so the shell
            // sees an Enter press. Empty input still sends \r (matches a
            // real terminal where pressing Enter on an empty line redraws
            // the prompt) — useful when the user just wants a fresh prompt.
            session.runCommand(text)
            return true
        }
        return false
    }

    // MARK: - Actions

    @objc private func stopLoopClicked() {
        // Post the "user took over" intent so any active agent loop can
        // wind down. The session itself stays alive — that's the whole
        // point of the spec's "stop loop and take over" affordance.
        NotificationCenter.default.post(
            name: .terminalUserTookOver,
            object: nil,
            userInfo: ["sessionId": session.id]
        )
        // Surface what happened in the scrollback so the user knows the
        // automation has bowed out. This is a UI-only banner — it isn't
        // written to the session's buffer, so it won't reappear if the
        // window is closed and reopened. That's intentional: the banner
        // is a transient affordance, not part of the shell transcript.
        if let storage = textView.textStorage {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.systemYellow,
            ]
            storage.append(NSAttributedString(string: "\n[Loop stopped — you have control]\n", attributes: attrs))
        }
        textView.scrollToEndOfDocument(nil)
        window?.makeFirstResponder(inputField)
    }

    // MARK: - Helpers

    private static func title(for session: TerminalSession) -> String {
        let dir = (session.workingDir as NSString).lastPathComponent
        return "Terminal — \(dir)"
    }
}

extension Notification.Name {
    /// Fired by the terminal window's "Stop Loop" button. Any future agent
    /// runtime that wants to be polite watches this so it can stop firing
    /// new commands into the session while the user is mid-takeover.
    static let terminalUserTookOver = Notification.Name("terminalUserTookOver")
}
