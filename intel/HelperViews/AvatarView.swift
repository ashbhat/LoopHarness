//
//  AvatarView.swift
//  Loop
//
//  iOS port of intelmac/AvatarView.swift. UIKit equivalent of the Mac
//  pixel-art "orb" — same intensity formula, same per-mode parameters, same
//  color palette. Uses CADisplayLink for ambient ticks instead
//  of NSTimer so frames stay synced to the device refresh rate.
//

import UIKit

final class AvatarView: UIView {
    enum Mode { case idle, listening, thinking, speaking }

    var mode: Mode = .idle {
        didSet {
            guard mode != oldValue else { return }
            // Capture the prior mode so `draw` can crossfade between the
            // two for ~transitionDuration seconds. Avoids a hard snap of
            // color and radius when state flips (e.g. listening → thinking).
            previousMode = oldValue
            transitionStart = Date()
            setNeedsDisplay()
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

    /// Trigger an acknowledge bloom. Replaces any in-flight pulse so
    /// back-to-back triggers don't drown each other out.
    func pulse() {
        pulseStart = Date()
        setNeedsDisplay()
    }
    /// Real-time mic RMS in [0, 1]. Only consulted in `.listening`.
    /// Updates here arrive at the publisher's cadence (~10 Hz on iOS), but the
    /// displayLink ticks at 30 Hz and reads `smoothedAmplitude`, which lerps
    /// toward this target — so the orb pulses smoothly between samples instead
    /// of stepping.
    var amplitude: Float = 0

    /// Eased amplitude consumed by `draw`. Fast attack so peaks feel snappy,
    /// slower decay so the orb doesn't flicker between speech bursts.
    private var smoothedAmplitude: Double = 0

    private let gridW: Int
    private let gridH: Int
    private let pixelSize: CGFloat
    private let baseRadius: Double

    private var startTime = Date()
    private var displayLink: CADisplayLink?

    override var intrinsicContentSize: CGSize {
        CGSize(width: CGFloat(gridW) * pixelSize, height: CGFloat(gridH) * pixelSize)
    }

    init(gridW: Int = 25, gridH: Int = 15, pixelSize: CGFloat = 10, baseRadius: Double = 3.8) {
        self.gridW = gridW
        self.gridH = gridH
        self.pixelSize = pixelSize
        self.baseRadius = baseRadius
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { displayLink?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    private func startAnimating() {
        guard displayLink == nil else { return }
        startTime = Date()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        let target = Double(max(0, min(1, amplitude)))
        let k = target > smoothedAmplitude ? 0.45 : 0.12
        smoothedAmplitude += (target - smoothedAmplitude) * k
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
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
        // decays quickly. Applied as an additive bump to the current
        // mode's radius and scale — outgoing mode in a transition is left
        // alone so the bloom reads as "the new state arrived".
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
                let cellRect = CGRect(
                    x: CGFloat(x) * pixelSize,
                    y: CGFloat(y) * pixelSize,
                    width: pixelSize - 1,
                    height: pixelSize - 1
                )

                // Outgoing mode is drawn first (faded by 1-progress) so the
                // incoming color composites cleanly on top.
                if let prevShape = prevShape, let prevColor = prevColor {
                    let i = intensity(for: prevShape, dx: dx, dy: dy, t: t)
                    let alpha = CGFloat(max(0.0, min(1.0, i)) * (1.0 - blendProgress))
                    if alpha >= 0.05 {
                        ctx.setFillColor(prevColor.withAlphaComponent(alpha).cgColor)
                        ctx.fill(cellRect)
                    }
                }

                let curI = intensity(for: currentShape, dx: dx, dy: dy, t: t)
                let curAlpha = CGFloat(max(0.0, min(1.0, curI)) * blendProgress)
                if curAlpha >= 0.05 {
                    ctx.setFillColor(currentColor.withAlphaComponent(curAlpha).cgColor)
                    ctx.fill(cellRect)
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
            // Shrink the resting orb (0.55 × baseR at amp=0) and curve amp
            // with sqrt so quiet speech still produces visible motion. The
            // old linear mapping made everyday speech look almost static.
            let curvedAmp = sqrt(max(0, min(1, amp)))
            r = baseR * 0.55 + baseR * 1.05 * curvedAmp
            scale = 0.45 + 0.55 * curvedAmp
        case .thinking:
            r = baseR + thinkingWobble * sin(t * 3.0)
            scale = 0.7
        case .speaking:
            // Prefer real TTS output amplitude when it's flowing in. Fall
            // back to the canned two-sine wobble when no amplitude has
            // arrived recently (silent gap, AVSpeechSynthesizer path) so
            // the orb still moves.
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

    private func color(for mode: Mode) -> UIColor {
        // Matches the Mac palette so cross-device users see the same orb
        // character: neutral resting, cyan listening, purple thinking,
        // green speaking. UIColor dynamic colors resolve against the current
        // trait collection at draw time, so the resting orb inverts in dark
        // mode without extra plumbing.
        switch mode {
        case .idle:      return UIColor.label
        case .listening: return UIColor.systemCyan
        case .thinking:  return UIColor.systemPurple
        case .speaking:  return UIColor.systemGreen
        }
    }
}
