/*
 * TurboMeta Home View
 * Home — feature entry points
 * Also hosts ContinuousVisionManager: the hands-free Quick Vision loop
 * (kept in this file so no Xcode project changes are needed).
 */

import SwiftUI
import AVFoundation
import Speech

struct TurboMetaHomeView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var wearablesViewModel: WearablesViewModel
    @StateObject private var quickVisionManager = QuickVisionManager.shared
    @StateObject private var liveAIManager = LiveAIManager.shared
    @StateObject private var continuousVision = ContinuousVisionManager.shared
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
                // Background gradient
                LinearGradient(
                    colors: [
                        AppColors.primary.opacity(0.1),
                        AppColors.secondary.opacity(0.1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: AppSpacing.lg) {
                        // Header
                        VStack(spacing: AppSpacing.sm) {
                            Text("app.name".localized)
                                .font(AppTypography.largeTitle)
                                .foregroundColor(AppColors.textPrimary)

                            Text("app.subtitle".localized)
                                .font(AppTypography.callout)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .padding(.top, AppSpacing.xl)

                        // Feature Grid
                        VStack(spacing: AppSpacing.md) {
                            // Row 1
                            HStack(spacing: AppSpacing.md) {
                                FeatureCard(
                                    title: "home.liveai.title".localized,
                                    subtitle: "home.liveai.subtitle".localized,
                                    icon: "brain.head.profile",
                                    gradient: [AppColors.liveAI, AppColors.liveAI.opacity(0.7)]
                                ) {
                                    showLiveAI = true
                                }

                                FeatureCard(
                                    title: "home.quickvision.title".localized,
                                    subtitle: "home.quickvision.subtitle".localized,
                                    icon: "eye.circle.fill",
                                    gradient: [Color.purple, Color.purple.opacity(0.7)]
                                ) {
                                    showQuickVision = true
                                }
                            }

                            // Row 2
                            HStack(spacing: AppSpacing.md) {
                                FeatureCard(
                                    title: "home.translate.title".localized,
                                    subtitle: "home.translate.subtitle".localized,
                                    icon: "globe",
                                    gradient: [Color.teal, Color.teal.opacity(0.7)]
                                ) {
                                    showLiveTranslate = true
                                }

                                FeatureCard(
                                    title: "OpenClaw",
                                    subtitle: openClawService.connectionState == .connected ? "home.openclaw.connected".localized : "home.openclaw.subtitle".localized,
                                    icon: "link.circle.fill",
                                    gradient: [Color.purple, Color.indigo]
                                ) {
                                    showOpenClaw = true
                                }
                            }

                            // Continuous Vision — hands-free Quick Vision loop
                            FeatureCardWide(
                                title: continuousVision.isRunning ? "Continuous Vision — ON" : "Continuous Vision",
                                subtitle: continuousVision.isRunning
                                    ? (continuousVision.statusText.isEmpty ? "Say STOP to end" : continuousVision.statusText + " — say STOP to end")
                                    : "Chappy keeps looking and describing until you say stop",
                                icon: continuousVision.isRunning ? "eye.fill" : "eyes",
                                gradient: continuousVision.isRunning ? [Color.green, Color.mint] : [Color.indigo, Color.blue]
                            ) {
                                if continuousVision.isRunning {
                                    continuousVision.stop()
                                } else {
                                    continuousVision.start(streamViewModel: streamViewModel)
                                }
                            }

                            // Row 3 - RTMP Streaming (Experimental)
                            FeatureCardWide(
                                title: "home.rtmp.title".localized,
                                subtitle: "home.rtmp.subtitle".localized,
                                icon: "antenna.radiowaves.left.and.right",
                                gradient: [Color.red, Color.orange],
                                badge: "home.experimental".localized
                            ) {
                                showRTMPStreaming = true
                            }

                            // Row 4 - Screen Recording Stream
                            FeatureCardWide(
                                title: "home.livestream.title".localized,
                                subtitle: "home.livestream.subtitle".localized,
                                icon: "video.fill",
                                gradient: [AppColors.liveStream, AppColors.liveStream.opacity(0.7)]
                            ) {
                                showLiveStream = true
                            }

                            // Row 5 - LeanEat
                            FeatureCardWide(
                                title: "home.leaneat.title".localized,
                                subtitle: "home.leaneat.subtitle".localized,
                                icon: "chart.bar.fill",
                                gradient: [AppColors.leanEat, AppColors.leanEat.opacity(0.7)]
                            ) {
                                showLeanEat = true
                            }
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.bottom, AppSpacing.xl)
                    }
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

        TTSService.shared.speak("Continuous vision on. Say stop when you are done.")
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
                // Ignore anything heard while Chappy itself is talking
                if !TTSService.shared.isSpeaking,
                   text.hasSuffix("stop") || text.contains("stop chappy") || text.contains("chappy stop") {
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
