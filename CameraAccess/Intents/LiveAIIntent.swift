/*
 * Live AI Intent
 * App Intent - lets Siri and Shortcuts trigger Live AI (runs in background, no unlock required)
 */

import AppIntents
import UIKit

// MARK: - Live AI Intent (Background Mode)

@available(iOS 16.0, *)
struct LiveAIIntent: AppIntent {
    static var title: LocalizedStringResource = "Live Conversation"
    static var description = IntentDescription("Start a real-time multimodal conversation")
    // Must open the App, because iOS restricts background audio recording
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Post a notification so the App automatically opens the Live AI screen
        NotificationCenter.default.post(name: .liveAITriggered, object: nil)
        return .result(dialog: "Starting live conversation...")
    }
}

// MARK: - Stop Live AI Intent

@available(iOS 16.0, *)
struct StopLiveAIIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Live Conversation"
    static var description = IntentDescription("Stop the currently running live conversation")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = LiveAIManager.shared

        if manager.isRunning {
            await manager.stopSession()
            return .result(dialog: "Live AI stopped")
        } else {
            return .result(dialog: "Live AI is not running")
        }
    }
}

// MARK: - Continuous Vision Intent ("Hey Siri, Continuous Vision")

@available(iOS 16.0, *)
struct ContinuousVisionIntent: AppIntent {
    static var title: LocalizedStringResource = "Continuous Vision"
    static var description = IntentDescription("Chappy keeps looking and describing until you say stop")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .continuousVisionTriggered, object: nil)
        return .result(dialog: "Starting continuous vision...")
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let liveAITriggered = Notification.Name("liveAITriggered")
    static let continuousVisionTriggered = Notification.Name("continuousVisionTriggered")
}
