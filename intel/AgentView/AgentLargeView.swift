//
//  AgentLargeView.swift
//  Loop
//
//  Immersive "large-mode" view: a floating orb as primary visual focus with a
//  live readout strip underneath. Presented when the user taps the compact
//  nav-bar avatar. Renders three streams of data:
//
//    1. The orb itself — driven by VoiceLoopCoordinator.shared.state, so it
//       lights up cyan while listening, purple while thinking, green while
//       speaking. Matches the nav-bar avatar 1:1 so the expansion feels like a
//       continuation rather than a separate component.
//    2. A status caption directly under the orb — the current shimmer string
//       (Thinking…, "saving note to Notion", etc.).
//    3. A vertical ticker of the most recent activity log entries —
//       tool calls, sub-agent ticks, thoughts. Older entries fade out at the
//       top so the strip feels alive without growing unbounded.
//
//  The view is a plain UIView so the hosting controller stays free to drive
//  pan-to-dismiss / present animation without subclassing baggage.
//

#if os(iOS)

import UIKit

final class AgentLargeView: UIView {

    /// Hero orb. Sized to dominate the upper half of the screen — same
    /// component used on the empty-state hero and the nav bar, just larger.
    let avatar = AvatarView(gridW: 25, gridH: 25, pixelSize: 12, baseRadius: 7.5)

    /// One-line status caption directly under the orb. Mirrors the
    /// MessagingVC shimmer text so the user sees the same "Thinking…" copy
    /// whether they're in chat or in large mode.
    private let statusLabel = UILabel()

    /// Smaller pill above the orb — "tap to collapse". Keeps the affordance
    /// discoverable without competing with the orb visually.
    private let dismissHint = UILabel()

    /// Vertical ticker of recent activity. We rebuild this from
    /// `AgentActivityLog.shared.entries` on every refresh; cap at
    /// `maxTickerLines` so the layout stays calm.
    private let tickerStack = UIStackView()
    private let tickerContainer = UIView()
    private let tickerMask = CAGradientLayer()

    /// Live sub-agent chips along the bottom. One pill per alive agent with
    /// its title + current step. Hidden when there are no sub-agents.
    private let subAgentScroll = UIScrollView()
    private let subAgentStack = UIStackView()

    /// Backdrop that pulses subtly with the orb's current mode — a radial
    /// vignette in the orb's tint color, super low opacity so the orb still
    /// reads as the focal element. Sits behind everything.
    private let backdrop = CAGradientLayer()

    /// How many ticker rows we keep on screen. More than this and the visual
    /// hierarchy collapses — the orb stops dominating.
    private let maxTickerLines = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        subscribe()
        refresh(animated: false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        subscribe()
        refresh(animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .systemBackground

        // Ambient backdrop. The colors are dialed in per-mode on `refresh`.
        backdrop.type = .radial
        backdrop.startPoint = CGPoint(x: 0.5, y: 0.35)
        backdrop.endPoint = CGPoint(x: 1.2, y: 1.2)
        backdrop.colors = [
            UIColor.label.withAlphaComponent(0.05).cgColor,
            UIColor.clear.cgColor
        ]
        layer.insertSublayer(backdrop, at: 0)

        avatar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 17, weight: .medium)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.text = "Idle"
        addSubview(statusLabel)

        dismissHint.translatesAutoresizingMaskIntoConstraints = false
        dismissHint.font = .systemFont(ofSize: 12, weight: .semibold)
        dismissHint.textColor = .tertiaryLabel
        dismissHint.textAlignment = .center
        dismissHint.text = "TAP TO COLLAPSE"
        // Subtle letter spacing — feels intentional rather than tossed in.
        let attrs: [NSAttributedString.Key: Any] = [.kern: 1.6]
        dismissHint.attributedText = NSAttributedString(string: dismissHint.text ?? "", attributes: attrs)
        addSubview(dismissHint)

        tickerContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tickerContainer)

        tickerStack.translatesAutoresizingMaskIntoConstraints = false
        tickerStack.axis = .vertical
        tickerStack.alignment = .center
        tickerStack.distribution = .equalSpacing
        tickerStack.spacing = 6
        tickerContainer.addSubview(tickerStack)

        // Fade older lines into the background at the top of the ticker.
        // Built once and resized in layoutSubviews.
        tickerMask.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.4).cgColor,
            UIColor.black.cgColor,
            UIColor.black.cgColor
        ]
        tickerMask.locations = [0.0, 0.25, 0.65, 1.0]
        tickerMask.startPoint = CGPoint(x: 0.5, y: 0.0)
        tickerMask.endPoint = CGPoint(x: 0.5, y: 1.0)
        tickerContainer.layer.mask = tickerMask

        subAgentScroll.translatesAutoresizingMaskIntoConstraints = false
        subAgentScroll.showsHorizontalScrollIndicator = false
        subAgentScroll.contentInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        addSubview(subAgentScroll)

        subAgentStack.translatesAutoresizingMaskIntoConstraints = false
        subAgentStack.axis = .horizontal
        subAgentStack.alignment = .center
        subAgentStack.spacing = 8
        subAgentScroll.addSubview(subAgentStack)

        NSLayoutConstraint.activate([
            dismissHint.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 24),
            dismissHint.centerXAnchor.constraint(equalTo: centerXAnchor),

            avatar.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Orb sits in the upper third so the readout has room to breathe
            // without the orb feeling lonely at the top.
            avatar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 80),
            avatar.widthAnchor.constraint(equalToConstant: 300),
            avatar.heightAnchor.constraint(equalToConstant: 300),

            statusLabel.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),

            tickerContainer.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            tickerContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            tickerContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            tickerContainer.bottomAnchor.constraint(equalTo: subAgentScroll.topAnchor, constant: -16),

            tickerStack.bottomAnchor.constraint(equalTo: tickerContainer.bottomAnchor),
            tickerStack.leadingAnchor.constraint(equalTo: tickerContainer.leadingAnchor),
            tickerStack.trailingAnchor.constraint(equalTo: tickerContainer.trailingAnchor),
            tickerStack.topAnchor.constraint(greaterThanOrEqualTo: tickerContainer.topAnchor),

            subAgentScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            subAgentScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            subAgentScroll.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
            subAgentScroll.heightAnchor.constraint(equalToConstant: 34),

            subAgentStack.topAnchor.constraint(equalTo: subAgentScroll.topAnchor),
            subAgentStack.bottomAnchor.constraint(equalTo: subAgentScroll.bottomAnchor),
            subAgentStack.leadingAnchor.constraint(equalTo: subAgentScroll.leadingAnchor),
            subAgentStack.trailingAnchor.constraint(equalTo: subAgentScroll.trailingAnchor),
            subAgentStack.heightAnchor.constraint(equalTo: subAgentScroll.heightAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        tickerMask.frame = tickerContainer.bounds
    }

    // MARK: - Observation

    private func subscribe() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: .agentActivityDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: .subAgentsDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateDidChange),
            name: .voiceLoopStateDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(amplitudeDidChange),
            name: .voiceLoopAmplitudeDidChange, object: nil)
    }

    @objc private func activityDidChange() {
        DispatchQueue.main.async { [weak self] in self?.refresh(animated: true) }
    }

    @objc private func stateDidChange() {
        DispatchQueue.main.async { [weak self] in self?.applyVoiceState() }
    }

    @objc private func amplitudeDidChange() {
        avatar.amplitude = VoiceLoopCoordinator.shared.latestAmplitude
    }

    // MARK: - Refresh

    /// Pulls the latest state from the coordinator and the activity log and
    /// rebuilds the visible UI. Idempotent — cheap enough to call on every
    /// notification.
    func refresh(animated: Bool) {
        applyVoiceState()
        rebuildTicker(animated: animated)
        rebuildSubAgentChips()
    }

    /// Map VoiceLoopCoordinator's state onto avatar mode + caption + backdrop
    /// tint. Kept tiny so the orb's color is the single point of truth — the
    /// caption and backdrop just echo it.
    private func applyVoiceState() {
        let state = VoiceLoopCoordinator.shared.state
        let mode: AvatarView.Mode
        let caption: String
        let tint: UIColor
        switch state {
        case .idle:
            mode = .idle
            caption = AgentActivityLog.shared.entries.last?.summary ?? "Idle"
            tint = UIColor.label
        case .recording:
            mode = .listening
            caption = "Listening…"
            tint = .systemCyan
        case .transcribing:
            mode = .thinking
            caption = "Transcribing…"
            tint = .systemPurple
        case .thinking:
            mode = .thinking
            // Prefer the most recent status string from the activity log so
            // tool-running copy ("saving note to Notion") wins over a generic
            // "Thinking…".
            let recentStatus = AgentActivityLog.shared.entries.reversed().first { entry in
                entry.kind == .status || entry.kind == .toolCall
            }?.summary
            caption = recentStatus ?? "Thinking…"
            tint = .systemPurple
        case .speaking:
            mode = .speaking
            caption = "Speaking…"
            tint = .systemGreen
        }
        avatar.mode = mode
        statusLabel.text = caption
        backdrop.colors = [
            tint.withAlphaComponent(0.18).cgColor,
            UIColor.clear.cgColor
        ]
    }

    /// Pulls the last `maxTickerLines` entries off the activity log and
    /// renders them oldest-on-top. Older lines render dimmer + smaller — the
    /// fade-out mask then carries them off the top edge.
    private func rebuildTicker(animated: Bool) {
        let recent = Array(AgentActivityLog.shared.entries.suffix(maxTickerLines))
        // Reuse rows if the count matches; otherwise rebuild the stack so we
        // don't try to animate stale labels.
        if tickerStack.arrangedSubviews.count != recent.count {
            tickerStack.arrangedSubviews.forEach {
                tickerStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            for _ in 0..<recent.count {
                let row = makeTickerRow()
                tickerStack.addArrangedSubview(row)
            }
        }
        for (i, entry) in recent.enumerated() {
            guard let row = tickerStack.arrangedSubviews[i] as? UIStackView,
                  let dot = row.arrangedSubviews.first,
                  let label = row.arrangedSubviews.last as? UILabel else { continue }
            // Newer entries (higher index) feel more present.
            let freshness = Double(i + 1) / Double(max(1, recent.count))
            let alpha = CGFloat(0.35 + 0.65 * freshness)
            label.alpha = alpha
            dot.alpha = alpha
            label.text = entry.summary
            label.textColor = .secondaryLabel
            dot.backgroundColor = color(for: entry.kind)
        }
        if animated {
            UIView.animate(withDuration: 0.2) { self.tickerStack.layoutIfNeeded() }
        }
    }

    /// One ticker row — a small colored dot on the left, the summary on the
    /// right. Centered as a unit so the strip feels like a single column.
    private func makeTickerRow() -> UIStackView {
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = 2.5
        dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 5).isActive = true

        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.textAlignment = .left

        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func color(for kind: AgentActivityLog.Kind) -> UIColor {
        switch kind {
        case .status:     return .systemGray
        case .toolCall:   return .systemBlue
        case .toolResult: return .systemTeal
        case .thought:    return .systemPurple
        case .subAgent:   return .systemOrange
        }
    }

    /// Show one chip per alive sub-agent. The chip is intentionally minimal —
    /// title + current step. Tapping a chip opens the existing inspector if
    /// the host wires `onSubAgentTap`.
    private func rebuildSubAgentChips() {
        let live = SubAgentManager.shared.liveAgents
        subAgentScroll.isHidden = live.isEmpty
        subAgentStack.arrangedSubviews.forEach {
            subAgentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for agent in live {
            let chip = makeSubAgentChip(for: agent)
            subAgentStack.addArrangedSubview(chip)
        }
    }

    private func makeSubAgentChip(for agent: SubAgent) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor.tertiarySystemBackground
        container.layer.cornerRadius = 14
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.separator.cgColor

        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = 3
        dot.backgroundColor = agent.state == .active ? .systemGreen : .systemYellow

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .label
        let title = agent.displayTitle
        let step = agent.currentStep
        let trimmed = step.isEmpty ? title : "\(title.prefix(28)) · \(step)"
        label.text = String(trimmed.prefix(60))

        container.addSubview(dot)
        container.addSubview(label)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 28),
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}

#endif
