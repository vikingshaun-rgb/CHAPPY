/*
 * ChappyTimers — named countdowns that survive a locked phone
 *
 * ADDITIVE FILE. Overwrites nothing.
 *
 * ── WHY A LOCAL NOTIFICATION AND NOT A Timer ───────────────────────────
 * An in-process Timer stops the moment iOS suspends the app, which for a
 * pocketed phone is roughly always. A timer that only works while you are
 * staring at the screen is not a timer. So every countdown is registered as a
 * UNTimeIntervalNotificationTrigger the instant it is set — iOS owns the alarm
 * from then on and it fires whether the app is backgrounded, suspended, or
 * killed outright.
 *
 * The in-process Timer still exists, but only as a nicety: if the app happens
 * to be alive when the countdown ends, Chappy says it out loud as well. Two
 * paths, one alarm — the notification is the source of truth, the speech is a
 * bonus, and the bonus path deliberately does NOT cancel the notification.
 *
 * ── ONE PING, THEN SILENCE ─────────────────────────────────────────────
 * A timer fires once. No nagging, no repeat, no escalation. The notification
 * stays on the lock screen if missed, which is what a lock screen is for.
 * Repeating alarms are the fastest way to make someone disable a feature, and
 * a nagging voice on the way to a job is worse than a missed pasta timer.
 */

import Foundation
import UserNotifications

@MainActor
final class ChappyTimers: ObservableObject {
    static let shared = ChappyTimers()
    private init() { load() }

    // MARK: - Model

    struct Countdown: Codable, Identifiable {
        var id: String
        var name: String
        var fireAt: Date
        var setAt: Date

        var remaining: TimeInterval { max(0, fireAt.timeIntervalSinceNow) }
        var isExpired: Bool { fireAt <= Date() }
    }

    @Published private(set) var active: [Countdown] = []

    private let key = "chappy_timers_active"
    private var tickers: [String: Timer] = [:]

    // MARK: - Setting

    /// Set a countdown of `seconds`. Returns a spoken confirmation.
    @discardableResult
    func set(seconds: TimeInterval, name: String?) -> String {
        guard seconds >= 1 else { return "That's not long enough to time." }
        // A day is the ceiling — longer than that is a reminder, and reminders
        // survive a reboot in a way notification triggers don't deserve to be
        // trusted with.
        guard seconds <= 86_400 else {
            return "Over a day is a reminder rather than a timer — want me to set one?"
        }

        purgeExpired()

        let id = "chappy-timer-\(UUID().uuidString)"
        let label = (name?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.spokenDuration(seconds) + " timer"

        let c = Countdown(id: id, name: label,
                          fireAt: Date().addingTimeInterval(seconds),
                          setAt: Date())
        active.append(c)
        save()

        schedule(c, in: seconds)
        startTicker(c)

        return "\(label) — \(Self.spokenDuration(seconds)) from now."
    }

    /// Set a timer that ends at a wall-clock time rather than after a duration.
    @discardableResult
    func set(at date: Date, name: String?) -> String {
        let secs = date.timeIntervalSinceNow
        guard secs > 0 else { return "That time's already gone." }
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        let label = name ?? "\(f.string(from: date)) timer"
        _ = set(seconds: secs, name: label)
        return "\(label) — set for \(f.string(from: date))."
    }

    // MARK: - Cancelling

    @discardableResult
    func cancel(matching text: String) -> String {
        purgeExpired()
        let q = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let unnamed = q.isEmpty || q == "timer" || q == "the timer" || q == "all"

        // AUDIT FIX: "cancel the timer" with several running used to silently
        // kill all of them. Ask instead — cancelling the wrong one is not
        // recoverable, and he cannot see a list with the phone pocketed.
        if unnamed, active.count > 1 {
            let names = active.map(\.name).joined(separator: ", ")
            return "You've got \(active.count) running — \(names). Which one?"
        }

        let targets = unnamed
            ? active
            : active.filter {
                $0.name.lowercased().contains(q) || q.contains($0.name.lowercased())
            }

        guard !targets.isEmpty else {
            // AUDIT FIX: "No timer by that name" was nonsense when no name
            // had been given.
            return unnamed ? "Nothing running." : "No timer by that name."
        }

        for t in targets { remove(t.id, cancelNotification: true) }
        return targets.count == 1
            ? "\(targets[0].name) cancelled."
            : "\(targets.count) timers cancelled."
    }

    // MARK: - Reading back

    func spokenSummary() -> String {
        purgeExpired()
        guard !active.isEmpty else { return "No timers running." }
        return active
            .sorted { $0.fireAt < $1.fireAt }
            .map { "\($0.name), \(Self.spokenDuration($0.remaining)) left" }
            .joined(separator: ". ")
    }

    /// Names of running timers — the proactive pass needs these so it never
    /// mentions something that is going to announce itself anyway.
    func selfAlertingNames() -> [String] {
        purgeExpired()
        return active.map(\.name)
    }

    // MARK: - Scheduling

    private func schedule(_ c: Countdown, in seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = c.name
        content.body  = "Time's up."
        content.sound = .default
        content.userInfo = ["chappy_timer": true]
        if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds),
                                                        repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: c.id, content: content, trigger: trigger)
        ) { err in
            if let err { print("⏱️ [Timers] schedule failed: \(err.localizedDescription)") }
        }
        print("⏱️ [Timers] \(c.name) in \(Int(seconds))s")
    }

    /// Speaks the timer out loud IF the app is alive when it lands.
    ///
    /// AUDIT FIX: this used to call the same removal path as an explicit
    /// cancel, which pulls the pending notification. Fired microseconds before
    /// iOS delivered it, that erased the lock-screen record of a timer that
    /// had just gone off. The spoken path now only drops the local bookkeeping
    /// and leaves the notification alone.
    private func startTicker(_ c: Countdown) {
        tickers[c.id]?.invalidate()
        let t = Timer(fire: c.fireAt, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active.contains(where: { $0.id == c.id }) else { return }
                ChappyEarcon.shared.done()
                ChappyHaptics.shared.arrival()
                TTSService.shared.speak("\(c.name) — time's up.")
                self.remove(c.id, cancelNotification: false)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tickers[c.id] = t
    }

    // MARK: - Housekeeping

    private func remove(_ id: String, cancelNotification: Bool) {
        if cancelNotification {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [id])
        }
        tickers[id]?.invalidate()
        tickers.removeValue(forKey: id)
        active.removeAll { $0.id == id }
        save()
    }

    /// Drop anything already fired. Called before every read, so a stale
    /// "3 timers running" can never be reported after a relaunch.
    private func purgeExpired() {
        let dead = active.filter(\.isExpired)
        guard !dead.isEmpty else { return }
        for d in dead {
            tickers[d.id]?.invalidate()
            tickers.removeValue(forKey: d.id)
        }
        active.removeAll(where: \.isExpired)
        save()
    }

    /// Re-arm in-process tickers after a relaunch. The notifications are
    /// already lodged with iOS and need no help; this restores only the
    /// spoken half.
    func restoreAfterLaunch() {
        purgeExpired()
        for c in active { startTicker(c) }
        print("⏱️ [Timers] restored \(active.count)")
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(active) else { return }
        UserDefaults.standard.set(d, forKey: key)
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Countdown].self, from: d) else { return }
        active = decoded
    }

    // MARK: - Parsing and phrasing

    /// Turn "ten minutes", "1 hour 30 minutes", "90 seconds" into seconds.
    /// Returns nil when the text carries no duration at all.
    ///
    /// AUDIT FIX (double-count): the unit table contained both "minute" and
    /// "min", and both "second" and "sec". Because "min" is a substring of
    /// "minute", BOTH matched the same words and BOTH added the same number —
    /// every timer was set to exactly twice what was asked for. A ten-minute
    /// parking timer fired at twenty, after the ticket had expired.
    /// Abbreviations are now expanded first and each unit counted once.
    ///
    /// AUDIT FIX (non-determinism): number words were matched by iterating a
    /// Dictionary, whose order is unspecified and varies between launches. For
    /// "forty five" both "five" and "forty five" matched and whichever came
    /// out first won — so the same sentence could mean 45 minutes one day and
    /// 5 the next. Now matched longest-first.
    static func parseDuration(_ text: String) -> TimeInterval? {
        var t = " " + text.lowercased() + " "

        // Fixed idioms first — they don't decompose into number + unit.
        if t.contains("half an hour") || t.contains("half hour") { return 1800 }
        if t.contains("hour and a half") { return 5400 }
        if t.contains("quarter of an hour") { return 900 }

        for (abbr, full) in [("hrs", "hour"), ("hr", "hour"),
                             ("mins", "minute"), ("min", "minute"),
                             ("secs", "second"), ("sec", "second")] {
            t = t.replacingOccurrences(of: "\\b\(abbr)\\b", with: full,
                                       options: .regularExpression)
        }

        let words: [String: Int] = [
            "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4,
            "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20,
            "twenty five": 25, "thirty": 30, "forty": 40, "forty five": 45,
            "fortyfive": 45, "fifty": 50, "sixty": 60, "ninety": 90
        ]
        let wordKeys = words.keys.sorted { $0.count > $1.count }   // longest first

        var total: TimeInterval = 0
        var found = false

        for (unit, multiplier) in [("hour", 3600.0), ("minute", 60.0), ("second", 1.0)] {
            guard let r = t.range(of: unit) else { continue }
            let before = String(t[t.startIndex..<r.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !before.isEmpty else { continue }

            let tail = before.split(separator: " ").suffix(2).joined(separator: " ")

            var n: Double?
            if let digits = tail.split(separator: " ").last.flatMap({ Double($0) }) {
                n = digits
            } else {
                for w in wordKeys where tail == w || tail.hasSuffix(" " + w) {
                    n = Double(words[w] ?? 0); break
                }
            }
            if let n, n > 0 {
                total += n * multiplier
                found = true
            }
        }
        return found ? total : nil
    }

    /// "10 minutes", "1 hour 5 minutes", "45 seconds"
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) second\(s == 1 ? "" : "s")" }
        let mins = s / 60, hrs = mins / 60, remMins = mins % 60
        if hrs == 0 { return "\(mins) minute\(mins == 1 ? "" : "s")" }
        if remMins == 0 { return "\(hrs) hour\(hrs == 1 ? "" : "s")" }
        return "\(hrs) hour\(hrs == 1 ? "" : "s") \(remMins) minute\(remMins == 1 ? "" : "s")"
    }
}
