//
//  ScheduledTasksWindowController.swift
//  LoopMac
//
//  Built from intel/Specs/7_background_scheduler_spec.md.
//
//  Mac Settings → Scheduled. Lists every BackgroundScheduler job and exposes
//  Run now / Delete / Open last result actions. Mirrors the iOS
//  ScheduledTasksVC list but in an AppKit table view.
//

import AppKit

final class ScheduledTasksWindowController: NSWindowController {

    /// Shared singleton so re-opening from the menu re-uses the same window.
    static let shared = ScheduledTasksWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scheduled"
        window.center()
        window.contentViewController = ScheduledTasksListViewController()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        (window?.contentViewController as? ScheduledTasksListViewController)?.reload()
    }
}

// MARK: - List

fileprivate final class ScheduledTasksListViewController: NSViewController,
                                                          NSTableViewDataSource,
                                                          NSTableViewDelegate {

    private let tableView = KeyAwareTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No scheduled tasks yet.\nAsk Loop to set one up.")
    private let runNowButton = NSButton(title: "Run now", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let openButton = NSButton(title: "Open last result", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    private var jobs: [ScheduledJob] = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))

        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowSizeStyle = .medium
        tableView.allowsEmptySelection = true
        // Multi-select so the user can grab a range with shift+click, lasso
        // with cmd+click, or hit the whole list with cmd+A and then delete.
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        // Wire the keyboard delete (⌫ / fwd-delete) inside the table to the
        // same path the Delete button uses, so the user never has to leave
        // the keyboard for the bulk-delete flow.
        tableView.onDeleteKey = { [weak self] in
            self?.deleteTapped()
        }
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        col.title = "Task"
        col.width = 500
        tableView.addTableColumn(col)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

        let buttonStack = NSStackView(views: [runNowButton, openButton, deleteButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttonStack)

        for b in [runNowButton, openButton, deleteButton] {
            b.bezelStyle = .rounded
            b.target = self
        }
        runNowButton.action = #selector(runNowTapped)
        openButton.action = #selector(openLastTapped)
        deleteButton.action = #selector(deleteTapped)
        deleteButton.contentTintColor = .systemRed

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            buttonStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            buttonStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: buttonStack.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: buttonStack.centerYAnchor),
        ])

        self.view = root
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Park the keyboard focus on the table so Cmd+A (Edit ▸ Select All)
        // and the delete keys hit it directly without an extra click.
        view.window?.makeFirstResponder(tableView)
    }

    func reload() {
        jobs = BackgroundScheduler.shared.loadJobs().sorted { $0.title < $1.title }
        tableView.reloadData()
        emptyLabel.isHidden = !jobs.isEmpty
        scrollView.isHidden = jobs.isEmpty
        updateButtonState()
    }

    private func selectedJobs() -> [ScheduledJob] {
        return tableView.selectedRowIndexes
            .filter { $0 >= 0 && $0 < jobs.count }
            .map { jobs[$0] }
    }

    private func updateButtonState() {
        let selected = selectedJobs()
        // Run now / Open last result are single-job affordances. Disable when
        // multiple are selected so the action is unambiguous — the user can
        // always narrow the selection with click or arrow keys.
        runNowButton.isEnabled = selected.count == 1
        openButton.isEnabled = selected.count == 1 && selected[0].lastRunAt != nil
        // Delete handles any non-empty selection. Reflect the count in the
        // button title so it's obvious you're about to remove N tasks.
        deleteButton.isEnabled = !selected.isEmpty
        deleteButton.title = selected.count > 1 ? "Delete \(selected.count)" : "Delete"
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { return jobs.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? JobCellView ?? JobCellView()
        cell.identifier = id
        let job = jobs[row]
        cell.configure(with: job)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { return 56 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonState()
    }

    // MARK: Actions

    @objc private func runNowTapped() {
        let selected = selectedJobs()
        guard selected.count == 1, let job = selected.first else { return }
        statusLabel.stringValue = "Running '\(job.title)'…"
        runNowButton.isEnabled = false
        let fire = BackgroundScheduler.shared.nextFireDate(for: job.trigger)
        BackgroundScheduler.shared.clearResults(forJobId: job.id)
        BackgroundScheduler.shared.prefetch(job: job, fireDate: fire) { [weak self] (result: BackgroundScheduler.RunResult) in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let body, _):
                    self.statusLabel.stringValue = "Done — \(body)"
                case .failure(let reason):
                    self.statusLabel.stringValue = "Failed: \(reason)"
                }
                self.reload()
            }
        }
    }

    @objc private func openLastTapped() {
        let selected = selectedJobs()
        guard selected.count == 1, let job = selected.first else { return }
        let results = BackgroundScheduler.shared.loadResults().filter { $0.jobId == job.id }
        guard let latest = results.sorted(by: { $0.fireDate > $1.fireDate }).first,
              let conv = SimpleConversationManager.shared.getConversation(by: latest.conversationId) else { return }
        // Route through the tab manager — the conversation window now
        // displays whichever conversation the foreground tab owns, so a bare
        // `manager.currentConversation = conv` + notification (the old
        // pre-tabs path) wouldn't actually swap what the user sees.
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let controller = appDelegate.conversationController {
            controller.openConversationInTab(conv)
            controller.showAndReload()
        } else {
            SimpleConversationManager.shared.currentConversation = conv
            NotificationCenter.default.post(name: .conversationStoreDidChange, object: nil)
        }
    }

    @objc private func deleteTapped() {
        let selected = selectedJobs()
        guard !selected.isEmpty else { return }

        let alert = NSAlert()
        if selected.count == 1 {
            alert.messageText = "Delete '\(selected[0].title)'?"
            alert.informativeText = "This stops the task and cancels pending notifications."
        } else {
            alert.messageText = "Delete \(selected.count) scheduled tasks?"
            alert.informativeText = "This stops every selected task and cancels their pending notifications. This can't be undone."
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        // Make Cancel the default so a stray Return doesn't nuke a long
        // selection. The destructive button still works on click or by
        // pressing Tab → Return.
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for job in selected {
            _ = BackgroundScheduler.shared.deleteJob(id: job.id)
        }
        reload()
    }
}

// MARK: - Key-aware table view

/// NSTableView subclass that forwards the delete keys to a callback so the
/// list can be cleaned up entirely from the keyboard. Cmd+A is handled by
/// AppKit's standard Edit ▸ Select All routing — we just need to be the
/// first responder and have allowsMultipleSelection on.
fileprivate final class KeyAwareTableView: NSTableView {
    /// Fires when the user presses ⌫ (backspace) or fwd-delete with a
    /// non-empty selection. Wired by ScheduledTasksListViewController.
    var onDeleteKey: (() -> Void)?

    override var acceptsFirstResponder: Bool { return true }

    override func keyDown(with event: NSEvent) {
        // 51 = ⌫ (backspace), 117 = forward delete. Both should map to the
        // same "remove what's selected" gesture — matches Finder.
        let isDelete = event.keyCode == 51 || event.keyCode == 117
        if isDelete, selectedRowIndexes.count > 0 {
            onDeleteKey?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Cell view

fileprivate final class JobCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        installSubviews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func installSubviews() {
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    func configure(with job: ScheduledJob) {
        titleLabel.stringValue = job.title
        var detail = BackgroundScheduler.shared.scheduleDescription(for: job)
        if let last = job.lastResult, !last.isEmpty {
            detail += " · " + last
        }
        detailLabel.stringValue = detail
    }
}

