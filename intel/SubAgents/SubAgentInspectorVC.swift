//
//  SubAgentInspectorVC.swift
//  Loop
//
//  Sheet shown when the user taps the top-of-screen "N sub-agents running"
//  pill. Lists every active and recently-finished sub-agent with state,
//  current step, runtime, and a kill action. Tapping a row drills into a
//  detail view that shows the agent's log feed.
//

#if os(iOS)

import UIKit

/// Lightweight wrapper for Devin/Cursor cloud agent rows in the inspector.
private enum CloudAgentRow {
    case devin(DevinAgentJob)
    case cursor(CursorAgentJob)

    var title: String {
        switch self {
        case .devin(let job): return job.displayTitle
        case .cursor(let job):
            let trimmed = job.task.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            if trimmed.count <= 80 { return trimmed }
            return String(trimmed.prefix(77)) + "\u{2026}"
        }
    }

    var status: String {
        switch self {
        case .devin(let job): return job.status.capitalized
        case .cursor(let job): return job.status.capitalized
        }
    }

    var isTerminal: Bool {
        switch self {
        case .devin(let job): return job.isTerminal
        case .cursor(let job): return job.isTerminal
        }
    }

    var providerLabel: String {
        switch self {
        case .devin: return "Devin"
        case .cursor: return "Cursor"
        }
    }

    var createdAt: Date {
        switch self {
        case .devin(let job): return job.createdAt
        case .cursor(let job): return job.createdAt
        }
    }

    var statusColor: UIColor {
        switch self {
        case .devin(let job):
            switch job.status {
            case "running":  return .systemGreen
            case "blocked":  return .systemYellow
            case "finished": return .systemGray
            case "error":    return .systemRed
            default:         return .systemGray
            }
        case .cursor(let job):
            switch job.status {
            case "running":  return .systemGreen
            case "finished": return .systemGray
            case "error":    return .systemRed
            default:         return .systemGray
            }
        }
    }
}

final class SubAgentInspectorVC: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var agents: [SubAgent] = []
    private var cloudAgents: [CloudAgentRow] = []

    /// Conversation the inspector is scoped to. Mirrors the pill's filter so
    /// the user sees only the agents that belong to the thread they came
    /// from. `nil` shows every agent (legacy / fallback).
    let conversationId: String?

    init(conversationId: String? = nil) {
        self.conversationId = conversationId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.conversationId = nil
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sub-agents"
        view.backgroundColor = .systemGroupedBackground

        let close = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )
        navigationItem.rightBarButtonItem = close

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SubAgentCell.self, forCellReuseIdentifier: SubAgentCell.reuseId)
        tableView.register(CloudAgentCell.self, forCellReuseIdentifier: CloudAgentCell.reuseId)
        tableView.estimatedRowHeight = 80
        tableView.rowHeight = UITableView.automaticDimension
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reload),
            name: .subAgentsDidChange,
            object: nil
        )
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func reload() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Mirror the unscoped allAgents ordering (alive first, then done
            // by finish-time desc) within the scoped subset.
            let live = SubAgentManager.shared.liveAgents(for: self.conversationId)
            let done = SubAgentManager.shared.finishedAgents(for: self.conversationId)
            self.agents = live + done

            // Cloud agents (Devin + Cursor): non-terminal first, then terminal,
            // most-recently-created first within each bucket.
            var cloud: [CloudAgentRow] = []
            let devinJobs = DevinAgentService.shared.allJobs().filter { job in
                self.conversationId == nil || job.conversationId == self.conversationId
            }
            for job in devinJobs where !job.isTerminal {
                cloud.append(.devin(job))
            }
            let cursorJobs = CursorAgentService.shared.allJobs().filter { job in
                self.conversationId == nil || job.conversationId == self.conversationId
            }
            for job in cursorJobs where !job.isTerminal {
                cloud.append(.cursor(job))
            }
            // Append terminal cloud jobs so user can see recent completions.
            for job in devinJobs where job.isTerminal {
                cloud.append(.devin(job))
            }
            for job in cursorJobs where job.isTerminal {
                cloud.append(.cursor(job))
            }
            self.cloudAgents = cloud
            self.tableView.reloadData()
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}

extension SubAgentInspectorVC: UITableViewDataSource, UITableViewDelegate {

    /// Section 0: native sub-agents. Section 1: cloud agents (Devin + Cursor).
    func numberOfSections(in tableView: UITableView) -> Int {
        // Always show both sections so the empty placeholder renders in
        // the correct bucket. Hide a section header when it's empty.
        return 2
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return agents.isEmpty ? nil : "Local Sub-agents"
        case 1: return cloudAgents.isEmpty ? nil : "Cloud Agents"
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return max(agents.count, (cloudAgents.isEmpty ? 1 : 0))
        case 1: return cloudAgents.count
        default: return 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            if agents.isEmpty {
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                cell.textLabel?.text = cloudAgents.isEmpty
                    ? "No agents running."
                    : "No local sub-agents running."
                cell.textLabel?.textColor = .secondaryLabel
                cell.textLabel?.textAlignment = .center
                cell.selectionStyle = .none
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: SubAgentCell.reuseId, for: indexPath) as! SubAgentCell
            cell.configure(with: agents[indexPath.row])
            return cell
        } else {
            let cell = tableView.dequeueReusableCell(withIdentifier: CloudAgentCell.reuseId, for: indexPath) as! CloudAgentCell
            cell.configure(with: cloudAgents[indexPath.row])
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            guard !agents.isEmpty else { return }
            let detail = SubAgentDetailVC(agentId: agents[indexPath.row].id)
            navigationController?.pushViewController(detail, animated: true)
        } else {
            let row = cloudAgents[indexPath.row]
            switch row {
            case .devin(let job):
                let detail = DevinAgentDetailVC(sessionId: job.sessionId)
                navigationController?.pushViewController(detail, animated: true)
            case .cursor(let job):
                if let urlString = job.prURL ?? job.dashboardURL,
                   let url = URL(string: urlString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 0, !agents.isEmpty else { return nil }
        let agent = agents[indexPath.row]
        if agent.isAlive {
            let stop = UIContextualAction(style: .destructive, title: "Stop") { _, _, done in
                SubAgentManager.shared.kill(id: agent.id)
                done(true)
            }
            stop.image = UIImage(systemName: "stop.fill")
            return UISwipeActionsConfiguration(actions: [stop])
        } else {
            let remove = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in
                SubAgentManager.shared.remove(id: agent.id)
                done(true)
            }
            remove.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [remove])
        }
    }
}

// MARK: - Cell

final class SubAgentCell: UITableViewCell {
    static let reuseId = "SubAgentCell"

    private let badge = UIView()
    private let titleLabel = UILabel()
    private let stepLabel = UILabel()
    private let stateLabel = UILabel()
    private let runtimeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        accessoryType = .disclosureIndicator

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer.cornerRadius = 5
        contentView.addSubview(badge)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        stepLabel.font = .systemFont(ofSize: 13)
        stepLabel.textColor = .secondaryLabel
        stepLabel.numberOfLines = 1
        contentView.addSubview(stepLabel)

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        stateLabel.textColor = .secondaryLabel
        contentView.addSubview(stateLabel)

        runtimeLabel.translatesAutoresizingMaskIntoConstraints = false
        runtimeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        runtimeLabel.textColor = .tertiaryLabel
        contentView.addSubview(runtimeLabel)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            badge.topAnchor.constraint(equalTo: titleLabel.topAnchor, constant: 4),
            badge.widthAnchor.constraint(equalToConstant: 10),
            badge.heightAnchor.constraint(equalToConstant: 10),

            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),

            stepLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stepLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            stepLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            stateLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stateLabel.topAnchor.constraint(equalTo: stepLabel.bottomAnchor, constant: 6),
            stateLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            runtimeLabel.leadingAnchor.constraint(equalTo: stateLabel.trailingAnchor, constant: 8),
            runtimeLabel.centerYAnchor.constraint(equalTo: stateLabel.centerYAnchor)
        ])
    }

    func configure(with agent: SubAgent) {
        titleLabel.text = agent.displayTitle
        stepLabel.text = agent.currentStep
        stateLabel.text = labelText(for: agent.state).uppercased()
        stateLabel.textColor = color(for: agent.state)
        badge.backgroundColor = color(for: agent.state)
        runtimeLabel.text = "· \(formatRuntime(agent.runtime))"
    }

    private func labelText(for state: SubAgentState) -> String {
        switch state {
        case .active: return "Active"
        case .sleeping: return "Sleeping"
        case .waitingForInput: return "Needs input"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private func color(for state: SubAgentState) -> UIColor {
        switch state {
        case .active: return .systemGreen
        case .sleeping: return .systemYellow
        case .waitingForInput: return .systemOrange
        case .completed: return .systemGray
        case .failed: return .systemRed
        }
    }

    private func formatRuntime(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%dm %02ds", m, s)
    }
}

// MARK: - Cloud Agent Cell

final class CloudAgentCell: UITableViewCell {
    static let reuseId = "CloudAgentCell"

    private let badge = UIView()
    private let titleLabel = UILabel()
    private let providerLabel = UILabel()
    private let stateLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        accessoryType = .disclosureIndicator

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer.cornerRadius = 5
        contentView.addSubview(badge)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        providerLabel.translatesAutoresizingMaskIntoConstraints = false
        providerLabel.font = .systemFont(ofSize: 13)
        providerLabel.textColor = .secondaryLabel
        contentView.addSubview(providerLabel)

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        contentView.addSubview(stateLabel)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            badge.topAnchor.constraint(equalTo: titleLabel.topAnchor, constant: 4),
            badge.widthAnchor.constraint(equalToConstant: 10),
            badge.heightAnchor.constraint(equalToConstant: 10),

            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),

            providerLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            providerLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            providerLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            stateLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stateLabel.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: 6),
            stateLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    fileprivate func configure(with row: CloudAgentRow) {
        titleLabel.text = row.title
        providerLabel.text = row.providerLabel
        stateLabel.text = row.status.uppercased()
        stateLabel.textColor = row.statusColor
        badge.backgroundColor = row.statusColor
    }
}

// MARK: - Detail (logs)

final class SubAgentDetailVC: UIViewController {
    private let agentId: String
    private let tableView = UITableView(frame: .zero, style: .plain)
    /// Snapshot of log entries; refreshed on every `subAgentsDidChange`.
    /// We render in reverse chronological order so the newest event sits at
    /// the top — feels closer to a live console.
    private var entries: [SubAgentLogEntry] = []

    init(agentId: String) {
        self.agentId = agentId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureNav()

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.estimatedRowHeight = 60
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(SubAgentLogCell.self, forCellReuseIdentifier: SubAgentLogCell.reuseId)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reload),
            name: .subAgentsDidChange,
            object: nil
        )
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureNav() {
        guard let agent = SubAgentManager.shared.agent(id: agentId) else {
            title = "Sub-agent"
            return
        }
        title = agent.displayTitle
        if agent.isAlive {
            let stop = UIBarButtonItem(
                title: "Stop",
                style: .plain,
                target: self,
                action: #selector(stopTapped)
            )
            stop.tintColor = .systemRed
            navigationItem.rightBarButtonItem = stop
        }
    }

    @objc private func reload() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let agent = SubAgentManager.shared.agent(id: self.agentId) else {
                self.entries = []
                self.tableView.reloadData()
                return
            }
            self.entries = agent.logs.reversed()
            self.configureNav()
            self.tableView.reloadData()
        }
    }

    @objc private func stopTapped() {
        SubAgentManager.shared.kill(id: agentId)
    }
}

extension SubAgentDetailVC: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(entries.count, 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if entries.isEmpty {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = "No activity yet."
            cell.textLabel?.textColor = .tertiaryLabel
            cell.textLabel?.textAlignment = .center
            cell.selectionStyle = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: SubAgentLogCell.reuseId, for: indexPath) as! SubAgentLogCell
        cell.configure(with: entries[indexPath.row])
        return cell
    }
}

// MARK: - Log cell

final class SubAgentLogCell: UITableViewCell {
    static let reuseId = "SubAgentLogCell"

    private let kindLabel = UILabel()
    private let summaryLabel = UILabel()
    private let timeLabel = UILabel()

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        selectionStyle = .none

        kindLabel.translatesAutoresizingMaskIntoConstraints = false
        kindLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        kindLabel.textColor = .secondaryLabel
        contentView.addSubview(kindLabel)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.numberOfLines = 0
        contentView.addSubview(summaryLabel)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .tertiaryLabel
        contentView.addSubview(timeLabel)

        NSLayoutConstraint.activate([
            kindLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            kindLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),

            timeLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            timeLabel.centerYAnchor.constraint(equalTo: kindLabel.centerYAnchor),

            summaryLabel.leadingAnchor.constraint(equalTo: kindLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: kindLabel.bottomAnchor, constant: 4),
            summaryLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
    }

    func configure(with entry: SubAgentLogEntry) {
        kindLabel.text = kindString(for: entry.kind).uppercased()
        kindLabel.textColor = kindColor(for: entry.kind)
        summaryLabel.text = entry.summary
        timeLabel.text = Self.timeFormatter.string(from: entry.timestamp)
    }

    private func kindString(for kind: SubAgentLogEntry.Kind) -> String {
        switch kind {
        case .toolCall: return "Tool"
        case .toolResult: return "Result"
        case .thought: return "Thought"
        case .system: return "System"
        }
    }

    private func kindColor(for kind: SubAgentLogEntry.Kind) -> UIColor {
        switch kind {
        case .toolCall: return .systemBlue
        case .toolResult: return .systemGreen
        case .thought: return .systemPurple
        case .system: return .systemGray
        }
    }
}

#endif
