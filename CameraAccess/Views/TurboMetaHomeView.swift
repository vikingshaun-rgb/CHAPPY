/*
 * TurboMeta Home View
 * Home — feature entry points
 * Also hosts ContinuousVisionManager: the hands-free Quick Vision loop
 * (kept in this file so no Xcode project changes are needed).
 */

import SwiftUI
import UIKit
import AVFoundation
import AVKit
import Speech
import MapKit
import EventKit

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
    @StateObject private var memory = ChappyMemory.shared
    @State private var showQuickVision = false
    @State private var showLiveTranslate = false
    @State private var showOpenClaw = false
    @State private var showMemory = false
    @State private var showReminders = false
    @State private var cachedReminderLine = ""
    @State private var cachedMemoryLine = ""
    @ObservedObject private var openClawService = OpenClawNodeService.shared

    /// POCKET LAW: arm the wake word, but never on top of a module that owns
    /// the microphone. Every one of these covers is a full-screen session; if
    /// one is up, that module is the thing listening and Standby must stay out
    /// of its way. It re-arms by itself via resumeAfterHandOff when the module
    /// closes, and failing that, the next didBecomeActive catches it.
    /// One line under the Memory row so the store is never a black box:
    /// you can see it filling up without opening it.
    // SPEED FIX (build 109). These two lines filtered the ENTIRE memory array
    // and ran reminder queries every time SwiftUI drew the home screen — and
    // it redraws constantly, because the orb is animating. Hundreds of full
    // passes a second, computing something that changes once an hour.
    //
    // Now computed once when the screen appears and after anything that could
    // change them. Nothing about what you see is different; it just stops
    // doing the work over and over.
    private var remindersDetailLine: String {
        cachedReminderLine.isEmpty
            ? "Say \"Chappy, remind me to…\" — or tap to add"
            : cachedReminderLine
    }

    private var memoryDetailLine: String {
        cachedMemoryLine.isEmpty
            ? "Everything Chappy stores, in one place"
            : cachedMemoryLine
    }

    private func refreshHomeCounts() {
        let od = ChappyReminders.shared.overdue().count
        let t = ChappyReminders.shared.today().count
        if od > 0 { cachedReminderLine = "\(od) overdue · \(t) today" }
        else if t > 0 { cachedReminderLine = "\(t) today · say \"remind me to…\"" }
        else { cachedReminderLine = "Say \"Chappy, remind me to…\" — or tap to add" }

        let all = memory.recent.count
        if all == 0 {
            cachedMemoryLine = "Everything Chappy stores, in one place"
        } else {
            let today = memory.recent.filter { Calendar.current.isDateInToday($0.at) }.count
            cachedMemoryLine = "\(all) stored · \(today) today · searchable"
        }
    }

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
                                    // Straight to Google Maps mid-route, without
                                    // opening Chappy's map first. Chappy keeps
                                    // speaking the turns either way.
                                    Button {
                                        NotificationCenter.default.post(name: .chappyOpenGoogleMaps, object: nil)
                                    } label: {
                                        Label("Google", systemImage: "arrow.triangle.turn.up.right.diamond")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.green)
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
                                // SNAP is now the SILENT one. It used to open
                                // Quick Vision — the identical thing the Look
                                // tile does — so the button had no job of its
                                // own. Photo, quietly described, stored. No
                                // talking: you take it because you want it
                                // later, not to be told about it now.
                                ChappyStandby.shared.snapSilently()
                                journalTick += 1
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
                            // PHASE 5 — the one spot. Sits first because it is
                            // the thing you come back to, not a setting.
                            MoreRow(icon: "bell.badge.fill",
                                    title: "Reminders",
                                    detail: remindersDetailLine) {
                                showReminders = true
                            }
                            MoreRow(icon: "brain",
                                    title: "Memory",
                                    detail: memoryDetailLine) {
                                showMemory = true
                            }
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
            .fullScreenCover(isPresented: $showMemory) {
                MemoryView()
            }
            .fullScreenCover(isPresented: $showReminders) {
                RemindersView()
            }
        }
        // BUILD 103 — THE CAMERA THAT NEVER WOKE UP.
        // snapSilently() posts this when the glasses camera isn't already
        // streaming, which is nearly always — the camera is off during normal
        // use on purpose, for the batteries. Nothing anywhere was listening,
        // so Snap and "take a photo" did precisely nothing and said nothing
        // about it. (The scan equivalent was wired; this one was missed.)
        .onReceive(NotificationCenter.default.publisher(for: .chappyWakeCameraForSnap)) { _ in
            Task { @MainActor in
                await streamViewModel.startSession()
                // WAIT FOR A FRAME, DON'T GUESS AT ONE.
                // A fixed 1.8s sleep was optimistic: the glasses light comes on
                // well before the first frame lands, so the check ran early and
                // Chappy announced the camera wasn't connected while it plainly
                // was. Poll instead — up to eight seconds, giving up only when
                // there really is nothing.
                var frame: UIImage?
                for _ in 0..<27 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if let f = streamViewModel.currentVideoFrame { frame = f; break }
                }
                if let frame {
                    ChappyStandby.shared.completeSilentSnap(frame)
                } else {
                    ChappyEarcon.shared.fail()
                    TTSService.shared.speak("The camera didn't wake up - check the glasses are connected in the Meta app.")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chappyOpenReminders)) { _ in
            showLiveAI = false; showQuickVision = false; showLiveTranslate = false
            showReminders = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .chappyOpenMemory)) { _ in
            showLiveAI = false; showQuickVision = false; showLiveTranslate = false
            showMemory = true
        }
        .onAppear {
            // GPS from app-open (not just Live AI) — journal, Remember and
            // the Map button all need a fix before any session starts
            ContextEngine.shared.start()
            refreshHomeCounts()
            // BUILD 110 — the greeting. Delayed just enough that the reminder
            // and calendar counts are loaded, so it has something true to say.
            // Never blocks: the app is fully usable while it talks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                ChappyStandby.shared.launchGreeting()
            }

            // PHASE 5 — fold the old scattered stores into the one spot. Runs
            // exactly once ever; the old files are left untouched, so a bad
            // migration costs nothing but a flag reset.
            TripRecorder.shared.loadVisualNotes()
            ChappyMemory.shared.migrateLegacyStoresIfNeeded()
            // PHASE 5 — every Live AI conversation ever recorded, folded into
            // the one spot. Free and instant: headline, transcript, and a
            // location recovered from the breadcrumb trail. The AI pass that
            // pulls the durable facts out runs later, on charge.
            ChappyMemory.shared.foldInConversationRecords()

            // PHASE 5.5 — reminders. Permission, re-arm every notification
            // (they are lost on reinstall and after a restore), start the
            // 30-second tick that speaks them while Chappy is running, and
            // give the morning brief if this is the first look of the day.
            ChappyReminders.shared.requestPermission()
            ChappyReminders.shared.startTicking()
            // PHASE 5.5 — the diary. One permission covers iCloud, Outlook,
            // Google and anything else already on the phone.
            ChappyCalendar.shared.requestAccess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                ChappyCalendar.shared.fileFinishedEvents()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                ChappyReminders.shared.rescheduleAll()
                ChappyReminders.shared.morningBriefIfDue()
                // …and the one that is actually useful: tomorrow, tonight,
                // while you can still do something about it.
                ChappyReminders.shared.eveningBriefIfDue()
            }

            // PHASE 5 — anything the glasses captured with Chappy closed.
            // Self-gating: does nothing unless charging, on WiFi, and at
            // least six hours since the last look. Delayed so it never
            // competes with arming the ear at launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                ChappyIngest.shared.runIfConditionsAreRight()
            }
            // Same conditions, same reasoning: reading a hundred old
            // conversations properly is an overnight job, not a launch job.
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                guard ChappyMemory.shared.factsPending > 0,
                      ChappyIngest.onWiFi() else { return }
                UIDevice.current.isBatteryMonitoringEnabled = true
                let charging = UIDevice.current.batteryState == .charging
                            || UIDevice.current.batteryState == .full
                guard charging else { return }
                Task {
                    await ChappyMemory.shared.runFactExtraction()
                    // DREAMING: read yesterday properly and write it up. One
                    // cheap call, once a day, on charge and WiFi.
                    await ChappyMemory.shared.dreamIfDue()
                    ChappyMemory.shared.fileDayRoute()
                }
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .chappyCloseModules)) { _ in
            // Close every cover. Standby gets the ear back via the modules'
            // own resumeAfterHandOff, and the 20s expiry catches any that miss.
            showLiveAI = false; showLiveTranslate = false; showQuickVision = false
            showLiveStream = false; showRTMPStreaming = false; showOpenClaw = false
            showLeanEat = false; showMapSheet = false; showNavMap = false
            ChappyStandby.shared.resumeAfterHandOff()
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
            TTSService.shared.speak("We're already talking. Finish this one first.")
            return
        }
        self.streamViewModel = streamViewModel

        guard streamViewModel.hasActiveDevice else {
            TTSService.shared.speak("I can't find your glasses. They'll need pairing in the Meta app first.")
            return
        }
        // AUDIT FIX: battery guard (Standby had one, this didn't)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let lvl = UIDevice.current.batteryLevel
        if lvl >= 0 && lvl < 0.20 {
            TTSService.shared.speak("You're under twenty percent. Watching would finish it off.")
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
            TTSService.shared.speak("Alright, I'll stop watching.")
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
                TTSService.shared.speak("That's twenty five minutes of watching - I'll stop there to save your battery. Say watch again whenever.")
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
            ZStack(alignment: .bottom) {
                RouteMapView(
                    coords: TripRecorder.shared.crumbs.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    },
                    destination: nil,
                    spots: TripRecorder.shared.spots)
                    .ignoresSafeArea(edges: .bottom)

                // The same escape hatch as the route map: one tap to the real
                // thing, from wherever you happen to be looking.
                Button {
                    NotificationCenter.default.post(name: .chappyOpenGoogleMaps, object: nil)
                } label: {
                    Label("Open in Google Maps", systemImage: "map.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.blue))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
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
            ZStack(alignment: .bottom) {
                RouteMapView(coords: navEngine.routeCoords, destination: navEngine.destinationCoord)
                    .ignoresSafeArea(edges: .bottom)

                // BUILD 90: this map is a PICTURE. It draws the line and
                // nothing else — no lane guidance, no live traffic, no
                // rerouting when you miss a turn. Fine for walking to the
                // shops; not what you want driving to Brisbane airport. One
                // tap hands the same destination to Google Maps already
                // navigating, in the right mode (two-wheeler for a scooter).
                Button {
                    NotificationCenter.default.post(name: .chappyOpenGoogleMaps, object: nil)
                } label: {
                    Label("Turn-by-turn in Google Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.blue))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
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


// =====================================================================
// MARK: - MEMORY BROWSER (PHASE 5 — the reference GUI)
// =====================================================================
//
// One screen, one list, one search box. Everything Chappy has ever stored
// is reachable from here, in the order it happened, with a filter row for
// the nine categories and a card for each memory.
//
// DESIGN RULES, learned from the modules that came before it:
//   · SEARCH IS INSTANT AND OFFLINE. It filters the last 30 days as you type
//     with zero network and zero cost. "Search everything" is a deliberate
//     second tap, because reading a year off disk is not something to do on
//     every keystroke.
//   · NOTHING IS HIDDEN BEHIND A MENU. Filters are visible chips. Sort is
//     always newest-first, because that is what a diary is.
//   · EVERY MEMORY IS A CARD WITH A PLACE AND A TIME. If it has coordinates
//     you can navigate back to it or open it in Google Maps. That is what
//     turns a list into something worth keeping.
//   · IT WORKS ON A PLANE. No screen in here needs the network.

struct MemoryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var memory = ChappyMemory.shared
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @StateObject private var ingest = ChappyIngest.shared
    @State private var searchText = ""
    @State private var selectedKinds: Set<ChappyMemory.Kind> = []
    @State private var pinnedOnly = false
    @State private var deepResults: [ChappyMemory.Entry]?
    @State private var detail: ChappyMemory.Entry?
    @State private var stats: ChappyMemory.Stats?
    @State private var showStats = false
    @State private var exportURL: URL?
    @State private var showExport = false

    private var query: ChappyMemory.Query {
        var q = ChappyMemory.Query()
        q.text = searchText
        q.kinds = selectedKinds
        q.pinnedOnly = pinnedOnly
        return q
    }

    /// Deep results win while they exist; any change to the query clears them,
    /// so the list can never quietly show stale answers to a new question.
    private var results: [ChappyMemory.Entry] {
        if let d = deepResults { return d }
        return memory.search(query)
    }

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [theme.bgTop, theme.bgBottom],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    searchBar
                    suggestionRow
                    filterRow
                    if ingest.isRunning { ingestStrip }
                    if memory.isSearchingDisk { searchingStrip }
                    if deepResults != nil { deepStrip }
                    listBody
                }
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundColor(theme.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            ChappyMemory.shared.stats { s in
                                stats = s; showStats = true
                            }
                        } label: { Label("Storage", systemImage: "internaldrive") }
                        Button {
                            ChappyMemory.shared.exportAll { url in
                                exportURL = url
                                showExport = url != nil
                            }
                        } label: { Label("Export everything", systemImage: "square.and.arrow.up") }
                        Button {
                            Task { await ChappyIngest.shared.run(manual: true) }
                        } label: { Label("Import from the glasses", systemImage: "eyeglasses") }
                        Button {
                            ChappyMemory.shared.reload()
                            deepResults = nil
                        } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(theme.accent)
                    }
                }
            }
        }
        .sheet(item: $detail) { e in
            MemoryDetailView(entry: e, theme: theme)
        }
        .alert("Memory storage", isPresented: $showStats) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(statsMessage)
        }
        .sheet(isPresented: $showExport) {
            if let u = exportURL { ChappyShareSheet(items: [u]) }
        }
    }

    /// Built outside the alert builder — a long string concatenation inside a
    /// ViewBuilder is exactly the shape that makes the type-checker give up
    /// and blame an unrelated line.
    private var statsMessage: String {
        guard let s = stats else { return "Counting…" }
        var out = "\(s.total) memories across \(s.days) days.\n"
        out += "\(s.photos) with photos, \(s.pinned) pinned.\n"
        out += "Using \(ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file)) on this phone."
        if let o = s.oldest {
            out += "\nOldest: " + DateFormatter.localizedString(from: o, dateStyle: .medium, timeStyle: .none)
        }
        return out
    }

    // MARK: Pieces

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(theme.textSecondary)
            TextField("Search your memories", text: $searchText)
                .foregroundColor(theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: searchText) { _ in deepResults = nil }
            if !searchText.isEmpty {
                Button {
                    searchText = ""; deepResults = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.textSecondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.cardFill))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// AUTOFILL FROM YOUR OWN WORDS. Places, people and events you have
    /// actually recorded — not a generic dictionary. Typing three letters of a
    /// warung you saved six weeks ago finishes it for you.
    private var suggestions: [String] {
        let q = searchText.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: .current)
        guard q.count >= 2, deepResults == nil else { return [] }
        var out: [String] = []
        for e in memory.recent {
            for candidate in [e.place, e.street, e.city, e.title].compactMap({ $0 }) {
                let f = candidate.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                          locale: .current)
                guard f.contains(q), candidate.count < 42,
                      !out.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame })
                else { continue }
                out.append(candidate)
                if out.count >= 6 { return out }
            }
        }
        return out
    }

    @ViewBuilder
    private var suggestionRow: some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { searchText = s } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "magnifyingglass").font(.system(size: 9))
                                Text(s).font(.caption).lineLimit(1)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(theme.accent.opacity(0.18)))
                            .foregroundColor(theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 6)
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(label: "All", on: selectedKinds.isEmpty && !pinnedOnly) {
                    selectedKinds.removeAll(); pinnedOnly = false; deepResults = nil
                }
                chip(label: "Pinned", icon: "pin.fill", on: pinnedOnly) {
                    pinnedOnly.toggle(); deepResults = nil
                }
                ForEach(ChappyMemory.Kind.allCases) { k in
                    chip(label: k.label, icon: k.icon, on: selectedKinds.contains(k)) {
                        if selectedKinds.contains(k) { selectedKinds.remove(k) }
                        else { selectedKinds.insert(k) }
                        deepResults = nil
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func chip(label: String, icon: String? = nil,
                      on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let i = icon { Image(systemName: i).font(.caption2) }
                Text(label).font(.caption).fontWeight(.medium)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(on ? theme.accent.opacity(0.25) : theme.cardFill))
            .overlay(Capsule().stroke(on ? theme.accent : Color.clear, lineWidth: 1))
            .foregroundColor(on ? theme.accent : theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var ingestStrip: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text(ingest.progress.isEmpty ? "Reading the glasses captures…" : ingest.progress)
                .font(.caption).foregroundColor(theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.bottom, 6)
    }

    private var searchingStrip: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text("Reading the whole history…")
                .font(.caption).foregroundColor(theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.bottom, 6)
    }

    private var deepStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption).foregroundColor(theme.accent)
            Text("Showing results from all time")
                .font(.caption).foregroundColor(theme.textSecondary)
            Spacer()
            Button("Recent only") { deepResults = nil }
                .font(.caption).foregroundColor(theme.accent)
        }
        .padding(.horizontal, 20).padding(.bottom, 6)
    }

    /// Computed OUTSIDE the ViewBuilder. Result builders can hold local
    /// bindings, but the type-checker times out on big ones and the error it
    /// gives you ("unable to type-check in reasonable time") points at the
    /// wrong line. Cheaper to keep the builder dumb.
    private var groups: [(key: String, day: Date, items: [ChappyMemory.Entry])] {
        memory.grouped(results)
    }

    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(groups, id: \.key) { g in
                        Section {
                            ForEach(g.items) { e in
                                MemoryRow(entry: e, theme: theme)
                                    .contentShape(Rectangle())
                                    .onTapGesture { detail = e }
                            }
                        } header: {
                            dayHeader(g.day, count: g.items.count)
                        }
                    }
                }
                // The second tap: read everything off disk, once, deliberately.
                if deepResults == nil && !query.isEmpty {
                    Button {
                        ChappyMemory.shared.searchEverything(query) { hits in
                            deepResults = hits
                        }
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("Search everything, not just the last 30 days")
                            Spacer()
                        }
                        .font(.footnote)
                        .foregroundColor(theme.accent)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(theme.cardFill))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                Color.clear.frame(height: 40)
            }
            .padding(.top, 4)
        }
    }

    private func dayHeader(_ day: Date, count: Int) -> some View {
        let df = DateFormatter()
        df.dateFormat = "EEEE d MMMM"
        let title = Calendar.current.isDateInToday(day) ? "Today"
                  : (Calendar.current.isDateInYesterday(day) ? "Yesterday"
                     : df.string(from: day))
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Text("\(count)")
                    .font(.caption2).foregroundColor(theme.textSecondary)
            }
            // THE DAY'S HEADLINE. Written locally and free; the AI version
            // (Dreaming) replaces the text later without touching this view.
            Text(ChappyMemory.shared.summary(for: day)
                 ?? ChappyMemory.shared.localSummary(for: day))
                .font(.caption2)
                .foregroundColor(theme.textSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.bgBottom.opacity(0.96))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 40))
                .foregroundColor(theme.textSecondary.opacity(0.5))
            Text(query.isEmpty ? "Nothing stored yet" : "No memories match that")
                .font(.subheadline).foregroundColor(theme.textPrimary)
            Text(query.isEmpty
                 ? "Snap a photo, save a spot or say \"log this\" and it lands here."
                 : "Try fewer words, or search everything below.")
                .font(.caption)
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 40)
    }
}

// MARK: - One row

struct MemoryRow: View {
    let entry: ChappyMemory.Entry
    let theme: ChappyTheme

    private var timeText: String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: entry.at)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if entry.hasPhoto, let img = ChappyMemory.shared.thumbnail(for: entry.id) {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            } else {
                Image(systemName: entry.kind.icon)
                    .font(.system(size: 17))
                    .foregroundColor(theme.accent.opacity(0.85))
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 9).fill(theme.cardFill))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if entry.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9)).foregroundColor(theme.accent)
                    }
                    Text(entry.title)
                        .font(.subheadline)
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(timeText)
                    if let p = entry.place ?? entry.street ?? entry.city {
                        Text("·"); Text(p).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundColor(theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundColor(theme.textSecondary.opacity(0.5))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.cardFill))
        .padding(.horizontal, 16)
    }
}

// MARK: - The card
//
// Every memory carries a time and (usually) a place, so every card can offer
// the two things you actually want six weeks later: take me back there, and
// show me that on the real map.

struct MemoryDetailView: View {
    let entry: ChappyMemory.Entry
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var draftTitle = ""
    @State private var pinned = false
    @State private var confirmDelete = false
    @State private var showOriginal = false
    @State private var askTravel = false
    @State private var toMaps = false
    @State private var region = MKCoordinateRegion()

    private var hasCoords: Bool {
        if let la = entry.lat, let lo = entry.lon { return la != 0 || lo != 0 }
        return false
    }

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [theme.bgTop, theme.bgBottom],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if entry.hasPhoto, let img = ChappyMemory.shared.thumbnail(for: entry.id) {
                            Image(uiImage: img)
                                .resizable().scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }

                        HStack(spacing: 8) {
                            Image(systemName: entry.kind.icon)
                                .foregroundColor(theme.accent)
                            Text(entry.kind.label.uppercased())
                                .font(.caption).fontWeight(.semibold)
                                .foregroundColor(theme.accent)
                            Spacer()
                            Button {
                                pinned.toggle()
                                ChappyMemory.shared.setPinned(id: entry.id, pinned)
                            } label: {
                                Image(systemName: pinned ? "pin.fill" : "pin")
                                    .foregroundColor(pinned ? theme.accent : theme.textSecondary)
                            }
                        }

                        if editing {
                            TextField("Label", text: $draftTitle)
                                .font(.title3)
                                .foregroundColor(theme.textPrimary)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardFill))
                            HStack {
                                Button("Save") {
                                    ChappyMemory.shared.relabel(id: entry.id, to: draftTitle)
                                    editing = false
                                }
                                .foregroundColor(theme.accent)
                                Button("Cancel") { editing = false }
                                    .foregroundColor(theme.textSecondary)
                            }
                        } else {
                            Text(entry.title)
                                .font(.title3).fontWeight(.semibold)
                                .foregroundColor(theme.textPrimary)
                                .onTapGesture { draftTitle = entry.title; editing = true }
                        }

                        if !entry.body.isEmpty {
                            Text(entry.body)
                                .font(.callout)
                                .foregroundColor(theme.textPrimary.opacity(0.85))
                        }

                        Text(fullStamp)
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)

                        if !entry.tags.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(entry.tags, id: \.self) { t in
                                    Text(t)
                                        .font(.caption2)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Capsule().fill(theme.cardFill))
                                        .foregroundColor(theme.textSecondary)
                                }
                            }
                        }

                        if hasCoords {
                            Map(coordinateRegion: $region,
                                annotationItems: [MemoryPin(coord: coord)]) { pin in
                                MapMarker(coordinate: pin.coord, tint: theme.accent)
                            }
                            .frame(height: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .allowsHitTesting(false)

                            // BUILD 103 — ASK, DON'T ASSUME.
                            // Both of these hard-coded walking, so tapping
                            // Google Maps on a memory 76 km away offered a
                            // seventeen-hour walk to Brisbane. A memory card
                            // has no prior route to infer a mode from, and the
                            // standing rule on this project is that the mode
                            // question gets asked rather than guessed.
                            HStack(spacing: 10) {
                                Button {
                                    toMaps = false; askTravel = true
                                } label: {
                                    actionLabel("Take me back", "arrow.uturn.backward")
                                }
                                Button {
                                    toMaps = true; askTravel = true
                                } label: {
                                    actionLabel("Directions", "arrow.triangle.turn.up.right.circle.fill")
                                }
                                Button {
                                    showPlaceOnMaps()
                                } label: {
                                    actionLabel("See the place", "map.fill")
                                }
                            }
                            .confirmationDialog("How are you getting there?",
                                                isPresented: $askTravel,
                                                titleVisibility: .visible) {
                                Button("Walking") { travel("walking") }
                                Button("Scooter or bike") { travel("two-wheeler") }
                                Button("Driving") { travel("driving") }
                                Button("Cancel", role: .cancel) { }
                            } message: {
                                Text(distanceHint)
                            }
                        } else {
                            Text("No location was recorded for this one.")
                                .font(.caption).foregroundColor(theme.textSecondary)
                        }

                        // THE ORIGINAL. Only shown when the memory came from
                        // the photo library, because iOS gives no public way
                        // to open Photos at a specific asset — a button that
                        // just opens Photos to the top of your camera roll is
                        // worse than no button. This loads the real file.
                        if entry.assetID != nil {
                            Button {
                                showOriginal = true
                            } label: {
                                actionLabel(entry.kind == .video ? "Play the video"
                                                                 : "See the full photo",
                                            entry.kind == .video ? "play.circle.fill"
                                                                 : "photo")
                            }
                            Text("The full-resolution file stays in your photo library, ready to post or edit.")
                                .font(.caption2)
                                .foregroundColor(theme.textSecondary)
                        }

                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Forget this")
                                Spacer()
                            }
                            .font(.footnote)
                            .foregroundColor(.red.opacity(0.85))
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardFill))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                    }
                    .padding(18)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(theme.accent)
                }
            }
            .alert("Forget this memory?", isPresented: $confirmDelete) {
                Button("Forget", role: .destructive) {
                    ChappyMemory.shared.forget(id: entry.id)
                    dismiss()
                }
                Button("Keep it", role: .cancel) { }
            } message: {
                Text("This deletes it from the store permanently.")
            }
        }
        .fullScreenCover(isPresented: $showOriginal) {
            OriginalMediaView(assetID: entry.assetID ?? "", title: entry.title, theme: theme)
        }
        .onAppear {
            pinned = entry.pinned
            if hasCoords {
                region = MKCoordinateRegion(center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004))
            }
        }
    }

    private var coord: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: entry.lat ?? 0, longitude: entry.lon ?? 0)
    }

    private var fullStamp: String {
        let df = DateFormatter()
        df.dateFormat = "EEEE d MMMM yyyy, h:mm a"
        var s = df.string(from: entry.at)
        if let p = entry.place ?? entry.street { s += "\n\(p)" }
        if let c = entry.city { s += entry.street == nil ? "\n\(c)" : ", \(c)" }
        if let c = entry.country { s += ", \(c)" }
        return s
    }

    private func actionLabel(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text).font(.caption).fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardFill))
        .foregroundColor(theme.accent)
    }

    /// How far away it is, so the mode question answers itself at a glance.
    /// "17 hr 15 min" was Google's way of telling him the app had guessed
    /// wrong; a distance on the button would have said it first.
    private var distanceHint: String {
        guard hasCoords,
              let la = ContextEngine.shared.snapshot.latitude,
              let lo = ContextEngine.shared.snapshot.longitude
        else { return entry.title }
        let m = TripRecorder.meters(la, lo, entry.lat ?? 0, entry.lon ?? 0)
        if m < 1000 { return "\(entry.title) — about \(Int(m.rounded())) metres away" }
        return String(format: "%@ — about %.1f km away", entry.title, m / 1000)
    }

    private func travel(_ mode: String) {
        if toMaps {
            openInGoogleMaps(mode: mode)
        } else {
            // NavEngine only knows two modes; a scooter routes as driving and
            // Google gets the two-wheeler hint on the handoff.
            NavEngine.shared.navigateBack(to: coord, name: entry.title,
                                          driving: mode != "walking")
            dismiss()
        }
    }

    /// Open Google Maps AT the spot rather than routing to it — for looking at
    /// what's around it, reading reviews, or finding the real business name.
    /// Routing and looking are different questions and deserve different buttons.
    private func showPlaceOnMaps() {
        let lat = entry.lat ?? 0, lon = entry.lon ?? 0
        let label = entry.title.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? "Saved"
        let app = URL(string: "comgooglemaps://?q=\(lat),\(lon)&center=\(lat),\(lon)&zoom=17")
        let web = URL(string: "https://www.google.com/maps/search/?api=1&query=\(lat),\(lon)&query_place_id=&hl=en#\(label)")
        if let a = app, UIApplication.shared.canOpenURL(a) { UIApplication.shared.open(a) }
        else if let w = web { UIApplication.shared.open(w) }
    }

    private func openInGoogleMaps(mode: String) {
        let lat = entry.lat ?? 0, lon = entry.lon ?? 0
        let app = URL(string: "comgooglemaps://?daddr=\(lat),\(lon)&directionsmode=\(mode)")
        let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(lat),\(lon)&travelmode=\(mode)")
        if let a = app, UIApplication.shared.canOpenURL(a) {
            UIApplication.shared.open(a)
        } else if let w = web {
            UIApplication.shared.open(w)
        }
    }
}

struct MemoryPin: Identifiable {
    let id = UUID()
    let coord: CLLocationCoordinate2D
}

// NOTE: the export sheet reuses ChappyShareSheet (LiveTranslateView.swift).
// Declaring a second ShareSheet here would collide with the one
// PhotoPreviewView already owns — a build 57 lesson, not repeated.


// MARK: - The original file
//
// iOS has no public URL that opens Photos at a particular asset, so a
// "open in Photos" button would either do nothing or drop you at the top of
// your camera roll. This loads the real asset instead — full-resolution
// photo, or the actual video playing — straight from the library, without
// ever copying it into Chappy's storage.

struct OriginalMediaView: View {
    let assetID: String
    let title: String
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let p = player {
                VideoPlayer(player: p)
                    .ignoresSafeArea()
                    .onAppear { p.play() }
                    .onDisappear { p.pause() }
            } else if let img = image {
                Image(uiImage: img)
                    .resizable().scaledToFit()
                    .ignoresSafeArea()
            } else if loading {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Fetching the original…")
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                    // iCloud-optimised libraries download on demand, which can
                    // take a moment on a slow connection. Saying so beats a
                    // spinner that looks stuck.
                    Text("If it's stored in iCloud this can take a few seconds.")
                        .font(.caption2).foregroundColor(.white.opacity(0.4))
                }
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34)).foregroundColor(.white.opacity(0.6))
                    Text("Couldn't load the original")
                        .foregroundColor(.white)
                    Text("It may have been deleted from your photo library. The memory is still here.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }

            VStack {
                HStack {
                    Button {
                        player?.pause()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.8))
                            .shadow(radius: 4)
                    }
                    Spacer()
                }
                .padding(18)
                Spacer()
                Text(title)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                    .multilineTextAlignment(.center)
            }
        }
        .task {
            let (img, av) = await ChappyIngest.shared.loadOriginal(assetID: assetID)
            loading = false
            if let av {
                player = AVPlayer(playerItem: AVPlayerItem(asset: av))
            } else if let img {
                image = img
            } else {
                failed = true
            }
        }
    }
}


// =====================================================================
// MARK: - REMINDERS SCREEN (Phase 5.5)
// =====================================================================
//
// Voice sets the simple case; this screen edits the complex one. That split
// is the one honest thing Alexa gets right and it is worth copying: nobody
// wants to say "every second Tuesday at nine except public holidays" out
// loud, and nobody wants to type "remind me to call mum at six".

struct RemindersView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var reminders = ChappyReminders.shared
    @StateObject private var memory = ChappyMemory.shared
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @State private var showAdd = false
    @State private var editing: ChappyMemory.Entry?
    @State private var showDone = false
    @State private var todaysEvents: [EKEvent] = []
    @State private var diaryTick = 0
    @State private var selectedCategory: ChappyReminders.Category? = nil

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [theme.bgTop, theme.bgBottom],
                               startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        briefCard
                        categoryChips
                        diarySection
                        section("Overdue", inFilter(reminders.overdue()), .red)
                        section("Today", inFilter(reminders.today().filter { $0.deliveredAt == nil }), theme.accent)
                        section("Waiting on a place", inFilter(reminders.placeReminders()), .cyan)
                        section("Coming up", reminders.upcoming().filter {
                            !Calendar.current.isDateInToday($0.effectiveFire ?? Date())
                        }, theme.textSecondary)
                        if showDone {
                            section("Done", reminders.done(), theme.textSecondary)
                        } else if !reminders.done().isEmpty {
                            Button("Show \(reminders.done().count) completed") { showDone = true }
                                .font(.footnote).foregroundColor(theme.accent)
                                .padding(.horizontal, 16).padding(.top, 6)
                        }
                        if reminders.open.isEmpty { empty }
                        Color.clear.frame(height: 60)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }.foregroundColor(theme.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill").foregroundColor(theme.accent)
                    }
                }
            }
        }
        .sheet(isPresented: $showAdd) { ReminderEditor(entry: nil, theme: theme) }
        .sheet(item: $editing) { e in ReminderEditor(entry: e, theme: theme) }
        .onAppear {
            ChappyReminders.shared.requestPermission()
            todaysEvents = ChappyCalendar.shared.today().filter {
                ($0.endDate ?? Date()) > Date()
            }
        }
    }

    /// ONE LIST. A thing you have to BE AT and a thing you have to DO are the
    /// same question at 7am — splitting them across two apps is exactly how
    /// one of them gets missed.
    @ViewBuilder
    private var diarySection: some View {
        // SPEED FIX (build 109): this ran a fresh EventKit predicate query on
        // every render. A calendar does not change between two frames of a
        // scroll — fetched once on appear instead.
        let events = todaysEvents
        if !events.isEmpty {
            Text("IN THE DIARY")
                .font(.caption2).fontWeight(.heavy).tracking(0.6)
                .foregroundColor(.purple)
                .padding(.horizontal, 20).padding(.top, 8)
            ForEach(events, id: \.eventIdentifier) { e in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: e.isAllDay ? "calendar" : "clock.badge")
                        .font(.system(size: 17)).foregroundColor(.purple)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            // BUILD 114: the flag says this one is handled —
                            // day before, hour before, and it pierces Focus.
                            if ChappyCalendar.shared.level(for: e) == .important {
                                Image(systemName: "flag.fill")
                                    .font(.system(size: 10)).foregroundColor(.orange)
                            } else if ChappyCalendar.shared.level(for: e) == .muted {
                                Image(systemName: "bell.slash.fill")
                                    .font(.system(size: 10)).foregroundColor(theme.textSecondary)
                            }
                            Text(e.title ?? "Appointment")
                                .font(.subheadline).foregroundColor(theme.textPrimary).lineLimit(2)
                        }
                        HStack(spacing: 6) {
                            Text(e.isAllDay ? "All day" : Self.time(e.startDate))
                            if let l = e.location, !l.isEmpty {
                                Text("·"); Text(l).lineLimit(1)
                            }
                            if let c = e.calendar?.title { Text("·"); Text(c).lineLimit(1) }
                        }
                        .font(.caption2).foregroundColor(theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.cardFill))
                .padding(.horizontal, 16)
                // MARK IT WHERE YOU SEE IT. No second screen, no separate list
                // to maintain — long-press the thing you're already looking at.
                .contextMenu {
                    Button {
                        ChappyCalendar.shared.setLevel(.important, for: e); diaryTick += 1
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: { Label("Important — warn me twice", systemImage: "flag.fill") }
                    Button {
                        ChappyCalendar.shared.setLevel(.normal, for: e); diaryTick += 1
                    } label: { Label("Normal", systemImage: "circle") }
                    Button {
                        ChappyCalendar.shared.setLevel(.muted, for: e); diaryTick += 1
                    } label: { Label("Mute this one", systemImage: "bell.slash") }
                }
            }
            .id(diaryTick)
        }
    }

    private static func time(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
    }

    // BUILD 115 — CATEGORY CHIPS. Derived from where each reminder came from,
    // so you never had to pick one. Only categories that actually have
    // something in them appear — no empty shelves.
    @ViewBuilder
    private var categoryChips: some View {
        let cats = reminders.liveCategories
        if cats.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chipButton(nil, "All", "square.grid.2x2")
                    ForEach(cats, id: \.rawValue) { c in
                        chipButton(c, c.label, c.icon)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 2)
        }
    }

    private func chipButton(_ c: ChappyReminders.Category?, _ label: String, _ icon: String) -> some View {
        let on = (selectedCategory == c)
        return Button {
            selectedCategory = (selectedCategory == c) ? nil : c
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption).fontWeight(.medium)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(on ? theme.accent.opacity(0.25) : theme.cardFill))
            .overlay(Capsule().stroke(on ? theme.accent : Color.clear, lineWidth: 1))
            .foregroundColor(on ? theme.accent : theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    /// Applies the chip filter to any section.
    private func inFilter(_ items: [ChappyMemory.Entry]) -> [ChappyMemory.Entry] {
        guard let c = selectedCategory else { return items }
        return items.filter { ChappyReminders.category(of: $0) == c }
    }

    private var briefCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sun.horizon.fill").foregroundColor(theme.accent)
                Text("Your day").font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button {
                    TTSService.shared.speak(ChappyReminders.shared.briefText())
                } label: {
                    Image(systemName: "speaker.wave.2.fill").foregroundColor(theme.accent)
                }
            }
            Text(ChappyReminders.shared.briefText())
                .font(.caption).foregroundColor(theme.textSecondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.cardFill))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [ChappyMemory.Entry], _ tint: Color) -> some View {
        if !items.isEmpty {
            Text(title.uppercased())
                .font(.caption2).fontWeight(.heavy).tracking(0.6)
                .foregroundColor(tint)
                .padding(.horizontal, 20).padding(.top, 8)
            ForEach(items) { r in
                ReminderRow(entry: r, theme: theme, tint: tint)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = r }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash").font(.system(size: 36))
                .foregroundColor(theme.textSecondary.opacity(0.5))
            Text("Nothing on the list").font(.subheadline).foregroundColor(theme.textPrimary)
            Text("Say \"Chappy, remind me to check in for my flight at six tomorrow\" — or tap plus.")
                .font(.caption).foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity).padding(.top, 50)
    }
}

struct ReminderRow: View {
    let entry: ChappyMemory.Entry
    let theme: ChappyTheme
    let tint: Color

    private var whenText: String {
        if let p = entry.placeTrigger, !p.isEmpty { return "when you're at \(p)" }
        guard let f = entry.effectiveFire else { return "no time set" }
        let cal = Calendar.current, df = DateFormatter()
        if entry.floatingTime != nil { df.dateFormat = "h:mm a" ; return df.string(from: f) + " local, wherever you are" }
        if cal.isDateInToday(f) { df.dateFormat = "'today' h:mm a" }
        else if cal.isDateInTomorrow(f) { df.dateFormat = "'tomorrow' h:mm a" }
        else { df.dateFormat = "EEE d MMM, h:mm a" }
        return df.string(from: f)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if entry.doneAt == nil { ChappyReminders.shared.complete(entry.id) }
                else { ChappyReminders.shared.reopen(entry.id) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: entry.doneAt == nil ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(entry.doneAt == nil ? theme.textSecondary : theme.accent)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline)
                    .foregroundColor(theme.textPrimary)
                    .strikethrough(entry.doneAt != nil)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Image(systemName: entry.placeTrigger?.isEmpty == false ? "mappin" : "clock")
                        .font(.system(size: 9))
                    Text(whenText)
                    if let rule = entry.repeatRule {
                        Text("· \(ChappyReminders.describe(rule: rule))").lineLimit(1)
                    }
                    if entry.escalate == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundColor(.orange)
                    }
                }
                .font(.caption2).foregroundColor(theme.textSecondary)
            }
            Spacer(minLength: 0)
            if entry.doneAt == nil, entry.effectiveFire != nil {
                Menu {
                    Button("Snooze 10 minutes") { ChappyReminders.shared.snooze(entry.id, minutes: 10) }
                    Button("Snooze 1 hour") { ChappyReminders.shared.snooze(entry.id, minutes: 60) }
                    Button("Tomorrow morning") {
                        let cal = Calendar.current
                        let d = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                        ChappyReminders.shared.snooze(entry.id,
                            until: cal.date(bySettingHour: 8, minute: 0, second: 0, of: d))
                    }
                    Divider()
                    Button("Delete", role: .destructive) { ChappyReminders.shared.delete(entry.id) }
                } label: {
                    Image(systemName: "ellipsis").font(.caption)
                        .foregroundColor(theme.textSecondary).frame(width: 30, height: 34)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(tint.opacity(entry.deliveredAt == nil ? 0.0 : 0.0), lineWidth: 1))
        .padding(.horizontal, 16)
        .opacity(entry.doneAt == nil ? 1 : 0.5)
    }
}

/// Create or edit. The complex cases live here on purpose.
struct ReminderEditor: View {
    let entry: ChappyMemory.Entry?
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var mode = 0            // 0 time · 1 floating · 2 place
    @State private var date = Date().addingTimeInterval(3600)
    @State private var floating = Date()
    @State private var place = ""
    @State private var repeatUnit = 0      // 0 none 1 day 2 week 3 month
    @State private var repeatN = 1
    @State private var afterCompletion = false
    @State private var escalate = false
    @State private var leaveBy = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Remind me to…", text: $title, axis: .vertical)
                }
                Section("When") {
                    Picker("", selection: $mode) {
                        Text("Time").tag(0); Text("Every day at").tag(1); Text("Place").tag(2)
                    }.pickerStyle(.segmented)

                    if mode == 0 {
                        DatePicker("Date and time", selection: $date)
                    } else if mode == 1 {
                        DatePicker("Local time", selection: $floating, displayedComponents: .hourAndMinute)
                        Text("Fires at this time wherever you are — it follows you across time zones instead of drifting.")
                            .font(.caption2).foregroundColor(.secondary)
                    } else {
                        TextField("Somewhere — \"supermarket\", \"home\", \"the hotel\"", text: $place)
                        Toggle("Warn me in time to leave", isOn: $leaveBy)
                        if leaveBy {
                            Text("Uses real travel time from where you are, not a fixed countdown.")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                if mode != 2 {
                    Section("Repeat") {
                        Picker("Repeat", selection: $repeatUnit) {
                            Text("Never").tag(0); Text("Daily").tag(1)
                            Text("Weekly").tag(2); Text("Monthly").tag(3)
                        }
                        if repeatUnit > 0 {
                            Stepper("Every \(repeatN)", value: $repeatN, in: 1...30)
                            Toggle("Count from when I do it", isOn: $afterCompletion)
                            Text(afterCompletion
                                 ? "Like laundry — the next one is measured from when you actually tick it off."
                                 : "Like rent — fixed schedule regardless of when you do it.")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                Section {
                    Toggle("Must not be missed", isOn: $escalate)
                    Text("Breaks through Focus and the notification summary.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if entry != nil {
                    Section {
                        Button("Delete", role: .destructive) {
                            if let e = entry { ChappyReminders.shared.delete(e.id) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(entry == nil ? "New reminder" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).count < 2)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let e = entry else { return }
        title = e.title
        escalate = e.escalate ?? false
        if let p = e.placeTrigger, !p.isEmpty { mode = 2; place = p; leaveBy = e.leadMinutes != nil }
        else if let f = e.floatingTime, let hm = ChappyReminders.hhmm(f) {
            mode = 1
            floating = Calendar.current.date(bySettingHour: hm.0, minute: hm.1, second: 0, of: Date()) ?? Date()
        } else if let d = e.dueAt { mode = 0; date = d }
        if let rule = e.repeatRule {
            afterCompletion = rule.hasSuffix("!")
            let r = afterCompletion ? String(rule.dropLast()) : rule
            repeatUnit = ["d": 1, "w": 2, "m": 3][String(r.prefix(1))] ?? 0
            repeatN = Int(r.dropFirst()) ?? 1
        }
    }

    private func save() {
        let rule: String? = {
            guard repeatUnit > 0 else { return nil }
            let u = ["d", "w", "m"][repeatUnit - 1]
            return "\(u)\(repeatN)\(afterCompletion ? "!" : "")"
        }()
        let hhmm: String? = {
            guard mode == 1 else { return nil }
            let c = Calendar.current.dateComponents([.hour, .minute], from: floating)
            return String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)
        }()
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if let e = entry {
            var c = e
            c.title = clean
            c.dueAt = mode == 0 ? date : nil
            c.floatingTime = hhmm
            c.placeTrigger = mode == 2 ? place : nil
            c.repeatRule = rule
            c.leadMinutes = (mode == 2 && leaveBy) ? 5 : nil
            c.escalate = escalate
            c.snoozedTo = nil
            c.deliveredAt = nil
            ChappyMemory.shared.replaceReminderFields(c)
            ChappyReminders.shared.rescheduleAll()
        } else {
            ChappyReminders.shared.add(title: clean,
                                       at: mode == 0 ? date : nil,
                                       floatingTime: hhmm,
                                       place: mode == 2 ? place : nil,
                                       repeatRule: rule,
                                       leadMinutes: (mode == 2 && leaveBy) ? 5 : nil,
                                       escalate: escalate,
                                       source: "typed")
        }
        dismiss()
    }
}
