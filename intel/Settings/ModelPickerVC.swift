//
//  ModelPickerVC.swift
//  Loop
//
//  iOS counterpart to the Mac "Model" menu. Lists every `ModelSelection`
//  case grouped into a section per `ModelProvider` (Apple / OpenAI /
//  Anthropic), with a checkmark on the active pick. Tapping a row writes
//  `ModelSelectionStore.current` — the same iCloud-KVS-backed store the
//  Mac menu and AgentHarness read — so the choice syncs across devices.
//
//  Per-provider footers tell the user what each group needs: Apple runs
//  on-device with no key, the hosted providers need their API key set
//  (we surface whether it's configured so an unusable pick is obvious
//  before the next turn fails with a "model not found"/auth error).
//

import UIKit

final class ModelPickerVC: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// Providers that actually have at least one model, in `ModelProvider`
    /// order. Computed once: the model catalog is static for the app's life.
    private let providers: [ModelProvider] = ModelProvider.allCases.filter {
        !ModelSelection.models(for: $0).isEmpty
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Model"
        view.backgroundColor = .systemGroupedBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "model")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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

    @objc private func reload() {
        tableView.reloadData()
    }

    private func models(in section: Int) -> [ModelSelection] {
        ModelSelection.models(for: providers[section])
    }

    /// Footer copy describing what the provider's section needs to work.
    private func footer(for provider: ModelProvider) -> String {
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
        }
    }

    private func keyConfigured(_ key: KeyStore.Key) -> Bool {
        KeyStore.shared.source(for: key) != .missing
    }
}

extension ModelPickerVC: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        providers.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        providers[section].displayName
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        footer(for: providers[section])
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        models(in: section).count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "model", for: indexPath)
        let model = models(in: indexPath.section)[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = model.displayName
        cell.contentConfiguration = config
        cell.accessoryType = (model == ModelSelectionStore.current) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let picked = models(in: indexPath.section)[indexPath.row]
        guard picked != ModelSelectionStore.current else { return }
        ModelSelectionStore.current = picked
        // Move the checkmark. Reloading every section keeps it correct when
        // the previous pick was in a different provider's section.
        tableView.reloadData()
    }
}
