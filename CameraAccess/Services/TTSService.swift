/*
 * Text-to-Speech Service
 * Default voice: Gemini TTS (natural, expressive) using the Gemini API key.
 * Fallback: Apple system TTS (free, offline) when no key / no network / error.
 */

import Foundation
import AVFoundation

class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published var isSpeaking = false

    // Gemini TTS models — primary, with fallback name if Google renames tiers
    private let ttsModels = ["gemini-2.5-flash-tts", "gemini-2.5-flash-preview-tts"]

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

    private var currentTask: Task<Void, Never>?

    override private init() {
        super.init()
        setupPlaybackEngine()
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
            // Playback mode keeps glasses/Bluetooth output working for spoken replies
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            print("⚠️ [TTS] Audio session configuration failed: \(error.localizedDescription) — continuing")
        }
    }

    private func startPlaybackEngine() {
        guard let playbackEngine = playbackEngine, !isPlaybackEngineRunning else { return }
        do {
            try playbackEngine.start()
            isPlaybackEngineRunning = true
        } catch {
            print("❌ [TTS] Playback engine failed to start: \(error)")
        }
    }

    private func stopPlaybackEngine() {
        playerNode?.stop()
        playerNode?.reset()
        if isPlaybackEngineRunning {
            playbackEngine?.stop()
            isPlaybackEngineRunning = false
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
    func speak(_ text: String, apiKey: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any previous speech
        currentTask?.cancel()
        stop()

        isSpeaking = true
        currentTask = Task { [weak self] in
            guard let self else { return }

            let googleKey = APIKeyManager.shared.getGoogleAPIKey() ?? ""
            let wantsSystemVoice = (UserDefaults.standard.string(forKey: "chappy_tts_voice") ?? "Kore") == "System"

            if !googleKey.isEmpty && !wantsSystemVoice {
                do {
                    try await self.speakWithGemini(text: trimmed, apiKey: googleKey)
                    if !Task.isCancelled { await MainActor.run { self.isSpeaking = false } }
                    return
                } catch {
                    if Task.isCancelled { return }
                    print("⚠️ [TTS] Gemini TTS failed (\(error.localizedDescription)) — falling back to system TTS")
                }
            } else {
                print("🔊 [TTS] No Gemini key — using system TTS")
            }

            await self.fallbackToSystemTTS(text: trimmed)
            if !Task.isCancelled { await MainActor.run { self.isSpeaking = false } }
        }
    }

    /// Stop speaking
    func stop() {
        currentTask?.cancel()
        currentTask = nil
        stopPlaybackEngine()
        systemSynthesizer?.stopSpeaking(at: .immediate)
        systemTTSContinuation?.resume()
        systemTTSContinuation = nil
        isSpeaking = false
    }

    // MARK: - Gemini TTS

    private func speakWithGemini(text: String, apiKey: String) async throws {
        var lastError: Error = TTSError.unknown

        for model in ttsModels {
            do {
                let audio = try await requestGeminiAudio(text: text, model: model, apiKey: apiKey)
                try Task.checkCancellation()
                print("🔊 [TTS] Gemini voice (\(voiceName)) speaking: \(text.prefix(50))…")
                await playPCM(audio)
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
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
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
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

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

    /// Play raw PCM16 @ 24 kHz and wait for playback to finish
    private func playPCM(_ audioData: Data) async {
        configureAudioSession()
        startPlaybackEngine()
        guard isPlaybackEngineRunning,
              let playbackFormat = playbackFormat,
              let buffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            print("❌ [TTS] Could not prepare audio for playback")
            return
        }

        playerNode?.play()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            playerNode?.scheduleBuffer(buffer) {
                cont.resume()
            }
        }
        // small tail so the last samples aren't clipped
        try? await Task.sleep(nanoseconds: 150_000_000)
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

    private func fallbackToSystemTTS(text: String) async {
        configureAudioSession()

        let synthesizer = AVSpeechSynthesizer()
        systemSynthesizer = synthesizer
        synthesizer.delegate = self

        let utterance = AVSpeechUtterance(string: text)
        let language = await MainActor.run { LanguageManager.shared.currentLanguage == .chinese ? "zh-CN" : "en-AU" }
        utterance.voice = AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        print("🔊 [TTS] System TTS speaking: \(text.prefix(30))…")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            systemTTSContinuation = cont
            synthesizer.speak(utterance)
        }
        systemTTSContinuation = nil
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        systemTTSContinuation?.resume()
        systemTTSContinuation = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        systemTTSContinuation?.resume()
        systemTTSContinuation = nil
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
