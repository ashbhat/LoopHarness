//
//  ScheduledTasksVC.swift
//  Loop
//
//  Built from LoopIOS/Specs/7_background_scheduler_spec.md.
//
//  Settings → Scheduled. Lists every BackgroundScheduler job with its
//  schedule, last run, and a "Run now" action. Swipe to delete.
//
//  iOS-only — the Mac surface lives in
//  LoopMac/ScheduledTasksWindowController.swift. The os(iOS) guard makes
//  this file safe to include in the Mac target's membership (it just
//  compiles to nothing there), matching the defensive pattern other UIKit
//  Settings files would benefit from.
//

#if os(iOS)

import UIKit

final class ScheduledTasksVC: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var jobs: [ScheduledJob] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Scheduled"
        view.backgroundColor = .systemGroupedBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        jobs = BackgroundScheduler.shared.loadJobs().sorted { $0.title < $1.title }
        tableView.reloadData()
    }

    // MARK: - Per-row actions

    private func presentActions(for job: ScheduledJob) {
        let sheet = UIAlertController(title: job.title,
                                      message: BackgroundScheduler.shared.scheduleDescription(for: job),
                                      preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "Run now", style: .default) { [weak self] _ in
            self?.runNow(job)
        })

        if job.lastRunAt != nil {
            sheet.addAction(UIAlertAction(title: "Open last result", style: .default) { [weak self] _ in
                self?.openLastResult(for: job)
            })
        }

        sheet.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.delete(job)
        })

        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func runNow(_ job: ScheduledJob) {
        let fire = BackgroundScheduler.shared.nextFireDate(for: job.trigger)
        // Clear any cached prefetch so the run actually executes.
        BackgroundScheduler.shared.clearResults(forJobId: job.id)

        let progress = UIAlertController(title: "Running '\(job.title)'…",
                                         message: "This may take a moment.",
                                         preferredStyle: .alert)
        present(progress, animated: true)

        BackgroundScheduler.shared.prefetch(job: job, fireDate: fire) { [weak self] result in
            DispatchQueue.main.async {
                progress.dismiss(animated: true) {
                    switch result {
                    case .success(let body, let conversationId):
                        let alert = UIAlertController(title: job.title,
                                                      message: body,
                                                      preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "Open conversation", style: .default) { _ in
                            if let conv = SimpleConversationManager.shared.getConversation(by: conversationId),
                               let nav = self?.navigationController,
                               let messagingVC = nav.viewControllers.first(where: { $0 is MessagingVC }) as? MessagingVC {
                                messagingVC.loadConversation(conv)
                                nav.popToRootViewController(animated: true)
                            }
                        })
                        alert.addAction(UIAlertAction(title: "Done", style: .cancel))
                        self?.present(alert, animated: true)
                    case .failure(let reason):
                        let alert = UIAlertController(title: "Couldn't run",
                                                      message: reason,
                                                      preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        self?.present(alert, animated: true)
                    }
                    self?.reload()
                }
            }
        }
    }

    private func openLastResult(for job: ScheduledJob) {
        let results = BackgroundScheduler.shared.loadResults().filter { $0.jobId == job.id }
        guard let latest = results.sorted(by: { $0.fireDate > $1.fireDate }).first,
              let conv = SimpleConversationManager.shared.getConversation(by: latest.conversationId) else { return }
        guard let nav = navigationController,
              let messagingVC = nav.viewControllers.first(where: { $0 is MessagingVC }) as? MessagingVC else { return }
        messagingVC.loadConversation(conv)
        nav.popToRootViewController(animated: true)
    }

    private func delete(_ job: ScheduledJob) {
        _ = BackgroundScheduler.shared.deleteJob(id: job.id)
        reload()
    }
}

extension ScheduledTasksVC: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(jobs.count, 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var config = cell.defaultContentConfiguration()
        if jobs.isEmpty {
            config.text = "No scheduled tasks yet."
            config.secondaryText = "Ask Loop to remind you about something at a specific time."
            config.textProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell
        }
        let job = jobs[indexPath.row]
        config.text = job.title
        var secondary = BackgroundScheduler.shared.scheduleDescription(for: job)
        if let last = job.lastResult, !last.isEmpty {
            secondary += " · " + last
        }
        config.secondaryText = secondary
        config.image = UIImage(systemName: "calendar.badge.clock")
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !jobs.isEmpty, indexPath.row < jobs.count else { return }
        presentActions(for: jobs[indexPath.row])
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !jobs.isEmpty, indexPath.row < jobs.count else { return nil }
        let job = jobs[indexPath.row]
        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.delete(job)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
}

#endif
