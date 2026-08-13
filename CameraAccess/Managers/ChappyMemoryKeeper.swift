/*
 * ChappyMemoryKeeper — the Codex: curated durable facts, separate from the log
 *
 * ADDITIVE FILE. Overwrites nothing. PHASE 5 STEP 4.5.
 *
 * ── WHAT THIS ADDS, AND WHY IT WASN'T ALREADY THERE ────────────────────
 * ChappyMemory is a good log: one JSONL per day, twelve kinds, 30 hot days in
 * RAM and the rest searchable on disk, expiry, pinning, and a written summary
 * per day via dreamIfDue(). What it never had is a PROFILE — a small curated
 * set of facts that stay true for months and are cheap enough to put in front
 * of the model on every single call.
 *
 * The distinction is the whole point. A log answers "what happened on Tuesday".
 * A profile answers "who is this person", and only the second can be injected
 * into every prompt, because it is bounded. Searching thirty days of entries to
 * discover he does Geeks2U callouts is expensive and unreliable; knowing it
 * outright costs about forty tokens.
 *
 * ── WHAT WAS TAKEN FROM HERMES, AND WHAT WASN'T ────────────────────────
 * Nous Research's Hermes Agent keeps MEMORY.md — "agent-curated facts written
 * with periodic nudges to persist durable knowledge" — deliberately separate
 * from the session log it searches with SQLite FTS5. The good idea there is the
 * write side, and it is the whole of what this file copies:
 *
 *   the nudge     — a scheduled moment that ASKS what deserves keeping,
 *                   rather than hoping something notices in passing
 *   curation      — facts get superseded and dropped, not just appended
 *   separation    — durable profile apart from the raw record
 *
 * What was NOT copied, because this codebase already does it better: Hermes
 * stores plaintext markdown and searches it with keyword FTS. ChappyMemory has
 * structured entries with kinds, dates, coordinates and expiry, plus a two-tier
 * hot/cold read. Swapping that for a text file and a keyword index would be a
 * downgrade. Honcho — its pluggable user-modelling provider — is a Python
 * service, which on iOS means a server, a network hop and a monthly bill for
 * something that fits in this file.
 *
 * ── SUPERSEDE, DON'T APPEND ────────────────────────────────────────────
 * The failure mode of every naive memory system is that it only ever grows, so
 * it ends up holding "prefers the Kuta villa" and "moved out of the Kuta villa"
 * at once and the model picks whichever it reads first. Each pass can ADD,
 * UPDATE (replacing a specific fact by id) or DROP. The store is hard-capped,
 * so it cannot quietly become a second log.
 *
 * ── COST ───────────────────────────────────────────────────────────────
 * One Haiku call a day — the current profile plus a day of entries in, a short
 * JSON diff out. Roughly two thirds of a cent, about $0.20 a month. It hangs
 * off a proactive pass that was already reading memory, so it adds no new
 * schedule and no new wake-ups.
 */

import Foundation

@MainActor
final class ChappyMemoryKeeper: ObservableObject {
    static let shared = ChappyMemoryKeeper()
    private init() { load() }

    // MARK: - Tuning

    private let model = "claude-haiku-4-5"
    /// Hard cap. The point of a profile is that it fits in every prompt.
    private let maxFacts = 60
    private let maxChars = 3500
    /// A fact nobody has confirmed in this long is probably no longer true.
    private let staleDays = 120.0

    // MARK: - Model

    struct Fact: Codable, Identifiable, Equatable {
        var id: String
        var text: String
        var firstSeen: Date
        var lastConfirmed: Date
    }

    @Published private(set) var facts: [Fact] = []

    private enum Key {
        static let facts = "chappy_profile_facts"
        static let lastRun = "chappy_profile_last_run"
    }
    private let d = UserDefaults.standard

    // MARK: - Reading (the whole point)

    /// The profile as a block for a system prompt. Bounded by construction.
    /// Returns "" when there is nothing yet, so callers can append blindly.
    // BUILD 182 — ONE PROFILE, EVERY BRAIN.
    //
    // This block is already read by the conversation brain and by the
    // proactive pass, which makes it the one place worth widening. The
    // travel intake collected thirteen durable facts — how he travels,
    // whether he works on the road, whether he rides a scooter, what he
    // can't eat — and until now they were read by exactly two travel
    // prompts and by nothing else in the app. "I don't eat pork" was
    // known to the trip planner and to no other part of Chappy.
    //
    // Appending it here means every brain that already asks who he is
    // gets it, at about two hundred tokens, with no new plumbing.
    func profileBlock() -> String {
        let live = facts.filter {
            Date().timeIntervalSince($0.lastConfirmed) < staleDays * 86_400
        }
        let travel = ChappyIntake.shared.brief
        // BUILD 184: the spoken assistant was working from learned facts
        // and the trip interview, and had never been told who he is.
        let who = ChappyProfile.shared.brief
        let stamp = ChappyBorder.shared.currentCountry.map { country -> String in
            if let left = ChappyBorder.shared.daysLeft {
                return "He is currently in \(country), with \(left) days left on his stay."
            }
            return "He is currently in \(country)."
        } ?? ""

        guard !live.isEmpty || !travel.isEmpty || !stamp.isEmpty || !who.isEmpty else { return "" }

        var out = ""
        if !who.isEmpty { out += who + "\n\n" }
        if !stamp.isEmpty { out += stamp + "\n" }
        if !travel.isEmpty { out += travel + "\n\n" }
        guard !live.isEmpty else { return out }
        out += "WHAT YOU KNOW ABOUT HIM (learned over time — use it when it changes the answer, don't recite it):\n"
        var used = out.count
        for f in live.sorted(by: { $0.lastConfirmed > $1.lastConfirmed }) {
            let line = "— \(f.text)\n"
            if used + line.count > maxChars { break }
            out += line
            used += line.count
        }
        return out
    }

    func profileOneLine() -> String {
        let live = facts.prefix(12).map(\.text)
        return live.isEmpty ? "" : live.joined(separator: "; ")
    }

    // MARK: - The nudge

    /// Called from a proactive pass. At most once a day, and only when there is
    /// a day's worth of material to reason about.
    func nudgeIfDue() async {
        let today = Self.dayKey(Date())
        guard d.string(forKey: Key.lastRun) != today else { return }
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        else { return }
        let key = ChappyMemory.dayKey(yesterday)

        let entries = ChappyMemory.shared.recent
            .filter { ChappyMemory.dayKey($0.at) == key && $0.kind != .day }
        guard entries.count >= 3 else {
            d.set(today, forKey: Key.lastRun)          // nothing happened
            return
        }
        // Mark BEFORE the call. A failure must not mean eight retries.
        d.set(today, forKey: Key.lastRun)

        await consolidate(entries: entries,
                          daySummary: ChappyMemory.shared.summary(for: yesterday),
                          dayName: key)
    }

    func runNow() async {
        d.removeObject(forKey: Key.lastRun)
        await nudgeIfDue()
    }

    // MARK: - The call

    private func consolidate(entries: [ChappyMemory.Entry],
                             daySummary: String?,
                             dayName: String) async {
        let apiKey = APIKeyManager.shared.getAPIKey(for: .anthropic) ?? ""
        guard !apiKey.isEmpty,
              let url = URL(string: "https://api.anthropic.com/v1/messages") else { return }

        let df = DateFormatter(); df.dateFormat = "h:mm a"
        let log = entries.sorted { $0.at < $1.at }.prefix(120)
            .map { "\(df.string(from: $0.at)) [\($0.kind.rawValue)] \($0.oneLine)" }
            .joined(separator: "\n")
        let current = facts.isEmpty ? "(nothing yet)"
            : facts.map { "\($0.id): \($0.text)" }.joined(separator: "\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 800,
            "system": Self.prompt,
            "messages": [["role": "user", "content": """
                CURRENT PROFILE:
                \(current)

                WHAT HAPPENED ON \(dayName):
                \(daySummary.map { "Summary: \($0)\n" } ?? "")\(log)
                """]]
        ] as [String: Any])

        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            print("🧠 [Keeper] HTTP \(code): \(String(data: data, encoding: .utf8) ?? "—")")
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return }

        CostMeter.shared.addQuickVision()
        apply(content
            .compactMap { ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }
            .joined())
    }

    // MARK: - Applying the diff

    private func apply(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                 .replacingOccurrences(of: "```", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b,
              let data = String(s[a...b]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { print("🧠 [Keeper] unparseable reply"); return }

        let now = Date()
        var next = facts
        var added = 0, updated = 0, dropped = 0

        // DROP first, so an update can't be undone by a stale drop.
        if let drops = obj["drop"] as? [String] {
            let before = next.count
            next.removeAll { drops.contains($0.id) }
            dropped = before - next.count
        }
        if let ups = obj["update"] as? [[String: Any]] {
            for u in ups {
                guard let id = u["id"] as? String,
                      let t = (u["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !t.isEmpty, isAllowed(t),
                      let i = next.firstIndex(where: { $0.id == id }) else { continue }
                next[i].text = t
                next[i].lastConfirmed = now
                updated += 1
            }
        }
        if let adds = obj["add"] as? [String] {
            for t0 in adds {
                let t = t0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, isAllowed(t) else { continue }
                let norm = t.lowercased()
                if next.contains(where: { $0.text.lowercased() == norm }) { continue }
                next.append(Fact(id: String(UUID().uuidString.prefix(8)).lowercased(),
                                 text: t, firstSeen: now, lastConfirmed: now))
                added += 1
            }
        }

        // Trim to the cap, oldest confirmation first — a profile that never
        // forgets is just a log.
        if next.count > maxFacts {
            next.sort { $0.lastConfirmed > $1.lastConfirmed }
            next = Array(next.prefix(maxFacts))
        }

        facts = next
        save()
        print("🧠 [Keeper] +\(added) ~\(updated) -\(dropped), \(facts.count) facts held")
    }

    /// Last-resort filter. The prompt forbids these categories, but a profile
    /// injected into every future prompt is the worst possible place for a
    /// mistake, so it is checked on the way in as well.
    private func isAllowed(_ t: String) -> Bool {
        let s = t.lowercased()
        let banned = ["password", "passcode", "api key", "api_key", "sk-ant", "aiza",
                      "credit card", "card number", "cvv", "bank account", "bsb",
                      "passport number", "licence number", "license number",
                      "medicare", "tax file", "diagnos", "prescription for",
                      "medication", "therapy", "depress", "anxiet"]
        if banned.contains(where: { s.contains($0) }) {
            print("🧠 [Keeper] refused a fact on the blocklist")
            return false
        }
        // Too short to mean anything, too long to be a fact rather than a story.
        return t.count >= 4 && t.count <= 200
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        d.set(data, forKey: Key.facts)
    }

    private func load() {
        guard let data = d.data(forKey: Key.facts),
              let decoded = try? JSONDecoder().decode([Fact].self, from: data) else { return }
        facts = decoded
    }

    /// For a settings screen — he should be able to see and delete what
    /// Chappy believes about him.
    func forget(_ id: String) {
        facts.removeAll { $0.id == id }
        save()
    }

    func forgetEverything() {
        facts = []
        save()
        d.removeObject(forKey: Key.lastRun)
    }

    private static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    func statusLine() -> String {
        facts.isEmpty ? "Nothing learned yet." : "\(facts.count) things known about you."
    }

    // MARK: - Prompt

    private static let prompt = """
    You maintain a small profile of durable facts about Shaun for his glasses assistant.

    You are given the profile as it stands and a log of one day. Decide what should change.

    WHAT BELONGS IN A PROFILE
    Things that stay true for months. How he works and who for. Places he goes back to. \
    People he mentions repeatedly and who they are to him. Preferences he has shown more than \
    once. Standing constraints — a vehicle, a route, a deadline, a trip. Tools he actually uses.

    WHAT DOES NOT
    Anything that happens once. Anything with a date attached — that is what the day log is \
    for. Today's weather, today's jobs, a single photo, a one-off question. If it would be \
    wrong to say in three months, leave it out.

    NEVER RECORD, even if it is plainly in the log: health, medical or mental-health \
    information; medication; anything financial beyond "he invoices clients"; card, bank, \
    passport, licence or government numbers; passwords or API keys; anyone's home address; \
    religion, politics or sexuality; anything about a named person's private life. If a fact is \
    half useful and half sensitive, keep only the useful half — "does IT callouts around \
    Melbourne" is fine, a client's medical clinic name is not.

    BE SPARING. One good day usually yields nought to two facts. Most days yield none. A \
    profile of twenty true things beats sixty vague ones, and every line here is read on every \
    future request, so waffle costs him money forever.

    PREFER UPDATING TO ADDING. If a new fact contradicts or refines an existing one, UPDATE \
    that one by its id. Adding a second version leaves both in play and the assistant will pick \
    whichever it reads first. DROP anything the day shows is no longer true.

    Write facts as short third-person statements, no hedging, no dates: "Does Geeks2U IT \
    callouts around Melbourne", not "It seems that on Tuesday he may have...".

    Reply with JSON only, no code fences, no commentary:
    {"add": ["fact", ...],
     "update": [{"id": "abc12345", "text": "revised fact"}, ...],
     "drop": ["id", ...]}

    Use empty arrays when there is nothing to change. That is the normal answer.
    """
}
