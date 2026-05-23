//
//  KeyEditVC.swift
//  Loop
//
//  Service editor. Shows one input row per `KeyStore.Key` belonging to a
//  service (e.g. GitHub: PAT + optional API base URL), so a user doesn't have
//  to drill into separate per-key panels to fully configure one provider.
//
//  Each row is independently saveable / clearable. The editor never displays
//  the stored value — only a masked "•••• abcd" preview — so a stolen unlocked
//  phone can't read back the secret. The user replaces a key by typing a fresh
//  one into its (empty) field; clearing has its own destructive action per row.
//

import UIKit

final class KeyEditVC: UIViewController {

    private let service: KeyStore.Service
    /// Per-key UI rows, in `service.keys` order. Indexed lookups keep the save
    /// path straightforward; the rows array is also what we walk to refresh
    /// preview/status after a Keychain write.
    private var rows: [KeyInputRow] = []
    /// Key whose input field should receive focus on first appearance. Set by
    /// deep-link callers (IntegrationsVC) that opened us with a specific key
    /// in mind; nil → focus the first row.
    private var initialFocusKey: KeyStore.Key?

    /// Primary initialiser used by `KeysVC` — opens the editor without a
    /// pre-selected field.
    init(service: KeyStore.Service) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    /// Convenience for deep-link callers that hand us a specific `Key`. We
    /// open its parent service and focus the matching input row on appear.
    convenience init(focusing key: KeyStore.Key) {
        let service = KeyStore.Service.containing(key) ?? .openAI
        self.init(service: service)
        self.initialFocusKey = key
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = service.displayName
        view.backgroundColor = .systemGroupedBackground

        // Header — service summary + footnote about Keychain storage. The
        // per-key purpose blurb lives on each row.
        let summaryLabel = UILabel()
        summaryLabel.text = service.summary
        summaryLabel.font = .preferredFont(forTextStyle: .footnote)
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.numberOfLines = 0

        let footerLabel = UILabel()
        footerLabel.text = "Keys are stored securely in the iOS Keychain on this device. They are never synced or sent to Loop's servers."
        footerLabel.font = .preferredFont(forTextStyle: .footnote)
        footerLabel.textColor = .secondaryLabel
        footerLabel.numberOfLines = 0

        // One row per key the service exposes — ordered with the primary key
        // first so the user lands on it by default.
        rows = service.keys.map { KeyInputRow(key: $0) }

        let stack = UIStackView(arrangedSubviews: [summaryLabel] + rows.map { $0 as UIView } + [footerLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(20, after: summaryLabel)
        if let lastRow = rows.last {
            stack.setCustomSpacing(24, after: lastRow)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Wrap in a scroll view because Obsidian's 3-field editor + soft
        // keyboard can overflow on smaller phones.
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.addSubview(stack)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyStoreDidChange),
            name: KeyStore.didChangeNotification,
            object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Focus the deep-linked row if one was requested, otherwise the first.
        let target = initialFocusKey.flatMap { focus in
            rows.first(where: { $0.key == focus })
        } ?? rows.first
        target?.beginEditing()
        // One-shot — don't re-focus on subsequent appearances (e.g. after
        // dismissing a clear-confirmation alert).
        initialFocusKey = nil
    }

    @objc private func keyStoreDidChange() {
        for row in rows { row.refreshState() }
    }
}

// MARK: - Per-key input row

/// A single field in the service editor: header (key display name), purpose
/// subtitle, current-value preview, the input itself, an inline status line,
/// and a destructive "Clear" affordance. Owns the per-key save/clear logic so
/// the parent VC is just a stack of these.
private final class KeyInputRow: UIView, UITextFieldDelegate {

    let key: KeyStore.Key

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let previewLabel = UILabel()
    private let textField = UITextField()
    private let statusLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)

    init(key: KeyStore.Key) {
        self.key = key
        super.init(frame: .zero)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.text = key.displayName

        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        subtitleLabel.text = key.subtitle

        let currentHeader = UILabel()
        currentHeader.font = .preferredFont(forTextStyle: .caption1)
        currentHeader.textColor = .secondaryLabel
        currentHeader.text = "Current value"

        previewLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        previewLabel.textColor = .label
        previewLabel.numberOfLines = 1
        previewLabel.lineBreakMode = .byTruncatingMiddle

        textField.placeholder = Self.isSecret(key) ? "Paste new key" : "Paste new value"
        textField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.isSecureTextEntry = Self.isSecret(key)
        textField.borderStyle = .roundedRect
        textField.backgroundColor = .tertiarySystemGroupedBackground
        textField.returnKeyType = .done
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .preferredFont(forTextStyle: .caption2)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        saveButton.setTitle("Save", for: .normal)
        saveButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote).bold()
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        clearButton.setTitle("Clear", for: .normal)
        clearButton.setTitleColor(.systemRed, for: .normal)
        clearButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)

        let actions = UIStackView(arrangedSubviews: [clearButton, UIView(), saveButton])
        actions.axis = .horizontal
        actions.spacing = 12
        actions.alignment = .center

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            subtitleLabel,
            currentHeader,
            previewLabel,
            textField,
            statusLabel,
            actions
        ])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(10, after: subtitleLabel)
        stack.setCustomSpacing(10, after: previewLabel)
        stack.setCustomSpacing(8, after: textField)
        stack.setCustomSpacing(8, after: statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Card-style container so each row reads as a discrete unit, matching
        // the inset-grouped table aesthetic the list uses.
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            textField.heightAnchor.constraint(equalToConstant: 40),
        ])

        refreshState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func beginEditing() {
        textField.becomeFirstResponder()
    }

    /// Reread KeyStore and update preview/status/clear-enabled. Called on
    /// init and whenever `KeyStore.didChangeNotification` fires so concurrent
    /// edits (or a Keychain sync) reflect immediately.
    func refreshState() {
        previewLabel.text = KeyStore.shared.maskedPreview(for: key)
        switch KeyStore.shared.source(for: key) {
        case .keychain:
            statusLabel.text = "Stored securely on this device. The value can't be read back — type a new one to replace it."
            clearButton.isHidden = false
        case .infoPlist:
            statusLabel.text = "Using the bundled default. Save a new value to override it."
            clearButton.isHidden = false
        case .missing:
            statusLabel.text = "Not set — optional. Features that need this will be disabled until you add a value."
            clearButton.isHidden = true
        }
    }

    // MARK: Actions

    @objc private func saveTapped() {
        let value = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            // Empty input shouldn't silently wipe the stored key — make the
            // user use Clear if that's really what they want.
            presentSimpleAlert(
                title: "Nothing to save",
                message: "Type or paste a new value into the field, or tap Clear to remove the stored value.")
            return
        }
        if KeyStore.shared.setValue(value, for: key) {
            textField.text = ""
            textField.resignFirstResponder()
        } else {
            presentSimpleAlert(
                title: "Couldn’t save \(key.displayName)",
                message: "The Keychain rejected the write, so nothing was stored.")
        }
    }

    @objc private func clearTapped() {
        let alert = UIAlertController(
            title: "Clear \(key.displayName)?",
            message: "Loop will fall back to the bundled default (if any). You can re-enter the value later.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            KeyStore.shared.setValue(nil, for: self.key)
        })
        viewController?.present(alert, animated: true)
    }

    // MARK: UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        saveTapped()
        return false
    }

    // MARK: Helpers

    /// Only the obvious "URL / name / id" keys are non-secrets. Everything
    /// else is a credential that should be entered into a secure field.
    private static func isSecret(_ key: KeyStore.Key) -> Bool {
        switch key {
        case .obsidianBaseURL, .obsidianVaultName, .githubBaseURL, .devinOrgID:
            return false
        default:
            return true
        }
    }

    private func presentSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        viewController?.present(alert, animated: true)
    }
}

// MARK: - Responder-chain helpers

private extension UIResponder {
    /// Walk up the responder chain to the nearest view controller — lets the
    /// row present alerts without having to inject a presenter down from its
    /// parent VC.
    var viewController: UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
