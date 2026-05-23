//
//  MarkdownEditorViewController.swift
//  intel (iOS)
//
//  A real, editable markdown editor — opened in place of QuickLook when the
//  user taps a `.md` file (in the Files drawer or via a file link inside a
//  chat message). The buffer stays raw markdown; styling is layered live by
//  MarkdownSourceHighlighter so the source reads like a document while
//  remaining fully editable.
//
//  Saving: an explicit Save button plus an automatic save when the editor is
//  dismissed with unsaved changes, so edits are never silently lost. Writes
//  go through Workspace's coordinated I/O so iCloud sees them atomically.
//

import UIKit

final class MarkdownEditorViewController: UIViewController {

    // MARK: - Entry points

    static func isMarkdownFile(_ url: URL) -> Bool {
        MarkdownSourceHighlighter.isMarkdownFile(url)
    }

    /// Wrap in a nav controller and present full-screen from `presenter`.
    static func present(for url: URL, from presenter: UIViewController) {
        let editor = MarkdownEditorViewController(fileURL: url)
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .fullScreen
        presenter.present(nav, animated: true)
    }

    // MARK: - State

    private let fileURL: URL
    private let baseFontSize: CGFloat = 16

    /// Last on-disk contents. `isDirty` is the buffer diverging from this.
    private var savedText: String = ""
    private var isLoaded = false
    private var isDirty: Bool { isLoaded && textView.text != savedText }

    /// Serializes writes so a Save tap and an auto-save-on-close can't race.
    private let ioQueue = DispatchQueue(label: "markdown-editor.io")

    // MARK: - Views

    private let textView = UITextView()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private lazy var saveButton = UIBarButtonItem(
        barButtonSystemItem: .save, target: self, action: #selector(saveTapped))

    // MARK: - Init

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureNavigationItem()
        configureTextView()
        configureActivityIndicator()
        observeKeyboard()
        loadFile()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Auto-save on the way out so a swipe-down / Done never drops edits.
        if (isBeingDismissed || isMovingFromParent), isDirty {
            persist(textView.text)
        }
    }

    // MARK: - Setup

    private func configureNavigationItem() {
        navigationItem.title = fileURL.lastPathComponent
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        saveButton.isEnabled = false
        navigationItem.rightBarButtonItem = saveButton
    }

    private func configureTextView() {
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .systemFont(ofSize: baseFontSize)
        textView.textColor = .label
        textView.backgroundColor = .systemBackground
        textView.isEditable = false               // until the file loads
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        // Markdown is punctuation-sensitive — keep iOS from "helpfully"
        // turning -- into an em dash or "" into smart quotes.
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.delegate = self
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureActivityIndicator() {
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        activityIndicator.startAnimating()
    }

    // MARK: - Load

    private func loadFile() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            // iCloud-evicted files need a pull-down first; best-effort and
            // time-boxed like the QuickLook path the editor replaces.
            try? Workspace.shared.ensureDownloaded(self.fileURL)
            let result: Result<String, Error>
            do {
                let data = try Data(contentsOf: self.fileURL)
                result = .success(String(decoding: data, as: UTF8.self))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let contents):
                    self.applyLoaded(contents)
                case .failure(let error):
                    self.presentLoadError(error)
                }
            }
        }
    }

    private func applyLoaded(_ contents: String) {
        savedText = contents
        textView.text = contents
        textView.isEditable = true
        isLoaded = true
        activityIndicator.stopAnimating()
        rehighlight()
        updateSaveButton()
    }

    private func presentLoadError(_ error: Error) {
        activityIndicator.stopAnimating()
        let alert = UIAlertController(
            title: "Couldn't open file",
            message: error.localizedDescription,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.dismissEditor()
        })
        present(alert, animated: true)
    }

    // MARK: - Highlighting

    private func rehighlight() {
        let selected = textView.selectedRange
        MarkdownSourceHighlighter.highlight(textView.textStorage, baseSize: baseFontSize)
        textView.selectedRange = selected
        // Keep the caret typing in body style until the next pass restyles.
        textView.typingAttributes = [
            .font: UIFont.systemFont(ofSize: baseFontSize),
            .foregroundColor: UIColor.label,
        ]
    }

    // MARK: - Save

    @objc private func saveTapped() {
        guard isDirty else { return }
        persist(textView.text)
    }

    @objc private func doneTapped() {
        if isDirty { persist(textView.text) }
        dismissEditor()
    }

    private func dismissEditor() {
        view.endEditing(true)
        dismiss(animated: true)
    }

    /// Write `contents` to disk on the io queue. Optimistically advances the
    /// saved baseline so the Save button disables immediately; on failure we
    /// surface an alert and leave the buffer marked dirty.
    private func persist(_ contents: String) {
        savedText = contents
        updateSaveButton()
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let writeError: Error?
            do {
                let data = Data(contents.utf8)
                try Workspace.shared.coordinatedWrite(to: self.fileURL) { target in
                    try data.write(to: target, options: .atomic)
                }
                writeError = nil
            } catch {
                writeError = error
            }
            if let error = writeError {
                DispatchQueue.main.async { self.presentSaveError(error) }
            }
        }
    }

    private func presentSaveError(_ error: Error) {
        // The write failed — drop the optimistic baseline so the buffer reads
        // as dirty again and the user can retry.
        savedText = ""
        updateSaveButton()
        guard presentedViewController == nil, view.window != nil else { return }
        let alert = UIAlertController(
            title: "Couldn't save",
            message: error.localizedDescription,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func updateSaveButton() {
        saveButton.isEnabled = isDirty
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        let inset = max(0, overlap - view.safeAreaInsets.bottom)
        textView.contentInset.bottom = inset
        textView.verticalScrollIndicatorInsets.bottom = inset
    }

    @objc private func keyboardWillHide() {
        textView.contentInset.bottom = 0
        textView.verticalScrollIndicatorInsets.bottom = 0
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - UITextViewDelegate

extension MarkdownEditorViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        rehighlight()
        updateSaveButton()
    }
}
