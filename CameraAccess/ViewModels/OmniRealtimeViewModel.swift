/*
 * Omni Realtime ViewModel
 * Manages real-time multimodal conversation with AI
 * Supports both Alibaba Qwen Omni and Google Gemini Live
 */

import Foundation
import SwiftUI
import AVFoundation

@MainActor
class OmniRealtimeViewModel: ObservableObject {

    // Published state
    @Published var isConnected = false
    @Published var isRecording = false
    @Published var isSpeaking = false
    @Published var currentTranscript = ""
    @Published var conversationHistory: [ConversationMessage] = []
    @Published var errorMessage: String?
    @Published var showError = false

    // Services (use one based on provider)
    private var omniService: OmniRealtimeService?
    private var geminiService: GeminiLiveService?
    private let provider: LiveAIProvider
    private let apiKey: String

    // Video frame
    private var currentVideoFrame: UIImage?
    private var isImageSendingEnabled = false // whether image sending is enabled (after first audio)

    // Steady frame drip for Gemini: the old design only sent a frame on
    // onSpeechStarted, which the Gemini service NEVER fires (it was an
    // Alibaba server event) — so Gemini received zero images and hallucinated.
    // A 1-second timer gives it true live vision.
    private var frameSendTimer: Timer?

    init(apiKey: String) {
        self.apiKey = apiKey
        self.provider = APIProviderManager.staticLiveAIProvider

        // Initialize appropriate service based on provider
        switch provider {
        case .alibaba:
            self.omniService = OmniRealtimeService(apiKey: apiKey)
        case .google:
            self.geminiService = GeminiLiveService(apiKey: apiKey)
        }

        setupCallbacks()
    }

    // MARK: - Setup

    private func setupCallbacks() {
        switch provider {
        case .alibaba:
            setupOmniCallbacks()
        case .google:
            setupGeminiCallbacks()
        }
    }

    private func setupOmniCallbacks() {
        guard let omniService = omniService else { return }

        omniService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
            }
        }

        omniService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                print("✅ [OmniVM] First-audio-sent callback received — enabling image sending")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.isImageSendingEnabled = true
                    print("📸 [OmniVM] Image sending enabled (voice-trigger mode) ")
                }
            }
        }

        omniService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = true

                if let strongSelf = self,
                   strongSelf.isImageSendingEnabled,
                   let frame = strongSelf.currentVideoFrame {
                    print("🎤📸 [OmniVM] User speech detected — sending current video frame")
                    strongSelf.omniService?.sendImageAppend(frame)
                }
            }
        }

        omniService.onSpeechStopped = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
            }
        }

        omniService.onTranscriptDelta = { [weak self] delta in
            Task { @MainActor in
                print("📝 [OmniVM] AIReply chunk: \(delta)")
                self?.currentTranscript += delta
            }
        }

        omniService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self = self else { return }
                print("💬 [OmniVM] Saving user speech: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        omniService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                guard let self = self else { return }
                let textToSave = fullText.isEmpty ? self.currentTranscript : fullText
                guard !textToSave.isEmpty else {
                    print("⚠️ [OmniVM] AI reply empty - skipping save")
                    return
                }
                print("💬 [OmniVM] Saving AI reply: \(textToSave)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: textToSave)
                )
                self.currentTranscript = ""
            }
        }

        omniService.onAudioDone = { [weak self] in
            Task { @MainActor in
                // Audio playback complete
            }
        }

        omniService.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                self?.showError = true
            }
        }
    }

    private func setupGeminiCallbacks() {
        guard let geminiService = geminiService else { return }

        geminiService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
                self?.startFrameSendTimer()
            }
        }

        geminiService.onReadRequest = { [weak self] in
            Task { @MainActor in
                guard let self, let frame = self.currentVideoFrame else { return }
                print("📖 [GeminiVM] Read request — sending high-res frame")
                self.geminiService?.sendHighResImageInput(frame)
            }
        }

        geminiService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                print("✅ [GeminiVM] First-audio-sent callback received — enabling image sending")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.isImageSendingEnabled = true
                    print("📸 [GeminiVM] Image sending enabled (voice-trigger mode) ")
                }
            }
        }

        geminiService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = true

                if let strongSelf = self,
                   strongSelf.isImageSendingEnabled,
                   let frame = strongSelf.currentVideoFrame {
                    print("🎤📸 [GeminiVM] User speech detected — sending current video frame")
                    strongSelf.geminiService?.sendImageInput(frame)
                }
            }
        }

        geminiService.onSpeechStopped = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
            }
        }

        geminiService.onTranscriptDelta = { [weak self] (delta: String) in
            Task { @MainActor in
                print("📝 [GeminiVM] AIReply chunk: \(delta)")
                self?.currentTranscript += delta
            }
        }

        geminiService.onUserTranscript = { [weak self] (userText: String) in
            Task { @MainActor in
                guard let self = self else { return }
                print("💬 [GeminiVM] Saving user speech: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        geminiService.onTranscriptDone = { [weak self] (fullText: String) in
            Task { @MainActor in
                guard let self = self else { return }
                let textToSave = fullText.isEmpty ? self.currentTranscript : fullText
                guard !textToSave.isEmpty else {
                    print("⚠️ [GeminiVM] AI reply empty - skipping save")
                    return
                }
                print("💬 [GeminiVM] Saving AI reply: \(textToSave)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: textToSave)
                )
                self.currentTranscript = ""
            }
        }

        geminiService.onAudioDone = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
            }
        }

        geminiService.onError = { [weak self] (error: String) in
            Task { @MainActor in
                self?.errorMessage = error
                self?.showError = true
            }
        }
    }

    // MARK: - Connection

    func connect() {
        switch provider {
        case .alibaba:
            omniService?.connect()
        case .google:
            geminiService?.connect()
        }
    }

    func disconnect() {
        // Save conversation before disconnecting
        saveConversation()

        frameSendTimer?.invalidate()
        frameSendTimer = nil

        stopRecording()

        switch provider {
        case .alibaba:
            omniService?.disconnect()
        case .google:
            geminiService?.disconnect()
        }

        isConnected = false
        isImageSendingEnabled = false
    }

    private func saveConversation() {
        // Only save if there's meaningful conversation
        guard !conversationHistory.isEmpty else {
            print("💬 [LiveAI] No conversation content — skipping save")
            return
        }

        let aiModel: String
        switch provider {
        case .alibaba:
            aiModel = "qwen3-omni-flash-realtime"
        case .google:
            aiModel = GeminiLiveService.liveModel
        }

        let record = ConversationRecord(
            messages: conversationHistory,
            aiModel: aiModel,
            language: "zh-CN" // TODO: get from settings
        )

        ConversationStorage.shared.saveConversation(record)
        print("💾 [LiveAI] Conversation saved: \(conversationHistory.count)  messages")
    }

    // MARK: - Recording

    func startRecording() {
        guard isConnected else {
            print("⚠️ [LiveAI] Not connected - can't start recording")
            errorMessage = "Please connect to the server first"
            showError = true
            return
        }

        print("🎤 [LiveAI] Start recording (voice-trigger mode) - Provider: \(provider.displayName)")

        switch provider {
        case .alibaba:
            omniService?.startRecording()
        case .google:
            geminiService?.startRecording()
        }

        isRecording = true
    }

    func stopRecording() {
        print("🛑 [LiveAI] Stop recording")

        switch provider {
        case .alibaba:
            omniService?.stopRecording()
        case .google:
            geminiService?.stopRecording()
        }

        isRecording = false
    }

    // MARK: - Video Frames

    func updateVideoFrame(_ frame: UIImage) {
        currentVideoFrame = frame
    }

    /// Send the latest glasses frame to Gemini once per second while connected.
    private func startFrameSendTimer() {
        frameSendTimer?.invalidate()
        frameSendTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isConnected else { return }
                // POCKET MODE: view-driven frame updates STOP when the screen
                // locks (SwiftUI stops rendering), freezing vision on the last
                // image. Pull straight from the stream source so Chappy keeps
                // seeing with the phone locked in a pocket.
                if let liveFrame = LiveAIManager.shared.streamViewModel?.currentVideoFrame {
                    self.currentVideoFrame = liveFrame
                }
                guard let frame = self.currentVideoFrame else { return }
                self.geminiService?.sendImageInput(frame)
            }
        }
        print("📸 [GeminiVM] Frame drip started (2 fps, pocket-safe)")
    }

    // MARK: - Manual Mode (if needed)

    func sendMessage() {
        omniService?.commitAudioBuffer()
    }

    // MARK: - Cleanup

    func dismissError() {
        showError = false
    }

    nonisolated deinit {
        Task { @MainActor [weak omniService, weak geminiService] in
            omniService?.disconnect()
            geminiService?.disconnect()
        }
    }
}

// MARK: - Conversation Message

struct ConversationMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp = Date()

    enum MessageRole {
        case user
        case assistant
    }
}
