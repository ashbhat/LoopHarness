//
//  SettingsWindowController.swift
//  LoopMac
//
//  Single-window settings surface. Lists every third-party service the app
//  integrates with — one row per `KeyStore.Service` — and renders a stack of
//  per-key input rows in the right pane (e.g. GitHub: PAT + optional API
//  base URL in the same panel). Opened from the Settings menu
//  (Loop ▸ Settings ▸ Keys…) and reuses the same shared KeyStore, so edits
//  made on the Mac take effect for every in-process API client on the next
//  call.
//

import AppKit

final class SettingsWindowController: NSWindowController {

    /// Shared instance so the menu item always re-uses the same window
    /// (matches user expectation: cmd-, opens *the* Settings, not a new copy).
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keys"
        window.center()
        window.contentViewController = KeysSettingsViewController()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showKeys() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Same as `showKeys()` but pre-selects the service containing `key` and
    /// focuses the matching input row inside it. Used by integration cells
    /// that want the user to land directly on the field they came to set.
    func showKeys(selecting key: KeyStore.Key) {
        showKeys()
        (window?.contentViewController as? KeysSettingsViewController)?.focus(key: key)
    }
}

// MARK: - Services list + per-service editor

/// Master list of services on the left (one row per `KeyStore.Service`);
/// editor panel on the right that stacks one input row per key in the
/// selected service. Single window + sidebar, no navigation stack — the
/// canonical Mac settings pattern.
private final class KeysSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let services: [KeyStore.Service] = KeyStore.Service.allCases

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    // Right-side editor surface. `editorStack` is rebuilt whenever the
    // selected service changes — each child is a `MacKeyInputRow`.
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private var editorStack: NSStackView!
    /// Per-key rows currently rendered in the editor. Walked on
    /// keyStoreDidChange to refresh each preview/status in place.
    private var rows: [MacKeyInputRow] = []

    private var selectedService: KeyStore.Service? {
        let row = tableView.selectedRow
        guard row >= 0, row < services.count else { return nil }
        return services[row]
    }

    /// Last service the user actually picked. `selectedService` reads live
    /// from `tableView.selectedRow`, which AppKit can transiently report as
    /// -1 (e.g. mid-reload or re-entrant refresh). Remembering it here keeps
    /// the editor showing the user's service instead of collapsing.
    private var lastSelectedService: KeyStore.Service?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
        root.translatesAutoresizingMaskIntoConstraints = false

        // Sidebar with the service list.
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.dataSource = self
        tableView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ServiceColumn"))
        column.width = 200
        column.minWidth = 160
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Right-hand editor header (service name + summary). The per-key rows
        // are appended below dynamically in `rebuildEditor`.
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.maximumNumberOfLines = 3
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.cell?.wraps = true
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let editor = NSStackView()
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 10
        editor.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        editor.translatesAutoresizingMaskIntoConstraints = false
        editorStack = editor

        // We host the (potentially tall) editor stack inside a scroll view so
        // a multi-field service like Obsidian doesn't get clipped at the
        // window's bottom.
        let editorScroll = NSScrollView()
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.drawsBackground = false
        editorScroll.borderType = .noBorder
        editorScroll.translatesAutoresizingMaskIntoConstraints = false

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(scrollView)
        split.addArrangedSubview(editorScroll)
        root.addSubview(split)

        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            editorScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            // Pin the editor stack to the scroll view's width so its rows
            // expand horizontally to the full pane.
            editor.widthAnchor.constraint(equalTo: editorScroll.widthAnchor),
        ])

        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        self.view = root

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyStoreDidChange),
            name: KeyStore.didChangeNotification,
            object: nil
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        rebuildEditor()
    }

    /// Select the service containing `key` and ask its editor row to take
    /// first responder — so a deep link from an integration cell lands the
    /// user directly on the field they came to set.
    func focus(key: KeyStore.Key) {
        guard let service = KeyStore.Service.containing(key),
              let row = services.firstIndex(of: service) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        rebuildEditor()
        // Defer so AppKit settles the freshly-built row hierarchy before we
        // ask the window to make a field first responder.
        DispatchQueue.main.async { [weak self] in
            self?.rows.first(where: { $0.key == key })?.focusInputField()
        }
    }

    // MARK: NSTableView data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { services.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ServiceCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            cell.addSubview(tf)
            cell.textField = tf

            // Trailing "this service has at least its primary key set"
            // checkmark. Stashed on the cell's `imageView` outlet as a
            // reuse-safe handle. Hidden rather than removed when unset so
            // the row layout doesn't jump as services are configured.
            let check = NSImageView()
            check.translatesAutoresizingMaskIntoConstraints = false
            check.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                   accessibilityDescription: "Service is configured")
            check.contentTintColor = .systemGreen
            check.setContentHuggingPriority(.required, for: .horizontal)
            check.setContentCompressionResistancePriority(.required, for: .horizontal)
            cell.addSubview(check)
            cell.imageView = check

            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                check.leadingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 6),
                check.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                check.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                check.widthAnchor.constraint(equalToConstant: 15),
                check.heightAnchor.constraint(equalToConstant: 15),
            ])
        }
        let service = services[row]
        cell.textField?.stringValue = service.displayName
        cell.imageView?.isHidden = KeyStore.shared.source(for: service.primaryKey) == .missing
        return cell
    }

    /// Flip per-row checkmarks in place. Deliberately avoids `reloadData()`
    /// so the table keeps its selection (see `keyStoreDidChange`).
    private func updateCheckmarks() {
        for row in 0..<services.count {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? NSTableCellView else { continue }
            let service = services[row]
            cell.imageView?.isHidden = KeyStore.shared.source(for: service.primaryKey) == .missing
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        rebuildEditor()
    }

    // MARK: Editor

    private func rebuildEditor() {
        let service: KeyStore.Service
        if let live = selectedService {
            service = live
            lastSelectedService = live
        } else if let remembered = lastSelectedService {
            // Selection was dropped under us (AppKit reload / re-entrant
            // refresh). Keep the user on their service and restore the row
            // highlight rather than blanking the whole pane.
            service = remembered
            if let row = services.firstIndex(of: remembered) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            // Genuinely nothing selected and nothing remembered yet.
            titleLabel.stringValue = ""
            summaryLabel.stringValue = ""
            removeAllRowsFromEditor()
            return
        }

        titleLabel.stringValue = service.displayName
        summaryLabel.stringValue = service.summary

        // Reset and rebuild the right pane: header (title + summary) then one
        // `MacKeyInputRow` per key the service exposes.
        for sub in editorStack.arrangedSubviews { sub.removeFromSuperview() }
        rows.removeAll()

        editorStack.addArrangedSubview(titleLabel)
        editorStack.addArrangedSubview(summaryLabel)
        editorStack.setCustomSpacing(14, after: summaryLabel)

        for key in service.keys {
            let row = MacKeyInputRow(key: key, parent: self)
            editorStack.addArrangedSubview(row)
            // Pin each row to the editor width so it stretches to the full
            // pane (NSStackView's leading alignment doesn't grow children).
            row.leadingAnchor.constraint(equalTo: editorStack.leadingAnchor, constant: 16).isActive = true
            row.trailingAnchor.constraint(equalTo: editorStack.trailingAnchor, constant: -16).isActive = true
            rows.append(row)
        }
    }

    private func removeAllRowsFromEditor() {
        for sub in editorStack.arrangedSubviews { sub.removeFromSuperview() }
        rows.removeAll()
    }

    @objc private func keyStoreDidChange() {
        // No reloadData() here: it would drop the table's selection and
        // collapse the editor. The sidebar reflects each service's primary
        // key (the checkmark); patch those in place via updateCheckmarks().
        // Each editor row owns its own preview/status and reads KeyStore on
        // refresh, so just tell them to repaint.
        for row in rows { row.refreshState() }
        updateCheckmarks()
    }

    // MARK: Save / clear failure presentation (shared with rows)

    fileprivate func presentSaveFailure(for key: KeyStore.Key) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t save \(key.displayName)"
        alert.informativeText = "The Keychain rejected the write, so nothing was stored. Open Console.app and filter on subsystem “com.bhat.intel”, category “KeyStore” for the exact error."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Per-key row (Mac)

/// One field within a service's editor: header (display name), purpose
/// subtitle, current-value preview, the input (secure for credentials, plain
/// for URLs/ids/names), an inline status line, and Save / Clear buttons.
/// Owns the per-key save/clear logic so the parent VC just rebuilds the
/// stack when the selected service changes.
private final class MacKeyInputRow: NSView {

    let key: KeyStore.Key
    private weak var parent: KeysSettingsViewController?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let currentHeader = NSTextField(labelWithString: "Current value")
    private let previewLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let inputField: NSTextField
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

    init(key: KeyStore.Key, parent: KeysSettingsViewController) {
        self.key = key
        self.parent = parent
        self.inputField = Self.isSecret(key) ? NSSecureTextField() : NSTextField()
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        // Card-ish background so each key row reads as a discrete unit.
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 8

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.stringValue = key.displayName
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.stringValue = key.subtitle
        subtitleLabel.maximumNumberOfLines = 4
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.cell?.wraps = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        currentHeader.font = .systemFont(ofSize: 11)
        currentHeader.textColor = .secondaryLabelColor
        currentHeader.translatesAutoresizingMaskIntoConstraints = false

        previewLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        previewLabel.textColor = .labelColor
        previewLabel.lineBreakMode = .byTruncatingMiddle
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.placeholderString = Self.isSecret(key) ? "Paste new key" : "Paste new value"
        inputField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        inputField.cell?.wraps = false
        inputField.cell?.isScrollable = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.cell?.wraps = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        saveButton.target = self
        saveButton.action = #selector(saveTapped)

        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.bezelColor = .systemRed

        let actions = NSStackView(views: [clearButton, NSView(), saveButton])
        actions.orientation = .horizontal
        actions.distribution = .fill
        actions.alignment = .centerY
        actions.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            currentHeader,
            previewLabel,
            inputField,
            statusLabel,
            actions
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: subtitleLabel)
        stack.setCustomSpacing(10, after: previewLabel)
        stack.setCustomSpacing(8, after: inputField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            inputField.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            inputField.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            previewLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            previewLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            statusLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            actions.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            actions.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
        ])

        refreshState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focusInputField() {
        window?.makeFirstResponder(inputField)
    }

    /// Reread KeyStore and update preview/status/clear-enabled. Called on
    /// init and whenever `KeyStore.didChangeNotification` fires.
    func refreshState() {
        previewLabel.stringValue = KeyStore.shared.maskedPreview(for: key)
        switch KeyStore.shared.source(for: key) {
        case .keychain:
            statusLabel.stringValue = "Stored securely in the Keychain on this device. The value can't be read back — type a new one to replace it."
            clearButton.isHidden = false
        case .infoPlist:
            statusLabel.stringValue = "Using the bundled default. Save a new value to override it."
            clearButton.isHidden = false
        case .missing:
            statusLabel.stringValue = "Not set — optional. Features that need this will be disabled until you add a value."
            clearButton.isHidden = true
        }
    }

    // MARK: Actions

    @objc private func saveTapped() {
        let value = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to save"
            alert.informativeText = "Paste a new value into the field, or tap Clear to remove the stored value."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        if KeyStore.shared.setValue(value, for: key) {
            inputField.stringValue = ""
            refreshState()
        } else {
            parent?.presentSaveFailure(for: key)
        }
    }

    @objc private func clearTapped() {
        let alert = NSAlert()
        alert.messageText = "Clear \(key.displayName)?"
        alert.informativeText = "Loop will fall back to the bundled default (if any). You can re-enter the value later."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if KeyStore.shared.setValue(nil, for: key) {
                refreshState()
            } else {
                parent?.presentSaveFailure(for: key)
            }
        }
    }

    /// Same secret/plain split as iOS — URLs, vault names, and org ids are
    /// not credentials, so they get a plain field that lets the user see what
    /// they're typing. Everything else stays in a secure field.
    private static func isSecret(_ key: KeyStore.Key) -> Bool {
        switch key {
        case .obsidianBaseURL, .obsidianVaultName, .githubBaseURL, .devinOrgID:
            return false
        default:
            return true
        }
    }
}
