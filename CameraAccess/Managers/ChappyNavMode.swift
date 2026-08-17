/*
 * ChappyNavMode — distance-aware travel mode selection
 *
 * ADDITIVE FILE. Adds no members to NavEngine and overwrites nothing.
 * Everything here talks to NavEngine through its internal public surface
 * (navigate(to:driving:), spokenRouteSummary, isNavigating), so it drops into
 * any build of the project without touching LiveAIManager.
 *
 * ── THE PROBLEM THIS SOLVES ────────────────────────────────────────────
 * Travel mode was decided in five separate places in route(), each by
 * keyword-matching the utterance, and none of them measured distance. Say
 * "take me to the airport" with no mode word in the sentence and every one of
 * those sites defaulted to driving:false — a 140-minute walking route. Google
 * Maps then opened in walking mode because lastDriving was false.
 *
 * ── THE RULE ───────────────────────────────────────────────────────────
 *   Explicit words in the sentence always win     ("drive me", "on foot")
 *   Already moving in a vehicle       → drive     (don't ask a man in a car)
 *   Over 5 km                         → drive
 *   Under 1 km                        → walk
 *   1–5 km, on foot or still          → ASK ONCE
 *
 * ── WHY THE PROBE IS MapKit, NOT PLACES ────────────────────────────────
 * NavEngine.navigate() already does a Google Places Text Search to resolve the
 * destination. Places bills ~$0.032 per call, so probing with Places and then
 * letting NavEngine probe again would double the cost of every navigation
 * command. MKLocalSearch is free and easily accurate enough for the only
 * question being asked here — 500 metres or 15 kilometres. Places is kept as
 * the fallback for places Apple has never heard of, which matters in Asia.
 *
 * AUDIT FIX: saved spots are now checked FIRST, before any network probe.
 * NavEngine resolves TripRecorder spots ahead of Places, so probing MapKit for
 * the raw words meant a saved pin called "the villa" was measured against
 * whatever MapKit thought "the villa" was — often nothing, or somewhere across
 * town — and the mode was decided from a distance to the wrong place entirely.
 */

import Foundation
import CoreLocation
import MapKit

// MARK: - Decision type

enum ChappyNavDecision {
    /// Route started. Payload is the model-facing summary; prefer
    /// NavEngine.shared.spokenRouteSummary when speaking to a human.
    case route(String)
    /// 1–5 km with no mode signal. Payload: (destination to remember, question).
    case ask(String, String)
    /// Nothing found, or no route. Payload is a human-speakable reason.
    case failed(String)
}

// MARK: -

@MainActor
enum ChappyNavMode {

    private static let alwaysDrive = 5000.0   // metres
    private static let alwaysWalk  = 1000.0

    /// Resolve travel mode from distance + utterance, then start the route.
    ///
    /// - Parameters:
    ///   - destination: the cleaned place name, openers already stripped.
    ///   - utterance: the full original sentence, used only to spot explicit
    ///     mode words. Pass the raw command, not the destination.
    static func go(to destination: String, utterance: String) async -> ChappyNavDecision {
        let clean = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .failed("I didn't catch where to.") }

        let snap = ContextEngine.shared.snapshot
        guard let lat = snap.latitude, let lon = snap.longitude else {
            return .failed("No GPS fix yet — give it a few seconds.")
        }
        let here = CLLocation(latitude: lat, longitude: lon)

        // ── 1. Explicit mode words beat everything ──────────────────────
        if let explicit = explicitMode(in: utterance.lowercased()) {
            return await start(clean, driving: explicit)
        }

        // ── 2. Already in a vehicle ─────────────────────────────────────
        if snap.motion == "in a vehicle" {
            print("🗺️ [NavMode] motion=vehicle → driving, no probe")
            return await start(clean, driving: true)
        }

        // ── 3. Distance probe ───────────────────────────────────────────
        guard let probe = await probeDistance(query: clean, from: here) else {
            // Couldn't measure. Bias to driving rather than silently walking
            // someone to an airport: a driving route for a 400 m stroll is a
            // mild annoyance, a walking route to somewhere 40 km away is
            // useless and takes a while to notice.
            print("🗺️ [NavMode] probe failed for '\(clean)' → driving fallback")
            return await start(clean, driving: true)
        }

        let km = probe.metres / 1000
        print(String(format: "🗺️ [NavMode] '%@' → %@ at %.2f km", clean, probe.name, km))

        // ── 4. Distance decides ─────────────────────────────────────────
        if probe.metres > alwaysDrive { return await start(clean, driving: true)  }
        if probe.metres < alwaysWalk  { return await start(clean, driving: false) }

        // ── 5. The ambiguous band ───────────────────────────────────────
        let distText = String(format: "%.1f", km) + " kilometres"
        return .ask(clean, "\(probe.name) is about \(distText) away. Walk or drive?")
    }

    /// BUILD 257 — THE SAME WALK-OR-DRIVE DECISION, WITHOUT STARTING A ROUTE.
    ///
    /// The leave-by clock needs to know how he will travel, and it was
    /// asking `travelMinutes(to:)` which defaults to driving. So a leave-by
    /// for somewhere ten minutes' walk away was computed at car speed —
    /// about three minutes — and he was told to leave seven minutes too
    /// late, every time, for the short trips where being late is easiest.
    ///
    /// Deliberately the SAME thresholds and the same probe as go() rather
    /// than a second opinion: if the leave-by says walk and the route then
    /// drives, the number he was given was for a journey he did not make.
    /// It reads live motion and distance only — it does NOT remember what he
    /// chose last time, and an earlier version of this comment claimed it
    /// did. Nothing in this file consults NavEngine.lastDriving.
    ///
    /// CALLERS MUST CACHE. On a destination that is not a saved spot this
    /// falls through MapKit to a billed Places search — see the cost note at
    /// the top of the file — so calling it on a timer is expensive.
    /// The ambiguous band drives here, because go() only asks the question
    /// when he is standing there ready to answer it — a leave-by warning has
    /// nobody to ask, and being early is the safe direction.
    static func likelyDriving(to destination: String) async -> Bool {
        let clean = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return true }
        let snap = ContextEngine.shared.snapshot
        guard let lat = snap.latitude, let lon = snap.longitude else { return true }
        if snap.motion == "in a vehicle" { return true }
        guard let probe = await probeDistance(query: clean,
                                              from: CLLocation(latitude: lat, longitude: lon))
        else { return true }
        return probe.metres >= alwaysWalk
    }

    /// Resolve an answer to the walk-or-drive question and route.
    /// Anything ambiguous drives — see the note in go().
    static func answerMode(_ reply: String, destination: String) async -> ChappyNavDecision {
        let r = reply.lowercased()
        let walk = r.contains("walk") || r.contains("foot") || r.contains("stroll")
        return await start(destination, driving: !walk)
    }

    // MARK: - Explicit mode detection

    /// true = drive, false = walk, nil = the sentence says nothing.
    /// Anchored phrases only: a bare " car" must not force driving on
    /// "walk me to the car rental place".
    private static func explicitMode(in u: String) -> Bool? {
        let driveWords = ["drive me", "drive us", "driving to", "by car", "via car",
                          "in the car", "by taxi", "by grab", "by uber", "by scooter",
                          "on the scooter", "by motorbike", "by bike", "by motorcycle",
                          "take the car", "we're driving", "were driving"]
        let walkWords  = ["walk me", "walk us", "on foot", "walking there",
                          "walking instead", "let's walk", "lets walk", "i'll walk",
                          "ill walk", "we'll walk", "well walk"]

        // Walk first: "walk me to the car park" contains both cues and he
        // plainly said walk.
        if walkWords.contains(where: { u.contains($0) })  { return false }
        if driveWords.contains(where: { u.contains($0) }) { return true }
        return nil
    }

    // MARK: - Distance probe

    private struct Probe { let metres: Double; let name: String }

    private static func probeDistance(query: String, from here: CLLocation) async -> Probe? {
        // Saved spots first — NavEngine resolves these ahead of everything
        // else, so the mode must be decided against the same place the route
        // will actually go to.
        if let spot = savedSpot(matching: query, from: here) { return spot }
        if let m = await mapKitProbe(query: query, from: here) { return m }
        return await placesProbe(query: query, from: here)
    }

    /// BUILD 257 — CALLS NavEngine's lookup rather than mirroring it.
    ///
    /// The old comment said "mirrors NavEngine's own spot lookup so both
    /// agree on the destination", and the two copies were in fact identical —
    /// but that is exactly the arrangement that produced the flights bug in
    /// 255, where navDestination had openers the router hook did not under a
    /// comment claiming the two lists were the same. Hand-kept copies agree
    /// right up until one of them is edited. Now there is one.
    private static func savedSpot(matching query: String, from here: CLLocation) -> Probe? {
        guard let spot = TripRecorder.savedSpot(matching: query,
                                                nearLat: here.coordinate.latitude,
                                                nearLon: here.coordinate.longitude)
        else { return nil }
        let d = here.distance(from: CLLocation(latitude: spot.lat, longitude: spot.lon))
        print("🗺️ [NavMode] matched saved spot '\(spot.name)'")
        return Probe(metres: d, name: spot.name)
    }

    private static func mapKitProbe(query: String, from here: CLLocation) async -> Probe? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        // 60 km: wide enough to find the airport, tight enough that "IGA"
        // resolves locally rather than in another state.
        req.region = MKCoordinateRegion(center: here.coordinate,
                                        latitudinalMeters: 60_000,
                                        longitudinalMeters: 60_000)
        guard let resp = try? await MKLocalSearch(request: req).start() else { return nil }

        // NEAREST wins, not most relevant. MapKit sorts by relevance, and for
        // a chain like McDonald's the most relevant result is frequently not
        // the closest — which is exactly the bug where asking for the nearest
        // one produced a route across town.
        return resp.mapItems.compactMap { item -> Probe? in
            let c = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(c) else { return nil }
            let d = here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            return Probe(metres: d, name: item.name ?? query)
        }
        .min(by: { $0.metres < $1.metres })
    }

    private static func placesProbe(query: String, from here: CLLocation) async -> Probe? {
        let key = APIKeyManager.shared.getMapsAPIKey() ?? ""
        guard !key.isEmpty,
              let url = URL(string: "https://places.googleapis.com/v1/places:searchText")
        else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue("places.displayName,places.location", forHTTPHeaderField: "X-Goog-FieldMask")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "textQuery": query,
            "locationBias": ["circle": [
                "center": ["latitude": here.coordinate.latitude,
                           "longitude": here.coordinate.longitude],
                "radius": 50_000.0
            ]],
            "maxResultCount": 5
        ] as [String: Any])

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let places = json["places"] as? [[String: Any]]
        else { return nil }

        return places.compactMap { p -> Probe? in
            guard let loc = p["location"] as? [String: Any],
                  let la = loc["latitude"] as? Double,
                  let lo = loc["longitude"] as? Double else { return nil }
            let d = here.distance(from: CLLocation(latitude: la, longitude: lo))
            let n = ((p["displayName"] as? [String: Any])?["text"] as? String) ?? query
            return Probe(metres: d, name: n)
        }
        .min(by: { $0.metres < $1.metres })
    }

    // MARK: - Route start

    /// Hands off to NavEngine, which does its own destination resolution and
    /// route fetch. We only decided the mode.
    private static func start(_ destination: String, driving: Bool) async -> ChappyNavDecision {
        let reply = await NavEngine.shared.navigate(to: destination, driving: driving)
        // NavEngine returns a model-facing string on failure too, so detect
        // failure by whether a route actually started rather than by parsing.
        guard NavEngine.shared.isNavigating else {
            return .failed(ChappyStandby.humanise(reply))
        }
        return .route(reply)
    }
}
