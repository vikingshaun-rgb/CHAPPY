/*
 * Live Translate ViewModel
 * Live Translate state management
 */

import Foundation
import SwiftUI
import UIKit

@MainActor
class LiveTranslateViewModel: ObservableObject {

    // MARK: - Connection State
    @Published var isConnected = false
    @Published var isRecording = false

    // MARK: - Translation State
    @Published var currentTranslation = ""       // current translation result
    @Published var currentOriginal = ""          // current original text (not yet supported, reserved) 
    @Published var streamingTranslation = ""     // streaming translation chunkchunk
    @Published var translationHistory: [TranslateRecord] = []

    // MARK: - Error State
    @Published var errorMessage: String?
    @Published var showError = false

    // MARK: - Settings (persisted)
    @Published var sourceLanguage: TranslateLanguage {
        didSet {
            UserDefaults.standard.set(sourceLanguage.rawValue, forKey: "translate_source_language")
            updateServiceSettings()
        }
    }

    @Published var targetLanguage: TranslateLanguage {
        didSet {
            UserDefaults.standard.set(targetLanguage.rawValue, forKey: "translate_target_language")
            updateServiceSettings()
        }
    }

    @Published var selectedVoice: TranslateVoice {
        didSet {
            UserDefaults.standard.set(selectedVoice.rawValue, forKey: "translate_voice")
            updateServiceSettings()
        }
    }

    @Published var audioOutputEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioOutputEnabled, forKey: "translate_audio_enabled")
            updateServiceSettings()
        }
    }

    @Published var imageEnhanceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(imageEnhanceEnabled, forKey: "translate_image_enhance")
        }
    }

    /// Use iPhone microphone (instead of the glasses mic) 
    /// Glasses mic suits translating yourself; iPhone mic suits translating the other person
    @Published var usePhoneMic: Bool {
        didSet {
            UserDefaults.standard.set(usePhoneMic, forKey: "translate_use_phone_mic")
        }
    }

    // MARK: - Video Frame (for image enhancement)
    var currentVideoFrame: UIImage?

    // MARK: - Private
    private var translateService: LiveTranslateService?
    private var imageTimer: Timer?

    // MARK: - Init

    init() {
        // Load settings from UserDefaults
        let savedSource = UserDefaults.standard.string(forKey: "translate_source_language") ?? "en"
        self.sourceLanguage = TranslateLanguage(rawValue: savedSource) ?? .en

        let savedTarget = UserDefaults.standard.string(forKey: "translate_target_language") ?? "zh"
        self.targetLanguage = TranslateLanguage(rawValue: savedTarget) ?? .zh

        let savedVoice = UserDefaults.standard.string(forKey: "translate_voice") ?? "Cherry"
        self.selectedVoice = TranslateVoice(rawValue: savedVoice) ?? .cherry

        self.audioOutputEnabled = UserDefaults.standard.object(forKey: "translate_audio_enabled") as? Bool ?? true
        self.imageEnhanceEnabled = UserDefaults.standard.object(forKey: "translate_image_enhance") as? Bool ?? false
        self.usePhoneMic = UserDefaults.standard.object(forKey: "translate_use_phone_mic") as? Bool ?? false
    }

    // MARK: - Connection

    func connect() {
        let apiKey = APIProviderManager.staticLiveAIAPIKey
        guard !apiKey.isEmpty else {
            errorMessage = "livetranslate.error.noApiKey".localized
            showError = true
            return
        }

        translateService = LiveTranslateService(apiKey: apiKey)
        setupCallbacks()

        translateService?.updateSettings(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            voice: selectedVoice,
            audioEnabled: audioOutputEnabled
        )

        translateService?.connect()
    }

    func disconnect() {
        stopImageTimer()
        translateService?.disconnect()
        translateService = nil
        isConnected = false
        isRecording = false
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        translateService?.startRecording(usePhoneMic: usePhoneMic)
        isRecording = true

        // If image input enabled, start the periodic image timer
        if imageEnhanceEnabled {
            startImageTimer()
        }
    }

    func stopRecording() {
        translateService?.stopRecording()
        isRecording = false
        stopImageTimer()

        // Save the current translation to history
        if !currentTranslation.isEmpty {
            let record = TranslateRecord(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                originalText: currentOriginal,
                translatedText: currentTranslation
            )
            translationHistory.insert(record, at: 0)

            // Cap the history count
            if translationHistory.count > 50 {
                translationHistory = Array(translationHistory.prefix(50))
            }
        }
    }

    // MARK: - Language Swap

    func swapLanguages() {
        // Swap only when both languages are valid targets
        guard sourceLanguage.supportsAudioOutput && targetLanguage.supportsAudioOutput else {
            errorMessage = "livetranslate.error.cannotSwap".localized
            showError = true
            return
        }

        let temp = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = temp

        // Clear the current translation
        currentTranslation = ""
        streamingTranslation = ""
    }

    // MARK: - Video Frame

    func updateVideoFrame(_ frame: UIImage) {
        currentVideoFrame = frame
    }

    // MARK: - Private Methods

    private func setupCallbacks() {
        translateService?.onConnected = { [weak self] in
            DispatchQueue.main.async {
                self?.isConnected = true
                print("✅ [TranslateVM] Connected")
            }
        }

        translateService?.onTranslationDelta = { [weak self] delta in
            DispatchQueue.main.async {
                self?.streamingTranslation += delta
            }
        }

        translateService?.onTranslationText = { [weak self] text in
            DispatchQueue.main.async {
                self?.currentTranslation = text
                self?.streamingTranslation = ""
            }
        }

        translateService?.onAudioDone = { [weak self] in
            DispatchQueue.main.async {
                print("🔊 [TranslateVM] audio playback done")
            }
        }

        translateService?.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.errorMessage = error
                self?.showError = true
            }
        }
    }

    private func updateServiceSettings() {
        translateService?.updateSettings(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            voice: selectedVoice,
            audioEnabled: audioOutputEnabled
        )
    }

    // MARK: - Image Timer

    private func startImageTimer() {
        stopImageTimer()
        imageTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendCurrentFrame()
            }
        }
    }

    private func stopImageTimer() {
        imageTimer?.invalidate()
        imageTimer = nil
    }

    private func sendCurrentFrame() {
        guard imageEnhanceEnabled, let frame = currentVideoFrame else { return }
        translateService?.sendImageFrame(frame)
    }

    // MARK: - Clear

    func clearTranslation() {
        currentTranslation = ""
        streamingTranslation = ""
        currentOriginal = ""
    }

    func clearHistory() {
        translationHistory.removeAll()
    }
}
