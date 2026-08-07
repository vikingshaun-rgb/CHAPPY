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
    static func launchGreeting(name: String, date: Date, firstOfDay: Bool) -> String {
        let part = timeOfDay(date)
        let who = name.isEmpty ? "" : ", \(name)"
        if firstOfDay {
            return line("launch_first", [
                "\(part)\(who). I'm listening.",
                "\(part)\(who). Ready when you are.",
                "\(part)\(who). All set.",
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
                "maxOutputTokens": 120,
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

    private var wakeID: SystemSoundID = 0
    private var doneID: SystemSoundID = 0
    private var failID: SystemSoundID = 0
    private var tapID: SystemSoundID = 0
    private var prepared = false

    private init() {}

    /// Render the three tones once. Safe to call repeatedly.
    func prepare() {
        guard !prepared else { return }
        prepared = true
        // Rising perfect fourth — "listening". A5 → D6.
        wakeID = register(name: "chappy-wake", notes: [(880.0, 0.075), (1174.7, 0.115)])
        // Soft single note — "done", deliberately quieter than the wake tone.
        doneID = register(name: "chappy-done", notes: [(1046.5, 0.110)], gain: 0.22)
        // Falling minor third — "didn't work".
        failID = register(name: "chappy-fail", notes: [(659.3, 0.080), (523.3, 0.130)], gain: 0.26)
        // One short high note, quiet. A click, not a chime.
        tapID  = register(name: "chappy-tap",  notes: [(1567.98, 0.032)], gain: 0.16)
    }

    func wake() { play(wakeID) }
    func done() { play(doneID) }
    func fail() { play(failID) }
    /// The button click. Deliberately the shortest and quietest of the four —
    /// a tap is an acknowledgement, not an announcement. Its whole job is to
    /// close the loop when the screen gives you nothing: you pressed Remember,
    /// something happened, you did not have to look.
    func tap() { play(tapID) }

    private func play(_ id: SystemSoundID) {
        guard id != 0 else { return }
        AudioServicesPlaySystemSound(id)
    }

    /// Render a short sequence of sine notes to a 16-bit mono WAV and register
    /// it as a system sound. Each note gets a raised-cosine envelope — a bare
    /// sine switched on and off clicks, and a click is the one thing that makes
    /// a chime sound cheap.
    private func register(name: String, notes: [(Double, Double)], gain: Double = 0.30) -> SystemSoundID {
        let sampleRate = 44100.0
        var samples: [Int16] = []
        for (freq, seconds) in notes {
            let count = Int(sampleRate * seconds)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let progress = Double(i) / Double(max(count - 1, 1))
                // Raised-cosine attack/release, ~12% of the note at each end.
                let edge = 0.12
                var env = 1.0
                if progress < edge { env = 0.5 - 0.5 * cos(.pi * progress / edge) }
                else if progress > 1 - edge { env = 0.5 - 0.5 * cos(.pi * (1 - progress) / edge) }
                // A touch of second harmonic keeps it from sounding like a test tone.
                let v = sin(2 * .pi * freq * t) * 0.85 + sin(4 * .pi * freq * t) * 0.15
                samples.append(Int16(max(-1.0, min(1.0, v * env * gain)) * 32767))
            }
        }
        guard !samples.isEmpty else { return 0 }

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
            return 0
        }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
        guard status == kAudioServicesNoError else {
            print("⚠️ [Earcon] Could not register \(name) (status \(status))")
            return 0
        }
        return id
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

    private static let wakeWords = ["chappy", "chappie", "chapy", "chappy's"]

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
        ("chilean", "es"), ("latin american", "es"), ("espanol", "es")
    ]

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
            announceArmFailure("Battery is under twenty percent - standby stays off to save it.")
            return
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio,
                                 options: [.duckOthers, .allowBluetooth, .defaultToSpeaker])
        try? session.setActive(true)

        guard startRecognition() else { starting = false; return }
        isListening = true
        starting = false
        installAudioResilience()
        ChappyEarcon.shared.prepare() // render the tones before they're needed
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
                TTSService.shared.speak(ChappyVoice.launchGreeting(
                    name: userName, date: Date(), firstOfDay: firstOfDay))
            } else {
                print("👂 [Standby] Armed silently (already greeted this launch)")
            }
        } else {
            // A deliberate tap on the ear button.
            ChappyEarcon.shared.wake()
            TTSService.shared.speak("Standby on. I'm listening for my name.")
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
        TTSService.shared.speak("Standby dropped out - tap the ear to bring me back.")
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
        (UserDefaults.standard.string(forKey: "chappy_user_name") ?? "")
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
        // ON-DEVICE = free, private, works with no signal.
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
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
                let text = result.bestTranscription.formattedString.lowercased()
                Task { @MainActor in
                    guard let self, self.task === thisTask else { return }
                    self.heard(text)
                }
            }
            if error != nil || (result?.isFinal ?? false) {
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
                        TTSService.shared.speak("Couldn't rename it, but the spot is saved.")
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
        let debounce: Double
        if Self.extendableCommands.contains(cleanTail) {
            debounce = 0.25
        } else {
            let wordCount = snapshot.split(separator: " ").count
            debounce = wordCount <= 3 ? 0.6 : (wordCount <= 6 ? 0.85 : 1.1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Complete in themselves — no command in the grammar extends any of these,
    /// so there is never a reason to wait.
    static let terminalCommands: Set<String> = [
        "stop", "cancel", "quiet", "enough", "shut up", "shush", "be quiet",
        "stop talking", "that's enough", "thats enough", "never mind",
        "battery", "battery check", "battery level",
        "where am i", "what street", "where was i", "i'm lost", "im lost",
        "emergency", "sos", "help", "help me",
        "stop navigation", "cancel navigation", "stop navigating",
        "open maps", "open google maps", "show the map", "show map",
        "what can i say", "what can you do",
        "spent today", "cost check", "usage today",
        "quiet mode", "tour mode", "budget mode", "normal mode",
    ]

    /// Known commands that MAY take a tail. Short grace, then fire.
    static let extendableCommands: Set<String> = [
        "translate", "look", "snap", "photo", "take a photo", "take a picture",
        "map", "remember", "watch", "keep watching", "navigate", "go",
        "remember this spot", "let's talk", "lets talk", "take me home",
        "get me home", "go home",
    ]

    private func finish(_ raw: String) {
        // AUDIT FIX (HIGH — re-entry): a second command arriving while one is
        // still routing used to run BOTH concurrently — two paid calls, two
        // voices, and a `busy` flag that stopped meaning anything.
        guard !busy else {
            // AUDIT P1 (SB-BUSY): this dropped the command with no speech and no
            // haptic. Wearing glasses with the phone pocketed, "heard and
            // dropped" and "never heard at all" are indistinguishable — so he
            // repeats himself into a void. Say something.
            print("👂 [Standby] Busy — dropped: \(raw)")
            ChappyEarcon.shared.fail()
            ChappyHaptics.shared.straightStep()
            TTSService.shared.speak("Still working on the last one.")
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
            TTSService.shared.speak("Yes?")
            resetRecognition()
            return
        }
        print("👂➡️ [Standby] Command: \(cmd)")
        busy = true
        routeTask?.cancel()
        routeTask = Task { @MainActor in
            await route(cmd)
            self.busy = false
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
        if c.contains("stop navigation") || c.contains("stop navigating")
            || c.contains("cancel navigation") || c.contains("stop the route") {
            NavEngine.shared.stop(); speak("Navigation stopped."); return
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
            NotificationCenter.default.post(name: .chappyCapturePhoto, object: nil)
            // AUDIT FIX: don't claim success when the camera isn't running.
            if LiveAIManager.shared.streamViewModel?.streamingStatus == .streaming {
                speak("Photo taken.")
            } else {
                speak("Camera isn't running - open Talk or Look first, then I can shoot.")
            }
            return
        }
        if let note = after(c, ["log this", "note this", "write this down", "make a note", "jot this down"]) {
            if note.count > 2 {
                TripRecorder.shared.addObservation(note)
                ChappyHaptics.shared.straightStep()
                speak("Logged.")
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
                speak("Saved, but GPS hasn't locked yet.")
            } else {
                ChappyEarcon.shared.done()
                speak("Saved \(spot.name).")
            }
            return
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
            speak("Reading it.")
            QuickVisionManager.shared.triggerQuickVision(customPrompt:
                "Read the text in this image and translate it into English. Say the original briefly, then the translation. Two short spoken sentences.")
            return
        }
        if c.hasPrefix("translate") || c.contains("interpreter")
            || c.contains("help me talk to") || c.contains("talk to them")
            || (c.contains("translate") && (c.contains("mode") || c.contains("for me"))) {
            let picked = Self.languageCode(spokenIn: c)
                ?? Self.languageCode(forCountry: ContextEngine.shared.snapshot.countryCode)
            guard let code = picked else {
                // Honest failure beats a translator that silently does nothing
                speak("I don't have this country's language yet. Say translate to Indonesian, Thai, Vietnamese, Chinese, Japanese or Filipino.")
                return
            }
            UserDefaults.standard.set("en", forKey: "translate_source_language")
            UserDefaults.standard.set(code, forKey: "translate_target_language")
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
            speak("Watching.")
            handOff()
            NotificationCenter.default.post(name: .continuousVisionTriggered, object: nil)
            return
        }
        if c.contains("stop navigation") || c.contains("cancel navigation") {
            NavEngine.shared.stop(); speak("Navigation stopped."); return
        }
        // AUDIT P1 (RG-HOME): only two phrasings were handled, so "take us
        // home" at 2am fell all the way through to the either/or prompt.
        if ["get me home", "take me home", "take us home", "get us home",
            "walk me home", "walk us home", "head home", "go home", "get home",
            "way home", "back to the hotel", "take us back to the hotel",
            "navigate home"].contains(where: { c.contains($0) }) {
            speak("Finding your way home.")
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
                speak("Heading home.")
                let reply = await NavEngine.shared.getHome()
                speak(reply); return
            }
            speak("Finding \(dest).")
            let reply = await NavEngine.shared.navigate(to: dest, driving: driving)
            // Human ears get the human string; the model-directed one is for
            // Live AI only. See AUDIT FIX (SPOKEN-LEAK) in NavEngine.navigate.
            speak(NavEngine.shared.spokenRouteSummary ?? reply); return
        }
        // AUDIT FIX (coverage gap): mode follow-ups re-route the last
        // destination — they worked in-session but not in Standby.
        if let last = NavEngine.shared.lastQuery,
           ["via car", "by car", "in the car", "by scooter", "on the scooter",
            "on foot", "walking instead", "by motorbike"].contains(where: { c.contains($0) }),
           c.split(separator: " ").count <= 5 {
            let driving = !(c.contains("foot") || c.contains("walking"))
            speak("Re-routing.")
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
            speak("Checking.")
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
            speak("Reading.")
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
            speak("Looking.")
            QuickVisionManager.shared.triggerQuickVision()
            return
        }
        // AUTO-ESCALATION: if this is really a conversation, don't fake it
        // with a one-shot — hand it to Live AI and carry the question over.
        if needsDeepSession(c) {
            speak("That needs a proper chat - opening Live AI.")
            UserDefaults.standard.set(c, forKey: "chappy_pending_question")
            handOff()
            NotificationCenter.default.post(name: .liveAITriggered, object: nil)
            return
        }

        // THE UNSURE RULE (spec'd, previously unbuilt): a bare noun is
        // ambiguous — "Chappy, sushi" could be find-me-one or tell-me-about.
        // Ask ONE either/or instead of guessing or burning a paid call.
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
        if let intent = await ChappyIntent.classify(c), intent.action != "ask" {
            print("🧠 [Intent] '\(c)' → \(intent.action) \(intent.parameter ?? "")")
            if await runIntent(intent) { return }
        }

        await quickAsk(c)
    }

    /// Execute a Flash-classified intent by routing it back through the SAME
    /// handlers the string ladder uses — no second implementation to drift.
    /// Returns false if we couldn't action it, so the caller can fall through
    /// to a plain answer rather than pretending.
    private func runIntent(_ intent: ChappyIntent.Result) async -> Bool {
        let p = intent.parameter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch intent.action {
        case "navigate":
            guard !p.isEmpty else { promptForDestination(); return true }
            if ["home", "hotel", "the hotel"].contains(p.lowercased()) {
                speak("Heading home."); speak(await NavEngine.shared.getHome()); return true
            }
            let driving = ["drive", "car", "taxi", "scooter", "motorbike", "grab"]
                .contains { (intent.mode ?? "").lowercased().contains($0) }
            speak("Finding \(p).")
            let reply = await NavEngine.shared.navigate(to: p, driving: driving)
            speak(NavEngine.shared.spokenRouteSummary ?? reply)
            return true

        case "translate":
            // p is a language name or code, or empty for "local language".
            let code = p.isEmpty ? nil : Self.languageCode(forName: p)
            guard let target = code ?? Self.languageCode(forCountry: ContextEngine.shared.snapshot.countryCode) else {
                speak("I don't have that language yet."); return true
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
            speak("Looking.")
            QuickVisionManager.shared.triggerQuickVision(customPrompt: p.isEmpty ? nil : "Look and answer: \(p)")
            return true

        case "photo":
            NotificationCenter.default.post(name: .chappyCapturePhoto, object: nil)
            speak("Photo taken."); return true

        case "remember":
            if p.isEmpty { rememberSpotByVoice() } else {
                let s = TripRecorder.shared.rememberSpot(named: p)
                ChappyEarcon.shared.done(); speak("Saved \(s.name).")
            }
            return true

        case "map":
            NotificationCenter.default.post(name: .chappyShowMap, object: nil)
            speak("Map's up."); return true

        case "watch":
            speak("Watching."); handOff()
            NotificationCenter.default.post(name: .continuousVisionTriggered, object: nil)
            return true

        case "live_ai":
            speak("Opening Live AI."); handOff()
            NotificationCenter.default.post(name: .liveAITriggered, object: nil)
            return true

        case "stop":
            TTSService.shared.stop(); NavEngine.shared.stop(); return true

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
        speak("Job saved for the computer: \(job). It runs when the computer's awake.")
    }

    // MARK: Helpers

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
                       "route me to ", "route to ", "how do i get to ", "how do we get to "]
        if !asksAbout { openers += ["closest ", "nearest "] }
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
                Task { @MainActor in ChappyHaptics.shared.costNudge() }
                TTSService.shared.speak("Heads up - roughly \(Int(threshold)) dollars of AI usage today.")
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
        if navigating {
            let status = locationManager.authorizationStatus
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                locationManager.allowsBackgroundLocationUpdates = true
                locationManager.showsBackgroundLocationIndicator = true
            }
            if status == .authorizedWhenInUse, !askedForAlways {
                askedForAlways = true
                locationManager.requestAlwaysAuthorization()
            }
        } else {
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
        let spot = Spot(name: name, t: Date(),
                        lat: snap.latitude ?? lastCrumb?.lat ?? 0,
                        lon: snap.longitude ?? lastCrumb?.lon ?? 0,
                        street: snap.street, city: snap.city, country: snap.country)
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
        let snapshot = notes
        let url = notesURL(for: Date())
        ioQueue.async {
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url) }
        }
        print("📝 [Trip] Observation: \(text)")
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
        if announce { TTSService.shared.speak("Navigation stopped.") }
    }

    /// Fed by ContextEngine on every fix: speaks turns, detects off-route.
    func updateLocation(_ loc: CLLocation) {
        // STEP 8: proximity watch fires even when not navigating
        if let w = watchTarget {
            let dw = loc.distance(from: CLLocation(latitude: w.coord.latitude, longitude: w.coord.longitude))
            if dw < 150 {
                watchTarget = nil
                ChappyHaptics.shared.proximity()
                speakNav("Heads up - you are about \(Int(dw)) meters from \(w.name).")
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
                speakNav("You are off the route. Recalculating.")
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
