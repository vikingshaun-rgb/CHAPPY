/*
 * ChappyDataBridge — the single seam between the new AI layer and your data
 *
 * ⚠️ THIS IS THE ONLY FILE THAT NAMES ChappyReminders / ChappyCalendar /
 *    ChappyMemory. If any of the calls below don't match the real API in your
 *    build, the compiler points at a line IN THIS FILE and nowhere else. Fix
 *    it here once and ChappyConversation and ChappyProactive are both correct.
 *
 * WHY THIS EXISTS. Two files need your reminders, your diary and your memory.
 * If each called those stores directly, one renamed method would mean hunting
 * through 900 lines across both. Funnelling every access through a handful of
 * small functions makes a rename a one-line fix in a known place — and it lets
 * the new AI layer drop into the project without me having seen those files.
 *
 * Every function is failure-tolerant: an empty or unavailable store returns an
 * empty string and the callers degrade gracefully. A brief with no calendar
 * line is still useful; a brief that invents a meeting is worse than none.
 */

import Foundation

@MainActor
enum ChappyDataBridge {

    // MARK: - Reminders

    /// Today's reminders as one spoken-ready line.
    /// ⚠️ VERIFY: ChappyReminders.shared.briefText()
    static func remindersBrief() -> String {
        ChappyReminders.shared.briefText()
    }

    /// Create a reminder. Returns a spoken confirmation, or nil on failure.
    /// ⚠️ VERIFY: ChappyReminders.Entry(text:category:), .remindAt, .shared.add(_:)
    static func addReminder(text: String, at date: Date?, category: String) -> String? {
        let cat = reminderCategory(named: category)
        var entry = ChappyReminders.Entry(text: text, category: cat)
        entry.remindAt = date
        ChappyReminders.shared.add(entry)

        guard let d = date else { return "Reminder saved: \(text)." }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "h:mm a, EEE d MMM"
        return "Reminder set for \(f.string(from: d)): \(text)."
    }

    /// ⚠️ VERIFY: the cases of ChappyReminders.Category
    private static func reminderCategory(named s: String) -> ChappyReminders.Category {
        switch s.lowercased() {
        case "work":   return .work
        case "travel": return .travel
        case "money":  return .money
        case "places": return .places
        case "health": return .health
        case "home":   return .home
        default:       return .general
        }
    }

    // MARK: - Calendar

    /// Today's diary as one spoken-ready line, or "" if nothing is on.
    /// ⚠️ VERIFY: ChappyCalendar.shared.agendaLine()
    static func agenda() -> String {
        ChappyCalendar.shared.agendaLine() ?? ""
    }

    // MARK: - Memory

    /// A compact digest of what Chappy has logged recently, for the proactive
    /// pass to reason over. Capped hard: memory grows without limit and an
    /// uncapped digest would quietly inflate the token bill on every call.
    ///
    /// This reads the ChappyMemory JSONL files directly rather than calling an
    /// API, precisely so it cannot break when that API changes. If your memory
    /// files live somewhere other than Documents, change the directory below.
    static func recentMemoryDigest(days: Int = 3, maxLines: Int = 40) -> String {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return "" }

        var candidates: [URL] = []
        for dir in [docs, docs.appendingPathComponent("memory")] {
            let found = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            candidates += found.filter { $0.pathExtension.lowercased() == "jsonl" }
        }
        guard !candidates.isEmpty else { return "" }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let recent = candidates
            .compactMap { url -> (URL, Date)? in
                let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let d, d > cutoff else { return nil }
                return (url, d)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(days)

        var lines: [String] = []
        for (url, _) in recent {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in raw.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let text = (obj["title"] as? String)
                    ?? (obj["text"] as? String)
                    ?? (obj["note"] as? String)
                    ?? (obj["summary"] as? String)
                guard let t = text, !t.isEmpty else { continue }
                let kind = (obj["kind"] as? String).map { "[\($0)] " } ?? ""
                lines.append(kind + t)
            }
        }
        guard !lines.isEmpty else { return "" }
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}
