// ####################################################################
// #                                                                  #
// #   CHAPPY  BUILD 194 MARKER                                       #
// #                                                                  #
// #   IF YOU CAN READ THIS AT THE TOP OF THE FILE IN XCODE,          #
// #   THE FILE IS INSTALLED. IF YOU CANNOT, IT IS NOT.               #
// #                                                                  #
// #   This banner is 300 lines long ON PURPOSE. It pushes every      #
// #   line of real code down by exactly 300. So if the compiler      #
// #   ever reports an error at line 1281 again, that is proof —      #
// #   not a guess — that Xcode is compiling an older copy of this    #
// #   file, because in THIS file line 1281 is 56 characters long   #
// #   and there IS no column 59 on it to complain about.           #
// #                                                                  #
// #   Every home-screen view property in this file now sits at       #
// #   line 1000 or higher. Report the line number you see.           #
// #                                                                  #
// ####################################################################
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
// ---- end of build 194 marker — real code starts on the next line ----
/*
 * TurboMeta Home View
 * Home — feature entry points
 * Also hosts ContinuousVisionManager: the hands-free Quick Vision loop
 * (kept in this file so no Xcode project changes are needed).
 */

import SwiftUI
import UIKit
import Charts   // BUILD 149: trail week chart
import AVFoundation
import AVKit
import Speech
import MapKit
import UserNotifications   // BUILD 163: the permission truth-check
import VisionKit          // BUILD 168: Apple's document scanner
import Vision              // BUILD 168: on-device OCR for scanned pages
import EventKit

// MARK: - BUILD 126: SNAP CONFIRMATION
//
// Snap took a photo and told you nothing. No flash, no shutter, no picture —
// just a glasses light that came on and stayed on, so "it worked" and "it is
// broken" looked and sounded identical. This is the missing half.
//
// Every camera worth using gives you three signals and they are not
// decoration:
//
//   SOUND   fired at the instant of capture, never at the press. That timing
//           is the whole point — hearing it is proof the picture exists.
//   FLASH   a fast white frame. Peripheral vision catches it even when you
//           are looking at the thing you photographed, not at the phone.
//   THE PICTURE ITSELF, briefly. Apple parks it in the thumbnail well;
//           Samsung pops it and lets it fade. Both let you confirm you got
//           the shot without leaving what you were doing.
//
// It lives in its own window rather than in the home view, because a photo
// taken by voice while Live AI or Translate is open would otherwise be
// confirmed underneath a full-screen cover, where you could never see it.

/// Drives the snap confirmation from anywhere in the app.
@MainActor
final class SnapFeedback: ObservableObject {
    static let shared = SnapFeedback()

    @Published var flashOn = false
    @Published var shot: UIImage?
    @Published var caption = ""
    @Published var isWaking = false
    // BUILD 147 — TAP TO ENLARGE. The card opens full screen; tap closes.
    @Published var enlarged: UIImage?
    @Published var enlargedCaption = ""

    func enlarge() {
        guard let s = shot else { return }
        hideWork?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            enlarged = s
            enlargedCaption = caption
            shot = nil
        }
    }

    func closeEnlarged() {
        withAnimation(.easeIn(duration: 0.2)) {
            enlarged = nil
            enlargedCaption = ""
        }
    }

    /// How long the card stays. Long enough to look at, short enough that it
    /// never becomes something you have to dismiss.
    private static let holdSeconds: TimeInterval = 2.6
    private var hideWork: DispatchWorkItem?

    private init() {}

    /// The glasses camera is asleep and is being woken. Shows the waiting
    /// state so the delay reads as a delay.
    func waking() {
        SnapHUD.shared.install()
        hideWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            isWaking = true
            shot = nil
            caption = ""
        }
        // Never leave the spinner up forever — the wake path gives up at about
        // eight seconds and speaks, so this outlives it by a margin and then
        // clears itself no matter what.
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.25)) { self?.isWaking = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    /// A frame genuinely exists. Flash, then hold the picture, then go.
    func captured(_ image: UIImage) {
        SnapHUD.shared.install()
        hideWork?.cancel()

        isWaking = false
        caption = ""
        // The flash is deliberately faster in than out — a real shutter is
        // abrupt at the start and lingers on the eye.
        withAnimation(.linear(duration: 0.05)) { flashOn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            withAnimation(.easeOut(duration: 0.28)) { self?.flashOn = false }
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            shot = image
        }

        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.3)) {
                self?.shot = nil
                self?.caption = ""
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdSeconds, execute: work)
    }

    /// The AI caption lands a second or two after the shutter. If the card is
    /// still up, show it — that is the difference between "a photo" and
    /// "the handwritten warung sign".
    func setCaption(_ text: String) {
        guard shot != nil else { return }
        withAnimation(.easeOut(duration: 0.2)) { caption = text }
    }

    /// Tapped — get out of the way immediately.
    func dismiss() {
        hideWork?.cancel()
        withAnimation(.easeIn(duration: 0.2)) {
            shot = nil
            caption = ""
            isWaking = false
        }
    }
}

/// A window that is invisible to touches except where the overlay actually
/// draws. Without this the whole screen would stop responding while a
/// confirmation was up.
final class SnapPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === rootViewController?.view ? nil : hit
    }
}

@MainActor
final class SnapHUD {
    static let shared = SnapHUD()
    private var window: SnapPassthroughWindow?
    private init() {}

    /// Built on first use and kept. Safe to call on every snap.
    func install() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first else { return }

        let w = SnapPassthroughWindow(windowScene: scene)
        // Above full-screen covers and sheets, below system alerts.
        w.windowLevel = .alert - 1
        w.backgroundColor = .clear
        let host = UIHostingController(rootView: SnapOverlay())
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
        print("📷 [Snap] Confirmation overlay installed")
    }
}

struct SnapOverlay: View {
    @ObservedObject private var feedback = SnapFeedback.shared

    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack {
            // THE FLASH. Ignores touches entirely and covers everything
            // including the status bar, the way a real shutter does.
            Color.white
                .opacity(feedback.flashOn ? 0.92 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // BUILD 147 — THE VIEWER. Full screen, pinch to zoom, caption
            // under, tap anywhere to close.
            if let big = feedback.enlarged {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.94).ignoresSafeArea()
                    Image(uiImage: big)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom)
                        .gesture(MagnificationGesture()
                            .onChanged { zoom = max(1, min(4, $0)) }
                            .onEnded { _ in withAnimation(.spring()) { zoom = 1 } })
                    if !feedback.enlargedCaption.isEmpty {
                        Text(feedback.enlargedCaption)
                            .font(.footnote).foregroundColor(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24).padding(.bottom, 46)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .onTapGesture { zoom = 1; feedback.closeEnlarged() }
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if let shot = feedback.shot {
                        card(shot)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else if feedback.isWaking {
                        wakingCard
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 34)
            }
        }
    }

    private func card(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 132, height: 132)
                .clipped()
            if !feedback.caption.isEmpty {
                Text(feedback.caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(width: 132, alignment: .leading)
            }
        }
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        // BUILD 147: tap opens it big; the little ✕ dismisses.
        .onTapGesture { feedback.enlarge() }
        .overlay(alignment: .topTrailing) {
            Button { feedback.dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(4)
            }
        }
    }

    private var wakingCard: some View {
        HStack(spacing: 9) {
            ProgressView().scaleEffect(0.75).tint(.white)
            Text("Waking the camera")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .allowsHitTesting(false)
    }
}

struct TurboMetaHomeView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var wearablesViewModel: WearablesViewModel
    @StateObject private var quickVisionManager = QuickVisionManager.shared
    @StateObject private var liveAIManager = LiveAIManager.shared
    @StateObject private var continuousVision = ContinuousVisionManager.shared
    @StateObject private var navEngine = NavEngine.shared
    @State private var showNavMap = false
    @State private var pulseOn = false          // BUILD 149: listening rings
    @State private var showCommands = false     // BUILD 149: what can I say
    @State private var showFlights = false      // BUILD 150: the flight deck
    @State private var showAtlas = false        // BUILD 156: the travel atlas
    @State private var atlasTarget: String?
    @State private var atlasLayer: ChappyAtlas.Layer?
    @State private var showDictate = false      // BUILD 157: voice -> clean text
    @State private var showPlaces = false       // BUILD 158: saved places
    @State private var showUpcoming = false     // BUILD 163: the 30-day diary
    @State private var notifsOff = false        // BUILD 163: permission truth
    @State private var showNotifDoctor = false  // BUILD 172
    @State private var showWeather = false      // BUILD 173
    @State private var showTravel = false       // BUILD 177
    @State private var showVisas = false        // BUILD 178
    @State private var showOptions = false      // BUILD 181
    @State private var showIntake = false       // BUILD 181
    @State private var showAtlasMap = false     // BUILD 178
    @State private var showCurrency = false     // BUILD 177
    @State private var showSearch = false       // BUILD 177
    @State private var showBriefs = false       // BUILD 173
    @State private var dictateAutoStart = false
    @AppStorage("chappy_show_advanced") private var showAdvancedTools = false
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

    /// BUILD 144 — the Reader on screen: point the glasses at text, tap the
    /// verb. On-device recognition, free; scans land in Memory.
    private var readerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("READER")
                    .font(.caption2).fontWeight(.heavy).tracking(0.8)
                    .foregroundColor(.cyan)
                Spacer()
                Text("Look at a page, menu or sign first")
                    .font(.caption2).foregroundColor(theme.textSecondary)
            }
            HStack(spacing: 8) {
                readerButton("Read", icon: "text.viewfinder") {
                    TTSService.shared.speak("Reading that now.")
                    ChappyReader.shared.begin(.read)
                }
                readerButton("Translate", icon: "character.book.closed") {
                    TTSService.shared.speak("Having a look.")
                    ChappyReader.shared.begin(.translate)
                }
                readerButton("Scan", icon: "doc.viewfinder") {
                    TTSService.shared.speak("Scanning.")
                    ChappyReader.shared.begin(.scan)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15).fill(.ultraThinMaterial))
        .padding(.horizontal, 16)
    }

    private func readerButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.caption).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.cyan.opacity(0.12)))
            .foregroundColor(.cyan)
        }
        .buttonStyle(.plain)
    }

    // BUILD 145: the adaptive line — real travel time to the next located job.
    @State private var leaveByLine: String?

    /// BUILD 140 — the day at a glance, on the home screen. Events and timed
    /// reminders merged, next three, soonest first. Tap opens the Diary.
    private var todayGlanceCard: some View {
        let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
        let now = Date()
        var rows: [(at: Date, icon: String, tint: Color, text: String)] = []
        for e in ChappyCalendar.shared.today() where !e.isAllDay {
            if let s = e.startDate, (e.endDate ?? s) > now {
                rows.append((s, "calendar", .purple, "\(e.title ?? "Appointment") · \(df.string(from: s))"))
            }
        }
        for r in ChappyReminders.shared.today() where r.deliveredAt == nil && r.doneAt == nil {
            if let f = r.effectiveFire, f > now {
                rows.append((f, "bell.fill", theme.accent, "\(r.title) · \(df.string(from: f))"))
            }
        }
        let next = rows.sorted { $0.at < $1.at }.prefix(3)
        let od = ChappyReminders.shared.overdue().count

        return Button { showReminders = true } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("TODAY")
                        .font(.caption2).fontWeight(.heavy).tracking(0.8)
                        .foregroundColor(theme.accent)
                    Spacer()
                    if od > 0 {
                        Text("\(od) overdue")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.red)
                            .contentTransition(.numericText())
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11)).foregroundColor(theme.textSecondary)
                }
                if let lb = leaveByLine {
                    HStack(spacing: 6) {
                        Image(systemName: "car.fill")
                            .font(.system(size: 10)).foregroundColor(.orange)
                        Text(lb).font(.caption).fontWeight(.semibold)
                            .foregroundColor(.orange).lineLimit(2)
                    }
                }
                if next.isEmpty {
                    Text("Nothing left on today.")
                        .font(.subheadline).foregroundColor(theme.textSecondary)
                    // BUILD 155 — today's done? Show what's coming, the way
                    // Google's at-a-glance and Apple's calendar widget do.
                    let ahead = ChappyCalendar.shared.upcoming(days: 3)
                        .filter { !$0.isAllDay && !($0.startDate.map { Calendar.current.isDateInToday($0) } ?? false) }
                        .prefix(2)
                    ForEach(Array(ahead.enumerated()), id: \.offset) { _, e in
                        if let s = e.startDate {
                            HStack(spacing: 8) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 11)).foregroundColor(.purple)
                                    .frame(width: 16)
                                Text("\(e.title ?? "Appointment") · \(Self.aheadStamp(s))")
                                    .font(.subheadline).foregroundColor(theme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                } else {
                    ForEach(Array(next.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            Image(systemName: row.icon)
                                .font(.system(size: 11)).foregroundColor(row.tint)
                                .frame(width: 16)
                            Text(row.text)
                                .font(.subheadline).foregroundColor(theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 15).fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    /// BUILD 155 — "Tomorrow 9:00 AM" / "Thursday 2:30 PM" for the look-ahead.
    private static func aheadStamp(_ d: Date) -> String {
        let t = DateFormatter(); t.dateFormat = "h:mm a"
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow \(t.string(from: d))" }
        let day = DateFormatter(); day.dateFormat = "EEEE"
        return "\(day.string(from: d)) \(t.string(from: d))"
    }

    /// BUILD 173 — live conditions on the tile face, so the common question
    /// is answered without opening anything.
    /// BUILD 177: the tile says what the trip IS, not what the screen is
    /// called — a tile reading "Travel Desk / plan trips" is a label, and a
    /// tile reading "Bali - 14 nights, $4,180" is information.
    /// BUILD 178: the tile leads with the PROBLEM when there is one. A
    /// visa overrun found on a home screen three months out is a fixable
    /// annoyance; found at a check-in desk it is a cancelled trip.
    private var visaDetailLine: String {
        guard let t = ChappyTravel.shared.active, !t.legs.isEmpty else {
            return "What an Australian passport gets, anywhere"
        }
        let pos = ChappyVisa.shared.positions(for: t)
        if let bad = pos.first(where: { $0.over }) {
            return "\(bad.country): \(bad.days) days but you get \(bad.allowance)"
        }
        if let act = pos.first(where: { $0.shape.needsActionBeforeFlying }) {
            return "\(act.country) needs sorting before you fly"
        }
        if pos.isEmpty { return "What an Australian passport gets, anywhere" }
        return "\(pos.count) \(pos.count == 1 ? "country" : "countries") — all inside the limit"
    }

    private var travelDetailLine: String {
        guard let t = ChappyTravel.shared.active, !t.legs.isEmpty else {
            return "Plan, cost and map a whole trip"
        }
        let c = ChappyTravel.shared.cost(t)
        var s = "\(t.name) \u{2014} \(t.nights) \(t.nights == 1 ? "night" : "nights")"
        if c.total > 0 { s += ", \(ChappyFX.money(c.total, t.homeCurrency))" }
        return s
    }

    private var weatherDetailLine: String {
        guard let n = ChappyWeather.shared.now else {
            return "Wind, rain, UV, pressure — 7 days ahead"
        }
        var s = "\(Int(n.tempC.rounded()))° \(ChappyWeather.describe(n.code))"
        if let d = ChappyWeather.shared.days.first, d.rainChance >= 30 {
            s += " · \(d.rainChance)% rain"
        }
        return s
    }

    /// BUILD 163 — the next thing, on the tile, so the week is visible
    /// without opening anything.
    private var upcomingDetailLine: String {
        let ev = ChappyCalendar.shared.upcoming(days: 30)
        guard let next = ev.first, let s = next.startDate else {
            return "Your calendar and reminders, 30 days ahead"
        }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(s) ? "h:mm a"
            : (Calendar.current.isDateInTomorrow(s) ? "'Tomorrow' h:mm a" : "EEE h:mm a")
        return "Next: \(next.title ?? "Appointment") · \(f.string(from: s))"
    }

    /// BUILD 158 — how many places, and how many still need a name.
    /// BUILD 191: this was an immediately-invoked closure inline in the
    /// tile's `detail:` argument — a filter, a count and a nested ternary
    /// dropped into the middle of a view body that already had thirty
    /// tiles in it. The type checker gave up on the whole body. Hoisted,
    /// exactly like placesDetailLine below it, which is the pattern that
    /// existed for this reason.
    private var flightsDetailLine: String {
        let n = ChappyWatch.shared.watches.filter { $0.kind == .route }.count
        if n == 0 { return "Segments, bags, price journal" }
        return "\(n) route\(n == 1 ? "" : "s") watched"
    }

    private var placesDetailLine: String {
        let all = TripRecorder.shared.spots
        guard !all.isEmpty else { return "Everywhere you've pinned — tap Remember to add" }
        let unnamed = all.filter { $0.name.lowercased().hasPrefix("spot at") }.count
        if unnamed > 0 { return "\(all.count) saved · \(unnamed) need a name" }
        return "\(all.count) saved · notes, arrival alerts, pings"
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

        // BUILD 145 — THE LEAVE-BY LINE. For the next appointment that has an
        // address, work out REAL travel time from where the phone is right
        // now: "Leave by 2:20 for the 3pm — about 34 min away." Recomputed on
        // every home refresh; one route lookup, only when there is something
        // to say.
        leaveByLine = nil
        if let next = ChappyCalendar.shared.today().first(where: { e in
            guard !e.isAllDay, let s = e.startDate, s > Date(),
                  let loc = e.location, !loc.isEmpty else { return false }
            return s.timeIntervalSinceNow < 6 * 3600
        }), let start = next.startDate, let loc = next.location {
            Task {
                guard let mins = await NavEngine.shared.travelMinutes(to: loc) else { return }
                let leave = start.addingTimeInterval(-Double(mins + 10) * 60)
                let f = DateFormatter(); f.dateFormat = "h:mm a"
                if leave > Date() {
                    leaveByLine = "Leave by \(f.string(from: leave)) for \(next.title ?? "the next one") — about \(mins) min away"
                } else {
                    leaveByLine = "⚠︎ \(next.title ?? "Next job") is about \(mins) min away — time to move"
                }
            }
        }

        let all = memory.recent.count
        if all == 0 {
            cachedMemoryLine = "Everything Chappy stores, in one place"
        } else {
            let today = memory.recent.filter { Calendar.current.isDateInToday($0.at) }.count
            cachedMemoryLine = "\(all) stored · \(today) today · searchable"
        }
    }

    /// BUILD 163 — ask iOS the truth about notifications, and if they are
    /// off, request them once; only show the banner if that request is
    /// refused or was already permanently denied.
    private func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { notifsOff = false }
            case .notDetermined:
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive]) { ok, _ in
                        DispatchQueue.main.async { notifsOff = !ok }
                    }
            default:
                DispatchQueue.main.async { notifsOff = true }
            }
        }
    }

    private func armStandbyIfClear(reason: String) {
        // BUILD 160: showDictate was missing — and Dictate is the one new
        // screen that OWNS the microphone. Arming into it meant two
        // recognisers fighting over one mic, which is a very effective way
        // to make both of them deaf.
        guard !showLiveAI, !showLiveTranslate, !showQuickVision,
              !showLiveStream, !showRTMPStreaming, !showOpenClaw, !showLeanEat,
              !showDictate
        else {
            print("👂 [Standby] Auto-arm skipped (\(reason)) — a module is on screen")
            return
        }
        ChappyStandby.shared.autoArmIfWanted(reason: reason)
    }

    // ================================================================
    // BUILD 192 — THE CHAIN THAT BROKE THE TYPE CHECKER.
    //
    // "The compiler is unable to type-check this expression in
    // reasonable time." Forty-five modifiers hung off one ZStack, and
    // each one rewrites the expression's type, so Swift was solving a
    // forty-five-deep inference problem in one pass. It had been at the
    // limit for several builds; the Flights sheet in 190 tipped it over.
    //
    // Each computed property below returns `some View`, and an opaque
    // return type is an inference boundary — the checker solves each
    // piece and then forgets how it got there. Four small problems
    // instead of one enormous one. The modifiers still apply in the
    // same order to the same view; nothing about the screen changes.
    // ================================================================
    // ================================================================
    // BUILD 193 — BREAK UP THE BODY, NOT JUST THE MODIFIERS.
    //
    // 192 split the forty-five-modifier chain and the checker still
    // gave up, because the chain was only half of it. The ZStack held
    // a ScrollView holding a VStack with ten children, two of them
    // LazyVGrids of thirty-odd tiles, every tile carrying closures,
    // ternaries and colour expressions. ViewBuilder's ten-argument
    // buildBlock had to infer all of that in ONE constraint system.
    //
    // Each child is now its own `some View` property. An opaque type
    // is a wall the solver cannot see through: it solves each block
    // alone, then treats it as one settled type when it assembles the
    // VStack. Same views, same order, same modifiers — the screen is
    // byte-for-byte what it was.
    // ================================================================

    /// BUILD 193: The avatar, its listening pulse and the greeting line.
    private var orbHeader: some View {
                        VStack(spacing: 8) {
                            // THE AVATAR — Chappy's living face. Eight styles,
                            // theme-matched by default, chosen in Settings →
                            // Appearance → Avatar. Pure code: GPU-composited,
                            // home-screen only, zero cost to the AI pipeline.
                            // BUILD 149 — THE LISTENING PULSE. While a command
                            // is being taken, rings radiate from the avatar —
                            // visible proof Chappy is hearing you, Siri-style.
                            ZStack {
                                if standby.awake {
                                    ForEach(0..<2, id: \.self) { i in
                                        Circle()
                                            .stroke(theme.accent.opacity(0.5), lineWidth: 2)
                                            .frame(width: 96, height: 96)
                                            .scaleEffect(pulseOn ? 1.55 : 1.0)
                                            .opacity(pulseOn ? 0 : 0.7)
                                            .animation(.easeOut(duration: 1.1)
                                                .repeatForever(autoreverses: false)
                                                .delay(Double(i) * 0.55), value: pulseOn)
                                    }
                                }
                                ChappyAvatarView(theme: theme, live: liveAIManager.isRunning)
                            }
                            .onChange(of: standby.awake) { _, on in pulseOn = on }
                            // BUILD 148 — THE WORDMARK. SF Rounded heavy with
                            // the theme's own colour poured through the
                            // letters. The name finally dresses like the app.
                            Text("Chappy")
                                .font(.system(size: 34, weight: .heavy, design: .rounded))
                                .tracking(0.5)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [theme.accent, theme.textPrimary],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                                .shadow(color: theme.accent.opacity(0.35), radius: 12, y: 2)
                            Text(liveAIManager.isRunning ? "Listening — just talk"
                                 : (continuousVision.isRunning ? "Watching — say chappy stop to end"
                                    : "Ready when you are"))
                                .font(.subheadline)
                                .foregroundColor(theme.textSecondary)
                        }
                        .padding(.top, 18)
    }

    /// BUILD 193: The thin row of state chips under the header.
    private var statusStrip: some View {
                        HStack(spacing: 8) {
                            StatusChip(label: "Glasses", on: streamViewModel.hasActiveDevice)
                            StatusChip(label: "Camera", on: streamViewModel.streamingStatus == .streaming)
                            StatusChip(label: "Live AI", on: liveAIManager.isRunning)
                            StatusChip(label: "Standby", on: standby.isListening)
                        }
    }

    /// BUILD 193: The turn-by-turn card. Only on screen while navigating, so it is
    /// a bare `if` and needs @ViewBuilder.
    @ViewBuilder
    private var navCard: some View {
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
                            .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.5), lineWidth: 1))
                            .sheet(isPresented: $showNavMap) {
                                NavMapSheet(navEngine: navEngine)
                            }
                        }
    }

    /// BUILD 193: The four big mode buttons.
    private var modeStack: some View {
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
    }

    /// BUILD 193: The small three-across action grid — Ear On and friends.
    private var actionGrid: some View {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 9),
                                            GridItem(.flexible(), spacing: 9),
                                            GridItem(.flexible(), spacing: 9),
                                            GridItem(.flexible(), spacing: 9)],
                                  spacing: 9) {
                            QuickActionButton(icon: "camera.fill", label: "Snap",
                                              tint: Color(red: 0.35, green: 0.85, blue: 1.0)) {
                                ChappyStandby.shared.snapSilently()
                                journalTick += 1
                            }
                            // HOLD Snap for the burst: ~20 frames sampled,
                            // sharpest kept. Apple/Top-Shot style.
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                    ChappyBurst.shared.fire()
                                    journalTick += 1
                                })
                            QuickActionButton(icon: "video.fill", label: "Video",
                                              tint: Color(red: 1.0, green: 0.42, blue: 0.55)) {
                                TTSService.shared.speak("Rolling - about twenty seconds.")
                                ChappyClip.shared.record()
                                journalTick += 1
                            }
                            QuickActionButton(icon: "mic.fill", label: "Dictate",
                                              tint: Color(red: 0.98, green: 0.55, blue: 0.35)) {
                                dictateAutoStart = true
                                showDictate = true
                            }
                            QuickActionButton(icon: "mappin.circle.fill", label: "Remember",
                                              tint: Color(red: 1.0, green: 0.68, blue: 0.25)) {
                                ChappyStandby.shared.rememberSpotByVoice()
                                journalTick += 1
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            }
                            QuickActionButton(icon: continuousVision.isRunning ? "eye.slash.fill" : "eye.fill",
                                              label: continuousVision.isRunning ? "Stop" : "Watch",
                                              tint: Color(red: 0.85, green: 0.45, blue: 1.0),
                                              active: continuousVision.isRunning) {
                                if continuousVision.isRunning {
                                    continuousVision.stop()
                                } else {
                                    if standby.isListening { standby.handOff() }
                                    continuousVision.start(streamViewModel: streamViewModel)
                                }
                            }
                            QuickActionButton(icon: standby.isListening ? "ear.fill" : "ear",
                                              label: standby.isListening ? "Ear On" : "Standby",
                                              tint: Color(red: 0.35, green: 0.95, blue: 0.70),
                                              active: standby.isListening) {
                                standby.toggle()
                            }
                            QuickActionButton(icon: "map.fill", label: "Map",
                                              tint: Color(red: 0.45, green: 0.65, blue: 1.0)) {
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
    }

    /// BUILD 193: Today's journal counts. Tap opens the Diary.
    private var journalRow: some View {
                        HStack {
                            Image(systemName: "book.closed.fill")
                                .foregroundColor(theme.textSecondary)
                            Text("Today: \(TripRecorder.shared.crumbs.count) points · \(TripRecorder.shared.spots.filter { Calendar.current.isDateInToday($0.t) }.count) spots · \(TripRecorder.shared.notes.count) notes")
                                .font(.footnote)
                                .foregroundColor(theme.textSecondary)
                            Spacer()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                        .id(journalTick) // refresh counts when Remember fires
    }

    /// BUILD 193: BUILD 163's "your notifications are off" banner — a bare `if`,
    /// so it needs @ViewBuilder too.
    @ViewBuilder
    private var notifBanner: some View {
                        if notifsOff {
                            Button {
                                // BUILD 172: the doctor first — it shows WHY,
                                // and iOS Settings is one tap from there.
                                showNotifDoctor = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "bell.slash.fill")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Notifications are off")
                                            .font(.subheadline).fontWeight(.semibold)
                                            .foregroundColor(theme.textPrimary)
                                        Text("Reminders, warn times and flight alerts can't reach you. Tap to turn them on.")
                                            .font(.caption2)
                                            .foregroundColor(theme.textSecondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2).foregroundColor(theme.textSecondary)
                                }
                                .padding(13)
                                .background(RoundedRectangle(cornerRadius: 15)
                                    .fill(Color.orange.opacity(0.14)))
                                .overlay(RoundedRectangle(cornerRadius: 15)
                                    .stroke(Color.orange.opacity(0.5), lineWidth: 1))
                            }
                            .buttonStyle(ChappyPressStyle())
                            .padding(.horizontal, 16)
                        }
    }

    /// BUILD 193: The two-column colour-coded tile grid — the largest single
    /// expression on the screen, and the main reason the type
    /// checker was timing out.
    // ================================================================
    // BUILD 199 — THE WALL COMES DOWN.
    //
    // Twenty tiles in one grid, under four mode buttons, seven quick
    // actions, a journal row and two cards. Everything equally loud,
    // nothing aware of the time or the place.
    //
    // The fix the good ones use is not fewer tiles. It is one live
    // thing at the top and everything else demoted — Google leads
    // with a field, Apple with a couple of cards that change, Samsung
    // sections everything so your thumb finds a group rather than an
    // icon. First screenful goes from twenty-plus targets to about
    // eight, and the ones that survive are the ones that change.
    //
    // Every tile body below is the one that was already there, moved
    // and not rewritten. This file has defeated the type checker
    // twice; a redesign is not the moment to also retype it.
    // ================================================================

    /// The one card that earns the top of the screen: what the
    /// weather is doing, what is next, and what trip is open. All
    /// three lines already existed as tile subtitles — they were just
    /// buried among nineteen others.
    private var nowCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Now")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundColor(theme.textSecondary)
                    .tracking(1.1)
                Spacer()
            }
            nowLine("cloud.sun.fill", weatherDetailLine)
            nowLine("calendar", upcomingDetailLine)
            nowLine("map.fill", travelDetailLine)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.accent.opacity(0.22), lineWidth: 1)
        )
    }

    private func nowLine(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(theme.accent)
                .frame(width: 18)
            Text(text)
                .font(.footnote)
                .foregroundColor(theme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    /// A group header. Tapping one closes whatever else was open —
    /// one section at a time is the whole point; two open sections is
    /// just the wall again with lines drawn on it.
    private func groupHeader(_ id: String, _ title: String,
                             _ icon: String, _ count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                openGroup = (openGroup == id) ? "" : id
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.accent)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.textSecondary)
                Spacer()
                Image(systemName: openGroup == id ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.textSecondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }

    private var group_travel: some View {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 11),
                                            GridItem(.flexible(), spacing: 11)],
                                  spacing: 11) {
                            ChappyTile(icon: "map.fill", title: "Travel Desk",
                                       detail: travelDetailLine,
                                       tint: Color(red: 0.42, green: 0.86, blue: 0.62)) {
                                showTravel = true
                            }
                            ChappyTile(icon: "airplane", title: "Flights",
                                       detail: flightsDetailLine,
                                       tint: Color(red: 0.30, green: 0.75, blue: 1.0)) {
                                showFlights = true
                            }
                            ChappyTile(icon: "globe.asia.australia.fill", title: "Visas",
                                       detail: visaDetailLine,
                                       tint: Color(red: 0.98, green: 0.55, blue: 0.42)) {
                                showVisas = true
                            }
                            ChappyTile(icon: "dollarsign.arrow.circlepath", title: "Currency",
                                       detail: "Convert anything, works offline",
                                       tint: Color(red: 0.96, green: 0.80, blue: 0.35)) {
                                showCurrency = true
                            }
                            ChappyTile(icon: "globe.asia.australia.fill", title: "Atlas",
                                       detail: ChappyAtlas.shared.summary.isEmpty
                                            ? "Everywhere you've been, mapped"
                                            : ChappyAtlas.shared.summary,
                                       tint: Color(red: 0.35, green: 0.85, blue: 1.0)) {
                                atlasTarget = nil; atlasLayer = nil
                                showAtlas = true
                            }
                            ChappyTile(icon: "mappin.and.ellipse", title: "Places",
                                       detail: placesDetailLine,
                                       tint: Color(red: 1.0, green: 0.68, blue: 0.25)) {
                                showPlaces = true
                            }
                            // AUDIT: the subtitle counted ChappyFlights.watches
                            // (the 176 status store) while the tile now opens a
                            // screen backed by ChappyWatch.watches. Two separate
                            // stores — so it could read "3 routes watched" and
                            // then show you nothing.
                        }
    }

    private var group_day: some View {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 11),
                                            GridItem(.flexible(), spacing: 11)],
                                  spacing: 11) {
                            ChappyTile(icon: "book.closed.fill", title: "Diary",
                                       detail: remindersDetailLine,
                                       tint: Color(red: 0.68, green: 0.5, blue: 1.0)) {
                                showReminders = true
                            }
                            ChappyTile(icon: "calendar", title: "Upcoming",
                                       detail: upcomingDetailLine,
                                       tint: Color(red: 0.72, green: 0.55, blue: 1.0)) {
                                showUpcoming = true
                            }
                            ChappyTile(icon: "brain", title: "Memory",
                                       detail: memoryDetailLine,
                                       tint: Color(red: 0.55, green: 0.45, blue: 1.0)) {
                                showMemory = true
                            }
                            ChappyTile(icon: "mic.fill", title: "Dictate",
                                       detail: "Talk it out — get clean, professional text",
                                       tint: Color(red: 1.0, green: 0.42, blue: 0.55)) {
                                dictateAutoStart = false
                                showDictate = true
                            }
                        }
    }

    private var group_ask: some View {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 11),
                                            GridItem(.flexible(), spacing: 11)],
                                  spacing: 11) {
                            ChappyTile(icon: "magnifyingglass.circle.fill", title: "Look it up",
                                       detail: "Search the web \u{2014} spoken, with sources",
                                       tint: Color(red: 0.68, green: 0.60, blue: 0.98)) {
                                showSearch = true
                            }
                            ChappyTile(icon: "cloud.sun.fill", title: "Weather",
                                       detail: weatherDetailLine,
                                       tint: Color(red: 0.35, green: 0.78, blue: 1.0)) {
                                showWeather = true
                            }
                            // BUILD 177 — the Travel Desk, the converter
                            // and the web look-up.
                            ChappyTile(icon: "questionmark.bubble.fill", title: "What can I say?",
                                       detail: "Every voice command, searchable",
                                       tint: Color(red: 0.25, green: 0.85, blue: 0.72)) {
                                showCommands = true
                            }
                            ChappyTile(icon: "sun.horizon.fill", title: "Briefs",
                                       detail: "How your daily brief is built — and when",
                                       tint: Color(red: 1.0, green: 0.72, blue: 0.35)) {
                                showBriefs = true
                            }
                        }
    }

    private var group_setup: some View {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 11),
                                            GridItem(.flexible(), spacing: 11)],
                                  spacing: 11) {
                            ChappyTile(icon: "bell.badge.fill", title: "Notifications",
                                       detail: notifsOff ? "OFF — tap to see why"
                                                         : "Check what iOS is holding or hiding",
                                       tint: notifsOff ? Color(red: 1.0, green: 0.55, blue: 0.2)
                                                       : Color(red: 0.35, green: 0.95, blue: 0.70)) {
                                showNotifDoctor = true
                            }
                            ChappyTile(icon: "cross.circle.fill", title: "Emergency",
                                       detail: emergencyContactText.isEmpty
                                            ? "Set the WhatsApp number" : "Saved — tap to change",
                                       tint: Color(red: 1.0, green: 0.35, blue: 0.38)) {
                                showEmergencyContact = true
                            }
                            ChappyTile(icon: "link.circle.fill", title: "OpenClaw",
                                       detail: openClawService.connectionState == .connected
                                            ? "Connected" : "Home computer bridge",
                                       tint: Color(red: 0.55, green: 0.62, blue: 0.72)) {
                                showOpenClaw = true
                            }
                            // The old experimental tools, only when asked for.
                            if showAdvancedTools {
                                ChappyTile(icon: "antenna.radiowaves.left.and.right",
                                           title: "RTMP", detail: "Experimental streaming",
                                           tint: .gray) { showRTMPStreaming = true }
                                ChappyTile(icon: "video.fill", title: "Screen Stream",
                                           detail: "Record and stream",
                                           tint: .gray) { showLiveStream = true }
                                ChappyTile(icon: "chart.bar.fill", title: "LeanEat",
                                           detail: "Food analysis",
                                           tint: .gray) { showLeanEat = true }
                            }
                        }
    }

    /// What used to be the wall. Same tiles, same actions, same
    /// colours — sorted, and mostly folded away.
    private var tileGrid: some View {
        VStack(spacing: 10) {
            nowCard
            groupHeader("travel", "Travel", "airplane", 6)
            if openGroup == "travel" { group_travel }
            groupHeader("day", "Your day", "sun.max.fill", 4)
            if openGroup == "day" { group_day }
            groupHeader("ask", "Ask", "questionmark.circle.fill", 4)
            if openGroup == "ask" { group_ask }
            groupHeader("setup", "Set up", "gearshape.fill", 3 + (showAdvancedTools ? 3 : 0))
            if openGroup == "setup" { group_setup }
        }
        .padding(.bottom, 30)
    }

    private var homeStack: some View {
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
                        orbHeader

                        // STATUS STRIP
                        statusStrip

                        // NAVIGATION CARD — appears only while navigating
                        navCard

                        // THE FOUR MODES
                        modeStack

                        // QUICK ACTIONS — BUILD 162: a wrapping grid, not a
                        // cramped single row. Seven actions never fitted
                        // across one line on a phone; now they breathe, each
                        // in its own colour, and Ear On lights up when live.
                        actionGrid

                        // TODAY — journal glance
                        journalRow

                        // BUILD 163 — WHY YOUR NOTIFICATIONS WENT MISSING.
                        //
                        // Every ping, warn time and flight alert in Chappy
                        // goes through iOS notifications. If permission was
                        // never granted — or was granted once and later
                        // switched off, or Focus is eating them — the app has
                        // no way to tell you and everything just silently
                        // stops. That is indistinguishable from "the feature
                        // is broken", which is exactly how it felt.
                        //
                        // So: check on every appearance, and if they're off,
                        // SAY SO, right here, with the button that fixes it.
                        notifBanner

                        // BUILD 140 — THE GLANCE. The day, on the home screen,
                        // before you've opened anything: next events, next
                        // reminders, one line of counts. Tap = the full Diary.
                        todayGlanceCard.chappyScrollFX()

                        // BUILD 144 — THE READER, FINALLY VISIBLE. It shipped
                        // voice-only in 134 and nobody could find it. Three
                        // buttons now: look at the thing, tap the verb.
                        readerCard.chappyScrollFX()

                        // BUILD 157 — THE TILE GRID. Nine identical grey rows
                        // became a two-column grid of colour-coded tiles, each
                        // with its own hue, glowing icon chip and gradient
                        // edge. Apple's Control Center and Samsung's One UI
                        // both proved the same thing: the eye finds a colour
                        // faster than it reads a word, and a grid halves the
                        // scroll. RTMP / Screen Stream / LeanEat moved behind
                        // the "advanced tools" switch in Settings — they were
                        // leftovers from the app this was built on.
                        tileGrid
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
                // BUILD 130: the new browser — map view, detail cards with
                // navigate-back, and an ambient filter so Pulse frames don't
                // bury the photos he actually chose to take.
                ChappyMemoryBrowser()
            }
            .sheet(isPresented: $showCommands) {
                WhatCanISayView(theme: theme)
            }
            .fullScreenCover(isPresented: $showAtlas) {
                AtlasView(initialTarget: atlasTarget, initialLayer: atlasLayer)
            }
            .fullScreenCover(isPresented: $showDictate) {
                DictateView(autoStart: dictateAutoStart)
            }
            .fullScreenCover(isPresented: $showPlaces) {
                PlacesView()
            }
            .fullScreenCover(isPresented: $showUpcoming) {
                UpcomingView()
            }
            .sheet(isPresented: $showNotifDoctor) { NotificationDoctor() }
            .fullScreenCover(isPresented: $showWeather) { WeatherStation() }
            .fullScreenCover(isPresented: $showTravel) { TravelDeskView() }
            .fullScreenCover(isPresented: $showAtlasMap) { TripAtlasView() }
            .sheet(isPresented: $showVisas) { VisaDeskView() }
            .sheet(isPresented: $showOptions) { TripOptionsSheet() }
            .sheet(isPresented: $showIntake) { IntakeSheet() }
    }

    /// The first half of the notification wiring — open Options, Intake,
    /// Visas, Atlas, Travel, FX, Search, Weather, Briefs, Doctor,
    /// Upcoming — hung off the stack above.
    private var homeStackEventsA: some View {
        homeStack
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenOptions)) { _ in
                showOptions = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenIntake)) { _ in
                showIntake = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenVisa)) { _ in
                showVisas = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenAtlasMap)) { _ in
                showAtlasMap = true
            }
            .sheet(isPresented: $showCurrency) { CurrencyView() }
            .sheet(isPresented: $showSearch) { WebSearchView() }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenTravel)) { _ in
                showTravel = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenFX)) { _ in
                showCurrency = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenSearch)) { _ in
                showSearch = true
            }
            .sheet(isPresented: $showBriefs) { BriefStudio() }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenWeather)) { _ in
                showWeather = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenBriefs)) { _ in
                showBriefs = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenNotifDoctor)) { _ in
                showNotifDoctor = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenUpcoming)) { _ in
                showUpcoming = true
            }
            // BUILD 196: Flights could only ever be opened by tapping the
            // tile — no voice route existed, which is no use at all with
            // the phone pocketed and the glasses on.
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenFlights)) { _ in
                showFlights = true
            }
            // BUILD 202 — SIRI'S WAY IN.
            //
            // An App Intent posts this from outside the app entirely:
            // "Hey Siri, Chappy flights", the Action button, a Shortcut,
            // Spotlight. It carries the tool and whatever detail the
            // shortcut supplied, and the interview asks for the rest.
            .onReceive(NotificationCenter.default.publisher(for: .chappyStartTool)) { note in
                guard let id = note.userInfo?["tool"] as? String else { return }
                let values = (note.userInfo?["values"] as? [String: String]) ?? [:]
                ChappyStandby.shared.startTool(id: id, values: values)
            }
    }

    /// The second half: the standby re-arm handlers that hand the
    /// microphone back when a mic-owning cover closes, and "Chappy
    /// reset", which shuts every sheet from anywhere.
    private var homeStackEventsB: some View {
        homeStackEventsA
            // BUILD 160 — RE-ARM ON THE WAY OUT. Standby only ever armed on
            // launch and on foreground, so closing a screen that had taken
            // the microphone left the ear shut until you backgrounded the
            // app and came back. Every mic-owning cover now hands it back.
            .onChange(of: showDictate) { _, open in
                if !open {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        armStandbyIfClear(reason: "dictate closed")
                    }
                }
            }
            .onChange(of: showQuickVision) { _, open in
                if !open {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        armStandbyIfClear(reason: "quick vision closed")
                    }
                }
            }
            .onChange(of: showLiveAI) { _, open in
                if !open {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                        armStandbyIfClear(reason: "live ai closed")
                    }
                }
            }
            .onChange(of: showLiveTranslate) { _, open in
                if !open {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                        armStandbyIfClear(reason: "translate closed")
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenPlaces)) { _ in
                showPlaces = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenAtlas)) { note in
                atlasTarget = note.userInfo?["target"] as? String
                atlasLayer = (note.userInfo?["layer"] as? String).flatMap { ChappyAtlas.Layer(rawValue: $0) }
                showAtlas = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenDictate)) { _ in
                dictateAutoStart = true
                showDictate = true
            }
            // BUILD 168: text is already loaded (a scan) — open, don't record.
            .onReceive(NotificationCenter.default.publisher(for: .chappyOpenDictateQuiet)) { _ in
                dictateAutoStart = false
                showDictate = true
            }
            // BUILD 170 — "CHAPPY RESET": close every sheet and cover, from
            // wherever you are, and come back to this screen.
            .onReceive(NotificationCenter.default.publisher(for: .chappyCloseEverything)) { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    showLiveAI = false;      showLiveTranslate = false
                    showQuickVision = false; showLiveStream = false
                    showRTMPStreaming = false; showOpenClaw = false
                    showLeanEat = false;     showMemory = false
                    showAtlas = false;       showPlaces = false
                    showUpcoming = false;    showDictate = false
                    showWeather = false;     showBriefs = false
                    showTravel = false;      showCurrency = false
                    showSearch = false;      showVisas = false
                    showAtlasMap = false
                    showOptions = false;     showIntake = false
                    showNotifDoctor = false
                    showFlights = false;     showCommands = false
                    showReminders = false;   showMapSheet = false
                    showEmergencyContact = false
                }
                // The ear may have been handed to a module that just closed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    armStandbyIfClear(reason: "reset")
                }
            }
    }

    var body: some View {
        NavigationView {
            homeStackEventsB
            // BUILD 190: the tile now opens the route screen — segments,
            // true cost, the price journal, nearby airports, connection
            // verdicts. The 176 status view is still there and is still
            // the right thing on the day you fly; it's one tap inside.
            .sheet(isPresented: $showFlights) {
                ChappyFlightsView()
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
                    SnapFeedback.shared.dismiss()
                    ChappyEarcon.shared.fail()
                    TTSService.shared.speak("The camera didn't wake up - check the glasses are connected in the Meta app.")
                }

                // BUILD 126: PUT THE CAMERA BACK.
                //
                // This path only runs because the camera was ASLEEP — that is
                // the whole reason the notification fired. It woke it and then
                // never turned it off again, so one Snap left the glasses
                // streaming indefinitely: the light stayed on, the battery
                // drained, and nothing in the app looked wrong.
                //
                // Only stand it down if nobody else has since claimed it.
                // Live AI and Continuous Vision both legitimately hold the
                // camera, and stealing it back from them would be a far worse
                // bug than the one being fixed.
                if !LiveAIManager.shared.isRunning,
                   !ContinuousVisionManager.shared.isRunning,
                   !showLiveAI, !showQuickVision, !showLiveStream, !showRTMPStreaming {
                    // A beat, so a capture still in flight isn't cut off.
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    await streamViewModel.stopSession()
                    print("📷 [Snap] Camera returned to sleep")
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
            // BUILD 132 — one-shot cleanup: the duplicate "glowing phone
            // screen" pulse captions and model junk already in the store.
            ChappyMemory.shared.sweepPulseJunk()
            // BUILD 138 — the Trail: all-day visit + breadcrumb monitoring.
            // Asks once to upgrade location to Always; low-power by design
            // (Apple's visit detection + significant changes, no raw GPS).
            ChappyTrail.shared.start()

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
            checkNotificationPermission()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            // Coming back from a call, another app, or a locked screen. Without
            // this the ear is armed exactly once per cold launch and any
            // interruption leaves it closed for the rest of the day.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                armStandbyIfClear(reason: "foreground")
            }
            checkNotificationPermission()
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
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("chappyMapsCleanup"))) { _ in
            // BUILD 135: Google Maps was opened directly (Live AI paths) —
            // do the same tidy-up the Standby handoff does: card gone,
            // sheet gone, Chappy's own turns silenced.
            let nav = NavEngine.shared
            if nav.isNavigating { nav.stop(announce: false) }
            showMapSheet = false
            showNavMap = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .chappyOpenGoogleMaps)) { _ in
            let nav = NavEngine.shared
            // BUILD 133: a multi-stop run built by addStops carries its own
            // URL — destination plus every waypoint. It wins over the plain
            // single-destination handoff below.
            if let multi = nav.pendingHandoffURL {
                nav.pendingHandoffURL = nil
                if nav.isNavigating { nav.stop(announce: false) }
                showMapSheet = false
                showNavMap = false
                UIApplication.shared.open(multi, options: [:], completionHandler: nil)
                return
            }
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
            // BUILD 132 — A CLEAN HANDOFF. Once Google Maps has the route,
            // Chappy steps back: its own map sheet and nav card close, and
            // its spoken turn-by-turn stops — two voices reading the same
            // turns was never guidance, it was noise. Come back to Chappy
            // and the screen is clear, not mid-prompt. (URL is built above,
            // BEFORE stop() clears the destination it needs.)
            if nav.isNavigating { nav.stop(announce: false) }
            showMapSheet = false
            showNavMap = false
            if let u = url { UIApplication.shared.open(u, options: [:], completionHandler: nil) }
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

/// BUILD 138 — THE TRAIL. The Map button's view when not navigating: the
/// day drawn as a line, the places you stopped as cards, and a strip of the
/// last week to swipe back through. Fed by ChappyTrail's all-day visit and
/// breadcrumb monitoring, plus the journal crumbs that were always there.
struct TodayMapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var trail = ChappyTrail.shared
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    private var isToday: Bool { Calendar.current.isDateInToday(selectedDay) }

    /// BUILD 149 — THE WEEK IN BARS. Kilometres moved per day from the
    /// Trail's own points; the selected day glows. Swift Charts, ~20 lines.
    private var weekChart: some View {
        let cal = Calendar.current
        let days: [(day: Date, km: Double)] = (0..<7).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back,
                                   to: cal.startOfDay(for: Date())) else { return nil }
            let pts = trail.points(for: d)
            var meters = 0.0
            for i in 1..<max(1, pts.count) {
                meters += CLLocation(latitude: pts[i-1].lat, longitude: pts[i-1].lon)
                    .distance(from: CLLocation(latitude: pts[i].lat, longitude: pts[i].lon))
            }
            return (d, meters / 1000)
        }
        return Chart(days, id: \.day) { item in
            BarMark(x: .value("Day", Self.shortDay(item.day)),
                    y: .value("km", item.km))
            .foregroundStyle(cal.isDate(item.day, inSameDayAs: selectedDay)
                             ? Color.blue : Color.blue.opacity(0.35))
            .cornerRadius(3)
        }
        .chartYAxis(.hidden)
        .frame(height: 54)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.black.opacity(0.2))
    }

    /// BUILD 146 — the day's memories, pinned where they happened.
    private var dayPins: [RouteMapView.JournalPin] {
        let tf = DateFormatter(); tf.dateFormat = "h:mm a"
        return ChappyMemory.shared.recent
            .filter { Calendar.current.isDate($0.at, inSameDayAs: selectedDay) }
            .compactMap { e in
                guard let la = e.lat, let lo = e.lon else { return nil }
                let (glyph, tint): (String, UIColor) = {
                    switch e.kind {
                    case .photo: return ("📷", .systemIndigo)
                    case .scan:  return ("📄", .systemCyan)
                    case .spend: return ("💰", .systemOrange)
                    case .place: return ("⭐", .systemYellow)
                    case .talk:  return ("💬", .systemGreen)
                    case .route: return ("🧭", .systemBlue)
                    default:     return ("✎", .systemTeal)
                    }
                }()
                return RouteMapView.JournalPin(
                    coord: CLLocationCoordinate2D(latitude: la, longitude: lo),
                    glyph: glyph, tint: tint,
                    title: e.title,
                    sub: tf.string(from: e.at))
            }
    }

    private var dayCoords: [CLLocationCoordinate2D] {
        var pts = trail.points(for: selectedDay)
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        // Today also gets the fine-grained journal crumbs it always had.
        if isToday {
            pts += TripRecorder.shared.crumbs.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            }
        }
        return pts
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                dayStrip
                weekChart
                ZStack(alignment: .bottom) {
                    RouteMapView(
                        coords: dayCoords,
                        destination: nil,
                        spots: isToday ? TripRecorder.shared.spots : [],
                        journalPins: dayPins)
                        .ignoresSafeArea(edges: [])

                    Button {
                        NotificationCenter.default.post(name: .chappyOpenGoogleMaps, object: nil)
                    } label: {
                        Label("Open in Google Maps", systemImage: "map.fill")
                            .font(.subheadline).fontWeight(.semibold)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Capsule().fill(Color.blue))
                            .foregroundColor(.white)
                    }
                    .padding(.bottom, 12)
                }
                visitList
            }
            .navigationTitle(isToday ? "Today's Trail" : Self.dayTitle(selectedDay))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The last seven days, newest first.
    private var dayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { back in
                    let day = Calendar.current.date(byAdding: .day, value: -back,
                        to: Calendar.current.startOfDay(for: Date()))!
                    let on = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selectedDay = day }
                    } label: {
                        Text(back == 0 ? "Today" : (back == 1 ? "Yesterday" : Self.shortDay(day)))
                            .font(.caption).fontWeight(.semibold)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(on ? Color.blue.opacity(0.25) : Color.white.opacity(0.06)))
                            .foregroundColor(on ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(Color.black.opacity(0.25))
    }

    /// The stops of the day, in order — the timeline you can read.
    /// BUILD 146: memories ride along between the stops, so the list reads
    /// as the day's story — arrived, photographed, spent, moved on.
    private var dayMemories: [ChappyMemory.Entry] {
        ChappyMemory.shared.recent
            .filter { Calendar.current.isDate($0.at, inSameDayAs: selectedDay) && $0.source != "pulse" }
            .sorted { $0.at < $1.at }
    }

    private var visitList: some View {
        let visits = trail.visits(for: selectedDay).sorted { $0.arrive < $1.arrive }
        return Group {
            if visits.isEmpty {
                VStack(spacing: 5) {
                    Text(isToday ? "No stops recorded yet today"
                                 : "No stops recorded that day")
                        .font(.subheadline).foregroundColor(.primary)
                    Text("Chappy notices arrivals and departures on its own once location is set to Always. Moving draws the line; stopping makes a card.")
                        .font(.caption2).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(visits) { v in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 18)).foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.name ?? "Stopped here")
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                    Text(v.spokenWindow)
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                // Back to any stop — the memory's exact spot,
                                // through the machinery that already exists.
                                Button {
                                    NavEngine.shared.navigateBack(
                                        to: CLLocationCoordinate2D(latitude: v.lat, longitude: v.lon),
                                        name: v.name ?? "that stop")
                                    dismiss()
                                } label: {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                        .font(.system(size: 18)).foregroundColor(.secondary)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                            .padding(.horizontal, 12)
                            // BUILD 138 — TAGS AND LINKS. Long-press a stop:
                            // star it (becomes a saved place — findable in
                            // Memory, usable by "take me back"), mark it as
                            // Home ("take me home" now points here), or open
                            // the place itself in Google Maps — reviews,
                            // website, opening hours, the lot.
                            .contextMenu {
                                Button {
                                    TripRecorder.shared.saveSpot(
                                        named: v.name ?? "Starred place",
                                        lat: v.lat, lon: v.lon)
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                } label: { Label("Star — save this place", systemImage: "star.fill") }
                                Button {
                                    TripRecorder.shared.saveSpot(named: "Home", lat: v.lat, lon: v.lon)
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                } label: { Label("Set as Home", systemImage: "house.fill") }
                                Button {
                                    let q = (v.name ?? "").addingPercentEncoding(
                                        withAllowedCharacters: .urlQueryAllowed) ?? ""
                                    let u = q.isEmpty
                                        ? "https://www.google.com/maps/search/?api=1&query=\(v.lat),\(v.lon)"
                                        : "https://www.google.com/maps/search/?api=1&query=\(q)&center=\(v.lat),\(v.lon)"
                                    if let url = URL(string: u) { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
                                } label: { Label("Place info in Google Maps", systemImage: "safari") }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 230)
            }
            // BUILD 146 — THE MOMENTS. What happened between the stops.
            let moments = dayMemories
            if !moments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(moments.prefix(12)) { m in
                            HStack(spacing: 6) {
                                Text(Self.momentGlyph(m.kind))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.title).font(.caption2).fontWeight(.semibold)
                                        .foregroundColor(.primary).lineLimit(1)
                                    Text(Self.momentTime(m.at)).font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
        }
    }

    private static func momentGlyph(_ k: ChappyMemory.Kind) -> String {
        switch k {
        case .photo: return "📷"; case .scan: return "📄"; case .spend: return "💰"
        case .place: return "⭐"; case .talk: return "💬"; case .route: return "🧭"
        default: return "✎"
        }
    }
    private static func momentTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
    }

    private static func shortDay(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f.string(from: d)
    }
    private static func dayTitle(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"; return f.string(from: d)
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
    /// BUILD 146 — JOURNAL PINS. The day's memories placed where they
    /// happened: photo, scan, note, spend, each with its own glyph and
    /// colour, tappable for title + time. This is what turns a line on a
    /// map into the story of a day.
    struct JournalPin {
        let coord: CLLocationCoordinate2D
        let glyph: String
        let tint: UIColor
        let title: String
        let sub: String
    }
    var journalPins: [JournalPin] = []

    final class JournalAnnotation: MKPointAnnotation {
        var glyph = "✎"
        var tint = UIColor.systemTeal
    }

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
        for pinData in journalPins {
            let a = JournalAnnotation()
            a.coordinate = pinData.coord
            a.title = pinData.title
            a.subtitle = pinData.sub
            a.glyph = pinData.glyph
            a.tint = pinData.tint
            map.addAnnotation(a)
        }
        // If there is no trail but there ARE pins or spots, frame them rather
        // than dropping the user on a blank world map.
        if coords.isEmpty, !(spots.isEmpty && journalPins.isEmpty) {
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
                // BUILD 146: the trail reads as a path, not a route — teal,
                // rounded, slightly translucent so streets stay legible.
                r.strokeColor = UIColor.systemTeal.withAlphaComponent(0.85)
                r.lineWidth = 5
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        // BUILD 146 — glyph markers with callouts, Apple-Journal style.
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let j = annotation as? JournalAnnotation else { return nil }
            let id = "journal-pin"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: j, reuseIdentifier: id)
            v.annotation = j
            v.glyphText = j.glyph
            v.markerTintColor = j.tint
            v.canShowCallout = true
            v.displayPriority = .required
            return v
        }
    }
}


// MARK: - Chappy Themes (the Face's wardrobe)

// BUILD 149 — SCROLL FEEL. The App Store trick: cards breathe in as they
// enter the screen. One modifier, sprinkled where lists live.
extension View {
    func chappyScrollFX() -> some View {
        self.scrollTransition(.interactive) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.55)
                .scaleEffect(phase.isIdentity ? 1 : 0.95)
        }
    }
}

// BUILD 148 — THE AURORA BACKDROP. Every theme's flat gradient becomes a
// living background: the base wash plus two big, heavily-blurred colour
// blobs drawn from the theme's own palette, drifting on a slow cycle. No
// image assets, all GPU, and each theme gets its own mood for free because
// the blobs are derived, not designed.
struct AuroraBackdrop: View {
    let theme: ChappyTheme
    @State private var drift = false

    static var hourTint: Color {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<9:   return .orange          // dawn
        case 9..<17:  return .yellow          // day
        case 17..<21: return .pink            // dusk
        default:      return .indigo          // night
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.bgTop, theme.bgBottom],
                           startPoint: .top, endPoint: .bottom)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                Circle()
                    .fill(theme.accent.opacity(0.20))
                    .frame(width: w * 0.9)
                    .blur(radius: 70)
                    .offset(x: drift ? -w * 0.25 : w * 0.30,
                            y: drift ? -h * 0.05 : h * 0.12)
                Circle()
                    .fill(theme.bgTop.opacity(0.55))
                    .frame(width: w * 0.8)
                    .blur(radius: 80)
                    .offset(x: drift ? w * 0.35 : -w * 0.2,
                            y: drift ? h * 0.55 : h * 0.35)
                Circle()
                    .fill(theme.accent.opacity(0.10))
                    .frame(width: w * 0.6)
                    .blur(radius: 60)
                    .offset(x: drift ? w * 0.05 : w * 0.45,
                            y: drift ? h * 0.85 : h * 0.65)
                // BUILD 149 — TIME OF DAY IN THE LIGHT. Dawn warms the
                // aurora, night cools and deepens it — same theme, living
                // atmosphere, the Material-You idea done the iOS way.
                Circle()
                    .fill(Self.hourTint.opacity(0.12))
                    .frame(width: w * 1.1)
                    .blur(radius: 90)
                    .offset(x: drift ? -w * 0.1 : w * 0.2,
                            y: drift ? h * 0.2 : -h * 0.1)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 22).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

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
        .background(Capsule().fill(.ultraThinMaterial))
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
        // BUILD 173 — TIGHTER. These four were 110pt tall with a 14pt pad and
        // a two-line subtitle, which is a lot of screen for four words. The
        // icon now sits BESIDE the title rather than above it, the subtitle
        // is one line, and the whole tile is 78pt — a third shorter, still
        // well over the 44pt touch minimum, and it lifts everything below
        // it up the screen. Active tiles now also carry a coloured glow, so
        // "which one is running" reads at a glance.
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(accent.opacity(active ? 0.3 : 0.18))
                            .frame(width: 30, height: 30)
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(active ? .white : accent)
                    }
                    .shadow(color: accent.opacity(active ? 0.8 : 0.45), radius: active ? 9 : 6)
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 78)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 17)
                .fill(active ? theme.cardActive : theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 17)
                .stroke(active ? accent.opacity(0.8) : theme.stroke, lineWidth: 1))
            .shadow(color: active ? accent.opacity(0.3) : .clear, radius: 10, y: 3)
        }
        .buttonStyle(ChappyPressStyle())
    }
}

// BUILD 162 — THE QUICK ROW, REBUILT.
//
// Six flat grey squares in a cramped row, no colour, no glow, and touch
// targets you had to aim at. Now every one carries its own hue, a glowing
// icon chip and a gradient edge — the same language as the tile grid — and
// they wrap onto two rows so nothing is squeezed. Scroll-safe: the press
// effect comes from ChappyPressStyle, never a gesture.
struct QuickActionButton: View {
    let icon: String
    let label: String
    var tint: Color = .cyan
    var active: Bool = false
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
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(active ? 0.32 : 0.18))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(active ? .white : tint)
                }
                .shadow(color: tint.opacity(active ? 0.85 : 0.5), radius: active ? 11 : 7)
                Text(label)
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundColor(active ? tint : theme.textPrimary.opacity(0.72))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 78)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(colors: [tint.opacity(active ? 0.22 : 0.10), .clear],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LinearGradient(colors: [tint.opacity(active ? 0.9 : 0.55),
                                                    tint.opacity(0.10)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1)
            )
            .shadow(color: tint.opacity(active ? 0.35 : 0.18), radius: 9, y: 3)
        }
        .buttonStyle(ChappyPressStyle())
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
            .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
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
                AuroraBackdrop(theme: theme)
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
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
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
                        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
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
                    .background(RoundedRectangle(cornerRadius: 9).fill(.ultraThinMaterial))
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
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
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
                AuroraBackdrop(theme: theme)
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
                                .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
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
                                        .background(Capsule().fill(.ultraThinMaterial))
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
                            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
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
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
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
        if let a = app, UIApplication.shared.canOpenURL(a) { UIApplication.shared.open(a, options: [:], completionHandler: nil) }
        else if let w = web { UIApplication.shared.open(w, options: [:], completionHandler: nil) }
    }

    private func openInGoogleMaps(mode: String) {
        let lat = entry.lat ?? 0, lon = entry.lon ?? 0
        let app = URL(string: "comgooglemaps://?daddr=\(lat),\(lon)&directionsmode=\(mode)")
        let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(lat),\(lon)&travelmode=\(mode)")
        if let a = app, UIApplication.shared.canOpenURL(a) {
            UIApplication.shared.open(a, options: [:], completionHandler: nil)
        } else if let w = web {
            UIApplication.shared.open(w, options: [:], completionHandler: nil)
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

// BUILD 150 — THE FLIGHT DECK. Watched routes with price history drawn as
// sparklines, the tracked flight's travel-day card, and a search box that
// speaks Amadeus. Booking hands off to the big sites with the route ready.
// BUILD 176 — WHAT'S LEFT IN THE TANK.
//
// The flight lookups run on AviationStack's free 100-a-month, and that
// plan has NO overage: at the limit the calls don't get billed, they
// start failing. So the way this breaks is Chappy going quiet on gate
// and delay information in an airport, with nothing on screen to explain
// it. Nothing in the app counted, so there was never a warning.
//
// Shown in FLIGHT DAYS, not raw calls. "Sixty-one left" is a number;
// "about seven more flight days" is something you can plan around.
struct FlightBudgetBar: View {
    let theme: ChappyTheme
    @ObservedObject private var budget = ChappyFlightBudget.shared
    @State private var editing = false
    @State private var limitField = ""

    private var tint: Color {
        let f = budget.fraction
        if f >= 0.9 { return .red }
        if f >= 0.7 { return .orange }
        return theme.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("FLIGHT CHECKS", systemImage: "gauge.with.needle")
                    .font(.caption2).fontWeight(.heavy).tracking(0.6)
                    .foregroundColor(.cyan)
                Spacer()
                Button {
                    limitField = String(budget.limit)
                    editing = true
                } label: {
                    Text("\(budget.used) / \(budget.limit)")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(tint)
                }
                .buttonStyle(.plain)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: max(3, geo.size.width * budget.fraction))
                }
            }
            .frame(height: 7)

            Text(summary)
                .font(.caption2)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.05)))
        .alert("Monthly flight checks", isPresented: $editing) {
            TextField("100", text: $limitField).keyboardType(.numberPad)
            Button("Save") {
                if let n = Int(limitField), n > 0 { budget.limit = n }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("AviationStack's free plan is 100 a month. If you upgrade, put the new number here - nothing else has to change.")
        }
    }

    private var summary: String {
        if budget.remaining == 0 {
            return "All used for this month. Flight status goes to the screen instead of being read out. Resets in \(budget.daysUntilReset) days."
        }
        let d = budget.flightDaysLeft
        let days = d >= 1
            ? "About \(d) more flight \(d == 1 ? "day" : "days")."
            : "Not quite a full flight day left."
        return "\(days) A tracked flight day costs at most \(ChappyFlightBudget.costOfAFlightDay). Resets in \(budget.daysUntilReset) days."
    }
}

struct FlightsView: View {
    @Environment(\.dismiss) private var dismiss
    let theme: ChappyTheme
    @ObservedObject private var flights = ChappyFlights.shared
    @State private var destField = ""
    @State private var monthField = ""
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // BUILD 176 — THE FLIGHT BUDGET METER.
                        FlightBudgetBar(theme: theme)
                        // SEARCH / WATCH BOX
                        VStack(alignment: .leading, spacing: 8) {
                            Text("WATCH A ROUTE")
                                .font(.caption2).fontWeight(.heavy).tracking(0.6)
                                .foregroundColor(.cyan)
                            TextField("Where to? Name or code - Bali, BNE, Denpasar...", text: $destField)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            // BUILD 155 — AIRPORT AUTOCOMPLETE. Type 2 letters
                            // and the offline table answers instantly: "bali"
                            // -> Denpasar DPS, "bne" -> Brisbane. Tap to fill.
                            let hits = ChappyAirports.search(destField)
                            if !hits.isEmpty, destField.count >= 2 {
                                ForEach(hits.prefix(4), id: \.code) { a in
                                    Button {
                                        destField = a.code
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    } label: {
                                        HStack {
                                            Image(systemName: "airplane")
                                                .font(.caption).foregroundColor(.cyan)
                                            Text(a.city).font(.subheadline)
                                                .foregroundColor(theme.textPrimary)
                                            Text(a.name).font(.caption2)
                                                .foregroundColor(theme.textSecondary)
                                                .lineLimit(1)
                                            Spacer()
                                            Text(a.code).font(.caption).fontWeight(.heavy)
                                                .foregroundColor(.cyan)
                                        }
                                        .padding(.vertical, 7).padding(.horizontal, 10)
                                        .background(RoundedRectangle(cornerRadius: 9)
                                            .fill(Color.cyan.opacity(0.08)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            TextField("Month, e.g. September (optional)", text: $monthField)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                let d = destField.trimmingCharacters(in: .whitespaces)
                                guard !d.isEmpty else { note = "Type a destination first."; return }
                                busy = true; note = "Checking…"
                                let m = ChappyFlights.monthKey(from: monthField.lowercased()) ?? ""
                                Task { @MainActor in
                                    note = await flights.addWatch(destName: d, month: m)
                                    busy = false; destField = ""; monthField = ""
                                }
                            } label: {
                                Label(busy ? "Checking…" : "Watch this route",
                                      systemImage: "binoculars.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: 11).fill(Color.cyan.opacity(0.18)))
                                    .foregroundColor(.cyan)
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                            if !note.isEmpty {
                                Text(note).font(.caption).foregroundColor(theme.textSecondary)
                            }
                            if !flights.isConfigured {
                                Text("Deal watching needs the free Amadeus keys — Settings → Flights.")
                                    .font(.caption2).foregroundColor(.orange)
                            }
                        }
                        .padding(13)
                        .background(RoundedRectangle(cornerRadius: 15).fill(.ultraThinMaterial))

                        // WATCHED ROUTES
                        ForEach(flights.watches) { w in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("\(w.originCode) → \(w.destName)")
                                        .font(.subheadline).fontWeight(.bold)
                                        .foregroundColor(theme.textPrimary)
                                    Spacer()
                                    if let p = w.lastPrice {
                                        Text("$\(Int(p))")
                                            .font(.title3).fontWeight(.heavy)
                                            .foregroundColor(.cyan)
                                            .contentTransition(.numericText())
                                    }
                                }
                                if let b = w.bestDate {
                                    Text("Cheapest: \(ChappyFlights.spokenDate(b))\(w.month.isEmpty ? "" : " · watching \(w.month)")")
                                        .font(.caption2).foregroundColor(theme.textSecondary)
                                }
                                if w.history.count >= 2 {
                                    Chart(Array(w.history.enumerated()), id: \.offset) { _, pt in
                                        LineMark(x: .value("t", pt.at), y: .value("$", pt.price))
                                            .foregroundStyle(Color.cyan)
                                            .interpolationMethod(.catmullRom)
                                        AreaMark(x: .value("t", pt.at), y: .value("$", pt.price))
                                            .foregroundStyle(Color.cyan.opacity(0.12))
                                            .interpolationMethod(.catmullRom)
                                    }
                                    .chartXAxis(.hidden).chartYAxis(.hidden)
                                    .frame(height: 44)
                                }
                                HStack {
                                    Button {
                                        let q = "flights to \(w.destName)"
                                            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                                        if let u = URL(string: "https://www.google.com/travel/flights?q=\(q)") {
                                            UIApplication.shared.open(u, options: [:], completionHandler: nil)
                                        }
                                    } label: {
                                        Label("Book", systemImage: "arrow.up.right.square")
                                            .font(.caption).fontWeight(.semibold)
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        flights.removeWatch(w.id)
                                    } label: {
                                        Image(systemName: "trash").font(.caption)
                                    }
                                }
                                .foregroundColor(theme.textSecondary)
                            }
                            .padding(13)
                            .background(RoundedRectangle(cornerRadius: 15).fill(.ultraThinMaterial))
                            .chappyScrollFX()
                        }

                        // BUILD 152 — FLIGHT DAY banner. Lights up when a
                        // tracked flight owns today; shows what the last
                        // check brought home: gate, terminal, delay.
                        if let today = flights.todayFlight() {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "airplane.circle.fill")
                                        .font(.title2).foregroundColor(.orange)
                                    Text("FLIGHT DAY — \(today.number)")
                                        .font(.caption).fontWeight(.heavy).tracking(0.8)
                                        .foregroundColor(.orange)
                                    Spacer()
                                }
                                Text(Self.flightDate(today.date))
                                    .font(.subheadline).fontWeight(.semibold)
                                    .foregroundColor(theme.textPrimary)
                                HStack(spacing: 10) {
                                    if let g = today.lastGate {
                                        Label("Gate \(g)", systemImage: "signpost.right")
                                    }
                                    if let t = today.depTerminal {
                                        Label("Terminal \(t)", systemImage: "building.2")
                                    }
                                    if let d = today.lastDelay, d > 0 {
                                        Label("+\(d) min", systemImage: "clock.badge.exclamationmark")
                                            .foregroundColor(.red)
                                    } else if today.lastStatus != nil {
                                        Label("On time", systemImage: "checkmark.circle")
                                            .foregroundColor(.green)
                                    }
                                }
                                .font(.caption).foregroundColor(theme.textSecondary)
                                Text("Briefs and gate-change alerts run automatically today. Say \u{201C}how's my flight\u{201D} any time, or \u{201C}take me to the airport\u{201D} for the right terminal.")
                                    .font(.caption2).foregroundColor(theme.textSecondary)
                            }
                            .padding(13)
                            .background(RoundedRectangle(cornerRadius: 15)
                                .fill(.ultraThinMaterial)
                                .overlay(RoundedRectangle(cornerRadius: 15)
                                    .stroke(Color.orange.opacity(0.5), lineWidth: 1)))
                            .chappyScrollFX()
                        }

                        // TRACKED FLIGHTS
                        if !flights.tracked.isEmpty {
                            Text("MY FLIGHTS")
                                .font(.caption2).fontWeight(.heavy).tracking(0.6)
                                .foregroundColor(.cyan).padding(.top, 4)
                            ForEach(flights.tracked.sorted { $0.date < $1.date }) { f in
                                HStack {
                                    Image(systemName: "airplane.departure")
                                        .foregroundColor(.cyan)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(f.number).font(.subheadline).fontWeight(.bold)
                                            .foregroundColor(theme.textPrimary)
                                        Text(Self.flightDate(f.date))
                                            .font(.caption2).foregroundColor(theme.textSecondary)
                                    }
                                    Spacer()
                                    Button {
                                        _ = flights.statusHandoff()
                                    } label: {
                                        Text("Status").font(.caption).fontWeight(.semibold)
                                            .foregroundColor(.cyan)
                                    }
                                }
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                            }
                        }

                        Text("Say: \u{201C}watch flights to Bali in September\u{201D} · \u{201C}any flight deals?\u{201D} · \u{201C}track flight QF52 on Thursday\u{201D} · \u{201C}how's my flight?\u{201D}")
                            .font(.caption2).foregroundColor(theme.textSecondary)
                            .padding(.top, 6)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Flights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(theme.accent)
                }
            }
        }
    }

    private static func flightDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM, h:mm a"; return f.string(from: d)
    }
}

// BUILD 149 — WHAT CAN I SAY? Every voice command Chappy understands, on
// one searchable screen, grouped by what it does. Tap a row and Chappy
// speaks the phrase back so you hear exactly how to say it.
struct WhatCanISayView: View {
    @Environment(\.dismiss) private var dismiss
    let theme: ChappyTheme
    @State private var search = ""

    private static let groups: [(name: String, icon: String, items: [String])] = [
        ("Talk & ask", "bubble.left.fill",
         ["Chappy, what time is it", "What's the weather", "Convert 180 centimeters to inches",
          "What's 15 percent of 80", "How many calories in half a chicken", "Plan my day"]),
        ("Navigate", "location.fill",
         ["Take me to Coles", "Navigate to Brisbane Airport and get me a coffee on the way",
          "Get fuel on the way", "Open maps", "Close maps", "Stop navigation", "Take me home",
          "Where am I", "Remember this spot, call it the blue warung"]),
        ("Camera & Reader", "camera.fill",
         ["Take a photo", "Action shot", "Record a clip", "What did I just see", "Read this",
          "Read the menu", "Translate this", "Scan this", "Keep reading", "Read my last scan",
          // BUILD 159 — press the glasses button first, then say these.
          "Read that properly", "Read the fine print", "Read my photo",
          "Scan my photo"]),
        ("Mail & texts", "envelope.fill",
         ["Check my email", "Any texts?", "Read the first one", "Reply saying on my way"]),
        ("Diary & reminders", "book.closed.fill",
         ["Remind me to pay rego Friday at 9", "Remind me to take the bins out when I get home",
          "What's on today", "What's on next week", "Reminders", "Snooze that", "Done with that"]),
        ("Lists & timers", "checklist",
         ["Add milk to the shopping list", "What's on my list", "Got the milk",
          "Set a timer for 10 minutes"]),
        ("Memory & journal", "brain.head.profile",
         ["Open memory", "What do you remember about the warung", "Where was I on Tuesday",
          "Read my journal", "Show my trail", "Remember everything for the next hour",
          "Stop remembering"]),
        ("Flights", "airplane",
         ["Watch flights to Bali in September", "Any flight deals?",
          "Track flight QF52 on Thursday", "How's my flight",
          "Take me to the airport"]),
        ("Atlas & travel map", "globe.asia.australia.fill",
         ["Open the atlas", "Where have I been", "Zoom to Ubud",
          "Show me temples", "Show me waterfalls", "What's around me",
          "Show me lookouts", "Fly to Bali"]),
        ("Voice", "waveform",
         ["Why is the voice robotic", "Voice status", "Check the voice",
          "Reset the voice", "Test the voice"]),
        ("Weather", "cloud.sun.fill",
         ["What's the weather", "Full weather", "Will it rain",
          "Weather this week", "Weather in Bali", "Open weather"]),
        ("Briefs", "sun.horizon.fill",
         ["What was my brief", "Brief me now", "Open briefs"]),
        ("Calendar & upcoming", "calendar",
         ["What's coming up", "My calendar", "What's on today",
          "What's on next week", "My appointments", "Upcoming",
          "Add an appointment Friday at three, dentist",
          "Star that", "Make that important"]),
        ("Places", "mappin.and.ellipse",
         ["Remember this spot, call it the blue warung", "My places",
          "Show my places", "What do you remember about the warung"]),
        ("Dictate & rewrite", "mic.fill",
         ["Take a report", "Dictate a note", "Write this up",
          "Dictate an email", "Draft an email", "Take a job report",
          "Reply saying on my way",
          // BUILD 168 — look at a page, get it rewritten.
          "Rewrite this", "Reword this", "Simplify this",
          "Summarise this", "Turn this into a letter"]),
        ("Rides & food", "car.fill",
         ["Get me a Grab to the airport", "How much is an Uber to Coles",
          "Ride home", "Order food", "Order from Mama's Warung",
          "Order the usual"]),
        ("Protection", "shield.fill",
         ["Is this a scam - he wants gift cards", "Scam check", "Is this a good deal",
          "Can I eat this", "Emergency"]),
        ("Modes & checks", "gearshape.fill",
         ["Let's talk", "Translate", "Quiet mode", "Battery check", "Spent today",
          "Test the voice", "Test notification", "Are my notifications on",
          // BUILD 170 — the escape hatch, from anywhere.
          "Chappy reset", "Close everything", "Back to the main screen",
          "Stop everything", "Close maps", "Stop navigation"]),
    ]

    private var filtered: [(name: String, icon: String, items: [String])] {
        guard !search.isEmpty else { return Self.groups }
        let q = search.lowercased()
        return Self.groups.compactMap { g in
            let hits = g.items.filter { $0.lowercased().contains(q) }
            return hits.isEmpty ? nil : (g.name, g.icon, hits)
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                List {
                    ForEach(filtered, id: \.name) { group in
                        Section {
                            ForEach(group.items, id: \.self) { phrase in
                                Button {
                                    TTSService.shared.speak(phrase)
                                } label: {
                                    HStack {
                                        Text("\u{201C}\(phrase)\u{201D}")
                                            .font(.subheadline)
                                            .foregroundColor(theme.textPrimary)
                                        Spacer()
                                        Image(systemName: "speaker.wave.2")
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.textSecondary)
                                    }
                                }
                                .listRowBackground(Color.white.opacity(0.05))
                            }
                        } header: {
                            Label(group.name, systemImage: group.icon)
                                .font(.caption).fontWeight(.heavy)
                                .foregroundColor(theme.accent)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .searchable(text: $search, prompt: "Search commands")
            }
            .navigationTitle("What can I say?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(theme.accent)
                }
            }
        }
    }
}

// BUILD 132 — ONE EVENT, ONE SHEET.
//
// Long-press menus are invisible; this is the discoverable version. Tap any
// diary event and everything Chappy can do about it is on one card:
// how important it is, and how far ahead the warning should come.
struct EventDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let event: EKEvent
    let theme: ChappyTheme
    var onChange: () -> Void

    @State private var level: ChappyCalendar.EventLevel = .normal
    @State private var lead: Int? = nil   // nil = calendar default
    @State private var starred = false    // BUILD 164

    // BUILD 145: the full menu the wearer asked for.
    private static let leadChoices: [(label: String, minutes: Int?)] = [
        ("Default", nil), ("10 min", 10), ("15 min", 15), ("30 min", 30),
        ("45 min", 45), ("1 hour", 60), ("2 hours", 120), ("Day before", 1440),
    ]

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // WHAT AND WHEN.
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.title ?? "Appointment")
                                .font(.title3).fontWeight(.semibold)
                                .foregroundColor(theme.textPrimary)
                            if let s = event.startDate {
                                let df: DateFormatter = {
                                    let f = DateFormatter()
                                    f.dateFormat = event.isAllDay ? "EEEE d MMMM" : "EEEE d MMMM, h:mm a"
                                    return f
                                }()
                                Text(event.isAllDay ? "All day — \(df.string(from: s))" : df.string(from: s))
                                    .font(.subheadline).foregroundColor(theme.textSecondary)
                            }
                            if let l = event.location, !l.isEmpty {
                                Label(l, systemImage: "mappin.and.ellipse")
                                    .font(.caption).foregroundColor(theme.textSecondary)
                            }
                            if let c = event.calendar?.title {
                                Label(c, systemImage: "calendar")
                                    .font(.caption).foregroundColor(theme.textSecondary)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))

                        // BUILD 164 — THE STAR, and the honest note about
                        // what can and can't be edited. A subscribed feed
                        // (your Geeks2U one) is read-only in iOS for EVERY
                        // app including Apple's — but Chappy's own overlay
                        // (star, warn time, brief) is stored on this phone
                        // against a fingerprint, so it works on all of them.
                        Button {
                            let now = !ChappyCalendar.shared.isStarred(event)
                            ChappyCalendar.shared.setStarred(now, for: event)
                            starred = now
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            TTSService.shared.speak(now ? "Starred." : "Star off.")
                            onChange()
                        } label: {
                            HStack {
                                Image(systemName: starred ? "star.fill" : "star")
                                    .foregroundStyle(starred ? .yellow : theme.textSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(starred ? "Starred" : "Star this")
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundColor(theme.textPrimary)
                                    Text("Leads the morning brief and gets a firmer warn-time")
                                        .font(.caption2).foregroundColor(theme.textSecondary)
                                }
                                Spacer()
                            }
                            .padding(13)
                            .background(RoundedRectangle(cornerRadius: 14)
                                .fill(starred ? Color.yellow.opacity(0.14) : Color.white.opacity(0.045)))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(starred ? Color.yellow.opacity(0.5) : .clear, lineWidth: 1))
                        }
                        .buttonStyle(ChappyPressStyle())

                        if !ChappyCalendar.shared.canEdit(event) {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.fill")
                                    .font(.caption).foregroundStyle(theme.textSecondary)
                                Text("This lives on a subscribed calendar, so its title and time can't be changed from any app — not even Apple's. Everything below still works.")
                                    .font(.caption2).foregroundColor(theme.textSecondary)
                            }
                            .padding(11)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.04)))
                        }

                        // HOW MUCH IT MATTERS.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("HOW IMPORTANT")
                                .font(.caption2).fontWeight(.heavy).tracking(0.6)
                                .foregroundColor(theme.textSecondary)
                            levelButton(.important, "flag.fill", "Important",
                                        "Warned the day before AND closer in — pierces quiet hours")
                            levelButton(.normal, "circle", "Normal",
                                        "Warned once, at the time set below")
                            levelButton(.muted, "bell.slash.fill", "Muted",
                                        "Stays visible, never spoken, never pinged")
                        }

                        // HOW FAR AHEAD.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("WARN ME")
                                .font(.caption2).fontWeight(.heavy).tracking(0.6)
                                .foregroundColor(theme.textSecondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                                ForEach(Self.leadChoices, id: \.label) { c in
                                    Button {
                                        lead = c.minutes
                                        ChappyCalendar.shared.setLead(c.minutes, for: event)
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        onChange()
                                    } label: {
                                        Text(c.label)
                                            .font(.caption).fontWeight(.semibold)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 9)
                                            .background(RoundedRectangle(cornerRadius: 9)
                                                .fill(lead == c.minutes ? theme.accent.opacity(0.22) : theme.cardFill))
                                            .foregroundColor(lead == c.minutes ? theme.accent : theme.textPrimary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            if level == .muted {
                                Text("Muted events never warn, whatever is set here.")
                                    .font(.caption2).foregroundColor(theme.textSecondary)
                            }
                        }

                        // BUILD 145 — THIS EVENT IN THE MORNING BRIEF.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("IN THE MORNING BRIEF")
                                .font(.caption2).fontWeight(.heavy).tracking(0.6)
                                .foregroundColor(theme.textSecondary)
                            HStack(spacing: 8) {
                                briefChip("Calendar default", value: nil)
                                briefChip("Always spoken", value: true)
                                briefChip("Never spoken", value: false)
                            }
                        }

                        Spacer(minLength: 20)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(theme.accent)
                }
            }
        }
        .onAppear {
            level = ChappyCalendar.shared.level(for: event)
            starred = ChappyCalendar.shared.isStarred(event)   // BUILD 164
            let own = ChappyCalendar.shared.leadMinutes(for: event)
            let calDefault = event.calendar.map { ChappyCalendar.shared.leadMinutes(for: $0) } ?? 30
            lead = own == calDefault ? nil : own
        }
    }

    @State private var briefChoice: Bool?? = Bool??.none   // .none = not yet loaded

    private func briefChip(_ label: String, value: Bool?) -> some View {
        let current: Bool? = briefChoice ?? ChappyCalendar.shared.briefOverride(for: event)
        let on = current == value
        return Button {
            briefChoice = .some(value)
            ChappyCalendar.shared.setBriefOverride(value, for: event)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onChange()
        } label: {
            Text(label)
                .font(.caption).fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(on ? theme.accent.opacity(0.22) : theme.cardFill))
                .foregroundColor(on ? theme.accent : theme.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private func levelButton(_ l: ChappyCalendar.EventLevel, _ icon: String,
                             _ title: String, _ detail: String) -> some View {
        Button {
            level = l
            ChappyCalendar.shared.setLevel(l, for: event)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onChange()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(l == .important ? .orange : (l == .muted ? theme.textSecondary : theme.accent))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(theme.textPrimary)
                    Text(detail).font(.caption2).foregroundColor(theme.textSecondary)
                }
                Spacer()
                if level == l {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.accent)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(level == l ? theme.accent.opacity(0.12) : theme.cardFill))
        }
        .buttonStyle(.plain)
    }
}

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

    // BUILD 127 — TWO WAYS IN.
    //
    // The categories already existed, but only as a FILTER: tap Work and
    // everything else vanished. That tells you about one category and hides
    // the shape of everything else, which is the opposite of what a header
    // does. Now time and type are peers — Schedule answers "what's next",
    // By type answers "what have I got on", and neither hides the other.
    private enum Mode: String, CaseIterable {
        case schedule, byType, timeline, pings, lists, done
        var label: String {
            switch self {
            case .schedule: return "Schedule"
            case .byType:   return "By type"
            case .timeline: return "Timeline"
            case .pings:    return "Pings"
            case .lists:    return "Lists"
            case .done:     return "Done"
            }
        }
        // BUILD 155 — chip icons.
        var icon: String {
            switch self {
            case .schedule: return "calendar"
            case .byType:   return "square.grid.2x2"
            case .timeline: return "clock"
            case .pings:    return "bell"
            case .lists:    return "checklist"
            case .done:     return "checkmark.circle"
            }
        }
    }

    /// BUILD 134 — one row of the Pings tab: a moment Chappy will make noise.
    private struct PingItem: Identifiable {
        enum Source { case reminder(ChappyMemory.Entry), event(EKEvent), timer(ChappyTimers.Countdown) }
        let id: String
        let at: Date
        let icon: String
        let tint: Color
        let title: String
        let sub: String
        let source: Source
    }

    /// BUILD 132: a tapped diary event, wrapped so .sheet(item:) can use it.
    private struct EventPick: Identifiable {
        let id: String
        let event: EKEvent
    }
    @State private var mode: Mode = .schedule
    @State private var timelineDay = Calendar.current.startOfDay(for: Date())
    @State private var timelineEvents: [EKEvent] = []
    // BUILD 132: tap an event → its own sheet (level + per-event warn time).
    @State private var eventPick: EventPick?
    // BUILD 132: the Lists tab — expanded list id and its fetched items.
    @State private var expandedList: String?
    @State private var listItems: [String: [String]] = [:]

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme).ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        briefCard
                        modePicker
                        switch mode {
                        case .schedule:
                            categoryChips
                            suggestedSection
                            diarySection
                            section("Overdue", inFilter(reminders.overdue()), .red)
                            section("Today", inFilter(reminders.today().filter { $0.deliveredAt == nil }), theme.accent)
                            section("Waiting on a place", inFilter(reminders.placeReminders()), .cyan)
                            section("Coming up", reminders.upcoming().filter {
                                !Calendar.current.isDateInToday($0.effectiveFire ?? Date())
                            }, theme.textSecondary)
                            if reminders.open.isEmpty { empty }
                        case .byType:
                            byTypeSections
                            if reminders.open.isEmpty { empty }
                        case .timeline:
                            weekStrip
                            timelineSection
                        case .pings:
                            pingsSection
                        case .lists:
                            listsSection
                        case .done:
                            doneSection
                        }
                        Color.clear.frame(height: 60)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Diary")
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
        .sheet(item: $eventPick) { p in
            EventDetailSheet(event: p.event, theme: theme) { diaryTick += 1 }
        }
        .onAppear {
            ChappyReminders.shared.requestPermission()
            todaysEvents = ChappyCalendar.shared.today().filter {
                ($0.endDate ?? Date()) > Date()
            }
            loadTimelineEvents()
        }
    }

    // BUILD 127: Schedule / By type / Done.
    // BUILD 155: six words crammed in one row was a desktop habit — thumbs
    // need 44 points. Now a 2x3 grid of real chips with icons, the pattern
    // Google Calendar and Fantastical both settled on for phones.
    private var modePicker: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(Mode.allCases, id: \.rawValue) { m in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { mode = m }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.icon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(m.label)
                            .font(.footnote).fontWeight(.semibold)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(mode == m ? theme.accent.opacity(0.22) : Color.white.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(mode == m ? theme.accent.opacity(0.55) : Color.clear, lineWidth: 1))
                    .foregroundColor(mode == m ? theme.accent : theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    /// BUILD 127 — THE HEADERS.
    ///
    /// Every open reminder, grouped by the category it already had, with a
    /// count on each header so the shape of things is readable at a glance:
    /// Money having one item in it that happens to be overdue is a fact you
    /// can now see without tapping anything.
    ///
    /// Empty categories never appear. Inside each one, soonest first, and
    /// anything with no date at all sinks to the bottom rather than floating
    /// to the top pretending to be urgent.
    @ViewBuilder
    private var byTypeSections: some View {
        let open = reminders.open.filter { $0.doneAt == nil }
        let grouped = Dictionary(grouping: open) { ChappyReminders.category(of: $0) }
        ForEach(ChappyReminders.Category.allCases, id: \.rawValue) { cat in
            if let items = grouped[cat], !items.isEmpty {
                let sorted = items.sorted {
                    ($0.effectiveFire ?? .distantFuture) < ($1.effectiveFire ?? .distantFuture)
                }
                HStack(spacing: 7) {
                    Image(systemName: cat.icon).font(.system(size: 11, weight: .bold))
                    Text(cat.label.uppercased())
                        .font(.caption2).fontWeight(.heavy).tracking(0.6)
                    Spacer()
                    Text("\(sorted.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.textSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                }
                .foregroundColor(cat.tintColour)
                .padding(.horizontal, 20).padding(.top, 10)

                ForEach(sorted) { r in
                    ReminderRow(entry: r, theme: theme, tint: cat.tintColour)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = r }
                }
            }
        }
    }

    // MARK: - BUILD 127: TIMELINE
    //
    // The one thing no list can show you: THE GAP BETWEEN WHEN SOMETHING IS
    // DUE AND WHEN IT PINGS. A list says "2:00 PM". It does not say that the
    // notification lands at one o'clock, in the middle of lunch. Every other
    // reminder app has the same blind spot, and it is the reason a lead time
    // set once is never quite what you expected.
    //
    // Calendar events share the timeline with reminders, because at 7am a
    // thing you have to BE AT and a thing you have to DO are the same
    // question, and splitting them across two screens is exactly how one of
    // them gets missed.

    private struct Slot: Identifiable {
        let id: String
        let at: Date
        let title: String
        let tint: Color
        let sub: String
        let isPing: Bool          // dashed — this is a notification, not a deadline
        let isEvent: Bool
        // BUILD 145: what a tap opens — the event sheet or the reminder editor.
        var event: EKEvent? = nil
        var rem: ChappyMemory.Entry? = nil
    }

    /// Seven days from today. A dot means there is something on that day, so
    /// you can see next Thursday is empty without scrolling into it.
    private var weekStrip: some View {
        let cal = Calendar.current
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: cal.startOfDay(for: Date())) }
        return HStack(spacing: 6) {
            ForEach(days, id: \.timeIntervalSince1970) { d in
                let on = cal.isDate(d, inSameDayAs: timelineDay)
                let busy = reminders.open.contains {
                    guard let f = $0.effectiveFire else { return false }
                    return cal.isDate(f, inSameDayAs: d)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { timelineDay = d }
                    loadTimelineEvents()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    VStack(spacing: 1) {
                        Text(Self.weekdayLetters(d))
                            .font(.system(size: 9, weight: .heavy)).tracking(0.5)
                            .foregroundColor(on ? theme.accent : theme.textSecondary)
                        Text("\(cal.component(.day, from: d))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(on ? theme.accent : theme.textPrimary)
                        Circle().fill(busy ? theme.accent : Color.clear)
                            .frame(width: 4, height: 4).padding(.top, 1)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 11)
                        .fill(on ? theme.accent.opacity(0.16) : theme.cardFill))
                    .overlay(RoundedRectangle(cornerRadius: 11)
                        .stroke(on ? theme.accent : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private static func weekdayLetters(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE"
        return f.string(from: d).uppercased()
    }

    /// Everything happening on the chosen day, deadlines and notifications
    /// alike, laid against the clock.
    private var slots: [Slot] {
        let cal = Calendar.current
        var out: [Slot] = []

        for r in reminders.open where r.doneAt == nil {
            guard let fire = r.effectiveFire, cal.isDate(fire, inSameDayAs: timelineDay) else { continue }
            let cat = ChappyReminders.category(of: r)
            out.append(Slot(id: r.id.uuidString, at: fire, title: r.title,
                            tint: r.escalate == true ? .orange : theme.accent,
                            sub: "\(cat.label) · due", isPing: false, isEvent: false, rem: r))
            // The notification, as its own block. This is the whole point.
            if let lead = r.leadMinutes, lead > 0 {
                let at = fire.addingTimeInterval(-Double(lead) * 60)
                if cal.isDate(at, inSameDayAs: timelineDay) {
                    out.append(Slot(id: r.id.uuidString + "-ping", at: at,
                                    title: "Ping — \(r.title)", tint: .orange,
                                    sub: ChappyCalendar.leadLabel(lead) + " before it's due",
                                    isPing: true, isEvent: false))
                }
            }
        }

        for e in timelineEvents where !e.isAllDay {
            guard let s = e.startDate, cal.isDate(s, inSameDayAs: timelineDay) else { continue }
            var sub = "Diary"
            if let l = e.location, !l.isEmpty { sub += " · \(l)" }
            out.append(Slot(id: e.eventIdentifier ?? UUID().uuidString, at: s,
                            title: e.title ?? "Appointment", tint: .purple,
                            sub: sub, isPing: false, isEvent: true, event: e))
        }

        return out.sorted { $0.at < $1.at }
    }

    @ViewBuilder
    private var timelineSection: some View {
        let cal = Calendar.current
        let items = slots
        let isToday = cal.isDateInToday(timelineDay)
        // Only draw hours that are actually in play, plus a little air —
        // a timeline that starts at midnight is mostly empty space.
        let hours: [Int] = {
            guard !items.isEmpty else { return Array(7...20) }
            let lo = max(0, (items.map { cal.component(.hour, from: $0.at) }.min() ?? 7) - 1)
            let hi = min(23, (items.map { cal.component(.hour, from: $0.at) }.max() ?? 20) + 1)
            return Array(lo...hi)
        }()
        let nowHour = cal.component(.hour, from: Date())

        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "calendar.day.timeline.left")
                    .font(.system(size: 32)).foregroundColor(theme.textSecondary.opacity(0.5))
                Text(isToday ? "Nothing left today" : "Nothing on this day")
                    .font(.subheadline).foregroundColor(theme.textPrimary)
            }
            .frame(maxWidth: .infinity).padding(.top, 46)
        } else {
            VStack(spacing: 0) {
                ForEach(hours, id: \.self) { h in
                    HStack(alignment: .top, spacing: 10) {
                        Text(Self.hourLabel(h))
                            .font(.system(size: 10)).foregroundColor(theme.textSecondary)
                            .frame(width: 46, alignment: .trailing)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 6) {
                            let inHour = items.filter { cal.component(.hour, from: $0.at) == h }
                            if inHour.isEmpty {
                                Color.clear.frame(height: 16)
                            } else {
                                ForEach(inHour) { s in slotCard(s) }
                            }
                            if isToday, h == nowHour {
                                HStack(spacing: 5) {
                                    Text("NOW").font(.system(size: 8, weight: .heavy)).foregroundColor(.red)
                                    Rectangle().fill(Color.red.opacity(0.7)).frame(height: 1)
                                }
                                .padding(.vertical, 1)
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.bottom, 8)
                        .overlay(alignment: .topLeading) {
                            Circle()
                                .fill(items.contains { cal.component(.hour, from: $0.at) == h }
                                      ? theme.accent : theme.textSecondary.opacity(0.3))
                                .frame(width: 7, height: 7)
                                .offset(x: -3.5, y: 2)
                        }
                        .background(alignment: .leading) {
                            Rectangle().fill(theme.textSecondary.opacity(0.18)).frame(width: 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 4)
        }
    }

    private func slotCard(_ s: Slot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.title)
                .font(.system(size: 12.5, weight: s.isPing ? .semibold : .regular))
                .foregroundColor(s.isPing ? .orange : theme.textPrimary)
                .lineLimit(2)
            Text(s.sub).font(.system(size: 10)).foregroundColor(theme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 11).fill(s.tint.opacity(s.isPing ? 0.08 : 0.14))
                Rectangle().fill(s.tint).frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11))
        )
        .overlay(
            // Dashed means "this is a notification, not a deadline".
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: s.isPing ? [4, 3] : []))
                .foregroundColor(s.isPing ? .orange.opacity(0.55) : .clear)
        )
        // BUILD 145 — TAP ANYTHING, ANYWHERE. The Schedule tab's event sheet
        // now opens from the Timeline too; reminders open their editor.
        .contentShape(Rectangle())
        .onTapGesture {
            if let e = s.event {
                eventPick = EventPick(id: e.eventIdentifier ?? UUID().uuidString, event: e)
            } else if let r = s.rem {
                editing = r
            }
        }
    }

    private static func hourLabel(_ h: Int) -> String {
        let ampm = h < 12 ? "AM" : "PM"
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve) \(ampm)"
    }

    private func loadTimelineEvents() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: timelineDay)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        timelineEvents = ChappyCalendar.shared.events(from: start, to: end)
    }

    @ViewBuilder
    private var doneSection: some View {
        let items = reminders.done()
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle").font(.system(size: 36))
                    .foregroundColor(theme.textSecondary.opacity(0.5))
                Text("Nothing finished yet").font(.subheadline).foregroundColor(theme.textPrimary)
            }
            .frame(maxWidth: .infinity).padding(.top, 50)
        } else {
            section("Done", items, theme.textSecondary)
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
                .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                .padding(.horizontal, 16)
                // BUILD 132 — TAP THE THING. Long-press was invisible; nobody
                // finds a contextMenu they weren't told about. A tap now opens
                // the event's own sheet: importance AND its own warn time.
                .contentShape(Rectangle())
                .onTapGesture {
                    eventPick = EventPick(id: e.eventIdentifier ?? UUID().uuidString, event: e)
                }
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

    // BUILD 145 — LISTS BY HAND (the Keep model). Voice stays the fast door;
    // this is the visible one. Name it, type items comma-separated, done —
    // the geofenced "pings you near a shop" magic attaches automatically.
    @State private var showNewList = false
    @State private var newListName = ""
    @State private var newListItems = ""

    private var newListButton: some View {
        Button { showNewList = true } label: {
            HStack {
                Image(systemName: "plus.circle.fill").foregroundColor(.mint)
                Text("New list").font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Text("or say \u{201C}add milk to the shopping list\u{201D}")
                    .font(.caption2).foregroundColor(theme.textSecondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showNewList) {
            NavigationView {
                Form {
                    Section("List name") {
                        TextField("Shopping", text: $newListName)
                    }
                    Section("Items — separate with commas") {
                        TextField("milk, bread, batteries", text: $newListItems, axis: .vertical)
                            .lineLimit(3...6)
                    }
                    Section {
                        Button("Create") {
                            let name = newListName.trimmingCharacters(in: .whitespaces)
                            let items = newListItems.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            guard !name.isEmpty, !items.isEmpty else { return }
                            Task {
                                _ = await ChappyLists.shared.addItems(items, toListNamed: name, placeHint: name)
                                listItems.removeValue(forKey: name)
                            }
                            newListName = ""; newListItems = ""
                            showNewList = false
                        }
                        .disabled(newListName.trimmingCharacters(in: .whitespaces).isEmpty)
                    } footer: {
                        Text("The list pings you on its own when you're near a shop that has what's on it.")
                    }
                }
                .navigationTitle("New list")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { showNewList = false }
                    }
                }
            }
        }
    }

    // BUILD 140 — SUGGESTED. Chappy's proposals for the day: a get-ready
    // nudge per appointment, a time for anything that has none. One tap
    // accepts one; "Chappy, plan my day" accepts the lot by voice. They
    // vanish as they're accepted because the store now covers them.
    @State private var suggTick = 0

    @ViewBuilder
    private var suggestedSection: some View {
        let sugg = reminders.suggestions()
        if !sugg.isEmpty {
            Text("SUGGESTED — TAP ✓ TO SET")
                .font(.caption2).fontWeight(.heavy).tracking(0.6)
                .foregroundColor(.orange)
                .padding(.horizontal, 20).padding(.top, 8)
                .id(suggTick)
            ForEach(sugg) { s in
                HStack(spacing: 10) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 13)).foregroundColor(.orange)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(s.title) · \(Self.time(s.fire))")
                            .font(.subheadline).foregroundColor(theme.textPrimary)
                            .lineLimit(1)
                        Text(s.reason)
                            .font(.caption2).foregroundColor(theme.textSecondary)
                    }
                    Spacer()
                    Button {
                        _ = ChappyDataBridge.addReminder(text: s.title, at: s.fire)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        suggTick += 1
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22)).foregroundColor(.green)
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 13)
                    .fill(Color.orange.opacity(0.08)))
                .padding(.horizontal, 16)
                .chappyScrollFX()
            }
        }
    }

    // BUILD 134 — THE PINGS TAB.
    //
    // The question this answers: "what is going to make noise, and when?"
    // Every future ping for the next 7 days, shown at the moment it will
    // FIRE — a heads-up set 30 minutes before a 3pm job appears at 2:30, not
    // at 3. Reminders open their editor on tap (change it, delete it),
    // calendar heads-ups open the event sheet (change the warn time, mute
    // it), timers show what's left. What you see here is what you'll hear.

    private func pingItems() -> [PingItem] {
        var items: [PingItem] = []
        let now = Date()
        let horizon = now.addingTimeInterval(7 * 86400)
        let df = DateFormatter(); df.dateFormat = "h:mm a"

        // Reminders, at their effective fire time.
        for r in reminders.open where r.doneAt == nil {
            guard let f = r.effectiveFire, f > now, f < horizon else { continue }
            var sub = "Reminder"
            if r.snoozedTo != nil, r.snoozedTo! > now { sub = "Snoozed reminder" }
            else if r.repeatRule != nil { sub = "Repeating reminder" }
            items.append(PingItem(id: "r-\(r.id)", at: f, icon: "bell.fill",
                                  tint: theme.accent, title: r.title, sub: sub,
                                  source: .reminder(r)))
        }
        // Place-triggered reminders have no clock — shown once, at the top of
        // the list via distantPast+1 so they're visible but not scheduled.
        for r in reminders.placeReminders() {
            items.append(PingItem(id: "p-\(r.id)", at: now.addingTimeInterval(-1),
                                  icon: "mappin.circle.fill", tint: .cyan,
                                  title: r.title,
                                  sub: "Fires near: \(r.placeTrigger ?? "a place")",
                                  source: .reminder(r)))
        }
        // Calendar heads-ups, at start minus lead. Important events ping twice.
        let cal = ChappyCalendar.shared
        for e in cal.upcoming(days: 7) where !e.isAllDay {
            guard cal.effectiveBehaviour(for: e) == .ping, let s = e.startDate else { continue }
            let lead = cal.leadMinutes(for: e)
            let important = cal.level(for: e) == .important
            var fires: [(Date, String)] = [(s.addingTimeInterval(-Double(lead) * 60),
                                            ChappyCalendar.leadLabel(lead))]
            if important {
                fires.append((s.addingTimeInterval(-86400), "the day before"))
            }
            for (f, label) in fires where f > now && f < horizon {
                items.append(PingItem(
                    id: "e-\(ChappyCalendar.fingerprint(e))-\(Int(f.timeIntervalSince1970))",
                    at: f,
                    icon: important ? "flag.fill" : "clock.badge",
                    tint: important ? .orange : .purple,
                    title: "\(e.title ?? "Appointment") at \(df.string(from: s))",
                    sub: "Heads-up, \(label)",
                    source: .event(e)))
            }
        }
        // Timers.
        for t in ChappyTimers.shared.active where !t.isExpired {
            items.append(PingItem(id: "t-\(t.id)", at: t.fireAt, icon: "timer",
                                  tint: .mint, title: t.name,
                                  sub: "Timer", source: .timer(t)))
        }
        return items.sorted { $0.at < $1.at }
    }

    @ViewBuilder
    private var pingsSection: some View {
        let items = pingItems()
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 32)).foregroundColor(theme.textSecondary.opacity(0.5))
                Text("Nothing will ping in the next 7 days")
                    .font(.subheadline).foregroundColor(theme.textPrimary)
            }
            .frame(maxWidth: .infinity).padding(.top, 46)
        } else {
            let grouped = Dictionary(grouping: items) { pingDayLabel($0.at) }
            let order = items.map { pingDayLabel($0.at) }.reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            ForEach(order, id: \.self) { day in
                Text(day.uppercased())
                    .font(.caption2).fontWeight(.heavy).tracking(0.6)
                    .foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 20).padding(.top, 10)
                ForEach(grouped[day] ?? []) { item in pingRow(item).chappyScrollFX() }
            }
            Text("Tap a ping to change or clear it. This list is exactly what will make noise.")
                .font(.caption2).foregroundColor(theme.textSecondary)
                .padding(.horizontal, 20).padding(.top, 6)
        }
    }

    private func pingDayLabel(_ d: Date) -> String {
        if d < Date() { return "Whenever you're near" }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEEE d MMM"; return f.string(from: d)
    }

    private func pingRow(_ item: PingItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 1) {
                if item.at > Date() {
                    Text(Self.time(item.at))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(item.tint)
                }
                Image(systemName: item.icon)
                    .font(.system(size: 13)).foregroundColor(item.tint)
            }
            .frame(width: 62)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline).foregroundColor(theme.textPrimary).lineLimit(2)
                Text(item.sub)
                    .font(.caption2).foregroundColor(theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11)).foregroundColor(theme.textSecondary.opacity(0.5))
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 13).fill(.ultraThinMaterial))
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            switch item.source {
            case .reminder(let r): editing = r
            case .event(let e):
                eventPick = EventPick(id: e.eventIdentifier ?? UUID().uuidString, event: e)
            case .timer: break
            }
        }
        .contextMenu {
            switch item.source {
            case .reminder(let r):
                Button { editing = r } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) {
                    reminders.complete(r.id)
                } label: { Label("Done — clear it", systemImage: "checkmark.circle") }
            case .event(let e):
                Button {
                    eventPick = EventPick(id: e.eventIdentifier ?? UUID().uuidString, event: e)
                } label: { Label("Change the warning", systemImage: "clock") }
                Button {
                    ChappyCalendar.shared.setLevel(.muted, for: e); diaryTick += 1
                } label: { Label("Mute this one", systemImage: "bell.slash") }
            case .timer(let t):
                Button(role: .destructive) {
                    _ = ChappyTimers.shared.cancel(matching: t.name)
                } label: { Label("Cancel timer", systemImage: "xmark.circle") }
            }
        }
    }

    // BUILD 132 — THE LISTS TAB.
    //
    // The self-alerting lists (the ones that ping when you're near a shop
    // that sells what's on them) existed only as voice: "add milk to the
    // shopping list" worked, but there was nowhere to SEE them. Now they
    // live where every other obligation lives. Tap a list to unfold it.
    @ViewBuilder
    private var listsSection: some View {
        let all = ChappyLists.shared.lists
        newListButton
        if all.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 32)).foregroundColor(theme.textSecondary.opacity(0.5))
                Text("No lists yet").font(.subheadline).foregroundColor(theme.textPrimary)
                Text("Say: \u{201C}Chappy, add milk to the shopping list\u{201D}\nA list pings you when you're near a shop that has it.")
                    .font(.caption).foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.top, 46)
        } else {
            ForEach(all) { l in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "checklist")
                            .font(.system(size: 17)).foregroundColor(.mint)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.name)
                                .font(.subheadline).fontWeight(.semibold)
                                .foregroundColor(theme.textPrimary)
                            Text(l.placeHint.isEmpty
                                 ? "Pings near a matching shop"
                                 : "Pings near: \(l.placeHint)")
                                .font(.caption2).foregroundColor(theme.textSecondary)
                        }
                        Spacer()
                        if let items = listItems[l.id] {
                            Text("\(items.count)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(theme.textSecondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                        Image(systemName: expandedList == l.id ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.textSecondary)
                    }
                    if expandedList == l.id {
                        if let items = listItems[l.id], !items.isEmpty {
                            ForEach(items, id: \.self) { item in
                                // BUILD 145 — TAP TO TICK. Voice still works
                                // ("got the milk"); now a finger does too.
                                Button {
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    Task {
                                        _ = await ChappyLists.shared.complete([item])
                                        let open = await ChappyLists.shared.openItems(listID: l.id)
                                        listItems[l.id] = open.compactMap { $0.title }
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "circle")
                                            .font(.system(size: 9)).foregroundColor(.mint)
                                        Text(item).font(.caption).foregroundColor(theme.textPrimary)
                                        Spacer()
                                        Text("tap to tick")
                                            .font(.system(size: 8)).foregroundColor(theme.textSecondary.opacity(0.6))
                                    }
                                    .padding(.leading, 46)
                                }
                                .buttonStyle(.plain)
                            }
                            Text("Say \u{201C}Chappy, got the milk\u{201D} to tick one off.")
                                .font(.caption2).foregroundColor(theme.textSecondary)
                                .padding(.leading, 46).padding(.top, 2)
                        } else {
                            Text(listItems[l.id] == nil ? "Loading…" : "Everything's ticked off.")
                                .font(.caption).foregroundColor(theme.textSecondary)
                                .padding(.leading, 46)
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        expandedList = expandedList == l.id ? nil : l.id
                    }
                    guard listItems[l.id] == nil else { return }
                    Task {
                        let open = await ChappyLists.shared.openItems(listID: l.id)
                        listItems[l.id] = open.compactMap { $0.title }
                    }
                }
            }
            Text("Lists ping on their own when you pass a shop that has what's on them.")
                .font(.caption2).foregroundColor(theme.textSecondary)
                .padding(.horizontal, 20).padding(.top, 4)
        }
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
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
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

// MARK: - BUILD 127: reminder row
//
// The row said what a thing was called and when it was due. It did not say
// what KIND of thing it was, when it would actually interrupt you, or give you
// any way to act on it — and "pick up the visa photos" without a map link is a
// reminder that reminds you of a job you still have to go and start.
//
// Four additions, each earning its place rather than appearing on everything:
// a coloured edge for urgency, a type pill, the ping time spelled out, and
// ONE action button — a map where there is somewhere to go, a search where
// there is something to look up, nothing where neither applies.
extension ChappyReminders.Category {
    var tintColour: Color {
        switch self {
        case .work:    return .purple
        case .travel:  return .cyan
        case .money:   return .orange
        case .places:  return .green
        case .health:  return .pink
        case .home:    return .blue
        case .general: return .gray
        }
    }
}

struct ReminderRow: View {
    let entry: ChappyMemory.Entry
    let theme: ChappyTheme
    let tint: Color

    private var category: ChappyReminders.Category { ChappyReminders.category(of: entry) }

    /// Red when it has already passed, amber when it is flagged, otherwise the
    /// theme accent. The edge is the fastest read on the whole screen.
    private var edgeColour: Color {
        if entry.doneAt != nil { return theme.textSecondary.opacity(0.4) }
        if let f = entry.effectiveFire, f < Date() { return .red }
        if entry.escalate == true { return .orange }
        return theme.accent
    }

    /// When it will actually interrupt you, which is not the same as when it
    /// is due — and was previously invisible everywhere in the app.
    private var pingText: String? {
        guard entry.doneAt == nil,
              let lead = entry.leadMinutes, lead > 0,
              let fire = entry.effectiveFire else { return nil }
        let at = fire.addingTimeInterval(-Double(lead) * 60)
        guard at > Date() else { return nil }
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        return "pings \(df.string(from: at))"
    }

    /// Somewhere to go: real coordinates, or a named place trigger.
    private var hasSomewhereToGo: Bool {
        (entry.lat != nil && entry.lon != nil) || (entry.placeTrigger?.isEmpty == false) || (entry.place?.isEmpty == false)
    }

    /// Straight-line kilometres, when both ends are known.
    private var distanceKm: Double? {
        guard let la = entry.lat, let lo = entry.lon else { return nil }
        let snap = ContextEngine.shared.snapshot
        guard let mla = snap.latitude, let mlo = snap.longitude else { return nil }
        let here = CLLocation(latitude: mla, longitude: mlo)
        return here.distance(from: CLLocation(latitude: la, longitude: lo)) / 1000.0
    }

    /// Reminders that are a QUESTION rather than an errand. Deliberately a
    /// short, specific list — a magnifier on every row would be clutter, and
    /// clutter is how a useful button stops being noticed.
    private static let lookupWords = [
        "check", "look up", "lookup", "find out", "how much", "what time",
        "price", "cost", "allowance", "opening hours", "compare", "research",
        "google", "book ", "rate", "exchange"
    ]
    private var isLookup: Bool {
        guard !hasSomewhereToGo else { return false }
        let t = entry.title.lowercased()
        return Self.lookupWords.contains { t.contains($0) }
    }

    /// Distance decides the mode, the same rule navigation uses. Nobody walks
    /// twelve kilometres to a job.
    private func openMap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let mode = (distanceKm ?? 99) > 1.0 ? "driving" : "walking"
        var url: URL?
        if let la = entry.lat, let lo = entry.lon {
            url = URL(string: "comgooglemaps://?daddr=\(la),\(lo)&directionsmode=\(mode)")
            if url == nil || !UIApplication.shared.canOpenURL(url!) {
                url = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(la),\(lo)&travelmode=\(mode)")
            }
        } else {
            let name = entry.placeTrigger ?? entry.place ?? entry.title
            let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            url = URL(string: "https://www.google.com/maps/search/?api=1&query=\(q)")
        }
        if let url { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
    }

    private func openSearch() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let q = entry.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://www.google.com/search?q=\(q)") {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

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
                    // BUILD 127: when it will actually interrupt you.
                    if let ping = pingText {
                        Text("· \(ping)")
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                    // BUILD 127: how far, when we know — so the map button's
                    // driving-or-walking choice is visible before you tap it.
                    if let km = distanceKm, km > 0.05 {
                        Text(km < 1 ? "· \(Int(km * 1000)) m" : String(format: "· %.1f km", km))
                            .lineLimit(1)
                    }
                }
                .font(.caption2).foregroundColor(theme.textSecondary)

                // BUILD 127: what KIND of thing this is, without reading it.
                Text(category.label.uppercased())
                    .font(.system(size: 8.5, weight: .heavy))
                    .tracking(0.5)
                    .foregroundColor(category.tintColour)
                    .padding(.horizontal, 6).padding(.vertical, 2.5)
                    .background(Capsule().fill(category.tintColour.opacity(0.16)))
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)

            // BUILD 127: ONE action, only where there is one worth having.
            if entry.doneAt == nil {
                if hasSomewhereToGo {
                    Button(action: openMap) {
                        Image(systemName: "map.fill").font(.system(size: 13))
                            .foregroundColor(theme.accent)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 9).fill(theme.accent.opacity(0.14)))
                    }.buttonStyle(.plain)
                } else if isLookup {
                    Button(action: openSearch) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13))
                            .foregroundColor(theme.accent)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 9).fill(theme.accent.opacity(0.14)))
                    }.buttonStyle(.plain)
                }
            }

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
        .background(
            // BUILD 127: the urgency edge. Fastest read on the screen — red
            // means it has already passed, amber means it was flagged.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial)
                Rectangle().fill(edgeColour).frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        )
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

    // BUILD 127 — WARN ME.
    //
    // `leadMinutes` existed on the model and was only ever set to 5, and only
    // for leave-by. So every timed reminder in the app fired at the moment it
    // was due and not a second earlier — which is useless for anything you
    // have to DO something about. "Check in for the flight at 2pm" arriving at
    // 2pm is a notification about a thing you are already late for.
    //
    // Discrete steps rather than a free scrub, because nobody wants 23 minutes
    // — and the readout names the actual clock time it will land, so you can
    // see the consequence while you are choosing it instead of finding out
    // tomorrow.
    private static let leadSteps: [Int] = [0, 5, 10, 15, 30, 60, 120, 240, 720, 1440]
    @State private var leadIndex: Double = 0

    private var leadMinutes: Int { Self.leadSteps[min(Int(leadIndex), Self.leadSteps.count - 1)] }

    private var leadReadout: String {
        let m = leadMinutes
        guard m > 0 else { return "On time — no early warning" }
        let base: Date? = mode == 0 ? date : (mode == 1 ? floating : nil)
        let name = ChappyCalendar.leadLabel(m)
        guard let base else { return "\(name) before" }
        let at = base.addingTimeInterval(-Double(m) * 60)
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        return "\(name) before — pings \(df.string(from: at))"
    }

    /// The four times he actually uses. Typing a date is the slow path.
    private var quickTimes: [(String, Date)] {
        let cal = Calendar.current
        let now = Date()
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        let nextWeek = cal.date(byAdding: .day, value: 7, to: now) ?? now
        return [
            ("In an hour", now.addingTimeInterval(3600)),
            ("Tonight 7pm", cal.date(bySettingHour: 19, minute: 0, second: 0, of: now) ?? now),
            ("Tomorrow 8am", cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow),
            ("Next week", cal.date(bySettingHour: 9, minute: 0, second: 0, of: nextWeek) ?? nextWeek)
        ]
    }

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
                        // BUILD 127: presets first, picker underneath. Four
                        // taps cover almost everything; the picker is there
                        // for the fifth case, not for the first four.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(quickTimes, id: \.0) { label, when in
                                    let on = abs(date.timeIntervalSince(when)) < 60
                                    Button {
                                        date = when
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    } label: {
                                        Text(label)
                                            .font(.caption).fontWeight(.medium)
                                            .padding(.horizontal, 11).padding(.vertical, 6)
                                            .background(Capsule().fill(on
                                                ? theme.accent.opacity(0.22)
                                                : Color.secondary.opacity(0.14)))
                                            .foregroundColor(on ? theme.accent : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
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
                // BUILD 127 — the slider that makes lead times real.
                if mode != 2 {
                    Section("Warn me") {
                        Slider(value: $leadIndex, in: 0...Double(Self.leadSteps.count - 1), step: 1)
                            .tint(theme.accent)
                        HStack(spacing: 0) {
                            Text("On time").font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Text("15m").font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Text("1h").font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Text("1d").font(.caption2).foregroundColor(.secondary)
                        }
                        Text(leadReadout)
                            .font(.footnote).fontWeight(.medium)
                            .foregroundColor(leadMinutes > 0 ? theme.accent : .secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
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
        // BUILD 127: bring the existing lead back onto the slider, snapping to
        // the nearest step so a value set by voice ("half an hour before")
        // still lands somewhere sensible rather than resetting to zero.
        if let lead = e.leadMinutes, lead > 0,
           let idx = Self.leadSteps.enumerated().min(by: {
               abs($0.element - lead) < abs($1.element - lead)
           })?.offset {
            leadIndex = Double(idx)
        }
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
            // BUILD 127: the slider now owns this for timed reminders; the
            // leave-by toggle still owns it for place ones.
            c.leadMinutes = mode == 2 ? (leaveBy ? 5 : nil) : (leadMinutes > 0 ? leadMinutes : nil)
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
                                       leadMinutes: mode == 2 ? (leaveBy ? 5 : nil)
                                                                : (leadMinutes > 0 ? leadMinutes : nil),
                                       escalate: escalate,
                                       source: "typed")
        }
        dismiss()
    }
}

// =====================================================================
// MARK: - CHAPPY AIRPORTS (Build 155) — the offline autocomplete table
// =====================================================================
//
//   ~90 airports that cover how Shaun actually flies: all of Australia,
//   all of South-East Asia, and the majors beyond. Matching is dumb and
//   instant — code, city, name, or a nickname ("bali") — no network,
//   no key. Amadeus still does the authoritative lookup at watch time.

enum ChappyAirports {

    struct Airport { let code: String; let city: String; let name: String; let alts: [String] }

    static func search(_ q: String) -> [Airport] {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.count >= 2 else { return [] }
        return table.filter { a in
            a.code.lowercased().hasPrefix(t)
                || a.city.lowercased().contains(t)
                || a.name.lowercased().contains(t)
                || a.alts.contains(where: { $0.contains(t) })
        }
    }

    static let table: [Airport] = [
        .init(code: "BNE", city: "Brisbane", name: "Brisbane Airport", alts: []),
        .init(code: "SYD", city: "Sydney", name: "Kingsford Smith", alts: []),
        .init(code: "MEL", city: "Melbourne", name: "Tullamarine", alts: []),
        .init(code: "OOL", city: "Gold Coast", name: "Coolangatta", alts: ["gold coast"]),
        .init(code: "CNS", city: "Cairns", name: "Cairns Airport", alts: []),
        .init(code: "TSV", city: "Townsville", name: "Townsville Airport", alts: []),
        .init(code: "MKY", city: "Mackay", name: "Mackay Airport", alts: []),
        .init(code: "ROK", city: "Rockhampton", name: "Rockhampton Airport", alts: []),
        .init(code: "PER", city: "Perth", name: "Perth Airport", alts: []),
        .init(code: "ADL", city: "Adelaide", name: "Adelaide Airport", alts: []),
        .init(code: "CBR", city: "Canberra", name: "Canberra Airport", alts: []),
        .init(code: "HBA", city: "Hobart", name: "Hobart Airport", alts: []),
        .init(code: "DRW", city: "Darwin", name: "Darwin Airport", alts: []),
        .init(code: "LST", city: "Launceston", name: "Launceston Airport", alts: []),
        .init(code: "NTL", city: "Newcastle", name: "Williamtown", alts: []),
        .init(code: "SUN", city: "Sunshine Coast", name: "Maroochydore", alts: ["maroochydore", "sunshine coast"]),
        .init(code: "DPS", city: "Denpasar (Bali)", name: "Ngurah Rai", alts: ["bali", "kuta", "seminyak", "ubud"]),
        .init(code: "CGK", city: "Jakarta", name: "Soekarno-Hatta", alts: []),
        .init(code: "SUB", city: "Surabaya", name: "Juanda", alts: []),
        .init(code: "LOP", city: "Lombok", name: "Lombok Intl", alts: ["lombok"]),
        .init(code: "JOG", city: "Yogyakarta", name: "YIA", alts: []),
        .init(code: "SIN", city: "Singapore", name: "Changi", alts: []),
        .init(code: "KUL", city: "Kuala Lumpur", name: "KLIA", alts: []),
        .init(code: "BKK", city: "Bangkok", name: "Suvarnabhumi", alts: []),
        .init(code: "DMK", city: "Bangkok", name: "Don Mueang", alts: []),
        .init(code: "HKT", city: "Phuket", name: "Phuket Intl", alts: []),
        .init(code: "CNX", city: "Chiang Mai", name: "Chiang Mai Intl", alts: []),
        .init(code: "USM", city: "Koh Samui", name: "Samui", alts: ["samui"]),
        .init(code: "SGN", city: "Ho Chi Minh City", name: "Tan Son Nhat", alts: ["saigon"]),
        .init(code: "HAN", city: "Hanoi", name: "Noi Bai", alts: []),
        .init(code: "DAD", city: "Da Nang", name: "Da Nang Intl", alts: []),
        .init(code: "MNL", city: "Manila", name: "Ninoy Aquino", alts: []),
        .init(code: "CEB", city: "Cebu", name: "Mactan-Cebu", alts: []),
        .init(code: "PNH", city: "Phnom Penh", name: "Phnom Penh Intl", alts: []),
        .init(code: "REP", city: "Siem Reap", name: "Siem Reap-Angkor", alts: ["angkor"]),
        .init(code: "VTE", city: "Vientiane", name: "Wattay", alts: []),
        .init(code: "RGN", city: "Yangon", name: "Yangon Intl", alts: []),
        .init(code: "BWN", city: "Brunei", name: "Brunei Intl", alts: []),
        .init(code: "HKG", city: "Hong Kong", name: "Chek Lap Kok", alts: []),
        .init(code: "TPE", city: "Taipei", name: "Taoyuan", alts: []),
        .init(code: "NRT", city: "Tokyo", name: "Narita", alts: []),
        .init(code: "HND", city: "Tokyo", name: "Haneda", alts: []),
        .init(code: "KIX", city: "Osaka", name: "Kansai", alts: []),
        .init(code: "ICN", city: "Seoul", name: "Incheon", alts: []),
        .init(code: "PVG", city: "Shanghai", name: "Pudong", alts: []),
        .init(code: "PEK", city: "Beijing", name: "Capital", alts: []),
        .init(code: "CAN", city: "Guangzhou", name: "Baiyun", alts: []),
        .init(code: "DEL", city: "Delhi", name: "Indira Gandhi", alts: []),
        .init(code: "BOM", city: "Mumbai", name: "Chhatrapati Shivaji", alts: []),
        .init(code: "CMB", city: "Colombo", name: "Bandaranaike", alts: []),
        .init(code: "MLE", city: "Maldives", name: "Velana", alts: ["male", "maldives"]),
        .init(code: "DXB", city: "Dubai", name: "Dubai Intl", alts: []),
        .init(code: "AUH", city: "Abu Dhabi", name: "Zayed Intl", alts: []),
        .init(code: "DOH", city: "Doha", name: "Hamad", alts: []),
        .init(code: "AKL", city: "Auckland", name: "Auckland Airport", alts: []),
        .init(code: "WLG", city: "Wellington", name: "Wellington Airport", alts: []),
        .init(code: "CHC", city: "Christchurch", name: "Christchurch Airport", alts: []),
        .init(code: "ZQN", city: "Queenstown", name: "Queenstown Airport", alts: []),
        .init(code: "NAN", city: "Fiji (Nadi)", name: "Nadi Intl", alts: ["fiji"]),
        .init(code: "POM", city: "Port Moresby", name: "Jacksons", alts: []),
        .init(code: "NOU", city: "Noumea", name: "La Tontouta", alts: []),
        .init(code: "PPT", city: "Tahiti", name: "Faa'a", alts: ["tahiti"]),
        .init(code: "HNL", city: "Honolulu", name: "Daniel K. Inouye", alts: ["hawaii"]),
        .init(code: "LAX", city: "Los Angeles", name: "LAX", alts: []),
        .init(code: "SFO", city: "San Francisco", name: "SFO", alts: []),
        .init(code: "JFK", city: "New York", name: "JFK", alts: []),
        .init(code: "YVR", city: "Vancouver", name: "Vancouver Intl", alts: []),
        .init(code: "MEX", city: "Mexico City", name: "Benito Juarez", alts: []),
        .init(code: "GRU", city: "Sao Paulo", name: "Guarulhos", alts: []),
        .init(code: "EZE", city: "Buenos Aires", name: "Ezeiza", alts: []),
        .init(code: "LHR", city: "London", name: "Heathrow", alts: []),
        .init(code: "LGW", city: "London", name: "Gatwick", alts: []),
        .init(code: "CDG", city: "Paris", name: "Charles de Gaulle", alts: []),
        .init(code: "AMS", city: "Amsterdam", name: "Schiphol", alts: []),
        .init(code: "FRA", city: "Frankfurt", name: "Frankfurt Airport", alts: []),
        .init(code: "MUC", city: "Munich", name: "Munich Airport", alts: []),
        .init(code: "ZRH", city: "Zurich", name: "Zurich Airport", alts: []),
        .init(code: "FCO", city: "Rome", name: "Fiumicino", alts: []),
        .init(code: "MAD", city: "Madrid", name: "Barajas", alts: []),
        .init(code: "BCN", city: "Barcelona", name: "El Prat", alts: []),
        .init(code: "ATH", city: "Athens", name: "Eleftherios Venizelos", alts: []),
        .init(code: "IST", city: "Istanbul", name: "Istanbul Airport", alts: []),
        .init(code: "JNB", city: "Johannesburg", name: "O.R. Tambo", alts: []),
        .init(code: "CPT", city: "Cape Town", name: "Cape Town Intl", alts: []),
        .init(code: "CAI", city: "Cairo", name: "Cairo Intl", alts: []),
        .init(code: "MRU", city: "Mauritius", name: "SSR Intl", alts: ["mauritius"]),
    ]
}

// =====================================================================
// MARK: - ATLAS VIEW (Build 156)
// =====================================================================
//
//   The map that makes the whole thing feel like a life rather than a
//   log. Opens at country scale with every journey drawn — cyan for
//   flights, teal for driving, green on foot — each line laid down
//   twice so it GLOWS: a wide soft stroke underneath, a bright thin one
//   on top. Zoom in and Apple's own places light up, live, tappable,
//   free. Chips toggle waterfalls, temples, lookouts, transport. The
//   weather where you're looking sits in the corner with a door
//   through to Zoom Earth's live satellite.

struct AtlasView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var atlas = ChappyAtlas.shared
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @State private var camera: MapCameraPosition = .automatic
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -27.47, longitude: 153.02),
        span: MKCoordinateSpan(latitudeDelta: 12, longitudeDelta: 12))
    @State private var span: ChappyAtlas.Span = .all
    @State private var layers: Set<ChappyAtlas.Layer> = []
    @State private var places: [ChappyAtlas.Place] = []
    @State private var searching = false
    @State private var selectedStop: ChappyAtlas.Stop?
    @State private var selectedPlace: ChappyAtlas.Place?
    @State private var weather: ChappyAtlas.Weather?
    @State private var satellite = false
    @State private var pulse = false
    @State private var showLegend = false

    var initialTarget: String?
    var initialLayer: ChappyAtlas.Layer?

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                map.ignoresSafeArea(edges: .bottom)
                topFurniture
                VStack {
                    Spacer()
                    if let s = selectedStop { stopCard(s) }
                    else if let p = selectedPlace { placeCard(p) }
                    else { bottomBar }
                }
            }
            .navigationTitle("Atlas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(theme.accent)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        satellite.toggle()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: satellite ? "globe.americas.fill" : "map")
                            .foregroundColor(theme.accent)
                    }
                }
            }
            .task {
                atlas.build(span: span)
                pulse = true
                if let t = initialTarget { await flyTo(t) }
                if let l = initialLayer {
                    layers.insert(l)
                    await refreshPlaces()
                }
                await refreshWeather()
            }
        }
    }

    private var map: some View {
        Map(position: $camera) {
            ForEach(atlas.legs) { leg in
                MapPolyline(coordinates: leg.coords)
                    .stroke(leg.mode.tint.opacity(0.22), style: StrokeStyle(
                        lineWidth: 11, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: leg.coords)
                    .stroke(leg.mode.tint.opacity(0.95), style: StrokeStyle(
                        lineWidth: 3, lineCap: .round, lineJoin: .round,
                        dash: leg.mode == .flight ? [9, 7] : []))
            }
            ForEach(atlas.stops) { stop in
                Annotation(stop.name, coordinate: stop.coord, anchor: .center) {
                    Button {
                        withAnimation(.spring(response: 0.35)) {
                            selectedPlace = nil
                            selectedStop = stop
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: { stopGlyph(stop) }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
            ForEach(places) { p in
                Annotation(p.name, coordinate: p.coord, anchor: .bottom) {
                    Button {
                        withAnimation(.spring(response: 0.35)) {
                            selectedStop = nil
                            selectedPlace = p
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: p.layer.icon)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Circle().fill(p.layer.tint))
                                .shadow(color: p.layer.tint.opacity(0.8), radius: 6)
                            Text(p.name)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(.black.opacity(0.55)))
                                .lineLimit(1).frame(maxWidth: 96)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
            UserAnnotation()
        }
        .mapStyle(satellite
                  ? .hybrid(elevation: .realistic, pointsOfInterest: .all)
                  : .standard(elevation: .realistic, pointsOfInterest: .all))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { ctx in
            region = ctx.region
            Task {
                await refreshWeather()
                if !layers.isEmpty { await refreshPlaces() }
            }
        }
    }

    /// Home gets a house, starred places a star, everywhere else a dot
    /// that grows with how often you've been — the "you keep coming back
    /// here" signal Google Timeline never draws.
    @ViewBuilder
    private func stopGlyph(_ s: ChappyAtlas.Stop) -> some View {
        let size: CGFloat = s.isHome ? 30 : (s.starred ? 26 : min(12 + CGFloat(s.visits) * 2, 24))
        ZStack {
            Circle()
                .fill(glowTint(s).opacity(0.28))
                .frame(width: size * 2.1, height: size * 2.1)
                .blur(radius: 5)
                .scaleEffect(pulse && (s.isHome || s.starred) ? 1.12 : 0.95)
                .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: pulse)
            Circle()
                .fill(glowTint(s))
                .frame(width: size, height: size)
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
                .shadow(color: glowTint(s).opacity(0.9), radius: 6)
            if s.isHome {
                Image(systemName: "house.fill").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            } else if s.starred {
                Image(systemName: "star.fill").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            } else if s.photos > 0 {
                Image(systemName: "camera.fill").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func glowTint(_ s: ChappyAtlas.Stop) -> Color {
        if s.isHome { return Color(red: 1.0, green: 0.45, blue: 0.35) }
        if s.starred { return .yellow }
        if s.visits >= 4 { return Color(red: 0.55, green: 0.45, blue: 1.0) }
        return theme.accent
    }

    private var topFurniture: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(ChappyAtlas.Layer.allCases) { l in
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                if layers.contains(l) { layers.remove(l) } else { layers.insert(l) }
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            Task { await refreshPlaces() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: l.icon).font(.system(size: 11, weight: .bold))
                                Text(l.label).font(.caption).fontWeight(.semibold)
                            }
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Capsule().fill(layers.contains(l)
                                ? l.tint.opacity(0.9) : Color.black.opacity(0.45)))
                            .foregroundStyle(layers.contains(l) ? .white : .white.opacity(0.75))
                            .shadow(color: layers.contains(l) ? l.tint.opacity(0.7) : .clear, radius: 7)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                if let w = weather {
                    Button {
                        if let u = ChappyAtlas.zoomEarthURL(region.center, zoom: zoomLevel()) {
                            UIApplication.shared.open(u, options: [:], completionHandler: nil)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: w.icon).font(.caption).foregroundStyle(.cyan)
                            Text(w.line).font(.caption).fontWeight(.semibold)
                                .foregroundStyle(.white)
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(.plain)
                }
                if searching { ProgressView().scaleEffect(0.7).tint(.white) }
                Spacer()
                Button { withAnimation { showLegend.toggle() } } label: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(7)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            if showLegend { legend }
        }
        .padding(.top, 6)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach([ChappyAtlas.Mode.flight, .drive, .walk], id: \.rawValue) { m in
                HStack(spacing: 7) {
                    Capsule().fill(m.tint).frame(width: 20, height: 3)
                        .shadow(color: m.tint, radius: 4)
                    Image(systemName: m.icon).font(.system(size: 10)).foregroundStyle(m.tint)
                    Text(m.label).font(.caption2).foregroundStyle(.white.opacity(0.85))
                }
            }
            Divider().background(.white.opacity(0.2))
            Text("House = home · Star = starred · bigger dot = more visits")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
            Text("Say: \u{201C}zoom to Ubud\u{201D} · \u{201C}show me temples\u{201D} · \u{201C}where have I been\u{201D}")
                .font(.system(size: 10)).foregroundStyle(.cyan.opacity(0.9))
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        .padding(.horizontal, 12)
    }

    private var bottomBar: some View {
        VStack(spacing: 7) {
            if !atlas.summary.isEmpty {
                Text(atlas.summary)
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
            HStack(spacing: 6) {
                ForEach(ChappyAtlas.Span.allCases, id: \.rawValue) { s in
                    Button {
                        span = s
                        atlas.build(span: s)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(s.rawValue)
                            .font(.caption2).fontWeight(.bold)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Capsule().fill(span == s
                                ? theme.accent.opacity(0.9) : Color.black.opacity(0.45)))
                            .foregroundStyle(span == s ? .white : .white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        camera = .region(atlas.homeRegion())
                    }
                } label: {
                    Image(systemName: "globe.asia.australia.fill")
                        .font(.caption)
                        .padding(8)
                        .background(Circle().fill(.ultraThinMaterial))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 14)
    }

    private func stopCard(_ s: ChappyAtlas.Stop) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: s.isHome ? "house.fill" : (s.starred ? "star.fill" : "mappin.circle.fill"))
                    .foregroundStyle(glowTint(s))
                Text(s.name).font(.headline).foregroundStyle(.white)
                Spacer()
                Button { withAnimation { selectedStop = nil } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 14) {
                Label("\(s.visits) visit\(s.visits == 1 ? "" : "s")", systemImage: "clock.arrow.circlepath")
                if s.photos > 0 { Label("\(s.photos)", systemImage: "camera.fill") }
                Text(Self.stamp(s.lastAt))
            }
            .font(.caption).foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 9) {
                Button {
                    Task { _ = await NavEngine.shared.navigate(to: s.name, driving: true) }
                } label: { pill("Take me", "location.fill", .cyan) }
                .buttonStyle(.plain)
                Button {
                    _ = TripRecorder.shared.saveSpot(named: s.name, lat: s.coord.latitude,
                                                     lon: s.coord.longitude)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: { pill("Star it", "star.fill", .yellow) }
                .buttonStyle(.plain)
                Button {
                    if let a = ChappyMemory.shared.spokenRecall(s.name) {
                        TTSService.shared.speak(a)
                    } else {
                        TTSService.shared.speak("Nothing else stored about \(s.name) yet.")
                    }
                } label: { pill("Recall", "brain.head.profile", .purple) }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 17).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(glowTint(s).opacity(0.5), lineWidth: 1))
        .shadow(color: glowTint(s).opacity(0.4), radius: 12)
        .padding(.horizontal, 12).padding(.bottom, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func placeCard(_ p: ChappyAtlas.Place) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: p.layer.icon).foregroundStyle(p.layer.tint)
                Text(p.name).font(.headline).foregroundStyle(.white).lineLimit(2)
                Spacer()
                Button { withAnimation { selectedPlace = nil } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            Text(p.category.isEmpty ? p.layer.label : p.category)
                .font(.caption).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 9) {
                Button {
                    Task { _ = await NavEngine.shared.navigate(to: p.name, driving: true) }
                } label: { pill("Take me", "location.fill", .cyan) }
                .buttonStyle(.plain)
                Button {
                    _ = ChappyMemory.shared.rememberAt(.place, title: p.name,
                        lat: p.coord.latitude, lon: p.coord.longitude,
                        tags: ["atlas", p.layer.rawValue], source: "atlas")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    TTSService.shared.speak("\(p.name) saved.")
                } label: { pill("Save", "bookmark.fill", .yellow) }
                .buttonStyle(.plain)
                Button {
                    let q = p.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let u = URL(string: "https://www.google.com/search?q=\(q)") {
                        UIApplication.shared.open(u, options: [:], completionHandler: nil)
                    }
                } label: { pill("Look up", "magnifyingglass", .green) }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 17).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(p.layer.tint.opacity(0.5), lineWidth: 1))
        .shadow(color: p.layer.tint.opacity(0.4), radius: 12)
        .padding(.horizontal, 12).padding(.bottom, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func pill(_ text: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(.caption).fontWeight(.semibold)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Capsule().fill(tint.opacity(0.22)))
        .foregroundStyle(tint)
    }

    private func refreshPlaces() async {
        guard !layers.isEmpty else { places = []; return }
        // A whole country's worth of "restaurant" is meaningless — the
        // live layers only make sense once you've zoomed in a bit.
        guard region.span.latitudeDelta < 2.2 else { places = []; return }
        searching = true
        places = await atlas.findPlaces(in: region, layers: layers)
        searching = false
    }

    private func refreshWeather() async {
        weather = await atlas.weather(at: region.center)
    }

    private func flyTo(_ query: String) async {
        if let spot = TripRecorder.shared.spots.last(where: {
            $0.name.lowercased().contains(query.lowercased()) }) {
            withAnimation(.easeInOut(duration: 0.8)) {
                camera = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lon),
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
            }
            return
        }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = region
        guard let resp = try? await MKLocalSearch(request: req).start(),
              let first = resp.mapItems.first else {
            TTSService.shared.speak("Couldn't find \(query) on the map.")
            return
        }
        withAnimation(.easeInOut(duration: 0.8)) {
            camera = .region(MKCoordinateRegion(
                center: first.placemark.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.09, longitudeDelta: 0.09)))
        }
    }

    private func zoomLevel() -> Int {
        let d = region.span.latitudeDelta
        switch d {
        case ..<0.05: return 14
        case ..<0.2:  return 12
        case ..<1:    return 10
        case ..<5:    return 8
        case ..<20:   return 6
        default:      return 4
        }
    }

    private static func stamp(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "today" }
        if Calendar.current.isDateInYesterday(d) { return "yesterday" }
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }
}

// =====================================================================
// MARK: - DICTATE VIEW (Build 157)
// =====================================================================
//
//   Speak a mess, walk away with clean text on your clipboard. A big
//   breathing mic while you talk, your words appearing live, then tone
//   chips to re-cut it — Professional, Job Report, Email, Brief,
//   Bullets, Plain — and Copy / Share / Save. The raw transcript stays
//   visible underneath so nothing the polish trims is ever lost.

struct DictateView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dictate = ChappyDictate.shared
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @State private var wave = false
    @State private var showRaw = false
    @State private var shareURL: URL?
    @State private var copied = false
    @State private var showEmail = false   // BUILD 167
    @State private var showScanner = false // BUILD 168
    @State private var reading = false

    var autoStart = false

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                ScrollView {
                    VStack(spacing: 18) {
                        micArea
                        if !dictate.transcript.isEmpty { toneRow }
                        if dictate.isPolishing { polishingRow }
                        if !dictate.polished.isEmpty { resultCard }
                        if !dictate.transcript.isEmpty { rawCard }
                        if let e = dictate.error { errorRow(e) }
                        if dictate.transcript.isEmpty && !dictate.isRecording { hintCard }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Dictate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        if dictate.isRecording { dictate.stop(andPolish: false) }
                        dismiss()
                    }
                    .foregroundColor(theme.accent)
                }
            }
            .onAppear {
                wave = true
                if autoStart && !dictate.isRecording { dictate.start() }
            }
            .sheet(item: $shareURL) { url in ChappyShareSheet(items: [url]) }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner { pages in
                    guard !pages.isEmpty else { return }
                    reading = true
                    Task {
                        let text = await ChappyPageOCR.read(pages)
                        reading = false
                        guard !text.isEmpty else {
                            TTSService.shared.speak("Couldn't read any text off that page.")
                            return
                        }
                        // Reword by default — that's what you scan a
                        // document to do. Every other style is one tap away.
                        dictate.load(text: text, tone: .reword)
                        TTSService.shared.speak("Read \(pages.count) page\(pages.count == 1 ? "" : "s"). Rewriting it now.")
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showEmail) {
                DictateEmailSheet(theme: theme,
                                  body: dictate.polished.isEmpty ? dictate.transcript : dictate.polished)
            }
        }
    }

    // MARK: mic

    private var micArea: some View {
        VStack(spacing: 14) {
            Button {
                if dictate.isRecording { dictate.stop(andPolish: true) }
                else { dictate.start() }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                ZStack {
                    // Breathing halo while live.
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(theme.accent.opacity(dictate.isRecording ? 0.35 : 0.12),
                                    lineWidth: 2)
                            .frame(width: 110 + CGFloat(i) * 34, height: 110 + CGFloat(i) * 34)
                            .scaleEffect(wave && dictate.isRecording ? 1.10 : 0.92)
                            .opacity(wave && dictate.isRecording ? 0.15 : 0.6)
                            .animation(.easeInOut(duration: 1.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.25), value: wave)
                    }
                    Circle()
                        .fill(LinearGradient(
                            colors: dictate.isRecording
                                ? [.red.opacity(0.95), .orange.opacity(0.85)]
                                : [theme.accent.opacity(0.95), theme.accent.opacity(0.6)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 108, height: 108)
                        .shadow(color: (dictate.isRecording ? Color.red : theme.accent).opacity(0.75),
                                radius: 22)
                    Image(systemName: dictate.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            Text(dictate.isRecording
                 ? "Listening — tap to finish"
                 : (dictate.transcript.isEmpty ? "Tap and talk" : "Tap to record again"))
                .font(.subheadline).fontWeight(.semibold)
                .foregroundColor(theme.textSecondary)

            // BUILD 168 — OR START FROM A PAGE. Scan a document with the
            // phone camera (Apple's own scanner: finds the edges, flattens
            // the perspective, does multiple pages), read it on-device,
            // and hand the text to the same rewriter. Then Reword it,
            // simplify it, or email it — exactly as if you'd said it.
            if !dictate.isRecording {
                Button {
                    showScanner = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: reading ? "hourglass" : "doc.viewfinder")
                            .font(.system(size: 14, weight: .bold))
                        Text(reading ? "Reading the page…" : "Scan a document")
                            .font(.subheadline).fontWeight(.semibold)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 46)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().stroke(theme.accent.opacity(0.5), lineWidth: 1))
                    .foregroundColor(theme.accent)
                    .shadow(color: theme.accent.opacity(0.25), radius: 8)
                }
                .buttonStyle(ChappyPressStyle())
                .disabled(reading)
            }

            if dictate.isRecording && !dictate.transcript.isEmpty {
                Text(dictate.transcript)
                    .font(.body)
                    .foregroundColor(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                    .transition(.opacity)
            }
        }
        .padding(.top, 10)
    }

    // MARK: tones

    private var toneRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("STYLE")
                .font(.caption2).fontWeight(.heavy).tracking(0.8)
                .foregroundColor(theme.accent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(ChappyDictate.Tone.allCases) { t in
                        Button {
                            dictate.tone = t
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            Task { await dictate.polish() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: t.icon).font(.system(size: 11, weight: .bold))
                                Text(t.label).font(.caption).fontWeight(.semibold)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(dictate.tone == t
                                ? t.tint.opacity(0.9) : Color.white.opacity(0.07)))
                            .foregroundStyle(dictate.tone == t ? .white : theme.textSecondary)
                            .shadow(color: dictate.tone == t ? t.tint.opacity(0.7) : .clear, radius: 8)
                        }
                        .buttonStyle(ChappyPressStyle(scale: 0.94))
                    }
                }
            }
        }
    }

    private var polishingRow: some View {
        HStack(spacing: 9) {
            ProgressView().tint(theme.accent)
            Text("Writing it up…")
                .font(.subheadline).foregroundColor(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
    }

    // MARK: result

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: dictate.tone.icon)
                    .foregroundStyle(dictate.tone.tint)
                Text(dictate.tone.label.uppercased())
                    .font(.caption2).fontWeight(.heavy).tracking(0.8)
                    .foregroundStyle(dictate.tone.tint)
                Spacer()
                Text("\(dictate.polished.split(separator: " ").count) words")
                    .font(.caption2).foregroundColor(theme.textSecondary)
            }
            Text(dictate.polished)
                .font(.body)
                .foregroundColor(theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            // BUILD 167 — the same button language as everywhere else:
            // glowing icon chip, gradient edge, coloured shadow, a real
            // 52-point target and the shared press squeeze.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9),
                                GridItem(.flexible(), spacing: 9)], spacing: 9) {
                Button {
                    dictate.copyToClipboard()
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation { copied = false }
                    }
                } label: {
                    actionPill(copied ? "Copied!" : "Copy",
                               copied ? "checkmark" : "doc.on.doc.fill",
                               copied ? .green : Color(red: 0.35, green: 0.85, blue: 1.0))
                }
                .buttonStyle(ChappyPressStyle())
                Button {
                    showEmail = true
                } label: {
                    actionPill("Email", "envelope.fill",
                               Color(red: 0.68, green: 0.5, blue: 1.0))
                }
                .buttonStyle(ChappyPressStyle())
                Button {
                    shareURL = dictate.save()
                } label: {
                    actionPill("Share", "square.and.arrow.up",
                               Color(red: 0.45, green: 0.65, blue: 1.0))
                }
                .buttonStyle(ChappyPressStyle())
                Button {
                    _ = dictate.save()
                    TTSService.shared.speak("Saved to your memory.")
                } label: {
                    actionPill("Save", "tray.and.arrow.down.fill",
                               Color(red: 1.0, green: 0.68, blue: 0.25))
                }
                .buttonStyle(ChappyPressStyle())
            }
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 17).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 17)
            .stroke(dictate.tone.tint.opacity(0.45), lineWidth: 1))
        .shadow(color: dictate.tone.tint.opacity(0.28), radius: 14)
    }

    private var rawCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showRaw.toggle() }
            } label: {
                HStack {
                    Image(systemName: "waveform")
                        .font(.caption).foregroundColor(theme.textSecondary)
                    Text("What you actually said")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                    Image(systemName: showRaw ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundColor(theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            if showRaw {
                Text(dictate.transcript)
                    .font(.callout)
                    .foregroundColor(theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.045)))
    }

    private func errorRow(_ e: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
            Text(e).font(.caption).foregroundColor(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW IT WORKS")
                .font(.caption2).fontWeight(.heavy).tracking(0.8)
                .foregroundColor(theme.accent)
            Text("Talk normally — ramble, correct yourself, it doesn't matter. Chappy transcribes on the phone, then rewrites it in the style you pick. Copy drops it straight on your clipboard for any app.")
                .font(.callout).foregroundColor(theme.textSecondary)
            Divider().background(theme.textSecondary.opacity(0.2))
            Text("Or scan a document and have it rewritten — tap Scan a document above, then pick a style.")
                .font(.callout).foregroundColor(theme.textSecondary)
            Text("Hands free: \u{201C}take a report\u{201D} · \u{201C}dictate a note\u{201D} · \u{201C}rewrite this\u{201D}")
                .font(.caption).foregroundColor(theme.accent.opacity(0.9))
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
    }

    private func actionPill(_ text: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(tint.opacity(0.22)).frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
            }
            .shadow(color: tint.opacity(0.55), radius: 7)
            Text(text).font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.14), .clear],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(LinearGradient(colors: [tint.opacity(0.6), tint.opacity(0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1))
        .shadow(color: tint.opacity(0.2), radius: 8, y: 3)
    }
}

// BUILD 161 — NO SHARE SHEET DECLARED HERE ON PURPOSE.
//
// I wrote one called `ShareSheet`, which collided with the `ShareSheet(photo:)`
// PhotoPreviewView has shipped for months — and that one clash broke BOTH
// files. Renaming it to ChappyShareSheet then collided with the identical
// ChappyShareSheet already living in LiveTranslateView.
//
// So: no third copy. DictateView uses the existing ChappyShareSheet from
// LiveTranslateView.swift — same `items: [Any]` shape, already in the target.
// The lesson, written down so the next module doesn't repeat it: grep the
// project for a type name before declaring it.

extension URL: Identifiable {
    public var id: String { absoluteString }
}

// =====================================================================
// MARK: - CHAPPY TILE (Build 157) — the colour-coded grid
// =====================================================================
//
//   The old MoreRow was a grey list: nine identical rows, no hierarchy,
//   endless scrolling. Apple's Control Center and Samsung's One UI quick
//   panel both solved this the same way — a GRID of tiles, each with its
//   own colour, so the eye finds things by hue instead of by reading.
//   Half the scroll, twice the speed, and it finally looks like an app
//   somebody designed.

struct ChappyTile: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    let action: () -> Void

    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    var body: some View {
        Button {
            ChappyEarcon.shared.tap()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                // The glowing icon chip.
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.22))
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .shadow(color: tint.opacity(0.55), radius: 9)
                Text(title)
                    .font(.subheadline).fontWeight(.bold)
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(colors: [tint.opacity(0.14), .clear],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(LinearGradient(colors: [tint.opacity(0.65), tint.opacity(0.12)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1)
            )
            .shadow(color: tint.opacity(0.22), radius: 10, y: 4)
        }
        // BUILD 162 — THE SCROLL BUG. This used to drive the press animation
        // with .simultaneousGesture(DragGesture(minimumDistance: 0)), and a
        // zero-distance drag gesture EATS THE SCROLL: rest a finger on a tile
        // and the page would not move. A ButtonStyle gets the identical
        // squeeze from configuration.isPressed and leaves scrolling alone,
        // which is exactly why SwiftUI provides it.
        .buttonStyle(ChappyPressStyle())
    }
}

/// The press effect every Chappy button shares: a small spring squeeze and
/// a touch of dimming. Scroll-safe by construction.
struct ChappyPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}

// =====================================================================
// MARK: - PLACES (BUILD 158)
// =====================================================================
//
//   The Remember button always saved. It just saved into the dark —
//   spots existed only as pins on a map, so one saved in a hurry with
//   no name was gone forever, and there was no way to rename, delete,
//   or do anything WITH a place once you had it.
//
//   Google Maps solved this with Saved lists, Apple with the Library.
//   Both stop at "here is your list". The bit neither does well is the
//   one that matters most on a job: an ARRIVAL NOTE — the gate code,
//   the parking, the dog — spoken the moment you pull up, before you
//   knock. That is what this screen is really for.

struct PlacesView: View {

    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @State private var spots: [TripRecorder.Spot] = []
    @State private var filter = "All"
    @State private var editing: Int?
    @State private var search = ""

    private static let categories = ["All", "Favourites", "Work", "Food", "Stay", "Other"]

    /// Anything auto-named ("spot at 4:53PM near…") still needs a name.
    private func needsName(_ s: TripRecorder.Spot) -> Bool {
        s.name.lowercased().hasPrefix("spot at")
    }

    private var shown: [(offset: Int, element: TripRecorder.Spot)] {
        let indexed = Array(spots.enumerated())
        return indexed.filter { pair in
            let s = pair.element
            let catOK: Bool = {
                switch filter {
                case "All": return true
                case "Favourites": return s.starred == true
                default: return (s.category ?? "Other") == filter
                }
            }()
            let searchOK = search.isEmpty
                || s.name.localizedCaseInsensitiveContains(search)
                || (s.note ?? "").localizedCaseInsensitiveContains(search)
                || (s.street ?? "").localizedCaseInsensitiveContains(search)
            return catOK && searchOK
        }
        .sorted { a, b in
            // Unnamed first — they're the ones you need to fix.
            if needsName(a.element) != needsName(b.element) { return needsName(a.element) }
            return a.element.t > b.element.t
        }
        .map { (offset: $0.offset, element: $0.element) }
    }

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                VStack(spacing: 0) {
                    chips
                    if shown.isEmpty { empty } else { list }
                }
            }
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search places and notes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(theme.accent)
                }
            }
            .onAppear { reload() }
            .sheet(item: Binding(
                get: { editing.map { PlaceIndex(id: $0) } },
                set: { editing = $0?.id })) { wrapped in
                    if spots.indices.contains(wrapped.id) {
                        PlaceEditor(index: wrapped.id, theme: theme) { reload() }
                    }
                }
        }
    }

    private struct PlaceIndex: Identifiable { let id: Int }

    private func reload() { spots = TripRecorder.shared.spots }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Self.categories, id: \.self) { c in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { filter = c }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(c)
                            .font(.footnote).fontWeight(.semibold)
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .background(Capsule().fill(filter == c
                                ? theme.accent.opacity(0.25) : Color.white.opacity(0.06)))
                            .foregroundColor(filter == c ? theme.accent : theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "mappin.slash")
                .font(.system(size: 50))
                .foregroundColor(theme.textSecondary.opacity(0.6))
            Text(search.isEmpty
                 ? "No places yet.\nTap Remember on the Home screen, or say\n\u{201C}remember this spot, call it the blue warung\u{201D}."
                 : "Nothing matches \u{201C}\(search)\u{201D}.")
                .font(.subheadline)
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
    }

    private var list: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 9) {
                ForEach(shown, id: \.offset) { pair in
                    row(index: pair.offset, spot: pair.element)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 26)
        }
    }

    private func row(index: Int, spot s: TripRecorder.Spot) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            editing = index
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(tint(s).opacity(0.2))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon(s))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint(s))
                }
                .shadow(color: tint(s).opacity(0.5), radius: 7)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(s.name)
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundColor(theme.textPrimary)
                            .lineLimit(1)
                        if s.starred == true {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9)).foregroundStyle(.yellow)
                        }
                        if s.arrivalNote?.isEmpty == false {
                            Image(systemName: "bell.badge.fill")
                                .font(.system(size: 9)).foregroundStyle(.orange)
                        }
                    }
                    if needsName(s) {
                        Text("Needs a name — tap to fix")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundColor(.orange)
                    } else if let n = s.note, !n.isEmpty {
                        Text(n).font(.caption2)
                            .foregroundColor(theme.textSecondary).lineLimit(1)
                    } else if let street = s.street {
                        Text(street).font(.caption2)
                            .foregroundColor(theme.textSecondary).lineLimit(1)
                    }
                    Text(Self.stamp(s.t) + distanceSuffix(s))
                        .font(.caption2)
                        .foregroundColor(theme.textSecondary.opacity(0.75))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(theme.textSecondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 15).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 15)
                .stroke(needsName(s) ? Color.orange.opacity(0.45) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func icon(_ s: TripRecorder.Spot) -> String {
        switch s.category ?? "" {
        case "Work": return "wrench.and.screwdriver.fill"
        case "Food": return "fork.knife"
        case "Stay": return "bed.double.fill"
        default: return s.starred == true ? "star.fill" : "mappin.circle.fill"
        }
    }

    private func tint(_ s: TripRecorder.Spot) -> Color {
        if s.starred == true { return .yellow }
        switch s.category ?? "" {
        case "Work": return .orange
        case "Food": return .pink
        case "Stay": return .purple
        default: return theme.accent
        }
    }

    private func distanceSuffix(_ s: TripRecorder.Spot) -> String {
        let snap = ContextEngine.shared.snapshot
        guard let la = snap.latitude, let lo = snap.longitude else { return "" }
        let d = CLLocation(latitude: la, longitude: lo)
            .distance(from: CLLocation(latitude: s.lat, longitude: s.lon))
        if d < 950 { return " · \(Int(d)) m away" }
        return String(format: " · %.1f km away", d / 1000)
    }

    private static func stamp(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }
}

// MARK: - One place, fully editable

private struct PlaceEditor: View {

    let index: Int
    let theme: ChappyTheme
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""
    @State private var arrivalNote = ""
    @State private var category = "Other"
    @State private var starred = false
    @State private var confirmDelete = false

    private var spot: TripRecorder.Spot? {
        TripRecorder.shared.spots.indices.contains(index)
            ? TripRecorder.shared.spots[index] : nil
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Name") {
                    TextField("What do you call it?", text: $name)
                        .font(.body)
                }
                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(["Work", "Food", "Stay", "Other"], id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Favourite", isOn: $starred)
                }
                Section {
                    TextField("Anything worth remembering", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Note")
                } footer: {
                    Text("Searchable, and Chappy can read it back — \u{201C}what do you remember about the blue warung\u{201D}.")
                }
                Section {
                    TextField("e.g. Gate code 4321, dog out back, park on the street",
                              text: $arrivalNote, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Label("Say this when I arrive", systemImage: "bell.badge")
                } footer: {
                    Text("Spoken automatically the moment you get within about 150 metres — once an hour at most. The gate code, before you knock.")
                }
                Section {
                    Button {
                        if let s = spot {
                            dismiss()
                            Task { _ = await NavEngine.shared.navigate(to: s.name, driving: true) }
                        }
                    } label: { Label("Take me here", systemImage: "location.fill") }

                    Button {
                        if let s = spot {
                            _ = ChappyDataBridge.addReminder(text: "At \(s.name)",
                                                             at: nil, place: s.name)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            TTSService.shared.speak("Ping set for \(s.name).")
                            dismiss()
                        }
                    } label: { Label("Remind me when I'm here", systemImage: "bell.fill") }

                    Button {
                        if let s = spot,
                           let u = URL(string: "https://maps.apple.com/?ll=\(s.lat),\(s.lon)&q=\(s.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                            UIApplication.shared.open(u, options: [:], completionHandler: nil)
                        }
                    } label: { Label("Open in Maps", systemImage: "map") }
                }
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete this place", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.fontWeight(.semibold)
                }
            }
            .onAppear {
                guard let s = spot else { return }
                name = s.name.lowercased().hasPrefix("spot at") ? "" : s.name
                note = s.note ?? ""
                arrivalNote = s.arrivalNote ?? ""
                category = s.category ?? "Other"
                starred = s.starred ?? false
            }
            .alert("Delete this place?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    TripRecorder.shared.deleteSpot(at: index)
                    onChange()
                    dismiss()
                }
                Button("Keep", role: .cancel) { }
            } message: {
                Text("The place is removed. Photos and notes you took there stay in Memory.")
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            TripRecorder.shared.renameSpot(id: nil, at: index, to: trimmed)
        }
        TripRecorder.shared.updateSpot(index: index, note: note,
                                       arrivalNote: arrivalNote,
                                       category: category, starred: starred)
        onChange()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

// =====================================================================
// MARK: - UPCOMING (Build 163)
// =====================================================================
//
//   The gap you named: "I have no idea when my appointments are."
//
//   Everything was there — iCloud events, Geeks2U jobs, timed reminders
//   — but only ever as TODAY. The Diary showed today, the home card
//   showed today, the brief read today. Nothing in the app answered
//   "what's my week?" without going to Apple's Calendar app.
//
//   So: one screen, thirty days, EVERYTHING merged and grouped by day.
//   Google Calendar's Schedule view and Apple's Calendar list view both
//   settled on the same shape for the same reason — a flat chronological
//   list with day headers is the only layout that survives a busy week
//   on a phone. Events and reminders sit together because your day
//   doesn't separate them.
//
//   Tap an event for warn times and brief settings. Tap a reminder to
//   tick or snooze it. The Calendars button is right there, because the
//   first question when something's missing is always "is that calendar
//   switched on?"

struct UpcomingView: View {

    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @State private var days = 30
    @State private var refresh = 0
    @State private var pickedEvent: EKEvent?
    @State private var showCalendars = false
    @State private var showAll = false     // include untimed reminders
    // BUILD 164 — three ways to look at the same month.
    @State private var mode: Look = .list
    @State private var anchor = Date()     // which week/month is on screen
    @State private var pickedDay: Date?
    @State private var showNewEvent = false

    enum Look: String, CaseIterable {
        case list = "List", week = "Week", month = "Month"
        var icon: String {
            switch self {
            case .list: return "list.bullet"
            case .week: return "calendar.day.timeline.left"
            case .month: return "calendar"
            }
        }
    }

    private struct Row: Identifiable {
        let id = UUID()
        var at: Date
        var isEvent: Bool
        var title: String
        var detail: String?
        var allDay: Bool
        var event: EKEvent?
        var reminder: ChappyMemory.Entry?
    }

    private var rows: [Row] {
        _ = refresh
        var out: [Row] = []
        for e in ChappyCalendar.shared.upcoming(days: days) {
            guard let s = e.startDate else { continue }
            out.append(Row(at: s, isEvent: true,
                           title: e.title ?? "Appointment",
                           detail: e.location?.isEmpty == false ? e.location : nil,
                           allDay: e.isAllDay, event: e, reminder: nil))
        }
        let horizon = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        for r in ChappyReminders.shared.open where r.doneAt == nil {
            if let f = r.effectiveFire, f <= horizon {
                out.append(Row(at: f, isEvent: false, title: r.title,
                               detail: r.placeTrigger, allDay: false,
                               event: nil, reminder: r))
            } else if showAll, r.effectiveFire == nil {
                out.append(Row(at: .distantFuture, isEvent: false, title: r.title,
                               detail: "no time set", allDay: false,
                               event: nil, reminder: r))
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    private var grouped: [(key: Date, rows: [Row])] {
        let cal = Calendar.current
        let buckets = Dictionary(grouping: rows) { r -> Date in
            r.at == .distantFuture ? .distantFuture : cal.startOfDay(for: r.at)
        }
        return buckets.keys.sorted().map { (key: $0, rows: buckets[$0] ?? []) }
    }

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                VStack(spacing: 0) {
                    lookPicker
                    switch mode {
                    case .list:  if rows.isEmpty { empty } else { list }
                    case .week:  weekView
                    case .month: monthView
                    }
                }
            }
            .navigationTitle("Upcoming")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showCalendars = true
                    } label: {
                        Image(systemName: "calendar.badge.checkmark")
                            .foregroundColor(theme.accent)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            showNewEvent = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(theme.accent)
                        }
                        Button("Done") { dismiss() }.foregroundColor(theme.accent)
                    }
                }
            }
            .sheet(isPresented: $showCalendars) { CalendarPickerSheet(theme: theme) }
            .sheet(isPresented: $showNewEvent) {
                NewEventSheet(theme: theme, start: pickedDay ?? Date()) { refresh += 1 }
            }
            .sheet(item: Binding(
                get: { pickedDay.map { DayBox(day: $0) } },
                set: { pickedDay = $0?.day })) { box in
                    DayListSheet(day: box.day, theme: theme) { refresh += 1 }
                }
            .sheet(item: Binding(
                get: { pickedEvent.map { EventBox(event: $0) } },
                set: { pickedEvent = $0?.event })) { box in
                    EventDetailSheet(event: box.event, theme: theme) { refresh += 1 }
                }
            .onAppear { refresh += 1 }
        }
    }

    private struct EventBox: Identifiable {
        let event: EKEvent
        var id: String { (event.eventIdentifier ?? UUID().uuidString)
            + String(Int((event.startDate ?? Date()).timeIntervalSince1970)) }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 50))
                .foregroundColor(theme.textSecondary.opacity(0.6))
            Text("Nothing in the next \(days) days.")
                .font(.subheadline).foregroundColor(theme.textSecondary)
            Text("If that's wrong, check which calendars are switched on \u{2014} the button top left.")
                .font(.caption).foregroundColor(theme.textSecondary.opacity(0.8))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }

    private var list: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(grouped, id: \.key) { group in
                    Section {
                        VStack(spacing: 8) {
                            ForEach(group.rows) { r in row(r) }
                        }
                    } header: {
                        HStack {
                            Text(Self.dayLabel(group.key).uppercased())
                                .font(.caption2).fontWeight(.heavy).tracking(0.9)
                                .foregroundColor(theme.accent)
                            Spacer()
                            Text("\(group.rows.count)")
                                .font(.caption2).foregroundColor(theme.textSecondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(.ultraThinMaterial)
                    }
                }
                // Range switch
                HStack(spacing: 7) {
                    ForEach([7, 30, 90], id: \.self) { d in
                        Button {
                            days = d
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Text(d == 7 ? "Week" : (d == 30 ? "Month" : "3 Months"))
                                .font(.caption2).fontWeight(.bold)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(days == d
                                    ? theme.accent.opacity(0.25) : Color.white.opacity(0.06)))
                                .foregroundColor(days == d ? theme.accent : theme.textSecondary)
                        }
                        .buttonStyle(ChappyPressStyle(scale: 0.94))
                    }
                    Spacer()
                    Button {
                        showAll.toggle()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(showAll ? "Hide undated" : "Show undated")
                            .font(.caption2).fontWeight(.bold)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                            .foregroundColor(theme.textSecondary)
                    }
                    .buttonStyle(ChappyPressStyle(scale: 0.94))
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 26)
            }
        }
    }

    private func row(_ r: Row) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let e = r.event { pickedEvent = e }
            else if let rem = r.reminder {
                ChappyReminders.shared.complete(rem.id)
                TTSService.shared.speak("Done.")
                refresh += 1
            }
        } label: {
            HStack(spacing: 11) {
                VStack(spacing: 1) {
                    if r.allDay {
                        Text("ALL").font(.system(size: 10, weight: .heavy))
                        Text("DAY").font(.system(size: 10, weight: .heavy))
                    } else if r.at == .distantFuture {
                        Image(systemName: "infinity").font(.caption)
                    } else {
                        Text(Self.timeLabel(r.at))
                            .font(.system(size: 13, weight: .bold))
                            .monospacedDigit()
                    }
                }
                .frame(width: 52)
                .foregroundColor(r.isEvent ? .purple : theme.accent)

                Rectangle()
                    .fill(r.isEvent ? Color.purple : theme.accent)
                    .frame(width: 3)
                    .clipShape(Capsule())
                    .shadow(color: (r.isEvent ? Color.purple : theme.accent).opacity(0.7), radius: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title)
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(2)
                    if let d = r.detail, !d.isEmpty {
                        Label(d, systemImage: r.isEvent ? "mappin" : "bell")
                            .font(.caption2).foregroundColor(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: r.isEvent ? "chevron.right" : "circle")
                    .font(.caption2).foregroundColor(theme.textSecondary)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke((r.isEvent ? Color.purple : theme.accent).opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(ChappyPressStyle())
        .padding(.horizontal, 14)
    }

    // MARK: BUILD 164 — the three looks

    private var lookPicker: some View {
        HStack(spacing: 7) {
            ForEach(Look.allCases, id: \.rawValue) { m in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { mode = m; anchor = Date() }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.icon).font(.system(size: 12, weight: .bold))
                        Text(m.rawValue).font(.footnote).fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 11)
                        .fill(mode == m ? theme.accent.opacity(0.22) : Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 11)
                        .stroke(mode == m ? theme.accent.opacity(0.55) : .clear, lineWidth: 1))
                    .foregroundColor(mode == m ? theme.accent : theme.textSecondary)
                }
                .buttonStyle(ChappyPressStyle(scale: 0.95))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    /// WEEK — seven days down the screen, each with its own events. The
    /// shape Google Calendar's phone "3 day" and Outlook's agenda both
    /// use, because seven columns on a phone is unreadable.
    private var weekView: some View {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                      from: anchor)) ?? anchor
        let daysOfWeek = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        return VStack(spacing: 0) {
            stepper(title: Self.weekTitle(start), back: -7, fwd: 7)
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 9) {
                    ForEach(daysOfWeek, id: \.self) { d in
                        dayCard(d)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 26)
            }
        }
    }

    private func dayCard(_ d: Date) -> some View {
        let items = itemsOn(d)
        let isToday = Calendar.current.isDateInToday(d)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            pickedDay = d
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(Self.dayLabel(d))
                        .font(.subheadline).fontWeight(.bold)
                        .foregroundColor(isToday ? theme.accent : theme.textPrimary)
                    if isToday {
                        Text("TODAY").font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(theme.accent.opacity(0.25)))
                            .foregroundColor(theme.accent)
                    }
                    Spacer()
                    if items.isEmpty {
                        Text("clear").font(.caption2)
                            .foregroundColor(theme.textSecondary.opacity(0.6))
                    } else {
                        Text("\(items.count)").font(.caption2).fontWeight(.bold)
                            .foregroundColor(theme.textSecondary)
                    }
                }
                ForEach(items.prefix(4), id: \.id) { r in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(r.isEvent ? Color.purple : theme.accent)
                            .frame(width: 6, height: 6)
                        Text(r.allDay ? "all day" : Self.shortTime(r.at))
                            .font(.caption2).monospacedDigit()
                            .foregroundColor(theme.textSecondary)
                            .frame(width: 58, alignment: .leading)
                        Text(r.title).font(.caption)
                            .foregroundColor(theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if items.count > 4 {
                    Text("+ \(items.count - 4) more").font(.caption2)
                        .foregroundColor(theme.accent)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(isToday ? theme.accent.opacity(0.55) : Color.white.opacity(0.06),
                        lineWidth: 1))
        }
        .buttonStyle(ChappyPressStyle())
    }

    /// MONTH — the grid everyone knows, with a dot per event. Tap a day
    /// for its list. Apple, Google and Outlook all converged here; the
    /// only real choice is what the dots mean, and here they mean
    /// "something is on", coloured by event vs reminder.
    private var monthView: some View {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: anchor)) ?? anchor
        let range = cal.range(of: .day, in: .month, for: monthStart) ?? 1..<31
        let firstWeekday = cal.component(.weekday, from: monthStart) - cal.firstWeekday
        let pad = (firstWeekday + 7) % 7
        let cells: [Date?] = Array(repeating: nil, count: pad)
            + range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: monthStart) }
        return VStack(spacing: 0) {
            stepper(title: Self.monthTitle(monthStart), back: -1, fwd: 1, byMonth: true)
            HStack(spacing: 0) {
                ForEach(Self.weekdayInitials(), id: \.self) { w in
                    Text(w).font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7),
                          spacing: 4) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                        if let d = day { monthCell(d) } else { Color.clear.frame(height: 52) }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 26)
            }
        }
    }

    private func monthCell(_ d: Date) -> some View {
        let items = itemsOn(d)
        let isToday = Calendar.current.isDateInToday(d)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            pickedDay = d
        } label: {
            VStack(spacing: 3) {
                Text("\(Calendar.current.component(.day, from: d))")
                    .font(.system(size: 14, weight: isToday ? .heavy : .medium))
                    .foregroundColor(isToday ? .white : theme.textPrimary)
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(isToday ? theme.accent : .clear))
                HStack(spacing: 2) {
                    ForEach(0..<min(items.count, 3), id: \.self) { i in
                        Circle()
                            .fill(items[i].isEvent ? Color.purple : theme.accent)
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(items.isEmpty ? Color.clear : Color.white.opacity(0.05)))
        }
        .buttonStyle(ChappyPressStyle(scale: 0.93))
    }

    private func stepper(title: String, back: Int, fwd: Int, byMonth: Bool = false) -> some View {
        HStack {
            Button {
                anchor = Calendar.current.date(byAdding: byMonth ? .month : .day,
                                               value: back, to: anchor) ?? anchor
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: { Image(systemName: "chevron.left").padding(8) }
                .buttonStyle(ChappyPressStyle(scale: 0.9))
            Spacer()
            Button {
                anchor = Date()
            } label: {
                Text(title).font(.subheadline).fontWeight(.bold)
                    .foregroundColor(theme.textPrimary)
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                anchor = Calendar.current.date(byAdding: byMonth ? .month : .day,
                                               value: fwd, to: anchor) ?? anchor
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: { Image(systemName: "chevron.right").padding(8) }
                .buttonStyle(ChappyPressStyle(scale: 0.9))
        }
        .foregroundColor(theme.accent)
        .padding(.horizontal, 14).padding(.bottom, 6)
    }

    /// Everything on one day — events and timed reminders together.
    private func itemsOn(_ d: Date) -> [Row] {
        _ = refresh
        let cal = Calendar.current
        var out: [Row] = []
        for e in ChappyCalendar.shared.events(onDay: d) {
            guard let s = e.startDate else { continue }
            out.append(Row(at: s, isEvent: true, title: e.title ?? "Appointment",
                           detail: e.location, allDay: e.isAllDay, event: e, reminder: nil))
        }
        for r in ChappyReminders.shared.open where r.doneAt == nil {
            if let f = r.effectiveFire, cal.isDate(f, inSameDayAs: d) {
                out.append(Row(at: f, isEvent: false, title: r.title,
                               detail: r.placeTrigger, allDay: false,
                               event: nil, reminder: r))
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    private static func weekTitle(_ start: Date) -> String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
        let f = DateFormatter(); f.dateFormat = "d MMM"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    private static func monthTitle(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        return f.string(from: d)
    }

    private static func weekdayInitials() -> [String] {
        let f = DateFormatter()
        let syms = f.veryShortWeekdaySymbols ?? ["S","M","T","W","T","F","S"]
        let first = Calendar.current.firstWeekday - 1
        return Array(syms[first...] + syms[..<first])
    }

    private static func shortTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    private struct DayBox: Identifiable {
        let day: Date
        var id: Double { day.timeIntervalSince1970 }
    }

    private static func dayLabel(_ d: Date) -> String {
        if d == .distantFuture { return "No time set" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .weekOfYear)
            ? "EEEE" : "EEEE d MMMM"
        return f.string(from: d)
    }

    private static func timeLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: d).replacingOccurrences(of: " ", with: "\n")
    }
}

/// Which calendars feed Chappy — the first question whenever something
/// expected doesn't show up.
private struct CalendarPickerSheet: View {
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @State private var tick = 0

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(ChappyCalendar.shared.allCalendars, id: \.calendarIdentifier) { cal in
                        Button {
                            ChappyCalendar.shared.setOn(cal, !ChappyCalendar.shared.isEnabled(cal))
                            tick += 1
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(cal.cgColor ?? UIColor.systemGray.cgColor))
                                    .frame(width: 11, height: 11)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(cal.title)
                                    if let src = cal.source?.title {
                                        Text(src).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if ChappyCalendar.shared.isEnabled(cal) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .id("\(cal.calendarIdentifier)-\(tick)")
                    }
                } footer: {
                    Text("Everything is on until you switch it off. If your iCloud events aren't here at all, Chappy hasn't been granted calendar access \u{2014} check iOS Settings, Chappy, Calendars.")
                }
            }
            .navigationTitle("Calendars")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - BUILD 164: one day, and making new events

/// Tapping a day in Week or Month lands here: everything on it, plus a
/// button to add something.
private struct DayListSheet: View {
    let day: Date
    let theme: ChappyTheme
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tick = 0
    @State private var picked: EKEvent?
    @State private var showNew = false

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                let events = ChappyCalendar.shared.events(onDay: day)
                let rems = ChappyReminders.shared.open.filter {
                    $0.doneAt == nil && ($0.effectiveFire.map {
                        Calendar.current.isDate($0, inSameDayAs: day) } ?? false)
                }
                if events.isEmpty && rems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 46))
                            .foregroundColor(theme.textSecondary.opacity(0.6))
                        Text("Nothing on.")
                            .font(.subheadline).foregroundColor(theme.textSecondary)
                        Button {
                            showNew = true
                        } label: {
                            Label("Add something", systemImage: "plus")
                                .font(.subheadline).fontWeight(.semibold)
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .background(Capsule().fill(theme.accent.opacity(0.22)))
                                .foregroundColor(theme.accent)
                        }
                        .buttonStyle(ChappyPressStyle())
                    }
                } else {
                    List {
                        Section("Appointments") {
                            ForEach(events, id: \.eventIdentifier) { e in
                                Button {
                                    picked = e
                                } label: {
                                    HStack(spacing: 10) {
                                        if ChappyCalendar.shared.isStarred(e) {
                                            Image(systemName: "star.fill")
                                                .font(.caption).foregroundStyle(.yellow)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(e.title ?? "Appointment")
                                                .foregroundColor(theme.textPrimary)
                                            Text(e.isAllDay ? "All day"
                                                 : Self.time(e.startDate ?? day))
                                                .font(.caption)
                                                .foregroundColor(theme.textSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundColor(theme.textSecondary)
                                    }
                                }
                            }
                        }
                        if !rems.isEmpty {
                            Section("Reminders") {
                                ForEach(rems) { r in
                                    Button {
                                        ChappyReminders.shared.complete(r.id)
                                        tick += 1; onChange()
                                    } label: {
                                        HStack {
                                            Image(systemName: "circle")
                                                .foregroundColor(theme.accent)
                                            Text(r.title).foregroundColor(theme.textPrimary)
                                            Spacer()
                                            if let f = r.effectiveFire {
                                                Text(Self.time(f)).font(.caption)
                                                    .foregroundColor(theme.textSecondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle(Self.title(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showNew) {
                NewEventSheet(theme: theme, start: day) { tick += 1; onChange() }
            }
            .sheet(item: Binding(
                get: { picked.map { EvBox(e: $0) } },
                set: { picked = $0?.e })) { box in
                    EventDetailSheet(event: box.e, theme: theme) { tick += 1; onChange() }
                }
        }
    }

    private struct EvBox: Identifiable {
        let e: EKEvent
        var id: String { (e.eventIdentifier ?? UUID().uuidString) }
    }

    private static func title(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"
        return f.string(from: d)
    }
    private static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: d)
    }
}

/// Making an appointment inside Chappy, instead of leaving for Apple's
/// Calendar and losing your place.
private struct NewEventSheet: View {
    let theme: ChappyTheme
    let start: Date
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var when = Date()
    @State private var minutes = 60
    @State private var place = ""
    @State private var notes = ""
    @State private var starred = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section("What") {
                    TextField("Appointment", text: $title)
                }
                Section("When") {
                    DatePicker("Starts", selection: $when)
                    Picker("For", selection: $minutes) {
                        Text("15 min").tag(15); Text("30 min").tag(30)
                        Text("1 hour").tag(60); Text("2 hours").tag(120)
                        Text("Half day").tag(240); Text("All day").tag(1440)
                    }
                }
                Section("Where") {
                    TextField("Address or place (optional)", text: $place)
                }
                Section("Notes") {
                    TextField("Anything worth remembering", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    Toggle(isOn: $starred) {
                        Label("Star it", systemImage: "star.fill")
                    }
                } footer: {
                    Text("Starred appointments lead the morning brief and get a firmer warn-time.")
                }
                if let e = error {
                    Section { Text(e).font(.caption).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("New appointment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") { save() }.fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                // Land on the tapped day, at the next sensible hour.
                let cal = Calendar.current
                let hour = cal.isDateInToday(start)
                    ? min(cal.component(.hour, from: Date()) + 1, 20) : 9
                when = cal.date(bySettingHour: hour, minute: 0, second: 0, of: start) ?? start
            }
        }
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = ChappyCalendar.shared.createEvent(
            title: t, start: when, minutes: minutes,
            location: place, notes: notes, allDay: minutes == 1440) {
            error = problem
            return
        }
        if starred, let made = ChappyCalendar.shared.events(onDay: when)
            .first(where: { $0.title == t }) {
            ChappyCalendar.shared.setStarred(true, for: made)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        TTSService.shared.speak("Added. \(t).")
        onSaved()
        dismiss()
    }
}

// =====================================================================
// MARK: - DICTATE → EMAIL (Build 167)
// =====================================================================
//
//   Talk it, tidy it, send it — without retyping a word.
//
//   The honest boundary: iOS will not let any app silently drop a draft
//   into Mail or Outlook. That's a sandbox rule, not a Chappy limit —
//   no third-party app on your phone can do it. What IS allowed, and
//   what every assistant uses, is handing the finished message over so
//   it opens as an editable draft with one tap to send. Your address
//   book, your account, your send button.
//
//   Outlook publishes its own scheme, so if it's installed you get the
//   choice; otherwise it goes to whatever iOS has set as default mail —
//   which may well be Outlook anyway.

struct DictateEmailSheet: View {

    let theme: ChappyTheme
    let body_: String

    init(theme: ChappyTheme, body: String) {
        self.theme = theme
        self.body_ = body
        _subject = State(initialValue: Self.suggestedSubject(body))
    }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_email_recents") private var recentsRaw = ""
    @AppStorage("chappy_email_prefer_outlook") private var preferOutlook = false

    @State private var to = ""
    @State private var subject: String
    @State private var sent = false

    private var recents: [String] {
        recentsRaw.split(separator: "|").map(String.init).filter { !$0.isEmpty }
    }

    /// Chappy already knows the addresses you actually use.
    private var known: [String] {
        var out = recents
        if ChappyMail.shared.isConfigured, !ChappyMail.shared.address.isEmpty {
            out.append(ChappyMail.shared.address)
        }
        return Array(NSOrderedSet(array: out).compactMap { $0 as? String }).prefix(6).map { $0 }
    }

    var body: some View {
        NavigationView {
            Form {
                Section("To") {
                    TextField("name@example.com", text: $to)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !known.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(known, id: \.self) { a in
                                    Button {
                                        to = a
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    } label: {
                                        Text(a)
                                            .font(.caption).fontWeight(.medium)
                                            .padding(.horizontal, 11).padding(.vertical, 6)
                                            .background(Capsule().fill(theme.accent.opacity(0.16)))
                                            .foregroundColor(theme.accent)
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(ChappyPressStyle(scale: 0.94))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                Section("Subject") {
                    TextField("Subject", text: $subject)
                }
                Section("Message") {
                    Text(body_)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                }
                if ChappyMail.hasOutlook {
                    Section {
                        Toggle("Open in Outlook", isOn: $preferOutlook)
                    } footer: {
                        Text("Off sends it to whichever mail app iOS has set as your default.")
                    }
                }
                Section {
                    Button {
                        hand(off: true)
                    } label: {
                        Label("Open as a draft", systemImage: "square.and.pencil")
                            .fontWeight(.semibold)
                    }
                    .disabled(to.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("Opens your mail app with everything filled in — recipient, subject and message. One tap there sends it. Chappy never sends mail on your behalf.")
                }
            }
            .navigationTitle("Email this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func hand(off: Bool) {
        let address = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        // Remember who you write to, so next time it's one tap.
        var list = recents.filter { $0.caseInsensitiveCompare(address) != .orderedSame }
        list.insert(address, at: 0)
        recentsRaw = list.prefix(6).joined(separator: "|")

        _ = ChappyMail.compose(to: address,
                               subject: subject.isEmpty ? "Note from Chappy" : subject,
                               body: body_,
                               preferOutlook: preferOutlook)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    /// First sensible line becomes the subject — the thing you'd have
    /// typed anyway.
    private static func suggestedSubject(_ text: String) -> String {
        // A Job Report starts with a label; the line after it is the meat.
        let lines = text.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        for l in lines {
            let cleaned = l.replacingOccurrences(of: "Reported issue:", with: "")
                .trimmingCharacters(in: .whitespaces)
            if cleaned.count > 3 {
                return String(cleaned.split(separator: ".").first.map(String.init) ?? cleaned)
                    .prefix(60).trimmingCharacters(in: .whitespaces)
            }
        }
        return "Note from Chappy"
    }
}

// =====================================================================
// MARK: - DOCUMENT SCANNER (Build 168)
// =====================================================================
//
//   For a page in your hand, the phone beats the glasses at any
//   resolution — you're photographing a flat thing at an angle from a
//   moving head, and no amount of megapixels fixes the geometry.
//
//   iOS gives us the right tool free: VNDocumentCameraViewController,
//   the exact scanner Apple Notes and Files use. It finds the page
//   edges by itself, corrects the perspective so the page comes out
//   flat and square, handles multiple pages in one go, and hands back
//   clean images. Then the same on-device OCR reads them.

struct DocumentScanner: UIViewControllerRepresentable {
    var onFinished: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinished: ([UIImage]) -> Void
        init(onFinished: @escaping ([UIImage]) -> Void) { self.onFinished = onFinished }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var pages: [UIImage] = []
            for i in 0..<scan.pageCount { pages.append(scan.imageOfPage(at: i)) }
            controller.dismiss(animated: true)
            onFinished(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
            onFinished([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            controller.dismiss(animated: true)
            onFinished([])
        }
    }
}

/// On-device OCR for scanned pages. Free, private, no network — the same
/// engine Reader uses, exposed here so the scanner can feed Dictate.
enum ChappyPageOCR {
    static func read(_ images: [UIImage]) async -> String {
        var out: [String] = []
        for img in images {
            guard let cg = img.cgImage else { continue }
            let text: String = await withCheckedContinuation { cont in
                let req = VNRecognizeTextRequest { r, _ in
                    let lines = (r.results as? [VNRecognizedTextObservation] ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                    cont.resume(returning: lines.joined(separator: "\n"))
                }
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let h = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
                    do { try h.perform([req]) } catch { cont.resume(returning: "") }
                }
            }
            if !text.isEmpty { out.append(text) }
        }
        return out.joined(separator: "\n\n")
    }
}

// =====================================================================
// MARK: - NOTIFICATION DOCTOR (Build 172)
// =====================================================================
//
//   "Notifications don't work outside the app at all."
//
//   Chappy's reminders ARE real iOS notifications — scheduled with
//   UNCalendarNotificationTrigger and UNTimeIntervalNotificationTrigger,
//   handed to the system, and delivered by iOS whether the app is
//   running or not. That machinery is correct and it re-arms on every
//   launch. So when nothing arrives, the cause is one of exactly four
//   things, and until now there was no way to tell which:
//
//     1. Permission is off or was never granted.
//     2. Scheduled Summary is holding them for a batch delivery.
//     3. A Focus mode is eating them (no Time Sensitive permission).
//     4. Nothing was ever actually scheduled.
//
//   Number 4 is the one nobody can diagnose by feel — and it's the one
//   this screen settles instantly, because it shows you the PENDING
//   QUEUE: every notification iOS is currently holding for Chappy, with
//   its fire time. If that list has items and they never arrive, it's
//   1-3. If it's empty, the fault is upstream and I need to fix it.

struct NotificationDoctor: View {

    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @State private var settings: UNNotificationSettings?
    @State private var pending: [UNNotificationRequest] = []
    @State private var note = ""

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                List {
                    permissionSection
                    suppressionSection
                    queueSection
                    actionsSection
                    if !note.isEmpty {
                        Section { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(theme.accent)
                }
            }
            .task { await refresh() }
        }
    }

    // MARK: sections

    @ViewBuilder
    private var permissionSection: some View {
        Section("Permission") {
            row("Allowed", ok: settings.map {
                $0.authorizationStatus == .authorized || $0.authorizationStatus == .provisional
            } ?? false)
            row("Banners", ok: settings?.alertSetting == .enabled)
            row("Sounds", ok: settings?.soundSetting == .enabled)
            row("Lock screen", ok: settings?.lockScreenSetting == .enabled)
        }
    }

    @ViewBuilder
    private var suppressionSection: some View {
        Section {
            // These two are the usual culprits, and neither is obvious.
            row("Scheduled Summary OFF",
                ok: settings?.scheduledDeliverySetting != .enabled,
                bad: "ON — iOS is holding your notifications back and delivering them in a batch. This alone explains \"nothing arrives\".")
            row("Time Sensitive allowed",
                ok: settings?.timeSensitiveSetting != .disabled,
                bad: "Off — any Focus mode will silence warn-times.")
        } header: {
            Text("The quiet killers")
        } footer: {
            Text("Scheduled Summary is under iOS Settings > Notifications > Scheduled Summary. Time Sensitive is under Settings > Chappy > Notifications.")
        }
    }

    @ViewBuilder
    private var queueSection: some View {
        Section {
            if pending.isEmpty {
                Label("Nothing queued", systemImage: "tray")
                    .foregroundStyle(.orange)
                Text("If you have reminders set and this is empty, they were never handed to iOS — that's a fault in Chappy, not a setting. Tap \u{201C}Re-arm everything\u{201D} below, then come back. If it's still empty, tell me.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(pending.prefix(8), id: \.identifier) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.content.title.isEmpty ? "Reminder" : r.content.title)
                            .font(.subheadline)
                        Text(Self.when(r.trigger))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if pending.count > 8 {
                    Text("+ \(pending.count - 8) more").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Queued with iOS (\(pending.count))")
        } footer: {
            Text("These are handed to the system — they fire whether Chappy is open, closed or the phone is locked. If they're listed here and still never appear, the cause is one of the settings above.")
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                if let u = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(u, options: [:], completionHandler: nil)
                }
            } label: { Label("Open iOS notification settings", systemImage: "gear") }

            Button {
                fireTest(after: 20)
            } label: {
                Label("Test in 20 seconds — then LOCK THE PHONE",
                      systemImage: "lock.iphone")
            }

            Button {
                ChappyReminders.shared.rescheduleAll()
                Task { await refresh() }
                note = "Re-armed. Check the queue count above."
            } label: { Label("Re-arm everything", systemImage: "arrow.clockwise") }
        } header: {
            Text("Prove it")
        } footer: {
            Text("The 20-second test is the honest one: lock the phone and put it down. A banner that arrives on a locked screen proves the whole chain works outside the app.")
        }
    }

    // MARK: work

    private func row(_ label: String, ok: Bool, bad: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(label)
                Spacer()
            }
            if !ok, let b = bad {
                Text(b).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func refresh() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        let p = await UNUserNotificationCenter.current().pendingNotificationRequests()
        await MainActor.run {
            settings = s
            pending = p.sorted { a, b in
                (Self.fireDate(a.trigger) ?? .distantFuture) < (Self.fireDate(b.trigger) ?? .distantFuture)
            }
        }
    }

    private func fireTest(after seconds: TimeInterval) {
        let c = UNMutableNotificationContent()
        c.title = "Chappy works outside the app"
        c.body = "This arrived with Chappy closed. The chain is fine."
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        let req = UNNotificationRequest(
            identifier: "chappy-doctor-\(Int(Date().timeIntervalSince1970))",
            content: c,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))
        UNUserNotificationCenter.current().add(req)
        note = "Sent. Lock the phone now — it lands in \(Int(seconds)) seconds."
        TTSService.shared.speak("Lock the phone. It'll arrive in twenty seconds.")
        Task { await refresh() }
    }

    private static func fireDate(_ t: UNNotificationTrigger?) -> Date? {
        if let c = t as? UNCalendarNotificationTrigger { return c.nextTriggerDate() }
        if let i = t as? UNTimeIntervalNotificationTrigger { return i.nextTriggerDate() }
        return nil
    }

    private static func when(_ t: UNNotificationTrigger?) -> String {
        guard let d = fireDate(t) else { return "when you arrive somewhere" }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM, h:mm a"
        return f.string(from: d)
    }
}

// =====================================================================
// MARK: - WEATHER STATION (Build 173)
// =====================================================================
//
//   Every instrument on one screen, for wherever you are or anywhere
//   you name — and every panel speakable, because the phone is usually
//   in a pocket when the question comes up.

struct WeatherStation: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var wx = ChappyWeather.shared
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @State private var search = ""
    @State private var searching = false

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        searchBar
                        if wx.loading && wx.now == nil {
                            ProgressView().tint(theme.accent).padding(.top, 40)
                        }
                        if let e = wx.error, wx.now == nil {
                            Text(e).font(.subheadline)
                                .foregroundColor(.orange).padding()
                        }
                        if let n = wx.now {
                            headline(n)
                            instruments(n)
                            if !wx.hours.isEmpty { hourStrip }
                            if !wx.days.isEmpty { weekPanel }
                            sunPanel(n)
                        todayPanel()
                        freshness
                            speakRow
                            satelliteRow
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("Weather")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await wx.loadHere() }
                    } label: {
                        Image(systemName: "location.fill").foregroundColor(theme.accent)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(theme.accent)
                }
            }
            .task { if wx.now == nil { await wx.loadHere() } }
        }
    }

    // MARK: pieces

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(theme.textSecondary)
            TextField("Anywhere — Ubud, Brisbane, Denpasar…", text: $search)
                .submitLabel(.search)
                .onSubmit {
                    let q = search.trimmingCharacters(in: .whitespaces)
                    guard !q.isEmpty else { return }
                    searching = true
                    Task { await wx.loadPlace(q); searching = false }
                }
            if searching { ProgressView().scaleEffect(0.7) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 13).fill(.ultraThinMaterial))
    }

    private func headline(_ n: ChappyWeather.Now) -> some View {
        VStack(spacing: 6) {
            Text(wx.placeName)
                .font(.caption).fontWeight(.semibold)
                .foregroundColor(theme.textSecondary)
            Image(systemName: ChappyWeather.symbol(n.code, day: n.isDay))
                .font(.system(size: 56))
                .foregroundStyle(theme.accent)
                .shadow(color: theme.accent.opacity(0.6), radius: 18)
            Text("\(Int(n.tempC.rounded()))°")
                .font(.system(size: 62, weight: .thin))
                .foregroundColor(theme.textPrimary)
            Text(ChappyWeather.describe(n.code).capitalized)
                .font(.title3).foregroundColor(theme.textPrimary)
            Text("Feels like \(Int(n.feelsC.rounded()))°"
                 + (wx.days.first.map { " · \(Int($0.minC.rounded()))° to \(Int($0.maxC.rounded()))°" } ?? ""))
                .font(.subheadline).foregroundColor(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
    }

    private func instruments(_ n: ChappyWeather.Now) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 9),
                            GridItem(.flexible(), spacing: 9)], spacing: 9) {
            gauge("Wind", "\(Int(n.windKmh)) km/h",
                  sub: "from the \(ChappyWeather.compass(n.windDeg))",
                  icon: "wind", tint: .cyan)
            gauge("Gusts", "\(Int(n.gustKmh)) km/h",
                  sub: n.gustKmh >= 40 ? "strong" : "steady",
                  icon: "wind.circle", tint: n.gustKmh >= 40 ? .orange : .cyan)
            gauge("Humidity", "\(n.humidity)%",
                  sub: "dew point \(Int(n.dewC.rounded()))°",
                  icon: "humidity.fill", tint: .blue)
            gauge("Rain now", String(format: "%.1f mm", n.rainMm),
                  sub: wx.days.first.map { "\($0.rainChance)% today" } ?? "",
                  icon: "drop.fill", tint: .blue)
            gauge("Cloud", "\(n.cloudPct)%",
                  sub: n.cloudPct > 70 ? "overcast" : (n.cloudPct > 30 ? "broken" : "clear"),
                  icon: "cloud.fill", tint: .gray)
            gauge("Pressure", "\(Int(n.pressure.rounded())) hPa",
                  sub: n.pressure < 1005 ? "low — change coming" : "steady",
                  icon: "barometer", tint: .purple)
            gauge("UV", String(format: "%.0f", n.uv),
                  sub: ChappyWeather.uvWord(n.uv),
                  icon: "sun.max.trianglebadge.exclamationmark",
                  tint: n.uv >= 6 ? .orange : .yellow)
            gauge("Visibility",
                  n.visibilityM >= 1000 ? "\(Int(n.visibilityM / 1000)) km"
                                        : "\(Int(n.visibilityM)) m",
                  sub: n.visibilityM < 2000 ? "poor" : "clear",
                  icon: "eye.fill", tint: .teal)
        }
    }

    private func gauge(_ title: String, _ value: String, sub: String,
                       icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .heavy)).tracking(0.6)
            }
            .foregroundStyle(tint)
            Text(value)
                .font(.title3).fontWeight(.semibold)
                .foregroundColor(theme.textPrimary)
                .minimumScaleFactor(0.7).lineLimit(1)
            if !sub.isEmpty {
                Text(sub).font(.caption2).foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 15)
            .stroke(tint.opacity(0.28), lineWidth: 1))
    }

    private var hourStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("NEXT 24 HOURS")
                .font(.caption2).fontWeight(.heavy).tracking(0.7)
                .foregroundColor(theme.accent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(wx.hours) { h in
                        VStack(spacing: 5) {
                            Text(Self.hourLabel(h.at))
                                .font(.caption2).foregroundColor(theme.textSecondary)
                            Image(systemName: ChappyWeather.symbol(h.code))
                                .font(.system(size: 16))
                                .foregroundStyle(theme.accent)
                            Text("\(Int(h.tempC.rounded()))°")
                                .font(.caption).fontWeight(.semibold)
                                .foregroundColor(theme.textPrimary)
                            Text(h.rainChance > 0 ? "\(h.rainChance)%" : " ")
                                .font(.system(size: 9))
                                .foregroundColor(h.rainChance >= 40 ? .blue : theme.textSecondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15).fill(.ultraThinMaterial))
    }

    private var weekPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THE WEEK")
                .font(.caption2).fontWeight(.heavy).tracking(0.7)
                .foregroundColor(theme.accent)
            ForEach(Array(wx.days.enumerated()), id: \.element.id) { i, d in
                HStack(spacing: 10) {
                    Text(i == 0 ? "Today" : Self.dayLabel(d.at))
                        .font(.subheadline)
                        .foregroundColor(theme.textPrimary)
                        .frame(width: 82, alignment: .leading)
                    Image(systemName: ChappyWeather.symbol(d.code))
                        .font(.system(size: 14)).foregroundStyle(theme.accent)
                        .frame(width: 22)
                    if d.rainChance > 0 {
                        Text("\(d.rainChance)%")
                            .font(.caption2)
                            .foregroundColor(d.rainChance >= 40 ? .blue : theme.textSecondary)
                            .frame(width: 34, alignment: .leading)
                    } else {
                        Spacer().frame(width: 34)
                    }
                    Spacer()
                    Text("\(Int(d.minC.rounded()))°")
                        .font(.subheadline).foregroundColor(theme.textSecondary)
                    Capsule()
                        .fill(LinearGradient(colors: [.blue.opacity(0.7), .orange.opacity(0.9)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: 52, height: 4)
                    Text("\(Int(d.maxC.rounded()))°")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(theme.textPrimary)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15).fill(.ultraThinMaterial))
    }

    private func sunPanel(_ n: ChappyWeather.Now) -> some View {
        HStack(spacing: 0) {
            if let d = wx.days.first {
                sunCell("Sunrise", d.sunrise, "sunrise.fill", .orange)
                sunCell("Sunset", d.sunset, "sunset.fill", .pink)
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 15).fill(.ultraThinMaterial))
    }

    // BUILD 182 — THE THREE THAT WERE FETCHED AND NEVER SHOWN.
    //
    // ChappyWeather has always pulled the day's total rainfall, the day's
    // PEAK UV and the day's maximum wind. All three went straight into the
    // morning brief and were invisible on the screen built to show every
    // instrument — so the UV gauge showed the reading for right now, which
    // at 7am is zero, while the day was going to hit eleven.
    private func todayPanel() -> some View {
        Group {
            if let d = wx.days.first {
                VStack(alignment: .leading, spacing: 10) {
                    Text("TODAY'S PEAKS")
                        .font(.caption2).fontWeight(.heavy).tracking(0.6)
                        .foregroundColor(.cyan)
                    HStack(spacing: 0) {
                        peakCell("Rain today", d.rainMm >= 0.1
                                    ? String(format: "%.1f mm", d.rainMm) : "None",
                                 "drop.fill", .blue,
                                 d.rainChance > 0 ? "\(d.rainChance)% chance" : "")
                        peakCell("Peak UV", "\(Int(d.uvMax.rounded()))",
                                 "sun.max.trianglebadge.exclamationmark.fill",
                                 d.uvMax >= 8 ? .red : (d.uvMax >= 6 ? .orange : .yellow),
                                 ChappyWeather.uvWord(d.uvMax))
                        peakCell("Top wind", "\(Int(d.windMaxKmh.rounded()))",
                                 "wind", .teal, "km/h")
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 15).fill(.ultraThinMaterial))
            }
        }
    }

    private func peakCell(_ title: String, _ value: String, _ icon: String,
                          _ tint: Color, _ sub: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(tint)
            Text(title).font(.caption2).foregroundColor(theme.textSecondary)
            Text(value)
                .font(.subheadline).fontWeight(.semibold)
                .foregroundColor(theme.textPrimary)
            if !sub.isEmpty {
                Text(sub).font(.system(size: 10)).foregroundColor(theme.textSecondary.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// BUILD 182: how old the reading is. Every other data screen in the
    /// app says this — the currency screen has said it since 177 — and the
    /// one built around live instruments did not, so a twenty-minute-old
    /// wind speed looked exactly like a live one.
    private var freshness: some View {
        Group {
            if let at = wx.fetchedAt {
                let mins = Int(Date().timeIntervalSince(at) / 60)
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text(mins < 1 ? "Just now"
                         : (mins < 60 ? "As at \(Self.timeLabel(at)) · \(mins) min ago"
                                      : "As at \(Self.timeLabel(at))"))
                    Spacer()
                    if mins >= 30 {
                        Button {
                            Task { await wx.loadHere() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(theme.accent)
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(mins >= 60 ? .orange : theme.textSecondary.opacity(0.85))
                .padding(.horizontal, 4)
            }
        }
    }

    private func sunCell(_ title: String, _ d: Date?, _ icon: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(tint)
            Text(title).font(.caption2).foregroundColor(theme.textSecondary)
            Text(d.map { Self.timeLabel($0) } ?? "—")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundColor(theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    private var speakRow: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 9),
                            GridItem(.flexible(), spacing: 9)], spacing: 9) {
            speakButton("Read it out", "speaker.wave.2.fill", theme.accent) {
                TTSService.shared.speakLong(wx.spokenFull())
            }
            speakButton("The week", "calendar", .purple) {
                TTSService.shared.speakLong(wx.spokenWeek())
            }
            speakButton("Will it rain?", "umbrella.fill", .blue) {
                TTSService.shared.speakLong(wx.spokenRain())
            }
            speakButton("Refresh", "arrow.clockwise", .green) {
                Task {
                    if let c = wx.coord {
                        await wx.load(lat: c.latitude, lon: c.longitude, name: wx.placeName)
                    } else { await wx.loadHere() }
                }
            }
        }
    }

    private func speakButton(_ t: String, _ icon: String, _ tint: Color,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
                Text(t).font(.subheadline).fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 13).fill(tint.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(tint.opacity(0.45), lineWidth: 1))
            .foregroundStyle(tint)
        }
        .buttonStyle(ChappyPressStyle())
    }

    private var satelliteRow: some View {
        Button {
            if let c = wx.coord, let u = ChappyAtlas.zoomEarthURL(c, zoom: 7) {
                UIApplication.shared.open(u, options: [:], completionHandler: nil)
            }
        } label: {
            HStack {
                Image(systemName: "globe.americas.fill").foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Live satellite & radar").font(.subheadline)
                        .foregroundColor(theme.textPrimary)
                    Text("Opens Zoom Earth on this spot")
                        .font(.caption2).foregroundColor(theme.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption).foregroundColor(theme.textSecondary)
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 15).fill(.ultraThinMaterial))
        }
        .buttonStyle(ChappyPressStyle())
    }

    private static func hourLabel(_ d: Date) -> String {
        if Calendar.current.isDate(d, equalTo: Date(), toGranularity: .hour) { return "Now" }
        let f = DateFormatter(); f.dateFormat = "h a"
        return f.string(from: d)
    }
    private static func dayLabel(_ d: Date) -> String {
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: d)
    }
    private static func timeLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: d)
    }
}

// =====================================================================
// MARK: - THE BRIEF STUDIO (Build 173)
// =====================================================================
//
//   "How is the morning brief composed, and where can I change it?"
//
//   Fair question, because until now the answer was: nowhere. There was
//   a single on/off toggle buried in Settings and no way to see what
//   went into a brief, when they happen, or what the last one actually
//   said.
//
//   HOW IT'S BUILT, plainly: at each scheduled time Chappy gathers four
//   things — your agenda for the period, your open reminders, a digest
//   of what it has remembered recently, and where you are — hands them
//   to Claude with instructions to be brief and to stay silent if
//   there's nothing worth saying, and speaks the result. If nothing is
//   notable it says nothing at all, which is why some slots pass in
//   silence. That is the design, not a fault.

struct BriefStudio: View {

    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @AppStorage("chappy_morning_brief") private var morningBrief = true
    @State private var times: [String] = ChappyProactive.shared.times
    @State private var quietStart = ChappyProactive.shared.quietStartHour
    @State private var quietEnd = ChappyProactive.shared.quietEndHour
    @State private var enabled = ChappyProactive.shared.isEnabled
    @State private var running = false
    @State private var note = ""

    private static let allTimes = ["06:00","07:00","08:00","09:00","10:00","11:00",
                                   "12:00","13:00","14:00","15:00","16:00","17:00",
                                   "18:00","19:00","20:00","21:00","22:00"]

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                List {
                    lastBriefSection
                    ingredientsSection
                    timesSection
                    quietSection
                    actionsSection
                    if !note.isEmpty {
                        Section { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Briefs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(theme.accent)
                }
            }
        }
    }

    private var lastBriefSection: some View {
        Section {
            let last = ChappyProactive.shared.lastBrief
            if last.isEmpty {
                Text("No brief yet today.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(last).font(.callout)
                Button {
                    TTSService.shared.speakLong(last)
                } label: { Label("Read it again", systemImage: "speaker.wave.2.fill") }
            }
        } header: {
            Text("The last brief")
        } footer: {
            Text("Say \u{201C}what was my brief\u{201D} any time to hear this again.")
        }
    }

    private var ingredientsSection: some View {
        Section {
            row("Your agenda", "calendar",
                "Calendar events and jobs in the period ahead")
            row("Open reminders", "bell.fill",
                "Anything due, overdue or place-triggered")
            row("Recent memory", "brain",
                "A digest of what Chappy has filed lately")
            row("Where you are", "location.fill",
                "Place, and the weather there")
        } header: {
            Text("What goes into one")
        } footer: {
            Text("Chappy hands those four to Claude with one instruction above all others: if there is nothing worth saying, say nothing. That's why some slots pass in silence — it's the design, not a fault. Starred appointments always lead.")
        }
    }

    private var timesSection: some View {
        Section {
            ForEach(Self.allTimes, id: \.self) { t in
                Button {
                    if times.contains(t) { times.removeAll { $0 == t } }
                    else { times.append(t) }
                    times.sort()
                    ChappyProactive.shared.times = times
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    HStack {
                        Text(Self.pretty(t))
                        Spacer()
                        if times.contains(t) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        } header: {
            Text("When (\(times.count) a day)")
        } footer: {
            Text("Chappy checks at each of these. It only speaks when there's something notable, so more times doesn't mean more talking — it means fewer missed things.")
        }
    }

    private var quietSection: some View {
        Section {
            Stepper("Quiet from \(quietStart):00", value: $quietStart, in: 18...23)
                .onChange(of: quietStart) { _, v in ChappyProactive.shared.quietStartHour = v }
            Stepper("Quiet until \(quietEnd):00", value: $quietEnd, in: 4...10)
                .onChange(of: quietEnd) { _, v in ChappyProactive.shared.quietEndHour = v }
            Toggle("Morning brief on first pick-up", isOn: $morningBrief)
        } header: {
            Text("Quiet hours")
        } footer: {
            Text("Nothing is spoken between these hours. Reminders still land silently and come back in the morning brief — except anything marked must-not-miss.")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                running = true
                note = "Composing…"
                Task {
                    await ChappyProactive.shared.runNow()
                    running = false
                    note = "Done — see The last brief above."
                }
            } label: {
                Label(running ? "Composing…" : "Compose one now", systemImage: "wand.and.stars")
            }
            .disabled(running)
        } footer: {
            Text("Builds a brief from right now, whatever the time. The quickest way to see what yours actually sounds like.")
        }
    }

    private func row(_ title: String, _ icon: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private static func pretty(_ t: String) -> String {
        let parts = t.split(separator: ":")
        guard let h = Int(parts.first ?? "") else { return t }
        let ampm = h < 12 ? "am" : "pm"
        let display = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        return "\(display):00 \(ampm)"
    }
}

// =====================================================================
// BUILD 177 — THE TRAVEL DESK.
//
// One screen that holds a whole trip: the map, the money, the legs, the
// places to eat and see, the weather for the month you're actually
// going, and a booking link per leg with your dates already in it.
//
// What it deliberately does NOT do is pretend to book. Airbnb has had no
// public API since 2019; Booking, Agoda, Trip.com, Klook and Traveloka
// all gate theirs behind an approved commercial agreement; Facebook
// Marketplace has never had one at all. So the honest design — and the
// one TripIt, Wanderlog and Kayak's planner all use — is: do the
// thinking here, hand off with everything pre-filled. Every link below
// is a plain universal link, so it opens the app if you have it and the
// site if you don't.
// =====================================================================

struct TravelDeskView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @ObservedObject private var desk = ChappyTravel.shared
    @ObservedObject private var fx = ChappyFX.shared
    /// AUDIT: the per-leg climate line read ChappySeason but never observed
    /// it, so the normals landed after the last redraw and the row stayed
    /// invisible until something unrelated forced a refresh.
    @ObservedObject private var season = ChappySeason.shared

    @State private var showNewTrip = false
    @State private var showTripFile = false
    @State private var showFlights = false
    /// BUILD 199: which section is open. Travel by default — it is
    /// September, and everything else can wait behind one tap.
    @State private var openGroup = "travel"
    @State private var showBudget = false
    @State private var newName = ""
    @State private var newPlace = ""
    @State private var editingLeg: ChappyTravel.Leg?
    @State private var placesLeg: ChappyTravel.Leg?
    @State private var showTripPicker = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -8.5, longitude: 115.2),
        span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6))

    private var trip: ChappyTravel.Trip? { desk.active }

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                if let t = trip {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            headerCard(t)
                            // BUILD 190: high in the stack on purpose. It
                            // decides the fare, the bags, the last day and
                            // whether you can be boarded — that belongs
                            // above the money, not buried under it.
                            ChappyOneWayCard(trip: t, theme: theme)
                            mapCard(t)
                            moneyCard(t)
                            legsCard(t)
                            extrasCard(t)
                                            actionsCard(t)
                            gripeCard(t)
                            honestyNote
                        }
                        .padding(14)
                        .padding(.bottom, 40)
                    }
                } else {
                    emptyState
                }
            }
            .sheet(isPresented: $showTripFile) { ChappyTripFileView(theme: theme) }
            .sheet(isPresented: $showFlights) { ChappyFlightsView() }
            .sheet(isPresented: $showBudget) { ChappyBudgetView(theme: theme) }
            .navigationTitle("Travel Desk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showTripFile = true
                        } label: { Label("Trip file", systemImage: "folder.fill") }
                        Button {
                            showFlights = true
                        } label: { Label("Flights", systemImage: "airplane") }
                        Button {
                            showBudget = true
                        } label: { Label("What will it buy", systemImage: "dollarsign.circle") }
                        Button {
                            newName = ""; showNewTrip = true
                        } label: { Label("New trip", systemImage: "plus") }
                        if desk.trips.count > 1 {
                            Button {
                                showTripPicker = true
                            } label: { Label("Switch trip", systemImage: "arrow.left.arrow.right") }
                        }
                        if let t = trip {
                            Button(role: .destructive) {
                                desk.deleteTrip(t.id)
                            } label: { Label("Delete this trip", systemImage: "trash") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .task {
                await fx.refresh()
                await loadSeasons()
                frameMap()
            }
            .onChange(of: desk.activeID) { _ in frameMap(); Task { await loadSeasons() } }
            .alert("New trip", isPresented: $showNewTrip) {
                TextField("Bali, September", text: $newName)
                Button("Create") {
                    let t = desk.newTrip(named: newName)
                    _ = t
                }
                Button("Cancel", role: .cancel) { }
            }
            .confirmationDialog("Switch trip", isPresented: $showTripPicker, titleVisibility: .visible) {
                ForEach(desk.trips) { t in
                    // AUDIT: activeID is only written to disk inside the
                    // private save(), so switching trips didn't survive a
                    // relaunch unless some other edit happened to save.
                    Button(t.name) { desk.activeID = t.id; desk.savePublic() }
                }
            }
            .sheet(item: $editingLeg) { leg in
                LegEditorSheet(legID: leg.id, theme: theme)
            }
            .sheet(item: $placesLeg) { leg in
                LegPlacesSheet(legID: leg.id, theme: theme)
            }
            .sheet(isPresented: $showShare) {
                if let u = shareURL { ChappyShareSheet(items: [u]) }
            }
            .sheet(isPresented: $showPlanner) { TripPlannerSheet(theme: theme) }
            .sheet(isPresented: $showOptionsSheet) { TripOptionsSheet() }
            .sheet(isPresented: $showIntakeSheet) { IntakeSheet() }
            .fullScreenCover(isPresented: $showBigMap) { TripAtlasView() }
            .sheet(isPresented: $showVisaDesk) { VisaDeskView() }
            .overlay {
                if desk.planning {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        VStack(spacing: 14) {
                            ProgressView().tint(theme.accent).scaleEffect(1.3)
                            Text("Pricing your trip…")
                                .font(.headline).foregroundColor(.white)
                            Text("Checking real prices and how to get between places. Up to a minute.")
                                .font(.caption).foregroundColor(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                    }
                }
            }
        }
    }

    // MARK: header

    private func headerCard(_ t: ChappyTravel.Trip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.name)
                .font(.title2).fontWeight(.bold)
                .foregroundColor(theme.textPrimary)
            Text(t.dateLine)
                .font(.subheadline)
                .foregroundColor(theme.textSecondary)
            HStack(spacing: 14) {
                stat("\(t.nights)", t.nights == 1 ? "night" : "nights")
                stat("\(t.legs.count)", t.legs.count == 1 ? "place" : "places")
                stat("\(t.party)", t.party == 1 ? "traveller" : "travelling")
                Spacer()
                Stepper("", value: Binding(
                    get: { t.party },
                    set: { var c = t; c.party = max(1, $0); desk.update(c) }
                ), in: 1...12)
                .labelsHidden()
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func stat(_ big: String, _ small: String) -> some View {
        HStack(spacing: 4) {
            Text(big).font(.headline).foregroundColor(theme.accent)
            Text(small).font(.caption).foregroundColor(theme.textSecondary)
        }
    }

    // MARK: map

    private struct LegPin: Identifiable {
        let id: UUID
        let coord: CLLocationCoordinate2D
        let n: Int
    }

    private func pins(_ t: ChappyTravel.Trip) -> [LegPin] {
        t.legs.enumerated().compactMap { i, leg in
            guard leg.hasCoord else { return nil }
            return LegPin(id: leg.id,
                          coord: CLLocationCoordinate2D(latitude: leg.lat, longitude: leg.lon),
                          n: i + 1)
        }
    }

    private func mapCard(_ t: ChappyTravel.Trip) -> some View {
        Group {
            if pins(t).isEmpty {
                EmptyView()
            } else {
                Map(coordinateRegion: $region, annotationItems: pins(t)) { pin in
                    MapAnnotation(coordinate: pin.coord) {
                        ZStack {
                            Circle().fill(theme.accent).frame(width: 26, height: 26)
                            Circle().stroke(.white.opacity(0.9), lineWidth: 2).frame(width: 26, height: 26)
                            Text("\(pin.n)")
                                .font(.caption2).fontWeight(.heavy)
                                .foregroundColor(.black)
                        }
                        .shadow(radius: 3)
                    }
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    // BUILD 178: the strip is a preview now — the real atlas
                    // is a screen of its own.
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showBigMap = true
                    } label: {
                        Label("Open atlas", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2).fontWeight(.semibold)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }
            }
        }
    }

    /// Frame every leg at once. A map showing one pin when the trip has
    /// six is a map that has quietly lied about the shape of the trip.
    private func frameMap() {
        guard let t = trip else { return }
        let coords = t.legs.filter(\.hasCoord).map { ($0.lat, $0.lon) }
        guard !coords.isEmpty else { return }
        let lats = coords.map(\.0), lons = coords.map(\.1)
        let minLa = lats.min()!, maxLa = lats.max()!
        let minLo = lons.min()!, maxLo = lons.max()!
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLa + maxLa) / 2,
                                           longitude: (minLo + maxLo) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.6, (maxLa - minLa) * 1.6),
                                   longitudeDelta: max(0.6, (maxLo - minLo) * 1.6)))
    }

    private func loadSeasons() async {
        guard let t = trip else { return }
        for leg in t.legs where leg.hasCoord {
            let m = Calendar.current.component(.month, from: leg.arrive)
            await ChappySeason.shared.load(lat: leg.lat, lon: leg.lon, month: m)
        }
    }

    // MARK: money

    private func moneyCard(_ t: ChappyTravel.Trip) -> some View {
        let c = desk.cost(t)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WHAT IT COSTS")
                    .font(.caption2).fontWeight(.heavy).tracking(0.6)
                    .foregroundColor(.cyan)
                Spacer()
                Text(t.homeCurrency)
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundColor(theme.textSecondary)
            }
            Text(ChappyFX.money(c.total, t.homeCurrency))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(theme.textPrimary)
            // BUILD 182: a total built from a missing exchange rate is WRONG,
            // and it used to be shown and spoken with nothing to say so.
            if c.hasUnconverted {
                Label("Some prices couldn't be converted — this total is off until rates load",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // BUILD 181: the total inverts the price rule on purpose —
            // "Rp 65,300,000" tells you nothing about whether you can
            // afford to go, and "$6,240" tells you immediately.
            if let first = t.legs.first {
                let local = desk.localCurrency(for: first, in: t)
                if local != t.homeCurrency,
                   let inLocal = ChappyFX.shared.convert(c.total, from: t.homeCurrency, to: local) {
                    Text(ChappyFX.money(inLocal, local))
                        .font(.subheadline)
                        .foregroundColor(theme.textSecondary.opacity(0.9))
                }
            }
            HStack(spacing: 10) {
                if t.party > 1 {
                    Text("\(ChappyFX.money(c.perPerson, t.homeCurrency)) each")
                }
                Text("\(ChappyFX.money(c.perDay, t.homeCurrency)) a day")
            }
            .font(.subheadline)
            .foregroundColor(theme.textSecondary)

            if c.total > 0 {
                VStack(spacing: 7) {
                    ForEach(c.lines) { line in
                        HStack(spacing: 10) {
                            Image(systemName: line.icon)
                                .font(.caption)
                                .foregroundColor(theme.accent)
                                .frame(width: 18)
                            Text(line.label)
                                .font(.subheadline)
                                .foregroundColor(theme.textPrimary)
                            Spacer()
                            Text(ChappyFX.money(line.amount, t.homeCurrency))
                                .font(.subheadline).fontWeight(.semibold)
                                .foregroundColor(theme.textSecondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule().fill(theme.accent.opacity(0.75))
                                    .frame(width: max(2, geo.size.width
                                        * (c.total > 0 ? line.amount / c.total : 0)))
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .padding(.top, 4)
            }

            HStack {
                Text("Buffer")
                    .font(.caption).foregroundColor(theme.textSecondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { Int(t.bufferPct) },
                    set: { var c2 = t; c2.bufferPct = Double($0); desk.update(c2) }
                )) {
                    ForEach([0, 5, 10, 15, 20, 25], id: \.self) { Text("\($0)%").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            .padding(.top, 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    // MARK: legs

    private func legsCard(_ t: ChappyTravel.Trip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("THE PLAN")
                    .font(.caption2).fontWeight(.heavy).tracking(0.6)
                    .foregroundColor(.cyan)
                Spacer()
                Button {
                    newPlace = ""
                    addLegPrompt = true
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption).fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.accent)
            }

            if t.legs.isEmpty {
                Text("No legs yet. Add a place, or just say \u{201C}add five nights in Ubud\u{201D}.")
                    .font(.subheadline)
                    .foregroundColor(theme.textSecondary)
            }

            ForEach(Array(t.legs.enumerated()), id: \.element.id) { i, leg in
                legRow(leg, index: i, prev: i > 0 ? t.legs[i - 1] : nil, trip: t)
                if i < t.legs.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.07))
                        .frame(height: 1).padding(.leading, 34)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .alert("Add a place", isPresented: $addLegPrompt) {
            TextField("Ubud", text: $newPlace)
            Button("Add") {
                guard let t = trip, !newPlace.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                desk.addLeg(to: t.id, place: newPlace.trimmingCharacters(in: .whitespaces))
                Task { await loadSeasons(); frameMap() }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func legRow(_ leg: ChappyTravel.Leg, index: Int,
                        prev: ChappyTravel.Leg?, trip t: ChappyTravel.Trip) -> some View {
        let f = DateFormatter(); f.dateFormat = "d MMM"
        let month = Calendar.current.component(.month, from: leg.arrive)
        let normals = leg.hasCoord
            ? ChappySeason.shared.normals(lat: leg.lat, lon: leg.lon, month: month) : nil
        let legCur = ChappyTravel.shared.localCurrency(for: leg, in: t)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(theme.accent.opacity(0.22)).frame(width: 26, height: 26)
                    Text("\(index + 1)")
                        .font(.caption2).fontWeight(.heavy)
                        .foregroundColor(theme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(leg.place)
                        .font(.headline)
                        .foregroundColor(theme.textPrimary)
                    Text("\(f.string(from: leg.arrive)) – \(f.string(from: leg.depart)) · \(leg.nights) \(leg.nights == 1 ? "night" : "nights")")
                        .font(.caption)
                        .foregroundColor(theme.textSecondary)
                }
                Spacer()
                Button {
                    editingLeg = leg
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.footnote)
                        .foregroundColor(theme.accent)
                        .padding(7)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }

            // BUILD 181 — LOCAL FIRST, DOLLARS BESIDE IT, AND A GRADE.
            //
            // "Rp 1,450,000 a night" means nothing on its own unless you
            // already know what villas in Canggu go for in September — and
            // if you knew that you wouldn't need the app. The band is what
            // turns the number into information.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Label(leg.arrival.label, systemImage: leg.arrival.icon)
                    if leg.arrivalCost > 0 {
                        Text(ChappyFX.money(leg.arrivalCost, t.homeCurrency))
                        DealChip(grade: ChappyTravel.grade(leg.arrivalCost, leg.arrivalBand),
                                 band: leg.arrivalBand, currency: t.homeCurrency, compact: true)
                    }
                }
                if leg.nightlyRate > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "bed.double.fill")
                        Text(ChappyFX.pair(leg.nightlyRate, local: legCur, home: t.homeCurrency) + " / night")
                        DealChip(grade: ChappyTravel.grade(leg.nightlyRate, leg.stayBand),
                                 band: leg.stayBand, currency: legCur, compact: true)
                    }
                }
                if let scoot = leg.scooterPerDay, scoot > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "scooter")
                        Text(ChappyFX.pair(scoot, local: legCur, home: t.homeCurrency) + " / day")
                        DealChip(grade: ChappyTravel.grade(scoot, leg.scooterBand),
                                 band: leg.scooterBand, currency: legCur, compact: true)
                    }
                }
            }
            .font(.caption)
            .foregroundColor(theme.textSecondary)
            .padding(.leading, 36)

            // the weather you'll actually get, for the month you're going
            if let n = normals {
                Label("\(Int(n.maxC.rounded()))° / \(Int(n.minC.rounded()))° · \(n.verdict)",
                      systemImage: "cloud.sun.fill")
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
                    .padding(.leading, 36)
            }

            if !leg.shortlist.isEmpty {
                Text(leg.shortlist.prefix(4).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundColor(theme.textSecondary.opacity(0.85))
                    .lineLimit(2)
                    .padding(.leading, 36)
            }

            // the handoff row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    chip("Eat & see", "fork.knife") { placesLeg = leg }
                    // BUILD 179: the map you actually navigate with.
                    if let g = desk.googlePlaceURL(leg) {
                        chip("Google Maps", "map.fill") { desk.open(g) }
                    }
                    if let gd = desk.googleDirectionsURL(to: leg, from: prev) {
                        chip("Directions", "arrow.triangle.turn.up.right.circle.fill") { desk.open(gd) }
                    }
                    if leg.arrival == .flight,
                       let u = desk.flightSearchURL(leg: leg, from: prev, trip: t) {
                        chip("Flights", "airplane") { desk.open(u) }
                    }
                    if let u = desk.groundURL(.rome2rio, leg: leg, from: prev, trip: t) {
                        chip("How to get there", "arrow.triangle.swap") { desk.open(u) }
                    }
                    if let u = desk.groundURL(.twelvego, leg: leg, from: prev, trip: t) {
                        chip("Bus / train / ferry", "tram.fill") { desk.open(u) }
                    }
                    ForEach(ChappyTravel.Booking.allCases) { site in
                        if let u = desk.bookingURL(site, leg: leg, trip: t) {
                            chip(site.label, "bed.double.fill") { desk.open(u) }
                        }
                    }
                    if let u = desk.groundURL(.klook, leg: leg, from: prev, trip: t) {
                        chip("Tours & tickets", "ticket.fill") { desk.open(u) }
                    }
                }
                .padding(.leading, 36)
                .padding(.trailing, 4)
            }
        }
    }

    private func chip(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Label(label, systemImage: icon)
                .font(.caption2).fontWeight(.semibold)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(theme.accent.opacity(0.16)))
                .foregroundColor(theme.accent)
        }
        .buttonStyle(.plain)
    }

    // MARK: extras

    private func extrasCard(_ t: ChappyTravel.Trip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VISAS, INSURANCE, EXTRAS")
                    .font(.caption2).fontWeight(.heavy).tracking(0.6)
                    .foregroundColor(.cyan)
                Spacer()
                Button {
                    extraLabel = ""; extraAmount = ""; addExtraPrompt = true
                } label: {
                    Image(systemName: "plus.circle.fill").font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.accent)
            }
            if t.extras.isEmpty {
                Text("The lines people forget: visa on arrival, travel insurance, a local SIM, vaccinations, airport parking.")
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }
            ForEach(t.extras) { e in
                HStack {
                    Text(e.label)
                        .font(.subheadline)
                        .foregroundColor(theme.textPrimary)
                    if e.perPerson {
                        Text("each").font(.caption2)
                            .foregroundColor(theme.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    Spacer()
                    Text(ChappyFX.money(e.perPerson ? e.amount * Double(t.party) : e.amount,
                                        t.homeCurrency))
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(theme.textSecondary)
                    Button {
                        var c = t; c.extras.removeAll { $0.id == e.id }; desk.update(c)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.footnote).foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .alert("Add an extra", isPresented: $addExtraPrompt) {
            TextField("Travel insurance", text: $extraLabel)
            TextField("Amount", text: $extraAmount).keyboardType(.decimalPad)
            Button("Add") {
                guard var c = trip, let amt = Double(extraAmount), !extraLabel.isEmpty else { return }
                c.extras.append(ChappyTravel.Extra(label: extraLabel, amount: amt, perPerson: true))
                desk.update(c)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Counted per person. Tap it off later if it's a one-off for the whole party.")
        }
    }

    // MARK: actions

    private func actionsCard(_ t: ChappyTravel.Trip) -> some View {
        VStack(spacing: 10) {
            Button {
                ChappyEarcon.shared.tap()
                showPlanner = true
            } label: {
                actionRow("Plan another one with AI", "sparkles")
            }
            if !desk.pendingOptions.isEmpty {
                Button {
                    ChappyEarcon.shared.tap()
                    showOptionsSheet = true
                } label: {
                    actionRow("Compare the three options", "square.stack.3d.up.fill")
                }
            }
            Button {
                ChappyEarcon.shared.tap()
                showIntakeSheet = true
            } label: {
                actionRow(ChappyIntake.shared.isComplete
                          ? "How you travel \u{2014} answered"
                          : "Tell me how you travel (\(ChappyIntake.shared.unanswered.count) questions)",
                          "person.text.rectangle.fill")
            }
            Button {
                ChappyEarcon.shared.tap()
                TTSService.shared.speak(desk.spokenCost(t))
            } label: {
                actionRow("Read me the numbers", "speaker.wave.2.fill")
            }
            Button {
                ChappyEarcon.shared.tap()
                _ = desk.emailReport(t)
            } label: {
                actionRow("Email the plan", "envelope.fill")
            }
            Button {
                ChappyEarcon.shared.tap()
                showVisaDesk = true
            } label: {
                actionRow("Check the visas", "globe.asia.australia.fill")
            }
            Button {
                ChappyEarcon.shared.tap()
                // BUILD 178: the shared report now carries a rendered map.
                Task {
                    if let u = await desk.writeReportWithMap(t) { shareURL = u; showShare = true }
                }
            } label: {
                actionRow("Share the full report", "square.and.arrow.up")
            }
        }
        .padding(14)
        .background(card)
    }

    private func actionRow(_ label: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(theme.accent)
                .frame(width: 22)
            Text(label)
                .font(.subheadline).fontWeight(.medium)
                .foregroundColor(theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundColor(theme.textSecondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// BUILD 181 — ARGUE WITH IT, FROM THE TRIP ITSELF.
    ///
    /// The options screen has the same box, but most push-back happens
    /// later — you look at the plan again three days on and know exactly
    /// what's wrong with it. Making him reopen the options screen to say
    /// so would mean he simply wouldn't.
    private func gripeCard(_ t: ChappyTravel.Trip) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("TELL ME WHAT'S WRONG WITH IT")
                .font(.caption2).fontWeight(.heavy).tracking(0.6)
                .foregroundColor(.cyan)
            HStack(spacing: 8) {
                TextField("Too expensive. Keep it under six grand.", text: $gripeField)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { pushBack(t) }
                Button { pushBack(t) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2).foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(gripeField.trimmingCharacters(in: .whitespaces).isEmpty || desk.planning)
            }
            Text("Or just say it out loud. It keeps everything you didn't complain about, and it remembers what you turned down.")
                .font(.caption2)
                .foregroundColor(theme.textSecondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func pushBack(_ t: ChappyTravel.Trip) {
        let said = gripeField.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty else { return }
        gripeField = ""
        ChappyEarcon.shared.tap()
        Task { await desk.revise(t, saying: said) }
    }

    private var honestyNote: some View {
        Text("Chappy plans and prices — it can't book. Airbnb has had no public API since 2019, and Booking, Agoda, Trip.com, Klook and Traveloka all need an approved commercial agreement. The links above carry your dates and party size through to each site, where the real prices are.")
            .font(.caption2)
            .foregroundColor(theme.textSecondary.opacity(0.8))
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "map.fill")
                .font(.system(size: 52))
                .foregroundColor(theme.textSecondary.opacity(0.6))
            Text("No trips yet")
                .font(.title3).fontWeight(.semibold)
                .foregroundColor(theme.textPrimary)
            Text("Start one here, or just say \u{201C}plan a trip\u{201D} and then \u{201C}add five nights in Ubud\u{201D}.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(theme.textSecondary)
                .padding(.horizontal, 40)
            Button {
                showPlanner = true
            } label: {
                Label("Plan one with AI", systemImage: "sparkles")
                    .font(.subheadline).fontWeight(.semibold)
                    .padding(.horizontal, 20).padding(.vertical, 11)
                    .background(Capsule().fill(theme.accent.opacity(0.28)))
                    .foregroundColor(theme.accent)
            }
            .buttonStyle(.plain)
            Button {
                newName = ""; showNewTrip = true
            } label: {
                Text("Or build one by hand")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundColor(theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.05))
    }

    @State private var showPlanner = false
    @State private var showOptionsSheet = false
    @State private var showIntakeSheet = false
    @State private var gripeField = ""
    @State private var showBigMap = false
    @State private var showVisaDesk = false
    @State private var addLegPrompt = false
    @State private var addExtraPrompt = false
    @State private var extraLabel = ""
    @State private var extraAmount = ""
}

// MARK: - Leg editor

/// Edits by ID rather than by value, because a sheet holding a COPY of a
/// leg is a sheet that silently throws away anything changed underneath
/// it — and dates rechain themselves the moment nights change.
struct LegEditorSheet: View {
    let legID: UUID
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var desk = ChappyTravel.shared

    private var trip: ChappyTravel.Trip? { desk.active }
    private var leg: ChappyTravel.Leg? { trip?.legs.first { $0.id == legID } }

    /// AUDIT: this called rechain() on EVERY edit, and rechain rewrites
    /// each leg's arrival from the one before it. So changing the date on
    /// leg two or later was reverted inside the same setter — the picker
    /// looked broken because it was. Nights still chain (that's the point);
    /// the date itself does not, unless it's the first leg, which is the
    /// only date the chain is actually anchored to.
    private func bind<T>(_ path: WritableKeyPath<ChappyTravel.Leg, T>,
                         _ fallback: T, chain: Bool = true) -> Binding<T> {
        Binding(
            get: { leg?[keyPath: path] ?? fallback },
            set: { v in
                guard var t = trip, let i = t.legs.firstIndex(where: { $0.id == legID }) else { return }
                t.legs[i][keyPath: path] = v
                desk.update(t)
                if chain { desk.rechain(t.id) }
            }
        )
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Where") {
                    TextField("Place", text: bind(\.place, ""))
                    DatePicker("Arrive", selection: bind(\.arrive, Date(), chain: false),
                               displayedComponents: .date)
                    Stepper("Nights: \(leg?.nights ?? 0)", value: bind(\.nights, 1), in: 1...90)
                }

                Section {
                    Picker("How", selection: bind(\.arrival, ChappyTravel.Arrival.flight)) {
                        ForEach(ChappyTravel.Arrival.allCases) { a in
                            Label(a.label, systemImage: a.icon).tag(a)
                        }
                    }
                    HStack {
                        Text("Cost")
                        Spacer()
                        TextField("0", value: bind(\.arrivalCost, 0.0), format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Flight number, bus company…", text: bind(\.arrivalNote, ""))
                } header: {
                    Text("Getting here")
                } footer: {
                    Text("Total for the whole party.")
                }

                Section {
                    TextField("Place name (optional)", text: bind(\.stayName, ""))
                    HStack {
                        Text("Per night")
                        Spacer()
                        TextField("0", value: bind(\.nightlyRate, 0.0), format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Priced in", selection: bind(\.stayCurrency, "")) {
                        Text(trip?.homeCurrency ?? "AUD").tag("")
                        // The blank tag ALREADY means the home currency, so
                        // listing it again gave two identical-looking rows
                        // with different meanings.
                        ForEach(ChappyFX.common.filter { $0 != (trip?.homeCurrency ?? "") },
                                id: \.self) { Text($0).tag($0) }
                    }
                } header: {
                    Text("Where you sleep")
                } footer: {
                    Text("Quote it in whatever the listing says — rupiah, baht, dollars. Chappy converts it into the trip's currency for the total.")
                }

                Section("Day to day") {
                    HStack {
                        Text("Food, per person per day")
                        Spacer()
                        TextField("0", value: bind(\.foodPerDay, 0.0), format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Getting around, per person per day")
                        Spacer()
                        TextField("0", value: bind(\.groundPerDay, 0.0), format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Things to do, whole leg")
                        Spacer()
                        TextField("0", value: bind(\.activitiesTotal, 0.0), format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }

                Section("Notes") {
                    TextField("Anything worth remembering", text: bind(\.notes, ""), axis: .vertical)
                        .lineLimit(2...6)
                }

                if let l = leg, !l.shortlist.isEmpty {
                    Section("Shortlist") {
                        ForEach(l.shortlist, id: \.self) { s in Text(s) }
                            .onDelete { idx in
                                guard var t = trip,
                                      let i = t.legs.firstIndex(where: { $0.id == legID }) else { return }
                                t.legs[i].shortlist.remove(atOffsets: idx)
                                desk.update(t)
                            }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        if let t = trip { desk.removeLeg(legID, from: t.id) }
                        dismiss()
                    } label: { Text("Remove this leg") }
                }
            }
            .navigationTitle(leg?.place ?? "Leg")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Eat & see

struct LegPlacesSheet: View {
    let legID: UUID
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var places = ChappyPlaces.shared
    @ObservedObject private var reviews = ChappyReviews.shared
    @ObservedObject private var desk = ChappyTravel.shared
    @State private var kind: ChappyPlaces.Kind = .restaurants

    private var trip: ChappyTravel.Trip? { desk.active }
    private var leg: ChappyTravel.Leg? { trip?.legs.first { $0.id == legID } }

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                VStack(spacing: 0) {
                    // BUILD 183: nine categories will not fit in a segmented
                    // control, and cramming them in produces nine unreadable
                    // two-letter labels. A scrolling chip row holds as many
                    // as we like and reads at a glance.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ChappyPlaces.Kind.allCases) { k in
                                Button {
                                    guard k != kind else { return }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    kind = k
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: k.icon2).font(.caption2)
                                        Text(k.label).font(.caption).fontWeight(.semibold)
                                    }
                                    .padding(.horizontal, 11).padding(.vertical, 7)
                                    .background(
                                        Capsule().fill(k == kind
                                            ? theme.accent.opacity(0.22)
                                            : Color.white.opacity(0.06)))
                                    .overlay(Capsule().stroke(
                                        k == kind ? theme.accent.opacity(0.55) : .clear, lineWidth: 1))
                                    .foregroundColor(k == kind ? theme.accent : theme.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(.vertical, 12)

                    if places.loading {
                        Spacer()
                        ProgressView().tint(theme.accent)
                        Spacer()
                    } else if places.results.isEmpty {
                        Spacer()
                        Text(places.error ?? "Nothing yet.")
                            .font(.subheadline)
                            .foregroundColor(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Spacer()
                    } else {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(places.results) { spot in
                                    row(spot)
                                }
                            }
                            .padding(12)
                        }
                    }

                    Text(places.sourceNote)
                        .font(.caption2)
                        .foregroundColor(theme.textSecondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20).padding(.bottom, 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle(leg?.place ?? "Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: kind) { await reload() }
        }
    }

    private func reload() async {
        guard let l = leg else { return }
        await places.search(near: l.lat, lon: l.lon, place: l.place, kind: kind)
        // BUILD 186: digest the top few in the background. Only the ones
        // Tripadvisor supplied — Google's licence does not permit us to
        // hold its review text, even in memory for a screen.
        for spot in places.results.prefix(4) where spot.fromTripAdvisor {
            _ = await reviews.digest(for: spot, place: l.place)
        }
    }

    private func row(_ spot: ChappyPlaces.Spot) -> some View {
        let saved = leg?.shortlist.contains(spot.name) ?? false
        return HStack(spacing: 12) {
            Image(systemName: spot.kind.icon)
                .font(.subheadline)
                .foregroundColor(theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(spot.name)
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundColor(theme.textPrimary)

                // BUILD 183: two numbers, labelled, so it is obvious which
                // is which — and an unlabelled 4.6 next to a 4.2 is just
                // confusing.
                if spot.googleRating != nil || spot.rating != nil {
                    HStack(spacing: 8) {
                        if let g = spot.googleRating {
                            ratingChip("G", g, spot.googleCount, .orange)
                        }
                        if let t = spot.rating {
                            ratingChip("TA", t, spot.reviews, Color(red: 0.20, green: 0.68, blue: 0.42))
                        }
                        if !spot.priceLevel.isEmpty {
                            Text(spot.priceLevel).font(.caption2)
                                .foregroundColor(theme.textSecondary)
                        }
                        if spot.openNow == true {
                            Text("Open").font(.caption2).fontWeight(.semibold)
                                .foregroundColor(.green)
                        } else if spot.openNow == false {
                            Text("Closed").font(.caption2)
                                .foregroundColor(theme.textSecondary.opacity(0.8))
                        }
                    }
                }

                // BUILD 186: what the reviews say, under the stars.
                if let d = reviews.cache[spot.id] {
                    Text(d.line)
                        .font(.caption2)
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if !d.complaints.isEmpty || !d.strengths.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(d.strengths.prefix(2)) { f in
                                themeChip(f.theme.label, .green)
                            }
                            ForEach(d.complaints.prefix(2)) { f in
                                themeChip(f.theme.label, .orange)
                            }
                        }
                    }
                } else if spot.fromTripAdvisor, reviews.loading.contains(spot.id) {
                    Text("Reading the reviews…")
                        .font(.caption2).foregroundColor(theme.textSecondary.opacity(0.7))
                }

                // The whole reason for having two sources.
                if let note = spot.divergenceNote {
                    Text(note).font(.caption2)
                        .foregroundColor(.orange.opacity(0.9))
                        .lineLimit(2)
                } else if !spot.address.isEmpty {
                    Text(spot.address).font(.caption)
                        .foregroundColor(theme.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            // BUILD 179: a name in a list is not much use. This opens the
            // actual place on Google — hours, photos, whether it's still
            // there — searched near this leg so it finds the right one.
            Button {
                guard let l = leg,
                      let u = ChappyTravel.shared.googleSearchURL(spot.name, near: l) else { return }
                UIApplication.shared.open(u, options: [:], completionHandler: nil)
            } label: {
                Image(systemName: "map")
                    .font(.footnote)
                    .foregroundColor(theme.textSecondary)
                    .padding(7)
            }
            .buttonStyle(.plain)
            Button {
                toggle(spot)
            } label: {
                Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundColor(saved ? .green : theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    private func themeChip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
            .foregroundColor(tint)
    }

    /// One source's verdict, with its review count, because a 5.0 from
    /// eleven people and a 4.6 from six thousand are not the same claim.
    private func ratingChip(_ tag: String, _ value: Double, _ count: Int?, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(tag).font(.system(size: 9, weight: .heavy))
                .foregroundColor(tint.opacity(0.9))
            Text(String(format: "%.1f", value))
                .font(.caption).fontWeight(.semibold)
                .foregroundColor(tint)
            if let n = count, n > 0 {
                Text("(\(n.formatted()))").font(.system(size: 10))
                    .foregroundColor(theme.textSecondary.opacity(0.85))
            }
        }
    }

    private func toggle(_ spot: ChappyPlaces.Spot) {
        guard var t = trip, let i = t.legs.firstIndex(where: { $0.id == legID }) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let at = t.legs[i].shortlist.firstIndex(of: spot.name) {
            t.legs[i].shortlist.remove(at: at)
        } else {
            t.legs[i].shortlist.append(spot.name)
        }
        desk.update(t)
    }
}

// =====================================================================
// BUILD 177 — THE CONVERTER.
//
// "How much is that in real money" is the most asked question of any
// trip and Chappy had no answer to it anywhere. Rates come from a free
// keyless service, cached to disk, so this works on a plane and in a
// market with one bar — which is precisely where you need it.
// =====================================================================

struct CurrencyView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }
    @ObservedObject private var fx = ChappyFX.shared

    @State private var amount = "100"
    @State private var from = "IDR"
    @State private var to = "AUD"

    private var value: Double { Double(amount.replacingOccurrences(of: ",", with: "")) ?? 0 }
    private var converted: Double? { fx.convert(value, from: from, to: to) }

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                ScrollView {
                    VStack(spacing: 14) {
                        VStack(spacing: 12) {
                            TextField("0", text: $amount)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .multilineTextAlignment(.center)
                                .foregroundColor(theme.textPrimary)

                            HStack(spacing: 10) {
                                picker($from)
                                Button {
                                    let t = from; from = to; to = t
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    Image(systemName: "arrow.left.arrow.right")
                                        .font(.subheadline)
                                        .foregroundColor(theme.accent)
                                        .padding(9)
                                        .background(Circle().fill(Color.white.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                                picker($to)
                            }

                            Text(converted.map { ChappyFX.money($0, to) } ?? "No rate for that pair yet")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundColor(converted == nil ? theme.textSecondary : theme.accent)
                                .padding(.top, 4)

                            if let c = converted, value > 0 {
                                Text("1 \(from) = \(String(format: "%.4f", c / value)) \(to)")
                                    .font(.caption)
                                    .foregroundColor(theme.textSecondary)
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.05)))

                        // the quick answers — round numbers you actually meet
                        VStack(alignment: .leading, spacing: 8) {
                            Text("AT A GLANCE")
                                .font(.caption2).fontWeight(.heavy).tracking(0.6)
                                .foregroundColor(.cyan)
                            ForEach(glanceRows) { row in
                                HStack {
                                    Text(row.from).font(.subheadline)
                                        .foregroundColor(theme.textPrimary)
                                    Spacer()
                                    Text(row.to).font(.subheadline).fontWeight(.semibold)
                                        .foregroundColor(theme.textSecondary)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.05)))

                        HStack {
                            Text(fx.fetchedAt.map { d -> String in
                                let f = DateFormatter(); f.dateStyle = .medium
                                return "Rates from \(f.string(from: d))"
                            } ?? "No rates yet")
                                .font(.caption2)
                                .foregroundColor(fx.isStale ? .orange : theme.textSecondary)
                            Spacer()
                            Button {
                                Task { await fx.refresh(force: true) }
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                                    .font(.caption2).fontWeight(.semibold)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(theme.accent)
                        }
                        .padding(.horizontal, 4)

                        Text("Rates are daily mid-market — a bank or a money changer will be a little worse. Cached on the phone, so this keeps working with no signal.")
                            .font(.caption2)
                            .foregroundColor(theme.textSecondary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                    .padding(14)
                }
            }
            .navigationTitle("Currency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
            .task {
                to = fx.home
                await fx.refresh()
            }
        }
    }

    private func picker(_ sel: Binding<String>) -> some View {
        Picker("", selection: sel) {
            ForEach(ChappyFX.common, id: \.self) { c in Text(c).tag(c) }
        }
        .pickerStyle(.menu)
        .tint(theme.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    /// The amounts you actually hand over: a coffee, a meal, a night,
    /// a taxi. Far more useful than a rate to four decimal places.
    struct Glance: Identifiable {
        var id: String { from }
        var from: String
        var to: String
    }

    private var glanceRows: [Glance] {
        [10.0, 50, 100, 500, 1000, 10000, 100_000, 1_000_000]
            .filter { amt in
                // Only show magnitudes that make sense for the currency —
                // nobody needs "1,000,000 AUD" or "10 IDR".
                ChappyFX.zeroDecimal.contains(from) ? amt >= 1000 : amt <= 1000
            }
            .prefix(5)
            .compactMap { amt in
                guard let out = fx.convert(amt, from: from, to: to) else { return nil }
                return Glance(from: ChappyFX.money(amt, from), to: ChappyFX.money(out, to))
            }
    }
}

// =====================================================================
// BUILD 177 — THE WEB LOOK-UP.
//
// Chappy could already search three separate ways — Google grounding in
// Live AI, Anthropic search in Quick Vision, deep_research from the live
// model — and not one was reachable from standby with the phone in a
// pocket. The answer is spoken; the SOURCES land here, because a travel
// answer you can't check is one you shouldn't act on.
// =====================================================================

struct WebSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }
    @ObservedObject private var search = ChappySearch.shared
    @State private var field = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        TextField("Does the Gilimanuk ferry run at night?", text: $field)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .submitLabel(.search)
                            .onSubmit { go() }
                        Button {
                            go()
                        } label: {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .font(.title2).foregroundColor(theme.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(search.busy || field.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(12)

                    if search.busy {
                        HStack(spacing: 8) {
                            ProgressView().tint(theme.accent)
                            Text("Looking it up…")
                                .font(.caption).foregroundColor(theme.textSecondary)
                        }
                        .padding(.bottom, 8)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(search.history) { a in
                                answerCard(a)
                            }
                            if search.history.isEmpty && !search.busy {
                                Text("Ask anything current — opening hours, ferry times, visa rules, whether a place is still open. Works by voice too: \u{201C}Chappy, look up whether the Ubud market opens on Sundays\u{201D}.")
                                    .font(.subheadline)
                                    .foregroundColor(theme.textSecondary)
                                    .padding(.top, 30)
                                    .padding(.horizontal, 20)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(12)
                    }

                    Text("\(search.remainingToday) look-ups left today")
                        .font(.caption2)
                        .foregroundColor(search.remainingToday <= 2 ? .orange : theme.textSecondary)
                        .padding(.bottom, 10)
                }
            }
            .navigationTitle("Look it up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear { focused = search.history.isEmpty }
        }
    }

    private func go() {
        let q = field.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        focused = false
        Task { await search.ask(q) }
        field = ""
    }

    private func answerCard(_ a: ChappySearch.Answer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(a.question)
                .font(.caption).fontWeight(.semibold)
                .foregroundColor(theme.accent)
            Text(a.text)
                .font(.subheadline)
                .foregroundColor(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !a.sources.isEmpty {
                Divider().background(Color.white.opacity(0.1))
                ForEach(a.sources.prefix(6)) { s in
                    Button {
                        if let u = URL(string: s.url) {
                            UIApplication.shared.open(u, options: [:], completionHandler: nil)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link").font(.caption2)
                            Text(s.host).font(.caption2).lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption2)
                        }
                        .foregroundColor(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button {
                    TTSService.shared.speakLong(a.text)
                } label: {
                    Label("Read it", systemImage: "speaker.wave.2.fill")
                        .font(.caption2).fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }
}

// =====================================================================
// BUILD 177 — THE PLANNER SHEET.
//
// Everything else in the Travel Desk is a form. This is the agent: say
// where and how long, and a whole costed itinerary comes back with the
// legs, the nightly rates, the food, the transport between them and the
// extras people forget. Then you edit it — because a plan you can't
// argue with is a plan you don't trust.
//
// Every field except the destination has a default, so the fastest path
// through this screen is: type "Vietnam", tap Plan.
// =====================================================================

struct TripPlannerSheet: View {
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var desk = ChappyTravel.shared

    @State private var destination = ""
    @State private var nights = 10
    @State private var party = 2
    @State private var useBudget = false
    @State private var budget = "4000"
    @State private var month = 0          // 0 = whenever
    @State private var style = ""

    private let styles = ["relaxed", "food", "beaches", "diving", "surfing", "hiking",
                          "temples", "nightlife", "photography", "island hopping",
                          "budget", "luxury", "family", "motorbike"]

    var body: some View {
        NavigationView {
            Form {
                Section("Where and how long") {
                    TextField("Vietnam, Bali, northern Thailand…", text: $destination)
                        .autocorrectionDisabled()
                    Stepper("\(nights) nights", value: $nights, in: 2...60)
                    Stepper("\(party) \(party == 1 ? "traveller" : "travelling")", value: $party, in: 1...12)
                    Picker("When", selection: $month) {
                        Text("Whenever").tag(0)
                        ForEach(1...12, id: \.self) { m in
                            Text(DateFormatter().monthSymbols[m - 1]).tag(m)
                        }
                    }
                }

                Section {
                    Toggle("Work to a ceiling", isOn: $useBudget)
                    if useBudget {
                        HStack {
                            Text(ChappyFX.shared.home)
                            Spacer()
                            TextField("4000", text: $budget)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Budget")
                } footer: {
                    Text(useBudget
                         ? "The whole trip for everyone, not each. It builds the plan to fit, and tells you if it can't."
                         : "Without a ceiling it aims at good value rather than cheapest.")
                }

                Section("What kind of trip") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(styles, id: \.self) { s in
                                let on = style.contains(s)
                                Button {
                                    // Rebuild the list rather than patching the
                                    // string — string surgery left ", ," in the
                                    // middle when a chip was deselected, and
                                    // that went straight into the AI prompt.
                                    var parts = style.split(separator: ",")
                                        .map { $0.trimmingCharacters(in: .whitespaces) }
                                        .filter { !$0.isEmpty }
                                    if on { parts.removeAll { $0 == s } }
                                    else if !parts.contains(s) { parts.append(s) }
                                    style = parts.joined(separator: ", ")
                                } label: {
                                    Text(s)
                                        .font(.caption).fontWeight(.semibold)
                                        .padding(.horizontal, 11).padding(.vertical, 6)
                                        .background(Capsule().fill(on ? theme.accent.opacity(0.25)
                                                                      : Color.gray.opacity(0.16)))
                                        .foregroundColor(on ? theme.accent : .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let e = desk.planError {
                    Section { Text(e).font(.caption).foregroundColor(.red) }
                }

                Section {
                    Button {
                        go()
                    } label: {
                        HStack {
                            Spacer()
                            Label(desk.planning ? "Working…" : "Plan it", systemImage: "sparkles")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(desk.planning || destination.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("Chappy checks current prices and how people actually travel between these places, then builds it into legs you can edit. It plans and prices — booking still happens on the sites, through the links on each leg.")
                }
            }
            .navigationTitle("Plan a trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func go() {
        let d = destination.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty else { return }
        let req = ChappyTravel.PlanRequest(
            destination: d,
            nights: nights,
            party: party,
            budget: useBudget ? Double(budget) : nil,
            month: month == 0 ? nil : month,
            style: style.trimmingCharacters(in: CharacterSet(charactersIn: " ,")))
        dismiss()
        Task { await desk.aiPlan(req) }
    }
}

// =====================================================================
// BUILD 178 — THE TRIP ATLAS.
//
// 177 had a two-hundred-point strip with numbered pins on it. That is a
// locator, not an atlas, and it was the weakest thing in the module.
//
// This is the real one, and it is built on iOS 17's MapKit rather than a
// Google Maps package, deliberately: no new dependency, no second API
// key to enable, nothing that can break the build — and it does
// everything the job actually needs.
//
//   * A HUE RAMP along the journey. Leg one is cool, the last leg is
//     warm, and you can read the DIRECTION of a trip at a glance without
//     reading a single number. That is the thing a row of identical red
//     pins can never tell you.
//   * THE ROUTE DRAWN, styled by how you travel it — dashed for flights,
//     solid for road and rail, dotted for ferries. The shape of the trip
//     becomes obvious: three short hops and one long haul looks different
//     from four even legs, and it should.
//   * TAP A PIN and you get that leg — nights, cost, the weather you'll
//     actually get, the visa position, and every booking link.
//   * LAYERS. Standard, hybrid or satellite, and your shortlisted
//     restaurants and attractions as a second set of pins you can switch
//     on when you want them and off when they're clutter.
// =====================================================================

struct TripAtlasView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @ObservedObject private var desk = ChappyTravel.shared
    @ObservedObject private var season = ChappySeason.shared
    @ObservedObject private var visa = ChappyVisa.shared

    @State private var camera: MapCameraPosition = .automatic
    @State private var style: Style = .standard
    @State private var showShortlist = false
    @State private var selected: ChappyTravel.Leg?
    @State private var placePins: [PlacePin] = []

    enum Style: String, CaseIterable, Identifiable {
        case standard = "Map", hybrid = "Hybrid", imagery = "Satellite"
        var id: String { rawValue }
        var mapStyle: MapStyle {
            switch self {
            case .standard: return .standard(elevation: .realistic)
            case .hybrid:   return .hybrid(elevation: .realistic)
            case .imagery:  return .imagery(elevation: .realistic)
            }
        }
    }

    struct PlacePin: Identifiable {
        let id = UUID()
        let name: String
        let coord: CLLocationCoordinate2D
        let legIndex: Int
    }

    private var trip: ChappyTravel.Trip? { desk.active }
    private var legs: [ChappyTravel.Leg] { (trip?.legs ?? []).filter(\.hasCoord) }

    /// THE HUE RAMP. Cool to warm along the journey — 200° through to
    /// about 20°, which reads as blue → teal → gold → orange. Chosen
    /// because it stays legible on satellite imagery AND on the standard
    /// map, which a red-to-green ramp does not.
    private func hue(_ i: Int) -> Color {
        let n = max(1, legs.count - 1)
        let t = Double(min(i, n)) / Double(n)
        return Color(hue: (200.0 - 180.0 * t) / 360.0, saturation: 0.85, brightness: 0.95)
    }

    private func coord(_ leg: ChappyTravel.Leg) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: leg.lat, longitude: leg.lon)
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                map
                controls
            }
            .navigationTitle(trip?.name ?? "Atlas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 14) {
                        // BUILD 179: hand the entire route to Google in one
                        // tap — every stop, in order, in the right mode.
                        if let t = trip, let g = desk.googleTripURL(t) {
                            Button { desk.open(g) } label: { Image(systemName: "map.fill") }
                        }
                        Button { frameTrip() } label: { Image(systemName: "scope") }
                    }
                }
            }
            .sheet(item: $selected) { leg in
                AtlasLegCard(legID: leg.id, theme: theme)
                    .presentationDetents([.medium, .large])
            }
            .task {
                frameTrip()
                await loadSeasons()
                buildPlacePins()
            }
            .onChange(of: showShortlist) { _, on in if on { buildPlacePins() } }
        }
    }

    // MARK: the map itself

    private var map: some View {
        Map(position: $camera) {
            // THE ROUTE. Drawn per hop so each one can carry the style of
            // the way you actually travel it.
            ForEach(Array(legs.enumerated()), id: \.element.id) { i, leg in
                if i > 0 {
                    let from = coord(legs[i - 1])
                    let to = coord(leg)
                    MapPolyline(coordinates: [from, to])
                        .stroke(hue(i).opacity(0.9),
                                style: strokeStyle(for: leg.arrival))
                }
            }

            // The shortlist, underneath the legs so it never covers one.
            if showShortlist {
                ForEach(placePins) { pin in
                    Annotation(pin.name, coordinate: pin.coord) {
                        Image(systemName: "star.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white, hue(pin.legIndex))
                            .shadow(radius: 2)
                    }
                    .annotationTitles(.hidden)
                }
            }

            ForEach(Array(legs.enumerated()), id: \.element.id) { i, leg in
                Annotation(leg.place, coordinate: coord(leg)) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selected = leg
                    } label: {
                        legPin(leg, index: i)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(style.mapStyle)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func strokeStyle(for a: ChappyTravel.Arrival) -> StrokeStyle {
        switch a {
        case .flight:
            return StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [11, 7])
        case .ferry:
            return StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [2, 7])
        case .walk:
            return StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 5])
        default:
            return StrokeStyle(lineWidth: 4, lineCap: .round)
        }
    }

    private func legPin(_ leg: ChappyTravel.Leg, index i: Int) -> some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(hue(i)).frame(width: 34, height: 34)
                Circle().stroke(.white, lineWidth: 2.5).frame(width: 34, height: 34)
                VStack(spacing: -1) {
                    Text("\(i + 1)")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.8))
                    Text("\(leg.nights)n")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black.opacity(0.55))
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            Text(leg.place)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.55)))
        }
    }

    // MARK: controls

    private var controls: some View {
        VStack(spacing: 10) {
            if let t = trip {
                let c = desk.cost(t)
                HStack(spacing: 12) {
                    Label("\(t.nights) nights", systemImage: "moon.stars.fill")
                    Label("\(legs.count) stops", systemImage: "mappin.and.ellipse")
                    if c.total > 0 {
                        Label(ChappyFX.money(c.total, t.homeCurrency), systemImage: "creditcard.fill")
                    }
                }
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(.black.opacity(0.55)))
            }

            HStack(spacing: 8) {
                Picker("", selection: $style) {
                    ForEach(Style.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 230)

                Button {
                    showShortlist.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: showShortlist ? "star.circle.fill" : "star.circle")
                        .font(.title3)
                        .foregroundStyle(showShortlist ? theme.accent : .white)
                        .padding(8)
                        .background(Circle().fill(.black.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)
        }
        .padding(.bottom, 14)
    }

    // MARK: framing and data

    /// Fit the WHOLE trip. A map showing one pin when the trip has six has
    /// quietly lied about the shape of it.
    /// AUDIT: named frame(), which collides with SwiftUI's deprecated
    /// zero-argument View.frame() modifier. If overload resolution ever
    /// picked the modifier, this would silently become a no-op and the
    /// "fit the whole trip" button would do nothing, with no error.
    private func frameTrip() {
        guard !legs.isEmpty else { return }
        let lats = legs.map(\.lat), lons = legs.map(\.lon)
        guard let minLa = lats.min(), let maxLa = lats.max(),
              let minLo = lons.min(), let maxLo = lons.max() else { return }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLa + maxLa) / 2,
                                           longitude: (minLo + maxLo) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.5, (maxLa - minLa) * 1.7),
                                   longitudeDelta: max(0.5, (maxLo - minLo) * 1.7)))
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(region)
        }
    }

    private func loadSeasons() async {
        for leg in legs {
            let m = Calendar.current.component(.month, from: leg.arrive)
            await ChappySeason.shared.load(lat: leg.lat, lon: leg.lon, month: m)
        }
    }

    /// Shortlisted places have names but no coordinates — they were saved
    /// from a list, not a map. Geocode them once, near their own leg, so
    /// the pin lands in the right town rather than on a same-named street
    /// on the other side of the world.
    private func buildPlacePins() {
        guard showShortlist else { placePins = []; return }
        Task { @MainActor in
            var out: [PlacePin] = []
            for (i, leg) in legs.enumerated() {
                for name in leg.shortlist.prefix(8) {
                    let req = MKLocalSearch.Request()
                    req.naturalLanguageQuery = "\(name) \(leg.place)"
                    req.region = MKCoordinateRegion(center: coord(leg),
                                                    latitudinalMeters: 30000,
                                                    longitudinalMeters: 30000)
                    guard let resp = try? await MKLocalSearch(request: req).start(),
                          let item = resp.mapItems.first else { continue }
                    out.append(PlacePin(name: name,
                                        coord: item.placemark.coordinate,
                                        legIndex: i))
                }
            }
            placePins = out
        }
    }
}

// MARK: - The card behind a pin

struct AtlasLegCard: View {
    let legID: UUID
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var desk = ChappyTravel.shared
    @ObservedObject private var visa = ChappyVisa.shared

    private var trip: ChappyTravel.Trip? { desk.active }
    private var leg: ChappyTravel.Leg? { trip?.legs.first { $0.id == legID } }
    private var index: Int? { trip?.legs.firstIndex { $0.id == legID } }

    var body: some View {
        ZStack {
            AuroraBackdrop(theme: theme)
            ScrollView {
                if let l = leg, let t = trip {
                    VStack(alignment: .leading, spacing: 14) {
                        header(l, t)
                        facts(l, t)
                        links(l, t)
                    }
                    .padding(16)
                } else {
                    Text("That leg is gone.")
                        .foregroundColor(theme.textSecondary)
                        .padding(40)
                }
            }
        }
    }

    private func header(_ l: ChappyTravel.Leg, _ t: ChappyTravel.Trip) -> some View {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"
        return VStack(alignment: .leading, spacing: 4) {
            Text(l.place)
                .font(.title2).fontWeight(.bold)
                .foregroundColor(theme.textPrimary)
            Text("\(f.string(from: l.arrive)) – \(f.string(from: l.depart)) · \(l.nights) \(l.nights == 1 ? "night" : "nights")")
                .font(.subheadline)
                .foregroundColor(theme.textSecondary)
        }
    }

    private func facts(_ l: ChappyTravel.Leg, _ t: ChappyTravel.Trip) -> some View {
        let month = Calendar.current.component(.month, from: l.arrive)
        let normals = ChappySeason.shared.normals(lat: l.lat, lon: l.lon, month: month)
        let legCur = l.stayCurrency.isEmpty ? t.homeCurrency : l.stayCurrency
        let country = ChappyVisa.country(from: l.country.isEmpty ? l.place : l.country)
        let rule = country.flatMap { ChappyVisa.auPassport[$0] }

        return VStack(alignment: .leading, spacing: 9) {
            if let n = normals {
                fact("cloud.sun.fill",
                     "\(Int(n.maxC.rounded()))° / \(Int(n.minC.rounded()))° · \(n.verdict)",
                     "Average of the last three \(DateFormatter().monthSymbols[month - 1])s, not a forecast")
            }
            if let r = rule, let c = country {
                fact(r.shape.icon,
                     "\(c): \(r.shape.label)\(r.days > 0 ? " · \(r.days) days" : "")",
                     ChappyVisa.shared.live[c]?.ageLine ?? "Indicative — tap Visas for the live rules")
            }
            if l.arrival != .none {
                fact(l.arrival.icon,
                     l.arrivalNote.isEmpty ? l.arrival.label : "\(l.arrival.label) — \(l.arrivalNote)",
                     l.arrivalCost > 0 ? ChappyFX.money(l.arrivalCost, t.homeCurrency) : "")
            }
            if l.nightlyRate > 0 {
                fact("bed.double.fill",
                     "\(ChappyFX.money(l.nightlyRate, legCur)) a night",
                     l.stayName.isEmpty ? "" : l.stayName)
            }
            if !l.shortlist.isEmpty {
                fact("star.fill", l.shortlist.prefix(4).joined(separator: " · "),
                     l.shortlist.count > 4 ? "and \(l.shortlist.count - 4) more" : "")
            }
            if !l.notes.isEmpty { fact("note.text", l.notes, "") }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    private func fact(_ icon: String, _ line: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundColor(theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(line)
                    .font(.subheadline)
                    .foregroundColor(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !sub.isEmpty {
                    Text(sub).font(.caption2).foregroundColor(theme.textSecondary)
                }
            }
            Spacer()
        }
    }

    private func links(_ l: ChappyTravel.Leg, _ t: ChappyTravel.Trip) -> some View {
        let prev = (index ?? 0) > 0 ? t.legs[(index ?? 1) - 1] : nil
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                // BUILD 179 — GOOGLE FIRST.
                //
                // MapKit draws the atlas because that was the right call for
                // the build: no package, no second key, nothing that can
                // break an archive. But where you LAND when you tap a place
                // is a different question, and in Asia the businesses, the
                // opening hours and the transit legs are all on Google.
                // Universal links, so the app opens if it's installed.
                if let g = desk.googlePlaceURL(l) {
                    linkChip("Google Maps", "map.fill") { desk.open(g) }
                }
                if let gd = desk.googleDirectionsURL(to: l, from: prev) {
                    linkChip("Directions", "arrow.triangle.turn.up.right.circle.fill") { desk.open(gd) }
                }
                if let u = desk.groundURL(.rome2rio, leg: l, from: prev, trip: t) {
                    linkChip("How to get there", "arrow.triangle.swap") { desk.open(u) }
                }
                if let u = desk.groundURL(.twelvego, leg: l, from: prev, trip: t) {
                    linkChip("Bus / train / ferry", "tram.fill") { desk.open(u) }
                }
                ForEach(ChappyTravel.Booking.allCases) { site in
                    if let u = desk.bookingURL(site, leg: l, trip: t) {
                        linkChip(site.label, "bed.double.fill") { desk.open(u) }
                    }
                }
                if let u = desk.groundURL(.klook, leg: l, from: prev, trip: t) {
                    linkChip("Tours & tickets", "ticket.fill") { desk.open(u) }
                }
            }
        }
    }

    private func linkChip(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Label(label, systemImage: icon)
                .font(.caption2).fontWeight(.semibold)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(theme.accent.opacity(0.16)))
                .foregroundColor(theme.accent)
        }
        .buttonStyle(.plain)
    }
}

// =====================================================================
// BUILD 178 — THE VISA DESK, ON SCREEN.
//
// The screen's whole job is to keep the three layers visibly apart:
// what the baked table says (instant, indicative), what the live check
// found (dated, sourced), and where the official word is (always one
// tap away). A screen that blurred those would be worse than no screen.
// =====================================================================

struct VisaDeskView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @ObservedObject private var visa = ChappyVisa.shared
    @ObservedObject private var desk = ChappyTravel.shared
    @State private var lookup = ""
    @State private var manual: String?

    private var trip: ChappyTravel.Trip? { desk.active }
    private var positions: [ChappyVisa.Position] { trip.map { visa.positions(for: $0) } ?? [] }

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let t = trip, !positions.isEmpty {
                            verdictCard(t)
                            ForEach(positions) { p in countryCard(p) }
                        } else {
                            Text("No trip planned, so there's nothing to check against. Look a country up below, or plan a trip first.")
                                .font(.subheadline)
                                .foregroundColor(theme.textSecondary)
                                .padding(.top, 8)
                        }
                        lookupCard
                        if let m = manual, let r = ChappyVisa.auPassport[m] {
                            manualCard(m, r)
                        }
                        disclaimer
                    }
                    .padding(14)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Visas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        guard let t = trip else { return }
                        Task { await visa.checkWholeTrip(t) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(trip == nil || !visa.checking.isEmpty)
                }
            }
            .onAppear { visa.pruneStale() }
        }
    }

    // MARK: the verdict

    private func verdictCard(_ t: ChappyTravel.Trip) -> some View {
        let over = positions.filter(\.over)
        let action = positions.filter { $0.shape.needsActionBeforeFlying }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: over.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(over.isEmpty ? .green : .orange)
                Text(over.isEmpty ? "Nothing over the limit" : "\(over.count) problem\(over.count == 1 ? "" : "s")")
                    .font(.headline)
                    .foregroundColor(theme.textPrimary)
                Spacer()
            }
            if !over.isEmpty {
                ForEach(over) { p in
                    Text("\(p.days) days in \(p.country) — counting arrival days — and an Australian passport gets \(p.allowance). Extend in country, do a border run, or apply for a longer visa before you fly.")
                        .font(.subheadline)
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !action.isEmpty {
                Text("Sort before you board: " + action.map { "\($0.country) (\($0.shape.label.lowercased()))" }
                    .joined(separator: ", ") + ".")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                ChappyEarcon.shared.tap()
                TTSService.shared.speakLong(visa.spokenTripCheck(t))
            } label: {
                Label("Read it to me", systemImage: "speaker.wave.2.fill")
                    .font(.caption).fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accent)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    // MARK: one country

    private func countryCard(_ p: ChappyVisa.Position) -> some View {
        let l = visa.live[p.country]
        let busy = visa.checking.contains(p.country)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: p.shape.icon)
                    .font(.title3)
                    .foregroundColor(p.over ? .orange : theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.country)
                        .font(.headline).foregroundColor(theme.textPrimary)
                    Text("\(p.shape.label)\(p.allowance > 0 ? " · \(p.allowance) days" : "")")
                        .font(.caption).foregroundColor(theme.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    // Days of presence, not nights — that is what a visa
                    // allowance counts, and the difference is an overstay.
                    Text("\(p.days) days")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(theme.textPrimary)
                    Text(p.verdict)
                        .font(.caption2)
                        .foregroundColor(p.over ? .orange : (p.tight ? .yellow : .green))
                }
            }

            if !p.legs.isEmpty {
                Text(p.legs.joined(separator: " · "))
                    .font(.caption2).foregroundColor(theme.textSecondary.opacity(0.8))
            }

            // THE LIVE LAYER, clearly separated from the table above it.
            if busy {
                HStack(spacing: 7) {
                    ProgressView().tint(theme.accent).scaleEffect(0.7)
                    Text("Checking the current rules…")
                        .font(.caption).foregroundColor(theme.textSecondary)
                }
            } else if let l {
                Divider().background(Color.white.opacity(0.1))
                Text(l.summary)
                    .font(.subheadline)
                    .foregroundColor(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                detail("Costs", l.cost)
                detail("How", l.howTo)
                detail("Extending", l.extendable)
                detail("Onward ticket", l.onwardTicket)
                detail("Passport", l.passportValidity)
                detail("Working remotely", l.remoteWork)
                HStack {
                    Text(l.ageLine)
                        .font(.caption2)
                        .foregroundColor(l.isStale ? .orange : theme.textSecondary)
                    Spacer()
                    if !p.schengenGroup {
                        Button {
                            Task { await visa.deepCheck(country: p.country, nights: p.nights, force: true) }
                        } label: {
                            Text("Re-check").font(.caption2).fontWeight(.semibold)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(theme.accent)
                    }
                }
                if !l.sources.isEmpty {
                    ForEach(l.sources.prefix(4), id: \.self) { u in
                        Button {
                            if let url = URL(string: u) {
                                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "link").font(.caption2)
                                Text(URL(string: u)?.host?.replacingOccurrences(of: "www.", with: "") ?? u)
                                    .font(.caption2).lineLimit(1)
                                Spacer()
                            }
                            .foregroundColor(theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if !p.schengenGroup {
                Button {
                    Task { await visa.deepCheck(country: p.country, nights: p.nights) }
                } label: {
                    Label("Check the current rules", systemImage: "magnifyingglass")
                        .font(.caption).fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.accent)
            }

            // "Schengen area" is a bucket, not a country. Asking the visa
            // desk about it produces nonsense, and building a Smartraveller
            // URL from it produces a 404. Show the countries instead.
            if p.schengenGroup {
                Text("Schengen counts as ONE allowance: 90 days in any rolling 180 across the whole zone, not per country. Check each country you're entering below.")
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(p.legs.prefix(6), id: \.self) { place in
                    if let c = ChappyVisa.country(from: place) {
                        official(c)
                    }
                }
            } else {
                official(p.country)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        Group {
            if !value.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text(label + ":")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(theme.accent)
                    Text(value)
                        .font(.caption)
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
    }

    /// The official word is one tap away on EVERY card. Chappy is a
    /// briefing, not an authority, and the design has to keep saying so.
    private func official(_ country: String) -> some View {
        HStack(spacing: 8) {
            if let u = ChappyVisa.smartravellerURL(country) {
                Button {
                    UIApplication.shared.open(u, options: [:], completionHandler: nil)
                } label: {
                    Label("Smartraveller", systemImage: "shield.lefthalf.filled")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.textSecondary)
            }
            if let u = ChappyVisa.officialSearchURL(country) {
                Button {
                    UIApplication.shared.open(u, options: [:], completionHandler: nil)
                } label: {
                    Label("Official source", systemImage: "building.columns")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: look one up

    private var lookupCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("LOOK A COUNTRY UP")
                .font(.caption2).fontWeight(.heavy).tracking(0.6)
                .foregroundColor(.cyan)
            HStack(spacing: 8) {
                TextField("Philippines, Japan, Vietnam…", text: $lookup)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { look() }
                Button { look() } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.title2).foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
            }
            Text("Thinking about somewhere after this trip? Check it here before you build a plan around it.")
                .font(.caption2)
                .foregroundColor(theme.textSecondary.opacity(0.85))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func look() {
        let q = lookup.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        guard let c = ChappyVisa.country(from: q) else {
            manual = nil
            Task { await visa.deepCheck(country: q, force: true) }
            return
        }
        manual = c
        Task { await visa.deepCheck(country: c) }
    }

    private func manualCard(_ country: String, _ r: ChappyVisa.Rule) -> some View {
        let l = visa.live[country]
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: r.shape.icon).font(.title3).foregroundColor(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(country).font(.headline).foregroundColor(theme.textPrimary)
                    Text("\(r.shape.label)\(r.days > 0 ? " · \(r.days) days" : "")")
                        .font(.caption).foregroundColor(theme.textSecondary)
                }
                Spacer()
            }
            if !r.note.isEmpty {
                Text(r.note).font(.caption).foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if visa.checking.contains(country) {
                HStack(spacing: 7) {
                    ProgressView().tint(theme.accent).scaleEffect(0.7)
                    Text("Checking the current rules…").font(.caption)
                        .foregroundColor(theme.textSecondary)
                }
            } else if let l {
                Divider().background(Color.white.opacity(0.1))
                Text(l.summary).font(.subheadline).foregroundColor(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                detail("Costs", l.cost)
                detail("How", l.howTo)
                detail("Working remotely", l.remoteWork)
                Text(l.ageLine).font(.caption2).foregroundColor(theme.textSecondary)
            }
            official(country)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private var disclaimer: some View {
        Text("The shapes above are an indicative table for an AUSTRALIAN passport, reviewed August 2026. The checked answers come from a live search and carry their sources and a date. Neither is an authority — visa rules change without notice and only the country's own immigration service and Smartraveller can tell you what is true at the border today. Check both before you fly.")
            .font(.caption2)
            .foregroundColor(theme.textSecondary.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.05))
    }
}

// =====================================================================
// BUILD 181 — THE DEAL CHIP.
//
// A price on its own is not information. "Rp 1,450,000 a night" tells
// you nothing unless you already know what villas in Canggu go for in
// September — and if you knew that, you wouldn't need the app.
//
// So every price that has a searched band behind it carries a grade:
// green at or under the low end, amber around what everyone pays, red
// above the tourist line, with the range spelled out so it can be
// argued with. The colours are chosen to survive both themes and to
// still read on a printed page, because this goes in the report too.
// =====================================================================

struct DealChip: View {
    let grade: ChappyTravel.Grade
    let band: ChappyTravel.Band?
    let currency: String
    var compact = false

    private var colour: Color {
        switch grade {
        case .great:   return Color(red: 0.11, green: 0.61, blue: 0.35)
        case .good:    return Color(red: 0.29, green: 0.63, blue: 0.24)
        case .fair:    return Color(red: 0.79, green: 0.54, blue: 0.07)
        case .high:    return Color(red: 0.75, green: 0.23, blue: 0.17)
        case .unknown: return .gray
        }
    }

    var body: some View {
        if grade == .unknown {
            EmptyView()
        } else {
            HStack(spacing: 5) {
                Circle().fill(colour).frame(width: 7, height: 7)
                Text(grade.label)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(colour)
                if !compact, let b = band, b.isUsable {
                    Text("typical \(ChappyFX.money(b.low, currency))–\(ChappyFX.money(b.high, currency))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(colour.opacity(0.13)))
        }
    }
}

// =====================================================================
// BUILD 181 — THE THREE OPTIONS.
//
// One plan is a quote. Three is a conversation. Same region, same
// length, same reasons for going — the only thing that changes is what
// you're spending and what it buys, which is the only comparison worth
// putting on a screen.
//
// And underneath: a box to argue with it in plain words, because the
// moment after you compare three prices is exactly the moment you know
// what's wrong with all of them.
// =====================================================================

struct TripOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }
    @ObservedObject private var desk = ChappyTravel.shared
    @State private var gripe = ""
    @State private var comparison: ChappyComparison?
    @State private var share: URL?
    @State private var verdicts: [UUID: (ChappyScore.Verdict, ChappyTrueCost.Result)] = [:]

    /// Scored once per option set. Everything downstream reads the cache.
    private func rebuildVerdicts() {
        comparison = ChappyComparison.compare(desk.pendingOptions)
        var out: [UUID: (ChappyScore.Verdict, ChappyTrueCost.Result)] = [:]
        for t in desk.pendingOptions {
            out[t.id] = (ChappyScore.shared.score(t), ChappyTrueCost.shared.compute(t))
        }
        verdicts = out
    }

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if desk.pendingOptions.isEmpty {
                            Text("No options built yet. Say \u{201C}plan me two weeks in Bali\u{201D}, or use the planner.")
                                .font(.subheadline)
                                .foregroundColor(theme.textSecondary)
                                .padding(.top, 30)
                        }
                        // BUILD 185: the sentence goes ABOVE the options, not
                        // below them. By the time you have scrolled past three
                        // prices you have already decided, and the whole point
                        // of the verdict is to reach you before that.
                        // AUDIT: computing this in the body ran six full
                        // scorings, twelve true-cost passes and about
                        // twenty-one cost() calls on EVERY render — and
                        // cost() spawns an FX refresh Task when a rate is
                        // missing, so an offline session fired twenty-one
                        // of those per frame. Computed once, when the
                        // options change.
                        if let cmp = comparison {
                            ChappyVerdictBanner(cmp: cmp, theme: theme)
                        }
                        ForEach(desk.pendingOptions) { t in
                            optionCard(t)
                        }
                        if !desk.pendingOptions.isEmpty { gripeBox }
                    }
                    .padding(14)
                    .padding(.bottom, 40)
                }
                if desk.planning { busy }
            }
            .task(id: desk.pendingOptions.map(\.id)) { rebuildVerdicts() }
            .sheet(item: $share) { u in ChappyShareSheet(items: [u]) }
            .navigationTitle("Three ways to do it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !desk.pendingOptions.isEmpty {
                        Button {
                            if let u = desk.writeComparison(desk.pendingOptions) { share = u }
                        } label: { Image(systemName: "square.and.arrow.up") }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    /// The score plus the true-cost uplift. Two numbers, and the second
    /// one is the one that changes minds: "$4,180 — really $4,690".
    @ViewBuilder
    private func scoreRow(_ t: ChappyTravel.Trip) -> some View {
        if let cached = verdicts[t.id] {
            scoreRowBody(t, cached.0, cached.1)
        }
    }

    @ViewBuilder
    private func scoreRowBody(_ t: ChappyTravel.Trip,
                              _ v: ChappyScore.Verdict,
                              _ truth: ChappyTrueCost.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(v.total)")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundColor(ChappyVerdictBanner.colour(v.total))
                Text(v.band)
                    .font(.caption).fontWeight(.semibold)
                    .foregroundColor(ChappyVerdictBanner.colour(v.total))
                Text(v.coverage)
                    .font(.system(size: 10))
                    .foregroundColor(theme.textSecondary.opacity(0.8))
                Spacer()
                if truth.hidden > 0 {
                    Text("really \(ChappyFX.money(truth.total, t.homeCurrency))")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.orange)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(ChappyVerdictBanner.colour(v.total))
                        .frame(width: geo.size.width * CGFloat(max(0, min(100, v.total))) / 100)
                }
            }
            .frame(height: 4)
            if let flag = v.redFlags.first {
                Text(flag)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func optionCard(_ t: ChappyTravel.Trip) -> some View {
        let shape = ChappyTravel.Shape(rawValue: t.shape ?? "") ?? .balanced
        let c = desk.cost(t)
        let isLive = desk.activeID == t.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shape.label)
                        .font(.headline).foregroundColor(theme.textPrimary)
                    Text(shape.blurb)
                        .font(.caption2).foregroundColor(theme.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ChappyFX.money(c.total, t.homeCurrency))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(isLive ? theme.accent : theme.textPrimary)
                    if t.party > 1 {
                        Text("\(ChappyFX.money(c.perPerson, t.homeCurrency)) each")
                            .font(.caption2).foregroundColor(theme.textSecondary)
                    }
                }
            }

            Text(t.legs.map { "\($0.place) \($0.nights)n" }.joined(separator: " · "))
                .font(.caption)
                .foregroundColor(theme.textSecondary)
                .lineLimit(2)

            // BUILD 185: the score, and — more useful than the score —
            // what the headline price is actually missing.
            scoreRow(t)

            // How much of this plan is actually well priced — the single
            // most useful thing about having bands at all.
            let grades = gradeSpread(t)
            if grades.total > 0 {
                HStack(spacing: 10) {
                    if grades.great > 0 { tally("\(grades.great) great", .green) }
                    if grades.fair > 0 { tally("\(grades.fair) about right", .orange) }
                    if grades.high > 0 { tally("\(grades.high) over the odds", .red) }
                }
            }

            if let s = t.summary, !s.isEmpty {
                Text(s)
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                ChappyEarcon.shared.tap()
                desk.adopt(t)
                dismiss()
            } label: {
                Text(isLive ? "This is the one you're on" : "Use this one")
                    .font(.subheadline).fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(isLive ? Color.white.opacity(0.08)
                                                      : theme.accent.opacity(0.22)))
                    .foregroundColor(isLive ? theme.textSecondary : theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(isLive)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(isLive ? 0.09 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(isLive ? theme.accent.opacity(0.5) : .clear, lineWidth: 1.5))
    }

    private func tally(_ text: String, _ colour: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(colour).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.textSecondary)
        }
    }

    private func gradeSpread(_ t: ChappyTravel.Trip) -> (great: Int, fair: Int, high: Int, total: Int) {
        var g = 0, f = 0, h = 0
        for leg in t.legs {
            for (value, band) in [(leg.nightlyRate, leg.stayBand),
                                  (leg.arrivalCost, leg.arrivalBand),
                                  (leg.foodPerDay, leg.foodBand),
                                  (leg.groundPerDay, leg.groundBand)] {
                switch ChappyTravel.grade(value, band) {
                case .great, .good: g += 1
                case .fair:         f += 1
                case .high:         h += 1
                case .unknown:      continue
                }
            }
        }
        return (g, f, h, g + f + h)
    }

    private var gripeBox: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("TELL ME WHAT'S WRONG WITH IT")
                .font(.caption2).fontWeight(.heavy).tracking(0.6)
                .foregroundColor(.cyan)
            HStack(spacing: 8) {
                TextField("Too expensive. Keep it under six grand.", text: $gripe)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { send() }
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2).foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(gripe.trimmingCharacters(in: .whitespaces).isEmpty || desk.planning)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(["Too expensive", "Cut a leg", "Fewer places",
                             "Nicer rooms", "Less flying", "No hostels"], id: \.self) { q in
                        Button {
                            gripe = q; send()
                        } label: {
                            Text(q)
                                .font(.caption2).fontWeight(.semibold)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(theme.accent.opacity(0.14)))
                                .foregroundColor(theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("It keeps everything you didn't complain about, and it remembers what you turned down.")
                .font(.caption2)
                .foregroundColor(theme.textSecondary.opacity(0.8))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    private func send() {
        let said = gripe.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty else { return }
        gripe = ""
        ChappyEarcon.shared.tap()
        Task {
            guard let t = desk.active ?? desk.pendingOptions.first else { return }
            await desk.revise(t, saying: said)
        }
    }

    private var busy: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(theme.accent).scaleEffect(1.3)
                Text("Reworking it…").font(.headline).foregroundColor(.white)
                Text("Checking real prices again. Up to a minute.")
                    .font(.caption).foregroundColor(.white.opacity(0.75))
            }
        }
    }
}

// =====================================================================
// BUILD 181 — THE INTAKE, ON SCREEN.
//
// The same questions the voice version asks, in the same order, sharing
// the same answers — so you can start it out loud on a walk and finish
// it on the couch, or the other way round.
//
// Every question carries WHY it changes the plan. A questionnaire that
// won't tell you why it's asking is one people abandon halfway, and
// half an intake is worse than none because the plan then quietly
// assumes things you never said.
// =====================================================================

struct IntakeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }
    @ObservedObject private var intake = ChappyIntake.shared
    @State private var text: [String: String] = [:]

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        ForEach(intake.live) { q in
                            question(q)
                        }
                        Text("Answered once, remembered for good. Every plan from here on reads these, which is why the second trip you plan comes out better than the first.")
                            .font(.caption2)
                            .foregroundColor(theme.textSecondary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                        Button(role: .destructive) {
                            intake.reset(); text = [:]
                        } label: {
                            Text("Start over").font(.caption).fontWeight(.semibold)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red.opacity(0.8))
                    }
                    .padding(14)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("How you travel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { intake.showing = false; dismiss() }
                }
            }
            .onAppear {
                for q in ChappyIntake.questions where q.kind == .text || q.kind == .number {
                    text[q.id] = intake.answers[q.id] ?? ""
                }
            }
            // AUDIT: showing was only cleared by the Done button, so a swipe
            // dismiss left it true and every later utterance was read as an
            // interview answer until the questionnaire finished.
            .onDisappear { intake.showing = false }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(intake.isComplete ? "All set" : "\(intake.unanswered.count) to go")
                    .font(.headline).foregroundColor(theme.textPrimary)
                Spacer()
                Text("\(Int(intake.progress * 100))%")
                    .font(.caption).foregroundColor(theme.accent)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule().fill(theme.accent)
                        .frame(width: max(3, geo.size.width * intake.progress))
                }
            }
            .frame(height: 6)
            Text("These are about how YOU travel, not about one trip. You can also just say \u{201C}Chappy, ask me about how I travel\u{201D} and do it out loud.")
                .font(.caption2)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    @ViewBuilder
    private func question(_ q: ChappyIntake.Question) -> some View {
        let answered = !(intake.answers[q.id] ?? "").isEmpty
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: answered ? "checkmark.circle.fill" : "circle")
                    .font(.footnote)
                    .foregroundColor(answered ? .green : theme.textSecondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.prompt)
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundColor(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !q.why.isEmpty {
                        Text(q.why)
                            .font(.caption2)
                            .foregroundColor(theme.textSecondary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            switch q.kind {
            case .yesno:
                HStack(spacing: 8) {
                    ForEach(["Yes", "No"], id: \.self) { v in
                        pill(v, on: intake.answers[q.id] == v) { intake.set(q.id, v) }
                    }
                }
            case .choice:
                FlowChips(options: q.options,
                          isOn: { intake.answers[q.id] == $0 },
                          tap: { intake.set(q.id, $0) },
                          theme: theme)
            case .multi:
                FlowChips(options: q.options,
                          isOn: { intake.has(q.id, $0) },
                          tap: { intake.toggleMulti(q.id, $0) },
                          theme: theme)
            case .text, .number:
                TextField("Your answer", text: Binding(
                    get: { text[q.id] ?? "" },
                    set: { text[q.id] = $0; intake.set(q.id, $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .keyboardType(q.kind == .number ? .numberPad : .default)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    private func pill(_ label: String, on: Bool, tap: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            tap()
        } label: {
            Text(label)
                .font(.caption).fontWeight(.semibold)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(on ? theme.accent.opacity(0.25) : Color.white.opacity(0.07)))
                .foregroundColor(on ? theme.accent : theme.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

/// Chips that wrap instead of scrolling sideways — an option you have to
/// swipe to discover is an option most people never see.
struct FlowChips: View {
    let options: [String]
    let isOn: (String) -> Bool
    let tap: (String) -> Void
    let theme: ChappyTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows(), id: \.self) { row in
                HStack(spacing: 7) {
                    ForEach(row, id: \.self) { o in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            tap(o)
                        } label: {
                            Text(o)
                                .font(.caption).fontWeight(.semibold)
                                .padding(.horizontal, 11).padding(.vertical, 7)
                                .background(Capsule().fill(isOn(o) ? theme.accent.opacity(0.25)
                                                                   : Color.white.opacity(0.07)))
                                .foregroundColor(isOn(o) ? theme.accent : theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Rough packing by character count — good enough for chips this size
    /// and far cheaper than a real flow layout.
    private func rows() -> [[String]] {
        var out: [[String]] = []
        var row: [String] = []
        var width = 0
        for o in options {
            let w = o.count + 4
            if width + w > 34, !row.isEmpty { out.append(row); row = []; width = 0 }
            row.append(o); width += w
        }
        if !row.isEmpty { out.append(row) }
        return out
    }
}


// =====================================================================
// BUILD 185 — THE SENTENCE, ON SCREEN.
//
// The report can afford a page. This has one paragraph and it has to
// land before he has scrolled past three prices — because once he has
// seen three prices he has already decided, and the verdict arrives
// as an argument rather than as advice.
//
// So: what I'd do, why, and when the cheapest is genuinely the best
// one, that sentence instead. The second case matters more than it
// looks. A recommender that always points at the dearer option has
// not made a judgement, and people work that out fast.
// =====================================================================

struct ChappyVerdictBanner: View {
    let cmp: ChappyComparison
    let theme: ChappyTheme
    @State private var expanded = false

    static func colour(_ score: Int) -> Color {
        switch score {
        case 80...:   return Color(red: 0.19, green: 0.77, blue: 0.49)
        case 62..<80: return Color(red: 0.56, green: 0.82, blue: 0.48)
        case 45..<62: return .orange
        default:      return Color(red: 1.0, green: 0.42, blue: 0.37)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: cmp.cheapestWins ? "checkmark.seal.fill" : "hand.raised.fill")
                    .font(.caption)
                Text(cmp.cheapestWins ? "The cheapest is the best one" : "What I'd do")
                    .font(.caption).fontWeight(.heavy)
                    .textCase(.uppercase)
                    .kerning(1.2)
                Spacer()
            }
            .foregroundColor(theme.accent)

            Text(cmp.recommendation)
                .font(.subheadline)
                .foregroundColor(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if expanded {
                Divider().background(Color.white.opacity(0.10))
                ForEach(cmp.rows) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(r.score.total)")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundColor(Self.colour(r.score.total))
                            .frame(width: 30, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.label).font(.caption).fontWeight(.semibold)
                                .foregroundColor(theme.textPrimary)
                            Text(ChappyFX.money(r.realCost, r.trip.homeCurrency)
                                 + (r.truth.hidden > 0
                                    ? " all in · headline \(ChappyFX.money(r.headlineCost, r.trip.homeCurrency))"
                                    : " all in"))
                                .font(.caption2).foregroundColor(theme.textSecondary)
                        }
                        Spacer()
                        if r.isRecommended {
                            Text("PICK").font(.system(size: 9, weight: .heavy))
                                .foregroundColor(Self.colour(90))
                        } else if r.isCheapest {
                            Text("CHEAPEST").font(.system(size: 9, weight: .heavy))
                                .foregroundColor(theme.textSecondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                Text(expanded ? "Less" : "Show the numbers")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundColor(theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.accent.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.accent.opacity(0.22), lineWidth: 1)))
    }
}


// =====================================================================
// BUILD 188 — THE TRIP FILE SCREEN.
//
// Three tabs, because these are three different moods. "What do I
// still have to do" is a Sunday-afternoon question. "What's the
// confirmation number" is a standing-at-a-desk question. "Where's my
// passport scan" is a panicking question, and it has to work with no
// signal.
//
// The timeline is first on purpose: it is the only one of the three
// that tells you something you did not already know.
// =====================================================================

struct ChappyTripFileView: View {
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var file = ChappyFile.shared
    @ObservedObject private var desk = ChappyTravel.shared
    @ObservedObject private var watch = ChappyWatch.shared
    @State private var tab = 0
    @State private var editing: ChappyFile.Booking?

    private var trip: ChappyTravel.Trip? { desk.active }

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        Text("To do").tag(0)
                        Text("Booked").tag(1)
                        Text("Watching").tag(2)
                        Text("Docs").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .padding(12)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if tab == 0 { timelineTab }
                            else if tab == 1 { bookingsTab }
                            else if tab == 2 { watchTab }
                            else { documentsTab }
                        }
                        .padding(14)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Trip file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) {
                    if tab == 1 {
                        Button {
                            var b = ChappyFile.Booking()
                            b.tripID = trip?.id
                            b.currency = trip?.homeCurrency ?? "AUD"
                            editing = b
                        } label: { Image(systemName: "plus") }
                    }
                }
            }
            .sheet(item: $editing) { b in
                ChappyBookingEditor(booking: b, theme: theme)
            }
        }
    }

    // ---------------------------------------------------------- to do

    @ViewBuilder private var timelineTab: some View {
        if let t = trip {
            let items = file.timeline(t)
            if items.isEmpty {
                empty("No dates on the trip yet, so there's nothing to count down to.")
            } else {
                let done = items.filter(\.done).count
                Text("\(done) of \(items.count) done")
                    .font(.caption).foregroundColor(theme.textSecondary)
                // timeline() already returns these in bucket order, so the
                // list just follows it. An extra sort here was a leftover
                // that compared a value with itself and did nothing.
                ForEach(items) { item in
                    timelineRow(item)
                }
            }
        } else {
            empty("No active trip.")
        }
    }

    private func timelineRow(_ item: ChappyFile.TimelineItem) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(item.done ? .green : (item.urgent ? .orange : theme.textSecondary))
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundColor(item.done ? theme.textSecondary : theme.textPrimary)
                        .strikethrough(item.done, color: theme.textSecondary)
                    Spacer()
                    Text(item.bucket)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(item.urgent ? .orange : theme.textSecondary.opacity(0.7))
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(item.urgent ? 0.08 : 0.04)))
    }

    // ---------------------------------------------------------- booked

    @ViewBuilder private var bookingsTab: some View {
        let mine = file.bookings(for: trip?.id)
        if mine.isEmpty {
            empty("Nothing recorded yet. Add a booking as you make it — the confirmation number is the bit you'll want at a desk with no signal.")
        } else {
            ForEach(mine) { b in
                Button { editing = b } label: { bookingRow(b) }
                    .buttonStyle(.plain)
            }
        }
        if let t = trip {
            let cover = file.coverage(t)
            if !cover.missing.isEmpty {
                Text("Still to book: " + cover.missing.joined(separator: ", "))
                    .font(.caption).foregroundColor(.orange)
                    .padding(.top, 4)
            }
        }
    }

    private func bookingRow(_ b: ChappyFile.Booking) -> some View {
        HStack(spacing: 11) {
            Image(systemName: b.kind.icon)
                .foregroundColor(theme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.title.isEmpty ? b.kind.label : b.title)
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundColor(theme.textPrimary)
                if !b.reference.isEmpty {
                    Text("Ref \(b.reference)")
                        .font(.caption).foregroundColor(theme.textSecondary)
                }
                if let d = b.daysToCancel {
                    Text(d < 0
                         ? "Free cancellation has passed"
                         : "Free cancellation for \(d) more day\(d == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(d < 0 ? theme.textSecondary : (d <= 3 ? .red : .green))
                }
            }
            Spacer()
            if b.amount > 0 {
                Text(ChappyFX.money(b.amount, b.currency))
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(theme.textPrimary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    // ---------------------------------------------------------- watching

    @ViewBuilder private var watchTab: some View {
        let mine = watch.watches.filter { $0.tripID == trip?.id || $0.tripID == nil }
        HStack {
            if let t = trip {
                Button {
                    watch.watchRoutes(of: t)
                } label: {
                    Label("Watch this trip's routes", systemImage: "plus.circle")
                        .font(.caption).fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.accent)
            }
            Spacer()
            if watch.running {
                ProgressView().scaleEffect(0.7)
            } else {
                Button { Task { await watch.run(force: true) } } label: {
                    Label("Check now", systemImage: "arrow.clockwise")
                        .font(.caption).fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.accent)
            }
        }

        if mine.isEmpty {
            empty("Nothing being watched yet. Add this trip's routes and Chappy takes one researched price a week and writes it down. After six weeks, \"book now or wait\" stops being a guess about airlines in general and becomes an observation about your route.")
        } else {
            ForEach(mine) { w in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Image(systemName: w.kind.icon)
                            .font(.caption).foregroundColor(theme.accent)
                        Text(w.label)
                            .font(.subheadline).fontWeight(.medium)
                            .foregroundColor(theme.textPrimary)
                        Spacer()
                        Text(w.advice.label)
                            .font(.caption).fontWeight(.heavy)
                            .foregroundColor(ChappyVerdictBanner.colour(
                                w.advice == .book ? 90 : (w.advice == .wait ? 50 : 65)))
                    }
                    Text(w.adviceLine)
                        .font(.caption).foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if w.points.count >= 2 {
                        sparkline(w)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05)))
                .contextMenu {
                    Button(role: .destructive) { watch.remove(w) } label: {
                        Label("Stop watching", systemImage: "trash")
                    }
                }
            }
        }
        if let last = watch.lastRun {
            Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2).foregroundColor(theme.textSecondary.opacity(0.7))
        }
    }

    private func sparkline(_ w: ChappyWatch.Watch) -> some View {
        let mids = w.points.map(\.mid)
        let lo = mids.min() ?? 0
        let hi = mids.max() ?? 1
        let span = max(0.0001, hi - lo)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(w.points) { p in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(abs(p.mid - lo) < 0.001 ? Color.green : Color.white.opacity(0.22))
                    .frame(height: 6 + CGFloat((p.mid - lo) / span) * 24)
            }
        }
        .frame(height: 30)
    }

    // ---------------------------------------------------------- documents

    @ViewBuilder private var documentsTab: some View {
        if file.documents.isEmpty {
            empty("Nothing stored. Share a PDF or a photo into Chappy — passport, visa, insurance, tickets — and it lives here, offline, for the moment you're at a desk with no wifi.")
        } else {
            ForEach(file.documents) { d in
                HStack(spacing: 11) {
                    Image(systemName: d.kind.icon)
                        .foregroundColor(theme.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.label.isEmpty ? d.kind.label : d.label)
                            .font(.subheadline).fontWeight(.medium)
                            .foregroundColor(theme.textPrimary)
                        if let days = d.daysToExpiry {
                            Text(days < 0 ? "Expired" : "Expires in \(days) days")
                                .font(.caption2)
                                .foregroundColor(days < 0 ? .red : (days < 183 ? .orange : theme.textSecondary))
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05)))
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 24)
    }
}

// =====================================================================

struct ChappyBookingEditor: View {
    @State var booking: ChappyFile.Booking
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var file = ChappyFile.shared
    @State private var hasStart = false
    @State private var hasCancel = false
    @State private var start = Date()
    @State private var cancel = Date()

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Kind", selection: $booking.kind) {
                        ForEach(ChappyFile.BookingKind.allCases) { k in
                            Label(k.label, systemImage: k.icon).tag(k)
                        }
                    }
                    TextField("What is it", text: $booking.title)
                    TextField("Provider", text: $booking.provider)
                    TextField("Confirmation number", text: $booking.reference)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                Section("Money") {
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("0", value: $booking.amount, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Currency", selection: $booking.currency) {
                        ForEach(ChappyFX.common, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Already paid", isOn: $booking.paid)
                }
                Section {
                    Toggle("Has a start date", isOn: $hasStart)
                    if hasStart {
                        DatePicker("Starts", selection: $start, displayedComponents: .date)
                    }
                } header: {
                    Text("Dates")
                } footer: {
                    Text("Used to sort the file and to put the booking on the right day of the itinerary.")
                }
                Section {
                    Toggle("Refundable until a date", isOn: $hasCancel)
                    if hasCancel {
                        DatePicker("Until", selection: $cancel, displayedComponents: .date)
                    }
                } header: {
                    Text("Free cancellation")
                } footer: {
                    Text("The most valuable field on this screen. Chappy reminds you seven days and two days before the deadline — a refundable booking you forgot to cancel is a non-refundable booking with extra steps, and it costs more than every hidden fee in the report put together.")
                }
                Section {
                    TextField("Notes", text: $booking.notes, axis: .vertical)
                        .lineLimit(2...5)
                }
                if file.bookings.contains(where: { $0.id == booking.id }) {
                    Section {
                        Button(role: .destructive) {
                            file.remove(booking); dismiss()
                        } label: { Text("Delete this booking") }
                    }
                }
            }
            .navigationTitle(booking.title.isEmpty ? "Booking" : booking.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { commit() }.fontWeight(.semibold)
                }
            }
            .onAppear {
                if let s = booking.starts { start = s; hasStart = true }
                if let c = booking.refundableUntil { cancel = c; hasCancel = true }
            }
        }
    }

    private func commit() {
        booking.starts = hasStart ? start : nil
        booking.refundableUntil = hasCancel ? cancel : nil
        if file.bookings.contains(where: { $0.id == booking.id }) { file.update(booking) }
        else { file.add(booking) }
        dismiss()
    }
}


// =====================================================================
// BUILD 190 — THE ONE-WAY CARD.
//
// Small, and it drives eight things: whether hops() invents a flight
// home, whether the true cost adds a return baggage sector, what the
// price journal is pricing, what the last day of the trip is, and —
// the one that actually stops people at an airport — whether an onward
// ticket is needed to board.
//
// The onward line is not a checklist item. In Indonesia, Thailand and
// the Philippines it is the airline that refuses you, at the desk,
// because the airline is liable for carrying someone a country won't
// admit. So it gets a red card and a countdown, not a tick box.
// =====================================================================

struct ChappyOneWayCard: View {
    let trip: ChappyTravel.Trip
    let theme: ChappyTheme
    @ObservedObject private var desk = ChappyTravel.shared
    @ObservedObject private var file = ChappyFile.shared
    @State private var showOnward = false

    private var isOneWay: Bool { trip.oneWay == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isOneWay ? "arrow.right" : "arrow.left.arrow.right")
                    .foregroundColor(theme.accent).font(.subheadline)
                Text(isOneWay ? "One-way" : "Return")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isOneWay },
                    set: { on in
                        var t = trip
                        t.oneWay = on
                        desk.update(t)
                    }))
                    .labelsHidden()
            }

            Text(isOneWay
                 ? "No flight home in the plan, bags counted one way, and the price journal prices one-ways rather than halving a return."
                 : "A return is assumed — there's a flight home in the route and the bags are counted both ways.")
                .font(.caption)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if isOneWay {
                let needs = ChappyOnward.shared.needs(trip)
                if !needs.isEmpty {
                    Divider().background(Color.white.opacity(0.10))
                    ForEach(needs) { need in
                        onwardRow(need)
                    }
                    Button { showOnward = true } label: {
                        Label("Record an onward ticket", systemImage: "plus.circle")
                            .font(.caption).fontWeight(.semibold)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accent)
                }
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.05)))
        .sheet(isPresented: $showOnward) {
            ChappyOnwardSheet(trip: trip, theme: theme)
        }
    }

    @ViewBuilder
    private func onwardRow(_ need: ChappyOnward.Need) -> some View {
        let bad = !need.satisfied && need.rule.enforcement == .strict
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: need.satisfied ? "checkmark.seal.fill"
                  : (bad ? "exclamationmark.triangle.fill" : "questionmark.circle"))
                .foregroundColor(need.satisfied ? .green : (bad ? .red : .orange))
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(need.country) — \(need.rule.enforcement.label)")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundColor(theme.textPrimary)
                Text(need.expiresBefore
                     ? "You've recorded one, but it lapses before you fly. A temporary reservation is only proof on the day."
                     : (need.satisfied ? "Held." : need.rule.note))
                    .font(.caption2)
                    .foregroundColor(need.expiresBefore ? .orange : theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// =====================================================================

struct ChappyOnwardSheet: View {
    let trip: ChappyTravel.Trip
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var file = ChappyFile.shared
    @State private var country = ""
    @State private var reference = ""
    @State private var method: ChappyOnward.Method = .temporary
    @State private var validUntil = Date().addingTimeInterval(48 * 3600)

    var body: some View {
        NavigationView {
            Form {
                Section("Which country") {
                    Picker("Country", selection: $country) {
                        ForEach(ChappyOnward.shared.needs(trip)) { n in
                            Text(n.country).tag(n.country)
                        }
                    }
                }
                Section {
                    Picker("Method", selection: $method) {
                        ForEach(ChappyOnward.Method.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    Text(method.detail)
                        .font(.caption).foregroundColor(.secondary)
                    Text("Cost: \(method.cost)")
                        .font(.caption).foregroundColor(.secondary)
                } header: {
                    Text("How")
                } footer: {
                    Text(ChappyOnward.neverGenerate)
                }
                Section {
                    TextField("PNR / confirmation", text: $reference)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    DatePicker("Valid until", selection: $validUntil)
                } header: {
                    Text("The booking")
                } footer: {
                    Text("A temporary reservation cancels itself after about 48 hours, so it's only proof on the day you fly. Chappy checks the date against your arrival and warns you if it lapses first — which is the specific way this goes wrong.")
                }
            }
            .navigationTitle("Onward ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.fontWeight(.semibold)
                }
            }
            .onAppear {
                if country.isEmpty { country = ChappyOnward.shared.needs(trip).first?.country ?? "" }
            }
        }
    }

    private func save() {
        var b = ChappyFile.Booking()
        b.tripID = trip.id
        b.kind = .onward
        b.title = "Onward from \(country)"
        b.reference = reference
        b.notes = "\(country) · \(method.label)"
        b.ends = validUntil
        b.currency = trip.homeCurrency
        file.add(b)
        dismiss()
    }
}


// =====================================================================
// BUILD 190 — THE FLIGHTS SCREEN.
//
// Everything below already existed as engine and had no way in: the
// airport atlas, the connection verdicts, the nearby-airport
// alternatives, the baggage table, the price journal. It lived in the
// emailed report, which meant it only reached him if he thought to
// generate one.
//
// The screen is deliberately not a flight search. Chappy has no live
// fares and never will, so imitating Google Flights would produce a
// worse Google Flights with no prices in it. What it does instead is
// tell him what a search RESULT means — whether $180 plus $95 of bags
// beats $240, whether the connection can be made, whether a cheaper
// airport is actually cheaper once the road is counted, and whether
// this week's number is good measured against his own record.
// =====================================================================

struct ChappyFlightsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @ObservedObject private var desk = ChappyTravel.shared
    @ObservedObject private var watch = ChappyWatch.shared
    @State private var picked: ChappyTravel.Hop?
    @State private var share: URL?
    @State private var showStatus = false

    private var trip: ChappyTravel.Trip? { desk.active }
    private var segments: [ChappyTravel.Hop] { trip.map { desk.hops($0) } ?? [] }

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let t = trip {
                            hitsSection
                            routeSection(t)
                            watchSection(t)
                            meterSection
                        } else {
                            Text("No active trip. Plan one in the Travel Desk and the segments show up here.")
                                .font(.subheadline).foregroundColor(theme.textSecondary)
                                .padding(.top, 30)
                        }
                        Button { showStatus = true } label: {
                            Label("Flight status & tracking", systemImage: "dot.radiowaves.left.and.right")
                                .font(.subheadline).fontWeight(.semibold)
                        }
                        .buttonStyle(.plain).foregroundColor(theme.accent).padding(.top, 8)
                    }
                    .padding(14).padding(.bottom, 40)
                }
            }
            .navigationTitle("Flights")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showStatus) { FlightsView(theme: theme) }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let t = trip {
                        Button {
                            share = desk.writeFlights(t)
                        } label: { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
            .sheet(item: $picked) { hop in
                ChappySegmentView(hop: hop, theme: theme)
            }
            .sheet(item: $share) { u in ChappyShareSheet(items: [u]) }
        }
    }

    // ---------------------------------------------------------- route

    @ViewBuilder private func routeSection(_ t: ChappyTravel.Trip) -> some View {
        HStack {
            Text(t.name).font(.headline).foregroundColor(theme.textPrimary)
            Spacer()
            if t.oneWay == true {
                Text("ONE-WAY").font(.system(size: 9, weight: .heavy))
                    .foregroundColor(theme.accent)
            }
        }
        if segments.isEmpty {
            Text("Nothing in this trip is reached by air yet.")
                .font(.subheadline).foregroundColor(theme.textSecondary)
        } else {
            ForEach(segments) { hop in
                Button { picked = hop } label: { segmentRow(hop, t) }
                    .buttonStyle(.plain)
            }
            let mins = segments.reduce(0) { $0 + $1.minutes }
            HStack {
                Text("Time in the air, all \(segments.count)")
                    .font(.caption).foregroundColor(theme.textSecondary)
                Spacer()
                Text(ChappyPorts.minutesLine(max(0, mins - 35 * segments.count)))
                    .font(.caption).fontWeight(.semibold).foregroundColor(theme.textPrimary)
            }
            .padding(.horizontal, 4)
        }
    }

    private func segmentRow(_ hop: ChappyTravel.Hop, _ t: ChappyTravel.Trip) -> some View {
        let w = watch.watches.first {
            $0.tripID == t.id && $0.label.hasPrefix("\(hop.from.iata) → \(hop.to.iata)")
        }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hop.route)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(theme.textPrimary)
                Text("\(f.string(from: hop.when)) · \(ChappyPorts.durationLine(hop.km)) · \(Int(hop.km.rounded())) km")
                    .font(.caption2).foregroundColor(theme.textSecondary)
            }
            Spacer()
            if let adv = w?.advice, adv != .thin {
                Text(adv.label.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(ChappyVerdictBanner.colour(adv == .book ? 90 : (adv == .wait ? 50 : 65)).opacity(0.18)))
                    .foregroundColor(ChappyVerdictBanner.colour(adv == .book ? 90 : (adv == .wait ? 50 : 65)))
            }
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundColor(theme.textSecondary.opacity(0.6))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    // ---------------------------------------------------------- what it found

    /// The top of the screen when something has actually turned up.
    /// Every one of these has already been priced by Chappy — the feed
    /// made a claim and Chappy went and checked it before showing him.
    @ViewBuilder private var hitsSection: some View {
        let hits = watch.liveHits
        if !hits.isEmpty {
            ForEach(hits.prefix(3)) { hit in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: hit.confirmed ? "checkmark.seal.fill" : "questionmark.circle")
                            .font(.caption)
                        Text(hit.confirmed ? "CONFIRMED" : "UNCONFIRMED")
                            .font(.system(size: 9, weight: .heavy)).kerning(1)
                        Spacer()
                        Text("\(hit.ageHours)h ago")
                            .font(.caption2).foregroundColor(theme.textSecondary)
                    }
                    .foregroundColor(hit.confirmed ? .green : .orange)

                    if !hit.route.isEmpty {
                        Text(hit.route).font(.subheadline).fontWeight(.semibold)
                            .foregroundColor(theme.textPrimary)
                    }
                    Text(hit.what).font(.caption).foregroundColor(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(hit.verdict).font(.caption2).foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        if let u = URL(string: hit.searchURL), !hit.searchURL.isEmpty {
                            Button { UIApplication.shared.open(u) } label: {
                                Label("Book it", systemImage: "airplane.departure")
                                    .font(.caption).fontWeight(.semibold)
                            }
                            .buttonStyle(.plain).foregroundColor(theme.accent)
                        }
                        if let u = URL(string: hit.url), !hit.url.isEmpty {
                            Button { UIApplication.shared.open(u) } label: {
                                Label("Read the post", systemImage: "safari")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain).foregroundColor(theme.textSecondary)
                        }
                    }
                }
                .padding(13)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill((hit.confirmed ? Color.green : Color.orange).opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke((hit.confirmed ? Color.green : Color.orange).opacity(0.26), lineWidth: 1))
            }
        }
    }

    // ---------------------------------------------------------- watching

    @ViewBuilder private func watchSection(_ t: ChappyTravel.Trip) -> some View {
        // AUDIT: filtering on !points.isEmpty meant that after tapping
        // "Watch these routes" — which creates them with no points yet —
        // the list was still empty and the button was still there. It
        // read as a broken button. The .thin copy already says "one
        // reading so far, three is the minimum"; let it say it.
        let mine = watch.watches.filter { $0.tripID == t.id && $0.kind == .route }
        if !mine.isEmpty {
            Text("Watching").font(.caption).fontWeight(.semibold)
                .foregroundColor(theme.textSecondary).padding(.top, 6)
            ForEach(mine) { w in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(w.label).font(.caption).fontWeight(.semibold)
                            .foregroundColor(theme.textPrimary)
                        Spacer()
                        Text(w.advice.label).font(.caption).fontWeight(.heavy)
                            .foregroundColor(ChappyVerdictBanner.colour(w.advice == .book ? 90 : (w.advice == .wait ? 50 : 65)))
                    }
                    Text(w.adviceLine).font(.caption2).foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05)))
            }
        } else if let t2 = trip {
            Button { watch.watchRoutes(of: t2) } label: {
                Label("Watch these routes", systemImage: "plus.circle")
                    .font(.caption).fontWeight(.semibold)
            }
            .buttonStyle(.plain).foregroundColor(theme.accent).padding(.top, 4)
        }
    }

    @ViewBuilder private var meterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The bar already exists and already knows the rules — no
            // reason to invent a second way of saying the same thing.
            FlightBudgetBar(theme: theme)
            Text("Spent on the flights you've booked, not on searching. Searching is free; status isn't.")
                .font(.caption2).foregroundColor(theme.textSecondary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }
}

// =====================================================================

struct ChappySegmentView: View {
    let hop: ChappyTravel.Hop
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var desk = ChappyTravel.shared
    @ObservedObject private var watch = ChappyWatch.shared

    private var trip: ChappyTravel.Trip? { desk.active }
    private var oneWay: Bool { trip?.oneWay == true }

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        if let w = mine { journal(w) }
                        included
                        alternatives
                        actions
                    }
                    .padding(14).padding(.bottom, 40)
                }
            }
            .navigationTitle(hop.route)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    /// AUDIT: no trip filter, and watches persist across trips in one
    /// array — so last year's SYD → DPS watch was shown against a trip
    /// six months from now, with a stale verdict.
    private var mine: ChappyWatch.Watch? {
        watch.watches.first {
            $0.tripID == trip?.id
                && $0.label.hasPrefix("\(hop.from.iata) → \(hop.to.iata)")
        }
    }

    /// AUDIT — THE ONE THAT WOULD NOT HAVE BUILT.
    ///
    /// `let f = DateFormatter()` is a declaration and the result builder
    /// leaves it alone. `f.dateFormat = "..."` is an expression statement
    /// of type (), and ViewBuilder has no Void overload — "type '()'
    /// cannot conform to 'View'". It is the only bare assignment at the
    /// top of a builder body anywhere in this file; every other formatter
    /// in here is set up inside a plain func with an explicit return.
    private var header: some View {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM yyyy"
        return VStack(alignment: .leading, spacing: 4) {
            Text(hop.route)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundColor(theme.textPrimary)
            Text("\(hop.from.city) → \(hop.to.city) · \(f.string(from: hop.when))")
                .font(.caption).foregroundColor(theme.textSecondary)
            Text("\(ChappyPorts.durationLine(hop.km)) gate to gate · \(Int(hop.km.rounded())) km · \(trip?.party ?? 1) travelling\(oneWay ? " · one-way" : "")")
                .font(.caption).foregroundColor(theme.textSecondary)
        }
    }

    @ViewBuilder private func journal(_ w: ChappyWatch.Watch) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(w.advice.label).font(.subheadline).fontWeight(.heavy)
                    .foregroundColor(ChappyVerdictBanner.colour(w.advice == .book ? 90 : (w.advice == .wait ? 50 : 65)))
                Spacer()
                Text("\(w.points.count) readings").font(.caption2)
                    .foregroundColor(theme.textSecondary)
            }
            Text(w.adviceLine).font(.caption).foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(ChappyVerdictBanner.colour(w.advice == .book ? 90 : (w.advice == .wait ? 50 : 65)).opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(ChappyVerdictBanner.colour(w.advice == .book ? 90 : (w.advice == .wait ? 50 : 65)).opacity(0.24), lineWidth: 1))
    }

    @ViewBuilder private var included: some View {
        // AUDIT: baggage(for:) is an EXACT match and FlightBrief.airlines
        // is free text ("Jetstar, Scoot"), so this never fired at all.
        // Routed through the fuzzy matcher now — and labelled honestly,
        // because FlightBrief holds ONE airline string for the whole
        // trip, so it may not be the carrier on this particular segment.
        if let raw = trip?.flights?.airlines,
           let name = ChappyTrueCost.airlineName(from: raw),
           let bag = ChappyTrueCost.baggage(for: name) {
            VStack(alignment: .leading, spacing: 6) {
                Text(bag.isLowCost ? "\(bag.airline) carries no bag" : "\(bag.airline) — \(bag.checkedIncludedKg)kg included")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(theme.textPrimary)
                Text(bag.isLowCost
                     ? "\(bag.carryOnKg)kg cabin, nothing checked on any fare. You carry 20kg each, so that isn't optional — buy it with the fare, because at the airport it's roughly triple."
                     : bag.note)
                    .font(.caption).foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if raw.contains(",") || raw.localizedCaseInsensitiveContains(" or ") {
                    Text("This trip lists \(raw) — Chappy holds one carrier for the whole plan, so check who actually flies this segment before trusting the bag rules.")
                        .font(.caption2).foregroundColor(theme.textSecondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.orange.opacity(bag.isLowCost ? 0.10 : 0.05)))
        }
    }

    @ViewBuilder private var alternatives: some View {
        let opts = desk.nearbyOptions(for: hop.to)
        if !opts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fly into somewhere else")
                    .font(.caption).fontWeight(.semibold).foregroundColor(theme.textSecondary)
                ForEach(opts) { o in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(Int(o.km.rounded())) km")
                            .font(.caption).fontWeight(.bold)
                            .foregroundColor(o.worthIt ? .green : .orange)
                            .frame(width: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.airport.label).font(.caption).fontWeight(.semibold)
                                .foregroundColor(theme.textPrimary)
                            Text(o.groundNote).font(.caption2).foregroundColor(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("I can't price these — no live fare feed exists for an app like this. The distance is the part people get wrong, and the distance is what decides whether a cheaper fare is actually cheaper.")
                    .font(.caption2).foregroundColor(theme.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.05)))
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 8) {
            if let u = ChappyFareShop.skyscanner(from: hop.from.iata, to: hop.to.iata,
                                                 on: hop.when, party: trip?.party ?? 1, oneWay: oneWay) {
                linkButton("Search on Skyscanner", "magnifyingglass", u, theme.accent)
            }
            if let u = desk.monthGridURL(hop, nights: trip?.nights ?? 1) {
                linkButton("Cheapest week of the month", "calendar", u, .orange)
            }
            if let name = trip?.flights?.airlines,
               let site = ChappyFareShop.airlineSites
               .sorted(by: { $0.key.count > $1.key.count })
               .first(where: { name.localizedCaseInsensitiveContains($0.key) }),
               let u = URL(string: site.value) {
                linkButton("\(site.key) direct", "airplane", u, theme.accent)
            }
            if let u = desk.codedFlightURL(hop, party: trip?.party ?? 1) {
                linkButton("Google Flights", "globe", u, theme.textSecondary)
            }
        }
        if let name = trip?.flights?.airlines,
           let warn = ChappyFareShop.googleBlindSpot(name) {
            Text(warn).font(.caption2).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    private func linkButton(_ title: String, _ icon: String, _ url: URL, _ tint: Color) -> some View {
        Button { UIApplication.shared.open(url) } label: {
            HStack {
                Image(systemName: icon).font(.caption)
                Text(title).font(.subheadline).fontWeight(.semibold)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption2)
            }
            .foregroundColor(tint)
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}


// =====================================================================
// BUILD 190 — WHAT THE NUMBER ACTUALLY BUYS.
//
// Ask for a trip on a budget and the planner will hit the budget —
// by thinning the trip until it fits. Twenty-two dollar rooms, twelve
// dollar days, and a plan that is technically real and practically
// miserable. The deal score doesn't catch it either, because every
// line sits at the bottom of its band, which reads as good value.
//
// This runs BEFORE the planner. Budget, minus flights, divided by
// nights and party, against what each country actually costs — and
// then the sentence a travel agent would say out loud before you
// picked the country rather than after.
//
// It advises rather than blocks. It's his money and his call; being
// told the trade-off beats being refused.
// =====================================================================

struct ChappyBudgetView: View {
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @State private var budget: Double = 5000
    @State private var nights: Double = 60
    @State private var party = 2
    @State private var destination = ""
    @State private var oneWay = true

    private var verdict: ChappyAfford.Verdict {
        ChappyAfford.shared.check(budget: budget, nights: Int(nights), party: party,
                                  destination: destination.isEmpty ? nil : destination,
                                  oneWay: oneWay)
    }

    var body: some View {
        // AUDIT: `verdict` is computed, and body referenced it six times
        // — two filters, two sorts and eight ChappyFX.money calls each,
        // and money() allocates a fresh NumberFormatter every time. On a
        // slider drag that is a few thousand formatter allocations a
        // second, which is a visible stutter rather than a theoretical
        // one. Computed once per pass.
        let v = verdict
        return NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        inputs
                        headlineCard(v)
                        if !v.works.isEmpty { list("Where that works", v.works, true) }
                        if !v.doesnt.isEmpty { list("Where it doesn't", v.doesnt, false) }
                        note
                    }
                    .padding(14).padding(.bottom, 40)
                }
            }
            .navigationTitle("What will it buy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder private var inputs: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Budget").font(.subheadline).foregroundColor(theme.textSecondary)
                Spacer()
                Text(ChappyFX.money(budget, "AUD"))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundColor(theme.textPrimary)
            }
            Slider(value: $budget, in: 1500...30000, step: 250).tint(theme.accent)
            HStack {
                Text("Nights").font(.subheadline).foregroundColor(theme.textSecondary)
                Spacer()
                Text("\(Int(nights))").font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(theme.textPrimary)
            }
            Slider(value: $nights, in: 7...180, step: 1).tint(theme.accent)
            HStack {
                Stepper("Travelling: \(party)", value: $party, in: 1...6)
                    .font(.subheadline).foregroundColor(theme.textSecondary)
            }
            Toggle("One-way", isOn: $oneWay)
                .font(.subheadline).foregroundColor(theme.textSecondary)
            TextField("Somewhere in mind? (optional)", text: $destination)
                .font(.subheadline)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    private func headlineCard(_ v: ChappyAfford.Verdict) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(v.headline)
                .font(.subheadline).foregroundColor(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().background(Color.white.opacity(0.10))
            Text(v.advice)
                .font(.subheadline).foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(theme.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(theme.accent.opacity(0.22), lineWidth: 1))
    }

    private func list(_ title: String, _ places: [ChappyAfford.Place], _ good: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).fontWeight(.semibold)
                .foregroundColor(theme.textSecondary)
            ForEach(places.prefix(good ? 6 : 4), id: \.region) { p in
                HStack(alignment: .top, spacing: 10) {
                    Text(ChappyFX.money(p.perNightTwo * Double(party) / 2, "AUD"))
                        .font(.caption).fontWeight(.bold)
                        .foregroundColor(good ? .green : .red)
                        .frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(p.country) — \(p.region)")
                            .font(.caption).fontWeight(.semibold)
                            .foregroundColor(theme.textPrimary)
                        Text(p.note).font(.caption2).foregroundColor(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    @ViewBuilder private var note: some View {
        Text("Per night for the whole party, on the ground, flights excluded. These come from real plans rather than a guess — they're what the long-stay simulations actually came out at. A number that fits here is a number you'd still enjoy in week eight.")
            .font(.caption2).foregroundColor(theme.textSecondary.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}
