import SwiftUI

/// Entry point for the visionOS build of Loop.
///
/// Loop is a *companion orb*, not an environment: it launches straight into a
/// single volumetric window that lives in the visionOS **Shared Space**, so it
/// floats in your real room (passthrough) alongside every other open app. You
/// look at the orb and pinch-and-hold to talk — the equivalent of holding
/// fn+control on the Mac.
///
/// Why a volume and not an `ImmersiveSpace`: opening *any* immersive space
/// (even a `.mixed` passthrough one) moves the wearer into the exclusive Full
/// Space, where visionOS hides all other apps. Apps only coexist in the Shared
/// Space, and a 3D scene there must be hosted in a volumetric `WindowGroup`.
///
/// Two scenes share one `VisionSession`: the volumetric orb (primary) and a
/// plain 2D conversation window opened from the pill below the orb.
@main
struct LoopVisionApp: App {
    /// The orb's volume. Sized in metres, comfortably larger than the orb's
    /// fixed gaze/pinch collision sphere (0.64 m across) and its largest
    /// animated state (the speaking/acknowledge bloom, ~0.6 m across) so
    /// neither is clipped at the volume's edge. The volume is centred on the
    /// RealityView origin, so the orb sits at `[0,0,0]` (see `OrbVolumeView`).
    private static let volumeExtent: CGFloat = 0.8

    /// Window id for the split-view conversation window (referenced by the
    /// pill's `openWindow(id:)` in `OrbVolumeView`).
    static let conversationWindowID = "conversation"

    /// One session shared by the orb and the conversation window so voice
    /// turns and the visible transcript stay in lockstep.
    @State private var session = VisionSession()

    var body: some Scene {
        WindowGroup {
            OrbVolumeView(session: session)
        }
        .windowStyle(.volumetric)
        .defaultSize(
            width: Self.volumeExtent,
            height: Self.volumeExtent,
            depth: Self.volumeExtent,
            in: .meters
        )

        WindowGroup(id: Self.conversationWindowID) {
            ConversationView(session: session)
        }
        .defaultSize(width: 900, height: 680)
    }
}
