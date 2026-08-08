/*
 * Live Translate ViewModel
 * Live Translate state management
 */

import Foundation
import SwiftUI
import UIKit
import NaturalLanguage
import AVFoundation

@MainActor
class LiveTranslateViewModel: ObservableObject {

    // MARK: - Connection State
    @Published var isConnected = false
    @Published var isRecording = false
    /// BUILD 56: line released to save resources. Everything on screen still
    /// works — tapping the mic brings it straight back.
    @Published var isAsleep = false
    /// SB-4: the line is gone and we are not coming back on our own. Distinct
    /// from asleep, which is a deliberate, cheap, instantly-recoverable state.
    @Published var lostConnection = false
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
            guard sourceLanguage != oldValue else { return }
            // FS-6: source == target is an interpreter that repeats every
            // speaker back to themselves. Enforce it on every change, not once
            // at connect — the two lists in Settings are adjacent and identical.
            if sourceLanguage == targetLanguage {
                targetLanguage = (sourceLanguage == .en) ? .id : .en
            }
            UserDefaults.standard.set(sourceLanguage.rawValue, forKey: "translate_source_language")
            updateServiceSettings()
        }
    }

    @Published var targetLanguage: TranslateLanguage {
        didSet {
            guard targetLanguage != oldValue else { return }
            if targetLanguage == sourceLanguage {
                sourceLanguage = (targetLanguage == .en) ? .id : .en
            }
            UserDefaults.standard.set(targetLanguage.rawValue, forKey: "translate_target_language")
            // BUILD 58: mark the change in the transcript rather than silently
            // continuing. Two languages interleaved with no visible break reads
            // as the app malfunctioning — which is exactly how it looked when
            // Indonesian turns sat above German ones.
            markLanguageChange()
            updateServiceSettings()
        }
    }

    /// BUILD 57: DEAD CONTROL. These voices — Cherry, Jada, Dylan, Sunny, Peter,
    /// Kiki, Eric — are Alibaba/Qwen voices left over from the original app.
    /// Translate runs on Gemini now and speaks with the single voice chosen in
    /// Settings → Voice, like every other part of Chappy. Picking one here has
    /// never changed anything. Worse, it used to tear down and rebuild the live
    /// session to apply a value the service ignores — a two-second dropout for
    /// nothing. It still saves your choice, but it no longer costs you a session.
    @Published var selectedVoice: TranslateVoice {
        didSet {
            UserDefaults.standard.set(selectedVoice.rawValue, forKey: "translate_voice")
        }
    }

    @Published var audioOutputEnabled: Bool {
        didSet {
            // FS-12: without this, "Chappy, speak" when speech was already on
            // tore the socket down and rebuilt it — deaf through the handshake,
            // mid-conversation, for a value the server never even sees.
            guard audioOutputEnabled != oldValue else { return }
            UserDefaults.standard.set(audioOutputEnabled, forKey: "translate_audio_enabled")
            updateServiceSettings()
        }
    }

    @Published var imageEnhanceEnabled: Bool {
        didSet {
            guard imageEnhanceEnabled != oldValue else { return }
            UserDefaults.standard.set(imageEnhanceEnabled, forKey: "translate_image_enhance")
            // FS-5: the timer was only ever started from startRecording(), so
            // flipping this mid-conversation spun the glasses camera up, kept
            // the screen awake and converted frames — and sent none of them.
            // Full cost, zero benefit.
            if isRecording {
                imageEnhanceEnabled ? startImageTimer() : stopImageTimer()
            }
        }
    }

    /// Use iPhone microphone (instead of the glasses mic) 
    /// Glasses mic suits translating yourself; iPhone mic suits translating the other person

    // ==================================================================
    // SCAN — the menu, the sign, the brochure he's holding up.
    //
    // THE DESIGN PROBLEM IS LENGTH, NOT TRANSLATION. A menu has forty items.
    // Translating it is easy; reciting forty dishes into someone's ear is
    // useless. So this is not "translate this document" — it is "let me ASK
    // things about this document". Chappy gives one sentence out loud, puts
    // the full text on screen where it can be read at leisure, and hands the
    // extracted text back to the live session so the next question —
    // "how much is the second one?" — lands with the model already knowing.
    //
    // The conversation never closes. He is mid-sentence with a vendor; the
    // whole point is that this happens inside that, not instead of it.

    @Published var isScanning = false

    /// Grab what the glasses can see and translate it.
    func scanDocument() {
        guard !isScanning else { return }
        guard let frame = currentVideoFrame,
              Date().timeIntervalSince(lastFrameAt) < 3.0 else {
            // The camera is off. Ask the view to wake it and come back — an
            // honest "hang on" beats him holding a menu up at nothing.
            NotificationCenter.default.post(name: .chappyWakeCameraForScan, object: nil)
            say("One moment, waking the camera.")
            return
        }
        isScanning = true
        let acks = ["Let me look.", "Reading that now.", "Hang on, having a look."]
        say(acks[transcript.count % acks.count])

        Task { @MainActor in
            defer { isScanning = false }
            let target = targetLanguage.displayName
            guard let result = await Self.readDocument(frame, into: "English", from: target) else {
                self.say("I couldn't read that one. Try holding it a bit steadier.")
                return
            }

            // The card, in the transcript, where it happened.
            let jpeg = frame.jpegData(compressionQuality: 0.5)
            let turn = TranslateTurn(
                original: result.original,
                translated: result.translated,
                fromWearer: false,
                sourceCode: self.targetLanguage.rawValue,
                targetCode: self.sourceLanguage.rawValue,
                documentJPEG: jpeg)
            self.transcript.append(turn)
            self.lastScannedText = result.translated

            // PHASE 5 — a scanned menu or sign is one of the most useful
            // things to have six weeks later, and the only one you literally
            // cannot re-take once you have walked away. Kept forever, with
            // the photo, no expiry.
            ChappyMemory.shared.remember(.scan,
                title: result.summary,
                body: "Original (\(target)):\n\(result.original)\n\nEnglish:\n\(result.translated)",
                tags: ["scan", "document", target.lowercased()],
                thumbnail: frame.jpegData(compressionQuality: 0.4),
                source: "translate-scan")

            // Hand it to the live session so follow-up questions land with
            // context. This is what makes "how much is the second one" work.
            self.translateService?.sendTextContext(
                "The user just photographed this text. Original: \(result.original)\n" +
                "English: \(result.translated)\n" +
                "Answer questions about it briefly if asked. Do not read it all out unless asked.")

            // ONE SENTENCE out loud. Never the whole document unprompted.
            self.say(result.summary)
        }
    }

    /// The most recent scan, so "read it" and "read that again" work.
    private(set) var lastScannedText: String = ""

    /// Read the whole thing aloud — only when he asks.
    func readLastScan() {
        guard !lastScannedText.isEmpty else {
            say("Nothing scanned yet."); return
        }
        say(lastScannedText)
    }

    struct ScanResult {
        let original: String
        let translated: String
        let summary: String
    }

    /// One-shot vision call. Deliberately NOT the live session: that returns
    /// conversational audio, and what a card needs is clean structured text he
    /// can read, save and scroll back to.
    static func readDocument(_ image: UIImage, into english: String, from foreign: String) async -> ScanResult? {
        guard let key = APIKeyManager.shared.getGoogleAPIKey(), !key.isEmpty,
              let jpeg = image.jpegData(compressionQuality: 0.6),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=\(key)")
        else { return nil }

        let prompt = """
        This photo shows text — a menu, sign, label, brochure or document, probably in \(foreign).
        Reply with ONLY JSON, no markdown fences:
        {"original":"...","translated":"...","summary":"..."}
        original   = the text exactly as printed, line breaks preserved.
        translated = a natural English translation, same line structure.
        summary    = ONE short spoken sentence describing what it is and the key numbers.
                     Example: "It's a menu. Twelve dishes, twenty to sixty thousand rupiah."
                     Never list every item here.
        If there is no readable text, set all three to "".
        """
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [
                ["text": prompt],
                ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
            ]]],
            "generationConfig": ["temperature": 0, "maxOutputTokens": 2000,
                                 "responseMimeType": "application/json"],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = json["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let raw = parts.first?["text"] as? String else { return nil }

        let cleaned = raw.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = cleaned.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let orig = o["original"] as? String, !orig.isEmpty,
              let tran = o["translated"] as? String else { return nil }
        let sum = (o["summary"] as? String) ?? "Here's what it says."
        return ScanResult(original: orig, translated: tran, summary: sum)
    }

    // MARK: The misheard nudge

    /// Consecutive turns the transcriber got wrong. Reset by any good turn.
    private var mishearStreak = 0
    /// Say it once per session. A tip repeated is a nag.
    private var nudgedAboutMic = false

    /// WHY THIS EXISTS. The Ray-Ban microphone is a head-worn beamforming array
    /// aimed at the WEARER's mouth — it actively suppresses sound arriving from
    /// other directions, which is exactly where the person you are talking to is
    /// standing. On top of that, the moment iOS uses the glasses as an INPUT it
    /// drops the Bluetooth link to Hands-Free Profile: 8-16 kHz, telephone
    /// grade, and that is what gets sent to be transcribed.
    ///
    /// The result is a specific, recognisable failure — a clean sentence coming
    /// back as confident nonsense in a third language ("und Parmesan" for "what
    /// time is it"). The app already detects exactly that and flags the turn.
    /// It just never did anything with the knowledge.
    ///
    /// So: two in a row while on the glasses mic, and Chappy says so — once,
    /// plainly, at the moment it matters, instead of leaving the trade-off
    /// buried in a settings screen the wearer will never open mid-conversation.
    private func noteMishearStreak(misheard: Bool, fromWearer: Bool) {
        guard misheard else { mishearStreak = 0; return }
        mishearStreak += 1
        guard mishearStreak >= 2, !usePhoneMic, !nudgedAboutMic else { return }
        nudgedAboutMic = true
        mishearStreak = 0
        say(fromWearer
            ? "I'm having trouble hearing you clearly. Tap MIC to use the phone microphone."
            : "I'm struggling to hear them. Tap MIC and point the phone at them.")
    }

    /// AUDIT FIX (MIC-SWITCH): SPEAK and LOUD are OUTPUT controls — they never
    /// touched the microphone, so there was no way to move the ear from the
    /// glasses to the phone without leaving the conversation, going into
    /// Settings and coming back. Handing the phone to a vendor across a table
    /// is the single most common thing you do with a translator, so it needs to
    /// be one tap from the main screen.
    ///
    /// The flip only takes effect at startRecording(), so a live session has to
    /// be bounced — stopped and restarted on the other input. That is fast
    /// enough to feel instant and keeps the websocket and the transcript alive.
    func switchMicSource() {
        // Any deliberate tap is remembered, and from then on the auto-default
        // below never overrides him again. Guessing is fine; guessing over
        // somebody's explicit choice is not.
        UserDefaults.standard.set(true, forKey: "translate_mic_user_set")
        let wasRecording = isRecording
        if wasRecording { translateService?.stopRecording() ; isRecording = false }
        usePhoneMic.toggle()
        ChappyHaptics.shared.straightStep()
        guard wasRecording else { return }
        // A beat for the route to settle — restarting into a session iOS is
        // still reconfiguring is how you get a 0 Hz format and a dead mic.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.translateService?.setLoudSpeaker(self.loudSpeaker)
            if self.translateService?.startRecording(usePhoneMic: self.usePhoneMic) == true {
                self.isRecording = true
                print("🎤 [TranslateVM] Mic → \(self.usePhoneMic ? "phone" : "glasses")")
            } else {
                print("❌ [TranslateVM] Mic switch failed to reopen")
                self.say(self.usePhoneMic
                         ? "Could not switch to the phone microphone."
                         : "Could not switch back to the glasses.")
            }
        }
    }

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
            guard politeMode != oldValue else { return }
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
    private var backgroundToken: NSObjectProtocol?
    private var resumeRecordingOnConnect = false
    private static let idleSleepSeconds: TimeInterval = 180
    /// BUILD 55: deferred settings push — see updateServiceSettings().
    private var pendingSettingsPush = false
    private var settingsPushTimer: Timer?
    private var lastStreamActivityAt = Date.distantPast
    /// SB-3: per-minute cost banking and the recording cap.
    private var costTimer: Timer?
    /// FS-4: when the newest camera frame actually arrived.
    private var lastFrameAt = Date.distantPast
    private var recordedMinutes: Double = 0

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
        // MIC DEFAULT. This used to default to the GLASSES, which optimises for
        // the wrong half of the conversation: the head-worn beamforming array
        // is aimed at the wearer and suppresses the person opposite him, and
        // using it as an input drops the Bluetooth link to telephone quality.
        // A translator exists to understand the OTHER person, so the phone mic
        // — full bandwidth, and pointable — is the better opening bet.
        //
        // Only a default. One tap on MIC sets translate_mic_user_set and his
        // choice is honoured from then on, forever.
        let micWasChosen = UserDefaults.standard.bool(forKey: "translate_mic_user_set")
        self.usePhoneMic = micWasChosen
            ? (UserDefaults.standard.object(forKey: "translate_use_phone_mic") as? Bool ?? true)
            : true
        self.loudSpeaker = UserDefaults.standard.object(forKey: "translate_loud_speaker") as? Bool ?? false
        self.politeMode = UserDefaults.standard.object(forKey: "translate_polite") as? Bool ?? true
        self.phrases = SavedPhrase.load()
        installLifecycleObserver()
    
        // BUILD 122 FIX — this observer was registered at the TOP of init(),
        // which touches `self` before every stored property exists. Swift
        // refuses, and rightly. It belongs at the END, once the object is
        // actually an object.
        //
        // "Chappy, start" while paused: Standby holds the ear when the
        // translate mic is stopped, so it posts and this listens. That round
        // trip is what lets you restart without touching the screen.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("chappyResumeTranslate"),
            object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.isRecording else { return }
                self.startRecording()
                self.say("Listening.", isConfirmation: true)
        }
}

    // MARK: - Connection

    func connect() {
        // AUDIT FIX (HIGH): translate_autostart was only cleared inside
        // onConnected, so ANY failure (no key, no network, cover collision,
        // early dismiss) left it true — and days later a manual visit to
        // Translate would start recording by itself. Read and clear here,
        // before anything can fail.
        // FS-17: this was a bare Bool written before the screen was known to
        // open. If another cover was already up SwiftUI dropped the
        // presentation, the flag survived app restarts, and days later opening
        // Translate by button started the microphone and the meter with no tap.
        // It expires now.
        let stamp = UserDefaults.standard.double(forKey: "translate_autostart_at")
        pendingAutostart = UserDefaults.standard.bool(forKey: "translate_autostart")
            && stamp > 0 && Date().timeIntervalSince1970 - stamp < 60
        UserDefaults.standard.set(false, forKey: "translate_autostart")
        UserDefaults.standard.removeObject(forKey: "translate_autostart_at")

        // BUILD 54: Source and Target were the wrong way round — Source is
        // meant to be the language YOU speak, and it was set to Indonesian on a
        // phone owned by an English speaker. Everything downstream inherited
        // that: the interpreter prompt believed the wearer spoke Indonesian,
        // and every English sentence was filed as the other person. Nobody
        // should have to know that. If the target matches the phone's own
        // language and the source doesn't, they're back to front — turn them
        // around before the session starts.
        // FS-7: waking from idle sleep re-ran all of this, silently undoing an
        // auto-retarget or a manual swap made during the conversation that is
        // STILL ON SCREEN, and restamping the header so it claimed the
        // conversation began after the pause it was displaying. Orientation and
        // the header belong to the start of a session, not to a resume.
        let resuming = !transcript.isEmpty
        if !resuming {
            applyOwnDefault()
            autoOrientToPhoneLanguage()
        }

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

        // TRANSCRIPT v2: stamp the session header once, at the top — and only
        // for a genuinely new session (FS-7).
        if !resuming {
            sessionStartedAt = Date()
            sessionPlace = Self.placeString()
        }

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
        stopCostCheckpoint()
        recordedMinutes = 0
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
        // Give the microphone back to the translate session — two recognisers
        // on one mic is how both of them end up deaf.
        ChappyStandby.shared.handOff()
        // BUILD 56: asleep? Wake up first, then start listening the moment the
        // line is live. You just tap the mic; you never see the difference.
        if isAsleep || lostConnection {
            resumeRecordingOnConnect = true
            lostConnection = false
            connect()
            return
        }
        idleTimer?.invalidate(); idleTimer = nil
        startCostCheckpoint()
        // BUILD 56 FIX: the meter used to start the clock when the SCREEN
        // opened. An hour with Translate sitting open and nobody talking was
        // billed as an hour of live interpreting. Gemini charges for audio, not
        // for an idle socket — so the clock starts when the microphone does.
        sessionStartAt = Date()
        translateService?.setLoudSpeaker(loudSpeaker)
        // FS-14: this used to set isRecording unconditionally — a red button, a
        // running cost clock and a suppressed idle countdown for a microphone
        // that never opened.
        guard translateService?.startRecording(usePhoneMic: usePhoneMic) == true else {
            print("❌ [TranslateVM] Microphone did not open")
            sessionStartAt = nil
            stopCostCheckpoint()
            startIdleCountdown()
            return
        }
        isRecording = true

        // If image input enabled, start the periodic image timer
        if imageEnhanceEnabled {
            startImageTimer()
        }
    }

    /// How much of the transcript has already been filed as a memory, so
    /// stopping and starting the mic three times in one conversation files
    /// one memory with three parts, not three copies of the same chat.
    private var archivedTurnCount = 0

    /// PHASE 5 — a conversation is ONE memory, not forty.
    ///
    /// Forty rows of "yes" / "how much" / "thank you" is not something anyone
    /// searches. What you want six weeks later is "the scooter hire in Ubud",
    /// and the useful text is the foreign side plus the English beside it.
    ///
    /// EXPIRY, and why. The verbatim words of a stranger you met once are a
    /// different kind of thing from a note you wrote about your own day, so
    /// the full transcript ages out after 60 days unless you pin it. The
    /// headline — what it was about, where, when — is kept forever with no
    /// expiry, so recall still works after the words are gone.
    private func archiveConversationToMemory() {
        let fresh = transcript.dropFirst(archivedTurnCount).filter {
            !$0.original.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard fresh.count >= 2 else { return }
        archivedTurnCount = transcript.count

        let lang = targetLanguage.displayName
        let place = ContextEngine.shared.snapshot.street
            ?? ContextEngine.shared.snapshot.city
        var title = "Conversation in \(lang)"
        if let p = place { title += " at \(p)" }

        // The gist line: the longest thing the OTHER person said, in English.
        // It is nearly always the sentence that says what the chat was about.
        let theirs = fresh.filter { !$0.fromWearer }
        let gist = theirs.max(by: { $0.translated.count < $1.translated.count })?.translated ?? ""

        var body = ""
        for t in fresh {
            let who = t.fromWearer ? "Me" : "Them"
            body += "\(who): \(t.translated)\n"
            if !t.original.isEmpty && t.original != t.translated {
                body += "    (\(t.original))\n"
            }
        }

        // TWO entries on purpose: a permanent headline and an expiring body.
        ChappyMemory.shared.remember(.talk,
            title: gist.isEmpty ? title : "\(title) — \(String(gist.prefix(80)))",
            tags: ["talk", lang.lowercased(), "conversation"],
            source: "translate")
        ChappyMemory.shared.remember(.talk,
            title: "Full transcript — \(lang)",
            body: body,
            tags: ["transcript", lang.lowercased()],
            expiresInDays: 60,
            source: "translate")
    }

    func stopRecording() {
        translateService?.stopRecording()
        isRecording = false
        archiveConversationToMemory()
        // BUILD 121 — THE HOLE IN VOICE CONTROL OF THIS SCREEN.
        //
        // You could STOP a session by voice, because the translate microphone
        // was open and heard you. You could never START one, because the
        // moment it stopped, NOTHING was listening — Standby hands the
        // microphone over when this screen opens and never took it back. So
        // the red button was the only way back in, which is exactly the
        // "I shouldn't have to touch it" you described.
        //
        // Now: the instant recording stops, the wake word takes the mic back.
        // Say "Chappy, start" and you are translating again without looking.
        ChappyStandby.shared.resumeAfterHandOff()
        stopCostCheckpoint()
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

    /// FS-4: takes an optional now. StreamSessionViewModel nils its frame when
    /// the stream stops, but the forwarder only passed non-nil through and this
    /// took a non-optional — so there was no way to clear it. Glasses go flat
    /// mid-session and the 0.5s timer kept uploading the same dead JPEG, about
    /// 7,200 identical billed images an hour, while telling the interpreter
    /// about a scene you stopped looking at an hour ago.
    func updateVideoFrame(_ frame: UIImage?) {
        currentVideoFrame = frame
        lastFrameAt = frame == nil ? .distantPast : Date()
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
                self?.lostConnection = false
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
                // SB-5: cleared on every completed turn now, including the
                // silent ones. They used to leave their text frozen in the live
                // bubble, concatenating all session — which in turn wedged
                // isIdleMoment false forever and stranded every queued setting.
                self.streamingOriginal = ""
                self.streamingTranslation = ""
                self.lastStreamActivityAt = Date()
                self.appendTurn(heard: heard, translated: translated)
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

        // SB-4: the line is genuinely gone and we are not coming back on our
        // own. Without this the pill kept saying "Listening" into a dead socket
        // while every buffer was silently discarded — and still billed.
        translateService?.onDisconnected = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isRecording { self.stopRecording() }
                self.isConnected = false
                self.isAsleep = true
                self.lostConnection = true
                self.errorMessage = message
                self.showError = UIApplication.shared.applicationState == .active
            }
        }

        translateService?.onError = { [weak self] error in
            DispatchQueue.main.async {
                // BUILD 57: an alert raised while the app is in the background
                // is waiting for you the moment you come back, describing a
                // problem that no longer exists. Log it, don't ambush them.
                guard UIApplication.shared.applicationState == .active else {
                    print("🔇 [TranslateVM] Suppressed background error: \(error)")
                    return
                }
                self?.errorMessage = error
                self?.showError = true
            }
        }
    }

    /// Drop a marker row where the language changed. Nothing is deleted: the
    /// old conversation stays scrollable, because the price you agreed three
    /// turns ago doesn't stop mattering because you've switched languages.
    /// "Start fresh" on the divider clears it when you actually want that.
    private func markLanguageChange() {
        guard !transcript.isEmpty else { return }
        if transcript.last?.isDivider == true { transcript.removeLast() }
        transcript.append(TranslateTurn(
            original: "",
            translated: "Now translating \(targetLanguage.displayName)",
            fromWearer: false,
            sourceCode: sourceLanguage.rawValue,
            targetCode: targetLanguage.rawValue,
            isDivider: true
        ))
    }

    // MARK: - App lifecycle (BUILD 57)

    /// Minimising the app suspended the network stack under the socket, which
    /// surfaced as a socket error, which then tried to recover three times and
    /// finally threw an alert in your face — describing a failure you caused by
    /// pressing the home button. Translate has no reason to run in the
    /// background, so it stands down cleanly instead and waits for you.
    private func installLifecycleObserver() {
        guard backgroundToken == nil else { return }
        backgroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isConnected || self.isRecording else { return }

                // BUILD 59 FIX: iOS fires this when the screen LOCKS, not just
                // when you leave the app. Build 57 stood the session down either
                // way — which meant putting the phone in your pocket mid-
                // conversation, with the glasses on, killed the interpreter.
                // That's the whole point of wearing glasses.
                //
                // So: if you're actively interpreting through a headset, this is
                // a pocket, not an exit. The audio background mode keeps it alive
                // and it carries on in your ear. Otherwise you've genuinely left,
                // and holding a paid session open would be waste.
                if self.isRecording, Self.headsetConnected {
                    print("📱 [TranslateVM] Backgrounded on the glasses — carrying on")
                    return
                }

                print("📱 [TranslateVM] Backgrounded — standing the session down")
                if self.isRecording { self.stopRecording() }
                self.sleepSession()
            }
        }
    }

    /// Are the glasses (or any headset) actually connected right now?
    private static var headsetConnected: Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        let types: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .headsetMic]
        return route.outputs.contains { types.contains($0.portType) }
            || route.inputs.contains { types.contains($0.portType) }
    }

    // MARK: - Session cap and cost checkpoint (SB-3)

    /// SB-3: cost was banked ONLY when you pressed Stop or closed the screen. A
    /// crash, a jetsam kill on a hot phone, or a force-quit lost the entire
    /// span — Google billed you and your own meter recorded nothing. Worse, the
    /// spend warnings only fire when the meter moves, so they could never fire
    /// during the session doing the spending. Bank every minute instead.
    ///
    /// And cap it. The background handler deliberately keeps a headset session
    /// alive when you pocket the phone — correct behaviour, but with no ceiling
    /// an interrupted market conversation could stream for eight hours at about
    /// five cents a minute with nothing on screen.
    private static let maxRecordingMinutes: Double = 45

    private func startCostCheckpoint() {
        costTimer?.invalidate()
        costTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, let start = self.sessionStartAt else { return }
                // Bank the minute that just passed and restart the clock, so a
                // crash can never cost more than 60 seconds of unrecorded spend.
                CostMeter.shared.addLiveSeconds(Date().timeIntervalSince(start))
                self.sessionStartAt = Date()
                self.recordedMinutes += 1

                if self.recordedMinutes >= Self.maxRecordingMinutes {
                    print("⏹️ [TranslateVM] Session cap reached — stopping")
                    self.say("That's forty-five minutes of interpreting - I'm stopping to protect your credit. Tap the mic to carry on.")
                    self.stopRecording()
                }
            }
        }
    }

    private func stopCostCheckpoint() {
        costTimer?.invalidate()
        costTimer = nil
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
        // WATCH-LIST: idle sleep saved the API bill but left the glasses camera
        // at 15fps and the screen awake, on a phone already hot in Indonesia.
        stopImageTimer()
        translateService?.disconnect()
        translateService = nil
        isConnected = false
        isAsleep = true
        idleTimer?.invalidate()
        idleTimer = nil
    }

    // MARK: - Speech (FS-3)

    /// FS-3: audioOutputEnabled was consulted in exactly ONE place — the live
    /// audio stream. Every other spoken line went straight to TTSService, so
    /// "SPEAK off" still announced "They're speaking Javanese. Switching." out
    /// loud in a temple, still spoke every bubble tap, every saved phrase and
    /// every big-text "Say it". The control's own label promises a silent,
    /// reading-only interpreter. Everything Translate says now goes through
    /// here, and confirmations of your own commands are the only exemption —
    /// you need to hear that a command landed.
    func say(_ text: String, languageCode: String? = nil, isConfirmation: Bool = false) {
        guard audioOutputEnabled || isConfirmation else {
            print("🔇 [TranslateVM] Silent mode — not speaking: \(text.prefix(40))")
            return
        }
        if let code = languageCode {
            TTSService.shared.speakOffline(text, languageCode: code)
        } else {
            TTSService.shared.speak(text)
        }
    }

    /// A tap while speaking should stop, not restart (FS-11).
    func stopSpeaking() { TTSService.shared.stop() }

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
        // FS-11: SavedPhrase has stored languageCode since the day it was
        // written and nothing ever read it. Using it means the system voice can
        // speak straight away with no network round trip — which is what the UI
        // has been promising.
        if TTSService.shared.isSpeaking { stopSpeaking(); return }
        say(phrase.foreign, languageCode: phrase.languageCode)
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
        // SB-5: staleness escape. If nothing has streamed for two seconds the
        // moment is idle whatever is left sitting in the buffers, so a stuck
        // one can never strand a queued setting for the rest of the session.
        if Date().timeIntervalSince(lastStreamActivityAt) > 2.0 { return true }
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
        // Freshness check covers the silent-stall case that nil-forwarding
        // alone does not: the frame is still there, it is just old.
        guard Date().timeIntervalSince(lastFrameAt) < 1.5 else { return }
        translateService?.sendImageFrame(frame)
    }

    // MARK: - Transcript building (TRANSCRIPT v2)

    /// Who spoke? The mic setting is a hint, not proof — with the glasses mic
    /// live, BOTH of you are in range. So identify the language of what was
    /// actually said, on-device and free, and let that decide. Falls back to
    /// the mic hint when the sentence is too short to call.
    // MARK: - Verbal repeat (BUILD 54)

    /// SB-6: commands are matched on WORD BOUNDARIES against whole phrases, and
    /// the utterance must START with your name. The old matcher was a bare
    /// `contains` over the whole sentence, which meant "Chappy, is it going to
    /// be cloudy?" turned the loudspeaker on, "Chappy, does he speak English?"
    /// undid your mute, and "Chappy, don't talk to him" turned the voice ON — a
    /// direct inversion of what you asked for.
    private static func commandTail(_ text: String) -> [String]? {
        let cleaned = text.lowercased()
            .filter { $0.isLetter || $0.isWhitespace || $0.isNumber }
            .trimmingCharacters(in: .whitespaces)
        var tokens = cleaned.split(separator: " ").map(String.init)
        // BUILD 103: "hey chappy, change to German" failed because the FIRST
        // token had to be his name exactly. People lead with hey, ok, so, um.
        while let f = tokens.first, ["hey", "ok", "okay", "so", "um", "uh", "yo"].contains(f) {
            tokens.removeFirst()
        }
        guard let first = tokens.first else { return nil }
        // Same widened list as the wake word itself — a name the recogniser
        // spelled differently is a command that silently never happened.
        guard ["chappy", "chappie", "chappys", "chapy", "chappi", "chapi",
               "chappey", "chappe", "chapper", "chappa", "shappy", "chaphy"].contains(first)
        else { return nil }
        tokens.removeFirst()
        // Drop pure politeness so "Chappy, could you please be quiet" still lands.
        tokens.removeAll { ["please", "can", "you", "could", "would", "just", "now"].contains($0) }
        guard !tokens.isEmpty, tokens.count <= 6 else { return nil }
        return tokens
    }

    /// Words that can sit around a command without changing it into a sentence.
    private static let connectors: Set<String> = [
        "be", "the", "it", "a", "to", "my", "him", "her", "them", "up", "again", "mode",
        // Direction words: they qualify a command rather than turning it into a
        // sentence ("pronunciation off", "speaker on", "no talking").
        "on", "off", "no", "show", "hide", "stop"
    ]

    /// Does the tail MEAN this phrase — i.e. contain it on word boundaries, with
    /// nothing left over but connectors?
    ///
    /// SB-6 (second pass): matching the phrase anywhere in the tail still let
    /// "Chappy, does he speak English?", "Chappy, tell him this is private
    /// property" and "Chappy, ask him again" fire as commands. Those are things
    /// you say ABOUT someone, not TO the app. A command is an imperative with
    /// nothing else in it; anything carrying a verb like "tell", "ask" or "does"
    /// is a sentence and belongs to the person in front of you.
    private static func has(_ tokens: [String], _ phrase: String) -> Bool {
        let want = phrase.split(separator: " ").map(String.init)
        guard !want.isEmpty, tokens.count >= want.count else { return false }
        for i in 0...(tokens.count - want.count) where Array(tokens[i..<(i + want.count)]) == want {
            var leftover = tokens
            leftover.removeSubrange(i..<(i + want.count))
            if leftover.allSatisfy({ connectors.contains($0) }) { return true }
        }
        return false
    }

    /// English repeat wording — whole phrases in the tail after your name.
    private static let repeatPhrasesEN: [String] = [
        "say that again", "say it again", "repeat that", "repeat it",
        "repeat", "one more time", "again", "play that again", "come again"
    ]

    /// SB-6: "maaf" is GONE. It is the most common Indonesian courtesy word —
    /// sorry, excuse me — and a complete utterance on its own. A vendor saying
    /// just "Maaf." triggered a replay and was never filed as a bubble; and
    /// because attribution comes from the output language, YOUR OWN "maaf" came
    /// back as English "Sorry", was attributed to them, and fired the replay
    /// too. That is precisely the bug removing English "sorry" was meant to fix.
    private static let repeatWordsLocal: [String] = [
        "ulangi", "tolong ulangi", "ulangi lagi", "sekali lagi", "bisa ulangi",
        "apa",
        "อีกครั้ง", "พูดอีกที", "nhac lai", "nhắc lại"
    ]

    /// Is this an instruction to the app, or something to translate?
    private static func isRepeatCommand(_ text: String, spokenByWearer: Bool) -> Bool {
        if let tail = commandTail(text) {
            return repeatPhrasesEN.contains { has(tail, $0) }
        }
        // The local shortcuts belong to the LOCAL — they can't say your name.
        guard !spokenByWearer else { return false }
        let t = text.lowercased()
            .filter { !$0.isPunctuation }
            .trimmingCharacters(in: .whitespaces)
        return repeatWordsLocal.contains(t)
    }

    @discardableResult
    private func handleSettingCommand(_ text: String) -> Bool {
        // BUILD 103 — CLOSING IT, WITHOUT THE WAKE WORD.
        // Nobody says "stop the translation" to the person standing in front
        // of them through an interpreter, so these need no name in front. They
        // had no handler at all before, which is why the only way out of a
        // conversation was digging the phone out and finding the X.
        let bare = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // BUILD 121: pausing without leaving. "Stop listening" is not the same
        // request as "close translate", and conflating them lost the transcript.
        if ["stop listening", "pause", "hold on stop", "stop the mic",
            "stop recording", "mute the mic"].contains(where: { bare.contains($0) }) {
            if isRecording { say("Paused.", isConfirmation: true); stopRecording() }
            return true
        }
        if ["stop translating", "stop translation", "stop the translation",
            "stop translate", "close translate", "close translation",
            "close the translation", "end translation", "end the translation",
            "finish translating", "translation stop", "translate stop",
            "were done here", "we're done here"].contains(where: { bare.contains($0) }) {
            say("Closing translate.", isConfirmation: true)
            stopRecording()
            NotificationCenter.default.post(name: .chappyCloseModules, object: nil)
            return true
        }

        guard let tail = Self.commandTail(text) else { return false }

        // "Chappy, read this" — mid-conversation, hands full, someone holding a
        // menu up in front of you. This is the whole point of the feature: it
        // has to happen INSIDE the conversation, not instead of it.
        let joined = tail.joined(separator: " ")
        if ["read this", "read that", "scan this", "scan that", "read it",
            "scan", "what does this say", "what does that say", "read the menu",
            "read the sign", "translate this", "translate that"].contains(joined) {
            scanDocument()
            return true
        }
        if ["read it out", "read it all", "read the whole thing", "read that out",
            "read it aloud", "read all of it"].contains(joined) {
            readLastScan()
            return true
        }
        func has(_ p: String) -> Bool { Self.has(tail, p) }

        // BUILD 103 — CHANGING LANGUAGE MID-CONVERSATION.
        // "Chappy, change to German" was routed nowhere and simply got
        // translated into Indonesian and spoken at the other person. The
        // retarget path existed and Standby could reach it — but Standby is
        // handed off while this screen owns the microphone, so from in here
        // there was no way to get to it. This screen already transcribes
        // everything you say; it just had to look.
        // BUILD 120 — WHY "CHAPPY, CHANGE TO FRENCH" DID NOTHING.
        //
        // has() only matches when everything LEFT OVER after the phrase is a
        // filler word. That is exactly right for "be polite" and exactly wrong
        // here, because the leftover IS the payload — "change to french" left
        // "french" behind, which is not filler, so the whole branch was
        // skipped and your command got translated at the other person instead.
        //
        // Language changes match on the raw tail instead.
        let joinedTail = tail.joined(separator: " ")
        if ["change to", "switch to", "change the language", "make it", "now in",
            "put it in", "swap to", "translate to", "change language",
            "speak", "talk in", "go to"].contains(where: { joinedTail.contains($0) })
            || ChappyStandby.languageCode(spokenIn: joinedTail) != nil {
            if let code = ChappyStandby.languageCode(spokenIn: joinedTail),
               let lang = TranslateLanguage(rawValue: code) {
                targetLanguage = lang
                UserDefaults.standard.set(code, forKey: "translate_target_language")
                UserDefaults.standard.set(code, forKey: "translate_last_used_language")
                say("Now in \(lang.displayName).", isConfirmation: true)
                return true
            }
            // Heard the shape of it but not the language. Say so rather than
            // translating "change to German" at the poor bloke opposite.
            say("Which language?", isConfirmation: true)
            return true
        }

        // Closing, with the name in front of it.
        if has("stop") || has("close") || has("exit") || has("finish")
            || has("done") || has("thats it") || has("that's it") {
            say("Closing translate.", isConfirmation: true)
            stopRecording()
            NotificationCenter.default.post(name: .chappyCloseModules, object: nil)
            return true
        }

        if has("polite") || has("formal") || has("respectful") {
            politeMode = true
            say("Polite from here.", isConfirmation: true)
            return true
        }
        if has("casual") || has("relaxed") || has("informal") {
            politeMode = false
            say("Casual from here.", isConfirmation: true)
            return true
        }

        // Silence. SB-6: "dont talk", "no talking" and "stop speaking" were all
        // missing, so they fell through to the speech-ON branch below and did
        // the exact opposite of what was asked.
        if has("quiet") || has("silent") || has("mute") || has("shush")
            || has("stop talking") || has("dont talk") || has("do not talk")
            || has("no talking") || has("stop speaking") || has("dont speak")
            || has("no voice") || has("text only") || has("read only") {
            audioOutputEnabled = false
            say("Silent. I'll write it, not say it.", isConfirmation: true)
            return true
        }

        if has("speaker off") || has("glasses only") || has("glasses")
            || has("private") || has("headphones") || has("in my ear") {
            loudSpeaker = false
            say("Back to your glasses.", isConfirmation: true)
            return true
        }

        // "out loud" first — it used to be dead code behind the bare "loud".
        if has("out loud") || has("loud") || has("loudspeaker")
            || has("speaker on") || has("speak up") {
            audioOutputEnabled = true
            loudSpeaker = true
            say("Loudspeaker on.", isConfirmation: true)
            return true
        }

        if has("speak") || has("talk") || has("unmute") || has("voice on") {
            audioOutputEnabled = true
            say("Speaking again.", isConfirmation: true)
            return true
        }

        // SB-6: this was a blind toggle that ignored the on/off word, so
        // "Chappy, pronunciation off" turned it ON whenever it was already off.
        if has("pronunciation") || has("pronounce") || has("phonetic")
            || has("pinyin") || has("romaji") {
            let key = "translate_show_pronunciation"
            let current = (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
            // Direction is a plain token check — has() requires the leftover to
            // be connectors only, which "pronunciation" is not, so it would
            // never see the on/off word and every command became a blind toggle.
            let wantsOff = tail.contains("off") || tail.contains("hide")
                || tail.contains("no") || tail.contains("stop")
            let wantsOn = tail.contains("on") || tail.contains("show")
            let next = wantsOff ? false : (wantsOn ? true : !current)
            UserDefaults.standard.set(next, forKey: key)
            say(next ? "Pronunciation on." : "Pronunciation off.", isConfirmation: true)
            return true
        }

        return false
    }

    /// Replay the last thing the OTHER person's side produced. If you ask, you
    /// want their words back in English; if they ask, they want yours back in
    /// their language. Falls back to the most recent line either way.
    private func handleRepeatCommand(askedByWearer: Bool) {
        // Skip divider rows — "say that again" should never replay
        // "Now translating German" at somebody.
        let spoken = transcript.filter { !$0.isDivider }
        let wanted = spoken.last(where: { $0.fromWearer != askedByWearer }) ?? spoken.last
        guard let turn = wanted, !turn.translated.isEmpty else {
            say("Nothing to repeat yet.", isConfirmation: true)
            return
        }
        print("🔁 [TranslateVM] Verbal repeat — replaying: \(turn.translated.prefix(40))")
        say(turn.translated)
    }

    private func appendTurn(heard: String, translated: String) {
        let clean = heard.trimmingCharacters(in: .whitespacesAndNewlines)

        // AUDIT FIX (TR-H2): identify the speaker ONCE, up front, and let both
        // the command checks and the bubble use it. It used to run twice with
        // slightly different rules, which is how a rule could be right in one
        // place and wrong in the other.
        var fromWearer = !usePhoneMic
        var detected: String? = Self.identify(clean)

        // BUILD 57: identify from the TRANSLATION first, not the original.
        // The translation is written cleanly by the model; the original is a
        // transcription of noisy audio and gets it wrong on short words —
        // "bagus" was too short to call and landed on your side of the screen.
        // And the logic is exact: an interpreter always answers in the OTHER
        // language, so if the reply is in their language, you spoke.
        let cleanTranslated = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        if let outLang = Self.identify(cleanTranslated) {
            if Self.sameLanguage(outLang, targetLanguage.rawValue) {
                fromWearer = true
            } else if Self.sameLanguage(outLang, sourceLanguage.rawValue) {
                fromWearer = false
            } else if let lang = detected {
                fromWearer = Self.sameLanguage(lang, sourceLanguage.rawValue)
            }
        } else if let lang = detected {
            fromWearer = Self.sameLanguage(lang, sourceLanguage.rawValue)
        }
        if detected == nil { detected = Self.identify(cleanTranslated) }

        // FS-10: identify() gives up under four characters, so "Ya", "Ok",
        // "No" and bare numbers fell back to the static mic hint and always
        // landed on the same side — on the glasses mic every "Ya" the vendor
        // said appeared as YOU. In a haggle those short turns are most of the
        // conversation. Conversations alternate: inherit the opposite side.
        if detected == nil, let last = transcript.last(where: { !$0.isDivider }) {
            fromWearer = !last.fromWearer
        }

        // BUILD 124: speaker identification leans on the TRANSLATION to decide
        // who spoke — and from this build the interpreter is held silent on any
        // turn carrying the app's name, so a command arrives with an empty
        // translation and nothing to identify from. Left alone, the
        // alternating-turns fallback above could hand the wearer's own command
        // to the other side of the screen and it would never reach the command
        // handler at all: silent, ignored, and looking exactly like a crash.
        // Only the wearer ever says the app's name. Settle it here.
        if LiveTranslateService.carriesCommandName(clean) {
            fromWearer = true
        }

        // VERBAL REPEAT: catch it before it becomes a bubble. The interpreter
        // has been told to stay silent on these, so nothing was spoken over it.
        if Self.isRepeatCommand(clean, spokenByWearer: fromWearer) {
            handleRepeatCommand(askedByWearer: fromWearer)
            return
        }

        // BUILD 57: every toggle on the screen also has a spoken form, so you
        // never have to dig the phone out mid-conversation. Same rule as repeat
        // — your name is what makes it a command, so "could you be polite to
        // him" or "speak up, I can't hear you" still get translated normally.
        // Only YOUR voice can drive the app. Whatever the person opposite says,
        // however it transcribes, it gets translated and never acted on.
        if fromWearer, handleSettingCommand(clean) { return }

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

        // BUILD 58: you speak English and they speak the target language. If the
        // transcriber comes back with a THIRD language on YOUR turn, it misheard
        // — and the translation is then a faithful rendering of a sentence you
        // never said. That's how "그렇지. 딱이지?" appeared on a German session.
        // Flag it rather than presenting nonsense as though it were real.
        // FS-10: this used to check only YOUR side, so a third-language
        // mistranscription of THEIR speech was drawn undimmed with no warning —
        // exactly what the flag exists to prevent.
        var misheard = false
        if let d = detected,
           !Self.sameLanguage(d, sourceLanguage.rawValue),
           !Self.sameLanguage(d, targetLanguage.rawValue) {
            misheard = true
            print("⚠️ [TranslateVM] Misheard as \(d): \(clean.prefix(40))")
        }

        let turn = TranslateTurn(
            at: Date(),
            original: clean,
            translated: translated.trimmingCharacters(in: .whitespacesAndNewlines),
            fromWearer: fromWearer,
            detectedLanguage: detected,
            sourceCode: sourceLanguage.rawValue,
            targetCode: targetLanguage.rawValue,
            misheard: misheard
        )
        transcript.append(turn)
        currentOriginal = turn.original
        noteMishearStreak(misheard: misheard, fromWearer: fromWearer)

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
        // BUILD 57: this used to stand down entirely once you'd pinned a
        // default — so pinning the pair while it was still the wrong way round
        // locked it backwards permanently, with the correction switched off.
        // The condition below is strict: it only fires when YOUR side is a
        // language your phone isn't in AND their side is. A deliberate choice
        // like English → Indonesian can never trip it.
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
        // If a backwards pair had been pinned, repair the pin too — otherwise
        // it would come back wrong the very next time you opened Translate.
        if hasOwnDefault {
            UserDefaults.standard.set(sourceLanguage.rawValue, forKey: "translate_default_source")
            UserDefaults.standard.set(targetLanguage.rawValue, forKey: "translate_default_target")
        }
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
        // BUILD 57: Apple reports Indonesian as Malay ("ms") more often than
        // not — they're close enough that its classifier can't reliably split
        // them, and every one of those was landing on the wrong side.
        let aliases: [String: Set<String>] = [
            "id": ["ms"],           // Indonesian ↔ Malay
            "ms": ["id"],
            "fi": ["tl"],           // fil ↔ tl
            "yu": ["zh"],           // yue ↔ zh
            "zh": ["yu"]
        ]
        return aliases[o]?.contains(d) ?? false
    }

    /// BUILD 57: the threshold used to be eight characters, which threw away
    /// exactly the words that matter in a market — "bagus", "berapa", "boleh".
    /// Four is enough for the classifier to have an opinion worth using.
    private static func identify(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4 else { return nil }
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(t)
        return recogniser.dominantLanguage?.rawValue
    }

    // MARK: - Auto-retarget (BUILD 54)

    private var retargetCandidate: TranslateLanguage?
    private var retargetHits = 0

    /// Apple's detector speaks a slightly different dialect of language codes
    /// than our enum does. Translate between the two, or give up honestly.
    private static func language(fromDetected code: String?) -> TranslateLanguage? {
        guard let code else { return nil }
        // FS-8: match the FULL code first — "yue" was truncated to "yu" and
        // lost. Then Apple's spellings: it reports Indonesian as Malay far more
        // often than "id", and every one of those was zeroing the retarget
        // counter with exactly the detections it needed to accumulate.
        let full = code.lowercased()
        if let exact = TranslateLanguage(rawValue: full) { return exact }
        var short = String(full.prefix(2))
        switch short {
        case "tl": short = "fil"
        case "ms": short = "id"
        case "yu": short = "yue"
        default: break
        }
        return TranslateLanguage(rawValue: short)
    }

    /// When the other person turns out to be speaking something other than what
    /// we're aimed at, aim at it instead. Only ever moves the language THEY
    /// speak — your side stays put.
    private func autoRetarget(to detected: String?, spokenByWearer: Bool) {
        // BUILD 61 FIX: your own turns used to fall into the reset below, which
        // meant the counter was wiped every time you opened your mouth. In a
        // real conversation you alternate — you, them, you, them — so "two turns
        // in a row from them" could NEVER be reached and auto-retarget was
        // effectively dead. Your speech is not evidence about their language;
        // it should be ignored, not treated as a contradiction.
        guard !spokenByWearer else { return }

        guard let lang = Self.language(fromDetected: detected),
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
        say("They're speaking \(name). Switching.", isConfirmation: true)
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

    /// BUILD 57: currency by COUNTRY first. Keying it off language was fine in
    /// Asia, where one language mostly means one currency, and completely wrong
    /// across South America — Spanish was mapped to euros, so a price in Lima,
    /// Buenos Aires or Bogotá would have been converted as though the vendor
    /// wanted euros. Where you're standing decides what's in the till.
    /// CRASH FIX (builds 63/64/65): this was a bare dictionary literal, and the
    /// FS-9 block below re-listed "MY" and "BN", which line 1404 already had.
    /// Swift does NOT reject duplicate keys in a dictionary literal at compile
    /// time — `Dictionary(dictionaryLiteral:)` calls `_precondition` at runtime,
    /// which is live in release builds. So it compiled clean, shipped, and
    /// trapped with "Fatal error: Dictionary literal contains duplicate keys"
    /// the first time anything read it.
    ///
    /// It read it on the first COMPLETED bubble: PriceSpotter.find consults the
    /// currency table before it checks whether the line even contains money, so
    /// every rendered turn hit it. The live streaming bubble skips priceChip,
    /// which is why it always survived exactly one sentence.
    ///
    /// Built with `uniquingKeysWith:` so appending a block can never trap again.
    /// `Dictionary(uniqueKeysWithValues:)` would NOT be safe — it traps too.
    static let currencyForCountry: [String: String] = Dictionary(
        currencyForCountryPairs, uniquingKeysWith: { first, _ in first })

    private static let currencyForCountryPairs: [(String, String)] = [
        // South America
        ("BR", "BRL"), ("AR", "ARS"), ("CL", "CLP"), ("CO", "COP"), ("PE", "PEN"),
        ("UY", "UYU"), ("PY", "PYG"), ("BO", "BOB"), ("EC", "USD"), ("VE", "VES"),
        ("GY", "GYD"), ("SR", "SRD"),
        // Central America, Mexico, Caribbean
        ("MX", "MXN"), ("CR", "CRC"), ("PA", "PAB"), ("GT", "GTQ"), ("HN", "HNL"),
        ("NI", "NIO"), ("SV", "USD"), ("DO", "DOP"), ("CU", "CUP"), ("PR", "USD"),
        // Southeast Asia
        ("ID", "IDR"), ("TH", "THB"), ("VN", "VND"), ("PH", "PHP"), ("KH", "KHR"),
        ("LA", "LAK"), ("MY", "MYR"), ("SG", "SGD"), ("BN", "BND"), ("TL", "USD"),
        // Rest
        ("CN", "CNY"), ("TW", "TWD"), ("HK", "HKD"), ("MO", "MOP"), ("JP", "JPY"),
        ("KR", "KRW"), ("IN", "INR"), ("NP", "NPR"), ("TR", "TRY"), ("RU", "RUB"),
        ("AE", "AED"), ("SA", "SAR"), ("QA", "QAR"), ("EG", "EGP"), ("MA", "MAD"),
        ("AU", "AUD"), ("NZ", "NZD"), ("GB", "GBP"), ("US", "USD"), ("CA", "CAD"),
        ("PT", "EUR"), ("ES", "EUR"), ("FR", "EUR"), ("DE", "EUR"), ("IT", "EUR"),
        ("GR", "EUR"), ("AO", "AOA"), ("MZ", "MZN"), ("CV", "CVE"),
        // FS-9: these were mapped to a language but had no currency, so they
        // fell through to the language guess — a 20 JOD item (about A$43) was
        // being shown as "20 AED ≈ A$8.30". Kuwait was worse.
        ("JO", "JOD"), ("KW", "KWD"), ("OM", "OMR"), ("BH", "BHD"), ("TN", "TND"),
        ("LB", "LBP"), ("CH", "CHF"), ("MY", "MYR"), ("BN", "BND"), ("IL", "ILS"),
        ("PK", "PKR"), ("BD", "BDT"), ("LK", "LKR"), ("MM", "MMK"), ("MN", "MNT"),
        ("ZA", "ZAR"), ("KE", "KES"), ("NG", "NGN"), ("PL", "PLN"), ("CZ", "CZK"),
        ("HU", "HUF"), ("RO", "RON"), ("SE", "SEK"), ("NO", "NOK"), ("DK", "DKK")
    ]

    /// FS-9: what language you'd expect to be spoken in each country. Used only
    /// to notice when GPS and the actual conversation disagree.
    /// CRASH-CLASS GUARD: built with `uniquingKeysWith:` so appending a
    /// block can never trap the way currencyForCountry did. A bare literal
    /// with one repeated key is a release-build fatal error, not a warning.
    static let expectedLanguage: [String: String] = Dictionary(
        expectedLanguagePairs, uniquingKeysWith: { first, _ in first })

    private static let expectedLanguagePairs: [(String, String)] = [
        ("ID", "id"), ("MY", "id"), ("BN", "id"), ("TH", "th"), ("VN", "vi"), ("PH", "fil"),
        ("KH", "km"), ("LA", "lo"), ("CN", "zh"), ("TW", "zh"), ("SG", "zh"), ("HK", "yue"),
        ("MO", "yue"), ("JP", "ja"), ("KR", "ko"), ("IN", "hi"), ("NP", "hi"), ("TR", "tr"),
        ("FR", "fr"), ("IT", "it"), ("DE", "de"), ("AT", "de"), ("CH", "de"), ("RU", "ru"),
        ("GR", "el"), ("CY", "el"), ("PT", "pt"), ("BR", "pt"), ("AO", "pt"), ("MZ", "pt"),
        ("ES", "es"), ("MX", "es"), ("AR", "es"), ("CL", "es"), ("CO", "es"), ("PE", "es"),
        ("UY", "es"), ("PY", "es"), ("BO", "es"), ("EC", "es"), ("VE", "es"), ("CR", "es"),
        ("PA", "es"), ("GT", "es"), ("HN", "es"), ("NI", "es"), ("SV", "es"), ("DO", "es"),
        ("CU", "es"), ("AE", "ar"), ("SA", "ar"), ("EG", "ar"), ("MA", "ar"), ("JO", "ar"),
        ("KW", "ar"), ("OM", "ar"), ("BH", "ar"), ("TN", "ar"), ("LB", "ar"), ("QA", "ar")
    ]

    /// Fallback when there's no GPS fix yet — language is a decent guess.
    /// CRASH-CLASS GUARD: built with `uniquingKeysWith:` so appending a
    /// block can never trap the way currencyForCountry did. A bare literal
    /// with one repeated key is a release-build fatal error, not a warning.
    static let currencyForLanguage: [String: String] = Dictionary(
        currencyForLanguagePairs, uniquingKeysWith: { first, _ in first })

    private static let currencyForLanguagePairs: [(String, String)] = [
        ("id", "IDR"), ("th", "THB"), ("vi", "VND"), ("fil", "PHP"), ("km", "KHR"),
        ("lo", "LAK"), ("zh", "CNY"), ("yue", "HKD"), ("ja", "JPY"), ("ko", "KRW"),
        ("hi", "INR"), ("tr", "TRY"), ("ar", "AED"), ("el", "EUR"), ("fr", "EUR"),
        ("it", "EUR"), ("de", "EUR"), ("ru", "RUB"),
        // Best guess only — the country map above overrides these whenever
        // there's a GPS fix, which there almost always is.
        ("es", "USD"), ("pt", "BRL")
    ]

    /// The currency actually in the till: country if we know it, language if not.
    static func currency(forLanguage lang: String) -> String? {
        let country = (ContextEngine.shared.snapshot.countryCode ?? "").uppercased()
        if !country.isEmpty, let byCountry = currencyForCountry[country] {
            // FS-9: the GPS country used to win unconditionally, so an
            // Indonesian speaker in Johor or on the Batam ferry had "harga 250
            // ribu" labelled MYR. When where you are and what is being spoken
            // disagree, we cannot know which currency is meant — and a wrong
            // price is worse than no price, which is this feature's own rule.
            if let expected = expectedLanguage[country],
               expected != lang,
               currencyForLanguage[lang] != byCountry {
                return nil
            }
            return byCountry
        }
        return currencyForLanguage[lang]
    }

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
