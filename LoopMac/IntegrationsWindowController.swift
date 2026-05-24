//
//  IntegrationsWindowController.swift
//  LoopMac
//
//  Mac counterpart to iOS's IntegrationsVC. Lists the third-party services
//  Loop can pull context from / take action in: Google Calendar (live via
//  EventKit — covers any calendar account the user has added in macOS
//  System Settings → Internet Accounts), Notion (token-backed via ntn_…
//  integration token in Keychain), and Slack (token-backed via xoxp- user
//  token in Keychain). Gmail is stubbed as coming soon.
//
//  Opened from Loop ▸ Settings ▸ Integrations…. Reuses the shared
//  CalendarSkill so authorization state is consistent with whatever the
//  voice loop already sees.
//

import AppKit
import EventKit

final class IntegrationsWindowController: NSWindowController {

    /// Shared so re-opening from the menu re-uses the same window instead of
    /// stacking duplicates — same convention as SettingsWindowController.
    static let shared = IntegrationsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Integrations"
        window.center()
        window.contentViewController = IntegrationsListViewController()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Row model

/// File-scope so the cell view can render it without the controller having
/// to expose its internals. Mirrors the iOS `Integration` model row-for-row.
fileprivate struct Integration {
    enum Status {
        case connected
        case notConnected
        case denied              // user said no in System Settings
        case comingSoon
    }
    let title: String
    let subtitle: String
    let icon: String            // SF Symbol name
    let tint: NSColor
    var status: Status
    let handler: ((IntegrationsListViewController) -> Void)?
}

// MARK: - List

fileprivate final class IntegrationsListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var integrations: [Integration] = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        root.translatesAutoresizingMaskIntoConstraints = false

        tableView.style = .inset
        tableView.headerView = nil
        tableView.rowHeight = 56
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("IntegrationColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        self.view = root

        // EventKit fires this when the user toggles Loop in System Settings →
        // Privacy & Security → Calendars. Refresh so the subtitle matches
        // reality without needing a relaunch.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshRows),
            name: .EKEventStoreChanged,
            object: nil
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Re-evaluate every appearance — the user might have flipped a
        // permission in System Settings while this window was hidden.
        rebuildIntegrations()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refreshRows() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildIntegrations()
        }
    }

    private func rebuildIntegrations() {
        let calendarStatus: Integration.Status
        let calendarSubtitle: String
        switch CalendarSkill.shared.currentAuthorizationStatus {
        case .fullAccess, .authorized:
            calendarStatus = .connected
            calendarSubtitle = "Connected · reads any calendar in macOS Internet Accounts"
        case .denied, .restricted, .writeOnly:
            calendarStatus = .denied
            calendarSubtitle = "Calendar access blocked — enable in System Settings"
        case .notDetermined:
            calendarStatus = .notConnected
            calendarSubtitle = "Click to connect Google / iCloud / Exchange"
        @unknown default:
            calendarStatus = .notConnected
            calendarSubtitle = "Click to connect"
        }

        integrations = [
            Integration(
                title: "Google Calendar",
                subtitle: calendarSubtitle,
                icon: "calendar",
                tint: .systemRed,
                status: calendarStatus,
                handler: { vc in vc.handleCalendarTap() }
            ),
            notionIntegration(),
            Integration(
                title: "Gmail",
                subtitle: "Coming soon · OAuth wiring in progress",
                icon: "envelope",
                tint: .systemRed,
                status: .comingSoon,
                handler: nil
            ),
            slackIntegration(),
            devinIntegration(),
        ]

        tableView.reloadData()
    }

    /// Devin coding agent. The v3 API needs both a cog_… API key AND an
    /// org-… Organization ID; surface "Connected" only when both are set,
    /// and route a click straight to whichever is missing.
    private func devinIntegration() -> Integration {
        let hasKey = !((KeyStore.shared.value(for: .devin) ?? "").isEmpty)
        let hasOrg = !((KeyStore.shared.value(for: .devinOrgID) ?? "").isEmpty)
        let status: Integration.Status
        let subtitle: String
        if hasKey && hasOrg {
            status = .connected
            subtitle = "Connected · dispatches coding agents that open PRs"
        } else if hasKey || hasOrg {
            status = .denied
            subtitle = hasKey
                ? "Almost connected — add your Organization ID"
                : "Almost connected — add your cog_ API key"
        } else {
            status = .notConnected
            subtitle = "Click to add your Devin API key + Organization ID"
        }
        return Integration(
            title: "Devin.AI",
            subtitle: subtitle,
            icon: "hammer",
            tint: .systemBlue,
            status: status,
            handler: { vc in vc.handleDevinTap() }
        )
    }

    fileprivate func handleDevinTap() {
        let hasKey = !((KeyStore.shared.value(for: .devin) ?? "").isEmpty)
        let hasOrg = !((KeyStore.shared.value(for: .devinOrgID) ?? "").isEmpty)
        if !hasKey { SettingsWindowController.shared.showKeys(selecting: .devin); return }
        if !hasOrg { SettingsWindowController.shared.showKeys(selecting: .devinOrgID); return }
        let alert = NSAlert()
        alert.messageText = "Devin connected"
        alert.informativeText = "Loop can dispatch Devin coding agents on your behalf. You can replace or remove either credential below."
        alert.addButton(withTitle: "Edit API Key")
        alert.addButton(withTitle: "Edit Organization ID")
        alert.addButton(withTitle: "Done")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            SettingsWindowController.shared.showKeys(selecting: .devin)
        case .alertSecondButtonReturn:
            SettingsWindowController.shared.showKeys(selecting: .devinOrgID)
        default:
            break
        }
    }

    /// Notion is token-backed — connection state is "did the user paste an
    /// ntn_… integration token into Settings → Keys → Notion Integration
    /// Token?". Mirrors the Slack pattern below.
    private func notionIntegration() -> Integration {
        let hasToken = !((KeyStore.shared.value(for: .notionIntegrationToken) ?? "").isEmpty)
        return Integration(
            title: "Notion",
            subtitle: hasToken
                ? "Connected · Notion integration token"
                : "Click to paste your Notion integration token",
            icon: "note.text",
            tint: .labelColor,
            status: hasToken ? .connected : .notConnected,
            handler: { vc in vc.handleNotionTap() }
        )
    }

    fileprivate func handleNotionTap() {
        let hasToken = !((KeyStore.shared.value(for: .notionIntegrationToken) ?? "").isEmpty)
        if hasToken {
            let alert = NSAlert()
            alert.messageText = "Notion connected"
            alert.informativeText = "Loop is connected to Notion via an integration token. You can replace or remove the token in Settings → Keys."
            alert.addButton(withTitle: "Edit Token")
            alert.addButton(withTitle: "Done")
            if alert.runModal() == .alertFirstButtonReturn {
                SettingsWindowController.shared.showKeys(selecting: .notionIntegrationToken)
            }
        } else {
            SettingsWindowController.shared.showKeys(selecting: .notionIntegrationToken)
        }
    }

    /// Slack is a personal-only integration in v1 — connection state is just
    /// "did the user paste an xoxp- token into Settings → Keys?". A future
    /// OAuth phase swaps how the token gets there without changing this row.
    private func slackIntegration() -> Integration {
        let hasToken = !((KeyStore.shared.value(for: .slackUserToken) ?? "").isEmpty)
        return Integration(
            title: "Slack",
            subtitle: hasToken
                ? "Connected · personal user token"
                : "Click to open Keys and paste your Slack user token",
            icon: "message",
            tint: .systemPurple,
            status: hasToken ? .connected : .notConnected,
            handler: { vc in vc.handleSlackTap() }
        )
    }

    fileprivate func handleSlackTap() {
        let hasToken = !((KeyStore.shared.value(for: .slackUserToken) ?? "").isEmpty)
        if hasToken {
            let alert = NSAlert()
            alert.messageText = "Slack connected"
            alert.informativeText = "Loop is connected to Slack via a personal user token. You can replace or remove the token in Settings → Keys."
            alert.addButton(withTitle: "Edit Token")
            alert.addButton(withTitle: "Done")
            if alert.runModal() == .alertFirstButtonReturn {
                SettingsWindowController.shared.showKeys(selecting: .slackUserToken)
            }
        } else {
            SettingsWindowController.shared.showKeys(selecting: .slackUserToken)
        }
    }

    // MARK: Calendar handler

    fileprivate func handleCalendarTap() {
        switch CalendarSkill.shared.currentAuthorizationStatus {
        case .fullAccess, .authorized:
            // Already connected. macOS won't let the app revoke its own
            // grant, so the only actionable affordance is jumping to the
            // right pane in System Settings.
            let alert = NSAlert()
            alert.messageText = "Google Calendar connected"
            alert.informativeText = "Loop can see your upcoming events and create new ones. To disconnect, open System Settings → Privacy & Security → Calendars and disable Loop."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                openCalendarPrivacyPane()
            }
        case .denied, .restricted, .writeOnly:
            // The OS won't re-prompt once the user has denied; deep-link
            // them to the pane that flips the grant back on.
            let alert = NSAlert()
            alert.messageText = "Calendar access blocked"
            alert.informativeText = "Loop's calendar access was previously denied. Re-enable Loop in System Settings → Privacy & Security → Calendars."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                openCalendarPrivacyPane()
            }
        case .notDetermined:
            CalendarSkill.shared.requestAccessIfNeeded { [weak self] _ in
                self?.rebuildIntegrations()
            }
        @unknown default:
            break
        }
    }

    private func openCalendarPrivacyPane() {
        // Deep link straight to the Calendars privacy pane on macOS 13+; the
        // URL scheme is stable across recent releases.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: NSTableView data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { integrations.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        return IntegrationCellView(integration: integrations[row])
    }

    /// Coming-soon rows have no handler; block selection so the row doesn't
    /// visually highlight when the user clicks an inert item.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        return IndexSet(proposedSelectionIndexes.filter { integrations[$0].handler != nil })
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < integrations.count else { return }
        // Drop the highlight after firing so the row reads as a momentary
        // tap target, not a persistent selection.
        tableView.deselectAll(nil)
        integrations[row].handler?(self)
    }
}

// MARK: - Cell

/// Two-line cell with a tinted SF Symbol on the left and a status accessory
/// on the right. Built imperatively (no XIB) to match the rest of the Mac UI.
fileprivate final class IntegrationCellView: NSTableCellView {

    init(integration: Integration) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let baseImage = NSImage(systemSymbolName: integration.icon, accessibilityDescription: nil) ?? NSImage()
        let iconView = NSImageView(image: baseImage.withSymbolConfiguration(symbolConfig) ?? baseImage)
        iconView.contentTintColor = integration.tint
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let title = NSTextField(labelWithString: integration.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        let subtitle = NSTextField(labelWithString: integration.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitle)

        let accessory = Self.accessoryView(for: integration.status)
        accessory.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accessory)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            title.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8),

            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// NSTextField inherits from NSControl and silently consumes mouseDown,
    /// which means NSTableView's `action` never fires when the click lands
    /// on a subview. Redirect any hit inside the cell to the cell itself so
    /// the event bubbles up to the table.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return super.hitTest(point) != nil ? self : nil
    }

    private static func accessoryView(for status: Integration.Status) -> NSView {
        switch status {
        case .connected:
            let dot = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Connected") ?? NSImage())
            dot.contentTintColor = .systemGreen
            return dot
        case .notConnected:
            let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
            chevron.contentTintColor = .tertiaryLabelColor
            return chevron
        case .denied:
            let dot = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Blocked") ?? NSImage())
            dot.contentTintColor = .systemOrange
            return dot
        case .comingSoon:
            let label = NSTextField(labelWithString: "Soon")
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = .tertiaryLabelColor
            return label
        }
    }
}
