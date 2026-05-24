//
//  AgentLargeVC.swift
//  Loop
//
//  Modal host for `AgentLargeView`. Presents the immersive agent view with a
//  crossfade transition (so the orb visually "expands" out of the nav bar)
//  and supports tap-to-dismiss + pan-down-to-dismiss. The collapse animation
//  reverses the crossfade so the orb appears to shrink back into the nav bar.
//
//  The controller only handles presentation choreography — every live data
//  binding lives on AgentLargeView itself.
//

#if os(iOS)

import UIKit

final class AgentLargeVC: UIViewController {

    /// The immersive view this controller hosts. Exposed so callers can read
    /// orb state for things like preheat / transition snapshots later.
    let agentView = AgentLargeView()

    /// Pan gesture used for the rubber-band drag-down dismiss. Tracked here
    /// so the gesture can be cancelled / reset cleanly on dismiss.
    private var panGesture: UIPanGestureRecognizer!

    /// The vertical offset at which we commit to dismissing on release. Less
    /// than this and the view springs back to center.
    private let dismissThreshold: CGFloat = 120

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        agentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(agentView)
        NSLayoutConstraint.activate([
            agentView.topAnchor.constraint(equalTo: view.topAnchor),
            agentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            agentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            agentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Tap the orb (or the surrounding hero area) to collapse. We attach
        // to the agent view so taps on the sub-agent chips at the bottom
        // don't accidentally dismiss the sheet — a chip tap fights the
        // dismiss gesture and wins, which is the right outcome.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        agentView.avatar.isUserInteractionEnabled = true
        agentView.avatar.addGestureRecognizer(tap)

        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(panGesture)
    }

    // MARK: - Dismiss interactions

    @objc private func handleTap() {
        dismiss(animated: true)
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view)
        switch pan.state {
        case .changed:
            // Only respond to downward drags. Upward / sideways feel weird
            // because the view doesn't have anywhere to go.
            let dy = max(0, translation.y)
            // Rubber-band — feels increasingly resistant the farther you drag.
            let damped = dy < dismissThreshold ? dy : dismissThreshold + (dy - dismissThreshold) * 0.4
            view.transform = CGAffineTransform(translationX: 0, y: damped)
            // Fade out as the user drags so the dismiss feels imminent before
            // the threshold trips.
            let progress = min(1, dy / 300)
            view.alpha = 1 - 0.4 * progress
        case .ended, .cancelled:
            if translation.y > dismissThreshold {
                dismiss(animated: true)
            } else {
                UIView.animate(withDuration: 0.3,
                               delay: 0,
                               usingSpringWithDamping: 0.75,
                               initialSpringVelocity: 0.4,
                               options: [.allowUserInteraction]) {
                    self.view.transform = .identity
                    self.view.alpha = 1
                }
            }
        default:
            break
        }
    }
}

#endif
