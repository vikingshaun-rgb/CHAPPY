/*
 * Gemini Live WebSocket Service
 * Provides real-time audio chat with Google Gemini AI
 * Model is HARD-PINNED below (liveModel) — callers cannot override it
 * until the socket layer is proven stable.
 * All socket failures are surfaced to the UI via onError (TestFlight has no console).
 */

import Foundation
import UIKit
import AVFoundation

// MARK: - Gemini Live Service

class GeminiLiveService: NSObject {

    // The one known-good Live model (verified 2026-08). Pinned here so a stale
    // value at any call site can no longer break the socket.
    static let liveModel = "gemini-3.1-flash-live-preview"

    // WebSocket
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var didReportSocketError = false
    /// AUDIT FIX (LA-H2): bounded auto-recovery state.
    private var recoveryAttempts = 0
    /// True between the user starting Live and the user (or a cap) ending it.
    /// Recovery must never fire after a deliberate disconnect.
    private var isUserSessionActive = false

    // Configuration
    private let apiKey: String
    private let model: String

    // Audio Engine (for recording)
    private var audioEngine: AVAudioEngine?
    /// AUDIT FIX (LA-H1): observer token for the record-engine watchdog.
    private var engineWatchdogToken: NSObjectProtocol?

    // Audio Playback Engine (separate engine for playback)
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioLifelinesInstalled = false

    // SESSION CONTINUITY (Phase 4 Step 8, part 1): Gemini live sessions have
    // a max duration — the server warns with a goAway message, then aborts
    // with 1008 if the client doesn't act. We store the rotating resumption
    // handle and auto-reconnect into the SAME session (context intact).
    private var resumptionHandle: String?
    private var isRenewingSession = false
    private var renewalCount = 0
    private var speechFrameFired = false
    private var endFrameFired = false
    private var journalCommandFired = false
    // ECO DRIP: cost saver — full frame rate only around conversation
    private var lastInteractionAt = Date()
    private var ecoSkipCounter = 0

    // STEP 8 FUSION: the live session other modules can speak through
    static weak var activeInstance: GeminiLiveService?
    /// AUDIT FIX: activeInstance stays set across renewals and dead sockets,
    /// so NavEngine spoke turns into a void instead of falling back to TTS.
    var isLive: Bool { isSessionConfigured && webSocket != nil }

    // COST METER: when this live session started (for spend estimates)
    private var liveSessionStartAt: Date?

    // AUDIT FIX (LA-C2): the most expensive failure mode in the whole app is a
    // live session nobody closed — frames AND audio, both metered, until the
    // battery dies. Two brakes: a hard wall-clock cap that survives renewals,
    // and a silence cutoff for the pocketed-phone case.
    private var sessionAnchor: Date?
    private var sessionCapTimer: Timer?
    private static let maxSessionMinutes: Double = 30
    private static let maxSilentMinutes: Double = 10
    private var didWarnSessionCap = false

    /// Anchored to the FIRST connect, so renewals can't keep pushing the cap out.
    private func armSessionCap() {
        if sessionAnchor == nil { sessionAnchor = Date() }
        guard let anchor = sessionAnchor else { return }
        let elapsed = Date().timeIntervalSince(anchor)
        let remaining = max(5, Self.maxSessionMinutes * 60 - elapsed)
        sessionCapTimer?.invalidate()
        sessionCapTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                TTSService.shared.speak("That's half an hour of live - I'm closing the session to protect your credit. Say Chappy, live, to start again.")
                self.disconnect()
            }
        }
    }

    // CONTEXT DRIP: keeps Chappy's sense of time & place fresh all session
    private var contextTimer: Timer?
    // NAV BRIDGE v2: debounced full-sentence navigation detection
    private var navDetectWork: DispatchWorkItem?
    // LOG THIS: debounced full-sentence note capture
    private var noteDetectWork: DispatchWorkItem?

    // STEP 8 CONTINUITY PART 2: rolling conversation memory for re-briefs
    private var currentUserLine = ""
    private var currentModelLine = ""
    private var recentLines: [String] = []

    // SCOOTER MODE: client-side voice detection state
    private var lastLoudAt = Date.distantPast
    private let playbackAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)
    private let recordTargetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
    private var recordConverter: AVAudioConverter?

    // Audio buffer management
    private var audioBuffer = Data()
    private var isCollectingAudio = false
    private var audioChunkCount = 0
    // VOICE WATCHDOG: detects turns where TEXT arrived but AUDIO never did
    // (server stopped sending voice) and self-heals — engine restart first,
    // silent session renewal if it happens twice in a row.
    private var audioChunksThisTurn = 0
    private var consecutiveSilentTurns = 0
    private let minChunksBeforePlay = 2
    private var hasStartedPlaying = false
    private var isPlaybackEngineRunning = false

    // Callbacks
    var onTranscriptDelta: ((String) -> Void)?
    var onTranscriptDone: ((String) -> Void)?
    var onUserTranscript: ((String) -> Void)?
    var onAudioDelta: ((Data) -> Void)?
    var onAudioDone: (() -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onSpeechStopped: (() -> Void)?
    var onError: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onFirstAudioSent: (() -> Void)?
    /// Fired when the user asks Chappy to READ something — the view model
    /// responds by sending one full-sharpness frame for fine print.
    var onReadRequest: (() -> Void)?

    // State
    private var isRecording = false
    private var hasAudioBeenSent = false
    private var isSessionConfigured = false

    // MARK: - BUILD 125: surviving the lock screen
    //
    // Chat worked the first time and then died the moment the phone locked,
    // and stayed dead even after unlocking and reopening the app. Three causes,
    // all here:
    //
    //   1. This class had NO background or foreground handling for its capture
    //      engine at all. ChappyStandby next door has it; chat never did. When
    //      the app went away the engine stopped and `isRecording` stayed true,
    //      so every later startRecording() hit `guard !isRecording` and returned
    //      immediately. Silent forever.
    //
    //   2. When the watchdog DID fire while backgrounded, its restart failed,
    //      leaving `isRecording` false — and the watchdog's own guard is
    //      `self.isRecording`, so it then ignored every future reconfiguration
    //      for the life of the object. It disarmed itself.
    //
    //   3. A failed engine.start() left the mic tap installed, so the next
    //      attempt double-installed and iOS raised an ObjC exception Swift
    //      cannot catch. That one is a crash, not a silence. The identical bug
    //      was found and fixed in LiveTranslateService long ago; this file
    //      never got the fix.
    //
    // `wantsRecording` is INTENT, separate from `isRecording` which is fact.
    // Recovery is driven by intent, so a failed restart can never disarm it.
    private var wantsRecording = false
    private var wasRecordingBeforeBackground = false
    private var lifecycleTokens: [NSObjectProtocol] = []
    private var restartAttempt = 0
    private static let restartDelays: [TimeInterval] = [0.4, 1.0, 2.5]
    /// Deferrals while waiting for the mic format to settle. Bounded so a
    /// genuinely dead input can't leave a half-second retry running forever.
    private var formatDeferrals = 0
    private static let maxFormatDeferrals = 10

    init(apiKey: String, model: String? = nil) {
        self.apiKey = apiKey
        // HARD PIN: ignore whatever the caller passes — builds 12-14 may still
        // hand in a retired model name. Remove the pin once Live is stable.
        self.model = GeminiLiveService.liveModel
        super.init()
        setupAudioEngine()
    }

    /// BUILD 126: this class had no deinit at all. A new instance is built for
    /// every chat session, and each one installed notification observers that
    /// outlived it. Harmless while they only revived playback; actively
    /// dangerous once build 125 taught them to reclaim the microphone, because
    /// a stale instance would fight the live one for the input hardware — and
    /// two engines tapping the same input is a crash, not a glitch.
    deinit {
        let nc = NotificationCenter.default
        for token in lifecycleTokens { nc.removeObserver(token) }
        if let token = engineWatchdogToken { nc.removeObserver(token) }
        audioEngine?.inputNode.removeTap(onBus: 0)
        if let engine = audioEngine, engine.isRunning { engine.stop() }
        print("🧹 [Gemini] Service torn down cleanly")
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        setupPlaybackEngine()
        installAudioLifelines()
    }

    // VOICE LIFELINE: iOS silently kills the playback engine on audio
    // interruptions and Bluetooth route changes (glasses drop/reconnect).
    // The old code trusted its own isPlaybackEngineRunning flag — which
    // stays true — so every later reply was scheduled into a dead engine:
    // the chat kept answering, the voice went mute. These observers plus
    // the health check in playAudio() bring the voice back automatically.
    private func installAudioLifelines() {
        guard !audioLifelinesInstalled else { return }
        audioLifelinesInstalled = true
        let nc = NotificationCenter.default
        // BUILD 126: every token is kept now. A GeminiLiveService is created
        // fresh for each chat session, and these observers were never removed —
        // so opening Live AI five times left five live instances all listening
        // for route changes, each with its own AVAudioEngine, all racing to
        // grab the same hardware input. Build 125 made that materially worse by
        // adding three more observers that CLAIM THE MICROPHONE. Retain the
        // tokens and tear them down in deinit.
        lifecycleTokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            if let engine = self.playbackEngine, !engine.isRunning {
                self.revivePlaybackEngine()
            }
        })
        lifecycleTokens.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let engine = self.playbackEngine, !engine.isRunning {
                self.revivePlaybackEngine()
            }
        })
        // BUILD 125: the interruption observer above revives PLAYBACK only, so
        // a call or a Siri press gave Chappy his voice back but never his ears.
        // "Silent and doesn't recognise my mic" was literally both halves of
        // that. Capture gets the same treatment now.
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                guard self.wantsRecording else { return }
                print("🎤 [Gemini] Interrupted — letting the mic go, will reclaim it")
                self.teardownCapture()
            case .ended:
                guard self.wantsRecording, !self.isRecording else { return }
                // iOS needs a beat after an interruption clears before it will
                // hand the session back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.reclaimMic(why: "interruption ended")
                }
            @unknown default: break
            }
        }

        // BUILD 125: the lock screen. With `audio` in UIBackgroundModes the app
        // is allowed to keep running, but the engine can still be stopped under
        // us and the session handed elsewhere. Let go cleanly on the way out
        // and take it back on the way in, rather than pretending nothing
        // happened and leaving a dead tap behind.
        lifecycleTokens.append(nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isRecording else { return }
                print("🎤 [Gemini] Backgrounded — standing the mic down cleanly")
                self.wasRecordingBeforeBackground = true
                self.teardownCapture()
            })

        lifecycleTokens.append(nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.wasRecordingBeforeBackground else { return }
                self.wasRecordingBeforeBackground = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.reclaimMic(why: "returned to foreground")
                }
            })

        // Belt and braces: didBecomeActive fires on unlock even when
        // willEnterForeground didn't (Control Centre, notification shade). If
        // we still WANT the mic and don't HAVE it, take it.
        lifecycleTokens.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.wantsRecording, !self.isRecording else { return }
                self.reclaimMic(why: "became active")
            })

        print("🛟 [Gemini] Audio lifelines installed (interruption + route + lifecycle)")
    }

    /// BUILD 125: release capture without touching INTENT. Safe to call from
    /// anywhere; leaves `wantsRecording` alone so recovery still knows the
    /// wearer wanted the microphone open.
    private func teardownCapture() {
        if let token = engineWatchdogToken {
            NotificationCenter.default.removeObserver(token)
            engineWatchdogToken = nil
        }
        // Unconditional — see cause 3 above. A tap left on a stopped engine is
        // an uncatchable exception on the next install.
        audioEngine?.inputNode.removeTap(onBus: 0)
        if let engine = audioEngine, engine.isRunning { engine.stop() }
        isRecording = false
    }

    /// BUILD 125: take the microphone back, with backoff. Driven by
    /// `wantsRecording`, never by `isRecording` — that was the flag that
    /// disarmed the old watchdog permanently.
    private func reclaimMic(why: String) {
        guard wantsRecording, isSessionConfigured, !isRecording else { return }
        print("🎤 [Gemini] Reclaiming the mic (\(why)), attempt \(restartAttempt + 1)")
        startRecording()
        guard !isRecording else { restartAttempt = 0; return }

        let attempt = restartAttempt
        guard attempt < Self.restartDelays.count else {
            restartAttempt = 0
            print("❌ [Gemini] Could not reclaim the mic after \(Self.restartDelays.count) tries")
            onError?("Chappy can't hear you — close and reopen the chat.")
            return
        }
        restartAttempt += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelays[attempt]) { [weak self] in
            self?.reclaimMic(why: why)
        }
    }

    private func revivePlaybackEngine() {
        print("🔄 [Gemini] Playback engine dead (interruption/route change) — reviving")
        playerNode?.stop()
        playbackEngine?.stop()
        isPlaybackEngineRunning = false
        setupPlaybackEngine()
        startPlaybackEngine()
        playerNode?.play()
    }

    private func setupPlaybackEngine() {
        playbackEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let playbackEngine = playbackEngine,
              let playerNode = playerNode else {
            print("❌ [Gemini] Failed to initialize the playback engine")
            return
        }

        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackAudioFormat)
        playbackEngine.prepare()
        print("✅ [Gemini] Playback engine initialized")
    }

    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
        } catch {
            print("⚠️ [Gemini] Audio session Configuration failed: \(error)")
        }
    }

    private func startPlaybackEngine() {
        guard let playbackEngine = playbackEngine, !isPlaybackEngineRunning else { return }

        do {
            configureAudioSession()
            try playbackEngine.start()
            isPlaybackEngineRunning = true
            print("▶️ [Gemini] Playback engine started")
        } catch {
            print("❌ [Gemini] Playback engine failed to start: \(error)")
        }
    }

    private func stopPlaybackEngine() {
        guard let playbackEngine = playbackEngine, isPlaybackEngineRunning else { return }

        playerNode?.stop()
        playerNode?.reset()
        playbackEngine.stop()
        isPlaybackEngineRunning = false
        print("⏹️ [Gemini] Playback engine stopped and queue cleared")
    }

    // MARK: - WebSocket Connection

    func connect() {
        // AUDIT FIX: connect() used to overwrite the socket without cancelling
        // the old one — the abandoned socket kept receiving, kept pushing audio
        // into the same player and kept billing.
        if webSocket != nil || urlSession != nil {
            webSocket?.cancel(with: .goingAway, reason: nil); webSocket = nil
            urlSession?.invalidateAndCancel(); urlSession = nil
        }
        // Gemini Live WebSocket URL with API key
        let baseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        let urlString = baseURL

        let keyPreview = apiKey.count > 10 ? "\(apiKey.prefix(6))…\(apiKey.suffix(4))" : "TOO-SHORT(\(apiKey.count))"
        print("🔌 [Gemini] Preparing WebSocket connection — model: \(model), key: \(keyPreview)")

        guard let url = URL(string: urlString) else {
            print("❌ [Gemini] Invalid URL")
            onError?("Invalid URL")
            return
        }

        didReportSocketError = false
        isUserSessionActive = true
        GeminiLiveService.activeInstance = self

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 15
        webSocket = urlSession?.webSocketTask(with: request)
        webSocket?.resume()

        print("🔌 [Gemini] WebSocket Task started")
        receiveMessage()
    }

    func disconnect() {
        print("🔌 [Gemini] Disconnect the WebSocket")
        if GeminiLiveService.activeInstance === self { GeminiLiveService.activeInstance = nil }
        // AUDIT FIX (LA-C2 / LA-H10): drop the brakes and the interlock flag
        // together — a stale "live" flag would lock Continuous Vision out for
        // the rest of the app's life.
        sessionCapTimer?.invalidate()
        sessionCapTimer = nil
        sessionAnchor = nil
        didWarnSessionCap = false
        isUserSessionActive = false
        recoveryAttempts = 0
        Task { @MainActor in
            LiveAIManager.shared.isRunning = false
            // AUDIT FIX (LA-H9): every exit from a live session — the X button,
            // the cap, a fatal drop — re-arms the wake word. Previously only the
            // manager's own (unused) stop path did.
            ChappyStandby.shared.resumeAfterHandOff()
        }
        contextTimer?.invalidate()
        contextTimer = nil
        navDetectWork?.cancel()
        navDetectWork = nil
        noteDetectWork?.cancel()
        noteDetectWork = nil
        // COST METER: bank the session time
        if let started = liveSessionStartAt {
            CostMeter.shared.addLiveSeconds(Date().timeIntervalSince(started))
            liveSessionStartAt = nil
        }
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        stopRecording()
        stopPlaybackEngine()
        isSessionConfigured = false
    }

    // MARK: - Session Configuration

    private func configureSession() {
        guard !isSessionConfigured else { return }

        // Get the system prompt for the current Live AI mode
        // PHASE 4: live context header — Chappy knows where/when it is
        let instructions = "LIVE CONTEXT: " + ContextEngine.shared.contextHeader() + "\n\n" + LiveAIModeManager.staticSystemPrompt + "\n\nIDENTITY: Your name is Chappy. You are the personal assistant of Shaun, an Australian traveller. When asked who or what you are, answer as Chappy - warmly and briefly. NEVER mention Gemini, Google, AI models, or being a language model; you are simply Chappy. PERSONA: loyal, sharp and capable like a great butler-engineer - concise, practical, a touch of dry wit when the moment suits, never rambling. Use your tools without being asked: search the web when current facts are needed, compute when numbers are involved (currency, bills, distances), and volunteer the useful next step ('want directions?', 'shall I remember this spot?').\n\nCHAPPY LIVE RULES: You are Chappy, a sharp real-time assistant looking through smart glasses worn by the user. Vision: describe only what is actually visible in the images you receive, in specific concrete detail - exact words, numbers, prices, colors, brands. If no clear image has arrived, say you cannot see clearly right now; never guess or invent. Reading: when asked to read, or when signs, menus, labels or screens are visible, read the text aloud verbatim. Food and health: when asked about food, drinks or products, read ingredients and labels, flag allergens and give practical health info. Translation: when visible text is in a foreign language, translate it and say the original name too. Places: when the user asks about a shop, restaurant, landmark or location, act like a knowledgeable local guide - what it is, what it is good for, whether it looks worth visiting. Style: SPEED IS EVERYTHING - default to ONE short punchy sentence, spoken immediately; expand only when explicitly asked for detail. Speak naturally like a trusted friend; lead with the answer, no preamble, no restating the question. Always answer in the language the user speaks to you. Watching: you receive a continuous stream of frames - always ground your answers ONLY in the very LATEST frame - when asked what the user is looking at, describe the newest image and NEVER an earlier one. The scene often changes WHILE the user is speaking: if frames disagree, the NEWEST frame is the truth and older frames are history - counting fingers, reading signs, describing scenes must always use the final frame received. SPEAK-WHEN-SPOKEN-TO DISCIPLINE: do NOT narrate scene changes by default - the camera moves constantly and unprompted commentary clogs the voice channel. Volunteer speech ONLY for genuine safety hazards or truly exceptional sights, at most one short sentence every couple of minutes. NEVER stack multiple replies: one question gets exactly one answer, and if the user starts speaking, abandon whatever you were saying instantly and listen. TOOLS ARE YOUR HANDS: use your function tools freely and unprompted - navigate_to when the user wants to go somewhere, remember_spot to save places, save_observation whenever you notice something notable worth remembering, alert_when_near for stop-watching, deep_research for questions needing thorough current facts (say you are digging into it first), open_app or open_website to act on the phone, and emergency IMMEDIATELY if the user is in danger. Never say you cannot do these things - call the tool. NAVIGATION TRUTH: you have NO power to 'send directions to the phone', 'load a map' or 'pull up a route' by yourself - the ONLY way navigation ever starts is the navigate_to tool, or a 'Navigation:' app message confirming the route. Never claim directions are ready or loaded unless one of those actually happened; if you did not call the tool, NOTHING happened. TIME AND PLACE TRUTH: messages starting with CONTEXT UPDATE are ground truth for the user's REAL current local time and location - when asked the time, the date, or where you are, answer from the LATEST context update, in local time. NEVER answer in UTC, never say you do not know where the user is, and never guess a city."

        // Use the voice chosen in Settings → Voice (was hardcoded to Aoede,
        // which silently ignored the user's picker). "System" (Apple TTS)
        // has no Live equivalent, so it falls back to Kore for Live sessions.
        let storedVoice = UserDefaults.standard.string(forKey: "chappy_tts_voice") ?? "Kore"
        let liveVoice = (storedVoice == "System" || storedVoice.isEmpty) ? "Kore" : storedVoice

        // Gemini Live API setup message
        let setupMessage: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "generation_config": [
                    "response_modalities": ["AUDIO"],
                    // Extract MORE detail from each frame at the model side —
                    // sharper scene understanding without bigger uploads.
                    "media_resolution": "MEDIA_RESOLUTION_HIGH",
                    "speech_config": [
                        "voice_config": [
                            "prebuilt_voice_config": [
                                "voice_name": liveVoice
                            ]
                        ]
                    ]
                ],
                "system_instruction": [
                    "parts": [
                        ["text": instructions]
                    ]
                ],
                // PROACTIVE AUDIO pulled 2026-08-03: v1beta rejects the field
                // (1007 "Unknown name 'proactivity'"). It's v1alpha-only —
                // re-add together with a v1alpha endpoint experiment later.
                // Transcripts of BOTH sides — the app's history and the
                // "read this" trigger depend on these arriving.
                "input_audio_transcription": [:],
                "output_audio_transcription": [:],
                // SESSION CONTINUITY: ask the server for resumption handles;
                // on renew we pass the stored handle to resume the same session.
                "session_resumption": (resumptionHandle != nil ? ["handle": resumptionHandle!] : [:]) as [String: Any],
                // FASTER TURNS: respond ~half a second after you stop talking
                // instead of waiting out a long silence.
                "realtime_input_config": [
                    "automatic_activity_detection": [
                        "end_of_speech_sensitivity": "END_SENSITIVITY_HIGH",
                        "silence_duration_ms": 300
                    ]
                ],
                // LONG SESSIONS: sliding-window compression stops the session
                // dying when the context fills up on a long walk.
                "context_window_compression": [
                    "sliding_window": [:]
                ],
                // GOOGLE SEARCH GROUNDING + CODE EXECUTION: Chappy can search
                // the live web AND run real calculations server-side (currency
                // conversion, splitting bills, distances) — no client code needed.
                "tools": [
                    ["google_search": [:]],
                    ["code_execution": [:]],
                    // PHASE 4 STEP 7 — THE HANDS: real function tools.
                    ["function_declarations": [
                        ["name": "navigate_to",
                         "description": "Start hands-free turn-by-turn navigation to a destination: a place name, shop, address, or a remembered spot. Use mode 'drive' when the user is in a car, on a scooter or motorbike.",
                         "parameters": ["type": "OBJECT", "properties": ["destination": ["type": "STRING", "description": "Where to go"], "mode": ["type": "STRING", "description": "walk or drive; default walk"]], "required": ["destination"]]],
                        ["name": "get_me_home",
                         "description": "Navigate the user back to their saved home or hotel spot."],
                        ["name": "stop_navigation",
                         "description": "Stop the current navigation."],
                        ["name": "remember_spot",
                         "description": "Save the user's current location as a named spot they can navigate back to later.",
                         "parameters": ["type": "OBJECT", "properties": ["name": ["type": "STRING", "description": "Name for this spot, e.g. home, the good coffee place"]], "required": ["name"]]],
                        ["name": "query_journal",
                         "description": "Get today's travel journal: places passed through, remembered spots, observations."],
                        ["name": "retrace_steps",
                         "description": "Get the route back the way the user came today."],
                        ["name": "save_observation",
                         "description": "Save a notable observation to the travel journal - an interesting shop, price, landmark or fact worth remembering. Use this UNPROMPTED when you notice something notable.",
                         "parameters": ["type": "OBJECT", "properties": ["text": ["type": "STRING"]], "required": ["text"]]],
                        // PHASE 5.5 — anything said mid-conversation can become a
                        // reminder without breaking the conversation to do it.
                        ["name": "set_reminder",
                         "description": "Set a reminder for the user. Use this WHENEVER they say anything that implies they want to be reminded, prompted or nudged about something later - even in passing, even mid-sentence, and even if they don't use the word 'remind'. Examples that should all call this: 'I must not forget to book that ferry tomorrow', 'chase that up on Friday', 'remind me about this later', 'I need to take the tablet at 8 every morning'. Work out the time from what they said and what time it is now. Prefer setting something over asking.",
                         "parameters": ["type": "OBJECT", "properties": [
                            "text": ["type": "STRING", "description": "What to remind them of, phrased as an instruction to them, e.g. 'Book the ferry'"],
                            "iso_time": ["type": "STRING", "description": "When it should fire, ISO 8601 with the local offset, e.g. 2026-09-14T18:30:00+08:00. Omit if this is a place reminder or has no time."],
                            "daily_time": ["type": "STRING", "description": "For something that happens at the same LOCAL time every day wherever they are, e.g. medication: 'HH:mm' in 24h. Use instead of iso_time."],
                            "place": ["type": "STRING", "description": "Fire it when they arrive somewhere instead of at a time, e.g. 'supermarket', 'home', 'the hotel'."],
                            "repeat_rule": ["type": "STRING", "description": "Optional. 'd1' daily, 'd3' every 3 days, 'w1' weekly, 'w1:mon,fri' those weekdays, 'm1' monthly. Add ! to count from when they complete it rather than the schedule, e.g. 'd3!' for laundry."],
                            "must_not_miss": ["type": "BOOLEAN", "description": "True for flights, medication, visas - anything that should break through Do Not Disturb."]
                         ], "required": ["text"]]],
                        ["name": "list_reminders",
                         "description": "Read back what the user has due today, overdue, and coming up. Use when they ask what's on, what they have to do, or how their day looks."],
                        ["name": "complete_reminder",
                         "description": "Mark a reminder done when the user says they have done it.",
                         "parameters": ["type": "OBJECT", "properties": ["text": ["type": "STRING", "description": "Roughly what the reminder said - matching is fuzzy."]], "required": ["text"]]],
                        ["name": "query_memory",
                         "description": "Search everything Chappy has ever stored - places saved, photos taken and captioned, conversations translated, documents scanned, notes logged, past chats. Use this BEFORE saying you don't know something about the user's own past. Free and instant.",
                         "parameters": ["type": "OBJECT", "properties": ["query": ["type": "STRING", "description": "Words to look for, e.g. 'warung coffee', 'scooter price', 'temple monkeys'"]], "required": ["query"]]],
                        ["name": "alert_when_near",
                         "description": "Watch the user's location and tell them when they get near a place (like their bus stop or a landmark).",
                         "parameters": ["type": "OBJECT", "properties": ["place": ["type": "STRING"]], "required": ["place"]]],
                        ["name": "open_website",
                         "description": "Open a website on the user's phone.",
                         "parameters": ["type": "OBJECT", "properties": ["url": ["type": "STRING"]], "required": ["url"]]],
                        ["name": "open_app",
                         "description": "Open an app on the phone by name: grab, gojek, whatsapp, google maps, youtube, instagram, telegram.",
                         "parameters": ["type": "OBJECT", "properties": ["app": ["type": "STRING"]], "required": ["app"]]],
                        ["name": "deep_research",
                         "description": "Send a question to the deep research brain for a thorough, current-facts answer (visa rules, is this a scam, detailed history of a temple, comparing options). Takes ~20 seconds - tell the user you are digging into it first.",
                         "parameters": ["type": "OBJECT", "properties": ["question": ["type": "STRING"]], "required": ["question"]]],
                        ["name": "emergency",
                         "description": "EMERGENCY: the user is in danger or urgently needs help. Speaks their exact location and the local emergency number, and opens a WhatsApp alert to their trusted contact."]
                    ]]
                ]
            ]
        ]

        sendJSON(setupMessage)
        print("⚙️ [Gemini] Send session configuration")
    }

    // MARK: - Audio Recording

    func startRecording() {
        // BUILD 125: intent is recorded FIRST and independently. Everything
        // that recovers the microphone keys off this, so a start that fails —
        // backgrounded, session busy, engine refusing — leaves a system that
        // still knows it is supposed to be listening.
        wantsRecording = true
        guard !isRecording else { return }

        do {
            print("🎤 [Gemini] Start recording")

            let audioSession = AVAudioSession.sharedInstance()
            switch audioSession.recordPermission {
            case .undetermined:
                audioSession.requestRecordPermission { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted {
                            self?.startRecording()
                        } else {
                            self?.onError?("Microphone permission denied")
                        }
                    }
                }
                return
            case .denied:
                onError?("Microphone permission denied")
                return
            case .granted:
                break
            @unknown default:
                break
            }

            // BUILD 125 (CRASH): removeTap used to be inside the isRunning
            // test, so a failed engine.start() left the tap installed on a
            // STOPPED engine and the next attempt installed a second one on the
            // same bus — an Objective-C exception that goes straight through
            // Swift's try/catch and takes the app down. LiveTranslateService
            // was given this exact fix; this file never was. Always remove.
            if let engine = audioEngine {
                if engine.isRunning { engine.stop() }
                engine.inputNode.removeTap(onBus: 0)
            }

            configureAudioSession()

            guard let engine = audioEngine else {
                print("❌ [Gemini] Audio engine not initialized")
                return
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            // BUILD 126 (THE CRASH): while the audio route is settling — the
            // instant the app opens, the instant it comes back from the lock
            // screen, the moment the glasses connect — the input format reads
            // back as 0 Hz for a beat. installTap with a zero sample rate or
            // zero channel count raises "required condition is false:
            // format.sampleRate == hwFormat.sampleRate", an Objective-C
            // exception that goes straight past Swift's try/catch and kills
            // the app outright.
            //
            // LiveTranslateService has had this guard since build 64. This file
            // never did — and build 125 made it far more likely to bite by
            // teaching chat to reclaim the microphone on foreground, on unlock
            // and after an interruption, which are precisely the three moments
            // the format is unsettled. Refuse, and come back in half a second.
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                formatDeferrals += 1
                guard formatDeferrals <= Self.maxFormatDeferrals else {
                    formatDeferrals = 0
                    print("❌ [Gemini] Input format never settled — giving up rather than looping")
                    onError?("Chappy can't get to the microphone. Close the chat and open it again.")
                    return
                }
                print("⚠️ [Gemini] Input format not ready (\(inputFormat.sampleRate) Hz) — deferring \(formatDeferrals)/\(Self.maxFormatDeferrals)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.wantsRecording, !self.isRecording else { return }
                    self.startRecording()
                }
                return
            }
            formatDeferrals = 0
            print("🎵 [Gemini] Input format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channels")

            if let recordTargetFormat {
                recordConverter = AVAudioConverter(from: inputFormat, to: recordTargetFormat)
            } else {
                recordConverter = nil
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer, inputFormat: inputFormat)
            }

            engine.prepare()
            try engine.start()

            isRecording = true
            restartAttempt = 0
            installRecordEngineWatchdog()
            print("✅ [Gemini] Recording started")

        } catch {
            // BUILD 125: leave nothing behind. The tap installed a few lines
            // above is still on the input node at this point, and it is the
            // thing that turns the NEXT attempt into a crash.
            audioEngine?.inputNode.removeTap(onBus: 0)
            isRecording = false
            print("❌ [Gemini] Failed to start recording: \(error.localizedDescription)")
            // Not surfaced to the wearer: reclaimMic retries with backoff and
            // only speaks up once it has genuinely given up.
        }
    }

    /// AUDIT FIX (LA-H1): iOS tears the engine's graph down whenever the audio
    /// route changes — Chappy's own TTS ducking, glasses connecting or dropping,
    /// AirPods, a phone call, CarPlay. Without this the tap is silently gone:
    /// the session looks alive, the meter keeps running and Chappy simply never
    /// hears another word. Rebuild the tap when the graph changes.
    private func installRecordEngineWatchdog() {
        guard engineWatchdogToken == nil, let engine = audioEngine else { return }
        engineWatchdogToken = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // BUILD 125: guard on INTENT, not on isRecording. The old guard was
            // `self.isRecording`, and the very first thing the body did was set
            // it false — so if the restart below then failed, this observer
            // could never fire again for the life of the object. It disarmed
            // itself at exactly the moment it was needed most.
            guard let self, self.wantsRecording, self.isSessionConfigured else { return }
            print("🔧 [Gemini] Audio engine reconfigured — rebuilding the mic tap")
            self.teardownCapture()
            // Backoff rather than a single 0.3 s shot: a route change during a
            // lock or a call needs longer than that before iOS will hand the
            // input back, and one failed try used to be the end of it.
            self.restartAttempt = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.reclaimMic(why: "engine reconfigured")
            }
        }
    }

    func stopRecording() {
        // BUILD 125: intent is cleared FIRST and unconditionally, before the
        // isRecording guard. Otherwise a stop pressed while capture happened to
        // be down left `wantsRecording` true, and the lifecycle observers would
        // dutifully reopen the microphone the wearer had just closed.
        wantsRecording = false
        wasRecordingBeforeBackground = false
        restartAttempt = 0
        guard isRecording else { return }

        print("🛑 [Gemini] Stop recording")
        teardownCapture()
        hasAudioBeenSent = false
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        // SCOOTER MODE: client-side voice detection — fire the freshest frame
        // the INSTANT the mic goes loud, no waiting for the server transcription
        // round trip. Glance + ask = answer about what you see RIGHT NOW.
        if let ch = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            if n > 0 {
                var sum: Float = 0
                let step = max(1, n / 256)
                var i = 0
                var count = 0
                while i < n {
                    sum += abs(ch[i])
                    i += step
                    count += 1
                }
                let level = sum / Float(max(count, 1))
                let now = Date()
                if level > 0.015 {
                    lastInteractionAt = now // ECO DRIP: voice = full rate
                    if now.timeIntervalSince(lastLoudAt) > 0.8 && !speechFrameFired {
                        speechFrameFired = true
                        endFrameFired = false
                        print("🎤⚡ [Gemini] Local speech detected — instant frame")
                        DispatchQueue.main.async { self.onSpeechStarted?() }
                    }
                    lastLoudAt = now
                } else if speechFrameFired && !endFrameFired {
                    // LIVE-SHOT: the scene often CHANGES while the user talks
                    // ("now how many fingers?"). The instant speech ENDS
                    // (~0.35s of quiet), push one more fresh frame so the
                    // answer is grounded in the very last thing they showed —
                    // not the moment they started the sentence.
                    let quiet = now.timeIntervalSince(lastLoudAt)
                    if quiet > 0.35 && quiet < 1.5 {
                        endFrameFired = true
                        print("🎤🏁 [Gemini] Speech ended — live-shot frame")
                        DispatchQueue.main.async { self.onSpeechStarted?() }
                    }
                }
            }
        }

        guard let recordConverter, let recordTargetFormat else { return }

        let ratio = recordTargetFormat.sampleRate / inputFormat.sampleRate
        let targetFrameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))

        guard let converted = AVAudioPCMBuffer(pcmFormat: recordTargetFormat, frameCapacity: max(1, targetFrameCapacity)) else {
            return
        }

        var hasProvidedInput = false
        var error: NSError?

        let status = recordConverter.convert(to: converted, error: &error) { _, outStatus in
            if hasProvidedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, status != .error else { return }
        guard let floatChannelData = converted.floatChannelData else { return }

        let frameLength = Int(converted.frameLength)
        let channel = floatChannelData.pointee

        var int16Data = [Int16](repeating: 0, count: frameLength)
        for i in 0..<frameLength {
            let sample = channel[i]
            let clampedSample = max(-1.0, min(1.0, sample))
            int16Data[i] = Int16(clampedSample * 32767.0)
        }

        let data = Data(bytes: int16Data, count: frameLength * MemoryLayout<Int16>.size)
        let base64Audio = data.base64EncodedString()

        sendRealtimeInput(audioData: base64Audio)

        if !hasAudioBeenSent {
            hasAudioBeenSent = true
            print("✅ [Gemini] First audio sent")
            DispatchQueue.main.async { [weak self] in
                self?.onFirstAudioSent?()
            }
        }
    }

    // MARK: - Send Events

    // MARK: - Tool Dispatch (Phase 4 Step 7)

    private func handleToolCall(_ toolCall: [String: Any]) {
        guard let calls = toolCall["functionCalls"] as? [[String: Any]] else { return }
        Task { @MainActor in
            var responses: [[String: Any]] = []
            for call in calls {
                let name = call["name"] as? String ?? ""
                let id = call["id"] as? String ?? ""
                let args = call["args"] as? [String: Any] ?? [:]
                let result = await self.runTool(name: name, args: args)
                responses.append(["id": id, "name": name, "response": ["result": result]])
            }
            self.sendJSON(["tool_response": ["function_responses": responses]])
        }
    }

    @MainActor
    private func runTool(name: String, args: [String: Any]) async -> String {
        print("🔧 [Gemini] Tool: \(name) args: \(args)")
        switch name {
        case "navigate_to":
            // AUDIT FIX (NAV-MODE): the model narrates the mode in its own
            // words but the TOOL defaults to "walk". So it would say "driving
            // you there" out loud, pass no mode, get a walking route, and then
            // the Google Maps hand-off (which reads NavEngine.lastDriving)
            // opened walking directions — the spoken word and the actual route
            // disagreed. Fall back to what the USER actually said rather than
            // to a silent default.
            let mode = (args["mode"] as? String ?? "").lowercased()
            let spoken = currentUserLine.lowercased()
            let saidDrive = ["drive", "driving", "by car", "in the car", "taxi",
                             "grab", "scooter", "motorbike", "ride"]
                .contains { spoken.contains($0) }
            let driving = mode.isEmpty
                ? saidDrive
                : (mode.contains("driv") || mode.contains("car") || mode.contains("taxi"))
            let dest = args["destination"] as? String ?? ""
            print("🧭 [Gemini] navigate_to '\(dest)' mode='\(mode)' spokenSaidDrive=\(saidDrive) → driving=\(driving)")
            let summary = await NavEngine.shared.navigate(to: dest, driving: driving)
            // Ground the narration: tell the model, in the tool result, which
            // mode it actually got, so it can't invent the other one.
            return "[route mode: \(driving ? "DRIVING" : "WALKING") — say this mode, not the other] " + summary
        case "get_me_home":
            return await NavEngine.shared.getHome()
        case "stop_navigation":
            NavEngine.shared.stop()
            return "Navigation stopped."
        case "remember_spot":
            let spot = TripRecorder.shared.rememberSpot(named: args["name"] as? String ?? "")
            return "Saved current location as '\(spot.name)'."
        case "query_journal":
            return TripRecorder.shared.todaySummary()
        case "retrace_steps":
            return TripRecorder.shared.retraceGuidance()
        case "save_observation":
            TripRecorder.shared.addObservation(args["text"] as? String ?? "")
            return "Noted in the journal."
        case "set_reminder":
            let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 1 else { return "Nothing to remind them of." }
            var when: Date?
            if let iso = args["iso_time"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                when = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
            }
            let daily = args["daily_time"] as? String
            let place = (args["place"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rule = args["repeat_rule"] as? String
            let urgent = (args["must_not_miss"] as? Bool) ?? false
            // The frame goes with it. "Remind me to order THIS" only means
            // anything six weeks later if the picture came too.
            let frame = await MainActor.run {
                LiveAIManager.shared.streamViewModel?.currentVideoFrame?
                    .jpegData(compressionQuality: 0.4)
            }
            let saved = await MainActor.run {
                ChappyReminders.shared.add(title: text, at: when,
                                           floatingTime: daily,
                                           place: (place?.isEmpty == false) ? place : nil,
                                           repeatRule: rule,
                                           leadMinutes: (place?.isEmpty == false) ? 5 : nil,
                                           escalate: urgent,
                                           thumbnail: frame,
                                           source: "live-ai")
            }
            if let p = place, !p.isEmpty { return "Reminder set: '\(saved.title)' when they get to \(p). Confirm it briefly." }
            if let d = daily { return "Reminder set: '\(saved.title)' at \(d) local every day. Confirm it briefly." }
            if let w = when {
                let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
                return "Reminder set: '\(saved.title)' for \(f.string(from: w)). Confirm it briefly, in a few words."
            }
            return "Saved '\(saved.title)' to the list with no time. Ask when they want it."
        case "list_reminders":
            return await MainActor.run { ChappyReminders.shared.spokenList() }
        case "complete_reminder":
            let want = (args["text"] as? String ?? "").lowercased()
            return await MainActor.run { () -> String in
                guard let t = ChappyReminders.shared.open.first(where: {
                    $0.title.lowercased().contains(want) || want.contains($0.title.lowercased())
                }) else { return "No open reminder matches that - tell them so." }
                ChappyReminders.shared.complete(t.id)
                return "Marked '\(t.title)' done."
            }
        case "query_memory":
            let q = args["query"] as? String ?? ""
            let answer = await MainActor.run { ChappyMemory.shared.spokenRecall(q, limit: 6) }
            return answer ?? "Nothing stored about '\(q)'. Say so honestly rather than guessing."
        case "alert_when_near":
            return await NavEngine.shared.alertWhenNear(args["place"] as? String ?? "")
        case "open_website":
            if let s = args["url"] as? String, let u = URL(string: s.hasPrefix("http") ? s : "https://" + s) {
                await UIApplication.shared.open(u)
                return "Opened \(s) on the phone."
            }
            return "Invalid URL."
        case "open_app":
            return openApp(args["app"] as? String ?? "")
        case "deep_research":
            return await performDeepResearch(args["question"] as? String ?? "")
        case "emergency":
            return await runEmergency()
        default:
            return "Unknown tool \(name)."
        }
    }

    @MainActor
    private func openApp(_ app: String) -> String {
        let key = app.lowercased()
        // MAPS LAW: "maps" means GOOGLE Maps (with the current destination
        // loaded when navigating). Apple Maps only when explicitly asked.
        if key.contains("map") && !key.contains("apple") {
            let nav = NavEngine.shared
            var url: URL?
            if let d = nav.destinationCoord {
                let mode = nav.lastDriving ? "driving" : "walking"
                let appURL = URL(string: "comgooglemaps://?daddr=\(d.latitude),\(d.longitude)&directionsmode=\(mode)")
                if let u = appURL, UIApplication.shared.canOpenURL(u) {
                    url = u
                } else {
                    url = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(d.latitude),\(d.longitude)&travelmode=\(mode)")
                }
            } else {
                let appURL = URL(string: "comgooglemaps://")
                if let u = appURL, UIApplication.shared.canOpenURL(u) {
                    url = u
                } else {
                    url = URL(string: "https://maps.google.com/")
                }
            }
            if let u = url {
                UIApplication.shared.open(u)
                // BUILD 135: hand off CLEANLY from this path too — close
                // Chappy's map card/sheet and stop its own turn-by-turn,
                // same as the Standby path does. The card that "wouldn't
                // disappear" came through here.
                NotificationCenter.default.post(name: Notification.Name("chappyMapsCleanup"), object: nil)
                return nav.destinationCoord != nil
                    ? "Google Maps is opening with the destination and turn-by-turn loaded."
                    : "Google Maps is opening on the phone."
            }
        }
        if key.contains("apple") {
            if let u = URL(string: "maps://") { UIApplication.shared.open(u); return "Opening Apple Maps." }
        }
        let map: [String: String] = [
            "grab": "grab://", "gojek": "gojek://", "whatsapp": "whatsapp://",
            "youtube": "youtube://", "instagram": "instagram://", "telegram": "tg://"
        ]
        guard let scheme = map.first(where: { key.contains($0.key) })?.value, let u = URL(string: scheme) else {
            return "No link known for \(app)."
        }
        UIApplication.shared.open(u)
        return "Opening \(app) on the phone."
    }

    /// STEP 7: deep_research → the Claude brain (thorough, current, speakable)
    private func performDeepResearch(_ question: String) async -> String {
        guard !question.isEmpty else { return "No question given." }
        let key = APIKeyManager.shared.getAPIKey(for: .anthropic) ?? ""
        guard !key.isEmpty, let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return "Research brain unavailable - no key configured."
        }
        // AUDIT FIX (LA-C4): this is the most expensive single call in Chappy
        // (Opus plus live web search) and the MODEL decides when to make it —
        // no human presses a button. Uncapped, on a key baked into the build,
        // a talkative afternoon is a four-figure surprise. Cap it per day.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dayKey = "chappy_research_" + df.string(from: Date())
        let usedToday = UserDefaults.standard.integer(forKey: dayKey)
        guard usedToday < 15 else {
            return "That's fifteen deep-research runs today - my daily limit. I can still answer from what I know, or ask me again tomorrow."
        }
        UserDefaults.standard.set(usedToday + 1, forKey: dayKey)
        CostMeter.shared.addResearch()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 90
        let body: [String: Any] = [
            "model": "claude-opus-4-8",
            "max_tokens": 1500,
            "system": "You are the deep-research brain of Chappy, a voice assistant for a traveller in Asia. Current context: \(ContextEngine.shared.contextHeader()) Answer thoroughly but SPEAKABLE: plain sentences, no markdown, no lists, under 250 words. Use web search for current facts.",
            "messages": [["role": "user", "content": question]],
            "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": 3]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            return "Research failed - the deep brain did not answer this time."
        }
        let text = content.compactMap { ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }.joined(separator: " ")
        return text.isEmpty ? "Research came back empty." : text
    }

    /// STEP 7: EMERGENCY PROTOCOL — location + local number + WhatsApp alert
    @MainActor
    private func runEmergency() async -> String {
        let snap = ContextEngine.shared.snapshot
        var address = ""
        if let s = snap.street { address += s }
        if let c = snap.city { address += address.isEmpty ? c : ", \(c)" }
        if let co = snap.country { address += address.isEmpty ? co : ", \(co)" }
        if address.isEmpty { address = "location unknown - GPS not fixed yet" }
        let numbers: [String: String] = ["ID": "112", "TH": "191", "VN": "113", "PH": "911",
                                         "KH": "117", "LA": "1191", "MY": "999", "SG": "995", "AU": "000"]
        let emergencyNumber = numbers[snap.countryCode ?? ""] ?? "112"
        var report = "EMERGENCY. The user is at \(address). The local emergency number is \(emergencyNumber)."
        if let lat = snap.latitude, let lon = snap.longitude {
            report += " Coordinates \(lat), \(lon)."
            let contact = UserDefaults.standard.string(forKey: "chappy_emergency_contact") ?? ""
            if !contact.isEmpty,
               let u = URL(string: "https://wa.me/\(contact)?text=EMERGENCY%20-%20I%20need%20help.%20My%20location:%20https://maps.google.com/?q=\(lat),\(lon)") {
                await UIApplication.shared.open(u)
                report += " A WhatsApp emergency message to the trusted contact is open on the phone - press send."
            }
        }
        return report + " Read ALL of this to the user immediately, clearly and calmly, and repeat the emergency number."
    }

    /// STEP 8 FUSION: nav speaks THROUGH the live conversation — Chappy's
    /// voice, camera-aware turns referencing what the user can actually see.
    func announceNavStep(_ instruction: String) {
        sendAppReply("Navigation instruction to deliver NOW: '\(instruction)'. Say it briefly in one sentence; if a distinctive landmark visible in the current camera frame marks the turn (a shop, sign or building), mention it - like: turn right at the 7-Eleven ahead.")
    }

    /// PHASE 4: hand the model an app-computed answer to speak (journal
    /// results, saved-spot confirmations). Sent as a completed user turn
    /// so Chappy replies out loud in its own voice.
    // MARK: - Nav Bridge v2 (full-sentence, debounced)

    /// Every phrasing that means "start navigation". Matched inside the
    /// accumulated user sentence, so word order and politeness don't matter.
    private static let navPhrases = [
        "navigate me to ", "navigate us to ", "navigate to ",
        "take me to ", "walk me to ", "drive me to ", "direct me to ",
        "get me directions to ", "directions to ", "get me to ",
        "guide me to ", "route me to ", "route to ",
        "the closest ", "the nearest "
    ]

    /// Follow-up phrasings that change HOW to travel ("navigate me via car")
    /// without repeating the destination.
    private static let modePhrases = [
        "via car", "by car", "in the car", "drive there", "driving there",
        "via scooter", "by scooter", "on the scooter", "on my scooter",
        "via bike", "by motorbike", "walk there", "on foot", "walking there"
    ]

    private func scheduleNavDetection() {
        let lower = currentUserLine.lowercased()
        let hasIntent = lower.contains("navigate") || lower.contains("navigation")
            || lower.contains("directions") || lower.contains("direct me")
            || lower.contains("route me")
        guard hasIntent
            || Self.navPhrases.contains(where: { lower.contains($0) })
            || Self.modePhrases.contains(where: { lower.contains($0) }) else { return }
        navDetectWork?.cancel()
        let lineSnapshot = currentUserLine
        let work = DispatchWorkItem { [weak self] in self?.fireNavDetection(on: lineSnapshot) }
        navDetectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func fireNavDetection(on line: String) {
        guard !journalCommandFired else { return }
        // Find the LAST matching phrase so lead-ins ("hey can you please
        // navigate me to...") don't poison the destination.
        var best: Range<String.Index>? = nil
        for phrase in Self.navPhrases {
            var searchRange = line.startIndex..<line.endIndex
            while let r = line.range(of: phrase, options: .caseInsensitive, range: searchRange) {
                if best == nil || r.upperBound > best!.upperBound { best = r }
                searchRange = r.upperBound..<line.endIndex
            }
        }
        let lowerLine = line.lowercased()
        let wantsDrive = lowerLine.contains("drive") || lowerLine.contains("driving")
            || lowerLine.contains(" car") || lowerLine.contains("scooter")
            || lowerLine.contains("motorbike") || lowerLine.contains("taxi")
        guard let hit = best else {
            // FALLBACK A: nav intent word + " to X" anywhere in the sentence
            // ("Navigate me by car to Brisbane Airport") — the destination is
            // whatever follows the LAST " to ".
            let navIntent = lowerLine.contains("navigate") || lowerLine.contains("navigation")
                || lowerLine.contains("directions") || lowerLine.contains("direct me")
                || lowerLine.contains("route")
            if navIntent, let toRange = line.range(of: " to ", options: [.caseInsensitive, .backwards]) {
                var dest2 = String(line[toRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: .punctuationCharacters)
                if dest2.lowercased().hasPrefix("the ") { dest2 = String(dest2.dropFirst(4)) }
                // Cleaner Places queries: "closest sushi place" → "sushi place"
                for prefix in ["closest ", "nearest "] where dest2.lowercased().hasPrefix(prefix) {
                    dest2 = String(dest2.dropFirst(prefix.count))
                }
                if dest2.count > 1 {
                    journalCommandFired = true
                    print("🧭 [Gemini] Nav bridge fallback → '\(dest2)' driving=\(wantsDrive)")
                    Task { @MainActor in
                        let reply = await NavEngine.shared.navigate(to: dest2, driving: wantsDrive)
                        self.sendAppReply("Navigation: \(reply) Tell the user this briefly.")
                    }
                    return
                }
            }
            // FALLBACK B: travel-mode-only follow-up like "navigate me via
            // car"? Re-route the LAST destination in the new mode.
            if Self.modePhrases.contains(where: { lowerLine.contains($0) }) {
                journalCommandFired = true
                let driving = !(lowerLine.contains("walk") || lowerLine.contains("on foot"))
                Task { @MainActor in
                    if let last = NavEngine.shared.lastQuery {
                        let reply = await NavEngine.shared.navigate(to: last, driving: driving)
                        self.sendAppReply("Navigation: \(reply) Tell the user this briefly.")
                    } else {
                        self.sendAppReply("Navigation: no destination given yet. Ask the user where they want to go.")
                    }
                }
            }
            return
        }
        var dest = String(line[hit.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        for mp in Self.modePhrases {
            if let r = dest.range(of: mp, options: .caseInsensitive) {
                dest = String(dest[..<r.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: .punctuationCharacters)
            }
        }
        for junk in ["thank you", "thanks", "please", "now"] {
            if dest.lowercased().hasSuffix(junk) {
                dest = String(dest.dropLast(junk.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: .punctuationCharacters)
            }
        }
        if dest.lowercased().hasPrefix("the ") { dest = String(dest.dropFirst(4)) }
        guard dest.count > 1 else { return }
        journalCommandFired = true
        print("🧭 [Gemini] Nav bridge v2 → '\(dest)'")
        if dest.lowercased() == "home" {
            Task { @MainActor in
                let reply = await NavEngine.shared.getHome()
                self.sendAppReply("Navigation: \(reply) Tell the user this briefly.")
            }
        } else {
            Task { @MainActor in
                let reply = await NavEngine.shared.navigate(to: dest, driving: wantsDrive)
                self.sendAppReply("Navigation: \(reply) Tell the user this briefly.")
            }
        }
    }

    // MARK: - Log This (voice notes into the journal)

    private func scheduleNoteDetection() {
        let lower = currentUserLine.lowercased()
        guard lower.contains("log this") || lower.contains("note this")
            || lower.contains("write this down") || lower.contains("make a note") else { return }
        noteDetectWork?.cancel()
        let snapshot = currentUserLine
        let work = DispatchWorkItem { [weak self] in self?.fireNoteDetection(on: snapshot) }
        noteDetectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func fireNoteDetection(on line: String) {
        guard !journalCommandFired else { return }
        journalCommandFired = true
        var note = ""
        for p in ["write this down", "make a note", "log this", "note this"] {
            if let r = line.range(of: p, options: .caseInsensitive) {
                note = String(line[r.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,:;.-!?"))
                break
            }
        }
        if note.count > 2 {
            TripRecorder.shared.addObservation(note)
            sendAppReply("The app logged this note in the journal, stamped with time and location: '\(note)'. Confirm to the user briefly: noted.")
        } else {
            sendAppReply("The user wants to log a note but the content was empty. Ask them to say it as one sentence, for example: log this, the hotel gate code is 4 4 2 1.")
        }
    }

    /// CONTEXT DRIP: silently refresh Chappy's real local time + location.
    /// turn_complete false = no spoken reply, it just updates the model's
    /// working knowledge (same mechanism as the post-renewal re-brief).
    private func sendContextUpdate() {
        // Never interleave a context turn while Chappy is mid-reply — that
        // risks confusing the audio stream. The next tick catches it.
        guard !isCollectingAudio else { return }
        sendJSON([
            "client_content": [
                "turns": [[
                    "role": "user",
                    "parts": [["text": "CONTEXT UPDATE (ground truth, do NOT reply to this): \(ContextEngine.shared.contextHeader())"]]
                ]],
                "turn_complete": false
            ]
        ])
    }

    private func sendAppReply(_ text: String) {
        sendJSON([
            "client_content": [
                "turns": [[
                    "role": "user",
                    "parts": [["text": "[APP MESSAGE - this is from the app, not spoken by the user] " + text]]
                ]],
                "turn_complete": true
            ]
        ])
    }

    private func sendJSON(_ json: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ [Gemini] Failed to serialize JSON")
            return
        }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocket?.send(message) { [weak self] error in
            if let error = error {
                print("❌ [Gemini] Send failed: \(error.localizedDescription)")
                self?.onError?("Send error: \(error.localizedDescription)")
            }
        }
    }

    private func sendRealtimeInput(audioData: String) {
        guard isSessionConfigured else { return }
        // Gemini Live realtime input format
        let message: [String: Any] = [
            "realtime_input": [
                "audio": ["data": audioData, "mime_type": "audio/pcm;rate=16000"]
            ]
        ]
        sendJSON(message)
    }

    /// Downscale a frame so its long side is at most `maxDimension` —
    /// keeps frames sharp enough to read signage while guaranteeing they
    /// stay well under the websocket message size limit.
    private func resizedForLive(_ image: UIImage, maxDimension: CGFloat = 1024) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension, maxSide > 0 else { return image }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    private var imageSendCount = 0

    // BACKPRESSURE CONTROL: never queue frames behind a slow upload.
    // If the previous frame is still in flight, SKIP this one — the next
    // tick sends a fresher frame instead. Queuing was making Gemini see
    // 10-20 second old pictures on slow connections.
    private var isFrameSendInFlight = false

    func sendImageInput(_ image: UIImage) {
        guard isSessionConfigured else { return }
        guard !isFrameSendInFlight else { return }

        // ECO DRIP: streaming frames while nobody's talking is pure cost.
        // After 45s of silence, drop to ~1 frame every 2.5s (an 8x saving);
        // the INSTANT the user speaks, the live-shot VAD fires a fresh frame
        // and full rate resumes — reactivity is untouched.
        let idle = Date().timeIntervalSince(lastInteractionAt)
        // AUDIT FIX (LA-C2): the pocketed-phone case. Ten minutes with neither
        // side saying a word means the session was forgotten, not paused —
        // close it rather than stream frames into an empty room all night.
        if idle > Self.maxSilentMinutes * 60 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isSessionConfigured else { return }
                TTSService.shared.speak("Nothing for ten minutes - I'm closing live to save your credit.")
                self.disconnect()
            }
            return
        }
        // AUDIT FIX (LA-C2): eco drip starts at 25s of quiet, not 45s.
        if idle > 25 {
            ecoSkipCounter += 1
            if ecoSkipCounter % 8 != 0 { return }
        } else {
            ecoSkipCounter = 0
        }

        // EAGLE MODE: small fast frames win for reactivity — a 512px frame
        // uploads 3-4x faster than 768px, so vision stays CURRENT even on a
        // slow/VPN connection. Fine detail comes from the on-demand high-res
        // "read this" frame, not the live drip.
        let prepared = resizedForLive(image, maxDimension: 512)
        guard var imageData = prepared.jpegData(compressionQuality: 0.6) else {
            print("❌ [Gemini] Failed to compress image")
            return
        }
        // Safety net: if still heavy, recompress harder rather than drop
        if imageData.count > 150 * 1024,
           let smaller = prepared.jpegData(compressionQuality: 0.4) {
            imageData = smaller
        }
        guard imageData.count <= 500 * 1024 else {
            print("⚠️ [Gemini] Frame too large even after recompress - skipping")
            return
        }

        let base64Image = imageData.base64EncodedString()

        imageSendCount += 1
        if imageSendCount == 1 || imageSendCount % 10 == 0 {
            print("📸 [Gemini] Sent frame #\(imageSendCount): \(imageData.count) bytes")
        }

        let message: [String: Any] = [
            "realtime_input": [
                "video": ["data": base64Image, "mime_type": "image/jpeg"]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ [Gemini] Failed to serialize frame")
            return
        }

        isFrameSendInFlight = true
        webSocket?.send(.string(jsonString)) { [weak self] error in
            self?.isFrameSendInFlight = false
            if let error = error {
                print("❌ [Gemini] Frame send failed: \(error.localizedDescription)")
            }
        }
    }

    /// One-shot FULL-SHARPNESS frame for reading fine print ("read this").
    /// Bypasses the 768px live-stream downscale — only caps extreme sizes —
    /// and jumps the in-flight queue because the user is waiting on it.
    func sendHighResImageInput(_ image: UIImage) {
        guard isSessionConfigured else { return }

        let prepared = resizedForLive(image, maxDimension: 1600)
        guard var imageData = prepared.jpegData(compressionQuality: 0.9) else {
            print("❌ [Gemini] Failed to compress high-res frame")
            return
        }
        if imageData.count > 800 * 1024,
           let smaller = prepared.jpegData(compressionQuality: 0.7) {
            imageData = smaller
        }
        guard imageData.count <= 1200 * 1024 else {
            print("⚠️ [Gemini] High-res frame too large - skipping")
            return
        }

        print("📖 [Gemini] Sending HIGH-RES frame: \(imageData.count) bytes")

        let message: [String: Any] = [
            "realtime_input": [
                "video": ["data": imageData.base64EncodedString(), "mime_type": "image/jpeg"]
            ]
        ]
        sendJSON(message)
    }

    // MARK: - Receive Messages

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage()

            case .failure(let error):
                let nsError = error as NSError
                print("❌ [Gemini] Failed to receive message: \(error.localizedDescription) [\(nsError.domain) \(nsError.code)]")
                // AUDIT FIX (LA-H2): 57/-999 are our own teardown; anything
                // else is a live socket dying mid-conversation — recover, don't
                // just report and go quiet forever.
                if nsError.code != 57 && nsError.code != -999 {
                    self?.attemptRecovery("receive error \(nsError.code)")
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleServerEvent(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                handleServerEvent(text)
            }
        @unknown default:
            break
        }
    }

    private func handleServerEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Handle setup complete
            if json["setupComplete"] != nil {
                print("✅ [Gemini] Session configured")
                self.isSessionConfigured = true
                self.onConnected?()
                Task { @MainActor in ChappyHaptics.shared.connected() }
                // HANDOVER: a question Standby judged too big for one shot
                // rides across into the live session and gets answered
                // properly — the user never repeats themselves.
                if let pending = UserDefaults.standard.string(forKey: "chappy_pending_question"),
                   !pending.isEmpty {
                    UserDefaults.standard.removeObject(forKey: "chappy_pending_question")
                    self.sendJSON([
                        "client_content": [
                            "turns": [["role": "user", "parts": [["text": pending]]]],
                            "turn_complete": true
                        ]
                    ])
                    print("🎯 [Gemini] Carried over standby question: \(pending)")
                }
                // COST METER: bank elapsed minutes across renewals
                if let started = self.liveSessionStartAt {
                    CostMeter.shared.addLiveSeconds(Date().timeIntervalSince(started))
                }
                self.liveSessionStartAt = Date()
                // AUDIT FIX (LA-C2): arm the runaway brakes.
                self.armSessionCap()
                // AUDIT FIX (LA-H2): a good handshake clears the recovery budget
                // so a later, unrelated drop still gets its three tries.
                self.recoveryAttempts = 0
                self.didReportSocketError = false
                // AUDIT FIX (LA-H10): the interlocks (Continuous Vision, the
                // stop intent, Quick Vision) all read LiveAIManager.isRunning,
                // which nothing ever set for a UI-started session — so every
                // one of them was a no-op. THIS is the live session; say so.
                Task { @MainActor in LiveAIManager.shared.isRunning = true }
                // CONTEXT DRIP: GPS usually locks a few seconds AFTER connect,
                // so the setup header is often empty. Re-feed real time+place
                // shortly after connect, then keep it fresh every 45s.
                self.contextTimer?.invalidate()
                self.contextTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
                    self?.sendContextUpdate()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    self?.sendContextUpdate()
                }
                // POST-RENEWAL RE-BRIEF: resumed sessions can come back with
                // amnesia ("I'm just a language model"). Re-inject identity as
                // silent context (turn_complete false = no spoken reply) and
                // drop a visible marker in the chat so renewals show themselves.
                if self.renewalCount > 0 {
                    self.onTranscriptDone?("🔁 [session renewed #\(self.renewalCount)]")
                    self.sendJSON([
                        "client_content": [
                            "turns": [[
                                "role": "user",
                                "parts": [["text": "SYSTEM REMINDER, do not reply to this: you are still Chappy, Shaun's glasses assistant. All persona, identity and vision rules remain fully in force. Live camera frames keep streaming from the glasses - always describe what they show when asked. Never call yourself a language model. Current context: \(ContextEngine.shared.contextHeader())\(recentLines.isEmpty ? "" : " Recent conversation before the reconnect: " + recentLines.suffix(10).joined(separator: " | ") + " Continue naturally from there.")"]]
                            ]],
                            "turn_complete": false
                        ]
                    ])
                }
                return
            }

            // SESSION CONTINUITY: keep the newest resumption handle
            if let update = json["sessionResumptionUpdate"] as? [String: Any] {
                if let handle = update["newHandle"] as? String, !handle.isEmpty {
                    self.resumptionHandle = handle
                }
                return
            }

            // goAway: session clock expiring — reconnect gracefully NOW,
            // resuming the same session via the stored handle.
            if json["goAway"] != nil {
                print("⏳ [Gemini] goAway received — renewing session")
                self.renewSession()
                return
            }

            // Handle server content (audio/text responses)
            if let serverContent = json["serverContent"] as? [String: Any] {
                self.handleServerContent(serverContent)
                return
            }

            // PHASE 4 STEP 7: real tool dispatch — Chappy's hands
            if let toolCall = json["toolCall"] as? [String: Any] {
                self.handleToolCall(toolCall)
                return
            }

            // Handle errors
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown error"
                print("❌ [Gemini] Server error: \(message)")
                self.onError?(message)
                return
            }
        }
    }

    private func handleServerContent(_ content: [String: Any]) {
        // Check for model turn
        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {

            for part in parts {
                // Handle text response
                if let text = part["text"] as? String {
                    print("💬 [Gemini] AIReply: \(text)")
                    onTranscriptDelta?(text)
                }

                // Handle inline audio data
                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   mimeType.contains("audio"),
                   let base64Audio = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: base64Audio) {

                    onAudioDelta?(audioData)
                    handleAudioChunk(audioData)
                }
            }
        }

        // Check if turn is complete
        if let turnComplete = content["turnComplete"] as? Bool, turnComplete {
            print("✅ [Gemini] AIReply complete")
            lastInteractionAt = Date() // ECO DRIP: conversation = full rate
            finishAudioPlayback()
            onTranscriptDone?("")
            // VOICE WATCHDOG: text without a single audio chunk = server-side
            // voice loss. First strike: rebuild the playback engine. Second
            // strike in a row: silently renew the session (context survives
            // via the resumption handle) — voice comes back on its own.
            if !currentModelLine.isEmpty {
                if audioChunksThisTurn == 0 {
                    consecutiveSilentTurns += 1
                    print("🔇 [Gemini] Turn had TEXT but no AUDIO (\(consecutiveSilentTurns) in a row) — reviving")
                    Task { @MainActor in ChappyHaptics.shared.voiceRevived() }
                    stopPlaybackEngine()
                    setupPlaybackEngine()
                    if consecutiveSilentTurns >= 2 {
                        consecutiveSilentTurns = 0
                        print("🔇 [Gemini] Voice watchdog: renewing session to restore audio")
                        renewSession()
                    }
                } else {
                    consecutiveSilentTurns = 0
                }
            }
            audioChunksThisTurn = 0
            // Re-arm the instant-eyes + journal triggers for the next question
            speechFrameFired = false
            endFrameFired = false
            journalCommandFired = false
            // STEP 8: roll the finished turn into the conversation memory
            if !currentUserLine.isEmpty {
                recentLines.append("User: " + currentUserLine)
                currentUserLine = ""
            }
            if !currentModelLine.isEmpty {
                recentLines.append("Chappy: " + currentModelLine)
                currentModelLine = ""
            }
            if recentLines.count > 20 { recentLines.removeFirst(recentLines.count - 20) }
        }

        // Check for interrupted flag
        if let interrupted = content["interrupted"] as? Bool, interrupted {
            print("⚠️ [Gemini] Reply interrupted")
            stopPlaybackEngine()
            setupPlaybackEngine()
        }

        // Handle input transcription (user speech)
        if let inputTranscription = content["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String {
            print("👤 [Gemini] User said: \(text)")
            currentUserLine += text
            // INSTANT EYES: the moment the user starts talking, fire a fresh
            // frame immediately (no waiting for the next 0.5s tick) so the
            // answer is grounded in what they are looking at RIGHT NOW.
            if !speechFrameFired {
                speechFrameFired = true
                onSpeechStarted?()
            }
            onUserTranscript?(text)

            // "READ THIS" DETECTION: when the user asks for reading, ship one
            // full-sharpness frame so fine print is actually legible.
            let lower = text.lowercased()
            if lower.contains("read th") || lower.contains("read it")
                || lower.contains("read me")                 || lower.contains("what do these") {
                print("📖 [Gemini] Read request detected — requesting high-res frame")
                onReadRequest?()
            }

            // PHASE 4 STEP 4 — JOURNAL VOICE COMMANDS (pre-tool-calling
            // bridge, same trick as "read this"): the app does the work,
            // then hands Chappy the answer to speak in its own voice.
            if !journalCommandFired {
                if lower.contains("remember this spot") || lower.contains("remember this place")
                    || lower.contains("remember where") {
                    journalCommandFired = true
                    var name = ""
                    if let r = text.range(of: "call it ", options: .caseInsensitive) {
                        name = String(text[r.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: .punctuationCharacters)
                    }
                    let spot = TripRecorder.shared.rememberSpot(named: name)
                    sendAppReply("The app just saved this location as a remembered spot named '\(spot.name)'. Briefly confirm this to the user in one short sentence.")
                } else if lower.contains("where was i today") || lower.contains("where have i been")
                    || lower.contains("where did i go") {
                    journalCommandFired = true
                    sendAppReply("Journal answer: \(TripRecorder.shared.todaySummary()) Relay this to the user naturally and briefly.")
                } else if lower.contains("i'm lost") || lower.contains("im lost") || lower.contains("i am lost") {
                    journalCommandFired = true
                    sendAppReply("Location help: \(TripRecorder.shared.lostReport()) Relay this calmly and briefly, then offer to retrace their steps.")
                } else if lower.contains("trace my steps") || lower.contains("retrace my steps")
                    || lower.contains("way i came") {
                    journalCommandFired = true
                    sendAppReply("Retrace data: \(TripRecorder.shared.retraceGuidance()) Relay the route back to the user briefly.")
                } else if lower.contains("chappy emergency") || lower.contains("emergency emergency") {
                    journalCommandFired = true
                    Task { @MainActor in
                        let report = await self.runEmergency()
                        self.sendAppReply(report)
                    }
                } else if lower.contains("stop navigation") || lower.contains("stop navigating")
                    || lower.contains("cancel navigation") {
                    journalCommandFired = true
                    Task { @MainActor in NavEngine.shared.stop() }
                    sendAppReply("Navigation has been stopped. Briefly confirm to the user.")
                } else if lower.contains("battery check") || lower.contains("battery status")
                    || lower.contains("battery level") || lower.contains("how's the battery") {
                    journalCommandFired = true
                    Task { @MainActor in
                        UIDevice.current.isBatteryMonitoringEnabled = true
                        let lvl = UIDevice.current.batteryLevel
                        let phone = lvl >= 0 ? "\(Int(lvl * 100)) percent" : "unknown"
                        self.sendAppReply("Phone battery is at \(phone). Glasses battery isn't exposed to the app - the Meta AI app shows it. Report this briefly.")
                    }
                } else if lower.contains("cost check") || lower.contains("usage check")
                    || lower.contains("i spent today on ai") || lower.contains("how much have i spent") {
                    journalCommandFired = true
                    let t = CostMeter.shared.today()
                    let month = CostMeter.shared.monthCostUSD()
                    sendAppReply(String(format: "AI usage estimate: about $%.2f today with %.0f live minutes and %d research dives; roughly $%.2f this month. These are rough over-estimates. Report briefly.", t.4, t.0, t.3, month))
                } else if lower.contains("take a photo") || lower.contains("take a picture")
                    || lower.contains("take a snapshot") || lower.contains("snap a photo")
                    || lower.contains("capture that") || lower.contains("capture this") {
                    // VOICE SHUTTER: fire the glasses' photo capture; the
                    // stream pipeline saves it to the phone's Photos.
                    journalCommandFired = true
                    NotificationCenter.default.post(name: .chappyCapturePhoto, object: nil)
                    sendAppReply("The app is taking a photo through the glasses right now and saving it to the phone's photo library. Confirm briefly: photo taken.")
                } else if lower.contains("my coordinates") || lower.contains("my co-ordinates")
                    || lower.contains("gps position") || lower.contains("exact position")
                    || lower.contains("exact location") {
                    // GPS TRUTH: the app answers with exact figures, no guessing
                    journalCommandFired = true
                    let s = ContextEngine.shared.snapshot
                    if let la = s.latitude, let lo = s.longitude {
                        var place = [s.street, s.suburb, s.city].compactMap { $0 }.joined(separator: ", ")
                        if place.isEmpty { place = "street name still resolving" }
                        sendAppReply(String(format: "Exact GPS position from the phone: latitude %.5f, longitude %.5f - %@. Read the coordinates clearly and slowly to the user.", la, lo, place))
                    } else {
                        sendAppReply("No GPS fix yet. Tell the user to give it a few seconds, ideally outdoors.")
                    }
                } else if lower.contains("open google maps") || lower.contains("open maps")
                    || lower.contains("open the maps") || lower.contains("real maps") {
                    // GOOGLE MAPS HANDOFF: launch the real Google Maps app
                    // with the current/last destination pre-loaded.
                    journalCommandFired = true
                    Task { @MainActor in
                        let nav = NavEngine.shared
                        var url: URL?
                        if let d = nav.destinationCoord {
                            let mode = nav.lastDriving ? "driving" : "walking"
                            let appURL = URL(string: "comgooglemaps://?daddr=\(d.latitude),\(d.longitude)&directionsmode=\(mode)")
                            if let u = appURL, UIApplication.shared.canOpenURL(u) {
                                url = u
                            } else {
                                url = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(d.latitude),\(d.longitude)&travelmode=\(mode)")
                            }
                        } else if let q = nav.lastQuery?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                            url = URL(string: "https://www.google.com/maps/search/?api=1&query=\(q)")
                        }
                        if let u = url {
                            await UIApplication.shared.open(u)
                            // BUILD 135: clean handoff from the nav bridge too.
                            NotificationCenter.default.post(name: Notification.Name("chappyMapsCleanup"), object: nil)
                            self.sendAppReply("Google Maps is opening on the phone with the destination loaded. Confirm this briefly.")
                        } else {
                            self.sendAppReply("Navigation: no destination known yet. Ask the user where they want to go first.")
                        }
                    }
                } else if lower.contains("get me home") || lower.contains("take me home") {
                    journalCommandFired = true
                    Task { @MainActor in
                        let reply = await NavEngine.shared.getHome()
                        self.sendAppReply("Navigation: \(reply) Tell the user this briefly.")
                    }
                } else {
                    // NAV BRIDGE v2: transcripts arrive in fragments, so match
                    // on the ACCUMULATED sentence with a short debounce - this
                    // catches "navigate ME to X", "directions to X", "the
                    // closest IGA" and never cuts the destination in half.
                    scheduleNavDetection()
                    // LOG THIS: same debounce trick — capture the whole note
                    scheduleNoteDetection()
                }
            }
        }

        // Handle output transcription (AI speech text)
        if let outputTranscription = content["outputTranscription"] as? [String: Any],
           let text = outputTranscription["text"] as? String {
            print("💬 [Gemini] AIText: \(text)")
            currentModelLine += text
            onTranscriptDelta?(text)
        }
    }

    // MARK: - Audio Playback

    private func handleAudioChunk(_ audioData: Data) {
        if !isCollectingAudio {
            isCollectingAudio = true
            audioBuffer = Data()
            audioChunkCount = 0
            hasStartedPlaying = false

            if isPlaybackEngineRunning {
                stopPlaybackEngine()
                setupPlaybackEngine()
                startPlaybackEngine()
                playerNode?.play()
                print("🔄 [Gemini] Re-initialize the playback engine")
            }
        }

        audioChunkCount += 1
        audioChunksThisTurn += 1

        if !hasStartedPlaying {
            audioBuffer.append(audioData)

            if audioChunkCount >= minChunksBeforePlay {
                hasStartedPlaying = true
                playAudio(audioBuffer)
                audioBuffer = Data()
            }
        } else {
            playAudio(audioData)
        }
    }

    private func finishAudioPlayback() {
        isCollectingAudio = false

        if !audioBuffer.isEmpty {
            playAudio(audioBuffer)
            audioBuffer = Data()
        }

        audioChunkCount = 0
        hasStartedPlaying = false
        onAudioDone?()
    }

    private func playAudio(_ audioData: Data) {
        // Health check FIRST: if the engine died since the last chunk
        // (route change / interruption), rebuild it — then grab the
        // fresh playerNode below so buffers land on the LIVE node.
        if let engine = playbackEngine, !engine.isRunning, isPlaybackEngineRunning {
            revivePlaybackEngine()
        }

        guard let playerNode = playerNode,
              let playbackAudioFormat else {
            return
        }

        if !isPlaybackEngineRunning {
            startPlaybackEngine()
            playerNode.play()
        } else if !playerNode.isPlaying {
            playerNode.play()
        }

        guard let pcmBuffer = createPCMBuffer(from: audioData, format: playbackAudioFormat) else {
            return
        }

        playerNode.scheduleBuffer(pcmBuffer)
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = data.count / 2

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            let dst = channelData.pointee
            for i in 0..<frameCount {
                dst[i] = Float(int16Pointer[i]) / 32768.0
            }
        }

        return buffer
    }
}

// MARK: - Error Reporting

extension GeminiLiveService {
    /// Surfaces the FIRST socket failure to the UI (TestFlight has no console,
    /// so prints alone are useless in the field). Subsequent errors from the
    /// same collapse are suppressed to avoid stacked alerts.
    fileprivate func reportSocketError(_ message: String) {
        guard !didReportSocketError else { return }
        didReportSocketError = true
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension GeminiLiveService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ [Gemini] WebSocket Connection established")
        DispatchQueue.main.async {
            self.configureSession()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason given"
        print("🔌 [Gemini] WebSocket Disconnected, closeCode: \(closeCode.rawValue), reason: \(reasonString)")
        // Session-duration abort (1008 after a missed goAway): reconnect
        // silently instead of showing an error — the renewed session resumes
        // where it left off via the resumption handle.
        if closeCode.rawValue == 1008 && reasonString.lowercased().contains("goaway") {
            print("⏳ [Gemini] Session-duration abort — auto-renewing")
            DispatchQueue.main.async { self.renewSession() }
            return
        }
        // 1000/1001 = normal shutdown (our own disconnect). AUDIT FIX (LA-H2):
        // everything else used to be terminal — one alert and a dead session.
        if closeCode != .normalClosure && closeCode != .goingAway {
            attemptRecovery("code \(closeCode.rawValue): \(reasonString)")
        }
    }

    /// AUDIT FIX (LA-H2): a socket death that isn't a goAway — a WiFi-to-cell
    /// handover, a VPN reconnect, a lift, a 5xx from Google — used to kill the
    /// session permanently: one alert on screen, glasses silent, and the only
    /// cure was force-quitting the app. Reconnect on the resumption handle
    /// (context intact), three tries with backoff, and only tell the user if
    /// all three fail.
    private func attemptRecovery(_ why: String) {
        guard isUserSessionActive else { return }
        guard recoveryAttempts < 3 else {
            reportSocketError("Live connection lost (\(why)). Start Live again to reconnect.")
            return
        }
        recoveryAttempts += 1
        let delay = Double(recoveryAttempts) * 1.5
        print("🔁 [Gemini] Recovery \(recoveryAttempts)/3 in \(delay)s — \(why)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isUserSessionActive, !self.isSessionConfigured else { return }
            self.renewSession()
        }
    }

    /// SESSION CONTINUITY: tear down just the socket and reconnect with the
    /// stored resumption handle. Mic and playback keep running — the send
    /// gate holds frames/audio until the renewed session is configured.
    private func renewSession() {
        guard !isRenewingSession else { return }
        isRenewingSession = true
        renewalCount += 1
        isSessionConfigured = false
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.isRenewingSession = false
            print("🔁 [Gemini] Reconnecting (resume handle: \(self.resumptionHandle != nil ? "yes" : "none"))")
            self.connect()
        }
    }

    /// Fires when the connection dies at the HTTP upgrade stage (didOpen never runs).
    /// This is where a 401/403/404 from Google shows up — the exact thing we've
    /// been blind to on TestFlight builds.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil { return }
        if let nsError = error as NSError?, nsError.code == NSURLErrorCancelled { return }
        var details: [String] = []
        if let http = task.response as? HTTPURLResponse {
            details.append("HTTP \(http.statusCode)")
        }
        if let error = error {
            let nsError = error as NSError
            details.append("\(error.localizedDescription) [\(nsError.code)]")
        }
        guard !details.isEmpty else { return }
        let message = "Connection failed: " + details.joined(separator: " — ")
        print("❌ [Gemini] \(message)")
        reportSocketError(message)
    }
}

// MARK: - Chappy internal notifications
extension Notification.Name {
    static let chappyCapturePhoto = Notification.Name("chappyCapturePhoto")
    static let chappyOpenTranslate = Notification.Name("chappyOpenTranslate")
    static let chappyOpenGoogleMaps = Notification.Name("chappyOpenGoogleMaps")
    /// BUILD 90: "close", "done", "exit" — dismiss whatever module is on screen.
    /// Live AI could be opened by voice but only closed by a button, which is
    /// useless with the phone in a pocket.
    static let chappyCloseModules = Notification.Name("chappyCloseModules")
    /// Change the language of a translate session that is already running.
    static let chappyRetargetTranslate = Notification.Name("chappyRetargetTranslate")
    /// Voice-triggered scan when the camera isn't already streaming.
    static let chappyWakeCameraForScan = Notification.Name("chappyWakeCameraForScan")
    /// Silent snap when the camera isn't already streaming.
    static let chappyWakeCameraForSnap = Notification.Name("chappyWakeCameraForSnap")
    /// Background-only Live AI start (no UI). Kept separate from
    /// .liveAITriggered so one trigger can never start two sessions.
    static let liveAIBackgroundStart = Notification.Name("liveAIBackgroundStart")
    static let chappyShowMap = Notification.Name("chappyShowMap")
    /// PHASE 5: open the memory browser by voice.
    static let chappyOpenMemory = Notification.Name("chappyOpenMemory")
    /// PHASE 5.5: open the reminders list by voice.
    static let chappyOpenReminders = Notification.Name("chappyOpenReminders")
}
