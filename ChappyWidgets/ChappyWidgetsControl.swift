//
//  ChappyWidgetsControl.swift
//  ChappyWidgets
//
//  BUILD 154 — one honest control: a Control Center / lock screen
//  button that opens Chappy. (The template's fake timer is gone.)
//

import AppIntents
import SwiftUI
import WidgetKit

struct OpenChappyIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Chappy"
    static let openAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult { .result() }
}

struct ChappyWidgetsControl: ControlWidget {
    static let kind: String = "com.shaun.chappy.ChappyWidgets"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenChappyIntent()) {
                Label("Chappy", systemImage: "sparkles")
            }
        }
        .displayName("Chappy")
        .description("Opens Chappy.")
    }
}
