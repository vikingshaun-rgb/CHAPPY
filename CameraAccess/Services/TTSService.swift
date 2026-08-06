/*
 * Text-to-Speech Service
 * Default voice: Gemini TTS (natural, expressive) using the Gemini API key.
 * Fallback: Apple system TTS (free, offline) when no key / no network / error.
 */

import Foundation
import AVFoundation
import NaturalLanguage

/// SB-DEADLOCK FIX: a checked continuation resumed twice is an instant crash,
/// and one never resumed is a permanent hang. Both were live in this file. This
/// gate makes "resume exactly once, from whichever thread arrives first" the
/// only possible outcome.
private final class ResumeGate {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?
    private var spent = false

    func arm(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if spent { lock.unlock(); c.resume(); return }
        cont = c
        lock.unlock()
    }

    /// Returns true if THIS call was the one that resumed it.
    @discardableResult
    func fire() -> Bool {
        lock.lock()
        if spent { lock.unlock(); return false }
        spent = true
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume()
        return true
    }
}

class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published var isSpeaking = false

    // Gemini TTS models — primary, with fallback name if Google renames tiers
    // Verified current 2026-08: 3.1 preview is the live tier; 2.5 preview kept as fallback
    private let ttsModels = ["gemini-3.1-flash-tts-preview", "gemini-2.5-flash-preview-tts"]

    /// Gemini prebuilt voice. Change via UserDefaults key "chappy_tts_voice".
    /// Nice options: Kore (warm female), Puck (male), Aoede, Charon, Fenrir, Leda.
    private var voiceName: String {
        UserDefaults.standard.string(forKey: "chappy_tts_voice") ?? "Kore"
    }

    // Playback engine (24 kHz PCM16 from Gemini)
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)
    private var isPlaybackEngineRunning = false

    // System TTS fallback
    private var systemSynthesizer: AVSpeechSynthesizer?
    private var systemTTSContinuation: CheckedContinuation<Void, Never>?
    /// SB-DEADLOCK FIX: `stop()` (any thread) and the synthesizer delegate (its
    /// own queue) both resumed this continuation. Two resumes of one checked
    /// continuation is a hard crash, and the nil-check between them was not
    /// atomic. All access is now funnelled through this lock.
    private let continuationLock = NSLock()

    private var currentTask: Task<Void, Never>?
    private var playbackResilienceInstalled = false

    /// SB-DEADLOCK FIX: `isSpeaking` is the barge-in gate for ChappyStandby —
    /// while it is true the wake word ignores EVERYTHING it hears. It was set
    /// true before an `await` that could never return (a lost synthesizer
    /// delegate callback or a lost scheduleBuffer completion), and every exit
    /// path that reset it was guarded by `!Task.isCancelled`. One lost callback
    /// left the flag true forever: the ear stayed armed, the chip stayed lit,
    /// and not one word was ever routed again. Generation + watchdog below make
    /// that state unreachable.
    private var speechGeneration = 0
    private var speakingWatchdog: Task<Void, Never>?
    /// When the current utterance was started — lets callers detect a stuck flag.
    private(set) var speakingSince: Date?

    override private init() {
        super.init()
        setupPlaybackEngine()
        installPlaybackResilience()
    }

    // MARK: - Speaking-flag lifecycle (deadlock-proof)

    /// Claim the speaking flag and return the generation token that owns it.
    @MainActor
    private func beginSpeaking(estimatedCharacters: Int) -> Int {
        speechGeneration &+= 1
        let gen = speechGeneration
        isSpeaking = true
        speakingSince = Date()

        // Ceiling: no utterance Chappy produces runs longer than this. Even a
        // long Live-AI answer is well under it, so the watchdog can only ever
        // fire on a genuinely lost callback.
        let ceiling = min(60.0, 8.0 + Double(estimatedCharacters) / 8.0)
        speakingWatchdog?.cancel()
        speakingWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ceiling * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.speechGeneration == gen, self.isSpeaking else { return }
                print("⏱️ [TTS] Watchdog: speech never reported completion after \(Int(ceiling))s — releasing the mic gate")
                self.isSpeaking = false
                self.speakingSince = nil
                // Unblock anything still parked on a continuation.
                self.resumeSystemContinuation()
                self.systemSynthesizer?.stopSpeaking(at: .immediate)
            }
        }
        return gen
    }

    /// Release the flag, but only if a newer utterance hasn't already claimed it.
    @MainActor
    private func endSpeaking(_ gen: Int) {
        guard speechGeneration == gen else { return }
        isSpeaking = false
        speakingSince = nil
        speakingWatchdog?.cancel()
        speakingWatchdog = nil
    }

    /// Resume the system-TTS continuation exactly once, from any thread.
    private func resumeSystemContinuation() {
        continuationLock.lock()
        let cont = systemTTSContinuation
        systemTTSContinuation = nil
        continuationLock.unlock()
        cont?.resume()
    }

    // MARK: - Playback Engine

    private func setupPlaybackEngine() {
        playbackEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let playbackEngine = playbackEngine,
              let playerNode = playerNode,
              let playbackFormat = playbackFormat else {
            print("❌ [TTS] Failed to initialize the playback engine")
            return
        }

        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
        playbackEngine.prepare()
        print("✅ [TTS] Playback engine initialized: Float32 @ 24kHz")
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // AUDIT FIX (CRITICAL): this used to force .playback on EVERY
            // spoken line. Any engine holding a microphone tap — Standby's
            // wake-word ear, Live AI's recorder, Continuous Vision's
            // voice-stop — lost its input the moment Chappy opened his mouth,
            // silently and permanently ("standby stops hearing me").
            // .playAndRecord plays exactly as well and never tears down a
            // recording route.
            // FS-2: this used to force mode .spokenAudio on every spoken line,
            // replacing the .voiceChat mode Translate deliberately sets for
            // hardware echo cancellation — and because startRecording() is
            // guarded by !isRecording, .voiceChat was never restored within a
            // conversation. One bubble tap and AEC was off for the rest of it.
            // It also added .allowBluetooth (which the iPhone-mic path
            // deliberately omits, so input could migrate to the glasses) and
            // cleared the output override set by applyOutputRoute.
            //
            // Leave an existing playAndRecord configuration exactly as it is.
            // Only configure the session when nobody else has.
            if session.category == .playAndRecord {
                try session.setActive(true)
            } else {
                try session.setCategory(.playAndRecord, mode: .voiceChat,
                                        options: [.duckOthers, .allowBluetooth,
                                                  .allowBluetoothA2DP, .defaultToSpeaker])
                try session.setActive(true)
            }
        } catch {
            print("⚠️ [TTS] Audio session configuration failed: \(error.localizedDescription) — continuing")
        }
    }

    /// AUDIT P0 (TTS-STALE): these gated on the self-maintained
    /// `isPlaybackEngineRunning` Bool rather than the engine's real state. iOS
    /// stops an engine on route changes and interruptions without asking, so
    /// that flag drifts out of truth and nothing ever corrects it — the exact
    /// mistake already fixed in LiveTranslateService, where the comment reads
    /// "the code trusted its own Bool". Ask the engine.
    private func startPlaybackEngine() {
        guard let playbackEngine, !playbackEngine.isRunning else { return }
        do {
            try playbackEngine.start()
            isPlaybackEngineRunning = true
        } catch {
            print("❌ [TTS] Playback engine failed to start: \(error)")
            isPlaybackEngineRunning = false
        }
    }

    private func stopPlaybackEngine() {
        if let node = playerNode, node.engine != nil {
            node.stop()
            node.reset()
        }
        if let playbackEngine, playbackEngine.isRunning {
            playbackEngine.stop()
        }
        isPlaybackEngineRunning = false
    }

    /// AUDIT P0 (TTS-STALE): a media-services reset detaches playerNode and
    /// leaves `node.engine == nil` — every later scheduleBuffer would then throw
    /// an ObjC exception straight through Swift's try/catch and take the app
    /// down. TTSService was the only audio component in the app with no
    /// interruption or reset observer at all.
    private func installPlaybackResilience() {
        guard !playbackResilienceInstalled else { return }
        playbackResilienceInstalled = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            print("🔊 [TTS] Media services reset — rebuilding playback engine")
            self.isPlaybackEngineRunning = false
            self.playbackEngine = nil
            self.playerNode = nil
            self.setupPlaybackEngine()
        }
    }

    // MARK: - Public Methods

    /// Pre-configure the audio session (call before stopping the stream)
    func prepareAudioSession() {
        configureAudioSession()
        print("🔊 [TTS] Audio session pre-configured")
    }

    /// Speak text.
    /// Priority: Gemini TTS (natural voice) → Apple system TTS (offline fallback).
    /// The apiKey parameter is accepted for backward compatibility but ignored;
    /// the Gemini key is read from the key store.
    /// FS-11: for saved phrases and replays we already KNOW the language, and
    /// the UI promises they work with no connection. Going through the network
    /// voice first meant a stalled 8-second socket on one bar of EDGE — the
    /// exact condition the feature exists for — with nothing on screen to say
    /// so. This path skips the network entirely.
    func speakOffline(_ text: String, languageCode: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentTask?.cancel()
        stop()
        let gen = beginSpeaking(estimatedCharacters: trimmed.count)
        currentTask = Task { [weak self] in
            guard let self else { return }
            // SB-DEADLOCK FIX: `defer` releases the flag on EVERY exit —
            // normal return, early return, thrown error, cancellation — where
            // the old `if !Task.isCancelled` guard released it on almost none.
            defer { Task { @MainActor in self.endSpeaking(gen) } }
            await self.fallbackToSystemTTS(text: trimmed, languageCode: languageCode)
        }
    }

    func speak(_ text: String, apiKey: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any previous speech
        currentTask?.cancel()
        stop()

        let gen = beginSpeaking(estimatedCharacters: trimmed.count)
        currentTask = Task { [weak self] in
            guard let self else { return }
            // SB-DEADLOCK FIX: see speakOffline — one release point, all exits.
            defer { Task { @MainActor in self.endSpeaking(gen) } }

            let googleKey = APIKeyManager.shared.getGoogleAPIKey() ?? ""
            let wantsSystemVoice = (UserDefaults.standard.string(forKey: "chappy_tts_voice") ?? "Kore") == "System"

            if !googleKey.isEmpty && !wantsSystemVoice {
                do {
                    try await self.speakWithGemini(text: trimmed, apiKey: googleKey, gen: gen)
                    CostMeter.shared.addTTSChars(trimmed.count)
                    return
                } catch {
                    if Task.isCancelled { return }
                    print("⚠️ [TTS] Gemini TTS failed (\(error.localizedDescription)) — falling back to system TTS")
                }
            } else {
                print("🔊 [TTS] No Gemini key — using system TTS")
            }

            await self.fallbackToSystemTTS(text: trimmed)
        }
    }

    /// Stop speaking
    func stop() {
        currentTask?.cancel()
        currentTask = nil
        stopPlaybackEngine()
        systemSynthesizer?.stopSpeaking(at: .immediate)
        // SB-DEADLOCK FIX: atomic, single-resume. The old code read the
        // continuation, resumed it and nilled it in three separate steps with
        // no lock, so a delegate callback landing between them resumed the same
        // continuation twice — an immediate hard crash, not an exception.
        resumeSystemContinuation()
        isSpeaking = false
        speakingSince = nil
        speakingWatchdog?.cancel()
        speakingWatchdog = nil
    }

    // MARK: - Gemini TTS

    private func speakWithGemini(text: String, apiKey: String, gen: Int) async throws {
        var lastError: Error = TTSError.unknown

        for model in ttsModels {
            do {
                let audio = try await requestGeminiAudio(text: text, model: model, apiKey: apiKey)
                try Task.checkCancellation()
                print("🔊 [TTS] Gemini voice (\(voiceName)) speaking: \(text.prefix(50))…")
                await playPCM(audio, gen: gen)
                return
            } catch TTSError.modelNotFound {
                print("⚠️ [TTS] Model \(model) not found — trying next")
                lastError = TTSError.modelNotFound
                continue
            } catch {
                throw error
            }
        }
        throw lastError
    }

    private func requestGeminiAudio(text: String, model: String, apiKey: String) async throws -> Data {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else { throw TTSError.invalidURL }

        let body: [String: Any] = [
            "contents": [["parts": [["text": text]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": ["voiceName": voiceName]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 8  // fail FAST to the system voice, never stall the session

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TTSError.invalidResponse }

        if http.statusCode == 404 { throw TTSError.modelNotFound }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            print("❌ [TTS] Gemini TTS HTTP \(http.statusCode): \(msg.prefix(200))")
            throw TTSError.httpError(http.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw TTSError.invalidResponse
        }

        for part in parts {
            if let inline = part["inlineData"] as? [String: Any],
               let b64 = inline["data"] as? String,
               let audio = Data(base64Encoded: b64) {
                return audio
            }
        }
        throw TTSError.noAudio
    }

    /// Play raw PCM16 @ 24 kHz and wait for playback to finish.
    /// - Parameter gen: the speech generation that owns this utterance. Used to
    ///   make the teardown conditional — see AUDIT P0 (TTS-STALE) below.
    private func playPCM(_ audioData: Data, gen: Int) async {
        configureAudioSession()
        startPlaybackEngine()
        guard let playbackEngine, playbackEngine.isRunning,
              let playbackFormat = playbackFormat,
              let buffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            print("❌ [TTS] Could not prepare audio for playback")
            return
        }

        // AUDIT P0 (TTS-STALE): scheduling into a stopped or DETACHED node
        // throws an ObjC exception that goes straight through Swift's try/catch
        // and takes the app down. LiveTranslateService was given exactly this
        // guard; TTSService never was. `node.engine == nil` is the state a
        // media-services reset leaves behind.
        guard let node = playerNode, node.engine != nil else {
            print("❌ [TTS] Player node is detached — skipping playback")
            return
        }
        node.play()

        // SB-DEADLOCK FIX: scheduleBuffer's completion handler is dropped
        // outright if the engine is stopped before the buffer is consumed — a
        // route change, an interruption, or a concurrent stop() all do it. This
        // await then never returned and isSpeaking stayed true for the life of
        // the app. Duration is known from the buffer itself, so the timeout is
        // exact rather than a guess.
        // A task group would NOT work here: withTaskGroup waits for every child,
        // so a timeout child finishing first still leaves the parked
        // continuation child hanging and the group never returns. The gate has
        // to be the continuation itself, resumed exactly once by whichever of
        // the two racers gets there first.
        let seconds = Double(buffer.frameLength) / playbackFormat.sampleRate
        let gate = ResumeGate()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            gate.arm(cont)
            node.scheduleBuffer(buffer) { gate.fire() }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 3.0) {
                if gate.fire() {
                    print("⏱️ [TTS] Playback completion was dropped — unparking after \(String(format: "%.1f", seconds + 3.0))s")
                }
            }
        }
        // small tail so the last samples aren't clipped
        try? await Task.sleep(nanoseconds: 150_000_000)

        // AUDIT P0 (TTS-STALE): this teardown used to be unconditional. When the
        // wearer barged in — "Chappy, stop… Chappy, navigate to the ATM" — the
        // OLD utterance was still parked on its dropped-completion timeout. It
        // woke up seconds later, after the new answer had already started, and
        // stopped the shared engine out from under it. The new answer died
        // mid-sentence for no visible reason. Only the generation that still
        // owns the voice is allowed to tear it down.
        let mine = await MainActor.run { self.speechGeneration == gen }
        guard mine else {
            print("🔊 [TTS] Stale utterance finished — leaving the current one alone")
            return
        }
        stopPlaybackEngine()
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = data.count / 2
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let floatData = buffer.floatChannelData?.pointee else { return nil }

        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                floatData[i] = Float(Int16(littleEndian: int16Buffer[i])) / 32768.0
            }
        }
        return buffer
    }

    // MARK: - System TTS Fallback (offline)

    private func fallbackToSystemTTS(text: String, languageCode: String? = nil) async {
        configureAudioSession()

        let synthesizer = AVSpeechSynthesizer()
        systemSynthesizer = synthesizer
        synthesizer.delegate = self

        let utterance = AVSpeechUtterance(string: text)
        // Voice chosen by the TEXT itself — the old app-language setting was
        // still "Chinese" from TurboMeta days and made English sound Chinese.
        // BUILD 54: the CJK-or-English test was too blunt. When the Gemini voice
        // is unavailable (no signal, which is exactly when you're standing in a
        // market), replaying an Indonesian line read it aloud in an Australian
        // accent. Identify the language on-device and use a matching voice.
        // WATCH-LIST FIX: NLLanguageRecognizer returns "zh-Hans"/"zh-Hant" but
        // the installed voices are "zh-CN"/"zh-HK"/"zh-TW", so the prefix match
        // failed and Chinese was read aloud by the Australian English voice.
        // Strip the script subtag, and prefer a language we were TOLD.
        func voiceLanguage(for code: String) -> String? {
            let base = String(code.split(separator: "-").first ?? "")
            let voices = AVSpeechSynthesisVoice.speechVoices().map(\.language)
            if let exact = voices.first(where: { $0.lowercased() == code.lowercased() }) { return exact }
            if base == "en" { return voices.contains("en-AU") ? "en-AU" : "en-US" }
            if base == "zh" {
                if code.lowercased().contains("hant") { return voices.first { $0.hasPrefix("zh-TW") || $0.hasPrefix("zh-HK") } }
                return voices.first { $0.hasPrefix("zh-CN") } ?? voices.first { $0.hasPrefix("zh") }
            }
            return voices.first { $0.hasPrefix(base + "-") || $0 == base }
        }

        var language = "en-AU"
        if let known = languageCode, let v = voiceLanguage(for: known) {
            language = v
        } else {
            let recogniser = NLLanguageRecognizer()
            recogniser.processString(text)
            if let code = recogniser.dominantLanguage?.rawValue, let v = voiceLanguage(for: code) {
                language = v
            }
        }
        utterance.voice = AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        print("🔊 [TTS] System TTS speaking: \(text.prefix(30))…")

        // SB-DEADLOCK FIX: the delegate callback is not guaranteed. If iOS
        // reconfigures the audio session under us — which is exactly what
        // ChappyStandby does one instant before this line, installing a mic tap
        // and calling setActive(true) — the utterance can end without ever
        // reporting didFinish or didCancel. This used to park forever.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    guard let self else { cont.resume(); return }
                    self.continuationLock.lock()
                    self.systemTTSContinuation = cont
                    self.continuationLock.unlock()
                    synthesizer.speak(utterance)
                }
            }
            group.addTask { [weak self] in
                // Apple's system voice runs near 3 characters per 100 ms at the
                // default rate; this ceiling sits well clear of any real line.
                let ceiling = min(45.0, 6.0 + Double(text.count) / 6.0)
                try? await Task.sleep(nanoseconds: UInt64(ceiling * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                print("⏱️ [TTS] System voice never reported finishing — unparking")
                self.resumeSystemContinuation()
            }
            await group.next()
            group.cancelAll()
        }
        resumeSystemContinuation()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {
    // SB-DEADLOCK FIX: both callbacks arrive on the synthesizer's own queue and
    // used to read-resume-nil without a lock, racing stop() on the main thread.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resumeSystemContinuation()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resumeSystemContinuation()
    }
}

// MARK: - Errors

private enum TTSError: LocalizedError {
    case invalidURL
    case invalidResponse
    case modelNotFound
    case noAudio
    case httpError(Int)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid TTS URL"
        case .invalidResponse: return "Invalid TTS response"
        case .modelNotFound: return "TTS model not found"
        case .noAudio: return "No audio in TTS response"
        case .httpError(let code): return "TTS HTTP error \(code)"
        case .unknown: return "Unknown TTS error"
        }
    }
}
