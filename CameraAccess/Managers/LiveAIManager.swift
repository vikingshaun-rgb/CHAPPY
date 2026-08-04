/*
 * Live AI Manager
 * Manages Live AI sessions in the background — supports Siri and Shortcuts without unlocking the phone
 */

import Foundation
import SwiftUI
import AVFoundation
import CoreLocation
import CoreMotion

// MARK: - Live AI Manager

@MainActor
class LiveAIManager: ObservableObject {
    static let shared = LiveAIManager()

    @Published var isRunning = false
    @Published var isConnected = false
    @Published var errorMessage: String?

    // Dependencies
    private(set) var streamViewModel: StreamSessionViewModel?
    private var omniService: OmniRealtimeService?
    private var geminiService: GeminiLiveService?
    private var provider: LiveAIProvider = .alibaba

    // Video frames
    private var currentVideoFrame: UIImage?
    private var isImageSendingEnabled = false
    private var frameUpdateTimer: Timer?
    // Counts 0.1s ticks; every 10th tick (~1 s) the frame is SENT to Gemini.
    // The old speech-triggered send relied on onSpeechStarted, which the
    // Gemini service never fires — Gemini was receiving zero images.
    private var frameTickCount = 0

    // Conversation history
    private var conversationHistory: [ConversationMessage] = []

    // TTS
    private let tts = TTSService.shared

    private init() {
        // Listen for Intent triggers
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLiveAITrigger(_:)),
            name: .liveAITriggered,
            object: nil
        )
    }

    /// Set the StreamSessionViewModel reference
    func setStreamViewModel(_ viewModel: StreamSessionViewModel) {
        self.streamViewModel = viewModel
    }

    @objc private func handleLiveAITrigger(_ notification: Notification) {
        Task { @MainActor in
            await startLiveAISession()
        }
    }

    // MARK: - Start Session

    /// Start a Live AI session (background mode)
    func startLiveAISession() async {
        guard !isRunning else {
            print("⚠️ [LiveAIManager] Already running")
            return
        }

        guard let streamViewModel = streamViewModel else {
            print("❌ [LiveAIManager] StreamViewModel not set")
            tts.speak("Live AI not initialized — open the app first")
            return
        }

        // Get the API key
        let apiKey = APIProviderManager.staticLiveAIAPIKey
        guard !apiKey.isEmpty else {
            errorMessage = "Please configure an API key in Settings first"
            tts.speak("Please configure an API key in Settings first")
            return
        }

        isRunning = true
        errorMessage = nil
        conversationHistory = []

        // Get the current provider
        provider = APIProviderManager.staticLiveAIProvider

        print("🚀 [LiveAIManager] Starting Live AI session...")

        do {
            // 1. Check whether a device is connected
            if !streamViewModel.hasActiveDevice {
                print("❌ [LiveAIManager] No active device connected")
                throw LiveAIError.noDevice
            }

            // 2. Start the video stream (if not already running)
            if streamViewModel.streamingStatus != .streaming {
                print("📹 [LiveAIManager] Starting stream...")
                await streamViewModel.handleStartStreaming()

                // Wait for the stream to reach streaming state (max 5 s)
                let streamReady = await waitForCondition(timeout: 5.0) {
                    streamViewModel.streamingStatus == .streaming
                }

                if !streamReady {
                    print("❌ [LiveAIManager] Failed to start streaming")
                    throw LiveAIError.streamNotReady
                }
            }

            // 3. Pre-configure audio session (needed for background mode)
            try configureAudioSessionForBackground()

            // 4. Initialize the AI service
            initializeService(apiKey: apiKey)

            // 4. Connect to the AI service
            print("🔌 [LiveAIManager] Connecting to AI service...")
            connectService()

            // Wait for connection (max 10 s)
            let connected = await waitForCondition(timeout: 10.0) {
                self.isConnected
            }

            if !connected {
                print("❌ [LiveAIManager] Failed to connect to AI service")
                throw LiveAIError.connectionFailed
            }

            // 5. Start the video-frame update timer
            startFrameUpdateTimer()
            print("✅ [LiveAIManager] Frame update timer started")

            // 6. Start recording directly (no TTS, avoids audio session conflicts)
            print("🎤 [LiveAIManager] About to start recording...")
            startRecording()

            print("✅ [LiveAIManager] Live AI session started, ready to talk")

        } catch let error as LiveAIError {
            errorMessage = error.localizedDescription
            print("❌ [LiveAIManager] LiveAIError: \(error)")
            await stopSession()
        } catch {
            errorMessage = error.localizedDescription
            print("❌ [LiveAIManager] Error: \(error)")
            await stopSession()
        }
    }

    // MARK: - Audio Session Configuration

    /// Pre-configure the audio session (background mode requires it before the audio engine init)
    private func configureAudioSessionForBackground() throws {
        let audioSession = AVAudioSession.sharedInstance()

        // Deactivate then reactivate for a clean state
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            print("✅ [LiveAIManager] Audio session deactivated")
        } catch {
            print("⚠️ [LiveAIManager] Failed to deactivate audio session: \(error)")
        }

        // Configure the audio session
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
        try audioSession.setActive(true)
        print("✅ [LiveAIManager] Background audio session configured: category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")
    }

    // MARK: - Initialize Service

    private func initializeService(apiKey: String) {
        switch provider {
        case .alibaba:
            omniService = OmniRealtimeService(apiKey: apiKey)
            setupOmniCallbacks()
        case .google:
            geminiService = GeminiLiveService(apiKey: apiKey)
            setupGeminiCallbacks()
        }
    }

    private func setupOmniCallbacks() {
        guard let omniService = omniService else { return }

        omniService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
                print("✅ [LiveAIManager] Omni connected")
            }
        }

        omniService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                print("✅ [LiveAIManager] First-audio-sent callback received — enabling image sending")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.isImageSendingEnabled = true
                }
            }
        }

        omniService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                if let strongSelf = self,
                   strongSelf.isImageSendingEnabled,
                   let frame = strongSelf.currentVideoFrame {
                    print("🎤📸 [LiveAIManager] User speech detected — sending current video frame")
                    strongSelf.omniService?.sendImageAppend(frame)
                }
            }
        }

        omniService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self = self else { return }
                print("💬 [LiveAIManager] User: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        omniService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                guard let self = self, !fullText.isEmpty else { return }
                print("💬 [LiveAIManager] AI: \(fullText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: fullText)
                )
            }
        }

        omniService.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                print("❌ [LiveAIManager] Omni error: \(error)")
            }
        }
    }

    private func setupGeminiCallbacks() {
        guard let geminiService = geminiService else { return }

        geminiService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
                print("✅ [LiveAIManager] Gemini connected")
            }
        }

        geminiService.onReadRequest = { [weak self] in
            Task { @MainActor in
                guard let self, let frame = self.currentVideoFrame else { return }
                print("📖 [LiveAIManager] Read request — sending high-res frame")
                self.geminiService?.sendHighResImageInput(frame)
            }
        }

        geminiService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                print("✅ [LiveAIManager] First-audio-sent callback received — enabling image sending")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.isImageSendingEnabled = true
                }
            }
        }

        geminiService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                if let strongSelf = self,
                   strongSelf.isImageSendingEnabled,
                   let frame = strongSelf.currentVideoFrame {
                    print("🎤📸 [LiveAIManager] User speech detected — sending current video frame")
                    strongSelf.geminiService?.sendImageInput(frame)
                }
            }
        }

        geminiService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self = self else { return }
                print("💬 [LiveAIManager] User: \(userText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        geminiService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                guard let self = self, !fullText.isEmpty else { return }
                print("💬 [LiveAIManager] AI: \(fullText)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: fullText)
                )
            }
        }

        geminiService.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                print("❌ [LiveAIManager] Gemini error: \(error)")
            }
        }
    }

    // MARK: - Connection

    private func connectService() {
        switch provider {
        case .alibaba:
            omniService?.connect()
        case .google:
            geminiService?.connect()
        }
    }

    private func startRecording() {
        print("🎤 [LiveAIManager] Start recording")
        switch provider {
        case .alibaba:
            omniService?.startRecording()
        case .google:
            geminiService?.startRecording()
        }
    }

    private func stopRecording() {
        print("🛑 [LiveAIManager] Stop recording")
        switch provider {
        case .alibaba:
            omniService?.stopRecording()
        case .google:
            geminiService?.stopRecording()
        }
    }

    // MARK: - Frame Update

    private func startFrameUpdateTimer() {
        frameUpdateTimer?.invalidate()
        frameUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateVideoFrame()
            }
        }
    }

    private func updateVideoFrame() {
        if let frame = streamViewModel?.currentVideoFrame {
            currentVideoFrame = frame

            // Steady 1 fps frame drip to Gemini so it can actually SEE
            frameTickCount += 1
            if frameTickCount >= 5 {
                frameTickCount = 0
                if provider == .google, isConnected {
                    geminiService?.sendImageInput(frame)
                }
            }
        }
    }

    // MARK: - Stop Session

    /// Stop the Live AI session
    func stopSession() async {
        guard isRunning else { return }

        print("🛑 [LiveAIManager] Stopping session...")

        // Stop the timer
        frameUpdateTimer?.invalidate()
        frameUpdateTimer = nil

        // Stop recording
        stopRecording()

        // Save the conversation
        saveConversation()

        // Disconnect
        switch provider {
        case .alibaba:
            omniService?.disconnect()
        case .google:
            geminiService?.disconnect()
        }

        // Stop the video stream
        await streamViewModel?.stopSession()

        // Reset state
        omniService = nil
        geminiService = nil
        isConnected = false
        isRunning = false
        isImageSendingEnabled = false
        currentVideoFrame = nil

        print("✅ [LiveAIManager] Session stopped")
    }

    /// Save the conversation to history
    private func saveConversation() {
        guard !conversationHistory.isEmpty else {
            print("💬 [LiveAIManager] No conversation content — skipping save")
            return
        }

        let aiModel: String
        switch provider {
        case .alibaba:
            aiModel = "qwen3-omni-flash-realtime"
        case .google:
            aiModel = "gemini-3.1-flash-live-preview"
        }

        let record = ConversationRecord(
            messages: conversationHistory,
            aiModel: aiModel,
            language: "en-US"
        )

        ConversationStorage.shared.saveConversation(record)
        print("💾 [LiveAIManager] Conversation saved: \(conversationHistory.count)  messages")
    }

    /// Wait for the condition or time out
    private func waitForCondition(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return false }
        }
        return true
    }

    /// Manual stop trigger (called from UI)
    func triggerStop() {
        Task { @MainActor in
            await stopSession()
        }
    }
}

// MARK: - Live AI Error

enum LiveAIError: LocalizedError {
    case noDevice
    case streamNotReady
    case connectionFailed
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "Glasses not connected — pair them in the Meta AI app first"
        case .streamNotReady:
            return "Video stream failed to start — check the glasses connection"
        case .connectionFailed:
            return "AI AI service connection failed — check your network"
        case .noAPIKey:
            return "Please configure an API key in Settings first"
        }
    }
}


// MARK: - Context Engine (Phase 4 Step 1)
// Chappy's ambient awareness: WHERE the user is (street/city/country),
// WHEN it is, the weather, and how they're moving. One snapshot, available
// to every feature. Embedded here deliberately — no new .swift file means
// no Xcode project registration risk. Weather via Open-Meteo (free, no
// key, no WeatherKit entitlement needed).

final class ContextEngine: NSObject, CLLocationManagerDelegate {
    static let shared = ContextEngine()

    struct Snapshot {
        var timestamp = Date()
        var latitude: Double?
        var longitude: Double?
        var street: String?
        var suburb: String?
        var city: String?
        var country: String?
        var countryCode: String?
        var weather: String?
        var temperatureC: Double?
        var motion: String?
    }

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let motionManager = CMMotionActivityManager()
    private var started = false
    private(set) var snapshot = Snapshot()
    private var lastGeocode = Date.distantPast
    private var lastWeatherFetch = Date.distantPast

    func start() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.start() }
            return
        }
        guard !started else { return }
        started = true
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        if CMMotionActivityManager.isActivityAvailable() {
            motionManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let a = activity else { return }
                if a.walking { self?.snapshot.motion = "walking" }
                else if a.running { self?.snapshot.motion = "running" }
                else if a.cycling { self?.snapshot.motion = "cycling" }
                else if a.automotive { self?.snapshot.motion = "in a vehicle" }
                else if a.stationary { self?.snapshot.motion = "still" }
            }
        }
        print("🧭 [Context] Engine started")
    }

    /// One sentence for AI prompts — the context header every brain receives.
    func contextHeader() -> String {
        start()
        var bits: [String] = []
        let df = DateFormatter()
        df.dateFormat = "EEEE h:mma"
        bits.append("It is \(df.string(from: Date())) local time")
        var place: [String] = []
        if let s = snapshot.street { place.append(s) }
        if let s = snapshot.suburb, s != snapshot.city { place.append(s) }
        if let c = snapshot.city { place.append(c) }
        if let c = snapshot.country { place.append(c) }
        if !place.isEmpty { bits.append("the user is at " + place.joined(separator: ", ")) }
        if let w = snapshot.weather, let t = snapshot.temperatureC {
            bits.append("weather \(w), \(Int(t.rounded())) degrees C")
        }
        if let m = snapshot.motion { bits.append("the user is \(m)") }
        return bits.joined(separator: "; ") + "."
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        print("🧭 [Context] Location authorization: \(status.rawValue)")
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        snapshot.latitude = loc.coordinate.latitude
        snapshot.longitude = loc.coordinate.longitude
        snapshot.timestamp = Date()
        if Date().timeIntervalSince(lastGeocode) > 120 {
            lastGeocode = Date()
            reverseGeocode(loc)
        }
        if Date().timeIntervalSince(lastWeatherFetch) > 900 {
            lastWeatherFetch = Date()
            fetchWeather(loc)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("🧭 [Context] Location error: \(error.localizedDescription)")
    }

    private func reverseGeocode(_ loc: CLLocation) {
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            guard let p = placemarks?.first else { return }
            DispatchQueue.main.async {
                self?.snapshot.street = p.thoroughfare
                self?.snapshot.suburb = p.subLocality
                self?.snapshot.city = p.locality
                self?.snapshot.country = p.country
                self?.snapshot.countryCode = p.isoCountryCode
                print("🧭 [Context] Located: \(p.locality ?? "?"), \(p.country ?? "?")")
            }
        }
    }

    private func fetchWeather(_ loc: CLLocation) {
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(loc.coordinate.latitude)&longitude=\(loc.coordinate.longitude)&current=temperature_2m,weather_code") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any] else { return }
            DispatchQueue.main.async {
                if let t = current["temperature_2m"] as? Double { self?.snapshot.temperatureC = t }
                if let code = current["weather_code"] as? Int { self?.snapshot.weather = ContextEngine.weatherDescription(code) }
            }
        }.resume()
    }

    private static func weatherDescription(_ code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1, 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51...57: return "drizzle"
        case 61...67: return "rain"
        case 71...77: return "snow"
        case 80...82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95...99: return "thunderstorm"
        default: return "unsettled"
        }
    }
}
