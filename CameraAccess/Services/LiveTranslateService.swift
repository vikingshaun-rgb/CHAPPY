/*
 * Live Translate WebSocket Service
 * Live translation service (realtime websocket)
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
    private let model = "qwen3-livetranslate-flash-realtime"
    // Get the WebSocket URL dynamically from the user's region setting
    private var baseURL: String {
        return APIProviderManager.staticLiveAIWebsocketURL
    }

    // Audio Engine (for recording)
    private var audioEngine: AVAudioEngine?

    // Audio Playback Engine (separate engine for playback)
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)

    // Audio buffer management
    private var audioBuffer = Data()
    private var isCollectingAudio = false
    private var audioChunkCount = 0
    private let minChunksBeforePlay = 2
    private var hasStartedPlaying = false
    private var isPlaybackEngineRunning = false

    // Translation settings
    private var sourceLanguage: TranslateLanguage = .en
    private var targetLanguage: TranslateLanguage = .zh
    private var voice: TranslateVoice = .cherry
    private var audioOutputEnabled = true

    // Audio resampling
    private var audioConverter: AVAudioConverter?
    private let targetSampleRate: Double = 16000  // API expects 16kHz

    // Callbacks
    var onConnected: (() -> Void)?
    var onTranslationText: ((String) -> Void)?    // Translation result text
    var onTranslationDelta: ((String) -> Void)?   // Incremental translation text
    var onAudioDelta: ((Data) -> Void)?
    var onAudioDone: (() -> Void)?
    var onError: ((String) -> Void)?

    // State
    private var isRecording = false
    private var eventIdCounter = 0

    // Image sending
    private var lastImageSendTime: Date?
    private let imageInterval: TimeInterval = 0.5  // every 0.5s max between image sends

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
        print("⏹️ [Translate] Playback engine stopped")
    }

    // MARK: - WebSocket Connection

    func connect() {
        let urlString = "\(baseURL)?model=\(model)"
        print("🔌 [Translate] Preparing WebSocket connection: \(urlString)")

        guard let url = URL(string: urlString) else {
            print("❌ [Translate] Invalid URL")
            onError?("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())

        webSocket = urlSession?.webSocketTask(with: request)
        webSocket?.resume()

        print("🔌 [Translate] WebSocket Task started")
        receiveMessage()
    }

    func disconnect() {
        print("🔌 [Translate] Disconnect the WebSocket")
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

        // If connected, reconfigure the session
        if webSocket != nil {
            configureSession()
        }
    }

    private func configureSession() {
        var modalities: [String] = ["text"]
        if audioOutputEnabled {
            modalities.append("audio")
        }

        let sessionConfig: [String: Any] = [
            "event_id": generateEventId(),
            "type": TranslateClientEvent.sessionUpdate.rawValue,
            "session": [
                "modalities": modalities,
                "voice": voice.rawValue,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm24",
                "input_audio_transcription": [
                    "language": sourceLanguage.rawValue
                ],
                "translation": [
                    "language": targetLanguage.rawValue
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500
                ]
            ]
        ]

        sendEvent(sessionConfig)
        print("📤 [Translate] Configuring session: \(sourceLanguage.rawValue) → \(targetLanguage.rawValue), Voice: \(voice.rawValue)")
    }

    // MARK: - Audio Recording

    func startRecording(usePhoneMic: Bool = false) {
        guard !isRecording else { return }

        do {
            print("🎤 [Translate] Start recording, Use\(usePhoneMic ? "iPhone" : "Bluetooth")Microphone")

            if let engine = audioEngine, engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }

            let audioSession = AVAudioSession.sharedInstance()

            if usePhoneMic {
                // Use the iPhone microphone — best for translating the other person
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker]  // Bluetooth disabled — force the iPhone microphone
                )
                print("🎙️ [Translate] Using iPhone mic (translate the other person)")
            } else {
                // Use the Bluetooth mic (glasses) — best for translating yourself
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.allowBluetooth, .defaultToSpeaker]
                )
                print("🎙️ [Translate] Using Bluetooth mic (translate yourself)")
            }
            try audioSession.setActive(true)

            // Log the current audio input device
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

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
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
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatChannelData = buffer.floatChannelData else { return }

        let inputSampleRate = buffer.format.sampleRate

        // Resample if the sample rate isn't 16 kHz
        if inputSampleRate != targetSampleRate {
            guard let resampledBuffer = resampleBuffer(buffer) else {
                return
            }
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

        // Create or update the converter
        if audioConverter == nil || audioConverter?.inputFormat != inputFormat {
            audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }

        guard let converter = audioConverter else {
            print("❌ [Translate] Failed to create the audio converter")
            return nil
        }

        // Compute output frame count
        let ratio = targetSampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        var hasProvidedInput = false
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
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

    private func sendBufferAsPCM16(_ buffer: AVAudioPCMBuffer) {
        guard let floatChannelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channel = floatChannelData.pointee

        // Float32 → PCM16
        var int16Data = [Int16](repeating: 0, count: frameLength)
        for i in 0..<frameLength {
            let sample = channel[i]
            let clampedSample = max(-1.0, min(1.0, sample))
            int16Data[i] = Int16(clampedSample * 32767.0)
        }

        let data = Data(bytes: int16Data, count: frameLength * MemoryLayout<Int16>.size)
        let base64Audio = data.base64EncodedString()

        sendAudioAppend(base64Audio)
    }

    // MARK: - Image Sending

    func sendImageFrame(_ image: UIImage) {
        // Rate-limit sends: every 0.5s max per image
        let now = Date()
        if let lastTime = lastImageSendTime, now.timeIntervalSince(lastTime) < imageInterval {
            return
        }
        lastImageSendTime = now

        guard let imageData = image.jpegData(compressionQuality: 0.6) else {
            print("❌ [Translate] Failed to compress image")
            return
        }

        // Cap image size at 500 KB
        guard imageData.count <= 500 * 1024 else {
            print("⚠️ [Translate] Image too large — skipping send")
            return
        }

        let base64Image = imageData.base64EncodedString()
        print("📸 [Translate] Sending image: \(imageData.count) bytes")

        let event: [String: Any] = [
            "event_id": generateEventId(),
            "type": TranslateClientEvent.inputImageBufferAppend.rawValue,
            "image": base64Image
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
                print("❌ [Translate] Failed to send event: \(error.localizedDescription)")
                self?.onError?("Send error: \(error.localizedDescription)")
            }
        }
    }

    private var audioSendCount = 0

    private func sendAudioAppend(_ base64Audio: String) {
        audioSendCount += 1
        if audioSendCount == 1 || audioSendCount % 50 == 0 {
            print("🎵 [Translate] Send audio chunk #\(audioSendCount), size: \(base64Audio.count) bytes")
        }

        let event: [String: Any] = [
            "event_id": generateEventId(),
            "type": TranslateClientEvent.inputAudioBufferAppend.rawValue,
            "audio": base64Audio
        ]
        sendEvent(event)
    }

    // MARK: - Receive Messages

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage()

            case .failure(let error):
                print("❌ [Translate] Failed to receive message: \(error.localizedDescription)")
                self?.onError?("Receive error: \(error.localizedDescription)")
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            print("⚠️ [Translate] Received an unparseable message: \(jsonString.prefix(200))")
            return
        }

        // Log every received event type
        print("📥 [Translate] Event received: \(type)")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            switch type {
            case TranslateServerEvent.sessionCreated.rawValue,
                 TranslateServerEvent.sessionUpdated.rawValue:
                print("✅ [Translate] Session established")
                self.onConnected?()

            case TranslateServerEvent.responseAudioTranscriptText.rawValue:
                // Incremental translation text
                if let delta = json["delta"] as? String {
                    print("💬 [Translate] Translation chunk: \(delta)")
                    self.onTranslationDelta?(delta)
                }

            case TranslateServerEvent.responseAudioTranscriptDone.rawValue:
                // Translation text complete (audio output+text mode)
                if let text = json["text"] as? String {
                    print("✅ [Translate] Translation complete: \(text)")
                    self.onTranslationText?(text)
                }

            case TranslateServerEvent.responseTextDone.rawValue:
                // Translation text complete (text-only mode)
                if let text = json["text"] as? String {
                    print("✅ [Translate] Translation complete (text): \(text)")
                    self.onTranslationText?(text)
                }

            case TranslateServerEvent.responseAudioDelta.rawValue:
                if let base64Audio = json["delta"] as? String,
                   let audioData = Data(base64Encoded: base64Audio) {
                    self.onAudioDelta?(audioData)
                    self.handleAudioChunk(audioData)
                }

            case TranslateServerEvent.responseAudioDone.rawValue:
                self.isCollectingAudio = false
                if !self.audioBuffer.isEmpty {
                    self.playAudio(self.audioBuffer)
                    self.audioBuffer = Data()
                }
                self.audioChunkCount = 0
                self.hasStartedPlaying = false
                self.onAudioDone?()

            case TranslateServerEvent.error.rawValue:
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    print("❌ [Translate] Server error: \(message)")
                    self.onError?(message)
                }

            default:
                break
            }
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
            }
        }

        audioChunkCount += 1

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

    private func playAudio(_ audioData: Data) {
        guard let playerNode = playerNode,
              let playbackFormat = playbackFormat else { return }

        if !isPlaybackEngineRunning {
            startPlaybackEngine()
            playerNode.play()
        } else if !playerNode.isPlaying {
            playerNode.play()
        }

        guard let pcmBuffer = createPCMBuffer(from: audioData, format: playbackFormat) else { return }
        playerNode.scheduleBuffer(pcmBuffer)
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = data.count / 2
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        // PCM16 → Float32
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            let floatData = channelData[0]
            for i in 0..<frameCount {
                floatData[i] = Float(int16Pointer[i]) / 32768.0
            }
        }

        return buffer
    }

    // MARK: - Helpers

    private func generateEventId() -> String {
        eventIdCounter += 1
        return "translate_\(eventIdCounter)_\(UUID().uuidString.prefix(8))"
    }
}

// MARK: - URLSessionWebSocketDelegate

extension LiveTranslateService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ [Translate] WebSocket Connection established")
        DispatchQueue.main.async {
            self.configureSession()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        print("🔌 [Translate] WebSocket Disconnected, closeCode: \(closeCode.rawValue), reason: \(reasonString)")
    }
}
