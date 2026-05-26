//
//  ModelPickerVC.swift
//  Loop
//
//  Settings ▸ Model. Three sub-screens behind a segmented control:
//  Inference, STT, and TTS. All three persist to iCloud-KVS via their
//  respective stores (ModelSelectionStore, STTProviderStore,
//  TTSProviderStore) so picks survive relaunches and sync across devices.
//
//  Each segment owns its own data source, footer copy, and "needs key"
//  prompt. The Apple ▸ Inference flow stays grouped by provider; STT and
//  TTS are flat lists since there are only a handful of choices and no
//  meaningful sub-grouping.
//

import UIKit

final class ModelPickerVC: UIViewController {

    /// Which sub-screen the user is looking at. Order matches the segmented
    /// control's segment indices.
    private enum Segment: Int, CaseIterable {
        case inference = 0
        case stt       = 1
        case tts       = 2

        var title: String {
            switch self {
            case .inference: return "Inference"
            case .stt:       return "STT"
            case .tts:       return "TTS"
            }
        }
    }

    private let segmentedControl = UISegmentedControl(items: Segment.allCases.map { $0.title })
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private var segment: Segment = .inference {
        didSet { tableView.reloadData() }
    }

    /// Providers that actually have at least one inference model. Computed
    /// once: the catalog is static for the app's life.
    private let inferenceProviders: [ModelProvider] = ModelProvider.allCases.filter {
        !ModelSelection.models(for: $0).isEmpty
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Model"
        view.backgroundColor = .systemGroupedBackground

        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        view.addSubview(segmentedControl)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "model")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            segmentedControl.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            segmentedControl.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 12),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // A key edited elsewhere (Settings ▸ Keys) changes our "key
        // configured" footers, so refresh when KeyStore changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reload),
            name: KeyStore.didChangeNotification,
            object: nil
        )
    }

    @objc private func segmentChanged() {
        guard let s = Segment(rawValue: segmentedControl.selectedSegmentIndex) else { return }
        segment = s
    }

    @objc private func reload() {
        tableView.reloadData()
    }

    private func keyConfigured(_ key: KeyStore.Key) -> Bool {
        KeyStore.shared.source(for: key) != .missing
    }

    // MARK: - Inference data source

    private func inferenceModels(in section: Int) -> [ModelSelection] {
        ModelSelection.models(for: inferenceProviders[section])
    }

    private func inferenceFooter(for provider: ModelProvider) -> String {
        switch provider {
        case .apple:
            return "Runs on-device. No API key or network required — also used automatically whenever you're offline."
        case .openAI:
            return keyConfigured(.openAI)
                ? "Uses your OpenAI API key."
                : "Needs an OpenAI API key. Add one in Settings ▸ Keys."
        case .anthropic:
            return keyConfigured(.anthropic)
                ? "Uses your Anthropic API key."
                : "Needs an Anthropic API key. Add one in Settings ▸ Keys."
        case .kimi:
            return keyConfigured(.kimi)
                ? "Uses your Kimi (Moonshot) API key."
                : "Needs a Kimi API key. Add one in Settings ▸ Keys."
        }
    }
}

// MARK: - Table view

extension ModelPickerVC: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        switch segment {
        case .inference: return inferenceProviders.count
        case .stt, .tts: return 1
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch segment {
        case .inference: return inferenceProviders[section].displayName
        case .stt:       return "Speech-to-Text"
        case .tts:       return "Text-to-Speech"
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch segment {
        case .inference:
            return inferenceFooter(for: inferenceProviders[section])
        case .stt:
            return "Used when you hold the mic button or trigger voice via the Action Button. Auto picks the best engine for your network."
        case .tts:
            return "How the assistant's replies are spoken. The on-device option runs without a network. Each cloud option needs its own key in Settings ▸ Keys."
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch segment {
        case .inference: return inferenceModels(in: section).count
        case .stt:       return STTProvider.allCases.count
        case .tts:       return TTSProvider.allCases.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "model", for: indexPath)
        var config = cell.defaultContentConfiguration()

        switch segment {
        case .inference:
            let model = inferenceModels(in: indexPath.section)[indexPath.row]
            config.text = model.displayName
            cell.accessoryType = (model == ModelSelectionStore.current) ? .checkmark : .none

        case .stt:
            let stt = STTProvider.allCases[indexPath.row]
            config.text = stt.displayName
            config.secondaryText = stt.summary
            config.secondaryTextProperties.numberOfLines = 0
            cell.accessoryType = (stt == STTProviderStore.current) ? .checkmark : .none

        case .tts:
            let tts = TTSProvider.allCases[indexPath.row]
            config.text = tts.displayName
            config.secondaryText = ttsRowSubtitle(for: tts)
            config.secondaryTextProperties.numberOfLines = 0
            cell.accessoryType = (tts == TTSProviderStore.current) ? .checkmark : .none
        }

        cell.contentConfiguration = config
        return cell
    }

    /// One-line description per TTS provider, with a key-status badge so
    /// the user can tell at a glance which providers will actually work.
    private func ttsRowSubtitle(for tts: TTSProvider) -> String {
        if let key = TTSProviderStore.requiredKey(for: tts) {
            let configured = keyConfigured(key)
            return configured
                ? "Uses your \(key.displayName)"
                : "Needs your \(key.displayName) — add it in Settings ▸ Keys"
        }
        return "On-device. No network, no API key."
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch segment {
        case .inference:
            let picked = inferenceModels(in: indexPath.section)[indexPath.row]
            applyInference(picked)
        case .stt:
            let picked = STTProvider.allCases[indexPath.row]
            applySTT(picked)
        case .tts:
            let picked = TTSProvider.allCases[indexPath.row]
            applyTTS(picked)
        }
    }

    // MARK: Inference apply

    private func applyInference(_ model: ModelSelection) {
        guard model != ModelSelectionStore.current else { return }
        if let key = model.requiredKey, KeyStore.shared.source(for: key) == .missing {
            promptForMissingKey(label: model.displayName, key: key) { [weak self] in
                ModelSelectionStore.current = model
                self?.tableView.reloadData()
            }
            return
        }
        ModelSelectionStore.current = model
        tableView.reloadData()
    }

    // MARK: STT apply

    private func applySTT(_ provider: STTProvider) {
        guard provider != STTProviderStore.current else { return }
        if let key = provider.requiredKey, KeyStore.shared.source(for: key) == .missing {
            promptForMissingKey(label: "\(provider.displayName) STT", key: key) { [weak self] in
                STTProviderStore.current = provider
                self?.tableView.reloadData()
            }
            return
        }
        STTProviderStore.current = provider
        tableView.reloadData()
    }

    // MARK: TTS apply

    private func applyTTS(_ provider: TTSProvider) {
        guard provider != TTSProviderStore.current else { return }
        if let key = TTSProviderStore.requiredKey(for: provider),
           KeyStore.shared.source(for: key) == .missing {
            promptForMissingKey(label: "\(provider.displayName) TTS", key: key) { [weak self] in
                TTSProviderStore.current = provider
                self?.tableView.reloadData()
            }
            return
        }
        TTSProviderStore.current = provider
        tableView.reloadData()
    }

    // MARK: Shared "needs key" sheet

    /// Reused by all three segments. The pick gets committed even if the user
    /// jumps to add the key (so when they pop back, the checkmark already
    /// reflects their choice) — same UX as the previous Inference-only flow.
    private func promptForMissingKey(label: String, key: KeyStore.Key, onCommit: @escaping () -> Void) {
        let alert = UIAlertController(
            title: "\(key.displayName) API key required",
            message: "\(label) needs a \(key.displayName) API key to work. Add one now to enable this choice.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add Key", style: .default) { [weak self] _ in
            guard let self else { return }
            onCommit()
            self.navigationController?.pushViewController(
                KeyEditVC(focusing: key),
                animated: true
            )
        })
        present(alert, animated: true)
    }
}
