/*
 * Live AI Manager
 * Manages Live AI sessions in the background — supports Siri and Shortcuts without unlocking the phone
 */

import Foundation
import SwiftUI
import AVFoundation
import CoreLocation
import CoreMotion
import MapKit

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
            // SCOOTER MODE: ~3fps drip keeps the view fresh at a glance
            if frameTickCount >= 3 {
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
        // PHASE 4 STEP 3: every fix feeds the journal (it self-throttles)
        TripRecorder.shared.record(location: loc)
        // PHASE 4 STEP 5: and the navigator (speaks turns when close)
        Task { @MainActor in NavEngine.shared.updateLocation(loc) }
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

// MARK: - Trip Recorder (Phase 4 Step 3)
// The always-on journal: GPS breadcrumbs + named spots, near-zero battery,
// fully offline (files in Documents). Fed by ContextEngine's location
// updates; queried by voice through Live AI.

final class TripRecorder {
    static let shared = TripRecorder()

    struct Crumb: Codable {
        let t: Date
        let lat: Double
        let lon: Double
        var street: String?
        var city: String?
        var motion: String?
    }

    struct Spot: Codable {
        let name: String
        let t: Date
        let lat: Double
        let lon: Double
        var street: String?
        var city: String?
        var country: String?
    }

    private(set) var crumbs: [Crumb] = []
    private(set) var spots: [Spot] = []
    private var lastCrumb: Crumb?
    private let ioQueue = DispatchQueue(label: "chappy.triprecorder", qos: .utility)

    private var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var spotsURL: URL { docs.appendingPathComponent("chappy-spots.json") }
    private func crumbsURL(for date: Date) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return docs.appendingPathComponent("chappy-crumbs-\(df.string(from: date)).json")
    }
    private func notesURL(for date: Date) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return docs.appendingPathComponent("chappy-notes-\(df.string(from: date)).json")
    }
    private(set) var notes: [String] = []

    private init() {
        if let d = try? Data(contentsOf: crumbsURL(for: Date())),
           let c = try? JSONDecoder().decode([Crumb].self, from: d) {
            crumbs = c
            lastCrumb = c.last
        }
        if let d = try? Data(contentsOf: spotsURL),
           let s = try? JSONDecoder().decode([Spot].self, from: d) {
            spots = s
        }
        if let d = try? Data(contentsOf: notesURL(for: Date())),
           let n = try? JSONDecoder().decode([String].self, from: d) {
            notes = n
        }
        print("👣 [Trip] Loaded \(crumbs.count) crumbs, \(spots.count) spots, \(notes.count) notes")
    }

    /// Called by ContextEngine on every location fix; keeps only meaningful movement.
    func record(location: CLLocation) {
        let snap = ContextEngine.shared.snapshot
        let new = Crumb(t: Date(),
                        lat: location.coordinate.latitude,
                        lon: location.coordinate.longitude,
                        street: snap.street, city: snap.city, motion: snap.motion)
        if let last = lastCrumb {
            let dist = TripRecorder.meters(last.lat, last.lon, new.lat, new.lon)
            let dt = new.t.timeIntervalSince(last.t)
            guard dist > 25 || dt > 120 else { return }
        }
        lastCrumb = new
        crumbs.append(new)
        saveCrumbs()
    }

    @discardableResult
    func rememberSpot(named rawName: String) -> Spot {
        let snap = ContextEngine.shared.snapshot
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            let df = DateFormatter()
            df.dateFormat = "h:mma"
            name = "spot at \(df.string(from: Date()))"
            if let s = snap.street { name += " near \(s)" }
        }
        let spot = Spot(name: name, t: Date(),
                        lat: snap.latitude ?? lastCrumb?.lat ?? 0,
                        lon: snap.longitude ?? lastCrumb?.lon ?? 0,
                        street: snap.street, city: snap.city, country: snap.country)
        spots.append(spot)
        saveSpots()
        print("📍 [Trip] Remembered spot: \(name)")
        return spot
    }

    /// Streets/areas passed through today, in order, plus remembered spots.
    func todaySummary() -> String {
        var route: [String] = []
        for c in crumbs {
            if let s = c.street ?? c.city, route.last != s, !route.contains(s) {
                route.append(s)
            }
        }
        var out = ""
        if route.isEmpty {
            out = "The journal has no located places yet today."
        } else {
            out = "Today the user has passed through: \(route.joined(separator: ", "))."
        }
        let todaySpots = spots.filter { Calendar.current.isDateInToday($0.t) }
        if !todaySpots.isEmpty {
            out += " Remembered spots today: \(todaySpots.map { $0.name }.joined(separator: ", "))."
        }
        if !notes.isEmpty {
            out += " Observations noted: \(notes.suffix(3).joined(separator: "; "))."
        }
        return out
    }

    /// Spoken situation report for "I'm lost".
    func lostReport() -> String {
        guard let here = lastCrumb ?? crumbs.last else {
            return "There is no location fix yet - ask the user to wait a moment while GPS settles."
        }
        var out = "The user is"
        if let s = here.street { out += " on \(s)" }
        if let c = here.city { out += ", \(c)" }
        if here.street == nil && here.city == nil { out += " at an unnamed location" }
        out += "."
        if let nearest = spots.min(by: {
            TripRecorder.meters($0.lat, $0.lon, here.lat, here.lon) < TripRecorder.meters($1.lat, $1.lon, here.lat, here.lon)
        }) {
            let d = TripRecorder.meters(nearest.lat, nearest.lon, here.lat, here.lon)
            let dir = TripRecorder.compass(from: (here.lat, here.lon), to: (nearest.lat, nearest.lon))
            out += " The nearest remembered spot is '\(nearest.name)', about \(Int(d.rounded())) meters to the \(dir)."
        }
        out += " There are \(crumbs.count) breadcrumbs recorded today, so the route back exists."
        return out
    }

    /// STEP 8: ambient noticing — Chappy's own observations, journaled.
    func addObservation(_ text: String) {
        guard !text.isEmpty else { return }
        let df = DateFormatter()
        df.dateFormat = "h:mma"
        var line = "\(df.string(from: Date())): \(text)"
        let snap = ContextEngine.shared.snapshot
        if let s = snap.street { line += " (near \(s))" }
        notes.append(line)
        let snapshot = notes
        let url = notesURL(for: Date())
        ioQueue.async {
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url) }
        }
        print("📝 [Trip] Observation: \(text)")
    }

    /// Spoken guidance for "trace my steps back" — the day's route in reverse.
    func retraceGuidance() -> String {
        guard crumbs.count > 1 else {
            return "There are not enough breadcrumbs yet to retrace - the trail starts recording as the user moves."
        }
        var route: [String] = []
        for c in crumbs.reversed() {
            if let s = c.street ?? c.city, route.last != s, !route.contains(s) {
                route.append(s)
            }
        }
        let total = zip(crumbs, crumbs.dropFirst()).reduce(0.0) {
            $0 + TripRecorder.meters($1.0.lat, $1.0.lon, $1.1.lat, $1.1.lon)
        }
        var out = "To retrace the route back"
        if route.count > 1 {
            out += ", head back along " + route.prefix(6).joined(separator: ", then ")
        }
        out += ". The full trail today is about \(Int((total / 100).rounded()) * 100) meters."
        out += " Guide the user street by street if they ask."
        return out
    }

    private func saveCrumbs() {
        let snapshot = crumbs
        let url = crumbsURL(for: Date())
        ioQueue.async {
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url) }
        }
    }

    private func saveSpots() {
        let snapshot = spots
        let url = spotsURL
        ioQueue.async {
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url) }
        }
    }

    static func meters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        CLLocation(latitude: lat1, longitude: lon1).distance(from: CLLocation(latitude: lat2, longitude: lon2))
    }

    static func compass(from a: (Double, Double), to b: (Double, Double)) -> String {
        let dLon = (b.1 - a.1) * .pi / 180
        let lat1 = a.0 * .pi / 180, lat2 = b.0 * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        let dirs = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest", "north"]
        return dirs[Int((deg + 22.5) / 45)]
    }
}

// MARK: - Nav Engine (Phase 4 Step 5)
// Voice-first turn-by-turn: Google Routes PRIMARY (best SE Asia data,
// chappy-maps key) with MapKit fallback, Google Places destination search,
// spoken geofenced turns via TTSService, off-route auto-reroute.

@MainActor
final class NavEngine: NSObject, ObservableObject {
    static let shared = NavEngine()

    struct NavStep {
        let instruction: String
        let coord: CLLocationCoordinate2D
        let distanceMeters: Double
    }

    @Published var isNavigating = false
    @Published var destinationName = ""
    @Published var nextInstruction = ""
    @Published var distanceText = ""
    @Published var routeCoords: [CLLocationCoordinate2D] = []
    @Published var destinationCoord: CLLocationCoordinate2D?

    private var steps: [NavStep] = []
    private var stepIndex = 0
    private var lastReroute = Date.distantPast
    // STEP 8: "tell me when I'm near X" watch target
    private var watchTarget: (name: String, coord: CLLocationCoordinate2D)?

    /// STEP 8 FUSION: nav speaks through the live Chappy session when one
    /// is running (camera-aware turns); falls back to plain TTS otherwise.
    private func speakNav(_ text: String) {
        if let live = GeminiLiveService.activeInstance {
            live.announceNavStep(text)
        } else {
            TTSService.shared.speak(text)
        }
    }

    /// STEP 8: set a proximity watch — "tell me when I'm near my stop"
    func alertWhenNear(_ place: String) async -> String {
        let snap = ContextEngine.shared.snapshot
        guard let lat = snap.latitude, let lon = snap.longitude else { return "No GPS fix yet." }
        if let found = await placesSearch(query: place, lat: lat, lon: lon) {
            watchTarget = (found.1, found.0)
            return "Watch set - the user will be alerted when they are near \(found.1)."
        }
        return "Could not find \(place) nearby to watch for."
    }

    /// Resolve a spoken destination and start guiding. Returns a summary for Chappy to speak.
    func navigate(to query: String) async -> String {
        let snap = ContextEngine.shared.snapshot
        guard let lat = snap.latitude, let lon = snap.longitude else {
            return "No GPS fix yet - ask the user to try again in a few seconds."
        }
        var destName = query
        var dest: CLLocationCoordinate2D?
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let spot = TripRecorder.shared.spots.last(where: { q.contains($0.name.lowercased()) || $0.name.lowercased().contains(q) }) {
            dest = CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lon)
            destName = spot.name
        }
        if dest == nil, let found = await placesSearch(query: query, lat: lat, lon: lon) {
            dest = found.0
            destName = found.1
        }
        guard let destination = dest else {
            return "Could not find '\(query)' nearby. Ask the user to try a different name."
        }
        var routed = await googleRoute(fromLat: lat, fromLon: lon, to: destination)
        if routed == nil { routed = await mapKitRoute(fromLat: lat, fromLon: lon, to: destination) }
        guard let route = routed, !route.steps.isEmpty else {
            return "Could not find a walking route to \(destName)."
        }
        steps = route.steps
        routeCoords = route.coords
        destinationCoord = destination
        destinationName = destName
        stepIndex = 0
        isNavigating = true
        updateCard()
        let mins = max(1, Int(route.durationSec / 60))
        return "Route to \(destName) found: about \(Int(route.distanceMeters)) meters, roughly \(mins) minutes walking. First step: \(steps[0].instruction)."
    }

    func getHome() async -> String {
        if let home = TripRecorder.shared.spots.last(where: { ["home", "hotel", "my hotel", "the hotel"].contains($0.name.lowercased()) }) {
            return await navigate(to: home.name)
        }
        return "No spot named home or hotel is saved yet. Tell the user: stand at your hotel and say remember this spot, call it home."
    }

    func stop(announce: Bool = false) {
        isNavigating = false
        steps = []
        routeCoords = []
        nextInstruction = ""
        distanceText = ""
        destinationCoord = nil
        if announce { TTSService.shared.speak("Navigation stopped.") }
    }

    /// Fed by ContextEngine on every fix: speaks turns, detects off-route.
    func updateLocation(_ loc: CLLocation) {
        // STEP 8: proximity watch fires even when not navigating
        if let w = watchTarget {
            let dw = loc.distance(from: CLLocation(latitude: w.coord.latitude, longitude: w.coord.longitude))
            if dw < 150 {
                watchTarget = nil
                speakNav("Heads up - you are about \(Int(dw)) meters from \(w.name).")
            }
        }
        guard isNavigating, stepIndex < steps.count else { return }
        let step = steps[stepIndex]
        let d = loc.distance(from: CLLocation(latitude: step.coord.latitude, longitude: step.coord.longitude))
        distanceText = d > 950 ? String(format: "%.1f km", d / 1000) : "\(Int(d)) m"
        if d < 25 {
            stepIndex += 1
            if stepIndex >= steps.count {
                speakNav("You have arrived at \(destinationName).")
                stop()
                return
            }
            speakNav(steps[stepIndex].instruction)
            updateCard()
        } else if Date().timeIntervalSince(lastReroute) > 30, !routeCoords.isEmpty {
            let nearest = routeCoords.map { loc.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }.min() ?? 0
            if nearest > 60 {
                lastReroute = Date()
                speakNav("You are off the route. Recalculating.")
                let name = destinationName
                Task { _ = await self.navigate(to: name) }
            }
        }
    }

    private func updateCard() {
        guard stepIndex < steps.count else { return }
        nextInstruction = steps[stepIndex].instruction
    }

    private struct Routed {
        let steps: [NavStep]
        let coords: [CLLocationCoordinate2D]
        let distanceMeters: Double
        let durationSec: Double
    }

    private func googleRoute(fromLat: Double, fromLon: Double, to: CLLocationCoordinate2D) async -> Routed? {
        let key = APIKeyManager.shared.getMapsAPIKey() ?? ""
        guard !key.isEmpty, let url = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue("routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.legs.steps.navigationInstruction,routes.legs.steps.endLocation,routes.legs.steps.distanceMeters", forHTTPHeaderField: "X-Goog-FieldMask")
        let body: [String: Any] = [
            "origin": ["location": ["latLng": ["latitude": fromLat, "longitude": fromLon]]],
            "destination": ["location": ["latLng": ["latitude": to.latitude, "longitude": to.longitude]]],
            "travelMode": "WALK"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = json["routes"] as? [[String: Any]], let r = routes.first else {
            print("🗺️ [Nav] Google route failed (\((resp as? HTTPURLResponse)?.statusCode ?? -1)) — MapKit fallback")
            return nil
        }
        var navSteps: [NavStep] = []
        for leg in (r["legs"] as? [[String: Any]] ?? []) {
            for s in (leg["steps"] as? [[String: Any]] ?? []) {
                let instr = ((s["navigationInstruction"] as? [String: Any])?["instructions"] as? String) ?? "Continue"
                let end = ((s["endLocation"] as? [String: Any])?["latLng"] as? [String: Any])
                let c = CLLocationCoordinate2D(latitude: end?["latitude"] as? Double ?? 0,
                                               longitude: end?["longitude"] as? Double ?? 0)
                let dm = (s["distanceMeters"] as? Double) ?? Double(s["distanceMeters"] as? Int ?? 0)
                navSteps.append(NavStep(instruction: instr, coord: c, distanceMeters: dm))
            }
        }
        let dist = (r["distanceMeters"] as? Double) ?? Double(r["distanceMeters"] as? Int ?? 0)
        var dur = 0.0
        if let ds = r["duration"] as? String { dur = Double(ds.replacingOccurrences(of: "s", with: "")) ?? 0 }
        let poly = ((r["polyline"] as? [String: Any])?["encodedPolyline"] as? String).map(NavEngine.decodePolyline) ?? []
        print("🗺️ [Nav] Google route OK: \(navSteps.count) steps, \(Int(dist))m")
        return Routed(steps: navSteps, coords: poly, distanceMeters: dist, durationSec: dur)
    }

    private func mapKitRoute(fromLat: Double, fromLon: Double, to: CLLocationCoordinate2D) async -> Routed? {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: fromLat, longitude: fromLon)))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        req.transportType = .walking
        guard let resp = try? await MKDirections(request: req).calculate(), let route = resp.routes.first else { return nil }
        var navSteps: [NavStep] = []
        for s in route.steps where !s.instructions.isEmpty {
            let pc = s.polyline.pointCount
            var cs = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pc)
            s.polyline.getCoordinates(&cs, range: NSRange(location: 0, length: pc))
            navSteps.append(NavStep(instruction: s.instructions, coord: cs.last ?? to, distanceMeters: s.distance))
        }
        let pc = route.polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pc)
        route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pc))
        print("🗺️ [Nav] MapKit route OK: \(navSteps.count) steps")
        return Routed(steps: navSteps, coords: coords, distanceMeters: route.distance, durationSec: route.expectedTravelTime)
    }

    private func placesSearch(query: String, lat: Double, lon: Double) async -> (CLLocationCoordinate2D, String)? {
        let key = APIKeyManager.shared.getMapsAPIKey() ?? ""
        guard !key.isEmpty, let url = URL(string: "https://places.googleapis.com/v1/places:searchText") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue("places.displayName,places.location", forHTTPHeaderField: "X-Goog-FieldMask")
        let body: [String: Any] = [
            "textQuery": query,
            "locationBias": ["circle": ["center": ["latitude": lat, "longitude": lon], "radius": 15000.0]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let places = json["places"] as? [[String: Any]], let p = places.first,
              let locd = p["location"] as? [String: Any],
              let la = locd["latitude"] as? Double, let lo = locd["longitude"] as? Double else { return nil }
        let name = ((p["displayName"] as? [String: Any])?["text"] as? String) ?? query
        print("🗺️ [Nav] Places found: \(name)")
        return (CLLocationCoordinate2D(latitude: la, longitude: lo), name)
    }

    nonisolated static func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0, lon = 0
        while index < encoded.endIndex {
            for pair in 0..<2 {
                var result = 0, shift = 0, b = 0
                repeat {
                    guard index < encoded.endIndex else { return coords }
                    b = Int(encoded[index].asciiValue ?? 63) - 63
                    index = encoded.index(after: index)
                    result |= (b & 0x1F) << shift
                    shift += 5
                } while b >= 0x20
                let delta = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                if pair == 0 { lat += delta } else { lon += delta }
            }
            coords.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
        }
        return coords
    }
}
