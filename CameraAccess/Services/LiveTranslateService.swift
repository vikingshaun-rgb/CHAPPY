/*
 * Live Translate WebSocket Service
 * Realtime speech translation powered by the Gemini Live API
 * (native audio: speech in -> translated speech out)
 *
 * Drop-in replacement for the previous Alibaba implementation:
 * same class name, callbacks and public methods, so the existing
 * LiveTranslateViewModel and views work unchanged.
 */

import Foundation
import UIKit
import AVFoundation

// MARK: - Service Class

class LiveTranslateService: NSObject {

    // WebSocket
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Configuration
    private let apiKey: String
    // HARD PIN: same known-good Live model as GeminiLiveService (old
    // gemini-live-2.5-flash-native-audio is retired and kills the socket).
    private let model = GeminiLiveService.liveModel
    private let baseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    private var didReportSocketError = false

    // Audio Engine (for recording)
    private var audioEngine: AVAudioEngine?

    // Audio Playback Engine (separate engine for playback)
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)

    // Audio buffer management
    private var hasStartedPlaying = false
    private var isPlaybackEngineRunning = false

    // Translation settings
    private var sourceLanguage: TranslateLanguage = .en
    private var targetLanguage: TranslateLanguage = .en
    private var voice: TranslateVoice = .cherry
    private var audioOutputEnabled = true
    /// BUILD 55: respectful register for officials and landlords, casual for
    /// the street. Set before connect, and on every settings push.
    var politeMode = true

    // Audio resampling
    private var audioConverter: AVAudioConverter?
    private let targetSampleRate: Double = 16000  // Gemini expects 16 kHz input

    // Callbacks (unchanged interface)
    var onConnected: (() -> Void)?
    var onTranslationText: ((String) -> Void)?    // final translation text
    var onTranslationDelta: ((String) -> Void)?   // incremental translation text
    var onAudioDelta: ((Data) -> Void)?
    var onAudioDone: (() -> Void)?
    var onError: ((String) -> Void)?
    // TRANSCRIPT v2: the speaker's own words, streaming and finalised.
    var onOriginalDelta: ((String) -> Void)?      // incremental heard text
    var onTurnComplete: ((String, String) -> Void)?  // (heard, translated)

    // State
    private var isRecording = false
    private var isConnected = false
    private var accumulatedText = ""
    /// TRANSCRIPT v2: incoming speech, accumulated across a turn.
    private var accumulatedOriginal = ""
    /// ECHO GATE: the microphone stays shut until this moment has passed.
    private var micGateUntil = Date.distantPast
    /// BUILD 54: one tail length can't suit both cases. On the phone's own
    /// loudspeaker the mic is centimetres from the source and the room rings,
    /// so it needs the longer hold. Through the glasses the sound is at your
    /// ear and barely reaches the mic, so a long tail only eats your first
    /// word — which is exactly what clipped "how far to the boat" down to
    /// "far to the boat". Set it from the hardware actually in use.
    /// BUILD 54: start SHORT and earn the extra time only if the room proves it
    /// needs it. The audio length itself is known exactly; this covers the three
    /// things that can't be calculated — the room still ringing, Bluetooth lag,
    /// and the model's voice detection grabbing a dying syllable. Guessing high
    /// costs you the first word of every sentence, so guess low and adapt.
    private var echoTailSeconds: TimeInterval = 0.4
    private static let tailOnSpeaker: TimeInterval = 0.4
    private static let tailOnHeadset: TimeInterval = 0.25
    private static let tailCeiling: TimeInterval = 0.9

    /// Called when an echo actually gets through. Evidence beats my guess: back
    /// the gate off a notch, up to a sane ceiling, and stay there for the rest
    /// of the session. Two or three leaks and it settles wherever this room
    /// needs it to be, without you touching a thing.
    func lengthenEchoTail() {
        guard echoTailSeconds < Self.tailCeiling else { return }
        echoTailSeconds = min(echoTailSeconds + 0.15, Self.tailCeiling)
        print("🔇 [Translate] Echo got through — tail now \(echoTailSeconds)s")
    }
    /// Output forced to the iPhone's loudspeaker so a table can hear it.
    private var loudSpeaker = false
    private var bluetoothInputAvailable = false
    /// BUILD 56: session continuity, ported from Live AI.
    private var resumptionHandle: String?
    private var isRenewingSession = false
    private var recoveryAttempts = 0
    /// True from the user opening Translate until they close it. Recovery must
    /// never fire after a deliberate disconnect.
    private var isUserSessionActive = false

    // Reconnect bookkeeping: recording may only resume AFTER setupComplete,
    // never straight after connect() — audio sent before setup kills the socket.
    private var shouldResumeRecordingAfterSetup = false
    private var lastUsePhoneMic = false

    // Image sending
    private var lastImageSendTime: Date?
    private let imageInterval: TimeInterval = 0.5  // at most one image every 0.5 s

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
        setupAudioEngine()
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        setupPlaybackEngine()
    }

    private func setupPlaybackEngine() {
        playbackEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let playbackEngine = playbackEngine,
              let playerNode = playerNode,
              let playbackFormat = playbackFormat else {
            print("❌ [Translate] Failed to initialize the playback engine")
            return
        }

        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
        playbackEngine.prepare()

        print("✅ [Translate] Playback engine initialized: Float32 @ 24kHz")
    }

    private func startPlaybackEngine() {
        guard let playbackEngine = playbackEngine, !isPlaybackEngineRunning else { return }
        do {
            try playbackEngine.start()
            isPlaybackEngineRunning = true
            print("▶️ [Translate] Playback engine started")
        } catch {
            print("❌ [Translate] Playback engine failed to start: \(error)")
        }
    }

    private func stopPlaybackEngine() {
        guard let playbackEngine = playbackEngine, isPlaybackEngineRunning else { return }
        playerNode?.stop()
        playerNode?.reset()
        playbackEngine.stop()
        isPlaybackEngineRunning = false
        // AUDIT FIX: hasStartedPlaying stayed true across restarts, so
        // playerNode.play() was never called again — translation went
        // permanently silent after any language/voice change.
        hasStartedPlaying = false
        print("⏹️ [Translate] Playback engine stopped")
    }

    // MARK: - Language helpers

    private func languageName(_ code: String) -> String {
        let map: [String: String] = [
            "en": "English", "zh": "Chinese (Mandarin)", "ja": "Japanese",
            "ko": "Korean", "fr": "French", "de": "German", "es": "Spanish",
            "it": "Italian", "pt": "Portuguese", "ru": "Russian",
            "vi": "Vietnamese", "th": "Thai", "id": "Indonesian",
            "ms": "Malay", "hi": "Hindi", "ar": "Arabic",
            "yue": "Cantonese", "auto": "the language being spoken"
        ]
        if let name = map[code] { return name }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// SYSTEM-WIDE VOICE: Translate follows the one voice chosen in
    /// Settings → Voice, same as Live AI and spoken replies. The legacy
    /// Alibaba voice picker in Translate settings is ignored (those voices
    /// never existed on Gemini anyway).
    private var geminiVoiceName: String {
        let stored = UserDefaults.standard.string(forKey: "chappy_tts_voice") ?? "Kore"
        if stored != "System" && !stored.isEmpty { return stored }
        return "Kore"
    }

    // MARK: - WebSocket Connection

    func connect() {
        let urlString = baseURL
        print("🔌 [Translate] Preparing WebSocket connection (Gemini Live)")

        guard let url = URL(string: urlString) else {
            print("❌ [Translate] Invalid URL")
            onError?("Invalid URL")
            return
        }

        didReportSocketError = false
        isUserSessionActive = true

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 15
        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())

        webSocket = urlSession?.webSocketTask(with: request)
        webSocket?.resume()

        print("🔌 [Translate] WebSocket task started")
        receiveMessage()
        // NOTE: sendSetup() now happens in didOpenWithProtocol — sending it
        // here raced the connection handshake and could be dropped/rejected.
    }

    func disconnect() {
        print("🔌 [Translate] Disconnecting WebSocket")
        isConnected = false
        // BUILD 56: a deliberate close must never trigger the recovery logic.
        isUserSessionActive = false
        recoveryAttempts = 0
        resumptionHandle = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        stopRecording()
        stopPlaybackEngine()
    }

    // MARK: - Configuration

    func updateSettings(
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage,
        voice: TranslateVoice,
        audioEnabled: Bool
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.voice = voice
        self.audioOutputEnabled = audioEnabled

        // Gemini Live sets system instructions at session start only —
        // if a session exists (even one mid-handshake or half-dead),
        // reconnect with the new settings.
        if webSocket != nil {
            print("🔄 [Translate] Settings changed - reconnecting session")
            let wasRecording = isRecording
            disconnect()
            // Resume recording only AFTER the new session's setupComplete —
            // starting it here pushed audio into an unconfigured socket, which
            // the server kills (this was the language-change crash).
            shouldResumeRecordingAfterSetup = wasRecording
            connect()
        }
    }

    private func sendSetup() {
        let source = languageName(sourceLanguage.rawValue)
        let target = languageName(targetLanguage.rawValue)

        // TWO-WAY AUTO-DETECT INTERPRETER: the model detects which language is
        // being spoken and translates in the appropriate direction — a whole
        // conversation works with no buttons and no language switching.
        let systemPrompt = """
        You are a professional two-way simultaneous interpreter between \(source) and \(target). \
        Listen to each utterance and detect its language automatically. \
        If the speech is in \(source), speak the \(target) translation. \
        For speech in ANY other language, including \(target), speak the \(source) translation \
        - the wearer speaks \(source), so anything foreign always comes back to them. \
        Speak ONLY the translation - no commentary, no explanations, no questions, \
        no extra words. Keep the tone and intent of the speaker. \
        SILENCE DISCIPLINE: if the audio is silence, background noise, music, a TV, \
        or speech clearly not directed at this conversation, output NOTHING AT ALL. \
        Never translate your own previous output. If an image is provided, use it \
        only as context to improve the translation. \
        \(politeMode
          ? "REGISTER: use the polite, respectful form of the language throughout - the level you would use with an official, a landlord, a police officer or an elder. Include the ordinary courtesy words a native speaker would use. "
          : "REGISTER: use the everyday casual form a friend or a market vendor would use - natural and relaxed, not stiff or formal. ")\
        PRICES: whenever a sum of money is spoken, render the number in the text \
        as DIGITS with thousands separators (say 250,000 - not two hundred and \
        fifty thousand), and keep the currency word. \
        CONTROL PHRASES: when the wearer says the name "Chappy" together with a \
        repeat instruction - "Chappy repeat that", "Chappy say that again", \
        "Chappy one more time" - that is an instruction to the app and NOT speech \
        to translate: output NOTHING AT ALL and stay silent, the app handles it. \
        A bare single word from the other speaker asking for a repeat - "ulangi", \
        "sekali lagi", "maaf", "apa" - is likewise handled by the app: stay silent. \
        Likewise "Chappy be polite", "Chappy formal" and "Chappy casual" are app \
        commands - stay silent, the app handles them. \
        CRITICAL: any OTHER sentence containing repeat wording IS ordinary speech \
        and must be translated normally. "Can you repeat that?", "sorry, could you \
        say that again?" and "one more time please" are things the wearer is saying \
        TO the person in front of them - translate those, never treat them as \
        commands. Only the name "Chappy" makes it an instruction.
        """

        var setup: [String: Any] = [
            "model": "models/\(model)",
            "systemInstruction": [
                "parts": [["text": systemPrompt]]
            ],
            "outputAudioTranscription": [:],
            // BUILD 56: SESSION CONTINUITY. Gemini Live sessions have a maximum
            // duration. The server warns with goAway and then aborts with 1008 —
            // which is exactly the "Socket closed — code 1008" that ended an
            // hour-long conversation. Ask for resumption handles so we can
            // reconnect into the SAME session instead of dying.
            "sessionResumption": (resumptionHandle != nil ? ["handle": resumptionHandle!] : [:]) as [String: Any],
            // TRANSCRIPT v2: ask the server to transcribe the INCOMING speech
            // too. Without this the app only ever knew what Chappy said back —
            // which is why the screen could show a translation but never the
            // sentence it came from, and why a saved history entry had an empty
            // originalText. This is what makes a two-sided transcript real.
            "inputAudioTranscription": [:]
        ]

        // NOTE: this Live model supports AUDIO responses ONLY — requesting TEXT
        // kills the session (1007). We always request AUDIO; when the user turns
        // voice output off, handleAudioChunk simply skips playback and the
        // transcription still provides the on-screen text.
        var generationConfig: [String: Any] = [:]
        generationConfig["responseModalities"] = ["AUDIO"]
        generationConfig["speechConfig"] = [
            "voiceConfig": [
                "prebuiltVoiceConfig": ["voiceName": geminiVoiceName]
            ]
        ]
        setup["generationConfig"] = generationConfig

        sendEvent(["setup": setup])
        print("📤 [Translate] Session setup sent: two-way \(source) ↔ \(target), voice: \(geminiVoiceName)")
    }

    // MARK: - Audio Recording

    /// BUILD 54: force sound out of the iPhone's own loudspeaker regardless of
    /// which microphone is in use. The glasses speaker is designed to be heard
    /// by you alone — across a table, in a warung, with two people listening,
    /// it simply isn't loud enough. This keeps the glasses mic (or the phone's)
    /// and moves only the OUTPUT to something everyone can hear.
    func setLoudSpeaker(_ on: Bool) {
        loudSpeaker = on
        applyOutputRoute()
        // Louder into the room means more of it comes back down the mic.
        echoTailSeconds = (bluetoothInputAvailable && !on) ? Self.tailOnHeadset : Self.tailOnSpeaker
        print("🔈 [Translate] Loudspeaker \(on ? "ON" : "off") — echo tail \(echoTailSeconds)s")
    }

    private func applyOutputRoute() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(loudSpeaker ? .speaker : .none)
        } catch {
            print("⚠️ [Translate] Could not switch output: \(error.localizedDescription)")
        }
    }

    func startRecording(usePhoneMic: Bool = false) {
        guard !isRecording else { return }
        lastUsePhoneMic = usePhoneMic

        do {
            print("🎤 [Translate] Start recording, using \(usePhoneMic ? "iPhone" : "Bluetooth") microphone")

            // AUDIT FIX (CRASH): a failed engine.start() left the tap
            // installed; the next record attempt double-installed and iOS
            // raised an uncatchable exception. Always remove first.
            if let engine = audioEngine {
                if engine.isRunning { engine.stop() }
                engine.inputNode.removeTap(onBus: 0)
            }

            let audioSession = AVAudioSession.sharedInstance()

            // BUILD 53: "use the glasses mic" is a preference, not a fact. With
            // the glasses off or flat, this asked for a Bluetooth route that
            // isn't there and iOS quietly handed back the handset mic anyway —
            // configured for a headset that doesn't exist. Check what's actually
            // connected and set the session up for the hardware in the room.
            let bluetoothAvailable = (audioSession.availableInputs ?? []).contains {
                $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
            }
            bluetoothInputAvailable = bluetoothAvailable
            let usePhoneMic = usePhoneMic || !bluetoothAvailable
            if !bluetoothAvailable {
                print("🎙️ [Translate] No Bluetooth mic present — configuring for the iPhone")
            }

            // Short hold through the glasses, long hold on any loudspeaker.
            // BUILD 54 FIX: this used to key off the INPUT device only, so
            // turning the loudspeaker on while wearing the glasses would have
            // kept the 0.35s tail and walked us straight back into the echo
            // loop. It's the output that makes the noise, so ask about that.
            echoTailSeconds = (bluetoothAvailable && !loudSpeaker) ? Self.tailOnHeadset : Self.tailOnSpeaker
            print("🔇 [Translate] Echo tail: \(echoTailSeconds)s")

            if usePhoneMic {
                // iPhone microphone - best for translating the other person
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .voiceChat, // AUDIT FIX: .default has NO echo cancellation — the mic heard Chappy's own translation and translated it back, forever
                    options: [.defaultToSpeaker, .allowBluetoothA2DP]
                )
                print("🎙️ [Translate] Using iPhone mic (translate the other person)")
            } else {
                // Bluetooth mic (glasses) - best for translating yourself
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .voiceChat, // AUDIT FIX: .default has NO echo cancellation — the mic heard Chappy's own translation and translated it back, forever
                    options: [.allowBluetooth, .defaultToSpeaker, .allowBluetoothA2DP]
                )
                print("🎙️ [Translate] Using Bluetooth mic (translate yourself)")
            }
            try audioSession.setActive(true)
            applyOutputRoute()

            if let inputRoute = audioSession.currentRoute.inputs.first {
                print("🎙️ [Translate] Current input device: \(inputRoute.portName) (\(inputRoute.portType.rawValue))")
            }

            guard let engine = audioEngine else {
                print("❌ [Translate] Audio engine not initialized")
                return
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            print("🎵 [Translate] Input format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channels")
            print("🎵 [Translate] Target format: \(targetSampleRate) Hz (will auto-resample)")

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer)
            }

            engine.prepare()
            try engine.start()

            isRecording = true
            print("✅ [Translate] Recording started")

        } catch {
            print("❌ [Translate] Failed to start recording: \(error.localizedDescription)")
            onError?("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        print("🛑 [Translate] Stop recording")
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        isRecording = false
        micGateUntil = .distantPast
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.floatChannelData != nil else { return }

        // ECHO GATE (BUILD 53): drop everything the mic hears while Chappy is
        // still speaking, plus a short tail. This is what breaks the loop.
        // BUILD 54: tapping the speaker on a bubble to repeat a line plays out
        // of the SAME speaker — without this it would restart the exact loop we
        // just killed, one tap at a time.
        if TTSService.shared.isSpeaking { micGateUntil = Date() }
        if Date() < micGateUntil.addingTimeInterval(echoTailSeconds) { return }

        let inputSampleRate = buffer.format.sampleRate

        if inputSampleRate != targetSampleRate {
            guard let resampledBuffer = resampleBuffer(buffer) else { return }
            sendBufferAsPCM16(resampledBuffer)
        } else {
            sendBufferAsPCM16(buffer)
        }
    }

    private func resampleBuffer(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputFormat = inputBuffer.format
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1) else {
            return nil
        }

        if audioConverter == nil || audioConverter?.inputFormat != inputFormat {
            audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }

        guard let converter = audioConverter else {
            print("❌ [Translate] Failed to create the audio converter")
            return nil
        }

        let ratio = targetSampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        var hasProvidedInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasProvidedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("❌ [Translate] Resampling failed: \(error.localizedDescription)")
            return nil
        }

        return outputBuffer
    }

    private var audioSendCount = 0

    private func sendBufferAsPCM16(_ buffer: AVAudioPCMBuffer) {
        guard isConnected else { return }
        guard let floatChannelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channel = floatChannelData.pointee

        var int16Data = [Int16](repeating: 0, count: frameLength)
        for i in 0..<frameLength {
            let sample = channel[i]
            let clampedSample = max(-1.0, min(1.0, sample))
            int16Data[i] = Int16(clampedSample * 32767.0)
        }

        let data = Data(bytes: int16Data, count: frameLength * MemoryLayout<Int16>.size)
        let base64Audio = data.base64EncodedString()

        audioSendCount += 1
        if audioSendCount == 1 || audioSendCount % 50 == 0 {
            print("🎵 [Translate] Sending audio chunk #\(audioSendCount)")
        }

        let event: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": base64Audio,
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ]
        sendEvent(event)
    }

    // MARK: - Image Sending

    func sendImageFrame(_ image: UIImage) {
        guard isConnected else { return }
        let now = Date()
        if let lastTime = lastImageSendTime, now.timeIntervalSince(lastTime) < imageInterval {
            return
        }
        lastImageSendTime = now

        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            print("❌ [Translate] Failed to compress image")
            return
        }

        guard imageData.count <= 500 * 1024 else {
            print("⚠️ [Translate] Image too large - skipping send")
            return
        }

        let base64Image = imageData.base64EncodedString()
        print("📸 [Translate] Sending image: \(imageData.count) bytes")

        let event: [String: Any] = [
            "realtimeInput": [
                "video": [
                    "data": base64Image,
                    "mimeType": "image/jpeg"
                ]
            ]
        ]
        sendEvent(event)
    }

    // MARK: - Send Events

    private func sendEvent(_ event: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ [Translate] Failed to serialize event")
            return
        }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocket?.send(message) { [weak self] error in
            if let error = error {
                let nsError = error as NSError
                print("❌ [Translate] Send failed: \(error.localizedDescription)")
                if nsError.code != 57 && nsError.code != -999 {
                    self?.reportSocketError("Send error: \(error.localizedDescription)")
                }
            }
        }
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
                print("❌ [Translate] Receive failed: \(error.localizedDescription) [\(nsError.domain) \(nsError.code)]")
                // BUILD 56: 57 and -999 are our own teardown. Anything else is
                // a live socket dying mid-conversation — try to recover before
                // troubling the user with an alert.
                if nsError.code != 57 && nsError.code != -999 {
                    self?.attemptRecovery("receive error \(nsError.code)")
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            if let data = text.data(using: .utf8) { handleServerData(data) }
        case .data(let data):
            handleServerData(data)
        @unknown default:
            break
        }
    }

    private func handleServerData(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("⚠️ [Translate] Received an unparseable message")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Session established
            if json["setupComplete"] != nil {
                print("✅ [Translate] Session established (Gemini Live)")
                self.isConnected = true
                self.accumulatedText = ""
                self.onConnected?()
                // Safe point to resume recording after a settings reconnect
                // BUILD 56: a good handshake clears the recovery budget, so a
                // later unrelated drop still gets its own three tries.
                self.recoveryAttempts = 0
                self.didReportSocketError = false
                if self.shouldResumeRecordingAfterSetup {
                    self.shouldResumeRecordingAfterSetup = false
                    self.startRecording(usePhoneMic: self.lastUsePhoneMic)
                }
                return
            }

            // Server content: audio chunks, transcription, turn completion
            if let serverContent = json["serverContent"] as? [String: Any] {

                // TRANSCRIPT v2: what the SPEAKER actually said, in their own
                // language — the left-hand side of every bubble pair.
                if let inputT = serverContent["inputTranscription"] as? [String: Any],
                   let text = inputT["text"] as? String, !text.isEmpty {
                    self.accumulatedOriginal += text
                    self.onOriginalDelta?(text)
                }

                // Translated-speech transcription (text of what is being spoken)
                if let transcription = serverContent["outputTranscription"] as? [String: Any],
                   let text = transcription["text"] as? String, !text.isEmpty {
                    self.accumulatedText += text
                    self.onTranslationDelta?(text)
                }

                // Audio chunks
                if let modelTurn = serverContent["modelTurn"] as? [String: Any],
                   let parts = modelTurn["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let inline = part["inlineData"] as? [String: Any],
                           let b64 = inline["data"] as? String,
                           let audioData = Data(base64Encoded: b64) {
                            self.handleAudioChunk(audioData)
                        }
                        if let text = part["text"] as? String, !text.isEmpty {
                            self.accumulatedText += text
                            self.onTranslationDelta?(text)
                        }
                    }
                }

                // Interruption: clear queued audio
                if (serverContent["interrupted"] as? Bool) == true {
                    print("⏸️ [Translate] Reply interrupted")
                    self.playerNode?.stop()
                    self.playerNode?.reset()
                    self.hasStartedPlaying = false
                }

                // Turn complete: finalize text
                if (serverContent["turnComplete"] as? Bool) == true {
                    let final = self.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let heard = self.accumulatedOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !final.isEmpty {
                        print("✅ [Translate] Translation complete: \(final.prefix(80))")
                        // TRANSCRIPT v2: the pair is delivered together so a turn
                        // can never be filed with a translation but no original.
                        self.onTurnComplete?(heard, final)
                        self.onTranslationText?(final)
                    }
                    self.accumulatedText = ""
                    self.accumulatedOriginal = ""
                    self.onAudioDone?()
                }
                return
            }

            // Errors / server-initiated disconnect
            // BUILD 56: the handle rotates; keep the newest one.
            if let update = json["sessionResumptionUpdate"] as? [String: Any],
               let handle = update["newHandle"] as? String, !handle.isEmpty {
                self.resumptionHandle = handle
                return
            }

            // BUILD 56: goAway is a WARNING, not a failure — the session clock
            // is running out. Reconnect on the handle now, quietly, while the
            // conversation is still going. This used to throw an alert in your
            // face and stop dead.
            if json["goAway"] != nil {
                print("⏳ [Translate] goAway — renewing the session")
                self.renewSession()
                return
            }
            if let error = json["error"] as? [String: Any] {
                let msg = (error["message"] as? String) ?? "\(error)"
                print("❌ [Translate] Server error: \(msg)")
                self.onError?(msg)
                return
            }
        }
    }

    // MARK: - Audio Playback (24 kHz PCM16 from Gemini)

    private func handleAudioChunk(_ audioData: Data) {
        onAudioDelta?(audioData)
        guard audioOutputEnabled else { return }

        // ECHO GATE (BUILD 53): hardware echo cancellation is not enough here.
        // The speaker plays the translation, the microphone hears it, the model
        // translates its own voice back, and the loop never stops:
        // "Okay" → "Baik, tenang saja" → "calm down" → "Tenang saja" → forever.
        // Real interpreters are half-duplex, and so is this now: while Chappy is
        // speaking, the microphone sends nothing. We hold the gate for exactly
        // as long as the audio we've queued, plus a short tail for the room.
        let frames = Double(audioData.count / 2)
        let seconds = frames / (playbackFormat?.sampleRate ?? 24000)
        micGateUntil = max(micGateUntil, Date()).addingTimeInterval(seconds)

        startPlaybackEngine()
        guard isPlaybackEngineRunning else { return }

        if !hasStartedPlaying {
            playerNode?.play()
            hasStartedPlaying = true
        }

        playAudio(audioData)
    }

    private func playAudio(_ audioData: Data) {
        guard let playbackFormat = playbackFormat,
              let buffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            return
        }
        playerNode?.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Server sends PCM16, 2 bytes per frame
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
}

// MARK: - Error Reporting

extension LiveTranslateService {
    /// Surfaces the FIRST socket failure to the UI and suppresses the follow-on
    /// cascade (close + receive-failure both fire for one collapse).
    fileprivate func reportSocketError(_ message: String) {
        guard !didReportSocketError else { return }
        didReportSocketError = true
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension LiveTranslateService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("🔌 [Translate] WebSocket opened — sending setup")
        DispatchQueue.main.async { [weak self] in
            self?.sendSetup()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason given"
        print("🔌 [Translate] WebSocket closed: \(closeCode.rawValue) \(reasonText)")
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
        }
        // BUILD 56: 1008 after a missed goAway is the session clock expiring,
        // not a fault. It's what killed your hour-long conversation with an
        // alert that read like a crash. Reconnect silently instead.
        if closeCode.rawValue == 1008 {
            print("⏳ [Translate] Session-duration abort — auto-renewing")
            DispatchQueue.main.async { [weak self] in self?.renewSession() }
            return
        }
        if closeCode != .goingAway && closeCode != .normalClosure {
            attemptRecovery("code \(closeCode.rawValue): \(reasonText)")
        }
    }

    /// BUILD 56: tear down the socket only, keep the microphone and playback
    /// running, and reconnect with the stored handle. The conversation carries
    /// on — at worst you lose a fraction of a second mid-gap.
    private func renewSession() {
        guard !isRenewingSession else { return }
        isRenewingSession = true
        // Recording must resume only AFTER setup completes, or the audio we send
        // in the meantime kills the new socket too.
        shouldResumeRecordingAfterSetup = isRecording
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.isRenewingSession = false
            print("🔁 [Translate] Reconnecting (handle: \(self.resumptionHandle != nil ? "yes" : "none"))")
            self.connect()
        }
    }

    /// A drop that ISN'T the session clock — a tunnel, a WiFi handover, a 5xx.
    /// Three tries on a backoff before we admit defeat to the user.
    private func attemptRecovery(_ why: String) {
        guard isUserSessionActive else { return }
        guard recoveryAttempts < 3 else {
            reportSocketError("Connection lost (\(why)). Close and reopen Translate to reconnect.")
            return
        }
        recoveryAttempts += 1
        let delay = Double(recoveryAttempts) * 1.5
        print("🔁 [Translate] Recovery \(recoveryAttempts)/3 in \(delay)s — \(why)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isUserSessionActive else { return }
            self.renewSession()
        }
    }

    /// Catches failures at the HTTP upgrade stage (didOpen never fires) —
    /// 401/403/404 from Google shows up here, visible on TestFlight at last.
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
        print("❌ [Translate] \(message)")
        reportSocketError(message)
    }
}
