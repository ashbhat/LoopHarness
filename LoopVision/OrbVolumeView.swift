import SwiftUI
import RealityKit

/// The orb, hosted in a volumetric window in the visionOS Shared Space.
///
/// This is the Vision Pro port of the iOS/Mac orb. There is deliberately *no*
/// skybox or starfield here (the immersive build had both): a volume's
/// background is clear, so the orb floats against live passthrough — your real
/// room, with every other app still visible around it.
///
/// Interaction is "look at it and pinch": `OrbAvatar` carries an
/// `InputTargetComponent` + `CollisionComponent`, and the pinch gesture below
/// is `.targetedToEntity(orb.root)`. visionOS only routes the pinch to the orb
/// while the wearer's gaze is on that collision shape — so a glance plus a
/// pinch-and-hold is the exact analogue of holding fn+control on the Mac:
/// record while held, send the turn on release.
///
/// All conversation state comes from the shared `VisionSession`; this view
/// only renders it (orb + floating caption) and forwards the pinch. The pill
/// ornament opens the separate 2D conversation window.
struct OrbVolumeView: View {
    let session: VisionSession

    /// The orb is a reference type that must outlive any single view-body
    /// evaluation; `@State` keeps one instance for the window's lifetime.
    @State private var orb = OrbAvatar()
    /// Retains the per-frame scene-update subscription — `EventSubscription`
    /// cancels itself as soon as it's released.
    @State private var subscriptions = SubscriptionBox()

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RealityView { content, attachments in
            // A volumetric window's RealityView is centred on its origin, so
            // placing the orb at the origin sits it in the middle of the
            // volume. The user repositions the whole volume like any window.
            orb.root.position = .zero
            content.add(orb.root)

            // The caption floats just below the orb, within the volume.
            if let caption = attachments.entity(for: Self.captionID) {
                caption.position = SIMD3<Float>(0, -0.30, 0)
                content.add(caption)
            }

            // Per-frame tick — the 3D analogue of the 2D AvatarView's
            // CADisplayLink. `deltaTime` keeps the animation framerate-
            // independent.
            subscriptions.tick = content.subscribe(to: SceneEvents.Update.self) { event in
                orb.update(deltaTime: event.deltaTime)
            }
        } update: { _, _ in
            // Reading the session's observable state here makes RealityView
            // re-run this closure whenever it changes, pushing mode/amplitude
            // into the orb. `setMode` is idempotent so repeats are free.
            orb.setMode(session.mode)
            orb.amplitude = session.amplitude
        } attachments: {
            Attachment(id: Self.captionID) {
                ConversationCaption(session: session)
            }
        }
        .gesture(pinchHold)
        .ornament(attachmentAnchor: .scene(.bottom)) {
            pill
        }
        // GitHub write tools (merge/review/comment/create) park a pending
        // confirmation on the session. The orb is the always-present surface
        // in visionOS, so the alert lives here so voice-only flows still get
        // a confirmation prompt even when the conversation window is closed.
        .alert(
            session.pendingGitHubConfirmation?.title ?? "",
            isPresented: Binding(
                get: { session.pendingGitHubConfirmation != nil },
                set: { presented in
                    // SwiftUI flips this to false when the alert dismisses
                    // via the user's tap (which already resolved the request)
                    // or via swipe-to-dismiss. The latter should cancel.
                    if !presented, session.pendingGitHubConfirmation != nil {
                        session.resolveGitHubConfirmation(false)
                    }
                }
            ),
            presenting: session.pendingGitHubConfirmation
        ) { pending in
            Button("Confirm", role: pending.destructive ? .destructive : nil) {
                session.resolveGitHubConfirmation(true)
            }
            Button("Cancel", role: .cancel) {
                session.resolveGitHubConfirmation(false)
            }
        } message: { pending in
            if !pending.detail.isEmpty { Text(pending.detail) }
        }
    }

    private static let captionID = "caption"

    // MARK: - Pinch-hold gesture (the fn+control equivalent)

    /// A zero-distance drag targeted at the orb behaves as press-and-hold:
    /// the first `onChanged` is the pinch-down, `onEnded` is the release.
    /// `pinchBegan()` is idempotent so the repeated `onChanged` callbacks
    /// while the pinch is held don't restart capture — same contract as
    /// `HotKeyMonitor.onHoldBegan` / `onHoldEnded`.
    private var pinchHold: some Gesture {
        DragGesture(minimumDistance: 0)
            .targetedToEntity(orb.root)
            .onChanged { _ in session.pinchBegan() }
            .onEnded { _ in session.pinchEnded() }
    }

    // MARK: - Pill → conversation window

    private var pill: some View {
        Button {
            openWindow(id: LoopVisionApp.conversationWindowID)
        } label: {
            Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                .font(.headline)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .glassBackgroundEffect()
        .padding(.bottom, 18)
    }
}

/// Holds the scene-update subscription so it isn't deallocated (and thereby
/// cancelled) the moment `RealityView`'s make closure returns.
@MainActor
final class SubscriptionBox {
    var tick: EventSubscription?
}

#Preview(windowStyle: .volumetric) {
    OrbVolumeView(session: VisionSession())
}
