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
import CoreLocation

@MainActor
final class ChappyConversation: ObservableObject {
    static let shared = ChappyConversation()
    private init() {}

    /// True while a session owns the wearer's speech. Standby checks this.
    @Published private(set) var isActive = false

    // ============================================================
    // BUILD 263 — CAN THIS BRAIN BE OPENED AT ALL?
    //
    // Asked BEFORE promoting a sentence here, not discovered after. The
    // fall-through at the bottom of the ladder now hands everything it
    // could not place to this session, and without this check a missing
    // Anthropic key would turn every unmatched sentence into "No key
    // configured" — replacing quickAsk, which needs the same key but at
    // least fails as one line rather than as an opened-and-closed session.
    // ============================================================
    var canOpen: Bool { anthropicKey() != nil }

    /// BUILD 263 — the screens this brain can open by name.
    ///
    /// Translate and Google Maps are deliberately ABSENT: they already have
    /// their own tools, and translate's needs `handOff()` before the
    /// notification or the recogniser and the translator fight over the
    /// microphone. Two ways to do one thing is how that bug comes back.
    private static let screens: [String: Notification.Name] = [
        "flights":          .chappyOpenFlights,
        "weather":          .chappyOpenWeather,
        "travel_desk":      .chappyOpenTravel,
        "visas":            .chappyOpenVisa,
        "currency":         .chappyOpenFX,
        "places":           .chappyOpenPlaces,
        "search":           .chappyOpenSearch,
        "memory":           .chappyOpenMemory,
        "reminders":        .chappyOpenReminders,
        "upcoming":         .chappyOpenUpcoming,
        "atlas":            .chappyOpenAtlasMap,
        "dictate":          .chappyOpenDictate,
        "briefs":           .chappyOpenBriefs,
        "close_everything": .chappyCloseEverything,
    ]

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
                let began = Date()
                let out = await execute(tool: name, args: args)
                // ============================================================
                // BUILD 264 — THE SESSION LEFT NO TRACE, AT ALL.
                //
                // There was not one ChappyRouterLog call anywhere in this
                // file's twenty-four tool handlers. "What Chappy did" recorded
                // the session OPENING and then went blind for up to three
                // minutes and up to a dollar twenty — and because the opening
                // row is logged as a real decision, build 253's gap detector
                // was satisfied and never flagged the silence.
                //
                // That screen is the only evidence behind every promotion
                // decision left in this redesign. It cannot stop at the door.
                //
                // routeDecision: false — the routing decision was made when
                // the session was opened. These are what it then did.
                // ============================================================
                ChappyRouterLog.shared.add(
                    heard: name + (args.isEmpty ? "" : " " + args.map { "\($0.key)=\($0.value)" }
                        .sorted().joined(separator: ", ")),
                    tier: "tool", tool: name, confidence: nil,
                    outcome: String(out.prefix(160)),
                    ms: Int(Date().timeIntervalSince(began) * 1000),
                    routeDecision: false)
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
            // BUILD 264 — RE-ARM THE CEILING, NOT JUST THE SILENCE CLOCK.
            //
            // scheduleCeiling() was called once, from open(), and never
            // again. resetSilenceTimer was re-armed here and on send; the
            // three-minute ceiling was not. So a turn that legitimately
            // takes minutes — which a web-search chain does, at the
            // timeouts in this file — was guillotined mid-answer, and the
            // reply he had waited for was discarded by the isActive guard
            // above. He would experience it as Chappy thinking hard, saying
            // "that's a few minutes", and then telling him nothing.
            //
            // The ceiling exists to stop a FORGOTTEN session sitting open,
            // not to interrupt one that is working.
            scheduleCeiling()
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

        // ============================================================
        // BUILD 263 — THE HANDS. Everything below this line is new.
        //
        // Until this build the session's tool list was photo, navigate,
        // translate, maps, reminders, lists, timers, recall and context.
        // The file's OWN comments name what that left out — "no weather,
        // no spend, no visa, no flight, no OCR, no web" — and that gap is
        // the whole reason the keyword ladder could never be demoted: the
        // brain that could understand him had no hands, and the hands had
        // no brain.
        //
        // Every one of these calls an engine that has been in the app for
        // dozens of builds and was reachable only by saying the exact
        // right words. None of them is new capability. All of them are
        // wiring.
        // ============================================================

        case "search_the_web":
            let q = (args["query"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard q.count > 2 else { return "No query given." }
            // The cap is his money, and the model must be told when it is
            // spent rather than being handed an apology string it will read
            // out as if it were the answer.
            guard ChappySearch.shared.remainingToday > 0 else {
                return "The daily web-search budget is spent. Say so plainly and answer from what you know, or offer to try again tomorrow."
            }
            return await ChappySearch.shared.ask(q, speak: false)

        case "look_up":
            let subject = (args["subject"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty else { return "No subject given." }
            if let fact = await ChappyFacts.shared.look(up: subject) { return fact }
            return "Nothing in the free encyclopaedia for \(subject). Use search_the_web if it matters, or answer from what you know."

        case "weather":
            let place = (args["place"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if place.isEmpty {
                // CACHED ON WHERE, NOT ON WHETHER — and both halves of that
                // were review findings against my own first two cuts.
                //
                // My first cut reused the reading whenever `now` was
                // non-nil. ChappyWeather is ONE process-wide singleton whose
                // location is whatever loadPlace last set, so after he asks
                // about anywhere else `now` is never nil again and "what's
                // it like outside" would read out Denpasar while he stands
                // in Brisbane — stated as fact, because this build's own
                // prompt tells the model to trust a tool over its memory.
                //
                // My second cut reloaded unconditionally, which fixed that
                // and broke two other things: an Open-Meteo request has a
                // twenty-second timeout, so on a bad connection every repeat
                // question held his microphone for twenty seconds; and the
                // Weather SCREEN observes this same object, so a screen he
                // left showing Denpasar snapped to where he was standing.
                //
                // So: reuse only a reading taken in the last ten minutes
                // within two kilometres of where he is now. fetchedAt is
                // written only on success and coord is written per load, so
                // this can never reuse a failed or wrong-place reading.
                let wx = ChappyWeather.shared
                let here = ContextEngine.shared.snapshot
                var reusable = false
                if let takenAt = wx.fetchedAt, Date().timeIntervalSince(takenAt) < 600,
                   let was = wx.coord, let lat = here.latitude, let lon = here.longitude {
                    reusable = CLLocation(latitude: was.latitude, longitude: was.longitude)
                        .distance(from: CLLocation(latitude: lat, longitude: lon)) < 2000
                }
                if !reusable { await wx.loadHere() }
            } else {
                await ChappyWeather.shared.loadPlace(place)
            }
            // A FAILED LOAD MUST NOT ANSWER WITH THE LAST PLACE'S NUMBERS.
            // Both loaders return early on no GPS fix or a geocoder miss —
            // they set `error` and leave `now`, `days` and `placeName`
            // exactly as they were. Nothing here read `error`, so the one
            // moment this tool was most likely to be wrong was the moment it
            // sounded most certain.
            if let failed = ChappyWeather.shared.error, ChappyWeather.shared.now != nil {
                return "The weather didn't load: \(failed) Say that to him. Do NOT give him numbers — anything still in memory is from somewhere else."
            }
            switch (args["span"] as? String ?? "now").lowercased() {
            case "week":   return ChappyWeather.shared.spokenWeek()
            case "rain":   return ChappyWeather.shared.spokenRain()
            case "detail": return ChappyWeather.shared.spokenFull()
            case "uv":
                // The one thing neither spokenNow nor spokenFull will tell
                // you: spokenNow mentions UV only at 6 or above, so "is it
                // safe" and "there is no reading" are the same silence.
                guard let n = ChappyWeather.shared.now else { return "No weather loaded." }
                // Named, because unlike spokenNow this line carries no place
                // of its own — and a bare "U V is 11, extreme" is exactly the
                // kind of confident orphan sentence this build must not make.
                var uvLine = "U V in \(ChappyWeather.shared.placeName) is \(Int(n.uv.rounded())), \(ChappyWeather.uvWord(n.uv))."
                if n.uv >= 8 { uvLine += " Sunscreen and a hat, and off the beach in the middle of the day." }
                else if n.uv >= 6 { uvLine += " Worth putting sunscreen on." }
                else if n.uv < 3 { uvLine += " He'll be fine without." }
                return uvLine
            default:       return ChappyWeather.shared.spokenNow()
            }

        case "cheapest_flights":
            guard ChappyFareSource.isConfigured else {
                return "There is no fare key set, so there is no day-by-day price data at all. Tell him: Settings, Travel Desk, Fare data."
            }
            let toRaw = (args["to"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !toRaw.isEmpty else { return "No destination given." }
            guard let dest = ChappyPorts.resolve(place: toRaw) else {
                return "Couldn't work out which airport \(toRaw) means. Ask him for the city or the airport code."
            }
            let fromRaw = (args["from"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let origin = (fromRaw.isEmpty ? nil : ChappyPorts.resolve(place: fromRaw))
                ?? ChappyPorts.byIATA(ChappyFlightsPrefs.origin)
            // Split, because one message for two different failures sent him
            // in a circle: home airport BNE plus "cheapest flights to
            // Brisbane" resolved both ends to BNE, told him Chappy couldn't
            // work out where he was flying from, and said exactly the same
            // thing again when he answered "Brisbane".
            guard let origin else {
                return "Couldn't work out where he is flying FROM. Ask him."
            }
            guard origin.iata != dest.iata else {
                return "That is the same airport both ends — \(dest.iata) to \(dest.iata). Ask him where he is actually starting from."
            }
            var monthKey = (args["month"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if monthKey.isEmpty { monthKey = ChappyFlightsPrefs.thisMonth }
            // Validated rather than defaulted. Silently answering about the
            // wrong month is worse than asking, because he cannot see it.
            // The RANGE, not just the digits. A model that gets the arithmetic
            // wrong sends 2026-13 or 2026-00; those passed, fetched nothing,
            // and came back as "nobody has searched that route lately" — a
            // confident wrong explanation of a malformed request it could
            // simply have retried.
            guard monthKey.count == 7, Array(monthKey)[4] == "-",
                  Int(monthKey.prefix(4)) != nil,
                  let mm = Int(monthKey.suffix(2)), (1...12).contains(mm) else {
                return "The month must be yyyy-MM with a real month, like 2026-10. You know today's date — work it out and call again."
            }
            let days = await ChappyFareSource.shared.month(origin: origin.iata,
                                                           dest: dest.iata,
                                                           month: monthKey)
            guard !days.isEmpty else {
                return "No cached fares for \(origin.iata) to \(dest.iata) in \(monthKey). That means nobody has searched that route lately — it does NOT mean nothing flies. Say it that way."
            }
            let sorted = days.sorted { $0.price < $1.price }
            let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEEE d MMMM"
            var named: [Double] = []
            var picks: [String] = []
            for d in sorted {
                guard picks.count < 4 else { break }
                // Skip anything within a couple of dollars of a day already
                // named, or it reads out four near-identical numbers.
                guard !named.contains(where: { abs($0 - d.price) < 3 }) else { continue }
                named.append(d.price)
                // ageNote is "" when the row carried no timestamp, which left
                // a dangling comma — "Friday 3 October $412 direct, ; Tuesday
                // 7 October" — spoken as a stumble.
                picks.append("\(dayFmt.string(from: d.date)) \(ChappyFX.money(d.price, d.currency))"
                             + (d.direct ? " direct" : " one stop")
                             + (d.ageNote.isEmpty ? "" : ", \(d.ageNote)"))
            }
            let avg = sorted.map { $0.price }.reduce(0, +) / Double(sorted.count)
            return "Cheapest \(origin.iata) to \(dest.iata) in \(monthKey): "
                + picks.joined(separator: "; ")
                + ". Month average \(ChappyFX.money(avg, sorted[0].currency))."
                + " These are fares somebody's search returned and Chappy cached — not live quotes. Read him two or three, not all four."

        case "save_place":
            let placeName = (args["name"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let saved = TripRecorder.shared.rememberSpot(named: placeName)
            if saved.lat == 0 {
                return "Saved \(saved.name), but GPS hadn't settled so the pin may be off. Tell him that."
            }
            return "Saved \(saved.name)."

        case "saved_places":
            let wanted = (args["name"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let here = ContextEngine.shared.snapshot
            if wanted.isEmpty {
                let all = TripRecorder.shared.spots
                guard !all.isEmpty else {
                    return "No places saved yet. He can say: remember this spot, call it the blue warung."
                }
                let recent = all.reversed().prefix(10).map { $0.name }
                return "\(all.count) saved. Most recent: \(recent.joined(separator: ", "))."
            }
            guard let spot = TripRecorder.savedSpot(matching: wanted,
                                                    nearLat: here.latitude,
                                                    nearLon: here.longitude) else {
                let known = TripRecorder.shared.spots.reversed().prefix(8)
                    .map { $0.name }.joined(separator: ", ")
                return known.isEmpty
                    ? "Nothing saved by that name, and nothing saved at all yet."
                    : "Nothing saved matching that. What he has saved: \(known)."
            }
            var out = spot.name
            if let street = spot.street { out += ", \(street)" }
            if let city = spot.city, city != spot.street { out += ", \(city)" }
            if let lat = here.latitude, let lon = here.longitude, spot.lat != 0 {
                let metres = CLLocation(latitude: lat, longitude: lon)
                    .distance(from: CLLocation(latitude: spot.lat, longitude: spot.lon))
                out += metres < 1000
                    ? ", about \(Int(metres)) metres away"
                    : String(format: ", about %.1f km away", metres / 1000)
            }
            if let note = spot.note, !note.isEmpty { out += ". His note: \(note)" }
            return out + ". To take him there call navigate with destination \"\(spot.name)\"."

        case "convert_money":
            let amount = (args["amount"] as? Double)
                ?? (args["amount"] as? Int).map(Double.init)
                ?? 0
            let fromCode = (args["from"] as? String ?? "").uppercased()
            let toCode = ((args["to"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                          ?? ChappyFX.shared.home).uppercased()
            guard amount > 0, fromCode.count == 3, toCode.count == 3 else {
                return "Need an amount and two three-letter currency codes, like AUD and IDR."
            }
            await ChappyFX.shared.refresh()
            guard let converted = ChappyFX.shared.convert(amount, from: fromCode, to: toCode) else {
                return "No rate known for \(fromCode) to \(toCode)."
            }
            return "\(ChappyFX.money(amount, fromCode)) is \(ChappyFX.money(converted, toCode))."
                + ChappyFX.rateAge

        case "open_screen":
            let screenID = (args["screen"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let note = Self.screens[screenID] else {
                return "No screen called that. The ones that exist: "
                    + Self.screens.keys.sorted().joined(separator: ", ") + "."
            }
            NotificationCenter.default.post(name: note, object: nil)
            if screenID == "close_everything" {
                return "Closed everything that was up, including any camera, stream or translation. Tell him that, so he isn't surprised."
            }
            return "Opened \(screenID.replacingOccurrences(of: "_", with: " "))."

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

        WHAT TO REACH FOR
        You have real hands now, and the whole point of them is that he should never have to \
        say a magic word. If he asks something you cannot answer from what you already know, \
        there is almost always a tool for it — use it rather than guessing or apologising.
        Weather, fares, rates and anything about his own saved places must come from a tool. \
        Never state a temperature, a fare, an exchange rate or where one of his places is from \
        memory: you will be confidently wrong and he is wearing this on his face.
        Cheapest before dearest: look_up before search_the_web, and neither if you simply know.
        When he names somewhere personal — my gym, the hotel, that warung — call saved_places \
        FIRST and pass the name it gives you to navigate. Otherwise you will route him to a \
        stranger's gym.

        WHEN YOU CANNOT DO SOMETHING
        Say so in one short sentence and say what would fix it. "There's no fare key set, so I \
        can't see prices" beats a vague apology. Never invent a capability, never promise to do \
        something later, and never claim a tool worked when its result says it did not.

        ENDING
        Call finished when the job is done or he signs off. You can call it in the same breath \
        as another tool — finishing does not cancel the other work.
        If you have answered him and there is plainly nothing more to do, call finished. A \
        session left open owns his microphone for forty-five seconds, which is forty-five \
        seconds he cannot talk to the rest of the app.
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

            // ============================================================
            // BUILD 263 — THE HANDS, DECLARED.
            // ============================================================

            t("search_the_web",
              "Search the live web and get a researched answer with sources. Use for anything that happened recently, any price, any opening hours, any 'is X still true', any news, and anything you are not certain of. Costs real money and is capped at 15 a day, so do NOT use it for something you already know or that look_up can answer.",
              ["query": p("string", "The question, written out in full as you would type it into a search engine. Not his raw mumble — the actual question.")],
              ["query"]),

            t("look_up",
              "Free encyclopaedia lookup — one paragraph on a person, place, thing or event. No cost, no cap, fast. TRY THIS BEFORE search_the_web for anything encyclopaedic. It knows nothing about the last year or two and nothing about prices, hours or news.",
              ["subject": p("string", "Just the subject. 'Borobudur', not 'tell me about Borobudur'.")],
              ["subject"]),

            t("weather",
              "Real forecast data for here or a named place. The prompt already carries a rough snapshot of the weather where he is standing; call this when he actually asks about weather, about another town, about rain, or about the days ahead.",
              ["place": p("string", "Town or city. Leave out entirely for where he is now."),
               "span": ["type": "string",
                        "enum": ["now", "detail", "rain", "week", "uv"],
                        "description": "now = temperature and conditions. detail = adds humidity, pressure, sunrise and sunset. rain = will it rain in the next twelve hours. week = five days. uv = the U V index and whether he needs sunscreen — use this for anything about sunburn, sunscreen or the sun's strength, because the other spans mention U V only when it is already high."]],
              []),

            t("cheapest_flights",
              "Which days in a month are cheapest to fly a route. Returns cached fares that other people's searches have already returned — it is NOT a live quote and NOT a booking. Say so when you read it out.",
              ["to": p("string", "Destination city or airport, in plain words. 'Bali', 'Denpasar', 'DPS'."),
               "from": p("string", "Origin city or airport. Leave out to use his saved home airport."),
               "month": p("string", "yyyy-MM, like 2026-10. You know today's date, so work it out from what he said. Leave out for this month.")],
              ["to"]),

            t("save_place",
              "Save where he is standing right now, under a name, so he can say 'take me to the gym' later. Use for 'remember this spot', 'save this as the gym', 'this is my hotel'. Only works for HERE — it cannot save somewhere he is merely talking about.",
              ["name": p("string", "What to call it, in his words. 'The gym', 'the blue warung'. Leave empty and it gets named after the time and street.")],
              []),

            t("saved_places",
              "Look up a place he saved earlier, or list them. Use before navigate whenever he names somewhere personal — 'my gym', 'the hotel', 'that warung' — so you route to HIS one and not a search result.",
              ["name": p("string", "The place he named. Leave out entirely to list what he has saved.")],
              []),

            t("convert_money",
              "Convert between currencies at real cached rates. Use whenever a price in a foreign currency comes up, even if he did not ask — knowing 850,000 rupiah is eighty dollars is the point of the thing.",
              ["amount": p("number", "How much."),
               "from":   p("string", "Three-letter code of what he has: IDR, THB, AUD, USD."),
               "to":     p("string", "Three-letter code to convert into. Leave out for his home currency.")],
              ["amount", "from"]),

            t("open_screen",
              "Put one of Chappy's own screens up on the phone. Use when he asks to see, open, show or pull up something, and when an answer is long enough that he will want to look at it afterwards. Opening a screen does not answer his question — say the answer too.",
              ["screen": ["type": "string",
                          "enum": ["flights", "weather", "travel_desk", "visas", "currency",
                                   "places", "search", "memory", "reminders", "upcoming",
                                   "atlas", "dictate", "briefs", "close_everything"],
                          "description": "Which screen. close_everything is not gentle — it also ends any live stream, camera session or translation that is running, so only call it when he has plainly asked to close, cancel or stop what is up."]],
              ["screen"]),

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
