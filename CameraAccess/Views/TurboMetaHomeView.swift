/*
 * TurboMeta Home View
 * Home — feature entry points
 * Also hosts ContinuousVisionManager: the hands-free Quick Vision loop
 * (kept in this file so no Xcode project changes are needed).
 */

import SwiftUI
import AVFoundation
import Speech
import MapKit

struct TurboMetaHomeView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var wearablesViewModel: WearablesViewModel
    @StateObject private var quickVisionManager = QuickVisionManager.shared
    @StateObject private var liveAIManager = LiveAIManager.shared
    @StateObject private var continuousVision = ContinuousVisionManager.shared
    @StateObject private var navEngine = NavEngine.shared
    @State private var showNavMap = false
    let apiKey: String

    @State private var showLiveAI = false
    @State private var showLiveStream = false
    @State private var showRTMPStreaming = false
    @State private var showLeanEat = false
    @State private var showQuickVision = false
    @State private var showLiveTranslate = false
    @State private var showOpenClaw = false
    @ObservedObject private var openClawService = OpenClawNodeService.shared

    var body: some View {
        NavigationView {
            ZStack {
                // THE FACE (Phase 4.9): dark-first, one accent, big targets.
                // Re-skin only — every action fires the exact same wiring
                // as the old grid (no-breakage law).
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.08, blue: 0.11),
                             Color(red: 0.02, green: 0.03, blue: 0.05)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        // ORB HEADER — glows when Chappy is live
                        VStack(spacing: 8) {
                            Circle()
                                .fill(RadialGradient(
                                    colors: [Color(red: 0.28, green: 0.9, blue: 0.63),
                                             Color(red: 0.03, green: 0.36, blue: 0.25)],
                                    center: .init(x: 0.35, y: 0.3),
                                    startRadius: 2, endRadius: 34))
                                .frame(width: 58, height: 58)
                                .shadow(color: Color(red: 0.28, green: 0.9, blue: 0.63)
                                    .opacity(liveAIManager.isRunning ? 0.8 : 0.35),
                                    radius: liveAIManager.isRunning ? 18 : 10)
                            Text("Chappy")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text(liveAIManager.isRunning ? "Listening — just talk"
                                 : (continuousVision.isRunning ? "Watching — say chappy stop to end"
                                    : "Ready when you are"))
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.55))
                        }
                        .padding(.top, 18)

                        // STATUS STRIP
                        HStack(spacing: 8) {
                            StatusChip(label: "Glasses", on: streamViewModel.hasActiveDevice)
                            StatusChip(label: "Camera", on: streamViewModel.streamingStatus == .streaming)
                            StatusChip(label: "Live AI", on: liveAIManager.isRunning)
                            StatusChip(label: "Vision", on: continuousVision.isRunning)
                        }

                        // NAVIGATION CARD — appears only while navigating
                        if navEngine.isNavigating {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 12) {
                                    Image(systemName: "location.north.circle.fill")
                                        .font(.title)
                                        .foregroundColor(.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("→ \(navEngine.destinationName)")
                                            .font(.headline)
                                            .foregroundColor(.white)
                                        Text(navEngine.nextInstruction)
                                            .font(.subheadline)
                                            .foregroundColor(.white.opacity(0.85))
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Text(navEngine.distanceText)
                                        .font(.headline)
                                        .foregroundColor(.green)
                                }
                                HStack(spacing: 10) {
                                    Button { showNavMap = true } label: {
                                        Label("Map", systemImage: "map")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.blue)
                                    Button { navEngine.stop(announce: true) } label: {
                                        Label("Stop", systemImage: "xmark.circle")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                }
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.4)))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.5), lineWidth: 1))
                            .sheet(isPresented: $showNavMap) {
                                NavMapSheet(navEngine: navEngine)
                            }
                        }

                        // THE FOUR MODES
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                ModeTile(title: "Talk",
                                         subtitle: "Live AI — eyes, ears and answers",
                                         icon: "waveform.circle.fill",
                                         accent: Color(red: 0.28, green: 0.9, blue: 0.63),
                                         active: liveAIManager.isRunning) {
                                    showLiveAI = true
                                }
                                ModeTile(title: "Look",
                                         subtitle: "One snap, one answer",
                                         icon: "eye.circle.fill",
                                         accent: .purple,
                                         active: false) {
                                    showQuickVision = true
                                }
                            }
                            HStack(spacing: 12) {
                                ModeTile(title: "Translate",
                                         subtitle: "Two-way interpreter",
                                         icon: "globe",
                                         accent: .teal,
                                         active: false) {
                                    showLiveTranslate = true
                                }
                                ModeTile(title: "Navigate",
                                         subtitle: navEngine.isNavigating ? "Navigating — tap for map" : "Talk, then say: navigate to...",
                                         icon: "location.circle.fill",
                                         accent: .blue,
                                         active: navEngine.isNavigating) {
                                    if navEngine.isNavigating { showNavMap = true } else { showLiveAI = true }
                                }
                            }
                        }

                        // QUICK ACTIONS
                        HStack(spacing: 10) {
                            QuickActionButton(icon: "camera.fill", label: "Snap") {
                                showQuickVision = true
                            }
                            QuickActionButton(icon: "mappin.circle.fill", label: "Remember") {
                                let spot = TripRecorder.shared.rememberSpot(named: "")
                                TTSService.shared.speak("Saved \(spot.name).")
                            }
                            QuickActionButton(icon: continuousVision.isRunning ? "eye.slash.fill" : "eye.fill",
                                              label: continuousVision.isRunning ? "Stop" : "Watch") {
                                if continuousVision.isRunning {
                                    continuousVision.stop()
                                } else {
                                    continuousVision.start(streamViewModel: streamViewModel)
                                }
                            }
                            QuickActionButton(icon: "map.fill", label: "Map") {
                                if navEngine.isNavigating { showNavMap = true }
                            }
                        }

                        // TODAY — journal glance
                        HStack {
                            Image(systemName: "book.closed.fill")
                                .foregroundColor(.white.opacity(0.5))
                            Text("Today: \(TripRecorder.shared.crumbs.count) points · \(TripRecorder.shared.spots.filter { Calendar.current.isDateInToday($0.t) }.count) spots · \(TripRecorder.shared.notes.count) notes")
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.55))
                            Spacer()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))

                        // MORE
                        VStack(spacing: 8) {
                            MoreRow(icon: "link.circle.fill", title: "OpenClaw",
                                    detail: openClawService.connectionState == .connected ? "Connected" : "Home computer bridge") {
                                showOpenClaw = true
                            }
                            MoreRow(icon: "antenna.radiowaves.left.and.right", title: "RTMP Streaming", detail: "Experimental") {
                                showRTMPStreaming = true
                            }
                            MoreRow(icon: "video.fill", title: "Screen Stream", detail: "Record and stream") {
                                showLiveStream = true
                            }
                            MoreRow(icon: "chart.bar.fill", title: "LeanEat", detail: "Food analysis") {
                                showLeanEat = true
                            }
                        }
                        .padding(.bottom, 30)
                    }
                    .padding(.horizontal, 18)
                }
            }
            .navigationBarHidden(true)
            .fullScreenCover(isPresented: $showLiveAI) {
                LiveAIView(streamViewModel: streamViewModel, apiKey: apiKey)
            }
            .fullScreenCover(isPresented: $showLiveStream) {
                SimpleLiveStreamView(streamViewModel: streamViewModel)
            }
            .fullScreenCover(isPresented: $showRTMPStreaming) {
                RTMPStreamingView(streamViewModel: streamViewModel)
            }
            .fullScreenCover(isPresented: $showLeanEat) {
                StreamView(viewModel: streamViewModel, wearablesVM: wearablesViewModel)
            }
            .fullScreenCover(isPresented: $showQuickVision) {
                QuickVisionView(streamViewModel: streamViewModel, apiKey: apiKey)
            }
            .fullScreenCover(isPresented: $showLiveTranslate) {
                LiveTranslateView(streamViewModel: streamViewModel)
            }
            .fullScreenCover(isPresented: $showOpenClaw) {
                OpenClawChatView(streamViewModel: streamViewModel)
            }
        }
        .onAppear {
            // Ensure QuickVisionManager has the streamViewModel reference
            quickVisionManager.setStreamViewModel(streamViewModel)
            // Ensure LiveAIManager has the streamViewModel reference
            liveAIManager.setStreamViewModel(streamViewModel)

            // OpenClaw Auto-connect (if a saved configuration exists)
            if openClawService.connectionState == .disconnected,
               openClawService.loadGatewayToken() != nil {
                openClawService.connect()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveAITriggered)) { _ in
            // Triggered from Shortcuts — auto-open the Live AI screen
            showLiveAI = true
        }
    }
}

// MARK: - Continuous Vision Manager
// Hands-free Quick Vision loop: snap → Chappy speaks → snap again — until
// the user SAYS "stop" (on-device speech recognition, works offline).

@MainActor
final class ContinuousVisionManager: NSObject, ObservableObject {
    static let shared = ContinuousVisionManager()

    @Published var isRunning = false
    @Published var statusText = ""

    private weak var streamViewModel: StreamSessionViewModel?
    private var loopTask: Task<Void, Never>?

    // Voice-stop listening
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let listenEngine = AVAudioEngine()

    // MARK: Start / Stop

    func start(streamViewModel: StreamSessionViewModel) {
        guard !isRunning else { return }
        self.streamViewModel = streamViewModel

        guard streamViewModel.hasActiveDevice else {
            TTSService.shared.speak("Glasses not connected - pair them in the Meta AI app first.")
            return
        }

        isRunning = true
        statusText = "Starting..."

        // Ask for speech permission (for the voice "stop") — loop runs either way
        SFSpeechRecognizer.requestAuthorization { _ in }

        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop(announce: Bool = true) {
        guard isRunning else { return }
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        stopVoiceStopListener()
        TTSService.shared.stop()
        if announce {
            TTSService.shared.speak("Continuous vision off.")
        }
        statusText = ""
        print("🛑 [ContinuousVision] Stopped")
    }

    // MARK: Main loop

    private func runLoop() async {
        guard let streamViewModel else { return }

        // Make sure the glasses stream is running
        if streamViewModel.streamingStatus != .streaming {
            await streamViewModel.handleStartStreaming()
            let deadline = Date().addingTimeInterval(6)
            while streamViewModel.streamingStatus != .streaming && Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        guard streamViewModel.streamingStatus == .streaming else {
            TTSService.shared.speak("Could not start the camera stream - check the glasses.")
            stop(announce: false)
            return
        }

        TTSService.shared.speak("Continuous vision on. Say chappy stop anytime.")
        while TTSService.shared.isSpeaking && isRunning {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Start listening for "stop" AFTER the intro (so it doesn't hear itself)
        startVoiceStopListener()

        while isRunning && !Task.isCancelled {
            // Keep the voice-stop listener alive (recognition tasks time out)
            ensureVoiceStopListener()

            guard let frame = streamViewModel.currentVideoFrame else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            statusText = "Looking..."
            do {
                let answer = try await QuickVisionService().analyzeImage(frame)
                guard isRunning else { break }

                statusText = "Speaking..."
                TTSService.shared.speak(answer)
                while TTSService.shared.isSpeaking && isRunning {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }

                // Small breather before the next look
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                print("⚠️ [ContinuousVision] Snap failed: \(error.localizedDescription)")
                statusText = "Retrying..."
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        statusText = ""
    }

    // MARK: Voice stop ("stop", "stop chappy", "chappy stop")

    private func startVoiceStopListener() {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let speechRecognizer, speechRecognizer.isAvailable else {
            print("⚠️ [ContinuousVision] Voice-stop unavailable - use the button to stop")
            return
        }
        stopVoiceStopListener()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = listenEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // CRASH GUARD: installing a tap with a dead mic format (sampleRate 0,
        // e.g. audio session not configured for recording yet) crashes the
        // app with an unhandled exception. Skip voice-stop this session
        // instead — the button still stops it.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            print("⚠️ [ContinuousVision] Mic format not ready — voice-stop off this session")
            return
        }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }

        do {
            listenEngine.prepare()
            try listenEngine.start()
        } catch {
            print("⚠️ [ContinuousVision] Voice-stop mic failed: \(error)")
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString.lowercased()
                // BARGE-IN: "chappy stop" / "stop chappy" / "shut up" cuts
                // Chappy off ANY time — even mid-sentence. Bare "stop" only
                // counts while Chappy is quiet, so its own narration
                // ("...there's a bus stop...") can never kill the session.
                let strongStop = text.contains("stop chappy")
                    || text.contains("chappy stop")
                    || text.contains("shut up")
                let bareStop = !TTSService.shared.isSpeaking && text.hasSuffix("stop")
                if strongStop || bareStop {
                    Task { @MainActor in self?.stop() }
                    return
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                // Task ended — the main loop's ensure call will restart it
                Task { @MainActor in self?.recognitionTask = nil }
            }
        }
        print("👂 [ContinuousVision] Voice-stop listener running")
    }

    private func ensureVoiceStopListener() {
        if recognitionTask == nil,
           SFSpeechRecognizer.authorizationStatus() == .authorized {
            startVoiceStopListener()
        }
    }

    private func stopVoiceStopListener() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if listenEngine.isRunning {
            listenEngine.inputNode.removeTap(onBus: 0)
            listenEngine.stop()
        }
    }
}

// MARK: - Feature Card

struct FeatureCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: [Color]
    var isPlaceholder: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: AppSpacing.md) {
                Spacer()

                // Icon
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: 56, height: 56)

                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(.white)
                }

                // Text
                VStack(spacing: AppSpacing.xs) {
                    Text(title)
                        .font(AppTypography.headline)
                        .foregroundColor(.white)

                    Text(subtitle)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.8))
                }

                if isPlaceholder {
                    Text("home.comingsoon".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.xs)
                        .background(.white.opacity(0.2))
                        .cornerRadius(AppCornerRadius.sm)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(
                LinearGradient(
                    colors: gradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(AppCornerRadius.lg)
            .shadow(color: AppShadow.medium(), radius: 10, x: 0, y: 5)
        }
        .disabled(isPlaceholder)
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Feature Card Wide

struct FeatureCardWide: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: [Color]
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.lg) {
                // Icon
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: 64, height: 64)

                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.white)
                }

                // Text
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    HStack(spacing: AppSpacing.sm) {
                        Text(title)
                            .font(AppTypography.title2)
                            .foregroundColor(.white)

                        if let badge = badge {
                            Text(badge)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.25))
                                .cornerRadius(4)
                        }
                    }

                    Text(subtitle)
                        .font(AppTypography.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(AppSpacing.lg)
            .background(
                LinearGradient(
                    colors: gradient,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(AppCornerRadius.lg)
            .shadow(color: AppShadow.medium(), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Scale Button Style

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Navigation Map (Phase 4 Step 6)
// On-demand map: appears ONLY when asked — voice-first always.
// Route drawn on MapKit (display), routing data from Google (NavEngine).

struct NavMapSheet: View {
    @ObservedObject var navEngine: NavEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            RouteMapView(coords: navEngine.routeCoords, destination: navEngine.destinationCoord)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(navEngine.destinationName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

struct RouteMapView: UIViewRepresentable {
    let coords: [CLLocationCoordinate2D]
    let destination: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        map.delegate = context.coordinator
        if !coords.isEmpty {
            let line = MKPolyline(coordinates: coords, count: coords.count)
            map.addOverlay(line)
            map.setVisibleMapRect(line.boundingMapRect.insetBy(dx: -600, dy: -600), animated: false)
        }
        if let d = destination {
            let pin = MKPointAnnotation()
            pin.coordinate = d
            map.addAnnotation(pin)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = .systemGreen
                r.lineWidth = 5
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}


// MARK: - The Face (Phase 4.9) building blocks

struct StatusChip: View {
    let label: String
    let on: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(on ? Color(red: 0.28, green: 0.9, blue: 0.63) : Color.white.opacity(0.25))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(on ? 0.9 : 0.45))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

struct ModeTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(accent)
                Spacer(minLength: 2)
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 110)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(active ? 0.12 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(active ? accent.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct QuickActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.9))
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

struct MoreRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }
}
