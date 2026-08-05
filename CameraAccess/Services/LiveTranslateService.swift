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
    private static let echoTailSeconds: TimeInterval = 0.6

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
        only as context to improve the translation.
        """

        var setup: [String: Any] = [
            "model": "models/\(model)",
            "systemInstruction": [
                "parts": [["text": systemPrompt]]
            ],
            "outputAudioTranscription": [:],
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
            let usePhoneMic = usePhoneMic || !bluetoothAvailable
            if !bluetoothAvailable {
                print("🎙️ [Translate] No Bluetooth mic present — configuring for the iPhone")
            }

            if usePhoneMic {
                // iPhone microphone - best for translating the other person
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .voiceChat, // AUDIT FIX: .default has NO echo cancellation — the mic heard Chappy's own translation and translated it back, forever
                    options: [.defaultToSpeaker]
                )
                print("🎙️ [Translate] Using iPhone mic (translate the other person)")
            } else {
                // Bluetooth mic (glasses) - best for translating yourself
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .voiceChat, // AUDIT FIX: .default has NO echo cancellation — the mic heard Chappy's own translation and translated it back, forever
                    options: [.allowBluetooth, .defaultToSpeaker]
                )
                print("🎙️ [Translate] Using Bluetooth mic (translate yourself)")
            }
            try audioSession.setActive(true)

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
        if Date() < micGateUntil.addingTimeInterval(Self.echoTailSeconds) { return }

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
                if nsError.code != 57 && nsError.code != -999 { self?.reportSocketError("Receive error [\(nsError.code)]: \(error.localizedDescription)") }
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
            if let goAway = json["goAway"] as? [String: Any] {
                print("⚠️ [Translate] Server goAway: \(goAway)")
                self.onError?("Connection ending (server)")
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
        if closeCode != .goingAway && closeCode != .normalClosure {
            reportSocketError("Socket closed — code \(closeCode.rawValue): \(reasonText)")
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
