//
//  AvatarPopAnimator.swift
//  Loop
//
//  Shared "pop" animation used to move the Loop avatar between layouts:
//  hero (empty-state, ~252pt) ↔ nav-bar (44pt) ↔ fullscreen (AgentLargeView,
//  ~300pt). The animation snapshots the source view, parks the snapshot in
//  the key window, then spring-morphs scale + position into the destination
//  slot. The real source/destination views are hidden during the flight and
//  swapped back at completion.
//
//  Why a snapshot (not animating the source view directly): the nav-bar
//  avatar lives inside the navigation bar's titleView, which clips off-bar
//  translations. Animating in the window lifts the flying avatar above any
//  clipping or modal layers, so the present/dismiss transition to/from
//  AgentLargeVC can animate across view-controller boundaries with the
//  same primitive.
//

#if os(iOS)

import UIKit

enum AvatarPopAnimator {

    /// Plays the pop animation in `window`, flying a snapshot of `source` to
    /// the on-screen position of `dest`. Hides both views during the flight
    /// and calls `completion` once the snapshot is torn down. Falls back to
    /// a plain crossfade when the user has Reduce Motion enabled.
    ///
    /// - Important: `source` and `dest` must be in a window (i.e. their
    ///   `convert(_:to:)` resolves to real coordinates). Callers should run
    ///   `layoutIfNeeded()` on the relevant ancestors before invoking so the
    ///   destination's frame is final.
    static func play(from source: UIView,
                     to dest: UIView,
                     in window: UIWindow,
                     duration: TimeInterval = 0.6,
                     completion: @escaping () -> Void) {
        // Reduce Motion: skip the 3D path. The two visibility flips happen
        // in the completion handler; we just delay them by a beat so the
        // caller still gets the crossfade illusion they had before.
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, animations: {
                source.alpha = 0
            }, completion: { _ in
                source.alpha = 1
                completion()
            })
            return
        }

        let sourceFrame = source.convert(source.bounds, to: window)
        let destFrame = dest.convert(dest.bounds, to: window)

        // Snapshot the LARGER view so the flight always renders at native
        // resolution. The previous "always snapshot the source" rule
        // stretched the small (44pt) nav-bar avatar up to hero/AgentLarge
        // size, which looked pixelated — and only sharpened at the very
        // end when the real high-res destination view took over. By
        // snapshotting whichever side is bigger, the transform path
        // always scales DOWN (or to identity), which iOS anti-aliases
        // cleanly. Both AvatarView sizes are still drawn at their native
        // grid resolutions; we just animate using the higher-detail one.
        let snapshotsTheSource = sourceFrame.width >= destFrame.width
        let viewToSnap = snapshotsTheSource ? source : dest
        guard let snap = viewToSnap.snapshotView(afterScreenUpdates: true) else {
            completion()
            return
        }

        // Frame the snapshot sits at when its transform is identity. The
        // start/end transforms below are derived relative to this so the
        // visual center traces a line from source to dest regardless of
        // which side we snapshotted.
        let snapNativeFrame = snapshotsTheSource ? sourceFrame : destFrame
        snap.frame = snapNativeFrame
        window.addSubview(snap)

        // Hide both real views during the flight so we render the snapshot
        // alone — no double-image at either endpoint. The completion swaps
        // visibility back to whatever the caller wants. Done AFTER the
        // snapshot so the snapshot can capture the live render.
        source.isHidden = true
        dest.isHidden = true

        // Build the transform that maps `snapNativeFrame` onto an arbitrary
        // window-space target. Scale around the layer's anchor (0.5, 0.5),
        // then translate so the visual center lands on the target's center.
        func transform(toward targetFrame: CGRect) -> CGAffineTransform {
            let s = targetFrame.width / max(snapNativeFrame.width, 1)
            let dx = targetFrame.midX - snapNativeFrame.midX
            let dy = targetFrame.midY - snapNativeFrame.midY
            return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s)
        }

        snap.transform = transform(toward: sourceFrame)

        // Spring scale + translate. The spring's small overshoot gives the
        // "pop" feel without a rotation.
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: 0.78,
            initialSpringVelocity: 0.6,
            options: [.curveEaseOut],
            animations: {
                snap.transform = transform(toward: destFrame)
            },
            completion: { _ in
                snap.removeFromSuperview()
                completion()
            }
        )
    }
}

// MARK: - View controller transitioning

/// `UIViewControllerTransitioningDelegate` that drives the avatar pop when
/// MainVC presents `AgentLargeVC`. Retain it on the presenter — UIKit holds
/// the delegate weakly during the transition, but iOS won't let go of the
/// strong-reference duty.
final class AvatarPopTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {

    /// The small avatar in MainVC's nav bar. Used as both the source on
    /// present and the destination on dismiss. Weak because MainVC owns it.
    weak var sourceAvatar: UIView?

    /// Closure used by the presenter to find the destination avatar inside
    /// the AgentLargeVC. Provided as a closure (rather than a stored
    /// reference) because AgentLargeVC builds its view lazily — the avatar
    /// only exists once `viewDidLoad` has run, which we trigger by
    /// touching `presented.view` inside the animator.
    var resolveDestinationAvatar: (UIViewController) -> UIView?

    init(sourceAvatar: UIView?,
         resolveDestinationAvatar: @escaping (UIViewController) -> UIView?) {
        self.sourceAvatar = sourceAvatar
        self.resolveDestinationAvatar = resolveDestinationAvatar
    }

    func animationController(forPresented presented: UIViewController,
                             presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return AvatarPopPresentAnimator(sourceAvatar: sourceAvatar,
                                        resolveDestinationAvatar: resolveDestinationAvatar)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return AvatarPopDismissAnimator(destinationAvatar: sourceAvatar,
                                        resolveSourceAvatar: resolveDestinationAvatar)
    }
}

/// Present-side animator. Brings the AgentLargeVC's view on screen and
/// concurrently flies a snapshot of the nav-bar avatar up to the
/// AgentLargeView's hero avatar position with the 3D pop.
final class AvatarPopPresentAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private weak var sourceAvatar: UIView?
    private let resolveDestinationAvatar: (UIViewController) -> UIView?

    init(sourceAvatar: UIView?,
         resolveDestinationAvatar: @escaping (UIViewController) -> UIView?) {
        self.sourceAvatar = sourceAvatar
        self.resolveDestinationAvatar = resolveDestinationAvatar
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.65
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        guard let toVC = transitionContext.viewController(forKey: .to),
              let toView = transitionContext.view(forKey: .to)
        else {
            transitionContext.completeTransition(false)
            return
        }

        // Add the destination view at full opacity so the snapshot inside
        // `play()` can capture the dest avatar at its native render — a
        // partially-transparent toView would bake the alpha into the
        // snapshot and the orb's silhouette would arrive faded. The hard
        // background swap reads fine because MainVC and AgentLargeVC both
        // sit on `systemBackground`; the pop is the visual continuity.
        toView.frame = container.bounds
        toView.alpha = 1
        container.addSubview(toView)
        toView.layoutIfNeeded()

        guard let source = sourceAvatar,
              let dest = resolveDestinationAvatar(toVC),
              let window = container.window ?? source.window
        else {
            // Couldn't wire the pop — fall back to a plain fade so the
            // transition isn't dropped entirely.
            toView.alpha = 0
            UIView.animate(withDuration: 0.25, animations: {
                toView.alpha = 1
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
            return
        }

        // Don't pre-hide `dest` — `play()` snapshots whichever side is
        // larger, and for present that's the destination (300pt avatar).
        // Hiding it before the snapshot would produce an empty texture.
        // `play()` handles the hide/unhide of both views internally.

        AvatarPopAnimator.play(from: source,
                                to: dest,
                                in: window,
                                duration: 0.65) {
            // Restore source visibility — MainVC's avatar comes back when
            // the modal eventually dismisses; while the modal is up it's
            // covered by toView anyway, but `isHidden = true` would
            // persist across dismiss without a reset.
            source.isHidden = false
            dest.isHidden = false
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        }
    }
}

/// Dismiss-side animator. Mirrors the present, flying back from the
/// AgentLargeView's hero avatar to the nav-bar avatar in MainVC.
final class AvatarPopDismissAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private weak var destinationAvatar: UIView?
    private let resolveSourceAvatar: (UIViewController) -> UIView?

    init(destinationAvatar: UIView?,
         resolveSourceAvatar: @escaping (UIViewController) -> UIView?) {
        self.destinationAvatar = destinationAvatar
        self.resolveSourceAvatar = resolveSourceAvatar
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.55
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        guard let fromVC = transitionContext.viewController(forKey: .from),
              let fromView = transitionContext.view(forKey: .from)
        else {
            transitionContext.completeTransition(false)
            return
        }

        // Re-attach the presenter (MainVC) view so its nav-bar avatar is in
        // a window-rooted hierarchy when we query `convert(_:to:)` for the
        // destination frame. `.fullScreen` modal dismissal otherwise leaves
        // the presenter's view detached at the start of the transition.
        if let toView = transitionContext.view(forKey: .to) {
            toView.frame = container.bounds
            container.insertSubview(toView, belowSubview: fromView)
            toView.layoutIfNeeded()
        }

        guard let source = resolveSourceAvatar(fromVC),
              let dest = destinationAvatar,
              let window = container.window ?? dest.window
        else {
            UIView.animate(withDuration: 0.2, animations: {
                fromView.alpha = 0
            }, completion: { _ in
                fromView.removeFromSuperview()
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
            return
        }

        // Don't pre-hide `dest` — `play()` snapshots whichever side is
        // larger (the source / AgentLargeVC avatar in the dismiss case),
        // and handles the hide/unhide internally.

        // Fade the rest of fromView (the AgentLargeVC's background +
        // chrome) out concurrently with the pop, so the orb is the last
        // thing to leave. The orb snapshot lives in the window above
        // fromView, so this fade doesn't dim it.
        UIView.animate(withDuration: 0.3, delay: 0.1, options: [.curveEaseIn], animations: {
            fromView.alpha = 0
        })

        AvatarPopAnimator.play(from: source,
                                to: dest,
                                in: window,
                                duration: 0.55) {
            dest.isHidden = false
            fromView.removeFromSuperview()
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        }
    }
}

#endif
