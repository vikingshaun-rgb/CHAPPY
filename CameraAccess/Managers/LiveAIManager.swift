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
    }

    func wake() { play(wakeURL) }
    func done() { play(doneURL) }
    func fail() { play(failURL) }
    /// The button click. Deliberately the shortest and quietest of the four —
    /// a tap is an acknowledgement, not an announcement. Its whole job is to
    /// close the loop when the screen gives you nothing: you pressed Remember,
    /// something happened, you did not have to look.
    func tap() { play(tapURL) }

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
        // MIC HANDOFF: Standby's local ear must let go before the deep layer
        // takes the microphone — two recognizers cannot share one input node.
        if ChappyStandby.shared.isListening {
            // AUDIT FIX (LA-H9): handOff() so stopSession()'s
            // resumeAfterHandOff() actually re-arms the wake word.
            ChappyStandby.shared.handOff()
            try? await Task.sleep(nanoseconds: 300_000_000)
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

                // Wait for the stream to reach streaming state (max 5 s)
                let streamReady = await waitForCondition(timeout: 5.0) {
                    streamViewModel.streamingStatus == .streaming
                }

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
            let connected = await waitForCondition(timeout: 10.0) {
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

            print("✅ [LiveAIManager] Live AI session started, ready to talk")

        } catch let error as LiveAIError {
            errorMessage = error.localizedDescription
            print("❌ [LiveAIManager] LiveAIError: \(error)")
            await stopSession()
        } catch {
            errorMessage = error.localizedDescription
            print("❌ [LiveAIManager] Error: \(error)")
            await stopSession()
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
    private var awake = false
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
            guard Date().timeIntervalSince(lastBufferAt) > 10 else { return }
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

        guard startRecognition() else { starting = false; return }
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
        if Date().timeIntervalSince(lastBufferAt) > 10 {
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
                    print("🧹 [Standby] Flushing the ear after Chappy's own voice")
                    self.resetRecognition()
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
        ChappyEarcon.shared.wake()

        let bare = tail.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-")).isEmpty
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
        ChappyEarcon.shared.tap()
        guard let vm = LiveAIManager.shared.streamViewModel,
              let frame = vm.currentVideoFrame else {
            NotificationCenter.default.post(name: .chappyWakeCameraForSnap, object: nil)
            return
        }
        completeSilentSnap(frame)
    }

    func completeSilentSnap(_ frame: UIImage) {
        ChappyHaptics.shared.shutter()
        let thumb = frame.jpegData(compressionQuality: 0.4)
        // Store it immediately with a placeholder — the photo must never be lost
        // waiting on a network call that might not come back.
        let note = TripRecorder.shared.addVisualNote(caption: "Photo", thumbnail: thumb)
        Task { @MainActor in
            if let caption = await Self.describe(frame) {
                TripRecorder.shared.updateCaption(id: note.id, to: caption)
            }
        }
        // A tone, not a sentence. The whole point is that it doesn't talk.
        ChappyEarcon.shared.done()
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
            || now < expectingMapsAnswerUntil
    }

    func closeAllPrompts() {
        expectingLanguageUntil = .distantPast
        expectingNavModeUntil = .distantPast
        expectingSpotNameUntil = .distantPast
        expectingDestinationUntil = .distantPast
        expectingMapsAnswerUntil = .distantPast
        pendingNavDestination = nil
    }

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
            ChappyEarcon.shared.done()
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
        let seps = [" and then ", " then ", " and also ", " and "]
        for sep in seps {
            guard let r = text.range(of: sep) else { continue }
            let a = String(text[text.startIndex..<r.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            let b = String(text[r.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
            guard a.count > 2, b.count > 2,
                  looksLikeCommand(a), looksLikeCommand(b) else { continue }
            return [a, b]
        }
        return [text]
    }

    /// Cheap test: does this half start with something imperative?
    private static func looksLikeCommand(_ t: String) -> Bool {
        let verbs = ["navigate", "take", "get", "go", "walk", "drive", "find",
                     "remember", "save", "pin", "mark", "translate", "snap",
                     "photo", "look", "watch", "show", "open", "map", "log",
                     "note", "stop", "call", "head", "bring"]
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
        ChappyEarcon.shared.done()
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
            ChappyEarcon.shared.fail()
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
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renew() }
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
            }
            return // never route while he's mid-answer
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

                // BUILD 90: answering "Want turn by turn in Google Maps?"
                if Date() < expectingMapsAnswerUntil, text.count > 1 {
                    expectingMapsAnswerUntil = .distantPast
                    let yes = ["yes", "yeah", "yep", "sure", "please", "ok", "okay",
                               "go on", "do it", "open"].contains { text.contains($0) }
                    if yes {
                        ChappyEarcon.shared.done()
                        NotificationCenter.default.post(name: .chappyOpenGoogleMaps, object: nil)
                    } else {
                        TTSService.shared.speak("No worries.")
                    }
                    resetRecognition()
                    return
                }
                // BUILD 87: answering "Which language?" — no wake word needed.
                if Date() < expectingLanguageUntil, text.count > 1 {
                    if let code = Self.languageCode(spokenIn: text) {
                        expectingLanguageUntil = .distantPast
                        beginTranslate(code: code)
                    } else {
                        ChappyEarcon.shared.fail()
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
                        let reply = await NavEngine.shared.navigate(to: dest, driving: drive)
                        self.speak(NavEngine.shared.spokenRouteSummary ?? reply)
                        // BUILD 104: the direct path offered the map; THIS path
                        // — the one you land on whenever you didn't say how you
                        // were travelling, which is most of the time — did not.
                        // So the hands-free "want the map? yes" never happened.
                        if NavEngine.shared.isNavigating {
                            self.offerGoogleMaps(driving: drive)
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
                        ChappyEarcon.shared.done()
                        ChappyHaptics.shared.straightStep()
                        TTSService.shared.speak("Saved as \(cleaned).")
                    } else {
                        ChappyEarcon.shared.fail()
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
            debounce = ["translate", "navigate", "go", "map to"].contains(cleanTail) ? 0.75 : 0.45
        } else {
            let wordCount = snapshot.split(separator: " ").count
            debounce = wordCount <= 3 ? 0.6 : (wordCount <= 6 ? 0.85 : 1.1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
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
            ChappyEarcon.shared.fail()
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
        if ["close", "close it", "exit", "go back", "done", "finish", "that's it",
            "thats it", "close live", "stop live", "close live ai", "end it",
            "shut it down", "close translate", "close this"].contains(where: { c == $0 || c.hasPrefix($0 + " ") }) {
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
        if after(c, ["take a photo", "take a picture", "take a shot", "get a shot",
                     "snap a photo", "snap that", "snap this", "capture this",
                     "capture that", "photo quick"]) != nil
            || c == "photo" || c == "take photo" {
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
                ChappyEarcon.shared.fail()
                speak("Saved it, though GPS hasn't settled - it may be a little off.")
            } else {
                ChappyEarcon.shared.done()
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
        // ---------- PHASE 5.5 — REMINDERS (free, offline, instant) ----------
        if Self.looksLikeReminder(c), let p = Self.parseReminder(c) {
            let r = ChappyReminders.shared.add(
                title: p.title, at: p.date, floatingTime: p.floating,
                place: p.place, repeatRule: p.rule, leadMinutes: p.lead,
                escalate: p.escalate,
                thumbnail: LiveAIManager.shared.streamViewModel?.currentVideoFrame?
                    .jpegData(compressionQuality: 0.4))
            ChappyEarcon.shared.done()
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
                ChappyEarcon.shared.done()
                speak("Done: \(t.title).")
            } else {
                ChappyEarcon.shared.fail()
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
        if c.contains("open reminders") || c.contains("show my reminders")
            || c.contains("show reminders") || c.contains("open my list") {
            NotificationCenter.default.post(name: .chappyOpenReminders, object: nil)
            ChappyEarcon.shared.done()
            speak("Here's your list."); return
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
                ChappyEarcon.shared.done()
                speak(answer)
            } else {
                ChappyEarcon.shared.fail()
                speak("Nothing stored about \(subject) yet.")
            }
            return
        }
        if c.contains("open memory") || c.contains("open my memory")
            || c.contains("show my memories") || c.contains("show me my memories")
            || c.contains("open the memory") || c.contains("memory browser")
            || c.contains("show my memory") {
            NotificationCenter.default.post(name: .chappyOpenMemory, object: nil)
            ChappyEarcon.shared.done()
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
        if c.contains("where was i") || c.contains("where have i been") || c.contains("what did i do today") {
            speak(TripRecorder.shared.todaySummary()); return
        }
        if c.contains("trace my steps") || c.contains("retrace") || c.contains("way i came") {
            speak(TripRecorder.shared.retraceGuidance()); return
        }
        if c.contains("i'm lost") || c.contains("im lost") || c.contains("i am lost") {
            speak(TripRecorder.shared.lostReport()); return
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
        if c.contains("let's talk") || c.contains("lets talk") || c.contains("start live")
            || c.contains("eyes on") || c.contains("come with me") || c.contains("watch with me") {
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
            ChappyEarcon.shared.done()
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
            // BUILD 87: if he didn't say HOW, ask — walking and driving routes
            // to the same place are completely different journeys, and guessing
            // walking for an airport run is how you get a 140-minute route.
            // Only asked when genuinely unknown: "walk me to" already said it.
            let modeStated = driving
                || ["walk", "on foot", "walking", "stroll"].contains { c.contains($0) }
            guard modeStated else { askForNavMode(destination: dest); return }
            speak("Finding \(dest).")
            let reply = await NavEngine.shared.navigate(to: dest, driving: driving)
            // Human ears get the human string; the model-directed one is for
            // Live AI only. See AUDIT FIX (SPOKEN-LEAK) in NavEngine.navigate.
            speak(NavEngine.shared.spokenRouteSummary ?? reply)
            if NavEngine.shared.isNavigating { offerGoogleMaps(driving: driving) }
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
            speak(NavEngine.shared.spokenRouteSummary ?? reply); return
        }
        if c.contains("open google maps") || c.contains("open maps") {
            NotificationCenter.default.post(name: .chappyOpenGoogleMaps, object: nil)
            speak("Opening Google Maps."); return
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
        if (c.hasPrefix("read th") || c.hasPrefix("read it") || c.contains("read this sign") || c.contains("read that sign") || c.contains("read the menu")) || c.contains("read it") || c.contains("read me")
            || c.contains("what does this say") || c.contains("what does that say")
            || (c.contains("what does") && c.contains("say")) {
            speak("Reading that now.")
            QuickVisionManager.shared.triggerQuickVision(customPrompt:
                "Read ALL visible text in this image aloud, verbatim and in order. If it is in another language, read it then translate it. No commentary.")
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
        if let intent = await ChappyIntent.classify(c), intent.action != "ask" {
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
                    speak(NavEngine.shared.spokenRouteSummary ?? reply); return
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
        expectingMapsAnswerUntil = Date().addingTimeInterval(10)
        if !isListening { silentArm = true; start() }
        TTSService.shared.speak(driving
            ? "Want turn by turn in Google Maps?"
            : "Want me to open it in Google Maps?")
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
                ChappyEarcon.shared.fail()
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
                    ChappyEarcon.shared.fail()
                    speak("Saved it, though GPS hasn't settled - it may be a little off.")
                } else {
                    ChappyEarcon.shared.done()
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
            UIApplication.shared.open(u)
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
            ChappyEarcon.shared.fail()
        } else {
            // Rotated so the second miss doesn't sound like a stuck record —
            // the moment a wearer notices the identical phrasing twice is the
            // moment the thing stops feeling like a companion.
            ChappyEarcon.shared.fail()
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
        }
        // PHASE 4 STEP 5: and the navigator (speaks turns when close)
        Task { @MainActor in NavEngine.shared.updateLocation(loc) }
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
        guard let destination = dest else {
            return "Could not find '\(query)' nearby. Ask the user to try a different name."
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
            TTSService.shared.speak(line)
        }
    }

    /// PHASE 5.5 — how long it would actually take to get there, for leave-by
    /// warnings. Deliberately does not start navigation or touch any state;
    /// it is a question, not a command.
    func travelMinutes(to query: String, driving: Bool = true) async -> Int? {
        let snap = ContextEngine.shared.snapshot
        guard let lat = snap.latitude, let lon = snap.longitude, !query.isEmpty else { return nil }
        var dest: CLLocationCoordinate2D?
        let q = query.lowercased()
        if let spot = TripRecorder.shared.spots.last(where: {
            q.contains($0.name.lowercased()) || $0.name.lowercased().contains(q) }) {
            dest = CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lon)
        }
        if dest == nil, let found = await placesSearch(query: query, lat: lat, lon: lon) {
            dest = found.0
        }
        guard let d = dest else { return nil }
        var routed = await googleRoute(fromLat: lat, fromLon: lon, to: d, driving: driving)
        if routed == nil { routed = await mapKitRoute(fromLat: lat, fromLon: lon, to: d, driving: driving) }
        guard let r = routed else { return nil }
        return max(1, Int(r.durationSec / 60))
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
            ChappyEarcon.shared.done()
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
            ChappyEarcon.shared.done()
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
        guard !TTSService.shared.isSpeaking else { return }
        let ready = due().filter { $0.deliveredAt == nil }
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

    func briefText() -> String {
        var parts: [String] = []
        let name = UserDefaults.standard.string(forKey: "chappy_user_name") ?? ""
        let df = DateFormatter(); df.dateFormat = "h:mm a"

        let od = overdue()
        let t = today().filter { $0.deliveredAt == nil }
        if od.isEmpty && t.isEmpty {
            parts.append(name.isEmpty ? "Morning. Nothing on today."
                                      : "Morning \(name). Nothing on today.")
        } else {
            parts.append(name.isEmpty ? "Morning." : "Morning \(name).")
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

    private var activeCalendars: [EKCalendar]? {
        let on = allCalendars.filter(isOn)
        return on.isEmpty ? nil : on
    }

    // MARK: Reading

    func events(from: Date, to: Date) -> [EKEvent] {
        guard authorised else { return [] }
        let p = store.predicateForEvents(withStart: from, end: to, calendars: activeCalendars)
        return store.events(matching: p)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    func today() -> [EKEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date()
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
    func agendaLine(limit: Int = 4) -> String? {
        let t = today().filter { !($0.isAllDay) && ($0.endDate ?? Date()) > Date() }
        let allDay = today().filter { $0.isAllDay }
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
            guard let id = e.eventIdentifier, !filed.contains(id),
                  let ended = e.endDate, ended < Date(), !e.isAllDay else { continue }
            filed.insert(id)
            var body = ""
            if let n = e.notes, !n.isEmpty { body = n }
            ChappyMemory.shared.rememberAt(.note,
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
