//
//  SSHSettingsVC.swift
//  Loop
//
//  Detail screen pushed from Settings → SSH. Lets the user configure host,
//  port, username, private key (secure textarea), and optional passphrase.
//  Values are persisted through SSHConfigStore.
//

import UIKit

final class SSHSettingsVC: UIViewController {

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    private let hostField = SSHSettingsVC.makeField(placeholder: "Host (e.g. 192.168.1.10)")
    private let portField = SSHSettingsVC.makeField(placeholder: "Port", keyboard: .numberPad)
    private let usernameField = SSHSettingsVC.makeField(placeholder: "Username")
    private let privateKeyView = SSHSettingsVC.makeTextView(placeholder: "Private Key (PEM)")
    private let passphraseField: UITextField = {
        let f = SSHSettingsVC.makeField(placeholder: "Passphrase (optional)")
        f.isSecureTextEntry = true
        return f
    }()

    // Connection status row (hidden until a save triggers a connection check).
    private let statusRow = UIStackView()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let statusDot = UIView()
    private let statusLabel = UILabel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SSH"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(saveTapped))

        setupLayout()
        loadCurrent()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardFrameWillChange(_ note: Notification) {
        guard
            let endFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
            let window = view.window
        else { return }
        let frameInView = view.convert(endFrame, from: window)
        let overlap = max(0, scrollView.frame.maxY - frameInView.minY)
        applyKeyboardInset(overlap, note: note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        applyKeyboardInset(0, note: note)
    }

    private func applyKeyboardInset(_ bottom: CGFloat, note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? UIView.AnimationCurve.easeInOut.rawValue
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16)

        UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
            self.scrollView.contentInset.bottom = bottom
            self.scrollView.verticalScrollIndicatorInsets.bottom = bottom
            if bottom > 0, let focused = self.findFirstResponder(in: self.view) {
                let target = focused.convert(focused.bounds, to: self.scrollView).insetBy(dx: 0, dy: -12)
                self.scrollView.scrollRectToVisible(target, animated: false)
            }
        })
    }

    private func findFirstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for sub in view.subviews {
            if let found = findFirstResponder(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Layout

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])

        let items: [(String, UIView)] = [
            ("Host", hostField),
            ("Port", portField),
            ("Username", usernameField),
            ("Private Key", privateKeyView),
            ("Passphrase", passphraseField),
        ]

        for (label, field) in items {
            let lbl = UILabel()
            lbl.text = label
            lbl.font = .preferredFont(forTextStyle: .subheadline)
            lbl.textColor = .secondaryLabel
            stack.addArrangedSubview(lbl)
            stack.addArrangedSubview(field)

            if let tv = field as? UITextView {
                tv.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            }
        }

        setupStatusRow()
    }

    private func setupStatusRow() {
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 8
        statusRow.isHidden = true

        statusSpinner.hidesWhenStopped = true

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.layer.cornerRadius = 5
        statusDot.isHidden = true
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.numberOfLines = 0

        statusRow.addArrangedSubview(statusSpinner)
        statusRow.addArrangedSubview(statusDot)
        statusRow.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(statusRow)
    }

    // MARK: - Connection status

    private enum ConnState {
        case checking
        case connected
        case failed(String)
    }

    private func setStatus(_ state: ConnState) {
        statusRow.isHidden = false
        switch state {
        case .checking:
            statusDot.isHidden = true
            statusSpinner.startAnimating()
            statusLabel.text = "Checking connection…"
            statusLabel.textColor = .secondaryLabel
        case .connected:
            statusSpinner.stopAnimating()
            statusDot.isHidden = false
            statusDot.backgroundColor = .systemGreen
            statusLabel.text = "Connected"
            statusLabel.textColor = .label
        case .failed(let message):
            statusSpinner.stopAnimating()
            statusDot.isHidden = false
            statusDot.backgroundColor = .systemRed
            statusLabel.text = message
            statusLabel.textColor = .label
        }
    }

    // MARK: - Data

    private func loadCurrent() {
        let cfg = SSHConfigStore.shared.config
        hostField.text = cfg.host
        portField.text = cfg.port == 0 ? "22" : String(cfg.port)
        usernameField.text = cfg.username
        privateKeyView.text = cfg.privateKey
        passphraseField.text = cfg.passphrase
    }

    @objc private func saveTapped() {
        view.endEditing(true)

        let port = Int(portField.text ?? "22") ?? 22
        let config = SSHConfig(
            host: hostField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            port: port,
            username: usernameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            privateKey: privateKeyView.text.trimmingCharacters(in: .whitespacesAndNewlines),
            passphrase: passphraseField.text ?? ""
        )
        SSHConfigStore.shared.config = config

        guard config.isConfigured else {
            setStatus(.failed("Enter host, username, and private key to connect."))
            return
        }

        setStatus(.checking)
        Task { @MainActor in
            do {
                try await SSHSkill.shared.testConnection()
                self.setStatus(.connected)
            } catch {
                self.setStatus(.failed("Could not connect: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Factory helpers

    private static func makeField(placeholder: String, keyboard: UIKeyboardType = .default) -> UITextField {
        let f = UITextField()
        f.placeholder = placeholder
        f.borderStyle = .roundedRect
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.keyboardType = keyboard
        f.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        return f
    }

    private static func makeTextView(placeholder: String) -> UITextView {
        let tv = UITextView()
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.layer.cornerRadius = 8
        tv.layer.borderWidth = 0.5
        tv.layer.borderColor = UIColor.separator.cgColor
        tv.backgroundColor = .secondarySystemGroupedBackground
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.isSecureTextEntry = true
        return tv
    }
}
