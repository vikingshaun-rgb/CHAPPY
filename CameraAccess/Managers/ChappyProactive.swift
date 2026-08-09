/*
 * ChappyProactive — scheduled check-ins that earn their interruption
 *
 * ADDITIVE FILE. Overwrites nothing.
 *
 * ── WHAT IT DOES ───────────────────────────────────────────────────────
 * Eight times a day — every two hours across the waking day — Chappy wakes
 * himself, reads the diary, the reminders and the last few days of memory, and
 * works out whether there is anything worth telling you. If there is, you get
 * one notification. If there isn't, and most of the time there isn't, he says
 * nothing at all.
 *
 * ── PASSES ARE NOT NOTIFICATIONS ───────────────────────────────────────
 * This is the whole trick. Eight passes buys RESPONSIVENESS: a job that
 * appears in the diary at ten past ten is noticed by eleven, not at the
 * evening check-in. It does not buy eight interruptions. Three mechanisms sit
 * between a pass and your lock screen:
 *
 *   the notable gate — the model decides most passes warrant nothing
 *   the spacing rule — 75 minutes minimum between routine notifications
 *   the budget       — 4 routine a day, 7 including urgent, then nothing
 *
 * A realistic day is eight passes and one or two notifications. A dull day is
 * eight passes and silence. That is the design working, not failing.
 *
 * ── THE DESIGN IS SHAPED BY WHAT HAS FAILED ELSEWHERE ──────────────────
 *   Alexa's unprompted "by the way…" suggestions annoyed people enough that
 *   Amazon shipped a dedicated voice command to switch them off for good.
 *
 *   The Friend pendant sent unsolicited commentary on your day. Reviewers
 *   called it condescending and hostile. It technically worked.
 *
 *   Meta's Live AI does speak up unprompted on this exact hardware, and
 *   reviewers said they'd keep it off — for privacy, not battery.
 *
 *   ChatGPT Pulse, a proactive morning briefing, launched as a flagship and
 *   was folded away inside a year.
 *
 * The pattern that has NOT failed is the scheduled batched digest — Apple's
 * Notification Summary has run at user-chosen times for years without
 * controversy. So:
 *
 *   1. SCHEDULED, NOT AMBIENT.  Fixed times you choose. Never mid-activity.
 *   2. NOTIFICATION, NOT VOICE. It never speaks unless you ask.
 *   3. SILENT WHEN EMPTY.       No notification unless there is something.
 *   4. BUDGETED.                Ceiling and spacing, independent of frequency.
 *   5. NON-REPEATING.           Each pass sees what it already said today.
 *   6. NEVER DOUBLE-PINGS.      Anything with its own alarm is invisible here.
 *   7. QUIET HOURS.             Nothing fires between the configured hours.
 *
 * ── COST ───────────────────────────────────────────────────────────────
 * Haiku, roughly 5k tokens in and 300 out: about two thirds of a cent a pass.
 * Eight a day is around $1.56/month. The expensive thing in this class of
 * product is always continuous audio capture, which this does not do — it
 * reads data you already have. The reason not to turn the frequency to sixty
 * is attention, not money.
 *
 * ── iOS REALITY CHECK ──────────────────────────────────────────────────
 * iOS will not reliably run code at a chosen minute. BGAppRefresh is
 * opportunistic: the system decides, it may run late, and it never runs if the
 * app was force-quit. So there are three routes to the same result:
 *
 *   a) Background refresh near the slot → full pass, fresh.
 *   b) The app is alive at the slot (Standby often is) → foreground timer.
 *   c) Neither → the next time the app activates it notices and runs late.
 *
 * Between them the pass lands nearly always. Route (c) is why a morning brief
 * can arrive at 9:40 on a day the phone stayed shut.
 */

import Foundation
import UIKit
import UserNotifications
import BackgroundTasks

// MARK: -

@MainActor
final class ChappyProactive: NSObject, ObservableObject {
    static let shared = ChappyProactive()

    /// Must also appear in Info.plist under BGTaskSchedulerPermittedIdentifiers.
    static let taskIdentifier = "com.smartview.glassai.proactive"

    private override init() { super.init() }

    // MARK: - Tuning

    /// Haiku: the cheap tier. If this model string is rejected, swap it for
    /// the one the rest of the app uses — the prompt works on either.
    private let model = "claude-haiku-4-5"
    private let maxTokens = 400

    /// Routine notifications per day. High-urgency ones are exempt.
    private let routineBudget = 4
    /// Absolute ceiling including urgent. Nothing gets through past this.
    private let hardBudget = 7
    /// Minimum quiet gap between routine notifications.
    private let minGapMinutes = 75.0
    /// How many recent briefs the model is shown so it doesn't repeat itself.
    private let repeatMemory = 8

    // MARK: - Settings

    private enum Key {
        static let enabled     = "chappy_proactive_enabled"
        static let times       = "chappy_proactive_times"
        static let quietStart  = "chappy_proactive_quiet_start"
        static let quietEnd    = "chappy_proactive_quiet_end"
        static let lastRunDay  = "chappy_proactive_last_day"
        static let firedToday  = "chappy_proactive_fired_today"
        static let doneSlots   = "chappy_proactive_done_slots"
        static let lastBrief   = "chappy_proactive_last_brief"
        static let lastBriefAt = "chappy_proactive_last_brief_at"
        static let lastNotifAt = "chappy_proactive_last_notif_at"
        static let saidToday   = "chappy_proactive_said_today"
    }

    private let d = UserDefaults.standard

    var isEnabled: Bool {
        get { d.object(forKey: Key.enabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.enabled); if newValue { scheduleBackgroundTask() } }
    }

    /// Eight passes, every two hours across the waking day. A PASS is not a
    /// NOTIFICATION — see the gate above.
    var times: [String] {
        get {
            (d.array(forKey: Key.times) as? [String]) ?? [
                "07:00", "09:00", "11:00", "13:00",
                "15:00", "17:00", "19:00", "21:00"
            ]
        }
        set { d.set(newValue.sorted(), forKey: Key.times) }
    }

    var quietStartHour: Int {
        get { d.object(forKey: Key.quietStart) as? Int ?? 22 }
        set { d.set(newValue, forKey: Key.quietStart) }
    }

    var quietEndHour: Int {
        get { d.object(forKey: Key.quietEnd) as? Int ?? 7 }
        set { d.set(newValue, forKey: Key.quietEnd) }
    }

    /// `private(set)` IS legal on a computed property with both accessors —
    /// it's only rejected on read-only ones. An access modifier on the `set`
    /// KEYWORD, however, is a parse error.
    private(set) var lastBrief: String {
        get { d.string(forKey: Key.lastBrief) ?? "" }
        set { d.set(newValue, forKey: Key.lastBrief) }
    }

    // MARK: - Lifecycle

    /// Call from app launch, BEFORE launching finishes — a BGTaskScheduler
    /// requirement, not a preference.
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false); return
            }
            Task { @MainActor in self.handleBackgroundRefresh(refresh) }
        }
        UNUserNotificationCenter.current().delegate = self
        print("🔔 [Proactive] background task registered")
    }

    func start() {
        guard isEnabled else { return }
        requestNotificationPermission()
        scheduleBackgroundTask()
        installForegroundWatch()
        Task { await runDuePass(reason: "launch") }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { ok, err in
                if let err { print("🔔 [Proactive] auth error: \(err.localizedDescription)") }
                else { print("🔔 [Proactive] notifications \(ok ? "granted" : "denied")") }
            }
    }

    private func scheduleBackgroundTask() {
        let req = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        req.earliestBeginDate = nextSlotDate()
        do { try BGTaskScheduler.shared.submit(req) }
        catch { print("🔔 [Proactive] submit failed: \(error.localizedDescription)") }
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundTask()   // always re-arm first
        let work = Task { @MainActor in
            await runDuePass(reason: "background")
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    private var foregroundTimer: Timer?
    /// AUDIT FIX: start() is documented as callable whenever settings change,
    /// and each call used to add another didBecomeActive observer while only
    /// invalidating the timer — so after three settings changes a single
    /// foregrounding ran four passes.
    private var activeObserver: NSObjectProtocol?

    private func installForegroundWatch() {
        foregroundTimer?.invalidate()
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runDuePass(reason: "foreground") }
        }
        RunLoop.main.add(t, forMode: .common)
        foregroundTimer = t

        if let o = activeObserver { NotificationCenter.default.removeObserver(o) }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.runDuePass(reason: "activate") }
        }
    }

    // MARK: - Scheduling maths

    private func hhmm(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// AUDIT FIX: saidToday was never cleared, so yesterday's briefs kept
    /// suppressing today's — the model was told not to repeat things it had
    /// said days earlier, and the verbatim guard killed genuinely new briefs.
    private func rollDayIfNeeded() {
        let today = dayKey(Date())
        guard d.string(forKey: Key.lastRunDay) != today else { return }
        d.set(today, forKey: Key.lastRunDay)
        d.set(0, forKey: Key.firedToday)
        d.set([String](), forKey: Key.doneSlots)
        d.set([String](), forKey: Key.saidToday)
    }

    private var firedToday: Int {
        get { d.integer(forKey: Key.firedToday) }
        set { d.set(newValue, forKey: Key.firedToday) }
    }

    private var doneSlots: [String] {
        get { (d.array(forKey: Key.doneSlots) as? [String]) ?? [] }
        set { d.set(newValue, forKey: Key.doneSlots) }
    }

    private func inQuietHours(_ date: Date) -> Bool {
        let h = Calendar.current.component(.hour, from: date)
        let s = quietStartHour, e = quietEndHour
        return s > e ? (h >= s || h < e) : (h >= s && h < e)
    }

    private func nextSlotDate() -> Date {
        let cal = Calendar.current
        let now = Date()
        if let next = times.compactMap({ slotDate($0, on: now) }).filter({ $0 > now }).min() {
            return next
        }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        return times.compactMap { slotDate($0, on: tomorrow) }.min()
            ?? now.addingTimeInterval(3600)
    }

    private func slotDate(_ hhmm: String, on day: Date) -> Date? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: day)
    }

    /// The slot currently due, if any.
    ///
    /// A slot stays due for a while so a phone shut at 07:00 still gets its
    /// morning pass on waking. That grace window MUST be shorter than the gap
    /// between slots: with eight slots two hours apart and the old hardcoded
    /// three-hour window, at 11:05 both 09:00 and 11:00 were due and two
    /// passes fired back to back — the older one reasoning about a morning
    /// already gone. It is now derived from the real spacing, and takes the
    /// LATEST due slot: a phone off all morning wants the 11:00 read of the
    /// day, not the 07:00 one.
    private func dueSlot() -> String? {
        let now = Date()
        let sorted = times.sorted()
        let grace = min(graceWindow(for: sorted), 3 * 3600)

        var best: String?
        for slot in sorted {
            guard let start = slotDate(slot, on: now) else { continue }
            guard now >= start, now <= start.addingTimeInterval(grace) else { continue }
            guard !doneSlots.contains(slot) else { continue }
            best = slot
        }
        return best
    }

    private func graceWindow(for sorted: [String]) -> TimeInterval {
        guard sorted.count > 1 else { return 3600 }
        let day = Date()
        let stamps = sorted.compactMap { slotDate($0, on: day)?.timeIntervalSince1970 }
        guard stamps.count > 1 else { return 3600 }
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        return max(900, (gaps.min() ?? 3600) * 0.9)
    }

    // MARK: - The pass

    private var isRunning = false

    func runDuePass(reason: String) async {
        guard isEnabled, !isRunning else { return }
        rollDayIfNeeded()

        guard !inQuietHours(Date()) else { return }
        guard firedToday < hardBudget else { return }
        guard let slot = dueSlot() else { return }

        isRunning = true
        defer { isRunning = false }
        print("🔔 [Proactive] running \(slot) pass (\(reason))")

        // Mark done BEFORE the network call. If it fails we do not want three
        // retries producing three notifications an hour later.
        doneSlots = doneSlots + [slot]

        // Daily housekeeping rides along with whichever pass runs first —
        // no extra schedule, no extra wake-ups.
        await ChappyMemoryKeeper.shared.nudgeIfDue()      // consolidate the profile
        await ChappyPhotoIngest.shared.ingestIfDue()      // glasses photos, if charging on wi-fi

        guard let brief = await composeBrief(slot: slot) else { return }

        lastBrief = brief.spoken
        d.set(Date(), forKey: Key.lastBriefAt)

        guard brief.notable else {
            print("🔔 [Proactive] \(slot): nothing notable — staying quiet")
            return
        }
        guard passesGate(brief) else { return }

        firedToday += 1
        d.set(Date(), forKey: Key.lastNotifAt)
        rememberSaid(brief.spoken)
        deliver(headline: brief.headline, body: brief.spoken, urgent: brief.urgency == .high)
    }

    /// Rate-limit notable briefs so eight passes never become eight pings.
    private func passesGate(_ brief: Brief) -> Bool {
        if brief.urgency == .high {
            print("🔔 [Proactive] urgent — bypassing gap and routine budget")
            return true
        }
        if firedToday >= routineBudget {
            print("🔔 [Proactive] routine budget spent (\(firedToday)/\(routineBudget)) — holding")
            return false
        }
        if let last = d.object(forKey: Key.lastNotifAt) as? Date {
            let mins = Date().timeIntervalSince(last) / 60
            if mins < minGapMinutes {
                print(String(format: "🔔 [Proactive] only %.0f min since last — holding", mins))
                return false
            }
        }
        return true
    }

    /// Run a pass now regardless of schedule — settings "test" button, or
    /// "Chappy, brief me".
    func runNow() async {
        rollDayIfNeeded()
        guard let brief = await composeBrief(slot: hhmm(Date())) else {
            TTSService.shared.speak("Couldn't put a brief together just now.")
            return
        }
        lastBrief = brief.spoken
        d.set(Date(), forKey: Key.lastBriefAt)
        TTSService.shared.speak(brief.spoken.isEmpty ? "Nothing worth flagging." : brief.spoken)
    }

    /// Speak the most recent brief without spending anything.
    /// AUDIT FIX: this used to read out a brief from days ago with no hint of
    /// its age.
    func speakLastBrief() {
        let b = lastBrief
        guard !b.isEmpty else { TTSService.shared.speak("No brief yet today."); return }
        guard let at = d.object(forKey: Key.lastBriefAt) as? Date else {
            TTSService.shared.speak(b); return
        }
        let mins = Int(Date().timeIntervalSince(at) / 60)
        if mins > 24 * 60 { TTSService.shared.speak("Nothing new today. Last one was yesterday: \(b)") }
        else if mins > 90 { TTSService.shared.speak("From \(mins / 60) hours ago: \(b)") }
        else              { TTSService.shared.speak(b) }
    }

    // MARK: - Repeat suppression

    private var saidToday: [String] {
        get { (d.array(forKey: Key.saidToday) as? [String]) ?? [] }
        set { d.set(Array(newValue.suffix(repeatMemory)), forKey: Key.saidToday) }
    }

    private func rememberSaid(_ text: String) { saidToday = saidToday + [text] }

    // MARK: - Don't announce what will announce itself

    /// Anything already carrying its own alarm — a running timer, a list with
    /// a live geofence, a reminder with a time on it.
    ///
    /// Without this the feature double-pings, and at eight passes a day it
    /// does so eight times as often. The timer fires at five; the 17:00 pass
    /// then reads the same store, sees the same thing, and says it again. Two
    /// notifications, one fact. A week of that and the feature gets switched
    /// off — which is why this is a rule in the prompt and not a nicety.
    private func selfAlerting() -> String {
        var lines: [String] = []
        for name in ChappyTimers.shared.selfAlertingNames() {
            lines.append("— timer \"\(name)\" announces itself when it ends")
        }
        for name in ChappyLists.shared.selfAlertingListNames() {
            lines.append("— list \"\(name)\" pings on its own near a shop")
        }
        lines.append("— any reminder with a time on it fires its own alert then")
        return lines.joined(separator: "\n")
    }

    // MARK: - Composing

    enum Urgency: String { case low, normal, high }

    private struct Brief {
        let notable: Bool
        let headline: String
        let spoken: String
        let urgency: Urgency
    }

    private func composeBrief(slot: String) async -> Brief? {
        let key = APIKeyManager.shared.getAPIKey(for: .anthropic) ?? ""
        guard !key.isEmpty,
              let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }

        let agenda    = ChappyDataBridge.agenda()
        let reminders = ChappyDataBridge.remindersBrief()
        let memory    = ChappyDataBridge.recentMemoryDigest()
        let context   = ContextEngine.shared.contextHeader()

        // Nothing to reason about — don't spend anything.
        if agenda.isEmpty, reminders.isEmpty, memory.isEmpty {
            print("🔔 [Proactive] no data at all — skipping the call")
            return Brief(notable: false, headline: "", spoken: "", urgency: .low)
        }

        let partOfDay: String
        switch Int(slot.prefix(2)) ?? 12 {
        case 0..<11:  partOfDay = "morning"
        case 11..<16: partOfDay = "midday"
        default:      partOfDay = "evening"
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue(key,          forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model":      model,
            "max_tokens": maxTokens,
            "system":     briefSystemPrompt(partOfDay: partOfDay),
            "messages":   [["role": "user", "content": """
                CONTEXT: \(context)

                \(ChappyMemoryKeeper.shared.profileBlock())

                DIARY TODAY: \(agenda.isEmpty ? "nothing scheduled" : agenda)

                REMINDERS: \(reminders.isEmpty ? "none set" : reminders)

                RECENT ACTIVITY:
                \(memory.isEmpty ? "nothing logged" : memory)

                ALREADY TOLD HIM TODAY (do not repeat any of this):
                \(saidToday.isEmpty ? "nothing yet today" : saidToday.map { "— " + $0 }.joined(separator: "\n"))

                THESE WILL ALERT HIM THEMSELVES — SAY NOTHING ABOUT THEM:
                \(selfAlerting())
                """]]
        ] as [String: Any])

        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            print("🔔 [Proactive] HTTP \(code): \(String(data: data, encoding: .utf8) ?? "—")")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return nil }

        CostMeter.shared.addQuickVision()

        let text = content
            .compactMap { ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }
            .joined(separator: " ")
        return parseBrief(text)
    }

    private func briefSystemPrompt(partOfDay: String) -> String {
        """
        You are Chappy, Shaun's assistant. This is an automated \(partOfDay) check-in — he did \
        not ask for it, so the bar for interrupting him is high.

        You run eight times a day, roughly every two hours. That cadence exists so that when \
        something DOES change you catch it within the hour — not so you can find something to \
        say eight times. On an ordinary day most of these passes should produce nothing, and \
        that is the system working correctly, not failing.

        WORTH INTERRUPTING FOR
        Something coming up he may not have clocked, close enough to act on now. Two things \
        clashing. A reminder about to go stale. Something in the physical situation that changed \
        the plan — weather turning against an outdoor job, being a long way from somewhere he is \
        due. A pattern across recent days he would want flagged.

        NOT WORTH IT
        Reciting a diary he can already see. Restating a reminder with nothing added. Generic \
        encouragement. "You have a quiet afternoon." Anything in the ALREADY TOLD HIM list, \
        unless it has become materially more urgent since — and "an hour closer" is not, on its \
        own, materially more urgent. If he has been told about the two o'clock job, he knows \
        about the two o'clock job.

        ABSOLUTELY NOT: anything in the WILL ALERT HIM THEMSELVES list. A running timer, a list \
        with a live location nudge, a reminder with a time set — each fires its own notification \
        at the right moment. Mentioning it here means being told twice about one thing, which is \
        the fastest way to make him switch all of this off. Your job is what would otherwise \
        SLIP: a reminder with no time on it, a job he is too far away to make, two things \
        colliding, weather against an outdoor booking.

        The honest answer is usually notable:false. Prefer it. Silence across six passes is what \
        earns attention on the seventh.

        URGENCY
        high   — he must act within minutes. Leaving now, a clash happening now. This bypasses \
                 spacing and the daily budget, so use it only when an hour's delay would make \
                 the message useless.
        normal — worth knowing today, no rush.
        low    — mildly useful; may be held back or dropped.

        Reply as JSON, nothing else, no code fences:
        {"notable": true or false,
         "urgency": "low" or "normal" or "high",
         "headline": "under 40 characters, what he'd read on a lock screen",
         "spoken": "one or two sentences, read aloud, plain speech"}

        In "spoken": no markdown, no lists, no emoji. Never write the word "Chappy" — his glasses \
        listen for it. Lead with what matters. Be specific: times and names, not "you have some \
        things on". If notable is false, leave headline and spoken as empty strings.
        """
    }

    private func parseBrief(_ raw: String) -> Brief {
        let empty = Brief(notable: false, headline: "", spoken: "", urgency: .low)
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                 .replacingOccurrences(of: "```", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // AUDIT FIX: a stray '}' before any '{' produced upperBound < lowerBound
        // and trapped.
        guard let start = s.firstIndex(of: "{"),
              let end = s.lastIndex(of: "}"),
              start < end else { return empty }

        guard let data = String(s[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return empty }

        let notable = (obj["notable"] as? Bool) ?? false
        let head    = (obj["headline"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken  = (obj["spoken"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Unrecognised urgency falls back to normal, never high — a parsing
        // slip must not buy its way past the rate limit.
        let urgency = Urgency(rawValue: (obj["urgency"] as? String ?? "").lowercased()) ?? .normal

        guard notable, !spoken.isEmpty else {
            return Brief(notable: false, headline: head, spoken: spoken, urgency: .low)
        }
        if saidToday.contains(where: { $0.caseInsensitiveCompare(spoken) == .orderedSame }) {
            print("🔔 [Proactive] model repeated itself — suppressed")
            return Brief(notable: false, headline: "", spoken: spoken, urgency: .low)
        }
        return Brief(notable: true,
                     headline: head.isEmpty ? "Check-in" : head,
                     spoken: spoken,
                     urgency: urgency)
    }

    // MARK: - Delivery

    /// A notification, never unprompted speech. See the header — every product
    /// that has spoken up uninvited has been disliked for it.
    private func deliver(headline: String, body: String, urgent: Bool) {
        let c = UNMutableNotificationContent()
        c.title = urgent ? "⚠︎ " + headline : headline
        c.body  = body
        c.sound = .default
        c.userInfo = ["chappy_proactive": true]
        c.categoryIdentifier = "CHAPPY_BRIEF"
        if urgent, #available(iOS 15.0, *) {
            // Urgent briefs pierce Focus; routine ones deliberately do not, so
            // iOS can batch them like any other low-priority notification.
            c.interruptionLevel = .timeSensitive
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "chappy-brief-\(Int(Date().timeIntervalSince1970))",
                                  content: c, trigger: nil)
        ) { err in
            if let err { print("🔔 [Proactive] deliver failed: \(err.localizedDescription)") }
        }
        ChappyHaptics.shared.costNudge()
        print("🔔 [Proactive] delivered: \(headline)")
    }
}

// MARK: - Notification interaction

extension ChappyProactive: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let title = response.notification.request.content.title
        let body = response.notification.request.content.body

        Task { @MainActor in
            if info["chappy_proactive"] as? Bool == true {
                // Open a session already knowing what the brief said, so
                // "yeah, remind me about that" works without repeating it.
                ChappyConversation.shared.open(carrying:
                    "You sent me this check-in: \"\(body)\". I've opened it — pick up from there.")
            } else if info["chappy_list"] as? Bool == true {
                ChappyConversation.shared.open(carrying:
                    "I'm at the shop. My \(title) list is: \(body). Help me work through it.")
            }
            completionHandler()
        }
    }

    /// AUDIT FIX: this claimed the app-wide delegate and forced a banner for
    /// EVERY foreground notification, including ones other parts of the app
    /// may want handled differently. Only Chappy's own get the banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let info = notification.request.content.userInfo
        let mine = (info["chappy_proactive"] as? Bool ?? false)
            || (info["chappy_list"] as? Bool ?? false)
            || (info["chappy_timer"] as? Bool ?? false)
        completionHandler(mine ? [.banner, .sound] : [])
    }
}
