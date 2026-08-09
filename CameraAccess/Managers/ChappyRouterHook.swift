/*
 * ChappyRouterHook — one line of patch, everything else additive
 *
 * ── WHY THIS FILE EXISTS ───────────────────────────────────────────────
 * Wiring the conversation layer, distance-aware navigation, lists, timers and
 * the proactive briefs into ChappyStandby.route() the obvious way needs edits
 * in six separate places inside an 8,700-line file. Every one is a chance to
 * clobber something. So everything lives here behind a single entry point, and
 * route() needs exactly one inserted line:
 *
 *     private func route(_ c: String) async {
 *         if await ChappyRouterHook.intercept(c) { return }     // <- this
 *         ... everything already there, untouched ...
 *
 * If intercept returns false the existing router runs exactly as before, so
 * the worst case for anything this file doesn't understand is the behaviour
 * you already have.
 *
 * ── ORDER OF PRECEDENCE ────────────────────────────────────────────────
 *   1. Safety, stops, and every existing module command → declined
 *   2. A live session                → gets the speech
 *   3. An unanswered "walk or drive?" → gets the answer
 *   4. Brief requests                → read the last one, free
 *   5. Several jobs in one breath    → opens a session
 *   6. Timers and lists              → handled free and instantly
 *   7. A plain navigation command    → distance-aware routing
 *   8. Judgement, planning, advice   → opens a session
 *   9. Anything else                 → declined
 */

import Foundation

@MainActor
enum ChappyRouterHook {

    // MARK: - Pending walk-or-drive question

    private static var pendingModeDest: String?
    private static var pendingModeAt = Date.distantPast
    private static let pendingModeTTL = 45.0

    // MARK: - Entry point

    /// Returns true if this command was fully handled here.
    static func intercept(_ c: String) async -> Bool {

        // ── 1. Hands off ────────────────────────────────────────────────
        if mustReachExistingRouter(c) {
            // A stop word while a session is open should still close it.
            if ChappyConversation.shared.isActive { ChappyConversation.shared.close() }
            return false
        }

        // ── 2. A live session owns the wearer's speech ──────────────────
        if ChappyConversation.shared.isActive {
            if isSignOff(c) { ChappyConversation.shared.close(sayBye: true) }
            else            { ChappyConversation.shared.send(c) }
            return true
        }

        // ── 3. Answering an outstanding walk-or-drive question ──────────
        if let dest = pendingModeDest {
            if Date().timeIntervalSince(pendingModeAt) > pendingModeTTL {
                pendingModeDest = nil
            } else if looksLikeModeAnswer(c) {
                pendingModeDest = nil
                await speakDecision(await ChappyNavMode.answerMode(c, destination: dest))
                return true
            } else {
                pendingModeDest = nil        // he moved on; so do we
            }
        }

        // ── 4. Briefs ───────────────────────────────────────────────────
        if isBriefRequest(c) {
            ChappyProactive.shared.speakLastBrief()
            return true
        }

        // ── 5. Several jobs in one breath → session ─────────────────────
        // Checked BEFORE navigation, or "take me to the servo and remind me
        // to get milk" is swallowed by the nav branch and the reminder never
        // happens.
        if carriesMultipleJobs(c) {
            ChappyConversation.shared.open(carrying: c)
            return true
        }

        // ── 5b. Ambient memory: dial, boost, browse, spend ──────────────
        // All free and local — no model, no network.
        if let spoken = handleMemoryCommand(c) {
            TTSService.shared.speak(spoken)
            return true
        }

        // ── 6. Timers and lists, free and instant ───────────────────────
        // The commands he'll use most, none of which needs a model. Opening a
        // paid session to hear "ten minutes" would be daft, and slower, which
        // matters more.
        if let spoken = await handleTimerOrList(c) {
            TTSService.shared.speak(spoken)
            return true
        }

        // ── 7. Navigation → distance decides the mode ───────────────────
        if let dest = destination(in: c) {
            // Saved-home routing already works well; leave it alone.
            if ["home", "hotel", "the hotel", "my hotel", "our hotel", "the room"]
                .contains(dest.lowercased()) { return false }

            TTSService.shared.speak(ChappyVoice.line("nav_ack", [
                "Finding it.", "One sec.", "Looking that up."
            ]))
            await speakDecision(await ChappyNavMode.go(to: dest, utterance: c))
            return true
        }

        // ── 8. Judgement, planning, advice → session ────────────────────
        if wantsThinking(c) {
            ChappyConversation.shared.open(carrying: c)
            return true
        }

        return false
    }

    // MARK: - Speaking a nav decision

    private static func speakDecision(_ decision: ChappyNavDecision) async {
        switch decision {
        case .route(let modelReply):
            // Prefer the human-facing summary; the returned string is written
            // for a model and says things like "Also tell the user:".
            TTSService.shared.speak(
                NavEngine.shared.spokenRouteSummary ?? ChappyStandby.humanise(modelReply))
        case .ask(let dest, let question):
            pendingModeDest = dest
            pendingModeAt = Date()
            TTSService.shared.speak(question)
        case .failed(let reason):
            ChappyEarcon.shared.fail()
            TTSService.shared.speak(reason)
        }
    }

    // MARK: - Classifiers

    /// Everything the existing router already handles well, plus safety.
    ///
    /// AUDIT FIX: the first version only guarded emergency and stops, so the
    /// hook's broad "wantsThinking" and multi-job tests sat ABOVE branches
    /// that already worked — "what's this" went to a paid session instead of
    /// Quick Vision, and "get the computer to send the photos and the notes"
    /// opened a session instead of queueing a computer job. Anything with a
    /// working home is declined here before the fuzzy tests run.
    private static func mustReachExistingRouter(_ c: String) -> Bool {
        // Safety
        let sos = ["emergency", "sos", "call for help", "i need an ambulance",
                   "call an ambulance", "i need help now"]
        let asksAbout = c.hasPrefix("what") || c.hasPrefix("where") || c.hasPrefix("is there")
            || c.hasPrefix("are there") || c.contains("emergency room")
            || c.contains("emergency number") || c.contains("emergency exit")
        if !asksAbout,
           sos.contains(where: { c == $0 || c.hasPrefix($0 + " ") || c.hasSuffix(" " + $0) }) {
            return true
        }

        // Stops and silence
        let stops = ["stop navigation", "stop navigating", "cancel navigation",
                     "stop the route", "shut up", "be quiet", "never mind",
                     "cancel that", "back to standby", "stop talking",
                     "that's enough", "thats enough"]
        if stops.contains(where: { c.contains($0) }) { return true }
        if c == "stop" || c == "cancel" || c == "enough" { return true }

        // Tier 3 — the computer
        if ["get the computer to", "ask my computer", "have the pc", "have the computer",
            "computer job", "get the pc to", "tell the computer to",
            "when the computer's on", "when the computer is on"]
            .contains(where: { c.contains($0) }) { return true }

        // Vision and one-look branches that already work and are cheaper
        if ["what's this", "what is this", "what's that", "what is that",
            "what am i looking at", "look at this", "read this", "read that",
            "read the menu", "read it", "read me", "what does this say",
            "what does that say", "good deal", "good price", "ripped off",
            "worth it", "too expensive", "can i eat", "can we eat",
            "is this safe to eat", "allergen", "keep watching",
            "continuous vision", "narrate", "open google maps", "open maps",
            "take a photo", "take a picture", "snap a photo"]
            .contains(where: { c.contains($0) }) { return true }

        return false
    }

    private static func isSignOff(_ c: String) -> Bool {
        ["bye", "goodbye", "that's all", "thats all", "that's it", "thats it",
         "we're done", "were done", "all good", "nothing else", "end session",
         "close session", "stop session"]
            .contains { c == $0 || c.hasPrefix($0 + " ") || c.hasSuffix(" " + $0) }
            || c == "thanks" || c == "thank you" || c == "cheers"
    }

    private static func looksLikeModeAnswer(_ c: String) -> Bool {
        guard c.split(separator: " ").count <= 5 else { return false }
        return ["walk", "walking", "foot", "drive", "driving", "car", "taxi",
                "grab", "scooter", "bike", "motorbike", "ride"]
            .contains { c.contains($0) }
    }

    /// AUDIT FIX: this used to include "check in", which matched "check in on
    /// the booking" and "what time do we check in" — both hijacked into
    /// reading yesterday's brief.
    private static func isBriefRequest(_ c: String) -> Bool {
        ["what's my brief", "whats my brief", "my brief", "brief me",
         "what did i miss", "catch me up", "what's my day", "whats my day",
         "read my brief"]
            .contains { c.contains($0) }
    }

    /// True when one sentence plainly contains more than one job.
    ///
    /// Deliberately conservative. A false positive costs half a cent and opens
    /// a session that would have worked anyway; a false negative silently
    /// drops half of what he asked for, which is the failure he reported.
    private static func carriesMultipleJobs(_ c: String) -> Bool {
        let verbs = ["remind me", "take me", "navigate", "photo", "picture",
                     "translate", "add to", "put on", "book", "call", "text",
                     "look up", "find me", "set a timer", "pick up", "grab"]
        guard verbs.filter({ c.contains($0) }).count >= 2 else { return false }
        // Require a joining word too, so "find me a photo shop" — one job that
        // happens to contain two verb phrases — doesn't open a session.
        return [" and ", " then ", " also ", " plus ", ", and", " after that",
                " on the way", " while you", " as well"].contains { c.contains($0) }
    }

    /// Commands that want reasoning rather than a lookup.
    ///
    /// AUDIT FIX: "help me" alone caught "help me translate this" and "what
    /// am i" caught "what am i looking at" — both had cheaper, better homes in
    /// the existing router. Openers are anchored to the shapes that genuinely
    /// need a conversation.
    private static func wantsThinking(_ c: String) -> Bool {
        let openers = [
            "help me figure", "help me work out", "help me decide", "help me sort",
            "help me plan", "help me choose", "what should i", "what do you think",
            "should i", "walk me through", "talk me through", "let's plan",
            "lets plan", "plan my", "plan the", "give me advice", "any advice",
            "advise me", "what's the best", "whats the best", "which one should",
            "any ideas", "what have i got on", "let's talk", "lets talk",
            "talk to me about", "i need to sort", "sort out", "recommend"
        ]
        if openers.contains(where: { c.contains($0) }) { return true }
        // Long multi-clause sentences are conversations wearing a command's hat.
        return c.split(separator: " ").count > 22
    }

    // MARK: - Ambient memory commands (PHASE 5 STEP 2)

    /// The dial, the boost, the browser and the spend readout. Returns a line
    /// to speak, or nil to let the rest of the router have it.
    private static func handleMemoryCommand(_ c: String) -> String? {

        // Stop, first and unconditionally. If he wants it off it goes off,
        // and it must not be possible for a phrasing miss to keep it running.
        if ["stop remembering", "stop recording", "stop the camera",
            "stop ambient", "turn off memory", "forget the camera"]
            .contains(where: { c.contains($0) }) {
            ChappyPulse.shared.stopEverything()
            return nil                                   // stopEverything speaks
        }

        // "remember everything for the next hour" / "for 20 minutes"
        if c.contains("remember everything") || c.contains("record everything")
            || c.contains("capture everything") {
            var mins = 60
            if let n = c.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .filter({ !$0.isEmpty }).first.flatMap({ Int($0) }), n > 0, n <= 480 {
                mins = c.contains("hour") ? n * 60 : n
            } else if c.contains("hour") {
                mins = 60
            }
            ChappyPulse.shared.boost(minutes: min(mins, 480))
            return nil                                   // boost speaks
        }

        // Setting the dial by name.
        for tier in ChappyPulse.Tier.allCases where tier != .off {
            let name = tier.rawValue
            if c.contains("memory \(name)") || c.contains("\(name) memory")
                || c.contains("set memory to \(name)") || c.contains("go \(name)") {
                ChappyPulse.shared.setTier(tier)
                return nil                               // setTier speaks
            }
        }

        // How is it doing, and what has it cost.
        if ["memory status", "how's memory", "hows memory", "what's memory doing",
            "whats memory doing", "how much has memory cost", "what have i spent on memory"]
            .contains(where: { c.contains($0) }) {
            return ChappyPulse.shared.statusLine() + " " + ChappyPhotoIngest.shared.statusLine()
        }

        // Open the browser. Speech can't scroll a list, so this is a handoff.
        if ["show my memory", "open my memory", "show me my memories",
            "open memory", "memory browser", "show my photos from"]
            .contains(where: { c.contains($0) }) {
            NotificationCenter.default.post(name: .chappyOpenMemory, object: nil)
            return "Opening your memory."
        }

        // Stop volunteering places / start again.
        if c.contains("stop telling me about places") || c.contains("stop suggesting places") {
            ChappyRelevance.shared.isEnabled = false
            return "I'll keep quiet about places."
        }
        if c.contains("tell me about places") || c.contains("remind me about places") {
            ChappyRelevance.shared.isEnabled = true
            return "I'll mention places you've been when you're near them."
        }

        // Catch the photos up now rather than waiting for tonight.
        if c.contains("catch up on my photos") || c.contains("import my photos")
            || c.contains("ingest my photos") {
            Task { await ChappyPhotoIngest.shared.runNow() }
            return "Going through your glasses photos now."
        }

        return nil
    }

    // MARK: - Free timer and list handling

    /// Returns something to say if this was a timer or list command, nil to
    /// let the rest of the router have it. Only single-job phrasings reach
    /// here — anything with two jobs went to a session above.
    private static func handleTimerOrList(_ c: String) async -> String? {

        // Reading back
        if ["what's on my list", "whats on my list", "read my list",
            "what's on the list", "whats on the list", "my shopping list",
            "what do i need to get", "read my lists"].contains(where: { c.contains($0) }) {
            return await ChappyLists.shared.spokenSummary()
        }
        if ["what timers", "any timers", "how long left", "how long's left",
            "how longs left", "read my timers", "check my timer"]
            .contains(where: { c.contains($0) }) {
            return ChappyTimers.shared.spokenSummary()
        }

        // Cancelling
        if c.contains("timer"),
           c.contains("cancel") || c.contains("stop the timer") || c.contains("clear the timer") {
            // AUDIT FIX: this stripped "the" as a raw substring, so "cancel
            // the weather timer" lost the "the" inside "weather" and searched
            // for "waer". Whole words only.
            let drop: Set<String> = ["cancel", "stop", "clear", "the", "timer", "timers", "my"]
            let name = c.split(separator: " ")
                .map(String.init)
                .filter { !drop.contains($0) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return ChappyTimers.shared.cancel(matching: name)
        }

        // Ticking off
        for opener in ["tick off ", "cross off ", "got the ", "i got the ",
                       "mark off ", "check off ", "picked up "] {
            if let r = c.range(of: opener) {
                let items = splitItems(String(c[r.upperBound...]))
                if !items.isEmpty { return await ChappyLists.shared.complete(items) }
            }
        }

        // Setting a timer. Anchored openers only: "how many minutes to the
        // airport" is not a timer, and "remind me in ten minutes" is a
        // reminder.
        let timerOpeners = ["set a timer", "start a timer", "timer for",
                            "set timer", "time me for"]
        if timerOpeners.contains(where: { c.contains($0) }), !c.contains("remind") {
            guard let secs = ChappyTimers.parseDuration(c) else { return "How long for?" }
            var name: String?
            if let r = c.range(of: " for the ", options: .backwards) {
                let tail = String(c[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty, ChappyTimers.parseDuration(tail) == nil { name = tail }
            }
            return ChappyTimers.shared.set(seconds: secs, name: name)
        }

        return nil
    }

    /// "milk, tissues and water" → ["milk", "tissues", "water"]
    private static func splitItems(_ s: String) -> [String] {
        s.replacingOccurrences(of: " and ", with: ",")
            .replacingOccurrences(of: " & ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Destination extraction

    /// Mirrors ChappyStandby.navDestination, which is private. Kept here so
    /// this file stays additive; behaviour is deliberately identical.
    private static func destination(in c: String) -> String? {
        let questionOpeners = ["how far", "how long", "how much", "what time",
                               "is there", "are there"]
        if questionOpeners.contains(where: { c.hasPrefix($0) }) { return nil }

        let informational = ["tell me about", "what's", "whats", "what is",
                             "how good", "any good", "is the", "are the", "which"]
        let asksAbout = informational.contains { c.contains($0) }

        var openers = ["navigate me to ", "navigate us to ", "navigate to ",
                       "take me back to ", "take us back to ", "get us back to ",
                       "take me to ", "take us to ", "walk me to ", "walk us to ",
                       "drive me to ", "drive us to ", "direct me to ", "guide me to ",
                       "get me directions to ", "directions to ", "get me to ",
                       "route me to ", "route to ", "how do i get to ",
                       "how do we get to "]
        if !asksAbout { openers += ["closest ", "nearest "] }

        var best: Range<String.Index>?
        for o in openers {
            if let r = c.range(of: o, options: .backwards) {
                if best == nil || r.upperBound > best!.upperBound { best = r }
            }
        }
        guard let hit = best else { return nil }

        var d = String(c[hit.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))

        for junk in [" by car", " via car", " by scooter", " on the scooter",
                     " by motorbike", " by taxi", " by grab", " by bike",
                     " in the car", " on foot", " walking", " driving",
                     " please", " thanks", " thank you", " now"] {
            while let r = d.range(of: junk, options: .caseInsensitive) {
                d = d.replacingCharacters(in: r, with: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            }
        }
        d = d.replacingOccurrences(of: "  ", with: " ")
        for prefix in ["the ", "a ", "closest ", "nearest "] where d.lowercased().hasPrefix(prefix) {
            d = String(d.dropFirst(prefix.count))
        }
        d = d.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
        return d.count > 1 ? d : nil
    }
}


