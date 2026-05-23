//
//  OrbAvatar.swift
//  LoopVision
//
//  The 3D port of the iOS/Mac "orb" avatar (intel/HelperViews/AvatarView.swift,
//  intelmac/AvatarView.swift). The 2D versions render an intensity *field* as a
//  grid of pixel cells; this version keeps that idea but lifts it into a true
//  volume: a lattice of small glowing spheres, each lit by the same intensity
//  formula evaluated in 3D. The result reads like a volumetric dot-matrix — a
//  breathing ball of luminous points that holds up from any angle in the
//  immersive space.
//
//  What is ported *verbatim* from the 2D AvatarView: the four modes, the
//  per-mode `shape(for:)` radius/scale formula, the color palette, the
//  asymmetric amplitude EMA, the mode crossfade, and the acknowledge bloom. The
//  only change is the final draw step: instead of `for y in 0..<gridH { for x
//  in 0..<gridW }` filling 2D squares, we walk a 3D lattice and size/show a
//  sphere per cell. The distance term `d` is the only thing that gains an axis
//  (`sqrt(dx*dx + dy*dy)` → `sqrt(dx*dx + dy*dy + dz*dz)`); every constant is
//  unchanged, so the orb keeps the same character across iPhone, Mac, Vision.
//
//  The 2D orb's pixel feel comes from a *quantized* radial falloff, not a
//  smooth gradient. We keep that: intensity is binned into `quantizeLevels`
//  discrete steps that drive each sphere's diameter, and sub-threshold cells
//  switch off entirely — the gaps between lit spheres are the 3D analogue of
//  the 2D orb's 1pt inter-cell gutter.
//
//  Float behaviour (all on the rig, independent of the renderer): a
//  `BillboardComponent` keeps the ball facing the viewer, the root drifts on a
//  slow orbit + vertical bob, and an inner pivot leans the ball back in
//  proportion to its own voice so it feels physically reactive.
//
//  An `UnlitMaterial` keeps every sphere at constant brightness regardless of
//  scene lighting; against the near-black immersive sky that reads as
//  self-illuminated. The 2D orb's per-mode `scale` (a pixel-alpha multiplier
//  there) maps to the shared material's emissive *brightness* here, so a
//  resting ball is a dim ember and an energetic one blazes.
//
//  NOTE: per LoopVision's "no Xcode build verification" constraint this is
//  unverified against an xrOS toolchain. `BillboardComponent` is a built-in
//  visionOS RealityKit component (auto-driven, no manual system); if a target
//  SDK lacks it, drop that one `components.set` line and the ball still works
//  minus viewer-facing.
//

import SwiftUI
import RealityKit
import simd

@MainActor
final class OrbAvatar {
    enum Mode { case idle, listening, thinking, speaking }

    /// Add this to the RealityView content. Everything (voxels, pivot) hangs
    /// off `root`; callers position the whole rig with `root.position`, which
    /// this class then treats as the orbit *centre* (see `update`).
    let root = Entity()

    /// Inner pivot: carries the thinking-swirl spin and the amplitude recoil
    /// so they don't fight the `BillboardComponent` that owns `root`'s
    /// orientation. Voxels are parented here.
    private let pivot = Entity()

    /// Pre-allocated, fixed-position sphere per lattice slot. Built once; per
    /// frame we only toggle `isEnabled`, set a quantized uniform `scale`, and
    /// (the one hot write — see perf note in `update`) reassign the shared
    /// material. Positions never change.
    private var voxels: [ModelEntity] = []
    /// Integer lattice coordinate (in voxel steps) for `voxels[n]`, parallel
    /// array so the per-frame loop avoids re-deriving it.
    private var coords: [SIMD3<Int>] = []
    /// Mirror of each voxel's enabled state so we only write `isEnabled` on a
    /// transition, not every frame.
    private var voxelOn: [Bool] = []

    // MARK: Lattice calibration

    /// Mirrors `AvatarView.baseRadius` (grid units). Kept identical so the
    /// `shape(for:)` math and its `0.066 * baseR` style constants are a
    /// straight copy of the 2D implementation.
    private let baseRadius: Double = 3.8

    /// Physical size: the old single-sphere orb used 0.16 m at r = baseRadius,
    /// so one grid unit ≈ 0.0421 m. Reused here so the voxel ball occupies the
    /// same physical volume as the orb it replaces.
    private var metersPerGridUnit: Float { 0.16 / Float(baseRadius) }

    /// Grid units between adjacent voxels. Coarser than the 2D 25×15 grid on
    /// purpose: fewer cells (cubic cost) *and* a chunkier, more deliberate
    /// dot-matrix read. Tunable — the fidelity/perf knob.
    private let voxelPitch: Double = 1.2

    /// How far the lattice must reach (grid units). Peak radius is speaking
    /// (baseR + 0.474·baseR ≈ 5.6) + pulse bloom (0.20·baseR ≈ 0.76) + the
    /// outer halo (~0.7), so 7.5 covers every mode with margin.
    private let latticeReach: Double = 7.5

    /// Max absolute lattice index per axis → (2·max+1)³ pre-allocated spheres.
    /// With pitch 1.2 / reach 7.5 that's 13³ = 2197 slots; at rest ~150 are
    /// visible, ~800 at a speaking peak.
    private var latticeMax: Int { Int((latticeReach / voxelPitch).rounded()) }

    /// Intensity is binned into this many size steps. Fewer = chunkier / more
    /// obviously "pixel". Below half a step the sphere switches off (the 3D
    /// equivalent of the 2D orb's 1pt inter-cell gutter).
    private let quantizeLevels = 5

    /// Diameter of a full-size (top-bin) sphere, in metres. The 0.78 fill
    /// leaves a gap between neighbours so the lattice reads as discrete dots
    /// rather than a fused blob.
    private var voxelDiameter: Float { Float(voxelPitch) * metersPerGridUnit * 0.78 }

    // MARK: Mode / animation state (verbatim from 2D AvatarView)

    private(set) var mode: Mode = .idle
    private var previousMode: Mode?
    private var transitionStart: TimeInterval?
    private let transitionDuration: TimeInterval = 0.25

    /// One-shot bloom — same (1-p)² envelope, duration and magnitude as the
    /// 2D `pulse()`. Fired as visual punctuation when a turn lands.
    private var pulseStart: TimeInterval?
    private let pulseDuration: TimeInterval = 0.30

    /// Real-time amplitude in [0, 1]. Mic RMS in `.listening`; the ball falls
    /// back to a synthesized wobble in `.speaking` when this stays ~0.
    var amplitude: Float = 0

    /// Eased amplitude consumed by the per-frame update. Fast attack (k=0.45)
    /// so peaks feel snappy, slow release (k=0.12) so it doesn't flicker
    /// between speech bursts — identical constants to the 2D AvatarView.
    private var smoothedAmplitude: Double = 0

    /// Accumulated scene time, advanced by `update(deltaTime:)`. Plays the
    /// role the 2D view's `Date().timeIntervalSince(startTime)` does.
    private var elapsed: TimeInterval = 0

    /// The orbit centre, captured once from wherever the caller parked
    /// `root.position` (OrbVolumeView places it before the first tick).
    private var orbitCenter: SIMD3<Float>?

    // MARK: Float behaviour calibration

    private let bobAmplitude: Float = 0.025   // metres of vertical drift
    private let bobOmega: Double = 0.9        // rad/s
    private let orbitRadius: Float = 0.05     // metres of horizontal drift
    private let orbitOmega: Double = 0.18     // rad/s — deliberately slow
    private let recoilDepth: Float = 0.045    // metres it leans away at amp=1
    private let recoilPitch: Float = 0.18     // radians it tilts back at amp=1

    init() {
        // Billboard so the ball faces the viewer as they move around it.
        // Auto-driven by RealityKit; our code only ever writes root.position.
        root.components.set(BillboardComponent())

        // Pinch target: the user pinches while looking at the ball (the Vision
        // equivalent of holding fn+control). A generous collision sphere makes
        // it forgiving to aim at even as the ball breathes.
        let reachM = Float(latticeReach) * metersPerGridUnit
        root.components.set(InputTargetComponent())
        root.components.set(CollisionComponent(shapes: [.generateSphere(radius: reachM)]))

        root.addChild(pivot)

        // One shared sphere mesh; per-cell appearance comes from uniform scale
        // (intensity) + the per-frame shared material (mode colour). Mesh and
        // positions are built exactly once.
        let mesh = MeshResource.generateSphere(radius: voxelDiameter * 0.5)
        let initialMaterial = UnlitMaterial(color: Self.color(Self.rgb(for: .idle), brightness: 0.45))
        let m = latticeMax
        voxels.reserveCapacity((2 * m + 1) * (2 * m + 1) * (2 * m + 1))
        for i in -m...m {
            for j in -m...m {
                for k in -m...m {
                    let voxel = ModelEntity(mesh: mesh, materials: [initialMaterial])
                    voxel.position = SIMD3<Float>(Float(i), Float(j), Float(k))
                        * Float(voxelPitch) * metersPerGridUnit
                    voxel.isEnabled = false
                    pivot.addChild(voxel)
                    voxels.append(voxel)
                    coords.append(SIMD3<Int>(i, j, k))
                    voxelOn.append(false)
                }
            }
        }
    }

    // MARK: - Public control (mirrors AvatarView's `mode` / `pulse()`)

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        previousMode = mode
        transitionStart = elapsed
        mode = newMode
    }

    func pulse() { pulseStart = elapsed }

    // MARK: - Per-frame update

    /// Call once per frame from the RealityView scene-update subscription.
    /// This is the 3D counterpart of `AvatarView.tick()` + `draw(_:)`.
    func update(deltaTime: TimeInterval) {
        elapsed += deltaTime
        let t = elapsed

        if orbitCenter == nil { orbitCenter = root.position }

        // --- Amplitude EMA — same constants as the 2D orb's `tick()`. -------
        let target = Double(max(0, min(1, amplitude)))
        let k = target > smoothedAmplitude ? 0.45 : 0.12
        smoothedAmplitude += (target - smoothedAmplitude) * k
        let amp = smoothedAmplitude

        // --- Mode crossfade (verbatim). ------------------------------------
        var blendProgress = 1.0
        var blendingPrevious: Mode?
        if let prev = previousMode, let start = transitionStart {
            let e = t - start
            if e < transitionDuration {
                blendProgress = smoothstep(e / transitionDuration)
                blendingPrevious = prev
            } else {
                previousMode = nil
                transitionStart = nil
            }
        }

        // --- Acknowledge bloom: (1-p)² envelope (verbatim). ----------------
        var pulseEnvelope = 0.0
        if let ps = pulseStart {
            let e = t - ps
            if e < pulseDuration {
                let p = e / pulseDuration
                pulseEnvelope = (1.0 - p) * (1.0 - p)
            } else {
                pulseStart = nil
            }
        }

        var cur = shape(for: mode, t: t, amp: amp)
        if pulseEnvelope > 0 {
            cur = ModeShape(r: cur.r + baseRadius * 0.20 * pulseEnvelope,
                            scale: cur.scale + 0.15 * pulseEnvelope)
        }

        var rGrid = cur.r          // effective radius, in grid units
        var glow = cur.scale       // effective brightness multiplier
        var rgb = Self.rgb(for: mode)
        if let prev = blendingPrevious {
            let p = shape(for: prev, t: t, amp: amp)
            rGrid = lerp(p.r, rGrid, blendProgress)
            glow = lerp(p.scale, glow, blendProgress)
            rgb = lerp(Self.rgb(for: prev), rgb, Float(blendProgress))
        }

        // One material for the whole ball this frame (mode colour × glow).
        // PERF: UnlitMaterial can't be mutated in place and shared live across
        // ModelComponents, so the colour change costs one material reassign
        // per *visible* voxel below. That's ~150 (idle) to ~800 (speaking
        // peak) writes/frame — fine for a prototype on Vision Pro. The
        // scale-free upgrade path is a single instanced LowLevelMesh; deferred
        // until the look is locked.
        let sharedMaterial = UnlitMaterial(color: Self.color(rgb, brightness: glow))

        // Only iterate/write the lattice region the current shape can reach,
        // not all ~2000 slots — at rest this is a small sub-cube.
        let bound = min(latticeMax,
                        Int((rGrid / voxelPitch).rounded(.up)) + 1)
        let effShape = ModeShape(r: rGrid, scale: glow)

        for n in 0..<voxels.count {
            let c = coords[n]
            // Outside the active region: ensure off (write only on change).
            if abs(c.x) > bound || abs(c.y) > bound || abs(c.z) > bound {
                if voxelOn[n] { voxels[n].isEnabled = false; voxelOn[n] = false }
                continue
            }

            let dx = Double(c.x) * voxelPitch
            let dy = Double(c.y) * voxelPitch
            let dz = Double(c.z) * voxelPitch
            let inten = intensity(for: effShape, mode: mode, dx: dx, dy: dy, dz: dz, t: t)

            // Quantize → discrete dot-matrix steps. Below half a step: off.
            let stepped = Int((inten * Double(quantizeLevels)).rounded())
            if stepped < 1 {
                if voxelOn[n] { voxels[n].isEnabled = false; voxelOn[n] = false }
                continue
            }
            let bin = min(stepped, quantizeLevels)

            let voxel = voxels[n]
            if !voxelOn[n] { voxel.isEnabled = true; voxelOn[n] = true }
            voxel.scale = SIMD3<Float>(repeating: Float(bin) / Float(quantizeLevels))
            voxel.model?.materials = [sharedMaterial]
        }

        // --- Float behaviour (independent of the renderer). ----------------
        let centre = orbitCenter ?? root.position

        // Slow orbital drift + gentle vertical bob around the caller's point.
        let orbitX = orbitRadius * Float(cos(t * orbitOmega))
        let orbitZ = orbitRadius * Float(sin(t * orbitOmega))
        let bobY = bobAmplitude * Float(sin(t * bobOmega))
        root.position = centre + SIMD3<Float>(orbitX, bobY, orbitZ)
        // root.orientation is owned by BillboardComponent — don't touch it.

        // Inner pivot: thinking spin (the 2D swirl's analogue) composed with
        // an amplitude recoil so the ball physically leans back when it talks.
        let a = Float(min(1.0, amp))
        let spin = mode == .thinking
            ? simd_quatf(angle: Float(t) * 1.4, axis: [0, 1, 0])
            : simd_quatf(angle: 0, axis: [0, 1, 0])
        let lean = simd_quatf(angle: -recoilPitch * a, axis: [1, 0, 0])
        pivot.orientation = spin * lean
        pivot.position = SIMD3<Float>(0, 0.01 * a, -recoilDepth * a)
    }

    // MARK: - Mode shape (verbatim port of AvatarView.shape(for:))

    private struct ModeShape {
        let r: Double
        let scale: Double
    }

    private func shape(for mode: Mode, t: TimeInterval, amp: Double) -> ModeShape {
        let baseR = baseRadius
        let idleWobble     = 0.066 * baseR
        let thinkingWobble = 0.105 * baseR
        let speakingGrowth = 0.474 * baseR
        let r: Double
        let scale: Double
        switch mode {
        case .idle:
            r = baseR + idleWobble * sin(t * 1.4)
            scale = 0.45
        case .listening:
            // Shrink the resting ball and sqrt-curve the amplitude so quiet
            // speech still produces visible motion (same as 2D).
            let curvedAmp = sqrt(max(0, min(1, amp)))
            r = baseR * 0.55 + baseR * 1.05 * curvedAmp
            scale = 0.45 + 0.55 * curvedAmp
        case .thinking:
            r = baseR + thinkingWobble * sin(t * 3.0)
            scale = 0.7
        case .speaking:
            // Prefer real output amplitude; fall back to the canned two-sine
            // wobble when none is arriving so the ball still moves.
            if amp > 0.02 {
                r = baseR + speakingGrowth * amp
                scale = 0.7 + 0.3 * amp
            } else {
                let wobble = abs(0.5 * sin(t * 7.0) + 0.3 * sin(t * 4.3))
                r = baseR + speakingGrowth * wobble
                scale = 0.7 + 0.3 * wobble
            }
        }
        return ModeShape(r: r, scale: scale)
    }

    /// 3D intensity. The non-thinking branch is the 2D formula with the
    /// distance term promoted to 3D (the *only* change). Thinking keeps the
    /// 2D ring + swirl but measures the swirl angle around the rig's Y axis
    /// (atan2 in the XZ plane), so it agrees with the pivot's Y spin.
    private func intensity(for shape: ModeShape, mode: Mode,
                           dx: Double, dy: Double, dz: Double,
                           t: TimeInterval) -> Double {
        let d = sqrt(dx * dx + dy * dy + dz * dz)
        if mode == .thinking {
            let angle = atan2(dz, dx)
            let ring = max(0.0, 1.0 - abs(d - shape.r) * 0.9)
            let swirl = 0.5 + 0.5 * sin(angle * 3 - t * 4)
            let fill = max(0.0, 1.0 - d / max(shape.r, 0.01)) * 0.3
            return (ring * swirl + fill) * shape.scale
        } else {
            if d < shape.r {
                return (1.0 - d / max(shape.r, 0.01)) * shape.scale
            } else {
                return max(0.0, 1.0 - (d - shape.r) * 1.4) * shape.scale * 0.7
            }
        }
    }

    private func smoothstep(_ x: Double) -> Double {
        let c = max(0.0, min(1.0, x))
        return c * c * (3.0 - 2.0 * c)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    private func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    // MARK: - Palette (matching the 2D color(for:))

    /// Concrete RGB approximations of the semantic colors the 2D orb uses:
    /// neutral resting, systemCyan listening, systemPurple thinking,
    /// systemGreen speaking. The immersive sky is near-black, so idle uses a
    /// soft white rather than the 2D `.label` (which would be dark on light).
    private static func rgb(for mode: Mode) -> SIMD3<Float> {
        switch mode {
        case .idle:      return SIMD3<Float>(0.85, 0.87, 0.92)
        case .listening: return SIMD3<Float>(0.20, 0.78, 1.00) // ~ systemCyan
        case .thinking:  return SIMD3<Float>(0.69, 0.32, 0.87) // ~ systemPurple
        case .speaking:  return SIMD3<Float>(0.20, 0.82, 0.40) // ~ systemGreen
        }
    }

    /// `brightness` is the 2D orb's per-mode `scale` (0…~1). In 2D it scales
    /// pixel alpha; here it scales emissive luminance so a resting ball is a
    /// dim ember and an energetic one is a bright bloom. Clamped to a
    /// non-zero floor so the ball never fully vanishes.
    private static func color(_ rgb: SIMD3<Float>, brightness: Double) -> RealityKit.Material.Color {
        let b = CGFloat(max(0.18, min(1.0, brightness)))
        return RealityKit.Material.Color(red: CGFloat(rgb.x) * b,
                                         green: CGFloat(rgb.y) * b,
                                         blue: CGFloat(rgb.z) * b,
                                         alpha: 1.0)
    }
}
