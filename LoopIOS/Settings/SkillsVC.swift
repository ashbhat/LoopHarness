//
//  SkillsVC.swift
//  Loop
//
//  Settings → Skills. Lists every installed MCP server, the tools it exposes,
//  and lets the user add or remove one. Bearer tokens live in the Keychain
//  (via `MCPRegistry.writeToken`) so the server JSON record stays safe in
//  iCloud. New servers are added either here or by tapping a
//  `loop://install/mcp?url=…` link from the web.
//

import UIKit

final class SkillsVC: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    /// Cached snapshot so we don't reload mid-render if the registry mutates.
    private var servers: [MCPServerRecord] = []
    /// If non-nil, opens the Add sheet pre-filled with this URL on appear.
    /// Used by the deep-link handler when the user taps an "Add to Loop"
    /// link in a browser.
    private var pendingInstallURL: String?

    convenience init(prefilledURL: String?) {
        self.init()
        self.pendingInstallURL = prefilledURL
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Skills"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addTapped)
        )

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "tool")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        refreshServers()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let url = pendingInstallURL {
            pendingInstallURL = nil
            presentAddSheet(prefilledURL: url)
        }
    }

    private func refreshServers() {
        servers = MCPRegistry.shared.servers
        tableView.reloadData()
    }

    // MARK: - Add

    @objc private func addTapped() {
        presentAddSheet(prefilledURL: nil)
    }

    private func presentAddSheet(prefilledURL: String?) {
        let alert = UIAlertController(
            title: "Install MCP Skill",
            message: "Paste the MCP server URL. If the service requires a token, paste it below — it's stored in the iOS Keychain.",
            preferredStyle: .alert
        )
        alert.addTextField { f in
            f.placeholder = "https://mcp.example.com/mcp"
            f.keyboardType = .URL
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
            f.text = prefilledURL
        }
        alert.addTextField { f in
            f.placeholder = "Bearer token (optional)"
            f.isSecureTextEntry = true
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Install", style: .default) { [weak self, weak alert] _ in
            let urlField = alert?.textFields?[0]
            let tokenField = alert?.textFields?[1]
            let url = urlField?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let token = tokenField?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.install(urlString: url, token: token?.isEmpty == false ? token : nil)
        })
        present(alert, animated: true)
    }

    private func install(urlString: String, token: String?) {
        // Wait-spinner so the user has feedback while we hit the network.
        let spinner = UIAlertController(title: "Installing…", message: nil, preferredStyle: .alert)
        present(spinner, animated: true)

        MCPRegistry.shared.install(urlString: urlString, bearerToken: token) { [weak self] result in
            DispatchQueue.main.async {
                spinner.dismiss(animated: true) {
                    switch result {
                    case .success(let record):
                        self?.refreshServers()
                        let toast = UIAlertController(
                            title: "Installed",
                            message: "\(record.name) — \(record.cachedTools.count) tool\(record.cachedTools.count == 1 ? "" : "s") added.",
                            preferredStyle: .alert
                        )
                        toast.addAction(UIAlertAction(title: "OK", style: .default))
                        self?.present(toast, animated: true)
                    case .failure(let error):
                        let fail = UIAlertController(
                            title: "Couldn't install",
                            message: error.localizedDescription,
                            preferredStyle: .alert
                        )
                        fail.addAction(UIAlertAction(title: "OK", style: .default))
                        self?.present(fail, animated: true)
                    }
                }
            }
        }
    }
}

// MARK: - Data source

extension SkillsVC: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        // One section per server + an explainer section at the top when
        // nothing is installed, so the empty state isn't a blank screen.
        return max(servers.count, 1)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if servers.isEmpty { return 1 }
        return 1 + servers[section].cachedTools.count // server row + one per tool
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if servers.isEmpty { return nil }
        return servers[section].name
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if servers.isEmpty {
            return "Tap + to install a remote skill from an MCP server (e.g. https://mcp.hirey.ai/mcp). The server's tools appear here and become callable by the agent."
        }
        return servers[section].url
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if servers.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            var config = cell.defaultContentConfiguration()
            config.text = "No skills installed"
            config.secondaryText = "Tap + to add an MCP server."
            cell.contentConfiguration = config
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell
        }

        let server = servers[indexPath.section]
        if indexPath.row == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            var config = cell.defaultContentConfiguration()
            config.text = server.enabled ? "Enabled" : "Disabled"
            config.secondaryText = "\(server.cachedTools.count) tool\(server.cachedTools.count == 1 ? "" : "s")"
            config.image = UIImage(systemName: server.enabled ? "checkmark.circle.fill" : "pause.circle")
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
            return cell
        }

        let tool = server.cachedTools[indexPath.row - 1]
        let cell = tableView.dequeueReusableCell(withIdentifier: "tool", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = tool.name
        config.secondaryText = tool.description
        config.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = config
        cell.accessoryType = .none
        cell.selectionStyle = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !servers.isEmpty, indexPath.row == 0 else { return }
        presentServerActions(for: servers[indexPath.section])
    }

    /// Tap the header row → action sheet with enable/disable, refresh, and
    /// remove. Cheaper than a full detail screen and matches what the user
    /// actually needs to do here.
    private func presentServerActions(for server: MCPServerRecord) {
        let sheet = UIAlertController(title: server.name,
                                      message: server.url,
                                      preferredStyle: .actionSheet)
        let toggleTitle = server.enabled ? "Disable" : "Enable"
        sheet.addAction(UIAlertAction(title: toggleTitle, style: .default) { [weak self] _ in
            MCPRegistry.shared.setEnabled(!server.enabled, slug: server.slug)
            self?.refreshServers()
        })
        sheet.addAction(UIAlertAction(title: "Refresh tools", style: .default) { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async {
                MCPRegistry.shared.reload()
                DispatchQueue.main.async { self?.refreshServers() }
            }
        })
        sheet.addAction(UIAlertAction(title: "Edit token…", style: .default) { [weak self] _ in
            self?.presentEditToken(for: server)
        })
        sheet.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            MCPRegistry.shared.uninstall(slug: server.slug)
            self?.refreshServers()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // iPad sheets need a source rect.
        if let pop = sheet.popoverPresentationController, let cell = view {
            pop.sourceView = cell
            pop.sourceRect = CGRect(x: cell.bounds.midX, y: cell.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    private func presentEditToken(for server: MCPServerRecord) {
        let alert = UIAlertController(
            title: "Token for \(server.name)",
            message: "Paste a new bearer token, or clear the field to remove the stored one.",
            preferredStyle: .alert
        )
        alert.addTextField { f in
            f.placeholder = "Bearer token"
            f.isSecureTextEntry = true
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
            f.text = MCPRegistry.readToken(slug: server.slug)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            let token = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            MCPRegistry.writeToken(token, slug: server.slug)
        })
        present(alert, animated: true)
    }
}
