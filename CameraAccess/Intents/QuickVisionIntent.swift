/*
 * Quick Vision Intent
 * App Intent - lets Siri and Shortcuts trigger Quick Vision
 *
 * Supported modes:
 * - Default mode: general image description
 * - Health vision: analyze how healthy a food is
 * - Blind assistance mode: describe surroundings for visually impaired users
 * - Reading mode: recognize and read text aloud
 * - Translation mode: recognize and translate text
 * - Encyclopedia mode: encyclopedia knowledge introduction
 * - Custom: use a custom prompt
 */

import AppIntents
import UIKit
import SwiftUI

// MARK: - Quick Vision Intent (Default Mode)

@available(iOS 16.0, *)
struct QuickVisionIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Vision"
    static var description = IntentDescription("Take a photo with Ray-Ban Meta glasses and identify the image content")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Custom Prompt")
    var customPrompt: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.standard, customPrompt: customPrompt)
        return formatResult(manager)
    }
}

// MARK: - Health Mode Intent

@available(iOS 16.0, *)
struct QuickVisionHealthIntent: AppIntent {
    static var title: LocalizedStringResource = "Health Vision"
    static var description = IntentDescription("Analyze how healthy a food/drink is")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.health)
        return formatResult(manager)
    }
}

// MARK: - Blind Mode Intent

@available(iOS 16.0, *)
struct QuickVisionBlindIntent: AppIntent {
    static var title: LocalizedStringResource = "Describe Surroundings"
    static var description = IntentDescription("Describe the surroundings in detail for visually impaired users")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.blind)
        return formatResult(manager)
    }
}

// MARK: - Reading Mode Intent

@available(iOS 16.0, *)
struct QuickVisionReadingIntent: AppIntent {
    static var title: LocalizedStringResource = "Read Text Aloud"
    static var description = IntentDescription("Recognize and read aloud the text in the image")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.reading)
        return formatResult(manager)
    }
}

// MARK: - Translation Mode Intent

@available(iOS 16.0, *)
struct QuickVisionTranslateIntent: AppIntent {
    static var title: LocalizedStringResource = "Translate Text"
    static var description = IntentDescription("Recognize and translate foreign-language text in the image")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.translate)
        return formatResult(manager)
    }
}

// MARK: - Encyclopedia Mode Intent

@available(iOS 16.0, *)
struct QuickVisionEncyclopediaIntent: AppIntent {
    static var title: LocalizedStringResource = "Encyclopedia Vision"
    static var description = IntentDescription("Identify objects and provide encyclopedia knowledge")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.encyclopedia)
        return formatResult(manager)
    }
}

// MARK: - Helper Function

@available(iOS 16.0, *)
@MainActor
private func formatResult(_ manager: QuickVisionManager) -> some IntentResult & ProvidesDialog {
    if let result = manager.lastResult {
        return .result(dialog: "Recognition complete: \(result)")
    } else if let error = manager.errorMessage {
        return .result(dialog: "Recognition failed: \(error)")
    } else {
        return .result(dialog: "Recognition complete")
    }
}

// MARK: - App Shortcuts Provider

@available(iOS 16.0, *)
struct TurboMetaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Default vision
        AppShortcut(
            intent: QuickVisionIntent(),
            phrases: [
                "Identify this with \(.applicationName)",
                "Use \(.applicationName) to see what this is",
                "\(.applicationName) quick vision",
                "\(.applicationName) take a photo and identify"
            ],
            shortTitle: "Quick Vision",
            systemImageName: "eye.circle.fill"
        )

        // Health vision
        AppShortcut(
            intent: QuickVisionHealthIntent(),
            phrases: [
                "Analyze health with \(.applicationName)",
                "\(.applicationName) health vision",
                "\(.applicationName) is this food healthy"
            ],
            shortTitle: "Health Vision",
            systemImageName: "heart.circle.fill"
        )

        // Blind assistance mode
        AppShortcut(
            intent: QuickVisionBlindIntent(),
            phrases: [
                "Describe surroundings with \(.applicationName)",
                "\(.applicationName) what is around me",
                "\(.applicationName) help me see what's ahead"
            ],
            shortTitle: "Describe Surroundings",
            systemImageName: "figure.walk.circle.fill"
        )

        // Reading mode
        AppShortcut(
            intent: QuickVisionReadingIntent(),
            phrases: [
                "Read text aloud with \(.applicationName)",
                "\(.applicationName) read this",
                "\(.applicationName) read the text for me"
            ],
            shortTitle: "Read Text Aloud",
            systemImageName: "text.viewfinder"
        )

        // Translation mode
        AppShortcut(
            intent: QuickVisionTranslateIntent(),
            phrases: [
                "Translate with \(.applicationName)",
                "\(.applicationName) translate this",
                "\(.applicationName) what does this mean"
            ],
            shortTitle: "Translate Text",
            systemImageName: "character.bubble.fill"
        )

        // Encyclopedia mode
        AppShortcut(
            intent: QuickVisionEncyclopediaIntent(),
            phrases: [
                "Tell me about this with \(.applicationName)",
                "\(.applicationName) encyclopedia vision",
                "\(.applicationName) what is this thing"
            ],
            shortTitle: "Encyclopedia Vision",
            systemImageName: "books.vertical.circle.fill"
        )

        // Live conversation
        AppShortcut(
            intent: LiveAIIntent(),
            phrases: [
                "Start a live conversation with \(.applicationName)",
                "\(.applicationName) live conversation",
                "Start \(.applicationName) live conversation",
                "\(.applicationName) start a conversation"
            ],
            shortTitle: "Live Conversation",
            systemImageName: "brain.head.profile"
        )

        // Stop live conversation
        AppShortcut(
            intent: StopLiveAIIntent(),
            phrases: [
                "\(.applicationName) stop live conversation",
                "Stop \(.applicationName) live conversation",
                "\(.applicationName) end the conversation"
            ],
            shortTitle: "Stop Live Conversation",
            systemImageName: "stop.circle.fill"
        )

        // Continuous vision
        AppShortcut(
            intent: ContinuousVisionIntent(),
            phrases: [
                "\(.applicationName) continuous vision",
                "Start continuous vision with \(.applicationName)",
                "\(.applicationName) keep watching"
            ],
            shortTitle: "Continuous Vision",
            systemImageName: "eye.fill"
        )
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let quickVisionTriggered = Notification.Name("quickVisionTriggered")
}

// MARK: - Quick Vision Manager

@MainActor
class QuickVisionManager: ObservableObject {
    static let shared = QuickVisionManager()

    @Published var isProcessing = false
    @Published var lastResult: String?
    @Published var errorMessage: String?
    @Published var lastImage: UIImage?
    @Published var lastMode: QuickVisionMode = .standard

    // Expose streamViewModel so Intents can check initialization state
    private(set) var streamViewModel: StreamSessionViewModel?
    private let tts = TTSService.shared

    private init() {
        // Listen for Intent triggers
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleQuickVisionTrigger(_:)),
            name: .quickVisionTriggered,
            object: nil
        )
    }

    /// Set the StreamSessionViewModel reference
    func setStreamViewModel(_ viewModel: StreamSessionViewModel) {
        self.streamViewModel = viewModel
    }

    @objc private func handleQuickVisionTrigger(_ notification: Notification) {
        let customPrompt = notification.userInfo?["customPrompt"] as? String
        let modeString = notification.userInfo?["mode"] as? String
        let mode = modeString.flatMap { QuickVisionMode(rawValue: $0) } ?? .standard

        Task { @MainActor in
            await performQuickVisionWithMode(mode, customPrompt: customPrompt)
        }
    }

    /// Perform quick vision using the specified mode
    func performQuickVisionWithMode(_ mode: QuickVisionMode, customPrompt: String? = nil) async {
        guard !isProcessing else {
            print("⚠️ [QuickVision] Already processing")
            return
        }

        guard let streamViewModel = streamViewModel else {
            print("❌ [QuickVision] StreamViewModel not set")
            tts.speak("Vision feature is not initialized. Please open the app first")
            return
        }

        isProcessing = true
        errorMessage = nil
        lastResult = nil
        lastImage = nil
        lastMode = mode

        // Get the API Key
        guard let apiKey = APIKeyManager.shared.getAPIKey(), !apiKey.isEmpty else {
            errorMessage = "Please configure an API Key in Settings first"
            tts.speak("Please configure an API Key in Settings first")
            isProcessing = false
            return
        }

        // Announce start
        tts.speak("Recognizing", apiKey: apiKey)

        // Get the prompt
        let prompt = customPrompt ?? QuickVisionModeManager.shared.getPrompt(for: mode)

        do {
            // 0. Check whether a device is connected
            if !streamViewModel.hasActiveDevice {
                print("❌ [QuickVision] No active device connected")
                throw QuickVisionError.noDevice
            }

            // 1. Start the video stream (if not already started)
            if streamViewModel.streamingStatus != .streaming {
                print("📹 [QuickVision] Starting stream...")
                await streamViewModel.handleStartStreaming()

                // Wait for the stream to enter the streaming state (up to 5 seconds)
                var streamWait = 0
                while streamViewModel.streamingStatus != .streaming && streamWait < 50 {
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 s
                    streamWait += 1
                }

                if streamViewModel.streamingStatus != .streaming {
                    print("❌ [QuickVision] Failed to start streaming")
                    throw QuickVisionError.streamNotReady
                }
            }

            // 2. Wait for the stream to stabilize
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 s

            // 3. Clear the previous photo, then capture
            streamViewModel.dismissPhotoPreview()
            print("📸 [QuickVision] Capturing photo...")
            streamViewModel.capturePhoto()

            // 4. Wait for the photo capture to complete (up to 3 seconds)
            var photoWait = 0
            while streamViewModel.capturedPhoto == nil && photoWait < 30 {
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 s
                photoWait += 1
            }

            // If the SDK capturePhoto fails, fall back to the current video frame
            let photo: UIImage
            if let capturedPhoto = streamViewModel.capturedPhoto {
                photo = capturedPhoto
                print("📸 [QuickVision] Using SDK captured photo")
            } else if let videoFrame = streamViewModel.currentVideoFrame {
                photo = videoFrame
                print("📸 [QuickVision] SDK capturePhoto failed, using video frame as fallback")
            } else {
                print("❌ [QuickVision] No photo or video frame available")
                throw QuickVisionError.frameTimeout
            }

            print("📸 [QuickVision] Photo captured: \(photo.size.width)x\(photo.size.height)")

            // Save the image for history
            lastImage = photo

            // 5. Pre-configure the TTS audio session
            tts.prepareAudioSession()

            // 6. Stop the video stream immediately
            print("🛑 [QuickVision] Stopping stream after capture")
            await streamViewModel.stopSession()

            // 7. Call the vision API
            let service = QuickVisionService(apiKey: apiKey)
            let result = try await service.analyzeImage(photo, customPrompt: prompt)

            // 8. Save the result
            lastResult = result

            // 9. Save to history
            saveToHistory(mode: mode, prompt: prompt, result: result, image: photo)

            // 10. Speak the result via TTS
            tts.speak(result, apiKey: apiKey)

            print("✅ [QuickVision] Complete: \(result)")

        } catch let error as QuickVisionError {
            errorMessage = error.localizedDescription
            print("❌ [QuickVision] QuickVisionError: \(error)")
            tts.speak(error.localizedDescription, apiKey: apiKey)
            await streamViewModel.stopSession()
        } catch {
            errorMessage = error.localizedDescription
            print("❌ [QuickVision] Error: \(error)")
            tts.speak("Recognition failed, \(error.localizedDescription)", apiKey: apiKey)
            await streamViewModel.stopSession()
        }

        isProcessing = false
    }

    /// Perform quick vision (using the currently configured mode)
    func performQuickVision(customPrompt: String? = nil) async {
        await performQuickVisionWithMode(QuickVisionModeManager.staticCurrentMode, customPrompt: customPrompt)
    }

    /// Perform quick vision (triggered from Shortcuts/Siri)
    func performQuickVisionFromIntent(customPrompt: String? = nil) async {
        await performQuickVision(customPrompt: customPrompt)
    }

    /// Save the vision result to history
    private func saveToHistory(mode: QuickVisionMode, prompt: String, result: String, image: UIImage) {
        let record = QuickVisionRecord(
            mode: mode,
            prompt: prompt,
            result: result,
            thumbnail: image
        )
        QuickVisionStorage.shared.saveRecord(record)
        print("💾 [QuickVision] Record saved to history")
    }

    /// Stop the video stream (called when the page closes)
    func stopStream() async {
        await streamViewModel?.stopSession()
    }

    /// Manually trigger quick vision (called from the UI)
    func triggerQuickVision(customPrompt: String? = nil) {
        Task { @MainActor in
            await performQuickVision(customPrompt: customPrompt)
        }
    }

    /// Manually trigger quick vision with the specified mode (called from the UI)
    func triggerQuickVisionWithMode(_ mode: QuickVisionMode) {
        Task { @MainActor in
            await performQuickVisionWithMode(mode)
        }
    }
}
