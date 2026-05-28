//
//  MessageBox.swift
//  Loop
//
//  Created by Ash Bhat on 11/2/24.
//
import UIKit
import AVFoundation
import Speech
import Network
import PhotosUI
import UniformTypeIdentifiers

protocol MessageBoxDelegate: AnyObject {
    func didSendMessageText(_ message: String)
    func stopSpeech()
}

enum MessageBoxState {
    case normal
    case recording
    case transcribing
}

class MessageBox: UIView {

    weak var delegate: MessageBoxDelegate?
    let emptyLabel = UILabel(frame: .zero)
    let containerView = UIView()
    let textView = MessageInputTextView()

    /// Max height for the input text view. Picked to fit ~6 lines of body
    /// text — enough that most messages don't need to scroll, but small
    /// enough that pasting a wall of text doesn't push the chat off-screen.
    fileprivate static let inputMaxHeight: CGFloat = 140
    let sendButton = UIButton()
    /// Paperclip button shown in the same slot as `sendButton` while the
    /// textfield is empty AND no attachment is staged. Tapping opens the
    /// camera / photo library / files action sheet.
    let attachButton = UIButton()
    let keyboardButton = UIButton()
    let micButton = UIButton()

    // Attachment chip (visible only when `pendingAttachment != nil`). Sits
    // above the input container so the user can preview / remove the staged
    // file before sending.
    let attachmentChipView = UIView()
    let attachmentThumbnailView = UIImageView()
    let attachmentNameLabel = UILabel()
    let attachmentRemoveButton = UIButton()
    /// Pinned to `containerView.topAnchor`. Constant flips between
    /// `0` (no chip) and a negative value (chip visible) — see
    /// `refreshAttachmentChip` below.
    private var attachmentChipBottomConstraint: NSLayoutConstraint?

    /// User-uploaded file staged for the next send. The MessagingVC pulls
    /// this from `didSendMessageText` and attaches it to the outgoing
    /// MessageStruct before clearing it. `didSet` keeps the chip + trailing
    /// button in sync without callers having to remember to refresh.
    var pendingAttachment: FileAttachment? {
        didSet {
            refreshAttachmentChip()
            refreshTrailingButton()
        }
    }

    // Recording UI elements
    let recordingContainerView = UIView()
    let waveformView = UIView()
    let recordingSendButton = UIButton()
    let transcribingLabel = UILabel()
    
    // Recording state
    var currentState: MessageBoxState = .normal
    var audioRecorder: AVAudioRecorder?
    var recordingTimer: Timer?
    /// Amplitude-reactive bars laid out across the waveform view. CALayers
    /// (not UIViews) so frame changes per timer tick stay cheap. Mirrors the
    /// Mac recorder bar's bar set in shape, density, and behavior.
    var waveformBars: [CALayer] = []
    /// Width that the bars were last laid out against. Rebuilt whenever the
    /// waveform view's bounds change (rotation, keyboard show/hide, etc.).
    private var waveformLayoutWidth: CGFloat = 0
    var recordingStartTime: Date?
    
    // Speech recognition
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Streaming STT (Deepgram) — used when DEEPGRAM_API_KEY is present in Info.plist
    // AND the device is online. Falls through to the AVAudioRecorder + SFSpeech path
    // when the key is missing, the WebSocket can't be reached, or we're offline.
    private var audioEngine: AVAudioEngine?
    private var deepgramSTT: DeepgramSTT?
    private var isStreamingSTT = false
    private var streamingAmplitude: Float = 0
    private var streamingFinalizeTimer: Timer?

    // Mirror of the mic buffer captured during streaming STT. If Deepgram fails or
    // times out we feed this file to SFSpeech instead of returning an empty result.
    private var streamingFallbackFile: AVAudioFile?
    private var streamingFallbackURL: URL?
    private var streamingDeepgramFailed = false

    // MARK: - Long-press-to-record
    /// Minimum hold duration before recording begins.
    private static let longPressThreshold: TimeInterval = 0.6
    /// True while the user is holding the mic button in long-press-to-record mode.
    private(set) var isLongPressRecording = false
    /// "Release to send" tooltip shown above the mic button during long-press recording.
    private let releaseToSendLabel = UILabel()

    private static var deepgramAPIKey: String? {
        return KeyStore.shared.value(for: .deepgram)
    }

    // MARK: - Reachability
    // Lives in SpeechPipeline/Reachability.swift now so AgentHarness and the
    // Mac app can share the same gate. Kept exposed here under the original
    // name for back-compat with existing call sites in this file.
    static var isOnline: Bool { Reachability.isOnline }

    // Keyboard state
    private var isKeyboardVisible = false
    
    init() {
        super.init(frame: .zero)
        setup()
    }
    
    func setup() {
        
        containerView.translatesAutoresizingMaskIntoConstraints = false
        recordingContainerView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(containerView)
        self.addSubview(recordingContainerView)
        
        // Mic button is outside the container, add to main view
        micButton.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(micButton)
        
        let views = [textView, sendButton, attachButton, keyboardButton, emptyLabel]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.containerView.addSubview(view)
        }

        // Attachment chip floats just above the input container. It's hidden
        // by default; `refreshAttachmentChip` toggles isHidden + the constraint
        // that drops the container down to make room.
        attachmentChipView.translatesAutoresizingMaskIntoConstraints = false
        attachmentChipView.isHidden = true
        self.addSubview(attachmentChipView)
        for v in [attachmentThumbnailView, attachmentNameLabel, attachmentRemoveButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            attachmentChipView.addSubview(v)
        }
        
        let recordingViews = [waveformView, recordingSendButton, transcribingLabel]
        for view in recordingViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.recordingContainerView.addSubview(view)
        }
        
        let chipBottom = attachmentChipView.bottomAnchor.constraint(equalTo: containerView.topAnchor, constant: -8)
        self.attachmentChipBottomConstraint = chipBottom

        NSLayoutConstraint.activate([
            // Mic button constraints - outside container, to the left, aligned to bottom
            micButton.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 15),
            micButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -3),
            micButton.widthAnchor.constraint(equalToConstant: 50),
            micButton.heightAnchor.constraint(equalToConstant: 50),

            // Attachment chip sits above containerView; pinned 8pt above its top
            // when visible, and constrained to a 0 height when hidden via the
            // height constraint below.
            attachmentChipView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 4),
            attachmentChipView.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -4),
            attachmentChipView.heightAnchor.constraint(equalToConstant: 48),
            chipBottom,

            attachmentThumbnailView.leadingAnchor.constraint(equalTo: attachmentChipView.leadingAnchor, constant: 8),
            attachmentThumbnailView.centerYAnchor.constraint(equalTo: attachmentChipView.centerYAnchor),
            attachmentThumbnailView.widthAnchor.constraint(equalToConstant: 36),
            attachmentThumbnailView.heightAnchor.constraint(equalToConstant: 36),

            attachmentNameLabel.leadingAnchor.constraint(equalTo: attachmentThumbnailView.trailingAnchor, constant: 8),
            attachmentNameLabel.centerYAnchor.constraint(equalTo: attachmentChipView.centerYAnchor),
            attachmentNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: attachmentRemoveButton.leadingAnchor, constant: -8),

            attachmentRemoveButton.trailingAnchor.constraint(equalTo: attachmentChipView.trailingAnchor, constant: -8),
            attachmentRemoveButton.centerYAnchor.constraint(equalTo: attachmentChipView.centerYAnchor),
            attachmentRemoveButton.widthAnchor.constraint(equalToConstant: 24),
            attachmentRemoveButton.heightAnchor.constraint(equalToConstant: 24),

            // Container view constraints - starts after mic button
            containerView.leadingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: 10),
            containerView.topAnchor.constraint(equalTo: self.topAnchor, constant: 15),
            containerView.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -15),
            containerView.bottomAnchor.constraint(equalTo: self.safeAreaLayoutGuide.bottomAnchor, constant: -15),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            
            // Recording container view constraints (initially hidden).
            // Min-height matches the normal input container so swapping in
            // and out keeps the bar at the same visual size.
            recordingContainerView.leadingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: 10),
            recordingContainerView.topAnchor.constraint(equalTo: self.topAnchor, constant: 15),
            recordingContainerView.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -15),
            recordingContainerView.bottomAnchor.constraint(equalTo: self.safeAreaLayoutGuide.bottomAnchor, constant: -15),
            recordingContainerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            
            // Normal UI constraints - text field and send button inside container
            textView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -10),
            textView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
            textView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            // Cap the input at ~6 lines of body text. Once content exceeds
            // this, `textViewDidChange` flips `isScrollEnabled` so the user
            // scrolls inside the bounded view instead of the input eating
            // the whole chat. See `MessageBox.inputMaxHeight`.
            textView.heightAnchor.constraint(lessThanOrEqualToConstant: MessageBox.inputMaxHeight),
            
            sendButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            sendButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10),
            sendButton.widthAnchor.constraint(equalToConstant: 40),
            sendButton.heightAnchor.constraint(equalToConstant: 40),

            // Attach button overlays the send button's slot — exactly one is
            // visible at a time (see `refreshTrailingButton`).
            attachButton.trailingAnchor.constraint(equalTo: sendButton.trailingAnchor),
            attachButton.bottomAnchor.constraint(equalTo: sendButton.bottomAnchor),
            attachButton.widthAnchor.constraint(equalToConstant: 40),
            attachButton.heightAnchor.constraint(equalToConstant: 40),

            emptyLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
            emptyLabel.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
            
            // Recording UI constraints. Slim vertical insets so the bars
            // fill almost the full height of the recording container —
            // matches the bigger visual presence the Mac waveform has
            // relative to its bar.
            waveformView.leadingAnchor.constraint(equalTo: recordingContainerView.leadingAnchor, constant: 10),
            waveformView.trailingAnchor.constraint(equalTo: recordingSendButton.leadingAnchor, constant: -5),
            waveformView.topAnchor.constraint(equalTo: recordingContainerView.topAnchor, constant: 3),
            waveformView.bottomAnchor.constraint(equalTo: recordingContainerView.bottomAnchor, constant: -3),
            
            recordingSendButton.trailingAnchor.constraint(equalTo: recordingContainerView.trailingAnchor, constant: -10),
            recordingSendButton.centerYAnchor.constraint(equalTo: recordingContainerView.centerYAnchor),
            recordingSendButton.widthAnchor.constraint(equalToConstant: 50),
            recordingSendButton.heightAnchor.constraint(equalToConstant: 50),
            
            transcribingLabel.centerXAnchor.constraint(equalTo: recordingContainerView.centerXAnchor),
            transcribingLabel.centerYAnchor.constraint(equalTo: recordingContainerView.centerYAnchor)
        ])
        
        keyboardButton.isHidden = true
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        micButton.setContentHuggingPriority(.required, for: .horizontal)
        


        textView.isScrollEnabled = false
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.delegate = self
        textView.onShiftReturn = { [weak self] in
            guard let self else { return }
            let hasText = !(self.textView.text ?? "").isEmpty
            let hasAttachment = self.pendingAttachment != nil
            guard hasText || hasAttachment else { return }
            self.sendButtonTapped()
        }
        textView.backgroundColor = UIColor.clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = .secondarySystemBackground
        // Container view styling - ChatGPT-like rounded container
        containerView.layer.cornerRadius = 25
        containerView.layer.cornerCurve = .continuous
        containerView.backgroundColor = UIColor.systemGray6
        containerView.layer.borderWidth = 0
        
        
        // Recording container view styling — matches the normal input
        // container's rounded fill, so swapping in/out feels like the same
        // surface gaining a waveform rather than swapping to a separate
        // bordered panel. Mirrors the Mac recorder bar, which keeps the
        // same backdrop in every state.
        recordingContainerView.layer.cornerRadius = 25
        recordingContainerView.layer.cornerCurve = .continuous
        recordingContainerView.layer.borderWidth = 0
        recordingContainerView.backgroundColor = UIColor.systemGray6
        recordingContainerView.isHidden = true
        recordingContainerView.clipsToBounds = true
        
        // Button setup - ChatGPT-like send button with up arrow
        sendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(font: UIFont.systemFont(ofSize: 18, weight: .semibold))), for: .normal)
        sendButton.tintColor = .secondaryLabel
        sendButton.backgroundColor = UIColor.tertiarySystemBackground
        sendButton.layer.cornerRadius = 20
        sendButton.addTarget(self, action: #selector(sendButtonTapped), for: .touchUpInside)

        // Attach button — paperclip in the same slot. Tinted to read as a
        // muted "secondary" affordance until tapped.
        attachButton.setImage(UIImage(systemName: "paperclip", withConfiguration: UIImage.SymbolConfiguration(font: UIFont.systemFont(ofSize: 18, weight: .regular))), for: .normal)
        attachButton.tintColor = .secondaryLabel
        attachButton.backgroundColor = UIColor.tertiarySystemBackground
        attachButton.layer.cornerRadius = 20
        attachButton.addTarget(self, action: #selector(attachButtonTapped), for: .touchUpInside)

        // Chip styling — pill-shaped capsule with a thumbnail, filename, and
        // an × button. Matches the visual weight of the input container.
        attachmentChipView.backgroundColor = UIColor.tertiarySystemBackground
        attachmentChipView.layer.cornerRadius = 12
        attachmentChipView.layer.cornerCurve = .continuous

        attachmentThumbnailView.contentMode = .scaleAspectFill
        attachmentThumbnailView.clipsToBounds = true
        attachmentThumbnailView.layer.cornerRadius = 6
        attachmentThumbnailView.backgroundColor = UIColor.systemFill
        attachmentThumbnailView.tintColor = .secondaryLabel

        attachmentNameLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        attachmentNameLabel.textColor = .label
        attachmentNameLabel.numberOfLines = 1
        attachmentNameLabel.lineBreakMode = .byTruncatingMiddle

        attachmentRemoveButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(font: UIFont.systemFont(ofSize: 22))), for: .normal)
        attachmentRemoveButton.tintColor = .tertiaryLabel
        attachmentRemoveButton.addTarget(self, action: #selector(attachmentRemoveTapped), for: .touchUpInside)
        
        keyboardButton.setImage(UIImage(systemName: "keyboard", withConfiguration: UIImage.SymbolConfiguration(font: UIFont.systemFont(ofSize: 25))), for: .normal)
        keyboardButton.tintColor = .secondaryLabel
        keyboardButton.addTarget(self, action: #selector(keyboardButtonTapped), for: .touchUpInside)
        
        // Mic button setup - ChatGPT-like separate button outside container
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(font: UIFont.systemFont(ofSize: 20))), for: .normal)
        micButton.tintColor = .secondaryLabel
        micButton.backgroundColor = UIColor.systemGray6
        micButton.layer.cornerRadius = 25
        micButton.layer.borderWidth = 0
        let micTapGesture = UITapGestureRecognizer(target: self, action: #selector(micButtonTapped))
        let micLongPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleMicLongPress(_:)))
        micLongPressGesture.minimumPressDuration = MessageBox.longPressThreshold
        micLongPressGesture.allowableMovement = 50
        micTapGesture.require(toFail: micLongPressGesture)
        micButton.addGestureRecognizer(micTapGesture)
        micButton.addGestureRecognizer(micLongPressGesture)
        
        // Recording UI setup
        recordingSendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(font: UIFont.systemFont(ofSize: 22))), for: .normal)
        recordingSendButton.tintColor = .white
        recordingSendButton.backgroundColor = UIColor.systemBlue
        recordingSendButton.layer.cornerRadius = 25
        recordingSendButton.addTarget(self, action: #selector(recordingSendButtonTapped), for: .touchUpInside)

        // Waveform view is now just a layout slot — the bars themselves are
        // CALayer sublayers added on demand once the slot has a real width.
        // No background or corner styling so it blends with the container.
        self.waveformView.backgroundColor = .clear
        self.waveformView.layer.cornerRadius = 0
        self.waveformView.clipsToBounds = false

        // The bootstrap setup that used to happen here (asyncAfter 1s) was a
        // workaround for not knowing the layout width upfront. We now rebuild
        // lazily once the recording state actually surfaces — see
        // `rebuildWaveformBarsIfNeeded`.
        
        // Transcribing label setup — `.secondaryLabel` reads as a muted
        // placeholder on the gray container, matching the Mac recorder's
        // "transcribing…" treatment.
        transcribingLabel.text = "transcribing…"
        transcribingLabel.textColor = .secondaryLabel
        transcribingLabel.font = UIFont.preferredFont(forTextStyle: .body)
        transcribingLabel.isHidden = true
        
        emptyLabel.text = "Ask anything"
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = UIFont.preferredFont(forTextStyle: .body)

        // "Release to send" label — hidden by default, shown during long-press recording.
        releaseToSendLabel.text = "Release to send"
        releaseToSendLabel.textColor = .secondaryLabel
        releaseToSendLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        releaseToSendLabel.textAlignment = .center
        releaseToSendLabel.isHidden = true
        releaseToSendLabel.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(releaseToSendLabel)
        NSLayoutConstraint.activate([
            releaseToSendLabel.centerXAnchor.constraint(equalTo: micButton.centerXAnchor),
            releaseToSendLabel.bottomAnchor.constraint(equalTo: micButton.topAnchor, constant: -4)
        ])

        // Initial state: nothing typed, nothing staged → paperclip showing.
        refreshTrailingButton()
        refreshAttachmentChip()

        // Setup keyboard notifications
        setupKeyboardNotifications()
    }
    
    private func setupKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }
    
    @objc private func keyboardWillShow() {
        // Only update if our textView is the first responder
        if textView.isFirstResponder {
            isKeyboardVisible = true
            updateMicButtonAppearance()
        }
    }
    
    @objc private func keyboardWillHide() {
        // Reset to mic icon when keyboard hides
        isKeyboardVisible = false
        updateMicButtonAppearance()
    }
    
    private func updateMicButtonAppearance() {
        // Don't update if recording - recording state takes precedence
        if currentState == .recording || isLongPressRecording {
            return
        }
        
        if isKeyboardVisible {
            // Show keyboard dismiss icon
            micButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down", withConfiguration: UIImage.SymbolConfiguration(font: UIFont.systemFont(ofSize: 20))), for: .normal)
            micButton.backgroundColor = UIColor.systemGray6
        } else {
            // Show mic icon
            micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(font: UIFont.systemFont(ofSize: 20))), for: .normal)
            micButton.backgroundColor = UIColor.systemGray6
        }
        // Keep the button styled consistently
        micButton.layer.cornerRadius = 25
        micButton.tintColor = .secondaryLabel
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc func keyboardButtonTapped() {
        if textView.isFirstResponder {
            self.textView.resignFirstResponder()
        }
        else {
            self.textView.becomeFirstResponder()
        }
    }
    
    @objc func micButtonTapped() {
        // If recording, stop recording. Ending recording also cuts any
        // in-progress TTS — the user is signalling "stop, listen to me".
        if currentState == .recording {
            delegate?.stopSpeech()
            stopRecording()
            returnToNormalState()
            return
        }

        if isKeyboardVisible && textView.isFirstResponder {
            // This tap is acting purely as a keyboard-dismiss button — it's
            // the same physical button as the mic, just a different icon
            // while the keyboard is up. Dismiss only; never touch audio here
            // (otherwise lowering the keyboard would also kill TTS playback).
            textView.resignFirstResponder()
        } else {
            // Start recording — cut TTS first so we don't capture the
            // assistant talking over the user.
            delegate?.stopSpeech()
            requestMicrophonePermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startRecording()
                    } else {
                        // Handle permission denied
                        print("Microphone permission denied")
                    }
                }
            }
        }
    }
    
    
    @objc func recordingSendButtonTapped() {
        let recordingDuration = Date().timeIntervalSince(recordingStartTime ?? Date())

        // Ensure minimum recording duration
        if recordingDuration < 0.5 {
            print("Recording too short (\(recordingDuration)s), please record for at least 0.5 seconds")
            if isStreamingSTT { teardownStreaming() }
            returnToNormalState()
            return
        }

        if isStreamingSTT {
            finalizeStreamingRecording()
            return
        }

        stopRecording()
        startTranscription()
    }
    
    @objc func sendButtonTapped() {
        self.delegate?.didSendMessageText(self.textView.text)
        self.textView.text = ""
        self.textViewDidChange(self.textView)
    }
    
    required init?(coder: NSCoder) {
        fatalError()
    }
    
    // MARK: - Waveform Setup
    //
    // Bars are CALayer sublayers of `waveformView.layer`. Layout is recomputed
    // on demand by `rebuildWaveformBarsIfNeeded()` (which the recording
    // start path calls after forcing a layout pass), and a CATransaction with
    // disabled actions inside `updateWaveform` keeps each timer tick from
    // animating implicitly.
    //
    // The math here is intentionally identical to RecorderWindowController
    // on the Mac so both surfaces feel like the same instrument.

    private static let waveformBarWidth: CGFloat = 2
    private static let waveformBarSpacing: CGFloat = 3
    private static let waveformBarBaseHeight: CGFloat = 4
    /// Top-of-range extra height on top of `waveformBarBaseHeight`. Cranked
    /// well past the Mac value (16): iPhone mics report lower RMS for the
    /// same speaking volume, AND the iOS recording container is taller than
    /// the Mac bar so the bars have room to grow without overflowing.
    /// Bars peak at 4 + 36 = 40pt against a ~44pt waveform slot.
    private static let waveformBarMaxExtra: CGFloat = 36

    private func rebuildWaveformBarsIfNeeded() {
        waveformView.layoutIfNeeded()
        let width = waveformView.bounds.width
        // Skip if we already built bars at this width — the bar count stays
        // stable across re-entries to the recording state.
        if !waveformBars.isEmpty, abs(width - waveformLayoutWidth) < 0.5 { return }

        waveformBars.forEach { $0.removeFromSuperlayer() }
        waveformBars.removeAll()

        guard width > 0 else { return }
        waveformLayoutWidth = width

        let height = waveformView.bounds.height
        let yMid = height / 2
        let pitch = Self.waveformBarWidth + Self.waveformBarSpacing
        // Floor instead of round so the right edge never overflows the
        // container — same approach the Mac uses.
        let total = max(20, Int(width / pitch))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<total {
            let bar = CALayer()
            bar.backgroundColor = UIColor.label.withAlphaComponent(0.6).cgColor
            bar.frame = CGRect(
                x: CGFloat(i) * pitch,
                y: yMid - Self.waveformBarBaseHeight / 2,
                width: Self.waveformBarWidth,
                height: Self.waveformBarBaseHeight
            )
            bar.cornerRadius = 1
            waveformView.layer.addSublayer(bar)
            waveformBars.append(bar)
        }
        CATransaction.commit()
    }
    
    // MARK: - State Management
    
    private func switchToRecordingState() {
        currentState = .recording
        containerView.isHidden = true
        recordingContainerView.isHidden = false
        waveformView.isHidden = false
        recordingSendButton.isHidden = false
        transcribingLabel.isHidden = true

        // Transform mic button into stop button
        micButton.setImage(UIImage(systemName: "stop.fill", withConfiguration: UIImage.SymbolConfiguration(font: UIFont.systemFont(ofSize: 22))), for: .normal)
        micButton.tintColor = .white
        micButton.backgroundColor = UIColor.systemRed
        micButton.layer.cornerRadius = 25

        VoiceLoopCoordinator.shared.setState(.recording)
        EarconPlayer.shared.play(.listenStart)

        if isLongPressRecording {
            startMicPulseAnimation()
            releaseToSendLabel.isHidden = false
        }
    }

    private func switchToTranscribingState() {
        currentState = .transcribing
        waveformView.isHidden = true
        recordingSendButton.isHidden = true
        // Re-assert the canonical text — the Deepgram partial handler may
        // have overwritten this with `listening…` or live partials during
        // the streaming recording phase.
        transcribingLabel.text = "transcribing…"
        transcribingLabel.isHidden = false

        VoiceLoopCoordinator.shared.setState(.transcribing)
        // User committed to sending whatever they just said — same auditory
        // cue the Mac plays in VoiceLoopCoordinator.sendUserText.
        EarconPlayer.shared.play(.listenSend)

        // Restore mic button appearance during transcription
        updateMicButtonAppearance()

        // No background changes here — the container stays its resting
        // systemGray6 fill and the centered "transcribing…" label carries
        // the state, matching how the Mac recorder bar handles this phase.
    }
    
    private func returnToNormalState() {
        currentState = .normal
        containerView.isHidden = false
        recordingContainerView.isHidden = true
        waveformView.isHidden = true
        recordingSendButton.isHidden = true
        transcribingLabel.isHidden = true

        // Clean up long-press recording state
        isLongPressRecording = false
        stopMicPulseAnimation()
        releaseToSendLabel.isHidden = true

        // Reset waveform bars back to their idle baseline. The container's
        // fill no longer changes during recording/transcribing, so there's
        // nothing else to undo here.
        resetWaveform()

        // Restore mic button appearance
        updateMicButtonAppearance()

        // Drop the coordinator back to .idle ONLY if we're still in a
        // voice-flow state. By the time we arrive here on a successful turn
        // the delegate has already pushed the transcript into MessagingVC
        // and the coordinator is in .thinking — clobbering that to .idle
        // here would break the avatar's thinking animation.
        let coord = VoiceLoopCoordinator.shared
        if coord.state == .recording || coord.state == .transcribing {
            coord.setState(.idle)
        }
    }
    
    // MARK: - Permission Handling
    
    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            completion(granted)
        }
    }
    
    // MARK: - Recording
    
    private func startRecording() {
        // Check microphone permission first
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            print("Microphone permission not granted")
            return
        }

        // STT engine selection. The user can pin either provider in
        // Settings ▸ Model ▸ STT; `auto` reproduces the historical
        // "prefer Deepgram when online with a key" heuristic.
        //
        //   .deepgram → try Deepgram-streaming; on setup failure fall
        //               through to the AVAudioRecorder + SFSpeech path
        //               so the recording still succeeds.
        //   .apple    → skip Deepgram entirely; record to a file via
        //               AVAudioRecorder and run SFSpeech against it on
        //               finalize. No network, no API key.
        //   .auto     → Deepgram when its key is configured and the device
        //               is online; otherwise the AVAudioRecorder + SFSpeech
        //               fallback, same as before.
        let sttPick = STTProviderStore.current
        let shouldTryDeepgram: Bool
        switch sttPick {
        case .deepgram:
            shouldTryDeepgram = (MessageBox.deepgramAPIKey != nil)
        case .apple:
            shouldTryDeepgram = false
        case .auto:
            shouldTryDeepgram = (MessageBox.deepgramAPIKey != nil && MessageBox.isOnline)
        }
        if shouldTryDeepgram, beginStreamingRecording() {
            return
        }

        // Setup audio session to allow background audio to continue playing
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // Use playAndRecord category with mixWithOthers option to allow background audio
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetooth])
            try audioSession.setActive(true)
            print("Audio session setup successful with playAndRecord + mixWithOthers")
        } catch {
            // Fallback to default mode if measurement fails
            do {
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth])
                try audioSession.setActive(true)
                print("Using fallback audio session mode with playAndRecord + mixWithOthers")
            } catch {
                print("Failed to setup audio session: \(error)")
                return
            }
        }
        
        // Setup recording URL
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent("recording.m4a")
        
        print("Documents directory: \(documentsPath.path)")
        print("Audio file path: \(audioFilename.path)")
        
        // Ensure documents directory exists
        if !FileManager.default.fileExists(atPath: documentsPath.path) {
            print("Documents directory does not exist!")
            return
        }
        
        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: audioFilename.path) {
            do {
                try FileManager.default.removeItem(at: audioFilename)
                print("Removed existing recording file")
            } catch {
                print("Failed to remove existing file: \(error)")
            }
        }
        
        // Setup recording settings optimized for speech recognition
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100, // Use standard sample rate for better compatibility
            AVNumberOfChannelsKey: 1, // Mono is better for speech recognition
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            print("Creating audio recorder with URL: \(audioFilename.path)")
            print("Recording settings: \(settings)")
            
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            
            print("Preparing to record...")
            let prepared = audioRecorder?.prepareToRecord() ?? false
            if !prepared {
                print("Failed to prepare recording")
                return
            }
            
            print("Starting recording...")
            let success = audioRecorder?.record() ?? false
            if success {
                print("Recording started successfully at: \(audioFilename.path)")
                recordingStartTime = Date()
                switchToRecordingState()
                startWaveformAnimation()
            } else {
                print("Failed to start recording - record() returned false")
                print("Audio recorder state: \(audioRecorder?.isRecording ?? false)")
                print("Audio recorder prepared: \(audioRecorder?.prepareToRecord() ?? false)")
            }
            
        } catch {
            print("Could not start recording: \(error)")
            print("Error details: \(error.localizedDescription)")
        }
    }
    
    private func stopRecording() {
        // Streaming path teardown runs through teardownStreaming() instead.
        if isStreamingSTT {
            teardownStreaming()
            return
        }
        guard let recorder = audioRecorder else { return }
        
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        recorder.stop()
        
        // Get recording duration for debugging
        let recordingDuration = Date().timeIntervalSince(recordingStartTime ?? Date())
        print("Recording stopped. Duration: \(recordingDuration)s")
        
        audioRecorder = nil
        
        // Deactivate audio session with options to allow other audio to continue
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }
    
    // MARK: - Waveform Animation
    
    private func startWaveformAnimation() {
        // Make sure the bars exist + match the current container width before
        // the first timer tick — otherwise the first frame would compute
        // against an empty array.
        rebuildWaveformBarsIfNeeded()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateWaveform()
        }
    }
    
    private func updateWaveform() {
        let normalizedPower: Float
        if isStreamingSTT {
            // streamingAmplitude is RMS in [0, 1] of the live engine tap.
            // Boosted heavily so normal-tone speech (RMS ~0.02–0.05) lands
            // around 0.4–0.7 of the bar range rather than barely registering.
            let boosted: Float = streamingAmplitude * Float(14.0)
            normalizedPower = min(Float(1.0), max(Float(0.0), boosted))
        } else {
            guard let recorder = audioRecorder else { return }
            recorder.updateMeters()
            let averagePower = recorder.averagePower(forChannel: 0)
            // Treat -55 dB as the practical noise floor instead of -60; on
            // iPhone the meter tends to bottom out a few dB above the
            // theoretical minimum so the wider range was wasted.
            normalizedPower = max(0, min(1, (averagePower + 55) / 55))
        }

        // Drive the nav-bar AvatarView's listening animation off the same
        // value as the waveform bars — already-throttled to 10Hz here.
        VoiceLoopCoordinator.shared.publishAmplitude(normalizedPower)

        // Re-resolve bars in case the container width changed since
        // recording started (rotation, keyboard, etc.).
        rebuildWaveformBarsIfNeeded()

        // Square-root curve lifts quiet speech into the visible band — both
        // mic paths bottom out at low linear values, so a perceptual curve
        // is what makes "speaking at a normal tone" actually move the bars.
        let amplitude = sqrt(min(Float(1.0), max(Float(0.0), normalizedPower)))
        let yMid = waveformView.bounds.height / 2
        let now = Float(Date().timeIntervalSinceReferenceDate)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in waveformBars.enumerated() {
            // Sin phase staggered across bars gives the surface a "listening"
            // shimmer even at low amplitudes — same formula the Mac uses.
            let phase = Float(i) * 0.13 + now
            let wave = (sin(phase) + 1) / 2
            let scaled = min(Float(1.0), max(Float(0.05), amplitude * (0.4 + wave)))
            let h = Self.waveformBarBaseHeight + Self.waveformBarMaxExtra * CGFloat(scaled)
            bar.frame = CGRect(x: bar.frame.origin.x,
                               y: yMid - h / 2,
                               width: Self.waveformBarWidth,
                               height: h)
            // Wider alpha swing (0.5 → 1.0) gives an extra visual signal of
            // loudness on top of the height change.
            bar.backgroundColor = UIColor.label.withAlphaComponent(0.5 + 0.5 * CGFloat(amplitude)).cgColor
        }
        CATransaction.commit()
    }

    private func resetWaveform() {
        let yMid = waveformView.bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in waveformBars {
            bar.frame = CGRect(x: bar.frame.origin.x,
                               y: yMid - Self.waveformBarBaseHeight / 2,
                               width: Self.waveformBarWidth,
                               height: Self.waveformBarBaseHeight)
            bar.backgroundColor = UIColor.label.withAlphaComponent(0.6).cgColor
        }
        CATransaction.commit()
    }
    
    // MARK: - Transcription
    
    private func startTranscription() {
        switchToTranscribingState()
        
        guard let audioURL = getRecordingURL() else {
            print("No recording URL found")
            returnToNormalState()
            return
        }
        
        requestSpeechRecognitionPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.transcribeAudio(url: audioURL)
                } else {
                    print("Speech recognition permission denied")
                    self?.returnToNormalState()
                }
            }
        }
    }
    
    private func requestSpeechRecognitionPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status == .authorized)
        }
    }
    
    private func transcribeAudio(url: URL) {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("Speech recognizer not available")
            returnToNormalState()
            return
        }
        
        // Check if audio file exists and has content
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Audio file does not exist at path: \(url.path)")
            returnToNormalState()
            return
        }
        
        // Get file size to check if it's not empty
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int64, fileSize < 1000 {
                print("Audio file is too small (\(fileSize) bytes), likely no speech recorded")
                returnToNormalState()
                return
            }
        } catch {
            print("Could not get file attributes: \(error)")
        }
        
        // Use file-based recognition instead of buffer-based for better reliability
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // Apple's cloud recognizer hangs without network; force on-device when offline.
        if !MessageBox.isOnline {
            guard recognizer.supportsOnDeviceRecognition else {
                print("On-device recognition unsupported for this locale; offline transcription unavailable")
                transcribingLabel.text = "offline transcription unavailable"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.returnToNormalState()
                }
                return
            }
            request.requiresOnDeviceRecognition = true
        } else {
            request.requiresOnDeviceRecognition = false
        }
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result = result {
                    let transcribedText = result.bestTranscription.formattedString
                    print("Transcription successful: '\(transcribedText)'")
                    
                    if !transcribedText.isEmpty {
                        self?.delegate?.didSendMessageText(transcribedText)
                    } else {
                        print("Transcription returned empty string")
                    }
                    self?.returnToNormalState()
                } else if let error = error {
                    print("Transcription error: \(error)")
                    print("Error details: \(error.localizedDescription)")
                    
                    // Try to provide a more helpful error message
                    if error.localizedDescription.contains("No speech detected") {
                        print("No speech was detected in the recording. Please try speaking louder or closer to the microphone.")
                    }
                    
                    self?.returnToNormalState()
                }
            }
        }
    }
    
    private func getRecordingURL() -> URL? {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("recording.m4a")
    }
    
    // MARK: - Public Voice Control Methods
    
    func startVoiceRecording() {
        print("MessageBox: Starting voice recording")
        // Mirror micButtonTapped: any in-progress TTS should yield to a fresh
        // record. Same intent whether the trigger is a tap or the intel://mic
        // URL scheme.
        delegate?.stopSpeech()
        requestMicrophonePermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.startRecording()
                } else {
                    print("Microphone permission denied")
                }
            }
        }
    }
    
    func sendCurrentRecording() {
        print("MessageBox: Sending current recording")
        if currentState == .recording {
            recordingSendButtonTapped()
        }
    }
    
    func stopVoiceRecording() {
        print("MessageBox: Stopping voice recording")
        if currentState == .recording {
            stopRecording()
            returnToNormalState()
        }
    }

    // MARK: - Long-Press-to-Record

    @objc private func handleMicLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            if textView.isFirstResponder {
                textView.resignFirstResponder()
            }
            delegate?.stopSpeech()

            guard AVAudioSession.sharedInstance().recordPermission == .granted else {
                requestMicrophonePermission { _ in }
                return
            }

            isLongPressRecording = true
            let feedback = UIImpactFeedbackGenerator(style: .heavy)
            feedback.impactOccurred()
            startRecording()

        case .ended:
            guard isLongPressRecording else { return }
            finishLongPressRecording()

        case .cancelled, .failed:
            guard isLongPressRecording else { return }
            cancelLongPressRecording()

        default:
            break
        }
    }

    private func finishLongPressRecording() {
        stopMicPulseAnimation()
        releaseToSendLabel.isHidden = true
        isLongPressRecording = false
        guard currentState == .recording else { return }
        recordingSendButtonTapped()
    }

    private func cancelLongPressRecording() {
        stopMicPulseAnimation()
        releaseToSendLabel.isHidden = true
        isLongPressRecording = false
        if currentState == .recording {
            if isStreamingSTT { teardownStreaming() }
            else { stopRecording() }
            returnToNormalState()
        }
    }

    private func startMicPulseAnimation() {
        UIView.animate(withDuration: 0.6,
                       delay: 0,
                       options: [.autoreverse, .repeat, .allowUserInteraction, .curveEaseInOut]) {
            self.micButton.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        }
    }

    private func stopMicPulseAnimation() {
        micButton.layer.removeAllAnimations()
        micButton.transform = .identity
    }

}

extension MessageBox: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        emptyLabel.isHidden = textView.text.count > 0
        refreshTrailingButton()
        updateInputScrollState()
    }

    /// Toggle the text view between "grow to fit content" (no scroll,
    /// intrinsic content size drives height) and "fixed max with internal
    /// scrolling" once content overflows `inputMaxHeight`. Without this,
    /// `isScrollEnabled = false` would keep growing forever and the input
    /// would eat the chat area on long pastes.
    fileprivate func updateInputScrollState() {
        let target = textView.sizeThatFits(CGSize(width: textView.bounds.width,
                                                   height: .greatestFiniteMagnitude)).height
        let shouldScroll = target >= MessageBox.inputMaxHeight
        if textView.isScrollEnabled != shouldScroll {
            textView.isScrollEnabled = shouldScroll
            // When flipping back to non-scrolling, force a layout pass so
            // intrinsic content size recomputes immediately; otherwise the
            // input briefly stays at the capped height after a delete.
            textView.invalidateIntrinsicContentSize()
        }
    }
}

extension MessageBox {
    /// Picks which of `sendButton` / `attachButton` is visible based on
    /// whether there's anything ready to send (typed text OR a staged
    /// attachment). Called from `textViewDidChange`, from `pendingAttachment`'s
    /// didSet, and after a send to reset the state.
    fileprivate func refreshTrailingButton() {
        let hasText = (textView.text?.count ?? 0) > 0
        let hasAttachment = pendingAttachment != nil
        let showSend = hasText || hasAttachment

        sendButton.isHidden = !showSend
        attachButton.isHidden = showSend

        sendButton.tintColor = showSend ? .white : .secondaryLabel
        sendButton.backgroundColor = showSend ? .systemBlue : UIColor.tertiarySystemBackground
        sendButton.isEnabled = showSend
    }

    /// Shows/hides the chip + adjusts its image and label off the current
    /// `pendingAttachment`. Loads the image preview lazily off the main
    /// thread so a large drop / large camera capture doesn't stall the UI.
    fileprivate func refreshAttachmentChip() {
        guard let attachment = pendingAttachment else {
            attachmentChipView.isHidden = true
            attachmentThumbnailView.image = nil
            attachmentNameLabel.text = nil
            // Collapse the gap above the input container when nothing's staged.
            attachmentChipBottomConstraint?.constant = 8
            return
        }

        attachmentChipView.isHidden = false
        attachmentNameLabel.text = attachment.fileName
        attachmentChipBottomConstraint?.constant = -8

        switch attachment.kind {
        case .pdf:
            attachmentThumbnailView.image = UIImage(systemName: "doc.richtext")
            attachmentThumbnailView.contentMode = .center
            attachmentThumbnailView.backgroundColor = UIColor.systemFill
        case .image:
            attachmentThumbnailView.image = UIImage(systemName: "photo")
            attachmentThumbnailView.contentMode = .center
            let url = attachment.fileURL
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let data = try? Data(contentsOf: url),
                      let img = UIImage(data: data) else { return }
                DispatchQueue.main.async {
                    guard let self = self,
                          self.pendingAttachment?.id == attachment.id else { return }
                    self.attachmentThumbnailView.image = img
                    self.attachmentThumbnailView.contentMode = .scaleAspectFill
                }
            }
        case .markdown:
            attachmentThumbnailView.image = UIImage(systemName: "doc.text")
            attachmentThumbnailView.contentMode = .center
            attachmentThumbnailView.backgroundColor = UIColor.systemFill
        case .text:
            attachmentThumbnailView.image = UIImage(systemName: "chevron.left.forwardslash.chevron.right")
            attachmentThumbnailView.contentMode = .center
            attachmentThumbnailView.backgroundColor = UIColor.systemFill
        case .generic:
            attachmentThumbnailView.image = UIImage(systemName: "doc")
            attachmentThumbnailView.contentMode = .center
            attachmentThumbnailView.backgroundColor = UIColor.systemFill
        }
    }

    @objc fileprivate func attachmentRemoveTapped() {
        pendingAttachment = nil
    }
}

extension MessageBox: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Recording failed")
            returnToNormalState()
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("Recording encode error: \(error)")
            returnToNormalState()
        }
    }
}

// MARK: - Streaming STT (Deepgram Nova-3 over WebSocket)

extension MessageBox {

    /// Brings up an AVAudioEngine tap and a Deepgram WebSocket. Returns true if
    /// the streaming path took ownership of the recording UI; false on any
    /// setup failure (in which case the caller falls back to AVAudioRecorder).
    fileprivate func beginStreamingRecording() -> Bool {
        guard let apiKey = MessageBox.deepgramAPIKey else { return false }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetooth])
            try audioSession.setActive(true)
        } catch {
            do {
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth])
                try audioSession.setActive(true)
            } catch {
                print("Streaming STT: audio session failed (\(error)) — falling back to AVAudioRecorder")
                return false
            }
        }

        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16000,
                                               channels: 1,
                                               interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            print("Streaming STT: audio format / converter setup failed — falling back")
            return false
        }

        let stt = DeepgramSTT(apiKey: apiKey)
        self.deepgramSTT = stt
        self.audioEngine = engine
        self.isStreamingSTT = true
        self.streamingDeepgramFailed = false

        // Open a fresh fallback file in the input format. Best-effort — if we can't
        // open it, streaming proceeds without an SFSpeech fallback for this turn.
        let fallbackURL = FileManager.default.temporaryDirectory.appendingPathComponent("streaming_fallback.caf")
        try? FileManager.default.removeItem(at: fallbackURL)
        if let file = try? AVAudioFile(forWriting: fallbackURL, settings: inputFormat.settings) {
            self.streamingFallbackFile = file
            self.streamingFallbackURL = fallbackURL
        } else {
            print("Streaming STT: failed to open fallback file at \(fallbackURL.path); SFSpeech fallback disabled for this turn")
            self.streamingFallbackFile = nil
            self.streamingFallbackURL = nil
        }

        stt.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self, self.isStreamingSTT else { return }
                self.transcribingLabel.text = text.isEmpty ? "listening…" : text
            }
        }
        stt.onFinal = { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Only resolve once the user has tapped send. If the socket
                // closed mid-recording for some other reason, we drop the
                // partial final and let the finalize timeout decide.
                if self.currentState == .transcribing {
                    self.completeStreamingWithText(text)
                }
            }
        }
        stt.onError = { [weak self] err in
            print("Deepgram STT error: \(err) — will fall back to SFSpeech on the captured audio")
            DispatchQueue.main.async {
                guard let self = self, self.isStreamingSTT else { return }
                self.streamingDeepgramFailed = true
                // If the user has already tapped send, switch to SFSpeech now.
                // While still .recording we keep capturing into the fallback file
                // and switch on send (or on the finalize timeout).
                if self.currentState == .transcribing {
                    self.fallbackToSFSpeechOnFailure()
                }
            }
        }

        stt.connect()

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Mirror the unconverted buffer to the SFSpeech fallback file. Best-effort.
            // Keep doing this even after Deepgram dies so the captured audio stays complete.
            if let file = self.streamingFallbackFile {
                do { try file.write(from: buffer) } catch { /* best-effort */ }
            }

            // Live RMS for the waveform (computed on the input buffer at native rate).
            if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                let n = Int(buffer.frameLength)
                var sumSq: Float = 0
                for i in 0..<n {
                    let v = channel[i]
                    sumSq += v * v
                }
                self.streamingAmplitude = sqrt(sumSq / Float(n))
            }

            // Don't keep pumping bytes into a dead WS — but the file write above still runs.
            guard let stt = self.deepgramSTT, !self.streamingDeepgramFailed else { return }

            // Convert to int16 mono @ 16 kHz for Deepgram. Capacity has +1 slack
            // because non-integer sample-rate ratios can produce a tail sample.
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard outCapacity > 0,
                  let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
                return
            }

            var providedInput = false
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError) { _, statusOut in
                if providedInput {
                    statusOut.pointee = .noDataNow
                    return nil
                }
                providedInput = true
                statusOut.pointee = .haveData
                return buffer
            }
            if status == .error || outBuffer.frameLength == 0 {
                if let convError = convError {
                    print("Streaming STT: convert error \(convError)")
                }
                return
            }

            if let int16 = outBuffer.int16ChannelData?[0] {
                let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
                let data = Data(bytes: int16, count: byteCount)
                stt.send(audio: data)
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            print("Streaming STT: engine.start() failed (\(error)) — falling back to AVAudioRecorder")
            teardownStreaming()
            return false
        }

        recordingStartTime = Date()
        switchToRecordingState()
        // Reuse the legacy waveform timer; updateWaveform branches on isStreamingSTT
        // and reads streamingAmplitude instead of the AVAudioRecorder meter.
        startWaveformAnimation()
        return true
    }

    /// User tapped send. Stop capture, ask Deepgram to flush its final, then
    /// hand the resulting text to the delegate. On timeout or prior WS error
    /// we fall back to SFSpeech against the captured audio.
    fileprivate func finalizeStreamingRecording() {
        guard isStreamingSTT else { return }

        // Stop the audio engine immediately — no point sending more frames.
        if let engine = audioEngine, engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        recordingTimer?.invalidate()
        recordingTimer = nil

        switchToTranscribingState()

        // If the WS already errored during recording, skip the round-trip and go
        // straight to SFSpeech on the captured audio.
        if streamingDeepgramFailed {
            fallbackToSFSpeechOnFailure()
            return
        }

        deepgramSTT?.finalizeStream()

        streamingFinalizeTimer?.invalidate()
        streamingFinalizeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.isStreamingSTT else { return }
                print("Streaming STT: finalize timed out — falling back to SFSpeech on the captured audio")
                self.fallbackToSFSpeechOnFailure()
            }
        }
    }

    /// Tear down streaming and run SFSpeech on the audio we captured in parallel.
    /// Used on Deepgram WS error or finalize timeout.
    fileprivate func fallbackToSFSpeechOnFailure() {
        guard isStreamingSTT else { return }

        if let engine = audioEngine, engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        // Capture the URL and release the file object so its data is flushed
        // before SFSpeech opens it.
        let fallbackURL = streamingFallbackURL
        streamingFallbackFile = nil
        streamingFallbackURL = nil

        streamingFinalizeTimer?.invalidate()
        streamingFinalizeTimer = nil
        deepgramSTT?.disconnect()
        deepgramSTT = nil
        audioEngine = nil
        isStreamingSTT = false
        streamingAmplitude = 0
        streamingDeepgramFailed = false

        if currentState != .transcribing {
            switchToTranscribingState()
        }

        guard let url = fallbackURL,
              FileManager.default.fileExists(atPath: url.path) else {
            print("Fallback STT: no captured audio available")
            returnToNormalState()
            return
        }

        requestSpeechRecognitionPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.transcribeAudio(url: url)
                } else {
                    print("Fallback STT: speech recognition permission denied")
                    self?.returnToNormalState()
                }
            }
        }
    }

    fileprivate func completeStreamingWithText(_ text: String) {
        guard isStreamingSTT else { return }
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        teardownStreaming()
        if !final.isEmpty {
            delegate?.didSendMessageText(final)
        }
        returnToNormalState()
    }

    fileprivate func teardownStreaming() {
        isStreamingSTT = false
        streamingAmplitude = 0
        streamingDeepgramFailed = false
        streamingFinalizeTimer?.invalidate()
        streamingFinalizeTimer = nil

        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        audioEngine = nil

        streamingFallbackFile = nil
        if let url = streamingFallbackURL {
            try? FileManager.default.removeItem(at: url)
        }
        streamingFallbackURL = nil

        deepgramSTT?.disconnect()
        deepgramSTT = nil

        recordingTimer?.invalidate()
        recordingTimer = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // best-effort
        }
    }

}

// DeepgramSTT moved to SpeechPipeline/DeepgramSTT.swift — shared between iOS
// and the Mac AppKit recorder.

// MARK: - Attachment pickers
//
// Three entry points wired through one action sheet: camera (UIImagePicker),
// photo library (PHPicker), and files (UIDocumentPicker). All three save the
// chosen bytes via `AttachmentStore` and then assign to `pendingAttachment`,
// which kicks the chip + trailing button into the "ready to send" state.

extension MessageBox: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    @objc fileprivate func attachButtonTapped() {
        guard let presenter = self.parentViewController else { return }

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        // Camera is only offered on real devices that actually have one.
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            sheet.addAction(UIAlertAction(title: "Camera", style: .default) { [weak self] _ in
                self?.presentCameraPicker()
            })
        }
        sheet.addAction(UIAlertAction(title: "Photo Library", style: .default) { [weak self] _ in
            self?.presentPhotoLibraryPicker()
        })
        sheet.addAction(UIAlertAction(title: "Files", style: .default) { [weak self] _ in
            self?.presentDocumentPicker()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // iPad needs an anchor to avoid an exception when presenting an action sheet.
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = attachButton
            pop.sourceRect = attachButton.bounds
        }
        presenter.present(sheet, animated: true)
    }

    private func presentCameraPicker() {
        guard let presenter = self.parentViewController else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        picker.mediaTypes = ["public.image"]
        presenter.present(picker, animated: true)
    }

    private func presentPhotoLibraryPicker() {
        guard let presenter = self.parentViewController else { return }
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        guard let presenter = self.parentViewController else { return }
        // Any file the user can pick — AttachmentStore kinds it on save
        // (image / pdf / markdown / source / text / generic) and enforces
        // the 20 MB size cap. `asCopy: true` so the system hands us a
        // temporary file we own; we then copy it into the workspace.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let data = image.jpegData(compressionQuality: 0.9) else { return }
        let name = "camera-\(Int(Date().timeIntervalSince1970)).jpg"
        savePickedImage(data, suggestedName: name, mime: "image/jpeg")
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

extension MessageBox: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let result = results.first else { return }
        let provider = result.itemProvider

        // Prefer the original data so we keep the file's original MIME type
        // (HEIC, JPEG, PNG) instead of forcing JPEG round-tripping.
        let preferredIdentifier = provider.registeredTypeIdentifiers.first { id in
            id.hasPrefix("public.image") || id == UTType.jpeg.identifier ||
            id == UTType.png.identifier || id == UTType.heic.identifier
        } ?? UTType.image.identifier

        provider.loadDataRepresentation(forTypeIdentifier: preferredIdentifier) { [weak self] data, error in
            guard let data = data else {
                if let error = error { print("PHPicker load error: \(error)") }
                return
            }
            let type = UTType(preferredIdentifier)
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let mime = type?.preferredMIMEType ?? "image/jpeg"
            let name = (provider.suggestedName ?? "photo") + ".\(ext)"
            DispatchQueue.main.async {
                self?.savePickedImage(data, suggestedName: name, mime: mime)
            }
        }
    }
}

extension MessageBox: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let src = urls.first else { return }
        // `asCopy: true` means we get a regular file URL — no security-scoped
        // access needed. But guard with startAccessingSecurityScopedResource
        // anyway in case Apple flips the default someday.
        let needsScope = src.startAccessingSecurityScopedResource()
        defer { if needsScope { src.stopAccessingSecurityScopedResource() } }
        do {
            let attachment = try AttachmentStore.shared.saveFromFileURL(src)
            self.pendingAttachment = attachment
        } catch {
            print("Files attach failed: \(error.localizedDescription)")
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // No-op.
    }

    /// Shared persistence hop for the camera + photo-library branches.
    fileprivate func savePickedImage(_ data: Data, suggestedName: String, mime: String) {
        do {
            let attachment = try AttachmentStore.shared.saveImage(data, suggestedName: suggestedName, mime: mime)
            self.pendingAttachment = attachment
        } catch {
            print("Image attach failed: \(error.localizedDescription)")
        }
    }
}

/// UITextView subclass that fires `onShiftReturn` when a hardware-keyboard
/// Shift+Return is pressed. UITextView normally consumes Return to insert
/// a newline, so we intercept in `pressesBegan` before the system handles
/// the press; plain Return falls through to the default newline behavior.
final class MessageInputTextView: UITextView {
    var onShiftReturn: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if key.keyCode == .keyboardReturnOrEnter,
               key.modifierFlags.contains(.shift) {
                onShiftReturn?()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }
}
