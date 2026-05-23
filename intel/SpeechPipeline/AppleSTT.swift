//
//  AppleSTT.swift
//  Loop
//
//  Apple on-device speech recognition wrapped so it can be dropped in where
//  DeepgramSTT lives when the device is offline. Mirrors that class's
//  partial/final/error callback shape so VoiceLoopCoordinator can swap one
//  for the other without restructuring the audio tap.
//
//  Why this exists separately from MessageBox's iOS-only SFSpeech path:
//  MessageBox is a UIView and ties everything to its own state. This helper
//  is a plain object that both targets can use; the iOS app keeps its
//  in-MessageBox path for now and Mac uses this for its offline fallback.
//

import Foundation
import Speech
import AVFoundation

final class AppleSTT {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalDelivered = false

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    /// Starts a live recognition session. Caller is responsible for getting
    /// authorization first via `AppleSTT.requestAuthorization`. Returns
    /// false (and fires `onError`) if the locale doesn't support on-device
    /// recognition — offline recognition is mandatory because callers reach
    /// us specifically when the network is gone.
    @discardableResult
    func start() -> Bool {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            onError?("SFSpeechRecognizer unavailable")
            return false
        }
        guard recognizer.supportsOnDeviceRecognition else {
            onError?("On-device recognition unsupported for this locale")
            return false
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Forced on-device — otherwise SFSpeech tries to reach Apple's
        // servers and hangs when we're offline, exactly the case this path
        // is for.
        req.requiresOnDeviceRecognition = true
        self.request = req
        self.finalDelivered = false

        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    if !self.finalDelivered {
                        self.finalDelivered = true
                        self.onFinal?(text)
                    }
                } else {
                    self.onPartial?(text)
                }
            }
            if let error = error, !self.finalDelivered {
                self.onError?(error.localizedDescription)
            }
        }
        return true
    }

    /// Feed a PCM buffer captured off AVAudioEngine.inputNode. SFSpeech
    /// handles internal sample-rate conversion, so the buffer can be at the
    /// engine's native format — no AVAudioConverter setup required.
    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    /// Signal end-of-audio. The final callback fires shortly after.
    func finalize() {
        request?.endAudio()
    }

    /// Drop the session immediately. No further callbacks fire.
    func cancel() {
        task?.cancel()
        task = nil
        request = nil
    }

    /// One-time Speech permission prompt. Idempotent on subsequent calls.
    /// Completion lands on the main queue.
    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }
}
