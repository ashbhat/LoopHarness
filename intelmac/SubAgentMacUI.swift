//
//  SubAgentMacUI.swift
//  LoopMac
//
//  Mac-side UI for the sub-agent runtime: a tappable status bar that sits at
//  the top of the conversation window and a floating inspector window with
//  the live agent list. Mirrors the iOS pill + sheet pattern.
//

import AppKit

// MARK: - Status bar

protocol SubAgentMacStatusBarDelegate: AnyObject {
    func subAgentStatusBarClicked()
}

final class SubAgentMacStatusBar: NSView {
    weak var delegate: SubAgentMacStatusBarDelegate?

    private let pill = NSView()
    private let dotView = NSView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    /// Height constraint we toggle to 0 when no sub-agents are alive — keeps
    /// the avatar / scroll view layout clean while idle.
    private var heightConstraint: NSLayoutConstraint?
    private let trackingArea: NSTrackingArea? = nil

    /// Conversation this pill is scoped to. Sub-agents only render here if
    /// they were spawned from this conversation; switching tabs flips the
    /// id and the pill re-counts. iOS pill mirrors this convention.
    var conversationId: String? {
        didSet {
            guard oldValue != conversationId else { return }
            refresh()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
        observeManager()
        refresh()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        observeManager()
        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint?.isActive = true

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        pill.layer?.cornerRadius = 13
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(pill)

        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = NSColor.systemGreen.cgColor
        dotView.layer?.cornerRadius = 4
        pill.addSubview(dotView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        pill.addSubview(label)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        pill.addSubview(chevron)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 26),

            dotView.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            dotView.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 8),
            dotView.heightAnchor.constraint(equalToConstant: 8),

            label.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            chevron.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            chevron.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])
    }

    private func observeManager() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(managerDidChange),
            name: .subAgentsDidChange,
            object: nil
        )
    }

    @objc private func managerDidChange() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func refresh() {
        let summary = SubAgentManager.shared.pillSummary(for: conversationId)
        if summary.isEmpty {
            heightConstraint?.constant = 0
            pill.isHidden = true
            return
        }
        heightConstraint?.constant = 32
        pill.isHidden = false
        label.stringValue = summary
        // Dot color: green/yellow while anything's running, gray once only
        // completed agents remain — same convention as the iOS pill.
        // Aggregate counts include Devin + Cursor jobs so a dispatched cloud
        // agent lights the dot green even though it isn't a native SubAgent.
        let liveCount = SubAgentManager.shared.aggregateLiveCount(for: conversationId)
        let color: NSColor
        if liveCount == 0 {
            color = .systemGray
        } else if SubAgentManager.shared.aggregateHasActive(for: conversationId) {
            color = .systemGreen
        } else {
            color = .systemYellow
        }
        dotView.layer?.backgroundColor = color.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        delegate?.subAgentStatusBarClicked()
    }

    override func resetCursorRects() {
        addCursorRect(pill.frame, cursor: .pointingHand)
    }
}

// MARK: - Inspector window

final class SubAgentInspectorWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// Single shared inspector so repeated clicks on the status bar bring the
    /// same window forward instead of opening duplicates.
    static let shared = SubAgentInspectorWindowController()

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No sub-agents running.")
    private var agents: [SubAgent] = []

    /// Conversation the inspector is currently scoped to. Set by the chat
    /// window when the user clicks the pill; switches at runtime when the
    /// user retargets the inspector by clicking a different tab's pill.
    /// `nil` means "show every agent" (legacy/fallback).
    private var conversationId: String?

    init() {
        let rect = NSRect(x: 0, y: 0, width: 480, height: 400)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.title = "Sub-agents"
        window.minSize = NSSize(width: 360, height: 280)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureContent()
        observeManager()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureContent() {
        guard let window = window else { return }
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        content.addSubview(scrollView)

        // Single full-width column. Each row renders a card with title + state
        // + step via SubAgentRowView (custom NSView) for richer layout than a
        // standard text cell.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agent"))
        column.width = 440
        column.minWidth = 200
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // Use explicit heights from `heightOfRow:` rather than automatic
        // height-from-constraints — the custom row view doesn't pin a
        // bottom anchor on every label, so automatic sizing would collapse
        // rows to ~0pt and the inspector would render blank.
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        scrollView.documentView = tableView

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        window.contentView = content
    }

    private func observeManager() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(managerDidChange),
            name: .subAgentsDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func managerDidChange() {
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    func reload() {
        // Mirror `SubAgentManager.allAgents` ordering (alive first, then done
        // by finish-time desc) within the scoped subset, so the list matches
        // what the user already saw in the unscoped view.
        let scoped = SubAgentManager.shared.liveAgents(for: conversationId)
            + SubAgentManager.shared.finishedAgents(for: conversationId)
        agents = scoped
        emptyLabel.isHidden = !agents.isEmpty
        tableView.reloadData()
    }

    /// Bring the inspector forward, optionally re-scoping it to a specific
    /// conversation. The chat window passes its active tab's conversation id
    /// so the inspector only shows agents belonging to the visible thread.
    func presentInFront(scopedTo conversationId: String? = nil) {
        if self.conversationId != conversationId {
            self.conversationId = conversationId
            reload()
        }
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        return agents.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < agents.count else { return nil }
        let agent = agents[row]
        let identifier = NSUserInterfaceItemIdentifier("SubAgentRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? SubAgentRowView
            ?? SubAgentRowView()
        view.identifier = identifier
        view.configure(with: agent)
        view.onStop = { [weak self] in
            SubAgentManager.shared.kill(id: agent.id)
            self?.reload()
        }
        view.onRemove = { [weak self] in
            SubAgentManager.shared.remove(id: agent.id)
            self?.reload()
        }
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 78
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < agents.count else { return }
        SubAgentDetailWindowController.show(agentId: agents[row].id)
    }
}

// MARK: - Detail window
//
// Opened by a double-click on a row in the inspector. Shows the agent's full
// log feed in reverse-chronological order (newest first) plus its current
// state header, so the user can read the complete flow — for a running agent
// it tracks live via `subAgentsDidChange`; for a completed one it's a frozen
// history. We key windows by agent id so each agent gets its own window —
// double-clicking the same row again refocuses the existing window instead
// of re-opening it.

final class SubAgentDetailWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    /// Stash of open detail windows keyed by agent id. Prevents duplicate
    /// windows for the same agent and lets external state changes broadcast
    /// to whichever windows are currently open.
    private static var openWindows: [String: SubAgentDetailWindowController] = [:]

    static func show(agentId: String) {
        if let existing = openWindows[agentId] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SubAgentDetailWindowController(agentId: agentId)
        openWindows[agentId] = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let agentId: String
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let stepLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No activity yet.")
    /// Reversed for display — newest entry on top, closest to a console feel.
    private var entries: [SubAgentLogEntry] = []

    init(agentId: String) {
        self.agentId = agentId
        let rect = NSRect(x: 0, y: 0, width: 560, height: 480)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.title = "Sub-agent"
        window.minSize = NSSize(width: 420, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureContent()
        observeManager()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureContent() {
        guard let window = window else { return }
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.maximumNumberOfLines = 2
        content.addSubview(headerLabel)

        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        stepLabel.font = NSFont.systemFont(ofSize: 11)
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(stepLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        content.addSubview(scrollView)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("log"))
        column.width = 520
        column.minWidth = 240
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.delegate = self
        tableView.dataSource = self
        scrollView.documentView = tableView

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            headerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            stepLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 2),
            stepLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            stepLabel.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: stepLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        window.contentView = content
    }

    private func observeManager() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(managerDidChange),
            name: .subAgentsDidChange,
            object: nil
        )
    }

    @objc private func managerDidChange() {
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    private func reload() {
        guard let agent = SubAgentManager.shared.agent(id: agentId) else {
            // Agent was removed/cleared while the window was open — surface
            // a friendly empty state rather than letting the window go stale.
            window?.title = "Sub-agent"
            headerLabel.stringValue = "Sub-agent no longer available"
            stepLabel.stringValue = "It may have been cleared from the inspector."
            entries = []
            emptyLabel.isHidden = false
            tableView.reloadData()
            return
        }
        window?.title = agent.displayTitle
        headerLabel.stringValue = agent.displayTitle
        let stateText: String
        switch agent.state {
        case .active:           stateText = "Active"
        case .sleeping:         stateText = "Sleeping"
        case .waitingForInput:  stateText = "Waiting for input"
        case .completed:        stateText = "Completed"
        case .failed:           stateText = "Failed"
        }
        let step = agent.currentStep.isEmpty ? "" : " — \(agent.currentStep)"
        stepLabel.stringValue = "\(stateText)\(step)"
        entries = agent.logs.reversed()
        emptyLabel.isHidden = !entries.isEmpty
        tableView.reloadData()
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { return entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SubAgentLogRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? SubAgentLogRowView
            ?? SubAgentLogRowView()
        view.identifier = identifier
        view.configure(with: entries[row])
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return SubAgentLogRowView.height(for: entries[row], width: tableView.bounds.width)
    }
}

extension SubAgentDetailWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        SubAgentDetailWindowController.openWindows.removeValue(forKey: agentId)
    }
}

private final class SubAgentLogRowView: NSView {
    private let kindLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        for label in [kindLabel, summaryLabel, timeLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.drawsBackground = false
            label.isBezeled = false
            label.isEditable = false
            addSubview(label)
        }
        kindLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        kindLabel.textColor = .secondaryLabelColor

        summaryLabel.font = NSFont.systemFont(ofSize: 12)
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.maximumNumberOfLines = 0

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor

        NSLayoutConstraint.activate([
            kindLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            kindLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: kindLabel.centerYAnchor),

            summaryLabel.leadingAnchor.constraint(equalTo: kindLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            summaryLabel.topAnchor.constraint(equalTo: kindLabel.bottomAnchor, constant: 2),
            summaryLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    func configure(with entry: SubAgentLogEntry) {
        kindLabel.stringValue = Self.kindString(for: entry.kind).uppercased()
        kindLabel.textColor = Self.kindColor(for: entry.kind)
        summaryLabel.stringValue = entry.summary
        timeLabel.stringValue = Self.timeFormatter.string(from: entry.timestamp)
    }

    /// Best-effort row height: the kind row + a measured summary block + a
    /// little padding. The NSTextField wraps inside `bounds.width` minus our
    /// margins. Falls back to a sensible default when called before layout.
    static func height(for entry: SubAgentLogEntry, width: CGFloat) -> CGFloat {
        let usable = max(180, width - 24)
        let font = NSFont.systemFont(ofSize: 12)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let bounding = (entry.summary as NSString).boundingRect(
            with: NSSize(width: usable, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return ceil(bounding.height) + 28
    }

    private static func kindString(for kind: SubAgentLogEntry.Kind) -> String {
        switch kind {
        case .toolCall:   return "Tool"
        case .toolResult: return "Result"
        case .thought:    return "Thought"
        case .system:     return "System"
        }
    }

    private static func kindColor(for kind: SubAgentLogEntry.Kind) -> NSColor {
        switch kind {
        case .toolCall:   return .systemBlue
        case .toolResult: return .systemGreen
        case .thought:    return .systemPurple
        case .system:     return .systemGray
        }
    }
}

// MARK: - Row view
//
// Subclass NSView (not NSTableRowView) because we return this from
// `tableView(_:viewFor:row:)` — that delegate method expects a "cell view"
// (any NSView), while NSTableRowView is what `rowViewForRow:` returns. The
// first version of this file mixed those up and the rows rendered as
// blank strips.

private final class SubAgentRowView: NSView {
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let stepLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let runtimeLabel = NSTextField(labelWithString: "")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)

    var onStop: (() -> Void)?
    var onRemove: (() -> Void)?
    private var currentAgentIsAlive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        addSubview(dot)

        for label in [titleLabel, stepLabel, stateLabel, runtimeLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.drawsBackground = false
            label.isBezeled = false
            label.isEditable = false
            addSubview(label)
        }
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2

        stepLabel.font = NSFont.systemFont(ofSize: 11)
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.lineBreakMode = .byTruncatingTail

        stateLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        runtimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        runtimeLabel.textColor = .tertiaryLabelColor

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        addSubview(stopButton)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -8),

            stepLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stepLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            stepLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            stateLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stateLabel.topAnchor.constraint(equalTo: stepLabel.bottomAnchor, constant: 4),

            runtimeLabel.leadingAnchor.constraint(equalTo: stateLabel.trailingAnchor, constant: 6),
            runtimeLabel.centerYAnchor.constraint(equalTo: stateLabel.centerYAnchor),

            stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stopButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(with agent: SubAgent) {
        titleLabel.stringValue = agent.displayTitle
        stepLabel.stringValue = agent.currentStep
        stateLabel.stringValue = stateString(for: agent.state).uppercased()
        stateLabel.textColor = color(for: agent.state)
        dot.layer?.backgroundColor = color(for: agent.state).cgColor
        runtimeLabel.stringValue = "· \(formatRuntime(agent.runtime))"
        currentAgentIsAlive = agent.isAlive
        stopButton.title = agent.isAlive ? "Stop" : "Remove"
    }

    @objc private func stopClicked() {
        if currentAgentIsAlive {
            onStop?()
        } else {
            onRemove?()
        }
    }

    private func stateString(for state: SubAgentState) -> String {
        switch state {
        case .active: return "Active"
        case .sleeping: return "Sleeping"
        case .waitingForInput: return "Needs input"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private func color(for state: SubAgentState) -> NSColor {
        switch state {
        case .active: return .systemGreen
        case .sleeping: return .systemYellow
        case .waitingForInput: return .systemOrange
        case .completed: return .systemGray
        case .failed: return .systemRed
        }
    }

    private func formatRuntime(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%dm %02ds", m, s)
    }
}
