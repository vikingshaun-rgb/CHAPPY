/*
 * ChappyRelevance — memory that speaks up at the right corner
 *
 * ADDITIVE FILE. Overwrites nothing. PHASE 5 STEP 4, first half.
 *
 * ── WHAT IT IS ─────────────────────────────────────────────────────────
 * The difference between a database and a mate who has been here with you.
 * When the wearer arrives somewhere he has been before, this searches memory
 * silently and — occasionally — volunteers what it found. "You've been on this
 * street. Your laksa place is 200 metres left."
 *
 * ── WHY THIS IS THE MOST DANGEROUS FEATURE IN THE APP ──────────────────
 * Everything else in Chappy waits to be asked. This one talks first, in your
 * ear, unprompted, while you are walking down a street — and the record of
 * products that do that is uniformly bad. Alexa's proactive suggestions annoyed
 * people enough that Amazon shipped a permanent kill command. The Friend
 * pendant's unsolicited commentary was reviewed as condescending. Meta's own
 * always-on Live AI is something reviewers said they would keep switched off.
 *
 * So this is built to stay quiet, and every parameter below is chosen to make
 * silence the default outcome:
 *
 *   OFF by default. It is opt-in, like Pulse.
 *   A hard ceiling of a few remarks a day, and a long gap between them.
 *   It only fires on ARRIVAL somewhere — never mid-street, never while driving,
 *   never while he is already talking to Chappy or anyone else.
 *   Each place is remarked on ONCE, then never again.
 *   No memory older than a few months, and nothing thinner than a real visit.
 *
 * The test applied throughout: would a friend who had been here with you
 * actually say this out loud? A friend says "oh, your laksa place is just up
 * there". A friend does not say "you were at these coordinates on the 4th".
 *
 * ── WHY NOT AN LLM ─────────────────────────────────────────────────────
 * There is no model call here at all. The trigger is a geofence-free distance
 * check against memories that already carry coordinates, and the line is
 * assembled from the memory's own title and bearing. That makes it free,
 * instant, offline, and — most importantly — incapable of inventing a place
 * that was never there, which is exactly the failure that would make a
 * volunteered remark unbearable.
 */

import Foundation
import CoreLocation

@MainActor
final class ChappyRelevance: ObservableObject {
    static let shared = ChappyRelevance()
    private init() { load() }

    // MARK: - Tuning — all of it biased towards saying nothing

    /// He has to be within this of a remembered place for it to count.
    private let hitRadius: CLLocationDistance = 250
    /// And it has to be far enough away to be worth pointing at.
    private let minInterestingDistance: CLLocationDistance = 40
    /// Arrival means: moved at least this far since the last remark point.
    private let arrivalTravel: CLLocationDistance = 400
    /// Never two remarks closer together than this.
    private let minGapMinutes = 45.0
    /// Ceiling per day regardless of how much he moves around.
    private let dailyCeiling = 3
    /// Memories older than this are archaeology, not a nudge.
    private let maxMemoryAgeDays = 120.0
    /// Quiet hours, matching the proactive brief.
    private let quietStart = 22, quietEnd = 7

    @Published var isEnabled: Bool {
        didSet { d.set(isEnabled, forKey: Key.enabled) }
    }
    @Published private(set) var remarksToday = 0
    @Published private(set) var lastRemark = ""

    private enum Key {
        static let enabled  = "chappy_relevance_enabled"
        static let day      = "chappy_relevance_day"
        static let count    = "chappy_relevance_count"
        static let lastAt   = "chappy_relevance_last_at"
        static let remarked = "chappy_relevance_remarked"   // memory ids, never repeated
    }
    private let d = UserDefaults.standard

    private var remarked: Set<String> = []
    private var lastRemarkFix: CLLocation?
    private var lastCheckFix: CLLocation?

    // MARK: - Entry point
    //
    // Driven by ContextEngine's location updates rather than a timer, because
    // the trigger is arriving somewhere, not the passage of time.

    func locationUpdated(_ loc: CLLocation) {
        guard isEnabled else { return }
        rollDayIfNeeded()

        // Cheap rejects first, in cost order.
        guard remarksToday < dailyCeiling else { return }
        guard !inQuietHours() else { return }
        guard notBusy() else { return }

        // Only on arrival. Without this it fires continuously along a street.
        if let last = lastRemarkFix, loc.distance(from: last) < arrivalTravel { return }
        // And only once he has actually settled — a fix while doing 60 on a
        // scooter is a place he is passing, not a place he has arrived at.
        guard (loc.speed < 2.0 || loc.speed < 0) else { return }
        if ContextEngine.shared.snapshot.motion == "in a vehicle" { return }

        // Debounce the check itself so a cluster of fixes is one search.
        if let last = lastCheckFix, loc.distance(from: last) < 50 { return }
        lastCheckFix = loc

        guard let hit = nearestWorthwhileMemory(to: loc) else { return }
        remark(about: hit.entry, distance: hit.metres, from: loc)
    }

    // MARK: - The search
    //
    // Pure local arithmetic over memories that already carry coordinates.
    // No network, no model, works on a plane.

    private struct Hit { let entry: ChappyMemory.Entry; let metres: CLLocationDistance }

    private func nearestWorthwhileMemory(to loc: CLLocation) -> Hit? {
        let cutoff = Date().addingTimeInterval(-maxMemoryAgeDays * 86_400)

        let candidates = ChappyMemory.shared.recent.compactMap { e -> Hit? in
            guard e.at > cutoff else { return nil }
            guard !remarked.contains(e.id.uuidString) else { return nil }
            // Pulse frames are ambient wallpaper — a remembered PLACE is one he
            // chose: a saved spot, a photo he took, a note he made, a meal.
            guard e.kind == .place || e.kind == .photo || e.kind == .note
                    || e.kind == .spend || e.kind == .scan else { return nil }
            guard !(e.tags.contains("pulse")) else { return nil }
            guard let la = e.lat, let lo = e.lon else { return nil }

            let m = loc.distance(from: CLLocation(latitude: la, longitude: lo))
            guard m <= hitRadius, m >= minInterestingDistance else { return nil }
            return Hit(entry: e, metres: m)
        }

        // Pinned first — a favourite outranks a passing note at the same
        // distance — then nearest.
        return candidates
            .sorted { a, b in
                if a.entry.pinned != b.entry.pinned { return a.entry.pinned }
                return a.metres < b.metres
            }
            .first
    }

    // MARK: - Saying it

    private func remark(about e: ChappyMemory.Entry, distance: CLLocationDistance, from loc: CLLocation) {
        guard let la = e.lat, let lo = e.lon else { return }

        let when = friendlyAge(e.at)
        let dir = bearingWord(from: loc, toLat: la, lon: lo)
        let metres = Int((distance / 10).rounded() * 10)

        // Short, factual, and it never claims more than it knows.
        let line = "\(e.title) is about \(metres) metres \(dir) — you were here \(when)."

        remarked.insert(e.id.uuidString)
        remarksToday += 1
        lastRemark = line
        lastRemarkFix = loc
        d.set(Date(), forKey: Key.lastAt)
        persist()

        ChappyEarcon.shared.wake()
        TTSService.shared.speak(line)
        print("💡 [Relevance] \(line)")
    }

    private func friendlyAge(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        switch days {
        case 0:      return "earlier today"
        case 1:      return "yesterday"
        case 2...6:  return "a few days ago"
        case 7...13: return "last week"
        case 14...45:
            let f = DateFormatter(); f.dateFormat = "d MMMM"
            return "on the \(f.string(from: date))"
        default:
            let f = DateFormatter(); f.dateFormat = "MMMM"
            return "back in \(f.string(from: date))"
        }
    }

    /// Compass words rather than degrees. "Two hundred metres north-east" is
    /// something a person can act on; a bearing of 47° is not.
    private func bearingWord(from: CLLocation, toLat: Double, lon: Double) -> String {
        let φ1 = from.coordinate.latitude * .pi / 180
        let φ2 = toLat * .pi / 180
        let Δλ = (lon - from.coordinate.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        let names = ["north", "north-east", "east", "south-east",
                     "south", "south-west", "west", "north-west"]
        return names[Int((deg + 22.5) / 45) % 8]
    }

    // MARK: - Guards

    /// Never interrupt something that is already talking or listening.
    private func notBusy() -> Bool {
        if ChappyConversation.shared.isActive { return false }
        if GeminiLiveService.activeInstance != nil { return false }
        if ContinuousVisionManager.shared.isRunning { return false }
        if NavEngine.shared.isNavigating { return false }
        if TTSService.shared.isSpeaking { return false }
        if let last = d.object(forKey: Key.lastAt) as? Date,
           Date().timeIntervalSince(last) / 60 < minGapMinutes { return false }
        return true
    }

    private func inQuietHours() -> Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return quietStart > quietEnd ? (h >= quietStart || h < quietEnd)
                                     : (h >= quietStart && h < quietEnd)
    }

    // MARK: - State

    private func rollDayIfNeeded() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        guard d.string(forKey: Key.day) != today else { return }
        d.set(today, forKey: Key.day)
        remarksToday = 0
        d.set(0, forKey: Key.count)
        // `remarked` deliberately does NOT reset. Once a place has been
        // mentioned it is mentioned; hearing about the same cafe every morning
        // for a week is precisely the failure mode this whole file avoids.
    }

    private func persist() {
        d.set(remarksToday, forKey: Key.count)
        // Bounded, oldest dropped — a year of ids is not worth carrying.
        if remarked.count > 800 { remarked = Set(remarked.suffix(600)) }
        d.set(Array(remarked), forKey: Key.remarked)
    }

    private func load() {
        isEnabled    = d.object(forKey: Key.enabled) as? Bool ?? false   // OFF by default
        remarksToday = d.integer(forKey: Key.count)
        remarked     = Set(d.stringArray(forKey: Key.remarked) ?? [])
    }

    /// "Chappy, forget you mentioned that" — clears the suppression list so
    /// places can be volunteered again.
    func allowRepeats() {
        remarked = []
        d.set([String](), forKey: Key.remarked)
        TTSService.shared.speak("I'll mention places again.")
    }

    func statusLine() -> String {
        guard isEnabled else { return "Not volunteering places." }
        return "Volunteering places. \(remarksToday) of \(dailyCeiling) today."
    }
}
