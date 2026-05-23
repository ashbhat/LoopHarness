//
//  SubAgentStatusBarView.swift
//  Loop
//
//  Slim "N sub-agents running" pill that sits at the top of MessagingVC.
//  Tappable — opens the runtime inspector. Hides when no agents are alive
//  or recently-finished. iOS only; the Mac uses its own subclass.
//

#if os(iOS)

import UIKit

protocol SubAgentStatusBarDelegate: AnyObject {
    func subAgentStatusBarTapped()
}

final class SubAgentStatusBarView: UIView {
    weak var delegate: SubAgentStatusBarDelegate?

    private let pill = UIView()
    private let dot = UIView()
    private let label = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    /// Driven by Core Animation — a soft pulse on the dot whenever there's
    /// at least one .active agent. The pulse stops when nothing is alive.
    private let pulseLayer = CALayer()

    /// Heightconstraint we toggle when there are 0 agents so the bar
    /// collapses cleanly without leaving an empty strip on top of the
    /// conversation table.
    private var heightConstraint: NSLayoutConstraint?

    /// Conversation the pill is scoped to. Sub-agents only render here if
    /// they were spawned from this conversation, so switching threads hides
    /// agents that belong to other threads. Setting this re-refreshes the
    /// pill so the count flips immediately on tab/conversation change.
    var conversationId: String? {
        didSet {
            guard oldValue != conversationId else { return }
            refresh(animated: false)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        observeManager()
        refresh(animated: false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        observeManager()
        refresh(animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupViews() {
        backgroundColor = .clear

        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint?.isActive = true

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        pill.layer.cornerRadius = 14
        pill.layer.borderWidth = 1
        pill.layer.borderColor = UIColor.separator.cgColor
        // Soft shadow so the pill floats above the table content slightly.
        pill.layer.shadowColor = UIColor.black.cgColor
        pill.layer.shadowOpacity = 0.08
        pill.layer.shadowOffset = CGSize(width: 0, height: 2)
        pill.layer.shadowRadius = 6
        addSubview(pill)

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = .systemGreen
        dot.layer.cornerRadius = 4
        pill.addSubview(dot)

        // Pulse layer rides under the dot to softly throb while agents run.
        pulseLayer.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.4).cgColor
        pulseLayer.cornerRadius = 4
        dot.layer.insertSublayer(pulseLayer, at: 0)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .label
        pill.addSubview(label)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .secondaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        pill.addSubview(chevron)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 28),

            dot.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            chevron.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            chevron.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        pill.addGestureRecognizer(tap)
        pill.isUserInteractionEnabled = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the pulse layer centered on the dot. Done in layoutSubviews
        // so the frame is set after autolayout resolves the dot's size.
        pulseLayer.frame = dot.bounds
    }

    private func observeManager() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(managerDidChange),
            name: .subAgentsDidChange,
            object: nil
        )
    }

    @objc private func managerDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refresh(animated: true)
        }
    }

    @objc private func tapped() {
        delegate?.subAgentStatusBarTapped()
    }

    /// Pull fresh state from the manager and update visibility + label.
    /// The pill stays visible while there are finished agents the user hasn't
    /// cleared yet, so a completion stays glance-able instead of vanishing
    /// the moment the agent transitions out of `isAlive`. Filtered to the
    /// current `conversationId` so only this thread's agents show here.
    func refresh(animated: Bool) {
        let summary = SubAgentManager.shared.pillSummary(for: conversationId)
        if summary.isEmpty {
            heightConstraint?.constant = 0
            pill.alpha = 0
            stopPulse()
            return
        }
        heightConstraint?.constant = 40
        label.text = summary
        // Dot coloring: green while anything is running (pulse on), gray
        // once only completed agents remain (pulse off — nothing to track).
        // Aggregate counts include Devin + Cursor jobs so a dispatched Devin
        // session lights the pill green even though it isn't a native
        // SubAgent. Native sub-agents are the only source of the "sleeping"
        // bucket (yellow) — Devin/Cursor have no sleep concept.
        let liveCount = SubAgentManager.shared.aggregateLiveCount(for: conversationId)
        if liveCount == 0 {
            dot.backgroundColor = .systemGray
            pulseLayer.backgroundColor = UIColor.systemGray.withAlphaComponent(0.4).cgColor
            stopPulse()
        } else {
            let active = SubAgentManager.shared.aggregateHasActive(for: conversationId)
            dot.backgroundColor = active ? .systemGreen : .systemYellow
            pulseLayer.backgroundColor = (active ? UIColor.systemGreen : UIColor.systemYellow)
                .withAlphaComponent(0.4).cgColor
            startPulse()
        }

        let work: () -> Void = {
            self.pill.alpha = 1
            self.superview?.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: work)
        } else {
            work()
        }
    }

    private func startPulse() {
        guard pulseLayer.animation(forKey: "pulse") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 2.2
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.6
        opacity.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 1.4
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulseLayer.add(group, forKey: "pulse")
    }

    private func stopPulse() {
        pulseLayer.removeAnimation(forKey: "pulse")
    }
}

#endif
