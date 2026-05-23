//
//  MicrophoneSettingsWindowController.swift
//  LoopMac
//
//  "Settings ▸ Microphone…" — lets the user pin Loop to a specific input
//  device. Mirrors the IntegrationsWindowController + KeysSettings pattern:
//  separate window opened from the Settings menu, shared singleton.
//

import AppKit
import CoreAudio

final class MicrophoneSettingsWindowController: NSWindowController {

    static let shared = MicrophoneSettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Microphone"
        window.minSize = NSSize(width: 420, height: 360)
        window.center()
        window.contentViewController = MicrophoneSettingsViewController()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View controller

private final class MicrophoneSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    /// Rows shown in the table. The first row is always the "System default"
    /// pseudo-entry, followed by a separator and the real devices. Computed
    /// once per `reload()` so a hot-swap between renders doesn't tear indices.
    private enum Row {
        case systemDefault(currentName: String?)
        case separator
        case device(MicrophoneDevice)
    }

    private var rows: [Row] = []
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let openSystemSettingsButton = NSButton(title: "Open System Settings…", target: nil, action: nil)
    /// CoreAudio property listener handle so we re-scan when the user plugs
    /// in / unplugs a device while the window is open. Removed in deinit.
    private var devicesListenerInstalled = false

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 460))

        let title = NSTextField(labelWithString: "Input device")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: "Pick which microphone Loop should use when you hold ctrl+fn. Choose “System default” to follow whatever you've set in System Settings ▸ Sound.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 3
        subtitle.preferredMaxLayoutWidth = 440
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // Single-column table. Each row renders a checkmark + device name.
        tableView.style = .inset
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none // we draw our own pinned indicator
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.action = #selector(rowClicked)
        tableView.target = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MicrophoneColumn"))
        column.width = 440
        column.minWidth = 200
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.cell?.wraps = true
        statusLabel.preferredMaxLayoutWidth = 440
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        openSystemSettingsButton.bezelStyle = .rounded
        openSystemSettingsButton.target = self
        openSystemSettingsButton.action = #selector(openSystemSettingsClicked)
        openSystemSettingsButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [openSystemSettingsButton, NSView(), refreshButton])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, subtitle, scrollView, statusLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: subtitle)
        stack.setCustomSpacing(10, after: scrollView)
        stack.setCustomSpacing(10, after: statusLabel)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),

            statusLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20),

            buttonRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20),
        ])

        self.view = root

        installDevicesListener()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionChangedExternally),
            name: .microphoneSelectionChanged,
            object: nil
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    deinit {
        removeDevicesListener()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Data refresh

    private func reload() {
        let devices = MicrophoneManager.shared.inputDevices()
        let defaultDevice = MicrophoneManager.shared.systemDefaultInput()
        rows = [.systemDefault(currentName: defaultDevice?.name)]
        if !devices.isEmpty {
            rows.append(.separator)
            rows.append(contentsOf: devices.map { Row.device($0) })
        }
        tableView.reloadData()
        statusLabel.stringValue = statusText()
    }

    private func statusText() -> String {
        let selectedUID = MicrophoneManager.shared.selectedUID
        if let uid = selectedUID {
            let known = MicrophoneManager.shared.inputDevices().contains(where: { $0.uid == uid })
            if !known {
                return "The pinned microphone isn't connected. Loop will fall back to the system default until it's plugged back in."
            }
            return "Loop is pinned to a specific microphone — it won't change if you swap the system default in Settings ▸ Sound."
        }
        return "Loop is using the system default microphone. Change it here, or in System Settings ▸ Sound ▸ Input."
    }

    @objc private func refreshClicked() {
        reload()
    }

    @objc private func openSystemSettingsClicked() {
        // Sound pane on macOS 13+. Older macs ignore the input fragment and
        // land on the Sound pane root, which is still useful.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound?input") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func selectionChangedExternally() {
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    @objc private func devicesDidChange() {
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    // MARK: - CoreAudio device-list listener

    /// A single static C trampoline reusable for all instances. CoreAudio
    /// listener blocks take `UnsafeMutableRawPointer` for the listener's
    /// client data, and we pass `Unmanaged.passUnretained(self)`.
    private static let listenerBlock: AudioObjectPropertyListenerBlock = { _, _ in
        // We register from the main thread for each instance and route
        // through NotificationCenter rather than touching `self` directly
        // here — keeps the trampoline thread-safe.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .microphoneDeviceListChanged, object: nil)
        }
    }

    private func installDevicesListener() {
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &prop,
            DispatchQueue.main,
            Self.listenerBlock
        )
        devicesListenerInstalled = (status == noErr)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(devicesDidChange),
            name: .microphoneDeviceListChanged,
            object: nil
        )
    }

    private func removeDevicesListener() {
        guard devicesListenerInstalled else { return }
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &prop,
            DispatchQueue.main,
            Self.listenerBlock
        )
        devicesListenerInstalled = false
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let selectedUID = MicrophoneManager.shared.selectedUID
        switch rows[row] {
        case .separator:
            let id = NSUserInterfaceItemIdentifier("MicrophoneSeparator")
            let view = tableView.makeView(withIdentifier: id, owner: nil) as? SeparatorRowView
                ?? SeparatorRowView()
            view.identifier = id
            return view
        case .systemDefault(let currentName):
            let cell = dequeueDeviceCell()
            cell.titleLabel.stringValue = "System default"
            cell.subtitleLabel.stringValue = currentName.map { "Currently: \($0)" } ?? "Currently: (none detected)"
            cell.subtitleLabel.isHidden = false
            cell.setPinned(selectedUID == nil)
            return cell
        case .device(let device):
            let cell = dequeueDeviceCell()
            cell.titleLabel.stringValue = device.name
            cell.subtitleLabel.stringValue = ""
            cell.subtitleLabel.isHidden = true
            cell.setPinned(selectedUID == device.uid)
            return cell
        }
    }

    private func dequeueDeviceCell() -> MicrophoneRowCell {
        let id = NSUserInterfaceItemIdentifier("MicrophoneRow")
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? MicrophoneRowCell {
            return reused
        }
        let cell = MicrophoneRowCell()
        cell.identifier = id
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .systemDefault: return 40
        case .separator:    return 8
        case .device:       return 28
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Separators are display-only; clicking them is a no-op.
        if case .separator = rows[row] { return false }
        return true
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case .systemDefault:
            MicrophoneManager.shared.selectedUID = nil
        case .separator:
            return
        case .device(let device):
            MicrophoneManager.shared.selectedUID = device.uid
        }
        reload()
    }
}

// MARK: - Row cell

private final class MicrophoneRowCell: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    let checkmark = NSImageView()
    /// Painted full-width behind the row when this cell is the pinned choice.
    /// Subtle accent tint, drawn under the labels so text reads cleanly. Keeps
    /// the visual hierarchy: pinned row = filled + bold + checkmark, others
    /// = plain.
    private let pinnedBackground = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        pinnedBackground.translatesAutoresizingMaskIntoConstraints = false
        pinnedBackground.wantsLayer = true
        pinnedBackground.layer?.cornerRadius = 5
        pinnedBackground.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.12).cgColor
        pinnedBackground.isHidden = true
        addSubview(pinnedBackground)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.drawsBackground = false
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.drawsBackground = false
        subtitleLabel.isBezeled = false
        subtitleLabel.isEditable = false
        addSubview(subtitleLabel)

        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")
        checkmark.contentTintColor = .controlAccentColor
        checkmark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        addSubview(checkmark)

        NSLayoutConstraint.activate([
            // Pinned-row tint hugs the row (with a small inset so it reads as
            // a pill rather than a full-bleed stripe).
            pinnedBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            pinnedBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pinnedBackground.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            pinnedBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            checkmark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: checkmark.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
        ])
    }

    /// Apply the "this is the active choice" treatment: tinted background,
    /// bold title, visible checkmark. When pinned == false, render as a
    /// neutral row.
    func setPinned(_ pinned: Bool) {
        pinnedBackground.isHidden = !pinned
        checkmark.isHidden = !pinned
        titleLabel.font = pinned
            ? .systemFont(ofSize: 13, weight: .semibold)
            : .systemFont(ofSize: 13)
    }
}

// MARK: - Separator row
//
// Thin, full-width hairline between the "System default" pseudo-entry and
// the real device list. Implemented as a non-selectable table row rather than
// a header view so reload() can rebuild the section break in lock-step with
// the rest of the table.

private final class SeparatorRowView: NSTableCellView {
    private let line = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.boxType = .separator
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Notification

extension Notification.Name {
    /// Fired (on main) when CoreAudio reports the system device list changed
    /// — plug or unplug a USB mic / Bluetooth headset.
    static let microphoneDeviceListChanged = Notification.Name("loop.audio.microphoneDeviceListChanged")
}
