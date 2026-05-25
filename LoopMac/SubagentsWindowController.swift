//
//  SubagentsWindowController.swift
//  LoopMac
//
//  Mac counterpart to iOS's `DevinAgentsListVC` + `DevinAgentDetailVC`. One
//  window, split-view: dispatched Devin sessions on the left (most-recent
//  first), live transcript + status + "See PR" button on the right.
//
//  Opened from Loop ▸ Settings ▸ Subagents…. Reuses the shared
//  `DevinAgentService` so dispatch / polling / completion post-back already
//  Just Work across the iOS and Mac surfaces.
//

import AppKit

final class SubagentsWindowController: NSWindowController {

    static let shared = SubagentsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Subagents"
        window.center()
        window.contentViewController = SubagentsViewController()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Show the window and pre-select a specific Devin session in the sidebar.
    /// Used by the chat inspector to push the user from the pill popup straight
    /// into the live transcript for the session they tapped — equivalent to
    /// iPhone's push to `DevinAgentDetailVC`.
    func show(sessionId: String) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        (window?.contentViewController as? SubagentsViewController)?
            .select(sessionId: sessionId)
    }
}

// MARK: - List + detail

final class SubagentsViewController: NSViewController,
                                     NSTableViewDataSource,
                                     NSTableViewDelegate {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let prButton = NSButton(title: "See PR", target: nil, action: nil)
    private let dashboardButton = NSButton(title: "Open in Devin", target: nil, action: nil)
    private let transcript = NSTextView()
    private let transcriptScroll = NSScrollView()
    private let pollTimer = TimerHolder()

    /// Snapshot driving the list. Re-loaded on .devinAgentsDidChange + when
    /// the window appears so we don't miss out-of-band updates.
    private var jobs: [DevinAgentJob] = []

    private var selectedJob: DevinAgentJob? {
        let row = tableView.selectedRow
        guard row >= 0, row < jobs.count else { return nil }
        return jobs[row]
    }
    private var lastSelectedSessionId: String?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        root.translatesAutoresizingMaskIntoConstraints = false

        // Left: sidebar list of dispatched sessions.
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SubagentColumn"))
        column.width = 220
        column.minWidth = 180
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Right: header + transcript.
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        prButton.target = self
        prButton.action = #selector(openPR)
        prButton.isHidden = true

        dashboardButton.target = self
        dashboardButton.action = #selector(openDashboard)
        dashboardButton.isHidden = true

        let buttonRow = NSStackView(views: [dashboardButton, prButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let headerStack = NSStackView(views: [titleLabel, statusLabel, buttonRow])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.font = .systemFont(ofSize: 13)
        transcript.textContainerInset = NSSize(width: 8, height: 8)
        transcript.isVerticallyResizable = true
        transcript.autoresizingMask = [.width]

        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.borderType = .lineBorder
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [headerStack, transcriptScroll])
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 8
        rightStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(scrollView)
        split.addArrangedSubview(rightStack)
        root.addSubview(split)

        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            rightStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            transcriptScroll.widthAnchor.constraint(equalTo: rightStack.widthAnchor),
            transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        self.view = root

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: .devinAgentsDidChange,
            object: nil
        )
    }

    /// Pre-select a session by id so callers (the chat inspector pill) can push
    /// the user directly into a specific transcript instead of landing on the
    /// most-recent row. Used by `SubagentsWindowController.show(sessionId:)`.
    func select(sessionId: String) {
        lastSelectedSessionId = sessionId
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        // Boost the shared poll timer for the selected session while the
        // window is on-screen (5s vs the background 20s). Set up only once
        // a selection exists.
        if let job = selectedJob {
            DevinAgentService.shared.addBoost(sessionId: job.sessionId)
        }
        // Catch any merge that happened while this window was closed —
        // one-shot poll of every terminal Devin session whose PR hasn't
        // merged/closed yet, so list rows pick up the new state before the
        // user clicks into one.
        DevinAgentService.shared.pollOpenPRs()
        // Mirror the iOS detail-view's local timer fallback: even if the
        // service is busy on other work, this nudges the UI to re-pull the
        // persisted snapshot every 2s so changes feel snappy on Mac too.
        pollTimer.start(every: 2) { [weak self] in self?.refresh() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pollTimer.cancel()
        if let job = selectedJob {
            DevinAgentService.shared.removeBoost(sessionId: job.sessionId)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Reload

    @objc private func refresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let next = DevinAgentService.shared.allJobs()
            self.jobs = next
            self.tableView.reloadData()

            // Preserve selection across reloads.
            if let id = self.lastSelectedSessionId,
               let row = self.jobs.firstIndex(where: { $0.sessionId == id }) {
                self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else if !self.jobs.isEmpty, self.tableView.selectedRow < 0 {
                self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            self.refreshDetail()
        }
    }

    private func refreshDetail() {
        guard let job = selectedJob else {
            titleLabel.stringValue = "No session selected"
            statusLabel.stringValue = "Dispatch a Devin coding task from the chat to see it here."
            prButton.isHidden = true
            dashboardButton.isHidden = true
            transcript.string = ""
            return
        }
        titleLabel.stringValue = job.displayTitle
        statusLabel.stringValue = Self.statusLine(for: job)
        prButton.isHidden = (job.prURL == nil)
        dashboardButton.isHidden = (job.dashboardURL == nil)
        // Re-label the PR button based on pr_state so a merge that lands
        // while the window is open is reflected on the next poll without us
        // needing to rebuild the whole panel.
        switch job.prState?.lowercased() {
        case "merged": prButton.title = "Merged PR"
        case "closed": prButton.title = "PR closed"
        default:       prButton.title = "See PR"
        }
        transcript.string = Self.transcriptText(for: job)
        // Scroll to bottom so the latest message is visible.
        transcript.scrollToEndOfDocument(nil)
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { max(jobs.count, 1) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SubagentCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let title = NSTextField(labelWithString: "")
            title.lineBreakMode = .byTruncatingTail
            title.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(title)
            cell.textField = title

            let subtitle = NSTextField(labelWithString: "")
            subtitle.font = .systemFont(ofSize: 10)
            subtitle.textColor = .secondaryLabelColor
            subtitle.lineBreakMode = .byTruncatingTail
            subtitle.translatesAutoresizingMaskIntoConstraints = false
            subtitle.identifier = NSUserInterfaceItemIdentifier("subtitle")
            cell.addSubview(subtitle)

            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            ])
        }
        if jobs.isEmpty {
            cell.textField?.stringValue = "No sessions yet"
            (cell.subviews.first { $0.identifier?.rawValue == "subtitle" } as? NSTextField)?.stringValue = ""
        } else {
            let job = jobs[row]
            cell.textField?.stringValue = job.displayTitle
            (cell.subviews.first { $0.identifier?.rawValue == "subtitle" } as? NSTextField)?.stringValue = Self.subtitle(for: job)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        // Block selecting the empty-state row.
        if jobs.isEmpty { return IndexSet() }
        return proposedSelectionIndexes
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Swap which session the service is boosting so the new selection
        // gets the 5s cadence and the old one falls back to background.
        let prior = lastSelectedSessionId
        let next = selectedJob?.sessionId
        if prior != next {
            if let p = prior { DevinAgentService.shared.removeBoost(sessionId: p) }
            if let n = next { DevinAgentService.shared.addBoost(sessionId: n) }
            lastSelectedSessionId = next
        }
        refreshDetail()
    }

    // MARK: - Actions

    @objc private func openPR() {
        guard let url = selectedJob?.prURL.flatMap(URL.init(string:)) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openDashboard() {
        guard let url = selectedJob?.dashboardURL.flatMap(URL.init(string:)) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Presentation helpers

    private static func statusLine(for job: DevinAgentJob) -> String {
        // PR state wins once a PR is on the table — "Merged" is the more
        // useful headline than "Finished" once the merge has actually landed.
        switch job.prState?.lowercased() {
        case "merged": return "🎉 Merged"
        case "closed": return "🚫 PR closed"
        default: break
        }
        switch job.status {
        case "running":   return "● Working"
        case "blocked":   return "🟡 Blocked"
        case "finished":  return "✅ Finished"
        case "expired":   return "⌛ Expired"
        case "cancelled": return "🚫 Cancelled"
        case "stale":     return "⌛️ Stopped tracking"
        case "error":     return "❌ Error"
        default:          return job.status
        }
    }

    private static func subtitle(for job: DevinAgentJob) -> String {
        let label = statusLine(for: job)
            .replacingOccurrences(of: "●", with: "")
            .replacingOccurrences(of: "🟡", with: "")
            .replacingOccurrences(of: "✅", with: "")
            .replacingOccurrences(of: "⌛", with: "")
            .replacingOccurrences(of: "🚫", with: "")
            .replacingOccurrences(of: "⌛️", with: "")
            .replacingOccurrences(of: "❌", with: "")
            .replacingOccurrences(of: "🎉", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let repo = job.repository, !repo.isEmpty {
            return "\(label) · \(DevinSkill.repoShortName(repo))"
        }
        return label
    }

    private static func transcriptText(for job: DevinAgentJob) -> String {
        guard !job.messages.isEmpty else {
            return job.status == "running"
                ? "Waiting for Devin's first message…"
                : "No messages."
        }
        return job.messages.map { msg -> String in
            let role: String
            let lower = msg.type.lowercased()
            if lower.contains("user") || lower.contains("human") {
                role = msg.username ?? "You"
            } else if lower.contains("system") {
                role = "System"
            } else {
                role = msg.username ?? "Devin"
            }
            return "[\(role)]  \(msg.message)"
        }.joined(separator: "\n\n")
    }
}

/// Tiny holder so the controller can own a recurring `Timer` without leaking
/// it to other files. Cancels cleanly on disappear.
fileprivate final class TimerHolder {
    private var timer: Timer?
    func start(every interval: TimeInterval, _ action: @escaping () -> Void) {
        cancel()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in action() }
    }
    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
