//
//  ImageViewerVC.swift
//  Loop
//
//  Built from intel/Specs/image_spec.md (full-screen image viewer for inline
//  generated images).
//
//  Standard UIScrollView pinch-to-zoom pattern: scroll view fills the view,
//  imageView lives inside. viewForZooming returns the imageView; min/max
//  scale is computed in viewDidLayoutSubviews so the image starts fitted.
//  Double-tap toggles between fitted and 2× for quick inspection.
//

import UIKit

final class ImageViewerVC: UIViewController {

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let image: UIImage
    private let onSave: () -> Void

    /// Strong-held so it survives presentation — `transitioningDelegate` on
    /// the wrapping nav controller is a weak reference. Set by the presenter.
    var zoomTransition: ImageZoomTransitionDelegate?

    /// Current black-canvas opacity. Normally 1; the swipe-down gesture drives
    /// it below 1 so the chat shows through, and the dismiss animator picks up
    /// whatever value we're at so the fade is continuous.
    private(set) var currentDimAlpha: CGFloat = 1

    /// The image as currently shown — same instance we were handed, exposed so
    /// the dismiss animator can snapshot it without re-decoding.
    var displayedImage: UIImage { image }

    private var dismissPan: UIPanGestureRecognizer!

    init(image: UIImage, onSave: @escaping () -> Void) {
        self.image = image
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Match the chrome to the dark canvas so the image stays the focal
        // point. Translucent so the image can scroll under it as the user
        // pans.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(handleClose)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.down.to.line"),
            style: .plain,
            target: self,
            action: #selector(handleSave)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Save to Photos"

        // Scroll view + image view setup. We don't pin the imageView's edges
        // to the scroll view's content layout guide directly — instead we set
        // contentSize = image.size in viewDidLayoutSubviews, which is the
        // simplest path that handles centering at any zoom level cleanly.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .black
        view.addSubview(scrollView)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.addSubview(imageView)
        scrollView.contentSize = image.size

        let doubleTap = UITapGestureRecognizer(target: self,
                                               action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        // Swipe-down-to-dismiss. Lives on the root view and only engages when
        // the image isn't zoomed in (so it never fights the scroll view's own
        // pan). It moves the canvas with the finger and hands off to the same
        // zoom animator on release.
        dismissPan = UIPanGestureRecognizer(target: self,
                                            action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = self
        view.addGestureRecognizer(dismissPan)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Compute "fitted" scale lazily once the scroll view has its bounds.
        // We set minimumZoomScale = 1 for the natural-pixel scale, but `1`
        // here means "image at native size" — which is way bigger than the
        // bounds for a 1024×1024 PNG. So we override min to the fit scale.
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        let fitScale = min(bounds.width / image.size.width,
                           bounds.height / image.size.height)
        // Skip if we've already laid out at this fit scale (avoid resetting
        // the user's zoom on rotation re-entry).
        if abs(scrollView.minimumZoomScale - fitScale) > .ulpOfOne {
            scrollView.minimumZoomScale = fitScale
            scrollView.maximumZoomScale = max(fitScale * 4, 1)
            scrollView.zoomScale = fitScale
        }
        centerImageView()
    }

    // MARK: - Actions

    @objc private func handleClose() {
        dismiss(animated: true)
    }

    @objc private func handleSave() {
        onSave()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        // Toggle between fit and 2× fit. If the user is already zoomed in past
        // 2× fit, tap zooms back out to fit.
        let fit = scrollView.minimumZoomScale
        if scrollView.zoomScale > fit + .ulpOfOne {
            scrollView.setZoomScale(fit, animated: true)
        } else {
            let target = min(fit * 2, scrollView.maximumZoomScale)
            // Zoom into the tapped point so it stays under the user's finger.
            let tap = gesture.location(in: imageView)
            let size = scrollView.bounds.size
            let rect = CGRect(
                x: tap.x - (size.width / target) / 2,
                y: tap.y - (size.height / target) / 2,
                width: size.width / target,
                height: size.height / target
            )
            scrollView.zoom(to: rect, animated: true)
        }
    }

    // MARK: - Swipe-down dismiss

    @objc private func handleDismissPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        let v = g.velocity(in: view)
        // Progress is driven by downward drag, capped at half the screen.
        let progress = max(0, min(1, t.y / (view.bounds.height * 0.5)))

        switch g.state {
        case .changed:
            // Track the finger, easing in a slight shrink, and let the chat
            // bleed through as the canvas dims.
            let scale = 1 - progress * 0.15
            scrollView.transform = CGAffineTransform(translationX: t.x * scale,
                                                     y: max(0, t.y) * scale)
                .scaledBy(x: scale, y: scale)
            currentDimAlpha = 1 - progress * 0.7
            view.backgroundColor = UIColor.black.withAlphaComponent(currentDimAlpha)

        case .ended, .cancelled:
            let shouldDismiss = g.state == .ended && (progress > 0.3 || v.y > 900)
            if shouldDismiss {
                // Hand off to the zoom-out animator from wherever we are now.
                dismiss(animated: true)
            } else {
                UIView.animate(withDuration: 0.25,
                               delay: 0,
                               usingSpringWithDamping: 0.85,
                               initialSpringVelocity: 0,
                               options: [.curveEaseOut]) {
                    self.scrollView.transform = .identity
                    self.currentDimAlpha = 1
                    self.view.backgroundColor = .black
                }
            }

        default:
            break
        }
    }

    // MARK: - Zoom-transition geometry

    /// The image's current on-screen rect in `container`'s coordinate space —
    /// reflects the live zoom scale and any in-flight swipe transform, so the
    /// dismiss animator can pick up exactly where the user left off.
    func currentImageFrame(in container: UIView) -> CGRect {
        return imageView.convert(imageView.bounds, to: container)
    }

    /// Aspect-fit rect for the image inside `bounds` — the resting frame the
    /// present animator zooms *to* (matches this VC's own fitted layout).
    static func fittedRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width,
                        bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale,
                          height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2,
                      y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Hide the live content so only the animator's snapshot is visible while
    /// it zooms back into the bubble.
    func prepareForZoomDismiss() {
        scrollView.isHidden = true
    }

    /// Reveal the live content (used if a present transition is cancelled).
    func restoreAfterZoom() {
        scrollView.isHidden = false
    }

    // MARK: - Centering

    /// Center the image when it's smaller than the scroll view's bounds.
    /// Without this, a fitted image sits in the top-left.
    private func centerImageView() {
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        let xInset = max((bounds.width - content.width) / 2, 0)
        let yInset = max((bounds.height - content.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: yInset, left: xInset,
                                               bottom: yInset, right: xInset)
    }
}

extension ImageViewerVC: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
        // Only let the scroll view pan when there's something to pan to (image
        // zoomed past fit). At fit scale the swipe-down-to-dismiss gesture owns
        // vertical drags instead.
        scrollView.isScrollEnabled =
            scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
    }
}

extension ImageViewerVC: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === dismissPan else { return true }
        // Only allow swipe-to-dismiss when the image is at its fitted scale
        // (not pinch-zoomed in) and the drag is predominantly vertical, so it
        // never steals a pan meant for scrolling a zoomed-in image.
        let zoomedIn = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
        if zoomedIn { return false }
        let velocity = dismissPan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x)
    }
}

// MARK: - Zoom transition

/// Vends the present/dismiss zoom animators for `ImageViewerVC`. Holds the
/// source bubble (weak — the cell may be recycled) and the image so the
/// animators can build their snapshot. If the source view is gone by dismiss
/// time the animators fall back to a plain cross-dissolve.
final class ImageZoomTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {

    private let image: UIImage
    private weak var sourceView: UIView?
    private weak var viewer: ImageViewerVC?

    init(image: UIImage, sourceView: UIView, viewer: ImageViewerVC) {
        self.image = image
        self.sourceView = sourceView
        self.viewer = viewer
    }

    func animationController(forPresented presented: UIViewController,
                             presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return ImageZoomAnimator(image: image, sourceView: sourceView,
                                 viewer: viewer, presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController)
        -> UIViewControllerAnimatedTransitioning? {
        return ImageZoomAnimator(image: image, sourceView: sourceView,
                                 viewer: viewer, presenting: false)
    }
}

/// Snapshot-based zoom. Presenting: a copy of the image grows from the
/// bubble's frame to the viewer's fitted frame while a black backdrop fades
/// in. Dismissing: the reverse, starting from wherever the image currently
/// sits (covers both the close button and a partial swipe-down).
final class ImageZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let image: UIImage
    private weak var sourceView: UIView?
    private weak var viewer: ImageViewerVC?
    private let presenting: Bool

    init(image: UIImage, sourceView: UIView?, viewer: ImageViewerVC?, presenting: Bool) {
        self.image = image
        self.sourceView = sourceView
        self.viewer = viewer
        self.presenting = presenting
    }

    func transitionDuration(using ctx: UIViewControllerContextTransitioning?) -> TimeInterval {
        return presenting ? 0.32 : 0.28
    }

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        presenting ? animatePresent(ctx) : animateDismiss(ctx)
    }

    // Frame of the source bubble in the container's coordinate space, if it's
    // still on screen and non-degenerate.
    private func sourceFrame(in container: UIView) -> CGRect? {
        guard let src = sourceView, src.window != nil else { return nil }
        let f = src.convert(src.bounds, to: container)
        guard f.width > 1, f.height > 1, container.bounds.intersects(f) else { return nil }
        return f
    }

    private func makeSnapshot(_ frame: CGRect, cornerRadius: CGFloat) -> UIImageView {
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.frame = frame
        iv.layer.cornerRadius = cornerRadius
        return iv
    }

    private func animatePresent(_ ctx: UIViewControllerContextTransitioning) {
        let container = ctx.containerView
        guard let toVC = ctx.viewController(forKey: .to),
              let toView = ctx.view(forKey: .to) else {
            ctx.completeTransition(false); return
        }
        toView.frame = ctx.finalFrame(for: toVC)
        container.addSubview(toView)
        toView.layoutIfNeeded()

        let finalRect = ImageViewerVC.fittedRect(for: image.size, in: container.bounds)
        let startRect = sourceFrame(in: container) ?? finalRect

        // Hide the real content; fade the whole (black) viewer in as the dim.
        viewer?.prepareForZoomDismiss()
        toView.alpha = 0

        let snapshot = makeSnapshot(startRect, cornerRadius: 14)
        container.addSubview(snapshot)

        UIView.animate(withDuration: transitionDuration(using: ctx),
                       delay: 0,
                       options: [.curveEaseInOut],
                       animations: {
            toView.alpha = 1
            snapshot.frame = finalRect
            snapshot.layer.cornerRadius = 0
        }, completion: { _ in
            self.viewer?.restoreAfterZoom()
            snapshot.removeFromSuperview()
            ctx.completeTransition(!ctx.transitionWasCancelled)
        })
    }

    private func animateDismiss(_ ctx: UIViewControllerContextTransitioning) {
        let container = ctx.containerView
        guard let fromView = ctx.view(forKey: .from) else {
            ctx.completeTransition(false); return
        }

        let startRect = viewer?.currentImageFrame(in: container)
            ?? ImageViewerVC.fittedRect(for: image.size, in: container.bounds)
        let endRect = sourceFrame(in: container)
        let startAlpha = viewer?.currentDimAlpha ?? 1

        // Black backdrop behind the snapshot so the chat is revealed by the
        // fade rather than popping in. Continues from the live dim level.
        let backdrop = UIView(frame: container.bounds)
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(startAlpha)
        container.addSubview(backdrop)

        let snapshot = makeSnapshot(startRect, cornerRadius: 0)
        container.addSubview(snapshot)

        // Swap the live viewer out for the snapshot in the same runloop tick.
        viewer?.prepareForZoomDismiss()
        fromView.isHidden = true

        UIView.animate(withDuration: transitionDuration(using: ctx),
                       delay: 0,
                       options: [.curveEaseInOut],
                       animations: {
            backdrop.alpha = 0
            if let endRect = endRect {
                snapshot.frame = endRect
                snapshot.layer.cornerRadius = 14
            } else {
                // No bubble to land in — settle to a gentle fade.
                snapshot.alpha = 0
                snapshot.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
            }
        }, completion: { _ in
            backdrop.removeFromSuperview()
            snapshot.removeFromSuperview()
            fromView.removeFromSuperview()
            ctx.completeTransition(!ctx.transitionWasCancelled)
        })
    }
}
