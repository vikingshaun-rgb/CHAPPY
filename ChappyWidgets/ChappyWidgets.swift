//
//  ChappyWidgets.swift
//  ChappyWidgets
//
//  BUILD 154 — the day at a glance on the home screen: today's flight
//  (number, time, gate, delay) and the reminder count. Reads the tiny
//  note the app leaves in the App Group; when the App Group capability
//  hasn't been added yet it degrades to a friendly placeholder instead
//  of breaking.
//

import WidgetKit
import SwiftUI

struct GlanceEntry: TimelineEntry {
    let date: Date
    let flightLine: String
    let reminderLine: String
    let hasData: Bool
}

struct GlanceProvider: TimelineProvider {

    private func readGlance() -> GlanceEntry {
        let d = UserDefaults(suiteName: "group.com.shaun.chappy")
        let flight = d?.string(forKey: "glance_flight") ?? ""
        let rem = d?.string(forKey: "glance_reminders") ?? ""
        let at = d?.double(forKey: "glance_at") ?? 0
        let fresh = at > 0 && Date().timeIntervalSince1970 - at < 24 * 3600
        return GlanceEntry(date: Date(),
                           flightLine: flight,
                           reminderLine: rem,
                           hasData: fresh && !(flight.isEmpty && rem.isEmpty))
    }

    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: Date(), flightLine: "✈️ QF52 10:40 AM · Gate 23",
                    reminderLine: "3 reminders today", hasData: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        completion(readGlance())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        // The app pokes reloadAllTimelines on every real change; this
        // half-hour cadence is just the safety net.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        completion(Timeline(entries: [readGlance()], policy: .after(next)))
    }
}

struct ChappyWidgetsEntryView: View {
    var entry: GlanceEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cyan)
                Text("CHAPPY")
                    .font(.caption2).bold().tracking(1.5)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Spacer(minLength: 0)
            if entry.hasData {
                if !entry.flightLine.isEmpty {
                    Text(entry.flightLine)
                        .font(.subheadline).bold()
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                if !entry.reminderLine.isEmpty {
                    Label(entry.reminderLine, systemImage: "checklist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("Flight day and reminders land here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.2),
                                    Color(red: 0.02, green: 0.03, blue: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct ChappyWidgets: Widget {
    let kind: String = "ChappyWidgets"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GlanceProvider()) { entry in
            ChappyWidgetsEntryView(entry: entry)
        }
        .configurationDisplayName("Chappy")
        .description("Today's flight and reminders at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    ChappyWidgets()
} timeline: {
    GlanceEntry(date: .now, flightLine: "✈️ QF52 10:40 AM · Gate 23",
                reminderLine: "3 reminders today", hasData: true)
}
