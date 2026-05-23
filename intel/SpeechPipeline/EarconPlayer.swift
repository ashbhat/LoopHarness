//
//  EarconPlayer.swift
//  intel
//
//  iOS port of intelmac/EarconPlayer.swift. Same synthesized PCM buffers,
//  same frequencies/durations/volumes, same half-cosine
//  envelope. Adds AVAudioSession activation around the engine start so
//  earcons can coexist with the existing recording (.record) and TTS
//  (.playback) sessions on iOS.
//

import AVFoundation

final class EarconPlayer {
    static let shared = EarconPlayer()

    enum Name {
        case welcome, goodbye, listenStart, listenSend, interrupt, error
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var buffers: [Name: AVAudioPCMBuffer] = [:]
    private var started = false

    /// Set to false to silence all earcons globally. MessagingVC binds this
    /// to the speaker mute toggle so disabling voice playback also disables
    /// the cues.
    var enabled = true

    private init() {
        self.format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        buildBuffers()
    }

    /// Schedule the earcon for playback. Returns immediately. If the engine
    /// isn't running yet, starts it lazily on first call. Never throws —
    /// failures are logged and swallowed so the caller's state machine can't
    /// stall on an audio glitch.
    func play(_ name: Name) {
        guard enabled, let buf = buffers[name] else { return }
        if !started { startEngine() }
        guard started else { return }
        player.scheduleBuffer(buf, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Schedule the earcon and block until it has had a chance to finish.
    /// Unused on iOS today (kept symmetric with the Mac surface).
    func playBlocking(_ name: Name, timeout: TimeInterval = 0.5) {
        guard enabled, let buf = buffers[name] else { return }
        if !started { startEngine() }
        guard started else { return }
        let semaphore = DispatchSemaphore(value: 0)
        player.scheduleBuffer(buf) { semaphore.signal() }
        if !player.isPlaying { player.play() }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private func startEngine() {
        #if !os(macOS)
        // Make sure the shared session is in a category that will let our
        // engine actually play. We mix with others so an in-progress
        // recording session keeps its mic open and an in-progress TTS
        // playback isn't ducked off.
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playAndRecord && session.category != .playback {
                try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
                try session.setActive(true, options: [])
            }
        } catch {
            print("⚠️ EarconPlayer: AVAudioSession setup failed (\(error))")
        }
        #endif

        do {
            try engine.start()
            started = true
        } catch {
            print("⚠️ EarconPlayer: engine.start() failed (\(error))")
        }
    }

    // MARK: - Synthesis

    private struct Segment {
        let freqs: [Double]
        let duration: Double
        let volume: Double
    }

    private func buildBuffers() {
        // A4=440, G#4=415.30, G4=392, E4=329.63, C5=523.25, E5=659.25.
        buffers[.welcome]     = synthesize([
            Segment(freqs: [440.00], duration: 0.10, volume: 0.10),
            Segment(freqs: [659.25], duration: 0.18, volume: 0.12),
        ])
        buffers[.goodbye]     = synthesize([
            Segment(freqs: [659.25], duration: 0.10, volume: 0.10),
            Segment(freqs: [440.00], duration: 0.20, volume: 0.10),
        ])
        buffers[.listenStart] = synthesize([
            Segment(freqs: [659.25], duration: 0.07, volume: 0.10),
        ])
        buffers[.listenSend]  = synthesize([
            Segment(freqs: [523.25], duration: 0.06, volume: 0.10),
            Segment(freqs: [392.00], duration: 0.10, volume: 0.10),
        ])
        buffers[.interrupt]   = synthesize([
            Segment(freqs: [329.63], duration: 0.06, volume: 0.12),
        ])
        buffers[.error]       = synthesize([
            Segment(freqs: [523.25], duration: 0.08, volume: 0.12),
            Segment(freqs: [415.30], duration: 0.16, volume: 0.12),
        ])
    }

    private func synthesize(_ segments: [Segment]) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let totalFrames = segments.reduce(0) { $0 + Int(sr * $1.duration) }
        guard totalFrames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(totalFrames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(totalFrames)
        guard let ch = buf.floatChannelData?[0] else { return nil }

        var offset = 0
        for seg in segments {
            let n = Int(sr * seg.duration)
            let env = envelope(n: n)
            for i in 0..<n {
                let t = Double(i) / sr
                var sample: Double = 0
                for f in seg.freqs {
                    sample += sin(2.0 * .pi * f * t)
                }
                sample /= Double(seg.freqs.count)
                ch[offset + i] = Float(sample * Double(env[i]) * seg.volume)
            }
            offset += n
        }
        return buf
    }

    /// Half-cosine attack/decay envelope — 480-sample (≈10ms) ramps at start
    /// and end. Without this the tones click on/off audibly.
    private func envelope(n: Int, ramp: Int = 480) -> [Float] {
        var env = [Float](repeating: 1.0, count: n)
        let r = min(ramp, n / 2)
        guard r > 0 else { return env }
        for i in 0..<r {
            let x = Float(0.5 - 0.5 * cos(.pi * Double(i) / Double(r)))
            env[i] = x
            env[n - 1 - i] = x
        }
        return env
    }
}
