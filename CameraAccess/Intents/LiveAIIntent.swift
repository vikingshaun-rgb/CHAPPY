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


// =====================================================================
// MARK: - BUILD 202 — THE REGISTRY, HANDED TO THE OPERATING SYSTEM
// =====================================================================
//
// Seventeen tools were declared to Chappy and to nobody else. Siri could
// not reach them, Spotlight could not find them, Shortcuts could not
// automate them and the Action button could not fire them.
//
// The registry was already the exact shape App Intents wants — an id, a
// title, typed parameters and a confirmation flag — so this is a
// translation, not a design. One intent with an enumerated parameter
// rather than seventeen separate ones, because the AppShortcutsProvider
// is capped at ten entries and nine are already spent on the vision
// modes.
//
// openAppWhenRun is true for all of them: Chappy needs the microphone,
// the speech recogniser and its own audio session, and iOS does not hand
// those to a background intent.

@available(iOS 16.0, *)
enum ChappyToolChoice: String, AppEnum {
    case flights, travel, visas, currency, translate, weather
    case navigate, food, attractions, reminders, dictate
    case memory, search, atlas, briefs, upcoming, options

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Chappy Tool"

    static var caseDisplayRepresentations: [ChappyToolChoice: DisplayRepresentation] = [
        .flights:     "Flights",
        .travel:      "Travel Desk",
        .visas:       "Visas",
        .currency:    "Currency",
        .translate:   "Translate",
        .weather:     "Weather",
        .navigate:    "Navigation",
        .food:        "Somewhere to eat",
        .attractions: "Something to do",
        .reminders:   "Reminders",
        .dictate:     "Dictate",
        .memory:      "Memory",
        .search:      "Look it up",
        .atlas:       "Atlas",
        .briefs:      "Briefs",
        .upcoming:    "Upcoming",
        .options:     "Trip options",
    ]
}

@available(iOS 16.0, *)
struct ChappyToolIntent: AppIntent {
    static var title: LocalizedStringResource = "Open a Chappy tool"
    static var description = IntentDescription(
        "Start any of Chappy's tools, optionally with the details already filled in.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Tool")
    var tool: ChappyToolChoice

    /// Free text — a destination, a country, a kind of food. Optional,
    /// because the interview will ask for whatever is missing, which is
    /// the whole point of having an interview.
    @Parameter(title: "Details", default: nil)
    var detail: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$tool) in Chappy with \(\.$detail)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var values: [String: String] = [:]
        if let d = detail?.trimmingCharacters(in: .whitespaces), !d.isEmpty {
            // One value, delivered to whichever slot that tool calls its
            // subject. The flow re-parses it — a city name still has to
            // survive the airport table before it counts as an airport.
            switch tool {
            case .flights, .travel:            values["to"] = d
            case .visas:                       values["country"] = d
            case .navigate:                    values["to"] = d
            case .food, .attractions:          values["kind"] = d
            case .translate:                   values["language"] = d
            case .weather:                     values["where"] = d
            case .reminders:                   values["what"] = d
            case .search:                      values["question"] = d
            case .memory:                      values["what"] = d
            default:                           break
            }
        }
        NotificationCenter.default.post(
            name: .chappyStartTool, object: nil,
            userInfo: ["tool": tool.rawValue, "values": values])
        return .result(dialog: "Opening \(tool.rawValue).")
    }
}
