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

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SSH"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(saveTapped))

        setupLayout()
        loadCurrent()
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
        let port = Int(portField.text ?? "22") ?? 22
        SSHConfigStore.shared.config = SSHConfig(
            host: hostField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            port: port,
            username: usernameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            privateKey: privateKeyView.text.trimmingCharacters(in: .whitespacesAndNewlines),
            passphrase: passphraseField.text ?? ""
        )

        let alert = UIAlertController(title: "Saved", message: "SSH configuration updated.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
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
