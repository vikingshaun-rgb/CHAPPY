/*
 * Live Translate ViewModel
 * Live Translate state management
 */

import Foundation
import SwiftUI
import UIKit
import NaturalLanguage

@MainActor
class LiveTranslateViewModel: ObservableObject {

    // MARK: - Connection State
    @Published var isConnected = false
    @Published var isRecording = false
    /// BUILD 56: line released to save resources. Everything on screen still
    /// works — tapping the mic brings it straight back.
    @Published var isAsleep = false
    // AUDIT FIX support: autostart is consumed once, cost is metered
    private var pendingAutostart = false
    private var suppressSettingsPush = false
    private var sessionStartAt: Date?

    // MARK: - Translation State
    @Published var currentTranslation = ""       // current translation result
    @Published var currentOriginal = ""          // what the speaker actually said
    @Published var streamingTranslation = ""     // streaming translation chunk
    @Published var streamingOriginal = ""        // streaming heard-speech chunk
    @Published var translationHistory: [TranslateRecord] = []

    // MARK: - Transcript (TRANSCRIPT v2)
    /// The running two-sided conversation, newest last. This is what the screen
    /// draws as bubbles and what Phase 5's memory store will file verbatim.
    @Published var transcript: [TranslateTurn] = []
    /// Session header: when it started and where you were when it did.
    @Published private(set) var sessionStartedAt: Date?
    @Published private(set) var sessionPlace: String?
    /// Optional human name for the session ("with the landlord").
    @Published var sessionLabel: String = ""

    // MARK: - Saved phrases (BUILD 55)
    /// The ten sentences that carry you everywhere. They're built from lines
    /// you've ALREADY said in a real conversation, so both languages are
    /// already known — which means they replay with no connection at all.
    @Published var phrases: [SavedPhrase] = []

    // MARK: - Error State
    @Published var errorMessage: String?
    @Published var showError = false

    // MARK: - Settings (persisted)
    @Published var sourceLanguage: TranslateLanguage {
        didSet {
            UserDefaults.standard.set(sourceLanguage.rawValue, forKey: "translate_source_language")
            updateServiceSettings()
        }
    }

    @Published var targetLanguage: TranslateLanguage {
        didSet {
            UserDefaults.standard.set(targetLanguage.rawValue, forKey: "translate_target_language")
            updateServiceSettings()
        }
    }

    @Published var selectedVoice: TranslateVoice {
        didSet {
            UserDefaults.standard.set(selectedVoice.rawValue, forKey: "translate_voice")
            updateServiceSettings()
        }
    }

    @Published var audioOutputEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioOutputEnabled, forKey: "translate_audio_enabled")
            updateServiceSettings()
        }
    }

    @Published var imageEnhanceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(imageEnhanceEnabled, forKey: "translate_image_enhance")
        }
    }

    /// Use iPhone microphone (instead of the glasses mic) 
    /// Glasses mic suits translating yourself; iPhone mic suits translating the other person
    @Published var usePhoneMic: Bool {
        didSet {
            UserDefaults.standard.set(usePhoneMic, forKey: "translate_use_phone_mic")
        }
    }

    /// BUILD 55: Indonesian and Thai both carry real formality. The interpreter
    /// was picking a register blind, which is fine at a warung and wrong in front
    /// of a landlord, an immigration officer or a policeman.
    @Published var politeMode: Bool {
        didSet {
            UserDefaults.standard.set(politeMode, forKey: "translate_polite")
            updateServiceSettings()
        }
    }

    /// BUILD 54: push the sound out of the iPhone's loudspeaker so a table can
    /// hear it, while the microphone stays exactly where it was. The glasses
    /// speaker is built to be heard by the wearer alone — fine walking down a
    /// street, useless across a table with two people listening.
    @Published var loudSpeaker: Bool {
        didSet {
            UserDefaults.standard.set(loudSpeaker, forKey: "translate_loud_speaker")
            translateService?.setLoudSpeaker(loudSpeaker)
        }
    }

    // MARK: - Video Frame (for image enhancement)
    var currentVideoFrame: UIImage?

    // MARK: - Private
    private var translateService: LiveTranslateService?
    private var imageTimer: Timer?
    /// BUILD 56: idle sleep — see startIdleCountdown().
    private var idleTimer: Timer?
    private var resumeRecordingOnConnect = false
    private static let idleSleepSeconds: TimeInterval = 180
    /// BUILD 55: deferred settings push — see updateServiceSettings().
    private var pendingSettingsPush = false
    private var settingsPushTimer: Timer?
    private var lastStreamActivityAt = Date.distantPast

    // MARK: - Init

    init() {
        // Load settings from UserDefaults
        let savedSource = UserDefaults.standard.string(forKey: "translate_source_language") ?? "en"
        var loadedSource = TranslateLanguage(rawValue: savedSource) ?? .en

        let savedTarget = UserDefaults.standard.string(forKey: "translate_target_language") ?? "en"
        var loadedTarget = TranslateLanguage(rawValue: savedTarget) ?? .en

        // ONE-TIME MIGRATION: older builds defaulted to Chinese and that value
        // is still SAVED on phones that ran them (saved values survive updates).
        // Scrub it once; after this the user's own choices always win.
        if !UserDefaults.standard.bool(forKey: "translate_zh_scrubbed_v1") {
            if loadedTarget == .zh {
                loadedTarget = .en
                UserDefaults.standard.set(loadedTarget.rawValue, forKey: "translate_target_language")
            }
            if loadedSource == .zh {
                loadedSource = .en
                UserDefaults.standard.set(loadedSource.rawValue, forKey: "translate_source_language")
            }
            UserDefaults.standard.set(true, forKey: "translate_zh_scrubbed_v1")
        }

        // BUILD 54: English is ALWAYS your side. A saved Indonesian source has
        // been silently telling the interpreter the wearer speaks Indonesian —
        // scrub it once, and make English the default for any fresh install.
        // The swap button still works if a session ever needs it turned around;
        // this only fixes the stored default, it doesn't lock the control.
        if !UserDefaults.standard.bool(forKey: "translate_source_en_v1") {
            if loadedSource != .en {
                // Whatever was sitting in Source was the foreign language —
                // that's the language you're travelling in, so keep it as the
                // one THEY speak rather than throwing the choice away.
                if loadedTarget == .en { loadedTarget = loadedSource }
                loadedSource = .en
                UserDefaults.standard.set(loadedSource.rawValue, forKey: "translate_source_language")
                UserDefaults.standard.set(loadedTarget.rawValue, forKey: "translate_target_language")
            }
            UserDefaults.standard.set(true, forKey: "translate_source_en_v1")
        }

        self.sourceLanguage = loadedSource
        self.targetLanguage = loadedTarget

        let savedVoice = UserDefaults.standard.string(forKey: "translate_voice") ?? "Cherry"
        self.selectedVoice = TranslateVoice(rawValue: savedVoice) ?? .cherry

        self.audioOutputEnabled = UserDefaults.standard.object(forKey: "translate_audio_enabled") as? Bool ?? true
        self.imageEnhanceEnabled = UserDefaults.standard.object(forKey: "translate_image_enhance") as? Bool ?? false
        self.usePhoneMic = UserDefaults.standard.object(forKey: "translate_use_phone_mic") as? Bool ?? false
        self.loudSpeaker = UserDefaults.standard.object(forKey: "translate_loud_speaker") as? Bool ?? false
        self.politeMode = UserDefaults.standard.object(forKey: "translate_polite") as? Bool ?? true
        self.phrases = SavedPhrase.load()
    }

    // MARK: - Connection

    func connect() {
        // AUDIT FIX (HIGH): translate_autostart was only cleared inside
        // onConnected, so ANY failure (no key, no network, cover collision,
        // early dismiss) left it true — and days later a manual visit to
        // Translate would start recording by itself. Read and clear here,
        // before anything can fail.
        pendingAutostart = UserDefaults.standard.bool(forKey: "translate_autostart")
        UserDefaults.standard.set(false, forKey: "translate_autostart")

        // BUILD 54: Source and Target were the wrong way round — Source is
        // meant to be the language YOU speak, and it was set to Indonesian on a
        // phone owned by an English speaker. Everything downstream inherited
        // that: the interpreter prompt believed the wearer spoke Indonesian,
        // and every English sentence was filed as the other person. Nobody
        // should have to know that. If the target matches the phone's own
        // language and the source doesn't, they're back to front — turn them
        // around before the session starts.
        // Your saved pair first; the automatic correction only runs if you
        // haven't set one.
        applyOwnDefault()
        autoOrientToPhoneLanguage()

        // AUDIT FIX (HIGH): a fresh install defaults to en↔en — an interpreter
        // that repeats you back to yourself. Never let source == target.
        if sourceLanguage == targetLanguage {
            targetLanguage = (sourceLanguage == .en) ? .id : .en
            print("🌐 [TranslateVM] source == target — corrected to \(targetLanguage.rawValue)")
        }

        let apiKey = APIProviderManager.staticLiveAIAPIKey
        guard !apiKey.isEmpty else {
            errorMessage = "livetranslate.error.noApiKey".localized
            showError = true
            return
        }
        // BUILD 56: opening Translate BY BUTTON never told the wake word to let
        // go of the microphone — only the voice route did. So Standby's
        // recogniser and the interpreter were both holding the same input node,
        // which is a fight neither wins. disconnect() already hands it back.
        if ChappyStandby.shared.isListening {
            print("👂 [TranslateVM] Handing the mic over from Standby")
            ChappyStandby.shared.handOff()
        }

        // TRANSCRIPT v2: stamp the session header once, at the top.
        sessionStartedAt = Date()
        sessionPlace = Self.placeString()

        translateService = LiveTranslateService(apiKey: apiKey)
        translateService?.politeMode = politeMode
        setupCallbacks()
        CurrencyRates.shared.refreshIfStale()

        translateService?.updateSettings(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            voice: selectedVoice,
            audioEnabled: audioOutputEnabled
        )

        translateService?.connect()
    }

    func disconnect() {
        stopImageTimer()
        idleTimer?.invalidate()
        idleTimer = nil
        isAsleep = false
        resumeRecordingOnConnect = false
        settingsPushTimer?.invalidate()
        settingsPushTimer = nil
        pendingSettingsPush = false
        // AUDIT FIX (CRITICAL): translate minutes were completely invisible to
        // the cost meter — an hour of interpreting reported as $0.00 and never
        // tripped the spend warnings.
        if let start = sessionStartAt {
            CostMeter.shared.addLiveSeconds(Date().timeIntervalSince(start))
            sessionStartAt = nil
        }
        translateService?.disconnect()
        translateService = nil
        isConnected = false
        isRecording = false
        UserDefaults.standard.set(false, forKey: "translate_autostart")
        pendingAutostart = false
        // AUDIT FIX: the wake-word ear comes back after a voice-started
        // translate session (it used to stay dead until the phone came out).
        ChappyStandby.shared.resumeAfterHandOff()
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        // BUILD 56: asleep? Wake up first, then start listening the moment the
        // line is live. You just tap the mic; you never see the difference.
        if isAsleep {
            resumeRecordingOnConnect = true
            connect()
            return
        }
        idleTimer?.invalidate(); idleTimer = nil
        // BUILD 56 FIX: the meter used to start the clock when the SCREEN
        // opened. An hour with Translate sitting open and nobody talking was
        // billed as an hour of live interpreting. Gemini charges for audio, not
        // for an idle socket — so the clock starts when the microphone does.
        sessionStartAt = Date()
        translateService?.setLoudSpeaker(loudSpeaker)
        translateService?.startRecording(usePhoneMic: usePhoneMic)
        isRecording = true

        // If image input enabled, start the periodic image timer
        if imageEnhanceEnabled {
            startImageTimer()
        }
    }

    func stopRecording() {
        translateService?.stopRecording()
        isRecording = false
        // Bank only the minutes the microphone was actually open.
        if let start = sessionStartAt {
            CostMeter.shared.addLiveSeconds(Date().timeIntervalSince(start))
            sessionStartAt = nil
        }
        startIdleCountdown()
        // BUILD 55: mic is off, so a rebuild costs nothing — apply anything
        // that was waiting for a pause rather than leaving it queued.
        if pendingSettingsPush { pushSettingsNow() }
        stopImageTimer()

        // Save the current translation to history
        if !currentTranslation.isEmpty {
            let record = TranslateRecord(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                originalText: currentOriginal,
                translatedText: currentTranslation
            )
            translationHistory.insert(record, at: 0)

            // Cap the history count
            if translationHistory.count > 50 {
                translationHistory = Array(translationHistory.prefix(50))
            }
        }
    }

    // MARK: - Language Swap

    func swapLanguages() {
        // Swap only when both languages are valid targets
        guard sourceLanguage.supportsAudioOutput && targetLanguage.supportsAudioOutput else {
            errorMessage = "livetranslate.error.cannotSwap".localized
            showError = true
            return
        }

        // AUDIT FIX (HIGH): each assignment's didSet pushed settings, so one
        // swap tore down and rebuilt the session TWICE — the second cycle saw
        // wasRecording == false and the mic never came back while the UI still
        // showed red. Suppress the push, then send once.
        suppressSettingsPush = true
        let temp = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = temp
        suppressSettingsPush = false
        updateServiceSettings()

        // Clear the current translation
        currentTranslation = ""
        streamingTranslation = ""
    }

    // MARK: - Video Frame

    func updateVideoFrame(_ frame: UIImage) {
        currentVideoFrame = frame
    }

    // MARK: - Private Methods

    private func setupCallbacks() {
        translateService?.onConnected = { [weak self] in
            DispatchQueue.main.async {
                self?.isConnected = true
                print("✅ [TranslateVM] Connected")
                // VOICE-STARTED TRANSLATE: when Chappy opened this by voice
                // ("Chappy, translate"), start listening the moment the line
                // is live — no buttons, mid-conversation ready.
                self?.isAsleep = false
                if self?.pendingAutostart == true {
                    self?.pendingAutostart = false
                    self?.startRecording()
                    print("🎙️ [TranslateVM] Auto-started by voice command")
                } else if self?.resumeRecordingOnConnect == true {
                    self?.resumeRecordingOnConnect = false
                    self?.startRecording()
                    print("🎙️ [TranslateVM] Woken by the mic button")
                } else {
                    self?.startIdleCountdown()
                }
            }
        }

        translateService?.onTranslationDelta = { [weak self] delta in
            DispatchQueue.main.async {
                self?.streamingTranslation += delta
                self?.lastStreamActivityAt = Date()
            }
        }

        // TRANSCRIPT v2: the speaker's own words, arriving live.
        translateService?.onOriginalDelta = { [weak self] delta in
            DispatchQueue.main.async {
                self?.streamingOriginal += delta
                self?.lastStreamActivityAt = Date()
            }
        }

        // TRANSCRIPT v2: a finished turn — file it as one bubble pair.
        translateService?.onTurnComplete = { [weak self] heard, translated in
            DispatchQueue.main.async {
                guard let self else { return }
                self.appendTurn(heard: heard, translated: translated)
                self.streamingOriginal = ""
                self.lastStreamActivityAt = Date()
            }
        }

        translateService?.onTranslationText = { [weak self] text in
            DispatchQueue.main.async {
                self?.currentTranslation = text
                self?.streamingTranslation = ""
            }
        }

        translateService?.onAudioDone = { [weak self] in
            DispatchQueue.main.async {
                print("🔊 [TranslateVM] audio playback done")
            }
        }

        translateService?.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.errorMessage = error
                self?.showError = true
            }
        }
    }

    // MARK: - Idle sleep (BUILD 56)

    /// BUILD 56: the socket used to open the instant the screen appeared and
    /// stay open until you closed it — which is how an hour-long idle window
    /// ran into Gemini's session limit and threw the 1008 alert. Nothing is
    /// being interpreted while nobody is talking, so let it go and bring it
    /// straight back when you tap the mic.
    private func startIdleCountdown() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleSleepSeconds,
                                         repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRecording, self.isConnected else { return }
                self.sleepSession()
            }
        }
    }

    /// Drop the line but keep everything on screen. The transcript, the header
    /// and your phrases are all local — none of them need a connection.
    private func sleepSession() {
        print("😴 [TranslateVM] Idle — releasing the session")
        translateService?.disconnect()
        translateService = nil
        isConnected = false
        isAsleep = true
        idleTimer?.invalidate()
        idleTimer = nil
    }

    // MARK: - Saved phrases

    func savePhrase(from turn: TranslateTurn) {
        // Store it the way you'd want to USE it: your English as the label,
        // their language as the thing that gets spoken.
        let english = turn.fromWearer ? turn.original : turn.translated
        let foreign = turn.fromWearer ? turn.translated : turn.original
        guard !english.isEmpty, !foreign.isEmpty else { return }
        // AUDIT FIX (TR-C1): this used sourceCode for a turn they spoke — which
        // is YOUR language, English. So every phrase saved from something the
        // other person said was filed as English and would have been read out
        // in an Australian accent. The foreign side is always targetCode.
        let code = turn.targetCode
        guard !phrases.contains(where: { $0.foreign == foreign }) else { return }
        phrases.insert(SavedPhrase(english: english, foreign: foreign, languageCode: code), at: 0)
        if phrases.count > 60 { phrases.removeLast(phrases.count - 60) }
        SavedPhrase.save(phrases)
    }

    func deletePhrase(_ phrase: SavedPhrase) {
        phrases.removeAll { $0.id == phrase.id }
        SavedPhrase.save(phrases)
    }

    /// Speak a saved phrase out loud in their language. Works with no session
    /// running and no signal — the words are already on the phone.
    func speakPhrase(_ phrase: SavedPhrase) {
        TTSService.shared.speak(phrase.foreign)
    }

    private func updateServiceSettings() {
        // AUDIT FIX: guarded so one swap can't fire two teardown/reconnect
        // cycles (which left the mic dead with the UI showing red).
        guard !suppressSettingsPush else { return }

        // BUILD 55: changing the register or the language rebuilds the Gemini
        // session, and a rebuild takes the microphone away for a second or two.
        // Doing that the instant you tap Polite means cutting someone off
        // mid-sentence and losing what they said. Wait for a gap instead —
        // nobody is talking during a gap, so nobody notices.
        if isRecording && !isIdleMoment {
            pendingSettingsPush = true
            scheduleDeferredPush()
            print("⏳ [TranslateVM] Settings change queued for the next pause")
            return
        }
        pushSettingsNow()
    }

    /// A natural pause: nothing streaming in either direction, Chappy isn't
    /// speaking, and it's been quiet for long enough to be a real gap rather
    /// than a breath between words.
    private var isIdleMoment: Bool {
        guard streamingOriginal.isEmpty, streamingTranslation.isEmpty else { return false }
        guard !TTSService.shared.isSpeaking else { return false }
        return Date().timeIntervalSince(lastStreamActivityAt) >= 0.8
    }

    private func pushSettingsNow() {
        pendingSettingsPush = false
        settingsPushTimer?.invalidate()
        settingsPushTimer = nil
        translateService?.politeMode = politeMode
        translateService?.updateSettings(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            voice: selectedVoice,
            audioEnabled: audioOutputEnabled
        )
    }

    /// Keep checking for that gap. Four times a second is responsive enough to
    /// feel instant and cheap enough not to matter.
    private func scheduleDeferredPush() {
        guard settingsPushTimer == nil else { return }
        settingsPushTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.pendingSettingsPush else {
                    self.settingsPushTimer?.invalidate()
                    self.settingsPushTimer = nil
                    return
                }
                guard self.isIdleMoment else { return }
                print("✅ [TranslateVM] Pause found — applying queued settings")
                self.pushSettingsNow()
            }
        }
    }

    // MARK: - Image Timer

    private func startImageTimer() {
        stopImageTimer()
        imageTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendCurrentFrame()
            }
        }
    }

    private func stopImageTimer() {
        imageTimer?.invalidate()
        imageTimer = nil
    }

    private func sendCurrentFrame() {
        guard imageEnhanceEnabled, let frame = currentVideoFrame else { return }
        translateService?.sendImageFrame(frame)
    }

    // MARK: - Transcript building (TRANSCRIPT v2)

    /// Who spoke? The mic setting is a hint, not proof — with the glasses mic
    /// live, BOTH of you are in range. So identify the language of what was
    /// actually said, on-device and free, and let that decide. Falls back to
    /// the mic hint when the sentence is too short to call.
    // MARK: - Verbal repeat (BUILD 54)

    /// English repeat wording. On its own this is NOT enough to be a command —
    /// "can you repeat that?" is a perfectly normal thing to say to the person
    /// opposite, and swallowing it would leave them staring at you in silence.
    /// Your name is what makes it an instruction.
    private static let repeatWordsEN: [String] = [
        "say that again", "say it again", "repeat that", "repeat it",
        "repeat", "one more time", "again", "play that again", "come again"
    ]

    /// The other person doesn't know Chappy exists, so they can't address it by
    /// name. For them, a bare repeat word IS the command — and replaying the
    /// last line is exactly what they're asking for anyway. Exact match only,
    /// so "sekali lagi" mid-sentence while ordering doesn't trigger it.
    /// AUDIT FIX (TR-H1): "sorry" was in this list. You say sorry constantly —
    /// bumping someone, squeezing past, declining a tout — and every one of
    /// them would have been eaten as a command instead of translated. Gone.
    private static let repeatWordsLocal: [String] = [
        "ulangi", "tolong ulangi", "ulangi lagi", "sekali lagi",
        "bisa ulangi", "maaf", "apa"
    ]

    /// "Chappy, be polite" / "Chappy, casual". Returns nil when it isn't one.
    private static func registerCommand(_ text: String) -> Bool? {
        let t = text.lowercased().filter { $0.isLetter || $0.isWhitespace }
            .trimmingCharacters(in: .whitespaces)
        guard t.contains("chappy") || t.contains("chappie"), t.count <= 40 else { return nil }
        if t.contains("polite") || t.contains("formal") || t.contains("respectful") { return true }
        if t.contains("casual") || t.contains("relax") || t.contains("informal") { return false }
        return nil
    }

    /// Is this an instruction to the app, or something to translate?
    private static func isRepeatCommand(_ text: String, spokenByWearer: Bool) -> Bool {
        let t = text.lowercased().filter { $0.isLetter || $0.isWhitespace }
            .trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 34 else { return false }

        // English: only ever a command when you say the name. Everything else
        // goes to the person you're talking to, which is the whole point.
        if t.contains("chappy") || t.contains("chappie") {
            return repeatWordsEN.contains { t.contains($0) }
        }

        // AUDIT FIX (TR-H1): the local shortcuts belong to the LOCAL. When it's
        // you speaking, only your name counts — otherwise a single word you
        // happen to say gets swallowed instead of translated.
        guard !spokenByWearer else { return false }
        return repeatWordsLocal.contains(t)
    }

    /// Replay the last thing the OTHER person's side produced. If you ask, you
    /// want their words back in English; if they ask, they want yours back in
    /// their language. Falls back to the most recent line either way.
    private func handleRepeatCommand(askedByWearer: Bool) {
        let wanted = transcript.last(where: { $0.fromWearer != askedByWearer }) ?? transcript.last
        guard let turn = wanted, !turn.translated.isEmpty else {
            TTSService.shared.speak("Nothing to repeat yet.")
            return
        }
        print("🔁 [TranslateVM] Verbal repeat — replaying: \(turn.translated.prefix(40))")
        TTSService.shared.speak(turn.translated)
    }

    private func appendTurn(heard: String, translated: String) {
        let clean = heard.trimmingCharacters(in: .whitespacesAndNewlines)

        // AUDIT FIX (TR-H2): identify the speaker ONCE, up front, and let both
        // the command checks and the bubble use it. It used to run twice with
        // slightly different rules, which is how a rule could be right in one
        // place and wrong in the other.
        var fromWearer = !usePhoneMic
        var detected: String? = nil
        if clean.count >= 8 {
            let recogniser = NLLanguageRecognizer()
            recogniser.processString(clean)
            if let lang = recogniser.dominantLanguage?.rawValue {
                detected = lang
                // The wearer speaks the SOURCE language; anything else is them.
                fromWearer = Self.sameLanguage(lang, sourceLanguage.rawValue)
            }
        }

        // VERBAL REPEAT: catch it before it becomes a bubble. The interpreter
        // has been told to stay silent on these, so nothing was spoken over it.
        if Self.isRepeatCommand(clean, spokenByWearer: fromWearer) {
            handleRepeatCommand(askedByWearer: fromWearer)
            return
        }

        // BUILD 55: register by voice. Same rule as repeat — your name makes it
        // a command, so "could you be polite to him" still gets translated.
        if let wantsPolite = Self.registerCommand(clean) {
            politeMode = wantsPolite
            // Worded so it stays true whether it applies now or at the next gap.
            TTSService.shared.speak(wantsPolite ? "Polite from here." : "Casual from here.")
            return
        }

        // ECHO GUARD (BUILD 53): the signature of a feedback loop is Chappy
        // hearing back the exact words it just spoke. Even with the microphone
        // gated, a loud room can leak one through — refuse to file it.
        if let last = transcript.last,
           Self.looseMatch(clean, last.translated) || Self.looseMatch(clean, last.original) {
            print("🔁 [TranslateVM] Dropped an echo of the previous turn")
            // This room is livelier than the default assumes. Tell the gate to
            // hold a little longer next time — it tunes itself to the space
            // you're actually standing in.
            translateService?.lengthenEchoTail()
            return
        }
        // Nothing useful was heard — don't invent a bubble for it.
        guard clean.count >= 2 else { return }

        let turn = TranslateTurn(
            at: Date(),
            original: clean,
            translated: translated.trimmingCharacters(in: .whitespacesAndNewlines),
            fromWearer: fromWearer,
            detectedLanguage: detected,
            sourceCode: sourceLanguage.rawValue,
            targetCode: targetLanguage.rawValue
        )
        transcript.append(turn)
        currentOriginal = turn.original

        // BUILD 54: you don't have to know what language they're speaking.
        // Chappy listens to what actually came out of their mouth and retargets
        // itself. Two turns in a row, so one mangled word can't derail a
        // conversation, and it says so out loud when it switches.
        autoRetarget(to: detected, spokenByWearer: fromWearer)

        // Keep the in-memory transcript bounded — a two-hour market haggle
        // shouldn't slowly eat an iPhone 11's RAM.
        if transcript.count > 400 {
            transcript.removeFirst(transcript.count - 400)
        }
    }

    // MARK: - Your defaults (BUILD 54)

    /// True once you've told Chappy which pair you want. From that moment no
    /// automatic correction ever touches your languages again — guessing is
    /// only for people who haven't said what they want.
    var hasOwnDefault: Bool {
        UserDefaults.standard.bool(forKey: "translate_user_default_set")
    }

    /// Remember the pair currently on screen as the one every session opens with.
    func saveCurrentAsDefault() {
        UserDefaults.standard.set(sourceLanguage.rawValue, forKey: "translate_default_source")
        UserDefaults.standard.set(targetLanguage.rawValue, forKey: "translate_default_target")
        UserDefaults.standard.set(true, forKey: "translate_user_default_set")
        objectWillChange.send()
        print("🌐 [TranslateVM] Default pair set: \(sourceLanguage.rawValue) → \(targetLanguage.rawValue)")
    }

    /// Hand the languages back to Chappy's judgement.
    func clearOwnDefault() {
        UserDefaults.standard.set(false, forKey: "translate_user_default_set")
        objectWillChange.send()
    }

    /// Apply your saved pair at the start of a session.
    private func applyOwnDefault() {
        // BUILD 54 FIX: a voice-started session ("Chappy, translate") has ALREADY
        // chosen the language from where you're standing. Re-applying the pinned
        // pair here would have thrown that away and put you back into Indonesian
        // while standing in Thailand.
        guard !pendingAutostart else { return }
        guard hasOwnDefault,
              let s = UserDefaults.standard.string(forKey: "translate_default_source"),
              let t = UserDefaults.standard.string(forKey: "translate_default_target"),
              let src = TranslateLanguage(rawValue: s),
              let tgt = TranslateLanguage(rawValue: t) else { return }
        guard src != sourceLanguage || tgt != targetLanguage else { return }
        suppressSettingsPush = true
        sourceLanguage = src
        targetLanguage = tgt
        suppressSettingsPush = false
    }

    /// Put the wearer's own language in Source, using the phone's language as
    /// the giveaway. Runs once per session start and only when it's clearly
    /// backwards, so a deliberate choice is never overridden.
    private func autoOrientToPhoneLanguage() {
        // Your choice always wins over my guess.
        guard !hasOwnDefault else { return }
        guard let raw = Locale.preferredLanguages.first else { return }
        let phone = String(raw.prefix(2)).lowercased()
        let src = String(sourceLanguage.rawValue.prefix(2)).lowercased()
        let tgt = String(targetLanguage.rawValue.prefix(2)).lowercased()
        guard tgt == phone, src != phone else { return }
        suppressSettingsPush = true
        let temp = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = temp
        suppressSettingsPush = false
        print("🌐 [TranslateVM] Languages were backwards — now \(sourceLanguage.rawValue) → \(targetLanguage.rawValue)")
    }

    /// Same words, ignoring case, punctuation and spacing — good enough to spot
    /// an echo without rejecting a person who genuinely repeats themselves in a
    /// different sentence.
    private static func looseMatch(_ a: String, _ b: String) -> Bool {
        func strip(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let x = strip(a), y = strip(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y
    }

    /// Apple's language identifier and our TranslateLanguage codes don't always
    /// spell the same language the same way — Filipino is "tl" to Apple and
    /// "fil" here, Cantonese comes back as Chinese. Compare them honestly
    /// rather than letting a spelling mismatch tag you as the other speaker.
    private static func sameLanguage(_ detected: String, _ ours: String) -> Bool {
        let d = String(detected.prefix(2)).lowercased()
        let o = String(ours.prefix(2)).lowercased()
        if d == o { return true }
        let aliases: [String: Set<String>] = [
            "fi": ["tl"],           // fil ↔ tl
            "yu": ["zh"],           // yue ↔ zh
            "zh": ["yu"]
        ]
        return aliases[o]?.contains(d) ?? false
    }

    // MARK: - Auto-retarget (BUILD 54)

    private var retargetCandidate: TranslateLanguage?
    private var retargetHits = 0

    /// Apple's detector speaks a slightly different dialect of language codes
    /// than our enum does. Translate between the two, or give up honestly.
    private static func language(fromDetected code: String?) -> TranslateLanguage? {
        guard let code else { return nil }
        var short = String(code.prefix(2)).lowercased()
        if short == "tl" { short = "fil" }          // Apple's Tagalog, our Filipino
        return TranslateLanguage(rawValue: short)
    }

    /// When the other person turns out to be speaking something other than what
    /// we're aimed at, aim at it instead. Only ever moves the language THEY
    /// speak — your side stays put.
    private func autoRetarget(to detected: String?, spokenByWearer: Bool) {
        guard !spokenByWearer,
              let lang = Self.language(fromDetected: detected),
              lang != targetLanguage,
              lang != sourceLanguage else {
            retargetCandidate = nil
            retargetHits = 0
            return
        }

        if retargetCandidate == lang {
            retargetHits += 1
        } else {
            retargetCandidate = lang
            retargetHits = 1
        }

        // Two consecutive turns in the same unexpected language is a real
        // conversation, not a stray word.
        guard retargetHits >= 2 else { return }
        retargetCandidate = nil
        retargetHits = 0

        let name = lang.displayName
        print("🌐 [TranslateVM] They're speaking \(name) — retargeting")
        targetLanguage = lang            // didSet pushes the new session settings
        TTSService.shared.speak("They're speaking \(name). Switching.")
    }

    /// Where the session started, in plain words, for the header.
    private static func placeString() -> String? {
        let snap = ContextEngine.shared.snapshot
        var parts: [String] = []
        if let s = snap.street { parts.append(s) }
        if let c = snap.city { parts.append(c) }
        if parts.isEmpty, let co = snap.country { parts.append(co) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - Clear

    func clearTranslation() {
        currentTranslation = ""
        streamingTranslation = ""
        streamingOriginal = ""
        currentOriginal = ""
        transcript.removeAll()
    }

    func clearHistory() {
        translationHistory.removeAll()
    }
}

// MARK: - Saved Phrase (BUILD 55)

/// A line you've already used, kept for next time. Both languages are stored,
/// so playing it needs no session, no API and no signal.
struct SavedPhrase: Identifiable, Codable, Equatable {
    let id: UUID
    let english: String
    let foreign: String
    let languageCode: String
    let savedAt: Date

    init(id: UUID = UUID(), english: String, foreign: String,
         languageCode: String, savedAt: Date = Date()) {
        self.id = id
        self.english = english
        self.foreign = foreign
        self.languageCode = languageCode
        self.savedAt = savedAt
    }

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chappy-phrases.json")
    }

    static func load() -> [SavedPhrase] {
        guard let d = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode([SavedPhrase].self, from: d) else { return [] }
        return p
    }

    static func save(_ phrases: [SavedPhrase]) {
        guard let d = try? JSONEncoder().encode(phrases) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

// MARK: - Currency (BUILD 55)

/// Haggling is mostly numbers, and a spoken Indonesian price is a long string
/// of words. Turning that into digits AND into dollars is the difference
/// between following a negotiation and nodding along to one.
final class CurrencyRates {
    static let shared = CurrencyRates()
    private init() {}

    /// Units of foreign currency per 1 AUD.
    private var rates: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: "chappy_fx_rates") as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "chappy_fx_rates") }
    }
    private var fetchedAt: Date? {
        get { UserDefaults.standard.object(forKey: "chappy_fx_at") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "chappy_fx_at") }
    }

    /// Language → the currency you'll actually be handed.
    static let currencyForLanguage: [String: String] = [
        "id": "IDR", "th": "THB", "vi": "VND", "fil": "PHP", "km": "KHR",
        "lo": "LAK", "zh": "CNY", "yue": "HKD", "ja": "JPY", "ko": "KRW",
        "hi": "INR", "tr": "TRY", "ar": "AED", "el": "EUR", "fr": "EUR",
        "es": "EUR", "it": "EUR", "de": "EUR", "pt": "EUR", "ru": "RUB"
    ]

    /// Once a day is plenty — rates move fractions of a percent and a stale
    /// number still tells you whether you're being charged double.
    func refreshIfStale() {
        if let at = fetchedAt, Date().timeIntervalSince(at) < 86_400, !rates.isEmpty { return }
        guard let url = URL(string: "https://open.er-api.com/v6/latest/AUD") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = json["rates"] as? [String: Double], !r.isEmpty else { return }
            self.rates = r
            self.fetchedAt = Date()
            print("💱 [FX] Rates refreshed (\(r.count) currencies)")
        }.resume()
    }

    /// "250,000 IDR" → "≈ A$24". Nil when we've never had a rate for it.
    func inAUD(_ amount: Double, currency: String) -> String? {
        guard let perAUD = rates[currency], perAUD > 0 else { return nil }
        let aud = amount / perAUD
        if aud >= 100 { return String(format: "≈ A$%.0f", aud) }
        if aud >= 10 { return String(format: "≈ A$%.1f", aud) }
        return String(format: "≈ A$%.2f", aud)
    }
}
