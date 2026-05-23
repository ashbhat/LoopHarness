//
//  SubagentsListVC.swift
//  Loop
//
//  Settings ▸ Subagents: unified history of every subagent the user has
//  spawned — native (in-app `SubAgent` runtimes), Devin cloud sessions, and
//  Cursor background-agent dispatches. Each source lives in its own section
//  so the user can scan for the one they care about; rows tap through to the
//  source's existing detail view (or out to the dashboard URL for Cursor,
//  which has no in-app detail yet).
//
//  Replaces the Devin-only list that used to live in `DevinAgentsListVC` —
//  same "Subagents" entry point in Settings, broader inventory behind it.
//

#if os(iOS)

import UIKit

final class SubagentsListVC: UIViewController {

    /// One row in the unified list. The associated value carries the source
    /// model so the cell renderer + tap handler can branch on kind without
    /// rebuilding the row from a string-shaped intermediate.
    private enum Row {
        case native(SubAgent)
        case devin(DevinAgentJob)
        case cursor(CursorAgentJob)
    }

    private struct Section {
        let title: String
        let rows: [Row]
        /// Shown in place of the rows when the source has nothing yet — keeps
        /// every section visible so the user can see what kinds of agents
        /// Loop can dispatch even before the first one runs.
        let emptyText: String
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var sections: [Section] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Subagents"
        view.backgroundColor = .systemGroupedBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.estimatedRowHeight = 64
        tableView.rowHeight = UITableView.automaticDimension
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // SubAgentManager already rebroadcasts devin/cursor changes through
        // `.subAgentsDidChange`, but the source services post their own
        // notifications too — observe all three so the list refreshes even if
        // someone mutes the manager-side bridge in the future.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(reload), name: .subAgentsDidChange, object: nil)
        center.addObserver(self, selector: #selector(reload), name: .devinAgentsDidChange, object: nil)
        center.addObserver(self, selector: #selector(reload), name: .cursorAgentsDidChange, object: nil)

        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
        // Catch a merge that happened on GitHub while the user was elsewhere
        // — kicks a one-shot poll of every terminal Devin job with an open
        // PR so the row flips to "Merged" without the user having to drill
        // into a detail view first. Cheap: bounded to PRs that haven't
        // already merged/closed.
        DevinAgentService.shared.pollOpenPRs()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func reload() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let native = SubAgentManager.shared.allAgents
            let devin = DevinAgentService.shared.allJobs()
            let cursor = CursorAgentService.shared.allJobs()
            self.sections = [
                Section(
                    title: "Native",
                    rows: native.map { .native($0) },
                    emptyText: "No native sub-agents have run yet."
                ),
                Section(
                    title: "Devin",
                    rows: devin.map { .devin($0) },
                    emptyText: "Ask the agent to dispatch a Devin coding task to see it here."
                ),
                Section(
                    title: "Cursor",
                    rows: cursor.map { .cursor($0) },
                    emptyText: "Ask the agent to dispatch a Cursor background agent to see it here."
                ),
            ]
            self.tableView.reloadData()
        }
    }
}

// MARK: - Table data source

extension SubagentsListVC: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let s = sections[section]
        return s.rows.isEmpty ? 1 : s.rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let section = sections[indexPath.section]
        var config = cell.defaultContentConfiguration()
        if section.rows.isEmpty {
            config.text = section.emptyText
            config.textProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }
        switch section.rows[indexPath.row] {
        case .native(let agent):
            config.text = agent.displayTitle
            config.secondaryText = Self.nativeSubtitle(for: agent)
            config.image = UIImage(systemName: Self.nativeIcon(for: agent))
            config.imageProperties.tintColor = Self.nativeTint(for: agent)
        case .devin(let job):
            config.text = job.displayTitle
            config.secondaryText = Self.devinSubtitle(for: job)
            config.image = UIImage(systemName: Self.devinIcon(for: job))
            config.imageProperties.tintColor = Self.devinTint(for: job)
        case .cursor(let job):
            config.text = Self.cursorDisplayTitle(for: job)
            config.secondaryText = Self.cursorSubtitle(for: job)
            config.image = UIImage(systemName: Self.cursorIcon(for: job))
            config.imageProperties.tintColor = Self.cursorTint(for: job)
        }
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let section = sections[indexPath.section]
        guard !section.rows.isEmpty else { return }
        switch section.rows[indexPath.row] {
        case .native(let agent):
            navigationController?.pushViewController(
                SubAgentDetailVC(agentId: agent.id),
                animated: true
            )
        case .devin(let job):
            navigationController?.pushViewController(
                DevinAgentDetailVC(sessionId: job.sessionId),
                animated: true
            )
        case .cursor(let job):
            // Cursor has no in-app detail VC yet; open the dashboard if we
            // have one, falling back to the PR for terminal jobs.
            let url = job.dashboardURL.flatMap(URL.init(string:))
                ?? job.prURL.flatMap(URL.init(string:))
            if let url = url { UIApplication.shared.open(url) }
        }
    }

    // MARK: Native presentation

    private static func nativeIcon(for agent: SubAgent) -> String {
        switch agent.state {
        case .active: return "circle.dotted"
        case .sleeping: return "moon.zzz"
        case .waitingForInput: return "hand.raised"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private static func nativeTint(for agent: SubAgent) -> UIColor {
        switch agent.state {
        case .active: return .systemGreen
        case .sleeping: return .systemYellow
        case .waitingForInput: return .systemOrange
        case .completed: return .systemGray
        case .failed: return .systemRed
        }
    }

    private static func nativeSubtitle(for agent: SubAgent) -> String {
        let state: String
        switch agent.state {
        case .active: state = "Working"
        case .sleeping: state = "Sleeping"
        case .waitingForInput: state = "Needs input"
        case .completed: state = "Completed"
        case .failed: state = "Failed"
        }
        let step = agent.currentStep.trimmingCharacters(in: .whitespacesAndNewlines)
        return step.isEmpty ? state : "\(state) · \(step)"
    }

    // MARK: Devin presentation
    // Same icon/tint/label vocabulary as the original DevinAgentsListVC so
    // the rows read identically after the unification.

    private static func devinIcon(for job: DevinAgentJob) -> String {
        // PR state wins over session state once a PR is on the table — a
        // merged PR is the outcome the user is actually waiting for, so it
        // should headline the row even after Devin's session has exited.
        switch job.prState?.lowercased() {
        case "merged": return "arrow.triangle.merge"
        case "closed": return "xmark.circle"
        default: break
        }
        switch job.status {
        case "running":   return "circle.dotted"
        case "blocked":   return "hand.raised"
        case "finished":  return "checkmark.circle.fill"
        case "expired":   return "hourglass"
        case "cancelled": return "slash.circle"
        case "stale":     return "clock.badge.exclamationmark"
        case "error":     return "exclamationmark.triangle.fill"
        default:          return "hammer"
        }
    }

    private static func devinTint(for job: DevinAgentJob) -> UIColor {
        switch job.prState?.lowercased() {
        case "merged": return .systemPurple
        case "closed": return .systemGray
        default: break
        }
        switch job.status {
        case "running":   return .systemBlue
        case "blocked":   return .systemYellow
        case "finished":  return .systemGreen
        case "expired", "stale": return .systemGray
        case "cancelled": return .systemGray
        case "error":     return .systemRed
        default:          return .label
        }
    }

    private static func devinSubtitle(for job: DevinAgentJob) -> String {
        let stateLabel: String = {
            switch job.prState?.lowercased() {
            case "merged": return "Merged"
            case "closed": return "PR closed"
            default: break
            }
            switch job.status {
            case "running":   return "Working"
            case "blocked":   return "Blocked"
            case "finished":  return "Finished"
            case "expired":   return "Expired"
            case "cancelled": return "Cancelled"
            case "stale":     return "Stopped tracking"
            case "error":     return "Error"
            default:          return job.status.capitalized
            }
        }()
        if let repo = job.repository, !repo.isEmpty {
            return "\(stateLabel) · \(DevinSkill.repoShortName(repo))"
        }
        return stateLabel
    }

    // MARK: Cursor presentation

    private static func cursorDisplayTitle(for job: CursorAgentJob) -> String {
        let task = job.task.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if task.count <= 80 { return task }
        return String(task.prefix(77)) + "…"
    }

    private static func cursorIcon(for job: CursorAgentJob) -> String {
        switch job.status {
        case "running":   return "circle.dotted"
        case "finished":  return "checkmark.circle.fill"
        case "cancelled": return "slash.circle"
        case "stale":     return "clock.badge.exclamationmark"
        case "error":     return "exclamationmark.triangle.fill"
        default:          return "cursorarrow.click"
        }
    }

    private static func cursorTint(for job: CursorAgentJob) -> UIColor {
        switch job.status {
        case "running":   return .systemBlue
        case "finished":  return .systemGreen
        case "stale", "cancelled": return .systemGray
        case "error":     return .systemRed
        default:          return .label
        }
    }

    private static func cursorSubtitle(for job: CursorAgentJob) -> String {
        let label: String
        switch job.status {
        case "running":   label = "Working"
        case "finished":  label = "Finished"
        case "cancelled": label = "Cancelled"
        case "stale":     label = "Stopped tracking"
        case "error":     label = "Error"
        default:          label = job.status.capitalized
        }
        if !job.repository.isEmpty {
            return "\(label) · \(job.repository)"
        }
        return label
    }
}

#endif
