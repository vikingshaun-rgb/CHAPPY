/*
 * Live AI Mode Manager
 * Live AI mode manager — current mode, custom prompt, translation target language
 */

import Foundation
import SwiftUI

class LiveAIModeManager: ObservableObject {
    static let shared = LiveAIModeManager()

    private let userDefaults = UserDefaults.standard
    private let modeKey = "liveAIMode"
    private let customPromptKey = "liveAICustomPrompt"
    private let translateTargetLanguageKey = "liveAITranslateTargetLanguage"

    @Published var currentMode: LiveAIMode {
        didSet {
            userDefaults.set(currentMode.rawValue, forKey: modeKey)
            print("📋 [LiveAIModeManager] Mode switched: \(currentMode.displayName)")
        }
    }

    @Published var customPrompt: String {
        didSet {
            userDefaults.set(customPrompt, forKey: customPromptKey)
        }
    }

    @Published var translateTargetLanguage: String {
        didSet {
            userDefaults.set(translateTargetLanguage, forKey: translateTargetLanguageKey)
        }
    }

    // Supported translation target languages
    static let supportedLanguages: [(code: String, name: String)] = [
        ("zh-CN", "Chinese"),
        ("en-US", "English"),
        ("ja-JP", "Japanese"),
        ("ko-KR", "한국어"),
        ("fr-FR", "Français"),
        ("de-DE", "Deutsch"),
        ("es-ES", "Español"),
        ("it-IT", "Italiano"),
        ("pt-BR", "Português"),
        ("ru-RU", "Русский")
    ]

    private init() {
        // Load the saved mode
        if let savedMode = userDefaults.string(forKey: modeKey),
           let mode = LiveAIMode(rawValue: savedMode) {
            self.currentMode = mode
        } else {
            self.currentMode = .standard
        }

        // Load the custom prompt
        self.customPrompt = userDefaults.string(forKey: customPromptKey) ?? "liveai.custom.default".localized

        // Load translation target language (defaults to system language)
        if let savedLanguage = userDefaults.string(forKey: translateTargetLanguageKey) {
            self.translateTargetLanguage = savedLanguage
        } else {
            self.translateTargetLanguage = LanguageManager.staticApiLanguageCode
        }
    }

    // MARK: - Get Current System Prompt

    /// Get the full system prompt for the current mode
    func getSystemPrompt() -> String {
        switch currentMode {
        case .custom:
            return customPrompt
        case .translate:
            return getTranslatePrompt()
        default:
            return currentMode.systemPrompt
        }
    }

    /// Get the system prompt for a given mode
    func getSystemPrompt(for mode: LiveAIMode) -> String {
        switch mode {
        case .custom:
            return customPrompt
        case .translate:
            return getTranslatePrompt()
        default:
            return mode.systemPrompt
        }
    }

    /// Get the translate-mode prompt (includes target language)
    private func getTranslatePrompt() -> String {
        let targetLanguageName = Self.supportedLanguages.first { $0.code == translateTargetLanguage }?.name ?? "Chinese"
        let basePrompt = "prompt.liveai.translate".localized
        return basePrompt.replacingOccurrences(of: "{LANGUAGE}", with: targetLanguageName)
    }

    // MARK: - Mode Management

    func setMode(_ mode: LiveAIMode) {
        currentMode = mode
    }

    func setCustomPrompt(_ prompt: String) {
        customPrompt = prompt
    }

    func setTranslateTargetLanguage(_ languageCode: String) {
        translateTargetLanguage = languageCode
    }

    // MARK: - Static Access (for non-SwiftUI contexts)

    static var staticCurrentMode: LiveAIMode {
        return shared.currentMode
    }

    static var staticSystemPrompt: String {
        return shared.getSystemPrompt()
    }

    /// Whether to auto-send an image on voice trigger
    static var staticAutoSendImageOnSpeech: Bool {
        return shared.currentMode.autoSendImageOnSpeech
    }
}
