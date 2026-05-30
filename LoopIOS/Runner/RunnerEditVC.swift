//
//  RunnerEditVC.swift
//  Loop
//
//  Add/edit form for a single Loop Runner. Shows nickname, URL, and shared
//  secret fields plus a "Test Connection" button that calls `GET /health`.
//  Secrets are stored in the Keychain via RunnerStore — never in UserDefaults.
//
//  On first runner add the app requests notification permission
//  (`.alert + .sound + .badge`) so results can surface as local notifications.
//

#if os(iOS)

import UIKit
import UserNotifications
import os

final class RunnerEditVC: UIViewController {

    var onSave: (() -> Void)?

    private var runner: RunnerConfig?
    private let isNew: Bool

    private let nicknameField = UITextField()
    private let urlField = UITextField()
    private let secretField = UITextField()
    private let testButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    init(runner: RunnerConfig?) {
        self.runner = runner
        self.isNew = runner == nil
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? "Add Runner" : "Edit Runner"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save,
            target: self,
            action: #selector(saveTapped)
        )

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])

        stack.addArrangedSubview(makeLabel("Nickname"))
        configureField(nicknameField, placeholder: "My Runner VM", text: runner?.nickname)
        stack.addArrangedSubview(nicknameField)

        stack.addArrangedSubview(makeLabel("Base URL"))
        configureField(urlField, placeholder: "https://my-vm.example.com:8080", text: runner?.baseURL)
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        stack.addArrangedSubview(urlField)

        stack.addArrangedSubview(makeLabel("Shared Secret"))
        configureField(secretField, placeholder: "Bearer token", text: nil)
        secretField.isSecureTextEntry = true
        secretField.autocapitalizationType = .none
        secretField.autocorrectionType = .no
        if let ref = runner?.secretRef, let existing = RunnerStore.shared.secret(for: ref) {
            secretField.text = existing
        }
        stack.addArrangedSubview(secretField)

        testButton.setTitle("  Test Connection", for: .normal)
        testButton.setImage(UIImage(systemName: "bolt.horizontal"), for: .normal)
        testButton.addTarget(self, action: #selector(testTapped), for: .touchUpInside)
        testButton.contentHorizontalAlignment = .center
        stack.addArrangedSubview(testButton)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        stack.addArrangedSubview(statusLabel)
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        guard let nickname = nicknameField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nickname.isEmpty else {
            showAlert("Nickname is required")
            return
        }
        guard let urlStr = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlStr.isEmpty,
              URL(string: urlStr) != nil else {
            showAlert("A valid URL is required")
            return
        }
        guard let secret = secretField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            showAlert("Shared secret is required")
            return
        }

        let isFirstRunner = RunnerStore.shared.loadRunners().isEmpty && isNew

        if isNew {
            let config = RunnerConfig(nickname: nickname, baseURL: urlStr)
            RunnerStore.shared.setSecret(secret, for: config.secretRef)
            RunnerStore.shared.addRunner(config)
        } else if var existing = runner {
            existing.nickname = nickname
            existing.baseURL = urlStr
            RunnerStore.shared.setSecret(secret, for: existing.secretRef)
            RunnerStore.shared.updateRunner(existing)
        }

        if isFirstRunner {
            requestNotificationPermission()
        }

        onSave?()
        navigationController?.popViewController(animated: true)
    }

    @objc private func testTapped() {
        guard let urlStr = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: urlStr),
              let secret = secretField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            statusLabel.text = "Fill in URL and secret first"
            statusLabel.textColor = .systemOrange
            return
        }

        statusLabel.text = "Testing…"
        statusLabel.textColor = .secondaryLabel
        testButton.isEnabled = false

        let client = LoopRunnerClient(baseURL: url, sharedSecret: secret)
        Task {
            do {
                let health = try await client.checkHealth()
                await MainActor.run {
                    statusLabel.text = "Connected — status: \(health.status)"
                    statusLabel.textColor = .systemGreen
                    testButton.isEnabled = true
                }
            } catch {
                await MainActor.run {
                    statusLabel.text = "Failed: \(error.localizedDescription)"
                    statusLabel.textColor = .systemRed
                    testButton.isEnabled = true
                }
            }
        }
    }

    // MARK: - Notification permission

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error = error {
                os_log(.error, "Notification auth error: %{public}@", error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        return label
    }

    private func configureField(_ field: UITextField, placeholder: String, text: String?) {
        field.borderStyle = .roundedRect
        field.placeholder = placeholder
        field.text = text
        field.font = .preferredFont(forTextStyle: .body)
    }

    private func showAlert(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

#endif
