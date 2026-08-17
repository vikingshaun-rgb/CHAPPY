/*
 * ChappyPulse — the intensity dial and ambient memory
 *
 * ADDITIVE FILE. Overwrites nothing. PHASE 5 STEP 2.
 *
 * Off / Light / Standard / Dense / Deep, voice-controlled, with a live cost
 * readout. Pulse wakes the glasses camera on an interval, takes a frame,
 * captions it cheaply, files caption + GPS + time as a memory, and puts the
 * camera back to sleep. Live AI becomes the summoned burst, not the lifestyle.
 *
 * ── THREE THINGS THE RESEARCH CHANGED ──────────────────────────────────
 *
 * 1. CAPTIONING IS NOT THE COST. Gemini 2.5 Flash-Lite at low media resolution
 *    is about $0.04 per thousand images. A full day at Deep — 288 frames — is
 *    roughly a cent, so the $0.50/day budget was never in danger. Haiku
 *    tokenises images by AREA rather than capping resolution and lands 10-25x
 *    more expensive, which is why the caption call deliberately does not go to
 *    the same brain as everything else in this app.
 *
 * 2. BATTERY IS THE CONSTRAINT, AND THE CAMERA SESSION COST IS UNDOCUMENTED.
 *    Meta publishes nothing about what it costs to open and close a DAT camera
 *    session. The Gen 2 runs on a 154 mAh cell where merely disabling voice-wake
 *    moves real runtime from ~3-4 hours to ~5-8, and a known SDK issue had
 *    sessions failing in a starting → stopping → stopped loop, which implies a
 *    real handshake rather than a cheap one. The developer community's own
 *    advice is to avoid frequent open/close and prefer short bounded windows.
 *    So a pulse is NOT one frame: it opens once, takes up to `framesPerWake`
 *    frames a few seconds apart, then closes. Fewer expensive handshakes for
 *    the same coverage. That number is tunable precisely because the crossover
 *    point is unknown and has to be measured on real hardware.
 *
 * 3. TWO FREE GATES BEFORE ANY SPEND. Motion first — if ContextEngine says he
 *    has been still since the last pulse, the camera is not woken at all; a
 *    stationary wearer is exactly where session overhead hurts most and the
 *    frame is worth least. Then similarity: Vision's
 *    VNGenerateImageFeaturePrintRequest compares the new frame against the last
 *    one actually captioned, on-device and free, and skips the network call if
 *    nothing has changed. Thirty frames of the same road cost nothing.
 *
 * ── PRIVACY IS A DESIGN CONSTRAINT, NOT A SETTING ──────────────────────
 * Microsoft shipped Recall on by default in 2024 and spent eighteen months
 * walking it back after researchers pulled the snapshot database off disk. By
 * July 2026 Ray-Ban Meta glasses had earned the nickname "pervert glasses",
 * DEF CON had banned them outright, and Instagram was removing accounts over
 * covert recording. The lesson from both is the same and it is not subtle:
 *
 *   Pulse is OFF by default and needs an explicit choice to enable.
 *   The glasses' own capture indicator is never suppressed.
 *   A status line shows what it is doing and what it has spent.
 *   One command — "Chappy, stop remembering" — kills it instantly.
 *
 * ── iOS 27 ─────────────────────────────────────────────────────────────
 * Captioning goes through one function on purpose. iOS 27's Foundation Models
 * framework gains image input, which makes captioning free and fully on-device
 * on Apple Intelligence hardware. When that ships, caption(_:) is the only
 * thing that changes.
 */

import Foundation
import UIKit
import Vision
import CoreLocation

@MainActor
final class ChappyPulse: ObservableObject {
    static let shared = ChappyPulse()
    private init() { load() }

    // MARK: - The dial

    enum Tier: String, CaseIterable, Codable, Identifiable {
        case off, light, standard, dense, deep
        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return "Off";       case .light: return "Light"
            case .standard: return "Standard"; case .dense: return "Dense"
            case .deep: return "Deep"
            }
        }

        /// Seconds between pulses. Wider at the low end than the original spec
        /// because the binding constraint is camera wake-ups, not API spend.
        var interval: TimeInterval {
            switch self {
            case .off: return .infinity
            case .light: return 15 * 60
            case .standard: return 10 * 60
            case .dense: return 5 * 60
            case .deep: return 150
            }
        }

        /// Frames per wake, a few seconds apart — fewer session handshakes for
        /// the same coverage.
        var framesPerWake: Int {
            switch self {
            case .off: return 0
            case .light, .standard: return 1
            case .dense: return 2
            case .deep: return 3
            }
        }

        var blurb: String {
            switch self {
            case .off:      return "Nothing is captured."
            case .light:    return "A glance every quarter hour. Pennies a day."
            case .standard: return "Every ten minutes. The everyday setting."
            case .dense:    return "Every five minutes, two frames. For a day worth remembering."
            case .deep:     return "Every couple of minutes. Heavy on battery — use it in bursts."
            }
        }
    }

    @Published private(set) var tier: Tier = .off
    @Published private(set) var isAwake = false
    @Published private(set) var framesToday = 0
    @Published private(set) var captionsToday = 0
    @Published private(set) var spentTodayUSD = 0.0
    @Published private(set) var lastCaption = ""
    @Published private(set) var boostUntil: Date?

    // MARK: - Tuning

    /// Gemini 2.5 Flash-Lite, low media resolution: ~258 image tokens in, ~30
    /// out. A constant so the status line shows a real number, not a guess.
    private let usdPerCaption = 0.00004
    /// Vision feature-print distance under which two frames are the same scene.
    /// Deliberately forgiving — skipping a frame costs nothing, captioning a
    /// duplicate costs money and clutters memory.
    private let sameSceneDistance: Float = 12.0
    /// Ambient memory is never worth the last of the battery.
    private let batteryFloor: Float = 0.20

    private enum Key {
        static let tier = "chappy_pulse_tier"
        static let day = "chappy_pulse_day"
        static let frames = "chappy_pulse_frames"
        static let captions = "chappy_pulse_captions"
        static let spent = "chappy_pulse_spent"
        static let boost = "chappy_pulse_boost_until"
        static let priorTier = "chappy_pulse_prior_tier"
    }
    private let d = UserDefaults.standard

    private var timer: Timer?
    private var lastPulseAt = Date.distantPast
    private var lastPrint: VNFeaturePrintObservation?
    private var lastFixAtPulse: CLLocation?
    // BUILD 132 — WHY "GLOWING PHONE SCREEN" WAS FILED THREE TIMES.
    //
    // Dedup only compared against the single PREVIOUS frame. Phone screen →
    // glance away → phone screen again read as three different scenes, and
    // each one paid for a caption and cluttered memory. Two rings fix it:
    // recent feature prints (the same SCENE within two hours is a duplicate
    // no matter what came between), and recent caption TEXT (the same
    // sentence within two days is a duplicate even when the pixels differ).
    private var recentPrints: [(print: VNFeaturePrintObservation, at: Date)] = []
    private var recentCaptions: [(text: String, at: Date)] = []

    // MARK: - Control

    func setTier(_ t: Tier, speak: Bool = true) {
        tier = t
        d.set(t.rawValue, forKey: Key.tier)
        rearm()
        guard speak else { return }
        TTSService.shared.speak(t == .off ? "Ambient memory off." : "\(t.label). \(t.blurb)")
        print("📸 [Pulse] tier → \(t.rawValue)")
    }

    /// "Chappy, remember everything for the next hour."
    func boost(to t: Tier = .deep, minutes: Int = 60) {
        if boostUntil == nil { d.set(tier.rawValue, forKey: Key.priorTier) }
        let until = Date().addingTimeInterval(Double(minutes) * 60)
        boostUntil = until
        d.set(until, forKey: Key.boost)
        setTier(t, speak: false)
        TTSService.shared.speak("Remembering everything for the next \(minutes) minutes.")
    }

    private func endBoostIfDue() {
        guard let until = boostUntil, Date() >= until else { return }
        boostUntil = nil
        d.removeObject(forKey: Key.boost)
        let prior = Tier(rawValue: d.string(forKey: Key.priorTier) ?? "off") ?? .off
        setTier(prior, speak: false)
        // BUILD 254: waits for a gap. mustBeHeard TRUE, on reflection —
        // setTier() above has already CHANGED what Chappy is recording, so
        // dropping the line leaves the tier silently reverted with nothing
        // said. A state change he did not ask for has to be announced; only
        // information can be dropped.
        ChappyStandby.speakWhenClear("Back to \(prior == .off ? "not recording" : prior.label.lowercased()).")
    }

    /// Call once at launch.
    func start() { rollDayIfNeeded(); rearm() }

    func stopEverything() {
        setTier(.off, speak: false)
        boostUntil = nil
        d.removeObject(forKey: Key.boost)
        TTSService.shared.speak("Stopped remembering.")
    }

    private func rearm() {
        timer?.invalidate(); timer = nil
        guard tier != .off else { return }
        // Short heartbeat rather than a timer at the tier interval, so a tier
        // change or an expiring boost takes effect immediately.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - The loop

    private func tick() async {
        endBoostIfDue()
        rollDayIfNeeded()
        guard tier != .off, !isAwake else { return }
        guard Date().timeIntervalSince(lastPulseAt) >= tier.interval else { return }

        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level >= 0, level < batteryFloor, UIDevice.current.batteryState != .charging {
            print("📸 [Pulse] battery \(Int(level * 100))% — standing down")
            setTier(.off, speak: false)
            // BUILD 254: worth hearing, so it waits rather than drops — but
            // it no longer lands on top of whatever he is saying.
            ChappyStandby.speakWhenClear("Battery's low — I've stopped ambient memory.")
            return
        }

        // Gate one: free, and skips the camera wake entirely — the expensive part.
        if !worthWaking() { lastPulseAt = Date(); return }
        await wakeAndCapture()
    }

    /// Deliberately generous. A stationary wearer indoors still gets an
    /// occasional frame, because "sat in the same cafe for two hours" is worth
    /// one memory — not zero, and not twenty.
    private func worthWaking() -> Bool {
        let snap = ContextEngine.shared.snapshot
        if snap.motion.map({ $0 != "still" }) ?? true { return true }
        if let last = lastFixAtPulse, let la = snap.latitude, let lo = snap.longitude {
            if last.distance(from: CLLocation(latitude: la, longitude: lo)) > 60 { return true }
        }
        return Date().timeIntervalSince(lastPulseAt) >= tier.interval * 4
    }

    // MARK: - Capture

    private func wakeAndCapture() async {
        isAwake = true
        lastPulseAt = Date()
        defer { isAwake = false }

        let snap = ContextEngine.shared.snapshot
        if let la = snap.latitude, let lo = snap.longitude {
            lastFixAtPulse = CLLocation(latitude: la, longitude: lo)
        }

        let wasStreaming = LiveAIManager.shared.streamViewModel?.streamingStatus == .streaming
        if !wasStreaming {
            NotificationCenter.default.post(name: .chappyWakeCameraForSnap, object: nil)
            for _ in 0..<20 {                                    // up to ~5s
                try? await Task.sleep(nanoseconds: 250_000_000)
                if LiveAIManager.shared.streamViewModel?.streamingStatus == .streaming { break }
            }
        }

        var taken = 0
        for i in 0..<max(1, tier.framesPerWake) {
            if i > 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            guard let frame = LiveAIManager.shared.streamViewModel?.currentVideoFrame else { break }
            taken += 1
            framesToday += 1
            await consider(frame)
        }
        persistCounters()

        // Put it back to sleep — but only if we were the ones who woke it, and
        // only if nothing else is relying on the session.
        if !wasStreaming, taken > 0 {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !someoneElseNeedsTheCamera() {
                await LiveAIManager.shared.streamViewModel?.stopSession()
            }
        }
        if taken == 0 { print("📸 [Pulse] no frame — camera never came up") }
    }

    private func someoneElseNeedsTheCamera() -> Bool {
        if ContinuousVisionManager.shared.isRunning { return true }
        if GeminiLiveService.activeInstance != nil { return true }
        return false
    }

    // MARK: - Gate two, then caption

    private func consider(_ frame: UIImage) async {
        if let fp = featurePrint(frame) {
            // BUILD 132: compare against every scene from the last two hours,
            // not just the one immediately before. Glancing away and back no
            // longer makes the same desk a "new" scene.
            recentPrints.removeAll { Date().timeIntervalSince($0.at) > 7200 }
            for prev in recentPrints {
                var distance = Float(0)
                try? prev.print.computeDistance(&distance, to: fp)
                if distance < sameSceneDistance {
                    print(String(format: "📸 [Pulse] same scene (%.1f) — no call", distance))
                    return
                }
            }
            recentPrints.append((fp, Date()))
            if recentPrints.count > 8 { recentPrints.removeFirst() }
            lastPrint = fp
        }

        guard let text = await caption(frame), !text.isEmpty else { return }

        // BUILD 132: the same SENTENCE inside two days is the same memory,
        // whatever the pixels did. One "hand holding smartphone in bed" is
        // an observation; five are a bug report.
        let norm = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        recentCaptions.removeAll { Date().timeIntervalSince($0.at) > 172_800 }
        if recentCaptions.contains(where: { $0.text == norm }) {
            print("📸 [Pulse] same caption — not filing twice")
            return
        }
        recentCaptions.append((norm, Date()))
        if recentCaptions.count > 40 { recentCaptions.removeFirst() }

        captionsToday += 1
        spentTodayUSD += usdPerCaption
        lastCaption = text
        CostMeter.shared.addQuickVision()

        // Pulse frames are ambient, not deliberate — they expire so a month of
        // them cannot bloat the store. Anything he pins survives.
        _ = ChappyMemory.shared.remember(
            .note,
            title: text,
            tags: ["pulse"],
            thumbnail: frame.jpegData(compressionQuality: 0.4),
            expiresInDays: 45,
            source: "pulse")
        persistCounters()
        print("📸 [Pulse] \(text)")
    }

    private func featurePrint(_ image: UIImage) -> VNFeaturePrintObservation? {
        guard let cg = image.cgImage else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        return req.results?.first as? VNFeaturePrintObservation
    }

    // MARK: - Captioning
    //
    // THE ONLY PLACE THAT SPENDS MONEY.

    private func caption(_ image: UIImage) async -> String? {
        guard let key = APIKeyManager.shared.getGoogleAPIKey(), !key.isEmpty else { return nil }
        // Small on purpose: a caption does not need pixels, and image tokens
        // scale with resolution.
        guard let jpeg = downscaled(image, to: 512).jpegData(compressionQuality: 0.5),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent?key=\(key)")
        else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [
                ["text": Self.captionPrompt],
                ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
            ]]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 60]
        ] as [String: Any])

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = json["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let t = parts.first?["text"] as? String
        else { print("📸 [Pulse] caption failed"); return nil }

        var clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // The model is told to say NOTHING for a worthless frame. Honour it.
        if clean.uppercased().hasPrefix("NOTHING") { return nil }
        // BUILD 132 — SANITATION. "Word Count & Style Check:**" made it into
        // the wearer's memory as a treasured moment. Strip markdown noise,
        // and reject anything that reads as the model talking about its
        // OUTPUT rather than the world in front of the camera.
        clean = clean
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let junk = ["word count", "style check", "caption:", "response:",
                    "here is", "here's a", "as an ai", "i cannot", "i can't see"]
        let lower = clean.lowercased()
        if clean.isEmpty || clean.hasSuffix(":") || junk.contains(where: { lower.contains($0) }) {
            print("📸 [Pulse] junk caption rejected: \(clean)")
            return nil
        }
        if clean.count > 120 { clean = String(clean.prefix(120)) }
        return clean
    }

    private static let captionPrompt = """
    One short line describing what is in front of the wearer — what the place is, any \
    business name or sign you can read, and anything notable. Under 15 words. No preamble, \
    no "the image shows".

    If the frame is a blur, the inside of a pocket, a plain wall, the sky, an empty road, \
    the wearer's own phone screen, a hand holding a phone, a screen glowing in a dark room, \
    someone lying in bed, or anything else with no value as a memory, reply with exactly: NOTHING

    Most frames OUTDOORS and in new places are worth remembering. Blurry, dark, empty ones — \
    and the wearer looking at their own devices — are not.
    """

    private func downscaled(_ image: UIImage, to maxSide: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        guard max(w, h) > maxSide else { return image }
        let scale = maxSide / max(w, h)
        let size = CGSize(width: w * scale, height: h * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Counters

    private func rollDayIfNeeded() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        guard d.string(forKey: Key.day) != today else { return }
        d.set(today, forKey: Key.day)
        framesToday = 0; captionsToday = 0; spentTodayUSD = 0
        persistCounters()
    }

    private func persistCounters() {
        d.set(framesToday, forKey: Key.frames)
        d.set(captionsToday, forKey: Key.captions)
        d.set(spentTodayUSD, forKey: Key.spent)
    }

    private func load() {
        tier = Tier(rawValue: d.string(forKey: Key.tier) ?? "off") ?? .off
        framesToday = d.integer(forKey: Key.frames)
        captionsToday = d.integer(forKey: Key.captions)
        spentTodayUSD = d.double(forKey: Key.spent)
        boostUntil = d.object(forKey: Key.boost) as? Date
    }

    /// One line for the settings chip and for "what have I spent".
    func statusLine() -> String {
        guard tier != .off else { return "Ambient memory off." }
        let cents = String(format: "%.1f", spentTodayUSD * 100)
        let boost = boostUntil.map { b in
            " Boosted for another \(max(0, Int(b.timeIntervalSinceNow / 60))) min."
        } ?? ""
        return "\(tier.label). \(captionsToday) kept from \(framesToday) looks today, \(cents)c.\(boost)"
    }
}
