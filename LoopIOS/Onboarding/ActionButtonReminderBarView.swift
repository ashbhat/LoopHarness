//
//  ActionButtonReminderBarView.swift
//  Loop (iOS)
//
//  Slim non-blocking pill below the nav bar, shown after the user skipped
//  the Action Button step during onboarding. Reminds them to bind the
//  Action Button to Loop. Tap → present the walkthrough modal again.
//  x → snooze for 7 days (Apple-Pay-style cadence). Permanently hides once
//  the user actually presses the button (handleMicURL flips
//  `OnboardingState.actionButtonBound = true`).
//
//  Collapses to zero height when not needed so it costs no vertical space
//  the rest of the time — same pattern `SubAgentStatusBarView` uses.
//

import UIKit

protocol ActionButtonReminderBarDelegate: AnyObject {
    /// User tapped the body of the pill — present the walkthrough modal.
    func actionButtonReminderBarTapped()
    /// User tapped the x — snooze the banner.
    func actionButtonReminderBarDismissed()
}

final class ActionButtonReminderBarView: UIView {

    weak var delegate: ActionButtonReminderBarDelegate?

    private let pill = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private let dismissButton = UIButton(type: .system)

    /// Drives the view's collapse-to-zero behavior. Read from
    /// `OnboardingState.shouldShowActionButtonReminder` on every refresh.
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        buildSubviews()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reads `OnboardingState` and shows/hides the pill. Cheap to call —
    /// MessagingVC re-invokes from `viewWillAppear` and on relevant state
    /// changes (e.g., after `handleActionButtonPressed`).
    func refresh() {
        let shouldShow = OnboardingState.shouldShowActionButtonReminder
        pill.isHidden = !shouldShow
        heightConstraint.constant = shouldShow ? 44 : 0
        setNeedsLayout()
    }

    private func buildSubviews() {
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.14)
        pill.layer.cornerRadius = 16
        pill.layer.cornerCurve = .continuous
        addSubview(pill)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        pill.addGestureRecognizer(tap)
        pill.isUserInteractionEnabled = true

        icon.image = UIImage(systemName: "exclamationmark.circle.fill")
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.text = "Bind Action Button to Loop"
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false

        var dismissConfig = UIButton.Configuration.plain()
        dismissConfig.image = UIImage(systemName: "xmark.circle.fill")
        dismissConfig.baseForegroundColor = .tertiaryLabel
        dismissConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 10)
        dismissButton.configuration = dismissConfig
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.addTarget(self, action: #selector(handleDismiss), for: .touchUpInside)

        pill.addSubview(icon)
        pill.addSubview(label)
        pill.addSubview(dismissButton)

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.priority = .required

        NSLayoutConstraint.activate([
            heightConstraint,

            pill.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            icon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            dismissButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            dismissButton.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            dismissButton.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
    }

    @objc private func handleTap() {
        delegate?.actionButtonReminderBarTapped()
    }

    @objc private func handleDismiss() {
        OnboardingState.actionButtonReminderDismissedAt = Date()
        refresh()
        delegate?.actionButtonReminderBarDismissed()
    }
}
