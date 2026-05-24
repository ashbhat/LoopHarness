//
//  DevinAgentDetailVC.swift
//  Loop
//
//  Live transcript view for a single dispatched Devin session. Polls
//  DevinAgentService at the spec's 5s cadence while on-screen (the service's
//  "boost" mechanism), renders messages in a chat-style list with tappable
//  URLs, and surfaces a "Live session" + "See PR" pair as a fixed bottom
//  toolbar (separate from the status header so a long title doesn't crowd the
//  action buttons).
//
//  Pushed from two places:
//   - The conversation, when the user taps a Devin agent affordance.
//   - Settings ▸ Subagents ▸ <row>, per user story step (P).
//

#if os(iOS)

import UIKit

final class DevinAgentDetailVC: UIViewController {

    private let sessionId: String
    private var job: DevinAgentJob?

    private let tableView = UITableView(frame: .zero, style: .plain)

    // MARK: Header (status only — buttons live in the bottom toolbar)
    private let headerView = UIView()
    private let statusLabel = UILabel()
    private let subtitleLabel = UILabel()

    // MARK: Bottom action toolbar
    private let footerView = UIView()
    private let footerStack = UIStackView()
    private let liveSessionButton = UIButton(type: .system)
    private let prButton = UIButton(type: .system)
    /// Hosts [header, table, footer] vertically. We use an outer stack rather
    /// than raw constraints so `footerView.isHidden = true` cleanly collapses
    /// the footer's real estate — the chat then occupies the full height
    /// until Devin surfaces a destination URL. Avoids fighting Auto Layout
    /// when toggling a height constraint with inner content.
    private let rootStack = UIStackView()

    init(sessionId: String) {
        self.sessionId = sessionId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Devin"

        setupHeader()
        setupTable()
        setupFooter()
        layoutSubviews()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(devinDidChange(_:)),
            name: .devinAgentsDidChange,
            object: nil
        )

        // Hydrate from persisted state immediately so the view never blanks
        // out on appear — even if the network is slow, the user sees the
        // transcript captured by previous polls.
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Bumps the shared poll timer to the spec's 5s cadence for this
        // session for as long as the screen is visible. Releases on disappear.
        DevinAgentService.shared.addBoost(sessionId: sessionId)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DevinAgentService.shared.removeBoost(sessionId: sessionId)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Header layout

    private func setupHeader() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = .secondarySystemBackground
        headerView.layer.cornerRadius = 12

        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        headerView.addSubview(statusLabel)
        headerView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 10),

            subtitleLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - Table

    private func setupTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 60
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(DevinMessageCell.self, forCellReuseIdentifier: DevinMessageCell.reuseId)
        tableView.allowsSelection = false
        // Give the bottom row breathing room so the last message isn't tucked
        // up against the footer toolbar — easier to read and to scroll past.
        tableView.contentInset.bottom = 8
    }

    // MARK: - Footer (bottom action toolbar)

    /// Two side-by-side buttons sitting above the safe area. The whole bar
    /// collapses to 0 height when neither button has a destination, so the
    /// chat owns the full screen until Devin has surfaced at least one URL.
    private func setupFooter() {
        footerView.translatesAutoresizingMaskIntoConstraints = false
        footerView.backgroundColor = .systemBackground
        // Hairline divider at the top — same visual weight as a UIToolbar so
        // the footer reads as a chrome surface, not a free-floating panel.
        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = .separator
        footerView.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: footerView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: footerView.topAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1.0 / max(UIScreen.main.scale, 1)),
        ])

        configureLiveSessionButton(liveSessionButton)
        configurePRButton(prButton)
        liveSessionButton.addTarget(self, action: #selector(openLiveSession), for: .touchUpInside)
        prButton.addTarget(self, action: #selector(openPR), for: .touchUpInside)

        footerStack.axis = .horizontal
        footerStack.spacing = 10
        footerStack.distribution = .fillEqually
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.addArrangedSubview(liveSessionButton)
        footerStack.addArrangedSubview(prButton)
        footerView.addSubview(footerStack)

        NSLayoutConstraint.activate([
            footerStack.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 16),
            footerStack.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -16),
            footerStack.topAnchor.constraint(equalTo: footerView.topAnchor, constant: 10),
            footerStack.bottomAnchor.constraint(equalTo: footerView.safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])

        // Start collapsed. The outer rootStack auto-removes hidden arranged
        // subviews from the layout, so the chat will own the full height
        // until reload() reveals a usable button.
        footerView.isHidden = true
    }

    /// "Live session" — secondary (tinted) style. Visible whenever Devin's
    /// dashboard URL is available, even while the session is still running.
    private func configureLiveSessionButton(_ button: UIButton) {
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.tinted()
            config.title = "Live session"
            config.image = UIImage(systemName: "arrow.up.right.square")
            config.imagePadding = 6
            config.cornerStyle = .medium
            config.baseBackgroundColor = .secondarySystemBackground
            button.configuration = config
        } else {
            button.setTitle("Live session", for: .normal)
            button.setImage(UIImage(systemName: "arrow.up.right.square"), for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.backgroundColor = .secondarySystemBackground
            button.layer.cornerRadius = 10
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        }
    }

    /// "See PR" — primary (filled) style so the most-important destination
    /// reads as the obvious call to action. The actual title/icon/colour are
    /// set in `applyPRButtonStyle(for:)`, which `reload()` calls every cycle
    /// so a merge flips the label without needing a re-create.
    private func configurePRButton(_ button: UIButton) {
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.filled()
            config.imagePadding = 6
            config.cornerStyle = .medium
            button.configuration = config
        } else {
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.layer.cornerRadius = 10
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        }
    }

    /// Update the PR button's label + icon + tint to match the current
    /// `pr_state`. `merged` → purple "Merged PR" with the merge glyph (same
    /// visual language GitHub uses); `closed` → grey "PR closed";
    /// open/draft/unknown → blue "See PR". Re-runs on every reload so the
    /// button flips live when the merge happens while the screen is open.
    private func applyPRButtonStyle(for state: String?) {
        let normalized = (state ?? "").lowercased()
        let title: String
        let symbol: String
        let tint: UIColor
        switch normalized {
        case "merged":
            title = "Merged PR"
            symbol = "arrow.triangle.merge"
            tint = .systemPurple
        case "closed":
            title = "PR closed"
            symbol = "xmark.circle.fill"
            tint = .systemGray
        default:
            title = "See PR"
            symbol = "checkmark.seal"
            tint = .systemBlue
        }
        if #available(iOS 15.0, *) {
            var config = prButton.configuration ?? UIButton.Configuration.filled()
            config.title = title
            config.image = UIImage(systemName: symbol)
            config.baseBackgroundColor = tint
            prButton.configuration = config
        } else {
            prButton.setTitle(title, for: .normal)
            prButton.setImage(UIImage(systemName: symbol), for: .normal)
            prButton.backgroundColor = tint
            prButton.tintColor = .white
            prButton.setTitleColor(.white, for: .normal)
        }
    }

    private func layoutSubviews() {
        // The header keeps its own card-style insets, so it gets its own
        // wrapper inside the stack to add horizontal margin. The table and
        // footer span edge-to-edge.
        let headerWrap = UIView()
        headerWrap.translatesAutoresizingMaskIntoConstraints = false
        headerWrap.addSubview(headerView)
        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: headerWrap.layoutMarginsGuide.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: headerWrap.layoutMarginsGuide.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: headerWrap.topAnchor, constant: 8),
            headerView.bottomAnchor.constraint(equalTo: headerWrap.bottomAnchor, constant: -8),
        ])

        rootStack.axis = .vertical
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(headerWrap)
        rootStack.addArrangedSubview(tableView)
        rootStack.addArrangedSubview(footerView)

        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Reload

    @objc private func devinDidChange(_ note: Notification) {
        // Only refresh when our session is the one that changed; other rows
        // updating in the background shouldn't reflow this list.
        if let id = note.userInfo?["sessionId"] as? String, id != sessionId { return }
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    private func reload() {
        let fresh = DevinAgentService.shared.job(forSessionId: sessionId)
        let priorMessageCount = job?.messages.count ?? 0
        job = fresh
        guard let job = fresh else { return }

        // Header text — status takes the full width now that buttons moved
        // out; subtitle is the repo (when known) falling back to the task.
        statusLabel.text = Self.statusLine(for: job)
        subtitleLabel.text = job.repository ?? job.displayTitle

        // Footer visibility — show each button only when it has a destination,
        // and collapse the whole bar when neither does. The outer rootStack
        // removes hidden arranged subviews from layout, so this restores the
        // table to full height while Devin is still spinning up.
        let hasPR = !(job.prURL ?? "").isEmpty
        let hasLive = !(job.dashboardURL ?? "").isEmpty
        prButton.isHidden = !hasPR
        liveSessionButton.isHidden = !hasLive
        footerView.isHidden = !hasPR && !hasLive

        // Re-style the PR button based on the latest pr_state so the user can
        // tell at a glance whether the PR's still in review or has already
        // landed. Re-applies whenever reload() runs — cheap, and the only
        // reliable hook since the button is configured once at setup.
        applyPRButtonStyle(for: job.prState)

        tableView.reloadData()

        // Auto-scroll to the bottom if new messages came in, so the live
        // transcript feels active without the user having to scroll manually.
        let newCount = job.messages.count
        if newCount > priorMessageCount, newCount > 0 {
            let indexPath = IndexPath(row: newCount - 1, section: 0)
            DispatchQueue.main.async { [weak self] in
                self?.tableView.scrollToRow(at: indexPath, at: .bottom, animated: priorMessageCount > 0)
            }
        }
    }

    // MARK: - Actions

    @objc private func openPR() {
        guard let urlString = job?.prURL, let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    @objc private func openLiveSession() {
        guard let urlString = job?.dashboardURL, let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Helpers

    private static func statusLine(for job: DevinAgentJob) -> String {
        // Once a PR has merged, that's the more useful headline than the
        // session's lifecycle state — the user cares "did it land?" more than
        // "did Devin's session exit cleanly?". Same goes for a PR that got
        // closed without merging.
        switch job.prState?.lowercased() {
        case "merged": return "🎉 Merged · \(job.displayTitle)"
        case "closed": return "🚫 PR closed · \(job.displayTitle)"
        default: break
        }
        switch job.status {
        case "running":   return "● Working · \(job.displayTitle)"
        case "blocked":   return "🟡 Blocked · \(job.displayTitle)"
        case "finished":  return "✅ Finished · \(job.displayTitle)"
        case "expired":   return "⌛ Expired · \(job.displayTitle)"
        case "cancelled": return "🚫 Cancelled · \(job.displayTitle)"
        case "stale":     return "⌛️ Stopped tracking · \(job.displayTitle)"
        case "error":     return "❌ Error · \(job.displayTitle)"
        default:          return job.displayTitle
        }
    }
}

extension DevinAgentDetailVC: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let count = job?.messages.count ?? 0
        return max(count, 1) // empty-state row
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let messages = job?.messages ?? []
        if messages.isEmpty {
            // Empty-state row — explicit so the view doesn't look frozen
            // before the first poll has landed.
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var config = cell.defaultContentConfiguration()
            config.text = job?.status == "running"
                ? "Waiting for Devin's first message…"
                : "No messages."
            config.textProperties.color = .secondaryLabel
            config.textProperties.alignment = .center
            cell.contentConfiguration = config
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: DevinMessageCell.reuseId, for: indexPath) as! DevinMessageCell
        cell.configure(with: messages[indexPath.row])
        return cell
    }
}

// MARK: - Message cell

/// Bubble cell with tappable URLs. We render the message body in a UITextView
/// (read-only, link-detecting) instead of a UILabel — UITextView's built-in
/// `dataDetectorTypes = .link` turns http(s) URLs into underlined, tappable
/// regions and routes the open to UIApplication for us, with no manual regex
/// or attributed-string work. The view is still selection-disabled so the
/// row doesn't feel like a text-edit surface.
private final class DevinMessageCell: UITableViewCell {
    static let reuseId = "DevinMessageCell"

    private let bubble = UIView()
    private let messageView = UITextView()
    private let metaLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 12
        contentView.addSubview(bubble)

        // UITextView config tuned to behave like a label: read-only, no
        // editing UI, no insets, transparent background. `isSelectable = true`
        // is required for `dataDetectorTypes` to do anything — without it,
        // taps on the URL produce no effect.
        messageView.translatesAutoresizingMaskIntoConstraints = false
        messageView.isEditable = false
        messageView.isSelectable = true
        messageView.isScrollEnabled = false
        messageView.backgroundColor = .clear
        messageView.textContainerInset = .zero
        messageView.textContainer.lineFragmentPadding = 0
        messageView.dataDetectorTypes = .link
        messageView.font = .systemFont(ofSize: 14)
        messageView.adjustsFontForContentSizeCategory = true
        // Give the text view its own enabled-link colour so it stands out
        // against the bubble background without us having to attribute the
        // string by hand. .link does the right thing in both light/dark mode.
        messageView.linkTextAttributes = [
            .foregroundColor: UIColor.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        bubble.addSubview(messageView)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .systemFont(ofSize: 11, weight: .medium)
        metaLabel.textColor = .secondaryLabel
        bubble.addSubview(metaLabel)

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubble.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            bubble.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),

            metaLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            metaLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            metaLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),

            messageView.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 2),
            messageView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            messageView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            messageView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with msg: DevinTranscriptMessage) {
        messageView.text = msg.message

        // Distinct shading for Devin vs. user messages so the transcript reads
        // like a chat. v3's `source` field is "devin" | "user" (we stored it
        // in `type` to keep the local struct shape stable across API versions),
        // so the heuristic is a simple substring check.
        let typeLower = msg.type.lowercased()
        if typeLower.contains("user") || typeLower.contains("human") {
            bubble.backgroundColor = .systemBlue.withAlphaComponent(0.12)
            metaLabel.text = (msg.username ?? "You").uppercased()
        } else if typeLower.contains("system") {
            bubble.backgroundColor = .systemGray.withAlphaComponent(0.12)
            metaLabel.text = "SYSTEM"
        } else {
            bubble.backgroundColor = .secondarySystemBackground
            metaLabel.text = (msg.username ?? "Devin").uppercased()
        }
    }
}

#endif
