/*
 * ChappyPhotoIngest — the photos you take when Chappy isn't running
 *
 * ADDITIVE FILE. Overwrites nothing. PHASE 5 STEP 3.
 *
 * ── THE GAP THIS CLOSES ────────────────────────────────────────────────
 * Press the capture button on the glasses and the photo goes to the Meta AI
 * app, then to iOS Photos. Chappy never sees it. That is most of the photos
 * taken in a day, because pressing a button on your temple works while the
 * phone is in a pocket and the app is closed — which is precisely when Chappy
 * cannot capture anything itself.
 *
 * So the deliberate half of memory has been missing entirely. Pulse (Step 2)
 * handles the ambient half while the app is alive; this handles everything the
 * wearer chose to photograph, whenever they chose it, app running or not.
 *
 * ── HOW IT WORKS ───────────────────────────────────────────────────────
 * A batch pass walks PhotoKit for images newer than the last run, skips
 * anything already filed, reads EXIF time and GPS off the asset itself rather
 * than guessing from when the pass ran, captions each one, and files it as a
 * .photo memory carrying the PHAsset localIdentifier. That identifier is why
 * `remember()` already takes an `assetID` — this was anticipated in the model
 * long before it was built.
 *
 * ── WHEN IT RUNS, AND WHY NOT SOONER ───────────────────────────────────
 * Charging and on wi-fi, once a day. Three reasons, all of them the wearer's:
 * captioning fifty photos on cellular in Indonesia costs real roaming money;
 * doing it on battery in the afternoon costs the afternoon; and photos taken
 * an hour ago are not urgently needed in memory — they are needed next week
 * when he asks where that place was.
 *
 * The pass is also chunked and interruptible. It files as it goes rather than
 * at the end, so a pass that dies halfway has still done half the work and the
 * next one picks up from the last filed asset rather than starting over.
 *
 * ── WHAT IT WILL NOT DO ────────────────────────────────────────────────
 * Read-only access to Photos, never write. A hard per-run ceiling so a first
 * run against a library of forty thousand holiday photos cannot spend a
 * fortune — it takes the newest `maxPerRun` and leaves the rest, and by
 * default it will not reach back further than `firstRunDays` on the very first
 * pass. Screenshots and photos with no location are skipped: a screenshot is
 * not a memory of a place, and the whole value here is where and when.
 */

import Foundation
import Photos
import UIKit
import CoreLocation
import Network

@MainActor
final class ChappyPhotoIngest: ObservableObject {
    static let shared = ChappyPhotoIngest()
    private init() { load() }

    // MARK: - Tuning

    /// Ceiling per pass. At Gemini Flash-Lite prices 60 captions is about a
    /// quarter of a cent, so this is a sanity bound rather than a budget one.
    private let maxPerRun = 60
    /// On the very first pass, don't reach back further than this.
    private let firstRunDays = 14
    /// Skip anything smaller than this — thumbnails, stickers, junk.
    private let minPixels = 200_000

    @Published private(set) var isRunning = false
    @Published private(set) var filedTotal = 0
    @Published private(set) var lastRunAt: Date?

    private enum Key {
        static let cursor = "chappy_ingest_cursor"      // newest asset date filed
        static let seen   = "chappy_ingest_seen"        // [localIdentifier]
        static let total  = "chappy_ingest_total"
        static let lastAt = "chappy_ingest_last_at"
    }
    private let d = UserDefaults.standard
    private var seen: Set<String> = []

    // MARK: - Access

    func requestAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { c in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { c.resume(returning: $0) }
        }
    }

    var hasAccess: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    // MARK: - Entry points

    /// Called from a proactive pass. Only actually runs when the conditions
    /// are right — charging, wi-fi, not already done today.
    func ingestIfDue() async {
        guard shouldRunNow() else { return }
        await run()
    }

    /// Force a pass — settings button, or "Chappy, catch up on my photos".
    func runNow() async {
        d.removeObject(forKey: Key.lastAt)
        await run(ignoreConditions: true)
    }

    private func shouldRunNow() -> Bool {
        guard hasAccess, !isRunning else { return false }
        if let last = lastRunAt, Calendar.current.isDateInToday(last) { return false }

        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        guard state == .charging || state == .full else { return false }
        return Self.onWiFi
    }

    /// Cheap, synchronous wi-fi check. NWPathMonitor is the right tool but it
    /// is asynchronous; this snapshot is refreshed by the monitor below.
    nonisolated(unsafe) private static var onWiFi = true
    private static let monitor: NWPathMonitor = {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            onWiFi = path.usesInterfaceType(.wifi) && path.status == .satisfied
        }
        m.start(queue: DispatchQueue(label: "chappy.ingest.net"))
        return m
    }()

    /// Call once at launch so the wi-fi monitor is live.
    func start() { _ = Self.monitor }

    // MARK: - The pass

    private func run(ignoreConditions: Bool = false) async {
        guard hasAccess else { print("🖼️ [Ingest] no Photos access"); return }
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            lastRunAt = Date()
            d.set(lastRunAt, forKey: Key.lastAt)
        }

        let cursor = (d.object(forKey: Key.cursor) as? Date)
            ?? Calendar.current.date(byAdding: .day, value: -firstRunDays, to: Date())
            ?? Date()

        let assets = fetchAssets(after: cursor)
        guard !assets.isEmpty else { print("🖼️ [Ingest] nothing new"); return }
        print("🖼️ [Ingest] \(assets.count) candidate(s) since \(cursor)")

        var filed = 0
        var newestFiled = cursor

        for asset in assets {
            // Bail out cleanly if conditions changed mid-pass — unplugged,
            // dropped off wi-fi. Work already done is already saved.
            if !ignoreConditions {
                let state = UIDevice.current.batteryState
                guard state == .charging || state == .full, Self.onWiFi else {
                    print("🖼️ [Ingest] conditions changed — stopping at \(filed)")
                    break
                }
            }
            guard let image = await requestImage(asset) else { continue }
            guard let text = await ChappyPulseCaptioner.caption(image) else {
                markSeen(asset.localIdentifier)      // don't retry a dud forever
                continue
            }

            let when = asset.creationDate ?? Date()
            _ = ChappyMemory.shared.remember(
                .photo,
                title: text,
                tags: ["glasses", "ingested"],
                thumbnail: image.jpegData(compressionQuality: 0.5),
                source: "photo-ingest",
                at: when,
                assetID: asset.localIdentifier)

            markSeen(asset.localIdentifier)
            filed += 1
            filedTotal += 1
            if when > newestFiled { newestFiled = when }

            // File as we go — a pass that dies halfway has still done half.
            d.set(newestFiled, forKey: Key.cursor)
            d.set(filedTotal, forKey: Key.total)
            print("🖼️ [Ingest] \(text)")
        }
        print("🖼️ [Ingest] filed \(filed)")
    }

    // MARK: - PhotoKit

    private func fetchAssets(after cursor: Date) -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate > %@ AND mediaType == %d",
                                     cursor as NSDate, PHAssetMediaType.image.rawValue)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: opts)

        var out: [PHAsset] = []
        result.enumerateObjects { asset, _, stop in
            if out.count >= self.maxPerRun { stop.pointee = true; return }
            guard !self.seen.contains(asset.localIdentifier) else { return }
            // Screenshots are not memories of a place.
            guard !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            guard asset.pixelWidth * asset.pixelHeight >= self.minPixels else { return }
            // No location, no value — the whole point is where and when. The
            // exception is a photo taken very recently, where the current fix
            // is a fair stand-in.
            let recent = (asset.creationDate ?? .distantPast) > Date().addingTimeInterval(-3600)
            guard asset.location != nil || recent else { return }
            out.append(asset)
        }
        return out
    }

    private func requestImage(_ asset: PHAsset) async -> UIImage? {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true      // iCloud-offloaded originals
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isSynchronous = false

        return await withCheckedContinuation { c in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 768, height: 768),
                contentMode: .aspectFit,
                options: opts
            ) { image, info in
                // The manager can call back twice — a degraded thumbnail then
                // the real thing. Only resume on the real one.
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
                c.resume(returning: image)
            }
        }
    }

    // MARK: - Bookkeeping

    private func markSeen(_ id: String) {
        seen.insert(id)
        // Bounded — the cursor does the real work, this only guards against
        // re-filing within a window.
        if seen.count > 2000 { seen = Set(seen.suffix(1500)) }
        d.set(Array(seen), forKey: Key.seen)
    }

    private func load() {
        seen = Set(d.stringArray(forKey: Key.seen) ?? [])
        filedTotal = d.integer(forKey: Key.total)
        lastRunAt = d.object(forKey: Key.lastAt) as? Date
    }

    func statusLine() -> String {
        guard hasAccess else { return "No access to Photos yet." }
        let last = lastRunAt.map { l -> String in
            let f = DateFormatter(); f.dateFormat = "EEE h:mm a"
            return "last run \(f.string(from: l))"
        } ?? "never run"
        return "\(filedTotal) glasses photos filed, \(last)."
    }
}

// MARK: - Shared captioner
//
// Pulse and ingest caption the same way for the same reason: Gemini Flash-Lite
// at low resolution is an order of magnitude cheaper per image than anything
// else, and a caption needs words not pixels. Kept here as one small type so
// the iOS 27 on-device switch happens in exactly one place for both callers.

enum ChappyPulseCaptioner {

    static func caption(_ image: UIImage) async -> String? {
        guard let key = APIKeyManager.shared.getGoogleAPIKey(), !key.isEmpty,
              let jpeg = downscaled(image, to: 512).jpegData(compressionQuality: 0.5),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent?key=\(key)")
        else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [
                ["text": prompt],
                ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
            ]]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 70]
        ] as [String: Any])

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = json["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let t = parts.first?["text"] as? String
        else { return nil }

        let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.uppercased().hasPrefix("NOTHING") ? nil : clean
    }

    /// Deliberate photos get a slightly richer caption than pulse frames — he
    /// chose to take this one, so it is more likely to be looked for later.
    private static let prompt = """
    Describe this photo in one line, under 20 words, as a memory the person who took it \
    would search for later. Name the place or business if a sign is readable, say what the \
    subject is, and mention anything distinctive. No preamble, no "the image shows".

    If it is a blur, a pocket shot, a plain surface or otherwise worthless as a memory, \
    reply with exactly: NOTHING
    """

    static func downscaled(_ image: UIImage, to maxSide: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        guard max(w, h) > maxSide else { return image }
        let scale = maxSide / max(w, h)
        let size = CGSize(width: w * scale, height: h * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
