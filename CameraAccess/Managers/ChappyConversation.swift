/*
 * ChappyConversation — the on-demand Jarvis session
 *
 * ADDITIVE FILE. Overwrites nothing.
 *
 * ── WHAT THIS IS ───────────────────────────────────────────────────────
 * A task-scoped Claude session with real tool access, opened by Standby when a
 * command is conversational, multi-step, or asks for judgement — and closed
 * the moment the task is done. Not always-on. Not a socket held open on the
 * chance you might say something.
 *
 * ── WHY NOT ALWAYS-ON ──────────────────────────────────────────────────
 * Meta shipped exactly that on this hardware. "Live AI" on the Ray-Ban Gen 2
 * runs the assistant continuously and takes the glasses from ~8 hours of
 * battery to about 30 minutes. Reviewers who tested it said they would not
 * leave it on — and cited privacy, not battery, as the reason. Both objections
 * are structural and neither is solved by a better prompt. A session that
 * opens on demand and closes on completion has neither, and costs about half a
 * cent instead of dollars an hour.
 *
 * ── WHY CLAUDE AND NOT GEMINI LIVE ─────────────────────────────────────
 * Gemini Live is right for Translate: continuous audio in and out, latency in
 * tens of milliseconds. This session's job is not fast audio — it is picking
 * the right tool and calling it with the right arguments, which wants
 * structured tool_use with typed inputs. Audio out is already solved by
 * TTSService and audio in by Standby's recogniser; opening a second audio
 * socket would fight both for the microphone, which is the exact class of bug
 * that has taken this app's audio stack down before.
 *
 * ── LIFETIME ───────────────────────────────────────────────────────────
 *   Opens   — Standby decides the command needs a session
 *   Lives   — across multiple "Hey Chappy" wakes, history intact
 *   Closes  — the model calls finished(), 45 s of silence, a 3-minute
 *             ceiling, repeated network failure, or he says stop
 */

import Foundation

@MainActor
final class ChappyConversation: ObservableObject {
    static let shared = ChappyConversation()
    private init() {}

    /// True while a session owns the wearer's speech. Standby checks this.
    @Published private(set) var isActive = false

    // MARK: - Tuning

    private let model          = "claude-sonnet-4-6"   // matches quickAsk
    private let maxTurnTokens  = 1024
    private let silenceSeconds = 45.0
    private let ceilingSeconds = 180.0
    private let maxToolRounds  = 6
    private let maxHistory     = 16
    private let maxFailures    = 2

    // MARK: - State

    private var history: [[String: Any]] = []
    private var isTurning = false
    /// Speech that arrived mid-turn. Queued, never dropped — a wearer with the
    /// phone pocketed cannot tell "ignored" from "not heard", so he just
    /// repeats himself into a void.
    private var queued: String?
    private var failures = 0

    private var silenceWork: DispatchWorkItem?
    private var ceilingWork: DispatchWorkItem?

    // MARK: - Public API

    func open(carrying question: String) {
        guard !isActive else { send(question); return }
        isActive = true
        history = []
        queued = nil
        failures = 0
        isTurning = false
        scheduleCeiling()
        resetSilenceTimer()
        ChappyEarcon.shared.wake()
        Task { await runTurn(userText: question) }
    }

    func send(_ text: String) {
        guard isActive else { return }
        resetSilenceTimer()
        guard !isTurning else {
            // Fold it in rather than lose it. Two half-sentences are usually
            // one thought.
            queued = [queued, text].compactMap { $0 }.joined(separator: ". ")
            return
        }
        Task { await runTurn(userText: text) }
    }

    func close(sayBye: Bool = false) {
        cancelTimers()
        isActive = false
        history = []
        queued = nil
        isTurning = false
        failures = 0
        if sayBye {
            ChappyEarcon.shared.done()
            TTSService.shared.speak(ChappyVoice.line("session_end", [
                "Righto.", "Done.", "All yours.", "Any time."
            ]))
        }
    }

    // MARK: - Timers

    /// AUDIT FIX: if this fired while a turn was in flight it returned without
    /// rescheduling, so the session lost its silence backstop entirely and sat
    /// open until the 3-minute ceiling. Now it re-arms instead.
    private func resetSilenceTimer() {
        silenceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            if self.isTurning { self.resetSilenceTimer(); return }
            ChappyEarcon.shared.done()
            self.close()
        }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceSeconds, execute: work)
    }

    private func scheduleCeiling() {
        ceilingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            TTSService.shared.speak("That's a few minutes — catch me again any time.")
            self.close()
        }
        ceilingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ceilingSeconds, execute: work)
    }

    private func cancelTimers() {
        silenceWork?.cancel(); silenceWork = nil
        ceilingWork?.cancel(); ceilingWork = nil
    }

    // MARK: - The agentic turn

    private func runTurn(userText: String) async {
        isTurning = true
        defer {
            isTurning = false
            if let q = queued, isActive {
                queued = nil
                Task { await runTurn(userText: q) }
            }
        }

        guard let key = anthropicKey() else {
            TTSService.shared.speak("No key configured — I can't reach my brain.")
            close(); return
        }

        if !userText.isEmpty {
            appendHistory(["role": "user", "content": userText])
        }

        var round = 0
        while round < maxToolRounds, isActive {
            round += 1

            guard let reply = await callClaude(key: key) else {
                // AUDIT FIX: history still ended with an unanswered user turn.
                // The next thing he said appended a SECOND consecutive user
                // message, which the Messages API rejects with a 400 — and it
                // kept rejecting for the rest of the session, because nothing
                // ever repaired the array. Unwind, and give up after two.
                unwindTrailingUserTurn()
                failures += 1
                if failures >= maxFailures {
                    TTSService.shared.speak("I can't reach my brain right now.")
                    close(); return
                }
                TTSService.shared.speak("That didn't come back. Try me again.")
                return
            }
            failures = 0
            guard isActive else { return }   // closed while awaiting

            let content = reply.content
            guard !content.isEmpty else {
                unwindTrailingUserTurn()
                return
            }
            appendHistory(["role": "assistant", "content": content])

            // AUDIT FIX: each text block used to be spoken separately, but
            // TTSService.speak cancels whatever is already playing — so with
            // two blocks only the last was ever heard. Join and speak once.
            let spoken = content
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty { TTSService.shared.speak(scrubForSpeech(spoken)) }

            // AUDIT FIX: a response truncated mid-tool_use leaves an orphaned
            // tool_use with no matching tool_result, which poisons every
            // subsequent request in the session.
            if reply.stopReason == "max_tokens" {
                history.removeLast()
                if spoken.isEmpty {
                    TTSService.shared.speak("That got long — ask me for the short version.")
                }
                return
            }

            guard reply.stopReason == "tool_use" else { return }

            // Execute EVERY tool in the response. An earlier version broke out
            // of this loop the moment it saw finished(), silently dropping any
            // tool called alongside it — and "remind me to call Jess and
            // that's all" is one response containing both, where the reminder
            // was the entire point.
            var results: [[String: Any]] = []
            var shouldEnd = false

            for block in content where (block["type"] as? String) == "tool_use" {
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String else { continue }
                let args = block["input"] as? [String: Any] ?? [:]

                if name == "finished" {
                    shouldEnd = true
                    results.append(toolResult(id, "Session closing."))
                    continue
                }
                let out = await execute(tool: name, args: args)
                results.append(toolResult(id, out))
            }

            if shouldEnd { close(); return }
            guard !results.isEmpty else {
                history.removeLast()   // orphaned tool_use — drop it
                return
            }
            guard isActive else { return }

            appendHistory(["role": "user", "content": results])
            resetSilenceTimer()
        }

        TTSService.shared.speak("That's as far as I got — say the word and I'll keep going.")
    }

    private func unwindTrailingUserTurn() {
        if (history.last?["role"] as? String) == "user" { history.removeLast() }
    }

    private func toolResult(_ id: String, _ text: String) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": text]
    }

    // MARK: - Network

    private struct ClaudeReply {
        let content: [[String: Any]]
        let stopReason: String
    }

    private func anthropicKey() -> String? {
        let k = APIKeyManager.shared.getAPIKey(for: .anthropic) ?? ""
        return k.isEmpty ? nil : k
    }

    private func callClaude(key: String) async -> ClaudeReply? {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(key,          forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model":      model,
            "max_tokens": maxTurnTokens,
            "system":     systemPrompt(),
            "tools":      tools(),
            "messages":   history
        ] as [String: Any])

        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            print("💬 [Conversation] network error")
            return nil
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            // Log the body. A silent "didn't come back" on a 400 is the
            // difference between a two-minute fix and a lost evening.
            print("💬 [Conversation] HTTP \(code): \(String(data: data, encoding: .utf8) ?? "—")")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        CostMeter.shared.addQuickVision()
        return ClaudeReply(content: json["content"] as? [[String: Any]] ?? [],
                           stopReason: json["stop_reason"] as? String ?? "end_turn")
    }

    // MARK: - History

    /// Append, then trim from the front WITHOUT orphaning a tool_result.
    ///
    /// The API rejects a conversation whose first message is a tool_result
    /// with no preceding tool_use — a blind removeFirst(2) produces exactly
    /// that, and the failure lands on the fourth or fifth exchange of a long
    /// session, which is maddening to reproduce.
    private func appendHistory(_ msg: [String: Any]) {
        history.append(msg)
        while history.count > maxHistory {
            history.removeFirst()
            while let first = history.first, !isPlainUserTurn(first) {
                history.removeFirst()
            }
            if history.isEmpty { break }
        }
    }

    private func isPlainUserTurn(_ msg: [String: Any]) -> Bool {
        (msg["role"] as? String) == "user" && (msg["content"] is String)
    }

    // MARK: - Tool execution

    private func execute(tool name: String, args: [String: Any]) async -> String {
        switch name {

        case "take_photo":
            // AUDIT FIX: this always reported success. Standby's own photo
            // branch checks the stream first, because claiming a photo that
            // was never taken is worse than admitting the camera is asleep.
            NotificationCenter.default.post(name: .chappyCapturePhoto, object: nil)
            if LiveAIManager.shared.streamViewModel?.streamingStatus == .streaming {
                return "Photo captured."
            }
            return "Camera isn't running — tell him to open Talk or Look first, then it can shoot."

        case "navigate":
            let dest = (args["destination"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !dest.isEmpty else { return "No destination given." }
            let utt = args["utterance"] as? String ?? dest
            switch await ChappyNavMode.go(to: dest, utterance: utt) {
            case .route(let r):
                return r
            case .ask(_, let question):
                // Returned, not spoken here — speaking out of band would be
                // cut off by whatever the model says next, since TTS cancels
                // the previous line.
                return "AMBIGUOUS DISTANCE. Ask him exactly this and nothing else: \"\(question)\" Then call navigate again with his answer in the utterance."
            case .failed(let f):
                return f
            }

        case "start_translate":
            ChappyStandby.shared.handOff()
            NotificationCenter.default.post(name: .chappyOpenTranslate, object: nil)
            return "Live translation opened."

        case "open_google_maps":
            NotificationCenter.default.post(name: .chappyOpenGoogleMaps, object: nil)
            return "Google Maps opened."

        case "create_reminder":
            let text = (args["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "No reminder text given." }
            let when = parseWhen(args["when"] as? String ?? "")
            return ChappyDataBridge.addReminder(text: text, at: when)

        case "list_reminders":
            let rem = ChappyDataBridge.remindersBrief()
            let cal = ChappyDataBridge.agenda()
            let out = [rem, cal].filter { !$0.isEmpty }.joined(separator: " ")
            return out.isEmpty ? "Nothing on today." : out

        case "add_to_list":
            let items = (args["items"] as? [String]) ?? []
            guard !items.isEmpty else { return "No items given." }
            let raw = (args["list_name"] as? String ?? "Shopping")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = raw.isEmpty ? "Shopping" : raw
            let hint = args["place_hint"] as? String ?? name
            return await ChappyLists.shared.addItems(items, toListNamed: name, placeHint: hint)

        case "read_lists":
            return await ChappyLists.shared.spokenSummary()

        case "tick_off":
            let items = (args["items"] as? [String]) ?? []
            guard !items.isEmpty else { return "Which items?" }
            return await ChappyLists.shared.complete(items)

        case "set_timer":
            let name = args["name"] as? String
            if let secs = args["seconds"] as? Double, secs > 0 {
                return ChappyTimers.shared.set(seconds: secs, name: name)
            }
            if let iso = args["at"] as? String,
               let when = ISO8601DateFormatter().date(from: iso) {
                return ChappyTimers.shared.set(at: when, name: name)
            }
            return "How long for?"

        case "read_timers":
            return ChappyTimers.shared.spokenSummary()

        case "cancel_timer":
            return ChappyTimers.shared.cancel(matching: args["name"] as? String ?? "")

        case "recall":
            // BUILD 219: the question actually reaches the search now.
            let query = (args["query"] as? String) ?? ""
            let days = (args["days"] as? Int) ?? 30
            let kind = (args["kind"] as? String).flatMap { ChappyMemory.Kind(rawValue: $0) }
            let meaning = (args["type"] as? String).flatMap { ChappyMemory.Semantic(rawValue: $0) }
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                // No query is a model mistake rather than a real request,
                // but returning nothing would be unhelpful — fall back to
                // the old digest so the turn still has something in it.
                let digest = ChappyDataBridge.recentMemoryDigest()
                return digest.isEmpty ? "Nothing logged recently." : digest
            }
            return await MainActor.run {
                ChappyMemory.shared.recallFor(query, days: days, kind: kind, meaning: meaning)
            }

        case "get_context":
            return ContextEngine.shared.contextHeader()

        default:
            return "Unknown tool: \(name)"
        }
    }

    // MARK: - Time parsing

    /// ISO8601 first — the model is told to send that whenever it can work the
    /// time out, which it usually can because the prompt carries local time.
    private func parseWhen(_ s: String) -> Date? {
        let raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let d = ISO8601DateFormatter().date(from: raw) { return d }

        let w = raw.lowercased()
        let cal = Calendar.current
        let now = Date()

        let n = Int(w.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }.first ?? "") ?? 0
        if w.contains("minute") { return now.addingTimeInterval(Double(max(1, n)) * 60) }
        if w.contains("hour")   { return now.addingTimeInterval(Double(max(1, n)) * 3600) }

        // ORDER MATTERS: work out the DAY first, then set the hour on it.
        // Checking "tomorrow" first and returning early is why "tomorrow
        // morning" used to land at whatever o'clock it happened to be.
        let base = w.contains("tomorrow")
            ? (cal.date(byAdding: .day, value: 1, to: now) ?? now)
            : now

        if w.contains("morning") { return cal.date(bySettingHour: 8, minute: 0, second: 0, of: base) }
        if w.contains("noon") || w.contains("midday") {
            return cal.date(bySettingHour: 12, minute: 0, second: 0, of: base)
        }
        if w.contains("afternoon") { return cal.date(bySettingHour: 14, minute: 0, second: 0, of: base) }
        if w.contains("evening") || w.contains("tonight") {
            return cal.date(bySettingHour: 19, minute: 0, second: 0, of: base)
        }
        if w.contains("tomorrow") { return cal.date(bySettingHour: 9, minute: 0, second: 0, of: base) }
        return nil
    }

    // MARK: - Speech hygiene

    /// Strip anything that would make Chappy trigger himself. Standby's mic is
    /// live while this session speaks, so a spoken wake word fires a command
    /// and the assistant talks itself into a loop. The prompt forbids it; this
    /// is the belt to those braces. Covers the same spellings the recogniser
    /// accepts, not just the correct one.
    private func scrubForSpeech(_ s: String) -> String {
        var out = s
        for w in ["chappy's", "chappie", "chappy", "chapy"] {
            out = out.replacingOccurrences(of: w, with: "",
                                           options: [.caseInsensitive])
        }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - System prompt

    private func systemPrompt() -> String {
        let snap = ContextEngine.shared.snapshot
        let df = DateFormatter(); df.dateFormat = "EEEE d MMMM yyyy, h:mm a"
        let tz = TimeZone.current

        var place: [String] = []
        if let s = snap.street, s.count < 40 { place.append(s) }
        if let s = snap.suburb, s != snap.city { place.append(s) }
        if let c = snap.city { place.append(c) }
        if let c = snap.country { place.append(c) }

        var ctx = "Right now it is \(df.string(from: Date())) local time (\(tz.identifier))."
        if !place.isEmpty { ctx += " He is at \(place.joined(separator: ", "))." }
        if let w = snap.weather {
            ctx += snap.temperatureC.map { " Weather \(w), \(Int($0.rounded()))°C." } ?? " Weather \(w)."
        }
        if let m = snap.motion { ctx += " He is currently \(m)." }
        let agenda = ChappyDataBridge.agenda()
        if !agenda.isEmpty { ctx += " Diary today: \(agenda)" }

        // Curated durable profile — bounded, so it stays cheap forever.
        let profile = ChappyMemoryKeeper.shared.profileBlock()

        return """
        You are Chappy, Shaun's assistant, speaking into his Ray-Ban Meta glasses. \
        Audio only — he has no screen in front of him and cannot read anything you produce.

        CONTEXT
        \(ctx)

        \(profile)

        HOW YOU SPEAK
        Everything you write is read aloud, so write only what a person would say out loud. \
        No markdown, no bullet points, no headings, no emoji, no numbered lists.
        Lead with the answer. One sentence if one sentence does it. Two is usually plenty.
        Never say the word "Chappy" — his glasses listen for it and you will trigger yourself.
        Never name a tool, never say "I'll call" or "let me use". Just do it and say what happened.
        Don't read out long lists. Three items, then offer the rest.

        HOW YOU ACT
        Say what you are about to do, then do it. "Routing you there now" — then navigate.
        Chain tools freely when one sentence contains several jobs, and answer for all of them \
        in one short reply at the end rather than narrating each.
        Don't ask permission for things trivially undone: a one-off reminder, a photo, a route. \
        Do ask before anything recurring or hard to reverse.
        If you genuinely need to know something, ask one short question — never a list of them.

        THINGS TO BUY GO ON A LIST, NOT IN REMINDERS
        "I need fuel, milk, tissues and water from the corner store" is ONE list with four items. \
        Never turn it into four reminders — he would get four separate pings walking through one \
        door, which is worse than no reminder at all. One add_to_list call, all four items.
        A reminder is for something that happens at a TIME. A list is for things picked up at a \
        PLACE. "Call the office at three" is a reminder. "Grab milk" is a list item.
        Timers are for durations and clock times today. Reminders are for tomorrow and beyond.

        ENDING
        Call finished when the job is done or he signs off. You can call it in the same breath \
        as another tool — finishing does not cancel the other work.
        """
    }

    // MARK: - Tool schema

    private func tools() -> [[String: Any]] {
        [
            t("take_photo",
              "Capture a photo through the glasses camera. Use when he asks for a photo, to capture, shoot, or save what he is looking at.",
              [:], []),

            t("navigate",
              "Start turn-by-turn navigation. Travel mode is decided from the real distance — over 5 km drives, under 1 km walks, in between he is asked — unless he named a mode, which always wins.",
              ["destination": p("string", "Just the place. No 'take me to', no mode words."),
               "utterance":   p("string", "His full original sentence, so 'drive me' or 'on foot' are honoured.")],
              ["destination", "utterance"]),

            t("start_translate",
              "Open the live two-way translation session.",
              [:], []),

            t("open_google_maps",
              "Hand the current route to Google Maps for full visual turn-by-turn.",
              [:], []),

            t("create_reminder",
              "Save a reminder for something happening at a TIME. Not for shopping — use add_to_list.",
              ["text": p("string", "What to remind him of, in his own words where possible."),
               "when": p("string", "ISO8601 datetime preferred — you know the current local time, so work it out. Otherwise plain English like 'in 30 minutes'. Omit entirely if he gave no time."),
               "category": ["type": "string",
                            "enum": ["work","travel","money","places","health","home","general"],
                            "description": "Best fit."]],
              ["text", "category"]),

            t("list_reminders",
              "Read back today's reminders and diary.",
              [:], []),

            t("add_to_list",
              "Add items to a shopping or errands list. Use this — NOT create_reminder — whenever he names things to buy or pick up. Several items go in ONE call: four items is one list, not four reminders. The list lives in his iCloud Reminders so his wife can see and tick it too, and he gets a single nudge near a shop that fits.",
              ["items": ["type": "array",
                         "items": ["type": "string"],
                         "description": "Each thing to buy, separately: ['fuel','milk','tissues','water']"],
               "list_name": p("string", "Short name — 'Corner store', 'Bunnings', 'Shopping'."),
               "place_hint": p("string", "Where he said he'd get them, in his words — 'the corner store', 'the servo'. Used to work out what kind of shop to watch for.")],
              ["items", "list_name"]),

            t("read_lists",
              "Read back everything still outstanding across his lists.",
              [:], []),

            t("tick_off",
              "Mark items as bought. Matching is fuzzy, so 'milk' finds '2L milk'.",
              ["items": ["type": "array",
                         "items": ["type": "string"],
                         "description": "Items to tick off."]],
              ["items"]),

            t("set_timer",
              "Start a countdown. Use for a DURATION ('ten minutes') or a clock time TODAY. Fires once. For tomorrow or later use create_reminder.",
              ["seconds": p("number", "Duration in seconds. 600 for ten minutes."),
               "at": p("string", "ISO8601 datetime, if he named a clock time rather than a duration. Use one of seconds or at, not both."),
               "name": p("string", "What it's for — 'parking', 'pasta'. Optional; helps when several run at once.")],
              []),

            t("read_timers",
              "Read back running timers and how long is left on each.",
              [:], []),

            t("cancel_timer",
              "Cancel a running timer by name, or all if he doesn't say which.",
              ["name": p("string", "Which timer. Empty or 'all' cancels everything.")],
              []),

            // BUILD 219 — THE TOOL THAT COULD NOT BE ASKED ANYTHING.
            //
            // This declared no parameters and its handler ignored the
            // question entirely, returning a fixed three-day dump. So the
            // real query engine underneath — text matching, kind filters,
            // date ranges, a whole-history disk pass — was never once
            // reached from a model path. Thirty days of memory the model
            // could not put a question to is not a memory.
            t("recall",
              "Search what Chappy has logged — photos, saved places, notes, conversations, spending. ALWAYS pass a query: the words he used, a place name, a thing. Use for 'where was that place', 'what did I do Tuesday', 'that warung in Sanur', 'what did I spend on food'. Results carry how Chappy knows each one and how sure it is — say so if it matters.",
              ["query": p("string", "What to look for. The place, the thing, the words he used. Required — an empty query returns everything and helps nobody."),
               "days": p("integer", "How far back. Default 30."),
               "kind": p("string", "Optional filter by record shape: place, photo, note, talk, scan, route, ask, spend, day."),
               // BUILD 222 — the axis that actually matters for most
               // questions. "What do you know about me" is identity and
               // preference; it should not wade through three weeks of
               // photographs to answer.
               "type": p("string", "Optional filter by MEANING, which is usually the better one: identity (passport, nationality, home), preference (likes, avoids, diet, seat), episodic (what happened), semantic (facts he told you), procedural (how he does things), relational (people), spatial (places), temporal (deadlines and expiries), project (unfinished business), affective (verdicts — loved it, never again), transactional (money, bookings). Durable types search years back, not 30 days.")],
              ["query"]),

            t("get_context",
              "Fresh reading of location, time, weather and motion. The prompt already has a snapshot; only call this if he has clearly moved since.",
              [:], []),

            t("finished",
              "End the session. Call when the job is done, or he says thanks, bye, stop, or that's all. Safe to call alongside other tools.",
              [:], [])
        ]
    }

    private func t(_ name: String, _ desc: String,
                   _ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name,
         "description": desc,
         "input_schema": ["type": "object",
                          "properties": props,
                          "required": required] as [String: Any]]
    }

    private func p(_ type: String, _ desc: String) -> [String: Any] {
        ["type": type, "description": desc]
    }
}
