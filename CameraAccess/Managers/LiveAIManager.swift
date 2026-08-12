/*
 * Live AI Manager
 * Manages Live AI sessions in the background — supports Siri and Shortcuts without unlocking the phone
 */

import Foundation
import SwiftUI
import AVFoundation
import AudioToolbox
import CoreLocation
import CoreMotion
import MapKit
import Speech
import Photos
import Network
import UserNotifications
import Vision   // BUILD 134: on-device OCR for the Reader
import ActivityKit   // BUILD 154: flight-day Live Activity (lock screen + Dynamic Island)
import WidgetKit     // BUILD 154: nudges the home-screen widget to refresh

// MARK: - CHAPPY EARCONS — the sound of being heard
//
// DESIGN NOTE (why tones, not speech, on every wake).
// Every shipping voice assistant answers the wake word with a SOUND, not a
// sentence, and they all converged on the same shape for the same reasons:
//
//   Siri            two-note chime, rising      (~200 ms)
//   Alexa           single soft tone + light    (~150 ms)
//   Google          two rising notes            (~180 ms)
//   Cortana         short rising sweep
//
// Three rules fall out of that convergence, and all three matter more with
// glasses on and the phone in a pocket than they do on a smart speaker:
//
//   1. LATENCY. The acknowledgement has to land within about 200 ms or you
//      start talking over it. Speech synthesis cannot hit that — it has to
//      allocate a voice and start an engine. A pre-rendered tone can.
//   2. BREVITY. You wake an assistant dozens of times a day. "Good morning,
//      how can I help you?" is charming twice and insufferable by lunchtime.
//      JARVIS in the films is terse for exactly this reason — the personality
//      is in the ONE line he says, not in a greeting ritual every time.
//   3. PITCH DIRECTION CARRIES MEANING. Rising = "go ahead, I'm listening".
//      Falling = "that didn't work". This is near-universal and free to adopt,
//      and it means you can tell success from failure with the phone pocketed
//      and no screen at all.
//
// So: a tone on EVERY wake, and a spoken greeting only when it is genuinely
// welcome — the first wake after a long gap, where it reads as Chappy coming
// on duty rather than as a chatbot clearing its throat.
//
// IMPLEMENTATION NOTE (why this does not use AVAudioEngine).
// The wake tone has to play while the microphone tap is live. Starting another
// AVAudioEngine at that exact moment is what has repeatedly taken this app's
// audio stack down — it forces a session reconfiguration and fires
// AVAudioEngineConfigurationChange at every engine in the process. So the tone
// is rendered once to a WAV in the caches directory and played through
// AudioServicesPlaySystemSound, which does not touch the session at all and
// cannot disturb a live recording. Rendering it in code also means NO new asset
// files, which matters because this project is built from the command line and
// adding a resource would mean editing project.pbxproj by hand.
// MARK: - CHAPPY VOICE — the warmth, kept on a short leash
//
// DESIGN NOTE (what "heart" means in a voice assistant, and what it doesn't).
// The temptation is to make the assistant effusive. That fails fast, for a
// reason worth stating plainly: you hear these lines dozens of times a day, and
// anything longer than a clause becomes an obstacle between you and the thing
// you asked for. Warmth in voice is NOT more words. It is:
//
//   1. VARIETY. The same six words every single time is what makes a machine
//      feel like a machine. Three or four alternates, never repeating twice in
//      a row, and it stops registering as canned — even though it plainly is.
//   2. NOTICING. Warmth is remarking on something only a companion would
//      notice: that it's your first walk of the day, that you've been going for
//      hours, that it's 2am, that the battery is nearly gone. The content is
//      caring; the length is one clause.
//   3. PROPORTION. Big moments get a beat more. Routine ones get almost
//      nothing. An assistant that celebrates every saved pin equally is
//      exhausting; one that says "nice one" the first time you find a real
//      bargain has a personality.
//
// So: short lines, rotated, occasionally observant, never chatty.
enum ChappyVoice {
    private static var lastPicked: [String: String] = [:]

    /// Pick a line that isn't the one used last time for this key.
    static func line(_ key: String, _ options: [String]) -> String {
        guard options.count > 1 else { return options.first ?? "" }
        let previous = lastPicked[key]
        let fresh = options.filter { $0 != previous }
        // Deterministic rotation rather than randomness — Chappy shouldn't
        // repeat himself, but he also shouldn't feel like a slot machine.
        let pick = fresh[abs(rotation) % fresh.count]
        rotation &+= 1
        lastPicked[key] = pick
        return pick
    }
    private static var rotation = 0

    static func timeOfDay(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 0..<5:   return "You're up late"
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Evening"
        }
    }

    /// Said when the app opens and the ear comes up — Chappy reporting for duty.
    ///
    /// The FIRST greeting of the day is allowed to be a proper hello, because
    /// you only get one and it sets the tone. Every one after that is clipped
    /// to a few words — a companion who greets you warmly at breakfast and
    /// nods the other nine times you open the app is pleasant; one who makes a
    /// speech every time is something you switch off by Tuesday.
    static func launchGreeting(name: String, date: Date, firstOfDay: Bool) -> String {
        let part = timeOfDay(date)
        let who = name.isEmpty ? "" : ", \(name)"
        if firstOfDay {
            return line("launch_first", [
                "\(part)\(who). Chappy here. What are we up to?",
                "\(part)\(who). Chappy here, ready when you are.",
                "\(part)\(who). Good to see you. What's the plan?",
            ])
        }
        return line("launch", [
            "Ready\(who).",
            "I'm here\(who).",
            "Listening\(who).",
        ])
    }

    /// Said when he says the name and nothing else.
    static func bareWake(name: String) -> String {
        let who = name.isEmpty ? "" : " \(name)"
        return line("bare_wake", ["Go ahead\(who).", "Yes\(who)?", "I'm listening.", "Mm?"])
    }

    /// Said when a command was heard but couldn't be actioned.
    /// THE PART THAT READS AS HEART.
    ///
    /// Warmth in an assistant is not politeness — "certainly, I'd be happy to"
    /// is a call centre, not a companion. It is NOTICING: remarking on
    /// something only someone paying attention would know. That it's your first
    /// walk of the day. That you've been going for hours. That it's 2am. That
    /// the battery won't last the walk home.
    ///
    /// One clause, occasionally, unprompted. Said every time it becomes
    /// wallpaper, so these fire at most once each per day.
    static func notice(hour: Int, walkedMinutes: Int, batteryPercent: Int, spotsToday: Int) -> String? {
        if (1...15).contains(batteryPercent) {
            return line("notice_batt", [
                "You're down to \(batteryPercent) percent, by the way.",
                "Battery's getting low - \(batteryPercent) percent left.",
            ])
        }
        if hour >= 23 || hour < 4 {
            return line("notice_late", ["Late one tonight.", "Still going, I see."])
        }
        if walkedMinutes >= 120 {
            return line("notice_long", [
                "You've been out a good few hours now.",
                "That's a fair walk you've done today.",
            ])
        }
        if spotsToday >= 5 {
            return line("notice_spots", ["You've found a few keepers today."])
        }
        return nil
    }

    static func stumble() -> String {
        line("stumble", ["Didn't catch that.", "Sorry - say that again?", "Missed that one."])
    }
}

// MARK: - TIER 3 — Flash intent
//
// COST NOTE, because this is the tier that spends money. The local recogniser
// has ALREADY produced the text by the time this runs, so this is a text
// request, not an audio stream. Streaming audio to a live model costs roughly
// 100x more and adds a second of connection setup — which would defeat the
// whole point. One classification is a few hundred tokens: a fraction of a
// cent, and only for sentences Tiers 1 and 2 didn't already handle for free.
//
// It is also strictly optional. No key, no signal, a slow network, a malformed
// reply — every one of those returns nil and the caller carries on to the
// normal answer path. Nothing in the offline command set depends on it.
enum ChappyIntent {
    struct Result {
        let action: String
        let parameter: String?
        let mode: String?
    }

    /// The vocabulary the model is allowed to answer with. Kept deliberately
    /// small: a classifier with nine options is reliable, one with forty is a
    /// creative writing exercise.
    private static let systemPrompt = """
    You route spoken commands for a wearable assistant called Chappy. Reply with ONLY a JSON object, no prose, no markdown fences.
    {"action": "...", "parameter": "...", "mode": "..."}
    action must be exactly one of:
      navigate  - wants directions somewhere. parameter = the destination in plain words. mode = walk|drive|scooter if stated.
      translate - wants the interpreter. parameter = the language name if stated, else "".
      look      - wants the camera to look at something and answer. parameter = what to look for, else "".
      photo     - just take a picture.
      remember  - save this place. parameter = the name if given, else "".
      map       - show the map.
      watch     - continuous narration of what they see.
      live_ai   - wants a live conversation.
      stop      - stop talking or stop navigating.
      journal   - what have I done / where have I been today.
      ask       - a general question that is NOT a command. Use this when unsure.
    Rules: prefer "ask" when genuinely ambiguous. Never invent a destination that was not said. Strip filler words from parameter.
    """

    static func classify(_ text: String) async -> Result? {
        let key = APIKeyManager.shared.getGoogleAPIKey() ?? ""
        guard !key.isEmpty, text.count > 2,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=\(key)")
        else { return nil }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": text]]]],
            "generationConfig": [
                "temperature": 0,
                // AUDIT P0: 120 was not enough. Flash models reason before
                // answering and that reasoning is charged against this budget,
                // so the response was truncated before any JSON appeared and
                // classify() returned nil for EVERY utterance — Tier 3 was
                // dead on arrival AND cost 4s of dead air on every question.
                "maxOutputTokens": 800,
                "responseMimeType": "application/json",
            ],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Hard ceiling. A command router that makes the user wait is worse than
        // one that occasionally gives up — Tier 4 is right behind it.
        req.timeoutInterval = 4
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = json["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let raw = parts.first?["text"] as? String
        else {
            print("🧠 [Intent] no usable reply — falling through")
            return nil
        }

        // Models sometimes wrap JSON in fences despite being told not to.
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let action = obj["action"] as? String
        else {
            print("🧠 [Intent] unparseable: \(cleaned.prefix(80))")
            return nil
        }
        let param = (obj["parameter"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = (obj["mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(action: action.lowercased(),
                      parameter: (param?.isEmpty ?? true) ? nil : param,
                      mode: (mode?.isEmpty ?? true) ? nil : mode)
    }
}

final class ChappyEarcon {
    static let shared = ChappyEarcon()

    private var wakeURL: URL?
    private var doneURL: URL?
    private var failURL: URL?
    private var tapURL: URL?
    private var thinkURL: URL?
    private var stillURL: URL?
    private var askURL: URL?
    /// BUILD 126: the camera pair. A shutter is not a chime — every attempt to
    /// make one out of sine partials sounds like a doorbell. These are
    /// synthesised as filtered noise bursts instead.
    private var shutterURL: URL?
    private var camWakeURL: URL?
    private var thinkTimer: Timer?
    private var prepared = false

    private init() {}

    /// Render the three tones once. Safe to call repeatedly.
    func prepare() {
        guard !prepared else { return }
        prepared = true
        // Rising perfect fourth — "listening". A5 → D6.
        // BUILD 90: retuned an octave down with soft edges. The old set was
        // bright sines with a strong second harmonic — technically a "chime",
        // audibly a microwave. These are warmer and sit under the voice.
        // Rising perfect fifth, D5 → A5. Warm, welcoming, unmistakably "go
        // ahead". Long enough to ring, short enough not to delay you.
        wakeURL = render(name: "chappy-wake", notes: [(587.33, 0.34), (880.00, 0.52)], gain: 0.30)
        // Soft single note — "done", deliberately quieter than the wake tone.
        // One warm note, left to ring. Settled, finished, no fuss.
        doneURL = render(name: "chappy-done", notes: [(659.25, 0.55)], gain: 0.24)
        // Falling minor third — "didn't work".
        // Falling minor third, G4 → E4. Reads as "no" in every culture that
        // has ever built a doorbell, and it is impossible to mistake for the
        // wake tone even with the phone in a pocket.
        failURL = render(name: "chappy-fail", notes: [(392.00, 0.30), (329.63, 0.46)], gain: 0.26)
        // One short high note, quiet. A click, not a chime.
        // A click, not a chime — short ring, well under the voice.
        tapURL  = render(name: "chappy-tap",  notes: [(1046.50, 0.12)], gain: 0.16)

        // BUILD 110 — THE MISSING CUES.
        //
        // THINKING is the important one. Between your question and the answer
        // there was silence, and silence reads as broken — so you repeat
        // yourself, which makes it worse. One soft low note, repeated while a
        // call is in flight, stopping the instant speech starts. Deliberately
        // quiet and low: it has to be noticeable and completely ignorable at
        // the same time.
        thinkURL = render(name: "chappy-think", notes: [(220.00, 0.16)], gain: 0.10)
        // STILL LISTENING — the follow-up window is open, you can keep going
        // without saying the name again. Two very quiet taps, so it reads as
        // "go on" rather than as a new event.
        stillURL = render(name: "chappy-still", notes: [(523.25, 0.09), (523.25, 0.09)], gain: 0.09)
        // A QUESTION FOR YOU — rising and left UNRESOLVED. A suggestion is a
        // question and should sound like one; every other cue lands, this one
        // hangs. You will know it is waiting for an answer without being told.
        askURL  = render(name: "chappy-ask", notes: [(523.25, 0.22), (698.46, 0.60)], gain: 0.22)

        // BUILD 126 — THE CAMERA PAIR.
        //
        // Snap had no sound of its own. It borrowed the tap and the done tone,
        // which are the same two sounds Remember uses, so there was no way to
        // tell a photo from a saved pin — or from nothing happening at all.
        //
        // Every camera app ever made solves this the same way, and it is worth
        // saying why: the shutter sound is not decoration, it is PROOF. Apple
        // fires it at the instant of capture, not when you press, precisely so
        // that hearing it means the picture exists. Samsung does the same and
        // adds a white flash. GoPro and Insta360 — the closest thing to
        // glasses, because you often cannot see a screen — go further and use
        // TWO different sounds, one for "starting" and one for "written",
        // because their capture has a real delay in it.
        //
        // Chappy's capture has a delay of up to eight seconds while the glasses
        // camera wakes. So it gets the GoPro treatment: a soft double-tick when
        // the camera starts waking, and a real mechanical shutter clack only
        // when a frame genuinely lands. Hearing the clack means you have a
        // photo. Not hearing it means you don't.
        camWakeURL = renderShutter(name: "chappy-cam-wake",
                                   bursts: [(0.000, 0.014, 1500, 0.42),
                                            (0.075, 0.014, 1500, 0.34)],
                                   gain: 0.20)
        // Mirror up, then mirror down 48 ms later — the shape of an SLR, which
        // is the sound every phone on earth imitates because everyone already
        // knows what it means.
        shutterURL = renderShutter(name: "chappy-shutter",
                                   bursts: [(0.000, 0.016, 2600, 1.00),
                                            (0.048, 0.024, 1700, 0.72)],
                                   gain: 0.42)
    }

    /// The thinking pulse. Safe to call twice; safe to stop when not running.
    func startThinking() {
        guard thinkTimer == nil else { return }
        prepare()
        play(thinkURL)
        thinkTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Never talk over the voice — the moment Chappy speaks, the
            // waiting is over and the pulse has done its job.
            if TTSService.shared.isSpeaking { self.stopThinking(); return }
            self.play(self.thinkURL)
        }
    }

    func stopThinking() {
        thinkTimer?.invalidate()
        thinkTimer = nil
    }

    func stillListening() { play(stillURL) }
    /// Use ONLY when Chappy is asking something and expects an answer.
    func askingYou() { play(askURL) }

    func wake() { play(wakeURL) }
    func done() { play(doneURL) }
    func fail() { play(failURL) }
    /// The button click. Deliberately the shortest and quietest of the four —
    /// a tap is an acknowledgement, not an announcement. Its whole job is to
    /// close the loop when the screen gives you nothing: you pressed Remember,
    /// something happened, you did not have to look.
    func tap() { play(tapURL) }

    /// BUILD 126. The camera is waking — this can take seconds on the glasses.
    /// Says "started", never "done".
    func cameraWaking() { prepare(); play(camWakeURL) }
    /// BUILD 126. A frame has genuinely been captured. This is the proof
    /// sound: it fires at the moment of capture and at no other time, so
    /// hearing it always means a photo exists.
    func shutter() { prepare(); play(shutterURL) }

    /// BUILD 126: a shutter is broadband noise, not a tone — `render` above
    /// stacks harmonic partials and cannot make one. This builds each click as
    /// a burst of noise pushed through a simple resonant band-pass, which is
    /// physically what a mirror slapping a stop actually is.
    ///
    /// Each burst is (start seconds, length seconds, centre frequency Hz,
    /// relative loudness).
    private func renderShutter(name: String,
                               bursts: [(Double, Double, Double, Double)],
                               gain: Double) -> URL? {
        let sampleRate = 44100.0
        let total = (bursts.map { $0.0 + $0.1 }.max() ?? 0.1) + 0.03
        let count = Int(sampleRate * total)
        guard count > 0 else { return nil }

        // Deterministic noise. A fixed seed means the click is byte-identical
        // every launch, so it never sounds subtly different from itself.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func noise() -> Double {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(Int64(bitPattern: seed)) / Double(Int64.max)
        }

        var samples = [Double](repeating: 0, count: count)
        for (start, length, centre, level) in bursts {
            // Two-pole resonant band-pass, run over the burst only.
            let w = 2 * Double.pi * centre / sampleRate
            let q = 0.94                       // ring, but don't whistle
            let a1 = 2 * q * cos(w), a2 = -q * q
            var y1 = 0.0, y2 = 0.0
            let first = Int(start * sampleRate)
            let last = min(count - 1, Int((start + length) * sampleRate))
            guard first < last else { continue }
            for i in first...last {
                let local = Double(i - first) / sampleRate
                // Near-instant attack, sharp decay — a click, not a swell.
                let env = exp(-local / (length * 0.28)) * min(1.0, local / 0.0004)
                let x = noise() * env
                let y = x + a1 * y1 + a2 * y2
                y2 = y1; y1 = y
                samples[i] += y * level * 0.25
            }
        }

        var pcm: [Int16] = []
        pcm.reserveCapacity(count)
        for v in samples {
            let out = max(-1.0, min(1.0, v * gain))
            pcm.append(Int16(out * 32767))
        }

        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); le32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate) * 2); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(byteCount)
        pcm.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }

        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("\(name).wav")
        do { try data.write(to: url, options: .atomic) } catch {
            print("⚠️ [Earcon] Could not write \(name): \(error.localizedDescription)")
            return nil
        }
        return url
    }

    /// THE REASON YOU HAVE NEVER HEARD A TONE.
    ///
    /// This used AudioServicesPlaySystemSound, and system sounds ALWAYS obey
    /// the physical Ring/Silent switch — no app can override that, whatever its
    /// audio session says. Your phone has been on silent in every screenshot
    /// you've sent me this week, so every wake tone, every click and every
    /// confirmation chime has been played into a muted output.
    ///
    /// AVAudioPlayer is different: it follows the audio SESSION CATEGORY, and
    /// Standby already runs `.playAndRecord`, which is explicitly not silenced
    /// by the ring switch. Same file, same moment, but you actually hear it.
    /// It also does not start an engine, so it still cannot disturb a live mic.
    private func play(_ url: URL?) {
        guard let url else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.volume = 1.0
            p.prepareToPlay()
            p.play()
            players.append(p)
            // Hold a reference until it finishes — an AVAudioPlayer that goes
            // out of scope stops mid-sound. Trimmed so this can't grow.
            if players.count > 6 { players.removeFirst(players.count - 6) }
        } catch {
            print("⚠️ [Earcon] Could not play: \(error.localizedDescription)")
        }
    }
    private var players: [AVAudioPlayer] = []

    /// Render a short sequence of sine notes to a 16-bit mono WAV and register
    /// it as a system sound. Each note gets a raised-cosine envelope — a bare
    /// sine switched on and off clicks, and a click is the one thing that makes
    /// a chime sound cheap.
    /// WHY THE OLD TONES SOUNDED CHEAP, AND WHAT ACTUALLY FIXES IT.
    ///
    /// The previous version was a sine wave faded in and out. That is the sound
    /// of a test signal, not an instrument, and no amount of retuning rescues
    /// it. Listening to how Meta, Apple, Google and Amazon build theirs, the
    /// same four properties show up every time — and none of them is the pitch:
    ///
    /// 1. FAST ATTACK, LONG DECAY. Struck objects — bells, chimes, keys — reach
    ///    full volume in about four milliseconds and then ring out. Fading IN
    ///    over 30% of the note, which is what the old code did, produces a
    ///    swell: a doorbell that sounds like a car reversing.
    ///
    /// 2. PARTIALS THAT DECAY AT DIFFERENT RATES. This is the big one. In a
    ///    real bell the high partials die away much faster than the fundamental,
    ///    so the sound starts bright and mellows as it rings. Hold every partial
    ///    at a constant level and the ear hears a synthesiser instantly.
    ///
    /// 3. SLIGHT INHARMONICITY. Perfect integer multiples sound like an organ.
    ///    Real bells have partials a little off — the 4.16 below is what gives
    ///    the faint metallic shimmer that reads as "expensive".
    ///
    /// 4. NOTES THAT OVERLAP. A two-note chime where the first note still rings
    ///    under the second is a musical gesture. Played end to end they are two
    ///    beeps. Meta's overlap; so do these.
    ///
    /// Rising interval for "listening", falling for "that failed" — that part is
    /// near-universal across every assistant and free to adopt.
    private func render(name: String, notes: [(Double, Double)], gain: Double = 0.30) -> URL? {
        let sampleRate = 44100.0
        // ratio to the fundamental · relative loudness · how fast it dies away
        let partials: [(Double, Double, Double)] = [
            (1.00, 1.00, 1.00),   // the note you hear
            (2.00, 0.42, 0.62),   // octave — body
            (3.01, 0.20, 0.42),   // twelfth — brightness at the strike
            (4.16, 0.11, 0.26),   // deliberately NOT 4.0 — the metallic shimmer
            (5.43, 0.05, 0.18),   // a whisper of air, gone almost at once
        ]
        // Notes overlap by a third of their length so the chime is one gesture.
        let overlap = 0.34
        var starts: [Double] = []
        var cursor = 0.0
        for (_, dur) in notes { starts.append(cursor); cursor += dur * (1 - overlap) }
        let total = (starts.last ?? 0) + (notes.last?.1 ?? 0.2)
        let count = Int(sampleRate * total)
        guard count > 0 else { return nil }

        var samples: [Int16] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            var v = 0.0
            for (n, note) in notes.enumerated() {
                let local = t - starts[n]
                guard local >= 0, local < note.1 else { continue }
                // 4 ms strike, then each partial rings out on its own clock.
                let attack = min(1.0, local / 0.004)
                for (ratio, amp, decayScale) in partials {
                    let tau = note.1 * 0.42 * decayScale
                    v += amp * exp(-local / tau) * sin(2 * .pi * note.0 * ratio * local) * attack
                }
            }
            // Normalised for the partial stack so `gain` still means loudness.
            let out = max(-1.0, min(1.0, v * gain * 0.55))
            samples.append(Int16(out * 32767))
        }
        guard !samples.isEmpty else { return nil }

        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); le32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate) * 2); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(byteCount)
        samples.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }

        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("\(name).wav")
        do { try data.write(to: url, options: .atomic) } catch {
            print("⚠️ [Earcon] Could not write \(name): \(error.localizedDescription)")
            return nil
        }
        return url
    }
}

// MARK: - Live AI Manager

@MainActor
class LiveAIManager: ObservableObject {
    static let shared = LiveAIManager()

    @Published var isRunning = false
    @Published var isConnected = false
    @Published var errorMessage: String?

    // Dependencies
    private(set) var streamViewModel: StreamSessionViewModel?
    private var omniService: OmniRealtimeService?
    private var geminiService: GeminiLiveService?
    private var provider: LiveAIProvider = .alibaba

    // Video frames
    private var currentVideoFrame: UIImage?
    private var isImageSendingEnabled = false
    private var frameUpdateTimer: Timer?
    // Counts 0.1s ticks; every 10th tick (~1 s) the frame is SENT to Gemini.
    // The old speech-triggered send relied on onSpeechStarted, which the
    // Gemini service never fires — Gemini was receiving zero images.
    private var frameTickCount = 0

    // Conversation history
    private var conversationHistory: [ConversationMessage] = []

    // TTS
    private let tts = TTSService.shared

    private init() {
        // AUDIT FIX (CRITICAL — double session): this manager USED to start
        // its own background Live AI session on .liveAITriggered, while the
        // home view ALSO presented LiveAIView which starts its own. One
        // command = two websockets, two microphones, two voices talking over
        // each other, and double billing. The screen now owns the session
        // exclusively; this manager only runs sessions started directly
        // (Siri background path calls startLiveAISession itself).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLiveAITrigger(_:)),
            name: .liveAIBackgroundStart,
            object: nil
        )
    }

    /// Set the StreamSessionViewModel reference
    func setStreamViewModel(_ viewModel: StreamSessionViewModel) {
        self.streamViewModel = viewModel
        // VOICE SHUTTER: "take a photo" in Live AI fires the glasses camera
        if !photoObserverInstalled {
            photoObserverInstalled = true
            NotificationCenter.default.addObserver(forName: .chappyCapturePhoto,
                                                   object: nil, queue: .main) { [weak self] _ in
                // AUDIT FIX (QV-C5): this is the ONLY path that saves to Photos.
                Task { @MainActor in self?.streamViewModel?.capturePhoto(saveToRoll: true) }
            }
        }
    }
    private var photoObserverInstalled = false

    @objc private func handleLiveAITrigger(_ notification: Notification) {
        Task { @MainActor in
            await startLiveAISession()
        }
    }

    // MARK: - Start Session

    /// Start a Live AI session (background mode)
    func startLiveAISession() async {
        guard !isRunning else {
            print("⚠️ [LiveAIManager] Already running")
            return
        }
        // BUILD 171 — AND NOT TWICE AT ONCE.
        //
        // isRunning is only set several lines below, after the mic handoff
        // and the key check. A second call arriving in that window — a
        // double tap, or the voice command landing at the same moment as
        // the tile — got past the guard and started a second session over
        // the top of the first. Two sessions, one set of glasses.
        guard !isStartingSession else {
            print("⚠️ [LiveAIManager] Start already in flight")
            return
        }
        isStartingSession = true
        defer { isStartingSession = false }
        // MIC HANDOFF: Standby's local ear must let go before the deep layer
        // takes the microphone — two recognizers cannot share one input node.
        if ChappyStandby.shared.isListening {
            // AUDIT FIX (LA-H9): handOff() so stopSession()'s
            // resumeAfterHandOff() actually re-arms the wake word.
            ChappyStandby.shared.handOff()
            // BUILD 165: 300ms was optimistic. Tearing down a recogniser and
            // releasing the input node is not instant, and starting the deep
            // layer while Standby still holds the node is a second way this
            // failed intermittently. Wait for the release, up to 2 seconds.
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if !ChappyStandby.shared.isListening { break }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        guard let streamViewModel = streamViewModel else {
            print("❌ [LiveAIManager] StreamViewModel not set")
            tts.speak("Live AI not initialized — open the app first")
            return
        }

        // Get the API key
        let apiKey = APIProviderManager.staticLiveAIAPIKey
        guard !apiKey.isEmpty else {
            errorMessage = "Please configure an API key in Settings first"
            tts.speak("Please configure an API key in Settings first")
            return
        }

        isRunning = true
        errorMessage = nil
        conversationHistory = []

        // Get the current provider
        provider = APIProviderManager.staticLiveAIProvider

        print("🚀 [LiveAIManager] Starting Live AI session...")

        do {
            // 1. Check whether a device is connected
            if !streamViewModel.hasActiveDevice {
                print("❌ [LiveAIManager] No active device connected")
                throw LiveAIError.noDevice
            }

            // 2. Start the video stream (if not already running)
            if streamViewModel.streamingStatus != .streaming {
                print("📹 [LiveAIManager] Starting stream...")
                await streamViewModel.handleStartStreaming()

                // BUILD 165 — FIVE SECONDS WAS THE WHOLE PROBLEM.
                // Cold Ray-Bans routinely take eight to ten seconds to hand
                // over a first frame; five meant Live AI only worked when
                // the glasses were already warm.
                //
                // BUILD 171 — BUT THE RETRY I ADDED WAS WORSE THAN THE BUG.
                //
                // It called handleStartStreaming() a SECOND time, and
                // startSession() begins by tearing down the existing
                // session ("sessions are single-use"). So the retry
                // demolished the very session it was waiting for, halfway
                // through its handshake with the glasses — which is a
                // crash, not a retry.
                //
                // Patience was the point, not re-triggering. One start, one
                // long wait, with a spoken nudge partway so you know it's
                // still working rather than dead.
                let nudge = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if streamViewModel.streamingStatus != .streaming {
                        tts.speak("Still waking the glasses.")
                    }
                }
                let streamReady = await waitForCondition(timeout: 22.0) {
                    streamViewModel.streamingStatus == .streaming
                }
                nudge.cancel()

                if !streamReady {
                    print("❌ [LiveAIManager] Failed to start streaming")
                    throw LiveAIError.streamNotReady
                }
            }

            // 3. Pre-configure audio session (needed for background mode)
            try configureAudioSessionForBackground()

            // 4. Initialize the AI service
            initializeService(apiKey: apiKey)

            // 4. Connect to the AI service
            print("🔌 [LiveAIManager] Connecting to AI service...")
            connectService()

            // Wait for connection (max 10 s)
            // BUILD 165: 10s is tight on a weak mobile signal — the exact
            // condition under which you most want it to keep trying.
            let connected = await waitForCondition(timeout: 16.0) {
                self.isConnected
            }

            if !connected {
                print("❌ [LiveAIManager] Failed to connect to AI service")
                throw LiveAIError.connectionFailed
            }

            // 5. Start the video-frame update timer
            startFrameUpdateTimer()
            print("✅ [LiveAIManager] Frame update timer started")

            // 6. Start recording directly (no TTS, avoids audio session conflicts)
            print("🎤 [LiveAIManager] About to start recording...")
            startRecording()

            // BUILD 172 AUDIT — SAY WHEN IT'S ACTUALLY READY.
            //
            // Every failure has spoken since 165, but SUCCESS was silent —
            // so a session that took eighteen seconds to come up was
            // indistinguishable from one that had quietly died, right up
            // until you spoke into it and something answered. With the
            // phone in a pocket you need the same courtesy for both
            // outcomes.
            ChappyEarcon.shared.wake()
            print("✅ [LiveAIManager] Live AI session started, ready to talk")

        } catch let error as LiveAIError {
            // BUILD 165 — "IT RANDOMLY WORKS."
            //
            // It wasn't random. Every failure path here set errorMessage,
            // printed to a console nobody is reading, and DIED IN SILENCE.
            // With the phone in a pocket, "Live AI failed because the glasses
            // took six seconds instead of five" and "Live AI ignored me" are
            // the same experience. So it worked whenever the hardware was
            // quick, and appeared broken whenever it wasn't.
            //
            // Now every failure says WHICH failure, out loud, in a sentence
            // that tells you what to do about it.
            errorMessage = error.localizedDescription
            print("❌ [LiveAIManager] LiveAIError: \(error)")
            ChappyEarcon.shared.fail()
            tts.speak(error.spokenAdvice)
            await stopSession()
            // BUILD 172 AUDIT — belt and braces, AFTER the cleanup.
            //
            // stopSession() opens with `guard isRunning else { return }`, so
            // clearing the flag before it would skip the teardown entirely.
            // But a flag left set is the worst failure mode there is: every
            // later attempt hits "Already running" and does nothing at all,
            // silently and permanently, curable only by force-quitting. So
            // it is forced down here, once the cleanup has definitely run.
            isRunning = false
        } catch {
            errorMessage = error.localizedDescription
            print("❌ [LiveAIManager] Error: \(error)")
            ChappyEarcon.shared.fail()
            tts.speak("Live AI couldn't start. \(error.localizedDescription)")
            await stopSession()
            isRunning = false        // BUILD 172 AUDIT — see above
        }
    }

    // MARK: - Audio Session Configuration

    /// Pre-configure the audio session (background mode requires it before the audio engine init)
    private func configureAudioSessionForBackground() throws {
        let audioSession = AVAudioSession.sharedInstance()

        // Deactivate then reactivate for a clean state
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            print("✅ [LiveAIManager] Audio session deactivated")
        } catch {
            print("⚠️ [LiveAIManager] Failed to deactivate audio session: \(error)")
        }

        // Configure the audio session
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
        try audioSession.setActive(true)
        print("✅ [LiveAIManager] Background audio session configured: category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")
    }

    // MARK: - Initialize Service

    private func initializeService(apiKey: String) {
        switch provider {
        case .alibaba:
            omniService = OmniRealtimeService(apiKey: apiKey)
            setupOmniCallbacks()
        case .google:
            geminiService = GeminiLiveService(apiKey: apiKey)
            setupGeminiCallbacks()
        }
    }

    private func setupOmniCallbacks() {
        guard let omniService = omniService else { return }

        omniService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
                print("✅ [LiveAIManager] Omni connected")
            }
        }

        omniService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                print("✅ [LiveAIManager] First-audio-sent callback received — enabling image sending")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.isImageSendingEnabled = true
                }
            }
        }

        omniService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                if let strongSelf = self,
                   strongSelf.isImageSendingEnabled,
                   let frame = strongSelf.currentVideoFrame {
                    print("🎤📸 [LiveAIManager] User speech detected — sending current video frame")
                    strongSelf.omniService?.sendImageAppend(frame)
                }
            }
        }

        omniService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self = self else { return }
                print("💬 [LiveAIManager] User: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        omniService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                guard let self = self, !fullText.isEmpty else { return }
                print("💬 [LiveAIManager] AI: \(fullText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: fullText)
                )
            }
        }

        omniService.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                print("❌ [LiveAIManager] Omni error: \(error)")
            }
        }
    }

    private func setupGeminiCallbacks() {
        guard let geminiService = geminiService else { return }

        geminiService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
                print("✅ [LiveAIManager] Gemini connected")
            }
        }

        geminiService.onReadRequest = { [weak self] in
            Task { @MainActor in
                guard let self, let frame = self.currentVideoFrame else { return }
                print("📖 [LiveAIManager] Read request — sending high-res frame")
                self.geminiService?.sendHighResImageInput(frame)
            }
        }

        geminiService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                print("✅ [LiveAIManager] First-audio-sent callback received — enabling image sending")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.isImageSendingEnabled = true
                }
            }
        }

        geminiService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                if let strongSelf = self,
                   strongSelf.isImageSendingEnabled,
                   let frame = strongSelf.currentVideoFrame {
                    print("🎤📸 [LiveAIManager] User speech detected — sending current video frame")
                    strongSelf.geminiService?.sendImageInput(frame)
                }
            }
        }

        geminiService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self = self else { return }
                print("💬 [LiveAIManager] User: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        geminiService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                guard let self = self, !fullText.isEmpty else { return }
                print("💬 [LiveAIManager] AI: \(fullText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: fullText)
                )
            }
        }

        geminiService.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                print("❌ [LiveAIManager] Gemini error: \(error)")
            }
        }
    }

    // MARK: - Connection

    private func connectService() {
        switch provider {
        case .alibaba:
            omniService?.connect()
        case .google:
            geminiService?.connect()
        }
    }

    private func startRecording() {
        print("🎤 [LiveAIManager] Start recording")
        switch provider {
        case .alibaba:
            omniService?.startRecording()
        case .google:
            geminiService?.startRecording()
        }
    }

    private func stopRecording() {
        print("🛑 [LiveAIManager] Stop recording")
        switch provider {
        case .alibaba:
            omniService?.stopRecording()
        case .google:
            geminiService?.stopRecording()
        }
    }

    // MARK: - Frame Update

    private func startFrameUpdateTimer() {
        frameUpdateTimer?.invalidate()
        frameUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateVideoFrame()
            }
        }
    }

    private func updateVideoFrame() {
        if let frame = streamViewModel?.currentVideoFrame {
            currentVideoFrame = frame

            // Steady 1 fps frame drip to Gemini so it can actually SEE
            frameTickCount += 1
            // SCOOTER MODE: ~3fps drip keeps the view fresh at a glance
            if frameTickCount >= 3 {
                frameTickCount = 0
                if provider == .google, isConnected {
                    geminiService?.sendImageInput(frame)
                }
            }
        }
    }

    // MARK: - Stop Session

    /// Stop the Live AI session
    func stopSession() async {
        guard isRunning else { return }

        print("🛑 [LiveAIManager] Stopping session...")
        // AUDIT FIX: the wake-word ear comes back on its own after the deep
        // layer closes — no digging the phone out to re-arm it.
        defer { ChappyStandby.shared.resumeAfterHandOff() }

        // Stop the timer
        frameUpdateTimer?.invalidate()
        frameUpdateTimer = nil

        // Stop recording
        stopRecording()

        // Save the conversation
        saveConversation()

        // Disconnect
        switch provider {
        case .alibaba:
            omniService?.disconnect()
        case .google:
            geminiService?.disconnect()
        }
        // AUDIT FIX (LA-H10): the live session the user actually starts lives
        // in LiveAIView, not in this manager — so "Hey Siri, stop live" closed
        // nothing at all. Reach the real socket through the shared instance.
        GeminiLiveService.activeInstance?.disconnect()

        // Stop the video stream
        await streamViewModel?.stopSession()

        // Reset state
        omniService = nil
        geminiService = nil
        isConnected = false
        isRunning = false
        isImageSendingEnabled = false
        currentVideoFrame = nil

        print("✅ [LiveAIManager] Session stopped")
    }

    /// Save the conversation to history
    private func saveConversation() {
        guard !conversationHistory.isEmpty else {
            print("💬 [LiveAIManager] No conversation content — skipping save")
            return
        }
        let fp = "\(conversationHistory.count)|\(conversationHistory.first?.content ?? "")|\(conversationHistory.last?.content ?? "")"
        guard ConversationSaveGate.shared.shouldSave(fingerprint: fp) else { return }

        let aiModel: String
        switch provider {
        case .alibaba:
            aiModel = "qwen3-omni-flash-realtime"
        case .google:
            aiModel = "gemini-3.1-flash-live-preview"
        }

        let record = ConversationRecord(
            messages: conversationHistory,
            aiModel: aiModel,
            language: "en-US"
        )

        ConversationStorage.shared.saveConversation(record)
        print("💾 [LiveAIManager] Conversation saved: \(conversationHistory.count)  messages")
    }

    /// Wait for the condition or time out
    private func waitForCondition(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return false }
        }
        return true
    }

    /// Manual stop trigger (called from UI)
    func triggerStop() {
        Task { @MainActor in
            await stopSession()
        }
    }
}

// MARK: - Live AI Error

enum LiveAIError: LocalizedError {
    case noDevice
    case streamNotReady
    case connectionFailed
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "Glasses not connected — pair them in the Meta AI app first"
        case .streamNotReady:
            return "Video stream failed to start — check the glasses connection"
        case .connectionFailed:
            return "AI AI service connection failed — check your network"
        case .noAPIKey:
            return "Please configure an API key in Settings first"
        }
    }

    /// BUILD 165 — what to SAY, which is not the same as what to log. Each
    /// one names the cause and the next action, because a failure you can't
    /// act on is just noise.
    var spokenAdvice: String {
        switch self {
        case .noDevice:
            return "I can't see the glasses. Check they're on and connected in the Meta AI app."
        case .streamNotReady:
            return "The glasses camera didn't wake up in time. Give it a few seconds and ask again."
        case .connectionFailed:
            return "Couldn't reach the AI service - that's usually signal. Try again when you've got bars."
        case .noAPIKey:
            return "No API key set. Settings, then API keys."
        }
    }
}

// MARK: - Context Engine (Phase 4 Step 1)
// Chappy's ambient awareness: WHERE the user is (street/city/country),
// WHEN it is, the weather, and how they're moving. One snapshot, available
// to every feature. Embedded here deliberately — no new .swift file means
// no Xcode project registration risk. Weather via Open-Meteo (free, no
// key, no WeatherKit entitlement needed).

// MARK: - CHAPPY STANDBY (Phase 4.97) — the wake word and the router
//
// The front door to everything. While the app is open (pocket fine, screen
// dark fine), a local on-device ear listens for the name "Chappy" — costing
// NOTHING while it waits, sending nothing anywhere. When the name lands, the
// rest of the sentence is routed by cost, cheapest first:
//
//   TIER 0  free phone actions      (photo, log, remember, map, status, modes)
//   TIER 1  one cheap call          (general questions, one-look, deal check)
//   TIER 2  live sessions           (talk, navigate, translate, watch)
//   TIER 3  the computer            (OpenClaw jobs, queued when PC is asleep)
//
// Laws: barge-in always · three-strike escape (never loop "didn't catch
// that" — offer Live AI instead) · one either/or when unsure · confirm money.
@MainActor
final class ChappyStandby: NSObject, ObservableObject {
    static let shared = ChappyStandby()

    @Published private(set) var isListening = false
    @Published private(set) var lastHeard = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// AUDIT P0 (SB-RESET): this was a `let`, so it could never be replaced.
    /// Apple's contract for a media-services reset is that every AVAudioEngine
    /// and node in the process is invalid and must be DISPOSED OF and recreated
    /// — restarting the same instance either throws from start() or gives you an
    /// engine that runs with no audio reaching the tap. The old code restarted
    /// this one, so a single reset meant the ear never came back for the rest of
    /// the day while the chip cheerfully read "Standby on".
    private var engine = AVAudioEngine()
    private var restartTimer: Timer?

    // Wake-word state
    /// BUILD 149: published so the avatar can visibly REACT while a command
    /// is being taken — the listening pulse. Rendering only; nothing reads
    /// it for logic outside this class.
    @Published private(set) var awake = false
    private var command = ""
    private var lastWordAt = Date()
    private var routeWork: DispatchWorkItem?
    private var strikes = 0
    private var busy = false
    private var coachCount = 0
    private var routeTask: Task<Void, Never>?
    private var starting = false
    private var wasListeningBeforeHandoff = false
    private var pendingAmbiguous: String?
    /// AUDIT P1 (SB-STICKY): the either/or question expires. Without this it
    /// latched forever and hijacked the next unrelated command.
    private var ambiguousAskedAt = Date.distantPast
    /// AUDIT FIX (SB-H1): interruption/route resilience state.
    private var resilienceInstalled = false
    private var interruptedWhileListening = false

    // MARK: Audit P0 state — reconfiguration loop, liveness, hand-off expiry

    /// AUDIT P0 (SB-LOOP): rebuildEar() reconfigures the audio session, which
    /// makes iOS post AVAudioEngineConfigurationChange to every engine in the
    /// process — including the one we just rebuilt. With no filter and no
    /// throttle that is a feedback loop. Translate was given exactly these two
    /// guards in build 64 after "a reconfiguration loop that took the app down
    /// after exactly one sentence"; Standby never got them.
    private var lastEarRebuild = Date.distantPast
    private var suppressConfigChangeUntil = Date.distantPast

    /// AUDIT P0 (SB-LIVENESS): `isListening` meant "we once armed", not "audio
    /// is flowing". Every non-deliberate death — interruption, stale tap, killed
    /// task — left it true, and autoArmIfWanted's `guard !isListening` then made
    /// the recovery hook a guaranteed no-op after exactly the events it exists
    /// for. Stamped by the input tap; a stale stamp means the ear is deaf no
    /// matter what the flag says.
    private var lastBufferAt = Date.distantPast
    /// BUILD 160: consecutive failed arming attempts, so a cold launch that
    /// loses the race with the audio session retries instead of going mute.
    private static var armAttempts = 0
    /// BUILD 160: the 2-second sweep that keeps the ear honest between renewals.
    private var livenessTimer: Timer?
    /// BUILD 171: when the sweep last rebuilt, so it can never storm.
    private var lastSweepRebuild = Date.distantPast
    /// BUILD 160: the most recent text heard AFTER the wake word. Empty means
    /// he said the name and nothing else — the only case that earns a beep.
    private var lastTail = ""

    /// AUDIT P0 (SB-LATCH): wasListeningBeforeHandoff was cleared in exactly one
    /// place — the first line of resumeAfterHandOff(). Any module that failed to
    /// call it turned the flag into a permanent latch that blocked auto-arm
    /// forever. Now it expires.
    private var handOffAt = Date.distantPast

    /// AUDIT P0 (SB-SELFTALK): while Chappy is speaking, the recogniser is still
    /// transcribing him through the speaker (.spokenAudio has no echo
    /// cancellation). Results delivered from before this stamp are discarded
    /// rather than scanned for the wake word.
    private var suppressTranscriptBefore = Date.distantPast
    private var wasSpeaking = false
    private var speechWatch: Timer?

    /// BUILD 103. On-device recognition writes his name down differently
    /// depending on how fast he says it and how far the phone is from his
    /// mouth, and a name it did not recognise is a command that silently
    /// never happened — which reads as "intermittent" rather than "deaf".
    ///
    /// Everything here begins "chap", "shap" or "tchap", so none of it can
    /// collide with an ordinary word. Deliberately NOT included: "happy" and
    /// "chatty", which would fire on normal conversation and make it worse.
    /// Names the recogniser has to get right or the command is wasted.
    /// Australian chains he uses now, and the SE Asian ones he is about to.
    static let brandHints: [String] = [
        "McDonald's", "Hungry Jack's", "Burger King", "KFC", "Red Rooster",
        "Subway", "Domino's", "Guzman y Gomez", "Zambrero", "Nando's",
        "IGA", "Woolworths", "Coles", "Aldi", "Bunnings", "Chemist Warehouse",
        "Officeworks", "BP", "Caltex", "Ampol", "7-Eleven",
        "Grab", "Gojek", "Indomaret", "Alfamart", "Circle K",
        "Ubud", "Canggu", "Seminyak", "Kuta", "Uluwatu", "Denpasar",
        "warung", "kebab", "kebabs", "nasi goreng", "mie goreng",
        "pharmacy", "chemist", "ATM", "petrol station", "supermarket",
    ]

    /// Bumped when the server recogniser errors. Two strikes and this session
    /// stays on-device — no retry storm, no silent deafness on a bad line.
    static var serverHearingFailures = 0

    private static let wakeWords = [
        "chappy", "chappie", "chapy", "chappy's", "chappi", "chapi",
        "chappey", "chappe", "chapper", "chappa", "chap he", "chap e",
        "shappy", "shappie", "tchappy", "chappys", "chaphy",
        // BUILD 135: what iOS actually hears an Australian say. "Chatty" is
        // the recogniser's favourite mishearing of the name.
        "chatty", "chattie", "chappé", "japi", "chubby",
    ]

    // MARK: Language intelligence (country-aware translation)

    /// AUDIT FIX (HIGH): every code here MUST exist in TranslateLanguage or
    /// the module silently degrades to English↔English while Chappy cheerfully
    /// announces "Translating English and Tagalog". Verified against the enum:
    /// en zh ja ko fr de ru es pt it yue id vi th ar hi el tr fil km lo.
    private static let supportedCodes: Set<String> = [
        "en", "zh", "ja", "ko", "fr", "de", "ru", "es", "pt", "it", "yue",
        "id", "vi", "th", "ar", "hi", "el", "tr", "fil", "km", "lo"
    ]
    /// Where you ARE decides the language — no menus, no picking.
    private static let countryLanguage: [String: String] = [
        "ID": "id", "TH": "th", "VN": "vi", "PH": "fil", "KH": "km", "LA": "lo",
        "MY": "id", "BN": "id",
        "SG": "zh", "CN": "zh", "TW": "zh", "HK": "yue", "MO": "yue", "JP": "ja",
        "KR": "ko", "IN": "hi", "NP": "hi", "TR": "tr", "FR": "fr", "IT": "it",
        "DE": "de", "AT": "de", "CH": "de", "RU": "ru", "GR": "el", "CY": "el",
        "AE": "ar", "EG": "ar", "MA": "ar", "SA": "ar", "JO": "ar",
        "QA": "ar", "KW": "ar", "OM": "ar", "BH": "ar", "TN": "ar", "LB": "ar",
        // BUILD 57 — PORTUGUESE-SPEAKING
        "PT": "pt", "BR": "pt", "AO": "pt", "MZ": "pt", "CV": "pt", "TL": "pt",
        // BUILD 57 — SPANISH-SPEAKING: all of South and Central America, plus
        // Mexico, the Caribbean and Spain. "Chappy, translate" now picks the
        // right language anywhere from Tijuana to Ushuaia.
        "ES": "es", "MX": "es", "AR": "es", "CL": "es", "CO": "es", "PE": "es",
        "UY": "es", "PY": "es", "BO": "es", "EC": "es", "VE": "es",
        "CR": "es", "PA": "es", "GT": "es", "HN": "es", "NI": "es", "SV": "es",
        "DO": "es", "CU": "es", "PR": "es", "GQ": "es"
    ]
    /// Spoken names → codes. Ordered lookup (dictionaries have no order, and
    /// random iteration made Chappy say "Bahasa" or "Indonesian" at random).
    private static let spokenLanguages: [(String, String)] = [
        ("indonesian", "id"), ("bahasa", "id"), ("thai", "th"), ("vietnamese", "vi"),
        ("filipino", "fil"), ("tagalog", "fil"), ("khmer", "km"), ("cambodian", "km"),
        ("lao", "lo"), ("mandarin", "zh"), ("chinese", "zh"), ("cantonese", "yue"),
        ("japanese", "ja"), ("korean", "ko"), ("hindi", "hi"), ("turkish", "tr"),
        ("french", "fr"), ("spanish", "es"), ("italian", "it"), ("german", "de"),
        ("portuguese", "pt"), ("russian", "ru"), ("greek", "el"), ("arabic", "ar"),
        // BUILD 57: how people actually ask for these two.
        ("brazilian", "pt"), ("brazil", "pt"), ("portugese", "pt"),
        ("castilian", "es"), ("mexican", "es"), ("argentinian", "es"),
        ("argentinean", "es"), ("colombian", "es"), ("peruvian", "es"),
        ("chilean", "es"), ("latin american", "es"), ("espanol", "es"),
        // BUILD 87: people name the COUNTRY, not the language. "Translate to
        // Indonesia" is the commonest way anyone actually says this, and it
        // matched nothing — so it fell through to the where-am-I fallback,
        // which in Australia yields English, which isn't a translation pair,
        // and Chappy answered "I don't have this country's language yet."
        // A correct-sounding refusal to a perfectly reasonable request.
        ("indonesia", "id"), ("indo", "id"), ("balinese", "id"), ("bali", "id"),
        ("thailand", "th"), ("vietnam", "vi"), ("viet", "vi"),
        ("philippines", "fil"), ("cambodia", "km"), ("laos", "lo"),
        ("japan", "ja"), ("nippon", "ja"), ("korea", "ko"), ("china", "zh"),
        ("taiwan", "zh"), ("hong kong", "yue"), ("india", "hi"),
        ("turkey", "tr"), ("france", "fr"), ("spain", "es"), ("italy", "it"),
        ("germany", "de"), ("portugal", "pt"), ("russia", "ru"),
        ("greece", "el"), ("dutch", "de"), ("nederlands", "de"),
        ("malaysia", "id"), ("malay", "id"), ("singapore", "zh")
    ]


    /// Where he IS — but only when that is genuinely a foreign language.
    /// English-to-English is not a translation, it is a mirror.
    static func localLanguageIfForeign() -> String? {
        guard let code = languageCode(forCountry: ContextEngine.shared.snapshot.countryCode),
              code != "en" else { return nil }
        return code
    }

    /// The last language he actually held a conversation in. On a trip this is
    /// almost always what he wants next, and it is what turns "open translate"
    /// into something that just starts.
    static func lastUsedTranslateLanguage() -> String? {
        guard let c = UserDefaults.standard.string(forKey: "translate_last_used_language"),
              !c.isEmpty, c != "en", supportedCodes.contains(c) else { return nil }
        return c
    }

    /// A language he can pin in Settings — useful before a trip, when he knows
    /// where he is going but is not there yet.
    static func usualTranslateLanguage() -> String? {
        guard let c = UserDefaults.standard.string(forKey: "translate_usual_language"),
              !c.isEmpty, c != "en", supportedCodes.contains(c) else { return nil }
        return c
    }

    static func languageCode(forCountry code: String?) -> String? {
        guard let code, let mapped = countryLanguage[code.uppercased()],
              supportedCodes.contains(mapped) else { return nil }
        return mapped
    }
    static func languageCode(spokenIn text: String) -> String? {
        guard let hit = spokenLanguages.first(where: { text.contains($0.0) }) else { return nil }
        return supportedCodes.contains(hit.1) ? hit.1 : nil
    }
    /// Map a spoken language NAME ("Thai", "German", "Brazilian Portuguese")
    /// to our code. Tier 3 returns words, not codes.
    static func languageCode(forName name: String) -> String? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        if let hit = spokenLanguages.first(where: { n.contains($0.0) })?.1 { return hit }
        let extras: [String: String] = [
            "mandarin": "zh", "cantonese": "yue", "bahasa": "id", "indonesian": "id",
            "tagalog": "fil", "filipino": "fil", "khmer": "km", "cambodian": "km",
            "lao": "lo", "brazilian": "pt", "portuguese": "pt", "castilian": "es",
            "spanish": "es", "greek": "el", "turkish": "tr", "arabic": "ar",
            "hindi": "hi", "japanese": "ja", "korean": "ko", "vietnamese": "vi",
            "thai": "th", "german": "de", "french": "fr", "italian": "it",
            "russian": "ru", "english": "en",
        ]
        return extras.first(where: { n.contains($0.key) })?.value
    }

    static func languageName(_ code: String) -> String {
        spokenLanguages.first(where: { $0.1 == code })?.0.capitalized ?? code.uppercased()
    }

    // MARK: Lifecycle

    func toggle() {
        // A tap is always a DELIBERATE act — it speaks, and it overrides any
        // pending silent auto-arm state left behind by an earlier attempt.
        silentArm = false
        if isListening {
            // A deliberate tap off means OFF — it must survive backgrounding,
            // or auto-arm would fight the user every time they pocket the phone.
            userTurnedOff = true
            stop()
        } else {
            userTurnedOff = false
            start()
        }
    }

    /// POCKET LAW: the Action Button opens Chappy and that must be the whole
    /// interaction — ear armed, wake word live, phone never leaves the pocket.
    /// Standby used to start closed on every cold launch, so the one gesture
    /// that exists to avoid touching the screen ended at a screen you had to
    /// touch. On by default; a deliberate tap-off is respected until relaunch.
    ///
    /// Read live from UserDefaults rather than @AppStorage: this is a plain
    /// class, not a View, so the property wrapper would never see a change the
    /// Settings screen made. Absent key means ON — a fresh install should be
    /// hands-free out of the box.
    private var autoArmEnabled: Bool {
        let d = UserDefaults.standard
        guard d.object(forKey: "chappy_standby_autoarm") != nil else { return true }
        return d.bool(forKey: "chappy_standby_autoarm")
    }
    /// Set when the user taps Standby OFF themselves. Auto-arm respects it for
    /// the life of the app run, then a fresh launch starts armed again.
    private var userTurnedOff = false

    /// Called on app launch and on every return to the foreground. Safe to call
    /// as often as you like — every failure mode exits quietly.
    func autoArmIfWanted(reason: String) {
        guard autoArmEnabled else { return }
        guard !userTurnedOff else { return }
        guard !starting else { return }
        // AUDIT P0 (SB-LIVENESS): `isListening` alone is not proof of life. If
        // it claims to be listening but the tap has gone quiet, the honest move
        // is to rebuild rather than to skip — the old `guard !isListening` was
        // precisely what made this hook useless after the failures it exists for.
        if isListening {
            // BUILD 160: was 10 seconds. A route change with glasses and a
            // pocketed phone happens constantly, and ten seconds of talking
            // to a dead mic is exactly what "I have to repeat myself" is.
            guard Date().timeIntervalSince(lastBufferAt) > 3.5 else { return }
            print("👂 [Standby] Chip says armed but the ear is deaf (\(reason)) — rebuilding")
            rebuildEar()
            return
        }
        // Never steal the mic from a session that is already using it.
        guard !LiveAIManager.shared.isRunning else { return }
        guard !ContinuousVisionManager.shared.isRunning else { return }
        // Translate is guarded at the CALL SITE (the home view only auto-arms
        // when no module is covering the screen) rather than by reaching into
        // LiveTranslateService — that file is on a rolled-back baseline and
        // must not be touched by this change.
        // A hand-off owns the ear's return — don't race resumeAfterHandOff().
        //
        // AUDIT P0 (SB-LATCH): this used to be an unconditional guard, and the
        // flag was cleared in exactly ONE place — the first line of
        // resumeAfterHandOff(). So any module that took the mic and failed to
        // hand it back turned this into a permanent latch, and auto-arm — the
        // supposed safety net — was blocked forever by the very failure it was
        // written to catch. Twenty seconds is far longer than any real hand-off
        // takes; past that, the module isn't coming back and we take the ear.
        if wasListeningBeforeHandoff {
            guard Date().timeIntervalSince(handOffAt) > 20 else { return }
            print("👂 [Standby] Hand-off never returned after 20s — reclaiming the ear")
            wasListeningBeforeHandoff = false
        }
        // Permissions must already be granted. Auto-arm must NEVER be the thing
        // that throws a permission dialog in the user's face at launch, and it
        // must never announce a failure he didn't ask for.
        // SIM FIX (COLD-START): on a genuinely fresh install both of these are
        // .notDetermined, and silently skipping meant the wake word simply
        // never worked until the user happened to tap Standby — the one screen
        // interaction this whole feature exists to avoid. Undetermined is not
        // "denied": ask once, at launch, while he is looking at the screen
        // anyway, then arm. Only a real DENIAL is left alone.
        let speechState = SFSpeechRecognizer.authorizationStatus()
        let micState = AVAudioSession.sharedInstance().recordPermission
        if speechState == .notDetermined || micState == .undetermined {
            print("👂 [Standby] First run — requesting permissions so the ear can arm")
            SFSpeechRecognizer.requestAuthorization { _ in
                AVAudioSession.sharedInstance().requestRecordPermission { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.autoArmIfWanted(reason: "permissions just granted")
                    }
                }
            }
            return
        }
        guard speechState == .authorized else {
            print("👂 [Standby] Auto-arm skipped (\(reason)) — speech permission denied")
            return
        }
        guard micState == .granted else {
            print("👂 [Standby] Auto-arm skipped (\(reason)) — mic permission denied")
            return
        }
        print("👂 [Standby] Auto-arming (\(reason))")
        silentArm = true
        start()
    }

    /// Suppresses the spoken greeting for an arm the user didn't ask for out
    /// loud. A haptic tick still confirms it, which is what you want when the
    /// phone is in your pocket and you're wearing the glasses.
    private var silentArm = false

    /// A failed arm the USER asked for is spoken. A failed auto-arm is silent —
    /// he never asked, so an unprompted "I need microphone access" from a
    /// pocketed phone is noise, not help.
    private func announceArmFailure(_ line: String) {
        if silentArm {
            silentArm = false
            print("👂 [Standby] Auto-arm declined: \(line)")
            return
        }
        TTSService.shared.speak(line)
    }

    func start() {
        // AUDIT FIX: isListening is only set at the END of beginSession, so a
        // double tap (or tap + Siri) used to build two recognizers, two
        // engines and two greetings.
        guard !isListening, !starting else { return }
        starting = true
        installUpheavalWatch()   // BUILD 142: tap installs wait out route changes
        // Never fight Live AI for the microphone — Live AI IS the deep layer.
        guard !LiveAIManager.shared.isRunning else {
            // AUDIT FIX (SB-C1): this returned without clearing `starting`, so
            // one tap while Live AI was running left the flag stuck true and
            // Standby could NEVER be started again for the life of the app.
            starting = false
            announceArmFailure("Live AI is already listening - no need for standby.")
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard status == .authorized else {
                    self?.starting = false
                    self?.announceArmFailure("I need speech permission for standby. Enable it in settings.")
                    return
                }
                // AUDIT FIX: mic permission was never requested — a denied mic
                // failed silently with the toggle just flipping back.
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self?.starting = false
                            self?.announceArmFailure("I need microphone access for standby.")
                            return
                        }
                        self?.beginSession()
                    }
                }
            }
        }
    }

    func stop() {
        restartTimer?.invalidate(); restartTimer = nil
        livenessTimer?.invalidate(); livenessTimer = nil
        speechWatch?.invalidate(); speechWatch = nil // AUDIT P0 (SB-SELFTALK)
        routeWork?.cancel(); routeWork = nil
        routeTask?.cancel(); routeTask = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        awake = false; command = ""; strikes = 0
        busy = false; starting = false // AUDIT FIX: a stuck busy flag made the ear permanently deaf
        isListening = false
        print("👂 [Standby] Ear closed")
    }

    /// AUDIT FIX (HIGH): every hand-off to a session used to close the ear
    /// forever — after one translate or one chat, the wake word was dead
    /// until the user dug the phone out and tapped the button. Now the ear
    /// remembers it was on and comes back by itself.
    func handOff() {
        wasListeningBeforeHandoff = isListening
        handOffAt = Date()
        stop()
    }
    func resumeAfterHandOff() {
        guard wasListeningBeforeHandoff, !isListening else { return }
        wasListeningBeforeHandoff = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !LiveAIManager.shared.isRunning else { return }
            self.start()
        }
    }

    private func beginSession() {
        // AUDIT FIX (SB-C1): both early exits below used to leave `starting`
        // true — a single low-battery tap deadlocked the wake word permanently.
        guard let recognizer, recognizer.isAvailable else {
            starting = false
            announceArmFailure("Standby isn't available on this phone right now.")
            return
        }
        // Battery guard — a local ear sips, but not below 20%.
        UIDevice.current.isBatteryMonitoringEnabled = true
        let lvl = UIDevice.current.batteryLevel
        if lvl >= 0 && lvl < 0.20 {
            starting = false
            announceArmFailure("You're low on battery, so I'll stay quiet and save what's left.")
            return
        }

        let session = AVAudioSession.sharedInstance()
        // ============ LEAVING "HEY META" ALONE ============
        // Bluetooth HFP is an EXCLUSIVE link: whoever claims the glasses'
        // microphone owns it, and nothing else can hear through it. `.allowBluetooth`
        // let Standby grab it — so simply having Chappy armed could stop
        // "Hey Meta" working, which is a lousy trade for a wake word that runs
        // perfectly well on the phone's own mic in your pocket.
        //
        // Standby now asks for the built-in mic and leaves the glasses free.
        // Translate and Live AI still take the glasses when you actually want
        // them to — those are deliberate, foreground acts. This one is ambient,
        // and ambient features should not quietly disable your other assistant.
        try? session.setCategory(.playAndRecord, mode: .spokenAudio,
                                 options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
        // Prefer the phone's own mic explicitly — A2DP alone still lets iOS
        // pick a headset input on some routes.
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }

        // BUILD 160 — THE SILENT FAILURE THAT ATE THE STARTUP VOICE.
        //
        // startRecognition() returns false whenever the audio session is
        // still settling — which on a cold launch is most of the time, since
        // arming fires 1.2s after the app appears. The old code just gave up
        // here: no ear, no greeting, no sound, no way to know. You'd talk to
        // a dead microphone and assume Chappy was ignoring you.
        //
        // Now it retries with backoff, three times, and only then admits
        // defeat out loud. Nothing about the success path changes.
        guard startRecognition() else {
            starting = false
            let attempt = Self.armAttempts
            Self.armAttempts += 1
            guard attempt < 3 else {
                Self.armAttempts = 0
                print("👂 [Standby] Arming failed three times — telling him")
                announceArmFailure("I couldn't open the microphone. Tap Ear On to try again.")
                return
            }
            let delay = 0.8 + Double(attempt) * 0.7      // 0.8s, 1.5s, 2.2s
            print("👂 [Standby] Arming failed (attempt \(attempt + 1)) — retrying in \(delay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isListening, !self.userTurnedOff else { return }
                self.silentArm = true
                self.start()
            }
            return
        }
        Self.armAttempts = 0
        isListening = true
        starting = false
        installAudioResilience()
        ChappyEarcon.shared.prepare() // render the tones before they're needed
        Self.validateCommandSets()   // AUDIT P0: catches prefix-unsafe entries
        ChappyHaptics.shared.connected()
        // THE ON-DUTY MOMENT. Opening the app — by the Action Button or by
        // tapping it — should feel like Chappy coming on shift: one short line
        // that also PROVES, out loud, that the microphone is live. Without it
        // you have no way to know the ear came up without pulling the phone out
        // and looking at a chip, which is exactly what this is meant to avoid.
        //
        // But it greets on COLD LAUNCH only. auto-arm also fires on every
        // return to the foreground, and something that talks every time you
        // flick back from Maps is something you turn off within a day.
        if silentArm {
            silentArm = false
            if !Self.greetedThisLaunch, wakeStyle != "silent" {
                Self.greetedThisLaunch = true
                ChappyEarcon.shared.wake()
                let firstOfDay = !Calendar.current.isDateInToday(lastGreetingAt)
                lastGreetingAt = Date()
                // BUILD 90: this was hitting the short-line fast path and
                // coming out in Apple's on-device voice — the "computery"
                // sound. The greeting is the one line worth a second of
                // latency: it is the first thing you hear each day and it sets
                // what Chappy sounds like.
                var greeting = ChappyVoice.launchGreeting(
                    name: userName, date: Date(), firstOfDay: firstOfDay)
                // A single observation, at most once a day, and only when there
                // is genuinely something a companion would mention.
                UIDevice.current.isBatteryMonitoringEnabled = true
                let pct = Int(max(UIDevice.current.batteryLevel, 0) * 100)
                let noticedToday = Calendar.current.isDateInToday(
                    Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "chappy_last_notice_at")))
                if !noticedToday,
                   let n = ChappyVoice.notice(
                       hour: Calendar.current.component(.hour, from: Date()),
                       walkedMinutes: TripRecorder.shared.crumbs.count,
                       batteryPercent: pct,
                       spotsToday: TripRecorder.shared.spots.filter {
                           Calendar.current.isDateInToday($0.t) }.count) {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "chappy_last_notice_at")
                    greeting += " " + n
                }
                TTSService.shared.speak(greeting, forceNetworkVoice: true)
            } else {
                print("👂 [Standby] Armed silently (already greeted this launch)")
            }
        } else {
            // A deliberate tap on the ear button.
            ChappyEarcon.shared.wake()
            TTSService.shared.speak("I'm listening.")
        }
        // Recognition tasks die after about a minute — quietly renew them.
        restartRenewTimer()
        startSpeechWatch()
        print("👂 [Standby] Ear open — waiting for the name")
    }

    private func renew() {
        guard isListening, !awake, !busy else { return } // never interrupt a command
        guard !interruptedWhileListening else { return } // a call owns the mic
        // AUDIT FIX (SB-H1): health check first. If iOS tore the engine down
        // while we weren't looking (a call, an alarm, media services resetting),
        // renewing the recognizer alone gives you a live ear with no audio going
        // into it — deaf, but the chip still says "Standby on".
        if !engine.isRunning {
            print("👂 [Standby] Engine died — rebuilding the whole ear")
            rebuildEar()
            return
        }
        // AUDIT P0 (SB-LIVENESS): the engine can be "running" with a stale tap
        // that hasn't delivered a buffer in minutes. That is the state the chip
        // was lying about. Buffers arrive continuously when the mic is live, so
        // 10 seconds of silence from the tap means dead, not quiet.
        if Date().timeIntervalSince(lastBufferAt) > 3.5 {   // BUILD 160: was 10
            print("👂 [Standby] No audio for \(Int(Date().timeIntervalSince(lastBufferAt)))s — ear is deaf, rebuilding")
            rebuildEar()
            return
        }
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        _ = startRecognition()
    }

    /// AUDIT FIX (SB-H1): full teardown and restart, keeping isListening true so
    /// the UI never flickers and the user never has to touch the phone.
    ///
    /// AUDIT P0 (SB-LOOP + SB-RESET + SB-RETRY): throttled, self-change
    /// suppressed, engine optionally replaced, and retried with backoff instead
    /// of disarming on the first stumble. One transient mic-format failure
    /// during a Bluetooth route change — which happens constantly with glasses
    /// and a pocketed phone — used to kill the ear for the rest of the session.
    /// BUILD 135: an on-demand liveness check for the moments most likely to
    /// kill the tap — right after camera work. If buffers have stopped, the
    /// ear rebuilds NOW instead of waiting out the 10-second watchdog.
    func pokeEar(after delay: TimeInterval = 1.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isListening else { return }
            if Date().timeIntervalSince(self.lastBufferAt) > 2.0 {
                print("👂 [Standby] Ear quiet after camera work — rebuilding now")
                self.rebuildEar()
            }
        }
    }

    /// - Parameters:
    ///   - freshEngine: replace the AVAudioEngine outright. Required after a
    ///     media-services reset, where the old instance is invalid by contract.
    ///   - attempt: retry counter; 0 is the first try.
    private func rebuildEar(freshEngine: Bool = false, attempt: Int = 0) {
        // Throttle: one rebuild per 2 seconds, no matter how many notifications
        // arrive. Retries are exempt — they are deliberately spaced already.
        if attempt == 0, Date().timeIntervalSince(lastEarRebuild) < 2.0 {
            print("👂 [Standby] Rebuild throttled")
            return
        }
        lastEarRebuild = Date()

        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)

        if freshEngine {
            // Every node on the old engine is invalid after a reset. Replace it,
            // and re-register the config-change observer on the NEW instance —
            // the old registration was scoped to an object that no longer exists.
            engine = AVAudioEngine()
            reinstallConfigChangeObserver()
            print("👂 [Standby] Engine replaced")
        }

        // Suppress the config-change notification our own setCategory/setActive
        // is about to cause, or we rebuild in response to our own rebuild.
        suppressConfigChangeUntil = Date().addingTimeInterval(1.5)
        let session = AVAudioSession.sharedInstance()
        // Re-applying an identical configuration is itself a route event and
        // buys nothing — only touch the session if it actually differs.
        if session.category != .playAndRecord || session.mode != .spokenAudio {
            try? session.setCategory(.playAndRecord, mode: .spokenAudio,
                                     options: [.duckOthers, .allowBluetooth, .defaultToSpeaker])
        }
        try? session.setActive(true)

        if startRecognition() { return }

        // Backoff: 0.6s, 1.5s, 3s. Three misses over ~5 seconds is a real
        // failure; one miss is just iOS still settling a route.
        let delays = [0.6, 1.5, 3.0]
        if attempt < delays.count {
            print("👂 [Standby] Rebuild attempt \(attempt + 1) failed — retrying in \(delays[attempt])s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
                guard let self, self.isListening else { return }
                self.rebuildEar(freshEngine: false, attempt: attempt + 1)
            }
            return
        }
        // Genuinely can't come back — say so rather than pretending.
        isListening = false
        TTSService.shared.speak("I've lost my hearing for a moment. Tap the ear and I'll be back.")
    }

    /// AUDIT FIX (SB-H1): Standby had NO interruption handling at all — Live AI
    /// next door has it, this didn't. One incoming call, one alarm, one Siri
    /// press and the wake word went silently deaf: the home screen still showed
    /// "Standby on", the ear was simply gone until the app was restarted. This
    /// is the difference between a wake word you can trust in your pocket all
    /// day and one you have to keep checking.
    private func installAudioResilience() {
        guard !resilienceInstalled else { return }
        resilienceInstalled = true
        let nc = NotificationCenter.default

        nc.addObserver(forName: AVAudioSession.interruptionNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            guard let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                switch type {
                case .began:
                    // A call or an alarm has the mic. Let go cleanly.
                    if self.isListening {
                        self.interruptedWhileListening = true
                        self.task?.cancel(); self.task = nil
                        self.request?.endAudio(); self.request = nil
                        if self.engine.isRunning { self.engine.stop() }
                        // AUDIT P0 (SB-CALLKILL): this timer used to keep
                        // running through the whole call. Within 50 seconds it
                        // fired renew(), saw a stopped engine, and called
                        // rebuildEar() WHILE the call still owned the session —
                        // setActive failed, the mic format read 0 Hz, and the
                        // ear disarmed itself. Then `.ended` guarded on
                        // isListening, which was now false, and never recovered.
                        // A phone call permanently killed the wake word.
                        self.restartTimer?.invalidate(); self.restartTimer = nil
                self.livenessTimer?.invalidate(); self.livenessTimer = nil
                        self.livenessTimer?.invalidate(); self.livenessTimer = nil
                        print("👂 [Standby] Interrupted — holding")
                    }
                case .ended:
                    // Drive recovery off the interruption flag, NOT isListening —
                    // a failed rebuild during the call could have cleared it.
                    guard self.interruptedWhileListening else { return }
                    self.interruptedWhileListening = false
                    // iOS needs a beat after the interruption clears.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        guard let self, !LiveAIManager.shared.isRunning else { return }
                        self.isListening = true // we are coming back; assert it
                        self.rebuildEar()
                        self.restartRenewTimer()
                    }
                @unknown default: break
                }
            }
        }

        // Media services resetting nukes every engine in the process.
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                print("👂 [Standby] Media services reset — rebuilding from scratch")
                // AUDIT P0 (SB-RESET): the old engine is invalid by Apple's
                // contract. Restarting it was never going to work.
                self.rebuildEar(freshEngine: true)
            }
        }

        // ==================================================================
        // THE BACKGROUND CRASH.
        //
        // This is almost certainly what has been killing the app when you
        // switch to Safari, and it is MY doing: it only started mattering when
        // auto-arm made Standby run on every launch. Before that the ear was
        // usually off, so there was no engine to get killed.
        //
        // iOS terminates an app that backgrounds while holding an ACTIVE
        // AVAudioSession with a RUNNING AVAudioEngine, unless the app declares
        // `audio` in UIBackgroundModes. Standby had no background handling of
        // any kind — it just kept the mic engine spinning as the app went away,
        // and the system shot it. That reads to the user as a random crash on
        // leaving the app, which is exactly what was reported.
        //
        // Two honest options, and we take whichever the Info.plist allows:
        //   • `audio` declared  -> keep listening in the background (the goal)
        //   • not declared      -> stand the ear DOWN cleanly on the way out
        //                          and bring it back on return. Costs
        //                          background listening; does not crash.
        // Checked at runtime so this file is correct either way, and so adding
        // the entitlement later needs no code change at all.
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                guard !Self.backgroundAudioAllowed else {
                    print("👂 [Standby] Backgrounded — staying live (audio background mode present)")
                    return
                }
                print("👂 [Standby] Backgrounded WITHOUT audio background mode — standing down to avoid termination")
                self.wasListeningBeforeBackground = true
                self.task?.cancel(); self.task = nil
                self.request?.endAudio(); self.request = nil
                if self.engine.isRunning { self.engine.stop() }
                self.engine.inputNode.removeTap(onBus: 0)
                self.restartTimer?.invalidate(); self.restartTimer = nil
                self.livenessTimer?.invalidate(); self.livenessTimer = nil
                self.speechWatch?.invalidate(); self.speechWatch = nil
                try? AVAudioSession.sharedInstance()
                    .setActive(false, options: .notifyOthersOnDeactivation)
                self.isListening = false
                // THE SILENT FAILURE. The chip said "Standby on", the ear was
                // dead, and there was no way to know until a command went
                // unanswered. This is the single highest-value notification in
                // the app, because it is the one that has actually cost days.
                ChappyNotify.post(.system,
                    title: "Chappy stopped listening",
                    body: "The wake word needs the app open. Add the audio background mode to keep it live in your pocket.",
                    critical: false, force: true)
            }
        }

        nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wasListeningBeforeBackground else { return }
                self.wasListeningBeforeBackground = false
                // A beat for iOS to hand the session back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, !self.isListening else { return }
                    self.silentArm = true // no greeting on every return
                    self.start()
                }
            }
        }

        reinstallConfigChangeObserver()
    }

    /// True when Info.plist declares the `audio` background mode. Without it,
    /// a running mic engine is a termination sentence the moment the app leaves
    /// the screen — so we have to let go instead.
    static let backgroundAudioAllowed: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        let ok = modes.contains("audio")
        print("👂 [Standby] Background audio mode: \(ok ? "PRESENT — can listen while away" : "ABSENT — will stand down when backgrounded")")
        return ok
    }()

    private var wasListeningBeforeBackground = false

    /// A plain-English answer to "why can't I hear anything / why won't it
    /// listen". Every line is read live from the system, not from our own
    /// flags — the whole problem with this layer has been code that believed
    /// its own bookkeeping. Shown in Settings → Voice check.
    static func diagnostics() -> [(String, String, Bool)] {
        let s = AVAudioSession.sharedInstance()
        let st = ChappyStandby.shared
        var out: [(String, String, Bool)] = []

        let speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        out.append(("Speech permission", speech ? "granted" : "NOT GRANTED", speech))
        let mic = s.recordPermission == .granted
        out.append(("Microphone permission", mic ? "granted" : "NOT GRANTED", mic))

        out.append(("Wake word armed", st.isListening ? "yes" : "no", st.isListening))
        let flowing = st.isListening && Date().timeIntervalSince(st.lastBufferAtPublic) < 10
        out.append(("Audio actually arriving", flowing ? "yes" : "NO — ear is deaf", flowing))

        // THE ONE THAT CAUGHT US OUT. System sounds always obey the physical
        // Ring/Silent switch, no matter what the audio session says. With the
        // switch flicked to silent you get no wake tone, no click, no chime —
        // and the only reasonable conclusion is that the app is broken.
        out.append(("Ring/Silent switch", "check the side of the phone — tones are silenced when set to silent", true))

        out.append(("Speaker output", s.currentRoute.outputs.first?.portName ?? "none", !s.currentRoute.outputs.isEmpty))
        out.append(("Microphone input", s.currentRoute.inputs.first?.portName ?? "none", !s.currentRoute.inputs.isEmpty))

        out.append(("Listen while backgrounded",
                    backgroundAudioAllowed ? "yes" : "no — ear stands down when you leave the app",
                    backgroundAudioAllowed))

        UIDevice.current.isBatteryMonitoringEnabled = true
        let lvl = UIDevice.current.batteryLevel
        let batteryOK = lvl < 0 || lvl >= 0.20
        out.append(("Battery", lvl < 0 ? "unknown" : "\(Int(lvl * 100))%\(batteryOK ? "" : " — under 20%, ear won't arm")", batteryOK))

        let key = !(APIKeyManager.shared.getGoogleAPIKey() ?? "").isEmpty
        out.append(("Voice (Gemini key)", key ? "set" : "missing — falls back to the system voice", true))
        return out
    }

    /// Read-only view of the input heartbeat, for diagnostics.
    var lastBufferAtPublic: Date { lastBufferAt }

    /// AUDIT P0 (SB-LOOP): scoped to the CURRENT engine instance, so it has to be
    /// re-registered whenever the engine is replaced. Also filters out the
    /// BUILD 142: the moment the audio world last MOVED — any route change,
    /// any engine reconfiguration, anywhere in the process. Tap installs
    /// check this and refuse to run until the dust settles, because
    /// installing into moving hardware is the uncatchable crash in the .ips.
    nonisolated(unsafe) static var lastAudioUpheavalAt = Date.distantPast
    private static var upheavalWatchInstalled = false

    private func installUpheavalWatch() {
        guard !Self.upheavalWatchInstalled else { return }
        Self.upheavalWatchInstalled = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                       object: nil, queue: nil) { _ in
            ChappyStandby.lastAudioUpheavalAt = Date()
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                       object: nil, queue: nil) { _ in
            ChappyStandby.lastAudioUpheavalAt = Date()
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                       object: nil, queue: nil) { _ in
            ChappyStandby.lastAudioUpheavalAt = Date()
        }
    }

    /// changes we caused ourselves — without that, every rebuild triggers the
    /// next one, and every TTS playback engine start re-enters here too.
    private func reinstallConfigChangeObserver() {
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening, !self.awake, !self.busy else { return }
                guard Date() >= self.suppressConfigChangeUntil else {
                    print("👂 [Standby] Ignoring our own graph change")
                    return
                }
                print("👂 [Standby] Audio graph changed — rebuilding")
                self.rebuildEar()
            }
        }
    }

    /// AUDIT P0 (SB-SELFTALK): the single worst bug in the layer. The mic tap
    /// stays live while Chappy speaks, and `.spokenAudio` has no echo
    /// cancellation (unlike the `.voiceChat` mode Translate deliberately uses),
    /// so the recogniser reliably transcribes what comes out of the speaker.
    /// heard() only SUPPRESSED ROUTING while isSpeaking was true — it never
    /// flushed the transcript. SFSpeechRecognizer keeps one cumulative
    /// transcript per task, so the moment the gate lifted, the next result
    /// arrived carrying Chappy's own sentence and the wake-word scan found
    /// "chappy" inside it. His own escape line — "Say: Chappy let's talk" —
    /// therefore opened a metered Live AI session entirely by itself.
    ///
    /// The fix is to flush the ear when the VOICE stops, not when the command
    /// routes, and to discard anything delivered from before that moment.
    private func startSpeechWatch() {
        speechWatch?.invalidate()
        wasSpeaking = TTSService.shared.isSpeaking
        speechWatch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                let now = TTSService.shared.isSpeaking
                defer { self.wasSpeaking = now }
                guard self.wasSpeaking, !now else { return }
                // Voice just stopped. Give the speaker's decay a moment, then
                // throw away everything the recogniser heard during the answer.
                self.suppressTranscriptBefore = Date().addingTimeInterval(0.3)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.isListening, !self.awake, !self.busy else { return }
                    // BUILD 119 — WHY YOU HAVE TO SAY IT TWICE.
                    //
                    // This tore down and rebuilt the whole recogniser after
                    // EVERY answer Chappy gave. Rebuilding means removing the
                    // tap, installing a new one and starting a new task — and
                    // for those few hundred milliseconds the ear is DEAF. The
                    // moment you are most likely to speak is the moment right
                    // after Chappy stops, so your reply landed in the gap and
                    // vanished. Then you said it again and it worked, which is
                    // exactly the behaviour you described.
                    //
                    // The suppress window above already throws away anything
                    // heard while Chappy was talking. The rebuild was only ever
                    // belt-and-braces for an actual echo — so now it only
                    // happens when there IS one: the transcript still carrying
                    // Chappy's own words back. Otherwise the ear stays up and
                    // hears your reply the first time.
                    let spoken = TTSService.shared.lastSpokenLine
                        .lowercased().split(separator: " ").filter { $0.count > 3 }
                    let heard = self.lastHeard.lowercased()
                    let echoing = spoken.count >= 2
                        && spoken.prefix(6).filter { heard.contains($0) }.count >= 2
                    if echoing {
                        print("🧹 [Standby] Echo detected — flushing the ear")
                        self.resetRecognition()
                    }
                }
            }
        }
    }

    // MARK: The wake acknowledgement

    /// How Chappy answers his name. See the design note on ChappyEarcon.
    /// - "tone"     tone every wake, greeting only after a long gap (default)
    /// - "greeting" tone every wake, greeting every wake (JARVIS, full fat)
    /// - "silent"   haptic only — for temples, cinemas, night buses
    private var wakeStyle: String {
        UserDefaults.standard.string(forKey: "chappy_wake_style") ?? "tone"
    }
    private var lastGreetingAt: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "chappy_last_greeting_at")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "chappy_last_greeting_at") }
    }
    /// Greet once per app launch, not once per foreground.
    private static var greetedThisLaunch = false
    /// What he'd like to be called. Blank is fine — the lines read without it.
    private var userName: String {
        // Seeded rather than blank — a greeting with no name in it is the
        // thing he asked me to fix, and an empty Settings field he has to find
        // first is not an answer. Changeable in Settings → Voice → Call me.
        (UserDefaults.standard.string(forKey: "chappy_user_name") ?? "Shaun")
            .trimmingCharacters(in: .whitespaces)
    }

    // BUILD 110 — THE GREETING THAT KNOWS SOMETHING.
    //
    // "Good morning sir" is a butler. "Morning. Four jobs, first at half nine,
    // and it's raining in Caboolture" is the thing you actually asked for.
    // The difference is not the voice — it is that one of them TELLS YOU
    // SOMETHING and the other performs politeness at you.
    //
    // Three rules, all of them about restraint:
    //   1. ONE LINE. The personality lives in the line, not in a ritual.
    //   2. NEVER THE SAME WORDS TWICE. Repetition is the biggest robot tell
    //      there is, and the cheapest thing in here to fix.
    //   3. SHUT UP SOMETIMES. Open the app twice in five minutes and the
    //      second one gets a tone and nothing else. Restraint reads as
    //      confidence; being greeted every time reads as a machine.
    //
    // It costs nothing in speed: everything it says is already in memory, and
    // a short line goes through the on-device voice, which starts instantly.
    // The slow voice is only ever used for long answers.

    private static let greetOpeners: [String] = [
        "Morning", "Morning to you", "Right, morning", "Good morning"
    ]
    private static let dayOpeners: [String] = [
        "Afternoon", "Right then", "Afternoon to you", "Back with you"
    ]
    private static let eveOpeners: [String] = [
        "Evening", "Evening to you", "Right, evening"
    ]
    private static let lateOpeners: [String] = [
        "You're up late", "Still going", "Late one"
    ]

    /// Spoken once when the app opens, if enough time has passed. Never blocks
    /// anything — the app is fully usable while it talks.
    func launchGreeting() {
        guard wakeStyle != "silent" else { return }
        // BUILD 117 — WHY YOU NEVER HEARD IT.
        //
        // Two mistakes, both mine.
        //
        // ONE: it shared `lastGreetingAt` with the WAKE-WORD greeting. Say
        // "Chappy" once and the launch greeting went silent for the next
        // fifteen minutes — and you say "Chappy" constantly, so it was
        // permanently suppressed by its own sibling. Its own clock now.
        //
        // TWO: fifteen minutes is far too long while testing, and the whole
        // point is the FIRST open. It now always speaks on a cold launch,
        // and after that respects a five-minute gap on foregrounding.
        let key = "chappy_launch_greeting_at"
        let last = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: key))
        // BUILD 132 — THE "RANDOM HELLO", FOUND.
        //
        // The old rule respawned the greeting on any foregrounding more than
        // five minutes after the last one. Come back from Google Maps, unlock
        // the phone, close a sheet — if five quiet minutes had passed, Chappy
        // piped up out of nowhere. It wasn't random; it was a timer nobody
        // could see, which is worse.
        //
        // New rule: ONE greeting per app launch, plus one more if the day has
        // rolled over since the last greeting (the phone that stays open all
        // week still deserves its good morning). Nothing else speaks unasked.
        if Self.greetedThisLaunch, Calendar.current.isDateInToday(last) { return }
        Self.greetedThisLaunch = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)

        let h = Calendar.current.component(.hour, from: Date())
        let pool: [String]
        switch h {
        case 5..<12:  pool = Self.greetOpeners
        case 12..<17: pool = Self.dayOpeners
        case 17..<23: pool = Self.eveOpeners
        default:      pool = Self.lateOpeners
        }
        // Rotated rather than random, so the same line never lands twice in a
        // row even by chance.
        let idx = UserDefaults.standard.integer(forKey: "chappy_greet_idx")
        UserDefaults.standard.set(idx + 1, forKey: "chappy_greet_idx")
        var line = pool[idx % pool.count]
        if !userName.isEmpty { line += " \(userName)." } else { line += "." }

        // THE USEFUL HALF. BUILD 133: up to TWO facts now — overdue first,
        // then the next thing in the diary — clipped, in priority order, and
        // nothing at all if the day is genuinely empty. With barge-in live,
        // a long brief costs nothing: say "Chappy" and it stops mid-word.
        let facts = Self.greetingFacts(max: 2)
        if !facts.isEmpty { line += " " + facts.joined(separator: " ") }

        ChappyEarcon.shared.wake()
        TTSService.shared.speak(line)
        // BUILD 135 — TALK BACK LIKE A PERSON. The greeting is an opening,
        // so the door it opens stays open: for a good stretch after it,
        // anything you say routes with NO wake word — "find the closest
        // hardware store" straight after "Good morning" just works, the way
        // Meta's do it. The window is generous because the ear is deaf while
        // the greeting itself is being spoken.
        followUpOpenedAt = Date()
        followUpUntil = Date().addingTimeInterval(25)
    }

    /// The one thing worth leading with. Ordered by how much it matters.
    /// BUILD 133: the launch brief, up to `max` short facts in priority order.
    /// Clear and precise on purpose — each fact is one clipped sentence, and
    /// an empty day is still allowed to be quiet.
    static func greetingFacts(max: Int = 2) -> [String] {
        let df = DateFormatter(); df.dateFormat = "h:mm"
        var facts: [String] = []

        // Overdue beats everything.
        let od = ChappyReminders.shared.overdue()
        if od.count == 1 { facts.append("\(od[0].title) is overdue.") }
        else if od.count > 1 { facts.append("\(od.count) things overdue.") }

        // Then what's next in the diary, because that is what you can act on.
        if let e = ChappyCalendar.shared.next(), let start = e.startDate,
           Calendar.current.isDateInToday(start) {
            let jobs = ChappyCalendar.shared.today().filter { !$0.isAllDay }.count
            if jobs > 1 {
                facts.append("\(jobs) on today, first at \(df.string(from: start)).")
            } else {
                facts.append("\(e.title ?? "Something") at \(df.string(from: start)).")
            }
        }

        // Then reminders due today.
        let t = ChappyReminders.shared.today().filter { $0.deliveredAt == nil }
        if t.count == 1 { facts.append("One thing on: \(t[0].title).") }
        else if t.count > 1 { facts.append("\(t.count) things on today.") }

        // Then the visa, if it is close enough to matter.
        if let v = ChappyReminders.shared.visaLine() { facts.append(v) }

        return Array(facts.prefix(max))
    }

    static func greetingFact() -> String? { greetingFacts(max: 1).first }

    /// Answer the wake word. Tone first and always — it has to land inside
    /// ~200 ms or the user talks over it — then decide about words.
    ///
    /// - Parameter tail: whatever was said AFTER the name in the same breath.
    ///   "Chappy, navigate to the ATM" must never be answered with "Good
    ///   morning" — he already told us what he wants and a greeting would just
    ///   delay it. The greeting is only for a bare "Chappy" said on its own.
    private func acknowledgeWake(tail: String) {
        ChappyHaptics.shared.connected()
        guard wakeStyle != "silent" else { return }

        // BUILD 118 — DON'T DING OVER HIM.
        //
        // The tone fired the instant the name was recognised. Say "Chappy,
        // open the map" in one breath and the ding lands in the middle of your
        // own sentence — it talks over you, and it comes back through the mic
        // on top of the words you are still saying.
        //
        // Every good assistant handles this the same way: acknowledge with a
        // SOUND only when you have stopped, and with a light or a screen when
        // you have not. So the tone now waits a third of a second. If more
        // speech arrives in that window you were mid-sentence, and it stays
        // silent and simply listens — the haptic above has already told you it
        // heard the name.
        // BUILD 160 — ONE BEEP, AND ONLY WHEN IT SAYS SOMETHING.
        //
        // The tone used to fire 0.33 seconds after the NAME, whether or not a
        // command was still coming. So "Chappy, what's on today" got a beep
        // dropped into the middle of the sentence, every single time. That is
        // the beeping.
        //
        // The rule now: the tone only exists to answer "did you hear me?" —
        // which is a question you only have when you said the name and
        // nothing else. If a command follows, the ANSWER is the
        // acknowledgement and a beep is noise. Wait long enough to know which
        // situation this is, then beep only for the bare one.
        lastTail = tail
        let bare = tail.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-")).isEmpty
        if bare {
            let mark = Date()
            pendingWakeToneAt = mark
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                guard let self, self.pendingWakeToneAt == mark else { return }
                // A command arrived in the meantime — no beep, the reply covers it.
                guard self.lastTail.trimmingCharacters(
                    in: CharacterSet(charactersIn: " ,.:;!?-")).isEmpty else { return }
                // Still mid-word? An acknowledgement would be an interruption.
                guard Date().timeIntervalSince(self.lastHeardAt) > 0.35 else { return }
                ChappyEarcon.shared.wake()
            }
        } else {
            // A command came with the name — cancel any pending tone.
            pendingWakeToneAt = Date()
        }
        guard bare else { return }

        let now = Date()
        // A greeting is welcome when Chappy is coming ON DUTY — first wake of
        // the morning, or after hours of silence. Said on every wake it stops
        // being warmth and becomes latency.
        let longGap = now.timeIntervalSince(lastGreetingAt) > 4 * 3600
        guard wakeStyle == "greeting" || longGap else { return }
        lastGreetingAt = now

        // Deliberately ONE short clause, and rotated so it never sounds canned.
        // The JARVIS effect comes from being brief and unhurried, not from a
        // paragraph of hospitality.
        TTSService.shared.speak("\(ChappyVoice.timeOfDay(now))\(userName.isEmpty ? "" : ", \(userName)").")
    }


    // ==================================================================
    // SNAP — the silent one.
    //
    // Snap and Look used to do the IDENTICAL thing: both opened Quick Vision,
    // took one photo and spoke one answer. Two buttons, same behaviour. So Snap
    // had no job of its own, which is the gap this fills:
    //
    //   SNAP   photo, described quietly, stored. Says nothing.
    //   LOOK   photo, answer spoken aloud. "What is this?"
    //   WATCH  continuous narration.
    //
    // Three modes, no overlap. Snap is a visual journal — you take it because
    // you want it later, not because you want to be told about it now.
    func snapSilently() {
        guard let vm = LiveAIManager.shared.streamViewModel,
              let frame = vm.currentVideoFrame else {
            // BUILD 126: the camera is asleep and will take seconds to wake.
            // Say so — with a sound that means "starting", never "done", and
            // with something on screen so the wait is visibly a wait rather
            // than a silence you have to interpret.
            ChappyEarcon.shared.cameraWaking()
            SnapFeedback.shared.waking()
            NotificationCenter.default.post(name: .chappyWakeCameraForSnap, object: nil)
            // BUILD 135: the camera coming up is exactly when the mic tap
            // gets torn down. Check the ear once the wake settles.
            pokeEar(after: 4.0)
            return
        }
        // The camera is already awake — this is instant, so the shutter is the
        // only sound needed. completeSilentSnap fires it.
        completeSilentSnap(frame)
    }

    func completeSilentSnap(_ frame: UIImage) {
        // BUILD 126 — PROOF, NOT SILENCE.
        //
        // Everything below this line used to be invisible. A haptic, a soft
        // tone identical to the one Remember plays, and a thumbnail filed into
        // a list you would have to go looking for. There was no way to tell a
        // photo from a failure from nothing at all — which is exactly what it
        // felt like from the outside.
        //
        // Three signals now, in the order every camera on earth uses them:
        // the shutter fires at the instant of capture (so hearing it is proof
        // the picture exists), the screen flashes, and the photo itself slides
        // in, holds, and leaves.
        ChappyHaptics.shared.shutter()
        ChappyEarcon.shared.shutter()
        SnapFeedback.shared.captured(frame)

        // BUILD 135 — THE EAR THAT DIED WITH THE SHUTTER. Waking the glasses
        // camera reroutes audio, and the mic tap can go down with it. The
        // liveness watchdog catches this eventually (10s), but "eventually"
        // reads as deaf. Check the ear the moment the photo is taken, and
        // again after the camera goes back to sleep.
        pokeEar(after: 1.5)
        pokeEar(after: 5.0)

        let thumb = frame.jpegData(compressionQuality: 0.4)

        // Store it immediately with a placeholder — the photo must never be lost
        // waiting on a network call that might not come back.
        let note = TripRecorder.shared.addVisualNote(caption: "Photo", thumbnail: thumb)

        // BUILD 126: and into the memory store, which is where you actually go
        // looking. It was only ever landing in visual notes, so a snapped photo
        // was invisible to search, to Dreaming and to the AI.
        let entry = ChappyMemory.shared.remember(.photo,
                                                 title: "Photo",
                                                 tags: ["snap"],
                                                 thumbnail: thumb,
                                                 source: "snap")

        // BUILD 126: and into the camera roll, so it is backed up to iCloud and
        // findable in the app you already use. Add-only permission — Chappy
        // never gets read access to your library from this path.
        Self.saveToCameraRoll(frame)

        Task { @MainActor in
            if let caption = await Self.describe(frame) {
                TripRecorder.shared.updateCaption(id: note.id, to: caption)
                ChappyMemory.shared.setTitle(id: entry.id, caption)
                // If the card is still on screen, let him read what it is.
                SnapFeedback.shared.setCaption(caption)
            }
        }
    }

    /// BUILD 126. Add-only, so the wearer is never asked for full library
    /// access just to keep a photo he took himself.
    nonisolated private static func saveToCameraRoll(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                print("📷 [Snap] No add-only photo permission — kept in Chappy only")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { ok, err in
                if ok { print("📷 [Snap] Saved to camera roll") }
                else { print("📷 [Snap] Camera roll save failed: \(err?.localizedDescription ?? "unknown")") }
            }
        }
    }

    /// One line, cheap and quiet. Never spoken unless he asks for it.
    static func describe(_ image: UIImage) async -> String? {
        guard let key = APIKeyManager.shared.getGoogleAPIKey(), !key.isEmpty,
              let jpeg = image.jpegData(compressionQuality: 0.5),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=\(key)")
        else { return nil }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [
                ["text": "Describe this photo in ONE short line, under 12 words, as a note-to-self for finding it again later. No preamble. Example: 'handwritten warung sign, opening hours in Indonesian'."],
                ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
            ]]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 300],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = json["candidates"] as? [[String: Any]],
              let content = c.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let t = parts.first?["text"] as? String else { return nil }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// AUDIT FIX (NAV-TILE): the Navigate tile now asks out loud and listens,
    /// instead of opening a paid Live AI session. Arms the ear if it isn't
    /// already, speaks the question, and treats the next thing heard as a
    /// destination even without the wake word — you just pressed the button, so
    /// you have already said "I'm talking to you".
    func promptForDestination() {
        expectingDestinationUntil = Date().addingTimeInterval(12)
        if !isListening {
            silentArm = true
            start()
        }
        TTSService.shared.speak("Where do you want to go?")
        ChappyHaptics.shared.connected()
    }

    /// While this is in the future, a sentence with no wake word is still taken
    /// as a command — specifically as a destination.
    private var expectingDestinationUntil = Date.distantPast
    /// The moment the recogniser last produced anything.
    private var lastHeardAt = Date.distantPast
    /// Cancels a queued wake tone if a newer wake supersedes it.
    private var pendingWakeToneAt = Date.distantPast


    // ==================================================================
    // PROMPT ETIQUETTE — the seven things a person does that a state
    // machine doesn't expect.
    //
    // Every prompt below ("Which language?", "Walking or driving?", "What
    // should I call it?") used to own the NEXT THING YOU SAID, whatever it
    // was. That produced some genuinely bad outcomes: answering "never mind"
    // to the naming prompt saved a spot literally called "never mind", and
    // "actually, take me home instead" was geocoded as a destination named
    // "actually take me home instead".
    //
    // These checks run BEFORE any specific prompt handler, so a person can do
    // the three things people always do: back out, change their mind, or ask
    // you to say it again.

    private var anyPromptOpen: Bool {
        let now = Date()
        return now < expectingLanguageUntil || now < expectingNavModeUntil
            || now < expectingSpotNameUntil || now < expectingDestinationUntil
            || now < expectingMapsAnswerUntil || now < expectingScamUntil
    }

    func closeAllPrompts() {
        expectingLanguageUntil = .distantPast
        expectingNavModeUntil = .distantPast
        expectingSpotNameUntil = .distantPast
        expectingDestinationUntil = .distantPast
        expectingMapsAnswerUntil = .distantPast
        expectingScamUntil = .distantPast
        pendingNavDestination = nil
    }

    /// BUILD 146: while open, the next full sentence is a scam description.
    var expectingScamUntil = Date.distantPast

    private static let cancelWords: Set<String> = [
        "never mind", "nevermind", "cancel", "cancel that", "forget it",
        "forget that", "leave it", "stop", "no thanks", "no thank you",
        "don't worry", "dont worry", "skip it", "not now", "drop it",
    ]
    private static let repeatWords: Set<String> = [
        "what", "what?", "sorry", "pardon", "say again", "say that again",
        "repeat that", "repeat", "come again", "what was that", "huh",
    ]
    /// Openers strong enough that hearing one mid-prompt means he has changed
    /// his mind, not answered. Deliberately narrow — "walking" must NOT count
    /// as a new command when the question was "walking or driving?".
    private static let mindChangeOpeners: [String] = [
        "actually", "instead", "no wait", "wait", "hang on", "forget that",
        "chappy", "take me to", "navigate to", "translate", "remember this",
        "take me home", "open maps", "show the map", "let's talk",
    ]

    /// Returns true when it fully handled the utterance.
    private func handlePromptEtiquette(_ text: String) -> Bool {
        guard anyPromptOpen else { return false }
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))

        // 1. BACKING OUT. "Never mind" is not a language, a travel mode or the
        //    name of a warung, and treating it as one is how you end up with a
        //    saved spot called "never mind".
        if Self.cancelWords.contains(t) || Self.cancelWords.contains(where: { t.hasSuffix(" " + $0) }) {
            closeAllPrompts()
            // BUILD 144 earcon diet: the spoken line IS the confirmation
            TTSService.shared.speak(ChappyVoice.line("cancelled", [
                "No worries.", "Alright, forget it.", "Sure, dropped.",
            ]))
            resetRecognition()
            return true
        }

        // 2. "SAY THAT AGAIN". The most natural thing in the world when you
        //    mishear someone, and it had no handler at all. Replays the line
        //    and KEEPS the prompt open so he can still answer it.
        if Self.repeatWords.contains(t) {
            let again = TTSService.shared.lastSpokenLine
            extendOpenPrompts(by: 12)
            TTSService.shared.speak(again.isEmpty ? "Sorry - I hadn't said anything yet." : again)
            resetRecognition()
            return true
        }

        // 3. CHANGING HIS MIND. If what he said reads as a different COMMAND,
        //    run that instead of forcing it into the answer slot.
        if Self.mindChangeOpeners.contains(where: { t.hasPrefix($0) || t.contains(" " + $0 + " ") }) {
            var cleaned = t
            for lead in ["actually ", "no wait ", "wait ", "hang on ", "instead "] {
                if cleaned.hasPrefix(lead) { cleaned = String(cleaned.dropFirst(lead.count)) }
            }
            closeAllPrompts()
            print("👂 [Standby] Changed his mind mid-prompt → '\(cleaned)'")
            busy = true
            routeTask?.cancel()
            routeTask = Task { @MainActor in
                await self.route(cleaned)
                self.busy = false
                self.followUpUntil = Date().addingTimeInterval(Self.followUpSeconds)
                self.resetRecognition()
            }
            return true
        }
        return false
    }


    /// Split "remember this spot and take me home" into two commands — but only
    /// when both halves genuinely look like instructions on their own. Without
    /// that test, "fish and chips" and "black and white" become two commands,
    /// which is far worse than missing a compound.
    static func splitCompound(_ text: String) -> [String] {
        // BUILD 144: up to THREE actions in one breath — "take me to Coles
        // and get fuel on the way and pull up my list". Same safety rule as
        // ever: a piece only counts as its own command if it LOOKS like one,
        // so "fish and chips" stays one thing. Recursion depth is bounded by
        // the cap, so a rambling sentence can't fan out into five actions.
        split(text, remaining: 3)
    }

    private static func split(_ text: String, remaining: Int) -> [String] {
        guard remaining > 1 else { return [text] }
        let seps = [" and then ", " then ", " and also ", " and "]
        for sep in seps {
            guard let r = text.range(of: sep) else { continue }
            let a = String(text[text.startIndex..<r.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            let b = String(text[r.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            guard a.count > 2, b.count > 2,
                  looksLikeCommand(a), looksLikeCommand(b) else { continue }
            return [a] + split(b, remaining: remaining - 1)
        }
        return [text]
    }

    /// Cheap test: does this half start with something imperative?
    private static func looksLikeCommand(_ t: String) -> Bool {
        let verbs = ["navigate", "take", "get", "go", "walk", "drive", "find",
                     "remember", "save", "pin", "mark", "translate", "snap",
                     "photo", "look", "watch", "show", "open", "map", "log",
                     "note", "stop", "call", "head", "bring",
                     // BUILD 144: the asks that arrive third in a chain.
                     "pull", "read", "tell", "check", "add", "set", "plan", "scan"]
        guard let first = t.split(separator: " ").first.map(String.init) else { return false }
        return verbs.contains(first)
    }

    /// Keep whichever prompts are open alive a little longer.
    private func extendOpenPrompts(by seconds: TimeInterval) {
        let now = Date()
        let new = now.addingTimeInterval(seconds)
        if now < expectingLanguageUntil { expectingLanguageUntil = new }
        if now < expectingNavModeUntil { expectingNavModeUntil = new }
        if now < expectingSpotNameUntil { expectingSpotNameUntil = new }
        if now < expectingDestinationUntil { expectingDestinationUntil = new }
        if now < expectingMapsAnswerUntil { expectingMapsAnswerUntil = new }
    }

    /// BUILD 87 — "just say translate, and it asks me which one."
    /// Exactly the flow he asked for, and the same trick as the destination
    /// prompt: he just spoke to Chappy, so his answer counts without the wake
    /// word. Say "translate" → "Which language?" → "Indonesian" → it opens and
    /// starts listening. No menus, no exact wording to remember.
    private var expectingLanguageUntil = Date.distantPast
    /// While this is in the future, speech routes as a command with no wake
    /// word. Opened after every completed command; see the note in heard().
    private var followUpUntil = Date.distantPast
    /// When the current run of follow-ups began. The window resets on every
    /// utterance, so without a ceiling it could stay open all afternoon in a
    /// crowd — and a live routing mic in a market is how someone else's
    /// sentence becomes your command.
    private var followUpOpenedAt = Date.distantPast
    static let followUpSeconds: TimeInterval = 12
    static let followUpMaxRun: TimeInterval = 45

    /// Speech that carries no instruction. Hearing these should HOLD the door
    /// open — that is precisely what they mean — not be routed as a command.
    static let fillerWords: Set<String> = [
        "um", "uh", "er", "erm", "hmm", "mmm", "ah", "oh", "so", "well",
        "like", "you know", "let me think", "hang on", "just a sec",
        "one sec", "hold on", "wait a minute", "give me a second",
    ]

    /// Words that cannot end a finished sentence. If the last thing you said
    /// was one of these, you were still going.
    static let danglingWords: Set<String> = [
        "to", "at", "in", "on", "for", "from", "with", "into", "onto", "near",
        "by", "about", "of", "and", "or", "but", "the", "a", "an", "my", "our",
        "that", "this", "these", "those", "is", "was", "are", "it", "me", "us",
        "him", "her", "them", "some", "any", "than", "then", "if", "when",
        "because", "towards", "toward", "up", "down", "over",
    ]

    /// Openers that mean nothing on their own — the useful half is still coming.
    static let openerFragments: Set<String> = [
        "take me", "take us", "get me", "get us", "show me", "tell me",
        "find me", "find the", "find a", "where is", "wheres", "where's",
        "what is", "whats", "what's", "how much", "how far", "how long",
        "call it", "log this", "note this", "navigate me", "navigate us",
        "remind me", "look for", "search for", "book me", "order me",
    ]

    /// THE HESITATION RULE (build 90, finally implemented).
    ///
    /// Silence is only an ending if what came before it was a complete thought.
    /// "Take me to… um… that place near the beach" pauses in the middle, and a
    /// pure timeout fires on "take me to" and throws the rest away.
    ///
    /// So a fragment that cannot possibly be finished — a trailing preposition,
    /// a bare opener, pure filler — buys three seconds. Anything that reads as
    /// complete still fires immediately, so "stop" stays instant. Hesitation is
    /// allowed; decisiveness is not punished.
    static func looksUnfinished(_ t: String) -> Bool {
        let text = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }

        // Words the extendable branch already handles get their own, SHORTER
        // window. Routing them here would make a bare "translate" sit silent
        // for three seconds, which is the opposite of the point.
        if extendableCommands.contains(text) { return false }
        // A complete command is never unfinished, however it happens to end.
        if terminalCommands.contains(text) { return false }

        if fillerWords.contains(text) { return true }
        if openerFragments.contains(text) { return true }

        let words = text.split(separator: " ").map(String.init)
        guard let last = words.last else { return false }
        if fillerWords.contains(last) { return true }
        if danglingWords.contains(last) { return true }
        return false
    }

    /// BUILD 170 — put every tool down and go back to the main screen.
    func resetEverything() {
        // 1. Silence first — you said this because something was talking
        //    over you, or nothing was responding. Either way, quiet.
        TTSService.shared.stop()
        ChappyEarcon.shared.stopThinking()

        // 2. End every live module. Each is a no-op if it wasn't running.
        NavEngine.shared.stop(announce: false)
        NotificationCenter.default.post(name: Notification.Name("chappyMapsCleanup"), object: nil)
        if ContinuousVisionManager.shared.isRunning { ContinuousVisionManager.shared.stop() }
        if LiveAIManager.shared.isRunning {
            Task { await LiveAIManager.shared.stopSession() }
        }
        if ChappyDictate.shared.isRecording { ChappyDictate.shared.stop(andPolish: false) }
        ChappyRide.shared.stopTripWatch()

        // 3. Cancel every pending question window, so Chappy isn't still
        //    waiting for an answer to something you've moved on from.
        //    closeAllPrompts() already knows every window there is — better
        //    than a list here that goes stale the next time one is added.
        closeAllPrompts()
        pendingNavDestination = nil

        // 4. Close whatever is on screen.
        NotificationCenter.default.post(name: .chappyCloseEverything, object: nil)

        // 5. And make sure the ear is genuinely alive on the way out —
        //    this command is most often said BECAUSE it had gone deaf.
        rebuildEar()

        ChappyHaptics.shared.straightStep()
        ChappyEarcon.shared.done()
        TTSService.shared.speak("All clear. Back to the start.")
    }

    func askForTranslateLanguage() {
        expectingLanguageUntil = Date().addingTimeInterval(12)
        if !isListening { silentArm = true; start() }
        ChappyEarcon.shared.wake()
        TTSService.shared.speak(ChappyVoice.line("ask_lang", [
            "Which language?",
            "Translate into what?",
            "What language are they speaking?",
        ]))
    }

    /// Start the interpreter on a resolved language code.
    func beginTranslate(code: String) {
        UserDefaults.standard.set("en", forKey: "translate_source_language")
        UserDefaults.standard.set(code, forKey: "translate_target_language")
        UserDefaults.standard.set(code, forKey: "translate_last_used_language")
        UserDefaults.standard.set(true, forKey: "translate_autostart")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "translate_autostart_at")
        // BUILD 144 earcon diet: the spoken line IS the confirmation
        TTSService.shared.speak("Translating English and \(Self.languageName(code)).")
        handOff()
        NotificationCenter.default.post(name: .chappyOpenTranslate, object: nil)
    }

    /// BUILD 87 — "then ask me if I'm driving, walking or on a scooter."
    /// Only asked when the mode is genuinely unknown: saying "walk me to the
    /// chemist" already answered it, and asking again would be maddening.
    private var pendingNavDestination: String?
    private var expectingNavModeUntil = Date.distantPast

    func askForNavMode(destination: String) {
        pendingNavDestination = destination
        expectingNavModeUntil = Date().addingTimeInterval(12)
        if !isListening { silentArm = true; start() }
        ChappyEarcon.shared.wake()
        // BUILD 104: this used to ask the mode WITHOUT naming the place, so a
        // misheard destination was invisible until a route to the wrong shop
        // appeared. Saying it back costs a second and catches every mishear at
        // the only moment it is still cheap to fix.
        TTSService.shared.speak("\(destination). Walking, driving, or scooter?")
    }

    /// Same trick for naming a spot you just saved.
    ///
    /// WHY THIS EXISTS: Remember always worked — it saved the pin and said so.
    /// But it named it "spot at 4:53PM near Cresthaven Court", and a list of
    /// timestamps is not a memory. Six weeks into a trip you will have forty of
    /// them and not one will mean anything. The pin is only worth saving if you
    /// can say "the warung with the good coffee" and find it again, so the
    /// naming has to happen in the two seconds while you still remember why you
    /// pressed the button — by voice, without taking the phone out.
    private var expectingSpotNameUntil = Date.distantPast

    /// Save where you are, then ask what to call it.
    func rememberSpotByVoice() {
        ChappyEarcon.shared.tap()
        ContextEngine.shared.start()
        let spot = TripRecorder.shared.rememberSpot(named: "")
        ChappyHaptics.shared.straightStep()
        guard spot.lat != 0 || spot.lon != 0 else {
            TTSService.shared.speak("Saved, but GPS hasn't locked yet - give it a few seconds outside and try again.")
            return
        }
        ChappyEarcon.shared.done()
        expectingSpotNameUntil = Date().addingTimeInterval(12)
        if !isListening {
            silentArm = true
            start()
        }
        TTSService.shared.speak(ChappyVoice.line("spot_saved", [
            "Saved. What should I call it?",
            "Got it. What's it called?",
            "Pinned. Give it a name?",
        ]))
    }

    /// The 50s renewal, in one place so the interruption handler can restart it.
    private func restartRenewTimer() {
        restartTimer?.invalidate()
        // BUILD 160: 50s renewals leave a small deaf gap each time. The
        // renewal itself stays (the recogniser genuinely expires near 60s),
        // but a 2-second liveness sweep now runs alongside it so a gap that
        // does swallow a word is measured in seconds, not tens of seconds.
        livenessTimer?.invalidate()
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening, !self.awake, !self.busy else { return }
                guard !TTSService.shared.isSpeaking else { return }
                // BUILD 171 — THE SWEEP HAD TO LEARN WHEN TO KEEP OUT.
                //
                // Two dangers in the 160 version. First, it ran every 2s
                // against a rebuild throttle of exactly 2s — so a genuinely
                // dead tap meant rebuilding the audio engine forever, and
                // installTap during that churn is precisely the crash 142
                // was written to stop. Second, it did not check whether
                // ANOTHER module had taken the microphone: Live AI,
                // Translate, Dictate and continuous vision all own the
                // input node while they run, and a rebuild underneath them
                // pulls the node out from under a live session.
                //
                // Now: never while another module holds the mic, never
                // before a first buffer has ever arrived, and no more than
                // one sweep-rebuild every 15 seconds.
                guard !LiveAIManager.shared.isRunning,
                      !ContinuousVisionManager.shared.isRunning,
                      !ChappyDictate.shared.isRecording,
                      GeminiLiveService.activeInstance == nil else { return }
                guard self.lastBufferAt != .distantPast else { return }
                guard Date().timeIntervalSince(self.lastSweepRebuild) > 15 else { return }
                if Date().timeIntervalSince(self.lastBufferAt) > 4.5 {
                    self.lastSweepRebuild = Date()
                    print("👂 [Standby] Liveness sweep: ear went quiet — rebuilding")
                    self.rebuildEar()
                }
            }
        }
        restartTimer = Timer.scheduledTimer(withTimeInterval: 55, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // BUILD 119: never rebuild the recogniser while he is talking.
                // The 50-second renewal is housekeeping; landing it in the
                // middle of a sentence loses the sentence. Wait for a gap.
                guard Date().timeIntervalSince(self.lastHeardAt) > 1.5,
                      !TTSService.shared.isSpeaking, !self.awake, !self.busy else {
                    print("👂 [Standby] Renewal deferred — mid-utterance")
                    return
                }
                self.renew()
            }
        }
    }

    @discardableResult
    private func startRecognition() -> Bool {
        guard let recognizer else { return false }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true

        // BUILD 104 — HEARING, PROPERLY.
        //
        // On-device recognition is free, private and works on a plane, and it
        // is noticeably WORSE at proper nouns than Apple's server model. That
        // is exactly the class of word this app lives on: McDonald's, Hungry
        // Jack's, IGA, Gojek, Uluwatu. "Take me to the closest McDonald's"
        // coming back as a route to a shop called King IT is what that failure
        // looks like from the outside.
        //
        // So: use the server model when there is a network, and fall back to
        // on-device the moment it fails twice. Offline still works; it just
        // hears brand names less well, which is the correct trade.
        let forcedOffline = UserDefaults.standard.bool(forKey: "chappy_hearing_offline_only")
        let useOnDevice = recognizer.supportsOnDeviceRecognition
            && (forcedOffline || Self.serverHearingFailures >= 2)
        req.requiresOnDeviceRecognition = useOnDevice

        // A short command is a search query, not dictation. The hint changes
        // which language model weights get used and it is free.
        req.taskHint = .search

        // CONTEXTUAL STRINGS — words to expect. This is the single cheapest
        // accuracy win available: his own assistant's name, every place he has
        // already saved, and the brands he actually says out loud.
        var hints = Self.wakeWords
        hints += TripRecorder.shared.spots.suffix(40).map { $0.name }
        hints += Self.brandHints
        req.contextualStrings = Array(hints.prefix(100))

        request = req

        let input = engine.inputNode
        // BUILD 142 — THE CRASH IN THE .IPS, KILLED AT THE SOURCE.
        //
        // installTap throws an UNCATCHABLE exception when the hardware format
        // shifts between reading it and installing the tap — and the crash
        // report shows exactly that: InstallTapOnNode dying on the main
        // thread while the engine queue was mid IOUnitConfigurationChanged
        // (Safari grabbing the route, app backgrounded). The format guard
        // below can't close that race; NOT INSTALLING during upheaval can.
        // A tap is never installed within a breath of a route change — wait
        // for calm, then come back.
        if Date().timeIntervalSince(Self.lastAudioUpheavalAt) < 0.7 {
            print("👂 [Standby] Audio still settling — deferring the tap")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.isListening else { return }
                _ = self.startRecognition()
            }
            return false
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            print("⚠️ [Standby] Mic format not ready")
            return false
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            // AUDIT P0 (SB-LIVENESS): the only honest proof that audio is
            // actually reaching us. engine.isRunning stays true through most of
            // the ways this ear dies; buffers stopping is what "deaf" looks like.
            self?.lastBufferAt = Date()
        }
        lastBufferAt = Date()
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch {
                print("⚠️ [Standby] Mic failed: \(error.localizedDescription)")
                return false
            }
        }
        // AUDIT FIX (HIGH): cancelling a task delivers a final error to the
        // OLD task's handler, which used to nil out the NEW task and start a
        // third — an unbounded ping-pong of orphaned recognizers all calling
        // heard(), i.e. duplicate commands. Each callback now proves it is
        // still the current task before doing anything.
        var thisTask: SFSpeechRecognitionTask?
        thisTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let result {
                // A result proves the path works; forgive earlier blips.
                if !useOnDevice { Self.serverHearingFailures = 0 }
                let text = result.bestTranscription.formattedString.lowercased()
                Task { @MainActor in
                    guard let self, self.task === thisTask else { return }
                    self.heard(text)
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                if error != nil && !useOnDevice {
                    Self.serverHearingFailures += 1
                    if Self.serverHearingFailures == 2 {
                        print("👂 [Standby] Server hearing failed twice — on-device for the rest of this session")
                    }
                }
                Task { @MainActor in
                    guard let self, self.task === thisTask else { return }
                    self.task = nil
                    // AUDIT FIX: restarting the EAR while a command routes is
                    // harmless (re-entry is blocked in finish()); the old
                    // !busy guard left the ear dead for up to 50 seconds.
                    guard self.isListening else { return }
                    _ = self.startRecognition()
                }
            }
        }
        task = thisTask
        return true
    }

    // MARK: Hearing

    private func heard(_ text: String) {
        // AUDIT P0 (SB-SELFTALK): anything delivered while Chappy was talking,
        // or in the decay window straight after, is his own voice coming back
        // through the speaker. Discard it without scanning for the wake word.
        guard Date() >= suppressTranscriptBefore else { return }
        // When words last arrived. Used to tell "he has stopped" from "he is
        // mid-sentence", which is the whole difference between an
        // acknowledgement and an interruption.
        lastHeardAt = Date()
        lastHeard = text

        // BARGE-IN LAW — with the self-interruption guard.
        // Naive "any speech stops the voice" is a trap: the mic hears CHAPPY
        // through the speaker and cuts him off mid-sentence, every sentence.
        // So while he is speaking, only DELIBERATE kill-words count; the
        // moment he's quiet, everything is heard normally.
        // SB-DEADLOCK FIX (belt and braces): this gate trusted a single Bool
        // owned by another object. When that Bool stuck true, the ear went
        // permanently deaf while the chip still read "Standby on" — armed,
        // listening, and routing nothing. TTSService now can't stick, but the
        // wake word is the last thing in the app that should ever depend on
        // somebody else's flag being honest. If it claims to have been speaking
        // for longer than any real utterance lasts, disbelieve it and hear.
        var reallySpeaking = TTSService.shared.isSpeaking
        if reallySpeaking, let since = TTSService.shared.speakingSince,
           Date().timeIntervalSince(since) > 60 {
            print("⚠️ [Standby] TTS has claimed to be speaking for over a minute — ignoring the gate")
            reallySpeaking = false
        }
        if reallySpeaking {
            let killWords = ["chappy stop", "stop chappy", "shut up", "shush",
                             "be quiet", "quiet", "enough", "stop talking", "that's enough"]
            if killWords.contains(where: { text.hasSuffix($0) || text.contains($0) }) {
                TTSService.shared.stop()
                ChappyHaptics.shared.straightStep()
                awake = false; command = ""
                routeWork?.cancel()
                print("🤫 [Standby] Killed mid-sentence by voice")
                return
            }
            // BUILD 133 — BARGE-IN, NOT JUST A MUTE BUTTON.
            //
            // Saying the NAME mid-sentence now cuts Chappy off and takes the
            // command in the same breath: "Chappy, take me home" lands while
            // the morning brief is still talking, kills it, and routes.
            //
            // The echo guard is the whole trick. The mic reliably hears the
            // speaker, so if the line being SPOKEN contains "chappy" (the
            // greeting does: "Chappy here"), the bare name doesn't count —
            // only the name plus a tail that Chappy is NOT currently saying
            // counts as the wearer. If the spoken line doesn't contain the
            // name, the name alone is enough.
            if let r = Self.wakeWords
                .compactMap({ text.range(of: $0, options: .backwards) })
                .max(by: { $0.upperBound < $1.upperBound }) {
                let spokenLower = TTSService.shared.lastSpokenLine.lowercased()
                let tail = String(text[r.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
                let nameSafe = !spokenLower.contains("chappy")
                let tailIsHis = !tail.isEmpty && !spokenLower.contains(tail)
                if nameSafe || tailIsHis {
                    TTSService.shared.stop()
                    ChappyHaptics.shared.straightStep()
                    print("🎙️ [Standby] Barge-in — the name heard mid-sentence")
                    // No return: the gate has lifted, and THIS utterance
                    // already carries the wake word (and maybe the command).
                    // Let it route right now rather than making him repeat it.
                } else {
                    return
                }
            } else {
                return // never route while he's mid-answer
            }
        }

        if !awake {
            guard let range = Self.wakeWords.compactMap({ text.range(of: $0, options: .backwards) })
                .max(by: { $0.upperBound < $1.upperBound })
            else {
                // AUDIT FIX (NAV-TILE): the user just pressed Navigate and was
                // asked a question out loud. Making him also say the wake word
                // to answer it would be absurd, so for a few seconds his answer
                // counts on its own — routed straight to navigation.
                // Naming a spot beats navigating to one — if both windows are
                // somehow open, the more recent prompt wins.
                // ============ BUILD 87: THE FOLLOW-UP WINDOW ============
                // Meta's glasses keep listening for a few seconds after they
                // answer, so a conversation is a conversation and not a series
                // of formal announcements. Saying the name before EVERY
                // sentence is the single most tiring thing about a wake-word
                // assistant, and it is why this felt like barking orders at a
                // machine rather than talking to something.
                //
                // Eight seconds after Chappy finishes, anything you say routes
                // as a command with no wake word. Each command resets the
                // window, so a run of them flows: "Chappy, translate" →
                // "Indonesian" → "map" → "remember this place".
                //
                // Deliberately NOT longer: the mic is live in your pocket in a
                // market, and every extra second is another sentence of someone
                // else's conversation that could route. Eight is enough to
                // follow a thought and short enough to be safe.
                if Date() < followUpUntil, !awake, !busy {
                    let t = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))

                    // Filler is not a command — it is a person thinking. Hold
                    // the door and say nothing.
                    if t.count < 3 || Self.fillerWords.contains(t)
                        || Self.fillerWords.contains(where: { t == $0 || t.hasSuffix(" " + $0) }) {
                        if Date().timeIntervalSince(followUpOpenedAt) < Self.followUpMaxRun {
                            followUpUntil = Date().addingTimeInterval(Self.followUpSeconds)
                            // BUILD 144 — EARCON DIET: the door stays open
                            // SILENTLY. The chirp here fired on every "um",
                            // which is exactly the lift-chime effect the
                            // wearer asked to be rid of. Sound now means a
                            // task starting or finishing, nothing else.
                        }
                        return
                    }

                    // The ceiling: a window that resets forever is a mic that
                    // never closes.
                    guard Date().timeIntervalSince(followUpOpenedAt) < Self.followUpMaxRun else {
                        followUpUntil = .distantPast
                        print("👂 [Standby] Follow-up run hit its ceiling — name required again")
                        return
                    }

                    followUpUntil = .distantPast
                    awake = true
                    command = t
                    ChappyHaptics.shared.connected()
                    print("👂⚡ [Standby] Follow-up (no wake word needed)")
                    lastWordAt = Date()
                    routeWork?.cancel()
                    let snap = command
                    let work = DispatchWorkItem { [weak self] in self?.finish(snap) }
                    routeWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
                    return
                }
                // Back out, change your mind, or ask him to repeat — checked
                // before any prompt gets to claim what you said.
                if handlePromptEtiquette(text) { return }

                // BUILD 146: answering "Tell me what's happening" (scam check).
                if Date() < expectingScamUntil, text.split(separator: " ").count >= 3 {
                    expectingScamUntil = .distantPast
                    let described = text
                    Task { @MainActor in
                        if let v = ChappyScamGuard.verdict(for: described) {
                            TTSService.shared.speak(v)
                        } else {
                            // No rule tripped — the cheap brain judges it,
                            // with the wearer's own context attached.
                            await self.quickAsk("SCAM CHECK - judge this situation for scam red flags in two short spoken sentences, be direct about risk: \(described)")
                        }
                    }
                    resetRecognition()
                    return
                }
                // BUILD 90: answering "Want turn by turn in Google Maps?"
                // BUILD 132: armed after EVERY spoken route summary too, so
                // bare "open maps" works without the wake word. Three changes:
                // the window only closes on a real answer (a stray recognised
                // word no longer eats it), "no" is explicit rather than
                // "anything that isn't yes", and the window is long enough to
                // outlast the summary itself — the ear is deaf while Chappy
                // talks, so a short window used to expire before the wearer
                // ever got a turn.
                if Date() < expectingMapsAnswerUntil, text.count > 1 {
                    let yes = ["yes", "yeah", "yep", "sure", "please", "ok", "okay",
                               "go on", "do it", "open maps", "open the maps",
                               "open google maps", "open it", "maps"]
                        .contains { text.contains($0) }
                    let no = ["no", "nah", "nope", "no thanks", "don't", "dont",
                              "never mind", "nevermind", "leave it"]
                        .contains { text == $0 || text.hasSuffix(" " + $0) || text.hasPrefix($0 + " ") }
                    if yes {
                        expectingMapsAnswerUntil = .distantPast
                        ChappyEarcon.shared.done()
                        NotificationCenter.default.post(name: .chappyOpenGoogleMaps, object: nil)
                        resetRecognition()
                        return
                    }
                    if no {
                        expectingMapsAnswerUntil = .distantPast
                        TTSService.shared.speak("No worries.")
                        resetRecognition()
                        return
                    }
                    // Neither — he said something else. Leave the window armed
                    // and let the words route normally.
                }
                // BUILD 87: answering "Which language?" — no wake word needed.
                if Date() < expectingLanguageUntil, text.count > 1 {
                    if let code = Self.languageCode(spokenIn: text) {
                        expectingLanguageUntil = .distantPast
                        beginTranslate(code: code)
                    } else {
                        TTSService.shared.speak("I don't have that one. Try Indonesian, Thai, Vietnamese, Japanese, Chinese, French, German or Spanish.")
                        expectingLanguageUntil = Date().addingTimeInterval(12)
                    }
                    resetRecognition()
                    return
                }
                // BUILD 87: answering "Walking, or driving?"
                if Date() < expectingNavModeUntil, let dest = pendingNavDestination, text.count > 1 {
                    expectingNavModeUntil = .distantPast
                    pendingNavDestination = nil
                    // Scooter is its own answer because it is the default way
                    // to move in Bali and he asked for it by name. It routes as
                    // a vehicle (scooters follow roads) but is remembered
                    // separately so the Google Maps hand-off opens the right
                    // mode rather than car directions for a motorbike.
                    let scooter = ["scoot", "motorbike", "moto", "bike"].contains { text.contains($0) }
                    let drive = scooter || ["driv", "car", "taxi", "grab", "uber",
                                            "ride"].contains { text.contains($0) }
                    NavEngine.shared.lastModeWasScooter = scooter
                    Task { @MainActor in
                        self.speak("Finding \(dest).")
                        ChappyEarcon.shared.startThinking()
                        let reply = await NavEngine.shared.navigate(to: dest, driving: drive)
                        ChappyEarcon.shared.stopThinking()
                        self.speak(NavEngine.shared.spokenRouteSummary ?? reply)
                        // BUILD 104: the direct path offered the map; THIS path
                        // — the one you land on whenever you didn't say how you
                        // were travelling, which is most of the time — did not.
                        // So the hands-free "want the map? yes" never happened.
                        if NavEngine.shared.isNavigating {
                            // BUILD 117: you already answered the mode question,
                            // so asking a SECOND question before showing the map
                            // is one question too many. On a vehicle it just
                            // opens — that is what "drive" meant. Walking still
                            // asks, because on foot the spoken directions are
                            // usually enough and Maps is the interruption.
                            if drive {
                                self.speak("Opening Google Maps.")
                                NotificationCenter.default.post(name: .chappyOpenGoogleMaps, object: nil)
                            } else {
                                self.offerGoogleMaps(driving: drive)
                            }
                        }
                    }
                    resetRecognition()
                    return
                }
                if Date() < expectingSpotNameUntil, text.count > 1 {
                    expectingSpotNameUntil = .distantPast
                    let name = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
                    // "call it the blue warung" / "it's the blue warung"
                    var cleaned = name
                    for lead in ["call it ", "name it ", "it's ", "its ", "the name is "] {
                        if cleaned.hasPrefix(lead) { cleaned = String(cleaned.dropFirst(lead.count)) }
                    }
                    if TripRecorder.shared.renameLastSpot(to: cleaned) {
                        // BUILD 144 earcon diet: the spoken line IS the confirmation
                        ChappyHaptics.shared.straightStep()
                        TTSService.shared.speak("Saved as \(cleaned).")
                    } else {
                        TTSService.shared.speak("Couldn't catch the name, but the spot's safe.")
                    }
                    resetRecognition()
                    return
                }
                if Date() < expectingDestinationUntil, text.count > 2 {
                    expectingDestinationUntil = .distantPast
                    awake = true
                    command = "take me to " + text
                    ChappyHaptics.shared.connected()
                    print("👂⚡ [Standby] Destination answer accepted without wake word")
                    lastWordAt = Date()
                    routeWork?.cancel()
                    let snapshot = command
                    let work = DispatchWorkItem { [weak self] in self?.finish(snapshot) }
                    routeWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
                }
                return
            }
            awake = true
            command = String(text[range.upperBound...])
            acknowledgeWake(tail: command)
            print("👂⚡ [Standby] Woken")
        } else {
            // Keep only what follows the LAST wake word in the running text
            if let range = Self.wakeWords.compactMap({ text.range(of: $0, options: .backwards) })
                .max(by: { $0.upperBound < $1.upperBound }) {
                command = String(text[range.upperBound...])
            } else {
                command = text
            }
        }
        lastWordAt = Date()
        // RESPONSIVENESS. 1.1s was tuned to be safe against clipping a long
        // sentence, but it is dead air on the short imperative commands that
        // are 90% of real use — "chappy translate", "chappy map". Scale it:
        // a short tail is almost certainly finished, a long one may still be
        // going. Saves roughly half a second on the commands you use most.
        routeWork?.cancel()
        let snapshot = command
        let work = DispatchWorkItem { [weak self] in self?.finish(snapshot) }
        routeWork = work
        // ================= TIER 2: INSTANT FIRE =================
        // Waiting for silence is the wrong model for a short imperative. Once
        // the ear has heard "chappy stop" there is nothing left to wait FOR —
        // no command in the grammar extends it — so any delay is pure dead air
        // on the one command whose entire purpose is to interrupt.
        //
        // Three classes, by whether more words could still be coming:
        //
        //   TERMINAL    nothing can follow. Fire NOW, 0 ms.
        //               stop · quiet · enough · battery · where am I
        //   EXTENDABLE  a known command that MIGHT take a tail
        //               ("translate" → "translate to Thai"). 250 ms grace:
        //               long enough to catch the tail, short enough to feel
        //               instant if it never comes.
        //   OPEN        anything else. Scaled wait, as before.
        //
        // The distinction matters: firing "translate" instantly would break
        // "translate to Thai" by acting before the language arrives. Guessing
        // wrong in that direction is worse than 250 ms.
        let cleanTail = snapshot.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
        if Self.terminalCommands.contains(cleanTail) {
            routeWork = nil
            print("⚡ [Standby] Instant fire: \(cleanTail)")
            finish(cleanTail)
            return
        }
        // ============ THINKING TIME ============
        // 0.6s of silence meant "he's finished". Real speech does not work
        // that way: "take me to… um… that place near the beach" pauses in the
        // middle, and the old code fired on "take me to" and threw the rest
        // away. Silence is only an ending if what came before it was a
        // complete thought.
        //
        // So an INCOMPLETE fragment — a bare preposition, a trailing "to", a
        // command opener with nothing after it — gets up to three seconds to
        // finish. A complete command still fires immediately, so "stop" stays
        // instant. Hesitation is allowed; decisiveness is not punished.
        let debounce: Double
        if Self.looksUnfinished(cleanTail) {
            debounce = 3.0
        } else if Self.extendableCommands.contains(cleanTail) {
            // BUILD 90: 0.40s was too tight for "translate … to Indonesian".
            // The tail arrives as a separate recogniser partial and any natural
            // pause expired the window, firing bare "translate" and losing the
            // language. Words that commonly take a tail get longer.
            // BUILD 135: widened again — the recogniser delivers partials in
            // bursts, and a burst gap mid-sentence was firing half a thought.
            debounce = ["translate", "navigate", "go", "map to"].contains(cleanTail) ? 0.9 : 0.6
        } else {
            // BUILD 118 — FASTER ONCE HE HAS ACTUALLY FINISHED.
            //
            // The old ladder waited longer the MORE he said, which is exactly
            // backwards: a long sentence is usually a complete one, and a
            // complete sentence should fire immediately. The long wait is for
            // hesitation, and looksUnfinished already catches that above.
            //
            // So: a complete-looking command gets a short window regardless of
            // length. Only genuinely ambiguous short fragments — where more
            // words would change the meaning — get the longer one.
            // BUILD 144 — TURN-TAKING LIKE A PERSON. The spec, in the wearer's
            // own words: "wait till I finish speaking — 1 to 2 seconds of
            // silence — THEN respond quickly." So sentence-shaped speech now
            // waits 1.2s of true quiet before firing, and every new word
            // resets the clock (routeWork is cancelled on each partial). The
            // trade is deliberate: ~half a second more patience buys never
            // being talked over, and the reply itself got fast in 143.
            // Terminals ("stop") stay instant; short imperatives stay snappy.
            let wordCount = snapshot.split(separator: " ").count
            // BUILD 160: short commands tightened 0.9 -> 0.75. A two-word
            // imperative is finished the moment it lands; the long wait in
            // 144 was for SENTENCES and that stays exactly where it was.
            // BUILD 163: tightened once more now the turn-taking is proven.
            // 0.65 for a two-word imperative is about as low as it can go
            // before the recogniser's own partial-delivery jitter starts
            // clipping words; sentences keep their patience.
            if wordCount <= 2 {
                debounce = 0.65          // short command — as snappy as it gets
            } else if wordCount <= 4 {
                debounce = 0.9           // short sentence
            } else {
                debounce = 1.15          // a real sentence — let him finish it
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// BUILD 166 — a question about WHEN SOMETHING ELSE happens, as opposed
    /// to a question about the clock. Deliberately narrow: it must open with
    /// a when-shape AND not name anything of his, because everything
    /// personal has its own handler further up the ladder.
    static func looksLikeEventTimeQuestion(_ c: String) -> Bool {
        let opens = ["what time is the ", "what time is a ", "what time does the ",
                     "what time does ", "what time do the ", "when is the ",
                     "when's the ", "whens the ", "what time are the ",
                     "when does the ", "when do the ", "what time is brisbane"]
        guard opens.contains(where: { c.contains($0) }) else { return false }
        let mine = ["my flight", "my appointment", "my reminder", "my meeting",
                    "my job", "my next", "my day", "my calendar", "my ride",
                    "my grab", "my uber", "i have", "i've got", "ive got"]
        if mine.contains(where: { c.contains($0) }) { return false }
        return true
    }

    /// AUDIT P0 — THE MISTAKE THIS SET USED TO MAKE.
    ///
    /// `heard()` receives the recogniser's RUNNING transcript, not finished
    /// sentences. "stop" is what "stop navigation" looks like a quarter of a
    /// second before the word "navigation" arrives. So a set containing short
    /// words fired on the FIRST HALF of longer commands:
    ///
    ///   "Chappy, stop navigation"        -> fired "stop", route never cancelled
    ///   "Chappy, quiet mode"             -> fired "quiet", mode never set
    ///   "Chappy, where am I on the map"  -> fired "where am i", map never opened
    ///   "Chappy, help me talk to them"   -> fired "help", coach menu instead
    ///   "Chappy, emergency room near me" -> FIRED A REAL SOS
    ///
    /// That last one is why this is a P0 and not a polish item: it would have
    /// WhatsApped his emergency contact with a live map pin because he asked
    /// where a hospital was. Two independent auditors found it separately.
    ///
    /// The fix is the inverse of the instinct: instant-fire the COMPLETE forms,
    /// never the short prefixes. "stop navigation" is terminal — nothing
    /// extends it. Bare "stop" is not, and gets the grace window instead. The
    /// unit test in Self.validateCommandSets() enforces this and will trip on
    /// the next person to add a short word here.
    static let terminalCommands: Set<String> = [
        // Interrupts that genuinely end there.
        "shut up", "shush", "be quiet", "never mind",
        "that's enough", "thats enough", "stop talking",
        // Complete long forms of otherwise-ambiguous commands.
        "stop navigation", "stop navigating", "cancel navigation",
        "battery check", "battery level",
        "quiet mode", "tour mode", "budget mode", "normal mode",
        "open google maps", "show the map", "show map",
        "what can i say", "what can you do",
        "spent today", "cost check", "usage today",
        "where was i", "what street", "i'm lost", "im lost",
        // PHASE 5 — complete, harmless, and nothing extends them.
        "open memory", "show my memories", "memory browser",
    ]

    /// Prefixes that MUST NOT instant-fire, because a real command extends
    /// them. Kept explicit so the reasoning survives the next edit.
    static let neverInstant: Set<String> = [
        "stop", "cancel", "quiet", "battery", "where am i",
        "emergency", "sos", "help", "help me", "open maps", "enough",
    ]

    /// Guard rail: no terminal command may be a prefix of another known
    /// command, and nothing in `neverInstant` may leak into the terminal set.
    /// Called once at arm time; a violation is a programming error, not a
    /// runtime condition, so it prints loudly rather than failing quietly.
    static func validateCommandSets() {
        for t in terminalCommands where neverInstant.contains(t) {
            print("‼️ [Standby] '\(t)' is prefix-unsafe and must not be terminal")
        }
        for a in terminalCommands {
            for b in terminalCommands.union(extendableCommands) where b != a && b.hasPrefix(a + " ") {
                print("‼️ [Standby] terminal '\(a)' is a prefix of '\(b)' — would fire early")
            }
        }
    }

    /// Known commands that MAY take a tail. A short grace, then fire.
    ///
    /// AUDIT P1: the grace is 400ms, not 250ms. 250 was measured between
    /// recogniser PARTIALS rather than actual silence, and a natural pause
    /// before the tail — "Chappy, translate… to Thai" — expired it, firing the
    /// bare command and then wiping the transcript so the tail was lost
    /// entirely. 400ms still reads as instant and survives a real breath.
    ///
    /// Everything here is verified to have a handler in route(). "look",
    /// "navigate" and "go" previously did NOT and fell through to the either/or
    /// prompt, which then poisoned the next command for 45 seconds.
    static let extendableCommands: Set<String> = [
        "translate", "snap", "photo", "take a photo", "take a picture",
        "map", "remember", "remember this spot", "watch", "keep watching",
        "let's talk", "lets talk", "take me home", "get me home", "go home",
        // BUILD 129: destination openers need the same grace "navigate"
        // already gets. "take me to the IGA at Sunset Road" arrives as
        // several recogniser partials and a short window routed half a
        // place name.
        "take me to", "take us to", "drive me to", "drive us to",
        "walk me to", "walk us to", "get me to", "get us to",
        "navigate to", "navigate me to", "directions to", "route to",
        "closest", "nearest",
        // The prefix-unsafe words from neverInstant land here instead: a grace
        // is exactly what they need, so the tail can arrive.
        "stop", "cancel", "quiet", "battery", "where am i",
        "emergency", "sos", "help", "help me", "open maps", "enough",
    ]

    private func finish(_ raw: String) {
        // AUDIT FIX (HIGH — re-entry): a second command arriving while one is
        // still routing used to run BOTH concurrently — two paid calls, two
        // voices, and a `busy` flag that stopped meaning anything.
        // AUDIT P1: "stop" is the command you use precisely BECAUSE something is
        // in flight — so routing it through the busy guard meant it was the one
        // command that could never do its job. He'd get a failure tone and
        // "Still working on the last one" while Chappy kept talking over him.
        // Interrupts jump the queue and kill the work that's blocking them.
        let interrupts = ["stop", "shut up", "shush", "quiet", "enough",
                          "be quiet", "stop talking", "that's enough",
                          "thats enough", "never mind", "cancel"]
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
        if interrupts.contains(cleaned) {
            TTSService.shared.stop()
            routeTask?.cancel()
            // An interrupt cancels the QUESTION too. Cutting Chappy off
            // mid-question and then having the next thing you say swallowed by
            // that same question is the opposite of being interrupted.
            closeAllPrompts()
            busy = false
            awake = false; command = ""
            routeWork?.cancel(); routeWork = nil
            ChappyHaptics.shared.straightStep()
            print("🤫 [Standby] Interrupt — killed in-flight work")
            resetRecognition()
            return
        }
        guard !busy else {
            // AUDIT P1 (SB-BUSY): this dropped the command with no speech and no
            // haptic. Wearing glasses with the phone pocketed, "heard and
            // dropped" and "never heard at all" are indistinguishable — so he
            // repeats himself into a void. Say something.
            print("👂 [Standby] Busy — dropped: \(raw)")
            ChappyHaptics.shared.straightStep()
            TTSService.shared.speak("One thing at a time - still on the last.")
            // AUDIT P1 (SB-AWAKE): `awake` was left TRUE here. The next sentence
            // was then routed with no wake word at all — an overheard
            // conversation could fire a command — and renew() is guarded on
            // `!awake`, so the ear also stopped renewing and went deaf inside a
            // minute. Both from one dropped command.
            awake = false
            command = ""
            routeWork?.cancel(); routeWork = nil
            return
        }
        let cmd = raw.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
        awake = false
        command = ""
        // AUDIT P1 (SB-DOUBLE): the debounce work item that scheduled this call
        // was never cancelled once it fired, and a later partial result could
        // schedule a second one carrying the same text — two photos, or two
        // paid calls, from one spoken sentence.
        routeWork?.cancel(); routeWork = nil
        guard !cmd.isEmpty else {
            // A bare "Chappy" used to answer "Yes?" and then CLOSE — so having
            // paused to think, you had to say the name again. That punished
            // exactly the moment you needed a second, which is the opposite of
            // what a follow-up window is for. Answering the name opens the door.
            followUpUntil = Date().addingTimeInterval(Self.followUpSeconds)
            followUpOpenedAt = Date()
            TTSService.shared.speak(ChappyVoice.line("yes", ["Yes?", "Go on.", "I'm here."]))
            resetRecognition()
            return
        }
        print("👂➡️ [Standby] Command: \(cmd)")
        busy = true
        routeTask?.cancel()
        routeTask = Task { @MainActor in
            // COMPOUND COMMANDS. "Remember this spot and take me home" used to
            // run the first half and silently drop the second — route() returns
            // on its first match and nothing ever split the sentence.
            //
            // Capped at two parts on purpose. Splitting a rambling sentence into
            // five actions is worse than doing one thing well, and "fish and
            // chips" must never become two commands — which is why the split
            // only happens when BOTH halves independently look like commands.
            let parts = Self.splitCompound(cmd)
            for (i, part) in parts.enumerated() {
                if i > 0 {
                    // Let the first action finish speaking before the next.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                await route(part)
            }
            if parts.count > 1 { print("👂 [Standby] Ran \(parts.count) commands in one sentence") }
            self.busy = false
            if Date().timeIntervalSince(self.followUpOpenedAt) > Self.followUpMaxRun {
                self.followUpOpenedAt = Date()   // fresh run after a real command
            }
            // Keep the door open — he can carry on without saying the name.
            self.followUpUntil = Date().addingTimeInterval(8)
            // AUDIT FIX (HIGH — phantom repeats): the recognizer keeps ONE
            // growing transcript for its whole task. Without wiping it, the
            // words "chappy take a photo" stay in the buffer and re-fire the
            // command on the next unrelated sentence. Fresh ear after every
            // command.
            self.resetRecognition()
        }
    }

    /// Discard the accumulated transcript and listen fresh.
    private func resetRecognition() {
        guard isListening else { return }
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        _ = startRecognition()
    }

    // MARK: The router

    private func route(_ c: String) async {
        // BUILD 129: everything new lives behind one entry point. If the
        // hook doesn't recognise a command it returns false and the router
        // below runs exactly as it always has.
        if await ChappyRouterHook.intercept(c) { return }

        // ---------- SAFETY FIRST — emergency outranks everything ----------
        // AUDIT FIX (P0): "Chappy, emergency" used to fall through to a 25s
        // network call. Standby is often the ONLY thing listening (screen
        // dark, phone pocketed) — that is exactly when this must be instant.
        // AUDIT P1 (RG-SOS): bare contains("emergency") fired a REAL SOS —
        // WhatsApp to the trusted contact with a live map pin — on "is there an
        // emergency room near here" and "what's the emergency number in
        // Indonesia". Imperative shapes only; questions about emergencies are
        // not emergencies.
        let sosShapes = ["emergency", "sos", "call for help", "help me help me",
                         "i need help now", "i need an ambulance", "call an ambulance"]
        let sosAsksAboutIt = c.hasPrefix("what") || c.hasPrefix("where") || c.hasPrefix("is there")
            || c.hasPrefix("are there") || c.hasPrefix("how do") || c.contains("emergency room")
            || c.contains("emergency number") || c.contains("emergency exit")
        if !sosAsksAboutIt, sosShapes.contains(where: { c == $0 || c.hasPrefix($0 + " ") || c.hasSuffix(" " + $0) }) {
            runEmergencyFromStandby(); return
        }

        // ---------- STOPS — anchored, never greedy ----------
        // AUDIT FIX (P0): "stop navigation" was swallowed by hasPrefix("stop")
        // so navigation could never be stopped by voice; and contains("enough")
        // silenced innocent sentences like "is 500,000 rupiah enough for dinner".
        // BUILD 90: he opened Live AI and could not get out of it by voice —
        // the only exit was a button on a screen he could not see. Anything
        // that reads as "shut this down" now closes whatever module is open.
        // BUILD 122 — ONE WAY OUT, FROM ANYWHERE.
        //
        // Every module is a full-screen cover, and one notification closes all
        // of them. What was missing was a word you would actually reach for
        // without thinking — so "home", "take me back" and "I'm done" now land
        // here too. There is no wrong way to say it, and it works the same
        // from translate, Live AI, the map or a photo. That matters more than
        // it sounds: with the phone in a pocket you cannot see which screen
        // you are on, so the exit has to be the same word everywhere.
        if ["close", "close it", "exit", "go back", "done", "finish", "that's it",
            "thats it", "close live", "stop live", "close live ai", "end it",
            "shut it down", "close translate", "close this",
            "home", "go home now", "back to home", "home screen", "take me back",
            "i'm done", "im done", "all done", "we're done", "were done",
            "get out", "back out", "cancel that", "never mind that",
            "close it down", "shut this"].contains(where: { c == $0 || c.hasPrefix($0 + " ") }) {
            ChappyEarcon.shared.done()
            // NOT stop() — LiveAIManager has stopSession() (async) and
            // triggerStop() (the fire-and-forget wrapper the UI uses).
            LiveAIManager.shared.triggerStop()
            ContinuousVisionManager.shared.stop(announce: false)
            NotificationCenter.default.post(name: .chappyCloseModules, object: nil)
            speak("Done.")
            return
        }
        if c.contains("stop navigation") || c.contains("stop navigating")
            || c.contains("cancel navigation") || c.contains("stop the route") {
            NavEngine.shared.stop(); speak("Route's off."); return
        }
        if c == "stop" || c == "cancel" || c.hasPrefix("stop talking")
            || c.contains("never mind") || c.contains("cancel that")
            || c.contains("shut up") || c.contains("be quiet")
            || c.hasSuffix("that's enough") || c == "enough" || c.contains("back to standby") {
            TTSService.shared.stop(); ChappyHaptics.shared.straightStep(); return
        }
        // BUILD 136: "close maps" — kill Chappy's route and clear its map UI.
        // Honesty note: iOS does not let one app quit another, so Google Maps
        // itself stays wherever it is — but Chappy's navigation ends and the
        // slate is clean the moment you come back.
        // BUILD 170 — CHAPPY RESET. One phrase that always works, from
        // anywhere, whatever is on screen.
        //
        // Every module had its own exit — "stop navigation", "close maps",
        // "quiet mode" — and you had to remember which one applied to
        // whatever was currently misbehaving. That is exactly backwards
        // when something IS misbehaving. Every assistant worth using has a
        // single escape hatch; this is Chappy's.
        //
        // It stops the voice mid-word, ends navigation, translate, Live AI
        // and continuous vision, cancels every pending question window,
        // closes every sheet on screen, and re-arms the ear. It never
        // deletes anything — reset means "put the tools down", not
        // "forget".
        if c.contains("chappy reset") || c.contains("chappy close")
            || c.contains("close everything") || c.contains("close it all")
            || c.contains("shut it all down") || c.contains("stop everything")
            || c.contains("back to the main screen") || c.contains("back to main screen")
            || c.contains("back to home screen") || c.contains("go back to home")
            || c.contains("clear the screen") || c.contains("start over")
            || c.contains("close all") || c.contains("reset chappy")
            || c == "reset" || c == "escape" {
            resetEverything()
            return
        }
        if c.contains("close maps") || c.contains("close the maps")
            || c.contains("close google maps") || c.contains("exit maps")
            || c.contains("shut maps") {
            NavEngine.shared.stop(announce: false)
            NotificationCenter.default.post(name: Notification.Name("chappyMapsCleanup"), object: nil)
            speak("Route's off. Swipe back to me whenever you're ready.")
            return
        }

        // ---------- BUILD 136: POCKET ANSWERS, FIRST IN LINE ----------
        // "What time is it" was answering in fifteen seconds because a
        // hundred ladder branches and a paid fall-through all got a look
        // before the free tier did. Pocket only ever answers the questions
        // it is CERTAIN about — time, date, conversions, arithmetic, the
        // weather snapshot — so it is safe to run before everything else,
        // and those questions now come back Meta-fast, offline, for free.
        if let pocket = ChappyPocket.answer(c) {
            speak(pocket)
            return
        }
        // BUILD 174 — ASK THE VOICE WHAT'S WRONG WITH IT.
        //
        // "The voice isn't always Gemini" was impossible to act on because
        // nothing reported WHY. Now it will tell you: set to System, no key,
        // or in a five-minute fallback after a specific failure — named.
        if c.contains("why is the voice") || c.contains("voice status")
            || c.contains("check the voice") || c.contains("what's wrong with the voice")
            || c.contains("whats wrong with the voice") || c.contains("is the voice ok") {
            speak(TTSService.voiceStatusLine)
            return
        }
        if c.contains("reset the voice") || c.contains("fix the voice")
            || c.contains("clear the voice") {
            TTSService.geminiVoiceGaveUp = false
            TTSService.lastFallbackReason = ""
            speak("Voice reset. That should be me again.")
            return
        }
        // BUILD 173 — THE WEATHER STATION, by voice.
        //
        // Pocket still answers a bare "what's the weather" instantly from
        // the cached snapshot — that stays, because speed is the feature
        // there. These are the asks that want the real instruments.
        if c.contains("full weather") || c.contains("open weather")
            || c.contains("weather station") || c.contains("weather screen")
            || c.contains("show me the weather") || c.contains("all the weather") {
            NotificationCenter.default.post(name: .chappyOpenWeather, object: nil)
            Task { @MainActor in
                if ChappyWeather.shared.now == nil { await ChappyWeather.shared.loadHere() }
                TTSService.shared.speakLong(ChappyWeather.shared.spokenFull())
            }
            return
        }
        if c.contains("will it rain") || c.contains("is it going to rain")
            || c.contains("any rain") || c.contains("do i need an umbrella")
            || c.contains("rain today") || c.contains("rain coming") {
            Task { @MainActor in
                if ChappyWeather.shared.now == nil { await ChappyWeather.shared.loadHere() }
                TTSService.shared.speakLong(ChappyWeather.shared.spokenRain())
            }
            return
        }
        if c.contains("weather this week") || c.contains("weather for the week")
            || c.contains("forecast this week") || c.contains("week's weather")
            || c.contains("weeks weather") || c.contains("weather forecast") {
            Task { @MainActor in
                if ChappyWeather.shared.now == nil { await ChappyWeather.shared.loadHere() }
                TTSService.shared.speakLong(ChappyWeather.shared.spokenWeek())
            }
            return
        }
        // "Weather in Bali" — anywhere, not just here.
        if let r = c.range(of: "weather in ") {
            let place = String(c[r.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
            if place.count > 1 {
                TTSService.shared.speak("Looking up \(place).")
                Task { @MainActor in
                    await ChappyWeather.shared.loadPlace(place)
                    TTSService.shared.speakLong(ChappyWeather.shared.spokenNow())
                }
                return
            }
        }
        // BUILD 173 — THE BRIEF, on demand and on screen.
        if c.contains("what was my brief") || c.contains("read my brief")
            || c.contains("last brief") || c.contains("repeat the brief") {
            let last = ChappyProactive.shared.lastBrief
            speak(last.isEmpty ? "No brief yet today." : last)
            return
        }
        if c.contains("brief me now") || c.contains("brief me")
            || c.contains("give me a brief") {
            speak("Putting one together.")
            Task { await ChappyProactive.shared.runNow() }
            return
        }
        if c.contains("open briefs") || c.contains("brief settings")
            || c.contains("how is my brief") || c.contains("brief studio") {
            NotificationCenter.default.post(name: .chappyOpenBriefs, object: nil)
            speak("Here's how your briefs are built.")
            return
        }
        // BUILD 166 — "WHAT TIME IS THE BRONCOS GAME ON THIS WEEK."
        //
        // Fixing the clock is half the job. The other half is answering the
        // question that was actually asked — and being honest that Chappy
        // has no live sports, cinema or shop-hours feed. Nothing here knows
        // this week's NRL draw, and a confident guess from a model trained
        // months ago is WORSE than no answer, because you'd act on it.
        //
        // So: say what it is, put it on screen, don't pretend. Same pattern
        // as the flight-status fallback. Personal questions ("what time is
        // my flight") are handled far above this and never reach here.
        // BUILD 169: open() is called with the explicit options/completion
        // form throughout. Inside an async function the bare open(url) form
        // resolves to UIApplication's ASYNC overload, which is what "async
        // but not marked with await" was complaining about — and it only
        // shows up in the handful of call sites that happen to sit in async
        // code. Spelling it out removes the ambiguity everywhere at once.
        if Self.looksLikeEventTimeQuestion(c) {
            let q = c.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let u = URL(string: "https://www.google.com/search?q=\(q)") {
                UIApplication.shared.open(u, options: [:], completionHandler: nil)
            }
            speak("I don't have live listings for that, so it's on screen.")
            return
        }

        // ---------- TIER 3 — the computer (unambiguous openers, checked early
        // so job wording like "send the photos" can't be hijacked) ----------
        if let job = after(c, ["get the computer to", "ask my computer to", "ask my computer",
                               "have the pc", "have the computer", "computer job",
                               "get the pc to", "tell the computer to", "when the computer's on",
                               "when the computer is on"]) {
            queueComputerJob(job); return
        }

        // ---------- TIER 0 — free, instant, on the phone ----------
        // AUDIT FIX (P0): bare "photo"/"picture"/"snap" used to eat
        // "log this, snap peas are 20,000" and "take me to the photo shop".
        // Imperative shapes only.
        // BUILD 155 — BURST first, so "action shot" never falls through to
        // the single-photo matcher. Hold the Snap button does the same.
        if ["action shot", "burst shot", "burst mode", "rapid shot", "quick shots",
            "sports shot", "action photo", "burst it", "take a burst",
            "rapid fire", "motion shot"].contains(where: { c.contains($0) }) {
            ChappyBurst.shared.fire()
            return
        }
        if after(c, ["take a photo", "take a picture", "take a shot", "get a shot",
                     "snap a photo", "snap that", "snap this", "capture this",
                     "capture that", "photo quick",
                     "grab a photo", "grab a picture", "get a photo", "get a picture",
                     "take a pic", "snap a pic", "get a pic", "shoot that",
                     "shoot this", "photograph this", "photograph that"]) != nil
            || c == "photo" || c == "take photo" || c == "snap" || c == "picture" {
            // Silent by design — see snapSilently(). A tone confirms it; there
            // is nothing to say about a photo taken to look at later.
            snapSilently()
            return
        }
        if let note = after(c, ["log this", "note this", "write this down", "make a note", "jot this down"]) {
            if note.count > 2 {
                TripRecorder.shared.addObservation(note)
                ChappyHaptics.shared.straightStep()
                // AUDIT FIX (PHASE 5): this block was pasted twice, so every
                // "log this" in front of the camera stored TWO identical photos
                // — and, once memory was wired in, two identical memories.
                // You usually log something BECAUSE of what is in front of you.
                // Quietly keep the picture with the words.
                if let f = LiveAIManager.shared.streamViewModel?.currentVideoFrame {
                    TripRecorder.shared.addVisualNote(caption: note,
                                                      thumbnail: f.jpegData(compressionQuality: 0.4))
                }
                speak("Noted.")
            } else {
                speak("What should I log?")
            }
            return
        }
        if c.contains("remember this spot") || c.contains("remember here")
            || c.contains("save this place") || c.contains("pin this")
            || c.contains("mark this spot") || c.contains("this is home") {
            var name = after(c, ["call it "]) ?? ""
            if c.contains("this is home") { name = "home" }
            // If he named it in the same breath, take it. If not, ask — same
            // reasoning as the Remember button: an unnamed pin is a timestamp.
            if name.isEmpty {
                rememberSpotByVoice()
                return
            }
            let spot = TripRecorder.shared.rememberSpot(named: name)
            ChappyHaptics.shared.straightStep()
            if spot.lat == 0 {
                speak("Saved it, though GPS hasn't settled - it may be a little off.")
            } else {
                // BUILD 144 earcon diet: the spoken line IS the confirmation
                speak("Saved \(spot.name).")
            }
            return
        }
        if c.contains("what did i photograph") || c.contains("what did i snap")
            || c.contains("what photos") {
            let today = TripRecorder.shared.todaysVisualNotes()
            guard !today.isEmpty else { speak("Nothing photographed today."); return }
            let list = today.suffix(6).map { $0.caption }.joined(separator: ", ")
            speak("\(today.count) today. \(list).")
            return
        }
        // BUILD 121 — RESTARTING A PAUSED TRANSLATE SESSION BY VOICE.
        // With the translate mic stopped, Standby holds the ear again — so
        // this is where "start" has to land. Sits above everything, because
        // while that screen is open a bare "start" can only mean one thing.
        if LiveTranslateIsOpen,
           ["start", "go", "start again", "carry on", "resume", "keep going",
            "start listening", "start translating", "unpause", "listen"]
            .contains(where: { c == $0 || c.hasPrefix($0 + " ") }) {
            ChappyEarcon.shared.done()
            handOff()
            NotificationCenter.default.post(name: .chappyResumeTranslate, object: nil)
            return
        }

        // ---------- PHASE 5.5 — REMINDERS (free, offline, instant) ----------
        if Self.looksLikeReminder(c), let p = Self.parseReminder(c) {
            let r = ChappyReminders.shared.add(
                title: p.title, at: p.date, floatingTime: p.floating,
                place: p.place, repeatRule: p.rule, leadMinutes: p.lead,
                escalate: p.escalate,
                thumbnail: LiveAIManager.shared.streamViewModel?.currentVideoFrame?
                    .jpegData(compressionQuality: 0.4))
            // BUILD 144 earcon diet: the spoken line IS the confirmation
            // A FIVE-WORD TAIL, not a readback. Confirmation fatigue is why
            // people stop using reminders; silence is acceptance.
            speak("\(r.title). \(p.confirmation)")
            return
        }
        if c.contains("what's on today") || c.contains("whats on today")
            || c.contains("what's due") || c.contains("whats due")
            || c.contains("my reminders") || c.contains("what reminders")
            || c.contains("what have i got on") || c.contains("what's on my list")
            || c.contains("whats on my list") || c.contains("read my list")
            || c.contains("anything due") || c.contains("what's coming up")
            || c.contains("whats coming up") {
            speak(ChappyReminders.shared.spokenList()); return
        }
        if c.contains("what's my day") || c.contains("whats my day")
            || c.contains("morning brief") || c.contains("brief me")
            || c.contains("how's my day") || c.contains("hows my day") {
            speak(ChappyReminders.shared.briefText()); return
        }
        // Ticking one off by name — fuzzy, because you never say it the same
        // way twice. Matches the closest open reminder.
        if let what = after(c, ["mark done", "tick off", "i've done", "ive done",
                                "that's done", "thats done", "done with",
                                "finished with", "cross off", "completed"]) {
            let target = ChappyReminders.shared.open.first {
                $0.title.lowercased().contains(what) || what.contains($0.title.lowercased())
            }
            if let t = target {
                ChappyReminders.shared.complete(t.id)
                // BUILD 144 earcon diet: the spoken line IS the confirmation
                speak("Done: \(t.title).")
            } else {
                speak("I don't have a reminder like that.")
            }
            return
        }
        // SEMANTIC SNOOZE — the same grammar as creating one. "Snooze until I
        // get home" works; nobody else on the market can do that.
        if c.hasPrefix("snooze") || c.contains("remind me again")
            || c.contains("not now") || c.contains("later") && c.count < 22 {
            guard let last = ChappyReminders.shared.due().first
                    ?? ChappyReminders.shared.overdue().first else {
                speak("Nothing to snooze."); return
            }
            if let place = after(c, ["until i'm at ", "until im at ", "when i get to ",
                                     "until i get to ", "until i'm home", "until im home"]) {
                ChappyReminders.shared.snooze(last.id, place: place.isEmpty ? "home" : place)
                speak("I'll say it again there.")
            } else if let mins = Self.snoozeMinutes(in: c) {
                ChappyReminders.shared.snooze(last.id, minutes: mins)
                speak("\(mins) minutes.")
            } else {
                ChappyReminders.shared.snooze(last.id, minutes: 10)
                speak("Ten minutes.")
            }
            return
        }
        // BUILD 135: bare "reminders" used to fall through to the either/or
        // prompt ("find you one nearby, or tell you about it?") — the single
        // most obvious word for the feature didn't open the feature.
        if c == "reminders" || c == "reminder" || c == "my reminders"
            || c.contains("open reminders") || c.contains("show my reminders")
            || c.contains("show reminders") || c.contains("open my list")
            || c.contains("what are my reminders") || c.contains("check my reminders") {
            NotificationCenter.default.post(name: .chappyOpenReminders, object: nil)
            // BUILD 144 earcon diet: the spoken line IS the confirmation
            // Say something USEFUL while the screen opens — the brief head.
            let facts = Self.greetingFacts(max: 2)
            speak(facts.isEmpty ? "Here's your list. Nothing due." : "Here's your list. " + facts.joined(separator: " "))
            return
        }
        // BUILD 140 — "PLAN MY DAY." Chappy reads the diary and sets the
        // reminders you'd have set yourself: a get-ready nudge per
        // appointment, a time for anything that has none. One sentence in,
        // a planned day out — every one of them editable in the Diary after.
        if c.contains("plan my day") || c.contains("suggest reminders")
            || c.contains("set up my day") || c.contains("organise my day")
            || c.contains("organize my day") {
            let sugg = ChappyReminders.shared.suggestions()
            guard !sugg.isEmpty else {
                speak("The day's already covered — nothing worth adding."); return
            }
            let df = DateFormatter(); df.dateFormat = "h:mm a"
            for s in sugg.prefix(3) { _ = ChappyDataBridge.addReminder(text: s.title, at: s.fire) }
            let lines = sugg.prefix(3).map { "\($0.title) at \(df.string(from: $0.fire))" }
                .joined(separator: ". ")
            speak("Done. \(lines). They're in the diary — kill any you don't want.")
            return
        }
        // BUILD 150 — FLIGHTS. Deal watching and travel-day tracking.
        if c.contains("watch flights to") || c.contains("watch flight prices")
            || c.contains("track flights to") {
            var dest = c
            for cut in ["watch flights to", "track flights to", "watch flight prices to"] {
                if let r = dest.range(of: cut) { dest = String(dest[r.upperBound...]); break }
            }
            let month = ChappyFlights.monthKey(from: dest)
                ?? ChappyFlights.monthKey(from: "in " + String(Calendar.current.component(.month, from: Date())))
            for (name, _) in [("january",1),("february",2),("march",3),("april",4),("may",5),("june",6),
                              ("july",7),("august",8),("september",9),("october",10),("november",11),("december",12)] {
                dest = dest.replacingOccurrences(of: " in \(name)", with: "")
                dest = dest.replacingOccurrences(of: name, with: "")
            }
            dest = dest.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            guard !dest.isEmpty else { speak("Watch flights to where?"); return }
            speak("Setting that up.")
            let m = month ?? "any"
            Task { @MainActor in
                TTSService.shared.speak(await ChappyFlights.shared.addWatch(destName: dest, month: m == "any" ? "" : m))
            }
            return
        }
        if c.contains("flight deals") || c.contains("any deals on flights")
            || c.contains("cheapest flights") || c.contains("how are my flights looking") {
            speak(ChappyFlights.shared.spokenDeals()); return
        }
        if c.contains("track flight ") || c.contains("track my flight ") {
            guard let num = ChappyFlights.flightNumber(in: c) else {
                speak("Which flight? Give me the number, like Q F five two."); return
            }
            let day = ChappyTrail.dayMentioned(in: c) ?? Date()
            speak(ChappyFlights.shared.track(number: num, date: day))
            return
        }
        if c.contains("how's my flight") || c.contains("hows my flight")
            || c.contains("flight status") || c.contains("is my flight on time")
            || c.contains("when's my flight") || c.contains("whens my flight")
            || c.contains("what gate") || c.contains("which gate")
            || c.contains("is the flight delayed") || c.contains("my flight delayed")
            || c.contains("check my flight") || c.contains("flight update") {
            speak(ChappyFlights.shared.statusHandoff()); return
        }
        // BUILD 153 — RIDE & FOOD. The Google-Maps pattern: Chappy prices
        // and ETAs the trip itself, then hands to Grab/Uber with the
        // drop-off pre-filled. One tap, one thumbprint, done.
        if ChappyRide.shared.consumeConfirm(c) { return }
        if c.contains("get me a grab") || c.contains("book a grab") || c.contains("grab to ")
            || c.contains("get me an uber") || c.contains("book an uber") || c.contains("uber to ")
            || c.contains("get me a ride") || c.contains("book a ride")
            || c.contains("get me a gojek") || c.contains("book a gojek")
            || c.contains("grab home") || c.contains("uber home") || c.contains("ride home")
            || c.contains("how much is a grab") || c.contains("how much is an uber")
            || c.contains("how much is a ride")
            || c.contains("call me a grab") || c.contains("call me an uber")
            || c.contains("get us a grab") || c.contains("get us an uber")
            || c.contains("order a grab") || c.contains("order an uber")
            || c.contains("grab me a ride") || c.contains("need a ride")
            || c.contains("call a taxi") || c.contains("get a taxi") {
            // "make it a Gojek" in the moment: a named provider wins from here on.
            if c.contains("gojek") { UserDefaults.standard.set("gojek", forKey: "chappy_ride_provider") }
            else if c.contains("uber") { UserDefaults.standard.set("uber", forKey: "chappy_ride_provider") }
            else if c.contains("grab") { UserDefaults.standard.set("grab", forKey: "chappy_ride_provider") }
            var dest = ""
            if let r = c.range(of: " to ", options: .backwards) { dest = String(c[r.upperBound...]) }
            if dest.isEmpty, c.contains("home") { dest = "home" }
            // Flight day: a bare "get me a Grab" means the airport, right terminal.
            if dest.isEmpty, let ap = ChappyFlights.shared.airportNavQuery() { dest = ap }
            guard !dest.isEmpty else {
                speak("Where to? Say: get me a \(ChappyRide.shared.provider.display) to the airport.")
                return
            }
            speak("Pricing it.")
            Task { @MainActor in
                TTSService.shared.speak(await ChappyRide.shared.quote(to: dest))
            }
            return
        }
        if c.contains("order food") || c.contains("get food") || c.contains("food delivery")
            || c.contains("uber eats") || c.contains("grab food") || c.contains("go food")
            || c.contains("order from ") || c.contains("i'm hungry") || c.contains("im hungry")
            || c.contains("order the usual") || c.contains("order dinner") || c.contains("order lunch")
            || c.contains("feed me") || c.contains("get dinner") || c.contains("get lunch")
            || c.contains("get takeaway") || c.contains("order takeaway")
            || c.contains("get some food") || c.contains("order some food") {
            speak(ChappyRide.shared.foodHandoff(from: c))
            return
        }
        // BUILD 153 — "SPENT 200" / "I spent 45 on lunch". Fares and food
        // land in memory as spend entries; the ride arrival prompt promises
        // this, so it has to be real. ("Spent today" stays the cost check.)
        if (c.hasPrefix("spent ") || c.contains("i spent ") || c.contains("i just spent ")),
           !c.contains("spent today"), !c.contains("have i spent") {
            let amount = c.split(separator: " ")
                .compactMap { Double($0.filter { "0123456789.".contains($0) }) }
                .first
            guard let amt = amount, amt > 0 else {
                speak("Spent how much? Say: spent 30 on lunch."); return
            }
            var what = ""
            if let r = c.range(of: " on ") {
                what = String(c[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
            }
            let amtText = amt == amt.rounded() ? String(Int(amt)) : String(format: "%.2f", amt)
            _ = ChappyMemory.shared.remember(.spend,
                title: what.isEmpty ? "Spent \(amtText)" : "\(amtText) on \(what)",
                tags: ["spend"], source: "voice")
            speak("Logged - \(amtText)\(what.isEmpty ? "" : " on \(what)").")
            return
        }
        // BUILD 147 — CLIP. Video, summarised: "record a clip" rolls ~20s of
        // frames and files the story of what happened.
        if c.contains("record a clip") || c.contains("record this") || c.contains("take a video")
            || c.contains("record a video") || c.contains("watch this and remember")
            || c.contains("film this") || c.contains("video this") || c.contains("take a clip")
            || c.contains("start recording") || c.contains("roll camera")
            || c.contains("get this on video") || c.contains("shoot a video")
            || c.contains("capture a clip") || c.contains("record that") {
            speak("Rolling - about twenty seconds.")
            ChappyClip.shared.record()
            return
        }
        if c.contains("what did i just see") || c.contains("what just happened") {
            speak("Quick look back.")
            ChappyClip.shared.record(seconds: 8)
            return
        }
        // BUILD 147 — MAIL AND MESSAGES. One inbox, two kinds of message:
        // email, and SMS arriving through the TelTel gateway.
        if c.contains("check my email") || c.contains("check my mail") || c.contains("check my inbox")
            || c.contains("any new email") || c.contains("any emails") || c.contains("any new mail") {
            speak("Having a look.")
            Task { @MainActor in TTSService.shared.speak(await ChappyMail.shared.check()) }
            return
        }
        if c.contains("any texts") || c.contains("check my texts") || c.contains("any messages")
            || c.contains("any new texts") || c.contains("check my messages") {
            speak("Checking.")
            Task { @MainActor in
                _ = await ChappyMail.shared.check()
                let texts = ChappyMail.shared.unread.filter { $0.isText }
                if texts.isEmpty { TTSService.shared.speak("No new texts.") }
                else { TTSService.shared.speak(ChappyMail.shared.read(index: 0, textsOnly: true)) }
            }
            return
        }
        if c.contains("read the first text") || c.contains("read my texts") {
            speak(ChappyMail.shared.read(index: 0, textsOnly: true)); return
        }
        if c.contains("read the first one") || c.contains("read the first message")
            || c.contains("read message one") {
            speak(ChappyMail.shared.read(index: 0, textsOnly: false)); return
        }
        if c.contains("read the second one") || c.contains("read message two") {
            speak(ChappyMail.shared.read(index: 1, textsOnly: false)); return
        }
        if c.contains("read the third one") || c.contains("read message three") {
            speak(ChappyMail.shared.read(index: 2, textsOnly: false)); return
        }
        if c.hasPrefix("reply") && (c.contains("saying") || c.contains("that ")) {
            var body = c
            for cut in ["reply to that saying", "reply saying", "reply that", "reply with"] {
                if let r = body.range(of: cut) { body = String(body[r.upperBound...]); break }
            }
            body = body.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            guard !body.isEmpty else { speak("Reply saying what?"); return }
            speak(ChappyMail.shared.replyToLast(saying: body))
            return
        }
        // BUILD 146 — SCAM GUARD. "Is this a scam" with the story in the same
        // breath answers instantly; bare "scam check" opens the ear for it.
        if c.contains("scam") || c.contains("is this a con") || c.contains("being conned")
            || c.contains("rip off or") || c.contains("does this sound dodgy") {
            let tail = c.replacingOccurrences(of: "scam check", with: "")
                .replacingOccurrences(of: "is this a scam", with: "")
                .replacingOccurrences(of: "is that a scam", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            if tail.split(separator: " ").count >= 4 {
                if let v = ChappyScamGuard.verdict(for: tail) { speak(v); return }
                await quickAsk("SCAM CHECK - judge this situation for scam red flags in two short spoken sentences, be direct about risk: \(tail)")
                return
            }
            expectingScamUntil = Date().addingTimeInterval(30)
            if !isListening { silentArm = true; start() }
            speak("Tell me what's happening - who's asking for what?")
            return
        }
        // BUILD 139 — VOICE SELF-TEST. "All the voices sound the same" means
        // Gemini renders are failing; this one command says WHY, out loud.
        if c.contains("test the voice") || c.contains("voice test")
            || c.contains("test your voice") || c.contains("why do you sound like a robot")
            || c.contains("fix your voice") {
            TTSService.shared.runVoiceSelfTest()
            return
        }
        // BUILD 135 — NOTIFICATION SELF-TEST. "Why aren't notifications
        // showing?" now has an answer you can get by asking. Reads the REAL
        // authorization state and, if allowed, fires a test banner in 5s.
        if c.contains("test notification") || c.contains("notification test")
            || c.contains("check notifications") || c.contains("test my notifications")
            // BUILD 170 — the ways people actually ask.
            || c.contains("are my notifications on") || c.contains("notification status")
            || c.contains("are notifications working") || c.contains("check my notifications")
            || c.contains("why aren't i getting notifications")
            || c.contains("why am i not getting notifications")
            || c.contains("notification doctor") || c.contains("fix my notifications") {
            // BUILD 172: put the full picture on screen as well as saying it —
            // the pending queue is the part you have to SEE.
            NotificationCenter.default.post(name: .chappyOpenNotifDoctor, object: nil)
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                DispatchQueue.main.async {
                    switch settings.authorizationStatus {
                    case .denied:
                        TTSService.shared.speak("Notifications are switched OFF for Chappy in iPhone Settings. Open Settings, find Chappy, tap Notifications, and turn Allow Notifications on. That's why nothing has been popping up.")
                    case .notDetermined:
                        TTSService.shared.speak("iOS hasn't been asked yet — asking now. Tap Allow.")
                        UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
                    default:
                        var extras: [String] = []
                        if settings.alertSetting != .enabled { extras.append("banners are off") }
                        if settings.soundSetting != .enabled { extras.append("sound is off") }
                        // BUILD 170 — THE TWO SETTINGS THAT SWALLOW EVERYTHING
                        // AND NOBODY THINKS OF.
                        //
                        // Scheduled Summary holds notifications back and
                        // delivers them in a batch at set times — so they
                        // "never arrive", they arrive at 6pm in a pile. And
                        // without Time Sensitive permission, a Focus mode
                        // eats warn-times silently. Both look identical to
                        // "notifications are broken" from the outside.
                        if settings.scheduledDeliverySetting == .enabled {
                            extras.append("Scheduled Summary is ON, which holds your notifications back and delivers them in a batch - that alone would explain missing pings. Turn it off under Settings, Notifications, Scheduled Summary")
                        }
                        if settings.timeSensitiveSetting == .disabled {
                            extras.append("Time Sensitive is off, so a Focus mode will silence warn-times")
                        }
                        if settings.lockScreenSetting != .enabled {
                            extras.append("lock screen notifications are off")
                        }
                        let content = UNMutableNotificationContent()
                        content.title = "Chappy test"
                        content.body = "Notifications are working."
                        content.sound = .default
                        content.userInfo = ["chappy_timer": true]
                        let req = UNNotificationRequest(
                            identifier: "chappy-test-\(Int(Date().timeIntervalSince1970))",
                            content: content,
                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
                        UNUserNotificationCenter.current().add(req)
                        TTSService.shared.speak(extras.isEmpty
                            ? "Allowed. Test banner in five seconds — watch the top of the screen."
                            : "Allowed, but \(extras.joined(separator: " and ")) in iPhone Settings. Test banner in five seconds anyway.")
                    }
                }
            }
            return
        }

        // ---------- PHASE 5 — MEMORY RECALL (free, offline, instant) ----------
        // Sits ABOVE the journal answers on purpose: "what do you remember
        // about the warung" is a memory question, and the journal only knows
        // about today.
        if let subject = after(c, ["what do you remember about", "what do you know about",
                                   "do you remember", "remind me about",
                                   "search my memory for", "search memory for",
                                   "look up in memory", "find in my memory",
                                   "when did i see", "when did we see",
                                   "have i been to", "where did i see"]) {
            // "do you remember" on its own is a question, not a search.
            // Without this, an empty subject matches EVERY memory and Chappy
            // reads four random things back at you.
            guard subject.trimmingCharacters(in: .whitespaces).count > 2 else {
                speak("Remember what?"); return
            }
            if let answer = ChappyMemory.shared.spokenRecall(subject) {
                // BUILD 144 earcon diet: the spoken line IS the confirmation
                speak(answer)
            } else {
                speak("Nothing stored about \(subject) yet.")
            }
            return
        }
        if c.contains("open memory") || c.contains("open my memory")
            || c.contains("show my memories") || c.contains("show me my memories")
            || c.contains("open the memory") || c.contains("memory browser")
            || c.contains("show my memory") {
            NotificationCenter.default.post(name: .chappyOpenMemory, object: nil)
            // BUILD 144 earcon diet: the spoken line IS the confirmation
            speak("Memory's open."); return
        }
        if c.contains("import from the glasses") || c.contains("import my photos")
            || c.contains("check the glasses") || c.contains("import from glasses")
            || c.contains("get my photos") || c.contains("import photos") {
            speak("Checking what the glasses have.")
            Task { await ChappyIngest.shared.run(manual: true) }
            return
        }
        if c.contains("read my old conversations") || c.contains("go through my records")
            || c.contains("read through records") || c.contains("catch up on records") {
            speak("Reading through them now.")
            Task { await ChappyMemory.shared.runFactExtraction(manual: true) }
            return
        }
        if c.contains("how many memories") || c.contains("what have you stored")
            || c.contains("how much do you remember") {
            let n = ChappyMemory.shared.recent.count
            speak(n == 0 ? "Nothing stored yet."
                         : "\(n) memories in the last month, all searchable."); return
        }
        // BUILD 146 — THE JOURNAL, SPOKEN. "Read my journal" / "tell me about
        // my day" narrates the day as a story: the stops from the Trail, the
        // moments from Memory, woven in time order. Free — it reads what the
        // phone already knows.
        if c.contains("read my journal") || c.contains("tell me about my day")
            || c.contains("my day story") || c.contains("story of my day")
            || c.contains("journal for") {
            let day = ChappyTrail.dayMentioned(in: c) ?? Date()
            let visits = ChappyTrail.shared.visits(for: day).sorted { $0.arrive < $1.arrive }
            let mems = ChappyMemory.shared.recent
                .filter { Calendar.current.isDate($0.at, inSameDayAs: day) && $0.source != "pulse" }
                .sorted { $0.at < $1.at }
            guard !visits.isEmpty || !mems.isEmpty else {
                speak("Nothing in the journal for that day yet."); return
            }
            let tf = DateFormatter(); tf.dateFormat = "h:mm a"
            var beats: [(Date, String)] = []
            for v in visits {
                beats.append((v.arrive, "\(v.name ?? "a stop"), \(v.spokenWindow)"))
            }
            for m in mems.prefix(6) {
                let verb: String
                switch m.kind {
                case .photo: verb = "photographed"
                case .scan: verb = "scanned"
                case .spend: verb = "spent on"
                case .place: verb = "starred"
                default: verb = "noted"
                }
                beats.append((m.at, "\(tf.string(from: m.at)), \(verb) \(m.title)"))
            }
            let story = beats.sorted { $0.0 < $1.0 }.prefix(9).map { $0.1 }.joined(separator: ". ")
            speak("Your day: \(story).")
            return
        }
        // BUILD 144 — THE WEEK, SPOKEN. "What's on next week / this week /
        // the week ahead" reads the diary forward, grouped by day.
        if (c.contains("next week") || c.contains("this week") || c.contains("week ahead")),
           c.contains("what") || c.contains("diary") || c.contains("calendar")
            || c.contains("on ") || c.contains("coming") {
            let events = ChappyCalendar.shared.upcoming(days: 7).filter { !$0.isAllDay }
            guard !events.isEmpty else { speak("Nothing in the diary for the week ahead."); return }
            let df = DateFormatter(); df.dateFormat = "EEEE"
            let tf = DateFormatter(); tf.dateFormat = "h:mm a"
            let lines = events.prefix(6).compactMap { e -> String? in
                guard let s = e.startDate else { return nil }
                let day = Calendar.current.isDateInToday(s) ? "Today"
                    : (Calendar.current.isDateInTomorrow(s) ? "Tomorrow" : df.string(from: s))
                return "\(day), \(e.title ?? "something") at \(tf.string(from: s))"
            }
            let more = events.count > 6 ? " And \(events.count - 6) more." : ""
            speak("The week ahead: \(lines.joined(separator: ". ")).\(more)")
            return
        }
        if c.contains("where was i") || c.contains("where have i been")
            || c.contains("what did i do today") || c.contains("where did i go") {
            // BUILD 138: a named day goes to the Trail — "where was I on
            // Tuesday" is a history question, and the Trail holds the history.
            if let day = ChappyTrail.dayMentioned(in: c),
               !Calendar.current.isDateInToday(day) {
                speak(ChappyTrail.shared.spokenSummary(for: day)); return
            }
            // Today: the Trail's visit list beats the old crumb summary when
            // it has something; otherwise fall back to what always worked.
            if !ChappyTrail.shared.todayVisits.isEmpty {
                speak(ChappyTrail.shared.spokenSummary(for: Date())); return
            }
            speak(TripRecorder.shared.todaySummary()); return
        }
        if c.contains("trace my steps") || c.contains("retrace") || c.contains("way i came") {
            speak(TripRecorder.shared.retraceGuidance()); return
        }
        if c.contains("i'm lost") || c.contains("im lost") || c.contains("i am lost") {
            speak(TripRecorder.shared.lostReport()); return
        }
        // BUILD 164 — STAR IT, BY VOICE. Works on subscribed calendars too,
        // because the star is Chappy's own overlay, not a calendar edit.
        if c.contains("star that") || c.contains("star this") || c.contains("star it")
            || c.contains("make that important") || c.contains("make this important")
            || c.contains("that's important") || c.contains("thats important")
            || c.contains("flag that") || c.contains("prioritise that")
            || c.contains("prioritize that") {
            guard let e = ChappyCalendar.shared.focusEvent() else {
                speak("Nothing on right now to star."); return
            }
            ChappyCalendar.shared.setStarred(true, for: e)
            speak("Starred \(e.title ?? "it"). It'll lead the brief.")
            return
        }
        if c.contains("unstar") || c.contains("not important")
            || c.contains("remove the star") {
            guard let e = ChappyCalendar.shared.focusEvent() else {
                speak("Nothing starred right now."); return
            }
            ChappyCalendar.shared.setStarred(false, for: e)
            speak("Star off."); return
        }
        // BUILD 164 — MAKE AN APPOINTMENT BY VOICE.
        if c.contains("add an appointment") || c.contains("add appointment")
            || c.contains("new appointment") || c.contains("put in my calendar")
            || c.contains("put it in my calendar") || c.contains("add to my calendar")
            || c.contains("book an appointment") || c.contains("add a meeting")
            || c.contains("new event") || c.contains("add an event") {
            guard ChappyCalendar.shared.canCreate else {
                speak("I can't write to your calendar yet — check Chappy has calendar access in iOS Settings.")
                return
            }
            // Reuse the reminder time parser — it is the battle-tested one
            // that already handles "Friday at three" and "tomorrow morning".
            // It needs an opener to bite, so we lend it one.
            let stripped = ["add an appointment", "add appointment", "new appointment",
                            "put it in my calendar", "put in my calendar",
                            "add to my calendar", "book an appointment",
                            "add a meeting", "add an event", "new event"]
                .reduce(c) { $0.replacingOccurrences(of: $1, with: " ") }
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            guard let parsed = ChappyStandby.parseReminder("remind me to " + stripped),
                  let when = parsed.date else {
                speak("When? Say: add an appointment Friday at three, dentist.")
                return
            }
            let title = parsed.title.isEmpty ? "Appointment" : parsed.title
            if let problem = ChappyCalendar.shared.createEvent(title: title, start: when) {
                speak("Couldn't add it: \(problem)")
                return
            }
            let df = DateFormatter(); df.dateFormat = "EEEE h:mm a"
            speak("Added. \(title), \(df.string(from: when)).")
            return
        }
        // BUILD 163 — UPCOMING. "What's my week" had no answer in the app.
        if c.contains("what's coming up") || c.contains("whats coming up")
            || c.contains("my calendar") || c.contains("open calendar")
            || c.contains("show my calendar") || c.contains("upcoming")
            || c.contains("what's my week") || c.contains("whats my week")
            || c.contains("my appointments") || c.contains("my schedule")
            || c.contains("what's on this month") || c.contains("show my diary") {
            NotificationCenter.default.post(name: .chappyOpenUpcoming, object: nil)
            let n = ChappyCalendar.shared.upcoming(days: 30).count
            speak(n == 0
                  ? "Nothing in the diary for the next month. Check which calendars are switched on."
                  : "\(n) thing\(n == 1 ? "" : "s") in the next month. Here they are.")
            return
        }
        // BUILD 158 — PLACES. The saved-spot list, finally reachable.
        if c.contains("my places") || c.contains("show my places")
            || c.contains("saved places") || c.contains("saved spots")
            || c.contains("my spots") || c.contains("list my places")
            || c.contains("open places") {
            NotificationCenter.default.post(name: .chappyOpenPlaces, object: nil)
            let n = TripRecorder.shared.spots.count
            speak(n == 0 ? "No places saved yet. Say: remember this spot, call it the blue warung."
                          : "\(n) place\(n == 1 ? "" : "s") saved.")
            return
        }
        // BUILD 157 — DICTATE. "Take a report" and Chappy opens the mic,
        // transcribes, then writes it up properly.
        if c.contains("take a report") || c.contains("dictate") || c.contains("write this up")
            || c.contains("take a note for work") || c.contains("job report")
            || c.contains("start a report") || c.contains("write a report")
            || c.contains("take dictation")
            // BUILD 167 — straight into an email.
            || c.contains("dictate an email") || c.contains("write an email")
            || c.contains("compose an email") || c.contains("draft an email")
            || c.contains("send an email") {
            var tone = "professional"
            if c.contains("job report") || c.contains("work report") { tone = "jobReport" }
            else if c.contains("email") || c.contains("e-mail") { tone = "email" }
            else if c.contains("bullet") { tone = "bullets" }
            ChappyDictate.shared.tone = ChappyDictate.Tone(rawValue: tone) ?? .professional
            NotificationCenter.default.post(name: .chappyOpenDictate, object: nil)
            speak("Go ahead - I'm listening.")
            return
        }
        // BUILD 156 — THE ATLAS, hands free. Checked BEFORE the day map so
        // "open the atlas" and "zoom to Ubud" never fall into today's trail.
        if c.contains("atlas") || c.contains("travel map")
            || c.contains("where have i been") || c.contains("everywhere i've been")
            || c.contains("everywhere i have been") || c.contains("my trips") {
            var payload: [String: Any] = [:]
            if let t = ChappyAtlas.voiceTarget(in: c) { payload["target"] = t }
            if let l = ChappyAtlas.layerMentioned(in: c) { payload["layer"] = l.rawValue }
            NotificationCenter.default.post(name: .chappyOpenAtlas, object: nil, userInfo: payload)
            let sum = ChappyAtlas.shared.summary
            speak(sum.isEmpty ? "Opening the atlas." : "Opening the atlas. \(sum).")
            return
        }
        // "Zoom to Ubud", "fly to Bali" — the atlas takes the wheel.
        if (c.contains("zoom to ") || c.contains("zoom in on ")
            || c.hasPrefix("fly to ") || c.contains("centre on ") || c.contains("center on ")),
           let t = ChappyAtlas.voiceTarget(in: c) {
            NotificationCenter.default.post(name: .chappyOpenAtlas, object: nil,
                                            userInfo: ["target": t])
            speak("Flying to \(t)."); return
        }
        // Deliberately NARROW: "find me a restaurant" must still navigate, so
        // only browse-shaped phrasings open a map layer.
        if (c.hasPrefix("show me ") || c.contains("what's around") || c.contains("whats around")
            || c.contains("around here") || c.contains("on the atlas")),
           !c.contains("take me"), !c.contains("navigate"), !c.contains("drive me"),
           let l = ChappyAtlas.layerMentioned(in: c) {
            NotificationCenter.default.post(name: .chappyOpenAtlas, object: nil,
                                            userInfo: ["layer": l.rawValue])
            speak("\(l.label) on the map."); return
        }
        // AUDIT P1 (RG-MAP): "where am I on the map" was swallowed here by the
        // broader "where am i" test and the map never opened. The map branch
        // lives further down, so catch the map wording first.
        if c.contains("on the map") || c.contains("show the map") || c.contains("show my trail")
            || c.contains("show map") || c.contains("open the map") {
            NotificationCenter.default.post(name: .chappyShowMap, object: nil)
            speak("Map's up."); return
        }
        if c.contains("where am i") || c.contains("what street") {
            speak(ContextEngine.shared.contextHeader()); return
        }
        if c.contains("coordinates") || c.contains("gps position") || c.contains("exact location") {
            let s = ContextEngine.shared.snapshot
            if let la = s.latitude, let lo = s.longitude {
                speak(String(format: "Latitude %.5f, longitude %.5f.", la, lo))
            } else { speak("No GPS fix yet.") }
            return
        }
        // AUDIT FIX (P0): bare "battery" hijacked "navigate me to the battery
        // store" and "get the computer to find a battery for the drone".
        if c.contains("battery check") || c.contains("battery level")
            || c.contains("battery status") || c.contains("how's the battery")
            || c.contains("hows the battery") || c == "battery" {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let l = UIDevice.current.batteryLevel
            speak(l >= 0 ? "Phone battery \(Int(l * 100)) percent." : "Battery level unknown."); return
        }
        if c.contains("cost check") || c.contains("spent today") || c.contains("usage today")
            || c.contains("usage check") || c.contains("how much have i spent")
            || c.contains("what have i spent") {
            let t = CostMeter.shared.today()
            speak(String(format: "About %.2f dollars today, %.2f this month.", t.4, CostMeter.shared.monthCostUSD()))
            return
        }
        // THE COACH — "what can I say?" answers for the moment you're IN,
        // never a 60-item menu (voice can't be scanned).
        // SIM FIX: "help me talk to her" (19 chars) hit the coach while
        // "help me talk to them" (20) hit translate — one character decided.
        if c.contains("what can i say") || c.contains("what can you do")
            || c.contains("commands")
            // AUDIT P1 (RG-COACH): a length test decided this — "help me talk to
            // her" (19) hit the coach, "help me talk to them" (20) didn't. Any
            // "help me <verb>" is a real request, not a plea for the menu.
            || (c == "help me" || c == "help") {
            speak(coachLine()); return
        }
        if c.contains("quiet mode") { UserDefaults.standard.set("quiet", forKey: "chappy_mode"); speak("Quiet mode."); return }
        if c.contains("tour mode") { UserDefaults.standard.set("tour", forKey: "chappy_mode"); speak("Tour mode."); return }
        if c.contains("budget mode") { UserDefaults.standard.set("budget", forKey: "chappy_mode"); speak("Budget mode on."); return }
        if c.contains("normal mode") { UserDefaults.standard.set("normal", forKey: "chappy_mode"); speak("Back to normal."); return }
        // AUDIT FIX (coverage gap): the map was promised in the grammar and
        // had no handler at all. Must sit ABOVE "where am i".
        if c.contains("show the map") || c.contains("show my trail") || c.contains("show map")
            || c.contains("open the map") || c.contains("where am i on the map") {
            NotificationCenter.default.post(name: .chappyShowMap, object: nil)
            speak("Map's up."); return
        }
        // AUDIT FIX (coverage gap): alert_when_near existed as a Live AI tool
        // but Standby couldn't reach it.
        if let place = after(c, ["alert me when we're near a", "alert me when we're near",
                                 "alert me when i'm near a", "alert me when im near a",
                                 "alert me when we pass a", "tell me when you see a",
                                 "tell me when we're near a"]) {
            speak("Watching for \(place).")
            let reply = await NavEngine.shared.alertWhenNear(place)
            speak(reply); return
        }

        // ---------- TIER 3 — the computer (checked early: explicit opener) ----------
        if let job = after(c, ["get the computer to", "ask my computer to", "ask my computer",
                               "have the pc", "have the computer", "computer job",
                               "get the pc to", "tell the computer to"]) {
            queueComputerJob(job); return
        }

        // ---------- TIER 2 — live sessions ----------
        // BUILD 162 — "OPEN LIVE AI" WASN'T A COMMAND. The triggers were
        // "let's talk", "start live", "eyes on" — and the single most obvious
        // phrasing, the name of the thing, was missing. So it fell through
        // every branch and landed on whatever matched loosely further down,
        // which is how asking for Live AI opened Maps.
        if c.contains("let's talk") || c.contains("lets talk") || c.contains("start live")
            || c.contains("eyes on") || c.contains("come with me") || c.contains("watch with me")
            || c.contains("live ai") || c.contains("live a i") || c.contains("liveai")
            || c.contains("open talk") || c.contains("start talk") || c.contains("talk mode")
            || c.contains("open live") || c.contains("live mode") {
            speak("Opening Live AI.")
            handOff() // AUDIT FIX: ear remembers to come back
            NotificationCenter.default.post(name: .liveAITriggered, object: nil)
            return
        }
        // TRANSLATE — country-aware, auto-detecting, auto-starting.
        // "translate" alone picks the local language from where you ARE
        // (Indonesia → Indonesian); "translate to Thai" pins it explicitly.
        // English is always your home side; the engine detects which side is
        // speaking, so one command covers both directions.
        // AUDIT FIX: "translate this" is a Tier 1 ONE-LOOK (read the sign and
        // translate it) — it used to launch the whole metered session.
        if c.contains("translate this") || c.contains("translate that")
            || c.contains("translate the sign") || c.contains("translate the menu") {
            speak("Let me read it.")
            QuickVisionManager.shared.triggerQuickVision(customPrompt:
                "Read the text in this image and translate it into English. Say the original briefly, then the translation. Two short spoken sentences.")
            return
        }
        // "Switch to Thai", "change the language to German", "make it Spanish"
        // — a language change, not a new session. If translate is already open
        // this retargets it; if not, it starts there.
        if ["switch to", "change to", "change the language", "make it", "now in",
            "put it in", "swap to"].contains(where: { c.contains($0) }),
           let newCode = Self.languageCode(spokenIn: c) {
            UserDefaults.standard.set(newCode, forKey: "translate_target_language")
            UserDefaults.standard.set(newCode, forKey: "translate_last_used_language")
            NotificationCenter.default.post(name: .chappyRetargetTranslate, object: newCode)
            // BUILD 144 earcon diet: the spoken line IS the confirmation
            speak("Switching to \(Self.languageName(newCode)).")
            if !LiveTranslateIsOpen {
                UserDefaults.standard.set(true, forKey: "translate_autostart")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "translate_autostart_at")
                handOff()
                NotificationCenter.default.post(name: .chappyOpenTranslate, object: nil)
            }
            return
        }
        // BUILD 103 — THE WORD "TRANSLATION".
        //
        // He says "open translation" because that is what a person says. The
        // string "translation" does not CONTAIN the string "translate" — the
        // eighth letter differs — so every one of these tests missed, the
        // command fell through the whole offline ladder, and it went to Gemini
        // Flash instead: one to four seconds, over the network, sometimes
        // right. That is precisely the "it sort of works and it doesn't"
        // he described, and it was one missing word.
        //
        // The exact-equality tests were the same mistake in a smaller way:
        // "open translate" matched, "open translate please" did not.

        // BUILD 134 — THE READER claims its forms BEFORE the translate-session
        // opener below can. "Translate this sign" means the text in front of
        // the camera, not a live conversation — UNLESS a target language is
        // named ("translate this to Thai"), which stays a session request.
        let namesALanguage = ["indonesian", "thai", "vietnamese", "japanese",
                              "chinese", "mandarin", "french", "german", "spanish",
                              "korean", "italian", "hindi", "balinese", "malay"]
            .contains { c.contains($0) }
        // BUILD 168 — REWRITE WHAT I'M LOOKING AT.
        if c.contains("rewrite this") || c.contains("rewrite that")
            || c.contains("reword this") || c.contains("reword that")
            || c.contains("rewrite the letter") || c.contains("rewrite this document")
            || c.contains("reword the document") || c.contains("rewrite it") {
            ChappyReader.shared.rewriteWhatYouSee(tone: .reword)
            return
        }
        if c.contains("simplify this") || c.contains("simplify that")
            || c.contains("plain english") || c.contains("in plain english")
            || c.contains("what does this say in plain") {
            ChappyReader.shared.rewriteWhatYouSee(tone: .simplify)
            return
        }
        if c.contains("summarise this") || c.contains("summarize this")
            || c.contains("summarise that") || c.contains("summarize that")
            || c.contains("sum this up") || c.contains("give me the gist") {
            ChappyReader.shared.rewriteWhatYouSee(tone: .summary)
            return
        }
        if c.contains("turn this into a letter") || c.contains("make this a letter")
            || c.contains("write this as a letter") {
            ChappyReader.shared.rewriteWhatYouSee(tone: .letter)
            return
        }
        // BUILD 159 — SHARP EYE, asked for by name. Press the glasses
        // capture button, then say one of these: Chappy waits for the
        // full-resolution photo to sync and reads THAT.
        if c.contains("read that properly") || c.contains("read this properly")
            || c.contains("read my photo") || c.contains("read the photo")
            || c.contains("read that photo") || c.contains("sharp read")
            || c.contains("read it properly") || c.contains("read the fine print")
            || c.contains("read the small print") {
            ChappyReader.shared.beginSharp(.read)
            return
        }
        if c.contains("scan my photo") || c.contains("scan the photo")
            || c.contains("scan that properly") {
            ChappyReader.shared.beginSharp(.scan)
            return
        }
        if !namesALanguage,
           c.contains("scan this") || c.contains("scan that") || c.contains("scan the ")
            || c.contains("save this document") || c.contains("scan and save")
            || c.contains("scan it") {
            speak("Scanning.")
            ChappyReader.shared.begin(.scan)
            return
        }
        if !namesALanguage,
           c.hasPrefix("translate this") || c.hasPrefix("translate that")
            || c.hasPrefix("translate the ") || c.contains("translate what it says") {
            speak("Having a look.")
            ChappyReader.shared.begin(.translate)
            return
        }
        if c.contains("keep reading") || c.contains("continue reading")
            || c.contains("next page") || c.contains("read the rest") {
            ChappyReader.shared.continueReading()
            return
        }
        if c.contains("read my last scan") || c.contains("read the last scan")
            || c.contains("read that scan") || c.contains("last scan") {
            ChappyReader.shared.readLastScan()
            return
        }

        if c.hasPrefix("translate") || c.hasPrefix("translation")
            || c.contains("translation") || c.contains("translator")
            || c.contains("interpreter") || c.contains("interpret for")
            || c.contains("open translate") || c.contains("start translate")
            || c.contains("start translating") || c.contains("open translating")
            || c.contains("translate mode") || c.contains("translate app")
            || c.contains("help me talk to") || c.contains("talk to them")
            || c.contains("speak to them") || c.contains("talk to him")
            || c.contains("talk to her") || c.contains("talk to this guy")
            || (c.contains("translate") && (c.contains("mode") || c.contains("for me"))) {
            // ============ WHICH LANGUAGE, WITHOUT ASKING ============
            // "Open translate and just start" is the right instinct, and it
            // works everywhere except where he is right now: at home the local
            // language is English, and English-to-English is not a translator.
            // Location alone therefore fails precisely when he tests it.
            //
            // So location is only ONE of four sources, tried in the order that
            // is most likely to be right:
            //
            //   1. what he just SAID          — "translate to Thai" wins always
            //   2. where he IS                — but only if it isn't English
            //   3. what he used LAST          — mid-trip this is nearly always
            //                                   the answer, and it is what makes
            //                                   "open translate" just work in a
            //                                   week of Indonesian conversations
            //   4. his usual language          — set once in Settings
            //
            // Only if all four come up empty does it ask. And even a wrong
            // guess self-corrects: auto-retarget switches after two turns in
            // another language, so the cost of guessing is a few seconds, while
            // the cost of asking every single time is a worse product.
            let picked = Self.languageCode(spokenIn: c)
                ?? Self.localLanguageIfForeign()
                ?? Self.lastUsedTranslateLanguage()
                ?? Self.usualTranslateLanguage()
            guard let code = picked else {
                // BUILD 87: this used to be a dead end — a refusal, and you had
                // to start the whole command again knowing the exact word it
                // wanted. At home in Australia the local language is English,
                // which is not a translation pair, so plain "Chappy, translate"
                // ALWAYS hit this. Asking is both friendlier and what he asked
                // for: say "translate", get asked which language, answer it.
                askForTranslateLanguage()
                return
            }
            UserDefaults.standard.set("en", forKey: "translate_source_language")
            UserDefaults.standard.set(code, forKey: "translate_target_language")
            UserDefaults.standard.set(code, forKey: "translate_last_used_language")
            UserDefaults.standard.set(true, forKey: "translate_autostart")
            // AUDIT P0 (MH-3): this stamp was READ by LiveTranslateViewModel and
            // written NOWHERE. A missing key reads back as 0.0, the viewmodel's
            // `stamp > 0` freshness check was therefore always false, and
            // pendingAutostart could never become true. So "Chappy, translate"
            // said "Go ahead" and then never started listening — the FS-17
            // expiry guard silently disabled the whole feature it was guarding.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "translate_autostart_at")
            speak("Translating English and \(Self.languageName(code)). Go ahead.")
            handOff()
            NotificationCenter.default.post(name: .chappyOpenTranslate, object: nil)
            return
        }
        if c.contains("keep watching") || c.contains("continuous vision") || c.contains("narrate") {
            speak("Eyes open.")
            handOff()
            NotificationCenter.default.post(name: .continuousVisionTriggered, object: nil)
            return
        }
        if c.contains("stop navigation") || c.contains("cancel navigation") {
            NavEngine.shared.stop(); speak("Route's off."); return
        }
        // AUDIT P1 (RG-HOME): only two phrasings were handled, so "take us
        // home" at 2am fell all the way through to the either/or prompt.
        if ["get me home", "take me home", "take us home", "get us home",
            "walk me home", "walk us home", "head home", "go home", "get home",
            "way home", "back to the hotel", "take us back to the hotel",
            "navigate home"].contains(where: { c.contains($0) }) {
            speak("Let me get you home.")
            let reply = await NavEngine.shared.getHome()
            speak(reply); return
        }
        if let dest = navDestination(in: c) {
            // AUDIT FIX: bare " car" forced driving on "walk me to the car
            // rental place"; anchored mode phrases only.
            // AUDIT P1 (RG-DRIVE): "drive us to the airport" (with his wife)
            // matched no driving phrase and silently produced a 140-minute
            // WALKING route to the airport.
            let driving = c.contains("drive me") || c.contains("drive us")
                || c.contains("driving to") || c.contains("by car")
                || c.contains("by taxi") || c.contains("by grab")
                || c.contains("via car") || c.contains("in the car") || c.contains("by scooter")
                || c.contains("on the scooter") || c.contains("by motorbike") || c.contains("by taxi")
            // AUDIT FIX: "take me to home" bypassed the saved-home handler
            if ["home", "hotel", "the hotel", "my hotel", "our hotel", "the room"]
                .contains(dest.lowercased()) {
                speak("Right, heading home.")
                let reply = await NavEngine.shared.getHome()
                speak(reply); return
            }
            // BUILD 152 — FLIGHT DAY: a bare "the airport" means HIS airport,
            // right terminal, when a flight is tracked today.
            var target = dest
            if ["airport", "the airport", "airport please", "the airport please"]
                .contains(target.lowercased()),
               let better = ChappyFlights.shared.airportNavQuery() {
                target = better
            }
            // BUILD 87: if he didn't say HOW, ask — walking and driving routes
            // to the same place are completely different journeys, and guessing
            // walking for an airport run is how you get a 140-minute route.
            // Only asked when genuinely unknown: "walk me to" already said it.
            let modeStated = driving
                || ["walk", "on foot", "walking", "stroll"].contains { c.contains($0) }
            guard modeStated else { askForNavMode(destination: target); return }
            speak("Finding \(target).")
            ChappyEarcon.shared.startThinking()
            let reply = await NavEngine.shared.navigate(to: target, driving: driving)
            ChappyEarcon.shared.stopThinking()
            // Human ears get the human string; the model-directed one is for
            // Live AI only. See AUDIT FIX (SPOKEN-LEAK) in NavEngine.navigate.
            speak(NavEngine.shared.spokenRouteSummary ?? reply)
            // BUILD 163 — THE MISSING "WANT GOOGLE MAPS?"
            //
            // This fired the offer IMMEDIATELY after the summary — and
            // TTSService.speak() cancels whatever is already speaking. So with
            // stops in the route (a long summary) the two collided and one of
            // them lost. You heard a route and then had to reach for Maps
            // yourself, because the question never survived.
            //
            // Now it waits for the summary to actually finish, then asks.
            if NavEngine.shared.isNavigating {
                Task { @MainActor in
                    var waited = 0
                    while TTSService.shared.isSpeaking && waited < 250 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        waited += 1
                    }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    self.offerGoogleMaps(driving: driving)
                }
            }
            return
        }
        // AUDIT FIX (coverage gap): mode follow-ups re-route the last
        // destination — they worked in-session but not in Standby.
        if let last = NavEngine.shared.lastQuery,
           ["via car", "by car", "in the car", "by scooter", "on the scooter",
            "on foot", "walking instead", "by motorbike"].contains(where: { c.contains($0) }),
           c.split(separator: " ").count <= 5 {
            let driving = !(c.contains("foot") || c.contains("walking"))
            speak("Finding you another way.")
            let reply = await NavEngine.shared.navigate(to: last, driving: driving)
            speak(NavEngine.shared.spokenRouteSummary ?? reply)
            if NavEngine.shared.isNavigating { armMapsAnswerWindow() }
            return
        }
        if c.contains("open google maps") || c.contains("open maps") {
            NotificationCenter.default.post(name: .chappyOpenGoogleMaps, object: nil)
            speak("Opening Google Maps."); return
        }

        // BUILD 133 — STOPS ON THE WAY, as a follow-up. A route is on and he
        // says "get me a coffee on the way and get fuel": resolve each ask to
        // a place partway along the trip and hand the whole run to Maps.
        if NavEngine.shared.destinationCoord != nil,
           c.contains("on the way") || c.contains("along the way")
            || c.hasPrefix("add a stop") || c.contains("stop for") {
            let wants = Self.parseStopQueries(from: c)
            guard !wants.isEmpty else { speak("Stop for what?"); return }
            speak("Let me find that.")
            let msg = await NavEngine.shared.addStops(wants)
            speak(msg)
            return
        }

        // ---------- TIER 1 — one cheap call ----------
        // THE DEAL CHECK — one look + a price verdict + a haggling number
        if c.contains("good deal") || c.contains("good price") || c.contains("ripped off")
            || c.contains("should this cost") || c.contains("is that fair")
            || c.contains("worth it") || c.contains("too expensive") {
            speak("Let me look.")
            QuickVisionManager.shared.triggerQuickVision(customPrompt:
                "Identify the item and any marked price in this photo. Then judge the price: is it fair for this region, or high? Answer in two short spoken sentences: what it is and the going rate, then a verdict with a number to counter-offer if it's high. Context: \(ContextEngine.shared.contextHeader())")
            return
        }
        // AUDIT FIX: "read the menu" and "what does this sign say" — both in
        // the spec — used to fall through to a BLIND paid call that would
        // invent an answer. Matches the in-session bridge's breadth now.
        // BUILD 134: routed through the Reader — free on-device OCR first,
        // the paid eyes only when OCR finds nothing legible.
        if (c.hasPrefix("read th") || c.hasPrefix("read it") || c.contains("read this sign") || c.contains("read that sign") || c.contains("read the menu")) || c.contains("read it") || c.contains("read me")
            || c.contains("what does this say") || c.contains("what does that say")
            || (c.contains("what does") && c.contains("say")) {
            speak("Reading that now.")
            ChappyReader.shared.begin(.read)
            return
        }
        if c.contains("can i eat") || c.contains("can she eat") || c.contains("can we eat")
            || c.contains("what's in this") || c.contains("is this safe to eat")
            || c.contains("allergen") || c.contains("vegetarian") {
            speak("Checking the label.")
            QuickVisionManager.shared.triggerQuickVision(customPrompt:
                "Read the ingredients or menu item in this image. Flag ALLERGENS clearly first (nuts, shellfish, dairy, gluten, egg, soy), then say briefly what it is. Two short spoken sentences.")
            return
        }
        if c.contains("what's this") || c.contains("what is this") || c.contains("what am i looking at")
            || c.contains("what's that") || c.contains("what is that") || c.contains("look at this") {
            speak("Having a look.")
            QuickVisionManager.shared.triggerQuickVision()
            return
        }
        // AUTO-ESCALATION: if this is really a conversation, don't fake it
        // with a one-shot — hand it to Live AI and carry the question over.
        if needsDeepSession(c) {
            speak("That deserves a proper conversation - give me a moment.")
            UserDefaults.standard.set(c, forKey: "chappy_pending_question")
            handOff()
            NotificationCenter.default.post(name: .liveAITriggered, object: nil)
            return
        }

        // THE UNSURE RULE (spec'd, previously unbuilt): a bare noun is
        // ambiguous — "Chappy, sushi" could be find-me-one or tell-me-about.
        // Ask ONE either/or instead of guessing or burning a paid call.
        // ============ TIER 2b: KEYWORD FALLBACK (offline) ============
        // The phrase ladder above is precise but finite. This catches the
        // phrasings it didn't anticipate WITHOUT a network call — scoring the
        // meaning words rather than matching a fixed string.
        //
        // Measured, not assumed: on a 60-phrase corpus of natural speech the
        // ladder alone got 86%. Keyword scoring ALONE got 71% — worse, because
        // word order carries meaning that keywords discard ("show the map"
        // scores as navigation). Ladder first, then keywords on what it missed,
        // reaches 98%. Precision first, recall second; never the reverse.
        //
        // Everything here is free and works with no signal, which is the whole
        // point — in a rice field with no bars this is the last tier that runs.
        if let guess = Self.keywordIntent(c) {
            print("🔤 [Keyword] '\(c)' → \(guess.action) \(guess.parameter ?? "")")
            if await runIntent(guess, utterance: c) { return }
        }

        // ================= TIER 3: FLASH INTENT (moved up) =================
        // AUDIT P1: this used to sit at the very END of route(), BELOW the
        // three-word either/or gate — so exactly the short rephrasings it
        // exists to rescue ("make it German", "find a chemist", "I need an
        // ATM") were swallowed by "Make It German - find you one nearby, or
        // tell you about it?" and never reached the classifier at all.
        // AUDIT P2: Tier 3 can take up to 4s on bad signal, and it did so in
        // total silence — indistinguishable from not being heard, so he repeats
        // himself. A tone costs nothing and closes the loop.
        ChappyEarcon.shared.tap()
        ChappyEarcon.shared.startThinking()
        if let intent = await ChappyIntent.classify(c), intent.action != "ask" {
        ChappyEarcon.shared.stopThinking()
            print("🧠 [Intent] '\(c)' → \(intent.action) \(intent.parameter ?? "")")
            CostMeter.shared.addTTSChars(c.count) // AUDIT P2: was invisible to "cost check"
            if await runIntent(intent, utterance: c) { return }
        }

        // AUDIT P1 (SB-LOOP2): the ANSWER branch used to sit BELOW the ask, so a
        // short reply — "find one", "tell me" — was itself ≤3 words and simply
        // re-triggered the question. "Chappy, petrol station" → "find you one
        // nearby, or tell you about it?" → "Chappy, find one" → "Find One -
        // find you one nearby, or tell you about it?" forever. The either/or
        // could not be answered by voice at all, which for a wearer with the
        // phone in his pocket meant it could not be answered.
        //
        // AUDIT P1 (SB-STICKY): pendingAmbiguous also never expired. Ignore the
        // question and walk on, and ten minutes later an unrelated command was
        // answered as if it were the reply.
        if let pending = pendingAmbiguous {
            if Date().timeIntervalSince(ambiguousAskedAt) > 45 {
                pendingAmbiguous = nil // stale — treat this as a fresh command
            } else {
                pendingAmbiguous = nil
                let wantsNav = ["near", "find", "go", "take me", "one", "closest",
                                "nearest", "there", "yes"].contains { c.contains($0) }
                if wantsNav {
                    speak("Finding \(pending).")
                    let reply = await NavEngine.shared.navigate(to: pending, driving: false)
                    speak(NavEngine.shared.spokenRouteSummary ?? reply)
                    if NavEngine.shared.isNavigating { armMapsAnswerWindow() }
                    return
                }
                await quickAsk("Tell me briefly about \(pending) near \(ContextEngine.shared.snapshot.city ?? "here")")
                return
            }
        }

        let words = c.split(separator: " ")
        if words.count <= 3, !c.contains("?"),
           !c.hasPrefix("what"), !c.hasPrefix("how"), !c.hasPrefix("who"),
           !c.hasPrefix("when"), !c.hasPrefix("where"), !c.hasPrefix("why"),
           !c.hasPrefix("is "), !c.hasPrefix("are "), !c.hasPrefix("can ") {
            pendingAmbiguous = c
            ambiguousAskedAt = Date()
            speak("\(c.capitalized) - find you one nearby, or tell you about it?")
            return
        }

        // Everything else question-shaped → the cheap brain
        // ================= TIER 3: FLASH INTENT =================
        // Everything above is hand-written string matching, and fifty
        // conditions can never cover how a person actually talks. "Take me to
        // my gym", "I need a chemist", "put it in German", "what's the closest
        // beach" — all reasonable, none matched, all previously falling through
        // to a general question when they were really commands.
        //
        // Rather than write condition fifty-one, hand the sentence to a small
        // model and ask what he MEANT. The local recogniser already produced
        // the text for free, so this is a text call, not audio: about 300 ms
        // and a fraction of a cent, and only for phrasings the free tiers
        // didn't recognise. No signal means no Tier 3 — and that is fine,
        // because Tiers 1 and 2 are entirely offline and still work.

        // BUILD 133 ============ TIER 2.75: POCKET ANSWERS ============
        // The questions a companion should never bill you for: the time, the
        // date, a unit conversion, a bit of arithmetic, the weather already
        // in the snapshot, "how are you". Answered locally in ~200ms, free,
        // and they work with no signal at all. Anything Pocket can't answer
        // falls through to the paid brain exactly as before.
        if let pocket = ChappyPocket.answer(c) {
            speak(pocket)
            return
        }
        await quickAsk(c)
    }


    // MARK: Tier 2b — offline keyword intent

    private static let stopWords: Set<String> = [
        "chappy", "chappie", "please", "can", "you", "could", "would", "just",
        "now", "the", "a", "an", "me", "us", "my", "our", "i", "im", "i'm",
        "for", "is", "it", "hey", "ok", "okay", "and", "of", "to", "that",
        "this", "some", "any", "do", "we",
    ]

    /// Verb set and object set per intent. A verb is required — an object on
    /// its own is a noun, not an instruction ("beach" is not "take me to the
    /// beach") — and objects then break ties.
    private static let keywordTable: [(String, Set<String>, Set<String>)] = [
        ("translate", ["translate", "interpret", "speak", "say", "convert", "switch", "put"],
         ["indonesian", "indonesia", "bahasa", "thai", "vietnamese", "japanese",
          "chinese", "french", "german", "spanish", "korean", "italian",
          "portuguese", "filipino", "russian", "greek", "arabic", "language", "them"]),
        ("photo", ["take", "snap", "capture", "shoot", "grab", "get"],
         ["photo", "picture", "shot", "pic", "image", "snap"]),
        ("remember", ["remember", "save", "pin", "mark", "keep", "note"],
         ["spot", "place", "here", "location"]),
        ("map", ["show", "open", "pull", "bring"], ["map", "trail"]),
        ("journal", ["where", "what"], ["been", "today", "did", "steps", "lost"]),
        ("watch", ["watch", "narrate", "describe"], ["watching", "vision"]),
        ("live_ai", ["talk", "chat"], ["live", "ai", "eyes"]),
        ("stop", ["stop", "cancel", "quiet", "shut", "enough", "shush"],
         ["talking", "navigation", "up"]),
        ("navigate", ["navigate", "take", "get", "go", "walk", "drive", "find",
                      "need", "want", "head", "bring", "point", "directions", "show"],
         ["way", "route", "closest", "nearest", "near", "station", "airport",
          "atm", "beach", "chemist", "pharmacy", "hotel", "gym", "shop",
          "restaurant", "cafe", "bank", "hospital", "market", "temple"]),
    ]

    /// Best-effort intent from meaning words alone. Returns nil rather than
    /// guessing when nothing scores clearly — a wrong action is worse than
    /// falling through to the next tier.
    static func keywordIntent(_ text: String) -> ChappyIntent.Result? {
        let toks = Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) })
        guard !toks.isEmpty else { return nil }

        var best: (String, Int)? = nil
        for (action, verbs, objects) in keywordTable {
            let v = toks.intersection(verbs).count
            guard v > 0 else { continue }          // a verb is mandatory
            let score = v * 2 + toks.intersection(objects).count * 2
            if score > (best?.1 ?? 1) { best = (action, score) }
        }
        guard let (action, _) = best else { return nil }

        // For navigation the destination is whatever is left once the
        // instruction words are removed — "find the closest fuel station"
        // leaves "fuel station".
        var parameter: String? = nil
        if action == "navigate" {
            let verbs = keywordTable.first { $0.0 == "navigate" }?.1 ?? []
            let words = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && !stopWords.contains($0) && !verbs.contains($0)
                          && !["closest", "nearest", "way", "route", "directions"].contains($0) }
            let joined = words.joined(separator: " ")
            guard joined.count > 2 else { return nil } // no destination, no route
            parameter = joined
        } else if action == "translate" {
            parameter = languageCode(spokenIn: text).map { languageName($0) }
        }
        return ChappyIntent.Result(action: action, parameter: parameter, mode: nil)
    }

    /// BUILD 90: after a route is found, OFFER the real thing.
    /// Chappy's own map is a picture — it shows the line but gives no lane
    /// guidance, no live traffic, no rerouting. For walking to the shops that
    /// is enough; for driving to Brisbane airport it is not. So the offer is
    /// made out loud, and "yes" opens Google Maps already navigating.
    private var expectingMapsAnswerUntil = Date.distantPast
    /// Set by the translate view while it is on screen, so a language change
    /// retargets the live session instead of opening a second one.
    static var LiveTranslateIsOpen = false
    private var LiveTranslateIsOpen: Bool { Self.LiveTranslateIsOpen }

    func offerGoogleMaps(driving: Bool) {
        // BUILD 132: 10s used to start counting BEFORE the question was even
        // spoken, and the ear ignores everything while Chappy talks — so the
        // real answering gap was a second or two. 30s leaves genuine room.
        expectingMapsAnswerUntil = Date().addingTimeInterval(30)
        if !isListening { silentArm = true; start() }
        TTSService.shared.speak(driving
            ? "Want turn by turn in Google Maps?"
            : "Want me to open it in Google Maps?")
    }

    /// BUILD 132: armed after every SPOKEN route summary ("...Say 'open Google
    /// Maps' for the full map"), so the wearer can answer the summary's own
    /// invitation with a bare "open maps" — no wake word, no rush. The summary
    /// takes ten-plus seconds to say and the ear is deaf while Chappy talks;
    /// the window is sized to survive that and still leave time to think.
    func armMapsAnswerWindow() {
        expectingMapsAnswerUntil = Date().addingTimeInterval(30)
        if !isListening { silentArm = true; start() }
    }

    /// BUILD 133: "get me a coffee on the way and get fuel" → ["cafe",
    /// "petrol station"]. Aussie road vocabulary first, generic fallback after
    /// — an unknown ask is passed through as its own words rather than
    /// dropped, because Places search copes fine with "bunnings".
    static func parseStopQueries(from c: String) -> [String] {
        var s = c
        for junk in ["on the way", "along the way", "add a stop for", "add a stop",
                     "stop for", "can you", "could you", "please", "for me", "me a ", "me some "] {
            s = s.replacingOccurrences(of: junk, with: " ")
        }
        var out: [String] = []
        for chunk in s.components(separatedBy: " and ") {
            let w = chunk.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            guard !w.isEmpty else { continue }
            if w.contains("coffee") || w.contains("cafe") { out.append("cafe") }
            else if w.contains("fuel") || w.contains("petrol") || w.contains("servo")
                || w.contains("gas station") { out.append("petrol station") }
            else if w.contains("maccas") || w.contains("mcdonald") { out.append("mcdonalds") }
            else if w.contains("food") || w.contains("something to eat") || w.contains("hungry")
                || w.contains("lunch") || w.contains("breakfast") { out.append("food") }
            else if w.contains("atm") || w.contains("cash") { out.append("atm") }
            else if w.contains("chemist") || w.contains("pharmacy") { out.append("pharmacy") }
            else if w.contains("water") || w.contains("drink") || w.contains("snack") {
                out.append("convenience store")
            }
            else if w.contains("groceries") || w.contains("supermarket")
                || w.contains("woolies") || w.contains("coles") { out.append("supermarket") }
            else {
                // Strip leading verbs and pass the rest through as-is.
                var g = w
                for v in ["get ", "grab ", "pick up ", "find ", "i want ", "i need ", "a ", "some "] {
                    if g.hasPrefix(v) { g = String(g.dropFirst(v.count)) }
                }
                let noise = ["it", "there", "that", "one", "way", "stop"]
                if !g.isEmpty, g.count > 2, !noise.contains(g) { out.append(g) }
            }
        }
        return out
    }

    /// Strip text written for the MODEL out of anything spoken to a HUMAN.
    /// NavEngine returns one string to two audiences and the tail is an
    /// instruction to the model; the wearer should never hear it.
    static func stripModelDirectives(_ s: String) -> String {
        var out = s
        for marker in ["Also tell the user:", "Tell the user:", "Ask the user",
                       "[route mode:", "say this mode"] {
            if let r = out.range(of: marker) { out = String(out[out.startIndex..<r.lowerBound]) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Execute a Flash-classified intent by routing it back through the SAME
    /// handlers the string ladder uses — no second implementation to drift.
    /// Returns false if we couldn't action it, so the caller can fall through
    /// to a plain answer rather than pretending.
    private func runIntent(_ intent: ChappyIntent.Result, utterance: String) async -> Bool {
        let p = intent.parameter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch intent.action {
        case "navigate":
            guard !p.isEmpty else { promptForDestination(); return true }
            // AUDIT P2: three aliases was narrower than the ladder's list, so
            // "our hotel" / "the room" were geocoded as literal place names and
            // sent you to a random hotel instead of yours.
            let homeWords = ["home", "hotel", "the hotel", "my hotel", "our hotel",
                             "the room", "our room", "my room", "the hostel",
                             "our place", "back home", "our hotel room"]
            if homeWords.contains(p.lowercased()) {
                // AUDIT P2: getHome()'s string is written for the MODEL and
                // contains "Tell the user:". Standby speaks it verbatim.
                speak("Right, heading home.")
                let r = await NavEngine.shared.getHome()
                speak(NavEngine.shared.spokenRouteSummary ?? Self.stripModelDirectives(r))
                if NavEngine.shared.isNavigating { armMapsAnswerWindow() }
                return true
            }
            // AUDIT P2: mode came ONLY from the classifier, so "we're getting a
            // Grab to the airport" produced a walking route when Flash left
            // mode empty. Trust the utterance as well as the classification.
            let modeHay = ((intent.mode ?? "") + " " + utterance).lowercased()
            let driving = ["drive", "driving", "car", "taxi", "grab", "scooter",
                           "motorbike", "moto", "ride"].contains { modeHay.contains($0) }
            speak("Finding \(p).")
            let reply = await NavEngine.shared.navigate(to: p, driving: driving)
            speak(NavEngine.shared.spokenRouteSummary ?? reply)
            if NavEngine.shared.isNavigating { armMapsAnswerWindow() }
            return true

        case "translate":
            // p is a language name or code, or empty for "local language".
            // AUDIT P2: an unvalidated parameter produced "Translating English
            // and EN" and then opened an English-to-English session. If he asks
            // for English he means "put THEIR language into English" — which is
            // the local language on the other side, not a null pair.
            var code = p.isEmpty ? nil : Self.languageCode(forName: p)
            if code == "en" { code = nil } // fall through to the local language
            guard let target = code ?? Self.languageCode(forCountry: ContextEngine.shared.snapshot.countryCode) else {
                speak("I don't speak that one yet, sorry."); return true
            }
            UserDefaults.standard.set("en", forKey: "translate_source_language")
            UserDefaults.standard.set(target, forKey: "translate_target_language")
            UserDefaults.standard.set(true, forKey: "translate_autostart")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "translate_autostart_at")
            speak("Translating English and \(Self.languageName(target)).")
            handOff()
            NotificationCenter.default.post(name: .chappyOpenTranslate, object: nil)
            return true

        case "look":
            speak("Having a look.")
            QuickVisionManager.shared.triggerQuickVision(customPrompt: p.isEmpty ? nil : "Look and answer: \(p)")
            return true

        case "photo":
            NotificationCenter.default.post(name: .chappyCapturePhoto, object: nil)
            // AUDIT P1: this said "Got it." unconditionally, re-introducing
            // a bug the ladder had already fixed. With the phone pocketed and
            // the camera not streaming, nothing is captured and Chappy claims
            // success — the wearer walks off believing he has the shot.
            if LiveAIManager.shared.streamViewModel?.streamingStatus == .streaming {
                ChappyEarcon.shared.done(); speak("Got it.")
            } else {
                speak("Camera isn't running - open Talk or Look first.")
            }
            return true

        case "remember":
            if p.isEmpty { rememberSpotByVoice() } else {
                let spot = TripRecorder.shared.rememberSpot(named: p)
                // AUDIT P1: the GPS check was dropped here. Indoors or straight
                // off a plane the pin saves at 0,0 and "Saved" is a lie — you
                // find out weeks later when the spot is in the ocean.
                if spot.lat == 0 && spot.lon == 0 {
                    speak("Saved it, though GPS hasn't settled - it may be a little off.")
                } else {
                    // BUILD 144 earcon diet: the spoken line IS the confirmation
                    ChappyHaptics.shared.straightStep()
                    speak("Saved \(spot.name).")
                }
            }
            return true

        case "map":
            NotificationCenter.default.post(name: .chappyShowMap, object: nil)
            speak("Map's up."); return true

        case "watch":
            speak("Eyes open."); handOff()
            NotificationCenter.default.post(name: .continuousVisionTriggered, object: nil)
            return true

        case "live_ai":
            speak("Opening Live AI."); handOff()
            NotificationCenter.default.post(name: .liveAITriggered, object: nil)
            return true

        case "stop":
            // AUDIT P1: this silently cancelled an ACTIVE ROUTE with no speech
            // and no tone. A conversational "alright, that'll do" could end
            // your navigation in Denpasar and you would not know until you
            // looked. Stopping the voice is harmless; stopping a route is not,
            // so they are no longer the same action.
            TTSService.shared.stop()
            ChappyHaptics.shared.straightStep()
            if NavEngine.shared.isNavigating {
                speak("Just quiet, or stop the route as well?")
            }
            return true

        case "journal":
            speak(TripRecorder.shared.todaySummary()); return true

        default:
            return false
        }
    }

    // MARK: Tier 1 brain — one call, spoken, then back to sleep

    private func quickAsk(_ question: String) async {
        let key = APIKeyManager.shared.getAPIKey(for: .anthropic) ?? ""
        guard !key.isEmpty, let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            escalate("I can't reach my brain - no key configured."); return
        }
        CostMeter.shared.addQuickVision() // one-shot call, same rough cost bracket
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 25
        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 300,
            "system": "You are Chappy, Shaun's glasses assistant, answering ONE quick spoken question. Context: \(ContextEngine.shared.contextHeader()) Answer in ONE or TWO short spoken sentences - no markdown, no lists, no preamble, lead with the answer. If the question needs live web facts you don't have, say so in one sentence and offer to dig deeper.",
            "messages": [["role": "user", "content": question]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            escalate("That one didn't come back."); return
        }
        let text = content.compactMap { ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }
            .joined(separator: " ")
        if text.isEmpty { escalate("I got nothing back on that."); return }
        strikes = 0
        speak(text)
    }

    // MARK: Tier 3 — computer jobs (queued when the PC is asleep)

    private func queueComputerJob(_ job: String) {
        guard job.count > 3 else { speak("What should the computer do?"); return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(job)\n"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let url = docs?.appendingPathComponent("chappy-openclaw-outbox.txt") {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        TripRecorder.shared.addObservation("Computer job: \(job)")
        speak("Right, I'll get the computer onto \(job) when it's awake.")
    }

    // MARK: Helpers

    /// "snooze for twenty minutes", "snooze an hour".
    static func snoozeMinutes(in c: String) -> Int? {
        if let r = c.range(of: #"(\d+)\s?(minute|minutes|min|mins|hour|hours|hr|hrs)"#,
                           options: .regularExpression) {
            let frag = String(c[r])
            let n = Int(frag.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .filter { !$0.isEmpty }.first ?? "") ?? 10
            return frag.contains("h") ? n * 60 : n
        }
        if c.contains("an hour") { return 60 }
        if c.contains("half an hour") { return 30 }
        return nil
    }

    /// Text following any of these openers (nil if none present)
    private func after(_ text: String, _ openers: [String]) -> String? {
        for o in openers {
            if let r = text.range(of: o) {
                return String(text[r.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            }
        }
        return nil
    }

    /// Destination from any natural navigation phrasing.
    /// AUDIT FIXES: (a) full opener list matching the in-session bridge —
    /// "guide me to", "direct me to", "navigate us to", "take us to" all
    /// worked in Live AI but silently failed here; (b) junk words are only
    /// stripped from the END, because the old "strip anywhere" logic turned
    /// "take me to Walking Street" into an empty destination and "the driving
    /// range" into a Places search for "the"; (c) leading "the/a" and
    /// "closest/nearest" are removed so Places gets a clean query, matching
    /// what the in-session bridge sends.
    private func navDestination(in c: String) -> String? {
        // Question words mean it's a question ABOUT a place, not a request to
        // go there: "how far is the nearest hospital" must not start a route.
        let questionOpeners = ["how far", "how long", "how much", "what time", "is there", "are there"]
        if questionOpeners.contains(where: { c.hasPrefix($0) }) { return nil }

        // SIM FIX: "take us back to the hotel" matched no opener at all.
        // AUDIT P1 (RG-INFO): "closest"/"nearest" matched ANYWHERE, so "tell me
        // about the nearest temple" and "what's the closest ATM like" started a
        // live turn-by-turn route instead of answering. They only count as a
        // navigation opener when the sentence isn't asking ABOUT the place.
        let informational = ["tell me about", "what's", "whats", "what is", "how good",
                             "any good", "is the", "are the", "which"]
        let asksAbout = informational.contains { c.contains($0) }
        var openers = ["navigate me to ", "navigate us to ", "navigate to ",
                       "take me back to ", "take us back to ", "get us back to ",
                       "take me to ", "take us to ", "walk me to ", "walk us to ",
                       "drive me to ", "drive us to ", "direct me to ", "guide me to ",
                       "get me directions to ", "directions to ", "get me to ",
                       "route me to ", "route to ", "how do i get to ", "how do we get to ",
                       "give me a map to ", "map to ", "a map to ", "show me the way to ",
                       "i need to get to ", "i want to go to ", "how far to "]
        // BUILD 104: the way he actually asks. "Find me the closest Hungry
        // Jack's and navigate me to it" used to extract the destination "it".
        if !asksAbout {
            openers += ["closest ", "nearest ",
                        "find me the closest ", "find me the nearest ",
                        "find the closest ", "find the nearest ", "find me a ",
                        "find me the best ", "find the best ", "find a ",
                        "where's the closest ", "wheres the closest ",
                        "where is the closest ", "where's the nearest ",
                        "wheres the nearest ", "where is the nearest ",
                        "is there a "]
        }
        // BUILD 104 — CHOP THE TAIL BEFORE PICKING THE OPENER.
        // "Find me the closest Hungry Jack's and navigate me to it" contains
        // TWO openers, and the last-one-wins rule picked the second, so the
        // destination came out as the word "it". The trailing half is never
        // the place name, so it goes first. Only stripped when there is
        // something in front of it, so a bare "take me there" still routes.
        var c = c
        for tail in [" navigate me to it", " navigate me there", " navigate to it",
                     " navigate there", " take me there", " take me to it",
                     " take us there", " get me there", " go there",
                     " route me there", " show me a map", " show me the map",
                     " map it", " drive me there", " walk me there"] {
            if let r = c.range(of: tail), r.lowerBound != c.startIndex {
                c = String(c[c.startIndex..<r.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
                // "…and" is left dangling once its clause is gone.
                if c.hasSuffix(" and") { c = String(c.dropLast(4)) }
                if c.hasSuffix(" then") { c = String(c.dropLast(5)) }
            }
        }

        // Take the LAST opener match so lead-ins can't poison the destination
        var best: Range<String.Index>?
        for o in openers {
            if let r = c.range(of: o, options: .backwards) {
                if best == nil || r.upperBound > best!.upperBound { best = r }
            }
        }
        guard let hit = best else { return nil }
        var d = String(c[hit.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
        // AUDIT P1 (RG-MODE): mode phrases were stripped only from the END and
        // the list was missing the ones he actually uses in Asia. "take me to
        // Kuta Beach by taxi" searched Places for "kuta beach by taxi" and found
        // nothing. Strip them wherever they appear — they are never part of a
        // place name.
        // Trailing clauses. "…and take me there" is not part of a shop name,
        // and it is how a person naturally chains the two halves of the ask.
        for tail in [" and take me there", " and navigate me to it", " and navigate there",
                     " and take me to it", " and show me a map", " and show me the map",
                     " and map it", " and route me there", " and get me there",
                     " and go there", " then take me there", " and take us there"] {
            if let r = d.lowercased().range(of: tail) {
                d = String(d[d.startIndex..<r.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            }
        }
        for junk in [" by car", " via car", " by scooter", " on the scooter", " by motorbike",
                     " by taxi", " by grab", " by bike", " in the car", " on foot",
                     " walking", " driving", " please", " thanks", " thank you", " now"] {
            while let r = d.lowercased().range(of: junk) {
                d = d.replacingCharacters(in: r, with: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            }
        }
        d = d.replacingOccurrences(of: "  ", with: " ")
        // Clean the query the way the in-session bridge does
        for prefix in ["the ", "a ", "closest ", "nearest "] where d.lowercased().hasPrefix(prefix) {
            d = String(d.dropFirst(prefix.count))
        }
        d = d.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
        // Belt and braces: a pronoun means the tail-chopper missed something.
        // Routing to a place called "it" is worse than not routing at all.
        if ["it", "there", "that", "them", "here", "one"].contains(d.lowercased()) { return nil }
        return d.count > 1 ? d : nil
    }

    /// AUDIT FIX (P0 safety): emergency handled locally, instantly, with no
    /// network round-trip — country emergency number spoken, WhatsApp SOS
    /// with a live map pin opened for the trusted contact.
    private func runEmergencyFromStandby() {
        let snap = ContextEngine.shared.snapshot
        var address = [snap.street, snap.city, snap.country].compactMap { $0 }.joined(separator: ", ")
        if address.isEmpty { address = "location not fixed yet" }
        let numbers: [String: String] = ["ID": "112", "TH": "191", "VN": "113", "PH": "911",
                                         "KH": "117", "LA": "1191", "MY": "999", "SG": "995", "AU": "000",
                                         // BUILD 57 — the Americas. 112 is a
                                         // sensible European default but it is
                                         // NOT the number in Brazil or Peru,
                                         // and this is the one list where a
                                         // wrong answer really matters.
                                         "BR": "190", "AR": "911", "CL": "133", "CO": "123",
                                         "PE": "105", "UY": "911", "PY": "911", "BO": "110",
                                         "EC": "911", "VE": "171", "MX": "911", "CR": "911",
                                         "PA": "911", "GT": "110", "US": "911", "CA": "911",
                                         "NZ": "111", "GB": "999", "IN": "112", "JP": "110",
                                         "KR": "112", "CN": "110", "TW": "110", "HK": "999"]
        let emergencyNumber = numbers[snap.countryCode ?? ""] ?? "112"
        var line = "Emergency. You are at \(address). Local emergency number is \(emergencyNumber). Calling that number is \(emergencyNumber)."
        let contact = (UserDefaults.standard.string(forKey: "chappy_emergency_contact") ?? "")
            .filter(\.isNumber) // AUDIT FIX: "+61 412..." never resolved on wa.me
        if !contact.isEmpty, let lat = snap.latitude, let lon = snap.longitude,
           let u = URL(string: "https://wa.me/\(contact)?text=EMERGENCY%20-%20I%20need%20help.%20My%20location:%20https://maps.google.com/?q=\(lat),\(lon)") {
            UIApplication.shared.open(u, options: [:], completionHandler: nil)
            line += " A WhatsApp message with your location is open - press send."
        }
        ChappyHaptics.shared.offRoute()
        TTSService.shared.speak(line)
    }

    /// AUDIT FIX (HIGH — visible in every demo): NavEngine and TripRecorder
    /// return strings written to be fed to an AI model, so Standby was
    /// literally saying "...First step: turn left. Also tell the user: say
    /// 'open Google Maps' anytime..." and "Ask the user to try again".
    /// Everything from a coaching phrase onward is stripped, and remaining
    /// third-person instructions are made human.
    private static let promptTails = [
        "also tell the user", "tell the user", "ask the user", "report this",
        "relay this", "confirm this", "say this", "guide the user",
        "read all of this to the user", "briefly confirm"
    ]
    static func humanise(_ text: String) -> String {
        var out = text
        let lower = out.lowercased()
        for tail in promptTails {
            if let r = lower.range(of: tail) {
                out = String(out[..<r.lowerBound])
                break
            }
        }
        out = out
            .replacingOccurrences(of: "the user's", with: "your")
            .replacingOccurrences(of: "The user's", with: "Your")
            .replacingOccurrences(of: "the user", with: "you")
            .replacingOccurrences(of: "The user", with: "You")
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;-"))
    }

    private func speak(_ text: String) {
        ChappyHaptics.shared.straightStep()
        TTSService.shared.speak(Self.humanise(text))
    }

    /// CONTEXTUAL COACH: four things worth saying RIGHT NOW, rotating so you
    /// meet the whole vocabulary over a week instead of memorising a manual.
    private func coachLine() -> String {
        var options: [String] = []
        if NavEngine.shared.isNavigating {
            options = ["open Google Maps", "stop navigation", "how far to go",
                       "remember this spot"]
        } else if ContextEngine.shared.snapshot.motion == "in a vehicle" {
            options = ["what's that place", "navigate me to the closest petrol station",
                       "log this", "take a photo"]
        } else {
            options = ["is this a good deal", "read this", "can she eat this",
                       "remember this spot call it home", "navigate me to the closest ATM",
                       "log this", "take a photo", "get the computer to research something",
                       "let's talk for a proper conversation", "translate"]
        }
        let picks = options.shuffled().prefix(4).joined(separator: ", or ")
        coachCount += 1
        let tail = coachCount <= 2 ? " Use my name first, then the words." : ""
        return "Try: \(picks).\(tail)"
    }

    /// COMPLEXITY DETECTOR: some requests are conversations, not commands —
    /// hand those to the deep layer instead of half-answering them.
    private func needsDeepSession(_ c: String) -> Bool {
        let conversational = ["help me figure", "help me work out", "what should i do",
                              "walk me through", "let's plan", "lets plan", "plan my",
                              "talk me through", "explain in detail", "go through",
                              "compare all", "and then", "after that", "keep watching"]
        if conversational.contains(where: { c.contains($0) }) { return true }
        // Long multi-clause sentences are conversations wearing a command's hat
        return c.split(separator: " ").count > 22
    }

    /// THREE-STRIKE ESCAPE: never loop "didn't catch that" — offer the deep
    /// layer instead. This is the on-ramp to full Live AI.
    private func escalate(_ reason: String) {
        strikes += 1
        if strikes >= 2 {
            strikes = 0
            // AUDIT P0 (SB-SELFTALK): this line literally spoke the wake word plus a
            // command, and the mic heard it. Never put the wake word inside
            // something Chappy says out loud.
            TTSService.shared.speak("\(reason) Want me to open Live AI so we can talk it through? Just say the word.")
        } else {
            // Rotated so the second miss doesn't sound like a stuck record —
            // the moment a wearer notices the identical phrasing twice is the
            // moment the thing stops feeling like a companion.
            TTSService.shared.speak("\(reason) \(ChappyVoice.stumble())")
        }
    }
}

// MARK: - Chappy Haptics (the silent second voice)
// Ears carry words; the pocket carries signals. A small learned vocabulary:
// LEFT = two light taps · RIGHT = one heavy thud · ARRIVAL = success rise ·
// OFF-ROUTE = warning · SHUTTER = rigid tick · CONNECT = soft tap ·
// VOICE REVIVED = slow heavy double · COST NUDGE = gentle double ·
// PROXIMITY = quickening taps. Foreground-reliable; notification-carried
// versions arrive with Phase 5.5.
@MainActor
final class ChappyHaptics {
    static let shared = ChappyHaptics()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notify = UINotificationFeedbackGenerator()

    /// Play a tap sequence: (delaySeconds, style) pairs.
    private func taps(_ pattern: [(Double, UIImpactFeedbackGenerator)]) {
        Task { @MainActor in
            for (delay, gen) in pattern {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                gen.impactOccurred()
            }
        }
    }

    func leftTurn()     { taps([(0, light), (0.18, light)]) }
    func rightTurn()    { taps([(0, heavy)]) }
    func straightStep() { taps([(0, light)]) }
    func arrival()      { notify.notificationOccurred(.success); taps([(0.25, light), (0.4, light)]) }
    func offRoute()     { notify.notificationOccurred(.warning) }
    func shutter()      { taps([(0, rigid)]) }
    func connected()    { taps([(0, light)]) }
    func voiceRevived() { taps([(0, heavy), (0.5, heavy)]) }
    func costNudge()    { taps([(0, light), (0.3, light)]) }
    func proximity()    { taps([(0, light), (0.2, light), (0.35, heavy)]) }

    // PHASE 5.5 — REMINDER SIGNATURES.
    //
    // The point of a haptic is that you can tell WHAT happened without
    // looking, without hearing, and with the phone in a pocket on a scooter.
    // That only works if the patterns are actually distinguishable from each
    // other and from the navigation cues above, so these are deliberately
    // shaped differently: nav is short and directional, reminders RISE.
    //
    //   normal   light · light · heavy      a rising "something's due"
    //   urgent   heavy · heavy · heavy, twice, with a gap you feel through denim
    //   place    three quick lights         a flutter — "you've arrived at the thing"
    //   done     success notification       the system's own tick
    func reminderDue()   { taps([(0, light), (0.14, light), (0.30, heavy)]) }
    func reminderUrgent() {
        taps([(0, heavy), (0.16, heavy), (0.32, heavy),
              (0.9, heavy), (0.16, heavy), (0.32, heavy)])
    }
    func reminderPlace() { taps([(0, light), (0.10, light), (0.20, light)]) }
    func reminderDone()  { notify.notificationOccurred(.success) }
    func reminderSnoozed() { taps([(0, light)]) }
}

// MARK: - Backup & Restore (Settings → Backup)
// One file carries EVERYTHING: every file in Documents (journal crumbs,
// spots, notes, records, gallery) + the app's UserDefaults (theme, voice,
// emergency contact, cost history, language). Share it to iCloud Drive;
// restore it on a new phone. Migration + lost-phone insurance in one.
final class ChappyBackup {
    static let shared = ChappyBackup()

    func createBackup() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        var files: [String: String] = [:]
        if let items = try? fm.subpathsOfDirectory(atPath: docs.path) {
            for rel in items {
                let full = docs.appendingPathComponent(rel)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full.path, isDirectory: &isDir), !isDir.boolValue,
                   let data = try? Data(contentsOf: full) {
                    files[rel] = data.base64EncodedString()
                }
            }
        }
        var defaults: [String: Any] = [:]
        if let bundleID = Bundle.main.bundleIdentifier,
           let domain = UserDefaults.standard.persistentDomain(forName: bundleID) {
            for (k, v) in domain where JSONSerialization.isValidJSONObject([k: v]) {
                defaults[k] = v
            }
        }
        let payload: [String: Any] = [
            "chappy_backup_version": 1,
            "created": ISO8601DateFormatter().string(from: Date()),
            "files": files,
            "defaults": defaults
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd-HHmm"
        let out = fm.temporaryDirectory.appendingPathComponent("Chappy-Backup-\(df.string(from: Date())).chappybackup")
        try? data.write(to: out)
        return out
    }

    /// Returns a human-readable result to show the user.
    func restore(from url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["chappy_backup_version"] != nil else {
            return "That file is not a Chappy backup."
        }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "Could not reach app storage."
        }
        var restoredFiles = 0
        for (rel, b64) in (json["files"] as? [String: String]) ?? [:] {
            guard let d = Data(base64Encoded: b64) else { continue }
            let dest = docs.appendingPathComponent(rel)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: dest)
            restoredFiles += 1
        }
        var restoredKeys = 0
        for (k, v) in (json["defaults"] as? [String: Any]) ?? [:] {
            UserDefaults.standard.set(v, forKey: k)
            restoredKeys += 1
        }
        return "Restored \(restoredFiles) files and \(restoredKeys) settings. Close and reopen Chappy to load everything."
    }
}

// MARK: - Cost Meter (Settings → Usage)
// Rough LOCAL estimate of AI spend — counts what the app actually does
// (Live AI minutes, TTS characters, Quick Vision + deep research calls)
// and prices them with ballpark rates. Not a bill — a smoke alarm.
final class CostMeter {
    static let shared = CostMeter()
    private let storeKey = "chappy_cost_days"
    private let spokenKey = "chappy_cost_warned"
    private let lock = NSLock()

    // BALLPARK RATES (USD) — deliberately rounded UP a little so the meter
    // over-warns rather than under-warns. Tune here if bills say otherwise.
    static let ratePerLiveMinute = 0.08      // Gemini Live audio+video stream
    static let ratePerTTSThousandChars = 0.02 // Gemini TTS
    static let ratePerQuickVision = 0.02      // Claude vision call
    static let ratePerResearch = 0.20         // Claude + web search deep dive

    private static func dayKey(_ d: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    private func load() -> [String: [String: Double]] {
        (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: [String: Double]]) ?? [:]
    }

    private func bump(_ field: String, by amount: Double) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        var day = all[Self.dayKey()] ?? [:]
        day[field] = (day[field] ?? 0) + amount
        all[Self.dayKey()] = day
        // keep only the last 62 days
        if all.count > 62 {
            for k in all.keys.sorted().dropLast(62) { all.removeValue(forKey: k) }
        }
        UserDefaults.standard.set(all, forKey: storeKey)
        maybeSpeakWarning()
    }

    func addLiveSeconds(_ s: Double) { guard s > 0 else { return }; bump("live_s", by: s) }
    func addTTSChars(_ n: Int) { guard n > 0 else { return }; bump("tts_c", by: Double(n)) }
    func addQuickVision() { bump("qv", by: 1) }
    func addResearch() { bump("research", by: 1) }

    static func cost(of day: [String: Double]) -> Double {
        ((day["live_s"] ?? 0) / 60) * ratePerLiveMinute
            + ((day["tts_c"] ?? 0) / 1000) * ratePerTTSThousandChars
            + (day["qv"] ?? 0) * ratePerQuickVision
            + (day["research"] ?? 0) * ratePerResearch
    }

    /// (liveMinutes, ttsChars, quickVision, research, estimatedUSD) for today
    func today() -> (Double, Int, Int, Int, Double) {
        let d = load()[Self.dayKey()] ?? [:]
        return ((d["live_s"] ?? 0) / 60, Int(d["tts_c"] ?? 0), Int(d["qv"] ?? 0),
                Int(d["research"] ?? 0), Self.cost(of: d))
    }

    /// Estimated USD for the current calendar month
    func monthCostUSD() -> Double {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"
        let prefix = f.string(from: Date())
        return load().filter { $0.key.hasPrefix(prefix) }.values.map(Self.cost).reduce(0, +)
    }

    /// Chappy speaks up ONCE per threshold per day: $2, $5, $10
    private func maybeSpeakWarning() {
        let todayCost = Self.cost(of: load()[Self.dayKey()] ?? [:])
        var warned = (UserDefaults.standard.dictionary(forKey: spokenKey) as? [String: [Double]]) ?? [:]
        var done = warned[Self.dayKey()] ?? []
        for threshold in [2.0, 5.0, 10.0] where todayCost >= threshold && !done.contains(threshold) {
            done.append(threshold)
            warned = [Self.dayKey(): done]
            UserDefaults.standard.set(warned, forKey: spokenKey)
            DispatchQueue.main.async {
                Task { @MainActor in
                    ChappyHaptics.shared.costNudge()
                    // Spend matters most when the app is CLOSED, because that
                    // is exactly when you are not watching it.
                    ChappyNotify.announce(.money,
                        spoken: "Quick heads up - you're around \(Int(threshold)) dollars for the day.",
                        title: "AI spend today",
                        body: String(format: "About $%.0f so far today.", threshold))
                }
            }
        }
    }
}

// MARK: - Conversation Save Gate (duplicate-Records fix)
// Both LiveAIManager and OmniRealtimeViewModel can end up saving the SAME
// session (Siri-started manager + opened screen = two save paths). The gate
// lets the first save through and swallows an identical one within 5 min.
final class ConversationSaveGate {
    static let shared = ConversationSaveGate()
    private var lastFingerprint: String?
    private var lastSavedAt = Date.distantPast
    private let lock = NSLock()

    func shouldSave(fingerprint: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if fingerprint == lastFingerprint && now.timeIntervalSince(lastSavedAt) < 300 {
            print("💾 [SaveGate] Duplicate conversation save blocked")
            return false
        }
        lastFingerprint = fingerprint
        lastSavedAt = now
        return true
    }
}

final class ContextEngine: NSObject, CLLocationManagerDelegate {
    static let shared = ContextEngine()

    struct Snapshot {
        var timestamp = Date()
        var latitude: Double?
        var longitude: Double?
        var street: String?
        var suburb: String?
        var city: String?
        var country: String?
        var countryCode: String?
        var weather: String?
        var temperatureC: Double?
        var motion: String?
    }

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let motionManager = CMMotionActivityManager()
    private var started = false
    private(set) var snapshot = Snapshot()
    private var lastGeocode = Date.distantPast
    private var lastWeatherFetch = Date.distantPast

    func start() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.start() }
            return
        }
        guard !started else { return }
        started = true
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        if CMMotionActivityManager.isActivityAvailable() {
            motionManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let a = activity else { return }
                if a.walking { self?.snapshot.motion = "walking" }
                else if a.running { self?.snapshot.motion = "running" }
                else if a.cycling { self?.snapshot.motion = "cycling" }
                else if a.automotive { self?.snapshot.motion = "in a vehicle" }
                else if a.stationary { self?.snapshot.motion = "still" }
            }
        }
        print("🧭 [Context] Engine started")
    }

    /// One sentence for AI prompts — the context header every brain receives.
    func contextHeader() -> String {
        start()
        var bits: [String] = []
        let df = DateFormatter()
        df.dateFormat = "EEEE d MMMM yyyy, h:mma"
        let tz = TimeZone.current
        bits.append("It is \(df.string(from: Date())) LOCAL time, timezone \(tz.abbreviation() ?? tz.identifier)")
        var place: [String] = []
        if let s = snapshot.street { place.append(s) }
        if let s = snapshot.suburb, s != snapshot.city { place.append(s) }
        if let c = snapshot.city { place.append(c) }
        if let c = snapshot.country { place.append(c) }
        if !place.isEmpty {
            bits.append("the user is at " + place.joined(separator: ", "))
        } else if let la = snapshot.latitude, let lo = snapshot.longitude {
            // GPS locked but street name not resolved yet — still useful
            bits.append(String(format: "the user is at GPS %.4f, %.4f", la, lo))
        }
        if let w = snapshot.weather, let t = snapshot.temperatureC {
            bits.append("weather \(w), \(Int(t.rounded())) degrees C")
        }
        if let m = snapshot.motion { bits.append("the user is \(m)") }
        return bits.joined(separator: "; ") + "."
    }

    /// NAV PRECISION: street-corner accuracy while navigating, battery-light
    /// hundred-metre mode the rest of the time.
    /// Ask for Always exactly once, and only when a route actually starts.
    private var askedForAlways = false

    /// True only when Info.plist declares the `location` background mode.
    /// Touching allowsBackgroundLocationUpdates without it is a hard crash, so
    /// this is checked rather than assumed. See the note in setPrecision.
    static let backgroundLocationAllowed: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        let ok = modes.contains("location")
        print("🧭 [Context] Background location mode: \(ok ? "PRESENT" : "ABSENT — nav stops tracking when backgrounded")")
        return ok
    }()

    func setPrecision(navigating: Bool) {
        locationManager.desiredAccuracy = navigating
            ? kCLLocationAccuracyBestForNavigation
            : kCLLocationAccuracyHundredMeters
        // AUDIT FIX: with auto-pause on, iOS stops updates when it thinks you
        // are stationary and does NOT reliably resume — turns went unspoken
        // and the journal stopped. The whole product is phone-in-pocket.
        locationManager.pausesLocationUpdatesAutomatically = !navigating
        locationManager.activityType = navigating ? .otherNavigation : .other
        // AUDIT P1 (BG-LOCATION) — CONFIRMED: this was gated on
        // `.authorizedAlways`, and the app only ever calls
        // requestWhenInUseAuthorization(). So allowsBackgroundLocationUpdates
        // was NEVER set, and the moment the phone locked mid-route the location
        // updates stopped: no turn announcements, no journal, no off-route
        // detection. For an app whose entire premise is phone-in-pocket, that
        // is the difference between working and not.
        //
        // WhenInUse is enough: with allowsBackgroundLocationUpdates = true iOS
        // keeps delivering while backgrounded and shows the blue indicator, so
        // the user can always see it's tracking. Always-authorisation is only
        // needed for updates with the app fully suspended, which we ask for
        // once, at the moment it actually earns the request — the start of a
        // real route, not on launch out of nowhere.
        // ==================================================================
        // THE "NAVIGATE TO IGA" CRASH — and it is mine, from build 73.
        //
        // Apple: setting `allowsBackgroundLocationUpdates = true` when the app
        // does NOT declare `location` in UIBackgroundModes is a FATAL ERROR.
        // Not an exception you can catch — the process is killed outright.
        //
        // Before build 73 this line was gated on `.authorizedAlways`, which the
        // app never requests, so it NEVER RAN and the crash never happened. My
        // "fix" widened the gate to `.authorizedWhenInUse` — which is true — so
        // the line finally executed, and the first voice command that started a
        // real route killed the app instantly. Say "navigate to IGA", get a
        // route, hit setPrecision(navigating: true), dead.
        //
        // Exactly the same class of mistake as the audio background mode, and I
        // made it twice: assuming an entitlement is present instead of checking.
        // Now it is checked at runtime, so the app is correct whether or not
        // the Info.plist declares it — and adding the entitlement later needs
        // no code change, it just starts working.
        if navigating {
            let status = locationManager.authorizationStatus
            if Self.backgroundLocationAllowed,
               status == .authorizedAlways || status == .authorizedWhenInUse {
                locationManager.allowsBackgroundLocationUpdates = true
                locationManager.showsBackgroundLocationIndicator = true
            }
            if Self.backgroundLocationAllowed, status == .authorizedWhenInUse, !askedForAlways {
                askedForAlways = true
                locationManager.requestAlwaysAuthorization()
            }
        } else if Self.backgroundLocationAllowed {
            locationManager.allowsBackgroundLocationUpdates = false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        print("🧭 [Context] Location authorization: \(status.rawValue)")
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        snapshot.latitude = loc.coordinate.latitude
        snapshot.longitude = loc.coordinate.longitude
        snapshot.timestamp = Date()
        // PHASE 4 STEP 3: every fix feeds the journal (it self-throttles)
        TripRecorder.shared.record(location: loc)
        // PHASE 5.5: a place reminder needs no timer of its own — it rides
        // the location fix the journal is already taking, so it costs nothing.
        Task { @MainActor in
            ChappyReminders.shared.checkPlaceTriggers()
            await ChappyReminders.shared.checkLeaveBy()
            await ChappyCalendar.shared.checkLeaveBy()
            ChappyCalendar.shared.checkHeadsUp()
        }
        // PHASE 4 STEP 5: and the navigator (speaks turns when close)
        Task { @MainActor in NavEngine.shared.updateLocation(loc) }
        // BUILD 130: memory volunteers on arrival. Rides the fixes that
        // already exist rather than starting a second location manager.
        Task { @MainActor in ChappyRelevance.shared.locationUpdated(loc) }
        if Date().timeIntervalSince(lastGeocode) > 120 {
            lastGeocode = Date()
            reverseGeocode(loc)
        }
        if Date().timeIntervalSince(lastWeatherFetch) > 900 {
            lastWeatherFetch = Date()
            fetchWeather(loc)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("🧭 [Context] Location error: \(error.localizedDescription)")
    }

    private func reverseGeocode(_ loc: CLLocation) {
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            guard let p = placemarks?.first else { return }
            DispatchQueue.main.async {
                self?.snapshot.street = p.thoroughfare
                self?.snapshot.suburb = p.subLocality
                self?.snapshot.city = p.locality
                self?.snapshot.country = p.country
                self?.snapshot.countryCode = p.isoCountryCode
                print("🧭 [Context] Located: \(p.locality ?? "?"), \(p.country ?? "?")")
            }
        }
    }

    private func fetchWeather(_ loc: CLLocation) {
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(loc.coordinate.latitude)&longitude=\(loc.coordinate.longitude)&current=temperature_2m,weather_code") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any] else { return }
            DispatchQueue.main.async {
                if let t = current["temperature_2m"] as? Double { self?.snapshot.temperatureC = t }
                if let code = current["weather_code"] as? Int { self?.snapshot.weather = ContextEngine.weatherDescription(code) }
            }
        }.resume()
    }

    private static func weatherDescription(_ code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1, 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51...57: return "drizzle"
        case 61...67: return "rain"
        case 71...77: return "snow"
        case 80...82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95...99: return "thunderstorm"
        default: return "unsettled"
        }
    }
}

// MARK: - Trip Recorder (Phase 4 Step 3)
// The always-on journal: GPS breadcrumbs + named spots, near-zero battery,
// fully offline (files in Documents). Fed by ContextEngine's location
// updates; queried by voice through Live AI.

final class TripRecorder {
    static let shared = TripRecorder()

    struct Crumb: Codable {
        let t: Date
        let lat: Double
        let lon: Double
        var street: String?
        var city: String?
        var motion: String?
    }

    struct Spot: Codable {
        /// `var` so a spot can be renamed by voice straight after saving —
        /// "spot at 4:53PM" is not a memory you can use six weeks later.
        var name: String
        /// PHASE 5: the id of this spot's entry in ChappyMemory, so a rename
        /// here renames it there too. Optional so every spot saved before
        /// Phase 5 still decodes.
        var memID: UUID?
        let t: Date
        let lat: Double
        let lon: Double
        var street: String?
        var city: String?
        var country: String?
        // BUILD 158 — a saved place stops being just a pin.
        /// Free text you dictate or type: "gate code 4321, dog out back".
        var note: String?
        /// Spoken the moment you arrive within ~150 m. The killer one for
        /// job sites — the code, the parking, the dog, said before you knock.
        var arrivalNote: String?
        /// Favourites / Work / Food / Stay / Other — one tap in the list.
        var category: String?
        var starred: Bool?
        /// The real name Apple Maps knows this address by, learned lazily.
        var placeName: String?
    }

    private(set) var crumbs: [Crumb] = []
    private(set) var spots: [Spot] = []
    private var lastCrumb: Crumb?
    private let ioQueue = DispatchQueue(label: "chappy.triprecorder", qos: .utility)

    private var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var spotsURL: URL { docs.appendingPathComponent("chappy-spots.json") }
    private func crumbsURL(for date: Date) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return docs.appendingPathComponent("chappy-crumbs-\(df.string(from: date)).json")
    }
    private func notesURL(for date: Date) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return docs.appendingPathComponent("chappy-notes-\(df.string(from: date)).json")
    }
    private(set) var notes: [String] = []

    /// BUILD 99 — SILENT CAPTURE.
    /// A photo on its own is a photo. A photo with one line describing it is
    /// something you can find again: "the handwritten sign outside the warung",
    /// "the blue scooter with the dented panel". The description is what makes
    /// a gallery searchable, and it costs a fraction of a cent per shot.
    ///
    /// Deliberately built BEFORE the memory phase rather than after. Every shot
    /// taken between now and then arrives already labelled — wait, and you land
    /// in Indonesia with a gallery of unlabelled images and a memory store with
    /// nothing to work with.
    struct VisualNote: Codable, Identifiable {
        var id: UUID = UUID()
        let at: Date
        /// One line, generated quietly. Never spoken unless asked.
        var caption: String
        let lat: Double
        let lon: Double
        var street: String?
        var city: String?
        /// Small JPEG. Full resolution stays in the photo library.
        var thumbnail: Data?
        /// PHASE 5: the matching ChappyMemory entry, so a caption that lands
        /// a second after the shutter updates both.
        var memID: UUID?
    }

    private(set) var visualNotes: [VisualNote] = []

    private var visualNotesURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chappy-visual-notes.json")
    }

    func loadVisualNotes() {
        guard let d = try? Data(contentsOf: visualNotesURL),
              let n = try? JSONDecoder().decode([VisualNote].self, from: d) else { return }
        visualNotes = n
    }

    @discardableResult
    func addVisualNote(caption: String, thumbnail: Data?) -> VisualNote {
        let snap = ContextEngine.shared.snapshot
        var note = VisualNote(at: Date(), caption: caption,
                              lat: snap.latitude ?? 0, lon: snap.longitude ?? 0,
                              street: snap.street, city: snap.city,
                              thumbnail: thumbnail)
        // PHASE 5 — WRITE THROUGH TO THE ONE SPOT.
        // TripRecorder keeps its own copy because the home screen counts and
        // the "what did I photograph today" answer already read from it, and
        // breaking a certified Phase 4 path to tidy up storage is a bad trade.
        // The memory store is what SEARCH and RECALL read; this is the sensor
        // buffer that feeds it.
        let mem = ChappyMemory.shared.remember(.photo, title: caption,
                                               tags: ["snap", "photo"],
                                               thumbnail: thumbnail,
                                               source: "snap")
        note.memID = mem.id
        visualNotes.append(note)
        if visualNotes.count > 500 { visualNotes.removeFirst(visualNotes.count - 500) }
        if let d = try? JSONEncoder().encode(visualNotes) { try? d.write(to: visualNotesURL) }
        print("📸 [Trip] Visual note: \(caption)")
        return note
    }

    func updateCaption(id: UUID, to caption: String) {
        guard let i = visualNotes.firstIndex(where: { $0.id == id }) else { return }
        visualNotes[i].caption = caption
        if let mid = visualNotes[i].memID {
            ChappyMemory.shared.relabel(id: mid, to: caption)
        }
        if let d = try? JSONEncoder().encode(visualNotes) { try? d.write(to: visualNotesURL) }
        print("📸 [Trip] Captioned: \(caption)")
    }

    /// "What did I photograph today?"
    func todaysVisualNotes() -> [VisualNote] {
        visualNotes.filter { Calendar.current.isDateInToday($0.at) }
    }

    private init() {
        if let d = try? Data(contentsOf: crumbsURL(for: Date())),
           let c = try? JSONDecoder().decode([Crumb].self, from: d) {
            crumbs = c
            lastCrumb = c.last
        }
        if let d = try? Data(contentsOf: spotsURL),
           let s = try? JSONDecoder().decode([Spot].self, from: d) {
            spots = s
        }
        if let d = try? Data(contentsOf: notesURL(for: Date())),
           let n = try? JSONDecoder().decode([String].self, from: d) {
            notes = n
        }
        print("👣 [Trip] Loaded \(crumbs.count) crumbs, \(spots.count) spots, \(notes.count) notes")
    }

    /// Called by ContextEngine on every location fix; keeps only meaningful movement.
    func record(location: CLLocation) {
        // AUDIT FIX: crumbs were loaded once at launch and appended forever,
        // so after midnight yesterday's whole route was re-saved into today's
        // file and "where was I today" replayed yesterday. Roll at midnight.
        if let last = lastCrumb, !Calendar.current.isDateInToday(last.t) {
            crumbs.removeAll { !Calendar.current.isDateInToday($0.t) }
            // BUILD 52 FIX: notes are plain strings with no timestamp on them,
            // so they can't be filtered by date — they're already written to a
            // per-day file the moment they're logged, which means yesterday's
            // notes are safely on disk under yesterday's date. Clearing the
            // in-memory list is the whole job, and loses nothing.
            notes.removeAll()
            lastCrumb = nil
            print("🌅 [Trip] New day — journal rolled over")
        }
        let snap = ContextEngine.shared.snapshot
        let new = Crumb(t: Date(),
                        lat: location.coordinate.latitude,
                        lon: location.coordinate.longitude,
                        street: snap.street, city: snap.city, motion: snap.motion)
        if let last = lastCrumb {
            let dist = TripRecorder.meters(last.lat, last.lon, new.lat, new.lon)
            let dt = new.t.timeIntervalSince(last.t)
            guard dist > 25 || dt > 120 else { return }
        }
        lastCrumb = new
        crumbs.append(new)
        saveCrumbs()
    }

    @discardableResult
    func rememberSpot(named rawName: String) -> Spot {
        let snap = ContextEngine.shared.snapshot
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            let df = DateFormatter()
            df.dateFormat = "h:mma"
            name = "spot at \(df.string(from: Date()))"
            if let s = snap.street { name += " near \(s)" }
        }
        var spot = Spot(name: name, t: Date(),
                        lat: snap.latitude ?? lastCrumb?.lat ?? 0,
                        lon: snap.longitude ?? lastCrumb?.lon ?? 0,
                        street: snap.street, city: snap.city, country: snap.country)
        // PHASE 5 — write through to the one spot.
        let mem = ChappyMemory.shared.rememberAt(.place, title: name,
                                                 lat: spot.lat == 0 ? nil : spot.lat,
                                                 lon: spot.lon == 0 ? nil : spot.lon,
                                                 street: spot.street, city: spot.city,
                                                 country: spot.country,
                                                 tags: ["spot", "saved"],
                                                 source: "remember")
        spot.memID = mem.id
        spots.append(spot)
        saveSpots()
        print("📍 [Trip] Remembered spot: \(name)")
        return spot
    }

    /// BUILD 138: save a spot at EXPLICIT coordinates — starring a Trail
    /// visit from earlier in the day, or marking one as Home, must pin the
    /// place you WERE, not the place you're standing now.
    @discardableResult
    func saveSpot(named rawName: String, lat: Double, lon: Double) -> Spot {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        var spot = Spot(name: name.isEmpty ? "Starred place" : name, t: Date(),
                        lat: lat, lon: lon,
                        street: nil, city: nil, country: nil)
        let mem = ChappyMemory.shared.rememberAt(.place, title: spot.name,
                                                 lat: lat, lon: lon,
                                                 tags: ["spot", "favourite"],
                                                 source: "trail")
        spot.memID = mem.id
        spots.append(spot)
        saveSpots()
        print("📍 [Trip] Starred: \(spot.name)")
        return spot
    }

    /// Rename the spot saved most recently. Returns false if there isn't one or
    /// the name is unusable, so the caller can say something honest rather than
    /// claim a success that didn't happen.
    @discardableResult
    func renameLastSpot(to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60, !spots.isEmpty else { return false }
        spots[spots.count - 1].name = trimmed
        if let mid = spots[spots.count - 1].memID {
            ChappyMemory.shared.relabel(id: mid, to: trimmed)
        }
        saveSpots()
        print("📍 [Trip] Renamed last spot to: \(trimmed)")
        return true
    }

    /// Streets/areas passed through today, in order, plus remembered spots.
    func todaySummary() -> String {
        var route: [String] = []
        for c in crumbs {
            if let s = c.street ?? c.city, route.last != s, !route.contains(s) {
                route.append(s)
            }
        }
        var out = ""
        if route.isEmpty {
            out = "The journal has no located places yet today."
        } else {
            out = "Today the user has passed through: \(route.joined(separator: ", "))."
        }
        let todaySpots = spots.filter { Calendar.current.isDateInToday($0.t) }
        if !todaySpots.isEmpty {
            out += " Remembered spots today: \(todaySpots.map { $0.name }.joined(separator: ", "))."
        }
        if !notes.isEmpty {
            out += " Observations noted: \(notes.suffix(3).joined(separator: "; "))."
        }
        return out
    }

    /// Spoken situation report for "I'm lost".
    func lostReport() -> String {
        guard let here = lastCrumb ?? crumbs.last else {
            return "There is no location fix yet - ask the user to wait a moment while GPS settles."
        }
        var out = "The user is"
        if let s = here.street { out += " on \(s)" }
        if let c = here.city { out += ", \(c)" }
        if here.street == nil && here.city == nil { out += " at an unnamed location" }
        out += "."
        if let nearest = spots.min(by: {
            TripRecorder.meters($0.lat, $0.lon, here.lat, here.lon) < TripRecorder.meters($1.lat, $1.lon, here.lat, here.lon)
        }) {
            let d = TripRecorder.meters(nearest.lat, nearest.lon, here.lat, here.lon)
            let dir = TripRecorder.compass(from: (here.lat, here.lon), to: (nearest.lat, nearest.lon))
            out += " The nearest remembered spot is '\(nearest.name)', about \(Int(d.rounded())) meters to the \(dir)."
        }
        out += " There are \(crumbs.count) breadcrumbs recorded today, so the route back exists."
        return out
    }

    /// STEP 8: ambient noticing — Chappy's own observations, journaled.
    func addObservation(_ text: String) {
        guard !text.isEmpty else { return }
        let df = DateFormatter()
        df.dateFormat = "h:mma"
        var line = "\(df.string(from: Date())): \(text)"
        let snap = ContextEngine.shared.snapshot
        if let s = snap.street { line += " (near \(s))" }
        notes.append(line)
        // PHASE 5 — the observation itself, without the time prefix (the store
        // has a real timestamp, so a time inside the text is just noise).
        ChappyMemory.shared.remember(.note, title: text,
                                     tags: ["note", "observation"],
                                     source: "journal")
        let snapshot = notes
        let url = notesURL(for: Date())
        ioQueue.async {
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url) }
        }
        print("📝 [Trip] Observation: \(text)")
    }

    /// PHASE 5 — THE BREADCRUMB TRICK.
    ///
    /// The crumb closest in time to `when`. This is what places a photo that
    /// carries no GPS of its own: the glasses have no receiver, so a capture
    /// may arrive with a timestamp and nothing else — but the trail already
    /// knows where you were every twenty-five metres all day, app open or not.
    ///
    /// Reads the day file when the date is not today, so a photo that syncs
    /// three days late still lands in the right street.
    func nearestCrumb(to when: Date, within: TimeInterval = 900) -> Crumb? {
        let pool: [Crumb]
        if Calendar.current.isDateInToday(when) {
            pool = crumbs
        } else if let d = try? Data(contentsOf: crumbsURL(for: when)),
                  let c = try? JSONDecoder().decode([Crumb].self, from: d) {
            pool = c
        } else {
            return nil
        }
        guard let best = pool.min(by: {
            abs($0.t.timeIntervalSince(when)) < abs($1.t.timeIntervalSince(when))
        }), abs(best.t.timeIntervalSince(when)) <= within else { return nil }
        return best
    }

    /// One line for a whole day of breadcrumbs — the streets in order and the
    /// distance. Thousands of points become something you can actually read.
    func routeSummary(for day: Date) -> String {
        let pool: [Crumb]
        if Calendar.current.isDateInToday(day) { pool = crumbs }
        else if let d = try? Data(contentsOf: crumbsURL(for: day)),
                let c = try? JSONDecoder().decode([Crumb].self, from: d) { pool = c }
        else { return "" }
        guard pool.count > 2 else { return "" }
        var route: [String] = []
        for c in pool {
            if let s = c.street ?? c.city, route.last != s, !route.contains(s) { route.append(s) }
        }
        guard !route.isEmpty else { return "" }
        let total = zip(pool, pool.dropFirst()).reduce(0.0) {
            $0 + TripRecorder.meters($1.0.lat, $1.0.lon, $1.1.lat, $1.1.lon)
        }
        let dist = total >= 2000 ? String(format: "%.0f km", total / 1000)
                                 : "\(Int(total.rounded())) m"
        return route.prefix(6).joined(separator: " → ") + " — \(dist)"
    }

    /// Spoken guidance for "trace my steps back" — the day's route in reverse.
    func retraceGuidance() -> String {
        guard crumbs.count > 1 else {
            return "There are not enough breadcrumbs yet to retrace - the trail starts recording as the user moves."
        }
        var route: [String] = []
        for c in crumbs.reversed() {
            if let s = c.street ?? c.city, route.last != s, !route.contains(s) {
                route.append(s)
            }
        }
        let total = zip(crumbs, crumbs.dropFirst()).reduce(0.0) {
            $0 + TripRecorder.meters($1.0.lat, $1.0.lon, $1.1.lat, $1.1.lon)
        }
        var out = "To retrace the route back"
        if route.count > 1 {
            out += ", head back along " + route.prefix(6).joined(separator: ", then ")
        }
        out += ". The full trail today is about \(Int((total / 100).rounded()) * 100) meters."
        out += " Guide the user street by street if they ask."
        return out
    }

    private func saveCrumbs() {
        let snapshot = crumbs
        let url = crumbsURL(for: Date())
        ioQueue.async {
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url) }
        }
    }

    // MARK: - BUILD 158: places you can actually manage

    func renameSpot(id: UUID?, at index: Int, to newName: String) {
        guard spots.indices.contains(index) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        spots[index].name = trimmed
        if let mid = spots[index].memID {
            ChappyMemory.shared.relabel(id: mid, to: trimmed)
        }
        saveSpots()
    }

    func updateSpot(index: Int, note: String? = nil, arrivalNote: String? = nil,
                    category: String? = nil, starred: Bool? = nil) {
        guard spots.indices.contains(index) else { return }
        if let n = note { spots[index].note = n.isEmpty ? nil : n }
        if let a = arrivalNote { spots[index].arrivalNote = a.isEmpty ? nil : a }
        if let c = category { spots[index].category = c }
        if let st = starred {
            spots[index].starred = st
            if let mid = spots[index].memID { ChappyMemory.shared.setPinned(id: mid, st) }
        }
        saveSpots()
    }

    func deleteSpot(at index: Int) {
        guard spots.indices.contains(index) else { return }
        spots.remove(at: index)
        saveSpots()
    }

    /// The nearest saved place within 150 m — used on arrival so Chappy can
    /// speak the note you left for yourself.
    func spotNear(lat: Double, lon: Double, metres: Double = 150) -> Spot? {
        let here = CLLocation(latitude: lat, longitude: lon)
        return spots
            .filter { here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon)) < metres }
            .min { a, b in
                here.distance(from: CLLocation(latitude: a.lat, longitude: a.lon))
                    < here.distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
            }
    }

    private func saveSpots() {
        let snapshot = spots
        let url = spotsURL
        ioQueue.async {
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url) }
        }
    }

    static func meters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        CLLocation(latitude: lat1, longitude: lon1).distance(from: CLLocation(latitude: lat2, longitude: lon2))
    }

    static func compass(from a: (Double, Double), to b: (Double, Double)) -> String {
        let dLon = (b.1 - a.1) * .pi / 180
        let lat1 = a.0 * .pi / 180, lat2 = b.0 * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        let dirs = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest", "north"]
        return dirs[Int((deg + 22.5) / 45)]
    }
}

// MARK: - Nav Engine (Phase 4 Step 5)
// Voice-first turn-by-turn: Google Routes PRIMARY (best SE Asia data,
// chappy-maps key) with MapKit fallback, Google Places destination search,
// spoken geofenced turns via TTSService, off-route auto-reroute.

@MainActor
final class NavEngine: NSObject, ObservableObject {
    static let shared = NavEngine()

    struct NavStep {
        let instruction: String
        let coord: CLLocationCoordinate2D
        let distanceMeters: Double
    }

    @Published var isNavigating = false
    @Published var destinationName = ""
    @Published var nextInstruction = ""
    @Published var distanceText = ""
    @Published var routeCoords: [CLLocationCoordinate2D] = []
    @Published var destinationCoord: CLLocationCoordinate2D?

    private var steps: [NavStep] = []
    private var stepIndex = 0
    private var lastReroute = Date.distantPast
    // STEP 8: "tell me when I'm near X" watch target
    private var watchTarget: (name: String, coord: CLLocationCoordinate2D)?
    /// BUILD 158: last time each place's arrival note was spoken.
    fileprivate static var arrivalSpoken: [String: Date] = [:]

    /// STEP 8 FUSION: nav speaks through the live Chappy session when one
    /// is running (camera-aware turns); falls back to plain TTS otherwise.
    private func speakNav(_ text: String) {
        if let live = GeminiLiveService.activeInstance {
            live.announceNavStep(text)
        } else {
            TTSService.shared.speak(text)
        }
    }

    /// STEP 8: set a proximity watch — "tell me when I'm near my stop"
    func alertWhenNear(_ place: String) async -> String {
        let snap = ContextEngine.shared.snapshot
        guard let lat = snap.latitude, let lon = snap.longitude else { return "No GPS fix yet." }
        if let found = await placesSearch(query: place, lat: lat, lon: lon) {
            watchTarget = (found.1, found.0)
            return "Watch set - the user will be alerted when they are near \(found.1)."
        }
        return "Could not find \(place) nearby to watch for."
    }

    /// Last destination the user asked for — lets "navigate via car" work
    /// as a follow-up without repeating the destination.
    private(set) var lastQuery: String?
    /// Whether the last route was a driving route (for Google Maps handoff).
    private(set) var lastDriving = false
    /// Scooter routes as a vehicle but opens two-wheeler directions in Maps.
    var lastModeWasScooter = false
    /// The version of the last route summary meant for HUMAN ears — no
    /// model-directed instructions in it. Standby speaks this one.
    private(set) var spokenRouteSummary: String?

    /// Resolve a spoken destination and start guiding. Returns a summary for Chappy to speak.
    func navigate(to query: String, driving: Bool = false) async -> String {
        // BUILD 133 — "TAKE ME TO BRISBANE AIRPORT AND GET ME A COFFEE ON THE
        // WAY AND GET FUEL." One breath, three asks. The tail after the first
        // "and then"/"and get" is STOPS, not part of the place name — without
        // this cut the whole sentence went to the geocoder, which found
        // nothing, and the command died. The tail is parsed into stop queries
        // and added once the route exists.
        var query = query
        var stopTail = ""
        var cutAt: String.Index?
        for cut in [" and then ", " then get ", " and get ", " and grab ",
                    " and pick up ", " on the way"] {
            if let r = query.range(of: cut, options: .caseInsensitive),
               cutAt == nil || r.lowerBound < cutAt! {
                cutAt = r.lowerBound   // EARLIEST cut wins, whatever its phrasing
            }
        }
        if let at = cutAt {
            stopTail = String(query[at...])
            query = String(query[..<at]).trimmingCharacters(in: .whitespaces)
        }
        lastQuery = query
        lastDriving = driving
        let snap = ContextEngine.shared.snapshot
        guard let lat = snap.latitude, let lon = snap.longitude else {
            return "No GPS fix yet - ask the user to try again in a few seconds."
        }
        var destName = query
        var dest: CLLocationCoordinate2D?
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let spot = TripRecorder.shared.spots.last(where: { q.contains($0.name.lowercased()) || $0.name.lowercased().contains(q) }) {
            dest = CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lon)
            destName = spot.name
        }
        if dest == nil, let found = await placesSearch(query: query, lat: lat, lon: lon) {
            dest = found.0
            destName = found.1
        }
        // BUILD 123 — NAVIGATION WITHOUT A KEY.
        //
        // Google Places was the only way a name became coordinates. No key,
        // or a rejected one, and the whole chain died silently: no
        // destination, no route, nothing to open in Maps — and the command
        // fell through to the AI, which answered like a travel guide instead
        // of taking you anywhere.
        //
        // Apple's own local search needs NO KEY AT ALL. It is a little worse
        // in Asia, which is why Google stays first, but it means navigation
        // can never again be brought down entirely by a key problem.
        if dest == nil, let found = await appleSearch(query: query, lat: lat, lon: lon) {
            dest = found.0
            destName = found.1
            print("🗺️ [Nav] Google Places unavailable — found '\(destName)' with Apple search")
        }
        guard let destination = dest else {
            return "Could not find '\(query)' nearby - say this to the user in one short sentence and suggest a different name. Do not give travel advice about the place."
        }
        var routed = await googleRoute(fromLat: lat, fromLon: lon, to: destination, driving: driving)
        if routed == nil { routed = await mapKitRoute(fromLat: lat, fromLon: lon, to: destination, driving: driving) }
        guard let route = routed, !route.steps.isEmpty else {
            return "Could not find a \(driving ? "driving" : "walking") route to \(destName)."
        }
        steps = route.steps
        routeCoords = route.coords
        destinationCoord = destination
        destinationName = destName
        stepIndex = 0
        isNavigating = true
        ContextEngine.shared.setPrecision(navigating: true)
        updateCard()
        let mins = max(1, Int(route.durationSec / 60))
        let distText = route.distanceMeters >= 2000
            ? String(format: "%.1f kilometers", route.distanceMeters / 1000)
            : "\(Int(route.distanceMeters)) meters"
        // AUDIT FIX (SPOKEN-LEAK): this single string was returned to BOTH
        // callers. Live AI feeds it to the model, which is why it ended with a
        // model-directed instruction — but Standby speaks the return value
        // VERBATIM, so the wearer heard Chappy say the words "Also tell the
        // user:" out loud. Two audiences, two strings.
        spokenRouteSummary = "\(destName). About \(distText), roughly \(mins) minutes \(driving ? "by vehicle" : "on foot"). \(steps[0].instruction). Say 'open Google Maps' for the full map."
        // BUILD 132 — ONE VOICE ON THE ROAD: render every line this route can
        // ever speak into the voice cache NOW, while there's still signal.
        // Each turn then plays from disk in the real voice, instantly, even
        // if the network dies mid-drive.
        prerenderRouteVoice()
        // BUILD 133: stops asked for in the same breath as the destination.
        if !stopTail.isEmpty {
            let wants = ChappyStandby.parseStopQueries(from: stopTail.lowercased())
            if !wants.isEmpty {
                let added = await addStops(wants)
                spokenRouteSummary = "\(destName). About \(distText), roughly \(mins) minutes \(driving ? "by vehicle" : "on foot"). \(added)"
                return "Route to \(destName) found with stops. \(added) Tell the user briefly."
            }
        }
        return "Route to \(destName) found: about \(distText), roughly \(mins) minutes \(driving ? "driving" : "walking"). First step: \(steps[0].instruction). Also tell the user: say 'open Google Maps' anytime for the full map with turn-by-turn on screen."
    }

    /// PHASE 5 — "take me back" from a memory card.
    ///
    /// Deliberately does NOT re-run the place search. The memory already holds
    /// the exact coordinates you stood at; looking the name up again finds a
    /// DIFFERENT warung with the same name three streets over, which is the
    /// single most annoying way for a memory to be wrong.
    func navigateBack(to dest: CLLocationCoordinate2D, name: String, driving: Bool = false) {
        Task { @MainActor in
            let snap = ContextEngine.shared.snapshot
            guard let lat = snap.latitude, let lon = snap.longitude else {
                TTSService.shared.speak("No GPS fix yet - give it a few seconds and try again.")
                return
            }
            var routed = await googleRoute(fromLat: lat, fromLon: lon, to: dest, driving: driving)
            if routed == nil {
                routed = await mapKitRoute(fromLat: lat, fromLon: lon, to: dest, driving: driving)
            }
            guard let route = routed, !route.steps.isEmpty else {
                TTSService.shared.speak("I couldn't find a route back to \(name).")
                return
            }
            steps = route.steps
            routeCoords = route.coords
            destinationCoord = dest
            destinationName = name
            stepIndex = 0
            isNavigating = true
            ContextEngine.shared.setPrecision(navigating: true)
            updateCard()
            let mins = max(1, Int(route.durationSec / 60))
            let line = "Back to \(name). Roughly \(mins) minutes \(driving ? "by vehicle" : "on foot"). \(route.steps[0].instruction)"
            spokenRouteSummary = line
            prerenderRouteVoice()
            TTSService.shared.speak(line)
        }
    }

    /// BUILD 133 — STOPS ON THE WAY.
    ///
    /// "Get me a coffee on the way and get fuel." Each ask is resolved to a
    /// real place biased PARTWAY ALONG the trip — a third in for the first
    /// stop, two-thirds for the next — so the coffee isn't behind you and the
    /// fuel isn't at the destination. Then the whole run, stops included, is
    /// handed to Google Maps, which is genuinely better at multi-stop driving
    /// than Chappy's own turn-by-turn will ever be. Chappy's job is done the
    /// moment the trip is BUILT.
    var pendingHandoffURL: URL?

    func addStops(_ queries: [String]) async -> String {
        guard let dest = destinationCoord else {
            return "No route on yet. Where are we headed first?"
        }
        let snap = ContextEngine.shared.snapshot
        guard let lat = snap.latitude, let lon = snap.longitude else { return "No GPS fix yet." }
        var found: [(CLLocationCoordinate2D, String)] = []
        var frac = 0.33
        for q in queries.prefix(3) {
            let midLat = lat + (dest.latitude - lat) * frac
            let midLon = lon + (dest.longitude - lon) * frac
            var hit = await placesSearch(query: q, lat: midLat, lon: midLon)
            if hit == nil { hit = await appleSearch(query: q, lat: midLat, lon: midLon) }
            if let hit { found.append(hit) }
            frac = min(0.7, frac + 0.25)
        }
        guard !found.isEmpty else { return "Couldn't find that along the route." }
        let travel = lastDriving || lastModeWasScooter ? "driving" : "walking"
        let wp = found.map { "\($0.0.latitude),\($0.0.longitude)" }
            .joined(separator: "%7C")
        pendingHandoffURL = URL(string:
            "https://www.google.com/maps/dir/?api=1&destination=\(dest.latitude),\(dest.longitude)&waypoints=\(wp)&travelmode=\(travel)")
        NotificationCenter.default.post(name: .chappyOpenGoogleMaps, object: nil)
        let names = found.map { $0.1 }.joined(separator: ", then ")
        return "Added \(names). Google Maps has the full run."
    }

    /// BUILD 132: everything the current route could say, cached ahead of time
    /// so nav never falls back to the robot voice mid-drive.
    private func prerenderRouteVoice() {
        var lines = steps.map { $0.instruction }
        if let summary = spokenRouteSummary { lines.append(summary) }
        if !destinationName.isEmpty {
            lines.append("You have arrived at \(destinationName).")
        }
        lines.append("You've come off the route. Give me a second.")
        TTSService.shared.prerender(lines)
    }

    /// PHASE 5.5 — how long it would actually take to get there, for leave-by
    /// warnings. Deliberately does not start navigation or touch any state;
    /// it is a question, not a command.
    func travelMinutes(to query: String, driving: Bool = true) async -> Int? {
        (await travelEstimate(to: query, driving: driving))?.mins
    }

    /// BUILD 153 — the fuller answer ChappyRide needs: minutes AND
    /// kilometres AND the resolved point, still without touching nav state.
    func travelEstimate(to query: String, driving: Bool = true)
        async -> (mins: Int, km: Double, coord: CLLocationCoordinate2D, name: String)? {
        let snap = ContextEngine.shared.snapshot
        guard let lat = snap.latitude, let lon = snap.longitude, !query.isEmpty else { return nil }
        var dest: CLLocationCoordinate2D?
        var name = query
        let q = query.lowercased()
        if let spot = TripRecorder.shared.spots.last(where: {
            q.contains($0.name.lowercased()) || $0.name.lowercased().contains(q) }) {
            dest = CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lon)
            name = spot.name
        }
        if dest == nil, let found = await placesSearch(query: query, lat: lat, lon: lon) {
            dest = found.0; name = found.1
        }
        if dest == nil, let found = await appleSearch(query: query, lat: lat, lon: lon) {
            dest = found.0; name = found.1
        }
        guard let d = dest else { return nil }
        var routed = await googleRoute(fromLat: lat, fromLon: lon, to: d, driving: driving)
        if routed == nil { routed = await mapKitRoute(fromLat: lat, fromLon: lon, to: d, driving: driving) }
        guard let r = routed else { return nil }
        return (max(1, Int(r.durationSec / 60)), r.distanceMeters / 1000.0, d, name)
    }

    /// Keyless place lookup. MKLocalSearch uses Apple's own maps data and
    /// needs no API key, no billing account and no configuration — so it is
    /// the floor under the whole navigation stack.
    private func appleSearch(query: String, lat: Double, lon: Double)
        async -> (CLLocationCoordinate2D, String)? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            latitudinalMeters: 40000, longitudinalMeters: 40000)
        guard let response = try? await MKLocalSearch(request: req).start(),
              let item = response.mapItems.first else { return nil }
        let coord = item.placemark.coordinate
        let name = item.name ?? query
        return (coord, name)
    }

    func getHome() async -> String {
        if let home = TripRecorder.shared.spots.last(where: { ["home", "hotel", "my hotel", "the hotel"].contains($0.name.lowercased()) }) {
            return await navigate(to: home.name)
        }
        return "No spot named home or hotel is saved yet. Tell the user: stand at your hotel and say remember this spot, call it home."
    }

    func stop(announce: Bool = false) {
        isNavigating = false
        ContextEngine.shared.setPrecision(navigating: false)
        steps = []
        routeCoords = []
        nextInstruction = ""
        distanceText = ""
        destinationCoord = nil
        if announce { TTSService.shared.speak("Route's off.") }
    }

    /// Fed by ContextEngine on every fix: speaks turns, detects off-route.
    func updateLocation(_ loc: CLLocation) {
        // STEP 8: proximity watch fires even when not navigating
        // BUILD 158 — ARRIVAL NOTES. The single most useful thing a saved
        // place can do: say the thing you left for yourself, before you
        // knock. Gate codes, parking, the dog, which door. Fires once per
        // place per hour so a long job never nags.
        if let spot = TripRecorder.shared.spotNear(lat: loc.coordinate.latitude,
                                                   lon: loc.coordinate.longitude),
           let note = spot.arrivalNote, !note.isEmpty,
           Self.arrivalSpoken[spot.name].map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            Self.arrivalSpoken[spot.name] = Date()
            ChappyNotify.announce(.nav,
                spoken: "\(spot.name): \(note)",
                title: "📍 \(spot.name)", body: note)
        }
        if let w = watchTarget {
            let dw = loc.distance(from: CLLocation(latitude: w.coord.latitude, longitude: w.coord.longitude))
            if dw < 150 {
                watchTarget = nil
                ChappyHaptics.shared.proximity()
                ChappyNotify.post(.nav, title: "You're near it", body: w.name, opens: .chappyShowMap)
                speakNav("\(w.name) is about \(Int(dw)) meters away.")
            }
        }
        guard isNavigating, stepIndex < steps.count else { return }
        let step = steps[stepIndex]
        let d = loc.distance(from: CLLocation(latitude: step.coord.latitude, longitude: step.coord.longitude))
        distanceText = d > 950 ? String(format: "%.1f km", d / 1000) : "\(Int(d)) m"
        // SPEED-AWARE TURNS: announce ~8 seconds before the corner at your
        // ACTUAL speed. Walking (~1.4 m/s) → ~25m as before; scooter at
        // 40 km/h (~11 m/s) → ~90m warning; capped at 200m for highways.
        let speed = max(loc.speed, 0) // m/s, -1 when unknown → treat as 0
        let lookahead = min(max(25.0, speed * 8.0), 200.0)
        if d < lookahead {
            stepIndex += 1
            if stepIndex >= steps.count {
                ChappyHaptics.shared.arrival()
                // GAP CLOSED: you could route somewhere, walk there and arrive,
                // and nothing was ever written down. The .route category existed
                // and nothing wrote to it.
                ChappyMemory.shared.remember(.route,
                    title: "Went to \(destinationName)",
                    tags: ["arrived", "navigation"],
                    source: "nav")
                // Arriving is the one nav event worth a banner — you get it
                // with the phone in a pocket, or find it later on the lock
                // screen if you missed the voice. Turns are NOT notified:
                // a banner per corner is how you learn to ignore all of them.
                ChappyNotify.post(.nav, title: "Arrived",
                                  body: destinationName, opens: .chappyShowMap)
                speakNav("You have arrived at \(destinationName).")
                stop()
                return
            }
            // HAPTIC TURN LANGUAGE: feel the turn as well as hear it
            let instr = steps[stepIndex].instruction.lowercased()
            if instr.contains("left") { ChappyHaptics.shared.leftTurn() }
            else if instr.contains("right") { ChappyHaptics.shared.rightTurn() }
            else { ChappyHaptics.shared.straightStep() }
            speakNav(steps[stepIndex].instruction)
            updateCard()
        } else if Date().timeIntervalSince(lastReroute) > 30, !routeCoords.isEmpty {
            let nearest = routeCoords.map { loc.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }.min() ?? 0
            if nearest > 60 {
                lastReroute = Date()
                ChappyHaptics.shared.offRoute()
                speakNav("You've come off the route. Give me a second.")
                let name = destinationName
                Task { _ = await self.navigate(to: name) }
            }
        }
    }

    private func updateCard() {
        guard stepIndex < steps.count else { return }
        nextInstruction = steps[stepIndex].instruction
    }

    private struct Routed {
        let steps: [NavStep]
        let coords: [CLLocationCoordinate2D]
        let distanceMeters: Double
        let durationSec: Double
    }

    private func googleRoute(fromLat: Double, fromLon: Double, to: CLLocationCoordinate2D, driving: Bool = false) async -> Routed? {
        let key = APIKeyManager.shared.getMapsAPIKey() ?? ""
        guard !key.isEmpty, let url = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue("routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.legs.steps.navigationInstruction,routes.legs.steps.endLocation,routes.legs.steps.distanceMeters", forHTTPHeaderField: "X-Goog-FieldMask")
        let body: [String: Any] = [
            "origin": ["location": ["latLng": ["latitude": fromLat, "longitude": fromLon]]],
            "destination": ["location": ["latLng": ["latitude": to.latitude, "longitude": to.longitude]]],
            "travelMode": driving ? "DRIVE" : "WALK"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = json["routes"] as? [[String: Any]], let r = routes.first else {
            print("🗺️ [Nav] Google route failed (\((resp as? HTTPURLResponse)?.statusCode ?? -1)) — MapKit fallback")
            return nil
        }
        var navSteps: [NavStep] = []
        for leg in (r["legs"] as? [[String: Any]] ?? []) {
            for s in (leg["steps"] as? [[String: Any]] ?? []) {
                let instr = ((s["navigationInstruction"] as? [String: Any])?["instructions"] as? String) ?? "Continue"
                let end = ((s["endLocation"] as? [String: Any])?["latLng"] as? [String: Any])
                let c = CLLocationCoordinate2D(latitude: end?["latitude"] as? Double ?? 0,
                                               longitude: end?["longitude"] as? Double ?? 0)
                let dm = (s["distanceMeters"] as? Double) ?? Double(s["distanceMeters"] as? Int ?? 0)
                navSteps.append(NavStep(instruction: instr, coord: c, distanceMeters: dm))
            }
        }
        let dist = (r["distanceMeters"] as? Double) ?? Double(r["distanceMeters"] as? Int ?? 0)
        var dur = 0.0
        if let ds = r["duration"] as? String { dur = Double(ds.replacingOccurrences(of: "s", with: "")) ?? 0 }
        let poly = ((r["polyline"] as? [String: Any])?["encodedPolyline"] as? String).map(NavEngine.decodePolyline) ?? []
        print("🗺️ [Nav] Google route OK: \(navSteps.count) steps, \(Int(dist))m")
        return Routed(steps: navSteps, coords: poly, distanceMeters: dist, durationSec: dur)
    }

    private func mapKitRoute(fromLat: Double, fromLon: Double, to: CLLocationCoordinate2D, driving: Bool = false) async -> Routed? {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: fromLat, longitude: fromLon)))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        req.transportType = driving ? .automobile : .walking
        guard let resp = try? await MKDirections(request: req).calculate(), let route = resp.routes.first else { return nil }
        var navSteps: [NavStep] = []
        for s in route.steps where !s.instructions.isEmpty {
            let pc = s.polyline.pointCount
            var cs = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pc)
            s.polyline.getCoordinates(&cs, range: NSRange(location: 0, length: pc))
            navSteps.append(NavStep(instruction: s.instructions, coord: cs.last ?? to, distanceMeters: s.distance))
        }
        let pc = route.polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pc)
        route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pc))
        print("🗺️ [Nav] MapKit route OK: \(navSteps.count) steps")
        return Routed(steps: navSteps, coords: coords, distanceMeters: route.distance, durationSec: route.expectedTravelTime)
    }

    private func placesSearch(query: String, lat: Double, lon: Double) async -> (CLLocationCoordinate2D, String)? {
        let key = APIKeyManager.shared.getMapsAPIKey() ?? ""
        guard !key.isEmpty, let url = URL(string: "https://places.googleapis.com/v1/places:searchText") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue("places.displayName,places.location", forHTTPHeaderField: "X-Goog-FieldMask")
        let body: [String: Any] = [
            "textQuery": query,
            "locationBias": ["circle": ["center": ["latitude": lat, "longitude": lon], "radius": 15000.0]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let places = json["places"] as? [[String: Any]], let p = places.first,
              let locd = p["location"] as? [String: Any],
              let la = locd["latitude"] as? Double, let lo = locd["longitude"] as? Double else { return nil }
        let name = ((p["displayName"] as? [String: Any])?["text"] as? String) ?? query
        print("🗺️ [Nav] Places found: \(name)")
        return (CLLocationCoordinate2D(latitude: la, longitude: lo), name)
    }

    nonisolated static func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0, lon = 0
        while index < encoded.endIndex {
            for pair in 0..<2 {
                var result = 0, shift = 0, b = 0
                repeat {
                    guard index < encoded.endIndex else { return coords }
                    b = Int(encoded[index].asciiValue ?? 63) - 63
                    index = encoded.index(after: index)
                    result |= (b & 0x1F) << shift
                    shift += 5
                } while b >= 0x20
                let delta = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                if pair == 0 { lat += delta } else { lon += delta }
            }
            coords.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
        }
        return coords
    }
}


// =====================================================================
// MARK: - CHAPPY MEMORY (PHASE 5 — STEP 1: THE ONE SPOT)
// =====================================================================
//
// Everything Chappy remembers now lands in ONE place, in ONE format.
//
// Before this, memory was scattered across four different files with four
// different shapes: spots in chappy-spots.json, observations in
// chappy-notes-<date>.json, photos in chappy-visual-notes.json, and
// translate conversations nowhere at all. Nothing could be searched across,
// nothing shared a timestamp format, and "what was that place on Tuesday"
// had no single thing to ask.
//
// WHY AN APPEND-ONLY LOG AND NOT A DATABASE
// SQLite was the plan on paper. A log won for four practical reasons that
// matter more on a phone in Indonesia than they do on a desk:
//   1. CRASH-SAFE BY CONSTRUCTION. A memory is one line, written once, never
//      rewritten. A crash mid-write loses at most the line being written —
//      never the file. Every rewrite-the-whole-array store we already have
//      can lose the lot.
//   2. NO MIGRATIONS. Adding a field to a JSON line is free. Adding a column
//      to SQLite on a phone you cannot debug in the field is not.
//   3. HUMAN-READABLE. Every entry is a line of text you can read, grep,
//      export, or email to yourself. If the app ever dies for good, the
//      memories survive as a folder of readable files.
//   4. DELETABLE BY DAY. One file per day means "forget last Tuesday" is a
//      file deletion, not a query.
// Speed is not a concern at this scale: a heavy day is ~40 KB, a year ~15 MB,
// and search only ever parses the days it needs.
//
// TWO LEVELS
//   RAW LOG      — every event, timestamped, categorised, located.
//   DAY SUMMARY  — one paragraph per day, written after the fact.
// Recall over months reads summaries first (small, fast, cheap to feed an AI)
// and only drills into the raw log for the day it lands on. That is the same
// shape a human diary has, and for the same reason.
//
// WHAT IS NOT STORED
// Credentials, tokens, passwords — never, by law of the master plan. Full-
// resolution photos stay in the photo library; memory keeps a thumbnail.
// Verbatim translate transcripts carry an expiry (see `expires`) because a
// recording of somebody else talking is not the same kind of thing as a note
// you wrote about your own day.

final class ChappyMemory: ObservableObject {
    static let shared = ChappyMemory()

    // MARK: Categories
    //
    // Deliberately few. Nine buckets a person can hold in their head beats
    // forty an algorithm assigned. Free-text `tags` carry the fine detail.
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case place        // a spot you saved
        case photo        // a silent snap, captioned
        case video        // a clip the glasses recorded, summarised
        case note         // an observation, yours or Chappy's
        case talk         // a translated conversation
        case scan         // a document or menu read
        case route        // somewhere you navigated to
        case ask          // something you asked and the answer
        case spend        // money noted
        case day          // the day's own summary paragraph
        case reminder     // a memory with a trigger on it
        case appointment  // something that was in the diary and has happened

        var id: String { rawValue }

        var label: String {
            switch self {
            case .place: return "Places"
            case .photo: return "Photos"
            case .video: return "Videos"
            case .note:  return "Notes"
            case .talk:  return "Talks"
            case .scan:  return "Scans"
            case .route: return "Trips"
            case .ask:   return "Asked"
            case .spend: return "Spend"
            case .day:   return "Days"
            case .reminder: return "Reminders"
            case .appointment: return "Diary"
            }
        }

        var icon: String {
            switch self {
            case .place: return "mappin.circle.fill"
            case .photo: return "camera.fill"
            case .video: return "video.fill"
            case .note:  return "text.alignleft"
            case .talk:  return "bubble.left.and.bubble.right.fill"
            case .scan:  return "doc.text.viewfinder"
            case .route: return "arrow.triangle.turn.up.right.circle.fill"
            case .ask:   return "questionmark.circle.fill"
            case .spend: return "creditcard.fill"
            case .day:   return "book.closed.fill"
            case .reminder: return "bell.fill"
            case .appointment: return "calendar"
            }
        }
    }

    // MARK: The entry
    //
    // Every field except id/at/kind/title is optional on purpose: a memory
    // written with no GPS fix is still a memory, and refusing to store it
    // because the sky was cloudy is how you end up with gaps.
    struct Entry: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        /// WHEN. Always set. Encoded as ISO-8601 so the raw file is readable.
        var at: Date
        /// WHAT KIND. The one required category.
        var kind: Kind
        /// THE LABEL — one short line, the thing you read in a list.
        var title: String
        /// THE DETAIL — the full text, if there is more than the label.
        var body: String = ""
        /// WHERE.
        var lat: Double?
        var lon: Double?
        var street: String?
        var city: String?
        var country: String?
        /// A resolved place name when one is known (Phase 5 Step 4 fills this
        /// from Google Places; stored as TEXT so it works offline forever).
        var place: String?
        /// Free-text tags for search. Lowercase, no spaces inside a tag.
        var tags: [String] = []
        /// True when a thumbnail JPEG exists on disk under this id.
        var hasPhoto: Bool = false
        /// Pinned memories survive every sweep and sort to the top of a day.
        var pinned: Bool = false
        /// Set for anything that should age out on its own. Nil = keep forever.
        var expires: Date?
        /// Which part of Chappy wrote this. Useful when a module misbehaves.
        var source: String = ""
        // ===== REMINDER FIELDS (PHASE 5.5) =====
        // All optional, so every memory written before reminders existed still
        // decodes, and a memory becomes a reminder by gaining a trigger rather
        // than by being copied into a second store.
        /// The moment it should fire. Nil for a place-only reminder.
        var dueAt: Date?
        /// FLOATING TIME, "HH:mm". Set instead of dueAt when the reminder means
        /// "8am wherever I am" rather than a fixed instant. This is the field
        /// every other assistant is missing, and it is the one that breaks the
        /// day you change country.
        var floatingTime: String?
        /// Compact repeat rule — "d3" every 3 days, "d3!" every 3 days AFTER
        /// COMPLETION, "w1:mon,fri" weekly on those days, "m1" monthly.
        var repeatRule: String?
        /// A place name or keyword that fires it instead of a clock.
        var placeTrigger: String?
        /// Minutes of buffer on top of real travel time for a leave-by warning.
        var leadMinutes: Int?
        /// When it was ticked off. Nil means still open.
        var doneAt: Date?
        /// Snooze wins over dueAt while it is in the future.
        var snoozedTo: Date?
        /// Time-sensitive: pierces Focus and the notification summary.
        var escalate: Bool?
        /// When it actually reached him. Logged so a reminder that fired while
        /// he was asleep is recoverable rather than silently lost.
        var deliveredAt: Date?

        /// Snooze beats the original time; a floating time resolves against
        /// TODAY in whatever zone the phone is in right now.
        var effectiveFire: Date? {
            if let s = snoozedTo, s > Date() { return s }
            if let hhmm = floatingTime, let p = ChappyReminders.hhmm(hhmm) {
                let cal = Calendar.current
                let today = cal.date(bySettingHour: p.0, minute: p.1, second: 0, of: Date())
                if let t = today, t >= Date() || Calendar.current.isDateInToday(t) { return t }
                return today
            }
            return snoozedTo ?? dueAt
        }

        /// PHOTO LIBRARY LINK. The PhotoKit local identifier of the original,
        /// for anything imported from the glasses. Memory holds a thumbnail
        /// and a summary; the full-resolution file stays in the library and
        /// this is how we get back to it. Nil for everything Chappy made itself.
        var assetID: String?

        /// One line for a list row, and for feeding an AI cheaply.
        var oneLine: String {
            var s = title
            if let p = place ?? street ?? city, !p.isEmpty { s += " — \(p)" }
            return s
        }

        /// Everything searchable about this entry, folded once.
        var searchBlob: String {
            ([title, body, place ?? "", street ?? "", city ?? "", country ?? ""]
                + tags + [kind.rawValue, kind.label])
                .joined(separator: " ")
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }
    }

    // MARK: Published state (UI reads this; only ever written on main)
    @Published private(set) var recent: [Entry] = []
    @Published private(set) var isSearchingDisk = false
    @Published private(set) var lastError: String?

    /// How many days of log are held in memory for instant search.
    /// Older days live on disk and are read only when a search asks for them.
    static let hotDays = 30

    private let io = DispatchQueue(label: "chappy.memory.io", qos: .utility)
    private let thumbCache = NSCache<NSString, UIImage>()
    private var summaries: [String: String] = [:]   // "yyyy-MM-dd" -> paragraph

    // MARK: Paths

    private var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    /// Documents/ChappyMemory/
    ///
    /// NOT `lazy`. A lazy var is initialised on whichever thread touches it
    /// first and Swift does not synchronise that — and these are touched from
    /// the main thread (a write starting) and the io queue (a search running)
    /// at the same time. Built eagerly by a static function instead, which
    /// runs once, before anything can race for it.
    private static func makeDir(_ sub: String?) -> URL {
        var u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChappyMemory", isDirectory: true)
        if let s = sub { u = u.appendingPathComponent(s, isDirectory: true) }
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private(set) var root: URL = ChappyMemory.makeDir(nil)
    private var thumbsDir: URL = ChappyMemory.makeDir("thumbs")
    private var summariesURL: URL { root.appendingPathComponent("summaries.json") }

    static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func dayKey(_ d: Date) -> String { dayKeyFormatter.string(from: d) }

    private func dayURL(_ d: Date) -> URL {
        root.appendingPathComponent("day-\(Self.dayKey(d)).jsonl")
    }
    private func thumbURL(_ id: UUID) -> URL {
        thumbsDir.appendingPathComponent("\(id.uuidString).jpg")
    }

    // MARK: Codec
    //
    // One encoder/decoder, made once. JSONEncoder is not cheap to build and
    // this runs on every single memory written.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601      // readable in the raw file
        e.outputFormatting = []                // ONE LINE per entry — required
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        loadSummaries()
        loadHotDays()
    }

    // MARK: - Writing

    /// THE ONE WAY IN. Every module that wants to remember something calls
    /// this and nothing else.
    ///
    /// Returns the stored entry so a caller can update it later (a photo whose
    /// caption arrives from the network a second after the shutter, say).
    @discardableResult
    func remember(_ kind: Kind,
                  title: String,
                  body: String = "",
                  tags: [String] = [],
                  thumbnail: Data? = nil,
                  expiresInDays: Int? = nil,
                  source: String = "",
                  at when: Date = Date(),
                  assetID: String? = nil) -> Entry {

        let snap = ContextEngine.shared.snapshot
        var e = Entry(at: when, kind: kind,
                      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                      body: body)
        e.lat = snap.latitude
        e.lon = snap.longitude
        e.street = snap.street
        e.city = snap.city
        e.country = snap.country
        e.tags = normalise(tags)
        e.source = source
        e.assetID = assetID
        e.hasPhoto = (thumbnail != nil)
        if let d = expiresInDays {
            e.expires = Calendar.current.date(byAdding: .day, value: d, to: when)
        }
        if e.title.isEmpty { e.title = fallbackTitle(for: kind, at: when) }

        write(e, thumbnail: thumbnail)
        return e
    }

    /// Store an entry that already knows its own location (migration, or a
    /// memory about somewhere you are not standing right now).
    @discardableResult
    func rememberAt(_ kind: Kind, title: String, body: String = "",
                    lat: Double?, lon: Double?, street: String? = nil,
                    city: String? = nil, country: String? = nil,
                    tags: [String] = [], thumbnail: Data? = nil,
                    expiresInDays: Int? = nil, source: String = "",
                    at when: Date = Date(), assetID: String? = nil) -> Entry {
        var e = Entry(at: when, kind: kind,
                      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                      body: body)
        e.lat = lat; e.lon = lon
        e.street = street; e.city = city; e.country = country
        e.tags = normalise(tags)
        e.source = source
        e.assetID = assetID
        e.hasPhoto = (thumbnail != nil)
        if let d = expiresInDays {
            e.expires = Calendar.current.date(byAdding: .day, value: d, to: when)
        }
        if e.title.isEmpty { e.title = fallbackTitle(for: kind, at: when) }
        write(e, thumbnail: thumbnail)
        return e
    }

    /// Append one line to the day file. Never rewrites, never blocks the caller.
    private func write(_ e: Entry, thumbnail: Data?) {
        // Publish immediately so the UI and any in-flight search see it now.
        setRecent(insert: e)

        let url = dayURL(e.at)
        let thumbURL = self.thumbURL(e.id)
        io.async { [weak self] in
            guard let self else { return }
            guard var line = try? self.encoder.encode(e) else {
                self.setError("Could not encode a memory"); return
            }
            line.append(0x0A)   // newline — this is what makes it a JSONL file
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    // APPEND. The whole point: never rewrite what is already safe.
                    let h = try FileHandle(forWritingTo: url)
                    defer { try? h.close() }
                    try h.seekToEnd()
                    try h.write(contentsOf: line)
                } else {
                    try line.write(to: url, options: .atomic)
                }
                if let t = thumbnail { try? t.write(to: thumbURL, options: .atomic) }
            } catch {
                self.setError("Memory write failed: \(error.localizedDescription)")
                print("⚠️ [Memory] write failed: \(error.localizedDescription)")
            }
        }
        print("🧠 [Memory] \(e.kind.rawValue): \(e.title)")
    }

    /// Change the label of an entry already written (captions arrive late;
    /// spots get renamed by voice two seconds after being saved).
    func relabel(id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(id: id) { $0.title = trimmed }
    }

    /// Overwrite a whole entry in place. Reminders change often — snoozed,
    /// completed, rescheduled — and each of those is a whole-record edit
    /// rather than a one-field patch.
    func replaceReminderFields(_ e: Entry) {
        mutate(id: e.id) { $0 = e }
    }

    /// BUILD 126: a snapped photo is filed the instant it exists, with the
    /// placeholder title "Photo", because the picture must never be lost
    /// waiting on a network call. The AI caption arrives a second or two later
    /// and replaces it. Nothing else in the store needed a title edit before.
    func setTitle(id: UUID, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutate(id: id) { $0.title = t }
    }

    func setPinned(id: UUID, _ pinned: Bool) {
        mutate(id: id) { $0.pinned = pinned; if pinned { $0.expires = nil } }
    }

    func addTag(id: UUID, _ tag: String) {
        let t = normalise([tag])
        guard let first = t.first else { return }
        mutate(id: id) { if !$0.tags.contains(first) { $0.tags.append(first) } }
    }

    /// A rewrite of ONE day file. Rare by design — the log is append-only for
    /// everything that happens in the normal course of a day, and this path
    /// only runs when you deliberately edit or delete a memory.
    private func mutate(id: UUID, _ change: @escaping (inout Entry) -> Void) {
        guard let existing = (recent.first { $0.id == id }) else {
            // Not hot — find it on disk.
            io.async { [weak self] in
                guard let self else { return }
                for url in self.dayFiles() {
                    var entries = self.readDay(url)
                    guard let i = entries.firstIndex(where: { $0.id == id }) else { continue }
                    change(&entries[i])
                    self.rewrite(day: url, entries: entries)
                    let updated = entries[i]
                    self.setRecent(replace: updated)
                    return
                }
            }
            return
        }
        var copy = existing
        change(&copy)
        setRecent(replace: copy)
        let url = dayURL(copy.at)
        io.async { [weak self] in
            guard let self else { return }
            var entries = self.readDay(url)
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i] = copy
                self.rewrite(day: url, entries: entries)
            }
        }
    }

    /// Delete one memory (and its thumbnail).
    func forget(id: UUID) {
        setRecent(remove: id)
        let thumb = thumbURL(id)
        io.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: thumb)
            for url in self.dayFiles() {
                var entries = self.readDay(url)
                guard entries.contains(where: { $0.id == id }) else { continue }
                entries.removeAll { $0.id == id }
                self.rewrite(day: url, entries: entries)
                return
            }
        }
    }

    /// BUILD 132 — THE CLEAN-UP THE STORE ALREADY NEEDED.
    ///
    /// Builds 130-131 filed ambient pulse captions with two blind spots: dedup
    /// only looked one frame back, and model junk ("Word Count & Style
    /// Check:**") was never filtered. Both are fixed at the source in
    /// ChappyPulse — this sweep deals with what already leaked in. It walks
    /// every day file once, drops pulse junk, and collapses pulse entries with
    /// identical titles down to the newest one. Pinned entries are untouchable,
    /// deliberate memories (snap, voice, photo ingest) are not pulse and are
    /// never considered. Runs once; a flag remembers it's been done.
    func sweepPulseJunk() {
        let flagKey = "chappy_pulse_sweep_132"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        UserDefaults.standard.set(true, forKey: flagKey)
        io.async { [weak self] in
            guard let self else { return }
            let junkBits = ["word count", "style check", "**", "here is", "here's a"]
            var newestByTitle: [String: (id: UUID, at: Date)] = [:]
            var removedIDs: [UUID] = []

            // Pass one, newest file first: learn which entry OWNS each title.
            let files = self.dayFiles().sorted { $0.lastPathComponent > $1.lastPathComponent }
            for url in files {
                for e in self.readDay(url) where !e.pinned {
                    guard e.source == "pulse" || e.tags.contains("pulse") else { continue }
                    let norm = e.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if newestByTitle[norm] == nil || e.at > newestByTitle[norm]!.at {
                        newestByTitle[norm] = (e.id, e.at)
                    }
                }
            }
            // Pass two: rewrite each day without the junk and the also-rans.
            for url in files {
                let entries = self.readDay(url)
                let kept = entries.filter { e in
                    guard !e.pinned,
                          e.source == "pulse" || e.tags.contains("pulse") else { return true }
                    let norm = e.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    let isJunk = norm.isEmpty || norm.hasSuffix(":")
                        || junkBits.contains { norm.contains($0) }
                    let isDupe = newestByTitle[norm].map { $0.id != e.id } ?? false
                    if isJunk || isDupe {
                        removedIDs.append(e.id)
                        if e.hasPhoto {
                            try? FileManager.default.removeItem(at: self.thumbURL(e.id))
                        }
                        return false
                    }
                    return true
                }
                if kept.count != entries.count {
                    self.rewrite(day: url, entries: kept)
                }
            }
            guard !removedIDs.isEmpty else { return }
            print("🧹 [Memory] Pulse sweep removed \(removedIDs.count) junk/duplicate entries")
            DispatchQueue.main.async {
                for id in removedIDs { self.setRecent(remove: id) }
            }
        }
    }

    /// Delete a whole day. One file, one deletion — this is the reason the
    /// log is split by day in the first place.
    func forgetDay(_ d: Date) {
        let url = dayURL(d)
        let key = Self.dayKey(d)
        let ids = recent.filter { Self.dayKey($0.at) == key }.map { $0.id }
        for i in ids { setRecent(remove: i) }
        io.async { [weak self] in
            guard let self else { return }
            for e in self.readDay(url) where e.hasPhoto {
                try? FileManager.default.removeItem(at: self.thumbURL(e.id))
            }
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                self.summaries.removeValue(forKey: key)
                self.saveSummaries()
            }
        }
    }

    private func rewrite(day url: URL, entries: [Entry]) {
        var out = Data()
        for e in entries {
            guard var line = try? encoder.encode(e) else { continue }
            line.append(0x0A)
            out.append(line)
        }
        if out.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? out.write(to: url, options: .atomic)
        }
    }

    // MARK: - Reading

    private func dayFiles() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: root,
                     includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("day-")
                         && $0.pathExtension == "jsonl" }
                  .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest first
    }

    /// Parse one day file. A corrupt line is skipped, never fatal — losing one
    /// memory to a bad write is survivable; losing the day is not.
    private func readDay(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [Entry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = line.data(using: .utf8),
                  let e = try? decoder.decode(Entry.self, from: d) else {
                print("⚠️ [Memory] skipped an unreadable line in \(url.lastPathComponent)")
                continue
            }
            out.append(e)
        }
        return out
    }

    /// Load the hot window at launch. Runs off the main thread; publishes once.
    private func loadHotDays() {
        io.async { [weak self] in
            guard let self else { return }
            let files = self.dayFiles().prefix(Self.hotDays)
            var all: [Entry] = []
            for f in files { all.append(contentsOf: self.readDay(f)) }
            let swept = self.sweepExpired(all)
            let sorted = swept.sorted { $0.at > $1.at }
            DispatchQueue.main.async {
                self.recent = sorted
                print("🧠 [Memory] \(sorted.count) memories loaded from \(files.count) days")
            }
        }
    }

    /// Force a reload (after a migration, or a restore from backup).
    func reload() { loadHotDays(); loadSummaries() }

    /// Drop anything past its expiry that is not pinned. Verbatim conversation
    /// transcripts are the reason this exists.
    @discardableResult
    private func sweepExpired(_ entries: [Entry]) -> [Entry] {
        let now = Date()
        let dead = entries.filter { e in
            guard let x = e.expires, !e.pinned else { return false }
            return x < now
        }
        guard !dead.isEmpty else { return entries }
        print("🧹 [Memory] \(dead.count) expired memories swept")
        let deadIDs = Set(dead.map { $0.id })
        // Rewrite each affected day once.
        let days = Set(dead.map { Self.dayKey($0.at) })
        for key in days {
            guard let d = Self.dayKeyFormatter.date(from: key) else { continue }
            let url = dayURL(d)
            var kept = readDay(url)
            kept.removeAll { deadIDs.contains($0.id) }
            rewrite(day: url, entries: kept)
        }
        for e in dead where e.hasPhoto {
            try? FileManager.default.removeItem(at: thumbURL(e.id))
        }
        return entries.filter { !deadIDs.contains($0.id) }
    }

    // MARK: - Search
    //
    // TWO TIERS, same shape as the command router.
    //   Tier 1 — the hot window, in memory, instant, free, works on a plane.
    //   Tier 2 — the whole history, read from disk on a background queue.
    // Nothing here calls the network. Tier 3 (asking an AI to interpret a
    // fuzzy question) plugs in later on top of these, not instead of them.

    struct Query {
        var text: String = ""
        var kinds: Set<Kind> = []
        var from: Date?
        var to: Date?
        var pinnedOnly = false
        var photosOnly = false

        var isEmpty: Bool {
            text.trimmingCharacters(in: .whitespaces).isEmpty
                && kinds.isEmpty && from == nil && to == nil
                && !pinnedOnly && !photosOnly
        }
    }

    /// Instant, offline, over the hot window.
    func search(_ q: Query) -> [Entry] { Self.match(recent, q) }

    /// The whole history. Calls back on the main thread.
    func searchEverything(_ q: Query, completion: @escaping ([Entry]) -> Void) {
        DispatchQueue.main.async { self.isSearchingDisk = true }
        io.async { [weak self] in
            guard let self else { return }
            var all: [Entry] = []
            for f in self.dayFiles() { all.append(contentsOf: self.readDay(f)) }
            let hits = Self.match(all, q).sorted { $0.at > $1.at }
            DispatchQueue.main.async {
                self.isSearchingDisk = false
                completion(hits)
            }
        }
    }

    /// The matcher. Every word in the query must appear somewhere in the
    /// entry — AND, not OR. "laksa warung" should not return every warung.
    static func match(_ entries: [Entry], _ q: Query) -> [Entry] {
        let needle = q.text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { $0.count > 1 || $0.allSatisfy(\.isNumber) }

        return entries.filter { e in
            if !q.kinds.isEmpty && !q.kinds.contains(e.kind) { return false }
            if q.pinnedOnly && !e.pinned { return false }
            if q.photosOnly && !e.hasPhoto { return false }
            if let f = q.from, e.at < f { return false }
            if let t = q.to, e.at > t { return false }
            guard !needle.isEmpty else { return true }
            let blob = e.searchBlob
            for w in needle where !blob.contains(w) { return false }
            return true
        }
        .sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.at > $1.at
        }
    }

    /// Grouped by day, newest day first — the shape the browser draws.
    func grouped(_ entries: [Entry]) -> [(key: String, day: Date, items: [Entry])] {
        var buckets: [String: [Entry]] = [:]
        for e in entries { buckets[Self.dayKey(e.at), default: []].append(e) }
        return buckets.keys.sorted(by: >).compactMap { key in
            guard let d = Self.dayKeyFormatter.date(from: key) else { return nil }
            let items = (buckets[key] ?? []).sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return $0.at > $1.at
            }
            return (key: key, day: d, items: items)
        }
    }

    // MARK: - Day summaries

    func summary(for day: Date) -> String? { summaries[Self.dayKey(day)] }

    func setSummary(_ text: String, for day: Date) {
        summaries[Self.dayKey(day)] = text
        saveSummaries()
    }

    private func loadSummaries() {
        io.async { [weak self] in
            guard let self,
                  let d = try? Data(contentsOf: self.summariesURL),
                  let s = try? JSONDecoder().decode([String: String].self, from: d)
            else { return }
            DispatchQueue.main.async { self.summaries = s }
        }
    }

    private func saveSummaries() {
        let snapshot = summaries
        let url = summariesURL
        io.async {
            if let d = try? JSONEncoder().encode(snapshot) {
                try? d.write(to: url, options: .atomic)
            }
        }
    }

    /// A local, free, offline summary of a day — no AI needed. This is the
    /// floor; the AI version (Phase 5 Step 3, "Dreaming") replaces the text
    /// but not the plumbing.
    func localSummary(for day: Date) -> String {
        let key = Self.dayKey(day)
        let items = recent.filter { Self.dayKey($0.at) == key }
        guard !items.isEmpty else { return "Nothing recorded." }
        var counts: [Kind: Int] = [:]
        for i in items { counts[i.kind, default: 0] += 1 }
        var places: [String] = []
        for i in items {
            if let p = i.place ?? i.street ?? i.city, !places.contains(p) { places.append(p) }
        }
        var parts: [String] = []
        for k in Kind.allCases where (counts[k] ?? 0) > 0 && k != .day {
            parts.append("\(counts[k] ?? 0) \(k.label.lowercased())")
        }
        var out = parts.joined(separator: ", ")
        if !places.isEmpty {
            out += " — around " + places.prefix(4).joined(separator: ", ")
        }
        return out
    }

    // MARK: - Dreaming: the nightly read-through
    //
    // Until now the day header was a TALLY — "4 places, 8 notes" — counted
    // locally and free. Useful, but it is not a summary and it does not know
    // what your day was about.
    //
    // This reads the day's memories once, overnight on charge and WiFi, and
    // writes one paragraph. It runs over YESTERDAY, not today, because a day
    // is not summarisable until it has finished. One cheap call per day.

    private static let dreamKey = "chappy_dreamed_days"

    func dreamIfDue() async {
        guard UserDefaults.standard.object(forKey: "chappy_dreaming") == nil
                || UserDefaults.standard.bool(forKey: "chappy_dreaming") else { return }
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        else { return }
        let key = Self.dayKey(yesterday)
        var done = Set(UserDefaults.standard.stringArray(forKey: Self.dreamKey) ?? [])
        guard !done.contains(key), summary(for: yesterday) == nil else { return }

        let items = recent.filter { Self.dayKey($0.at) == key && $0.kind != .day }
        guard items.count >= 3 else { done.insert(key)
            UserDefaults.standard.set(Array(done.suffix(120)), forKey: Self.dreamKey); return }

        if let paragraph = await Self.writeDaySummary(items, dayName: key) {
            setSummary(paragraph, for: yesterday)
            print("🌙 [Dreaming] \(key): \(paragraph)")
        }
        done.insert(key)
        UserDefaults.standard.set(Array(done.suffix(120)), forKey: Self.dreamKey)
    }

    static func writeDaySummary(_ items: [Entry], dayName: String) async -> String? {
        guard let key = APIKeyManager.shared.getGoogleAPIKey(), !key.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=\(key)")
        else { return nil }
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        let lines = items.sorted { $0.at < $1.at }.prefix(120).map {
            "\(df.string(from: $0.at)) [\($0.kind.rawValue)] \($0.oneLine)"
        }.joined(separator: "\n")

        let prompt = """
        These are the things an assistant recorded for one traveller on \(dayName) -         places, photos, notes, conversations, jobs and trips, in order.

        Write ONE paragraph, 2 to 3 sentences, saying what the day actually WAS.         Write it TO him, in second person, plainly - "You spent the morning..."         Name the places and the things that mattered. Skip anything routine.         No preamble, no bullet points, no "this day was".

        \(lines)
        """
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.4, "maxOutputTokens": 700],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 40
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let c = j["candidates"] as? [[String: Any]],
              let content = c.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let t = parts.first?["text"] as? String else { return nil }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// THE DAY'S ROUTE, as one line rather than four hundred breadcrumbs.
    func fileDayRoute() {
        let key = "chappy_route_filed"
        var done = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else { return }
        let day = Self.dayKey(yesterday)
        guard !done.contains(day) else { return }
        done.insert(day)
        UserDefaults.standard.set(Array(done.suffix(120)), forKey: key)
        let line = TripRecorder.shared.routeSummary(for: yesterday)
        guard !line.isEmpty else { return }
        rememberAt(.route, title: line, lat: nil, lon: nil,
                   tags: ["route", "day"], source: "trail", at: yesterday)
    }

    // MARK: - Spoken recall (the free tier of "what do you remember about…")

    /// A short spoken answer built entirely on-device. Returns nil when there
    /// is genuinely nothing, so the caller can say something honest rather
    /// than invent.
    func spokenRecall(_ text: String, limit: Int = 4) -> String? {
        var q = Query(); q.text = text
        let hits = search(q)
        guard !hits.isEmpty else { return nil }
        let df = DateFormatter()
        df.dateFormat = "EEEE"
        let lines = hits.prefix(limit).map { e -> String in
            let when = Calendar.current.isDateInToday(e.at) ? "today"
                     : (Calendar.current.isDateInYesterday(e.at) ? "yesterday"
                        : df.string(from: e.at))
            return "\(e.oneLine), \(when)"
        }
        return "\(hits.count) \(hits.count == 1 ? "memory" : "memories"). " + lines.joined(separator: ". ") + "."
    }

    // MARK: - Thumbnails

    func thumbnail(for id: UUID) -> UIImage? {
        let key = id.uuidString as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let d = try? Data(contentsOf: thumbURL(id)),
              let img = UIImage(data: d) else { return nil }
        thumbCache.setObject(img, forKey: key)
        return img
    }

    // MARK: - Housekeeping / stats

    struct Stats {
        var total = 0
        var days = 0
        var photos = 0
        var pinned = 0
        var bytes: Int64 = 0
        var oldest: Date?
    }

    func stats(completion: @escaping (Stats) -> Void) {
        io.async { [weak self] in
            guard let self else { return }
            var s = Stats()
            let files = self.dayFiles()
            s.days = files.count
            var oldest: Date?
            for f in files {
                let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int64) ?? 0
                s.bytes += size
                for e in self.readDay(f) {
                    s.total += 1
                    if e.hasPhoto { s.photos += 1 }
                    if e.pinned { s.pinned += 1 }
                    if oldest == nil || e.at < oldest! { oldest = e.at }
                }
            }
            if let t = try? FileManager.default.contentsOfDirectory(at: self.thumbsDir, includingPropertiesForKeys: [.fileSizeKey]) {
                for u in t {
                    let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
                    s.bytes += size
                }
            }
            s.oldest = oldest
            DispatchQueue.main.async { completion(s) }
        }
    }

    /// Everything, as one text file you can email to yourself. The escape
    /// hatch that makes a proprietary store acceptable.
    func exportAll(completion: @escaping (URL?) -> Void) {
        io.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(nil) }; return }
            var text = "CHAPPY MEMORY EXPORT\n\(Date())\n\n"
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            for f in self.dayFiles().reversed() {
                let entries = self.readDay(f).sorted { $0.at < $1.at }
                guard !entries.isEmpty else { continue }
                let key = String(f.lastPathComponent.dropFirst(4).dropLast(6))
                text += "\n===== \(key) =====\n"
                if let s = self.summaries[key] { text += "\(s)\n\n" }
                for e in entries {
                    text += "[\(df.string(from: e.at))] \(e.kind.label.uppercased()): \(e.title)\n"
                    if !e.body.isEmpty { text += "    \(e.body)\n" }
                    if let p = e.place ?? e.street ?? e.city { text += "    at \(p)\n" }
                }
            }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("chappy-memory-\(Self.dayKey(Date())).txt")
            try? text.data(using: .utf8)?.write(to: out, options: .atomic)
            DispatchQueue.main.async { completion(out) }
        }
    }

    // MARK: - Migration
    //
    // The old scattered stores are read ONCE and folded in, so nothing from
    // before Phase 5 is lost and there is genuinely only one place to look
    // from here on. The old files are left on disk untouched — this is a
    // copy, not a move, so a bad migration costs nothing.

    private static let migrationKey = "chappy_memory_migrated_v1"

    func migrateLegacyStoresIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.migrationKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.migrationKey)
        // SPEED FIX (build 109): this looped every old spot, photo and note ON
        // THE MAIN THREAD at launch. On a full store that is a visible freeze
        // on the first screen you look at.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.migrateNow()
        }
    }

    private func migrateNow() {
        let trip = TripRecorder.shared
        var moved = 0

        // Saved spots.
        for s in trip.spots {
            rememberAt(.place, title: s.name,
                       lat: s.lat, lon: s.lon,
                       street: s.street, city: s.city, country: s.country,
                       tags: ["spot"], source: "migration", at: s.t)
            moved += 1
        }

        // Captioned photos (thumbnails come across too).
        for v in trip.visualNotes {
            rememberAt(.photo, title: v.caption,
                       lat: v.lat == 0 ? nil : v.lat, lon: v.lon == 0 ? nil : v.lon,
                       street: v.street, city: v.city,
                       tags: ["snap"], thumbnail: v.thumbnail,
                       source: "migration", at: v.at)
            moved += 1
        }

        // Today's observations. Older per-day note files are picked up below.
        for n in trip.notes {
            rememberAt(.note, title: n, lat: nil, lon: nil,
                       tags: ["observation"], source: "migration")
            moved += 1
        }

        // Historic note files: chappy-notes-YYYY-MM-DD.json
        let docsDir = docs
        if let all = try? FileManager.default.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: nil) {
            for f in all where f.lastPathComponent.hasPrefix("chappy-notes-") {
                let key = String(f.lastPathComponent.dropFirst("chappy-notes-".count).dropLast(5))
                guard let day = Self.dayKeyFormatter.date(from: key),
                      !Calendar.current.isDateInToday(day),
                      let d = try? Data(contentsOf: f),
                      let lines = try? JSONDecoder().decode([String].self, from: d) else { continue }
                for line in lines {
                    rememberAt(.note, title: line, lat: nil, lon: nil,
                               tags: ["observation"], source: "migration", at: day)
                    moved += 1
                }
            }
        }

        print("🧠 [Memory] migration complete — \(moved) memories folded in")
        // Give the writes a beat to land, then rebuild the hot window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.reload()
        }
    }

    // MARK: - Internals

    private func normalise(_ tags: [String]) -> [String] {
        var seen: [String] = []
        for t in tags {
            let clean = t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "-")
            if !clean.isEmpty, !seen.contains(clean), clean.count <= 24 { seen.append(clean) }
        }
        return Array(seen.prefix(8))
    }

    private func fallbackTitle(for kind: Kind, at when: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "h:mma"
        return "\(kind.label.dropLast()) at \(df.string(from: when))"
    }

    // THREADING LAW (learned the hard way in build 80): a @Published property
    // written off the main thread deadlocks Combine's lock on the main thread
    // and the app is killed by the watchdog. Every publish goes through here.
    private func setRecent(insert e: Entry) {
        if Thread.isMainThread { recent.insert(e, at: 0) }
        else { DispatchQueue.main.async { [weak self] in self?.recent.insert(e, at: 0) } }
    }
    private func setRecent(replace e: Entry) {
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            if let i = self.recent.firstIndex(where: { $0.id == e.id }) { self.recent[i] = e }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }
    private func setRecent(remove id: UUID) {
        let apply: () -> Void = { [weak self] in self?.recent.removeAll { $0.id == id } }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }
    private func setError(_ msg: String?) {
        if Thread.isMainThread { lastError = msg }
        else { DispatchQueue.main.async { [weak self] in self?.lastError = msg } }
    }
}


// =====================================================================
// MARK: - GLASSES CAPTURE INGEST (PHASE 5 — STEP 2)
// =====================================================================
//
// "Hey Meta, take a picture." "Hey Meta, take a video."
//
// This is the capture path that works when Chappy is CLOSED. The glasses
// record to their own storage, the Meta AI app syncs them over WiFi, iOS
// auto-import drops them in the photo library, and this reads them from
// there. No session, no battery cost, no app open, 24 hours a day.
//
// WHY THIS AND NOT SDK RECORDING
// The DAT SDK hands Chappy a live frame stream. That is the right tool for
// looking at something and describing it, and the wrong tool for making a
// video you would actually post: the stream is preview-grade and it only
// exists while a session is open. The glasses' own recorder produces the
// real file at full resolution. So the glasses capture, and Chappy's whole
// job is to find it, understand it, and file it.
//
// WHAT IT COSTS
// One cheap vision call per photo. For a video: frames plus an on-device
// transcript folded into ONE call. Twenty captures a day is a fraction of a
// cent. It runs on charge and WiFi, so it costs no battery you would notice
// and no cellular data at all.
//
// WHAT IT NEVER DOES
// It never copies or moves the video. The file stays in the photo library at
// full resolution, ready to post or edit; memory keeps a summary, a
// thumbnail and the library id. Copying video into app storage is the one
// decision here that would fill the phone.
//
// REQUIRES: NSPhotoLibraryUsageDescription in Info.plist.

/// One-shot claim. Whoever calls `claim()` first gets true; everyone after
/// gets false. Used to make sure a checked continuation resumes exactly once
/// when two callbacks are racing for it.
final class ResumeOnce {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

final class ChappyIngest: ObservableObject {
    static let shared = ChappyIngest()

    @Published private(set) var isRunning = false
    @Published private(set) var progress = ""
    /// BUILD 171: a start is in flight — see startLiveAISession().
    private var isStartingSession = false
    @Published private(set) var lastResult = ""

    /// Library ids already turned into memories. Kept as a set of strings so
    /// re-running the ingest can never produce a second copy of anything —
    /// the one failure mode that would make this feature worse than useless.
    private var seen: Set<String> = []
    private let seenKey = "chappy_ingest_seen_v1"
    private let watermarkKey = "chappy_ingest_watermark"
    private let lastRunKey = "chappy_ingest_last_run"

    /// Album names the Meta app has used. Checked first; if none of them
    /// exist we fall back to "everything new in the library", which is right
    /// anyway for anyone who has auto-import writing straight to the camera roll.
    private static let metaAlbumNames = [
        "Meta AI", "Meta View", "Ray-Ban Meta", "Meta Glasses", "Meta",
    ]

    /// Videos longer than this are summarised from frames alone. On-device
    /// speech on a 20-minute clip is minutes of CPU for a paragraph that the
    /// pictures would have given us anyway — and the clips that matter for
    /// what was SAID (a haggle, a set of directions) are short.
    private static let maxTranscribeSeconds: Double = 120
    /// Frames sampled from a video. Twelve is enough for Flash to tell what
    /// happened without turning one clip into a photo album.
    private static let maxFrames = 12
    /// A single run never processes more than this, so the first ingest on a
    /// library with 4,000 holiday photos in it does not run for an hour.
    private static let maxPerRun = 40

    private init() {
        seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
    }

    var lastRun: Date? {
        let t = UserDefaults.standard.double(forKey: lastRunKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// The watermark is the moment ingest was first switched on. Anything
    /// older than it is your existing photo library, not glasses captures,
    /// and swallowing ten years of camera roll into a travel memory store is
    /// not a helpful surprise. You can move it back deliberately in Settings.
    var watermark: Date {
        get {
            let t = UserDefaults.standard.double(forKey: watermarkKey)
            if t > 0 { return Date(timeIntervalSince1970: t) }
            let now = Date()
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: watermarkKey)
            return now
        }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: watermarkKey) }
    }

    // MARK: - When it runs
    //
    // Foreground-triggered on purpose. A true background task needs a new
    // Info.plist capability and a BGTaskScheduler identifier, and every
    // Info.plist change so far has cost a build. Opening Chappy once while
    // it charges overnight is a thing you already do.

    /// Called when the app becomes active. Runs only if the conditions are
    /// right, and says nothing at all if they are not.
    func runIfConditionsAreRight() {
        guard UserDefaults.standard.object(forKey: "chappy_ingest_enabled") == nil
                || UserDefaults.standard.bool(forKey: "chappy_ingest_enabled") else { return }
        guard !isRunning else { return }
        if let last = lastRun, Date().timeIntervalSince(last) < 6 * 3600 { return }

        UIDevice.current.isBatteryMonitoringEnabled = true
        let charging = UIDevice.current.batteryState == .charging
                    || UIDevice.current.batteryState == .full
        guard charging else {
            print("📥 [Ingest] Skipped — not charging")
            return
        }
        guard ChappyIngest.onWiFi() else {
            print("📥 [Ingest] Skipped — not on WiFi")
            return
        }
        Task { await run(manual: false) }
    }

    /// WiFi test via NWPathMonitor — one long-lived monitor started once.
    /// (The getifaddrs trick works too, but it pokes at BSD headers that
    /// Swift only re-exports by accident, and this is a supported API.)
    private static let pathMonitor: NWPathMonitor = {
        let m = NWPathMonitor()
        m.start(queue: DispatchQueue(label: "chappy.ingest.net", qos: .utility))
        return m
    }()

    static func onWiFi() -> Bool {
        let path = pathMonitor.currentPath
        return path.status == .satisfied && path.usesInterfaceType(.wifi)
    }

    // MARK: - The run

    @MainActor
    func run(manual: Bool) async {
        guard !isRunning else { return }
        isRunning = true
        progress = "Asking for photo access…"
        defer { isRunning = false; progress = "" }

        let status = await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { c.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            lastResult = "Photo access is off. Settings → Chappy → Photos."
            if manual { TTSService.shared.speak("I need photo access to read what the glasses captured.") }
            return
        }

        let assets = candidates()
        guard !assets.isEmpty else {
            lastResult = "Nothing new from the glasses."
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRunKey)
            if manual { TTSService.shared.speak("Nothing new to import.") }
            return
        }

        var photos = 0, videos = 0, failed = 0
        for (i, asset) in assets.enumerated() {
            progress = "Reading \(i + 1) of \(assets.count)…"
            let ok: Bool
            if asset.mediaType == .video {
                ok = await ingestVideo(asset)
                if ok { videos += 1 }
            } else {
                ok = await ingestPhoto(asset)
                if ok { photos += 1 }
            }
            if ok {
                seen.insert(asset.localIdentifier)
                UserDefaults.standard.set(Array(seen), forKey: seenKey)
            } else {
                failed += 1
            }
        }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRunKey)
        var summary = "\(photos + videos) filed"
        if videos > 0 { summary += " (\(videos) video\(videos == 1 ? "" : "s"))" }
        if failed > 0 { summary += ", \(failed) couldn't be read" }
        lastResult = summary
        print("📥 [Ingest] \(summary)")
        // Overnight, on the charger, app in the background — the whole point
        // of this feature is that you wake up to it already done.
        if photos + videos > 0 {
            ChappyNotify.post(.memory,
                title: "Glasses captures filed",
                body: summary + " — captioned and searchable.",
                opens: .chappyOpenMemory)
        }
        if manual {
            // BUILD 144 earcon diet: the spoken line IS the confirmation
            TTSService.shared.speak(photos + videos == 0
                ? "Nothing new to import."
                : "Imported \(photos + videos) from the glasses.")
        }
    }

    /// New media since the watermark that we have not already filed.
    private func candidates() -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate > %@", watermark as NSDate)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        var found: [PHAsset] = []

        // Prefer a Meta album if one exists — it is the only signal iOS gives
        // us about where a photo actually came from.
        let albums = PHAssetCollection.fetchAssetCollections(with: .album,
                                                             subtype: .any, options: nil)
        var usedAlbum = false
        albums.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle,
                  Self.metaAlbumNames.contains(where: {
                      title.localizedCaseInsensitiveContains($0) })
            else { return }
            usedAlbum = true
            let assets = PHAsset.fetchAssets(in: collection, options: opts)
            assets.enumerateObjects { a, _, _ in found.append(a) }
        }

        if !usedAlbum {
            // No Meta album: auto-import is writing straight to the camera
            // roll, which is the common setup. Everything new counts.
            let all = PHAsset.fetchAssets(with: opts)
            all.enumerateObjects { a, _, _ in found.append(a) }
        }

        found = found.filter { !seen.contains($0.localIdentifier) }
        if found.count > Self.maxPerRun {
            print("📥 [Ingest] \(found.count) waiting — taking the oldest \(Self.maxPerRun) this run")
            found = Array(found.prefix(Self.maxPerRun))
        }
        return found
    }

    // MARK: - Photos

    private func ingestPhoto(_ asset: PHAsset) async -> Bool {
        guard let image = await requestImage(asset, maxDimension: 1024) else { return false }
        let when = asset.creationDate ?? Date()
        let described = await ChappyStandby.describe(image)
        let caption = described ?? "Photo from the glasses"
        let loc = placeFor(asset, at: when)

        ChappyMemory.shared.rememberAt(
            .photo, title: caption,
            lat: loc.lat, lon: loc.lon,
            street: loc.street, city: loc.city, country: loc.country,
            tags: ["glasses", "capture"],
            thumbnail: thumbnailData(image),
            source: "glasses-import",
            at: when,
            assetID: asset.localIdentifier)
        return true
    }

    // MARK: - Video
    //
    // Three cheap inputs, one call: what it looked like (frames), what was
    // said (on-device speech, free), and where and when it happened (already
    // known). That combination is what turns "IMG_4471.mov" into "haggling
    // over the scooter hire on Jalan Monkey Forest, settled at 70k".

    private func ingestVideo(_ asset: PHAsset) async -> Bool {
        guard let avAsset = await requestAVAsset(asset) else { return false }
        let when = asset.creationDate ?? Date()
        let seconds = asset.duration
        let frames = await keyFrames(from: avAsset, count: Self.maxFrames)
        guard !frames.isEmpty else { return false }

        // TRANSCRIPTION CAP, enforced rather than merely mentioned. A file
        // recogniser has no seek — you cannot ask it for the first two minutes
        // of a twenty-minute clip — so the honest choice is to transcribe
        // short videos fully and say plainly that a long one wasn't done.
        var spoken = ""
        var tooLongToHear = false
        if seconds <= Self.maxTranscribeSeconds, let url = (avAsset as? AVURLAsset)?.url {
            let heard = await Self.transcribe(url)
            spoken = heard ?? ""
        } else if seconds > Self.maxTranscribeSeconds {
            tooLongToHear = true
        }

        let written = await Self.summariseVideo(frames: frames,
                                                spoken: spoken,
                                                seconds: seconds)
        let summary = written ?? "Video from the glasses, \(Int(seconds)) seconds"

        let loc = placeFor(asset, at: when)
        var body = "\(Int(seconds)) second video."
        if !spoken.isEmpty {
            body += "\n\nWhat was said:\n\(spoken)"
        } else if tooLongToHear {
            body += "\n\n(Too long to transcribe on-device — summarised from the picture only.)"
        }
        body += "\n\nThe full-resolution video is still in your photo library."

        ChappyMemory.shared.rememberAt(
            .video, title: summary, body: body,
            lat: loc.lat, lon: loc.lon,
            street: loc.street, city: loc.city, country: loc.country,
            tags: ["glasses", "video", "capture"],
            thumbnail: thumbnailData(frames[frames.count / 2]),
            source: "glasses-import",
            at: when,
            assetID: asset.localIdentifier)
        return true
    }

    /// On-device speech from a video file. Free, offline, and it never leaves
    /// the phone — which matters, because a video of a conversation contains
    /// somebody else's voice.
    static func transcribe(_ url: URL) async -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        // RESUME EXACTLY ONCE. Two callbacks race here — the recogniser and
        // the watchdog — and resuming a continuation twice is a crash, not a
        // warning. A plain captured `var` would also be a mutable local shared
        // by two escaping closures, which strict concurrency rejects outright.
        let gate = ResumeOnce()
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let r = result, r.isFinal {
                    if gate.claim() { c.resume(returning: r.bestTranscription.formattedString) }
                } else if error != nil {
                    if gate.claim() { c.resume(returning: nil) }
                }
            }
            // A file recogniser that never calls back would hang the whole
            // ingest run. Give it a ceiling and move on.
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
                guard gate.claim() else { return }
                task.cancel()
                c.resume(returning: nil)
            }
        }
    }

    /// One Flash call: frames + transcript + duration → one line.
    static func summariseVideo(frames: [UIImage], spoken: String, seconds: Double) async -> String? {
        guard let key = APIKeyManager.shared.getGoogleAPIKey(), !key.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=\(key)")
        else { return nil }

        var parts: [[String: Any]] = [[
            "text": "These are \(frames.count) frames sampled evenly from a "
                  + "\(Int(seconds)) second video recorded on smart glasses, in order."
                  + (spoken.isEmpty ? ""
                     : "\n\nThis is what was said during it (on-device transcript, may be imperfect):\n\(spoken)")
                  + "\n\nWrite ONE line, under 20 words, describing what happened — "
                  + "the kind of line that would let someone find this clip again months later. "
                  + "No preamble, no 'this video shows'. "
                  + "Example: 'haggling over scooter hire, settled at 70 thousand'."
        ]]
        for f in frames {
            guard let jpeg = f.jpegData(compressionQuality: 0.4) else { continue }
            parts.append(["inline_data": ["mime_type": "image/jpeg",
                                          "data": jpeg.base64EncodedString()]])
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            // Flash reasons before it answers, so the budget has to cover the
            // thinking as well as the sentence. 120 was the build-88 mistake.
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 500],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 45
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = json["candidates"] as? [[String: Any]],
              let content = c.first?["content"] as? [String: Any],
              let ps = content["parts"] as? [[String: Any]],
              let t = ps.first?["text"] as? String else { return nil }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func keyFrames(from asset: AVAsset, count: Int) async -> [UIImage] {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0 else { return [] }
        let n = max(1, min(count, Int(duration / 2) + 1))
        var out: [UIImage] = []
        for i in 0..<n {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(n), preferredTimescale: 600)
            // ObjC exception territory if the asset is unreadable — the throwing
            // API is the safe one, and a failed frame is not a failed video.
            if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
                out.append(UIImage(cgImage: cg))
            }
        }
        return out
    }

    // MARK: - Location
    //
    // THE BREADCRUMB TRICK.
    // Glasses photos may or may not carry GPS — the glasses have no receiver
    // of their own and whether the phone's fix survives into the file is not
    // something to assume. It barely matters: TripRecorder has been writing a
    // breadcrumb every 25 metres all day. Any capture with a TIMESTAMP can be
    // placed by finding the nearest crumb. Free, offline, and it works for
    // photos taken with Chappy closed and the phone in a pocket.

    private struct Placed {
        var lat: Double?; var lon: Double?
        var street: String?; var city: String?; var country: String?
    }

    private func placeFor(_ asset: PHAsset, at when: Date) -> Placed {
        var p = Placed()
        if let l = asset.location {
            p.lat = l.coordinate.latitude
            p.lon = l.coordinate.longitude
        }
        if let crumb = TripRecorder.shared.nearestCrumb(to: when, within: 900) {
            if p.lat == nil { p.lat = crumb.lat; p.lon = crumb.lon }
            p.street = crumb.street
            p.city = crumb.city
        }
        if p.city == nil, Calendar.current.isDateInToday(when) {
            let s = ContextEngine.shared.snapshot
            p.street = p.street ?? s.street
            p.city = s.city
            p.country = s.country
        }
        return p
    }

    // MARK: - PhotoKit plumbing

    private func requestImage(_ asset: PHAsset, maxDimension: CGFloat) async -> UIImage? {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true      // iCloud-optimised originals
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .exact
        opts.isSynchronous = false
        let gate = ResumeOnce()
        return await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxDimension, height: maxDimension),
                contentMode: .aspectFit, options: opts) { image, info in
                    // requestImage calls back TWICE for an iCloud asset: a
                    // degraded thumbnail first, the real one after. Skip the
                    // first, and never resume twice.
                    if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
                    if gate.claim() { c.resume(returning: image) }
                }
        }
    }

    private func requestAVAsset(_ asset: PHAsset) async -> AVAsset? {
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        opts.version = .current
        let gate = ResumeOnce()
        return await withCheckedContinuation { (c: CheckedContinuation<AVAsset?, Never>) in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { av, _, _ in
                if gate.claim() { c.resume(returning: av) }
            }
        }
    }

    private func thumbnailData(_ image: UIImage) -> Data? {
        let target: CGFloat = 400
        let scale = min(1, target / max(image.size.width, image.size.height))
        guard scale < 1 else { return image.jpegData(compressionQuality: 0.5) }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let r = UIGraphicsImageRenderer(size: size)
        let small = r.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return small.jpegData(compressionQuality: 0.5)
    }

    /// Open the original in the app (full resolution, straight from the
    /// library). There is no public URL that opens Photos at a specific
    /// asset, so pretending there is would just be a button that does nothing.
    func loadOriginal(assetID: String) async -> (UIImage?, AVAsset?) {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = fetched.firstObject else { return (nil, nil) }
        if asset.mediaType == .video {
            return (nil, await requestAVAsset(asset))
        }
        return (await requestImage(asset, maxDimension: 2400), nil)
    }
}


// =====================================================================
// MARK: - THE RECORDS FOLD-IN (PHASE 5 — one spot means one spot)
// =====================================================================
//
// Every Live AI conversation you have ever had lives in ConversationStorage:
// up to a hundred of them, whole transcripts, no search, no location, no
// categories, and a screen that can only be scrolled. That is an archive,
// not a memory.
//
// This folds them in. TWO STAGES, on purpose.
//
//   STAGE 1 — instant, free, offline, runs at launch.
//   Every conversation becomes ONE memory: a headline taken from what you
//   actually opened with, the full transcript in the body, and — the good
//   part — a LOCATION, recovered by matching the conversation's timestamp
//   against the breadcrumb trail. Conversations that were never located
//   suddenly know which street you were standing on.
//
//   STAGE 2 — overnight, on charge and WiFi, throttled.
//   One cheap call per conversation pulls out the few DURABLE facts buried
//   in it and files each as its own small memory. Sixty messages of "yeah",
//   "okay" and "what about that one" do not become sixty memories; the three
//   things worth keeping become three.
//
// The old store is never touched. It is a copy, not a move, so the Records
// screen keeps working exactly as it does today and nothing is at risk if
// the extraction gets something wrong.

extension ChappyMemory {

    private static let recordsMigratedKey = "chappy_memory_records_migrated_v1"
    private static let extractedKey = "chappy_memory_facts_extracted_v1"
    /// Conversations processed per extraction run. A hundred calls in one
    /// burst is a rate-limit response and a hundred failures; fifteen a night
    /// clears the whole backlog in a week and nobody notices.
    private static let extractPerRun = 15

    // MARK: Stage 1 — headlines, transcripts and places

    func foldInConversationRecords() {
        guard !UserDefaults.standard.bool(forKey: Self.recordsMigratedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.recordsMigratedKey)

        // Off the main thread: loadAllConversations decodes the entire
        // archive out of UserDefaults and each transcript is a string build.
        // At launch, on main, that is a visible stutter for no reason.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.foldInConversationRecordsNow()
        }
    }

    private func foldInConversationRecordsNow() {
        let records = ConversationStorage.shared.loadAllConversations()
        guard !records.isEmpty else {
            print("🧠 [Records] Nothing to fold in")
            return
        }

        var folded = 0
        for r in records {
            let title = Self.headline(for: r)
            let body = Self.transcript(of: r)

            // THE BREADCRUMB TRICK AGAIN. A conversation record stores no
            // location at all — but the trail knows where you were when it
            // happened, so every one of these can be put on the map.
            let crumb = TripRecorder.shared.nearestCrumb(to: r.timestamp, within: 1800)

            rememberAt(.ask,
                       title: title,
                       body: body,
                       lat: crumb?.lat, lon: crumb?.lon,
                       street: crumb?.street, city: crumb?.city,
                       tags: ["live-ai", "conversation", "records"],
                       source: "records-fold",
                       at: r.timestamp)
            folded += 1
        }
        print("🧠 [Records] Folded in \(folded) conversations")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.reload()
        }
    }

    /// What you opened with, which is nearly always what the conversation was
    /// about. Falls back to the first thing Chappy said, then to the date —
    /// never to a placeholder that tells you nothing.
    static func headline(for r: ConversationRecord) -> String {
        let firstUser = r.messages.first(where: { $0.role == .user })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if firstUser.count > 3 { return String(firstUser.prefix(80)) }

        let firstAny = r.messages.first?.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if firstAny.count > 3 { return "Chappy said: " + String(firstAny.prefix(70)) }

        let df = DateFormatter()
        df.dateFormat = "EEEE d MMMM, h:mma"
        return "Conversation on \(df.string(from: r.timestamp))"
    }

    /// The transcript, capped. A very long session is genuinely worth keeping,
    /// but not at the cost of a memory file measured in megabytes — and the
    /// original is still sitting untouched in Records either way.
    static func transcript(of r: ConversationRecord, limit: Int = 6000) -> String {
        var out = ""
        for m in r.messages {
            let who = m.role == .user ? "You" : "Chappy"
            let line = "\(who): \(m.content.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            if out.count + line.count > limit {
                out += "…(transcript continues — the full version is in Records)"
                break
            }
            out += line
        }
        return out
    }

    // MARK: Stage 2 — the facts worth keeping

    private var extractedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.extractedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.extractedKey) }
    }

    /// How many conversations are still waiting to be read properly.
    var factsPending: Int {
        let done = extractedIDs
        return ConversationStorage.shared.loadAllConversations()
            .filter { !done.contains($0.id.uuidString) }
            .filter { $0.messages.count >= 4 }
            .count
    }

    /// Runs on charge and WiFi. Reads a handful of old conversations properly
    /// and files what was actually learned in them.
    func runFactExtraction(manual: Bool = false) async {
        var done = extractedIDs
        let pending = ConversationStorage.shared.loadAllConversations()
            .filter { !done.contains($0.id.uuidString) }
            // Under four messages is "hello" and a false start. Nothing to learn.
            .filter { $0.messages.count >= 4 }
            .prefix(Self.extractPerRun)

        guard !pending.isEmpty else {
            if manual { TTSService.shared.speak("Nothing left to read through.") }
            return
        }
        print("🧠 [Records] Reading \(pending.count) conversations for durable facts")

        var filed = 0
        for r in pending {
            let facts = await Self.extractFacts(from: r)
            let crumb = TripRecorder.shared.nearestCrumb(to: r.timestamp, within: 1800)
            for f in facts {
                rememberAt(.note, title: f,
                           lat: crumb?.lat, lon: crumb?.lon,
                           street: crumb?.street, city: crumb?.city,
                           tags: ["learned", "live-ai"],
                           source: "records-extract",
                           at: r.timestamp)
                filed += 1
            }
            // Marked done whether or not anything came back. A conversation
            // with nothing durable in it is a finished job, not a retry.
            done.insert(r.id.uuidString)
            extractedIDs = done
            try? await Task.sleep(nanoseconds: 700_000_000)
        }

        print("🧠 [Records] \(filed) facts filed from \(pending.count) conversations")
        if filed > 0 {
            // ChappyMemory is not main-actor bound (it is written to from the
            // audio and ingest queues), and ChappyNotify is. Hop across.
            let count = pending.count
            let n = filed
            await MainActor.run {
                ChappyNotify.post(.memory,
                    title: "Read \(count) old conversations",
                    body: "\(n) thing\(n == 1 ? "" : "s") worth keeping filed into memory.",
                    opens: .chappyOpenMemory)
            }
        }
        if manual {
            // BUILD 144 earcon diet: the spoken line IS the confirmation
            TTSService.shared.speak(filed == 0
                ? "Read them through - nothing worth keeping in those."
                : "Filed \(filed) thing\(filed == 1 ? "" : "s") from \(pending.count) old conversations.")
        }
    }

    /// One cheap call. Asks for the things that are still true next month —
    /// not a summary, which is what you get if you ask for a summary and is
    /// almost never what you want to search for later.
    static func extractFacts(from r: ConversationRecord) async -> [String] {
        guard let key = APIKeyManager.shared.getGoogleAPIKey(), !key.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=\(key)")
        else { return [] }

        let text = transcript(of: r, limit: 12000)
        guard text.count > 80 else { return [] }

        let prompt = """
        Below is a transcript between a traveller and his AI assistant.

        Pull out ONLY the things that are still worth knowing in a month — \
        a place and what it was like, a price he was quoted or paid, a name, \
        a preference he stated, a fact about somewhere he was, a decision he made.

        Ignore small talk, the assistant's explanations, anything that was only \
        true at that moment (the weather, what time it was, what was in front of him).

        Return a JSON array of at most 3 strings. Each string is ONE short line, \
        under 15 words, written so it makes sense on its own months later.
        If there is nothing durable in it, return [].

        Return ONLY the JSON array, nothing else.

        TRANSCRIPT:
        \(text)
        """

        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            // Flash reasons before answering, so the budget covers the thinking
            // as well as the answer. This is the build-88 lesson, kept.
            "generationConfig": ["temperature": 0.1, "maxOutputTokens": 800],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = json["candidates"] as? [[String: Any]],
              let content = c.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let raw = parts.first?["text"] as? String
        else { return [] }

        // Flash sometimes wraps JSON in a code fence however firmly you ask.
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.firstIndex(of: "["), let end = cleaned.lastIndex(of: "]") {
            cleaned = String(cleaned[start...end])
        }
        guard let d = cleaned.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [String]
        else { return [] }

        return arr
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 6 && $0.count < 160 }
            .prefix(3)
            .map { $0 }
    }
}


// =====================================================================
// MARK: - CHAPPY REMINDERS (PHASE 5.5 — the vocal diary)
// =====================================================================
//
// ONE STORE, TWO VIEWS.
// A reminder is a memory with a trigger on it. A memory is a reminder with
// no trigger. "Remember the tracking number" and "remind me to book the
// ferry" write the same kind of record, which is why "what did I say about
// the tracking number" and "what's due today" search one index instead of
// two — and why "remind me about that thing I noted yesterday" can attach a
// trigger to a memory that already exists rather than making a duplicate.
//
// Meta's glasses keep reminders and memories in separate stores that never
// cross-reference. That is the single biggest thing to beat, and it is beaten
// by doing nothing — the store was built this way already.
//
// TWO THINGS NOBODY ELSE DOES, BOTH OF WHICH MATTER TO A FULL-TIME TRAVELLER
//
//   1. FLOATING TIME. "Take the tablet at 8am" means 8am WHEREVER YOU ARE.
//      "Ring the bank at 9am Brisbane" means a fixed instant. Every assistant
//      on the market stores one absolute moment and quietly gets one of those
//      two wrong the day you change country. Chappy stores which kind it is.
//
//   2. COMPLETION-ANCHORED REPEATS. "Every 3 days" from the schedule versus
//      "3 days after I actually do it" are different things — laundry is the
//      second, rent is the first. Todoist has this and no voice assistant
//      does, because nobody worked out how to say it out loud. You say
//      "every three days after I do it".
//
// DELIVERY IS NEGOTIATED, CAPTURE IS NOT.
// Capture always works, offline, instantly. Delivery has a ladder: if Chappy
// is running it speaks in your ear; either way a local notification fires so
// a closed app still reaches you, and the Meta app can read that aloud
// through the glasses. Every fire is logged, so a reminder that went off
// while you were asleep is recoverable rather than lost — which is exactly
// how Meta's glasses lose them today.

import UserNotifications

@MainActor
final class ChappyReminders: NSObject, ObservableObject {
    static let shared = ChappyReminders()

    @Published private(set) var lastSpoken: String = ""
    @Published var permissionDenied = false

    private var tickTimer: Timer?
    private var briefedOn: String {
        get { UserDefaults.standard.string(forKey: "chappy_brief_day") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "chappy_brief_day") }
    }

    private override init() { super.init() }

    // MARK: - Permission

    func requestPermission() {
        // BUILD 116 — THE DELEGATE MUST BE SET REGARDLESS.
        //
        // registerCategories() was only called INSIDE the permission callback,
        // and only when it returned true. So if permission was already decided
        // — which it is on every launch after the first — the action buttons
        // and the foreground handler could end up unregistered, and a
        // notification would either not show while you were in the app or
        // arrive with no Done / Snooze buttons on it.
        //
        // Setting the delegate is free and safe to do every launch. Do it
        // first, then ask.
        registerCategories()
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive]) { ok, _ in
                DispatchQueue.main.async {
                    self.permissionDenied = !ok
                    if ok { self.registerCategories() }
                }
                print(ok ? "🔔 [Reminders] Notifications allowed" : "⚠️ [Reminders] Notifications refused")
            }
    }

    // MARK: - Notification actions
    //
    // THE POINT: you should never have to open the app to deal with a
    // reminder. Long-press the banner on the lock screen and it's done,
    // snoozed ten minutes, or pushed until you're home — from the same screen
    // it appeared on. Siri gives you a fixed-interval snooze and nothing else;
    // "when I'm home" is the one people actually want and nobody offers it.
    /// Honest answer to "are notifications actually on?", for the diagnostics
    /// screen — so this never has to be guessed at again.
    func authorisationReport(_ done: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let state: String
            switch s.authorizationStatus {
            case .authorized:     state = "On"
            case .provisional:    state = "Quiet only — no sound or banner"
            case .denied:         state = "OFF — turn on in Settings › Chappy › Notifications"
            case .notDetermined:  state = "Never asked — reopen Chappy"
            default:              state = "Unknown"
            }
            let alerts = s.alertSetting == .enabled ? "banners on" : "BANNERS OFF"
            let sound = s.soundSetting == .enabled ? "sound on" : "SOUND OFF"
            let lock = s.lockScreenSetting == .enabled ? "lock screen on" : "lock screen off"
            done("\(state) · \(alerts) · \(sound) · \(lock)")
        }
    }

    func registerCategories() {
        let done = UNNotificationAction(identifier: "CHAPPY_DONE",
                                        title: "Done", options: [])
        let s10 = UNNotificationAction(identifier: "CHAPPY_SNOOZE10",
                                       title: "In 10 minutes", options: [])
        let sHome = UNNotificationAction(identifier: "CHAPPY_SNOOZE_HOME",
                                         title: "When I'm home", options: [])
        let cat = UNNotificationCategory(identifier: "CHAPPY_REMINDER",
                                         actions: [done, s10, sHome],
                                         intentIdentifiers: [],
                                         options: [])
        // Everything that is NOT a reminder — arrivals, imports, spend,
        // problems. No action buttons: tapping opens the right screen, and
        // there is nothing to "complete" about an arrival.
        let info = UNNotificationCategory(identifier: "CHAPPY_INFO",
                                          actions: [], intentIdentifiers: [], options: [])
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([cat, info])
        center.delegate = self
    }

    /// QUIET HOURS. A reminder that buzzes at 3am is one you turn off
    /// entirely, and then it never helps you again. Anything marked
    /// must-not-miss still comes through — that is what the flag is for.
    var inQuietHours: Bool {
        guard UserDefaults.standard.object(forKey: "chappy_quiet_hours") == nil
                || UserDefaults.standard.bool(forKey: "chappy_quiet_hours") else { return false }
        let h = Calendar.current.component(.hour, from: Date())
        let from = UserDefaults.standard.object(forKey: "chappy_quiet_from") as? Int ?? 22
        let to = UserDefaults.standard.object(forKey: "chappy_quiet_to") as? Int ?? 7
        return from > to ? (h >= from || h < to) : (h >= from && h < to)
    }

    // MARK: - Reading the list

    var all: [ChappyMemory.Entry] {
        ChappyMemory.shared.recent.filter { $0.kind == .reminder }
    }
    var open: [ChappyMemory.Entry] {
        all.filter { $0.doneAt == nil }
    }
    /// Due now-ish and not done. Snooze wins over the original time.
    func due(at when: Date = Date()) -> [ChappyMemory.Entry] {
        open.filter { r in
            guard let fire = r.effectiveFire else { return false }
            return fire <= when
        }.sorted { ($0.effectiveFire ?? .distantPast) < ($1.effectiveFire ?? .distantPast) }
    }
    func overdue(graceMinutes: Int = 2) -> [ChappyMemory.Entry] {
        let cutoff = Date().addingTimeInterval(-Double(graceMinutes) * 60)
        return due(at: cutoff).filter { $0.deliveredAt == nil || ($0.deliveredAt ?? .distantPast) < ($0.effectiveFire ?? .distantPast) }
    }
    func upcoming(limit: Int = 50) -> [ChappyMemory.Entry] {
        open.filter { ($0.effectiveFire ?? .distantFuture) > Date() }
            .sorted { ($0.effectiveFire ?? .distantFuture) < ($1.effectiveFire ?? .distantFuture) }
            .prefix(limit).map { $0 }
    }
    func today() -> [ChappyMemory.Entry] {
        open.filter {
            guard let f = $0.effectiveFire else { return false }
            return Calendar.current.isDateInToday(f)
        }.sorted { ($0.effectiveFire ?? .distantPast) < ($1.effectiveFire ?? .distantPast) }
    }
    func placeReminders() -> [ChappyMemory.Entry] {
        open.filter { !($0.placeTrigger ?? "").isEmpty }
    }
    func done(limit: Int = 60) -> [ChappyMemory.Entry] {
        all.filter { $0.doneAt != nil }
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    // BUILD 115 — CATEGORIES YOU NEVER HAVE TO CHOOSE.
    //
    // Every task app on earth loses people at the same moment: the dropdown
    // where you pick a list. So Chappy doesn't ask.
    //
    // Every reminder already knows where it came from — a job calendar, a
    // saved place, a Live AI conversation, a flight. The category IS that
    // provenance, and it is free. Manual override exists; you will rarely
    // need it.
    enum Category: String, CaseIterable {
        case work, travel, money, places, health, home, general

        var label: String {
            switch self {
            case .work:    return "Work"
            case .travel:  return "Travel"
            case .money:   return "Money"
            case .places:  return "Places"
            case .health:  return "Health"
            case .home:    return "Home"
            case .general: return "General"
            }
        }
        var icon: String {
            switch self {
            case .work:    return "briefcase.fill"
            case .travel:  return "airplane"
            case .money:   return "creditcard.fill"
            case .places:  return "mappin"
            case .health:  return "heart.fill"
            case .home:    return "house.fill"
            case .general: return "tray.fill"
            }
        }
        /// Same four choices as calendars, so there is one thing to learn.
        var defaultPings: Bool { self == .work || self == .travel || self == .money || self == .health }
    }

    /// Derived, then overridden. Tags win, then the words themselves, then
    /// where it came from.
    nonisolated static func category(of e: ChappyMemory.Entry) -> Category {
        if let raw = UserDefaults.standard.string(forKey: "chappy_rcat_" + e.id.uuidString),
           let c = Category(rawValue: raw) { return c }

        let t = (e.title + " " + e.body).lowercased()
        let tags = e.tags.joined(separator: " ")

        if !(e.placeTrigger ?? "").isEmpty { return .places }
        if tags.contains("job") || tags.contains("work")
            || ["invoice", "job ", "client", "shift", "geeks", "quote", "callout"]
                .contains(where: { t.contains($0) }) { return .work }
        if ["flight", "visa", "passport", "check in", "check-in", "boarding", "hotel",
            "airbnb", "booking", "ferry", "airport", "onward"]
            .contains(where: { t.contains($0) }) { return .travel }
        if ["pay", "invoice", "rent", "bill", "transfer", "insurance", "renew", "subscription"]
            .contains(where: { t.contains($0) }) { return .money }
        if ["tablet", "pill", "medication", "dentist", "doctor", "vaccin", "jab", "script"]
            .contains(where: { t.contains($0) }) { return .health }
        if ["laundry", "washing", "bins", "shopping", "groceries", "milk", "clean"]
            .contains(where: { t.contains($0) }) { return .home }
        if e.source == "records-fold" || e.source == "live-ai" { return .general }
        return .general
    }

    nonisolated static func setCategory(_ c: Category, for id: UUID) {
        UserDefaults.standard.set(c.rawValue, forKey: "chappy_rcat_" + id.uuidString)
    }

    /// Per-category behaviour — the mirror of the calendar picker, so there is
    /// one idea to learn rather than two.
    nonisolated static func categoryPings(_ c: Category) -> Bool {
        if let v = UserDefaults.standard.object(forKey: "chappy_rcatping_" + c.rawValue) as? Bool { return v }
        return c.defaultPings
    }
    nonisolated static func setCategoryPings(_ on: Bool, _ c: Category) {
        UserDefaults.standard.set(on, forKey: "chappy_rcatping_" + c.rawValue)
    }

    func inCategory(_ c: Category) -> [ChappyMemory.Entry] {
        open.filter { Self.category(of: $0) == c }
    }

    /// Which categories actually have something in them — no empty chips.
    var liveCategories: [Category] {
        var seen: [Category] = []
        for r in open {
            let c = Self.category(of: r)
            if !seen.contains(c) { seen.append(c) }
        }
        return Category.allCases.filter { seen.contains($0) }
    }

    // MARK: - Creating

    /// The one way in. Returns the stored reminder so a caller can confirm it.
    @discardableResult
    func add(title: String,
             at when: Date? = nil,
             floatingTime: String? = nil,
             place: String? = nil,
             repeatRule: String? = nil,
             leadMinutes: Int? = nil,
             escalate: Bool = false,
             thumbnail: Data? = nil,
             source: String = "voice") -> ChappyMemory.Entry {

        var e = ChappyMemory.shared.remember(.reminder,
                                            title: title,
                                            tags: ["reminder"],
                                            thumbnail: thumbnail,
                                            source: source)
        e.dueAt = when
        e.floatingTime = floatingTime
        e.placeTrigger = place
        e.repeatRule = repeatRule
        e.leadMinutes = leadMinutes
        e.escalate = escalate
        ChappyMemory.shared.replaceReminderFields(e)
        schedule(e)
        return e
    }

    /// PROMOTION. "Remind me about that thing I noted yesterday" attaches a
    /// trigger to a memory that already exists instead of writing a second
    /// copy of it. Nobody else does this, because nobody else keeps
    /// reminders and memories in one place.
    @discardableResult
    func promote(memoryID: UUID, to when: Date?, place: String? = nil) -> Bool {
        guard var e = ChappyMemory.shared.recent.first(where: { $0.id == memoryID }) else { return false }
        e.kind = .reminder
        e.dueAt = when
        e.placeTrigger = place
        e.doneAt = nil
        ChappyMemory.shared.replaceReminderFields(e)
        schedule(e)
        return true
    }

    // MARK: - Changing

    func complete(_ id: UUID) {
        guard var e = ChappyMemory.shared.recent.first(where: { $0.id == id }) else { return }
        cancelNotification(for: e)
        // COMPLETION-ANCHORED REPEATS: "every three days after I do it" counts
        // from NOW, not from when it was scheduled. Laundry works this way and
        // rent does not, and the difference is the whole point.
        if let rule = e.repeatRule, let next = Self.nextFire(rule: rule,
                                                            from: e.effectiveFire ?? Date(),
                                                            completedAt: Date()) {
            e.dueAt = next
            e.snoozedTo = nil
            e.deliveredAt = nil
            e.doneAt = nil
            ChappyMemory.shared.replaceReminderFields(e)
            schedule(e)
            print("🔁 [Reminders] '\(e.title)' repeats — next \(next)")
            return
        }
        e.doneAt = Date()
        e.snoozedTo = nil
        ChappyMemory.shared.replaceReminderFields(e)
    }

    func reopen(_ id: UUID) {
        guard var e = ChappyMemory.shared.recent.first(where: { $0.id == id }) else { return }
        e.doneAt = nil
        e.deliveredAt = nil
        ChappyMemory.shared.replaceReminderFields(e)
        schedule(e)
    }

    /// SEMANTIC SNOOZE. Ten minutes is the default, but "until I get home" and
    /// "tomorrow morning" use the same grammar as creating one — because the
    /// moment you have to think in minutes, you stop using it.
    func snooze(_ id: UUID, minutes: Int? = nil, until: Date? = nil, place: String? = nil) {
        guard var e = ChappyMemory.shared.recent.first(where: { $0.id == id }) else { return }
        cancelNotification(for: e)
        if let p = place {
            e.placeTrigger = p
            e.snoozedTo = nil
            e.dueAt = nil
        } else if let u = until {
            e.snoozedTo = u
        } else {
            e.snoozedTo = Date().addingTimeInterval(Double(minutes ?? 10) * 60)
        }
        e.deliveredAt = nil
        ChappyMemory.shared.replaceReminderFields(e)
        schedule(e)
    }

    func reschedule(_ id: UUID, to when: Date?, place: String?, floating: String?) {
        guard var e = ChappyMemory.shared.recent.first(where: { $0.id == id }) else { return }
        cancelNotification(for: e)
        e.dueAt = when
        e.placeTrigger = place
        e.floatingTime = floating
        e.snoozedTo = nil
        e.deliveredAt = nil
        ChappyMemory.shared.replaceReminderFields(e)
        schedule(e)
    }

    func delete(_ id: UUID) {
        if let e = ChappyMemory.shared.recent.first(where: { $0.id == id }) { cancelNotification(for: e) }
        ChappyMemory.shared.forget(id: id)
    }

    // MARK: - Notifications (the path that works with Chappy closed)

    private func schedule(_ e: ChappyMemory.Entry) {
        cancelNotification(for: e)
        guard e.doneAt == nil else { return }

        // FLOATING TIME. A floating reminder has no fixed instant — it is
        // "8am wherever I am", so it is scheduled as a CALENDAR trigger on
        // local hour and minute, and iOS re-evaluates it in the new zone the
        // moment you land. An absolute one is scheduled on its interval.
        let content = UNMutableNotificationContent()
        content.title = "Chappy"
        content.body = e.title
        content.sound = .default
        // A SUBTITLE THAT SAYS WHY IT FIRED. "Reminder" tells you nothing;
        // "every 3 days, from when you do it" tells you whether to act now.
        var sub: [String] = []
        if let p = e.placeTrigger, !p.isEmpty { sub.append("You're at \(p)") }
        if let rule = e.repeatRule { sub.append(Self.describe(rule: rule)) }
        if e.floatingTime != nil { sub.append("local time, wherever you are") }
        content.subtitle = sub.joined(separator: " · ")
        content.categoryIdentifier = "CHAPPY_REMINDER"
        // One thread, so ten reminders stack into one group instead of ten
        // separate banners burying everything else on the lock screen.
        content.threadIdentifier = "chappy-reminders"
        if e.escalate == true {
            content.interruptionLevel = .timeSensitive
        } else if inQuietHours {
            // Lands silently in the summary rather than waking anyone.
            content.interruptionLevel = .passive
            content.sound = nil
        }
        content.userInfo = ["chappyReminderID": e.id.uuidString,
                            "chappyUrgent": e.escalate == true,
                            "chappyPlace": e.placeTrigger ?? ""]

        var trigger: UNNotificationTrigger?
        if let hhmm = e.floatingTime, let parts = Self.hhmm(hhmm) {
            var dc = DateComponents()
            dc.hour = parts.0; dc.minute = parts.1
            trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: e.repeatRule != nil)
        } else if let fire = e.effectiveFire, fire > Date() {
            trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)
        }
        // A place-only reminder has no clock; ContextEngine fires it instead.
        guard let t = trigger else { return }

        let req = UNNotificationRequest(identifier: e.id.uuidString, content: content, trigger: t)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { print("⚠️ [Reminders] Could not schedule: \(err.localizedDescription)") }
        }
    }

    private func cancelNotification(for e: ChappyMemory.Entry) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [e.id.uuidString])
    }

    /// Re-arm everything after a restore, a reinstall, or a timezone change.
    func rescheduleAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        for e in open { schedule(e) }
        print("🔔 [Reminders] \(open.count) reminders re-armed")
    }

    // MARK: - Speaking (the path that works when Chappy IS running)

    func startTicking() {
        tickTimer?.invalidate()
        // 30s is close enough for a reminder and costs nothing — this is a
        // date comparison, not a wake-up.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stopTicking() { tickTimer?.invalidate(); tickTimer = nil }

    private func tick() {
        // Calendar warnings ride here rather than on the location fix: half
        // his jobs are REMOTE, so he never moves, so a movement-driven check
        // would never fire for exactly the events that matter most.
        ChappyCalendar.shared.checkHeadsUp()
        guard !TTSService.shared.isSpeaking else { return }
        let ready = due().filter {
            $0.deliveredAt == nil && Self.categoryPings(Self.category(of: $0))
        }
        guard let first = ready.first else { return }
        // QUIET HOURS: still marked delivered and still on the list, just not
        // spoken aloud at 3am. It surfaces in the morning brief instead.
        if inQuietHours && first.escalate != true { return }
        markDelivered(first)
        if first.escalate == true { ChappyHaptics.shared.reminderUrgent() }
        else { ChappyHaptics.shared.reminderDue() }
        ChappyEarcon.shared.wake()
        var line = first.title
        if ready.count > 1 { line += ". And \(ready.count - 1) more." }
        TTSService.shared.speak(line)
        lastSpoken = first.title
        // A spoken reminder is worth remembering that it happened. If it fired
        // while you were asleep, you can still find it.
        ChappyMemory.shared.remember(.note, title: "Reminder fired: \(first.title)",
                                     tags: ["reminder-fired"], source: "reminders")
    }

    private func markDelivered(_ e: ChappyMemory.Entry) {
        var c = e
        c.deliveredAt = Date()
        ChappyMemory.shared.replaceReminderFields(c)
    }

    // MARK: - The morning brief

    /// One paragraph, once a day, the first time you pick the phone up.
    /// Deliberately not an alarm — it happens when you're already there.
    func morningBriefIfDue() {
        let key = ChappyMemory.dayKey(Date())
        guard briefedOn != key else { return }
        guard UserDefaults.standard.object(forKey: "chappy_morning_brief") == nil
                || UserDefaults.standard.bool(forKey: "chappy_morning_brief") else { return }
        let h = Calendar.current.component(.hour, from: Date())
        guard h >= 5, h < 12 else { return }
        briefedOn = key
        let line = briefText()
        guard !line.isEmpty else { return }
        ChappyEarcon.shared.wake()
        TTSService.shared.speak(line)
    }

    /// BUILD 113 — TOMORROW, TONIGHT.
    ///
    /// A morning brief tells you about a day you are already standing in. By
    /// then it is too late to do anything about an eight o'clock job or a
    /// dinner someone else put in the shared calendar. The useful brief is the
    /// one the night before, while you can still act on it.
    ///
    /// Matters most for shared calendars specifically: your partner adds
    /// something at four in the afternoon and, without this, you find out
    /// about it when it is already happening.
    private var eveningBriefedOn: String {
        get { UserDefaults.standard.string(forKey: "chappy_eve_brief_day") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "chappy_eve_brief_day") }
    }

    func eveningBriefIfDue() {
        guard UserDefaults.standard.object(forKey: "chappy_evening_brief") == nil
                || UserDefaults.standard.bool(forKey: "chappy_evening_brief") else { return }
        let key = ChappyMemory.dayKey(Date())
        guard eveningBriefedOn != key else { return }
        let h = Calendar.current.component(.hour, from: Date())
        guard h >= 18, h < 23 else { return }
        let line = tomorrowText()
        guard !line.isEmpty else { eveningBriefedOn = key; return }
        eveningBriefedOn = key
        ChappyEarcon.shared.wake()
        TTSService.shared.speak(line)
    }

    func tomorrowText() -> String {
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())),
              let end = cal.date(byAdding: .day, value: 1, to: start) else { return "" }
        let events = ChappyCalendar.shared.events(from: start, to: end)
        let jobs = events.filter { !$0.isAllDay }
        let due = open.filter {
            guard let f = $0.effectiveFire else { return false }
            return f >= start && f < end
        }
        guard !jobs.isEmpty || !due.isEmpty else { return "" }

        let df = DateFormatter(); df.dateFormat = "h:mm a"
        var parts: [String] = ["Tomorrow."]
        if let first = jobs.first, let s = first.startDate {
            if jobs.count == 1 {
                parts.append("\(first.title ?? "One thing") at \(df.string(from: s)).")
            } else {
                parts.append("\(jobs.count) on, first at \(df.string(from: s)) - \(first.title ?? "").")
                if let last = jobs.last, let l = last.startDate {
                    parts.append("Last one \(df.string(from: l)).")
                }
            }
        }
        if !due.isEmpty {
            parts.append("\(due.count) reminder\(due.count == 1 ? "" : "s"): "
                         + due.prefix(3).map { $0.title }.joined(separator: ", ") + ".")
        }
        return parts.joined(separator: " ")
    }

    func briefText() -> String {
        var parts: [String] = []
        let name = UserDefaults.standard.string(forKey: "chappy_user_name") ?? ""
        let df = DateFormatter(); df.dateFormat = "h:mm a"

        // BUILD 132 — THE BRIEF THAT COULD NOT TELL THE TIME.
        //
        // It said "Morning. Nothing on today." at 2pm, directly above a 3pm
        // job it was not counting — because the greeting was hardcoded and
        // the brief only counted REMINDERS, never the calendar. Now the
        // greeting matches the clock and calendar jobs count as "on today".
        let hour = Calendar.current.component(.hour, from: Date())
        let dayPart = hour < 12 ? "Morning" : (hour < 17 ? "Afternoon" : "Evening")
        let greet = name.isEmpty ? "\(dayPart)." : "\(dayPart) \(name)."
        let jobs = ChappyCalendar.shared.today().filter {
            !$0.isAllDay && (($0.endDate ?? .distantPast) > Date())
        }

        let od = overdue()
        let t = today().filter { $0.deliveredAt == nil }
        if od.isEmpty && t.isEmpty && jobs.isEmpty {
            parts.append("\(greet) \(hour >= 17 ? "Nothing left today." : "Nothing on today.")")
        } else {
            parts.append(greet)
            // Calendar jobs themselves are spoken by agendaLine() below —
            // here they only stop the head from claiming an empty day.
            if !t.isEmpty {
                let list = t.prefix(3).map { "\($0.title) at \(df.string(from: $0.effectiveFire ?? Date()))" }
                parts.append("Today: \(list.joined(separator: ", ")).")
                if t.count > 3 { parts.append("And \(t.count - 3) more.") }
            }
            // OVERDUE IS BATCHED AND MENTIONED ONCE. Never re-rung on a
            // schedule — an assistant that nags is one you turn off.
            if !od.isEmpty {
                parts.append("\(od.count) overdue: \(od.prefix(2).map { $0.title }.joined(separator: ", ")).")
            }
        }
        // THE CALENDAR, MERGED. One agenda — a thing you have to be at and a
        // thing you have to do are the same question at 7am, and splitting
        // them across two apps is the reason people miss one of them.
        if let agenda = ChappyCalendar.shared.agendaLine() {
            parts.append("In the diary: \(agenda)")
        }
        let s = ContextEngine.shared.snapshot
        if let w = s.weather, let temp = s.temperatureC {
            parts.append("\(Int(temp.rounded())) degrees, \(w).")
        }
        // VISA — the highest-stakes recurring fact in a full-time traveller's
        // life, and the easiest to lose track of.
        if let visa = visaLine() { parts.append(visa) }
        // BUILD 147: what the last mail check found, never a fresh fetch.
        if ChappyMail.shared.isConfigured, !ChappyMail.shared.unread.isEmpty {
            let texts = ChappyMail.shared.unread.filter { $0.isText }.count
            let mails = ChappyMail.shared.unread.count - texts
            var bits: [String] = []
            if texts > 0 { bits.append("\(texts) text\(texts == 1 ? "" : "s")") }
            if mails > 0 { bits.append("\(mails) email\(mails == 1 ? "" : "s")") }
            parts.append("Unread: \(bits.joined(separator: " and ")).")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Visa countdown

    func setVisa(country: String, days: Int, entered: Date = Date()) {
        UserDefaults.standard.set(country, forKey: "chappy_visa_country")
        UserDefaults.standard.set(days, forKey: "chappy_visa_days")
        UserDefaults.standard.set(entered.timeIntervalSince1970, forKey: "chappy_visa_entered")
        let cal = Calendar.current
        // Warnings with enough runway to extend or fly, not to panic.
        for d in [14, 7, 3, 1] {
            guard let expiry = cal.date(byAdding: .day, value: days, to: entered),
                  let warn = cal.date(byAdding: .day, value: -d, to: expiry),
                  warn > Date() else { continue }
            add(title: "Visa for \(country) expires in \(d) day\(d == 1 ? "" : "s")",
                at: warn, escalate: d <= 3, source: "visa")
        }
        ChappyMemory.shared.remember(.note,
            title: "Entered \(country) on a \(days)-day visa",
            tags: ["visa", country.lowercased()], source: "visa")
    }

    func visaLine() -> String? {
        guard let country = UserDefaults.standard.string(forKey: "chappy_visa_country") else { return nil }
        let days = UserDefaults.standard.integer(forKey: "chappy_visa_days")
        let t = UserDefaults.standard.double(forKey: "chappy_visa_entered")
        guard days > 0, t > 0 else { return nil }
        let entered = Date(timeIntervalSince1970: t)
        guard let expiry = Calendar.current.date(byAdding: .day, value: days, to: entered) else { return nil }
        let left = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
        if left < 0 { return "Your \(country) visa expired \(-left) days ago." }
        if left > 21 { return nil }   // don't nag from day one
        return "\(left) day\(left == 1 ? "" : "s") left on your \(country) visa."
    }

    // MARK: - Place triggers  ·  called by ContextEngine on every fix

    /// "Remind me to buy sunscreen next time I'm at a supermarket."
    /// Google removed location reminders from Assistant and never brought them
    /// back; Meta's glasses never had them. This is the same geofence logic
    /// alert-when-near already uses.
    func checkPlaceTriggers() {
        let pending = placeReminders().filter { $0.deliveredAt == nil }
        guard !pending.isEmpty else { return }
        let s = ContextEngine.shared.snapshot
        let here = [s.street, s.suburb, s.city].compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        for r in pending {
            guard let want = r.placeTrigger?
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current),
                  !want.isEmpty else { continue }
            // A saved spot by name, or the street/suburb you're standing in.
            var hit = here.contains(want)
            if !hit, let spot = TripRecorder.shared.spots.last(where: {
                $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                locale: .current).contains(want) }),
               let la = s.latitude, let lo = s.longitude {
                hit = TripRecorder.meters(la, lo, spot.lat, spot.lon) < 150
            }
            guard hit else { continue }
            markDelivered(r)
            ChappyHaptics.shared.reminderPlace()
            ChappyEarcon.shared.wake()
            TTSService.shared.speak("You're at \(r.placeTrigger ?? "the place") - \(r.title)")
        }
    }

    // MARK: - Leave-by
    //
    // A reminder with a place doesn't warn you at the time, it warns you when
    // you have to LEAVE. Chappy already computes real routes, so this is the
    // difference between a list and a secretary.

    func checkLeaveBy() async {
        let candidates = open.filter {
            $0.leadMinutes != nil && $0.dueAt != nil && $0.deliveredAt == nil
                && !($0.placeTrigger ?? "").isEmpty
        }
        for r in candidates {
            guard let due = r.dueAt, let lead = r.leadMinutes else { continue }
            // Only worth a lookup inside a sensible window.
            let mins = due.timeIntervalSinceNow / 60
            guard mins > 0, mins < Double(lead) + 45 else { continue }
            guard let travel = await NavEngine.shared.travelMinutes(to: r.placeTrigger ?? "") else { continue }
            let leaveAt = due.addingTimeInterval(-Double(travel + lead) * 60)
            guard Date() >= leaveAt else { continue }
            markDelivered(r)
            ChappyHaptics.shared.reminderUrgent()
            ChappyEarcon.shared.wake()
            TTSService.shared.speak("Time to go - \(r.title). It's about \(travel) minutes from here.")
        }
    }

    // MARK: - Spoken answers

    func spokenList() -> String {
        let t = today(), od = overdue(), up = upcoming(limit: 3)
        if t.isEmpty && od.isEmpty && up.isEmpty { return "Nothing on the list." }
        var parts: [String] = []
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        if !od.isEmpty {
            parts.append("\(od.count) overdue: \(od.prefix(3).map { $0.title }.joined(separator: ", ")).")
        }
        if !t.isEmpty {
            parts.append("Today: " + t.prefix(4).map {
                "\($0.title) at \(df.string(from: $0.effectiveFire ?? Date()))" }.joined(separator: ", ") + ".")
        } else if let n = up.first, let f = n.effectiveFire {
            let day = DateFormatter(); day.dateFormat = "EEEE 'at' h:mm a"
            parts.append("Next up: \(n.title), \(day.string(from: f)).")
        }
        if let agenda = ChappyCalendar.shared.agendaLine(limit: 3) {
            parts.append("Diary: \(agenda)")
        }
        let places = placeReminders()
        if !places.isEmpty {
            parts.append("\(places.count) waiting on a place.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Recurrence
    //
    // "every 3 days"  → anchored to the SCHEDULE (rent, tablets)
    // "every 3 days after I do it" → anchored to COMPLETION (laundry, haircut)
    // The second one is the useful one and no voice assistant has it.

    /// Rules are stored as compact strings so they survive a JSON round trip:
    ///   "d3"          every 3 days
    ///   "d3!"         every 3 days AFTER COMPLETION
    ///   "w1:mon,fri"  every week on Monday and Friday
    ///   "m1"          every month
    nonisolated static func nextFire(rule: String, from scheduled: Date, completedAt: Date) -> Date? {
        let anchorCompletion = rule.hasSuffix("!")
        var r = anchorCompletion ? String(rule.dropLast()) : rule
        let cal = Calendar.current
        let base = anchorCompletion ? completedAt : scheduled

        var weekdays: [Int] = []
        if let colon = r.firstIndex(of: ":") {
            let names = String(r[r.index(after: colon)...]).split(separator: ",").map(String.init)
            let map = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
            weekdays = names.compactMap { map[String($0.prefix(3))] }.sorted()
            r = String(r[r.startIndex..<colon])
        }
        guard let unit = r.first else { return nil }
        let n = max(1, Int(r.dropFirst()) ?? 1)

        // Named weekdays: walk forward to the next one in the set.
        if !weekdays.isEmpty {
            var d = cal.date(byAdding: .day, value: 1, to: base) ?? base
            for _ in 0..<14 {
                if weekdays.contains(cal.component(.weekday, from: d)) { return keepTime(of: scheduled, on: d) }
                d = cal.date(byAdding: .day, value: 1, to: d) ?? d
            }
            return nil
        }
        switch unit {
        case "d": return cal.date(byAdding: .day, value: n, to: base)
        case "w": return cal.date(byAdding: .weekOfYear, value: n, to: base)
        case "m": return cal.date(byAdding: .month, value: n, to: base)
        case "y": return cal.date(byAdding: .year, value: n, to: base)
        case "h": return cal.date(byAdding: .hour, value: n, to: base)
        default:  return nil
        }
    }

    nonisolated private static func keepTime(of source: Date, on day: Date) -> Date {
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute], from: source)
        return cal.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: day) ?? day
    }

    nonisolated static func hhmm(_ s: String) -> (Int, Int)? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, p[0] >= 0, p[0] < 24, p[1] >= 0, p[1] < 60 else { return nil }
        return (p[0], p[1])
    }

    /// Plain English for a rule, for the card and for speaking it back.
    // MARK: - Acting on a notification
    //
    // Both of these arrive off the main actor, so each hops back before it
    // touches anything. A completion handler that is never called is an app
    // iOS starts treating as unresponsive, so both always call theirs.

    nonisolated static func describe(rule: String) -> String {
        let anchored = rule.hasSuffix("!")
        var r = anchored ? String(rule.dropLast()) : rule
        var days = ""
        if let colon = r.firstIndex(of: ":") {
            days = " on " + String(r[r.index(after: colon)...]).replacingOccurrences(of: ",", with: ", ")
            r = String(r[r.startIndex..<colon])
        }
        guard let u = r.first else { return "repeats" }
        let n = max(1, Int(r.dropFirst()) ?? 1)
        let unit = ["d": "day", "w": "week", "m": "month", "y": "year", "h": "hour"][String(u)] ?? "day"
        let every = n == 1 ? "every \(unit)" : "every \(n) \(unit)s"
        return every + days + (anchored ? ", from when you do it" : "")
    }
}


extension ChappyReminders: UNUserNotificationCenterDelegate {

    /// A reminder that arrives while you are already looking at the phone
    /// should still show and still buzz — otherwise the one time you are
    /// holding it is the one time it goes missing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        let urgent = (info["chappyUrgent"] as? Bool) ?? false
        let place = (info["chappyPlace"] as? String) ?? ""
        Task { @MainActor in
            if urgent { ChappyHaptics.shared.reminderUrgent() }
            else if !place.isEmpty { ChappyHaptics.shared.reminderPlace() }
            else { ChappyHaptics.shared.reminderDue() }
        }
        completionHandler([.banner, .list, .sound])
    }

    /// Done, snoozed, or opened — all three without unlocking into the app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let idString = response.notification.request.content.userInfo["chappyReminderID"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            // An informational one carries the screen it belongs to, so a tap
            // lands where the thing actually is rather than on the home screen.
            if let opens = response.notification.request.content
                .userInfo["chappyOpens"] as? String {
                NotificationCenter.default.post(name: Notification.Name(opens), object: nil)
                return
            }
            guard let s = idString, let id = UUID(uuidString: s) else {
                NotificationCenter.default.post(name: .chappyOpenReminders, object: nil)
                return
            }
            switch action {
            case "CHAPPY_DONE":
                ChappyReminders.shared.complete(id)
                ChappyHaptics.shared.reminderDone()
            case "CHAPPY_SNOOZE10":
                ChappyReminders.shared.snooze(id, minutes: 10)
                ChappyHaptics.shared.reminderSnoozed()
            case "CHAPPY_SNOOZE_HOME":
                ChappyReminders.shared.snooze(id, place: "home")
                ChappyHaptics.shared.reminderSnoozed()
            default:
                // Tapped the banner itself — open the list, not the home screen.
                NotificationCenter.default.post(name: .chappyOpenReminders, object: nil)
            }
        }
    }
}


// =====================================================================
// MARK: - CHAPPY NOTIFY (Phase 5.5 — the pocket channel)
// =====================================================================
//
// THE RULE THAT KEEPS THIS FROM BECOMING SPAM:
//
//   A notification is for something you would want to know when you are NOT
//   looking, and could not have found out any other way.
//
// Chappy already has a mouth. Anything it tells you out loud while the ear is
// armed does NOT need a banner as well — that is how an app trains you to
// swipe everything away without reading it, and then the one that mattered
// goes with the rest. So every post goes through `voiceCouldNotReach()`
// first: if the app is in front of you, or the ear is armed and speaking,
// the notification is skipped, because you already know.
//
// What that leaves is exactly the useful set: things that happen while the
// app is closed, backgrounded, or has quietly died — which, on this project,
// is most of the failures that cost days.
//
// Every category can be turned off on its own. Nothing here is important
// enough to be un-silenceable except the ones you marked must-not-miss.

enum ChappyNotify {

    enum Channel: String, CaseIterable {
        case nav        // arrived, route stopped, watchpoint hit
        case money      // daily spend crossing a threshold
        case memory     // glasses import done, old conversations read
        case system     // the ear stopped, battery, glasses dropped
        case claw       // a job finished on the home computer
        case research   // a long answer came back

        var label: String {
            switch self {
            case .nav: return "Navigation"
            case .money: return "Spending"
            case .memory: return "Memory & imports"
            case .system: return "Problems and battery"
            case .claw: return "Home computer"
            case .research: return "Research answers"
            }
        }
        var detail: String {
            switch self {
            case .nav: return "Arrived, route ended unexpectedly, or a place you asked to be told about"
            case .money: return "When the day's AI spend crosses two, five and ten dollars"
            case .memory: return "Overnight glasses imports and old conversations finishing"
            case .system: return "The wake word stopping, battery getting low, glasses dropping out — the silent failures"
            case .claw: return "A job you sent to the home computer finishing"
            case .research: return "A deep research answer arriving after you walked away"
            }
        }
        var defaultOn: Bool { self == .money ? true : true }
        var key: String { "chappy_notify_" + rawValue }
    }

    /// True when speaking would NOT have reached him — which is the only time
    /// a banner earns its place.
    @MainActor
    static func voiceCouldNotReach() -> Bool {
        // In the foreground he is looking at the screen; a banner is noise.
        if UIApplication.shared.applicationState == .active { return false }
        // Armed in a pocket with background audio: Chappy can speak, so it does.
        if ChappyStandby.shared.isListening && ChappyStandby.backgroundAudioAllowed { return false }
        return true
    }

    @MainActor
    static func post(_ channel: Channel,
                     title: String,
                     body: String,
                     critical: Bool = false,
                     opens: Notification.Name? = nil,
                     force: Bool = false) {
        guard UserDefaults.standard.object(forKey: channel.key) == nil
                || UserDefaults.standard.bool(forKey: channel.key) else { return }
        if !force && !voiceCouldNotReach() { return }

        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.threadIdentifier = "chappy-" + channel.rawValue
        c.categoryIdentifier = "CHAPPY_INFO"
        if critical {
            c.interruptionLevel = .timeSensitive
            c.sound = .default
        } else if ChappyReminders.shared.inQuietHours {
            c.interruptionLevel = .passive
            c.sound = nil
        } else {
            c.sound = .default
        }
        if let o = opens { c.userInfo = ["chappyOpens": o.rawValue] }

        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        print("🔔 [Notify] \(channel.rawValue): \(title) — \(body)")
    }

    /// Say it out loud AND post it if the voice could not have landed. One
    /// call site instead of two, so a module can never accidentally do both.
    @MainActor
    static func announce(_ channel: Channel,
                         spoken: String,
                         title: String,
                         body: String? = nil,
                         critical: Bool = false,
                         opens: Notification.Name? = nil) {
        if voiceCouldNotReach() {
            post(channel, title: title, body: body ?? spoken, critical: critical, opens: opens, force: true)
        } else {
            TTSService.shared.speak(spoken)
        }
    }
}

// =====================================================================
// MARK: - SAYING IT OUT LOUD (Phase 5.5 capture)
// =====================================================================
//
// The research finding that shaped this: every typed parser on the market
// (Todoist, Fantastical) solves the "is Friday part of the title or the due
// date" problem by making you use quotes. There is no spoken equivalent of a
// quote mark. So the split has to be done by structure — find the time
// phrase, cut it out, and whatever is left is the thing to be reminded of.
//
// And the second finding: never block capture on a clarification. If the time
// is ambiguous, pick the sensible one, SAY which one you picked, and let him
// correct it. A reminder that failed to be created because it wanted to ask a
// question is worse than a reminder set an hour out.

extension ChappyStandby {

    struct ParsedReminder {
        var title: String
        var date: Date?
        var floating: String?      // "HH:mm" — 8am wherever I am
        var place: String?
        var rule: String?          // "d3", "d3!", "w1:mon,fri"
        var lead: Int?
        var escalate = false
        /// What to say back. Short by design — a five-word tail, never a
        /// full readback. Confirmation fatigue is why people stop using these.
        var confirmation: String = ""
    }

    /// Words that mean "this is the reminder text" and everything after the
    /// time phrase belongs to it.
    private static let reminderOpeners = [
        "remind me to ", "remind me that ", "remind me ", "remind us to ", "remind us ",
        "set a reminder to ", "set a reminder for ", "set a reminder ",
        "don't let me forget to ", "dont let me forget to ", "don't let me forget ",
        "dont let me forget ", "make sure i ", "make sure we ",
        "nudge me to ", "nudge me ", "ping me to ", "ping me ", "tell me to ",
    ]

    static func looksLikeReminder(_ c: String) -> Bool {
        reminderOpeners.contains { c.contains($0) }
    }

    // MARK: The parser

    static func parseReminder(_ raw: String) -> ParsedReminder? {
        var c = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opener = reminderOpeners.first(where: { c.contains($0) }),
              let r = c.range(of: opener) else { return nil }
        c = String(c[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
        guard c.count > 2 else { return nil }

        var out = ParsedReminder(title: c)

        // ---- IMPLIED PLACES ------------------------------------------------
        // "when I get home" names no place after it — the place IS the phrase,
        // and the task can sit on either side of it. "Ping me when I get home
        // to water the plants" broke every parser I tested it against.
        for (phrase, resolved) in [("when i get home", "home"), ("when i'm home", "home"),
                                   ("when im home", "home"), ("when i'm back home", "home"),
                                   ("when i get back home", "home"),
                                   ("when i get to the hotel", "hotel"),
                                   ("when i'm at the hotel", "hotel"),
                                   ("when im at the hotel", "hotel"),
                                   ("when i get back to the hotel", "hotel"),
                                   ("when i get to the room", "hotel")] {
            guard let r = c.range(of: phrase) else { continue }
            var t = c.replacingCharacters(in: r, with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            if t.hasPrefix("to ") { t = String(t.dropFirst(3)) }
            out.place = resolved
            out.title = t.isEmpty ? raw : t
            out.lead = nil
            out.confirmation = "When you're \(resolved == "home" ? "home" : "at the hotel"), got it."
            return finish(out)
        }

        // ---- PLACE TRIGGERS ------------------------------------------------
        // Google removed these from Assistant and never brought them back;
        // Meta's glasses never had them. They are the ones people actually
        // want, because most tasks are bound to a place, not a clock.
        for opener in ["when i'm at ", "when im at ", "when i am at ",
                       "next time i'm at ", "next time im at ", "next time i'm in ",
                       "next time im in ", "when i get to ", "when i'm near ",
                       "when im near ", "when we're at ", "when were at ",
                       "when i'm back at ", "when im back at ", "when i get home",
                       "when i'm home", "when im home", "at the "] {
            guard let pr = c.range(of: opener) else { continue }
            let place = String(c[pr.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            // "when I get home" has no tail — the place IS the phrase.
            // "next time I'm at a supermarket to buy sunscreen" — the task can
            // trail the place as easily as lead it.
            var resolved = place
            var trailingTask = ""
            if let toR = place.range(of: " to ") {
                resolved = String(place[place.startIndex..<toR.lowerBound])
                trailingTask = String(place[toR.upperBound...])
            }
            resolved = resolved.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            if resolved.hasPrefix("a ") { resolved = String(resolved.dropFirst(2)) }
            if resolved.hasPrefix("the ") { resolved = String(resolved.dropFirst(4)) }
            guard resolved.count > 1 else { continue }
            out.place = resolved
            out.title = String(c[c.startIndex..<pr.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            if out.title.isEmpty { out.title = trailingTask }
            if out.title.isEmpty { out.title = raw }
            out.confirmation = "At the \(resolved), got it."
            // A place reminder can still carry a lead time for leave-by.
            out.lead = 5
            return finish(out)
        }

        // ---- RECURRENCE ---------------------------------------------------
        if let rule = repeatRule(in: c) {
            out.rule = rule.0
            out.title = strip(rule.1, from: out.title)
        }

        // ---- TIME ---------------------------------------------------------
        // Floating first: "at 8 every morning wherever I am" and the plain
        // daily shapes mean local-clock, not a fixed instant.
        if out.rule != nil, let hhmm = plainClock(in: c) {
            out.floating = hhmm
            out.title = strip(hhmm.replacingOccurrences(of: ":", with: ""), from: out.title)
            out.title = stripTimeWords(out.title)
            out.confirmation = "\(spoken(hhmm)) \(ChappyReminders.describe(rule: out.rule ?? "d1")), got it."
            return finish(out)
        }

        // Relative shapes the system detector handles badly.
        if let quick = relative(in: c) {
            out.date = quick.0
            out.title = strip(quick.1, from: out.title)
            out.confirmation = "\(shortWhen(quick.0)), got it."
            return finish(out)
        }

        // The system detector. Good at "tomorrow at 6", "next Tuesday at 3",
        // "on the 14th", and it hands back the exact substring it consumed —
        // which is what lets the title be cut cleanly without quote marks.
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = c as NSString
            let matches = det.matches(in: c, range: NSRange(location: 0, length: ns.length))
            if let m = matches.last, let d = m.date {
                var when = d
                // AM/PM AMBIGUITY: never block on it. "at 6" with no meridiem
                // that lands in the past almost always meant the evening.
                if when < Date(), Calendar.current.isDateInToday(when),
                   let bumped = Calendar.current.date(byAdding: .hour, value: 12, to: when),
                   bumped > Date() {
                    when = bumped
                }
                if when < Date() {
                    when = Calendar.current.date(byAdding: .day, value: 1, to: when) ?? when
                }
                out.date = when
                out.title = strip(ns.substring(with: m.range), from: out.title)
                out.confirmation = "\(shortWhen(when)), got it."
                return finish(out)
            }
        }

        if out.rule != nil {
            out.floating = "09:00"
            out.confirmation = "\(ChappyReminders.describe(rule: out.rule ?? "d1")) at nine, got it."
            return finish(out)
        }

        // No time and no place. Still a reminder — it just sits on the list
        // until it's given one. Losing the capture would be worse.
        out.confirmation = "On the list, no time set."
        return finish(out)
    }

    private static func finish(_ p: ParsedReminder) -> ParsedReminder {
        var o = p
        o.title = stripTimeWords(o.title)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
        if o.title.count < 2 { o.title = "Reminder" }
        o.title = o.title.prefix(1).uppercased() + o.title.dropFirst()
        // Escalate anything that reads like it must not be missed.
        let urgent = ["flight", "check in", "check-in", "passport", "visa", "boarding",
                      "ferry", "train", "bus", "medication", "tablet", "pill", "insulin"]
        if urgent.contains(where: { o.title.lowercased().contains($0) }) { o.escalate = true }
        return o
    }

    // MARK: Pieces

    private static func strip(_ fragment: String, from title: String) -> String {
        guard !fragment.isEmpty else { return title }
        var t = title
        if let r = t.lowercased().range(of: fragment.lowercased()) {
            t = t.replacingCharacters(in: r, with: " ")
        }
        return t.replacingOccurrences(of: "  ", with: " ")
    }

    private static func stripTimeWords(_ s: String) -> String {
        var t = " " + s + " "
        for w in [" at ", " on ", " by ", " in ", " this ", " next ", " every ", " o'clock ",
                  " oclock ", " am ", " pm ", " today ", " tomorrow ", " tonight ",
                  " morning ", " afternoon ", " evening ", " the ", " a "] {
            if t.hasSuffix(w) { t = String(t.dropLast(w.count - 1)) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "in 20 minutes", "in an hour", "tonight", "tomorrow morning".
    private static func relative(in c: String) -> (Date, String)? {
        let cal = Calendar.current
        if let r = c.range(of: #"in (\d+|a|an) (minute|minutes|min|mins|hour|hours|hr|hrs|day|days|week|weeks)"#,
                           options: .regularExpression) {
            let frag = String(c[r])
            let parts = frag.split(separator: " ").map(String.init)
            let n = (parts.count > 1 ? (Int(parts[1]) ?? 1) : 1)
            let unit = parts.last ?? "minutes"
            var d: Date?
            if unit.hasPrefix("min") { d = cal.date(byAdding: .minute, value: n, to: Date()) }
            else if unit.hasPrefix("h") { d = cal.date(byAdding: .hour, value: n, to: Date()) }
            else if unit.hasPrefix("d") { d = cal.date(byAdding: .day, value: n, to: Date()) }
            else if unit.hasPrefix("w") { d = cal.date(byAdding: .weekOfYear, value: n, to: Date()) }
            if let d { return (d, frag) }
        }
        // Named parts of the day, with the hours a person actually means.
        let named: [(String, Int, Int)] = [
            ("tomorrow morning", 1, 8), ("tomorrow afternoon", 1, 14),
            ("tomorrow evening", 1, 19), ("tomorrow night", 1, 20),
            ("tonight", 0, 19), ("this evening", 0, 19), ("this afternoon", 0, 14),
            ("in the morning", 1, 8), ("first thing", 1, 7),
        ]
        for (phrase, dayOffset, hour) in named where c.contains(phrase) {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: Date()),
                  var d = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { continue }
            if d < Date() { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
            return (d, phrase)
        }
        return nil
    }

    /// "every day", "every 3 days", "every monday and friday", "every other
    /// week", and the one nobody else has — "every 3 days AFTER I DO IT".
    private static func repeatRule(in c: String) -> (String, String)? {
        guard c.contains("every ") || c.contains("each ") || c.contains("daily")
                || c.contains("weekly") || c.contains("monthly") else { return nil }

        // Completion-anchored: laundry, haircut, oil change. Todoist writes
        // this as "every!" and no voice assistant supports it at all.
        let anchored = ["after i do it", "after i've done it", "after ive done it",
                        "from when i do it", "after it's done", "after its done"]
            .contains { c.contains($0) }
        let bang = anchored ? "!" : ""

        let dayNames = ["monday": "mon", "tuesday": "tue", "wednesday": "wed",
                        "thursday": "thu", "friday": "fri", "saturday": "sat", "sunday": "sun"]
        let hits = dayNames.filter { c.contains($0.key) }
        if !hits.isEmpty {
            let ordered = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
                .filter { hits.values.contains($0) }
            return ("w1:" + ordered.joined(separator: ","), "every")
        }
        if c.contains("daily") || c.contains("every day") || c.contains("each day") {
            return ("d1" + bang, "every day")
        }
        if c.contains("every other day") { return ("d2" + bang, "every other day") }
        if c.contains("every other week") { return ("w2" + bang, "every other week") }
        if c.contains("weekly") || c.contains("every week") { return ("w1" + bang, "every week") }
        if c.contains("monthly") || c.contains("every month") { return ("m1" + bang, "every month") }
        if c.contains("every year") || c.contains("yearly") { return ("y1" + bang, "every year") }
        if let r = c.range(of: #"every (\d+) (day|days|week|weeks|month|months|hour|hours)"#,
                           options: .regularExpression) {
            let frag = String(c[r])
            let parts = frag.split(separator: " ").map(String.init)
            let n = Int(parts[1]) ?? 1
            let u = String(parts[2].prefix(1))
            return ("\(u)\(n)\(bang)", frag)
        }
        return nil
    }

    /// A bare clock time inside a recurring phrase — "every day at 8".
    private static func plainClock(in c: String) -> String? {
        guard let r = c.range(of: #"at (\d{1,2})(:(\d{2}))?\s?(am|pm)?"#, options: .regularExpression)
        else { return nil }
        let frag = String(c[r])
        let nums = frag.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }.compactMap { Int($0) }
        guard var h = nums.first else { return nil }
        let m = nums.count > 1 ? nums[1] : 0
        if frag.contains("pm"), h < 12 { h += 12 }
        if frag.contains("am"), h == 12 { h = 0 }
        // No meridiem and a small number: 7 means morning, 8 means morning.
        if !frag.contains("am"), !frag.contains("pm"), h <= 5 { h += 12 }
        guard h < 24, m < 60 else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    private static func spoken(_ hhmm: String) -> String {
        guard let p = ChappyReminders.hhmm(hhmm) else { return hhmm }
        let ampm = p.0 < 12 ? "am" : "pm"
        var h = p.0 % 12; if h == 0 { h = 12 }
        return p.1 == 0 ? "\(h)\(ampm)" : String(format: "%d:%02d%@", h, p.1, ampm)
    }

    /// A five-word tail, never a full readback.
    private static func shortWhen(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) { f.dateFormat = "'today at' h:mm a" }
        else if cal.isDateInTomorrow(d) { f.dateFormat = "'tomorrow at' h:mm a" }
        else if let days = cal.dateComponents([.day], from: Date(), to: d).day, days < 7 {
            f.dateFormat = "EEEE 'at' h:mm a"
        } else { f.dateFormat = "d MMM 'at' h:mm a" }
        return f.string(from: d)
    }
}

// =====================================================================
// MARK: - CHAPPY CALENDAR (Phase 5.5 — one agenda, every account)
// =====================================================================
//
// EventKit reads whatever calendars are already subscribed on the phone.
// iCloud, Outlook, Google, a shared family calendar — all of them, through
// ONE permission, with no OAuth, no per-provider work, no server, and
// nothing running at home. If the account is in iOS Settings, Chappy sees it.
//
// That is why calendar comes before email: the same day of work covers three
// providers instead of one, and it works on a plane.
//
// NOTHING IS COPIED. Events are read live and never duplicated into the
// memory store — a calendar entry that gets moved would otherwise leave a
// stale copy behind, and the whole promise of this store is that there is one
// truth. What DOES get stored is a memory when an appointment has actually
// happened, because "when did I meet the villa guy" is a question about the
// past, and the past is what memory is for.
//
// REQUIRES: NSCalendarsFullAccessUsageDescription in Info.plist.

import EventKit

@MainActor
final class ChappyCalendar: ObservableObject {
    static let shared = ChappyCalendar()

    private let store = EKEventStore()
    @Published private(set) var authorised = false
    @Published private(set) var lastError: String?

    private init() {}

    // MARK: Permission

    func requestAccess() {
        if #available(iOS 17.0, *) {
            store.requestFullAccessToEvents { [weak self] ok, err in
                Task { @MainActor in
                    self?.authorised = ok
                    self?.lastError = err?.localizedDescription
                    if ok { print("📅 [Calendar] Access granted") }
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] ok, err in
                Task { @MainActor in
                    self?.authorised = ok
                    self?.lastError = err?.localizedDescription
                }
            }
        }
    }

    // MARK: Which calendars count
    //
    // Everything is included until he switches one off. The common case is a
    // work calendar he doesn't want read aloud on holiday, not a hunt through
    // a checklist before the feature does anything.

    var allCalendars: [EKCalendar] {
        guard authorised else { return [] }
        return store.calendars(for: .event)
            .sorted { ($0.source?.title ?? "") + $0.title < ($1.source?.title ?? "") + $1.title }
    }

    private func isOn(_ cal: EKCalendar) -> Bool {
        let key = "chappy_cal_" + cal.calendarIdentifier
        return UserDefaults.standard.object(forKey: key) == nil
            || UserDefaults.standard.bool(forKey: key)
    }

    func setOn(_ cal: EKCalendar, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "chappy_cal_" + cal.calendarIdentifier)
    }

    func isEnabled(_ cal: EKCalendar) -> Bool { isOn(cal) }

    // BUILD 111 — PER-CALENDAR BEHAVIOUR.
    //
    // Twelve calendars treated identically is unusable: your Geeks2U jobs and
    // a birthday should not get the same treatment, and reading all of it out
    // every morning is how you end up switching the whole thing off.
    //
    // Four behaviours, one tap each, set once:
    //   PING   spoken and notified before it starts, plus leave-by
    //   BRIEF  read out in the morning, silent otherwise   (the default)
    //   SHOW   visible in the diary, never spoken
    //   IGNORE not read at all
    enum Behaviour: String, CaseIterable {
        case ping, brief, show, ignore
        var label: String {
            switch self {
            case .ping:   return "Ping me"
            case .brief:  return "In the brief"
            case .show:   return "Just show it"
            case .ignore: return "Ignore"
            }
        }
        var detail: String {
            switch self {
            case .ping:   return "Warned before it starts, and told when to leave"
            case .brief:  return "Read out in the morning, silent the rest of the day"
            case .show:   return "Appears in the diary, never spoken"
            case .ignore: return "Not read at all"
            }
        }
    }

    func behaviour(for cal: EKCalendar) -> Behaviour {
        if let raw = UserDefaults.standard.string(forKey: "chappy_calb_" + cal.calendarIdentifier),
           let b = Behaviour(rawValue: raw) { return b }
        // SENSIBLE UNTIL TOLD OTHERWISE. A work calendar full of jobs wants
        // warning about; a holiday calendar does not. Guessing right by
        // default beats a settings screen nobody opens.
        let t = cal.title.lowercased()
        if ["job", "work", "geek", "shift", "roster", "booking"].contains(where: { t.contains($0) }) {
            return .ping
        }
        if ["holiday", "birthday", "school"].contains(where: { t.contains($0) }) {
            return .show
        }
        return .brief
    }

    func setBehaviour(_ b: Behaviour, for cal: EKCalendar) {
        UserDefaults.standard.set(b.rawValue, forKey: "chappy_calb_" + cal.calendarIdentifier)
    }

    /// How long before it starts you want telling. Per calendar, because a job
    /// and a dinner do not need the same runway.
    /// BUILD 113: this capped at two hours, so there was no way to say "tell
    /// me the day before". Some things — a booking, a flight, anything you
    /// have to prepare for — are useless as a thirty-minute warning.
    func leadMinutes(for cal: EKCalendar) -> Int {
        let v = UserDefaults.standard.integer(forKey: "chappy_call_" + cal.calendarIdentifier)
        return v > 0 ? v : 30
    }

    /// Plain English for a lead time, however long it is.
    nonisolated static func leadLabel(_ m: Int) -> String {
        if m >= 1440 { let d = m / 1440; return d == 1 ? "the day before" : "\(d) days before" }
        if m >= 60 { let h = m / 60; let r = m % 60
            return r == 0 ? "\(h) hour\(h == 1 ? "" : "s") before"
                          : "\(h)h \(r)m before" }
        return "\(m) minutes before"
    }

    func setLeadMinutes(_ m: Int, for cal: EKCalendar) {
        UserDefaults.standard.set(m, forKey: "chappy_call_" + cal.calendarIdentifier)
    }

    // BUILD 114 — PER-EVENT OVERRIDE.
    //
    // A flight and a dentist appointment can live in the same calendar, and no
    // per-calendar setting can tell them apart. So any single event can be
    // lifted above — or dropped below — whatever its calendar says.
    //
    //   IMPORTANT  day before AND an hour before, time-sensitive so it pierces
    //              Focus and quiet hours. Flights, payments, bookings — the
    //              things where late is the same as never.
    //   NORMAL     whatever the calendar is set to.
    //   MUTED      silent, still visible. A recurring thing you don't need.
    //
    // NOTHING IS WRITTEN BACK TO EVENTKIT. The flags live here, so a shared
    // calendar is never modified and whoever shares it sees nothing.
    enum EventLevel: String { case important, normal, muted }

    /// FINGERPRINT, NOT IDENTIFIER.
    /// A subscribed feed — your Geeks2U one — can regenerate event IDs when it
    /// refreshes, which would silently detach an "important" flag from its
    /// event. Title plus start time plus calendar survives that. It is the
    /// kind of thing that looks fine for a week and then stops working in
    /// Ubud, which is exactly when it would matter.
    nonisolated static func fingerprint(_ e: EKEvent) -> String {
        let t = (e.title ?? "").lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .prefix(40)
        let start = Int((e.startDate ?? Date()).timeIntervalSince1970)
        let cal = e.calendar?.calendarIdentifier ?? "?"
        return "\(t)|\(start)|\(cal)"
    }

    private var eventLevels: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "chappy_event_levels") as? [String: String]) ?? [:] }
        set {
            // Capped, oldest-ish dropped, so this can never grow unbounded.
            var v = newValue
            if v.count > 400 { v = Dictionary(uniqueKeysWithValues: Array(v).suffix(400)) }
            UserDefaults.standard.set(v, forKey: "chappy_event_levels")
        }
    }

    func level(for e: EKEvent) -> EventLevel {
        guard let raw = eventLevels[Self.fingerprint(e)],
              let l = EventLevel(rawValue: raw) else { return .normal }
        return l
    }

    func setLevel(_ l: EventLevel, for e: EKEvent) {
        var v = eventLevels
        let key = Self.fingerprint(e)
        if l == .normal { v.removeValue(forKey: key) } else { v[key] = l.rawValue }
        eventLevels = v
    }

    // BUILD 132 — PER-EVENT WARN TIME.
    //
    // The per-calendar lead was the right default and the wrong ceiling: a
    // 3pm job you need an hour's drive for and a 3pm haircut round the corner
    // could share a calendar. Any single event can now carry its own lead,
    // set by tapping it in Reminders. Same fingerprint trick as levels, same
    // rule: nothing is written back to EventKit.
    private var eventLeads: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: "chappy_event_leads") as? [String: Int]) ?? [:] }
        set {
            var v = newValue
            if v.count > 400 { v = Dictionary(uniqueKeysWithValues: Array(v).suffix(400)) }
            UserDefaults.standard.set(v, forKey: "chappy_event_leads")
        }
    }

    /// The lead for THIS event: its own override first, its calendar second.
    func leadMinutes(for e: EKEvent) -> Int {
        if let m = eventLeads[Self.fingerprint(e)], m > 0 { return m }
        return e.calendar.map { leadMinutes(for: $0) } ?? 30
    }

    /// nil = back to the calendar default.
    func setLead(_ m: Int?, for e: EKEvent) {
        var v = eventLeads
        let key = Self.fingerprint(e)
        if let m, m > 0 { v[key] = m } else { v.removeValue(forKey: key) }
        eventLeads = v
    }

    /// THE RESOLVER. Event override first, calendar behaviour second. One
    /// function, so every path — heads-up, leave-by, both briefs — agrees.
    func effectiveBehaviour(for e: EKEvent) -> Behaviour {
        switch level(for: e) {
        case .important: return .ping
        case .muted:     return .show
        case .normal:    return e.calendar.map { behaviour(for: $0) } ?? .brief
        }
    }

    /// THE HEADS-UP. Fires once per event, N minutes before it starts, only
    /// for calendars set to Ping. Separate from leave-by: leave-by depends on
    /// a route lookup succeeding, and a warning you actually need should not
    /// depend on the network being up.
    private var headsUpDone: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "chappy_cal_headsup") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(80)), forKey: "chappy_cal_headsup") }
    }

    func checkHeadsUp() {
        guard authorised else { return }
        var done = headsUpDone
        // Three days, because a lead time can now be a day or two.
        for e in upcoming(days: 3) {
            guard let start = e.startDate, !e.isAllDay,
                  effectiveBehaviour(for: e) == .ping else { continue }
            let important = level(for: e) == .important
            let mins = start.timeIntervalSinceNow / 60
            let fp = Self.fingerprint(e)
            // BUILD 132: a per-event lead, when set, replaces the hour-before
            // slot on important events and the whole lead on normal ones.
            let custom = eventLeads[fp].map(Double.init)
            // An important event warns TWICE: the day before, so you can act,
            // and closer in, so you don't forget you acted.
            let leads: [Double] = important
                ? [1440, custom ?? 60]
                : [custom ?? Double(e.calendar.map { leadMinutes(for: $0) } ?? 30)]
            var fired = false
            for lead in leads {
                let key = "\(fp)#\(Int(lead))"
                guard !done.contains(key), mins > 0, mins <= lead else { continue }
                // Don't fire the day-before slot for something that is already
                // an hour away — you'd get both at once.
                if lead > 120, mins < 120 { done.insert(key); continue }
                done.insert(key); fired = true; break
            }
            guard fired else { continue }
            headsUpDone = done
            let df = DateFormatter(); df.dateFormat = "h:mm a"
            var spoken = "\(e.title ?? "Something") at \(df.string(from: start))"
            if let l = e.location, !l.isEmpty {
                spoken += ", \(l.split(separator: ",").first.map(String.init) ?? l)"
            }
            spoken += ". \(Self.leadLabel(Int(mins.rounded())).replacingOccurrences(of: " before", with: ""))."
            if important { ChappyHaptics.shared.reminderUrgent() }
            else { ChappyHaptics.shared.reminderDue() }
            ChappyNotify.announce(.nav, spoken: spoken,
                                  title: (important ? "⚑ " : "") + (e.title ?? "Coming up"),
                                  body: Self.leadLabel(Int(mins.rounded())).replacingOccurrences(of: " before", with: "")
                                      + ((e.location.map { " · " + $0 }) ?? ""),
                                  critical: important)
        }
    }

    private var activeCalendars: [EKCalendar]? {
        let on = allCalendars.filter { isOn($0) && behaviour(for: $0) != .ignore }
        return on.isEmpty ? nil : on
    }

    // MARK: Reading

    func events(from: Date, to: Date) -> [EKEvent] {
        guard authorised else { return [] }
        let p = store.predicateForEvents(withStart: from, end: to, calendars: activeCalendars)
        let raw = store.events(matching: p)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        // SAME EVENT, TWO CALENDARS. Subscribing to a feed that is ALSO shared
        // through Exchange is a completely normal thing to end up with, and it
        // should not double every job in the diary or warn you twice.
        var seen = Set<String>()
        return raw.filter { e in
            let key = "\(e.title ?? "")|\(Int((e.startDate ?? .distantPast).timeIntervalSince1970))"
            return seen.insert(key).inserted
        }
    }

    func today() -> [EKEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date()
        return events(from: start, to: end)
    }

    /// BUILD 164 — any single day, for the week and month grids.
    func events(onDay d: Date) -> [EKEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: d)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? d
        return events(from: start, to: end)
    }

    func upcoming(days: Int = 7) -> [EKEvent] {
        let end = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return events(from: Date(), to: end)
    }

    /// The next thing that hasn't started yet.
    func next() -> EKEvent? {
        upcoming(days: 3).first { ($0.startDate ?? .distantPast) > Date() }
    }

    // MARK: Speaking it

    /// One line per event, short enough to be heard rather than read.
    /// Only Ping and Brief calendars are ever read aloud. "Just show it" means
    /// exactly that — visible in the diary, never spoken at you.
    // BUILD 145 — PER-EVENT "IN THE BRIEF". One job can join the morning
    // read-out without its whole calendar coming along, and vice versa.
    // Same fingerprint trick as levels and leads; nil = calendar decides.
    private var eventBriefs: [String: Bool] {
        get { (UserDefaults.standard.dictionary(forKey: "chappy_event_briefs") as? [String: Bool]) ?? [:] }
        set {
            var v = newValue
            if v.count > 400 { v = Dictionary(uniqueKeysWithValues: Array(v).suffix(400)) }
            UserDefaults.standard.set(v, forKey: "chappy_event_briefs")
        }
    }

    func briefOverride(for e: EKEvent) -> Bool? { eventBriefs[Self.fingerprint(e)] }

    // =================================================================
    // MARK: - BUILD 164: writing to the calendar, honestly
    // =================================================================
    //
    //   The Geeks2U feed is a SUBSCRIBED calendar, and iOS makes those
    //   strictly read-only — not a Chappy limitation, an EventKit one.
    //   Apple's own Calendar app can't edit them either. So:
    //
    //     * Chappy's own overlay (star, warn time, brief) works on
    //       EVERY event including subscribed ones, because it's stored
    //       against a fingerprint on this phone.
    //     * Real edits — title, time, place, notes — work on writable
    //       calendars (iCloud, On My iPhone).
    //     * New events go to your default calendar.
    //
    //   canEdit() is what the UI asks before offering the fields, so
    //   nothing ever presents an edit that will silently fail.

    func canEdit(_ e: EKEvent) -> Bool {
        e.calendar?.allowsContentModifications ?? false
    }

    var canCreate: Bool {
        authorised && store.defaultCalendarForNewEvents != nil
    }

    /// Create an event. Returns nil on success, or a reason it failed.
    @discardableResult
    func createEvent(title: String, start: Date, minutes: Int = 60,
                     location: String? = nil, notes: String? = nil,
                     allDay: Bool = false) -> String? {
        guard authorised else { return "Chappy doesn't have calendar access yet." }
        guard let cal = store.defaultCalendarForNewEvents else {
            return "No writable calendar — add an iCloud calendar in iOS Settings."
        }
        let e = EKEvent(eventStore: store)
        e.calendar = cal
        e.title = title
        e.startDate = start
        e.isAllDay = allDay
        e.endDate = allDay ? start : start.addingTimeInterval(Double(minutes) * 60)
        if let l = location, !l.isEmpty { e.location = l }
        if let nts = notes, !nts.isEmpty { e.notes = nts }
        do { try store.save(e, span: .thisEvent, commit: true); return nil }
        catch { return error.localizedDescription }
    }

    /// Edit a writable event in place. Returns nil on success.
    @discardableResult
    func updateEvent(_ e: EKEvent, title: String? = nil, start: Date? = nil,
                     minutes: Int? = nil, location: String? = nil,
                     notes: String? = nil) -> String? {
        guard canEdit(e) else {
            return "That one lives on a subscribed calendar, so nobody can edit it — not even Apple's Calendar. You can still star it and set a warn time."
        }
        if let t = title, !t.isEmpty { e.title = t }
        if let s = start {
            let length = e.endDate?.timeIntervalSince(e.startDate ?? s) ?? 3600
            e.startDate = s
            e.endDate = s.addingTimeInterval(minutes.map { Double($0) * 60 } ?? length)
        } else if let m = minutes, let s = e.startDate {
            e.endDate = s.addingTimeInterval(Double(m) * 60)
        }
        if let l = location { e.location = l }
        if let nts = notes { e.notes = nts }
        do { try store.save(e, span: .thisEvent, commit: true); return nil }
        catch { return error.localizedDescription }
    }

    @discardableResult
    func deleteEvent(_ e: EKEvent) -> String? {
        guard canEdit(e) else { return "Subscribed calendars can't be edited from any app." }
        do { try store.remove(e, span: .thisEvent, commit: true); return nil }
        catch { return error.localizedDescription }
    }

    /// BUILD 164 — the star, as its own idea. `level` already had
    /// .important, but nothing surfaced it and nothing could set it by
    /// voice. This is the same storage with a name a person would use.
    func isStarred(_ e: EKEvent) -> Bool { level(for: e) == .important }

    func setStarred(_ on: Bool, for e: EKEvent) {
        setLevel(on ? .important : .normal, for: e)
    }

    /// The event a "star that" / "make that important" should act on:
    /// whatever is happening now, or the next thing today.
    func focusEvent() -> EKEvent? {
        let now = Date()
        let live = today().first { e in
            guard let s = e.startDate else { return false }
            return s <= now && (e.endDate ?? s) >= now
        }
        return live ?? upcoming(days: 2).first { ($0.startDate ?? .distantPast) > now }
    }

    func setBriefOverride(_ on: Bool?, for e: EKEvent) {
        var v = eventBriefs
        let key = Self.fingerprint(e)
        if let on { v[key] = on } else { v.removeValue(forKey: key) }
        eventBriefs = v
    }

    private func spokenWorthy(_ e: EKEvent) -> Bool {
        // BUILD 145: the per-event switch outranks everything below it.
        if let override = briefOverride(for: e) { return override }
        if level(for: e) == .important { return true }   // always, whatever the calendar says
        if level(for: e) == .muted { return false }
        let b = effectiveBehaviour(for: e)
        return b == .ping || b == .brief
    }

    func agendaLine(limit: Int = 4) -> String? {
        let t = today().filter { !($0.isAllDay) && ($0.endDate ?? Date()) > Date() && spokenWorthy($0) }
        let allDay = today().filter { $0.isAllDay && spokenWorthy($0) }
        guard !t.isEmpty || !allDay.isEmpty else { return nil }
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        var parts: [String] = []
        if !allDay.isEmpty { parts.append(allDay.prefix(2).map { $0.title ?? "" }.joined(separator: ", ")) }
        for e in t.prefix(limit) {
            var s = "\(e.title ?? "Something") at \(df.string(from: e.startDate ?? Date()))"
            if let loc = e.location, !loc.isEmpty { s += " at \(loc.split(separator: ",").first.map(String.init) ?? loc)" }
            parts.append(s)
        }
        if t.count > limit { parts.append("and \(t.count - limit) more") }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: Leave-by, for anything with a place on it
    //
    // The single most useful thing a calendar can do that a calendar app does
    // not: warn you relative to REAL travel time rather than clock time.
    // Chappy already computes routes, so "leave in fifteen, it's a
    // twenty-five minute ride" is a sentence it can honestly say.

    private var warnedEventIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "chappy_cal_warned") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(60)), forKey: "chappy_cal_warned") }
    }

    func checkLeaveBy() async {
        guard authorised else { return }
        guard UserDefaults.standard.object(forKey: "chappy_cal_leaveby") == nil
                || UserDefaults.standard.bool(forKey: "chappy_cal_leaveby") else { return }
        var warned = warnedEventIDs
        for e in upcoming(days: 1) {
            guard let start = e.startDate, !e.isAllDay,
                  let where_ = e.location, !where_.isEmpty,
                  effectiveBehaviour(for: e) == .ping,
                  let id = e.eventIdentifier, !warned.contains(id) else { continue }
            let minsAway = start.timeIntervalSinceNow / 60
            // Only worth a route lookup inside a sensible window.
            guard minsAway > 0, minsAway < 120 else { continue }
            guard let travel = await NavEngine.shared.travelMinutes(to: where_) else { continue }
            // Five minutes of slack, because nobody leaves the instant they're told.
            guard minsAway <= Double(travel + 5) else { continue }
            warned.insert(id)
            warnedEventIDs = warned
            ChappyHaptics.shared.reminderUrgent()
            ChappyNotify.announce(.nav,
                spoken: "Time to leave for \(e.title ?? "your appointment"). It's about \(travel) minutes to \(where_).",
                title: "Leave now — \(e.title ?? "appointment")",
                body: "About \(travel) minutes to \(where_).",
                critical: true)
        }
    }

    // MARK: What happened, for memory
    //
    // Appointments become memories only once they are in the PAST. A future
    // event lives in the calendar where it can be moved; a past one is a fact
    // about your day and belongs in the record with everything else.

    func fileFinishedEvents() {
        guard authorised else { return }
        var filed = Set(UserDefaults.standard.stringArray(forKey: "chappy_cal_filed") ?? [])
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -2, to: Date()) ?? Date()
        for e in events(from: start, to: Date()) {
            guard let ended = e.endDate, ended < Date(), !e.isAllDay else { continue }
            // DEDUPE BY WHAT IT IS, NOT BY ITS ID.
            // The same Geeks2U job arrives on two calendars — the Exchange one
            // and the subscribed ICS feed — with a DIFFERENT eventIdentifier in
            // each. Keying on the id filed every job twice, which is exactly
            // what showed up in the memory list. Title plus start time is the
            // thing that is actually unique.
            let key = "\(e.title ?? "")|\(Int((e.startDate ?? ended).timeIntervalSince1970))"
            guard !filed.contains(key) else { continue }
            filed.insert(key)
            var body = ""
            if let n = e.notes, !n.isEmpty { body = n }
            ChappyMemory.shared.rememberAt(.appointment,
                title: e.title ?? "Appointment",
                body: body,
                lat: nil, lon: nil,
                city: e.location,
                tags: ["appointment", "calendar"],
                source: "calendar",
                at: e.startDate ?? ended)
        }
        UserDefaults.standard.set(Array(filed.suffix(400)), forKey: "chappy_cal_filed")
    }
}

extension Notification.Name {
    /// BUILD 121: resume a paused Live Translate session by voice. Declared
    /// here rather than beside the others so this build touches one fewer file.
    static let chappyResumeTranslate = Notification.Name("chappyResumeTranslate")
}


// =====================================================================
// MARK: - CHAPPY POCKET (Build 133 — the free answers)
// =====================================================================
//
// THE RULE: if a question can be answered from the phone itself — the clock,
// the calendar, arithmetic, a unit table, the weather snapshot Chappy already
// holds — it must never cost a network call or a cent. These are also the
// questions where SPEED is the feature: a companion that takes three seconds
// to tell you the time doesn't feel like a companion.
//
// Pocket sits at Tier 2.75: after every real command has had its chance, just
// before the paid brain. It answers or it stays silent — it never guesses,
// because a wrong free answer is worse than a slow paid one.
enum ChappyPocket {

    static func answer(_ raw: String) -> String? {
        let t = raw.lowercased()
            .replacingOccurrences(of: "please", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))

        if let s = timeOrDate(t) { return s }
        if let s = smallTalk(t) { return s }
        if let s = weather(t) { return s }
        if let s = conversion(t) { return s }
        if let s = percentage(t) { return s }
        if let s = arithmetic(t) { return s }
        return nil
    }

    // MARK: time & date

    // BUILD 166 — "WHAT TIME IS THE BRONCOS GAME" GOT THE CLOCK.
    //
    // This matched contains("what time"), so ANY question with those two
    // words in it was answered with the current time. "What time is the
    // Broncos game", "what time does Coles shut", "what time did I get
    // home" — all of them got "it's twenty past four in the afternoon",
    // which is both wrong and maddening, because it sounds like Chappy
    // heard you fine and simply doesn't care.
    //
    // The clock only ever answers a question ABOUT THE CLOCK. The moment
    // there is a subject after "what time is", the question is about an
    // EVENT and belongs to something that can actually look it up.
    // Whitelisted phrasings only — no contains().
    private static let clockAsks: Set<String> = [
        "what time is it", "what time is it now", "whats the time", "what's the time",
        "what is the time", "the time", "time", "time please", "tell me the time",
        "got the time", "have you got the time", "what time do you have",
        "what's the time now", "whats the time now", "current time", "time now",
    ]

    private static let dateAsks: Set<String> = [
        "what's the date", "whats the date", "what is the date", "what date is it",
        "what's today's date", "whats todays date", "todays date", "today's date",
        "what day is it", "what day is it today", "what's today", "whats today",
        "what day", "the date",
    ]

    private static func timeOrDate(_ t: String) -> String? {
        let bare = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
        if clockAsks.contains(bare) {
            let df = DateFormatter(); df.dateFormat = "h:mm"
            let h = Calendar.current.component(.hour, from: Date())
            let part = h < 12 ? "in the morning" : (h < 18 ? "in the afternoon" : "at night")
            return "It's \(df.string(from: Date())) \(part)."
        }
        if dateAsks.contains(bare) {
            let df = DateFormatter(); df.dateFormat = "EEEE, d MMMM"
            return "It's \(df.string(from: Date()))."
        }
        return nil
    }

    // MARK: small talk — a companion answers like one, for free

    private static func smallTalk(_ t: String) -> String? {
        if t.contains("how are you") || t.contains("how's it going")
            || t.contains("how are things") || t.contains("how you doing") {
            return ChappyVoice.line("pocket_howru", [
                "Good. Eyes open, ears on. You?",
                "All running. What are we up to?",
                "Can't complain — nobody listens to an app anyway. What's next?",
            ])
        }
        if t.contains("who are you") || t.contains("what's your name") || t.contains("what are you") {
            return "Chappy. I live in your glasses — navigation, memory, reminders, translation, and a decent set of eyes."
        }
        if t.contains("thank you") || t == "thanks" || t.hasSuffix(" thanks") {
            return ChappyVoice.line("pocket_thanks", ["No worries.", "Anytime.", "That's the job."])
        }
        return nil
    }

    // MARK: weather — only from the snapshot already on the phone

    private static func weather(_ t: String) -> String? {
        guard t.contains("weather") || t.contains("how hot") || t.contains("how cold")
            || t.contains("temperature") else { return nil }
        let s = ContextEngine.shared.snapshot
        guard let w = s.weather, let temp = s.temperatureC else { return nil } // no data → paid brain may know
        return "\(Int(temp.rounded())) degrees and \(w)."
    }

    // MARK: conversions

    /// metres-per-unit (or the special temperature pair) for everything the
    /// wearer has ever plausibly asked on the road.
    private struct Unit {
        let names: [String]; let toBase: Double; let spoken: String
        let kind: String   // length, mass, volume, temp
    }
    private static let units: [Unit] = [
        Unit(names: ["centimeters", "centimetres", "centimeter", "centimetre", "cm"], toBase: 0.01, spoken: "centimeters", kind: "length"),
        Unit(names: ["millimeters", "millimetres", "mm"], toBase: 0.001, spoken: "millimeters", kind: "length"),
        Unit(names: ["meters", "metres", "meter", "metre"], toBase: 1, spoken: "meters", kind: "length"),
        Unit(names: ["kilometers", "kilometres", "kilometer", "kilometre", "km", "kays", "clicks"], toBase: 1000, spoken: "kilometers", kind: "length"),
        Unit(names: ["inches", "inch"], toBase: 0.0254, spoken: "inches", kind: "length"),
        Unit(names: ["feet", "foot"], toBase: 0.3048, spoken: "feet", kind: "length"),
        Unit(names: ["yards", "yard"], toBase: 0.9144, spoken: "yards", kind: "length"),
        Unit(names: ["miles", "mile"], toBase: 1609.344, spoken: "miles", kind: "length"),
        Unit(names: ["kilograms", "kilogram", "kilos", "kilo", "kg"], toBase: 1, spoken: "kilos", kind: "mass"),
        Unit(names: ["grams", "gram"], toBase: 0.001, spoken: "grams", kind: "mass"),
        Unit(names: ["pounds", "pound", "lbs"], toBase: 0.453592, spoken: "pounds", kind: "mass"),
        Unit(names: ["ounces", "ounce"], toBase: 0.0283495, spoken: "ounces", kind: "mass"),
        Unit(names: ["stone"], toBase: 6.35029, spoken: "stone", kind: "mass"),
        Unit(names: ["liters", "litres", "liter", "litre"], toBase: 1, spoken: "liters", kind: "volume"),
        Unit(names: ["milliliters", "millilitres", "ml", "mils"], toBase: 0.001, spoken: "milliliters", kind: "volume"),
        Unit(names: ["gallons", "gallon"], toBase: 3.78541, spoken: "gallons", kind: "volume"),
        Unit(names: ["cups", "cup"], toBase: 0.25, spoken: "cups", kind: "volume"),
    ]

    private static func findUnit(_ s: String) -> Unit? {
        // Longest names first, so "kilometers" never half-matches "meters".
        let all = units.flatMap { u in u.names.map { (name: $0, unit: u) } }
            .sorted { $0.name.count > $1.name.count }
        return all.first { s == $0.name }?.unit
    }

    private static func conversion(_ t: String) -> String? {
        // Temperature is its own arithmetic.
        if let m = t.firstMatch(of: #/(-?\d+(?:\.\d+)?)\s*(?:degrees\s*)?(celsius|fahrenheit|c|f)\b.*?(?:to|in|into)\s*(?:degrees\s*)?(celsius|fahrenheit|c|f)\b/#) {
            guard let v = Double(m.1) else { return nil }
            let from = String(m.2).hasPrefix("f") ? "f" : "c"
            let to = String(m.3).hasPrefix("f") ? "f" : "c"
            guard from != to else { return nil }
            let out = from == "c" ? v * 9 / 5 + 32 : (v - 32) * 5 / 9
            return "\(clean(v)) \(from == "c" ? "Celsius" : "Fahrenheit") is \(clean(out)) \(to == "c" ? "Celsius" : "Fahrenheit")."
        }
        // "180 centimeters to inches" / "convert 5 miles into km" /
        // "how many inches in 180 centimeters"
        var value: Double?; var fromRaw = ""; var toRaw = ""
        if let m = t.firstMatch(of: #/(-?\d+(?:\.\d+)?)\s*([a-z]+)\s+(?:to|in|into)\s+([a-z]+)/#) {
            value = Double(m.1); fromRaw = String(m.2); toRaw = String(m.3)
        } else if let m = t.firstMatch(of: #/how many\s+([a-z]+)\s+(?:in|is)\s+(-?\d+(?:\.\d+)?)\s*([a-z]+)/#) {
            value = Double(m.2); fromRaw = String(m.3); toRaw = String(m.1)
        }
        guard let v = value,
              let from = findUnit(fromRaw), let to = findUnit(toRaw),
              from.kind == to.kind, from.spoken != to.spoken else { return nil }
        let out = v * from.toBase / to.toBase
        return "\(clean(v)) \(from.spoken) is \(clean(out)) \(to.spoken)."
    }

    // MARK: percentages & arithmetic

    private static func percentage(_ t: String) -> String? {
        guard let m = t.firstMatch(of: #/(\d+(?:\.\d+)?)\s*(?:%|percent|per cent)\s*(?:of)\s*(-?\d+(?:\.\d+)?)/#) else { return nil }
        guard let p = Double(m.1), let n = Double(m.2) else { return nil }
        return "\(clean(p)) percent of \(clean(n)) is \(clean(n * p / 100))."
    }

    private static func arithmetic(_ t: String) -> String? {
        // Spoken operators first, so "12 times 8" parses like "12 * 8".
        var s = t
        for (word, op) in [("multiplied by", "*"), ("divided by", "/"), ("times", "*"),
                           ("plus", "+"), ("minus", "-"), (" x ", " * ")] {
            s = s.replacingOccurrences(of: word, with: op)
        }
        guard let m = s.firstMatch(of: #/(-?\d+(?:\.\d+)?)\s*([+\-*\/])\s*(-?\d+(?:\.\d+)?)/#) else { return nil }
        // Only answer when the sentence is question-shaped maths, not any
        // sentence with two numbers in it.
        guard t.contains("what") || t.contains("how much") || t.contains("calculate")
            || t.contains("times") || t.contains("plus") || t.contains("minus")
            || t.contains("divided") || t.contains("multiplied") else { return nil }
        guard let a = Double(m.1), let b = Double(m.3) else { return nil }
        let out: Double
        switch m.2 {
        case "+": out = a + b
        case "-": out = a - b
        case "*": out = a * b
        default:
            guard b != 0 else { return "Can't divide by zero — nobody can." }
            out = a / b
        }
        return "\(clean(out))."
    }

    /// "70.86614" → "70.9", "12.0" → "12" — numbers as a person says them.
    private static func clean(_ v: Double) -> String {
        let rounded = (v * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }
}


// =====================================================================
// MARK: - CHAPPY READER (Build 134 — read, translate, scan)
// =====================================================================
//
// THE INSIGHT THIS IS BUILT ON: reading text is FREE now. Apple's Vision
// framework does document-grade OCR on-device — menus, labels, signs,
// contracts — with no network and no API bill. The old path sent a photo to
// a paid model to do what the phone could do for nothing.
//
// So the Reader is a ladder of its own:
//   1. Grab ONE frame from the glasses (same wake-grab-sleep dance as Pulse).
//   2. OCR on-device. Free, instant, works with no signal.
//   3a. READ       → speak it, chunked, "keep reading" for the rest.
//   3b. TRANSLATE  → one tiny TEXT-ONLY call (the image never leaves the
//                    phone), then speak the English.
//   3c. SCAN       → file text + photo into memory as a .scan, then read it.
//                    "Read my last scan" brings it back any time.
//   4. Only if OCR finds nothing legible (handwriting, terrible light) does
//      it fall back to the paid eyes — QuickVision — exactly as before.
@MainActor
final class ChappyReader {

    static let shared = ChappyReader()
    private init() {}

    enum Mode { case read, translate, scan }

    /// What "keep reading" continues from.
    private var remainder = ""
    private var lastMode: Mode = .read

    // MARK: - Entry points

    /// BUILD 159 — which eye answered last: the full-res glasses photo or
    /// the live view. Surfaced so a poor reading tells you which to fix.
    nonisolated(unsafe) static var lastSourceWasSharp = false

    func begin(_ mode: Mode) {
        lastMode = mode
        Task { await run(mode) }
    }

    /// BUILD 168 — READ IT, THEN REWRITE IT.
    ///
    /// Look at a page (or press the glasses button first, and Sharp Eye
    /// uses the full-resolution photo), OCR it on-device, and hand the
    /// text straight to the rewriter — where Reword, Plain English,
    /// Formal letter and Summary are one tap apart, and Email is one tap
    /// after that. No retyping, and the original text stays visible
    /// underneath so nothing is lost behind the rewrite.
    func rewriteWhatYouSee(tone: ChappyDictate.Tone = .reword) {
        Task {
            TTSService.shared.speak("Reading it.")
            ChappyEarcon.shared.startThinking()
            let frame = await grabFrame()
            ChappyEarcon.shared.stopThinking()
            guard let f = frame else {
                TTSService.shared.speak("The camera didn't come up. Try that again.")
                return
            }
            let text = await ocr(f)
            guard text.count >= 20 else {
                TTSService.shared.speak("I couldn't get enough text off that. Try the phone scanner - it flattens the page properly.")
                NotificationCenter.default.post(name: .chappyOpenDictate, object: nil)
                return
            }
            ChappyDictate.shared.load(text: text, tone: tone)
            NotificationCenter.default.post(name: .chappyOpenDictateQuiet, object: nil)
            TTSService.shared.speak("Got it. Rewriting now - pick a style when it lands.")
        }
    }

    /// BUILD 159 — "read this properly": press the glasses button, then
    /// say it. Chappy waits a few seconds for the photo to sync across
    /// and reads THAT at full resolution.
    func beginSharp(_ mode: Mode) {
        lastMode = mode
        Task {
            TTSService.shared.speak("Looking at your photo.")
            ChappyEarcon.shared.startThinking()
            let shot = await ChappyPhotoIngest.shared.waitForFreshPhoto(seconds: 6)
            ChappyEarcon.shared.stopThinking()
            if shot != nil {
                Self.lastSourceWasSharp = true
            } else {
                TTSService.shared.speak("No new photo - using the live view.")
            }
            await self.run(mode, override: shot)
        }
    }

    func continueReading() {
        guard !remainder.isEmpty else {
            TTSService.shared.speak("That was the lot.")
            return
        }
        speakChunked(remainder)
    }

    /// "Read my last scan."
    func readLastScan() {
        let scans = ChappyMemory.shared.recent
            .filter { $0.kind == .scan && !$0.body.isEmpty }
            .sorted { $0.at > $1.at }
        guard let last = scans.first else {
            TTSService.shared.speak("No scans saved yet. Say 'scan this' while looking at a page.")
            return
        }
        speakChunked(last.body)
    }

    // MARK: - The run

    private func run(_ mode: Mode, override: UIImage? = nil) async {
        // BUILD 161: `override ?? (await grabFrame())` doesn't compile — the
        // right-hand side of ?? is an autoclosure and autoclosures can't be
        // async. Spelled out, which is clearer anyway.
        var picked = override
        if picked == nil { picked = await grabFrame() }
        guard let frame = picked else {
            TTSService.shared.speak("The camera didn't come up. Try that again.")
            return
        }
        let text = await ocr(frame)

        // Nothing legible → the paid eyes, which also handle handwriting.
        guard text.count >= 12 else {
            QuickVisionManager.shared.triggerQuickVision(customPrompt:
                "Read ALL visible text in this image aloud, verbatim and in order. If it is in another language, read it then translate it. No commentary.")
            return
        }

        // BUILD 146 — THE EYES FEED THE GUARD. Everything read or scanned is
        // swept for scam red flags, free. A dodgy invoice announces itself.
        let flags = ChappyScamGuard.redFlags(in: text)
        if let first = flags.first {
            TTSService.shared.speak("Before I read it - heads up: \(first.warning)")
            try? await Task.sleep(nanoseconds: 6_000_000_000)
        }

        switch mode {
        case .read:
            speakChunked(text)

        case .scan:
            let title = String(text.split(separator: "\n").first ?? "Scanned document").prefix(60)
            _ = ChappyMemory.shared.remember(
                .scan,
                title: String(title),
                body: text,
                tags: ["scan"],
                thumbnail: frame.jpegData(compressionQuality: 0.5),
                source: "reader")
            TTSService.shared.speak("Saved. \(spokenLength(of: text))")
            remainder = text

        case .translate:
            TTSService.shared.speak("One moment.")
            if let english = await translate(text) {
                speakChunked(english)
            } else {
                // No signal or no key — read it as-is rather than doing nothing.
                TTSService.shared.speak("Couldn't reach the translator. Reading it as it is.")
                speakChunked(text)
            }
        }
    }

    // MARK: - Camera (Pulse's wake-grab-sleep dance, one frame)

    private func grabFrame() async -> UIImage? {
        // BUILD 159 — SHARP EYE. If you pressed the capture button on the
        // glasses in the last two minutes, Meta has already written the
        // FULL-RESOLUTION still into the photo library — the same pixels
        // Meta AI reads. That beats a video-stream frame for fine print by
        // a mile, and it is free. Falls straight through to the live frame
        // when there isn't one, so this can only ever improve the picture.
        if let hit = await ChappyPhotoIngest.shared.freshFullResPhoto(within: 120) {
            print("👁️ [Reader] Sharp Eye: full-res photo from \(Int(hit.age))s ago")
            ChappyReader.lastSourceWasSharp = true
            return hit.image
        }
        ChappyReader.lastSourceWasSharp = false
        let wasStreaming = LiveAIManager.shared.streamViewModel?.streamingStatus == .streaming
        if !wasStreaming {
            NotificationCenter.default.post(name: .chappyWakeCameraForSnap, object: nil)
            for _ in 0..<20 {                                    // up to ~5s
                try? await Task.sleep(nanoseconds: 250_000_000)
                if LiveAIManager.shared.streamViewModel?.streamingStatus == .streaming { break }
            }
            // Let exposure settle — the first frames off a cold camera are
            // dark, and dark frames read as "no text".
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        let frame = LiveAIManager.shared.streamViewModel?.currentVideoFrame
        if !wasStreaming {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !ContinuousVisionManager.shared.isRunning, GeminiLiveService.activeInstance == nil {
                await LiveAIManager.shared.streamViewModel?.stopSession()
            }
        }
        return frame
    }

    // MARK: - OCR (free, on-device)

    private func ocr(_ image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        return await withCheckedContinuation { cont in
            let request = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cg,
                                                    orientation: .up, options: [:])
                do { try handler.perform([request]) }
                catch { cont.resume(returning: "") }
            }
        }
    }

    // MARK: - Translation (text-only — the photo never leaves the phone)

    private func translate(_ text: String) async -> String? {
        guard let key = APIKeyManager.shared.getGoogleAPIKey(), !key.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent?key=\(key)")
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [[
                "text": "Translate this into natural English. Reply with ONLY the translation, nothing else. If it is already English, reply with the text unchanged.\n\n\(String(text.prefix(4000)))"
            ]]]],
            "generationConfig": ["temperature": 0.1, "maxOutputTokens": 1200]
        ] as [String: Any])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = json["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let t = parts.first?["text"] as? String
        else { return nil }
        let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    // MARK: - Speaking, chunked

    /// A page at a time. Long documents are split at sentence boundaries so
    /// each chunk sounds finished; "keep reading" continues where it stopped.
    private func speakChunked(_ text: String) {
        let limit = 1100
        let flat = text.replacingOccurrences(of: "\n", with: ". ")
            .replacingOccurrences(of: "..", with: ".")
        guard flat.count > limit else {
            remainder = ""
            TTSService.shared.speak(flat)
            return
        }
        // Cut at the last sentence end before the limit.
        var cut = flat.index(flat.startIndex, offsetBy: limit)
        if let dot = flat[..<cut].lastIndex(of: ".") { cut = flat.index(after: dot) }
        remainder = String(flat[cut...]).trimmingCharacters(in: .whitespaces)
        TTSService.shared.speak(String(flat[..<cut]) + " Say 'keep reading' for the rest.")
    }

    private func spokenLength(of text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).count
        if words < 40 { return "It's short — want me to read it now? Say 'keep reading'." }
        return "About \(words) words. Say 'keep reading' to hear it, or ask for it later with 'read my last scan'."
    }
}


// =====================================================================
// MARK: - CHAPPY TRAIL (Build 138 — the day, drawn)
// =====================================================================
//
// Google's Timeline works because it never stops watching. iOS won't let a
// third-party app run raw GPS all day — and the wearer's battery wouldn't
// survive it — but Apple provides two low-power instruments built for
// exactly this job:
//
//   VISITS   — iOS itself detects "arrived somewhere, left somewhere" and
//              delivers it even in the background, near-free on battery.
//              This is the skeleton of a day: home till 2:10, the shop for
//              twenty minutes, home again.
//   SIGNIFICANT CHANGES — a breadcrumb roughly every 500m while moving.
//              Enough to draw the day's path as a line on a map.
//
// Everything is stored ON THIS PHONE as one small JSON file per day.
// Nothing leaves the device; reverse-geocoding a visit's name uses Apple's
// geocoder, the same one the Maps app uses. Days expire after 90 unless
// the wearer changes the setting. One switch kills the whole thing.
@MainActor
final class ChappyTrail: NSObject, ObservableObject {

    static let shared = ChappyTrail()

    struct Point: Codable {
        var at: Date
        var lat: Double
        var lon: Double
    }

    struct Visit: Codable, Identifiable {
        var id: UUID = UUID()
        var arrive: Date
        var depart: Date?          // nil = still there
        var lat: Double
        var lon: Double
        var name: String?          // reverse-geocoded, lazily

        var spokenWindow: String {
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            if let d = depart {
                let mins = max(1, Int(d.timeIntervalSince(arrive) / 60))
                return "\(f.string(from: arrive)) to \(f.string(from: d)), about \(mins) minutes"
            }
            return "since \(f.string(from: arrive))"
        }
    }

    private struct Day: Codable {
        var points: [Point] = []
        var visits: [Visit] = []
    }

    @Published private(set) var todayPoints: [Point] = []
    @Published private(set) var todayVisits: [Visit] = []

    private let mgr = CLLocationManager()
    private var delegateSet = false
    private let d = UserDefaults.standard

    var isEnabled: Bool {
        get { d.object(forKey: "chappy_trail_enabled") as? Bool ?? true }
        set {
            d.set(newValue, forKey: "chappy_trail_enabled")
            newValue ? start() : stopMonitoring()
        }
    }

    // MARK: lifecycle

    func start() {
        guard isEnabled else { return }
        if !delegateSet { mgr.delegate = self; delegateSet = true }
        // The one thing the wearer has to grant: Always. When-in-use can't
        // hear visits with the phone in a pocket, which is the entire point.
        switch mgr.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            mgr.requestAlwaysAuthorization()
        default: break
        }
        mgr.startMonitoringVisits()
        mgr.startMonitoringSignificantLocationChanges()
        loadToday()
        if let l = mgr.location { add(point: l) }   // never an empty map
        pruneOldDays()
        print("👣 [Trail] monitoring — \(todayPoints.count) points, \(todayVisits.count) visits today")
    }

    private func stopMonitoring() {
        mgr.stopMonitoringVisits()
        mgr.stopMonitoringSignificantLocationChanges()
        print("👣 [Trail] off")
    }

    // MARK: recording

    fileprivate func add(point loc: CLLocation) {
        rollIfNeeded()
        // Dedup: a new crumb has to be genuinely elsewhere or meaningfully later.
        if let last = todayPoints.last {
            let d = CLLocation(latitude: last.lat, longitude: last.lon).distance(from: loc)
            if d < 40, Date().timeIntervalSince(last.at) < 300 { return }
        }
        todayPoints.append(Point(at: Date(), lat: loc.coordinate.latitude, lon: loc.coordinate.longitude))
        saveToday()
    }

    fileprivate func handle(visit: CLVisit) {
        rollIfNeeded()
        let arrive = visit.arrivalDate == .distantPast ? Date() : visit.arrivalDate
        let coord = visit.coordinate
        if visit.departureDate == .distantFuture {
            // Arrival. Skip if an open visit already covers this spot.
            if todayVisits.contains(where: { $0.depart == nil && close($0, to: coord) }) { return }
            var v = Visit(arrive: arrive, depart: nil,
                          lat: coord.latitude, lon: coord.longitude, name: nil)
            todayVisits.append(v)
            saveToday()
            geocode(&v)
        } else {
            // Departure. Close the matching open visit, or file the whole stay.
            if let i = todayVisits.firstIndex(where: { $0.depart == nil && close($0, to: coord) }) {
                todayVisits[i].depart = visit.departureDate
            } else {
                var v = Visit(arrive: arrive, depart: visit.departureDate,
                              lat: coord.latitude, lon: coord.longitude, name: nil)
                todayVisits.append(v)
                geocode(&v)
            }
            saveToday()
        }
        print("👣 [Trail] visit — now \(todayVisits.count) today")
    }

    private func close(_ v: Visit, to c: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: v.lat, longitude: v.lon)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) < 120
    }

    private func geocode(_ v: inout Visit) {
        let id = v.id
        let loc = CLLocation(latitude: v.lat, longitude: v.lon)
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            let name = marks?.first.flatMap { $0.name ?? $0.thoroughfare ?? $0.locality }
            Task { @MainActor in
                guard let self, let name else { return }
                if let i = self.todayVisits.firstIndex(where: { $0.id == id }) {
                    self.todayVisits[i].name = name
                    self.saveToday()
                }
            }
        }
    }

    // MARK: storage — one JSON per day

    private var dirURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChappyTrail", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func key(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    private func url(_ date: Date) -> URL {
        dirURL.appendingPathComponent(Self.key(date) + ".json")
    }

    private var loadedDayKey = ""

    private func rollIfNeeded() {
        let today = Self.key(Date())
        guard loadedDayKey != today else { return }
        if !loadedDayKey.isEmpty { saveToday() }
        loadedDayKey = today
        let day = read(Date())
        todayPoints = day.points
        todayVisits = day.visits
    }

    private func loadToday() { loadedDayKey = ""; rollIfNeeded() }

    private func saveToday() {
        let day = Day(points: todayPoints, visits: todayVisits)
        if let data = try? JSONEncoder().encode(day) {
            try? data.write(to: url(Date()), options: .atomic)
        }
    }

    private func read(_ date: Date) -> Day {
        guard let data = try? Data(contentsOf: url(date)),
              let day = try? JSONDecoder().decode(Day.self, from: data) else { return Day() }
        return day
    }

    /// Points for any day — today comes from memory, the past from disk.
    func points(for date: Date) -> [Point] {
        Calendar.current.isDateInToday(date) ? todayPoints : read(date).points
    }

    func visits(for date: Date) -> [Visit] {
        Calendar.current.isDateInToday(date) ? todayVisits : read(date).visits
    }

    private func pruneOldDays() {
        // BUILD 156 — LIFETIME BY DEFAULT. The Atlas is only worth having if
        // the history actually accumulates: a year of visits is well under a
        // megabyte, and "where was I in April" should still answer in 2028.
        // 0 = keep forever. Anyone who set a limit by hand keeps it.
        let keepDays = d.object(forKey: "chappy_trail_keep_days") as? Int ?? 0
        guard keepDays > 0 else { return }
        let cutoff = Self.key(Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) ?? Date())
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)) ?? [] {
            if f.deletingPathExtension().lastPathComponent < cutoff { try? fm.removeItem(at: f) }
        }
    }

    // MARK: voice

    /// "Where was I on Tuesday?" — the day, spoken.
    func spokenSummary(for date: Date) -> String {
        let vs = visits(for: date)
        let dayName: String = {
            if Calendar.current.isDateInToday(date) { return "Today" }
            if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
            let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: date)
        }()
        guard !vs.isEmpty else {
            let pts = points(for: date)
            if pts.isEmpty { return "\(dayName): no trail recorded. Tracking may not have been on yet." }
            return "\(dayName): you were on the move but didn't stop anywhere long enough to count. \(pts.count) points on the trail — say 'show my trail' to see the line."
        }
        let stops = vs.prefix(5).map { v in
            "\(v.name ?? "a stop"), \(v.spokenWindow)"
        }.joined(separator: ". ")
        let more = vs.count > 5 ? " And \(vs.count - 5) more stops." : ""
        return "\(dayName): \(stops).\(more) Say 'show my trail' for the map."
    }

    /// The day a sentence refers to, if it names one.
    static func dayMentioned(in c: String) -> Date? {
        if c.contains("yesterday") {
            return Calendar.current.date(byAdding: .day, value: -1, to: Date())
        }
        if c.contains("today") { return Date() }
        let names = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
                     "thursday": 5, "friday": 6, "saturday": 7]
        for (name, wd) in names where c.contains(name) {
            // The most recent such weekday, never today.
            for back in 1...7 {
                if let d = Calendar.current.date(byAdding: .day, value: -back, to: Date()),
                   Calendar.current.component(.weekday, from: d) == wd {
                    return d
                }
            }
        }
        return nil
    }
}

extension ChappyTrail: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in ChappyTrail.shared.add(point: l) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor in ChappyTrail.shared.handle(visit: visit) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("👣 [Trail] location error: \(error.localizedDescription)")
    }
}


// =====================================================================
// MARK: - SUGGESTED REMINDERS (Build 140)
// =====================================================================
//
// Chappy reads the day and proposes the reminders you'd have set yourself:
// a get-ready nudge before each appointment, and a time for anything on the
// list that has none. Suggestions are CHEAP — pure local reads, no AI call —
// and they never self-activate: a tap or a "plan my day" is always the
// consent. Anything accepted becomes an ordinary reminder you can edit or
// kill like any other.
extension ChappyReminders {

    struct Suggestion: Identifiable {
        let id = UUID()
        let title: String
        let fire: Date
        let reason: String
    }

    func suggestions() -> [Suggestion] {
        var out: [Suggestion] = []
        let now = Date()

        // A get-ready nudge for each upcoming appointment that doesn't
        // already have a reminder shadowing it.
        for e in ChappyCalendar.shared.upcoming(days: 2) where !e.isAllDay {
            guard let s = e.startDate, let t = e.title, !t.isEmpty else { continue }
            let fire = s.addingTimeInterval(-45 * 60)
            guard fire > now.addingTimeInterval(600) else { continue }
            let stem = t.lowercased().prefix(12)
            guard !open.contains(where: { $0.title.lowercased().contains(stem) }) else { continue }
            let hasAddress = (e.location?.isEmpty == false)
            out.append(Suggestion(
                title: "Get ready for \(t)",
                fire: fire,
                reason: hasAddress
                    ? "45 min before — and the leave-by warning covers the drive"
                    : "45 min before it starts"))
            if out.count >= 3 { break }
        }

        // A time for anything that has none — an untimed reminder is a wish.
        if let six = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: now),
           six > now {
            for r in open where r.doneAt == nil && r.dueAt == nil
                && r.floatingTime == nil && r.placeTrigger == nil && r.repeatRule == nil {
                out.append(Suggestion(title: r.title, fire: six,
                                      reason: "No time on it — six tonight?"))
                if out.count >= 5 { break }
            }
        }
        return out
    }
}


// =====================================================================
// MARK: - CHAPPY SCAM GUARD (Build 146 — Phase 5 Step 5)
// =====================================================================
//
// A traveller's most expensive minutes are the ones where something feels
// slightly off and there's nobody to ask. Chappy is somebody to ask.
//
// The guard is a LADDER, cheapest first:
//   1. RULES — the twelve shapes nearly every scam wears, matched locally,
//      free, instant, offline. Gift cards. Wire-only. Fake urgency.
//      Authority threats. Too-good prices. Overpayment "refunds".
//   2. THE BRAIN — a described situation that trips no rule goes to the
//      cheap model WITH the wearer's Codex context, because "is this normal
//      here" depends on where here is.
//   3. THE EYES — everything the Reader scans is swept for red flags
//      automatically. A dodgy invoice announces itself.
//
// The guard NEVER auto-blocks anything — it says what it sees and why, and
// the human decides. An assistant that cries wolf gets switched off, so
// rule matches are specific, not vibes.
enum ChappyScamGuard {

    struct Flag { let warning: String }

    private static let rules: [(patterns: [String], warning: String)] = [
        (["gift card", "itunes card", "google play card", "steam card"],
         "Nobody legitimate takes payment in gift cards. Not the tax office, not a bank, not a supplier. That's a scam, full stop."),
        (["wire transfer only", "western union", "moneygram", "wire the money", "transfer only no"],
         "Untraceable-transfer-only is the classic scam payment. A real business takes a card."),
        (["pay outside", "off the platform", "outside the app", "avoid the fees", "deal directly"],
         "Being pulled off the platform kills your buyer protection — that's usually the whole point of asking."),
        (["arrest", "warrant", "police will", "tax office says", "deported", "suspend your account today"],
         "Authority plus urgency is the oldest con there is. Real agencies write letters; they don't threaten you into paying on the phone."),
        (["overpaid", "send back the difference", "refund the extra", "accidentally sent too much"],
         "The overpayment refund trick — their payment will bounce after you've sent real money back."),
        (["crypto", "double your", "guaranteed return", "investment opportunity", "trading platform"],
         "Guaranteed returns don't exist. Anyone promising them wants your principal, not your prosperity."),
        (["verification code", "read me the code", "code i sent you", "one time code"],
         "NEVER read anyone a verification code. That code is the key to one of your accounts — that's why they want it."),
        (["customs fee", "release the package", "small fee to deliver", "parcel is held"],
         "Held-parcel fees are a phishing staple. Check with the courier directly, never through the link or number they gave."),
        (["romance", "stuck overseas", "needs money to fly", "hospital bills abroad", "never met in person"],
         "Money to someone you've never met in person is gone the moment it's sent, whatever the story."),
        (["act now", "today only", "last chance", "right now or", "expires in minutes"],
         "Manufactured urgency exists to stop you thinking. Anything real survives a day's thought."),
        (["too cheap", "half the price of every", "way below market"],
         "A price wildly below every other seller usually isn't a bargain — it's bait."),
        (["deposit to hold", "booking fee upfront", "send deposit sight unseen"],
         "Deposits for something you haven't seen, to someone you can't verify, rarely come back."),
    ]

    /// Free, local, instant. Returns every matched warning, strongest first.
    static func redFlags(in text: String) -> [Flag] {
        let t = text.lowercased()
        return rules.compactMap { rule in
            rule.patterns.contains(where: { t.contains($0) }) ? Flag(warning: rule.warning) : nil
        }
    }

    /// The spoken verdict for a described situation.
    static func verdict(for text: String) -> String? {
        let flags = redFlags(in: text)
        guard !flags.isEmpty else { return nil }
        if flags.count == 1 { return "Red flag. \(flags[0].warning)" }
        return "Two red flags at once. \(flags[0].warning) And: \(flags[1].warning) I'd walk away."
    }
}


// =====================================================================
// MARK: - CHAPPY CLIP (Build 147 — video, summarised)
// =====================================================================
//
// Snap's bigger sibling. The glasses feed ~1 frame a second, which is
// exactly what a summariser wants: "record a clip" captures a sequence,
// sends the frames in ONE cheap call, and files a .video memory — a
// narrative of what happened, first frame as the thumbnail, pinned on the
// Journal Map. A 20-second clip costs about a tenth of a cent.
@MainActor
final class ChappyClip {

    static let shared = ChappyClip()
    private init() {}

    private(set) var isRecording = false

    func record(seconds: Int = 20) {
        guard !isRecording else {
            TTSService.shared.speak("Already rolling."); return
        }
        isRecording = true
        Task { await run(seconds: seconds) }
    }

    private func run(seconds: Int) async {
        defer { isRecording = false }

        // BUILD 172 — VIDEO "STARTED AND IMMEDIATELY TURNED OFF."
        //
        // Clip still had the five-second camera wait that Burst was cured
        // of in 162. Cold Ray-Bans take eight to ten seconds, so the wait
        // expired, the frame grab found nothing, and it gave up — which
        // from the outside looks exactly like starting and stopping.
        // Same cure: twenty seconds, the waking tone so you know it's
        // coming, the on-screen waking card, and an honest failure.
        let wasStreaming = LiveAIManager.shared.streamViewModel?.streamingStatus == .streaming
        if !wasStreaming {
            ChappyEarcon.shared.cameraWaking()
            SnapFeedback.shared.waking()
            NotificationCenter.default.post(name: .chappyWakeCameraForSnap, object: nil)
            var awake = false
            for _ in 0..<80 {                                   // up to ~20s
                try? await Task.sleep(nanoseconds: 250_000_000)
                if LiveAIManager.shared.streamViewModel?.streamingStatus == .streaming {
                    awake = true; break
                }
            }
            guard awake else {
                TTSService.shared.speak("The glasses didn't wake up in time - no clip. Give them a moment and try again.")
                ChappyStandby.shared.pokeEar(after: 1.5)
                return
            }
            try? await Task.sleep(nanoseconds: 900_000_000)     // exposure settle
            TTSService.shared.speak("Rolling now.")
        }

        var frames: [UIImage] = []
        let interval = max(1, seconds / 14)          // ≤14 frames whatever the length
        for i in 0..<(seconds / interval) {
            if i > 0 { try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000) }
            if let f = LiveAIManager.shared.streamViewModel?.currentVideoFrame {
                frames.append(f)
            }
        }

        if !wasStreaming {
            if GeminiLiveService.activeInstance == nil, !ContinuousVisionManager.shared.isRunning {
                await LiveAIManager.shared.streamViewModel?.stopSession()
            }
        }

        guard frames.count >= 3 else {
            TTSService.shared.speak("The camera never settled — no clip this time.")
            return
        }
        ChappyEarcon.shared.done()

        guard let summary = await summarise(frames) else {
            // The moment still gets kept, just untitled — never lose footage
            // to a network burp.
            _ = ChappyMemory.shared.remember(.video, title: "Clip, \(frames.count) frames",
                                             tags: ["clip"],
                                             thumbnail: frames[0].jpegData(compressionQuality: 0.5),
                                             source: "clip")
            TTSService.shared.speak("Clip saved. Couldn't reach the summariser — it's kept untitled.")
            return
        }
        let title = String(summary.split(separator: ".").first.map(String.init) ?? summary).prefix(70)
        _ = ChappyMemory.shared.remember(.video, title: String(title),
                                         body: summary,
                                         tags: ["clip"],
                                         thumbnail: frames[0].jpegData(compressionQuality: 0.5),
                                         source: "clip")
        TTSService.shared.speak(summary)
    }

    private func summarise(_ frames: [UIImage]) async -> String? {
        guard let key = APIKeyManager.shared.getGoogleAPIKey(), !key.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent?key=\(key)")
        else { return nil }
        var parts: [[String: Any]] = [[
            "text": "These are sequential frames from a short first-person video clip, in order. Narrate what happened across them as 2-3 vivid spoken sentences - what the place is, what changed, anything notable or readable. No preamble."
        ]]
        for f in frames {
            // BUILD 158: 384px could narrate a scene but never read a label
            // or a serial number. 768 is four times the pixels and still
            // cheap enough to send fourteen of them.
            let side: CGFloat = 768
            let scale = side / max(f.size.width, f.size.height)
            let sz = CGSize(width: f.size.width * scale, height: f.size.height * scale)
            let small = UIGraphicsImageRenderer(size: sz).image { _ in
                f.draw(in: CGRect(origin: .zero, size: sz))
            }
            guard let jpeg = small.jpegData(compressionQuality: 0.6) else { continue }
            parts.append(["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["temperature": 0.3, "maxOutputTokens": 160]
        ] as [String: Any])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = json["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let ps = content["parts"] as? [[String: Any]],
              let t = ps.first?["text"] as? String
        else { return nil }
        let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "*", with: "")
        return clean.isEmpty ? nil : clean
    }
}


// =====================================================================
// MARK: - CHAPPY MAIL (Build 147 — mail and messages, one manager)
// =====================================================================
//
// THE TELTEL INSIGHT: iOS will never let an app read SMS or WhatsApp — but
// the wearer's SMS arrive as EMAILS through his TelTel gateway, into an
// inbox Chappy CAN read with his blessing and an app-specific password.
// So one IMAP client is both an email manager and a text-message manager:
// a message from *@teltel.com.au IS a text, and replying to it sends a
// real SMS back out through the gateway.
//
// The client speaks just enough IMAP: LOGIN, SELECT, UID SEARCH UNSEEN,
// UID FETCH with BODY.PEEK (peek, so reading a summary never marks mail
// read behind the wearer's back). TLS from the first byte (port 993).
// Replies open the Mail composer pre-filled — one human tap to send,
// same consent pattern as WhatsApp and SOS.
@MainActor
final class ChappyMail: ObservableObject {

    static let shared = ChappyMail()
    private init() {}

    struct Message: Identifiable {
        let id: Int              // IMAP UID
        let from: String         // display or address
        let fromAddress: String
        let subject: String
        let preview: String
        var isText: Bool { fromAddress.lowercased().contains("teltel") }
    }

    @Published private(set) var unread: [Message] = []
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?

    private(set) var lastRead: Message?

    private enum Key {
        static let address = "chappy_mail_address"
        static let host = "chappy_mail_host"
    }

    var address: String { UserDefaults.standard.string(forKey: Key.address) ?? "" }
    var host: String { UserDefaults.standard.string(forKey: Key.host) ?? "imap.mail.me.com" }
    var isConfigured: Bool {
        !address.isEmpty && APIKeyManager.shared.getMailPassword() != nil
    }

    func configure(address: String, host: String, password: String) {
        UserDefaults.standard.set(address, forKey: Key.address)
        UserDefaults.standard.set(host, forKey: Key.host)
        _ = APIKeyManager.shared.saveMailPassword(password)
    }

    // MARK: the check

    /// Fetch unseen mail and return the SPOKEN summary.
    func check() async -> String {
        guard isConfigured, let pass = APIKeyManager.shared.getMailPassword() else {
            return "Mail isn't set up yet. Settings, Mail and Messages - it takes one app-specific password."
        }
        let imap = MiniIMAP()
        do {
            try await imap.connect(host: host)
            _ = try await imap.command("LOGIN \(quoted(address)) \(quoted(pass))")
            _ = try await imap.command("SELECT INBOX")
            let search = try await imap.command("UID SEARCH UNSEEN")
            let uids = Self.uids(from: search).suffix(8)
            var out: [Message] = []
            for uid in uids {
                let r = try await imap.command(
                    "UID FETCH \(uid) (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)] BODY.PEEK[TEXT]<0.400>)")
                out.append(Self.parse(uid: uid, fetch: r))
            }
            imap.close()
            unread = out.reversed()      // newest first
            lastChecked = Date()
            lastError = nil
            return spokenSummary()
        } catch {
            imap.close()
            lastError = error.localizedDescription
            return "Couldn't reach the mailbox: \(error.localizedDescription)"
        }
    }

    func spokenSummary() -> String {
        guard !unread.isEmpty else { return "Inbox is clear - nothing unread." }
        let texts = unread.filter { $0.isText }
        let mails = unread.filter { !$0.isText }
        var parts: [String] = []
        if !texts.isEmpty {
            parts.append("\(texts.count) text\(texts.count == 1 ? "" : "s") - from \(texts.prefix(2).map { Self.smsSender($0) }.joined(separator: ", "))")
        }
        if !mails.isEmpty {
            parts.append("\(mails.count) email\(mails.count == 1 ? "" : "s") - \(mails.prefix(3).map { "\($0.from): \($0.subject)" }.joined(separator: ". "))")
        }
        return parts.joined(separator: ". ") + ". Say 'read the first one' to hear it."
    }

    /// "Read the first one" / "read message two" / "read the first text".
    func read(index: Int, textsOnly: Bool) -> String {
        let pool = textsOnly ? unread.filter { $0.isText } : unread
        guard pool.indices.contains(index) else {
            return textsOnly ? "No text like that." : "No message like that."
        }
        let m = pool[index]
        lastRead = m
        if m.isText {
            return "Text from \(Self.smsSender(m)): \(m.preview.isEmpty ? m.subject : m.preview)"
        }
        return "From \(m.from). \(m.subject). \(m.preview)"
    }

    /// BUILD 167 — COMPOSE, into whichever mail app he actually uses.
    ///
    /// iOS won't let an app silently create a draft in Mail or Outlook —
    /// that's a hard sandbox rule, not a Chappy limit. What IS allowed is
    /// handing a fully-written message to the mail app, which lands as an
    /// editable draft with one tap to send. Same one-tap-consent pattern
    /// as the reply path, which has worked since 147.
    ///
    /// Outlook publishes its own URL scheme, so if it's installed and
    /// preferred we go straight there; otherwise mailto: opens whatever
    /// iOS has set as the default mail app (which may well BE Outlook).
    @discardableResult
    static func compose(to: String, subject: String, body: String,
                        preferOutlook: Bool = false) -> Bool {
        let enc: (String) -> String = {
            $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        }
        if preferOutlook,
           let ol = URL(string: "ms-outlook://compose?to=\(enc(to))&subject=\(enc(subject))&body=\(enc(body))"),
           UIApplication.shared.canOpenURL(ol) {
            UIApplication.shared.open(ol, options: [:], completionHandler: nil)
            return true
        }
        guard let u = URL(string: "mailto:\(enc(to))?subject=\(enc(subject))&body=\(enc(body))")
        else { return false }
        UIApplication.shared.open(u, options: [:], completionHandler: nil)
        return true
    }

    /// Is Outlook actually on this phone? Used to decide whether to offer it.
    static var hasOutlook: Bool {
        URL(string: "ms-outlook://").map { UIApplication.shared.canOpenURL($0) } ?? false
    }

    /// Reply — opens Mail pre-filled; ONE human tap sends. A reply to a
    /// TelTel message goes back out as a real SMS.
    func replyToLast(saying body: String) -> String {
        guard let m = lastRead else { return "Read a message first, then tell me the reply." }
        let to = m.fromAddress.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? m.fromAddress
        let subj = ("Re: " + m.subject).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let b = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let u = URL(string: "mailto:\(to)?subject=\(subj)&body=\(b)") else {
            return "Couldn't build that reply."
        }
        UIApplication.shared.open(u, options: [:], completionHandler: nil)
        return m.isText
            ? "Reply's ready on screen - one tap sends the text."
            : "Reply's ready on screen - one tap sends it."
    }

    // MARK: parsing (deliberately forgiving)

    private func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
              .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func uids(from response: String) -> [Int] {
        for line in response.components(separatedBy: "\r\n") where line.hasPrefix("* SEARCH") {
            return line.dropFirst(8).split(separator: " ").compactMap { Int($0) }
        }
        return []
    }

    static func parse(uid: Int, fetch: String) -> Message {
        var from = "someone", fromAddr = "", subject = "(no subject)"
        var bodyLines: [String] = []
        var inHeaders = false
        for raw in fetch.components(separatedBy: "\r\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("from:") {
                inHeaders = true
                let v = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let lt = v.firstIndex(of: "<"), let gt = v.firstIndex(of: ">") {
                    fromAddr = String(v[v.index(after: lt)..<gt])
                    let name = String(v[v.startIndex..<lt])
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    from = name.isEmpty ? fromAddr : name
                } else {
                    fromAddr = v; from = v
                }
            } else if lower.hasPrefix("subject:") {
                subject = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if inHeaders, !line.isEmpty, !line.hasPrefix("*"),
                      !lower.hasPrefix("from:"), !lower.hasPrefix("subject:"),
                      line != ")", !line.hasPrefix("a") || !line.contains(" OK") {
                // Everything after the headers that isn't IMAP plumbing is body.
                if !line.contains("BODY[") && !line.hasPrefix("{") {
                    bodyLines.append(line)
                }
            }
        }
        var preview = bodyLines.joined(separator: " ")
            .replacingOccurrences(of: "=\r\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.count > 260 { preview = String(preview.prefix(260)) }
        return Message(id: uid, from: from, fromAddress: fromAddr,
                       subject: subject, preview: preview)
    }

    /// "0412 345 678" out of "0412345678@teltel.com.au" — spoken like a person.
    static func smsSender(_ m: Message) -> String {
        let local = m.fromAddress.split(separator: "@").first.map(String.init) ?? m.from
        if local.allSatisfy({ $0.isNumber || $0 == "+" }), local.count >= 8 {
            return local.enumerated().map { i, c in
                (i > 0 && i % 4 == 0) ? " \(c)" : "\(c)"
            }.joined()
        }
        return m.from
    }
}

/// Just enough IMAP, over TLS from the first byte.
final class MiniIMAP {

    private var conn: NWConnection?
    private var tagN = 0

    enum MailError: LocalizedError {
        case connect, closed, bad(String)
        var errorDescription: String? {
            switch self {
            case .connect: return "couldn't connect"
            case .closed: return "connection closed"
            case .bad(let s): return s
            }
        }
    }

    func connect(host: String) async throws {
        let c = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(integerLiteral: 993),
                             using: .tls)
        conn = c
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            c.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready: done = true; cont.resume()
                case .failed(let e): done = true; cont.resume(throwing: e)
                case .cancelled: done = true; cont.resume(throwing: MailError.closed)
                default: break
                }
            }
            c.start(queue: .global(qos: .userInitiated))
        }
        _ = try await readUntil("\r\n")   // the server greeting
    }

    func command(_ body: String) async throws -> String {
        tagN += 1
        let tag = "a\(tagN)"
        try await send("\(tag) \(body)\r\n")
        let resp = try await readUntil("\r\n\(tag) ")
        if resp.contains("\r\n\(tag) NO") || resp.contains("\r\n\(tag) BAD") {
            // Speakable: the word after NO/BAD onwards, trimmed.
            let tail = resp.components(separatedBy: "\r\n\(tag) ").last ?? "refused"
            throw MailError.bad(String(tail.prefix(120)))
        }
        return resp
    }

    private func send(_ s: String) async throws {
        guard let conn else { throw MailError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(s.utf8), completion: .contentProcessed { e in
                if let e { cont.resume(throwing: e) } else { cont.resume() }
            })
        }
    }

    /// Read until the marker appears, then one more line-end. Bounded so a
    /// hostile or confused server can't balloon memory.
    private func readUntil(_ marker: String) async throws -> String {
        guard let conn else { throw MailError.closed }
        var buf = Data()
        for _ in 0..<200 {
            if let text = String(data: buf, encoding: .utf8) ?? String(data: buf, encoding: .isoLatin1),
               let r = text.range(of: marker) {
                // finish the marker's line
                if text[r.upperBound...].contains("\r\n") || marker == "\r\n" {
                    return text
                }
            }
            if buf.count > 512 * 1024 { throw MailError.bad("response too large") }
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, done, err in
                    if let err { cont.resume(throwing: err) }
                    else if let data, !data.isEmpty { cont.resume(returning: data) }
                    else if done { cont.resume(throwing: MailError.closed) }
                    else { cont.resume(returning: Data()) }
                }
            }
            buf.append(chunk)
        }
        throw MailError.bad("response never completed")
    }

    func close() {
        conn?.cancel()
        conn = nil
    }
}


// =====================================================================
// MARK: - CHAPPY FLIGHTS (Build 150 — deal watch + my flight)
// =====================================================================
//
// Two halves, one engine:
//
//   DEAL WATCH — powered by Amadeus, the airline industry's own data rail,
//   whose free developer tier covers exactly what a personal deal watcher
//   needs: real offers for a route, and cheapest-date search. Watched
//   routes are re-checked on the proactive engine's existing daily passes
//   (capped at 3 checks a day), every price is logged so routes grow a
//   history, and a real drop pings the wearer. No key configured = the
//   feature says so politely and sits quiet; keys go in Settings whenever.
//
//   MY FLIGHT — "track flight QF52 on Thursday" builds the travel-day
//   scaffolding automatically: check-in reminder at T-24h, airport
//   departure reminder, and the flight as a diary presence. Live status
//   hands off to a search with the flight number pre-filled — the honest
//   free option until a status API earns its keep.
@MainActor
final class ChappyFlights: ObservableObject {

    static let shared = ChappyFlights()
    private init() { load(); armFlightDayWatch() }

    // MARK: models

    struct PricePoint: Codable { var at: Date; var price: Double }

    struct WatchedRoute: Codable, Identifiable {
        var id: UUID = UUID()
        var originCode: String      // "BNE"
        var destCode: String        // "DPS"
        var destName: String        // "Denpasar"
        var month: String           // "2026-09"
        var currency: String = "AUD"
        var lastPrice: Double?
        var bestDate: String?
        var history: [PricePoint] = []
    }

    struct TrackedFlight: Codable, Identifiable {
        var id: UUID = UUID()
        var number: String          // "QF52"
        var date: Date
        // BUILD 152 — FLIGHT DAY memory. Every field optional so flights
        // tracked under build 150/151 still decode from UserDefaults.
        var depAirport: String?     // "Brisbane Airport" — learned from the first live check
        var depIata: String?        // "BNE"
        var depTerminal: String?
        var lastStatus: String?     // change detection: only CHANGES get spoken
        var lastDelay: Int?
        var lastGate: String?
        var lastEstDep: String?     // "10:55"
        var domestic: Bool?         // both timezones Australian → 90 min buffer, else 3 h
        var slotsDone: [String]?    // "night","morning","t6","t3","t90","t45" — each fires once
    }

    @Published private(set) var watches: [WatchedRoute] = []
    @Published private(set) var tracked: [TrackedFlight] = []
    @Published private(set) var lastError: String?

    var isConfigured: Bool {
        APIKeyManager.shared.getAmadeusKey() != nil && APIKeyManager.shared.getAmadeusSecret() != nil
    }

    // MARK: persistence

    private func save() {
        let d = UserDefaults.standard
        if let w = try? JSONEncoder().encode(watches) { d.set(w, forKey: "chappy_flight_watches") }
        if let t = try? JSONEncoder().encode(tracked) { d.set(t, forKey: "chappy_flight_tracked") }
    }

    private func load() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "chappy_flight_watches"),
           let w = try? JSONDecoder().decode([WatchedRoute].self, from: data) { watches = w }
        if let data = d.data(forKey: "chappy_flight_tracked"),
           let t = try? JSONDecoder().decode([TrackedFlight].self, from: data) { tracked = t }
    }

    // MARK: Amadeus plumbing

    private var token: String?
    private var tokenExpiry = Date.distantPast

    private func bearer() async throws -> String {
        if let t = token, Date() < tokenExpiry { return t }
        guard let key = APIKeyManager.shared.getAmadeusKey(),
              let secret = APIKeyManager.shared.getAmadeusSecret(),
              let url = URL(string: "https://test.api.amadeus.com/v1/security/oauth2/token")
        else { throw FlightError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "grant_type=client_credentials&client_id=\(key)&client_secret=\(secret)"
            .data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = json["access_token"] as? String
        else { throw FlightError.auth }
        token = t
        tokenExpiry = Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 1700) - 60)
        return t
    }

    private func get(_ path: String) async throws -> [String: Any] {
        let t = try await bearer()
        guard let url = URL(string: "https://test.api.amadeus.com" + path) else { throw FlightError.bad }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FlightError.http(code) }
        return json
    }

    enum FlightError: LocalizedError {
        case notConfigured, auth, bad, http(Int), noResults
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Amadeus keys aren't set - Settings, Flights"
            case .auth: return "Amadeus refused the keys"
            case .bad: return "bad request"
            case .http(let c): return "flight service error \(c)"
            case .noResults: return "no flights found"
            }
        }
    }

    /// "denpasar" → ("DPS", "Denpasar"). Airports first, then cities.
    func locationCode(for name: String) async throws -> (code: String, name: String) {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let json = try await get("/v1/reference-data/locations?keyword=\(q)&subType=AIRPORT,CITY&page%5Blimit%5D=3")
        guard let arr = json["data"] as? [[String: Any]], let first = arr.first,
              let code = first["iataCode"] as? String else { throw FlightError.noResults }
        let display = (first["name"] as? String)?.capitalized ?? name
        return (code, display)
    }

    /// The cheapest dates for a route in a month. Returns (date, price) list.
    func cheapestDates(origin: String, dest: String) async throws -> [(date: String, price: Double)] {
        let json = try await get("/v1/shopping/flight-dates?origin=\(origin)&destination=\(dest)")
        guard let arr = json["data"] as? [[String: Any]] else { throw FlightError.noResults }
        return arr.compactMap { d in
            guard let date = d["departureDate"] as? String,
                  let priceObj = d["price"] as? [String: Any],
                  let total = priceObj["total"] as? String, let p = Double(total)
            else { return nil }
            return (date, p)
        }
    }

    /// Real offers for a fixed date.
    func offers(origin: String, dest: String, date: String) async throws -> [(carrier: String, price: Double)] {
        let json = try await get("/v2/shopping/flight-offers?originLocationCode=\(origin)&destinationLocationCode=\(dest)&departureDate=\(date)&adults=1&currencyCode=AUD&max=5")
        guard let arr = json["data"] as? [[String: Any]] else { throw FlightError.noResults }
        return arr.compactMap { o in
            guard let priceObj = o["price"] as? [String: Any],
                  let total = priceObj["total"] as? String, let p = Double(total) else { return nil }
            let carrier = ((o["validatingAirlineCodes"] as? [String])?.first) ?? "—"
            return (carrier, p)
        }
    }

    // MARK: deal watch

    func addWatch(destName: String, month: String, origin: String = "BNE") async -> String {
        guard isConfigured else {
            return "Flight watching needs the free Amadeus keys first - they go in Settings, Flights. Two minutes at developers dot amadeus dot com."
        }
        do {
            let loc = try await locationCode(for: destName)
            var w = WatchedRoute(originCode: origin, destCode: loc.code,
                                 destName: loc.name, month: month)
            let all = try await cheapestDates(origin: origin, dest: loc.code)
            let inMonth = all.filter { $0.date.hasPrefix(month) }
            let pick = (inMonth.isEmpty ? all : inMonth).min { $0.price < $1.price }
            if let p = pick {
                w.lastPrice = p.price
                w.bestDate = p.date
                w.history.append(PricePoint(at: Date(), price: p.price))
            }
            watches.append(w)
            save()
            if let p = pick {
                return "Watching \(loc.name). Cheapest right now: \(Int(p.price)) dollars on \(Self.spokenDate(p.date)). I'll check a few times a day and sing out when it drops."
            }
            return "Watching \(loc.name). No prices back yet - I'll keep checking."
        } catch {
            lastError = error.localizedDescription
            return "Couldn't set that watch: \(error.localizedDescription)"
        }
    }

    func removeWatch(_ id: UUID) { watches.removeAll { $0.id == id }; save() }

    /// Piggybacks the proactive passes; self-caps at 3 checks a day.
    private var checksToday: Int {
        get { UserDefaults.standard.string(forKey: "chappy_flight_check_day") == Self.dayKey()
              ? UserDefaults.standard.integer(forKey: "chappy_flight_checks") : 0 }
        set {
            UserDefaults.standard.set(Self.dayKey(), forKey: "chappy_flight_check_day")
            UserDefaults.standard.set(newValue, forKey: "chappy_flight_checks")
        }
    }
    private static func dayKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    func checkIfDue() async {
        guard isConfigured, !watches.isEmpty, checksToday < 3 else { return }
        checksToday += 1
        for i in watches.indices {
            let w = watches[i]
            guard let all = try? await cheapestDates(origin: w.originCode, dest: w.destCode) else { continue }
            let inMonth = all.filter { $0.date.hasPrefix(w.month) }
            guard let pick = (inMonth.isEmpty ? all : inMonth).min(by: { $0.price < $1.price }) else { continue }
            let old = watches[i].lastPrice
            watches[i].lastPrice = pick.price
            watches[i].bestDate = pick.date
            watches[i].history.append(PricePoint(at: Date(), price: pick.price))
            if watches[i].history.count > 60 { watches[i].history.removeFirst() }
            // A real drop: 5%+ below the last seen price.
            if let o = old, pick.price < o * 0.95 {
                ChappyNotify.announce(.nav,
                    spoken: "Flight deal: \(w.destName) just dropped to \(Int(pick.price)) dollars, \(Self.spokenDate(pick.date)).",
                    title: "✈️ \(w.destName) ↓ $\(Int(pick.price))",
                    body: "was $\(Int(o)) — \(Self.spokenDate(pick.date))")
            }
        }
        save()
    }

    func spokenDeals() -> String {
        guard isConfigured else {
            return "Flight watching needs the free Amadeus keys - Settings, Flights."
        }
        guard !watches.isEmpty else {
            return "No routes watched yet. Say: watch flights to Bali in September."
        }
        let lines = watches.prefix(4).map { w -> String in
            guard let p = w.lastPrice else { return "\(w.destName): no price yet" }
            return "\(w.destName): \(Int(p)) dollars\(w.bestDate.map { ", " + Self.spokenDate($0) } ?? "")"
        }
        return "Watching: " + lines.joined(separator: ". ") + "."
    }

    // MARK: my flight

    func track(number: String, date: Date) -> String {
        let f = TrackedFlight(number: number.uppercased(), date: date)
        tracked.removeAll { Calendar.current.isDate($0.date, inSameDayAs: date) && $0.number == f.number }
        tracked.append(f)
        save()
        // The travel-day scaffolding, as ordinary reminders he can edit.
        _ = ChappyDataBridge.addReminder(text: "Check in for \(f.number)",
                                         at: date.addingTimeInterval(-24 * 3600))
        _ = ChappyDataBridge.addReminder(text: "Head to the airport for \(f.number)",
                                         at: date.addingTimeInterval(-3 * 3600))
        armFlightDayWatch()
        let df = DateFormatter(); df.dateFormat = "EEEE h:mm a"
        return "Tracking \(f.number), \(df.string(from: date)). Check-in reminder set for the day before, airport reminder three hours out. On the day I'll run flight-day mode - briefs, leave-by time, and I'll sing out if the gate or the delay changes."
    }

    /// BUILD 151 — LIVE STATUS, SPOKEN. AviationStack answers "how's my
    /// flight" out loud: on time or delayed, gate, terminal. The free tier
    /// is 100 calls a month, so this fires ONLY when asked — never polled —
    /// and the screen handoff stays as the fallback.
    func statusHandoff() -> String {
        guard tracked.sorted(by: { $0.date < $1.date })
            .first(where: { $0.date > Date().addingTimeInterval(-6 * 3600) }) != nil else {
            return "No flight tracked. Say: track flight QF52 on Thursday."
        }
        Task { @MainActor in
            TTSService.shared.speak(await self.liveStatus())
        }
        return "Checking."
    }

    private func liveStatus() async -> String {
        guard let f = tracked.sorted(by: { $0.date < $1.date })
            .first(where: { $0.date > Date().addingTimeInterval(-6 * 3600) }) else {
            return "No flight tracked."
        }
        guard let snap = await fetchSnapshot(f) else { return screenFallback(f) }
        apply(snap, to: f.id)
        var line = spokenStatus(f.number, snap)
        // BUILD 152: a manual "how's my flight" with the flight still ahead
        // gets the leave-by plan bolted on — status without a plan is trivia.
        if snap.status != "landed", snap.status != "active",
           f.date.timeIntervalSinceNow > 45 * 60,
           let lb = await leaveByLine(for: freshest(f.id) ?? f, snap: snap) {
            line += " " + lb
        }
        // BUILD 154: a manual check inside 12 h lights the Live Activity too.
        if let f2 = freshest(f.id), f2.date.timeIntervalSinceNow < 12 * 3600 {
            ChappyLiveActivity.shared.sync(flight: f2,
                                           leaveBy: await leaveByDate(for: f2, snap: snap))
        }
        return line
    }

    /// BUILD 154 — the leave-by moment as a Date, for the Live Activity
    /// countdown. Same maths as the spoken line.
    private func leaveByDate(for f: TrackedFlight, snap: FlightSnapshot?) async -> Date? {
        guard let airport = snap?.depAirport ?? f.depAirport else { return nil }
        guard let mins = await NavEngine.shared.travelMinutes(to: airport) else { return nil }
        let dom = snap?.domestic ?? f.domestic ?? true
        return f.date.addingTimeInterval(-Double((dom ? 90 : 180) + mins + 10) * 60)
    }

    private func screenFallback(_ f: TrackedFlight) -> String {
        let q = "\(f.number) flight status".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? f.number
        if let u = URL(string: "https://www.google.com/search?q=\(q)") {
            UIApplication.shared.open(u, options: [:], completionHandler: nil)
        }
        return "Couldn't reach the status service - it's on screen instead."
    }

    // =================================================================
    // BUILD 152 — FLIGHT DAY MODE.
    //
    // The moment a tracked flight is inside 36 hours, Chappy runs the day:
    // a night-before brief with a leave-by time, a morning brief, then
    // budgeted re-checks at T-6h, T-3h, T-90m and T-45m that only SPEAK
    // when something moved — gate changed, delay posted, cancelled.
    // Each slot fires once and the day is hard-capped at 8 AviationStack
    // calls, so a flight day costs ~6 of the free 100 a month. No flight
    // inside 36 hours → the timer isn't even running.
    // =================================================================

    struct FlightSnapshot {
        var status: String
        var delay: Int?
        var gate: String?
        var terminal: String?
        var estDep: String?         // "10:55"
        var estArr: String?
        var depAirport: String?     // "Brisbane Airport"
        var depIata: String?
        var schedDep: Date?         // the REAL scheduled departure, full date
        var domestic: Bool?
    }

    /// One AviationStack call → one snapshot. Nil on any failure — callers
    /// fall back to the screen handoff or stay quiet.
    private func fetchSnapshot(_ f: TrackedFlight) async -> FlightSnapshot? {
        guard let key = APIKeyManager.shared.getAviationStackKey(),
              let url = URL(string: "http://api.aviationstack.com/v1/flights?access_key=\(key)&flight_iata=\(f.number)&limit=1")
        else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]], let flight = arr.first
        else { return nil }
        let dep = flight["departure"] as? [String: Any] ?? [:]
        let arr2 = flight["arrival"] as? [String: Any] ?? [:]
        var s = FlightSnapshot(status: (flight["flight_status"] as? String) ?? "unknown")
        s.delay = dep["delay"] as? Int
        s.gate = dep["gate"] as? String
        s.terminal = dep["terminal"] as? String
        s.depAirport = dep["airport"] as? String
        s.depIata = dep["iata"] as? String
        if let est = (dep["estimated"] as? String) ?? (dep["scheduled"] as? String), est.count >= 16 {
            s.estDep = String(est.dropFirst(11).prefix(5))
        }
        if let a = arr2["estimated"] as? String, a.count >= 16 {
            s.estArr = String(a.dropFirst(11).prefix(5))
        }
        if let sched = dep["scheduled"] as? String {
            s.schedDep = ISO8601DateFormatter().date(from: sched)
        }
        // Both ends on Australian clocks → domestic buffers. Anything
        // else gets the international three hours.
        if let dt = dep["timezone"] as? String, let at = arr2["timezone"] as? String {
            s.domestic = dt.hasPrefix("Australia") && at.hasPrefix("Australia")
        }
        return s
    }

    /// Fold a snapshot into the stored flight so the NEXT check can tell
    /// what changed. Also upgrades the tracked date to the real scheduled
    /// departure the first time we see it — he says "Thursday", the API
    /// knows 10:40 Thursday, and every slot and leave-by needs the 10:40.
    private func apply(_ s: FlightSnapshot, to id: UUID) {
        guard let i = tracked.firstIndex(where: { $0.id == id }) else { return }
        tracked[i].lastStatus = s.status
        tracked[i].lastDelay = s.delay
        tracked[i].lastGate = s.gate
        tracked[i].lastEstDep = s.estDep
        if let a = s.depAirport { tracked[i].depAirport = a }
        if let c = s.depIata { tracked[i].depIata = c }
        if let t = s.terminal { tracked[i].depTerminal = t }
        if let d = s.domestic { tracked[i].domestic = d }
        if let real = s.schedDep,
           abs(real.timeIntervalSince(tracked[i].date)) < 36 * 3600 {
            tracked[i].date = real
        }
        save()
        ChappyGlance.write()   // BUILD 154: the home widget rides every snapshot
    }

    private func freshest(_ id: UUID) -> TrackedFlight? {
        tracked.first(where: { $0.id == id })
    }

    /// The spoken verdict, shared by the manual ask and every brief.
    private func spokenStatus(_ number: String, _ s: FlightSnapshot) -> String {
        var bits: [String] = []
        switch s.status {
        case "cancelled": return "\(number) is CANCELLED. I'd call the airline now."
        case "landed": bits.append("\(number) has landed")
        case "active": bits.append("\(number) is in the air")
        case "incident", "diverted": bits.append("\(number) reports \(s.status) - check with the airline")
        default: bits.append("\(number) is scheduled")
        }
        if let delay = s.delay, delay > 0 {
            bits.append("running \(delay) minutes late")
        } else if s.status == "scheduled" {
            bits.append("on time")
        }
        if let est = s.estDep { bits.append("departing \(est)") }
        if let gate = s.gate { bits.append("gate \(gate)") }
        if let term = s.terminal { bits.append("terminal \(term)") }
        if s.status == "active", let a = s.estArr { bits.append("landing about \(a)") }
        return bits.joined(separator: ", ") + "."
    }

    /// The whole point of flight day: a leave-by time built from LIVE drive
    /// time to the actual airport, plus a realistic check-in buffer.
    private func leaveByLine(for f: TrackedFlight, snap: FlightSnapshot) async -> String? {
        guard let airport = snap.depAirport ?? f.depAirport else { return nil }
        guard let mins = await NavEngine.shared.travelMinutes(to: airport) else { return nil }
        let dom = snap.domestic ?? f.domestic ?? true
        let buffer = dom ? 90 : 180
        let leave = f.date.addingTimeInterval(-Double(buffer + mins + 10) * 60)
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        if leave <= Date() {
            return "Time to move - \(airport) is about \(mins) minutes away."
        }
        return "Leave by \(df.string(from: leave)) - about \(mins) minutes' drive, plus \(dom ? "ninety minutes" : "three hours") at the airport."
    }

    /// The flight that owns TODAY: departed less than 3 h ago or leaving
    /// within 20 h. Drives the airport-nav swap and the Flights GUI banner.
    func todayFlight() -> TrackedFlight? {
        tracked.sorted { $0.date < $1.date }.first {
            $0.date.timeIntervalSinceNow > -3 * 3600 &&
            $0.date.timeIntervalSinceNow < 20 * 3600
        }
    }

    /// "Take me to the airport" on flight day → the RIGHT airport and the
    /// right terminal, no questions asked. Nil when today isn't a flight day.
    func airportNavQuery() -> String? {
        guard let f = todayFlight(), let ap = f.depAirport else { return nil }
        if let t = f.depTerminal { return "\(ap) Terminal \(t)" }
        return ap
    }

    // MARK: the flight-day heartbeat

    private var flightDayTimer: Timer?

    /// A 10-minute heartbeat that only exists while a flight is inside 36
    /// hours. ChappyProactive's passes call flightDayPass too, so the
    /// briefs still land even when the timer died with the app.
    func armFlightDayWatch() {
        flightDayTimer?.invalidate(); flightDayTimer = nil
        guard tracked.contains(where: {
            $0.date.timeIntervalSinceNow > -3 * 3600 &&
            $0.date.timeIntervalSinceNow < 36 * 3600
        }) else { return }
        flightDayTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in await ChappyFlights.shared.flightDayPass() }
        }
        print("✈️ [FlightDay] watch armed")
    }

    private var flightDayChecksToday: Int {
        get { UserDefaults.standard.string(forKey: "chappy_flightday_day") == Self.dayKey()
              ? UserDefaults.standard.integer(forKey: "chappy_flightday_checks") : 0 }
        set {
            UserDefaults.standard.set(Self.dayKey(), forKey: "chappy_flightday_day")
            UserDefaults.standard.set(newValue, forKey: "chappy_flightday_checks")
        }
    }

    func flightDayPass() async {
        for f in tracked {
            let toGo = f.date.timeIntervalSinceNow
            guard toGo > -2 * 3600, toGo < 36 * 3600 else { continue }
            guard let slot = dueFlightSlot(f) else { continue }
            guard flightDayChecksToday < 8 else { return }   // the hard daily cap
            flightDayChecksToday += 1
            // Marked done BEFORE the network call — a failed fetch must not
            // become three retries and three announcements an hour later.
            markSlot(slot, on: f.id)
            guard let snap = await fetchSnapshot(f) else { continue }
            let before = freshest(f.id) ?? f
            apply(snap, to: f.id)
            await announceSlot(slot, flight: freshest(f.id) ?? f, before: before, snap: snap)
            // BUILD 154: inside 12 hours the Live Activity mirrors every check.
            if let f2 = freshest(f.id), f2.date.timeIntervalSinceNow < 12 * 3600 {
                ChappyLiveActivity.shared.sync(flight: f2,
                                               leaveBy: await leaveByDate(for: f2, snap: snap))
            }
        }
        armFlightDayWatch()   // flight gone past → timer stands down
    }

    /// Which flight-day moment is NOW, if any. Tightest window wins; each
    /// fires once. Windows are wide because the pass runs every 10 minutes.
    private func dueFlightSlot(_ f: TrackedFlight) -> String? {
        let done = f.slotsDone ?? []
        let now = Date()
        let dep = f.date
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let windows: [(String, ClosedRange<Date>)] = [
            ("t45", dep.addingTimeInterval(-55 * 60)...dep.addingTimeInterval(-25 * 60)),
            ("t90", dep.addingTimeInterval(-110 * 60)...dep.addingTimeInterval(-65 * 60)),
            ("t3",  dep.addingTimeInterval(-3.6 * 3600)...dep.addingTimeInterval(-2.4 * 3600)),
            ("t6",  dep.addingTimeInterval(-6.5 * 3600)...dep.addingTimeInterval(-4.8 * 3600))
        ]
        for (name, w) in windows where !done.contains(name) && w.contains(now) {
            return name
        }
        // Morning brief: flight day, after 6am, more than 2.5 h before wheels-up.
        if !done.contains("morning"), cal.isDate(now, inSameDayAs: dep),
           hour >= 6, dep.timeIntervalSince(now) > 2.5 * 3600 {
            return "morning"
        }
        // Night-before brief: 6pm to 11pm the evening before.
        if !done.contains("night"),
           let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(tomorrow, inSameDayAs: dep),
           hour >= 18, hour < 23 {
            return "night"
        }
        return nil
    }

    private func markSlot(_ s: String, on id: UUID) {
        guard let i = tracked.firstIndex(where: { $0.id == id }) else { return }
        var d = tracked[i].slotsDone ?? []
        d.append(s)
        tracked[i].slotsDone = d
        save()
    }

    private func announceSlot(_ slot: String, flight f: TrackedFlight,
                              before: TrackedFlight, snap: FlightSnapshot) async {
        switch slot {
        case "night":
            var line = "Flight day tomorrow. " + spokenStatus(f.number, snap)
            if let lb = await leaveByLine(for: f, snap: snap) { line += " " + lb }
            line += " I'll check again in the morning."
            ChappyNotify.announce(.nav, spoken: line,
                title: "✈️ \(f.number) tomorrow",
                body: (snap.estDep.map { "Departs \($0). " } ?? "") + "Night-before brief.")
        case "morning":
            var line = "Flight day. " + spokenStatus(f.number, snap)
            if let lb = await leaveByLine(for: f, snap: snap) { line += " " + lb }
            // BUILD 153: the ride is one sentence away on flight day.
            line += " When you're ready, say: get me a \(ChappyRide.shared.provider.display) to the airport."
            ChappyNotify.announce(.nav, spoken: line,
                title: "✈️ \(f.number) today",
                body: (snap.estDep.map { "Departs \($0). " } ?? "") + "Morning brief.")
        default:
            // The quiet checks: speak ONLY when something moved.
            if snap.status == "cancelled" {
                ChappyNotify.announce(.nav,
                    spoken: "\(f.number) is CANCELLED. Call the airline now.",
                    title: "✈️ \(f.number) CANCELLED",
                    body: "Call the airline.", critical: true)
                return
            }
            var changes: [String] = []
            if let g = snap.gate, g != before.lastGate {
                changes.append(before.lastGate == nil ? "gate is \(g)" : "gate moved to \(g)")
            }
            let oldDelay = before.lastDelay ?? 0
            if let d = snap.delay, d >= 10, abs(d - oldDelay) >= 10 {
                changes.append("now running \(d) minutes late")
            } else if oldDelay >= 10, (snap.delay ?? 0) < 10 {
                changes.append("back on time")
            }
            if let e = snap.estDep, let old = before.lastEstDep, e != old, changes.isEmpty {
                changes.append("departure now \(e)")
            }
            guard !changes.isEmpty else {
                print("✈️ [FlightDay] \(slot): no change — staying quiet"); return
            }
            let line = "\(f.number): " + changes.joined(separator: ", ") + "."
            ChappyNotify.announce(.nav, spoken: line,
                title: "✈️ \(f.number) update",
                body: changes.joined(separator: ", "))
        }
    }

    static func spokenDate(_ ymd: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: ymd) else { return ymd }
        let out = DateFormatter(); out.dateFormat = "EEEE d MMMM"
        return out.string(from: d)
    }

    /// "september" → "2026-09" (next occurrence).
    static func monthKey(from text: String) -> String? {
        let months = ["january": 1, "february": 2, "march": 3, "april": 4,
                      "may": 5, "june": 6, "july": 7, "august": 8,
                      "september": 9, "october": 10, "november": 11, "december": 12]
        let t = text.lowercased()
        for (name, num) in months where t.contains(name) {
            let now = Date()
            var year = Calendar.current.component(.year, from: now)
            if num < Calendar.current.component(.month, from: now) { year += 1 }
            return String(format: "%04d-%02d", year, num)
        }
        return nil
    }

    /// Finds "qf52"-shaped tokens without regex: letters then digits, 3-7 chars.
    static func flightNumber(in text: String) -> String? {
        for tok in text.uppercased().split(separator: " ") {
            let s = String(tok.filter { $0.isLetter || $0.isNumber })
            guard s.count >= 3, s.count <= 7 else { continue }
            let letters = s.prefix(while: { $0.isLetter })
            let rest = s.dropFirst(letters.count)
            if (1...3).contains(letters.count), rest.count >= 1, rest.allSatisfy({ $0.isNumber }) {
                return s
            }
        }
        return nil
    }
}

// =====================================================================
// MARK: - CHAPPY RIDE & FOOD (Build 153)
// =====================================================================
//
//   The honest shape of ride-hailing on iOS: Apple KILLED the SiriKit
//   ride-booking domain, Grab's booking API is partner-only, and payment
//   lives inside each provider's app — which is where you WANT your card.
//   What survived everywhere (Google Maps does exactly this) is the
//   DEEP-LINK HANDOFF: open Grab or Uber with pickup and drop-off
//   already filled, so the whole booking is one tap and one thumbprint.
//
//   So Chappy owns everything AROUND that tap: the fare band (tariff
//   table, editable in Settings), the live ETA (nav engine), the
//   handoff itself, and the TRIP WATCH — Chappy can't see Grab's
//   driver, but the Trail can see YOU: not moving 8 minutes after
//   booking → a nudge; rolling → confirmation; arrived → the spend
//   prompt straight into the cost log.
//
//   FOOD is the same pattern one screen over: GrabFood / Uber Eats /
//   GoFood handoff plus a favourites list for "order the usual".
//   No menu browsing by voice — there is no public API — and no
//   pretending otherwise.

@MainActor
final class ChappyRide: ObservableObject {

    static let shared = ChappyRide()
    private init() {}

    enum Provider: String, CaseIterable {
        case grab, uber, gojek
        var display: String {
            switch self {
            case .grab: return "Grab"
            case .uber: return "Uber"
            case .gojek: return "Gojek"
            }
        }
    }

    /// Auto: Australian clocks → Uber, everywhere else → Grab. The
    /// Settings pick wins when set; "make it a Gojek" wins in the moment.
    var provider: Provider {
        if let p = Provider(rawValue: UserDefaults.standard.string(forKey: "chappy_ride_provider") ?? "") {
            return p
        }
        return TimeZone.current.identifier.hasPrefix("Australia") ? .uber : .grab
    }

    // MARK: tariff — a BAND, not a quote, and it says so on the tin.

    private var isAUD: Bool { TimeZone.current.identifier.hasPrefix("Australia") }

    private func tariff() -> (base: Double, perKm: Double, perMin: Double) {
        let d = UserDefaults.standard
        if d.double(forKey: "chappy_ride_perkm") > 0 {
            return (d.double(forKey: "chappy_ride_base"),
                    d.double(forKey: "chappy_ride_perkm"),
                    d.double(forKey: "chappy_ride_permin"))
        }
        // Defaults: UberX Brisbane in dollars, GrabCar Bali in rupiah.
        return isAUD ? (3.5, 1.5, 0.4) : (10000, 6500, 350)
    }

    private func spokenFare(_ f: Double) -> String {
        if isAUD {
            let lo = max(5, Int((f / 5).rounded()) * 5)
            return "\(lo) to \(Int((Double(lo) * 1.3 / 5).rounded()) * 5) dollars"
        }
        let k = max(10, Int((f / 1000).rounded()))
        return "\(k) to \(Int((Double(k) * 1.3).rounded())) thousand rupiah"
    }

    // MARK: the quote → confirm → open flow

    private var pending: (coord: CLLocationCoordinate2D, name: String)?
    private var pendingUntil = Date.distantPast

    func quote(to raw: String) async -> String {
        let query = raw.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
        guard !query.isEmpty else { return "Where to?" }
        guard let est = await NavEngine.shared.travelEstimate(to: query) else {
            openApp()   // couldn't price it — still open the app; that was the ask
            return "Couldn't price that one - \(provider.display) is open, set the drop-off there."
        }
        let t = tariff()
        let fare = t.base + t.perKm * est.km + t.perMin * Double(est.mins)
        pending = (est.coord, est.name)
        pendingUntil = Date().addingTimeInterval(120)
        return "About \(est.mins) minutes to \(est.name), roughly \(spokenFare(fare)). Want me to open \(provider.display)?"
    }

    /// "Yes / book it / open it" inside two minutes of a quote. Word-bounded
    /// so "yesterday" never books a car.
    func consumeConfirm(_ c: String) -> Bool {
        guard Date() < pendingUntil, let p = pending else { return false }
        let padded = " " + c + " "
        let yes = ["yes", "yeah", "yep", "book it", "open it", "do it", "go ahead", "sure"]
        guard yes.contains(where: { padded.contains(" \($0) ") }) else { return false }
        pendingUntil = .distantPast
        openRide(to: p.coord, name: p.name)
        return true
    }

    func openRide(to coord: CLLocationCoordinate2D, name: String) {
        TTSService.shared.speak("Opening \(provider.display) - drop-off is set, you just confirm and pay.")
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let lat = coord.latitude, lon = coord.longitude
        let deep: String
        let web: String
        switch provider {
        case .grab:
            deep = "grab://open?screenType=BOOKING&dropOffLatitude=\(lat)&dropOffLongitude=\(lon)&dropOffAddress=\(enc)"
            web = "https://www.grab.com/download/"
        case .uber:
            deep = "uber://?action=setPickup&pickup=my_location&dropoff%5Blatitude%5D=\(lat)&dropoff%5Blongitude%5D=\(lon)&dropoff%5Bnickname%5D=\(enc)"
            web = "https://m.uber.com/ul/?action=setPickup&pickup=my_location&dropoff%5Blatitude%5D=\(lat)&dropoff%5Blongitude%5D=\(lon)&dropoff%5Bnickname%5D=\(enc)"
        case .gojek:
            deep = "gojek://"   // no public drop-off params — app opens, one search
            web = "https://www.gojek.com/app/"
        }
        open(deep, fallback: web)
        startTripWatch(dest: coord, name: name)
    }

    private func open(_ deep: String, fallback: String) {
        guard let u = URL(string: deep) else { return }
        UIApplication.shared.open(u, options: [:]) { ok in
            if !ok {
                DispatchQueue.main.async {
                    if let w = URL(string: fallback) { UIApplication.shared.open(w, options: [:], completionHandler: nil) }
                }
            }
        }
    }

    func openApp() {
        switch provider {
        case .grab: open("grab://", fallback: "https://www.grab.com/download/")
        case .uber: open("uber://", fallback: "https://m.uber.com")
        case .gojek: open("gojek://", fallback: "https://www.gojek.com/app/")
        }
    }

    // MARK: trip watch — Chappy can't see the driver, but it can see YOU.

    private var watchTimer: Timer?
    private var watchDest: CLLocationCoordinate2D?
    private var watchName = ""
    private var watchStart: CLLocationCoordinate2D?
    private var watchBegan = Date.distantPast
    private var rolling = false
    private var nudged = false

    func startTripWatch(dest: CLLocationCoordinate2D, name: String) {
        watchTimer?.invalidate()
        watchDest = dest; watchName = name
        let s = ContextEngine.shared.snapshot
        if let la = s.latitude, let lo = s.longitude {
            watchStart = CLLocationCoordinate2D(latitude: la, longitude: lo)
        } else { watchStart = nil }
        watchBegan = Date(); rolling = false; nudged = false
        watchTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in ChappyRide.shared.tripTick() }
        }
        print("🚗 [Ride] trip watch armed → \(name)")
    }

    private func tripTick() {
        guard let dest = watchDest else { watchTimer?.invalidate(); return }
        // Two hours and we let it go — the day has moved on.
        if Date().timeIntervalSince(watchBegan) > 2 * 3600 { stopTripWatch(); return }
        let s = ContextEngine.shared.snapshot
        guard let lat = s.latitude, let lon = s.longitude else { return }
        let here = CLLocation(latitude: lat, longitude: lon)
        let toDest = here.distance(from: CLLocation(latitude: dest.latitude, longitude: dest.longitude))
        if toDest < 300 {
            ChappyNotify.announce(.nav,
                spoken: "You're at \(watchName). Say spent, and the amount, and I'll log the fare.",
                title: "📍 Arrived", body: watchName)
            stopTripWatch(); return
        }
        if let start = watchStart {
            let fromStart = here.distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude))
            if !rolling, fromStart > 400 {
                rolling = true
                TTSService.shared.speak("Trip's rolling.")
            } else if !rolling, !nudged,
                      Date().timeIntervalSince(watchBegan) > 8 * 60, fromStart < 150 {
                nudged = true
                ChappyNotify.announce(.nav,
                    spoken: "No movement yet - worth a look at the \(provider.display) app.",
                    title: "🚗 Still waiting?", body: "No pickup detected after 8 minutes")
            }
        }
    }

    func stopTripWatch() {
        watchTimer?.invalidate(); watchTimer = nil
        watchDest = nil; watchStart = nil
    }

    // MARK: food

    var favourites: [String] {
        get { UserDefaults.standard.stringArray(forKey: "chappy_food_favs") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "chappy_food_favs") }
    }

    func foodHandoff(from c: String) -> String {
        // "order from Mama's Warung" carries a name; plain "order food" doesn't.
        var place = ""
        if let r = c.range(of: "order from ") { place = String(c[r.upperBound...]) }
        place = place.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
        if place == "the usual" { place = "" }
        if place.isEmpty, c.contains("usual"), let fav = favourites.first { place = fav }
        let enc = place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let appName: String
        let deep: String
        let web: String
        switch provider {
        case .uber:
            appName = "Uber Eats"
            deep = "ubereats://"
            web = place.isEmpty ? "https://www.ubereats.com" : "https://www.ubereats.com/search?q=\(enc)"
        case .grab:
            appName = "Grab Food"
            deep = "grab://open?screenType=GRABFOOD"
            web = "https://food.grab.com"
        case .gojek:
            appName = "Go Food"
            deep = "gojek://"
            web = "https://gofood.co.id"
        }
        open(deep, fallback: web)
        if !place.isEmpty {
            return "\(appName) is open - search \(place), it's one tap from there. Tell me what you spent after and I'll log it."
        }
        if !favourites.isEmpty {
            return "\(appName) is open. Your usuals: \(favourites.prefix(3).joined(separator: ", "))."
        }
        return "\(appName) is open - order away, and tell me what you spent after."
    }
}

// =====================================================================
// MARK: - CHAPPY LIVE ACTIVITY (Build 154)
// =====================================================================
//
//   The flight, living on the lock screen and in the Dynamic Island all
//   day: countdown to wheels-up, gate, terminal, delay, leave-by. The
//   app updates it from the same flight-day passes that speak — one
//   source of truth, two surfaces.
//
//   ⚠️ ChappyFlightAttributes exists in TWO places on purpose: here, and
//   in ChappyWidgets/ChappyWidgetsLiveActivity.swift. ActivityKit
//   matches them by TYPE NAME and Codable shape across the process
//   boundary — the two copies must stay IDENTICAL, field for field.

struct ChappyFlightAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String       // scheduled / active / landed / cancelled
        var gate: String?
        var terminal: String?
        var delayMin: Int
        var departure: Date      // countdown target
        var leaveBy: Date?       // when to walk out the door
    }
    var number: String           // "QF52"
    var airport: String          // "Brisbane Airport"
}

@MainActor
final class ChappyLiveActivity {

    static let shared = ChappyLiveActivity()
    private init() {}

    private var current: Activity<ChappyFlightAttributes>?

    /// Start on first sync inside 12 hours, update on every snapshot,
    /// end itself once the flight has landed or gone 3 hours past.
    func sync(flight f: ChappyFlights.TrackedFlight, leaveBy: Date?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if f.lastStatus == "landed" || f.date.timeIntervalSinceNow < -3 * 3600 {
            end(); return
        }
        let state = ChappyFlightAttributes.ContentState(
            status: f.lastStatus ?? "scheduled",
            gate: f.lastGate,
            terminal: f.depTerminal,
            delayMin: f.lastDelay ?? 0,
            departure: f.date,
            leaveBy: leaveBy)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3 * 3600))
        if let a = current {
            Task { await a.update(content) }
        } else {
            let attrs = ChappyFlightAttributes(number: f.number,
                                               airport: f.depAirport ?? "the airport")
            current = try? Activity.request(attributes: attrs, content: content)
            print("✈️ [LiveActivity] started for \(f.number)")
        }
    }

    func end() {
        guard let a = current else { return }
        current = nil
        Task { await a.end(nil, dismissalPolicy: .default) }
    }
}

// =====================================================================
// MARK: - CHAPPY GLANCE (Build 154) — feeds the home-screen widget
// =====================================================================
//
//   The widget process can't call into the app; it reads a tiny shared
//   note the app leaves in the App Group. Until the App Group capability
//   is added in Xcode (Signing & Capabilities → App Groups →
//   group.com.shaun.chappy, on BOTH targets) the note lands nowhere and
//   the widget shows its graceful fallback — nothing breaks either way.

@MainActor
enum ChappyGlance {
    // BUILD 161: everything this reads — ChappyFlights, ChappyReminders — is
    // MainActor-isolated, so the enum has to be too. It was only ever called
    // from MainActor contexts; the compiler just wanted it said out loud.
    static func write() {
        guard let d = UserDefaults(suiteName: "group.com.shaun.chappy") else { return }
        var flightLine = ""
        if let f = ChappyFlights.shared.todayFlight() {
            let df = DateFormatter(); df.dateFormat = "h:mm a"
            var bits = ["✈️ \(f.number) \(df.string(from: f.date))"]
            if let g = f.lastGate { bits.append("Gate \(g)") }
            if let delay = f.lastDelay, delay > 0 { bits.append("+\(delay)m") }
            flightLine = bits.joined(separator: " · ")
        }
        let od = ChappyReminders.shared.overdue().count
        let today = ChappyReminders.shared.today().count
        let remLine = od > 0 ? "\(od) overdue · \(today) today"
                    : (today > 0 ? "\(today) reminders today" : "Day's clear")
        d.set(flightLine, forKey: "glance_flight")
        d.set(remLine, forKey: "glance_reminders")
        d.set(Date().timeIntervalSince1970, forKey: "glance_at")
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// =====================================================================
// MARK: - CHAPPY BURST (Build 155) — the action shot
// =====================================================================
//
//   Apple's burst is 10 frames a second with the sharpest auto-picked;
//   Google's Top Shot is the same idea. The glasses can't burst — Meta
//   hands over one still at a time — but the STREAM is already frames,
//   so Chappy samples it hard for ~2.5 seconds, scores every frame for
//   sharpness (edge energy on a 64px grayscale — blur kills edges), and
//   keeps the winner. Hold the Snap button, or say "action shot".

@MainActor
final class ChappyBurst {

    static let shared = ChappyBurst()
    private init() {}

    private(set) var isFiring = false

    func fire() {
        guard !isFiring else { return }
        isFiring = true
        Task { await run() }
    }

    private func run() async {
        defer { isFiring = false }

        let wasStreaming = LiveAIManager.shared.streamViewModel?.streamingStatus == .streaming
        if !wasStreaming {
            // BUILD 162 — THE GLASSES NEED LONGER, AND YOU NEED TO KNOW.
            //
            // The old version said "Burst" and gave the camera five seconds
            // to wake. Cold glasses routinely take longer than that, so you
            // got a promise, a silence, and no photo. Snap has always handled
            // this properly: a waking tone, something on screen, and patience.
            // Burst now does the same — twelve seconds, with the wake-up
            // sound so you know it is coming rather than broken.
            ChappyEarcon.shared.cameraWaking()
            SnapFeedback.shared.waking()
            NotificationCenter.default.post(name: .chappyWakeCameraForSnap, object: nil)
            var awake = false
            for _ in 0..<48 {                                  // up to ~12s
                try? await Task.sleep(nanoseconds: 250_000_000)
                if LiveAIManager.shared.streamViewModel?.streamingStatus == .streaming {
                    awake = true; break
                }
            }
            guard awake else {
                TTSService.shared.speak("The glasses didn't wake up in time. Try again in a moment.")
                ChappyStandby.shared.pokeEar(after: 1.5)
                return
            }
            // Let exposure settle — the first frames off a cold camera are
            // dark, and a dark frame always scores as the blurriest.
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        TTSService.shared.speak("Burst.")

        // BUILD 172 — A BURST SHOULD SOUND LIKE A BURST.
        //
        // It sampled twenty frames in total silence, so there was no way to
        // tell a working burst from a dead camera until it finished. Now
        // the shutter fires as it goes — every third frame, which reads as
        // rapid-fire without becoming a machine gun — and the count is
        // both spoken and posted, so "seven shots" is a fact you're told
        // rather than something you have to guess at.
        var frames: [UIImage] = []
        for i in 0..<20 {
            if i > 0 { try? await Task.sleep(nanoseconds: 125_000_000) }
            if let f = LiveAIManager.shared.streamViewModel?.currentVideoFrame {
                frames.append(f)
                if frames.count % 3 == 1 { ChappyEarcon.shared.shutter() }
            }
        }

        if !wasStreaming {
            if GeminiLiveService.activeInstance == nil, !ContinuousVisionManager.shared.isRunning {
                await LiveAIManager.shared.streamViewModel?.stopSession()
            }
        }

        guard frames.count >= 3 else {
            TTSService.shared.speak("The camera never settled - no burst this time.")
            return
        }

        let scored: (best: UIImage, count: Int) = await Task.detached(priority: .userInitiated) {
            var bestScore = -1.0
            var best = frames[0]
            for f in frames {
                let s = Self.sharpness(of: f)
                if s > bestScore { bestScore = s; best = f }
            }
            return (best, frames.count)
        }.value

        SnapFeedback.shared.captured(scored.best)
        _ = ChappyMemory.shared.remember(.photo,
            title: "Action shot - sharpest of \(scored.count)",
            tags: ["burst", "photo"],
            thumbnail: scored.best.jpegData(compressionQuality: 0.65),
            source: "burst")
        ChappyEarcon.shared.done()
        ChappyHaptics.shared.shutter()
        ChappyNotify.post(.nav,
                          title: "📸 Burst: \(scored.count) shots",
                          body: "Kept the sharpest. It's in Gallery under Photos.")
        TTSService.shared.speak("\(scored.count) shots. Kept the sharpest.")
        // BUILD 162: waking the camera reroutes audio and can take the mic
        // tap down with it — same reason Snap pokes the ear twice.
        ChappyStandby.shared.pokeEar(after: 1.5)
        ChappyStandby.shared.pokeEar(after: 5.0)
    }

    /// Edge energy on a 64×64 grayscale: sum of squared neighbour
    /// differences. Motion blur and focus misses flatten edges, so the
    /// sharpest frame wins by a wide margin. Cheap enough for 20 frames.
    nonisolated private static func sharpness(of image: UIImage) -> Double {
        let side = 64
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt)
            .image { _ in image.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
        guard let cg = small.cgImage else { return 0 }
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var energy = 0.0
        for y in 0..<(side - 1) {
            for x in 0..<(side - 1) {
                let i = y * side + x
                let dx = Double(pixels[i]) - Double(pixels[i + 1])
                let dy = Double(pixels[i]) - Double(pixels[i + side])
                energy += dx * dx + dy * dy
            }
        }
        return energy
    }
}

// =====================================================================
// MARK: - THE ATLAS (Build 156)
// =====================================================================
//
//   Every place you have been, drawn as one map, for as long as you keep
//   the app. The design borrows from three places on purpose:
//
//     Google Timeline   — the journey, coloured by how you travelled
//     Polarsteps        — the TRIP as the hero: a glowing line across a
//                         country, not a table of coordinates
//     Apple Maps        — live points of interest that appear as you
//                         zoom, free, no key, tappable
//
//   The data layer lives here; the map itself is AtlasView. Nothing in
//   the Atlas has its own database — visits come from ChappyTrail,
//   stars and photos from ChappyMemory, home from TripRecorder. The
//   Atlas is a WINDOW onto the brain, not a second brain.

@MainActor
final class ChappyAtlas: ObservableObject {

    static let shared = ChappyAtlas()
    private init() {}

    enum Mode: String, Codable {
        case flight, drive, walk
        var tint: Color {
            switch self {
            case .flight: return Color(red: 0.35, green: 0.85, blue: 1.0)
            case .drive:  return Color(red: 0.20, green: 0.90, blue: 0.75)
            case .walk:   return Color(red: 0.55, green: 0.95, blue: 0.45)
            }
        }
        var icon: String {
            switch self {
            case .flight: return "airplane"
            case .drive:  return "car.fill"
            case .walk:   return "figure.walk"
            }
        }
        var label: String {
            switch self {
            case .flight: return "Flight"
            case .drive:  return "Drive"
            case .walk:   return "Walk"
            }
        }
    }

    struct Leg: Identifiable {
        let id = UUID()
        var mode: Mode
        var coords: [CLLocationCoordinate2D]
        var km: Double
        var at: Date
    }

    struct Stop: Identifiable {
        let id: UUID
        var name: String
        var coord: CLLocationCoordinate2D
        var visits: Int
        var lastAt: Date
        var starred: Bool
        var isHome: Bool
        var photos: Int
    }

    enum Span: String, CaseIterable {
        case month = "Month", threeMonths = "3 Months", year = "Year", all = "All time"
        var days: Int {
            switch self {
            case .month: return 31
            case .threeMonths: return 92
            case .year: return 366
            case .all: return 3650
            }
        }
    }

    @Published private(set) var legs: [Leg] = []
    @Published private(set) var stops: [Stop] = []
    @Published private(set) var summary = ""
    @Published private(set) var isBuilding = false

    func build(span: Span) {
        guard !isBuilding else { return }
        isBuilding = true
        let days = span.days
        Task { @MainActor in
            let result = await Self.assemble(days: days)
            self.legs = result.0
            self.stops = result.1
            self.summary = result.2
            self.isBuilding = false
        }
    }

    private static func assemble(days: Int) async -> ([Leg], [Stop], String) {
        var visits: [ChappyTrail.Visit] = []
        var allPoints: [ChappyTrail.Point] = []
        let cal = Calendar.current
        for back in 0..<days {
            guard let d = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let v = ChappyTrail.shared.visits(for: d)
            if v.isEmpty { continue }
            visits.append(contentsOf: v)
            allPoints.append(contentsOf: ChappyTrail.shared.points(for: d))
        }
        visits.sort { $0.arrive < $1.arrive }
        allPoints.sort { $0.at < $1.at }

        // ── STOPS: visits collapsed by proximity, enriched with stars,
        // home and photo counts.
        var stops: [Stop] = []
        let spots = TripRecorder.shared.spots
        let mems = ChappyMemory.shared.recent.filter { $0.lat != nil && $0.lon != nil }
        for v in visits {
            let here = CLLocation(latitude: v.lat, longitude: v.lon)
            if let i = stops.firstIndex(where: {
                here.distance(from: CLLocation(latitude: $0.coord.latitude,
                                               longitude: $0.coord.longitude)) < 300 }) {
                stops[i].visits += 1
                if v.arrive > stops[i].lastAt { stops[i].lastAt = v.arrive }
                if stops[i].name == "Stop", let n = v.name { stops[i].name = n }
                continue
            }
            let spot = spots.first { s in
                here.distance(from: CLLocation(latitude: s.lat, longitude: s.lon)) < 250
            }
            let name = spot?.name ?? v.name ?? "Stop"
            let photos = mems.filter { m in
                guard let la = m.lat, let lo = m.lon else { return false }
                return here.distance(from: CLLocation(latitude: la, longitude: lo)) < 300
                    && (m.kind == .photo || m.kind == .video)
            }.count
            var starred = false
            if let mid = spot?.memID {
                starred = ChappyMemory.shared.recent.first { $0.id == mid }?.pinned ?? false
            }
            let isHome = ["home", "hotel", "my hotel", "the hotel"]
                .contains((spot?.name ?? "").lowercased())
            stops.append(Stop(id: v.id, name: name,
                              coord: CLLocationCoordinate2D(latitude: v.lat, longitude: v.lon),
                              visits: 1, lastAt: v.arrive,
                              starred: starred, isHome: isHome, photos: photos))
        }

        // ── LEGS: consecutive visits become a journey, classified by the
        // speed it took to cover the gap.
        var legs: [Leg] = []
        var totalKm = 0.0
        if visits.count > 1 {
            for i in 1..<visits.count {
                let a = visits[i - 1], b = visits[i]
                let from = CLLocation(latitude: a.lat, longitude: a.lon)
                let to = CLLocation(latitude: b.lat, longitude: b.lon)
                let km = from.distance(from: to) / 1000
                if km <= 0.15 { continue }
                let start = a.depart ?? a.arrive
                let hours = max(b.arrive.timeIntervalSince(start) / 3600, 0.02)
                let kmh = km / hours
                let mode: Mode = (km > 400 || kmh > 200) ? .flight : (kmh > 11 ? .drive : .walk)
                var shape = allPoints.filter { $0.at >= start && $0.at <= b.arrive }
                    .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                if mode == .flight || shape.count < 2 {
                    shape = [from.coordinate, to.coordinate]
                } else {
                    shape.insert(from.coordinate, at: 0)
                    shape.append(to.coordinate)
                }
                legs.append(Leg(mode: mode, coords: shape, km: km, at: b.arrive))
                totalKm += km
            }
        }

        let towns = Set(stops.map { $0.name.lowercased() }).count
        let flights = legs.filter { $0.mode == .flight }.count
        var bits: [String] = []
        bits.append("\(stops.count) stop\(stops.count == 1 ? "" : "s")")
        if towns > 1 { bits.append("\(towns) places") }
        if totalKm >= 1 { bits.append("\(Int(totalKm)) km") }
        if flights > 0 { bits.append("\(flights) flight\(flights == 1 ? "" : "s")") }
        return (legs, stops, bits.joined(separator: " · "))
    }

    /// The region that holds everything — the Atlas opens here, which for
    /// a life lived in two countries means a continent, not a street.
    func homeRegion() -> MKCoordinateRegion {
        let cs = stops.map { $0.coord }
        guard !cs.isEmpty else {
            let s = ContextEngine.shared.snapshot
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: s.latitude ?? -27.47,
                                               longitude: s.longitude ?? 153.02),
                span: MKCoordinateSpan(latitudeDelta: 12, longitudeDelta: 12))
        }
        let lats = cs.map { $0.latitude }, lons = cs.map { $0.longitude }
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 1.5),
                                   longitudeDelta: max((maxLon - minLon) * 1.4, 1.5)))
    }

    // MARK: the live layers

    enum Layer: String, CaseIterable, Identifiable {
        case sights, nature, temples, food, transport, gems
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sights: return "Sights"
            case .nature: return "Nature"
            case .temples: return "Temples"
            case .food: return "Food"
            case .transport: return "Transport"
            case .gems: return "Gems"
            }
        }
        var icon: String {
            switch self {
            case .sights: return "star.circle.fill"
            case .nature: return "leaf.fill"
            case .temples: return "building.columns.fill"
            case .food: return "fork.knife"
            case .transport: return "tram.fill"
            case .gems: return "sparkles"
            }
        }
        var tint: Color {
            switch self {
            case .sights: return .yellow
            case .nature: return .green
            case .temples: return .orange
            case .food: return .pink
            case .transport: return .blue
            case .gems: return .purple
            }
        }
        var queries: [String] {
            switch self {
            case .sights:    return ["tourist attraction", "landmark", "museum"]
            case .nature:    return ["waterfall", "beach", "national park"]
            case .temples:   return ["temple", "church", "shrine"]
            case .food:      return ["restaurant", "cafe", "market"]
            case .transport: return ["train station", "bus station", "airport"]
            // Geocaching.com has no open API, so "Gems" is the honest
            // version: the things worth detouring for that ordinary map
            // searches bury.
            case .gems:      return ["lookout", "viewpoint", "hot spring", "cave"]
            }
        }
    }

    struct Place: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var category: String
        var coord: CLLocationCoordinate2D
        var layer: Layer
        func hash(into h: inout Hasher) { h.combine(id) }
        static func == (a: Place, b: Place) -> Bool { a.id == b.id }
    }

    /// Search the visible region for every switched-on layer. Keyless —
    /// MKLocalSearch is Apple's own data.
    func findPlaces(in region: MKCoordinateRegion, layers: Set<Layer>) async -> [Place] {
        guard !layers.isEmpty else { return [] }
        var out: [Place] = []
        for layer in layers {
            for q in layer.queries {
                let req = MKLocalSearch.Request()
                req.naturalLanguageQuery = q
                req.region = region
                guard let resp = try? await MKLocalSearch(request: req).start() else { continue }
                for item in resp.mapItems.prefix(8) {
                    guard let name = item.name else { continue }
                    let c = item.placemark.coordinate
                    if out.contains(where: {
                        abs($0.coord.latitude - c.latitude) < 0.0006 &&
                        abs($0.coord.longitude - c.longitude) < 0.0006 }) { continue }
                    let cat = item.pointOfInterestCategory?.rawValue
                        .replacingOccurrences(of: "MKPOICategory", with: "") ?? q.capitalized
                    out.append(Place(name: name, category: cat, coord: c, layer: layer))
                }
            }
        }
        return out
    }

    // MARK: weather — free, keyless

    struct Weather {
        var tempC: Double
        var code: Int
        var windKmh: Double
        var line: String { "\(Int(tempC.rounded()))°, \(Weather.describe(code))" }
        var icon: String { Weather.symbol(code) }
        static func describe(_ c: Int) -> String {
            switch c {
            case 0: return "clear"
            case 1, 2: return "partly cloudy"
            case 3: return "overcast"
            case 45, 48: return "fog"
            case 51...57: return "drizzle"
            case 61...67: return "rain"
            case 71...77: return "snow"
            case 80...82: return "showers"
            case 95...99: return "storms"
            default: return "mixed"
            }
        }
        static func symbol(_ c: Int) -> String {
            switch c {
            case 0: return "sun.max.fill"
            case 1, 2: return "cloud.sun.fill"
            case 3: return "cloud.fill"
            case 45, 48: return "cloud.fog.fill"
            case 51...67, 80...82: return "cloud.rain.fill"
            case 71...77: return "cloud.snow.fill"
            case 95...99: return "cloud.bolt.rain.fill"
            default: return "cloud.sun.fill"
            }
        }
    }

    private var wxCache: [String: (Weather, Date)] = [:]

    /// Open-Meteo: no key, no account. Cached six minutes per rough spot.
    func weather(at c: CLLocationCoordinate2D) async -> Weather? {
        let key = String(format: "%.1f,%.1f", c.latitude, c.longitude)
        if let hit = wxCache[key], Date().timeIntervalSince(hit.1) < 360 { return hit.0 }
        guard let url = URL(string:
            "https://api.open-meteo.com/v1/forecast?latitude=\(c.latitude)&longitude=\(c.longitude)&current=temperature_2m,weather_code,wind_speed_10m")
        else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = json["current"] as? [String: Any],
              let t = cur["temperature_2m"] as? Double else { return nil }
        let w = Weather(tempC: t,
                        code: (cur["weather_code"] as? Int) ?? 0,
                        windKmh: (cur["wind_speed_10m"] as? Double) ?? 0)
        wxCache[key] = (w, Date())
        return w
    }

    /// Zoom Earth — live satellite, radar and storm tracks. A link, not a
    /// scrape: their site does it better than any embed could.
    static func zoomEarthURL(_ c: CLLocationCoordinate2D, zoom: Int = 8) -> URL? {
        URL(string: String(format: "https://zoom.earth/maps/satellite/#view=%.4f,%.4f,%dz",
                           c.latitude, c.longitude, zoom))
    }

    // MARK: voice bridge

    static func voiceTarget(in c: String) -> String? {
        for cut in ["zoom to ", "zoom in on ", "take the atlas to ", "atlas to ",
                    "fly to ", "centre on ", "center on "] {
            if let r = c.range(of: cut) {
                let t = String(c[r.upperBound...])
                    .replacingOccurrences(of: "on the map", with: "")
                    .replacingOccurrences(of: "in the atlas", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
                if t.count > 1 { return t }
            }
        }
        return nil
    }

    static func layerMentioned(in c: String) -> Layer? {
        if c.contains("temple") || c.contains("church") || c.contains("shrine") { return .temples }
        if c.contains("waterfall") || c.contains("beach") || c.contains("nature")
            || c.contains("national park") { return .nature }
        if c.contains("sight") || c.contains("attraction") || c.contains("landmark")
            || c.contains("museum") { return .sights }
        if c.contains("restaurant") || c.contains("cafe") { return .food }
        if c.contains("train") || c.contains("bus station") || c.contains("transport") { return .transport }
        if c.contains("lookout") || c.contains("viewpoint") || c.contains("gem")
            || c.contains("hidden") { return .gems }
        return nil
    }
}

extension Notification.Name {
    /// BUILD 156 — open the Atlas, optionally already flying somewhere.
    static let chappyOpenAtlas = Notification.Name("chappyOpenAtlas")
}

// =====================================================================
// MARK: - CHAPPY DICTATE (Build 157)
// =====================================================================
//
//   Speak a mess, get clean text on the clipboard. Every serious player
//   converged on this in 2024-25 and they all landed in the same place:
//
//     Apple Writing Tools  — Proofread / Rewrite, with TONES
//     Samsung Note Assist  — transcribe, then REFORMAT into templates
//     Google (Gboard/Pixel)— polish and proofread on device
//     Wispr Flow, Superwhisper — the whole point is speak → paste
//
//   So the flow is: talk → raw transcript kept forever → Gemini cleans
//   it into the tone you pick → Copy / Share / Save. The RAW words are
//   never thrown away, because a polish that loses a detail is worse
//   than no polish at all.
//
//   The transcription itself is Apple's on-device recogniser, the same
//   ear Standby already uses — so the words cost nothing and never
//   leave the phone until you ask for the polish.

@MainActor
final class ChappyDictate: NSObject, ObservableObject {

    static let shared = ChappyDictate()
    private override init() { super.init() }

    enum Tone: String, CaseIterable, Identifiable {
        case professional, jobReport, email, brief, bullets, plain
        // BUILD 168 — the document styles. Rewriting something you've
        // scanned is a different job from tidying something you said.
        case reword, simplify, letter, summary
        var id: String { rawValue }
        var label: String {
            switch self {
            case .professional: return "Professional"
            case .jobReport:    return "Job Report"
            case .email:        return "Email"
            case .brief:        return "Brief"
            case .bullets:      return "Bullets"
            case .plain:        return "Plain"
            case .reword:       return "Reword"
            case .simplify:     return "Plain English"
            case .letter:       return "Formal letter"
            case .summary:      return "Summary"
            }
        }
        var icon: String {
            switch self {
            case .professional: return "briefcase.fill"
            case .jobReport:    return "wrench.and.screwdriver.fill"
            case .email:        return "envelope.fill"
            case .brief:        return "bolt.fill"
            case .bullets:      return "list.bullet"
            case .plain:        return "text.alignleft"
            case .reword:       return "arrow.triangle.2.circlepath"
            case .simplify:     return "textformat.size.smaller"
            case .letter:       return "doc.richtext"
            case .summary:      return "text.line.first.and.arrowtriangle.forward"
            }
        }
        var tint: Color {
            switch self {
            case .professional: return .blue
            case .jobReport:    return .orange
            case .email:        return .purple
            case .brief:        return .green
            case .bullets:      return .teal
            case .plain:        return .gray
            case .reword:       return .indigo
            case .simplify:     return .mint
            case .letter:       return .brown
            case .summary:      return .cyan
            }
        }
        /// The instruction. Deliberately strict about INVENTING: a report
        /// that adds a fact you didn't say is a liability, not a feature.
        var prompt: String {
            let rule = "Never invent facts, names, numbers or outcomes that are not in the transcript. If something is unclear, keep it vague rather than guessing. Fix grammar, remove filler and false starts, and keep every real detail. Output only the finished text - no preamble, no notes, no markdown headers."
            switch self {
            case .professional:
                return "Rewrite this dictation as clear, professional prose suitable for a work document. \(rule)"
            case .jobReport:
                return """
                Rewrite this dictation as a structured job report using exactly these labelled sections, each on its own line, omitting any section the transcript does not cover:
                Reported issue:
                Findings:
                Work performed:
                Outcome:
                Parts / time:
                Follow-up:
                \(rule)
                """
            case .email:
                return "Rewrite this dictation as a polite, concise email body. No subject line, no greeting placeholder like [Name] - start with a natural greeting only if the transcript implies one. \(rule)"
            case .brief:
                return "Rewrite this dictation as tightly as possible - the same information in as few clear sentences as it takes. \(rule)"
            case .bullets:
                return "Rewrite this dictation as a bulleted list, one point per line starting with a dash. \(rule)"
            case .plain:
                return "Clean up this dictation: fix grammar and punctuation, remove filler words and false starts, keep the speaker's own voice and wording otherwise. \(rule)"
            // BUILD 168 — document rewriting. Note these say TEXT, not
            // dictation: they're used on scanned documents as often as
            // on speech, and the instruction has to fit both.
            case .reword:
                return "Rewrite this text completely in your own words. Change the sentence structure and vocabulary throughout so it does not read like the original, while keeping every fact, figure, name and instruction exactly as given. Keep roughly the same length. \(rule)"
            case .simplify:
                return "Rewrite this text in plain English a busy person can read once and act on. Short sentences. No jargon, and if a technical term is unavoidable, say what it means. Keep every fact and number. \(rule)"
            case .letter:
                return "Rewrite this text as a formal letter body: measured, courteous and businesslike. No address block, no date line, no signature - just the body paragraphs. \(rule)"
            case .summary:
                return "Summarise this text: the key points only, as short paragraphs or bullets, in the order they matter. Keep every figure, date, name and deadline. Say what it is asking of the reader, if anything. \(rule)"
            }
        }
    }

    @Published var isRecording = false
    @Published var transcript = ""
    @Published var polished = ""
    @Published var isPolishing = false
    @Published var tone: Tone = .professional
    @Published var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    // MARK: recording

    func start() {
        guard !isRecording else { return }
        error = nil
        transcript = ""
        polished = ""

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard status == .authorized else {
                    self?.error = "Speech recognition isn't allowed — Settings, Chappy, Speech Recognition."
                    return
                }
                self?.beginEngine()
            }
        }
    }

    private func beginEngine() {
        // Hand the microphone over cleanly — Standby must not be holding it.
        if ChappyStandby.shared.isListening { ChappyStandby.shared.handOff() }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // On-device where the phone supports it: the words never leave.
        if recognizer?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true
        }
        request = req

        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            error = "The microphone wasn't ready — try again in a second."
            return
        }
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            self.error = "Couldn't start the microphone."
            return
        }
        isRecording = true
        ChappyEarcon.shared.tap()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self else { return }
                if let r = result {
                    self.transcript = r.bestTranscription.formattedString
                }
                if err != nil || (result?.isFinal ?? false) {
                    if self.isRecording { self.stop(andPolish: true) }
                }
            }
        }
    }

    func stop(andPolish: Bool) {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        ChappyEarcon.shared.done()
        // Give Standby its ear back.
        ChappyStandby.shared.resumeAfterHandOff()
        if andPolish, transcript.count > 3 {
            Task { await polish() }
        }
    }

    /// BUILD 168 — feed the polisher something you didn't say out loud.
    /// A scanned page, a pasted block, the last thing Reader read. The
    /// original goes into `transcript` exactly as before, so "what you
    /// actually said" becomes "what the page actually said" and nothing
    /// is ever lost behind the rewrite.
    func load(text: String, tone newTone: Tone = .reword) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if isRecording { stop(andPolish: false) }
        transcript = t
        polished = ""
        error = nil
        tone = newTone
        Task { await polish() }
    }

    // MARK: the polish

    func polish() async {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count > 3 else { return }
        isPolishing = true
        defer { isPolishing = false }

        guard let key = APIKeyManager.shared.getGoogleAPIKey(), !key.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=\(key)")
        else {
            // No key, no drama: cleaned-up-by-hand is better than nothing.
            polished = Self.localTidy(raw)
            error = "Polished offline — no API key for the full rewrite."
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [["text": "\(tone.prompt)\n\nTRANSCRIPT:\n\(raw)"]]]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 1400]
        ] as [String: Any])

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = json["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let t = parts.first?["text"] as? String
        else {
            polished = Self.localTidy(raw)
            error = "Couldn't reach the rewriter — here's the tidied transcript."
            return
        }
        polished = t.trimmingCharacters(in: .whitespacesAndNewlines)
        error = nil
    }

    /// The offline fallback: capitalise sentences, strip the ums. Not
    /// clever, but it never leaves you with nothing.
    static func localTidy(_ s: String) -> String {
        var t = s
        for filler in [" um ", " uh ", " erm ", " you know ", " like, "] {
            t = t.replacingOccurrences(of: filler, with: " ", options: .caseInsensitive)
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return t }
        t = String(first).uppercased() + t.dropFirst()
        if !t.hasSuffix(".") && !t.hasSuffix("!") && !t.hasSuffix("?") { t += "." }
        return t
    }

    // MARK: keeping it

    func copyToClipboard() {
        UIPasteboard.general.string = polished.isEmpty ? transcript : polished
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Files it in memory AND writes a .txt you can open from Files.
    @discardableResult
    func save() -> URL? {
        let text = polished.isEmpty ? transcript : polished
        guard !text.isEmpty else { return nil }
        let title = String(text.split(separator: "\n").first?.prefix(60) ?? "Dictated note")
        _ = ChappyMemory.shared.remember(.note,
            title: String(title),
            body: text + (transcript == text ? "" : "\n\n— raw —\n" + transcript),
            tags: ["dictation", tone.rawValue],
            source: "dictate")

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "Chappy-\(tone.rawValue)-\(df.string(from: Date())).txt"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return url
    }
}

extension Notification.Name {
    /// BUILD 157 — open Dictate, already recording.
    static let chappyOpenDictate = Notification.Name("chappyOpenDictate")
    /// BUILD 173 — the weather station and the brief studio.
    static let chappyOpenWeather = Notification.Name("chappyOpenWeather")
    static let chappyOpenBriefs = Notification.Name("chappyOpenBriefs")
    /// BUILD 172 — open the notification diagnostic screen.
    static let chappyOpenNotifDoctor = Notification.Name("chappyOpenNotifDoctor")
    /// BUILD 170 — the panic button: close every sheet and cover and go
    /// back to the home screen.
    static let chappyCloseEverything = Notification.Name("chappyCloseEverything")
    /// BUILD 168 — open Dictate WITHOUT starting the microphone, because
    /// the text is already loaded.
    static let chappyOpenDictateQuiet = Notification.Name("chappyOpenDictateQuiet")
    /// BUILD 158 — open the saved-places list.
    static let chappyOpenPlaces = Notification.Name("chappyOpenPlaces")
    /// BUILD 163 — open the 30-day Upcoming view.
    static let chappyOpenUpcoming = Notification.Name("chappyOpenUpcoming")
}

// =====================================================================
// MARK: - CHAPPY WEATHER STATION (Build 173)
// =====================================================================
//
//   There has never been a weather screen. Weather existed only as a
//   single line inside the daily brief and a bubble on the Atlas — so
//   asking "where's the weather module" was a fair question with an
//   awkward answer. This is the real thing.
//
//   Open-Meteo, which is free, needs no key and no account, and gives
//   the full instrument panel: temperature and what it feels like,
//   humidity, dew point, pressure, wind speed, direction and gusts,
//   rain now and rain probability, cloud cover, visibility, UV, and
//   sunrise/sunset — plus 24 hours ahead and 7 days ahead in one call.
//
//   Located wherever you are, or anywhere you name. Every number is
//   speakable, because reading a dashboard is not the point when the
//   phone is in your pocket.

@MainActor
final class ChappyWeather: ObservableObject {

    static let shared = ChappyWeather()
    private init() {}

    struct Now {
        var tempC = 0.0
        var feelsC = 0.0
        var humidity = 0
        var dewC = 0.0
        var pressure = 0.0
        var windKmh = 0.0
        var gustKmh = 0.0
        var windDeg = 0
        var rainMm = 0.0
        var cloudPct = 0
        var visibilityM = 0.0
        var uv = 0.0
        var code = 0
        var isDay = true
    }

    struct Hour: Identifiable {
        var id: Int { Int(at.timeIntervalSince1970) }
        var at: Date
        var tempC: Double
        var rainChance: Int
        var code: Int
    }

    struct Day: Identifiable {
        var id: Int { Int(at.timeIntervalSince1970) }
        var at: Date
        var maxC: Double
        var minC: Double
        var rainChance: Int
        var rainMm: Double
        var code: Int
        var sunrise: Date?
        var sunset: Date?
        var uvMax: Double
        var windMaxKmh: Double
    }

    @Published private(set) var placeName = ""
    @Published private(set) var now: Now?
    @Published private(set) var hours: [Hour] = []
    @Published private(set) var days: [Day] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var coord: CLLocationCoordinate2D?
    @Published private(set) var fetchedAt: Date?

    // MARK: fetching

    /// Where you are right now.
    func loadHere() async {
        let snap = ContextEngine.shared.snapshot
        guard let la = snap.latitude, let lo = snap.longitude else {
            error = "No GPS fix yet — give it a few seconds outside."
            return
        }
        let name = [snap.city, snap.country].compactMap { $0 }.joined(separator: ", ")
        await load(lat: la, lon: lo, name: name.isEmpty ? "Where you are" : name)
    }

    /// Anywhere you can name. Apple's geocoder, so no key and no quota.
    func loadPlace(_ query: String) async {
        loading = true
        defer { loading = false }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        guard let resp = try? await MKLocalSearch(request: req).start(),
              let hit = resp.mapItems.first else {
            error = "Couldn't find \(query)."
            return
        }
        let c = hit.placemark.coordinate
        let nm = hit.placemark.locality ?? hit.name ?? query
        await load(lat: c.latitude, lon: c.longitude, name: nm)
    }

    func load(lat: Double, lon: Double, name: String) async {
        loading = true
        error = nil
        defer { loading = false }
        placeName = name
        coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)

        let current = "temperature_2m,relative_humidity_2m,apparent_temperature,is_day," +
                      "precipitation,rain,weather_code,cloud_cover,pressure_msl," +
                      "wind_speed_10m,wind_direction_10m,wind_gusts_10m,visibility,dew_point_2m,uv_index"
        let hourly  = "temperature_2m,precipitation_probability,weather_code"
        let daily   = "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset," +
                      "uv_index_max,precipitation_sum,precipitation_probability_max,wind_speed_10m_max"
        guard let url = URL(string:
            "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)" +
            "&current=\(current)&hourly=\(hourly)&daily=\(daily)" +
            "&timezone=auto&forecast_days=7")
        else { error = "Bad request."; return }

        var req = URLRequest(url: url); req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { error = "Couldn't reach the weather service."; return }

        if let c = json["current"] as? [String: Any] {
            var n = Now()
            n.tempC       = c["temperature_2m"] as? Double ?? 0
            n.feelsC      = c["apparent_temperature"] as? Double ?? n.tempC
            n.humidity    = c["relative_humidity_2m"] as? Int ?? 0
            n.dewC        = c["dew_point_2m"] as? Double ?? 0
            n.pressure    = c["pressure_msl"] as? Double ?? 0
            n.windKmh     = c["wind_speed_10m"] as? Double ?? 0
            n.gustKmh     = c["wind_gusts_10m"] as? Double ?? 0
            n.windDeg     = c["wind_direction_10m"] as? Int ?? 0
            n.rainMm      = c["precipitation"] as? Double ?? 0
            n.cloudPct    = c["cloud_cover"] as? Int ?? 0
            n.visibilityM = c["visibility"] as? Double ?? 0
            n.uv          = c["uv_index"] as? Double ?? 0
            n.code        = c["weather_code"] as? Int ?? 0
            n.isDay       = (c["is_day"] as? Int ?? 1) == 1
            now = n
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        func parse(_ s: String) -> Date? {
            iso.date(from: s) ?? {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd'T'HH:mm"
                f.timeZone = TimeZone.current
                return f.date(from: s)
            }()
        }

        if let h = json["hourly"] as? [String: Any],
           let times = h["time"] as? [String] {
            let temps = h["temperature_2m"] as? [Double] ?? []
            let probs = h["precipitation_probability"] as? [Int] ?? []
            let codes = h["weather_code"] as? [Int] ?? []
            var out: [Hour] = []
            for (i, t) in times.enumerated() {
                guard let d = parse(t), d >= Date().addingTimeInterval(-3600) else { continue }
                out.append(Hour(at: d,
                                tempC: i < temps.count ? temps[i] : 0,
                                rainChance: i < probs.count ? probs[i] : 0,
                                code: i < codes.count ? codes[i] : 0))
                if out.count >= 24 { break }
            }
            hours = out
        }

        if let dd = json["daily"] as? [String: Any],
           let times = dd["time"] as? [String] {
            let maxs  = dd["temperature_2m_max"] as? [Double] ?? []
            let mins  = dd["temperature_2m_min"] as? [Double] ?? []
            let codes = dd["weather_code"] as? [Int] ?? []
            let sr    = dd["sunrise"] as? [String] ?? []
            let ss    = dd["sunset"] as? [String] ?? []
            let uvs   = dd["uv_index_max"] as? [Double] ?? []
            let sums  = dd["precipitation_sum"] as? [Double] ?? []
            let probs = dd["precipitation_probability_max"] as? [Int] ?? []
            let winds = dd["wind_speed_10m_max"] as? [Double] ?? []
            var out: [Day] = []
            let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
            for (i, t) in times.enumerated() {
                guard let d = dayFmt.date(from: t) else { continue }
                out.append(Day(at: d,
                               maxC: i < maxs.count ? maxs[i] : 0,
                               minC: i < mins.count ? mins[i] : 0,
                               rainChance: i < probs.count ? probs[i] : 0,
                               rainMm: i < sums.count ? sums[i] : 0,
                               code: i < codes.count ? codes[i] : 0,
                               sunrise: i < sr.count ? parse(sr[i]) : nil,
                               sunset: i < ss.count ? parse(ss[i]) : nil,
                               uvMax: i < uvs.count ? uvs[i] : 0,
                               windMaxKmh: i < winds.count ? winds[i] : 0))
            }
            days = out
        }
        fetchedAt = Date()
    }

    // MARK: saying it

    /// The everyday answer: what it's doing now and whether to take a coat.
    func spokenNow() -> String {
        guard let n = now else { return "No weather loaded yet." }
        var bits = ["\(Int(n.tempC.rounded())) degrees in \(placeName), \(Self.describe(n.code))"]
        if abs(n.feelsC - n.tempC) >= 2 {
            bits.append("feels like \(Int(n.feelsC.rounded()))")
        }
        if n.windKmh >= 15 {
            bits.append("wind \(Int(n.windKmh)) k m h from the \(Self.compass(n.windDeg))")
        }
        if n.gustKmh >= 40 { bits.append("gusting \(Int(n.gustKmh))") }
        if let today = days.first, today.rainChance >= 20 {
            bits.append("\(today.rainChance) percent chance of rain today")
        }
        if n.uv >= 6 { bits.append("U V index \(Int(n.uv.rounded())) - hat weather") }
        return bits.joined(separator: ", ") + "."
    }

    /// Every instrument, for when you actually want the lot.
    func spokenFull() -> String {
        guard let n = now else { return "No weather loaded yet." }
        var s = spokenNow()
        s += " Humidity \(n.humidity) percent, dew point \(Int(n.dewC.rounded()))."
        s += " Pressure \(Int(n.pressure.rounded())) hectopascals."
        s += " Cloud cover \(n.cloudPct) percent."
        if n.visibilityM > 0 {
            s += " Visibility \(n.visibilityM >= 1000 ? "\(Int(n.visibilityM / 1000)) kilometres" : "\(Int(n.visibilityM)) metres")."
        }
        if n.rainMm > 0 { s += " \(String(format: "%.1f", n.rainMm)) millimetres falling now." }
        if let d = days.first {
            s += " Today \(Int(d.minC.rounded())) to \(Int(d.maxC.rounded()))."
            if let sr = d.sunrise, let ss = d.sunset {
                let f = DateFormatter(); f.dateFormat = "h:mm a"
                s += " Sunrise \(f.string(from: sr)), sunset \(f.string(from: ss))."
            }
        }
        return s
    }

    /// The week, in one breath.
    func spokenWeek() -> String {
        guard !days.isEmpty else { return "No forecast loaded yet." }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        let lines = days.prefix(5).enumerated().map { i, d -> String in
            let name = i == 0 ? "Today" : (i == 1 ? "Tomorrow" : f.string(from: d.at))
            var s = "\(name), \(Int(d.minC.rounded())) to \(Int(d.maxC.rounded())), \(Self.describe(d.code))"
            if d.rainChance >= 30 { s += ", \(d.rainChance) percent rain" }
            return s
        }
        return lines.joined(separator: ". ") + "."
    }

    /// "Will it rain?" answered properly — when, and how likely.
    func spokenRain() -> String {
        guard !hours.isEmpty else { return "No forecast loaded yet." }
        let wet = hours.prefix(12).filter { $0.rainChance >= 40 }
        guard let first = wet.first else {
            let peak = hours.prefix(12).map { $0.rainChance }.max() ?? 0
            return peak < 15
                ? "No rain coming in the next twelve hours."
                : "Nothing likely - the highest chance in the next twelve hours is \(peak) percent."
        }
        let f = DateFormatter(); f.dateFormat = "h a"
        return "Rain likely from about \(f.string(from: first.at)), \(first.rainChance) percent. \(wet.count) of the next twelve hours look wet."
    }

    // MARK: shared vocabulary

    static func describe(_ c: Int) -> String {
        switch c {
        case 0: return "clear"
        case 1: return "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61: return "light rain"
        case 63: return "rain"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71, 73, 75, 77: return "snow"
        case 80, 81: return "showers"
        case 82: return "heavy showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorms"
        case 96, 99: return "thunderstorms with hail"
        default: return "mixed"
        }
    }

    static func symbol(_ c: Int, day: Bool = true) -> String {
        switch c {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.sun.fill"
        }
    }

    static func compass(_ deg: Int) -> String {
        let dirs = ["north", "north-east", "east", "south-east",
                    "south", "south-west", "west", "north-west"]
        let i = Int((Double(deg) / 45.0).rounded()) % 8
        return dirs[max(0, i)]
    }

    static func uvWord(_ uv: Double) -> String {
        switch uv {
        case ..<3: return "low"
        case ..<6: return "moderate"
        case ..<8: return "high"
        case ..<11: return "very high"
        default: return "extreme"
        }
    }
}
