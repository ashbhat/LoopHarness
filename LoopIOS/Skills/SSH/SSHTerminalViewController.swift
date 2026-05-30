//
//  SSHTerminalViewController.swift
//  Loop
//
//  In-app interactive SSH terminal, restyled to the "Direction A — Refined
//  Terminal" design (Claude Design handoff). Hosts a SwiftTerm `TerminalView`
//  driven by `SSHTerminalSession` (NIOSSH PTY + shell) and wraps it in:
//    • a slim ~46px header — back, live status dot, host/ip, compact Disconnect
//    • a themed terminal — light/dark token palettes via `TerminalTheme`
//    • a redesigned accessory bar (`SSHTerminalAccessoryView`) with a ⌘ palette
//    • a command palette sheet (`SSHCommandPaletteViewController`)
//
//  Bridges the terminal and the session via `TerminalViewDelegate`:
//    user input -> send; local resize -> session.resize; remote output -> feed.
//
//  Pushed from Settings → SSH. iOS-only (UIKit + SwiftTerm); excluded from the
//  Mac/Vision targets.
//

import UIKit
import SwiftTerm

final class SSHTerminalViewController: UIViewController {

    private let config: SSHConfig

    private var terminalView: TerminalView!
    private var session: SSHTerminalSession?
    private var accessory: SSHTerminalAccessoryView!

    // Header
    private let headerView = UIView()
    private let headerBorder = CALayer()
    private let backButton = UIButton(type: .system)
    private let statusRing = UIView()
    private let statusDot = UIView()
    private let hostLabel = UILabel()
    private let subLabel = UILabel()
    private let disconnectButton = UIButton(type: .system)

    // Connecting state
    private let overlay = UIView()
    private let overlaySpinner = UIActivityIndicatorView(style: .medium)
    private let overlayLabel = UILabel()

    private var theme: TerminalTheme
    private var hasStarted = false
    private var sessionClosed = false
    private var userInitiatedClose = false

    init(config: SSHConfig) {
        self.config = config
        self.theme = .dark
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { session?.disconnect() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        theme = TerminalTheme.current(for: traitCollection)
        setupTerminal()
        setupHeader()
        setupOverlay()
        applyTheme()

        // Re-theme when the system light/dark style changes.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            let next = TerminalTheme.current(for: self.traitCollection)
            if next.isDark != self.theme.isDark {
                self.theme = next
                self.applyTheme()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startIfNeeded()
        _ = terminalView.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leaving for good — whether popped (push) or dismissed (full-screen).
        if isMovingFromParent || isBeingDismissed {
            navigationController?.setNavigationBarHidden(false, animated: animated)
            userInitiatedClose = true
            session?.disconnect()
        }
    }

    // MARK: - Setup

    private func setupTerminal() {
        let tv = TerminalView(frame: view.bounds,
                              font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.terminalDelegate = self
        view.addSubview(tv)
        terminalView = tv

        // Redesigned accessory bar in place of SwiftTerm's default key row.
        let bar = SSHTerminalAccessoryView(theme: theme)
        bar.terminalView = tv
        bar.onPalette = { [weak self] in self?.openPalette() }
        tv.inputAccessoryView = bar
        accessory = bar
    }

    private func setupHeader() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.layer.addSublayer(headerBorder)
        view.addSubview(headerView)

        backButton.layer.cornerRadius = 9
        backButton.setImage(UIImage(systemName: "chevron.left",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        headerView.addSubview(backButton)

        // Status dot + glow ring.
        statusRing.layer.cornerRadius = 6.5
        statusRing.translatesAutoresizingMaskIntoConstraints = false
        statusDot.layer.cornerRadius = 3.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusRing.addSubview(statusDot)

        hostLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        hostLabel.text = config.host
        subLabel.font = UIFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        subLabel.text = config.username.isEmpty ? config.host : config.username

        let textStack = UIStackView(arrangedSubviews: [hostLabel, subLabel])
        textStack.axis = .vertical
        textStack.spacing = 1

        let idGroup = UIStackView(arrangedSubviews: [statusRing, textStack])
        idGroup.axis = .horizontal
        idGroup.spacing = 8
        idGroup.alignment = .center
        idGroup.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(idGroup)

        var disconnectCfg = UIButton.Configuration.plain()
        disconnectCfg.attributedTitle = AttributedString(
            "Disconnect", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13, weight: .semibold)]))
        disconnectCfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 13, bottom: 0, trailing: 13)
        disconnectButton.configuration = disconnectCfg
        disconnectButton.layer.cornerRadius = 15
        disconnectButton.layer.borderWidth = 0.5
        disconnectButton.translatesAutoresizingMaskIntoConstraints = false
        disconnectButton.addTarget(self, action: #selector(disconnectTapped), for: .touchUpInside)
        headerView.addSubview(disconnectButton)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            backButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 14),
            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            backButton.widthAnchor.constraint(equalToConstant: 30),
            backButton.heightAnchor.constraint(equalToConstant: 30),

            statusRing.widthAnchor.constraint(equalToConstant: 13),
            statusRing.heightAnchor.constraint(equalToConstant: 13),
            statusDot.centerXAnchor.constraint(equalTo: statusRing.centerXAnchor),
            statusDot.centerYAnchor.constraint(equalTo: statusRing.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            idGroup.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 10),
            idGroup.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            idGroup.trailingAnchor.constraint(lessThanOrEqualTo: disconnectButton.leadingAnchor, constant: -8),

            disconnectButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -14),
            disconnectButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            disconnectButton.heightAnchor.constraint(equalToConstant: 30),

            headerView.bottomAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 10),

            terminalView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        setStatus(.connecting)
    }

    private func setupOverlay() {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlaySpinner.translatesAutoresizingMaskIntoConstraints = false
        overlaySpinner.startAnimating()
        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        overlayLabel.text = "Connecting…"
        overlayLabel.font = .systemFont(ofSize: 13)
        overlayLabel.textAlignment = .center

        overlay.addSubview(overlaySpinner)
        overlay.addSubview(overlayLabel)
        view.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlaySpinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            overlaySpinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -10),
            overlayLabel.topAnchor.constraint(equalTo: overlaySpinner.bottomAnchor, constant: 10),
            overlayLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
        ])
    }

    // MARK: - Theming

    private func applyTheme() {
        overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        view.backgroundColor = theme.background
        theme.apply(to: terminalView)

        headerView.backgroundColor = theme.panel
        headerBorder.backgroundColor = theme.line.cgColor
        backButton.backgroundColor = theme.keyBg
        backButton.tintColor = theme.fg
        hostLabel.textColor = theme.bright
        subLabel.textColor = theme.dim
        disconnectButton.configuration?.baseForegroundColor = theme.red
        disconnectButton.layer.borderColor = theme.line.cgColor

        overlay.backgroundColor = theme.background
        overlaySpinner.color = theme.dim
        overlayLabel.textColor = theme.dim

        accessory.applyTheme(theme)
        if let dot = currentStatusColor { paintStatus(dot) }
    }

    // MARK: - Status dot

    private enum Status { case connecting, connected, closed }
    private var currentStatusColor: UIColor?

    private func setStatus(_ status: Status) {
        let color: UIColor
        switch status {
        case .connecting: color = theme.amber
        case .connected: color = theme.green
        case .closed: color = theme.red
        }
        paintStatus(color)
    }

    private func paintStatus(_ color: UIColor) {
        currentStatusColor = color
        statusDot.backgroundColor = color
        statusRing.backgroundColor = color.withAlphaComponent(0.18)
    }

    // MARK: - Session

    private func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        connect()
    }

    private func connect() {
        view.layoutIfNeeded()
        let terminal = terminalView.getTerminal()
        let cols = terminal.cols > 0 ? terminal.cols : 80
        let rows = terminal.rows > 0 ? terminal.rows : 24

        setStatus(.connecting)
        let session = SSHTerminalSession(config: SSHTerminalSession.Config(config))
        session.onData = { [weak self] bytes in
            guard let self else { return }
            if self.currentStatusColor == self.theme.amber { self.setStatus(.connected) }
            self.hideOverlay()
            self.terminalView.feed(byteArray: bytes)
        }
        session.onClosed = { [weak self] reason in
            self?.handleClosed(reason)
        }
        self.session = session
        session.connect(cols: cols, rows: rows)
    }

    private func hideOverlay() {
        guard overlay.superview != nil else { return }
        overlaySpinner.stopAnimating()
        overlay.removeFromSuperview()
    }

    private func handleClosed(_ reason: String?) {
        guard !sessionClosed else { return }
        sessionClosed = true
        hideOverlay()
        session = nil
        setStatus(.closed)

        guard !userInitiatedClose, isViewLoaded, view.window != nil else { return }

        let message = reason ?? "The connection was closed."
        terminalView.feed(text: "\r\n\u{001B}[31m[\(message)]\u{001B}[0m\r\n")

        let alert = UIAlertController(title: "Disconnected", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Reconnect", style: .default) { [weak self] _ in self?.reconnect() })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in self?.dismissSelf() })
        present(alert, animated: true)
    }

    private func reconnect() {
        sessionClosed = false
        userInitiatedClose = false
        connect()
        _ = terminalView.becomeFirstResponder()
    }

    // MARK: - Actions

    @objc private func backTapped() {
        dismissSelf()
    }

    @objc private func disconnectTapped() {
        userInitiatedClose = true
        session?.disconnect()
        dismissSelf()
    }

    /// Leaves the screen: dismiss when presented (full screen), pop when pushed.
    private func dismissSelf() {
        if presentingViewController != nil {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    private func openPalette() {
        let palette = SSHCommandPaletteViewController(theme: theme)
        palette.onSelect = { [weak self] action in self?.runPaletteAction(action) }
        present(palette, animated: true)
    }

    private func runPaletteAction(_ action: PaletteItem.Action) {
        switch action {
        case .reconnect:
            if session == nil { reconnect() }
            _ = terminalView.becomeFirstResponder()
        case .clear:
            session?.send(Data([0x0c]))   // Ctrl-L
        case .scrollToLatest:
            terminalView.scroll(toPosition: 1.0)
        case .runCommand(let cmd):
            session?.send(Data((cmd + "\n").utf8))
            _ = terminalView.becomeFirstResponder()
        }
    }
}

// MARK: - TerminalViewDelegate

extension SSHTerminalViewController: TerminalViewDelegate {

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.send(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // Many shells emit "user@host: cwd" — surface the host as the title line,
        // demoting the dialed address to the subtitle (matches the design's
        // hostname-over-IP layout).
        guard let at = title.lastIndex(of: "@") else { return }
        let after = title[title.index(after: at)...]
        let host = after.prefix { $0 != ":" && $0 != " " }
        guard !host.isEmpty else { return }
        hostLabel.text = String(host)
        subLabel.text = config.host
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        UIApplication.shared.open(url)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
