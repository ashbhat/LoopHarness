//
//  RunnersListVC.swift
//  Loop
//
//  Settings → Runners: list of configured Loop Runner VMs. Each row shows
//  the runner's nickname, URL, last poll time, and turn count. Tap through
//  to edit; swipe to delete. The "+" button adds a new runner via
//  RunnerEditVC.
//
//  iOS-only — mirrors the ScheduledTasksVC / SubagentsListVC pattern.
//

#if os(iOS)

import UIKit

final class RunnersListVC: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var runners: [RunnerConfig] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Runners"
        view.backgroundColor = .systemGroupedBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.estimatedRowHeight = 72
        tableView.rowHeight = UITableView.automaticDimension
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addTapped)
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reload),
            name: RunnerStore.didChangeNotification,
            object: nil
        )
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func reload() {
        DispatchQueue.main.async { [weak self] in
            self?.runners = RunnerStore.shared.loadRunners()
            self?.tableView.reloadData()
        }
    }

    @objc private func addTapped() {
        let editor = RunnerEditVC(runner: nil)
        editor.onSave = { [weak self] in self?.reload() }
        navigationController?.pushViewController(editor, animated: true)
    }
}

// MARK: - Table data source

extension RunnersListVC: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        runners.isEmpty ? 1 : runners.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)

        if runners.isEmpty {
            var config = cell.defaultContentConfiguration()
            config.text = "No runners configured"
            config.textProperties.color = .secondaryLabel
            config.secondaryText = "Tap + to add a Loop Runner VM"
            cell.contentConfiguration = config
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let runner = runners[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = runner.nickname
        let lastPoll: String
        if let lp = runner.lastPollTime {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            lastPoll = formatter.localizedString(for: lp, relativeTo: Date())
        } else {
            lastPoll = "never"
        }
        config.secondaryText = "\(runner.baseURL)\nLast poll: \(lastPoll) · \(runner.lastSeenTurnCount) turns"
        config.secondaryTextProperties.numberOfLines = 2
        config.secondaryTextProperties.color = .secondaryLabel
        config.image = UIImage(systemName: "server.rack")
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !runners.isEmpty else { return }
        let runner = runners[indexPath.row]
        let editor = RunnerEditVC(runner: runner)
        editor.onSave = { [weak self] in self?.reload() }
        navigationController?.pushViewController(editor, animated: true)
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !runners.isEmpty
    }

    func tableView(_ tableView: UITableView,
                    commit editingStyle: UITableViewCell.EditingStyle,
                    forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, !runners.isEmpty else { return }
        let runner = runners[indexPath.row]
        RunnerStore.shared.deleteRunner(id: runner.id)
        runners.remove(at: indexPath.row)
        if runners.isEmpty {
            tableView.reloadData()
        } else {
            tableView.deleteRows(at: [indexPath], with: .automatic)
        }
    }
}

#endif
