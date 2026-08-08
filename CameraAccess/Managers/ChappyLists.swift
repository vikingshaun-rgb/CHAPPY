/*
 * ChappyLists — shopping lists that know where you are
 *
 * ADDITIVE FILE. Overwrites nothing.
 *
 * ── THE ONE DESIGN DECISION THAT MATTERS ───────────────────────────────
 * "Fuel, milk, tissues and water from the corner store" is ONE list with four
 * items, not four reminders. Built as four reminders you get four pings, which
 * is worse than no feature at all. So: one list, one geofence, one ping
 * carrying every outstanding item.
 *
 * ── WHY EventKit AND NOT A PRIVATE STORE ───────────────────────────────
 * A list lives in iCloud Reminders as a real EKCalendar with real EKReminders
 * in it. More work than a JSON file in Documents, and it buys three things a
 * private store never can:
 *
 *   Sharing.    He shares the list from Apple Reminders and his wife ticks
 *               items off her own phone. No account system to build.
 *   Survival.   Delete Chappy and the list is still there. It is her data too.
 *   Ubiquity.   It shows in Reminders, Siri, the Watch, the Mac.
 *
 * ── WHY THE GEOFENCING IS OURS AND NOT EKAlarm's ───────────────────────
 * EventKit will happily attach a location alarm to a reminder. Attach one to
 * each of four items and iOS fires four notifications as you walk through the
 * door. There is no EventKit concept of "alert once for this group". So items
 * live in EventKit, where they sync and share, and the geofence is ours.
 *
 * ── PERMISSIONS ────────────────────────────────────────────────────────
 * Reminders access requires NSRemindersFullAccessUsageDescription in the
 * Info.plist. Without it this does not throw — the process is terminated by
 * TCC, and `try?` cannot save you.
 *
 * Region monitoring in the background needs Always location. WhenInUse only
 * fires while the app is foregrounded, which for a pocketed phone means never.
 * Always is requested once, when the first located list is made — not at
 * launch, where it reads as a shakedown.
 */

import Foundation
import EventKit
import CoreLocation
import UserNotifications
import MapKit

// MARK: -

@MainActor
final class ChappyLists: NSObject, ObservableObject {
    static let shared = ChappyLists()

    private let store = EKEventStore()
    private let geoManager = CLLocationManager()

    /// iOS allows 20 monitored regions per app across the whole process.
    /// Nav and anything else may want some, so lists take a slice.
    private let maxRegions = 12
    /// Per-list share of that slice, so three lists can coexist.
    private let maxRegionsPerList = 4
    private let regionRadius: CLLocationDistance = 160

    /// Don't re-ping the same list inside this window.
    private let repingCooldown: TimeInterval = 3 * 3600

    @Published private(set) var lists: [Listing] = []

    // MARK: - Model

    struct Listing: Codable, Identifiable {
        var id: String                  // EKCalendar identifier
        var name: String                // "Corner store"
        var placeHint: String
        var categories: [String]        // MKPointOfInterestCategory raw values
        var createdAt: Date
        var lastPingedAt: Date?
    }

    private enum Key {
        static let lists = "chappy_lists_meta"
    }

    private override init() {
        super.init()
        loadMeta()
        geoManager.delegate = self
        geoManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Call once at launch. Re-arms geofences and starts watching for the
    /// wearer moving somewhere new.
    ///
    /// AUDIT FIX: without this, nothing ever constructed ChappyLists at
    /// startup, so after any relaunch the CLLocationManager delegate was never
    /// set and every geofence in the app was silently dead until he happened
    /// to add another item.
    func startAtLaunch() {
        geoManager.startMonitoringSignificantLocationChanges()
        Task { await rescanAll() }
        print("📍 [Lists] launched with \(lists.count) list(s)")
    }

    // MARK: - Access

    func requestAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            return (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            return await withCheckedContinuation { c in
                store.requestAccess(to: .reminder) { ok, _ in c.resume(returning: ok) }
            }
        }
    }

    // MARK: - Creating a list

    /// Create (or top up) a named list and add items. Returns a spoken line.
    @discardableResult
    func addItems(_ items: [String], toListNamed name: String, placeHint: String) async -> String {
        let clean = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clean.isEmpty else { return "Nothing to add." }

        guard await requestAccess() else {
            return "I need access to Reminders before I can keep lists."
        }
        guard let cal = calendar(named: name) else {
            return "Couldn't create that list."
        }

        for item in clean {
            let r = EKReminder(eventStore: store)
            r.title = item
            r.calendar = cal
            r.isCompleted = false
            // Deliberately NO EKAlarm — see the header.
            try? store.save(r, commit: false)
        }
        try? store.commit()

        var listing = lists.first(where: { $0.id == cal.calendarIdentifier })
            ?? Listing(id: cal.calendarIdentifier,
                       name: name,
                       placeHint: placeHint,
                       categories: Self.categories(for: placeHint, items: clean),
                       createdAt: Date(),
                       lastPingedAt: nil)
        listing.placeHint = placeHint
        listing.categories = Self.categories(for: placeHint, items: clean)
        upsert(listing)

        let armed = await refreshRegions(for: listing)

        // AUDIT FIX: this used to promise a nudge unconditionally. If the
        // region budget was spent, or there were no matching shops nearby, or
        // Always location had been declined, no geofence existed and the
        // promise was a straight lie. Say what actually happened.
        let itemText = spokenJoin(clean)
        return armed > 0
            ? "\(name) list — \(itemText). I'll nudge you when you're near one."
            : "\(name) list — \(itemText). Ask me for it when you're out; I can't watch for a shop just now."
    }

    private func calendar(named name: String) -> EKCalendar? {
        if let existing = store.calendars(for: .reminder).first(where: {
            $0.title.caseInsensitiveCompare(name) == .orderedSame
        }) { return existing }

        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = name
        // Must live on a source that accepts reminders — iCloud where possible
        // so it syncs and can be shared, local as a fallback.
        cal.source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local })
        guard (try? store.saveCalendar(cal, commit: true)) != nil else { return nil }
        return cal
    }

    // MARK: - Reading and ticking

    func openItems(listID: String) async -> [EKReminder] {
        guard let cal = store.calendars(for: .reminder)
            .first(where: { $0.calendarIdentifier == listID }) else { return [] }
        let pred = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: [cal])
        return await withCheckedContinuation { c in
            store.fetchReminders(matching: pred) { c.resume(returning: $0 ?? []) }
        }
    }

    func spokenSummary() async -> String {
        guard await requestAccess() else { return "No access to Reminders." }
        var parts: [String] = []
        for l in lists {
            let items = await openItems(listID: l.id).compactMap(\.title)
            if !items.isEmpty { parts.append("\(l.name): \(spokenJoin(items))") }
        }
        return parts.isEmpty ? "Nothing on your lists." : parts.joined(separator: ". ")
    }

    /// Tick items off by name across every list. Fuzzy on purpose — "milk"
    /// should find "2L milk".
    ///
    /// AUDIT FIX: an untitled reminder produced title == "", and
    /// `spokenWord.contains("")` is always true, so a single "tick off milk"
    /// silently completed every untitled item on every list. Both sides are
    /// now length-guarded.
    @discardableResult
    func complete(_ names: [String]) async -> String {
        guard await requestAccess() else { return "No access to Reminders." }
        let wanted = names
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 1 }
        guard !wanted.isEmpty else { return "Which items?" }

        var done: [String] = []
        for l in lists {
            for item in await openItems(listID: l.id) {
                guard let raw = item.title?.lowercased(), raw.count > 1 else { continue }
                let hit = wanted.contains { raw.contains($0) || $0.contains(raw) }
                if hit {
                    item.isCompleted = true
                    if (try? store.save(item, commit: false)) != nil {
                        done.append(item.title ?? "")
                    }
                }
            }
        }
        try? store.commit()
        guard !done.isEmpty else { return "Couldn't find that on your lists." }

        var remaining: [String] = []
        for l in lists { remaining += await openItems(listID: l.id).compactMap(\.title) }
        if remaining.isEmpty { return "Ticked off. That's the lot." }
        return "Ticked off. \(remaining.count) left — \(spokenJoin(remaining))."
    }

    // MARK: - Geofencing

    /// Find shops of the right kind nearby and monitor them.
    /// Returns how many regions were actually armed — callers must not promise
    /// a nudge unless this is greater than zero.
    @discardableResult
    private func refreshRegions(for listing: Listing) async -> Int {
        requestAlwaysIfNeeded()

        // AUDIT FIX: stop the old regions FIRST. This used to sit below the
        // empty-shops guard, so re-scanning somewhere with no matching shops
        // left the previous city's geofences armed — pinging him about a
        // Melbourne list while standing in Bali.
        stopMonitoring(listID: listing.id)

        guard let lat = ContextEngine.shared.snapshot.latitude,
              let lon = ContextEngine.shared.snapshot.longitude else { return 0 }
        let centre = CLLocationCoordinate2D(latitude: lat, longitude: lon)

        let shops = await nearbyShops(categories: listing.categories, around: centre)
        guard !shops.isEmpty else {
            print("📍 [Lists] no matching shops near \(listing.name)")
            return 0
        }

        // AUDIT FIX: budget was computed against the app-wide monitoredRegions
        // count but subtracted from a lists-only ceiling, so two existing lists
        // could silently take it to zero while the wearer was still told
        // "I'll nudge you". Count only OUR regions, and cap per list.
        let mine = geoManager.monitoredRegions.filter { $0.identifier.hasPrefix("chappylist|") }.count
        let budget = max(0, maxRegions - mine)
        let n = min(maxRegionsPerList, budget, shops.count)
        guard n > 0 else {
            print("📍 [Lists] region budget spent — no geofence for \(listing.name)")
            return 0
        }

        for (i, shop) in shops.prefix(n).enumerated() {
            let region = CLCircularRegion(center: shop.coord,
                                          radius: regionRadius,
                                          identifier: "chappylist|\(listing.id)|\(i)")
            region.notifyOnEntry = true
            region.notifyOnExit = false
            geoManager.startMonitoring(for: region)
        }
        print("📍 [Lists] monitoring \(n) shop(s) for \(listing.name)")
        return n
    }

    private struct Shop { let coord: CLLocationCoordinate2D; let name: String }

    private func nearbyShops(categories: [String],
                             around centre: CLLocationCoordinate2D) async -> [Shop] {
        let req = MKLocalPointsOfInterestRequest(center: centre, radius: 8000)
        let known = Set(Self.knownCategories.map(\.rawValue))
        let cats = categories
            .filter { known.contains($0) }
            .map { MKPointOfInterestCategory(rawValue: $0) }
        if !cats.isEmpty {
            req.pointOfInterestFilter = MKPointOfInterestFilter(including: cats)
        }
        guard let resp = try? await MKLocalSearch(request: req).start() else { return [] }

        let origin = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        return resp.mapItems
            .compactMap { item -> (Shop, Double)? in
                let c = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(c) else { return nil }
                let d = origin.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                return (Shop(coord: c, name: item.name ?? "shop"), d)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func stopMonitoring(listID: String) {
        for r in geoManager.monitoredRegions where r.identifier.hasPrefix("chappylist|\(listID)|") {
            geoManager.stopMonitoring(for: r)
        }
    }

    private func requestAlwaysIfNeeded() {
        switch geoManager.authorizationStatus {
        case .authorizedWhenInUse: geoManager.requestAlwaysAuthorization()
        case .notDetermined:       geoManager.requestWhenInUseAuthorization()
        default:                   break
        }
    }

    /// Re-scan when the wearer has genuinely moved, and drop geofences for
    /// lists that have been fully ticked off.
    func rescanAll() async {
        for l in lists {
            if (await openItems(listID: l.id)).isEmpty { stopMonitoring(listID: l.id) }
            else { _ = await refreshRegions(for: l) }
        }
    }

    // MARK: - Firing

    fileprivate func handleEntry(regionID: String) {
        let parts = regionID.split(separator: "|")
        guard parts.count >= 2 else { return }
        let listID = String(parts[1])
        guard let listing = lists.first(where: { $0.id == listID }) else { return }

        // Cooldown is per LIST, not per shop — walking past three servos in a
        // row must not produce three notifications.
        if let last = listing.lastPingedAt,
           Date().timeIntervalSince(last) < repingCooldown {
            print("📍 [Lists] \(listing.name) still cooling down")
            return
        }

        Task { @MainActor in
            let items = await openItems(listID: listID).compactMap(\.title)
            guard !items.isEmpty else {
                stopMonitoring(listID: listID)   // all ticked; stop watching
                return
            }
            var updated = listing
            updated.lastPingedAt = Date()
            upsert(updated)

            notify(title: listing.name, body: spokenJoin(items))
            ChappyHaptics.shared.proximity()
        }
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.userInfo = ["chappy_list": true]
        if #available(iOS 15.0, *) { c.interruptionLevel = .timeSensitive }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "chappy-list-\(Int(Date().timeIntervalSince1970))",
                                  content: c, trigger: nil))
        print("📍 [Lists] pinged \(title): \(body)")
    }

    // MARK: - Category mapping

    static let knownCategories: [MKPointOfInterestCategory] =
        [.foodMarket, .store, .gasStation, .pharmacy]

    /// Map what he said — and what he's buying — onto Apple's POI categories.
    /// Generous on purpose: an Australian servo sells milk and tissues, so
    /// "corner store" should match one.
    static func categories(for hint: String, items: [String]) -> [String] {
        let h = (hint + " " + items.joined(separator: " ")).lowercased()
        var out: Set<MKPointOfInterestCategory> = []

        let grocery = ["corner store", "shop", "store", "supermarket", "grocer",
                       "woolies", "woolworths", "coles", "aldi", "iga", "milk",
                       "bread", "tissues", "water", "food", "snacks", "deli"]
        let fuel     = ["fuel", "petrol", "servo", "gas", "diesel", "bp", "shell",
                        "caltex", "ampol", "7-eleven", "seven eleven"]
        let pharmacy = ["chemist", "pharmacy", "panadol", "medicine", "script",
                        "prescription", "bandaid", "sunscreen"]
        let hardware = ["bunnings", "hardware", "screws", "timber", "paint", "tools"]

        if grocery.contains(where: { h.contains($0) })  { out.insert(.foodMarket); out.insert(.store) }
        if fuel.contains(where: { h.contains($0) })     { out.insert(.gasStation) }
        if pharmacy.contains(where: { h.contains($0) }) { out.insert(.pharmacy) }
        if hardware.contains(where: { h.contains($0) }) { out.insert(.store) }

        if out.isEmpty { out.insert(.store); out.insert(.foodMarket) }
        return out.map(\.rawValue)
    }

    // MARK: - Speech helper

    /// "fuel, milk, tissues and water" — never "…tissues, water".
    private func spokenJoin(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    // MARK: - Persistence

    private func upsert(_ l: Listing) {
        if let i = lists.firstIndex(where: { $0.id == l.id }) { lists[i] = l }
        else { lists.append(l) }
        saveMeta()
    }

    private func saveMeta() {
        guard let data = try? JSONEncoder().encode(lists) else { return }
        UserDefaults.standard.set(data, forKey: Key.lists)
    }

    private func loadMeta() {
        guard let data = UserDefaults.standard.data(forKey: Key.lists),
              let decoded = try? JSONDecoder().decode([Listing].self, from: data) else { return }
        lists = decoded
    }

    /// Lists currently armed with a geofence — the proactive pass needs these
    /// so it never mentions a list that is going to ping on its own.
    func selfAlertingListNames() -> [String] {
        let armed = Set(geoManager.monitoredRegions
            .filter { $0.identifier.hasPrefix("chappylist|") }
            .compactMap { $0.identifier.split(separator: "|").dropFirst().first.map(String.init) })
        return lists.filter { armed.contains($0.id) }.map(\.name)
    }
}

// MARK: - Location delegate

extension ChappyLists: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        guard id.hasPrefix("chappylist|") else { return }
        Task { @MainActor in self.handleEntry(regionID: id) }
    }

    /// AUDIT FIX: was the iOS 13 `didChangeAuthorization:` form, deprecated
    /// since iOS 14 and inconsistent with ContextEngine, which already uses
    /// this one.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status == .authorizedAlways else { return }
        Task { @MainActor in await self.rescanAll() }
    }

    /// He's moved somewhere new — the shops worth watching have changed.
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in await self.rescanAll() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     monitoringDidFailFor region: CLRegion?,
                                     withError error: Error) {
        print("📍 [Lists] monitoring failed for \(region?.identifier ?? "—"): \(error.localizedDescription)")
    }
}
