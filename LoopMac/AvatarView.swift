//
//  AvatarView.swift
//  LoopMac
//
//  Pixel-art "orb" that represents the AI at the top of the conversation
//  window. An intensity-based formula with per-mode parameters, rendered as
//  small filled squares on an NSView.
//
//  Four modes:
//    - idle:       slow breathing pulse
//    - listening:  radius + scale track real mic RMS
//    - thinking:   rotating swirl across a ring
//    - speaking:   "voice out" wobble synthesized from layered sines (we
//                  don't currently sample the TTS engine's output level)
//

import AppKit
import QuartzCore

/// Which spinning-orb prototype is active. Toggle to A/B test.
enum SpinMode {
    /// Original behaviour — no rotation.
    case off
    /// Option 1: treat each pixel as a point on a 3D sphere (lat/lon → x,y,z),
    /// rotate around the Y axis every frame. Equator moves fast, poles barely
    /// move — reads as a spinning globe.
    case spherical
    /// Option 2: horizontal rows of pixels drift at speeds proportional to
    /// cos(latitude). No real 3D math, but the silhouette still feels
    /// spherical. Cheaper fallback.
    case parallaxBands
}

final class AvatarView: NSView {
    enum Mode { case idle, listening, thinking, speaking }

    // MARK: - Spinning-orb prototype toggle & knobs

    /// Change this to switch between prototypes at runtime.
    static var spinMode: SpinMode = .spherical

    /// Y-axis rotation speed in radians per second.
    var rotationSpeed: Double = 1.2
    /// Longitudinal band count for the procedural surface texture.
    var spinBandCount: Double = 4.0
    /// Band spatial frequency for parallax mode (grid-unit⁻¹).
    var parallaxBandFrequency: Double = 0.8

    var mode: Mode = .idle {
        didSet {
            guard mode != oldValue else { return }
            // Capture the prior mode so `draw` can crossfade between the two
            // for ~transitionDuration seconds. Avoids a hard snap of color
            // and radius when state flips (e.g. listening → thinking).
            previousMode = oldValue
            transitionStart = Date()
            needsDisplay = true
        }
    }

    private var previousMode: Mode?
    private var transitionStart: Date?
    private let transitionDuration: TimeInterval = 0.25

    /// One-shot bloom that briefly grows the orb (radius + scale) and
    /// decays out. Fired by callers as visual punctuation — e.g. the user
    /// just sent a turn, or the assistant just finished one. Independent
    /// of mode, so it overlays on top of whatever animation is running.
    private var pulseStart: Date?
    private let pulseDuration: TimeInterval = 0.30

    /// Trigger an acknowledge bloom. Safe to call from any mode; if a pulse
    /// is already in flight, this replaces it so back-to-back triggers
    /// don't drown each other out.
    func pulse() {
        pulseStart = Date()
        needsDisplay = true
    }
    /// Real-time amplitude in [0, 1]. Read in `.listening` (mic RMS) and
    /// `.speaking` (TTS output RMS). Updates here can arrive at any
    /// cadence — the display-link `tick()` lerps `smoothedAmplitude` toward
    /// it so the orb pulses smoothly between samples instead of stepping.
    var amplitude: Float = 0

    /// Eased amplitude consumed by `draw`. Fast attack (k=0.45) so peaks
    /// feel snappy, slower release (k=0.12) so the orb doesn't flicker
    /// between speech bursts — matches the iOS `AvatarView` smoothing.
    private var smoothedAmplitude: Double = 0

    // Grid dimensions and the orb's resting radius. Parameterized so the
    // same view can be used at conversation-window scale (25×15 @ 10pt
    // cells) and at recorder-bar scale (e.g. 9×9 @ 4pt cells).
    private let gridW: Int
    private let gridH: Int
    private let pixelSize: CGFloat
    private let baseRadius: Double

    private var startTime = Date()
    private var displayLink: CADisplayLink?

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(gridW) * pixelSize, height: CGFloat(gridH) * pixelSize)
    }

    // Drawing in top-down coordinates matches how the formula thinks about
    // (x, y) — avoids manual Y-flips in `draw(_:)`.
    override var isFlipped: Bool { true }

    /// Default geometry matches the conversation-window avatar (25×15
    /// cells, baseR 3.8). Pass smaller values for the recorder-bar mini.
    init(gridW: Int = 25, gridH: Int = 15, pixelSize: CGFloat = 10, baseRadius: Double = 3.8) {
        self.gridW = gridW
        self.gridH = gridH
        self.pixelSize = pixelSize
        self.baseRadius = baseRadius
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { displayLink?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Only burn frames while we're actually on screen — when the
        // conversation window is closed or the app is hidden, stop ticking.
        if window != nil {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    private func startAnimating() {
        guard displayLink == nil else { return }
        startTime = Date()
        // NSView's display link (macOS 14+) ties redraws to the view's
        // current screen refresh rate. Replaces the wall-clock Timer that
        // could drift relative to the display and stutter under load.
        let link = self.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        // Asymmetric EMA: rise fast (peaks feel snappy), fall slow (no
        // jitter between speech bursts). Same constants as iOS AvatarView.
        let target = Double(max(0, min(1, amplitude)))
        let k = target > smoothedAmplitude ? 0.45 : 0.12
        smoothedAmplitude += (target - smoothedAmplitude) * k
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = Date().timeIntervalSince(startTime)

        let cx = Double(gridW) / 2.0 - 0.5
        let cy = Double(gridH) / 2.0 - 0.5
        let amp = smoothedAmplitude

        // Where we are in the crossfade between previousMode and mode.
        // `progress` rises from 0→1 over `transitionDuration`; once we land
        // we drop the previousMode so subsequent frames go single-shape.
        var blendProgress: Double = 1.0
        var blendingPrevious: Mode? = nil
        if let prev = previousMode, let start = transitionStart {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed < transitionDuration {
                blendProgress = smoothstep(elapsed / transitionDuration)
                blendingPrevious = prev
            } else {
                previousMode = nil
                transitionStart = nil
            }
        }

        // Acknowledge pulse: (1 - progress)² envelope so it pops hard and
        // decays quickly. Applied as an additive bump to the current mode's
        // radius and scale — outgoing mode in a transition is left alone so
        // the bloom reads as "the new state arrived".
        var pulseEnvelope: Double = 0
        if let pulseStart = pulseStart {
            let elapsed = Date().timeIntervalSince(pulseStart)
            if elapsed < pulseDuration {
                let p = elapsed / pulseDuration
                pulseEnvelope = (1.0 - p) * (1.0 - p)
            } else {
                self.pulseStart = nil
            }
        }

        var currentShape = shape(for: mode, t: t, amp: amp)
        if pulseEnvelope > 0 {
            currentShape = ModeShape(
                mode: currentShape.mode,
                r: currentShape.r + baseRadius * 0.20 * pulseEnvelope,
                scale: currentShape.scale + 0.15 * pulseEnvelope
            )
        }
        let prevShape = blendingPrevious.map { shape(for: $0, t: t, amp: amp) }
        let currentColor = color(for: mode)
        let prevColor = blendingPrevious.map { color(for: $0) }

        for y in 0..<gridH {
            for x in 0..<gridW {
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                let rect = NSRect(
                    x: CGFloat(x) * pixelSize,
                    y: CGFloat(y) * pixelSize,
                    // pixelSize - 1 leaves a 1pt gap between cells — that
                    // gap is what makes the result read as "pixels" rather
                    // than a smooth gradient.
                    width: pixelSize - 1,
                    height: pixelSize - 1
                )

                // Outgoing mode is drawn first (faded by 1-progress) so the
                // incoming color composites cleanly on top.
                if let prevShape = prevShape, let prevColor = prevColor {
                    let i = effectiveIntensity(for: prevShape, dx: dx, dy: dy, t: t)
                    let alpha = CGFloat(max(0.0, min(1.0, i)) * (1.0 - blendProgress))
                    if alpha >= 0.05 {
                        ctx.setFillColor(prevColor.withAlphaComponent(alpha).cgColor)
                        ctx.fill(rect)
                    }
                }

                let curI = effectiveIntensity(for: currentShape, dx: dx, dy: dy, t: t)
                let curAlpha = CGFloat(max(0.0, min(1.0, curI)) * blendProgress)
                if curAlpha >= 0.05 {
                    ctx.setFillColor(currentColor.withAlphaComponent(curAlpha).cgColor)
                    ctx.fill(rect)
                }
            }
        }
    }

    // MARK: - Mode shape + intensity

    private struct ModeShape {
        let mode: Mode
        let r: Double
        let scale: Double
    }

    /// Per-mode radius/scale. Calibration constants are fractions of
    /// `baseRadius` so the orb's reactive amplitude stays proportional at
    /// every size (conversation-window vs recorder-bar).
    private func shape(for mode: Mode, t: TimeInterval, amp: Double) -> ModeShape {
        let baseR = baseRadius
        let idleWobble       = 0.066 * baseR
        let thinkingWobble   = 0.105 * baseR
        let speakingGrowth   = 0.474 * baseR
        let r: Double
        let scale: Double
        switch mode {
        case .idle:
            r = baseR + idleWobble * sin(t * 1.4)
            scale = 0.45
        case .listening:
            // Two changes vs the resting-orb sizes of other modes:
            //   1. Shrink the center (0.55 × baseR at amp=0) so there's
            //      headroom for the wave to expand visibly into when the
            //      user actually speaks.
            //   2. Curve amplitude with sqrt so quiet speech still produces
            //      visible motion — linear mapping made everyday speech
            //      look almost static.
            let curvedAmp = sqrt(max(0, min(1, amp)))
            r = baseR * 0.55 + baseR * 1.05 * curvedAmp
            scale = 0.45 + 0.55 * curvedAmp
        case .thinking:
            r = baseR + thinkingWobble * sin(t * 3.0)
            scale = 0.7
        case .speaking:
            // Prefer real TTS output amplitude when it's flowing in — gives
            // the orb a "lip-synced" feel that tracks actual speech bursts
            // and pauses. Fall back to the canned two-sine wobble when no
            // amplitude has arrived recently (silent gap, AVSpeechSynthesizer
            // path, etc.) so the orb still moves convincingly.
            if amp > 0.02 {
                r = baseR + speakingGrowth * amp
                scale = 0.7 + 0.3 * amp
            } else {
                let wobble = abs(0.5 * sin(t * 7.0) + 0.3 * sin(t * 4.3))
                r = baseR + speakingGrowth * wobble
                scale = 0.7 + 0.3 * wobble
            }
        }
        return ModeShape(mode: mode, r: r, scale: scale)
    }

    // MARK: - Spin-aware intensity

    private func effectiveIntensity(for shape: ModeShape, dx: Double, dy: Double, t: TimeInterval) -> Double {
        let base = intensity(for: shape, dx: dx, dy: dy, t: t)
        switch Self.spinMode {
        case .off:
            return base
        case .spherical:
            return sphericalIntensity(base: base, shape: shape, dx: dx, dy: dy, t: t)
        case .parallaxBands:
            return parallaxIntensity(base: base, shape: shape, dx: dx, dy: dy, t: t)
        }
    }

    /// Option 1: project each pixel onto a sphere, rotate around Y, sample
    /// a procedural longitude-band texture, and add limb darkening + specular.
    private func sphericalIntensity(base: Double, shape: ModeShape, dx: Double, dy: Double, t: TimeInterval) -> Double {
        let r = max(shape.r, 0.01)
        let d = sqrt(dx * dx + dy * dy)
        guard d < r else { return base }

        let zSq = r * r - dx * dx - dy * dy
        let z = sqrt(max(0, zSq))

        let lon = atan2(dx, z) + rotationSpeed * t
        let lat = asin(max(-1, min(1, dy / r)))

        let pattern = 0.82 + 0.18 * sin(lon * spinBandCount + lat * 1.5)

        // Limb darkening (Lambertian-ish).
        let cosAngle = z / r
        let limb = 0.55 + 0.45 * pow(cosAngle, 0.6)

        // Fixed specular highlight — upper-right light, does not rotate.
        let nx = dx / r, ny = dy / r, nz = z / r
        let ldot = max(0.0, nx * 0.5 + ny * (-0.5) + nz * 0.7071)
        let spec = pow(ldot, 16.0) * 0.25

        return base * pattern * limb + spec
    }

    /// Option 2: each row drifts at cos(latitude) speed. Cheap — one sqrt
    /// per pixel, no per-pixel trig.
    private func parallaxIntensity(base: Double, shape: ModeShape, dx: Double, dy: Double, t: TimeInterval) -> Double {
        let r = max(shape.r, 0.01)
        let d = sqrt(dx * dx + dy * dy)
        guard d < r else { return base }

        let lat = dy / r
        let drift = sqrt(max(0, 1.0 - lat * lat))
        let shifted = dx + drift * rotationSpeed * t
        let pattern = 0.82 + 0.18 * sin(shifted * parallaxBandFrequency)

        // Limb darkening approximation.
        let edgeFrac = d / r
        let limb = 0.55 + 0.45 * (1.0 - edgeFrac * edgeFrac)

        // Fixed specular highlight (same as spherical).
        let approxZ = sqrt(max(0, 1.0 - edgeFrac * edgeFrac))
        let nx = dx / r, ny = dy / r, nz = approxZ
        let ldot = max(0.0, nx * 0.5 + ny * (-0.5) + nz * 0.7071)
        let spec = pow(ldot, 16.0) * 0.25

        return base * pattern * limb + spec
    }

    private func intensity(for shape: ModeShape, dx: Double, dy: Double, t: TimeInterval) -> Double {
        let d = sqrt(dx * dx + dy * dy)
        if shape.mode == .thinking {
            let angle = atan2(dy, dx)
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

    private func color(for mode: Mode) -> NSColor {
        // Mode palette: a neutral resting tone, cyan
        // when listening, purple when thinking, green when speaking. We
        // hand back NSColor objects (not CGColors) so each draw resolves
        // them against the *current* effective appearance — that's how the
        // resting orb inverts (dark dots on light mode, light dots on dark
        // mode) without any extra plumbing.
        switch mode {
        case .idle:      return NSColor.labelColor
        case .listening: return NSColor.systemCyan
        case .thinking:  return NSColor.systemPurple
        case .speaking:  return NSColor.systemGreen
        }
    }
}
