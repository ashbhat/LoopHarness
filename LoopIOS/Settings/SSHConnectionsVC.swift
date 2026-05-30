//
//  SSHConnectionsVC.swift
//  Loop
//
//  Root screen for Settings → SSH: a list of saved SSH connections. The top
//  row is the default — the connection the `ssh_client` skill and the Loop
//  Runner transport use each session. A + button adds a new connection; rows
//  tap into the per-connection editor (`SSHSettingsVC`); swipe trailing to
//  Delete or open a Terminal, swipe leading to make a connection the default.
//
//  iOS-only (references the SwiftTerm-backed terminal); excluded from the
//  Mac/Vision targets.
//

import UIKit

final class SSHConnectionsVC: UITableViewController {

    private var connections: [SSHConfig] = []
    private let emptyLabel = UILabel()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SSH"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        emptyLabel.text = "No SSH connections.\nTap + to add one."
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .subheadline)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        connections = SSHConfigStore.shared.connections
        tableView.backgroundView = connections.isEmpty ? emptyLabel : nil
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func addTapped() {
        navigationController?.pushViewController(SSHSettingsVC(connection: nil), animated: true)
    }

    private func openTerminal(_ connection: SSHConfig) {
        guard connection.isConfigured else {
            let alert = UIAlertController(
                title: "Not configured",
                message: "Add a host, username, and private key before opening a terminal.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let terminal = SSHTerminalViewController(config: connection)
        terminal.modalPresentationStyle = .fullScreen
        present(terminal, animated: true)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        connections.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        connections.isEmpty ? nil : "The top connection is the default used for new sessions. Swipe right on another to make it the default."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
        let conn = connections[indexPath.row]
        let isDefault = indexPath.row == 0

        cell.textLabel?.text = conn.displayName
        cell.detailTextLabel?.text = conn.endpointSummary
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.accessoryType = .disclosureIndicator

        // Leading dot: filled green for the default, hollow for the rest.
        let symbol = isDefault ? "circle.fill" : "circle"
        cell.imageView?.image = UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11))
        cell.imageView?.tintColor = isDefault ? .systemGreen : .tertiaryLabel
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let conn = connections[indexPath.row]
        navigationController?.pushViewController(SSHSettingsVC(connection: conn), animated: true)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let conn = connections[indexPath.row]

        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            SSHConfigStore.shared.delete(id: conn.id)
            self?.reload()
            done(true)
        }
        let terminal = UIContextualAction(style: .normal, title: "Terminal") { [weak self] _, _, done in
            self?.openTerminal(conn)
            done(true)
        }
        terminal.backgroundColor = .systemGreen
        return UISwipeActionsConfiguration(actions: [delete, terminal])
    }

    override func tableView(_ tableView: UITableView,
                            leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row != 0 else { return nil }   // already the default
        let conn = connections[indexPath.row]
        let makeDefault = UIContextualAction(style: .normal, title: "Default") { [weak self] _, _, done in
            SSHConfigStore.shared.makeDefault(id: conn.id)
            self?.reload()
            done(true)
        }
        makeDefault.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [makeDefault])
    }
}
