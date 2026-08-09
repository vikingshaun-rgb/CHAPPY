/*
 * ChappyDataBridge — the seam between the new AI layer and your existing data
 *
 * ── THIS FILE WAS WRITTEN BLIND AND HAS NOW BEEN CORRECTED ─────────────
 * The first version guessed at the reminders API. Having read the real
 * LiveAIManager.swift, three of those guesses were wrong, and the real API is
 * better than what I'd assumed:
 *
 *   WRONG:  ChappyReminders.Entry(text:category:) then .shared.add(entry)
 *   RIGHT:  ChappyReminders.shared.add(title:at:place:leadMinutes:…) which
 *           returns a ChappyMemory.Entry. Reminders ARE memories with a
 *           .reminder kind — there is no separate Entry type.
 *
 *   WRONG:  passing a Category when creating a reminder.
 *   RIGHT:  Category is DERIVED, not chosen — ChappyReminders.category(of:)
 *           infers it from provenance. Build 115's note in that file is
 *           explicit that the app never asks, because "every task app on earth
 *           loses people at the dropdown where you pick a list". So the
 *           category argument is gone from this bridge entirely; the model no
 *           longer picks one and cannot pick a wrong one.
 *
 *   WRONG:  scraping JSONL files off disk for the memory digest.
 *   RIGHT:  ChappyMemory.shared.recent is already a published array of
 *           Entry. Reading the store directly is both correct and cheaper.
 *
 * Two further capabilities came free, because the real add() already takes
 * them: `place:` for a place trigger and `leadMinutes:` for a warn-me lead.
 * Both are now plumbed through, so a voice reminder can carry the same
 * trigger and lead that the Reminders screen sets by hand.
 */

import Foundation

@MainActor
enum ChappyDataBridge {

    // MARK: - Reminders

    /// Today's reminders as one spoken-ready line.
    static func remindersBrief() -> String {
        ChappyReminders.shared.briefText()
    }

    /// Create a reminder. Returns a spoken confirmation.
    ///
    /// - Parameters:
    ///   - text: the reminder title, in his own words.
    ///   - date: absolute fire time, or nil for an untimed one.
    ///   - place: optional place trigger — fires when he's there, using the
    ///     existing checkPlaceTriggers machinery rather than a new geofence.
    ///   - leadMinutes: warn-me lead. With a place set this also feeds
    ///     checkLeaveBy, which warns when to LEAVE rather than when it's due.
    @discardableResult
    static func addReminder(text: String,
                            at date: Date?,
                            place: String? = nil,
                            leadMinutes: Int? = nil) -> String {
        let entry = ChappyReminders.shared.add(title: text,
                                               at: date,
                                               place: place,
                                               leadMinutes: leadMinutes,
                                               source: "chappy-ai")

        // Speak back what was actually stored, not what was asked for — the
        // category is inferred and he may want to know which bucket it landed
        // in when it turns up later.
        let cat = ChappyReminders.category(of: entry).label.lowercased()

        if let p = place, !p.isEmpty, date == nil {
            return "Saved under \(cat) — I'll remind you at \(p)."
        }
        guard let d = date else { return "Saved under \(cat): \(text)." }

        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "h:mm a, EEE d MMM"
        let lead = leadMinutes.map { " I'll warn you \($0) minutes before." } ?? ""
        return "Set for \(f.string(from: d)) under \(cat).\(lead)"
    }

    // MARK: - Calendar

    /// Today's diary as one spoken-ready line, or "" if nothing is on.
    static func agenda() -> String {
        ChappyCalendar.shared.agendaLine() ?? ""
    }

    // MARK: - Memory

    /// A compact digest of what Chappy has logged recently, for the proactive
    /// pass and the `recall` tool to reason over.
    ///
    /// Capped hard on both age and line count: memory grows without limit and
    /// an uncapped digest would quietly inflate the token bill on all eight
    /// passes a day.
    static func recentMemoryDigest(days: Int = 3, maxLines: Int = 40) -> String {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let df = DateFormatter()
        df.dateFormat = "EEE h:mm a"

        let lines = ChappyMemory.shared.recent
            .filter { $0.at > cutoff }
            .sorted { $0.at < $1.at }
            .suffix(maxLines)
            .map { e -> String in
                var s = "[\(e.kind.rawValue)] \(df.string(from: e.at)) — \(e.title)"
                if let p = e.place, !p.isEmpty { s += " (at \(p))" }
                else if let c = e.city, !c.isEmpty { s += " (\(c))" }
                if e.doneAt != nil { s += " ✓done" }
                return s
            }

        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }

    /// Anything with a time on it that will fire its own alert — handed to the
    /// proactive pass so it never announces something twice.
    static func selfAlertingReminders() -> [String] {
        ChappyReminders.shared.open
            .filter { $0.effectiveFire != nil && $0.deliveredAt == nil }
            .prefix(12)
            .map(\.title)
    }
}
