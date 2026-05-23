//
//  ViewController.swift
//  Loop
//
//  Created by Ash Bhat on 11/2/24.
//

import UIKit
import AVFoundation
import FoundationModels


enum AIState: Equatable {
    case None
    case Thinking(text: String)

    /// Default "still working" copy used between tool calls and on the
    /// initial round-trip, before the model has chosen a tool to run.
    static let defaultThinking: AIState = .Thinking(text: "Thinking...")

    var displayText: String {
        switch self {
        case .None: return ""
        case .Thinking(let text): return text
        }
    }
}

/// Spoken-response playback speed. One preset, mapped per-engine because each
/// TTS engine uses a different scale (AVSpeech 0…1, Deepgram time-pitch ratio).
enum SpeechSpeed: String, CaseIterable {
    case slow, normal, fast, veryFast

    var label: String {
        switch self {
        case .slow:     return "Slow"
        case .normal:   return "Normal"
        case .fast:     return "Fast"
        case .veryFast: return "Very Fast"
        }
    }

    /// AVSpeechUtterance.rate range is [Min…Max] with Default ≈ 0.5.
    var avSpeechRate: Float {
        switch self {
        case .slow:     return 0.42
        case .normal:   return AVSpeechUtteranceDefaultSpeechRate
        case .fast:     return 0.55
        case .veryFast: return 0.62
        }
    }

    /// AVAudioUnitTimePitch.rate multiplier used by DeepgramTTS. 1.0 is realtime.
    /// Also applied to ElevenLabs / OpenAI playback via AVAudioPlayer.rate
    /// (which preserves pitch when enableRate = true).
    var deepgramRate: Double {
        switch self {
        case .slow:     return 1.0
        case .normal:   return 1.2
        case .fast:     return 1.5
        case .veryFast: return 1.8
        }
    }
}

/// Streaming-TTS provider used for assistant audio. Change `active` and
/// rebuild to swap providers; each case has its own API-key Info.plist slot
/// and falls through to AVSpeechSynthesizer if the key is missing or the
/// request fails.
enum TTSProvider: String, CaseIterable {
    case aura2              = "aura2"              // Deepgram Aura-2 — fastest, flat prosody
    case elevenLabsV3       = "elevenLabsV3"       // ElevenLabs Eleven v3 — most expressive, ~600ms-1s TTFB
    case elevenLabsFlashV25 = "elevenLabsFlashV25" // ElevenLabs Flash v2.5 — low-latency (~75ms model TTFB), less expressive than v3
    case openAIMiniTTS      = "openAIMiniTTS"      // OpenAI gpt-4o-mini-tts — steerable via instructions
    case system             = "system"             // On-device AVSpeechSynthesizer (no network)

    /// Human-readable name shown in the speaker menu.
    var displayName: String {
        switch self {
        case .aura2:              return "Deepgram Aura-2"
        case .elevenLabsV3:       return "ElevenLabs v3"
        case .elevenLabsFlashV25: return "ElevenLabs Flash v2.5"
        case .openAIMiniTTS:      return "OpenAI gpt-4o-mini-tts"
        case .system:             return "On-device (offline)"
        }
    }

    /// Voice identifiers the user can pick for this provider, alongside a
    /// human label. For the `.system` case, voices come from
    /// AVSpeechSynthesisVoice.speechVoices() at runtime — handled separately.
    var voiceOptions: [(label: String, id: String)] {
        switch self {
        case .aura2:
            return [
                ("Thalia (warm female)",   "aura-2-thalia-en"),
                ("Asteria (calm female)",  "aura-2-asteria-en"),
                ("Luna (soft female)",     "aura-2-luna-en"),
                ("Helios (deep male)",     "aura-2-helios-en"),
                ("Orion (clear male)",     "aura-2-orion-en"),
                ("Arcas (narrative male)", "aura-2-arcas-en")
            ]
        case .elevenLabsV3, .elevenLabsFlashV25:
            return [
                ("Rachel (warm female)",  "21m00Tcm4TlvDq8ikWAM"),
                ("Bella (young female)",  "EXAVITQu4vr4xnSDxMaL"),
                ("Adam (deep male)",      "pNInz6obpgDQGcFmaJgB"),
                ("Antoni (calm male)",    "ErXwobaYiN019PkySvjV"),
                ("Elli (soft female)",    "MF3mGyEYCl7XYWbV9V6O"),
                ("Josh (steady male)",    "TxGEqnHWrfWFTfGW9XjX")
            ]
        case .openAIMiniTTS:
            return ["alloy", "echo", "fable", "onyx", "nova",
                    "shimmer", "coral", "sage", "ash", "ballad", "verse"]
                .map { ($0.capitalized, $0) }
        case .system:
            return []
        }
    }

    /// Voice id used when the user hasn't picked one for this provider yet.
    var defaultVoiceId: String {
        switch self {
        case .aura2:              return "aura-2-thalia-en"
        case .elevenLabsV3:       return "21m00Tcm4TlvDq8ikWAM"
        case .elevenLabsFlashV25: return "21m00Tcm4TlvDq8ikWAM"
        case .openAIMiniTTS:      return "shimmer"
        case .system:             return ""
        }
    }
}

class MessagingVC: UIViewController {

    var ai_state: AIState = .None
    let tableView = UITableView()
    let messageBox = MessageBox()
    /// Slim pill at the top of the screen showing "N sub-agents running". Tap
    /// presents `SubAgentInspectorVC`. Collapses to zero height when no
    /// sub-agents are alive so it doesn't eat layout space.
    let subAgentStatusBar = SubAgentStatusBarView()

    var bottomConstraint: NSLayoutConstraint?
    
    var messageIdToAnimate: String?
    
    var base_system_prompt = """
You are Loop, a personal AI agent and living memory that runs on the user's iPhone and Mac. You remember what the user tells you across conversations and devices, and you act on their behalf through your skills.

The user talks to you through a chat-style messaging interface, and by voice using the Action Button. You are texting back on a small screen, so keep responses to about 30 words and use markdown, bolding, and emojis as needed to convey your ideas clearly.

Your iCloud Drive workspace is the default save location for any files you create. Save there unless the user explicitly asks for somewhere else.

When the user asks how you work, what you can do, or how you're built, read `ABOUT_LOOP.md` in the workspace root (via file_read) and answer from it.

\(NotionSkill.systemPromptFragment)

\(SchedulerSkill.systemPromptFragment)

\(ExaSkill.systemPromptFragment)
"""
    
    var default_message: String = "Hello!"
    
    var actions: [MesssageActions] = []
    
    override var navigationController: UINavigationController? {
        get {
            self.parent?.navigationController
        }
    }
    // Side drawer
    private var sideDrawer: SideDrawerViewController?
    private var edgePanGestureRecognizer: UIPanGestureRecognizer!
    
    // Edge pan gesture tracking
    private var isEdgePanActive = false
    private var edgePanStartLocation: CGPoint = .zero
    private var edgePanStartTime: CFTimeInterval = 0
    
    // Conversation management
    private let conversationManager = SimpleConversationManager.shared
    private var currentConversationEntity: SimpleConversation? {
        didSet {
            // Re-scope the sub-agent pill so it only counts agents that were
            // spawned from the conversation we're currently viewing. Set on
            // every assignment so create/switch/reload paths all propagate
            // without each having to call the pill directly.
            subAgentStatusBar.conversationId = currentConversationEntity?.id
        }
    }
    
    // Speech synthesis - using backend audio generation
    private var audioPlayer: AVAudioPlayer?
    /// 30 Hz poll that converts `audioPlayer.averagePower(forChannel:)`
    /// into a linear [0, 1] amplitude and publishes it via
    /// `VoiceLoopCoordinator.publishOutputAmplitude`. Driven by the
    /// `AVAudioPlayer`-backed TTS providers (cloud OpenAI mini-tts,
    /// ElevenLabs HTTP, Deepgram fallback) so the avatar's speaking-mode
    /// formula tracks the actual speech instead of a canned sine.
    private var ttsMeteringTimer: Timer?
    private var currentSpeechMessageId: String?
    private var speechBuffer: String = ""
    private var muteButton: UIBarButtonItem?

    // Streaming TTS (Deepgram Aura-2). Used when DEEPGRAM_API_KEY is configured;
    // falls back to AVSpeechSynthesizer when missing or on connection failure.
    private var deepgramTTS: DeepgramTTS?

    // Offline TTS — used when the device has no network. AVSpeechSynthesizer runs
    // on-device and never needs to reach any backend.
    private let offlineSynthesizer = AVSpeechSynthesizer()
    private var offlineSpeechMessageId: String?

    /// The voice used for offline TTS. Honors the user's explicit choice from the
    /// nav-bar speaker menu when set; otherwise picks the most lifelike Apple
    /// voice the device has for the user's locale (Premium > Enhanced > Default).
    private var offlineVoice: AVSpeechSynthesisVoice? {
        if let id = selectedVoiceIdentifier,
           let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        return MessagingVC.autoPreferredVoice
    }

    private static let autoPreferredVoice: AVSpeechSynthesisVoice? = {
        let language = "en-US"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        if #available(iOS 16.0, *) {
            if let v = voices.first(where: { $0.quality == .premium }) { return v }
        }
        if let v = voices.first(where: { $0.quality == .enhanced }) { return v }
        return AVSpeechSynthesisVoice(language: language)
    }()

    /// User-selected offline voice identifier. nil → fall back to autoPreferredVoice.
    private var selectedVoiceIdentifier: String? {
        get { iCloudKVSDefaults.shared.string(forKey: "offlineVoiceIdentifier") }
        set {
            iCloudKVSDefaults.shared.set(newValue, forKey: "offlineVoiceIdentifier")
            updateMuteButtonAppearance()
        }
    }

    /// User-selected TTS provider. Persisted across launches; defaults to
    /// OpenAI gpt-4o-mini-tts. The setter rebuilds the speaker menu so the
    /// voice submenu updates to the new provider's voice list.
    private var ttsProvider: TTSProvider {
        get {
            let raw = iCloudKVSDefaults.shared.string(forKey: "ttsProvider") ?? TTSProvider.openAIMiniTTS.rawValue
            return TTSProvider(rawValue: raw) ?? .openAIMiniTTS
        }
        set {
            iCloudKVSDefaults.shared.set(newValue.rawValue, forKey: "ttsProvider")
            muteButton?.menu = buildSpeakerMenu()
        }
    }

    /// Voice id selected for a given provider, persisted per-provider so
    /// switching providers doesn't lose the user's last pick.
    private func selectedVoiceId(for provider: TTSProvider) -> String {
        let key = "ttsVoice.\(provider.rawValue)"
        return iCloudKVSDefaults.shared.string(forKey: key) ?? provider.defaultVoiceId
    }

    private func setSelectedVoiceId(_ id: String, for provider: TTSProvider) {
        iCloudKVSDefaults.shared.set(id, forKey: "ttsVoice.\(provider.rawValue)")
        muteButton?.menu = buildSpeakerMenu()
    }

    /// In-flight + completed TTS timing keyed by message id. Used to drive
    /// the spinner + "| 2.03s to audio" suffix on the assistant's model label.
    private var ttsStatuses: [String: MessagingCell.TTSStatus] = [:]
    /// Wall-clock time the TTS request was kicked off, captured per-message
    /// so we can compute "time to audio" when the first byte plays.
    private var ttsStartTimes: [String: Date] = [:]

    /// User-selected playback speed. Applies to both AVSpeech (offline) and
    /// Deepgram (online) paths.
    private var speechSpeed: SpeechSpeed {
        get {
            let raw = iCloudKVSDefaults.shared.string(forKey: "speechSpeed") ?? SpeechSpeed.normal.rawValue
            return SpeechSpeed(rawValue: raw) ?? .normal
        }
        set {
            iCloudKVSDefaults.shared.set(newValue.rawValue, forKey: "speechSpeed")
            updateMuteButtonAppearance()
        }
    }

    private static var deepgramAPIKey: String? {
        return KeyStore.shared.value(for: .deepgram)
    }

    private static var elevenLabsAPIKey: String? {
        return KeyStore.shared.value(for: .elevenLabs)
    }

    private static var openAIAPIKey: String? {
        return KeyStore.shared.value(for: .openAI)
    }
    
    
    
    // Mute state — synced across reinstalls/devices via iCloudKVSDefaults.
    private var isMuted: Bool {
        get {
            return iCloudKVSDefaults.shared.bool(forKey: "audioMuted")
        }
        set {
            iCloudKVSDefaults.shared.set(newValue, forKey: "audioMuted")
            updateMuteButtonAppearance()
        }
    }
    
    lazy var messages: [MessageStruct] = [
        MessageStruct(role: "system", content: base_system_prompt),
    ]
    
    
    
    var visible_messages: [MessageStruct] {
        return self.messages.filter({
            // System + bare function calls + raw function results are hidden,
            // EXCEPT we keep messages carrying an imageAttachment regardless
            // of role — those are the inline image bubbles.
            if $0.imageAttachment != nil { return true }
            return $0.role != "system" && $0.function == nil && $0.role != "function"
        })
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Hand the harness a reference back to us so /new, /reset, and /compact
        // can apply UI-level side effects without the harness depending on UIKit.
        AgentHarness.shared.slashCommandHost = self
        // ImageGenerationService injects placeholder + final image messages
        // into the chat as the long-running HTTP request progresses; route
        // those through us so the bubble updates in place.
        ImageGenerationService.shared.host = self
        // CalendarSkill needs a UI host so it can present
        // EKEventEditViewController for the user to review proposed events
        // before they're saved.
        CalendarSkill.shared.host = self
        // SlackSkill needs a UI host so write tools can present a
        // confirmation alert before chat.postMessage fires.
        SlackSkill.shared.host = self
        // GitHubSkill uses the same pattern for merge/review/comment/create
        // tools — each one pops a confirmation alert before the API call.
        GitHubSkill.shared.host = self
        // Sweep stale .generating attachments forward to .failed so a kill
        // mid-generation doesn't leave us with a forever-spinning bubble.
        cleanupStuckImageGenerations()

        let currentDate = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .medium

        let formattedDate = dateFormatter.string(from: currentDate)
        
        self.messages[0].content = self.base_system_prompt + " The current date and time is \(formattedDate). Please take this into account when answering questions about whether a place is closed or not."
        
        self.setupNav()
        self.setupUI()
        self.setupEdgePanGesture()
        
        // Load last conversation and messages
        loadLastConversation()
        
        self.messageIdToAnimate = self.visible_messages.last(where: {$0.role == "assistant"})?.id
        
        messageBox.delegate = self
        offlineSynthesizer.delegate = self

        // Listen for voice transcription trigger from URL scheme
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVoiceTranscriptionTrigger),
            name: NSNotification.Name("TriggerVoiceTranscription"),
            object: nil
        )

        // IntegrationSkill asks us to surface the Integrations settings UI
        // (or the system Privacy pane) on its behalf, since the skill itself
        // doesn't import UIKit.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIntegrationSettingsRequest(_:)),
            name: .integrationSkillRequestedSettings,
            object: nil
        )

        // When a sub-agent finishes and posts its summary into our parent
        // conversation, reload so the bubble appears in real time instead of
        // waiting for the next view-appear.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSubAgentMessage(_:)),
            name: .subAgentDidPostMessage,
            object: nil
        )
        // Cursor cloud-agent completions post back the same way (the handler
        // only keys off `conversationId`), so reuse it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSubAgentMessage(_:)),
            name: .cursorAgentDidPostMessage,
            object: nil
        )
        // Devin cloud-agent completions post back identically — same handler.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSubAgentMessage(_:)),
            name: .devinAgentDidPostMessage,
            object: nil
        )

        // Pick up any attachment the SceneDelegate stashed during cold-start
        // before MessagingVC had loaded. This drains the inbox so the file
        // doesn't reappear on later view loads.
        if let pending = SharedAttachmentInbox.shared.drain() {
            self.stageIncomingAttachment(pending)
        }

        // Do any additional setup after loading the view.
    }

    /// Public entry point used by the SceneDelegate when a file is shared
    /// into the app via the system share sheet. Drops the attachment on the
    /// message bar so the user just hits send.
    func stageIncomingAttachment(_ attachment: FileAttachment) {
        self.messageBox.pendingAttachment = attachment
        // Pop the keyboard so the user can type a prompt before sending.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.messageBox.textView.becomeFirstResponder()
        }
    }

    func makeSinglePrompt(from messages: [MessageStruct]) -> String {
        var prompt = """
        I've attached the chat history below.
        Please respond as the assistant with the next response in this sequence.

        """

        for message in messages {
            switch message.role {
            case "user":
                prompt += "User: \(message.content)\n"
            case "assistant":
                prompt += "Assistant: \(message.content)\n"
            default:
                continue
            }

        }

        prompt += "Assistant:"
        return prompt
    }

    override func viewWillAppear(_ animated: Bool) {
        self.navigationController?.setNavigationBarHidden(false, animated: false)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Conversation Management
    
    private func loadLastConversation() {
        print("🚀 Loading last conversation on app start")
        
        if let conversation = conversationManager.loadLastConversation() {
            print("🚀 Found last conversation: \(conversation.title)")
            currentConversationEntity = conversation
            loadMessagesFromConversation(conversation)
        } else {
            print("🚀 No last conversation found, starting with default message")
            // No previous conversation, start with default message
            loadDefaultMessage()
        }
    }
    
    private func loadMessagesFromConversation(_ conversation: SimpleConversation) {
        print("🔄 Loading conversation: \(conversation.title)")
        print("🔄 Total messages in conversation: \(conversation.messages.count)")
        
        let messageEntities = conversationManager.getMessages(for: conversation)
        print("🔄 Retrieved \(messageEntities.count) messages from storage")
        
        // Clear existing messages except system message
        messages = [messages[0]] // Keep system message
        
        // Convert and add all messages from conversation
        for (index, messageEntity) in messageEntities.enumerated() {
            let messageStruct = conversationManager.messageStruct(from: messageEntity)
            messages.append(messageStruct)
            print("🔄 Loaded message \(index + 1): \(messageStruct.role) - \(messageStruct.content.prefix(50))...")
        }
        
        print("🔄 Total messages after loading: \(messages.count)")
        
        // Reload table view and scroll to bottom
        DispatchQueue.main.async {
            self.tableView.reloadData()
            self.scrollToLastMessage()
        }
    }
    
    private func loadDefaultMessage() {
        // Clear existing messages except system message
        messages = [messages[0]] // Keep system message
        
//        // Add default assistant message
//        let defaultMessage = MessageStruct(role: "assistant", content: default_message, actions: actions)
//        messages.append(defaultMessage)
        
        // Reload table view
        DispatchQueue.main.async {
            self.tableView.reloadData()
//            self.messageBox.textView.becomeFirstResponder()
        }
    }
    
    func loadConversation(_ conversation: SimpleConversation) {
        currentConversationEntity = conversation
        conversationManager.currentConversation = conversation
        // Clear TTS timing state so a stale "| 2.03s to audio" suffix doesn't
        // ride along onto a different conversation's messages by id collision.
        ttsStatuses.removeAll()
        ttsStartTimes.removeAll()
        loadMessagesFromConversation(conversation)
    }

    private func createNewConversation() {
        // Create a new conversation with a unique title
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        let newConversation = conversationManager.createConversation(title: "New Chat \(timestamp)")
        currentConversationEntity = newConversation
        conversationManager.currentConversation = newConversation
        ttsStatuses.removeAll()
        ttsStartTimes.removeAll()
        loadDefaultMessage()
    }
    
    func ensureCurrentConversation() -> SimpleConversation {
        if let conversation = currentConversationEntity {
            print("✅ Using existing conversation: \(conversation.title)")
            return conversation
        }
        
        print("⚠️ No current conversation, creating new one")
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        let conversation = conversationManager.createConversation(title: "Chat \(timestamp)")
        currentConversationEntity = conversation
        conversationManager.currentConversation = conversation
        print("✅ Created new conversation: \(conversation.title)")
        return conversation
    }
    
    // MARK: - Voice Transcription Control
    
    @objc private func handleVoiceTranscriptionTrigger() {
        print("Received voice transcription trigger notification")
        // Add a small delay to ensure the view is fully loaded
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.toggleVoiceTranscription()
        }
    }

    /// IntegrationSkill posts this when the model calls
    /// `open_integration_settings`. `userInfo["target"]` decides whether we
    /// push the in-app Integrations panel (default) or jump to the system
    /// Privacy & Security pane for Calendars.
    @objc private func handleIntegrationSettingsRequest(_ note: Notification) {
        let target = (note.userInfo?["target"] as? String) ?? "in_app"
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if target == "calendar_privacy" {
                // The system pane is the actionable surface when Calendar is
                // in .denied — open it directly so the user lands one tap
                // away from re-granting access.
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                return
            }
            // Default: push the in-app panel. Guard against re-pushing if
            // it's already on top of the nav stack.
            if let nav = self.navigationController,
               !(nav.topViewController is IntegrationsVC) {
                nav.pushViewController(IntegrationsVC(), animated: true)
            }
        }
    }
    
    func toggleVoiceTranscription() {
        print("Toggling voice transcription")
        
        // Check if voice transcription is currently running
        if messageBox.currentState == .recording {
            print("Voice transcription is running, sending current recording")
            messageBox.sendCurrentRecording()
        } else {
            print("Starting voice transcription")
            messageBox.startVoiceRecording()
        }
    }
    
    func newMessageSent() {
        
    }
    
    
}

extension MessagingVC: MessageBoxDelegate {
    
    func didSendMessageStruct(_ message: MessageStruct) {
        // Ensure we have a current conversation
        let conversation = ensureCurrentConversation()

        // Add message to conversation
        conversationManager.addMessage(message, to: conversation)

        // Update local conversation reference
        currentConversationEntity = conversationManager.currentConversation

        // Add to local messages array
        self.messages.append(message)
        self.newMessageSent()

        // Tool just finished — flip the shimmer back to a generic "thinking"
        // copy while the model decides what to do with the result.
        self.ai_state = .defaultThinking
        VoiceLoopCoordinator.shared.setState(.thinking)
        DispatchQueue.main.async {
            self.tableView.reloadData()
        }

        Cloud.connection.chat(messages: self.messages) { responseMessage, error in
            self.ai_state = .None
            if let responseMessage = responseMessage {
                self.processMessage(message: responseMessage)
            }
            else {
                if #available(iOS 26.0, *) {
                    let systemModel = SystemLanguageModel.default
                    if systemModel.availability == .available {
                        print("Apple Intelligence enabled")
                        let session = LanguageModelSession()

                        let singlePrompt = self.makeSinglePrompt(from: self.messages)
                        Task {
                            do {
                                let response = try await session.respond(to: singlePrompt)
                                let responseMessage = MessageStruct(role: "assistant", content: response.content, model: "Apple LLM")

                                self.messages.append(responseMessage)
                                self.messageIdToAnimate = responseMessage.id

                                // Save error message to conversation
                                self.conversationManager.addMessage(responseMessage, to: conversation)

                                DispatchQueue.main.async {
                                    self.tableView.reloadData()
                                    self.scrollToLastMessage()
                                    // Without this the offline reply lands in
                                    // the table silently — playMessageSynthesizer
                                    // is what routes to speakOffline on no-net.
                                    self.playMessageSynthesizer(message: responseMessage)
                                }

                            }
                        }
                        return


                    }
                }


                let errorMessage = MessageStruct(role: "assistant", content: "Sorry – I'm having trouble connecting to Gemini. Please try again.")
                self.messages.append(errorMessage)
                self.messageIdToAnimate = errorMessage.id

                // Save error message to conversation
                self.conversationManager.addMessage(errorMessage, to: conversation)

                DispatchQueue.main.async {
                    self.tableView.reloadData()
                    self.scrollToLastMessage()
                }
                EarconPlayer.shared.play(.error)
                VoiceLoopCoordinator.shared.setState(.idle)
            }
        }
    }

    func didSendMessageText(_ message: String) {
        // Ensure we have a current conversation
        let conversation = ensureCurrentConversation()

        // Visual punctuation: the user just sent something. Pulses the
        // avatar(s) via MainVC's subscription on the coordinator.
        VoiceLoopCoordinator.shared.publishAcknowledgePulse()

        // Pull any staged file attachment off the input bar; the send button
        // is active even with empty text if there's a file ready, so we
        // tolerate `message.isEmpty` as long as one of the two is present.
        let stagedAttachment = self.messageBox.pendingAttachment
        var messageStruct = MessageStruct(role: "user", content: message)
        messageStruct.fileAttachment = stagedAttachment

        // Clear the staged attachment immediately so the chip + paperclip
        // bounce back the moment the send tap registers, even before the
        // network call comes back.
        if stagedAttachment != nil {
            self.messageBox.pendingAttachment = nil
        }

        // Add message to conversation
        conversationManager.addMessage(messageStruct, to: conversation)

        // Update local conversation reference
        currentConversationEntity = conversationManager.currentConversation

        // Add to local messages array
        self.messages.append(messageStruct)
        self.newMessageSent()

        self.ai_state = .defaultThinking
        VoiceLoopCoordinator.shared.setState(.thinking)
        self.tableView.reloadData()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
            self.scrollToLastMessage()
        })


        Cloud.connection.chat(messages: self.messages) { responseMessage, error in
            self.ai_state = .None
            if let responseMessage = responseMessage {
                self.processMessage(message: responseMessage)
            }
            else {

                if #available(iOS 26.0, *) {
                    let systemModel = SystemLanguageModel.default
                    if systemModel.availability == .available {
                        print("Apple Intelligence enabled")
                        let session = LanguageModelSession()

                        let singlePrompt = self.makeSinglePrompt(from: self.messages)
                        Task {
                            do {
                                print(singlePrompt)
                                let response = try await session.respond(to: singlePrompt)
                                print(response)
                                let responseMessage = MessageStruct(role: "assistant", content: response.content, model: "Apple LLM")

                                self.messages.append(responseMessage)
                                self.messageIdToAnimate = responseMessage.id

                                // Save error message to conversation
                                self.conversationManager.addMessage(responseMessage, to: conversation)

                                DispatchQueue.main.async {
                                    self.tableView.reloadData()
                                    self.scrollToLastMessage()
                                    // Without this the offline reply lands in
                                    // the table silently — playMessageSynthesizer
                                    // is what routes to speakOffline on no-net.
                                    self.playMessageSynthesizer(message: responseMessage)
                                }

                            }
                        }
                        return


                    }
                }
                
                
                let errorMessage = MessageStruct(role: "assistant", content: "Sorry – I'm having trouble connecting to Gemini. Please try again.")
                self.messages.append(errorMessage)
                self.messageIdToAnimate = errorMessage.id

                // Save error message to conversation
                self.conversationManager.addMessage(errorMessage, to: conversation)

                DispatchQueue.main.async {
                    self.tableView.reloadData()
                    self.scrollToLastMessage()
                }
                EarconPlayer.shared.play(.error)
                VoiceLoopCoordinator.shared.setState(.idle)
            }
        }

//      make api request to get response
    }
    
    func stopSpeech() {
        stopSpeaking()
    }

    /// Resolves the shimmer label copy for a model-emitted function call.
    /// Skills get first crack via their own statusText(for:); legacy in-VC
    /// tools and a generic fallback handle the rest.
    private func statusText(for call: FunctionCallStruct) -> String {
        if let s = ExaSkill.shared.statusText(for: call) { return s }
        if let s = NotionSkill.shared.statusText(for: call) { return s }
        if let s = SchedulerSkill.shared.statusText(for: call) { return s }
        if let s = SelfImprovementSkill.shared.statusText(for: call) { return s }
        if let s = FileSystemSkill.shared.statusText(for: call) { return s }
        if let s = SpecBuilderSkill.shared.statusText(for: call) { return s }
        if let s = ObsidianSkill.shared.statusText(for: call) { return s }
        if let s = CalendarSkill.shared.statusText(for: call) { return s }
        if let s = SkillBuilderSkill.shared.statusText(for: call) { return s }
        if let s = SubAgentSkill.shared.statusText(for: call) { return s }
        if let s = GitHubSkill.shared.statusText(for: call) { return s }
        if let s = DevinSkill.shared.statusText(for: call) { return s }
        if let s = DynamicSkillRegistry.shared.statusText(for: call) { return s }

        switch call.name {
        case "add_note_to_notion":
            return "saving note to Notion"
        case "get_today_meta_note":
            return "looking up today's notes"
        default:
            let pretty = call.name.replacingOccurrences(of: "_", with: " ")
            return "running \(pretty)"
        }
    }

    func processMessage(message: MessageStruct) {

        if message.role == "function" {
            // Single-result entry point. The multi-call path below batches
            // its own results, then re-enters chat directly, so it never
            // round-trips through this branch.
            self.didSendMessageStruct(message)
            return
        }

        if message.functions.isEmpty {
            // Plain assistant turn — no tool calls. Render normally; if the
            // model returned an empty turn after a tool sequence (which can
            // happen when it has nothing left to say), unwind the shimmer
            // instead of dropping the user into a forever-spinning state.
            guard message.content.count > 0 else {
                self.ai_state = .None
                VoiceLoopCoordinator.shared.setState(.idle)
                DispatchQueue.main.async { self.tableView.reloadData() }
                return
            }
            let conversation = ensureCurrentConversation()
            conversationManager.addMessage(message, to: conversation)
            currentConversationEntity = conversationManager.currentConversation
            self.messages.append(message)
            VoiceLoopCoordinator.shared.publishAcknowledgePulse()
            self.playMessageSynthesizer(message: message)
            self.messageIdToAnimate = message.id
            DispatchQueue.main.async {
                self.tableView.reloadData()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                    self.scrollToLastMessage()
                })
            }
            return
        }

        // Assistant emitted ≥1 tool call(s). Update the shimmer + activity log
        // for the first call so the UI flips before any tool starts running,
        // persist the assistant turn so the model can see its own call list
        // on the next round-trip, then fan out every call before issuing one
        // follow-up chat with all the results.
        if let firstCall = message.functions.first {
            let status = self.statusText(for: firstCall)
            self.ai_state = .Thinking(text: status)
            AgentActivityLog.shared.log(.toolCall, status, detail: firstCall.name)
        }
        self.messages.append(message)
        DispatchQueue.main.async { self.tableView.reloadData() }
        self.dispatchAllCalls(in: message)
    }

    /// Fan out every call on an assistant turn. Anthropic and OpenAI both
    /// support parallel tool calls in a single response — dispatching them
    /// concurrently and replying with all the results in one user turn is
    /// what unlocks multi-step plans ("create note, move it, post link").
    /// Previously the harness only serviced the first call and silently
    /// dropped the rest, stalling the loop after one tool.
    private func dispatchAllCalls(in message: MessageStruct) {
        let calls = message.functions
        let total = calls.count
        var resultBuffer = Array<MessageStruct?>(repeating: nil, count: total)
        var pendingCount = total

        // Hot-loaded JS skills emit progress via the registry's logHandler;
        // wire it into the shimmer once so any of the parallel calls can
        // surface a live status line.
        DynamicSkillRegistry.shared.logHandler = { [weak self] _, line in
            DispatchQueue.main.async {
                self?.ai_state = .Thinking(text: line)
                self?.tableView.reloadData()
            }
        }

        for (index, call) in calls.enumerated() {
            self.dispatchCall(call) { [weak self] result in
                guard let self = self else { return }
                var r = result
                // Pair the result back to the originating call so the wire
                // layer can emit a structured `tool_result` (Anthropic) or
                // `role:"tool"` (OpenAI) message instead of falling back to
                // prose — without this binding the model can't reliably tell
                // which result came from which call.
                if r.callId == nil { r.callId = call.callId }
                if r.name == nil   { r.name   = call.name }
                DispatchQueue.main.async {
                    resultBuffer[index] = r
                    pendingCount -= 1
                    if pendingCount == 0 {
                        self.finishToolBatch(resultBuffer.compactMap { $0 })
                    }
                }
            }
        }
    }

    /// Persist + append every tool result, then issue one follow-up chat.
    /// Mirrors the post-append tail of `didSendMessageStruct` minus the
    /// Apple-LLM offline branch (the harness routes to its own
    /// `offlineRespond` when the device is offline and never reaches this
    /// path with tools in flight).
    private func finishToolBatch(_ results: [MessageStruct]) {
        let conversation = ensureCurrentConversation()
        for r in results {
            conversationManager.addMessage(r, to: conversation)
            self.messages.append(r)
        }
        currentConversationEntity = conversationManager.currentConversation
        self.newMessageSent()
        self.ai_state = .defaultThinking
        VoiceLoopCoordinator.shared.setState(.thinking)
        DispatchQueue.main.async { self.tableView.reloadData() }

        Cloud.connection.chat(messages: self.messages) { [weak self] responseMessage, error in
            guard let self = self else { return }
            self.ai_state = .None
            if let responseMessage = responseMessage {
                self.processMessage(message: responseMessage)
                return
            }
            // Surface the underlying detail when it's specific (wrong key,
            // bad model id, quota) so the user can fix it instead of seeing
            // a generic "couldn't connect" — same gate the user-message
            // flow uses.
            let detail = error?.localizedDescription ?? ""
            let body: String
            if !detail.isEmpty && !detail.lowercased().hasPrefix("the operation couldn") {
                body = detail
            } else {
                body = "Sorry – I'm having trouble connecting to the model. Please try again."
            }
            let errorMessage = MessageStruct(role: "assistant", content: body)
            DispatchQueue.main.async {
                self.processMessage(message: errorMessage)
            }
        }
    }

    /// Route a single tool call to whoever can handle it. The shared
    /// `SkillDispatcher` covers every bundled skill plus the user-authored
    /// JS registry, and it emits a structured "Unknown tool" error result
    /// for hallucinated names — so the model always gets *some* reply and
    /// the conversation can't silently stall on a missing handler (which is
    /// what the iOS path used to do before this refactor). SubAgentSkill is
    /// routed inline (intentionally excluded from `SkillDispatcher` so
    /// background-scheduled jobs can't spawn sub-agents).
    private func dispatchCall(_ call: FunctionCallStruct,
                              completion: @escaping (MessageStruct) -> Void) {
        // Stamp the originating conversation onto the call so skills
        // that need parent-conversation context (SubAgentSkill,
        // TerminalSkill) read from there rather than the global
        // `currentConversation` pointer — see VoiceLoopCoordinator's
        // matching shim for the multi-tab Mac scenario this guards
        // against. Cheap to populate on iOS even though the global
        // would also work in single-thread terms; keeps the dispatch
        // contract uniform across platforms.
        var call = call
        if call.conversationId == nil {
            call.conversationId = currentConversationEntity?.id
        }
        if SubAgentSkill.shared.handles(functionName: call.name) {
            SubAgentSkill.shared.handle(functionCall: call, completion: completion)
            return
        }
        SkillDispatcher.shared.dispatch(call, completion: completion)
    }

    /// Shared TTS preprocessor. Lives in `SpeechPipeline/SpeechSanitizer.swift`
    /// so it can evolve (pronunciation control, SSML, summarization, etc.)
    /// without churn here. V0 strips URLs, markdown, tool/debug artifacts,
    /// and emojis, and rewrites numbered lists for natural pacing.
    /// `static` because Swift forbids stored properties on extensions; the
    /// sanitizer holds only Configuration state, so a single shared instance
    /// is safe.
    private static let speechSanitizer = SpeechSanitizer()
    
    func playMessageSynthesizer(message: MessageStruct) {
        // Check if audio is muted
        if isMuted {
            // No speech will play, but the assistant's turn IS complete —
            // drop the avatar back to idle so it doesn't sit in the
            // thinking state forever.
            VoiceLoopCoordinator.shared.setState(.idle)
            return
        }

        // Stop any ongoing audio
        stopSpeaking()

        // From the avatar's perspective the turn is now in its speaking
        // phase. setState dedupes so the order with stopSpeaking (which also
        // tries to drop to .idle) doesn't matter.
        VoiceLoopCoordinator.shared.setState(.speaking)

        // Store the message ID we're speaking
        currentSpeechMessageId = message.id

        // Run the model output through the speech sanitization pipeline before
        // any provider sees it — strips URLs, markdown, tool artifacts, and
        // rewrites numbered lists / punctuation for natural pacing.
        let cleanContent = MessagingVC.speechSanitizer.sanitize(message.content)
        guard !cleanContent.isEmpty else { return }

        // Mark the start of the TTS request and show the spinner next to the
        // model name. markTTSStarted hops to main internally — playMessageSynthesizer
        // can be called from a Cloud.chat completion handler running on the
        // URLSession delegate queue, and AutoLayout/UITableView access from a
        // background thread crashes UIKit.
        markTTSStarted(forMessageId: message.id)

        // Offline path takes priority — no point opening a WS or hitting the
        // backend without a network. Uses AVSpeechSynthesizer with the most
        // lifelike voice the device has available.
        if !MessageBox.isOnline {
            speakOffline(text: cleanContent, messageId: message.id)
            return
        }

        // Dispatch to the user-selected streaming TTS provider. Each begin*Speak
        // returns true if it took ownership of this turn; false → fall through
        // to AVSpeechSynthesizer.
        let provider = self.ttsProvider
        let took: Bool
        switch provider {
        case .aura2:
            took = MessagingVC.deepgramAPIKey != nil
                && beginDeepgramSpeak(text: cleanContent, messageId: message.id)
        case .elevenLabsV3:
            took = MessagingVC.elevenLabsAPIKey != nil
                && beginElevenLabsSpeak(text: cleanContent, messageId: message.id, modelId: "eleven_v3")
        case .elevenLabsFlashV25:
            took = MessagingVC.elevenLabsAPIKey != nil
                && beginElevenLabsSpeak(text: cleanContent, messageId: message.id, modelId: "eleven_flash_v2_5")
        case .openAIMiniTTS:
            took = MessagingVC.openAIAPIKey != nil
                && beginOpenAISpeak(text: cleanContent, messageId: message.id)
        case .system:
            // User explicitly chose offline TTS — skip any network providers.
            speakOffline(text: cleanContent, messageId: message.id)
            return
        }
        if took { return }

        // No streaming provider configured (or all failed to start). Fall back
        // to the on-device synthesizer.
        speakOffline(text: cleanContent, messageId: message.id)
    }

    /// Compute the time-to-audio for `messageId` using the `ttsStartTimes`
    /// stamp and update the cell. Idempotent — if the duration is already
    /// recorded as `.ready(...)`, calling again is a no-op.
    ///
    /// Callable from any thread; reads of `ttsStartTimes` / `ttsStatuses`
    /// are forced onto main so they can't race with `setTTSStatus(_:for:)`.
    fileprivate func markAudioReady(forMessageId messageId: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.markAudioReady(forMessageId: messageId)
            }
            return
        }
        guard let started = ttsStartTimes[messageId] else { return }
        if case .ready = ttsStatuses[messageId] { return }
        let elapsed = Date().timeIntervalSince(started)
        setTTSStatus(.ready(seconds: elapsed), for: messageId)
    }
    
    /// Updates speech synthesis with new content as it streams in
    /// This is useful when message content is being received incrementally
    func updateSpeechWithStreamingContent(messageId: String, newContent: String) {
        // Same sanitizer the non-streaming path uses — keeps the gate on what
        // counts as "meaningful content" honest by measuring the spoken text.
        let cleanContent = MessagingVC.speechSanitizer.sanitize(newContent)

        // Only speak if there's meaningful content (more than a few characters)
        guard cleanContent.count > 3 else {
            return
        }
        
        // If this is the message we're currently speaking, stop and restart with updated content
        if currentSpeechMessageId == messageId {
            stopSpeaking()
            // Regenerate audio with updated content
            let message = MessageStruct(id: messageId, role: "assistant", content: newContent)
            playMessageSynthesizer(message: message)
        } else {
            // New message, start speaking it
            let message = MessageStruct(id: messageId, role: "assistant", content: newContent)
            playMessageSynthesizer(message: message)
        }
    }
    
    func stopSpeaking() {
        audioPlayer?.stop()
        audioPlayer = nil
        deepgramTTS?.stop()
        deepgramTTS = nil
        if offlineSynthesizer.isSpeaking || offlineSynthesizer.isPaused {
            offlineSynthesizer.stopSpeaking(at: .immediate)
        }
        offlineSpeechMessageId = nil
        currentSpeechMessageId = nil
        speechBuffer = ""

        // Only drop the coordinator back to .idle if it's currently in a
        // speaking state. stopSpeaking is also called as a setup step inside
        // playMessageSynthesizer (right before we kick off a new turn) — in
        // that case the next setState(.speaking) will overwrite us anyway,
        // but skipping here keeps state transitions less noisy.
        let coord = VoiceLoopCoordinator.shared
        if coord.state == .speaking {
            coord.setState(.idle)
        }
    }

    /// Speak `text` using on-device AVSpeechSynthesizer. No network, no Deepgram.
    /// Picks the most lifelike voice available on the device (see
    /// `preferredOfflineVoice`).
    private func speakOffline(text: String, messageId: String) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Offline TTS: audio session setup failed (\(error)) — speaking anyway")
        }

        let utterance = AVSpeechUtterance(string: text)
        let voice = offlineVoice
        utterance.voice = voice
        utterance.rate = speechSpeed.avSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        offlineSpeechMessageId = messageId
        offlineSynthesizer.speak(utterance)
        // AVSpeechSynthesizer is on-device — "audio ready" is essentially
        // immediate, so stamp the duration here. (didStart is unreliable on
        // some iOS versions and adds delegate complexity for a sub-frame win.)
        markAudioReady(forMessageId: messageId)
        print("Offline TTS: speaking message \(messageId) with voice \(voice?.name ?? "system default") at \(speechSpeed.label)")
    }
    
    private func scrollToLastMessage() {
        if self.visible_messages.count > 0 {
            let lastIndex = IndexPath(row: self.visible_messages.count - 1, section: 0)
            self.tableView.scrollToRow(at: lastIndex, at: .top, animated: false)
        }
    }
    
    private func scrollToBottom() {
        if self.visible_messages.count > 0 {
            let lastIndex = IndexPath(row: self.visible_messages.count - 1, section: 0)
            self.tableView.scrollToRow(at: lastIndex, at: .bottom, animated: false)
        }
    }
}


// UI Setup
extension MessagingVC {
    func setupNav() {
        self.title = "Intel"

        // Sync earcon enable flag with the persisted mute state at launch
        // (the setter wires this on toggles; this covers the cold start).
        EarconPlayer.shared.enabled = !isMuted

        // Left bar button
        let sideBarButton = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal"), style: .done, target: self, action: #selector(leftBarButtonTapped))
        sideBarButton.tintColor = .secondarySystemBackground
        self.navigationItem.leftBarButtonItems = [sideBarButton]
        
        self.navigationItem.leftBarButtonItem?.tintColor = .secondarySystemBackground
        
        // Right bar buttons: speaker (now opens a settings menu) + edit
        muteButton = UIBarButtonItem(image: UIImage(systemName: isMuted ? "speaker.slash" : "speaker.wave.1"), menu: buildSpeakerMenu())
        muteButton?.tintColor = .secondarySystemBackground

        let editButton = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), style: .done, target: self, action: #selector(rightBarButtonTapped))
        editButton.tintColor = .secondarySystemBackground

        let settingsButton = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(settingsButtonTapped))
        settingsButton.tintColor = .secondarySystemBackground

        // Order: edit (leading), speaker, settings (trailing).
        self.navigationItem.rightBarButtonItems = [editButton, muteButton!, settingsButton]
    }

    private func updateMuteButtonAppearance() {
        muteButton?.image = UIImage(systemName: isMuted ? "speaker.slash" : "speaker.wave.1")
        // Rebuild so checkmarks reflect the new state on next tap.
        muteButton?.menu = buildSpeakerMenu()
        // Earcons follow the speaker mute toggle — turning off voice
        // playback should silence state-transition cues too.
        EarconPlayer.shared.enabled = !isMuted
    }

    /// Builds the speaker-button popover menu: mute toggle, speed presets,
    /// and (if voice playback is enabled) the offline voice picker.
    private func buildSpeakerMenu() -> UIMenu {
        // Mute toggle. UI mirrors the icon: "Voice playback" on/off.
        let muteAction = UIAction(
            title: isMuted ? "Turn on voice playback" : "Turn off voice playback",
            image: UIImage(systemName: isMuted ? "speaker.wave.2" : "speaker.slash"),
            attributes: isMuted ? [] : .destructive
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isMuted.toggle()
            if self.isMuted { self.stopSpeaking() }
        }

        // Speed presets — applied to AVSpeech and Deepgram on the next utterance.
        let speedActions = SpeechSpeed.allCases.map { preset in
            UIAction(
                title: preset.label,
                state: self.speechSpeed == preset ? .on : .off
            ) { [weak self] _ in
                self?.speechSpeed = preset
            }
        }
        let speedMenu = UIMenu(
            title: "Speed — \(speechSpeed.label)",
            image: UIImage(systemName: "speedometer"),
            children: speedActions
        )

        // Provider picker. Tapping a provider persists it and rebuilds the
        // menu (so the Voice submenu below switches to that provider's list).
        let activeProvider = ttsProvider
        let providerActions = TTSProvider.allCases.map { p in
            UIAction(
                title: p.displayName,
                state: p == activeProvider ? .on : .off
            ) { [weak self] _ in
                self?.ttsProvider = p
            }
        }
        let providerMenu = UIMenu(
            title: "Model — \(activeProvider.displayName)",
            image: UIImage(systemName: "waveform.badge.mic"),
            children: providerActions
        )

        // Voice submenu — branches by provider. The .system case uses the
        // device's AVSpeechSynthesisVoice list; the network providers use a
        // hardcoded curated list per voiceOptions.
        let voiceMenu = buildVoiceMenu(for: activeProvider)

        // When muted, hide everything below the toggle — they aren't doing anything.
        let children: [UIMenuElement] = isMuted
            ? [muteAction]
            : [muteAction, speedMenu, providerMenu, voiceMenu]
        return UIMenu(title: "", children: children)
    }

    /// Build the Voice submenu for the currently-selected provider.
    /// Network providers list curated voices from `provider.voiceOptions`;
    /// the on-device provider lists every AVSpeech voice on the device.
    private func buildVoiceMenu(for provider: TTSProvider) -> UIMenu {
        switch provider {
        case .system:
            let voices = availableOfflineVoices()
            let currentVoiceId = selectedVoiceIdentifier
            var voiceActions: [UIAction] = [
                UIAction(
                    title: "System default",
                    subtitle: "Use the most lifelike voice on this device",
                    state: currentVoiceId == nil ? .on : .off
                ) { [weak self] _ in
                    self?.selectedVoiceIdentifier = nil
                }
            ]
            voiceActions += voices.map { voice in
                UIAction(
                    title: voice.name,
                    subtitle: voiceQualityLabel(voice.quality),
                    state: voice.identifier == currentVoiceId ? .on : .off
                ) { [weak self] _ in
                    self?.selectedVoiceIdentifier = voice.identifier
                }
            }
            return UIMenu(
                title: "Voice",
                image: UIImage(systemName: "person.wave.2"),
                children: voiceActions
            )

        case .aura2, .elevenLabsV3, .elevenLabsFlashV25, .openAIMiniTTS:
            let currentId = selectedVoiceId(for: provider)
            let actions: [UIAction] = provider.voiceOptions.map { option in
                UIAction(
                    title: option.label,
                    state: option.id == currentId ? .on : .off
                ) { [weak self] _ in
                    self?.setSelectedVoiceId(option.id, for: provider)
                }
            }
            // Show the current voice's friendly label in the submenu title.
            let currentLabel = provider.voiceOptions.first(where: { $0.id == currentId })?.label
                ?? currentId
            return UIMenu(
                title: "Voice — \(currentLabel)",
                image: UIImage(systemName: "person.wave.2"),
                children: actions
            )
        }
    }

    private func availableOfflineVoices() -> [AVSpeechSynthesisVoice] {
        let language = "en-US"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.sorted { a, b in
            if a.quality.rawValue != b.quality.rawValue {
                return a.quality.rawValue > b.quality.rawValue
            }
            return a.name < b.name
        }
    }

    private func voiceQualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        if #available(iOS 16.0, *), quality == .premium { return "Premium" }
        if quality == .enhanced { return "Enhanced" }
        return "Default"
    }
    
    func setupUI() {
        let views: [UIView] = [tableView, messageBox, subAgentStatusBar]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
        }
        subAgentStatusBar.delegate = self
        bottomConstraint = messageBox.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        NSLayoutConstraint.activate([
            subAgentStatusBar.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            subAgentStatusBar.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor),
            subAgentStatusBar.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),

            tableView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            tableView.topAnchor.constraint(equalTo: subAgentStatusBar.bottomAnchor),
            tableView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: messageBox.topAnchor),

            messageBox.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            bottomConstraint!,
            messageBox.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
        ])
        
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(MessagingCell.self, forCellReuseIdentifier: "cell")
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .onDrag
        
        // Enable automatic cell height calculation with better performance
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
        
        // Performance optimizations for smoother scrolling
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderTopPadding = 0
        
        // Reduce cell reuse overhead
        tableView.prefetchDataSource = nil
        
        // Improve scrolling performance
        tableView.delaysContentTouches = false
        // tableView.canCancelContentTouches = true
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // Adjust bottom constraint when the keyboard shows
    @objc func keyboardWillShow(_ notification: Notification) {
        guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboardHeight = keyboardFrame.height
        bottomConstraint?.constant = -keyboardHeight
        
        UIView.animate(withDuration: 0.3, animations: {
            self.view.layoutIfNeeded()
        }, completion: { completed in
            self.scrollToBottom()
        })
    }

    // Reset bottom constraint when the keyboard hides
    @objc func keyboardWillHide(_ notification: Notification) {
        bottomConstraint?.constant = 0
        UIView.animate(withDuration: 0.3) {
            self.view.layoutIfNeeded()
        }
    }
    
    
    @objc func leftBarButtonTapped() {
        showSideDrawer()
    }
    
    @objc func settingsButtonTapped() {
        let settings = SettingsVC()
        let nav = UINavigationController(rootViewController: settings)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    @objc func rightBarButtonTapped() {
        // Create a new conversation
        createNewConversation()
        
        let currentDate = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .medium

        let formattedDate = dateFormatter.string(from: currentDate)
        
        // Update system message with current date
        self.messages[0].content = self.base_system_prompt + " The current date and time is \(formattedDate). Please take this into account when answering questions about whether a place is closed or not."
        
        self.messageIdToAnimate = self.messages.last?.id
        self.tableView.reloadData()
        
    }
    
    // MARK: - Edge Pan Gesture Setup
    
    private func setupEdgePanGesture() {
        edgePanGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleEdgePanGesture(_:)))
        edgePanGestureRecognizer.delegate = self
        view.addGestureRecognizer(edgePanGestureRecognizer)
    }
    
    @objc private func handleEdgePanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let location = gesture.location(in: view)
        let velocity = gesture.velocity(in: view)
        
        switch gesture.state {
        case .began:
            // Only start if gesture begins near the left edge
            if location.x <= 20 && !isEdgePanActive {
                isEdgePanActive = true
                edgePanStartLocation = location
                edgePanStartTime = CACurrentMediaTime()
                
                // Create and show the side drawer
                showSideDrawerForEdgePan()
            }
            
        case .changed:
            if isEdgePanActive {
                // Track the gesture in real-time
                trackEdgePanGesture(translation: translation, velocity: velocity)
            }
            
        case .ended, .cancelled:
            if isEdgePanActive {
                // Complete or cancel based on momentum and distance
                completeEdgePanGesture(translation: translation, velocity: velocity)
                isEdgePanActive = false
            }
            
        default:
            break
        }
    }
    
    private func showSideDrawerForEdgePan() {
        guard sideDrawer == nil else { return }
        
        sideDrawer = SideDrawerViewController()
        sideDrawer?.delegate = self
        
        // Hide navigation bar to allow drawer to fully overlay
        navigationController?.setNavigationBarHidden(true, animated: false)
        
        // Add to window level to truly overlay everything
        let window = view.window ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow })
        if let window = window {
            window.addSubview(sideDrawer!.view)
            
            // Set up proper constraints for the drawer view - full screen overlay at window level
            sideDrawer!.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                sideDrawer!.view.topAnchor.constraint(equalTo: window.topAnchor),
                sideDrawer!.view.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                sideDrawer!.view.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                sideDrawer!.view.bottomAnchor.constraint(equalTo: window.bottomAnchor)
            ])
            
            // Ensure the drawer view is on top of everything at window level
            window.bringSubviewToFront(sideDrawer!.view)
        } else if let navController = navigationController {
            // Fallback to navigation controller
            navController.addChild(sideDrawer!)
            navController.view.addSubview(sideDrawer!.view)
            
            sideDrawer!.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                sideDrawer!.view.topAnchor.constraint(equalTo: navController.view.topAnchor),
                sideDrawer!.view.leadingAnchor.constraint(equalTo: navController.view.leadingAnchor),
                sideDrawer!.view.trailingAnchor.constraint(equalTo: navController.view.trailingAnchor),
                sideDrawer!.view.bottomAnchor.constraint(equalTo: navController.view.bottomAnchor)
            ])
            
            sideDrawer!.didMove(toParent: navController)
            navController.view.bringSubviewToFront(sideDrawer!.view)
        } else {
            // Final fallback to current view controller
            addChild(sideDrawer!)
            view.addSubview(sideDrawer!.view)
            
            sideDrawer!.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                sideDrawer!.view.topAnchor.constraint(equalTo: view.topAnchor),
                sideDrawer!.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                sideDrawer!.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                sideDrawer!.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            
            sideDrawer!.didMove(toParent: self)
            view.bringSubviewToFront(sideDrawer!.view)
        }
        
        // Start the drawer in edge pan tracking mode (completely hidden initially)
        sideDrawer?.startEdgePanTracking()
    }
    
    private func trackEdgePanGesture(translation: CGPoint, velocity: CGPoint) {
        // Send the translation to the side drawer for real-time tracking
        sideDrawer?.updateEdgePanPosition(translation: translation.x)
    }
    
    private func completeEdgePanGesture(translation: CGPoint, velocity: CGPoint) {
        let gestureDuration = CACurrentMediaTime() - edgePanStartTime
        let dragDistance = abs(translation.x)
        let dragVelocity = abs(velocity.x)
        
        // Determine if we should complete the drawer opening
        let shouldComplete: Bool
        
        if dragVelocity > 500 {
            // High velocity - use velocity direction
            shouldComplete = velocity.x > 0
        } else {
            // Low velocity - use distance threshold
            let minDistance: CGFloat = 100 // Minimum distance to complete
            shouldComplete = dragDistance > minDistance
        }
        
        if shouldComplete {
            // Complete the drawer opening
            sideDrawer?.completeEdgePanOpening(velocity: velocity.x, duration: gestureDuration)
        } else {
            // Cancel and close the drawer
            sideDrawer?.cancelEdgePanOpening()
        }
    }
    
    // MARK: - Side Drawer Methods
    
    private func showSideDrawer() {
        guard sideDrawer == nil else { return }
        
        sideDrawer = SideDrawerViewController()
        sideDrawer?.delegate = self
        
        // Hide navigation bar to allow drawer to fully overlay
        navigationController?.setNavigationBarHidden(true, animated: false)
        
        // Add to window level to truly overlay everything
        let window = view.window ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow })
        if let window = window {
            window.addSubview(sideDrawer!.view)
            
            // Set up proper constraints for the drawer view - full screen overlay at window level
            sideDrawer!.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                sideDrawer!.view.topAnchor.constraint(equalTo: window.topAnchor),
                sideDrawer!.view.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                sideDrawer!.view.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                sideDrawer!.view.bottomAnchor.constraint(equalTo: window.bottomAnchor)
            ])
            
            // Ensure the drawer view is on top of everything at window level
            window.bringSubviewToFront(sideDrawer!.view)
        } else if let navController = navigationController {
            // Fallback to navigation controller
            navController.addChild(sideDrawer!)
            navController.view.addSubview(sideDrawer!.view)
            
            sideDrawer!.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                sideDrawer!.view.topAnchor.constraint(equalTo: navController.view.topAnchor),
                sideDrawer!.view.leadingAnchor.constraint(equalTo: navController.view.leadingAnchor),
                sideDrawer!.view.trailingAnchor.constraint(equalTo: navController.view.trailingAnchor),
                sideDrawer!.view.bottomAnchor.constraint(equalTo: navController.view.bottomAnchor)
            ])
            
            sideDrawer!.didMove(toParent: navController)
            navController.view.bringSubviewToFront(sideDrawer!.view)
        } else {
            // Final fallback to current view controller
            addChild(sideDrawer!)
            view.addSubview(sideDrawer!.view)
            
            sideDrawer!.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                sideDrawer!.view.topAnchor.constraint(equalTo: view.topAnchor),
                sideDrawer!.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                sideDrawer!.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                sideDrawer!.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            
            sideDrawer!.didMove(toParent: self)
            view.bringSubviewToFront(sideDrawer!.view)
        }
        
        // Force layout to ensure proper sizing before animation
        sideDrawer!.view.setNeedsLayout()
        sideDrawer!.view.layoutIfNeeded()
        
        // Start with drawer in closed position
        sideDrawer!.prepareForButtonOpening()
        
        // Explicitly open the drawer for button-triggered opening
        DispatchQueue.main.async {
            self.sideDrawer?.openDrawer()
        }
    }
}

extension MessagingVC: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let addional_cell_count = self.ai_state != .None ? 1 : 0
        return self.visible_messages.count + addional_cell_count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row == self.visible_messages.count {
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MessagingCell
            cell.setAnimationState(state: self.ai_state)
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MessagingCell
        let message = self.visible_messages[indexPath.row]
        cell.setData(data: message, shouldAnimate: message.id == self.messageIdToAnimate)
        if message.id == self.messageIdToAnimate {
            self.messageIdToAnimate = nil
        }
        // Reapply any in-flight or completed TTS status so cells coming back
        // from reuse don't lose their spinner / "| 2.03s to audio" suffix.
        cell.setTTSStatus(ttsStatuses[message.id] ?? .none)
        // Image-bubble cells get a delegate so download/retry taps route back
        // through this VC. Reuse-safe: the delegate is reapplied on every
        // dequeue and the cell stores the active attachment id.
        cell.imageDelegate = self

        return cell
    }

    /// Mark `messageId`'s TTS as in-flight (spinner) and find the on-screen
    /// cell to update without reloading the row (which would restart the
    /// typing animation and dump scroll position).
    ///
    /// Callable from any thread — the network completion handlers that drive
    /// processMessage land on URLSession's delegate queue. We hop to main
    /// before touching `tableView` / the cell or mutating `ttsStatuses`, so
    /// dictionary reads and AutoLayout stay on a single thread.
    private func setTTSStatus(_ status: MessagingCell.TTSStatus, for messageId: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setTTSStatus(status, for: messageId)
            }
            return
        }
        ttsStatuses[messageId] = status
        guard let idx = visible_messages.firstIndex(where: { $0.id == messageId }) else { return }
        let indexPath = IndexPath(row: idx, section: 0)
        if let cell = tableView.cellForRow(at: indexPath) as? MessagingCell {
            cell.setTTSStatus(status)
        }
    }

    /// Stamp the start time AND set the spinner status. Wrapped in a single
    /// main-thread hop so callers (which may live on a network completion
    /// thread) don't have to know about the threading invariants.
    fileprivate func markTTSStarted(forMessageId messageId: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.markTTSStarted(forMessageId: messageId)
            }
            return
        }
        ttsStartTimes[messageId] = Date()
        setTTSStatus(.generating, for: messageId)
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
    
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return 100
    }
}

// MARK: - UIGestureRecognizerDelegate

extension MessagingVC: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Don't allow simultaneous recognition with the side drawer's pan gesture
        if let sideDrawerPan = sideDrawer?.panGestureRecognizer, otherGestureRecognizer == sideDrawerPan {
            return false
        }
        // Allow the edge pan gesture to work alongside other gestures
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Only respond to touches that start near the left edge and when side drawer is not open
        let location = touch.location(in: view)
        return location.x <= 20 && sideDrawer == nil
    }
}

// MARK: - SideDrawerDelegate

extension MessagingVC: SideDrawerDelegate {
    func sideDrawerDidClose() {
        guard let drawer = sideDrawer else { return }
        
        // Show navigation bar again when drawer closes
        navigationController?.setNavigationBarHidden(false, animated: true)
        
        // Remove from window if it was added there
        if let window = drawer.view.superview as? UIWindow {
            drawer.view.removeFromSuperview()
        } else if let navController = navigationController, drawer.parent == navController {
            drawer.willMove(toParent: nil)
            drawer.view.removeFromSuperview()
            drawer.removeFromParent()
        } else if drawer.parent == self {
            drawer.willMove(toParent: nil)
            drawer.view.removeFromSuperview()
            drawer.removeFromParent()
        }
        
        sideDrawer = nil
    }
    
    func sideDrawerDidSelectConversation(_ conversation: Conversation?) {
        if let conversation = conversation {
            // Load the selected conversation
            if let conversationEntity = conversationManager.getConversation(by: conversation.id) {
                loadConversation(conversationEntity)
            }
        } else {
            // Create new conversation
            createNewConversation()
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension MessagingVC: AVAudioPlayerDelegate {
    /// Begin polling the player's metering and publishing it as the
    /// speaking-mode amplitude. Call this immediately after `play()` for
    /// any AVAudioPlayer-backed TTS path. The timer is torn down in
    /// `stopTTSMetering()` (in didFinishPlaying / decode error / stop).
    func startTTSMetering(for player: AVAudioPlayer) {
        ttsMeteringTimer?.invalidate()
        player.isMeteringEnabled = true
        ttsMeteringTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak player] _ in
            guard let player = player, player.isPlaying else { return }
            player.updateMeters()
            let db = player.averagePower(forChannel: 0)
            // dB → linear with a normalization band. -50 dB ≈ inaudible,
            // 0 dB ≈ peak. Map [-50, 0] → [0, 1].
            let normalized = max(0, min(1, (db + 50.0) / 50.0))
            VoiceLoopCoordinator.shared.publishOutputAmplitude(Float(normalized))
            _ = self  // silence "unused capture" since we may not need self body
        }
    }

    func stopTTSMetering() {
        ttsMeteringTimer?.invalidate()
        ttsMeteringTimer = nil
        VoiceLoopCoordinator.shared.publishOutputAmplitude(0)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Audio finished playing
        currentSpeechMessageId = nil
        speechBuffer = ""
        audioPlayer = nil
        stopTTSMetering()
        VoiceLoopCoordinator.shared.setState(.idle)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        // Audio decode error
        print("Audio decode error: \(error?.localizedDescription ?? "unknown")")
        currentSpeechMessageId = nil
        speechBuffer = ""
        audioPlayer = nil
        stopTTSMetering()
        VoiceLoopCoordinator.shared.setState(.idle)
    }
}

// MARK: - AVSpeechSynthesizerDelegate (offline TTS)

extension MessagingVC: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Only clear if this is still the active offline turn — a new turn
            // would have already reset these via stopSpeaking().
            if let id = self.offlineSpeechMessageId, self.currentSpeechMessageId == id {
                self.currentSpeechMessageId = nil
                self.speechBuffer = ""
            }
            self.offlineSpeechMessageId = nil
            VoiceLoopCoordinator.shared.setState(.idle)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // No-op — stopSpeaking() already cleared state synchronously, and a new
        // turn may have already started by the time this delegate callback fires.
    }
}

// MARK: - Streaming TTS (Deepgram Aura-2 over WebSocket)

extension MessagingVC {

    /// Open a Deepgram TTS WebSocket and stream the spoken response. Returns
    /// true if the streaming path took ownership; false on any setup failure
    /// (in which case the caller falls back to AVSpeechSynthesizer).
    fileprivate func beginDeepgramSpeak(text: String, messageId: String) -> Bool {
        guard let apiKey = MessagingVC.deepgramAPIKey else { return false }

        // Match the existing playback session config so we don't fight the mic
        // engine if it was just torn down.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("DeepgramTTS: audio session setup failed (\(error)) — falling back")
            return false
        }

        let voiceId = self.selectedVoiceId(for: .aura2)
        let tts = DeepgramTTS(apiKey: apiKey, voice: voiceId, speed: speechSpeed.deepgramRate)
        // If Aura gets ANY PCM out before erroring, we treat the turn as
        // hers and skip the cloud + offline fallback — replaying the full
        // text on top of partial Aura speech is more jarring than just
        // stopping at the partial. Flipped only on main, read only on main.
        var didReceiveAudio = false
        tts.onFirstAudio = { [weak self] in
            DispatchQueue.main.async {
                didReceiveAudio = true
                self?.markAudioReady(forMessageId: messageId)
            }
        }
        tts.onError = { [weak self] err in
            print("DeepgramTTS error: \(err)")
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Only fall back if this is still the current speech turn.
                guard self.currentSpeechMessageId == messageId else { return }
                self.deepgramTTS = nil
                if didReceiveAudio {
                    // Aura already streamed some speech to the user — don't
                    // double up by running the whole text again through
                    // offline TTS. Let the partial stand and end the turn.
                    if self.currentSpeechMessageId == messageId {
                        self.currentSpeechMessageId = nil
                        self.speechBuffer = ""
                    }
                    VoiceLoopCoordinator.shared.setState(.idle)
                    return
                }
                self.speakOffline(text: text, messageId: messageId)
            }
        }
        tts.onFinished = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.currentSpeechMessageId == messageId {
                    self.currentSpeechMessageId = nil
                    self.speechBuffer = ""
                }
                self.deepgramTTS = nil
                VoiceLoopCoordinator.shared.setState(.idle)
            }
        }
        // Real per-buffer RMS into the avatar's speaking-mode pulse.
        // Token-guarded so a stale Aura that we abandoned can't push into
        // the active turn.
        tts.onOutputAmplitude = { [weak self] amp in
            guard let self = self,
                  self.currentSpeechMessageId == messageId else { return }
            VoiceLoopCoordinator.shared.publishOutputAmplitude(amp)
        }

        guard tts.start() else {
            print("DeepgramTTS: engine start failed — falling back")
            return false
        }
        self.deepgramTTS = tts
        tts.speak(text: text)
        print("DeepgramTTS: started speak for message \(messageId)")
        return true
    }
}

// DeepgramTTS lives in SpeechPipeline/DeepgramTTS.swift now — shared with
// the macOS recorder. The class is identical to what was here.

// MARK: - ElevenLabs v3 + OpenAI gpt-4o-mini-tts (HTTP, full-buffer playback)
//
// Both providers fetch the entire utterance as MP3 bytes and play via
// AVAudioPlayer. Slower first-byte than Aura-2's WS streaming, but the
// quality jump (especially on lists and emotional prosody) is the point.
// Switch by changing TTSProvider.active.

extension MessagingVC {

    /// Default ElevenLabs voice. Rachel — clear, warm, common default. Override
    /// by adding ELEVEN_LABS_VOICE_ID to Info.plist.
    fileprivate static let elevenLabsDefaultVoiceId = "21m00Tcm4TlvDq8ikWAM"

    /// Default OpenAI voice. "shimmer" is warm and conversational. Override
    /// via OPENAI_TTS_VOICE in Info.plist (alloy, echo, fable, onyx, nova,
    /// shimmer, coral, sage, ash, ballad, verse).
    fileprivate static let openAIDefaultVoice = "shimmer"

    /// Steers OpenAI's gpt-4o-mini-tts toward better list pacing and warmth.
    /// Aura-2 ignores this; ElevenLabs has its own prosody model.
    fileprivate static let openAITTSInstructions = """
    Speak in a warm, natural, conversational tone. When reading lists, pause \
    briefly between items so each one is distinct. Vary pace and emphasis \
    like a person would.
    """

    fileprivate func beginElevenLabsSpeak(text: String, messageId: String, modelId: String) -> Bool {
        guard let apiKey = MessagingVC.elevenLabsAPIKey else { return false }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("ElevenLabsTTS: audio session setup failed (\(error)) — falling back")
            return false
        }

        // Flash v2.5 uses the same voice library as v3 but has its own
        // per-provider persisted selection so users can mix and match.
        let provider: TTSProvider = (modelId == "eleven_flash_v2_5") ? .elevenLabsFlashV25 : .elevenLabsV3
        let voiceId = self.selectedVoiceId(for: provider)
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)") else {
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.4,
                "use_speaker_boost": true
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        req.httpBody = bodyData

        let speed = self.speechSpeed.deepgramRate
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // If a newer turn has started, drop this audio.
                guard self.currentSpeechMessageId == messageId else { return }

                if let error = error {
                    print("ElevenLabsTTS error: \(error) — falling back")
                    self.fallbackToOffline(text: text, messageId: messageId)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                    print("ElevenLabsTTS HTTP \(http.statusCode): \(bodyStr) — falling back")
                    self.fallbackToOffline(text: text, messageId: messageId)
                    return
                }
                guard let data = data, !data.isEmpty else {
                    print("ElevenLabsTTS empty response — falling back")
                    self.fallbackToOffline(text: text, messageId: messageId)
                    return
                }
                self.playMP3Data(data, messageId: messageId, speed: speed, providerLabel: "ElevenLabs")
            }
        }.resume()

        print("ElevenLabsTTS: request sent for message \(messageId)")
        return true
    }

    fileprivate func beginOpenAISpeak(text: String, messageId: String) -> Bool {
        guard let apiKey = MessagingVC.openAIAPIKey else { return false }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("OpenAITTS: audio session setup failed (\(error)) — falling back")
            return false
        }

        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let voice = self.selectedVoiceId(for: .openAIMiniTTS)
        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "input": text,
            "voice": voice,
            "response_format": "mp3",
            "instructions": MessagingVC.openAITTSInstructions
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        req.httpBody = bodyData

        let speed = self.speechSpeed.deepgramRate
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.currentSpeechMessageId == messageId else { return }

                if let error = error {
                    print("OpenAITTS error: \(error) — falling back")
                    self.fallbackToOffline(text: text, messageId: messageId)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                    print("OpenAITTS HTTP \(http.statusCode): \(bodyStr) — falling back")
                    self.fallbackToOffline(text: text, messageId: messageId)
                    return
                }
                guard let data = data, !data.isEmpty else {
                    print("OpenAITTS empty response — falling back")
                    self.fallbackToOffline(text: text, messageId: messageId)
                    return
                }
                self.playMP3Data(data, messageId: messageId, speed: speed, providerLabel: "OpenAI")
            }
        }.resume()

        print("OpenAITTS: request sent for message \(messageId)")
        return true
    }

    /// Shared MP3-buffer playback path. Used by ElevenLabs + OpenAI.
    /// `enableRate = true` lets AVAudioPlayer.rate apply speechSpeed without
    /// chipmunking pitch.
    private func playMP3Data(_ data: Data, messageId: String, speed: Double, providerLabel: String) {
        guard self.currentSpeechMessageId == messageId else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.enableRate = true
            player.rate = Float(max(0.5, min(2.0, speed)))
            self.audioPlayer = player
            player.play()
            self.markAudioReady(forMessageId: messageId)
            print("\(providerLabel)TTS: playback started for \(messageId)")
        } catch {
            print("\(providerLabel)TTS playback error: \(error) — falling back to offline")
            self.speakOffline(text: "", messageId: messageId)
        }
    }

    /// AVSpeechSynthesizer fallback used when the chosen streaming provider
    /// fails mid-turn.
    private func fallbackToOffline(text: String, messageId: String) {
        guard self.currentSpeechMessageId == messageId else { return }
        speakOffline(text: text, messageId: messageId)
    }
}

// MARK: - MessagingCellImageDelegate

extension MessagingVC: MessagingCellImageDelegate {

    /// Save the image to the user's Photos library. Requires
    /// NSPhotoLibraryAddUsageDescription in Info.plist; iOS will prompt the
    /// first time and silently no-op on subsequent calls if denied.
    func messagingCellDidTapDownload(attachmentId: String) {
        guard let attachment = self.messages.compactMap({ $0.imageAttachment })
                .first(where: { $0.id == attachmentId }),
              attachment.status == .ready,
              let url = attachment.fileURL,
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return
        }
        UIImageWriteToSavedPhotosAlbum(image, self,
                                       #selector(image(_:didFinishSavingWithError:contextInfo:)),
                                       nil)
    }

    func messagingCellDidTapRetry(attachmentId: String) {
        guard let attachment = self.messages.compactMap({ $0.imageAttachment })
                .first(where: { $0.id == attachmentId }) else {
            return
        }
        // Talk to the service directly so we reuse the same attachment id —
        // the existing placeholder bubble flips back to .generating in place
        // instead of inserting a brand-new row.
        ImageGenerationService.shared.retry(attachmentId: attachmentId,
                                            prompt: attachment.prompt)
    }

    func messagingCellDidTapImage(attachmentId: String, sourceView: UIView) {
        guard let attachment = self.messages.compactMap({ $0.imageAttachment })
                .first(where: { $0.id == attachmentId }),
              attachment.status == .ready,
              let url = attachment.fileURL,
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return
        }
        // Present the viewer wrapped in a UINavigationController so we get
        // the navigation bar with Close + Save buttons for free. Full-screen
        // black canvas keeps the image as the focal point.
        let viewer = ImageViewerVC(image: image) { [weak self] in
            self?.messagingCellDidTapDownload(attachmentId: attachmentId)
        }
        let nav = UINavigationController(rootViewController: viewer)
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = .white
        nav.navigationBar.isTranslucent = true

        // Custom zoom transition out of (and back into) the tapped bubble.
        // `.custom` keeps this view controller's view in the hierarchy behind
        // the viewer so the bubble is there to zoom back into on dismiss.
        let transition = ImageZoomTransitionDelegate(image: image,
                                                     sourceView: sourceView,
                                                     viewer: viewer)
        viewer.zoomTransition = transition       // strong-hold (delegate is weak)
        nav.modalPresentationStyle = .custom
        nav.transitioningDelegate = transition
        present(nav, animated: true)
    }

    @objc private func image(_ image: UIImage,
                             didFinishSavingWithError error: Error?,
                             contextInfo: UnsafeRawPointer) {
        // Lightweight feedback. Could surface a toast/snackbar later — for
        // now log + rely on the system's native Photos permission flow.
        if let error = error {
            print("Image save failed: \(error.localizedDescription)")
        } else {
            print("Image saved to Photos")
        }
    }
}

// MARK: - ImageSkillHost

extension MessagingVC: ImageSkillHost {

    func imageSkillDidStartGenerating(_ attachment: ImageAttachment) {
        // Idempotent: if a placeholder already exists for this attachment id
        // (retry path), flip the existing message back to .generating in
        // place. Otherwise inject a fresh synthetic assistant message so a
        // brand-new generation gets its own bubble.
        if let idx = self.messages.firstIndex(where: { $0.imageAttachment?.id == attachment.id }) {
            self.messages[idx].imageAttachment = attachment
            DispatchQueue.main.async {
                if let visibleIdx = self.visible_messages.firstIndex(where: { $0.imageAttachment?.id == attachment.id }) {
                    let path = IndexPath(row: visibleIdx, section: 0)
                    self.tableView.reloadRows(at: [path], with: .none)
                } else {
                    self.tableView.reloadData()
                }
            }
            return
        }

        let placeholder = MessageStruct(
            id: "image-\(attachment.id)",
            role: "assistant",
            content: "",
            model: "gpt-image-2",
            imageAttachment: attachment
        )
        let conversation = ensureCurrentConversation()
        conversationManager.addMessage(placeholder, to: conversation)
        currentConversationEntity = conversationManager.currentConversation
        self.messages.append(placeholder)
        DispatchQueue.main.async {
            self.tableView.reloadData()
            self.scrollToLastMessage()
        }
    }

    func imageSkillDidFinishGenerating(_ attachment: ImageAttachment) {
        // Find the placeholder we inserted in didStartGenerating and mutate
        // its attachment in place so the cell flips from spinner → image (or
        // → error state) without rebuilding the row's identity.
        guard let idx = self.messages.firstIndex(where: { $0.imageAttachment?.id == attachment.id }) else {
            return
        }
        self.messages[idx].imageAttachment = attachment
        DispatchQueue.main.async {
            // Reload just the row so the typing animation on neighboring
            // messages doesn't restart.
            if let visibleIdx = self.visible_messages.firstIndex(where: { $0.imageAttachment?.id == attachment.id }) {
                let path = IndexPath(row: visibleIdx, section: 0)
                self.tableView.reloadRows(at: [path], with: .none)
            } else {
                self.tableView.reloadData()
            }
        }
    }

    /// Cold-launch sweep — flip any imageAttachment still in .generating to
    /// .failed. The HTTP task that owned them is gone, so we'd otherwise
    /// leave the user staring at a forever-spinner. Called from viewDidLoad
    /// after the initial conversation load.
    fileprivate func cleanupStuckImageGenerations() {
        var changed = false
        for idx in self.messages.indices {
            if var attachment = self.messages[idx].imageAttachment,
               attachment.status == .generating {
                attachment.status = .failed
                attachment.failureReason = "Generation was interrupted (app restart). Tap retry to try again."
                self.messages[idx].imageAttachment = attachment
                changed = true
            }
        }
        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.tableView.reloadData()
            }
        }
    }
}

// MARK: - SlashCommandHost

extension MessagingVC: SlashCommandHost {

    func slashCommandDidRequestNewChat() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Mirror rightBarButtonTapped: spin up a fresh conversation and
            // refresh the system message with the current date.
            self.stopSpeaking()
            self.createNewConversation()

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .long
            dateFormatter.timeStyle = .medium
            let formattedDate = dateFormatter.string(from: Date())
            if !self.messages.isEmpty {
                self.messages[0].content = self.base_system_prompt + " The current date and time is \(formattedDate). Please take this into account when answering questions about whether a place is closed or not."
            }

            self.tableView.reloadData()
        }
    }

    func slashCommandDidRequestReset() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stopSpeaking()
            // Drop every non-system message in memory. Persisted history on
            // the current conversation is left alone — same scope as the
            // existing loadDefaultMessage() helper.
            if !self.messages.isEmpty {
                self.messages = [self.messages[0]]
            }
            self.tableView.reloadData()
        }
    }

    func slashCommandDidRequestCompact(_ compactedMessages: [MessageStruct]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stopSpeaking()
            self.messages = compactedMessages
            self.tableView.reloadData()
        }
    }
}

// MARK: - CalendarSkillHost

import EventKit
import EventKitUI

extension MessagingVC: CalendarSkillHost, EKEventEditViewDelegate {
    /// Present the system event editor pre-filled with the AI's proposed
    /// fields. The user reviews, optionally adds attendees / changes the
    /// time, then taps Save or Cancel. We translate that action into a
    /// `CalendarEditOutcome` and hand it back so the skill can shape its
    /// function result message.
    func calendarSkillRequestsEventEditor(forEvent event: EKEvent,
                                          eventStore: EKEventStore,
                                          completion: @escaping (CalendarEditOutcome) -> Void) {
        let controller = EKEventEditViewController()
        controller.event = event
        controller.eventStore = eventStore
        controller.editViewDelegate = self
        // Stash the completion on an associated object so the delegate can
        // recover it when the editor dismisses. EKEventEditViewDelegate's
        // single callback can't carry arbitrary userInfo, so this is the
        // standard pattern.
        objc_setAssociatedObject(controller,
                                 &CalendarEditorCompletionKey,
                                 completion as Any,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        present(controller, animated: true)
    }

    func eventEditViewController(_ controller: EKEventEditViewController,
                                 didCompleteWith action: EKEventEditViewAction) {
        let completion = objc_getAssociatedObject(controller, &CalendarEditorCompletionKey) as? (CalendarEditOutcome) -> Void
        let outcome: CalendarEditOutcome
        switch action {
        case .saved:     outcome = .saved
        case .canceled:  outcome = .cancelled
        case .deleted:   outcome = .deleted
        @unknown default: outcome = .failed
        }
        controller.dismiss(animated: true) {
            completion?(outcome)
        }
    }
}

// Storage key for the associated-object trick above. Outside the extension
// so it lives in module scope (associated objects need a stable address).
private var CalendarEditorCompletionKey: UInt8 = 0

// MARK: - GitHubSkillHost

extension MessagingVC: GitHubSkillHost {
    /// Present a UIAlertController for any GitHub write tool. Title carries
    /// the action ("Merge PR #42?"), detail carries the body the API will
    /// send. Destructive actions (merge, request-changes review, close-issue)
    /// get a .destructive primary button.
    func githubSkill(requestConfirmation title: String,
                     detail: String,
                     destructive: Bool,
                     completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: title,
            message: detail.isEmpty ? nil : detail,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Confirm",
                                      style: destructive ? .destructive : .default) { _ in
            completion(true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completion(false)
        })
        present(alert, animated: true)
    }
}

// MARK: - SlackSkillHost

extension MessagingVC: SlackSkillHost {
    /// Present a UIAlertController with the proposed Slack message so the
    /// user can review and approve before chat.postMessage fires. The user's
    /// tap IS the confirmation checkpoint — no second ask in chat is needed.
    func slackSkill(requestSendConfirmation channelLabel: String,
                    text: String,
                    completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: "Send Slack message to \(channelLabel)?",
            message: text,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Send", style: .default) { _ in
            completion(true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completion(false)
        })
        present(alert, animated: true)
    }
}

// MARK: - Sub-agent runtime hooks

extension MessagingVC: SubAgentStatusBarDelegate {
    /// Triggered when the user taps the "N sub-agents running" pill at the
    /// top of the chat. Presents the inspector modally.
    func subAgentStatusBarTapped() {
        // Scope the inspector to the conversation we're viewing so only this
        // thread's agents show up — same filter the pill itself uses.
        let inspector = SubAgentInspectorVC(conversationId: currentConversationEntity?.id)
        let nav = UINavigationController(rootViewController: inspector)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    /// Fired when a sub-agent's completion summary lands in the parent
    /// conversation. If the user has that conversation on screen, reload to
    /// show the bubble immediately.
    @objc func handleSubAgentMessage(_ notification: Notification) {
        guard let conversationId = notification.userInfo?["conversationId"] as? String,
              let current = currentConversationEntity,
              current.id == conversationId else {
            return
        }
        // Reload from store so the freshly-posted message becomes visible.
        if let refreshed = conversationManager.getConversation(by: conversationId) {
            currentConversationEntity = refreshed
            loadMessagesFromConversation(refreshed)
        }
        // Read the sub-agent's response out loud. Scoped to sub-agents only
        // — the Cursor cloud-agent path shares this selector but doesn't
        // want auto-speech (the user is back to the chat to see a PR link,
        // not to hear it). `playMessageSynthesizer` internally calls
        // `stopSpeaking()` before starting, so any in-flight TTS or offline
        // playback is interrupted in the right order.
        guard notification.name == .subAgentDidPostMessage else { return }
        let summary = (notification.userInfo?["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty else { return }
        // Reuse the posted message's id so the TTS spinner appears next to
        // the right bubble.
        let messageId = (notification.userInfo?["messageId"] as? String) ?? UUID().uuidString
        let speechMessage = MessageStruct(id: messageId, role: "assistant", content: summary)
        playMessageSynthesizer(message: speechMessage)
    }
}
