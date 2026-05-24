import Foundation

/// Minimal Deepgram Listen v1 streaming client. Platform-neutral — used by
/// both the iOS MessageBox capture path and the macOS recorder window.
final class DeepgramSTT: NSObject, URLSessionWebSocketDelegate {
    private let apiKey: String
    private let sampleRate: Int
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var finals: [String] = []
    private var partial: String = ""
    private var didEmitFinal = false

    /// Concatenated finals + current partial. Fires whenever Deepgram sends a Results event.
    var onPartial: ((String) -> Void)?
    /// Concatenated finals only. Fires once after CloseStream/socket close.
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    init(apiKey: String, sampleRate: Int = 16000) {
        self.apiKey = apiKey
        self.sampleRate = sampleRate
        super.init()
    }

    func connect() {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "endpointing", value: "300"),
        ]
        guard let url = components.url else {
            onError?(NSError(domain: "DeepgramSTT", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"]))
            return
        }

        var request = URLRequest(url: url)
        request.addValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let cfg = URLSessionConfiguration.default
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: OperationQueue())
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()
    }

    func send(audio: Data) {
        guard let task = task else { return }
        task.send(.data(audio)) { err in
            if let err = err {
                print("Deepgram WS send error: \(err)")
            }
        }
    }

    /// Tell Deepgram we're done streaming audio. It will send any pending final
    /// transcript and then close the socket; flushFinal() resolves on either path.
    /// Named `finalizeStream` (not `finalize`) because NSObject already has
    /// a `finalize()` method we'd otherwise be overriding implicitly.
    func finalizeStream() {
        guard let task = task else {
            flushFinal()
            return
        }
        let close = "{\"type\":\"CloseStream\"}"
        task.send(.string(close)) { _ in }
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveLoop()
            case .failure(let err):
                if self.finals.isEmpty {
                    self.onError?(err)
                } else {
                    self.flushFinal()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text = text,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let type = json["type"] as? String
        switch type {
        case "Results":
            guard let channel = json["channel"] as? [String: Any],
                  let alternatives = channel["alternatives"] as? [[String: Any]],
                  let first = alternatives.first,
                  let transcript = first["transcript"] as? String else { return }
            let isFinal = (json["is_final"] as? Bool) ?? false
            if isFinal {
                if !transcript.isEmpty { finals.append(transcript) }
                partial = ""
            } else {
                partial = transcript
            }
            var combined = finals
            if !partial.isEmpty { combined.append(partial) }
            onPartial?(combined.joined(separator: " ").trimmingCharacters(in: .whitespaces))
        case "Metadata", "SpeechStarted", "UtteranceEnd":
            break
        default:
            break
        }
    }

    private func flushFinal() {
        guard !didEmitFinal else { return }
        didEmitFinal = true
        let combined = finals.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        onFinal?(combined)
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {}

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        flushFinal()
    }
}
