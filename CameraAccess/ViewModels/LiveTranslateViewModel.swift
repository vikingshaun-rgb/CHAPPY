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
    // AUDIT FIX support: autostart is consumed once, cost is metered
    private var pendingAutostart = false
    private var suppressSettingsPush = false
    private var sessionStartAt: Date?

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
        var loadedSource = TranslateLanguage(rawValue: savedSource) ?? .en

        let savedTarget = UserDefaults.standard.string(forKey: "translate_target_language") ?? "en"
        var loadedTarget = TranslateLanguage(rawValue: savedTarget) ?? .en

        // ONE-TIME MIGRATION: older builds defaulted to Chinese and that value
        // is still SAVED on phones that ran them (saved values survive updates).
        // Scrub it once; after this the user's own choices always win.
        if !UserDefaults.standard.bool(forKey: "translate_zh_scrubbed_v1") {
            if loadedTarget == .zh {
                loadedTarget = .en
                UserDefaults.standard.set(loadedTarget.rawValue, forKey: "translate_target_language")
            }
            if loadedSource == .zh {
                loadedSource = .en
                UserDefaults.standard.set(loadedSource.rawValue, forKey: "translate_source_language")
            }
            UserDefaults.standard.set(true, forKey: "translate_zh_scrubbed_v1")
        }

        self.sourceLanguage = loadedSource
        self.targetLanguage = loadedTarget

        let savedVoice = UserDefaults.standard.string(forKey: "translate_voice") ?? "Cherry"
        self.selectedVoice = TranslateVoice(rawValue: savedVoice) ?? .cherry

        self.audioOutputEnabled = UserDefaults.standard.object(forKey: "translate_audio_enabled") as? Bool ?? true
        self.imageEnhanceEnabled = UserDefaults.standard.object(forKey: "translate_image_enhance") as? Bool ?? false
        self.usePhoneMic = UserDefaults.standard.object(forKey: "translate_use_phone_mic") as? Bool ?? false
    }

    // MARK: - Connection

    func connect() {
        // AUDIT FIX (HIGH): translate_autostart was only cleared inside
        // onConnected, so ANY failure (no key, no network, cover collision,
        // early dismiss) left it true — and days later a manual visit to
        // Translate would start recording by itself. Read and clear here,
        // before anything can fail.
        pendingAutostart = UserDefaults.standard.bool(forKey: "translate_autostart")
        UserDefaults.standard.set(false, forKey: "translate_autostart")

        // AUDIT FIX (HIGH): a fresh install defaults to en↔en — an interpreter
        // that repeats you back to yourself. Never let source == target.
        if sourceLanguage == targetLanguage {
            targetLanguage = (sourceLanguage == .en) ? .id : .en
            print("🌐 [TranslateVM] source == target — corrected to \(targetLanguage.rawValue)")
        }

        let apiKey = APIProviderManager.staticLiveAIAPIKey
        guard !apiKey.isEmpty else {
            errorMessage = "livetranslate.error.noApiKey".localized
            showError = true
            return
        }
        sessionStartAt = Date()

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
        // AUDIT FIX (CRITICAL): translate minutes were completely invisible to
        // the cost meter — an hour of interpreting reported as $0.00 and never
        // tripped the spend warnings.
        if let start = sessionStartAt {
            CostMeter.shared.addLiveSeconds(Date().timeIntervalSince(start))
            sessionStartAt = nil
        }
        translateService?.disconnect()
        translateService = nil
        isConnected = false
        isRecording = false
        UserDefaults.standard.set(false, forKey: "translate_autostart")
        pendingAutostart = false
        // AUDIT FIX: the wake-word ear comes back after a voice-started
        // translate session (it used to stay dead until the phone came out).
        ChappyStandby.shared.resumeAfterHandOff()
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

        // AUDIT FIX (HIGH): each assignment's didSet pushed settings, so one
        // swap tore down and rebuilt the session TWICE — the second cycle saw
        // wasRecording == false and the mic never came back while the UI still
        // showed red. Suppress the push, then send once.
        suppressSettingsPush = true
        let temp = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = temp
        suppressSettingsPush = false
        updateServiceSettings()

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
                // VOICE-STARTED TRANSLATE: when Chappy opened this by voice
                // ("Chappy, translate"), start listening the moment the line
                // is live — no buttons, mid-conversation ready.
                if self?.pendingAutostart == true {
                    self?.pendingAutostart = false
                    self?.startRecording()
                    print("🎙️ [TranslateVM] Auto-started by voice command")
                }
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
        // AUDIT FIX: guarded so one swap can't fire two teardown/reconnect
        // cycles (which left the mic dead with the UI showing red).
        guard !suppressSettingsPush else { return }
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
