/*
 * Text-to-Speech Service
 * Default voice: Gemini TTS (natural, expressive) using the Gemini API key.
 * Fallback: Apple system TTS (free, offline) when no key / no network / error.
 */

import Foundation
import AVFoundation
import NaturalLanguage
import CryptoKit

/// BUILD 125 — ONE VOICE.
///
/// Build 109 split Chappy's mouth in two: short lines went to Apple's on-device
/// voice because they were instant, long lines went to Gemini because it sounds
/// human. The result was an assistant that changed sex every other sentence —
/// "Saved" in one voice, the answer that followed in another. That is worse
/// than either voice on its own, and it was my doing.
///
/// The fix is not to choose between them. It is to stop paying the network toll
/// twice for the same sentence. Chappy's short lines are a small, finite,
/// repeating set — "Route's off", "Map's up", "Saved", "Having a look". Render
/// each one through Gemini ONCE, keep the audio on disk, and every time after
/// it plays instantly, in the right voice, with no signal at all.
///
/// Raw PCM16 @ 24 kHz is what Gemini hands back and what the playback engine
/// wants, so nothing is transcoded on either side of the cache.
private final class VoiceCache {

    static let shared = VoiceCache()

    /// Total bytes to keep. PCM16 @ 24 kHz is ~48 KB per second, so 60 MB is
    /// roughly twenty minutes of speech — far more than the repeating set ever
    /// needs, and nothing next to a phone full of photos.
    private static let budgetBytes = 60 * 1024 * 1024

    private let dir: URL
    private let io = DispatchQueue(label: "chappy.voice.cache", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("ChappyVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// The voice is part of the key. Change voice in Settings and every line
    /// re-renders in the new one rather than serving the old voice from disk —
    /// which is exactly the flip-flop this whole class exists to end.
    private func filename(text: String, voice: String) -> String {
        let digest = SHA256.hash(data: Data("\(voice)|\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".pcm"
    }

    func url(text: String, voice: String) -> URL {
        dir.appendingPathComponent(filename(text: text, voice: voice))
    }

    func has(text: String, voice: String) -> Bool {
        FileManager.default.fileExists(atPath: url(text: text, voice: voice).path)
    }

    /// Returns cached audio and stamps the file as used, so pruning can be LRU
    /// rather than arbitrary.
    func load(text: String, voice: String) -> Data? {
        let u = url(text: text, voice: voice)
        guard let data = try? Data(contentsOf: u), !data.isEmpty else { return nil }
        io.async {
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                   ofItemAtPath: u.path)
        }
        return data
    }

    func save(_ data: Data, text: String, voice: String) {
        guard !data.isEmpty else { return }
        let u = url(text: text, voice: voice)
        io.async { [weak self] in
            try? data.write(to: u, options: .atomic)
            self?.pruneIfNeeded()
        }
    }

    /// Oldest-used first, down to the budget. Runs on the io queue only.
    private func pruneIfNeeded() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }

        var total = 0
        var entries: [(url: URL, size: Int, used: Date)] = []
        for u in items {
            let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = vals?.fileSize ?? 0
            let used = vals?.contentModificationDate ?? .distantPast
            total += size
            entries.append((u, size, used))
        }
        guard total > Self.budgetBytes else { return }

        for e in entries.sorted(by: { $0.used < $1.used }) {
            try? fm.removeItem(at: e.url)
            total -= e.size
            if total <= Self.budgetBytes { break }
        }
        print("🔊 [VoiceCache] Pruned to \(total / 1024) KB")
    }

    /// Wipe everything — used when the wearer changes voice and wants the disk
    /// back, and by Settings' "clear cached speech".
    func clear() {
        io.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(at: self.dir, includingPropertiesForKeys: nil)) ?? []
            for u in items { try? fm.removeItem(at: u) }
            print("🔊 [VoiceCache] Cleared")
        }
    }

    var fileCount: Int {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).count
    }
}

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

    // Gemini TTS models — primary, with fallback name if Google renames tiers.
    // BUILD 143: 2.5 promoted to PRIMARY — half the price of 3.1 ($10 vs $20
    // per million audio tokens) and typically faster to first byte, and the
    // voice test proved latency is the whole battle. 3.1 stays as fallback.
    private let ttsModels = ["gemini-2.5-flash-preview-tts", "gemini-3.1-flash-tts-preview"]

    /// Gemini prebuilt voice. Change via UserDefaults key "chappy_tts_voice".
    /// Nice options: Kore (warm female), Puck (male), Aoede, Charon, Fenrir, Leda.
    private var voiceName: String {
        UserDefaults.standard.string(forKey: "chappy_tts_voice") ?? "Kore"
    }

    /// BUILD 125: above this length a line is almost certainly a one-off AI
    /// answer that will never be said twice, so caching it only burns disk.
    /// Chappy's repeating vocabulary — confirmations, refusals, nav calls — is
    /// comfortably under it.
    fileprivate static let cacheableLimit = 200

    /// BUILD 125: ONE Apple voice, chosen once and pinned.
    ///
    /// When Apple's voice does have to speak — no key, no cached copy, no
    /// signal — it must at least always be the SAME Apple voice. Left to
    /// itself, `AVSpeechSynthesisVoice(language:)` returns whatever the system
    /// feels like that day, which is a second way for Chappy to change person
    /// mid-conversation. Resolve it once, write the identifier down, and use
    /// that identifier forever after.
    private func pinnedSystemVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let key = "chappy_pinned_voice_\(language)"
        if let saved = UserDefaults.standard.string(forKey: key),
           let v = AVSpeechSynthesisVoice(identifier: saved) {
            return v
        }

        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased() == language.lowercased() }
        guard !candidates.isEmpty else { return nil }

        // Match the sex of the chosen Gemini voice where iOS will tell us, so
        // the fallback is as close a relative as the device can offer.
        var pool = candidates
        if #available(iOS 17.0, *) {
            let wanted: AVSpeechSynthesisVoiceGender = Self.femaleGeminiVoices.contains(voiceName) ? .female : .male
            let matched = candidates.filter { $0.gender == wanted }
            if !matched.isEmpty { pool = matched }
        }

        // Prefer the nicest available, then settle it deterministically so two
        // launches never disagree.
        let ranked = pool.sorted { a, b in
            if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
            return a.identifier < b.identifier
        }
        guard let chosen = ranked.first else { return nil }
        UserDefaults.standard.set(chosen.identifier, forKey: key)
        print("🔊 [TTS] Pinned fallback voice for \(language): \(chosen.name) (\(chosen.identifier))")
        return chosen
    }

    /// Gemini's prebuilt voices, split so the Apple fallback can match.
    private static let femaleGeminiVoices: Set<String> = [
        "Kore", "Aoede", "Leda", "Zephyr", "Autonoe", "Callirrhoe",
        "Despina", "Erinome", "Gacrux", "Laomedeia", "Pulcherrima",
        "Vindemiatrix", "Sulafat", "Achernar", "Sadachbia"
    ]

    // BUILD 139 — THE VOICE SELF-TEST.
    //
    // "All the voices sound the same" is not a taste problem — it means every
    // Gemini render is FAILING and every preview is the one Apple fallback.
    // This makes one real render and says exactly why it failed, out loud,
    // because the wearer can't read the Xcode console from a moving scooter.
    func runVoiceSelfTest() {
        Task { [weak self] in
            guard let self else { return }
            let key = APIKeyManager.shared.getGoogleAPIKey() ?? ""
            guard !key.isEmpty else {
                self.speak("No Google key is set, so every voice falls back to this Apple one. Add the Gemini key in Settings.")
                return
            }
            Self.geminiVoiceGaveUp = false   // the test must actually try
            do {
                let audio = try await self.requestGeminiAudio(
                    text: "This is my real voice, and it's working.",
                    model: self.ttsModels[0], apiKey: key)
                VoiceCache.shared.save(audio, text: "This is my real voice, and it's working.", voice: self.voiceName)
                let gen = self.beginSpeaking(estimatedCharacters: 40)
                defer { Task { @MainActor in self.endSpeaking(gen) } }
                try await self.playPCM(audio, gen: gen)
                self.speak("That was the Gemini voice, working fine. If things sound robotic later it's a temporary network drop, not a setup problem.")
            } catch {
                let msg: String
                let desc = error.localizedDescription
                if desc.contains("429") {
                    msg = "Google says the voice quota is used up — error four two nine. That's why everything sounds like this robot. The Gemini key is on the free tier for speech: turn on billing for it in Google A I Studio, or the quota resets each day."
                } else if desc.contains("403") {
                    msg = "Google refused the key — error four zero three. The key works for pictures but is blocked for speech. Check the key's API restrictions in Google A I Studio."
                } else if desc.contains("404") {
                    msg = "The speech model name was not found — error four zero four. Tell Claude: the T T S model needs renaming."
                } else {
                    msg = "The voice service failed: \(desc). If this keeps happening, tell Claude exactly this message."
                }
                self.speak(msg)
                print("🔊 [TTS] Self-test failed: \(desc)")
            }
        }
    }

    /// Forget the pinned choices — used when the wearer changes voice so the
    /// fallback re-matches the new one.
    static func repinSystemVoices() {
        let d = UserDefaults.standard
        for (k, _) in d.dictionaryRepresentation() where k.hasPrefix("chappy_pinned_voice_") {
            d.removeObject(forKey: k)
        }
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
    /// Once the network voice has failed, stop asking it. Chappy changing voice
    /// every other sentence is worse than never using the nicer one.
    private static var geminiGaveUpAt: Date?
    /// AUDIT P2: this used to latch forever on a single transient error, so one
    /// bad moment of signal cost the nicer voice until the app was restarted.
    /// Thirty minutes is long enough to stop it flip-flopping sentence to
    /// sentence, short enough that a tunnel doesn't cost you the rest of the day.
    static var geminiVoiceGaveUp: Bool {
        get {
            guard let t = geminiGaveUpAt else { return false }
            // BUILD 143: five minutes, not thirty. With the render timeout
            // fixed, a latch now means a genuine outage — and outages end.
            // Half an hour of robot over one bad moment was the real insult.
            if Date().timeIntervalSince(t) > 300 { geminiGaveUpAt = nil; return false }
            return true
        }
        set { geminiGaveUpAt = newValue ? Date() : nil }
    }

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
    /// The last line spoken aloud. Kept so "what?" / "say that again" can
    /// replay it — the single most natural thing to say when you mishear
    /// someone, and it had no handler anywhere in the app.
    private(set) var lastSpokenLine: String = ""

    override private init() {
        super.init()
        setupPlaybackEngine()
        installPlaybackResilience()

        // BUILD 125: warm the voice cache a few seconds after launch, off the
        // critical path. Once the repeating vocabulary is on disk this is a
        // no-op forever, so it costs one quiet burst on the first run and
        // nothing after. Deliberately self-contained — no other file has to
        // remember to call it.
        Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.warmCache()
        }
    }

    /// BUILD 125: notice a voice change without Settings having to tell us.
    /// The cache is keyed by voice so it can never serve the wrong one, but the
    /// PINNED Apple fallback has to re-match, and the old voice's audio is dead
    /// weight worth reclaiming.
    private func noticeVoiceChange() {
        let current = voiceName
        let key = "chappy_tts_voice_last_seen"
        let previous = UserDefaults.standard.string(forKey: key)
        guard previous != current else { return }
        UserDefaults.standard.set(current, forKey: key)
        guard previous != nil else { return }   // first run, nothing to clear
        print("🔊 [TTS] Voice changed \(previous ?? "?") → \(current) — resetting cache and fallback")
        VoiceCache.shared.clear()
        Self.repinSystemVoices()
        Self.geminiVoiceGaveUp = false
        warmCache()
    }

    // MARK: - Speaking-flag lifecycle (deadlock-proof)

    // ==================================================================
    // THE DEADLOCK. Confirmed from the build-80 crash report, not guessed.
    //
    //   Thread 0 (main):
    //     __ulock_wait2
    //     _os_unfair_lock_lock_slow
    //     ObservableObjectPublisher.Inner.send()
    //     Published.subscript.setter
    //     CameraAccess ...
    //   Termination: FRONTBOARD 0x8BADF00D
    //     "Failed to terminate gracefully after 5.0s"
    //
    // The main thread is parked forever on Combine's internal lock inside a
    // @Published setter. That happens when a @Published property is written
    // from a background thread while the main thread is publishing, and
    // `isSpeaking` is written by beginSpeaking()/endSpeaking()/stop(), all of
    // which are called from wherever the caller happens to be: URLSession
    // completion handlers, audio callbacks, Timer fires, async contexts.
    //
    // This is MY regression and I can date it exactly. In build 69 the archive
    // failed with "call to main actor-isolated instance method
    // 'beginSpeaking' in a synchronous nonisolated context", and I removed the
    // @MainActor annotation to make it compile — with a comment claiming
    // "callers are main-thread in practice". They are not. Silencing the
    // compiler's thread-safety warning is what created the hang.
    //
    // Every write to the published flag now goes through here. Already on the
    // main thread, write directly; otherwise hop ASYNC — never sync, which
    // would be a second way to deadlock.
    private func setSpeaking(_ value: Bool, since: Date?) {
        if Thread.isMainThread {
            isSpeaking = value
            speakingSince = since
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isSpeaking = value
                self?.speakingSince = since
            }
        }
    }


    /// Claim the speaking flag and return the generation token that owns it.
    /// NOT @MainActor: speak()/speakOffline call this synchronously from
    /// nonisolated context and need the token back immediately — annotating it
    /// was a compile error (build 69, caught at archive). State mutation here
    /// matches the file's existing pattern: callers are main-thread in practice.
    private func beginSpeaking(estimatedCharacters: Int) -> Int {
        speechGeneration &+= 1
        let gen = speechGeneration
        setSpeaking(true, since: Date())

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
                self.setSpeaking(false, since: nil)
                // Unblock anything still parked on a continuation.
                self.resumeSystemContinuation()
                self.systemSynthesizer?.stopSpeaking(at: .immediate)
            }
        }
        return gen
    }

    /// Release the flag, but only if a newer utterance hasn't already claimed it.
    /// Callers hop to the main thread via Task { @MainActor in ... } — the
    /// method itself stays nonisolated so those Tasks compile.
    private func endSpeaking(_ gen: Int) {
        guard speechGeneration == gen else { return }
        setSpeaking(false, since: nil)
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

            // BUILD 125: "offline" used to mean "Apple's voice", because the
            // only way to avoid the network was to avoid Gemini. With a disk
            // cache it no longer does — a saved phrase you have heard before
            // plays in Chappy's real voice with the radio off, which is the
            // whole point of saved phrases. Still zero network either way.
            let voice = self.voiceName
            if voice != "System",
               let cached = VoiceCache.shared.load(text: trimmed, voice: voice) {
                do {
                    try await self.playPCM(cached, gen: gen)
                    return
                } catch {
                    if Task.isCancelled { return }
                }
            }
            await self.fallbackToSystemTTS(text: trimmed, languageCode: languageCode)
        }
    }

    // MARK: - BUILD 125: cache warm-up

    /// The lines Chappy actually repeats. Rendering these once on wifi means
    /// the wearer effectively never hears a cold one — every confirmation,
    /// refusal and nav call comes off the disk instantly, in the real voice,
    /// for the rest of the phone's life.
    ///
    /// Pulled from the literal `speak(...)` calls in LiveAIManager, so this is
    /// the vocabulary as it actually exists rather than a guess at it.
    private static let warmPhrases: [String] = [
        "Got it.", "Done.", "Noted.", "Saved.", "No worries.", "I'm listening.",
        "Route's off.", "Map's up.", "Right, heading home.", "Let me get you home.",
        "Opening Live AI.", "Opening Google Maps.", "Memory's open.",
        "Having a look.", "Let me look.", "Let me read it.", "Eyes open.",
        "Reading that now.", "Reading through them now.", "Checking the label.",
        "Where do you want to go?", "What should I log?", "Remember what?",
        "Here's your list.", "Nothing to snooze.", "Nothing new to import.",
        "Nothing photographed today.", "Nothing left to read through.",
        "No GPS fix yet.", "Finding you another way.", "Quiet mode.",
        "Tour mode.", "Budget mode on.", "Back to normal.",
        "One thing at a time - still on the last.",
        "I don't have a reminder like that.",
        "I don't speak that one yet, sorry.",
        "Just quiet, or stop the route as well?",
        "That deserves a proper conversation - give me a moment."
    ]

    /// Render anything in the warm list that isn't cached yet. Serial, gentle,
    /// and silent — it never plays a sound. Safe to call on every launch: once
    /// the set is on disk this does nothing at all.
    func warmCache() {
        let voice = voiceName
        guard voice != "System" else { return }
        let key = APIKeyManager.shared.getGoogleAPIKey() ?? ""
        guard !key.isEmpty else { return }

        let missing = Self.warmPhrases.filter { !VoiceCache.shared.has(text: $0, voice: voice) }
        guard !missing.isEmpty else {
            print("🔊 [TTS] Voice cache warm (\(VoiceCache.shared.fileCount) lines)")
            return
        }

        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            print("🔊 [TTS] Warming the voice cache — \(missing.count) lines to render")
            var made = 0
            for phrase in missing {
                // One at a time, with a breath between, so warming never
                // competes with a line the wearer is actually waiting on.
                if Self.geminiVoiceGaveUp { break }
                do {
                    let audio = try await self.requestGeminiAudio(
                        text: phrase, model: self.ttsModels[0], apiKey: key)
                    VoiceCache.shared.save(audio, text: phrase, voice: voice)
                    CostMeter.shared.addTTSChars(phrase.count)
                    made += 1
                } catch {
                    // A warm-up is a nicety. If it can't run, the normal path
                    // still renders on demand — never surface this.
                    print("🔊 [TTS] Warm-up stopped: \(error.localizedDescription)")
                    break
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            print("🔊 [TTS] Voice cache warmed — \(made) new lines")
        }
    }

    /// Called when the wearer picks a different voice in Settings: the old
    /// voice's audio is dead weight, and the Apple fallback needs to re-match.
    func voiceChanged() {
        VoiceCache.shared.clear()
        Self.repinSystemVoices()
        Self.geminiVoiceGaveUp = false
        warmCache()
    }

    /// BUILD 132 — ONE VOICE ON THE ROAD.
    ///
    /// Nav lines are unique ("Turn left onto Ann Street") so the warm list can
    /// never hold them — every turn was a live network render, and the first
    /// render that failed in traffic latched the Apple fallback for half an
    /// hour. The wearer heard the robot voice precisely when Chappy was doing
    /// its most impressive thing.
    ///
    /// So: the moment a route is computed, render EVERY step of it into the
    /// cache in the background. By the time the wearer reaches turn one, the
    /// whole route speaks from disk — instant, offline-proof, in the ONE voice.
    func prerender(_ lines: [String]) {
        let voice = voiceName
        guard voice != "System" else { return }
        let key = APIKeyManager.shared.getGoogleAPIKey() ?? ""
        guard !key.isEmpty else { return }
        let missing = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !VoiceCache.shared.has(text: $0, voice: voice) }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // BUILD 135: the route summary is being rendered and SPOKEN right
            // now, over the same network the route lookup just used. Starting
            // the pre-render in the same instant caused the very failure it
            // exists to prevent — a rate-limited render latching the robot
            // voice. Wait for the summary to finish before warming the turns.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            print("🔊 [TTS] Pre-rendering \(missing.count) nav lines")
            for line in missing {
                if Self.geminiVoiceGaveUp { break }
                do {
                    let audio = try await self.requestGeminiAudio(
                        text: line, model: self.ttsModels[0], apiKey: key)
                    VoiceCache.shared.save(audio, text: line, voice: voice)
                    CostMeter.shared.addTTSChars(line.count)
                } catch {
                    // A pre-render is a nicety; the normal path still renders
                    // on demand. Never latch the fallback over one of these.
                    print("🔊 [TTS] Pre-render stopped: \(error.localizedDescription)")
                    break
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    // =================================================================
    // BUILD 158 — SPEAKING LONG ANSWERS WITHOUT THE WAIT
    // =================================================================
    //
    //   Gemini renders audio at roughly 25 tokens a second, so a
    //   paragraph-length answer takes fifteen to twenty seconds to
    //   generate before a single word can play. Quick Vision showed the
    //   text instantly and then sat in silence — which felt broken even
    //   though nothing was.
    //
    //   Every streaming assistant solves this the same way: don't render
    //   the paragraph, render the FIRST SENTENCE. It comes back in about
    //   two seconds and starts playing while sentence two renders behind
    //   it. Same voice, same quality, first word roughly nine times
    //   sooner.
    //
    //   Short lines (one sentence, under ~140 characters) go straight
    //   down the normal path — chunking them would only add overhead.

    func speakLong(_ text: String, languageCode: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let chunks = Self.sentenceChunks(trimmed)
        guard chunks.count > 1 else {
            speak(trimmed, languageCode: languageCode)
            return
        }
        // First chunk out loud immediately; the rest queue behind it.
        speak(chunks[0], languageCode: languageCode)
        let rest = Array(chunks.dropFirst())
        // BUILD 162 — WHY THE VOICE WENT HALF-ROBOT.
        //
        // This used to fire prerenderNow(rest) in the same instant as the
        // live render of chunk one — several Gemini TTS calls at once, over
        // the same connection. That is a 429 waiting to happen, and two
        // consecutive failures latch the Apple fallback for five minutes.
        // It is precisely the mistake BUILD 135 documented for navigation,
        // repeated here.
        //
        // Now: warm only ONE chunk ahead, and only after the current one is
        // actually speaking. Same seamlessness, a quarter of the requests,
        // no thundering herd.
        Task { @MainActor in
            for chunk in rest {
                self.prerenderNow([chunk])
                // Wait for the current line to finish, with a hard ceiling
                // so a stuck player can never freeze the rest of the answer.
                var waited = 0
                while self.isSpeaking && waited < 600 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
                if Task.isCancelled { return }
                self.speak(chunk, languageCode: languageCode)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Like prerender, but without the eight-second politeness delay —
    /// used when the lines are about to be spoken in the next breath.
    private func prerenderNow(_ lines: [String]) {
        let voice = voiceName
        guard voice != "System" else { return }
        let key = APIKeyManager.shared.getGoogleAPIKey() ?? ""
        guard !key.isEmpty else { return }
        let missing = lines.filter { !VoiceCache.shared.has(text: $0, voice: voice) }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for line in missing {
                if Self.geminiVoiceGaveUp { break }
                do {
                    let audio = try await self.requestGeminiAudio(
                        text: line, model: self.ttsModels[0], apiKey: key)
                    VoiceCache.shared.save(audio, text: line, voice: voice)
                    CostMeter.shared.addTTSChars(line.count)
                } catch {
                    // A warm-up is a nicety. It must never contribute to the
                    // failure count that latches the robot voice.
                    print("🔊 [TTS] Warm-up skipped: \(error.localizedDescription)")
                    break
                }
                // BUILD 162: breathing room between renders, same 350ms the
                // nav pre-render has always used. Back-to-back calls are what
                // earn a 429.
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    /// Split on sentence ends, then glue the short ones together — a
    /// three-word sentence on its own costs a whole round trip for
    /// nothing. Target is roughly 140 characters a chunk.
    static func sentenceChunks(_ text: String, target: Int = 140) -> [String] {
        var out: [String] = []
        var current = ""
        var sentence = ""
        for ch in text {
            sentence.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                sentence = ""
                guard !s.isEmpty else { continue }
                if current.isEmpty { current = s }
                else if current.count + s.count + 1 <= target { current += " " + s }
                else { out.append(current); current = s }
            }
        }
        let tail = (current + " " + sentence).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out.filter { !$0.isEmpty }
    }

    /// - Parameters:
    ///   - languageCode: AUDIT P1. The short-line fast path bypassed the
    ///     Gemini call, and with it the language handling — a short Indonesian
    ///     or Thai line was read aloud in an Australian accent. Pass the
    ///     language when you know it.
    ///   - forceNetworkVoice: AUDIT P1. Every voice sample in Settings is under
    ///     90 characters, so the fast path sent them ALL to the system voice —
    ///     the voice picker and "Test the voice" demonstrated a voice you were
    ///     not choosing. Settings passes true so you hear the real thing.
    func speak(_ text: String,
               apiKey: String? = nil,
               languageCode: String? = nil,
               forceNetworkVoice: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any previous speech
        currentTask?.cancel()
        stop()

        lastSpokenLine = trimmed
        noticeVoiceChange()
        let gen = beginSpeaking(estimatedCharacters: trimmed.count)
        currentTask = Task { [weak self] in
            guard let self else { return }
            // SB-DEADLOCK FIX: see speakOffline — one release point, all exits.
            defer { Task { @MainActor in self.endSpeaking(gen) } }

            let googleKey = APIKeyManager.shared.getGoogleAPIKey() ?? ""
            let wantsSystemVoice = (UserDefaults.standard.string(forKey: "chappy_tts_voice") ?? "Kore") == "System"

            // BUILD 125 — ONE VOICE, ALWAYS.
            //
            // The old code here split by LENGTH: anything under 90 characters
            // went to Apple's voice because Gemini is a network round trip and
            // short acknowledgements have to be instant. It worked, and it made
            // Chappy change sex every other sentence. Length is not a sane way
            // to choose a voice.
            //
            // Now there is exactly one voice, and speed comes from the disk
            // instead. Short lines repeat — "Route's off", "Map's up", "Saved"
            // — so the first time costs a round trip and every time after is a
            // file read. Faster than what it replaced, in the right voice, and
            // it works with no signal at all.
            //
            // Apple's voice is now a genuine last resort: no key, no cached
            // copy, and no network. When it does speak it speaks as ONE pinned
            // voice (see systemVoice) rather than whatever iOS picks that day.
            let voice = self.voiceName

            // 1. DISK. Instant, offline, right voice.
            if !wantsSystemVoice, !forceNetworkVoice,
               let cached = VoiceCache.shared.load(text: trimmed, voice: voice) {
                do {
                    try await self.playPCM(cached, gen: gen)
                    return
                } catch {
                    if Task.isCancelled { return }
                    // A cached file that won't play is a corrupt file. Drop it
                    // and let the network re-render rather than going mute.
                    try? FileManager.default.removeItem(
                        at: VoiceCache.shared.url(text: trimmed, voice: voice))
                    print("⚠️ [TTS] Cached line wouldn't play — re-rendering")
                }
            }

            // 2. NETWORK. Renders, plays, and keeps the audio for next time.
            if !googleKey.isEmpty, !wantsSystemVoice, !Self.geminiVoiceGaveUp {
                do {
                    try await self.speakWithGemini(text: trimmed, apiKey: googleKey, gen: gen)
                    // Only charge for audio that genuinely reached the speaker.
                    CostMeter.shared.addTTSChars(trimmed.count)
                    return
                } catch {
                    if Task.isCancelled { return }
                    // BUILD 135 — WHY NAV WENT ROBOT.
                    //
                    // One failed render latched the Apple voice for thirty
                    // minutes — and navigation is EXACTLY where one render
                    // fails: the route lookup, the geocode and the TTS all
                    // hit the network in the same two seconds, and a single
                    // dropped socket or 429 was enough. So the latch now
                    // costs TWO consecutive failures, with a breath between.
                    // Transient blips retry and stay in the real voice;
                    // genuine outages still fall back exactly as before.
                    do {
                        try await Task.sleep(nanoseconds: 800_000_000)
                        if Task.isCancelled { return }
                        try await self.speakWithGemini(text: trimmed, apiKey: googleKey, gen: gen)
                        CostMeter.shared.addTTSChars(trimmed.count)
                        return
                    } catch {
                        if Task.isCancelled { return }
                        Self.geminiVoiceGaveUp = true
                        print("⚠️ [TTS] Gemini TTS failed twice (\(error.localizedDescription)) — Apple voice until the cooldown clears")
                    }
                }
            } else if googleKey.isEmpty {
                print("🔊 [TTS] No Gemini key — using system TTS")
            }

            // 3. LAST RESORT.
            await self.fallbackToSystemTTS(text: trimmed, languageCode: languageCode)
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
        setSpeaking(false, since: nil)
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
                // BUILD 125: keep it BEFORE playing, so audio we paid for
                // survives even if playback then fails. Long lines are almost
                // always one-off AI answers — caching those would fill the disk
                // with speech that is never heard twice.
                if text.count <= Self.cacheableLimit {
                    VoiceCache.shared.save(audio, text: text, voice: voiceName)
                }
                print("🔊 [TTS] Gemini voice (\(voiceName)) speaking: \(text.prefix(50))…")
                try await playPCM(audio, gen: gen)
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
        // BUILD 143 — THE ROBOT'S REAL CAUSE, measured at last. The voice
        // self-test PASSED with a delay: Google takes 5-10s to GENERATE the
        // audio, and this 8s guillotine was beheading half the renders —
        // every casualty fell back to the robot and latched it. Twenty
        // seconds of patience, and the wait is bearable because the cache
        // and the nav pre-render make repeated lines instant anyway.
        request.timeoutInterval = 20

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
    private func playPCM(_ audioData: Data, gen: Int) async throws {
        configureAudioSession()
        startPlaybackEngine()
        guard let playbackEngine, playbackEngine.isRunning,
              let playbackFormat = playbackFormat,
              let buffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            // AUDIT P0: this used to `return`, which is indistinguishable from
            // success to the caller. So a failed playback charged the meter,
            // never latched the fallback, and the wearer got TOTAL SILENCE for
            // every long answer from then on — no voice, no tone, nothing on
            // screen, while the chip still read "Standby on". Throwing is what
            // routes him to the Apple voice instead of into a void.
            print("❌ [TTS] Could not prepare audio for playback")
            throw TTSError.noAudio
        }

        // AUDIT P0 (TTS-STALE): scheduling into a stopped or DETACHED node
        // throws an ObjC exception that goes straight through Swift's try/catch
        // and takes the app down. LiveTranslateService was given exactly this
        // guard; TTSService never was. `node.engine == nil` is the state a
        // media-services reset leaves behind.
        guard let node = playerNode, node.engine != nil else {
            print("❌ [TTS] Player node is detached — skipping playback")
            throw TTSError.noAudio
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
        // BUILD 125: pinned, not picked. AVSpeechSynthesisVoice(language:)
        // returns whichever voice the system fancies for that language, which
        // can differ between launches and after an iOS update — a second way
        // for Chappy to change person mid-conversation, on top of the one this
        // build removes. Resolve it once, remember the identifier, reuse it.
        utterance.voice = pinnedSystemVoice(for: language)
            ?? AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        print("🔊 [TTS] System TTS speaking (\(utterance.voice?.name ?? "?")): \(text.prefix(30))…")

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
    // AUDIT P2: these fired for ANY synthesizer, including a stale one being
    // torn down, so a late didCancel from the previous utterance unparked the
    // CURRENT one and cut it off mid-sentence. Only the live synthesizer counts.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard synthesizer === systemSynthesizer else { return }
        resumeSystemContinuation()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard synthesizer === systemSynthesizer else { return }
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
