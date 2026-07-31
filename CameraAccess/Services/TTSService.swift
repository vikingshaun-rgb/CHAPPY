/*
 * TTS Service
 * Text-to-speech service
 * plays via AVAudioEngine, same approach as OmniRealtimeService
 */

import AVFoundation
import Foundation

@MainActor
class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published var isSpeaking = false

    private let baseURL = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
    private let model = "qwen3-tts-flash"

    // Get the voice from the current language setting
    private var voice: String {
        return LanguageManager.staticTtsVoice
    }

    // Get language type from the current language setting
    private var languageType: String {
        return LanguageManager.staticApiLanguageCode
    }

    // same AVAudioEngine approach as OmniRealtimeService
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    // Use standard Float32 format, iOS 18-compatible+
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)
    private var isPlaybackEngineRunning = false

    private var currentTask: Task<Void, Never>?
    private var systemSynthesizer: AVSpeechSynthesizer?

    private override init() {
        super.init()
        setupPlaybackEngine()
    }

    // MARK: - Audio Engine Setup (same as OmniRealtimeService)

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

    /// Configure the audio session (call before starting the playback engine)
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()

            // Check the current session state
            print("🔊 [TTS] Current audio session: category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")

            // Configure only when needed to avoid clashing with the existing session
            // use the exact same settings as OmniRealtimeService (no defaultToSpeaker)
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            try audioSession.setPreferredSampleRate(24000)
            try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
            print("✅ [TTS] Audio session configured")
        } catch {
            print("⚠️ [TTS] Audio session Configuration failed: \(error), continuing to attempt playback...")
            // Don't throw — try playing with the existing session
        }
    }

    private func startPlaybackEngine() {
        guard let playbackEngine = playbackEngine, !isPlaybackEngineRunning else { return }

        configureAudioSession()
        do {
            try playbackEngine.start()
            playerNode?.play()
            isPlaybackEngineRunning = true
            print("✅ [TTS] Playback engine started")
        } catch {
            print("❌ [TTS] Playback engine failed to start: \(error)")
        }
    }

    private func stopPlaybackEngine() {
        playerNode?.stop()
        playerNode?.reset()
        playbackEngine?.stop()
        isPlaybackEngineRunning = false
    }

    // MARK: - API Request Models

    struct TTSRequest: Codable {
        let model: String
        let input: Input

        struct Input: Codable {
            let text: String
            let voice: String
            let language_type: String
        }
    }

    // MARK: - Public Methods

    /// Pre-configure the audio session (call before stopping the stream)
    func prepareAudioSession() {
        configureAudioSession()
        print("🔊 [TTS] Audio session pre-configured")
    }

    /// Speak text
    /// - Cloud TTS path
    /// - OpenRouter API: using system TTS
    func speak(_ text: String, apiKey: String? = nil) {
        // Cancel the previous task
        currentTask?.cancel()
        stop()

        // OpenRouter using system TTS
        if APIProviderManager.staticCurrentProvider != .alibaba {
            print("🔊 [TTS] OpenRouter mode, using system TTS")
            isSpeaking = true
            currentTask = Task {
                await fallbackToSystemTTS(text: text)
                isSpeaking = false
            }
            return
        }

        // Cloud TTS path
        let key = apiKey ?? APIKeyManager.shared.getAPIKey(for: .alibaba)

        guard let finalKey = key, !finalKey.isEmpty else {
            print("❌ [TTS] No Alibaba API key, falling back to system TTS")
            isSpeaking = true
            currentTask = Task {
                await fallbackToSystemTTS(text: text)
                isSpeaking = false
            }
            return
        }

        print("🔊 [TTS] Speaking with qwen3-tts-flash: \(text.prefix(50))...")

        isSpeaking = true

        currentTask = Task {
            do {
                try await synthesizeAndPlay(text: text, apiKey: finalKey)
            } catch {
                if !Task.isCancelled {
                    print("❌ [TTS] Error: \(error)")
                    // Fall back to system TTS on failure
                    await fallbackToSystemTTS(text: text)
                }
            }
            if !Task.isCancelled {
                isSpeaking = false
            }
        }
    }

    /// Stop speaking
    func stop() {
        currentTask?.cancel()
        currentTask = nil
        stopPlaybackEngine()
        isSpeaking = false
        print("🔊 [TTS] Stopped")
    }

    // MARK: - Private Methods

    private func synthesizeAndPlay(text: String, apiKey: String) async throws {
        guard let url = URL(string: baseURL) else {
            throw TTSError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE")
        request.timeoutInterval = 30

        let ttsRequest = TTSRequest(
            model: model,
            input: TTSRequest.Input(
                text: text,
                voice: voice,
                language_type: languageType
            )
        )

        request.httpBody = try JSONEncoder().encode(ttsRequest)

        print("📡 [TTS] Sending request to qwen3-tts-flash...")

        // Use URLSession's bytes API to handle SSE
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            print("❌ [TTS] API error: \(httpResponse.statusCode)")
            throw TTSError.apiError(statusCode: httpResponse.statusCode)
        }

        // Stop current playback and reset the playerNode queue
        playerNode?.stop()
        playerNode?.reset()

        // Ensure the playback engine is running
        if !isPlaybackEngineRunning {
            startPlaybackEngine()
        }

        // Call play() early so playerNode is ready to receive buffers
        playerNode?.play()
        print("▶️ [TTS] Playback engine and playerNode ready")

        guard isPlaybackEngineRunning else {
            print("❌ [TTS] Playback engine not running")
            throw TTSError.playbackFailed
        }

        var chunkCount = 0
        var totalBytes = 0

        for try await line in bytes.lines {
            if Task.isCancelled { return }

            // SSE format: "data: {...}"
            if line.hasPrefix("data:") {
                let jsonString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)

                if jsonString == "[DONE]" {
                    break
                }

                if let jsonData = jsonString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let output = json["output"] as? [String: Any],
                   let audio = output["audio"] as? [String: Any],
                   let audioString = audio["data"] as? String,
                   !audioString.isEmpty,
                   let audioData = Data(base64Encoded: audioString),
                   !audioData.isEmpty {
                    chunkCount += 1
                    totalBytes += audioData.count
                    if chunkCount == 1 {
                        print("🔊 [TTS] First audio chunk received: \(audioData.count) bytes")
                    }
                    // Stream-play each audio chunk
                    playAudioChunk(audioData)
                }
            }
        }

        if Task.isCancelled { return }

        print("🔊 [TTS] Received \(chunkCount) chunks, \(totalBytes) bytes total")

        // Wait for playback to finish
        await waitForPlaybackCompletion()

        print("🔊 [TTS] Finished playing")
    }

    private func playAudioChunk(_ audioData: Data) {
        // Skip empty data
        guard !audioData.isEmpty else {
            return
        }

        guard let playerNode = playerNode,
              let playbackFormat = playbackFormat else {
            print("⚠️ [TTS] playerNode or playbackFormat not initialized")
            return
        }

        guard let pcmBuffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            print("⚠️ [TTS] Failed to create PCM buffer, audioData.count=\(audioData.count)")
            return
        }

        // Ensure the playback engine is running
        if !isPlaybackEngineRunning {
            startPlaybackEngine()
        }

        // ensure playerNode is playing (consistent with OmniRealtimeService)
        if !playerNode.isPlaying {
            playerNode.play()
            print("▶️ [TTS] playerNode.play() called")
        }

        // Schedule the audio buffer for playback
        playerNode.scheduleBuffer(pcmBuffer)
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Server sends PCM16, 2 bytes per frame
        let frameCount = data.count / 2
        guard frameCount > 0 else {
            print("⚠️ [TTS] createPCMBuffer: frameCount is 0, data.count=\(data.count)")
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            print("⚠️ [TTS] createPCMBuffer: Failed to create AVAudioPCMBuffer, format=\(format), frameCount=\(frameCount)")
            return nil
        }

        guard let channelData = buffer.floatChannelData else {
            print("⚠️ [TTS] createPCMBuffer: floatChannelData is nil")
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        // Convert PCM16 to Float32 (iOS 18-compatible+) 
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            let floatData = channelData[0]
            for i in 0..<frameCount {
                // Int16 range -32768..32767, converted to -1.0 to 1.0
                floatData[i] = Float(int16Pointer[i]) / 32768.0
            }
        }

        return buffer
    }

    private func waitForPlaybackCompletion() async {
        guard let playerNode = playerNode else { return }

        // Wait for all audio to finish playing
        while playerNode.isPlaying {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        // Extra wait to ensure playback fully completes
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
    }

    /// Falling back to system TTS
    private func fallbackToSystemTTS(text: String) async {
        print("🔊 [TTS] Falling back to system TTS")

        // System TTS uses Playback mode (not PlayAndRecord)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
            try audioSession.setActive(true)
            print("✅ [TTS] System TTS audio session configured")
        } catch {
            print("⚠️ [TTS] System TTS audio session error: \(error)")
        }

        // Keep a strong reference via an instance variable so it isn't deallocated
        systemSynthesizer = AVSpeechSynthesizer()

        guard let synthesizer = systemSynthesizer else { return }

        let utterance = AVSpeechUtterance(string: text)
        // Pick the system voice from the current language setting
        let voiceLanguage = LanguageManager.staticIsChinese ? "zh-CN" : "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLanguage)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.0
        utterance.volume = 1.0
        utterance.pitchMultiplier = 1.0

        print("🔊 [TTS] System TTS speaking: \(text.prefix(30))...")
        synthesizer.speak(utterance)

        // Wait briefly for playback to begin
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Wait for playback to finish
        while synthesizer.isSpeaking {
            if Task.isCancelled {
                synthesizer.stopSpeaking(at: .immediate)
                systemSynthesizer = nil
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        print("✅ [TTS] System TTS finished")
        systemSynthesizer = nil
    }
}

// MARK: - Error Types

enum TTSError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(statusCode: Int)
    case noAudioData
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured"
        case .invalidResponse:
            return "Invalid response"
        case .apiError(let statusCode):
            return "API Error: \(statusCode)"
        case .noAudioData:
            return "No audio data received"
        case .playbackFailed:
            return "Audio playback failed"
        }
    }
}
