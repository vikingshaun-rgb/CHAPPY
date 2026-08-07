/*
 * TurboMeta Home View
 * Home — feature entry points
 * Also hosts ContinuousVisionManager: the hands-free Quick Vision loop
 * (kept in this file so no Xcode project changes are needed).
 */

import SwiftUI
import UIKit
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
    @State private var showEmergencyContact = false
    @State private var emergencyContactText = UserDefaults.standard.string(forKey: "chappy_emergency_contact") ?? ""
    let apiKey: String

    @State private var showLiveAI = false
    @State private var showLiveStream = false
    @State private var showRTMPStreaming = false
    @State private var showLeanEat = false
    // CHAPPY THEMES: the Face's wardrobe (picker lives in Settings → Appearance)
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }
    // LIVING ORB: breathing animation state
    @State private var orbPulse = false
    // Journal refresh trigger (Remember button feedback) + always-on map
    @State private var journalTick = 0
    @State private var showMapSheet = false
    // CHAPPY STANDBY — the wake-word ear
    @StateObject private var standby = ChappyStandby.shared
    @State private var showQuickVision = false
    @State private var showLiveTranslate = false
    @State private var showOpenClaw = false
    @ObservedObject private var openClawService = OpenClawNodeService.shared

    /// POCKET LAW: arm the wake word, but never on top of a module that owns
    /// the microphone. Every one of these covers is a full-screen session; if
    /// one is up, that module is the thing listening and Standby must stay out
    /// of its way. It re-arms by itself via resumeAfterHandOff when the module
    /// closes, and failing that, the next didBecomeActive catches it.
    private func armStandbyIfClear(reason: String) {
        guard !showLiveAI, !showLiveTranslate, !showQuickVision,
              !showLiveStream, !showRTMPStreaming, !showOpenClaw, !showLeanEat
        else {
            print("👂 [Standby] Auto-arm skipped (\(reason)) — a module is on screen")
            return
        }
        ChappyStandby.shared.autoArmIfWanted(reason: reason)
    }

    var body: some View {
        NavigationView {
            ZStack {
                // THE FACE (Phase 4.9): dark-first, one accent, big targets.
                // Re-skin only — every action fires the exact same wiring
                // as the old grid (no-breakage law).
                LinearGradient(
                    colors: [theme.bgTop, theme.bgBottom],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        // ORB HEADER — glows when Chappy is live
                        VStack(spacing: 8) {
                            // THE AVATAR — Chappy's living face. Eight styles,
                            // theme-matched by default, chosen in Settings →
                            // Appearance → Avatar. Pure code: GPU-composited,
                            // home-screen only, zero cost to the AI pipeline.
                            ChappyAvatarView(theme: theme, live: liveAIManager.isRunning)
                            Text("Chappy")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundColor(theme.textPrimary)
                            Text(liveAIManager.isRunning ? "Listening — just talk"
                                 : (continuousVision.isRunning ? "Watching — say chappy stop to end"
                                    : "Ready when you are"))
                                .font(.subheadline)
                                .foregroundColor(theme.textSecondary)
                        }
                        .padding(.top, 18)

                        // STATUS STRIP
                        HStack(spacing: 8) {
                            StatusChip(label: "Glasses", on: streamViewModel.hasActiveDevice)
                            StatusChip(label: "Camera", on: streamViewModel.streamingStatus == .streaming)
                            StatusChip(label: "Live AI", on: liveAIManager.isRunning)
                            StatusChip(label: "Standby", on: standby.isListening)
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
                                            .foregroundColor(theme.textPrimary)
                                        Text(navEngine.nextInstruction)
                                            .font(.subheadline)
                                            .foregroundColor(theme.textPrimary.opacity(0.85))
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
                            .background(RoundedRectangle(cornerRadius: 18).fill(theme.cardFill))
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
                                         accent: theme.accent,
                                         active: liveAIManager.isRunning) {
                                    // AUDIT FIX (LA-H9): stop() forgets Standby was
                                    // ever listening, so closing Live AI left the
                                    // wake word dead until the user dug the phone
                                    // out. handOff() remembers and comes back.
                                    if standby.isListening { standby.handOff() }
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
                                    // AUDIT FIX: mic handoff — two engines on
                                    // one input node crashed the translator
                                    if standby.isListening { standby.handOff() }
                                    showLiveTranslate = true
                                }
                                ModeTile(title: "Go",
                                         subtitle: navEngine.isNavigating
                                            ? "Navigating — tap for map"
                                            : (standby.isListening ? "Tap, then say where to" : "Tap to arm, then say where to"),
                                         icon: "location.circle.fill",
                                         accent: .blue,
                                         active: navEngine.isNavigating) {
                                    // AUDIT FIX (NAV-TILE): tapping this used to
                                    // silently open a METERED Live AI session,
                                    // which is not what a button labelled
                                    // "Navigate" should do and is not what
                                    // anyone expects. Navigation is a free,
                                    // on-device Standby command — so arm the
                                    // ear and ask, instead of burning a session.
                                    if navEngine.isNavigating {
                                        showNavMap = true
                                    } else {
                                        ChappyStandby.shared.promptForDestination()
                                    }
                                }
                            }
                        }

                        // QUICK ACTIONS
                        HStack(spacing: 10) {
                            QuickActionButton(icon: "camera.fill", label: "Snap") {
                                showQuickVision = true
                            }
                            QuickActionButton(icon: "mappin.circle.fill", label: "Remember") {
                                // Remember always DID save — but it named the pin
                                // "spot at 4:53PM near Cresthaven Court", which is
                                // a timestamp, not a memory. Forty of those and
                                // none of them mean anything. Now it clicks, saves,
                                // and asks what to call it, so you can answer
                                // "the warung with the good coffee" out loud in the
                                // two seconds while you still remember why you
                                // pressed it.
                                ChappyStandby.shared.rememberSpotByVoice()
                                journalTick += 1
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            }
                            QuickActionButton(icon: continuousVision.isRunning ? "eye.slash.fill" : "eye.fill",
                                              label: continuousVision.isRunning ? "Stop" : "Watch") {
                                if continuousVision.isRunning {
                                    continuousVision.stop()
                                } else {
                                    // AUDIT FIX: mic handoff (the Talk tile did
                                    // this, the Watch tile didn't — two
                                    // recognizers fought over one microphone)
                                    if standby.isListening { standby.handOff() }
                                    continuousVision.start(streamViewModel: streamViewModel)
                                }
                            }
                            // CHAPPY STANDBY — the wake-word ear (free while waiting)
                            QuickActionButton(icon: standby.isListening ? "ear.fill" : "ear",
                                              label: standby.isListening ? "Ear On" : "Standby") {
                                standby.toggle()
                            }
                            QuickActionButton(icon: "map.fill", label: "Map") {
                                ContextEngine.shared.start()
                                showMapSheet = true
                            }
                            .sheet(isPresented: $showMapSheet) {
                                if navEngine.isNavigating {
                                    NavMapSheet(navEngine: navEngine)
                                } else {
                                    TodayMapSheet()
                                }
                            }
                        }

                        // TODAY — journal glance
                        HStack {
                            Image(systemName: "book.closed.fill")
                                .foregroundColor(theme.textSecondary)
                            Text("Today: \(TripRecorder.shared.crumbs.count) points · \(TripRecorder.shared.spots.filter { Calendar.current.isDateInToday($0.t) }.count) spots · \(TripRecorder.shared.notes.count) notes")
                                .font(.footnote)
                                .foregroundColor(theme.textSecondary)
                            Spacer()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(theme.cardFill))
                        .id(journalTick) // refresh counts when Remember fires

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
                            MoreRow(icon: "cross.circle.fill", title: "Emergency Contact",
                                    detail: emergencyContactText.isEmpty ? "Set the WhatsApp number for emergencies" : "Saved — tap to change") {
                                showEmergencyContact = true
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
            // GPS from app-open (not just Live AI) — journal, Remember and
            // the Map button all need a fix before any session starts
            ContextEngine.shared.start()
            // Ensure QuickVisionManager has the streamViewModel reference
            quickVisionManager.setStreamViewModel(streamViewModel)
            // Ensure LiveAIManager has the streamViewModel reference
            liveAIManager.setStreamViewModel(streamViewModel)

            // OpenClaw Auto-connect (if a saved configuration exists)
            if openClawService.connectionState == .disconnected,
               openClawService.loadGatewayToken() != nil {
                openClawService.connect()
            }

            // POCKET LAW: Action Button → app open → ear already listening.
            // Delayed a beat so the audio session settles after launch; arming
            // into a session iOS is still configuring is how the ear ends up
            // running with no audio reaching it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                armStandbyIfClear(reason: "app opened")
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            // Coming back from a call, another app, or a locked screen. Without
            // this the ear is armed exactly once per cold launch and any
            // interruption leaves it closed for the rest of the day.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                armStandbyIfClear(reason: "foreground")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveAITriggered)) { _ in
            // Triggered from Shortcuts — auto-open the Live AI screen
            showLiveAI = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .chappyOpenTranslate)) { _ in
            showLiveTranslate = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .chappyShowMap)) { _ in
            showMapSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .chappyOpenGoogleMaps)) { _ in
            let nav = NavEngine.shared
            var url: URL?
            if let d = nav.destinationCoord {
                // Two-wheeler directions where Google supports them (most of
                // SE Asia); driving elsewhere. A scooter on car directions gets
                // sent down roads it shouldn't be on.
                let mode = nav.lastModeWasScooter ? "two-wheeler"
                    : (nav.lastDriving ? "driving" : "walking")
                let appURL = URL(string: "comgooglemaps://?daddr=\(d.latitude),\(d.longitude)&directionsmode=\(mode)")
                url = (appURL.map { UIApplication.shared.canOpenURL($0) } == true)
                    ? appURL
                    : URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(d.latitude),\(d.longitude)&travelmode=\(mode)")
            } else {
                let appURL = URL(string: "comgooglemaps://")
                url = (appURL.map { UIApplication.shared.canOpenURL($0) } == true)
                    ? appURL : URL(string: "https://maps.google.com/")
            }
            if let u = url { UIApplication.shared.open(u) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .continuousVisionTriggered)) { _ in
            // "Hey Siri, Continuous Vision"
            if !continuousVision.isRunning {
                continuousVision.start(streamViewModel: streamViewModel)
            } else {
                // AUDIT P0 (MH-1): the hand-off was already spent by the router.
                // Swallowing the notification here stranded the ear just as
                // thoroughly as a failed start did.
                ChappyStandby.shared.resumeAfterHandOff()
            }
        }
        .alert("Emergency Contact", isPresented: $showEmergencyContact) {
            TextField("Number with country code, e.g. 61412345678", text: $emergencyContactText)
                .keyboardType(.phonePad)
            Button("Save") {
                UserDefaults.standard.set(
                    emergencyContactText.trimmingCharacters(in: .whitespaces),
                    forKey: "chappy_emergency_contact")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("When you say Chappy emergency, your live location is sent to this WhatsApp number.")
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

    // AUDIT: session guards — a narration loop with no brakes is a money fire
    private var startedStream = false
    private var startedAt = Date()
    private var renewTimer: Timer?
    private var failures = 0
    private static let maxSessionMinutes: Double = 25

    func start(streamViewModel: StreamSessionViewModel) {
        // AUDIT P0 (MH-1): the router speaks "Watching.", calls handOff() — which
        // tears down the recognizer, the tap, the engine AND the renew timer —
        // and then posts the notification that lands here. Every one of the
        // bail-outs below used to return without giving the microphone back, so
        // "Chappy, keep watching" with the glasses asleep or the battery at 18%
        // killed the wake word for the rest of the day. The wearer heard a
        // refusal and then silence, forever, with no way back except taking the
        // phone out — the one thing this whole layer exists to avoid.
        var claimed = false
        defer { if !claimed { ChappyStandby.shared.resumeAfterHandOff() } }
        guard !isRunning else { return }
        // AUDIT FIX (HIGH): Watch + Talk together = two Chappys narrating over
        // each other, both metered, each stealing the other's audio session.
        guard !LiveAIManager.shared.isRunning else {
            TTSService.shared.speak("Live AI is already running - stop that first.")
            return
        }
        self.streamViewModel = streamViewModel

        guard streamViewModel.hasActiveDevice else {
            TTSService.shared.speak("Glasses not connected - pair them in the Meta AI app first.")
            return
        }
        // AUDIT FIX: battery guard (Standby had one, this didn't)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let lvl = UIDevice.current.batteryLevel
        if lvl >= 0 && lvl < 0.20 {
            TTSService.shared.speak("Battery's under twenty percent - watching would drain it fast.")
            return
        }
        // AUDIT FIX: the wake-word ear must let go of the mic, and be restored
        if ChappyStandby.shared.isListening { ChappyStandby.shared.handOff() }

        isRunning = true
        claimed = true // from here on, stop() owns returning the ear
        startedAt = Date()
        failures = 0
        statusText = "Starting..."

        SFSpeechRecognizer.requestAuthorization { _ in }
        // AUDIT FIX: mic permission was never requested — voice-stop failed
        // silently on a fresh install while the intro promised it worked.
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }

        // AUDIT FIX (HIGH): recognition tasks die after ~60s and renewal was
        // only attempted between loop iterations — so "chappy stop" was deaf
        // for most of every describe-and-speak cycle.
        renewTimer?.invalidate()
        renewTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, !TTSService.shared.isSpeaking else { return }
                self.stopVoiceStopListener()
                self.startVoiceStopListener()
            }
        }

        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop(announce: Bool = true) {
        guard isRunning else { return }
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        renewTimer?.invalidate(); renewTimer = nil
        stopVoiceStopListener()
        TTSService.shared.stop()
        // AUDIT FIX (CRITICAL): stop() never released the camera. The glasses
        // kept streaming and isIdleTimerDisabled stayed true, so the phone
        // screen never slept — both batteries burned after the user said stop.
        if startedStream, let vm = streamViewModel {
            startedStream = false
            Task { @MainActor in await vm.stopSession() }
        }
        if announce {
            TTSService.shared.speak("Continuous vision off.")
        }
        // AUDIT FIX: the ear comes back after a voice-started Watch session
        ChappyStandby.shared.resumeAfterHandOff()
        statusText = ""
        print("🛑 [ContinuousVision] Stopped")
    }

    // MARK: Main loop

    private func runLoop() async {
        // AUDIT FIX: bailing here left isRunning stuck true with no loop —
        // a permanently "Watching" UI that does nothing.
        guard let streamViewModel else { stop(announce: false); return }

        // Make sure the glasses stream is running
        if streamViewModel.streamingStatus != .streaming {
            startedStream = true // remember WE started it, so we release it
            await streamViewModel.handleStartStreaming()
            let deadline = Date().addingTimeInterval(6)
            while streamViewModel.streamingStatus != .streaming && Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        guard streamViewModel.streamingStatus == .streaming else {
            // AUDIT FIX: stop() cancels TTS, so speaking BEFORE stopping meant
            // the user heard nothing at all — the button just flipped back.
            stop(announce: false)
            TTSService.shared.speak("Could not start the camera stream - check the glasses.")
            return
        }

        TTSService.shared.speak("Continuous vision on. Say chappy stop anytime.")
        while TTSService.shared.isSpeaking && isRunning {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Start listening for "stop" AFTER the intro (so it doesn't hear itself)
        startVoiceStopListener()

        var blindTicks = 0
        while isRunning && !Task.isCancelled {
            // AUDIT FIX (CRITICAL): hard session cap. There was no duration
            // limit, no battery stop and no spend ceiling — a forgotten
            // session narrated the inside of a bag for hours, billing all day.
            if Date().timeIntervalSince(startedAt) > Self.maxSessionMinutes * 60 {
                TTSService.shared.speak("That's twenty five minutes of watching - I'll stop here to save battery and cost. Say watch again to carry on.")
                stop(announce: false)
                return
            }
            ensureVoiceStopListener()

            guard let frame = streamViewModel.currentVideoFrame else {
                // AUDIT FIX (HIGH): a Quick Vision snap, glasses out of range,
                // or a stream restart nils the frame — the loop used to spin
                // here FOREVER while the UI still claimed to be watching.
                blindTicks += 1
                if blindTicks == 20 { // ~10s blind: try to revive the stream
                    statusText = "Reconnecting..."
                    if streamViewModel.streamingStatus != .streaming {
                        await streamViewModel.handleStartStreaming()
                        startedStream = true
                    }
                }
                if blindTicks > 60 { // ~30s blind: say so, don't lie
                    TTSService.shared.speak("I've lost the camera - continuous vision off.")
                    stop(announce: false)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            blindTicks = 0

            statusText = "Looking..."
            do {
                // AUDIT FIX (CRITICAL COST): the default Quick Vision prompt
                // carries web search (up to 3 searches PER FRAME, ~$0.01 each)
                // and whatever mode the user last picked — an encyclopedia
                // entry every ten seconds. Narration gets its own short,
                // search-free prompt.
                let answer = try await QuickVisionService().analyzeImage(
                    frame,
                    customPrompt: "You are narrating for someone wearing these glasses. In ONE short spoken sentence, say only what is notable or has CHANGED in this view. If nothing has meaningfully changed, reply with exactly: SKIP. No preamble, no lists, never mention images or photos.",
                    allowWebSearch: false) // AUDIT FIX: search per narration frame was ~10x the cost
                guard isRunning, !Task.isCancelled else { break }
                failures = 0

                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.uppercased().hasPrefix("SKIP") || trimmed.isEmpty {
                    // Nothing new to say — stay quiet and cost nothing extra
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    continue
                }
                // (cost is booked inside the service on a real 200 — no double count)
                statusText = "Speaking..."
                TTSService.shared.speak(trimmed)
                while TTSService.shared.isSpeaking && isRunning && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                // AUDIT FIX (HIGH): the recognizer keeps ONE growing transcript,
                // so Chappy narrating "...there's a bus stop" left the word
                // "stop" in the buffer and killed the session a moment later.
                // Fresh ear after every utterance.
                stopVoiceStopListener()
                startVoiceStopListener()

                try? await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                // AUDIT FIX (HIGH): this used to retry forever, silently — a
                // bad key meant 30 failed calls a minute and total silence
                // while the UI said "Watching".
                failures += 1
                print("⚠️ [ContinuousVision] Snap failed (\(failures)): \(error.localizedDescription)")
                statusText = "Retrying..."
                if failures == 2 {
                    TTSService.shared.speak("I'm having trouble seeing - trying again.")
                }
                if failures >= 5 {
                    TTSService.shared.speak("Vision keeps failing - stopping. Check the connection and your key.")
                    stop(announce: false)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(Double(failures) * 2_000_000_000))
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

/// Today's trail — the Map button's view when not navigating: your live
/// location plus every journal breadcrumb from today.
struct TodayMapSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            RouteMapView(
                coords: TripRecorder.shared.crumbs.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                },
                destination: nil,
                spots: TripRecorder.shared.spots)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(TripRecorder.shared.spots.isEmpty
                                 ? "Today's Trail"
                                 : "Today's Trail · \(TripRecorder.shared.spots.count) saved")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

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
    /// AUDIT FIX (SPOTS-INVISIBLE): Today's Trail drew the breadcrumb line and
    /// nothing else, so every spot you had carefully remembered was invisible
    /// on the one screen built to show you where you'd been. Saving a place you
    /// can never see again is not a feature. Titled pins, so tapping one tells
    /// you what you called it.
    var spots: [TripRecorder.Spot] = []

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        map.delegate = context.coordinator
        if !coords.isEmpty {
            let line = MKPolyline(coordinates: coords, count: coords.count)
            map.addOverlay(line)
            map.setVisibleMapRect(line.boundingMapRect.insetBy(dx: -600, dy: -600), animated: false)
        } else {
            // No trail yet — follow the user's live blue dot instead of
            // showing a blank world map
            map.userTrackingMode = .follow
        }
        if let d = destination {
            let pin = MKPointAnnotation()
            pin.title = "Destination"
            pin.coordinate = d
            map.addAnnotation(pin)
        }
        for s in spots where s.lat != 0 || s.lon != 0 {
            let pin = MKPointAnnotation()
            pin.coordinate = CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
            pin.title = s.name
            pin.subtitle = [s.street, s.city].compactMap { $0 }.joined(separator: ", ")
            map.addAnnotation(pin)
        }
        // If there is no trail but there ARE spots, frame the spots rather than
        // dropping the user on a blank world map.
        if coords.isEmpty, !spots.isEmpty {
            map.showAnnotations(map.annotations, animated: false)
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


// MARK: - Chappy Themes (the Face's wardrobe)

struct ChappyTheme {
    let name: String
    let bgTop: Color
    let bgBottom: Color
    let orbBright: Color
    let orbDeep: Color
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let cardFill: Color
    let cardActive: Color
    let stroke: Color

    static let midnightJade = ChappyTheme(
        name: "Midnight Jade",
        bgTop: Color(red: 0.05, green: 0.08, blue: 0.11), bgBottom: Color(red: 0.02, green: 0.03, blue: 0.05),
        orbBright: Color(red: 0.28, green: 0.9, blue: 0.63), orbDeep: Color(red: 0.03, green: 0.36, blue: 0.25),
        accent: Color(red: 0.28, green: 0.9, blue: 0.63),
        textPrimary: .white, textSecondary: Color.white.opacity(0.55),
        cardFill: Color.white.opacity(0.06), cardActive: Color.white.opacity(0.12), stroke: Color.white.opacity(0.08))

    static let baliSunset = ChappyTheme(
        name: "Bali Sunset",
        bgTop: Color(red: 0.11, green: 0.07, blue: 0.05), bgBottom: Color(red: 0.04, green: 0.02, blue: 0.01),
        orbBright: Color(red: 1.0, green: 0.5, blue: 0.3), orbDeep: Color(red: 0.45, green: 0.13, blue: 0.03),
        accent: Color(red: 1.0, green: 0.58, blue: 0.3),
        textPrimary: .white, textSecondary: Color.white.opacity(0.55),
        cardFill: Color.white.opacity(0.06), cardActive: Color.white.opacity(0.12), stroke: Color.white.opacity(0.08))

    static let neonSaigon = ChappyTheme(
        name: "Neon Saigon",
        bgTop: Color(red: 0.07, green: 0.02, blue: 0.1), bgBottom: Color(red: 0.02, green: 0.01, blue: 0.05),
        orbBright: Color(red: 1.0, green: 0.25, blue: 0.62), orbDeep: Color(red: 0.35, green: 0.03, blue: 0.4),
        accent: Color(red: 1.0, green: 0.3, blue: 0.65),
        textPrimary: .white, textSecondary: Color.white.opacity(0.55),
        cardFill: Color.white.opacity(0.06), cardActive: Color.white.opacity(0.12), stroke: Color.white.opacity(0.08))

    static let reefBlue = ChappyTheme(
        name: "Reef Blue",
        bgTop: Color(red: 0.02, green: 0.07, blue: 0.13), bgBottom: Color(red: 0.01, green: 0.02, blue: 0.06),
        orbBright: Color(red: 0.3, green: 0.85, blue: 1.0), orbDeep: Color(red: 0.02, green: 0.28, blue: 0.48),
        accent: Color(red: 0.3, green: 0.85, blue: 1.0),
        textPrimary: .white, textSecondary: Color.white.opacity(0.55),
        cardFill: Color.white.opacity(0.06), cardActive: Color.white.opacity(0.12), stroke: Color.white.opacity(0.08))

    static let arcticWhite = ChappyTheme(
        name: "Arctic White",
        bgTop: Color(red: 0.97, green: 0.97, blue: 0.98), bgBottom: Color(red: 0.88, green: 0.89, blue: 0.92),
        orbBright: Color(red: 1.0, green: 0.2, blue: 0.28), orbDeep: Color(red: 0.55, green: 0.0, blue: 0.1),
        accent: Color(red: 0.92, green: 0.1, blue: 0.22),
        textPrimary: Color(red: 0.08, green: 0.09, blue: 0.11), textSecondary: Color.black.opacity(0.5),
        cardFill: Color.black.opacity(0.05), cardActive: Color.black.opacity(0.1), stroke: Color.black.opacity(0.1))

    static let outbackGold = ChappyTheme(
        name: "Outback Gold",
        bgTop: Color(red: 0.06, green: 0.05, blue: 0.02), bgBottom: Color(red: 0.01, green: 0.01, blue: 0.0),
        orbBright: Color(red: 1.0, green: 0.82, blue: 0.38), orbDeep: Color(red: 0.45, green: 0.3, blue: 0.05),
        accent: Color(red: 0.96, green: 0.78, blue: 0.35),
        textPrimary: .white, textSecondary: Color.white.opacity(0.55),
        cardFill: Color.white.opacity(0.06), cardActive: Color.white.opacity(0.12), stroke: Color.white.opacity(0.08))

    static let bladeRunner = ChappyTheme(
        name: "Blade Runner",
        bgTop: Color(red: 0.03, green: 0.05, blue: 0.09), bgBottom: Color(red: 0.01, green: 0.01, blue: 0.03),
        orbBright: Color(red: 1.0, green: 0.1, blue: 0.16), orbDeep: Color(red: 0.38, green: 0.0, blue: 0.06),
        accent: Color(red: 1.0, green: 0.15, blue: 0.22),
        textPrimary: .white, textSecondary: Color.white.opacity(0.55),
        cardFill: Color.white.opacity(0.06), cardActive: Color.white.opacity(0.12), stroke: Color.white.opacity(0.08))

    static let heavyMetal = ChappyTheme(
        name: "Heavy Metal",
        bgTop: Color(red: 0.08, green: 0.08, blue: 0.09), bgBottom: Color(red: 0.02, green: 0.02, blue: 0.02),
        orbBright: Color(red: 0.88, green: 0.9, blue: 0.94), orbDeep: Color(red: 0.22, green: 0.24, blue: 0.28),
        accent: Color(red: 0.78, green: 0.81, blue: 0.86),
        textPrimary: .white, textSecondary: Color.white.opacity(0.55),
        cardFill: Color.white.opacity(0.07), cardActive: Color.white.opacity(0.14), stroke: Color.white.opacity(0.1))

    static let cyberVolt = ChappyTheme(
        name: "Cyber Volt",
        bgTop: Color(red: 0.04, green: 0.05, blue: 0.02), bgBottom: Color(red: 0.0, green: 0.01, blue: 0.0),
        orbBright: Color(red: 0.78, green: 1.0, blue: 0.2), orbDeep: Color(red: 0.25, green: 0.4, blue: 0.02),
        accent: Color(red: 0.78, green: 1.0, blue: 0.2),
        textPrimary: .white, textSecondary: Color.white.opacity(0.55),
        cardFill: Color.white.opacity(0.06), cardActive: Color.white.opacity(0.12), stroke: Color.white.opacity(0.08))

    static let deepAmethyst = ChappyTheme(
        name: "Deep Amethyst",
        bgTop: Color(red: 0.07, green: 0.04, blue: 0.12), bgBottom: Color(red: 0.02, green: 0.01, blue: 0.05),
        orbBright: Color(red: 0.72, green: 0.45, blue: 1.0), orbDeep: Color(red: 0.25, green: 0.08, blue: 0.45),
        accent: Color(red: 0.72, green: 0.45, blue: 1.0),
        textPrimary: .white, textSecondary: Color.white.opacity(0.55),
        cardFill: Color.white.opacity(0.06), cardActive: Color.white.opacity(0.12), stroke: Color.white.opacity(0.08))

    static let all: [ChappyTheme] = [midnightJade, baliSunset, neonSaigon, reefBlue,
                                     arcticWhite, outbackGold, bladeRunner, heavyMetal,
                                     cyberVolt, deepAmethyst]

    static func named(_ n: String) -> ChappyTheme {
        all.first { $0.name == n } ?? midnightJade
    }
}

// MARK: - Chappy Avatars (the Face's soul — 8 styles, pure code)

enum ChappyAvatar: String, CaseIterable {
    case auto = "Auto (match theme)"
    case classic = "Classic Orb"
    case wisp = "The Wisp"
    case holoCore = "Holo-Core"
    case plasma = "Plasma Heart"
    case mercury = "Liquid Mercury"
    case nebula = "Nebula"
    case sentinel = "Sentinel"
    case jelly = "The Jelly"
    case aurora = "Aurora Flame"

    /// Which avatar actually renders: explicit choice wins, else theme-matched.
    static func resolved(for themeName: String) -> ChappyAvatar {
        let stored = UserDefaults.standard.string(forKey: "chappy_avatar") ?? ChappyAvatar.auto.rawValue
        if let chosen = ChappyAvatar(rawValue: stored), chosen != .auto { return chosen }
        return themeMatch(for: themeName)
    }

    /// The theme's natural avatar, ignoring any explicit choice.
    static func themeMatch(for themeName: String) -> ChappyAvatar {
        switch themeName {
        case "Midnight Jade":  return .wisp
        case "Bali Sunset":    return .plasma
        case "Neon Saigon":    return .aurora
        case "Reef Blue":      return .jelly
        case "Arctic White":   return .holoCore
        case "Outback Gold":   return .mercury
        case "Blade Runner":   return .holoCore
        case "Heavy Metal":    return .mercury
        case "Cyber Volt":     return .sentinel
        case "Deep Amethyst":  return .nebula
        default:               return .classic
        }
    }
}

/// Simple regular polygon for the Sentinel avatar.
struct AvatarPolygon: Shape {
    let sides: Int
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for i in 0..<sides {
            let angle = (Double(i) / Double(sides)) * 2 * .pi - .pi / 2
            let point = CGPoint(x: center.x + radius * cos(angle),
                                y: center.y + radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

struct ChappyAvatarView: View {
    let theme: ChappyTheme
    let live: Bool
    /// When set, renders this exact style (used by the picker previews).
    var forceStyle: ChappyAvatar? = nil
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    @AppStorage("chappy_avatar") private var avatarChoice = ChappyAvatar.auto.rawValue
    @State private var pulse = false
    @State private var spin = false

    private var avatar: ChappyAvatar { forceStyle ?? ChappyAvatar.resolved(for: themeName) }
    /// Live AI running → everything moves ~2x faster (the heartbeat quickens)
    private var tempo: Double { live ? 0.45 : 1.0 }
    private let gold = Color(red: 1.0, green: 0.83, blue: 0.45)

    var body: some View {
        ZStack {
            // Shared breathing halo behind every style
            Circle()
                .fill(RadialGradient(colors: [theme.orbBright.opacity(0.3), .clear],
                                     center: .center, startRadius: 4, endRadius: 60))
                .frame(width: 120, height: 120)
                .scaleEffect(pulse ? 1.16 : 0.88)
                .opacity(pulse ? 0.9 : 0.4)
                .animation(.easeInOut(duration: 2.4 * tempo).repeatForever(autoreverses: true), value: pulse)
            avatarBody
                .shadow(color: theme.orbBright.opacity(live ? 0.8 : 0.35),
                        radius: live ? 18 : 9)
        }
        .frame(width: 96, height: 96)
        // FRESH IDENTITY per style+theme: switching avatar or theme rebuilds
        // this view from scratch, restarting every repeatForever animation.
        // Without this, a newly chosen avatar renders FROZEN.
        .id("avatar-\(avatar.rawValue)-\(theme.name)")
        .onAppear {
            pulse = false; spin = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pulse = true; spin = true
            }
        }
    }

    @ViewBuilder private var avatarBody: some View {
        switch avatar {
        case .wisp: wispView
        case .holoCore: holoCoreView
        case .plasma: plasmaView
        case .mercury: mercuryView
        case .nebula: nebulaView
        case .sentinel: sentinelView
        case .jelly: jellyView
        case .aurora: auroraView
        default: classicView
        }
    }

    // Classic Orb — the original breathing sphere
    private var classicView: some View {
        Circle()
            .fill(RadialGradient(colors: [theme.orbBright, theme.orbDeep],
                                 center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: 34))
            .frame(width: 58, height: 58)
            .scaleEffect(pulse ? 1.06 : 0.96)
            .animation(.easeInOut(duration: 2.4 * tempo).repeatForever(autoreverses: true), value: pulse)
    }

    // The Wisp — silk-smoke ribbons orbiting a golden firefly core
    private var wispView: some View {
        ZStack {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(theme.orbBright.opacity(0.45))
                        .frame(width: 56, height: 13)
                        .blur(radius: 6)
                        .rotationEffect(.degrees(Double(i) * 120))
                }
            }
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 7 * tempo).repeatForever(autoreverses: false), value: spin)
            Circle().fill(gold).frame(width: 11, height: 11).blur(radius: 1.5)
                .scaleEffect(pulse ? 1.25 : 0.85)
                .animation(.easeInOut(duration: 1.6 * tempo).repeatForever(autoreverses: true), value: pulse)
        }
    }

    // Holo-Core — Jarvis rings orbiting a warm core
    private var holoCoreView: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [gold, theme.orbDeep],
                                     center: .center, startRadius: 1, endRadius: 18))
                .frame(width: 26, height: 26)
            Ellipse().stroke(theme.accent.opacity(0.75), lineWidth: 1.3)
                .frame(width: 72, height: 26)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 8 * tempo).repeatForever(autoreverses: false), value: spin)
            Ellipse().stroke(theme.accent.opacity(0.45), lineWidth: 1.1)
                .frame(width: 64, height: 52)
                .rotationEffect(.degrees(60))
                .rotationEffect(.degrees(spin ? -360 : 0))
                .animation(.linear(duration: 11 * tempo).repeatForever(autoreverses: false), value: spin)
            Circle().stroke(theme.accent.opacity(0.3), lineWidth: 1)
                .frame(width: 78, height: 78)
                .scaleEffect(pulse ? 1.04 : 0.97)
                .animation(.easeInOut(duration: 2.4 * tempo).repeatForever(autoreverses: true), value: pulse)
        }
    }

    // Plasma Heart — golden sun with flaring corona rings
    private var plasmaView: some View {
        ZStack {
            Circle().stroke(theme.orbBright.opacity(pulse ? 0.0 : 0.6), lineWidth: 2)
                .frame(width: 50, height: 50)
                .scaleEffect(pulse ? 1.8 : 1.0)
                .animation(.easeOut(duration: 2.0 * tempo).repeatForever(autoreverses: false), value: pulse)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.9, blue: 0.55), gold, theme.orbDeep],
                                     center: .init(x: 0.4, y: 0.35), startRadius: 2, endRadius: 30))
                .frame(width: 50, height: 50)
                .scaleEffect(pulse ? 1.07 : 0.95)
                .animation(.easeInOut(duration: 1.4 * tempo).repeatForever(autoreverses: true), value: pulse)
        }
    }

    // Liquid Mercury — chrome sphere with a sliding highlight
    private var mercuryView: some View {
        Circle()
            .fill(AngularGradient(colors: [Color(white: 0.92), Color(white: 0.45),
                                           Color(white: 0.8), Color(white: 0.3), Color(white: 0.92)],
                                  center: .center))
            .frame(width: 56, height: 56)
            .overlay(
                Circle().fill(RadialGradient(colors: [.white, .clear],
                                             center: .center, startRadius: 1, endRadius: 12))
                    .frame(width: 20, height: 20)
                    .offset(x: pulse ? 12 : -12, y: -13)
                    .animation(.easeInOut(duration: 3.0 * tempo).repeatForever(autoreverses: true), value: pulse)
            )
            .overlay(Circle().fill(theme.accent.opacity(0.16)))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 14 * tempo).repeatForever(autoreverses: false), value: spin)
    }

    // Nebula — swirling cosmic dust around a starlight core
    private var nebulaView: some View {
        ZStack {
            Ellipse().fill(theme.orbBright.opacity(0.35))
                .frame(width: 72, height: 30).blur(radius: 8)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 10 * tempo).repeatForever(autoreverses: false), value: spin)
            Ellipse().fill(theme.accent.opacity(0.3))
                .frame(width: 58, height: 24).blur(radius: 7)
                .rotationEffect(.degrees(45))
                .rotationEffect(.degrees(spin ? -360 : 0))
                .animation(.linear(duration: 7 * tempo).repeatForever(autoreverses: false), value: spin)
            Circle().fill(.white).frame(width: 12, height: 12).blur(radius: 2)
                .scaleEffect(pulse ? 1.3 : 0.9)
                .animation(.easeInOut(duration: 2.0 * tempo).repeatForever(autoreverses: true), value: pulse)
        }
    }

    // Sentinel — counter-rotating geometric guardian
    private var sentinelView: some View {
        ZStack {
            AvatarPolygon(sides: 6)
                .stroke(theme.accent.opacity(0.8), lineWidth: 1.4)
                .frame(width: 58, height: 58)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 9 * tempo).repeatForever(autoreverses: false), value: spin)
            AvatarPolygon(sides: 6)
                .stroke(gold.opacity(0.5), lineWidth: 1)
                .frame(width: 42, height: 42)
                .rotationEffect(.degrees(30))
                .rotationEffect(.degrees(spin ? -360 : 0))
                .animation(.linear(duration: 6 * tempo).repeatForever(autoreverses: false), value: spin)
            Circle().fill(theme.orbBright).frame(width: 9, height: 9)
                .scaleEffect(pulse ? 1.4 : 0.8)
                .animation(.easeInOut(duration: 1.5 * tempo).repeatForever(autoreverses: true), value: pulse)
        }
    }

    // The Jelly — pulsing bell with drifting tendrils
    private var jellyView: some View {
        VStack(spacing: 1) {
            Ellipse()
                .fill(RadialGradient(colors: [theme.orbBright.opacity(0.85), theme.orbDeep.opacity(0.4)],
                                     center: .init(x: 0.5, y: 0.25), startRadius: 2, endRadius: 30))
                .frame(width: 50, height: pulse ? 32 : 40)
                .animation(.easeInOut(duration: 1.8 * tempo).repeatForever(autoreverses: true), value: pulse)
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(theme.orbBright.opacity(0.5))
                        .frame(width: 2.5, height: i % 2 == 0 ? 24 : 18)
                        .rotationEffect(.degrees((pulse ? 7 : -7) * (i % 2 == 0 ? 1 : -1)), anchor: .top)
                        .animation(.easeInOut(duration: 1.8 * tempo).repeatForever(autoreverses: true), value: pulse)
                }
            }
            .blur(radius: 0.5)
        }
    }

    // Aurora Flame — swaying ribbons of light
    private var auroraView: some View {
        HStack(spacing: -9) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient(colors: [theme.orbBright, theme.accent.opacity(0.35), .clear],
                                         startPoint: .bottom, endPoint: .top))
                    .frame(width: 13, height: 62 - CGFloat(i) * 10)
                    .blur(radius: 4.5)
                    .rotationEffect(.degrees((pulse ? 9 : -9) * (i % 2 == 0 ? 1 : -1)), anchor: .bottom)
                    .animation(.easeInOut(duration: (2.2 - Double(i) * 0.3) * tempo)
                        .repeatForever(autoreverses: true), value: pulse)
            }
        }
    }
}

/// Avatar picker — pushed from Settings → Appearance → Avatar.
struct AvatarPickerList: View {
    @AppStorage("chappy_avatar") private var avatarChoice = ChappyAvatar.auto.rawValue
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    var body: some View {
        List(ChappyAvatar.allCases, id: \.rawValue) { a in
            Button {
                avatarChoice = a.rawValue
            } label: {
                HStack(spacing: 14) {
                    // Live animated mini-preview of THIS style in the current theme
                    ZStack {
                        Circle().fill(Color.black)
                        ChappyAvatarView(theme: ChappyTheme.named(themeName), live: false,
                                         forceStyle: a == .auto ? ChappyAvatar.themeMatch(for: themeName) : a)
                            .scaleEffect(0.38)
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    Text(a.rawValue)
                        .foregroundColor(.primary)
                    Spacer()
                    if avatarChoice == a.rawValue {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Chappy Avatar")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Theme picker — pushed from Settings → Appearance → Theme.
struct ThemePickerList: View {
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    var body: some View {
        List(ChappyTheme.all, id: \.name) { t in
            Button {
                themeName = t.name
            } label: {
                HStack(spacing: 14) {
                    Circle()
                        .fill(RadialGradient(colors: [t.orbBright, t.orbDeep],
                                             center: .init(x: 0.35, y: 0.3),
                                             startRadius: 2, endRadius: 16))
                        .frame(width: 32, height: 32)
                        .shadow(color: t.orbBright.opacity(0.6), radius: 5)
                    Text(t.name)
                        .foregroundColor(.primary)
                    Spacer()
                    if themeName == t.name {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Chappy Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - The Face (Phase 4.9) building blocks

struct StatusChip: View {
    let label: String
    let on: Bool
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(on ? theme.accent : theme.textPrimary.opacity(0.25))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundColor(theme.textPrimary.opacity(on ? 0.9 : 0.45))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(theme.cardFill))
    }
}

struct ModeTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let active: Bool
    let action: () -> Void
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(accent)
                Spacer(minLength: 2)
                Text(title)
                    .font(.headline)
                    .foregroundColor(theme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 110)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 20).fill(active ? theme.cardActive : theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(active ? accent.opacity(0.7) : theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct QuickActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }
    var body: some View {
        // Every quick action clicks and taps back. These buttons are pressed
        // one-handed, often without looking — glasses on, walking, phone half
        // out of a pocket — and a flat control that gives you nothing is one
        // you press twice because you can't tell whether the first press
        // landed. Done centrally so no button can be added later and forget.
        Button {
            ChappyEarcon.shared.tap()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(theme.textPrimary.opacity(0.9))
                Text(label)
                    .font(.caption2)
                    .foregroundColor(theme.textPrimary.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.cardFill))
        }
        .buttonStyle(.plain)
    }
}

struct MoreRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(theme.textPrimary.opacity(0.7))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(theme.textPrimary)
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(theme.textPrimary.opacity(0.45))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(theme.textPrimary.opacity(0.3))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.cardFill))
        }
        .buttonStyle(.plain)
    }
}
