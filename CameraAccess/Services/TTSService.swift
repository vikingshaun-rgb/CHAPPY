/*
 * Text-to-Speech Service
 * Default voice: Gemini TTS (natural, expressive) using the Gemini API key.
 * Fallback: Apple system TTS (free, offline) when no key / no network / error.
 */

import Foundation
import AVFoundation
import NaturalLanguage
import CryptoKit
import Security   // BUILD 175: errSecInteractionNotAllowed
import UIKit      // BUILD 244: UIImpactFeedbackGenerator for the speech taps

/// BUILD 125 — ONE VOICE.
///
/// Build 109 split Chappy's mouth in two: short lines went to Apple's on-device
/// voice because they were instant, long lines went to Gemini because it sounds
/// human. The result was an assistant that changed sex every other sentence —
/// "Saved" in one voice, the answer that followed in another. That is worse
/// than either voice on its own, and it was my doing.
///
/// The fix is not to choose between them. It is to stop paying the network toll
/// twice for the same sentence. Chappy's short lines are a small, finite,
/// repeating set — "Route's off", "Map's up", "Saved", "Having a look". Render
/// each one through Gemini ONCE, keep the audio on disk, and every time after
/// it plays instantly, in the right voice, with no signal at all.
///
/// Raw PCM16 @ 24 kHz is what Gemini hands back and what the playback engine
/// wants, so nothing is transcoded on either side of the cache.
private final class VoiceCache {

    static let shared = VoiceCache()

    /// Total bytes to keep. PCM16 @ 24 kHz is ~48 KB per second, so 60 MB is
    /// roughly twenty minutes of speech — far more than the repeating set ever
    /// needs, and nothing next to a phone full of photos.
    private static let budgetBytes = 60 * 1024 * 1024

    private let dir: URL
    private let io = DispatchQueue(label: "chappy.voice.cache", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("ChappyVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// The voice is part of the key. Change voice in Settings and every line
    /// re-renders in the new one rather than serving the old voice from disk —
    /// which is exactly the flip-flop this whole class exists to end.
    private func filename(text: String, voice: String) -> String {
        let digest = SHA256.hash(data: Data("\(voice)|\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".pcm"
    }

    func url(text: String, voice: String) -> URL {
        dir.appendingPathComponent(filename(text: text, voice: voice))
    }

    func has(text: String, voice: String) -> Bool {
        FileManager.default.fileExists(atPath: url(text: text, voice: voice).path)
    }

    /// Returns cached audio and stamps the file as used, so pruning can be LRU
    /// rather than arbitrary.
    func load(text: String, voice: String) -> Data? {
        let u = url(text: text, voice: voice)
        guard let data = try? Data(contentsOf: u), !data.isEmpty else { return nil }
        io.async {
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                   ofItemAtPath: u.path)
        }
        return data
    }

    func save(_ data: Data, text: String, voice: String) {
        guard !data.isEmpty else { return }
        let u = url(text: text, voice: voice)
        io.async { [weak self] in
            try? data.write(to: u, options: .atomic)
            self?.pruneIfNeeded()
        }
    }

    /// Oldest-used first, down to the budget. Runs on the io queue only.
    private func pruneIfNeeded() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }

        var total = 0
        var entries: [(url: URL, size: Int, used: Date)] = []
        for u in items {
            let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = vals?.fileSize ?? 0
            let used = vals?.contentModificationDate ?? .distantPast
            total += size
            entries.append((u, size, used))
        }
        guard total > Self.budgetBytes else { return }

        for e in entries.sorted(by: { $0.used < $1.used }) {
            try? fm.removeItem(at: e.url)
            total -= e.size
            if total <= Self.budgetBytes { break }
        }
        print("🔊 [VoiceCache] Pruned to \(total / 1024) KB")
    }

    /// Wipe everything — used when the wearer changes voice and wants the disk
    /// back, and by Settings' "clear cached speech".
    func clear() {
        io.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(at: self.dir, includingPropertiesForKeys: nil)) ?? []
            for u in items { try? fm.removeItem(at: u) }
            print("🔊 [VoiceCache] Cleared")
        }
    }

    var fileCount: Int {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).count
    }
}

/// SB-DEADLOCK FIX: a checked continuation resumed twice is an instant crash,
/// and one never resumed is a permanent hang. Both were live in this file. This
/// gate makes "resume exactly once, from whichever thread arrives first" the
/// only possible outcome.
private final class ResumeGate {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?
    private var spent = false

    func arm(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if spent { lock.unlock(); c.resume(); return }
        cont = c
        lock.unlock()
    }

    /// Returns true if THIS call was the one that resumed it.
    @discardableResult
    func fire() -> Bool {
        lock.lock()
        if spent { lock.unlock(); return false }
        spent = true
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume()
        return true
    }
}

// =====================================================================
// BUILD 272 — A SECOND VOICE PROVIDER, AND WHY
// =====================================================================
//
// Chappy went completely mute on 18 August because a Gemini preview TTS
// model returned 429. Everything build 271 did was damage control on that
// fact. The underlying problem is that the voice of a wearable device sat
// on a free preview tier of a general-purpose model, and preview tiers are
// where a provider puts its tightest caps and its weakest promises.
//
// ElevenLabs Flash v2.5 is a purpose-built streaming speech engine: about
// 75ms to first audio against the 4,200ms Chappy measured on Gemini. That
// is not a tuning gap, it is an architecture gap - one generates audio
// tokens through a general model, the other starts emitting sound before
// it has finished thinking.
//
// THE PART THAT MADE THIS CHEAP: ElevenLabs will return `pcm_24000`, which
// is signed 16-bit little-endian mono at 24 kHz - byte-for-byte the format
// this file has fed AVAudioEngine since build 100. The whole playback half,
// the carry-byte handling, the generation ownership rules, the cache: all
// unchanged. Only the fetch is new.
//
// AND `pcm_24000` IS AVAILABLE ON THE STARTER PLAN. Only 44.1 kHz PCM is
// gated to Pro and above. Checked before writing a line of this, because
// the alternative was MP3, and MP3 would have meant a decoder, a second
// audio path, and every hazard build 260 spent itself removing.
//
// ALL OF THIS LIVES IN TTSService.swift ON PURPOSE. A new file has to be
// added to the Xcode target by hand, and files silently missing from the
// target have already cost this project real builds. Nothing here is worth
// that risk.

enum ChappyVoiceProvider: String {
    case gemini
    case elevenLabs

    /// BUILD 274 — ELEVENLABS IS THE DEFAULT NOW.
    ///
    /// With his key and his voice both baked in there is nothing left to set
    /// up, so defaulting to Google would only mean one more switch to find.
    /// Google is still one tap away and is still the automatic fallback when
    /// ElevenLabs does not answer.
    static var current: ChappyVoiceProvider {
        let d = UserDefaults.standard
        if let p = ChappyVoiceProvider(rawValue: d.string(forKey: "chappy_voice_provider") ?? "") {
            return p
        }
        // BUILD 275 — THIS GUARD WAS FAR TOO WIDE AND IT COST HIM THE BUILD.
        //
        // 274 protected a wearer who had deliberately chosen "System" - the
        // free, offline Apple voice - from being moved onto a paid cloud
        // provider by a changed default. That protection is right. What I
        // wrote was "ANY stored Gemini voice is a choice", and that is a
        // different and much bigger claim.
        //
        // chappy_tts_voice has been written by the voice picker since build
        // 125. Everyone who has ever opened that screen has one. So on his
        // phone this returned .gemini, ElevenLabs was never attempted, and
        // 274 shipped a feature that could not run - while the log filled
        // with the exact Gemini 429s the whole thing exists to escape.
        //
        // Only "System" is a decision to refuse a cloud voice. Every other
        // value is a leftover preference about WHICH Gemini voice, which says
        // nothing about whether he wants a faster provider. Narrow it to the
        // one case the protection was actually for.
        if d.string(forKey: "chappy_tts_voice") == "System" {
            return .gemini
        }
        return .elevenLabs
    }

    /// BUILD 272 — NO HARDCODED VOICE IDS, AND THIS IS NOT FUSSINESS.
    ///
    /// The obvious build here is a picker with George, Lily, Alice and Daniel
    /// baked in. It would have shipped broken. ElevenLabs' Default voices
    /// expire on 31 December 2026, AND they are only available to accounts
    /// created before March 2026 - so a brand new Starter account, which is
    /// exactly what he is buying, cannot use a single one of those IDs. Every
    /// baked-in voice would have 404'd on his first render, and the symptom
    /// would have been "the new voice doesn't work" with no clue why.
    ///
    /// So the list is fetched from his own account at runtime and cached. What
    /// he can choose is whatever HE actually has, today, for as long as he has
    /// it - which is also the only version of this that still works in 2027.
    ///
    /// Empty until the list has been fetched once and a voice chosen. An empty
    /// ID must never reach the URL: see the guard in streamElevenLabsAudio.
    /// BUILD 274 — his chosen voice, baked in as the default.
    ///
    /// The note above still stands and is the reason this is a DEFAULT rather
    /// than a constant: ElevenLabs' stock voices expire at the end of 2026, so
    /// any ID in source has a shelf life. This one is his own, from his own
    /// account, which he sent me — and the moment he taps a different voice in
    /// Settings, that one is used instead and this line stops mattering.
    static var elevenVoiceID: String {
        let saved = UserDefaults.standard.string(forKey: "chappy_11l_voice_id") ?? ""
        return saved.isEmpty ? "wDsJlOXPqcvIUKdLXjDs" : saved
    }

    /// Flash v2.5: ~75ms, 32 languages, half the credits per character of the
    /// multilingual models.
    ///
    /// BUILD 274 gave this a row next to the voice list - Flash, Turbo and
    /// Multilingual v2 - so it is now his to change, not only mine. The model
    /// is part of the voice cache key for the reason spelled out on
    /// `voiceName`: the three do not sound the same.
    static var elevenModel: String {
        UserDefaults.standard.string(forKey: "chappy_11l_model") ?? "eleven_flash_v2_5"
    }

    /// True only when this provider can actually be attempted. Checked before
    /// the attempt rather than discovered by a failed one, because a failed
    /// attempt on the voice path costs silence.
    /// NOT @MainActor. APIKeyManager is not actor-isolated - every other key
    /// read on the speaking path calls it synchronously - and marking this
    /// MainActor would have forced an await into a condition list inside a
    /// nonisolated Task for no benefit.
    static var elevenReady: Bool {
        current == .elevenLabs
            && !elevenVoiceID.isEmpty
            && !(APIKeyManager.shared.getElevenLabsKey() ?? "").isEmpty
    }
}

/// BUILD 272 — reading his account rather than guessing at it.
///
/// Two small calls, both used by Settings only, neither on the speaking path.
enum ElevenLabsAccount {

    struct Voice: Identifiable, Hashable {
        let id: String          // voice_id
        let name: String
        let accent: String      // "british", "american", ... may be empty
        let descriptor: String  // labels.description, may be empty
    }

    struct Usage {
        let tier: String
        let used: Int
        let limit: Int
        var remaining: Int { max(0, limit - used) }
    }

    private static func request(_ path: String, key: String) -> URLRequest? {
        guard let url = URL(string: "https://api.elevenlabs.io" + path) else { return nil }
        var r = URLRequest(url: url)
        r.setValue(key, forHTTPHeaderField: "xi-api-key")
        r.timeoutInterval = 15
        return r
    }

    /// v2/voices, filtered to what a person would actually want to pick from.
    /// page_size is capped at 100 by the API; one page is plenty for a
    /// personal account and saves paginating for no reason.
    static func voices(key: String) async -> [Voice] {
        guard !key.isEmpty,
              let r = request("/v2/voices?page_size=100", key: key) else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(for: r)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                ChappyStandbyLog.note("⚠️ [11L] Could not read the voice list (HTTP \(code))")
                return []
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = json["voices"] as? [[String: Any]] else { return [] }
            return raw.compactMap { v in
                guard let id = v["voice_id"] as? String, !id.isEmpty,
                      let name = v["name"] as? String else { return nil }
                let labels = v["labels"] as? [String: Any]
                return Voice(id: id,
                             name: name,
                             accent: (labels?["accent"] as? String) ?? "",
                             descriptor: (labels?["description"] as? String) ?? "")
            }
        } catch {
            ChappyStandbyLog.note("⚠️ [11L] Could not read the voice list: \(error.localizedDescription)")
            return []
        }
    }

    /// What it is costing him, from the source rather than from my arithmetic.
    static func usage(key: String) async -> Usage? {
        guard !key.isEmpty,
              let r = request("/v1/user/subscription", key: key) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: r),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Usage(tier: (json["tier"] as? String) ?? "unknown",
                     used: (json["character_count"] as? Int) ?? 0,
                     limit: (json["character_limit"] as? Int) ?? 0)
    }
}

class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published var isSpeaking = false

    // Gemini TTS models — primary, with fallback name if Google renames tiers.
    // BUILD 143 (SUPERSEDED, kept for its reasoning): "2.5 promoted to
    // PRIMARY — half the price of 3.1 ($10 vs $20 per million audio tokens)
    // and typically faster to first byte." The latency half stopped being
    // true the day 3.1 shipped streaming, and nobody noticed. The price half
    // may still hold — but see the note on rendering below: it rests on a
    // figure nobody has re-checked, and it is not worth a voice that changes
    // halfway through a conversation.
    // BUILD 259 — 3.1 FIRST, AND THIS ORDER IS THE WHOLE BUILD.
    //
    // These two were the other way round, and 3.1 was only ever reached if
    // 2.5 outright failed. Google's own docs: "Streaming is supported for
    // Text-to-Speech models starting with version 3.1." So the app has been
    // pinned to the one model in its own list that CANNOT stream, and every
    // reply waited for the entire clip to render before a single sample
    // played. His log, repeatedly:
    //
    //     🐢 took 3462ms to render 10 characters
    //     🐢 took 4939ms to render 17 characters
    //
    // Ten characters and three and a half seconds, because the cost is
    // almost all round-trip and render setup — it barely varies with length.
    // That is why it felt like nothing was responding.
    //
    // Why it was this way: when the voice was built, 2.5 preview was the only
    // Gemini TTS there was. 3.1 arrived later with streaming, went into the
    // list as a safety fallback, and nobody went back and asked whether the
    // assumption behind the ordering still held. It didn't.
    //
    // 2.5 stays as the fallback, so a bad day on 3.1 lands exactly where the
    // old primary was rather than on the robot voice.
    // BUILD 271 - COMPUTED, NOT STORED, AND NOT HARDCODED ANY MORE.
    //
    // Stored `let` meant the value was frozen when TTSService was first
    // touched, so even once these became settings a change would not take
    // effect until the app was killed and relaunched - the worst possible
    // behaviour for a control whose entire reason to exist is "the voice is
    // broken right now and I need to move off this model".
    //
    // Order still matters and still means what it meant: index 0 renders
    // everything, index 1 is only reached when index 0 fails - and only its
    // playback, never its cache, for the reason given at that call site.
    //
    // An earlier draft of this comment sent the reader to "the note above
    // about why they must not both be preview models". There is no such note,
    // and there could not be: Google offers three speech models and all three
    // are previews, so both entries are previews by necessity, not by
    // oversight. Review caught the comment inventing a rule the UI cannot
    // satisfy - the same fault this file records against itself twice already.
    private var ttsModels: [String] {
        let primary = ChappyModels.tts
        let fallback = ChappyModels.ttsFallback
        // A fallback identical to the primary is not a fallback, it is the
        // same request twice and twice the latency before the Apple voice.
        return primary == fallback ? [primary] : [primary, fallback]
    }

    // BUILD 259 — ONE MODEL RENDERS EVERYTHING, AND I TRIED IT THE OTHER WAY
    // FIRST.
    //
    // Four call sites render WITHOUT going through speakWithGemini — the
    // voice self-test, warmCache, the per-step nav pre-render and the chunk
    // warm. None of them stream, so I pinned them to 2.5 to keep build 143's
    // half-the-price saving. Review killed it on two counts, both right:
    //
    //   1. VoiceCache's key is SHA256(voice|text) — THE MODEL IS NOT IN IT.
    //      So a nav step pre-rendered by 2.5 and a live line streamed by 3.1
    //      share a keyspace, and any prosodic difference between the two
    //      model versions becomes the voice changing mid-conversation. That
    //      is the exact complaint build 125 exists to prevent.
    //   2. The self-test would have been pinned to the FALLBACK. Its whole
    //      job is to say why the real voice is failing; on a key where 3.1
    //      is quota-limited and 2.5 is fine it would have rendered happily
    //      and announced "working fine" while every real line failed.
    //
    // So everything renders with ttsModels[0]. The price question is real,
    // but it rests on a figure from build 143 that nobody has re-checked
    // against current pricing, and a stale number is not a reason to ship a
    // voice that changes halfway through a sentence. If it matters: verify
    // the pricing, then put the model in the cache key, then split them.

    /// Only 3.1 and later return audio progressively. A version test rather
    /// than a substring one: `contains("-4")` matched any model with a `-4`
    /// anywhere in its name, so a date- or size-suffixed non-streaming model
    /// would have been classified as streaming and cost a failed attempt —
    /// up to the twenty-second timeout — before falling back.
    private func modelStreams(_ model: String) -> Bool {
        guard let r = model.range(of: #"gemini-(\d+)\.(\d+)"#, options: .regularExpression) else {
            return false
        }
        let nums = model[r].dropFirst("gemini-".count).split(separator: ".")
        guard nums.count == 2, let major = Int(nums[0]), let minor = Int(nums[1]) else { return false }
        return major > 3 || (major == 3 && minor >= 1)
    }

    // BUILD 271 - NAME THE QUOTA, DO NOT GUESS AT IT.
    //
    // He asked a fair question: "is the voice dead because we moved the brain
    // to 3.7?" I could not answer it from the log, because the log recorded
    // "TTS HTTP error 429" and nothing else. Google DOES say which quota it
    // refused on, in the error body, and the answer is different depending on
    // what it says:
    //
    //   ...PerProjectPerModel...  -> the VOICE model's own cap. Nothing to do
    //                                with the brain. Google applies the
    //                                tightest caps to preview models, and the
    //                                voice model is a preview model.
    //   ...PerProject... (no model) -> the whole project's cap, which the
    //                                brain and the voice share. Then the 3.7
    //                                switch is a genuine suspect, because
    //                                Google states rate limits are enforced
    //                                per project, not per API key.
    //
    // One string decides it. Pull it out and put it in front of him.
    static func quotaReason(from body: String) -> String {
        guard !body.isEmpty,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any] else { return "" }

        // The quota id is the precise answer; the message is the readable one.
        if let details = err["details"] as? [[String: Any]] {
            for d in details {
                guard let violations = d["violations"] as? [[String: Any]] else { continue }
                for v in violations {
                    if let id = v["quotaId"] as? String, !id.isEmpty {
                        let scope = id.contains("PerModel") ? "this voice model only"
                                  : (id.contains("PerProject") ? "the WHOLE project, brain included" : "unclear scope")
                        return " - quota \(id) (\(scope))"
                    }
                }
            }
        }
        if let msg = err["message"] as? String, !msg.isEmpty {
            return " - \(msg.prefix(160))"
        }
        return ""
    }

    /// BUILD 259 — one bad streaming attempt turns streaming off for the rest
    /// of the session and everything falls back to the proven whole-clip path.
    ///
    /// This is deliberate cowardice. This file has a documented history of
    /// silent-forever bugs — a dropped completion handler, a detached node, a
    /// stopped engine — and a new progressive playback path is exactly the
    /// kind of change that can produce one. The worst case has to be "no
    /// better than yesterday", never "no voice at all".
    /// Stored as a MOMENT, not a flag, and it clears itself after five
    /// minutes. Review pointed at this file's own argument against a
    /// permanent latch, twenty lines from here: geminiVoiceGaveUp decays for
    /// exactly this reason, because "half an hour of robot over one bad
    /// moment was the real insult." A single 429 or a dropped socket must not
    /// switch off this build's whole point for the rest of the day — and this
    /// app stays resident for hours, so "the session" meant the day.
    nonisolated(unsafe) private static var streamingGaveUpAt: Date?
    private static var streamingGaveUp: Bool {
        get {
            guard let t = streamingGaveUpAt else { return false }
            if Date().timeIntervalSince(t) > 300 { streamingGaveUpAt = nil; return false }
            return true
        }
        set { streamingGaveUpAt = newValue ? Date() : nil }
    }

    /// Gemini prebuilt voice. Change via UserDefaults key "chappy_tts_voice".
    /// Nice options: Kore (warm female), Puck (male), Aoede, Charon, Fenrir, Leda.
    private var geminiVoiceName: String {
        UserDefaults.standard.string(forKey: "chappy_tts_voice") ?? "Kore"
    }

    /// BUILD 272 — THE CACHE KEY, AND WHY THIS ONE LINE MATTERS MOST.
    ///
    /// VoiceCache keys on SHA256(voice|text) and NOTHING ELSE. Adding a second
    /// provider without touching this would have meant an ElevenLabs line and
    /// a Gemini line of the same text sharing one file on disk: switch
    /// provider, and every sentence Chappy already knows replays in the OLD
    /// provider's voice while new ones arrive in the new. That is the
    /// changing-person fault builds 125 and 259 exist to prevent, and it would
    /// have looked exactly like "the new voice doesn't work properly".
    ///
    /// Prefixing the provider makes the keyspaces disjoint for free. It also
    /// means switching back and forth costs nothing: each provider keeps its
    /// own cached copies rather than trampling the other's.
    private var voiceName: String {
        switch ChappyVoiceProvider.current {
        // REVIEW FIX - THE MODEL IS IN THE KEY TOO.
        //
        // 274 added a Flash / Turbo / Multilingual picker, and those three do
        // not sound the same. With only the voice in the key, switching engine
        // would leave every already-cached line replaying in the old engine's
        // prosody for ever while new lines arrived in the new one - the
        // changing-person fault again, arriving through the one control added
        // to let him compare them. Three keyspaces, disjoint, no wipe needed.
        case .elevenLabs:
            return "11l:\(ChappyVoiceProvider.elevenModel):\(ChappyVoiceProvider.elevenVoiceID)"
        case .gemini:     return geminiVoiceName
        }
    }

    /// BUILD 125: above this length a line is almost certainly a one-off AI
    /// answer that will never be said twice, so caching it only burns disk.
    /// Chappy's repeating vocabulary — confirmations, refusals, nav calls — is
    /// comfortably under it.
    fileprivate static let cacheableLimit = 200

    /// BUILD 125: ONE Apple voice, chosen once and pinned.
    ///
    /// When Apple's voice does have to speak — no key, no cached copy, no
    /// signal — it must at least always be the SAME Apple voice. Left to
    /// itself, `AVSpeechSynthesisVoice(language:)` returns whatever the system
    /// feels like that day, which is a second way for Chappy to change person
    /// mid-conversation. Resolve it once, write the identifier down, and use
    /// that identifier forever after.
    private func pinnedSystemVoice(for language: String) -> AVSpeechSynthesisVoice? {
        // TTSService has no initialiser to hang this off, and this is the only
        // function in the app that reads a pin - so it is the one place the
        // migration cannot be skipped.
        Self.migratePinnedVoicesIfNeeded()

        let key = "chappy_pinned_voice_\(language)"
        if let saved = UserDefaults.standard.string(forKey: key),
           let v = AVSpeechSynthesisVoice(identifier: saved) {
            return v
        }

        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased() == language.lowercased() }
        guard !candidates.isEmpty else { return nil }

        // Match the sex of the chosen Gemini voice where iOS will tell us, so
        // the fallback is as close a relative as the device can offer.
        var pool = candidates
        if #available(iOS 17.0, *) {
            // BUILD 272: geminiVoiceName. This matches the Apple fallback's sex
            // to the chosen Gemini voice; with ElevenLabs selected the prefixed
            // name matches nothing in the set and everyone silently became
            // male. Reading the Gemini name keeps the old behaviour intact and
            // is no worse than before for ElevenLabs, where the set does not
            // describe the voice anyway.
            let wanted: AVSpeechSynthesisVoiceGender = Self.femaleGeminiVoices.contains(geminiVoiceName) ? .female : .male
            let matched = candidates.filter { $0.gender == wanted }
            if !matched.isEmpty { pool = matched }
        }

        // BUILD 271 - "NICEST AVAILABLE" IS THE WRONG WORD FOR AVAILABLE.
        //
        // This sorted by quality DESCENDING and took the best: Premium first,
        // then Enhanced, then Default. That reads as obviously right and is
        // the likeliest reason he heard NOTHING today rather than the robot.
        //
        // speechVoices() lists Enhanced and Premium voices whether or not
        // their audio assets have actually been downloaded to the phone.
        // Speaking through one that has not been downloaded does not throw
        // and does not fall back - the utterance is accepted, didFinish is
        // reported on schedule, and no sound is produced. Silence that looks
        // exactly like success.
        //
        // And the result was written to UserDefaults and reused FOREVER, so a
        // single unlucky pin makes every future fallback silent across every
        // launch. Nothing re-evaluated it. That is this file's signature bug
        // - the silent-forever kind - in a function whose whole job is to be
        // the thing that still works when everything else has failed.
        //
        // So: Default quality FIRST. It is the compact voice that ships in
        // the OS image and is present on every device by definition. This
        // voice only ever speaks when Chappy's real voice has already failed;
        // trading a little polish for "it makes a sound" is not a close call.
        //
        // Only reachable for a language iOS says it has, so a nil return here
        // still means genuinely nothing installed, exactly as before.
        // REVIEW FIX - "PREFER .default" ALONE PICKS THE WORST VOICE ON THE
        // PHONE, NOT THE SAFEST.
        //
        // My first cut tested only `quality == .default` and then tie-broke on
        // identifier ascending. Quality .default also covers the Eloquence set
        // (com.apple.eloquence.*) and the novelty voices, and those sort BEFORE
        // com.apple.ttsbundle.* alphabetically - so the emergency voice would
        // have pinned to a 1980s DECtalk-style Eloquence voice and written it
        // to UserDefaults forever. That is not a hypothesised silence, it is a
        // guaranteed regression, and it would have been my fault twice over.
        //
        // Rank on three keys, in order:
        //   1. quality: default, then enhanced, then premium
        //   2. shipped-in-the-OS bundle before anything else
        //   3. identifier, purely so two launches never disagree
        func rank(_ v: AVSpeechSynthesisVoice) -> (Int, Int, String) {
            let q: Int
            switch v.quality {
            case .default:  q = 0
            case .enhanced: q = 1
            default:        q = 2      // .premium, and anything Apple adds later
            }
            let shipped = v.identifier.hasPrefix("com.apple.ttsbundle.") ? 0 : 1
            return (q, shipped, v.identifier)
        }
        let ranked = pool.sorted { rank($0) < rank($1) }
        guard let chosen = ranked.first else { return nil }
        UserDefaults.standard.set(chosen.identifier, forKey: key)
        ChappyStandbyLog.note("🗣️ [TTS] Emergency voice for \(language) is \(chosen.name) (quality \(chosen.quality.rawValue))")
        return chosen
    }

    /// BUILD 271 - a way out of a bad pin without deleting the app.
    ///
    /// If the pinned identifier ever stops resolving - iOS drops a downloaded
    /// voice on an update, or the wearer removes it in Accessibility - the
    /// lookup above already falls through and re-picks. This is for the case
    /// where it resolves but does not make a sound, which the phone cannot
    /// detect and he can. Wired to the voice self-test.
    static func forgetPinnedFallbackVoices() {
        // REVIEW FIX - repinSystemVoices() already cleared exactly this
        // keyspace and I wrote a byte-for-byte copy of it without looking.
        // Two functions clearing the same defaults, called from different
        // places, is how they drift apart later.
        repinSystemVoices()
        ChappyStandbyLog.note("🗣️ [TTS] Emergency voice pins cleared - will be re-chosen on the next fallback")
    }

    /// REVIEW FIX - THIS BUILD HAD TO REPAIR THE PHONE THAT ALREADY HAS THE
    /// BUG, AND IT DID NOT.
    ///
    /// The lookup above returns any saved identifier that still resolves, and
    /// a Premium voice with no downloaded asset resolves fine. So every fix in
    /// this build would have sailed straight past the one device that reported
    /// the fault: his pin was already written, and nothing re-evaluated it
    /// unless he happened to press the voice self-test.
    ///
    /// One-shot, versioned, runs once per install. Cheap and it cannot loop.
    static func migratePinnedVoicesIfNeeded() {
        let d = UserDefaults.standard
        let current = 271
        guard d.integer(forKey: pinVersionKey) < current else { return }
        repinSystemVoices()
        d.set(current, forKey: pinVersionKey)
        ChappyStandbyLog.note("🗣️ [TTS] Emergency voice re-chosen for build 271")
    }

    /// Gemini's prebuilt voices, split so the Apple fallback can match.
    private static let femaleGeminiVoices: Set<String> = [
        "Kore", "Aoede", "Leda", "Zephyr", "Autonoe", "Callirrhoe",
        "Despina", "Erinome", "Gacrux", "Laomedeia", "Pulcherrima",
        "Vindemiatrix", "Sulafat", "Achernar", "Sadachbia"
    ]

    // BUILD 139 — THE VOICE SELF-TEST.
    //
    // "All the voices sound the same" is not a taste problem — it means every
    // Gemini render is FAILING and every preview is the one Apple fallback.
    // This makes one real render and says exactly why it failed, out loud,
    // because the wearer can't read the Xcode console from a moving scooter.
    func runVoiceSelfTest() {
        Task { [weak self] in
            guard let self else { return }
            // BUILD 271 - clear the emergency-voice pin FIRST, every time.
            //
            // "Test the voice" is the one button he presses when he cannot
            // hear anything, so it is the right place to undo a bad pin. It
            // costs one voice lookup and it means a silent Apple fallback can
            // always be repaired from the phone, without a build from me.
            Self.forgetPinnedFallbackVoices()
            // Clears the five-minute streaming latch so the next REAL line
            // gets a fresh attempt. The test itself renders whole-clip, so it
            // does not prove streaming works - it only stops a stale latch
            // outliving the problem that set it.
            Self.streamingGaveUp = false

            // REVIEW FIX (BUILD 272) - the self-test renders through Gemini
            // whatever the provider, so on ElevenLabs it was about to announce
            // "that was the Gemini voice, working fine" about a voice that is
            // not the one speaking. Test what is actually in use.
            if ChappyVoiceProvider.elevenReady {
                // Through speak(), NOT straight into streamElevenLabsAudio.
                // The renderer needs a speaking generation to own, and it is
                // speak() that mints one - calling the renderer directly would
                // mean inventing a generation number, which is how this file's
                // barge-in ownership rules get quietly broken. Going through
                // the front door also means the test exercises the REAL path,
                // fallbacks included, which is the only thing worth testing.
                self.speak("This is my real voice, on ElevenLabs. If you can hear this, the fast voice is working.",
                           forceNetworkVoice: true)
                return
            }

            let key = APIKeyManager.shared.getGoogleAPIKey() ?? ""
            guard !key.isEmpty else {
                self.speak("No Google key is set, so every voice falls back to this Apple one. Add the Gemini key in Settings.")
                return
            }
            Self.geminiVoiceGaveUp = false   // the test must actually try
            do {
                let audio = try await self.requestGeminiAudio(
                    text: "This is my real voice, and it's working.",
                    model: self.ttsModels[0], apiKey: key)
                VoiceCache.shared.save(audio, text: "This is my real voice, and it's working.", voice: self.geminiVoiceName)
                let gen = self.beginSpeaking(estimatedCharacters: 40)
                defer { Task { @MainActor in self.endSpeaking(gen) } }
                try await self.playPCM(audio, gen: gen)
                self.speak("That was the Gemini voice, working fine. If things sound robotic later it's a temporary network drop, not a setup problem.")
            } catch {
                let msg: String
                let desc = error.localizedDescription
                if desc.contains("429") {
                    msg = "Google says the voice quota is used up — error four two nine. That's why everything sounds like this robot. The Gemini key is on the free tier for speech: turn on billing for it in Google A I Studio, or the quota resets each day."
                } else if desc.contains("403") {
                    msg = "Google refused the key — error four zero three. The key works for pictures but is blocked for speech. Check the key's API restrictions in Google A I Studio."
                } else if desc.contains("404") {
                    msg = "The speech model name was not found — error four zero four. Tell Claude: the T T S model needs renaming."
                } else {
                    msg = "The voice service failed: \(desc). If this keeps happening, tell Claude exactly this message."
                }
                self.speak(msg)
                print("🔊 [TTS] Self-test failed: \(desc)")
            }
        }
    }

    /// Forget the pinned choices — used when the wearer changes voice so the
    /// fallback re-matches the new one.
    static func repinSystemVoices() {
        let d = UserDefaults.standard
        // REVIEW FIX - the migration marker is called
        // chappy_pinned_voice_version, which matches this very prefix. Left
        // alone, voiceChanged() and the self-test wiped the marker along with
        // the pins, so a "one-shot" migration re-ran every time and logged
        // "re-chosen for build 271" on a build that had already done it.
        for (k, _) in d.dictionaryRepresentation()
        where k.hasPrefix("chappy_pinned_voice_") && k != Self.pinVersionKey {
            d.removeObject(forKey: k)
        }
    }

    private static let pinVersionKey = "chappy_pinned_voice_version"

    // Playback engine (24 kHz PCM16 from Gemini)
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)
    private var isPlaybackEngineRunning = false

    // System TTS fallback
    private var systemSynthesizer: AVSpeechSynthesizer?
    private var systemTTSContinuation: CheckedContinuation<Void, Never>?
    /// SB-DEADLOCK FIX: `stop()` (any thread) and the synthesizer delegate (its
    /// own queue) both resumed this continuation. Two resumes of one checked
    /// continuation is a hard crash, and the nil-check between them was not
    /// atomic. All access is now funnelled through this lock.
    private let continuationLock = NSLock()

    private var currentTask: Task<Void, Never>?
    /// BUILD 258 — lines currently being pre-rendered, so the same uncached
    /// short line asked for twice inside one render window costs one call
    /// rather than two. See the note in prerenderNow.
    nonisolated(unsafe) private static var rendersInFlight = Set<String>()
    private let inFlightLock = NSLock()

    /// BUILD 254 — THE QUEUE BEHIND THE SENTENCE.
    ///
    /// `speakLong` splits a long answer into chunks and speaks them from a
    /// loop. That loop used to live in an unstored `Task`, so `stop()` —
    /// which cancels `currentTask`, the PLAYBACK of the chunk being spoken —
    /// could not reach it. Its own `if Task.isCancelled` could never be true,
    /// because nobody held the task to cancel.
    ///
    /// The wearer's experience: he says "shut up", the sentence stops, and
    /// the next chunk starts a tenth of a second later. On a four-chunk
    /// answer he has to say it four times. That is the single loudest half
    /// of "it talks over the top of me".
    private var chunkTask: Task<Void, Never>?

    /// True only for the instant the chunk loop is calling `speak()` itself.
    ///
    /// Without it the fix eats its own tail: `speak()` calls `stop()`, which
    /// would cancel `chunkTask` — the loop cancelling itself on its way to
    /// chunk two, so chunks three onward would never play.
    ///
    /// Both this and `chunkTask` are guarded by `chunkLock`. My first
    /// argument for leaving them bare was "set and cleared around one
    /// synchronous call on the main actor, with no await between" — which
    /// is true of the WRITER and says nothing about the reader. The
    /// SB-DEADLOCK note further down this file states plainly that `stop()`
    /// is "called from wherever the caller happens to be: URLSession
    /// completion handlers, audio callbacks, Timer fires, async contexts."
    /// BE PRECISE ABOUT WHAT THE LOCK BUYS: memory coherence, not
    /// exclusion. An off-main `stop()` landing inside that window still
    /// reads true, still skips the cancel, and still lets chunks three and
    /// four play on. What it gets is a coherent value rather than a torn
    /// one, and a window bounded to one real synchronous call. The race is
    /// closed in practice only because the barge-in path's `stop()` comes
    /// from @MainActor ChappyStandby, which cannot interleave with the
    /// loop — and that, not the lock, is the guarantee.
    private var chunkLoopIsSpeaking = false
    private let chunkLock = NSLock()
    private var playbackResilienceInstalled = false
    /// Once the network voice has failed, stop asking it. Chappy changing voice
    /// every other sentence is worse than never using the nicer one.
    private static var geminiGaveUpAt: Date?
    /// AUDIT P2: this used to latch forever on a single transient error, so one
    /// bad moment of signal cost the nicer voice until the app was restarted.
    /// Thirty minutes is long enough to stop it flip-flopping sentence to
    /// sentence, short enough that a tunnel doesn't cost you the rest of the day.
    /// BUILD 174 — WHY it gave up, kept so "why is the voice robotic" has a
    /// real answer instead of a shrug.
    static var lastFallbackReason = ""
    static var lastFallbackAt: Date?

    /// BUILD 274 (review fix). What ElevenLabs last refused with, so
    /// voiceStatusLine can answer "why does it sound like Google" truthfully
    /// rather than reading the settings back at him.
    nonisolated(unsafe) static var lastElevenFailure: (code: Int, at: Date)?

    /// BUILD 275. Last provider decision written to the log, so the line above
    /// appears when something changes and stays quiet when nothing does.
    nonisolated(unsafe) static var lastProviderStamp = ""

    /// The honest status line, for the voice test and for asking out loud.
    static var voiceStatusLine: String {
        // REVIEW FIX (BUILD 272) - THE THIRD PLACE THAT ONLY KNEW ABOUT GOOGLE.
        //
        // This is what Chappy SAYS OUT LOUD when asked why the voice sounds
        // wrong. Left alone it would have answered "there's no Google key, so
        // only Apple's voice is available" while ElevenLabs was speaking
        // perfectly well without one - a confident, wrong answer to the exact
        // question this line exists to answer honestly.
        if ChappyVoiceProvider.current == .elevenLabs {
            // REVIEW FIX - BOTH OF THE OLD TESTS WENT UNREACHABLE IN 274.
            //
            // With a key and a voice baked in, neither can be empty, so this
            // used to answer "on ElevenLabs, working" no matter what - which
            // is a confident wrong answer from the one function whose entire
            // job is saying honestly why the voice sounds off. If the key is
            // revoked or out of credit, every line quietly pays a failure and
            // renders through Google, and this said nothing.
            //
            // Report what actually happened instead of what is configured.
            if let f = lastElevenFailure, Date().timeIntervalSince(f.at) < 600 {
                let why: String
                switch f.code {
                case 401: why = "the ElevenLabs key was rejected"
                case 402: why = "the ElevenLabs account is out of characters"
                case 404, 422: why = "that ElevenLabs voice isn't available on this account"
                case 429: why = "ElevenLabs is rate limiting"
                default:  why = "ElevenLabs returned an error (\(f.code))"
                }
                let ago = Int(Date().timeIntervalSince(f.at))
                return "Chappy is on Google right now because \(why) — \(ago) seconds ago."
            }
            return "Chappy's voice is on ElevenLabs, with Google behind it and the phone's own voice behind that."
        }

        let wantsSystem = (UserDefaults.standard.string(forKey: "chappy_tts_voice") ?? "Kore") == "System"
        if wantsSystem {
            return "The voice is set to System in Settings — that's Apple's voice by choice, not a fault."
        }
        if (APIKeyManager.shared.getGoogleAPIKey() ?? "").isEmpty {
            // BUILD 175: tell the two apart. "No key" is a setup problem the
            // wearer can fix; "the phone was locked" is the bug that made
            // every startup robotic, and it now repairs itself.
            if APIKeyManager.lastKeychainStatus == errSecInteractionNotAllowed {
                return "The key couldn't be read because the phone was locked. That's the old startup fault - it repairs itself the next time you open Chappy unlocked."
            }
            return "There's no Google key, so only Apple's voice is available."
        }
        if geminiVoiceGaveUp {
            let ago = lastFallbackAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            return "Chappy's voice is in fallback after a failure \(ago) seconds ago: \(lastFallbackReason). It clears itself within five minutes, or say 'reset the voice'."
        }
        return "Chappy's own voice is working normally."
    }

    static var geminiVoiceGaveUp: Bool {
        get {
            guard let t = geminiGaveUpAt else { return false }
            // BUILD 143: five minutes, not thirty. With the render timeout
            // fixed, a latch now means a genuine outage — and outages end.
            // Half an hour of robot over one bad moment was the real insult.
            if Date().timeIntervalSince(t) > 300 { geminiGaveUpAt = nil; return false }
            return true
        }
        set { geminiGaveUpAt = newValue ? Date() : nil }
    }

    /// SB-DEADLOCK FIX: `isSpeaking` is the barge-in gate for ChappyStandby —
    /// while it is true the wake word ignores EVERYTHING it hears. It was set
    /// true before an `await` that could never return (a lost synthesizer
    /// delegate callback or a lost scheduleBuffer completion), and every exit
    /// path that reset it was guarded by `!Task.isCancelled`. One lost callback
    /// left the flag true forever: the ear stayed armed, the chip stayed lit,
    /// and not one word was ever routed again. Generation + watchdog below make
    /// that state unreachable.
    /// BUILD 259 — BEHIND A LOCK, because 259 made it load-bearing.
    ///
    /// Before this build ONE site made a teardown decision on this counter.
    /// Now three do, and one of them is an error path that stops the SHARED
    /// player node. beginSpeaking's own doc still says "callers are
    /// main-thread in practice" — which is word for word the justification
    /// this file identifies, forty lines up, as the cause of the build-80
    /// hang. Leaving that phrase load-bearing in three places is how this
    /// file has been bitten twice.
    ///
    /// A lock rather than @MainActor, deliberately: annotating beginSpeaking
    /// is exactly what failed the build-69 archive and got the isolation
    /// stripped out in the first place. This is the same NSLock pattern
    /// already used four times in this file, and it drops a main-actor hop
    /// out of the audio teardown path as a bonus — the hop at the top of the
    /// stream catch sat between a failed render and clearing the node, at the
    /// moment the main queue is busiest with barge-in work.
    private let genLock = NSLock()
    private var _speechGeneration = 0
    private func bumpGeneration() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        _speechGeneration &+= 1
        return _speechGeneration
    }
    private func generationIsCurrent(_ g: Int) -> Bool {
        genLock.lock(); defer { genLock.unlock() }
        return _speechGeneration == g
    }
    private var speakingWatchdog: Task<Void, Never>?
    /// When the current utterance was started — lets callers detect a stuck flag.
    private(set) var speakingSince: Date?
    /// The last line spoken aloud. Kept so "what?" / "say that again" can
    /// replay it — the single most natural thing to say when you mishear
    /// someone, and it had no handler anywhere in the app.
    private(set) var lastSpokenLine: String = ""

    /// BUILD 264 — when it was said, so the ear can tell Chappy's own voice
    /// from the wearer's. Without a clock, a line spoken an hour ago would
    /// still be treated as an echo and a genuine repeat would be swallowed.
    private(set) var lastSpokenAt: Date = .distantPast

    override private init() {
        super.init()
        setupPlaybackEngine()
        installPlaybackResilience()

        // BUILD 125: warm the voice cache a few seconds after launch, off the
        // critical path. Once the repeating vocabulary is on disk this is a
        // no-op forever, so it costs one quiet burst on the first run and
        // nothing after. Deliberately self-contained — no other file has to
        // remember to call it.
        Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.warmCache()
        }
    }

    /// BUILD 125: notice a voice change without Settings having to tell us.
    /// The cache is keyed by voice so it can never serve the wrong one, but the
    /// PINNED Apple fallback has to re-match, and the old voice's audio is dead
    /// weight worth reclaiming.
    private func noticeVoiceChange() {
        let current = voiceName
        let key = "chappy_tts_voice_last_seen"
        let previous = UserDefaults.standard.string(forKey: key)
        guard previous != current else { return }
        UserDefaults.standard.set(current, forKey: key)
        guard previous != nil else { return }   // first run, nothing to clear
        print("🔊 [TTS] Voice changed \(previous ?? "?") → \(current) — repinning and rewarming")
        // REVIEW FIX (BUILD 272) - AND THIS CLEAR WAS ALWAYS UNNECESSARY.
        //
        // The VOICE is part of the cache key. A line rendered in the old voice
        // is unreachable the instant the voice changes - it cannot be served
        // by mistake, which is the only thing a wipe protects against. Stale
        // files are pruned by the 60 MB LRU budget in the normal way.
        //
        // It started to matter the moment ElevenLabs arrived: auditioning
        // voices changes `voiceName` on every tap, so five taps meant five
        // total cache wipes and five full 38-phrase re-warms over the network.
        // It also made the note on `voiceName` a lie, which review caught.
        //
        // Contrast voiceChanged(), which DOES still clear: that one fires on a
        // MODEL change, and the model is not in the key.
        Self.repinSystemVoices()
        Self.geminiVoiceGaveUp = false
        warmCache()
    }

    // MARK: - Speaking-flag lifecycle (deadlock-proof)

    // ==================================================================
    // THE DEADLOCK. Confirmed from the build-80 crash report, not guessed.
    //
    //   Thread 0 (main):
    //     __ulock_wait2
    //     _os_unfair_lock_lock_slow
    //     ObservableObjectPublisher.Inner.send()
    //     Published.subscript.setter
    //     CameraAccess ...
    //   Termination: FRONTBOARD 0x8BADF00D
    //     "Failed to terminate gracefully after 5.0s"
    //
    // The main thread is parked forever on Combine's internal lock inside a
    // @Published setter. That happens when a @Published property is written
    // from a background thread while the main thread is publishing, and
    // `isSpeaking` is written by beginSpeaking()/endSpeaking()/stop(), all of
    // which are called from wherever the caller happens to be: URLSession
    // completion handlers, audio callbacks, Timer fires, async contexts.
    //
    // This is MY regression and I can date it exactly. In build 69 the archive
    // failed with "call to main actor-isolated instance method
    // 'beginSpeaking' in a synchronous nonisolated context", and I removed the
    // @MainActor annotation to make it compile — with a comment claiming
    // "callers are main-thread in practice". They are not. Silencing the
    // compiler's thread-safety warning is what created the hang.
    //
    // Every write to the published flag now goes through here. Already on the
    // main thread, write directly; otherwise hop ASYNC — never sync, which
    // would be a second way to deadlock.
    private func setSpeaking(_ value: Bool, since: Date?) {
        if Thread.isMainThread {
            let changed = isSpeaking != value
            isSpeaking = value
            speakingSince = since
            if changed { Self.speechHaptic(value) }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let changed = self.isSpeaking != value
                self.isSpeaking = value
                self.speakingSince = since
                if changed { Self.speechHaptic(value) }
            }
        }
    }

    /// BUILD 244 — THE TAP THAT SAYS HE'S TALKING.
    ///
    /// With the glasses on and the phone pocketed there is no way to tell
    /// "Chappy is answering" from "Chappy heard nothing" until the first
    /// word arrives — and the first word can be twenty seconds behind the
    /// question when the network voice is cold. A soft tap at the start and
    /// a softer one at the end closes that gap without a screen.
    ///
    /// UIImpactFeedbackGenerator, deliberately, not CoreHaptics: this fires
    /// from arbitrary call sites at arbitrary times, and CHHapticEngine has
    /// to be started, kept alive, and restarted after every audio-session
    /// interruption — which in this app is constantly. An engine that must
    /// survive the audio session is the wrong dependency for the one signal
    /// whose job is to work when the audio path is misbehaving.
    ///
    /// Both generators are kept alive rather than made per call: a freshly
    /// allocated generator has to warm the Taptic Engine before its first
    /// impact, so a throwaway one is reliably late for exactly the event it
    /// is timing.
    ///
    /// UIFeedbackGenerator and everything on it is @MainActor in the SDK,
    /// and TTSService is a plain class whose setSpeaking is deliberately NOT
    /// MainActor-isolated (see the deadlock note above). So the generators
    /// are built and fired inside `Task { @MainActor in }` — which is
    /// exactly the shape ChappyHaptics already uses in LiveAIManager, and
    /// the only shape in this project proven to compile. Reaching for
    /// nonisolated(unsafe) here would be silencing a thread-safety warning
    /// on a file whose worst outage came from doing precisely that.
    @MainActor private static var startHaptic: UIImpactFeedbackGenerator?
    @MainActor private static var endHaptic: UIImpactFeedbackGenerator?

    private static func speechHaptic(_ starting: Bool) {
        guard UserDefaults.standard.object(forKey: "chappy_speech_haptics") == nil
                || UserDefaults.standard.bool(forKey: "chappy_speech_haptics") else { return }
        Task { @MainActor in
            // Kept alive rather than made per call: a freshly allocated
            // generator has to warm the Taptic Engine before its first
            // impact, so a throwaway one is reliably late for exactly the
            // event it is timing.
            if startHaptic == nil { startHaptic = UIImpactFeedbackGenerator(style: .soft) }
            if endHaptic == nil { endHaptic = UIImpactFeedbackGenerator(style: .rigid) }
            if starting {
                startHaptic?.prepare()
                startHaptic?.impactOccurred(intensity: 0.55)
                // Warm the other one now, so the end tap is on time.
                endHaptic?.prepare()
            } else {
                endHaptic?.impactOccurred(intensity: 0.35)
            }
        }
    }


    /// Claim the speaking flag and return the generation token that owns it.
    /// NOT @MainActor: speak()/speakOffline call this synchronously from
    /// nonisolated context and need the token back immediately — annotating it
    /// was a compile error (build 69, caught at archive). State mutation here
    /// matches the file's existing pattern: callers are main-thread in practice.
    private func beginSpeaking(estimatedCharacters: Int) -> Int {
        let gen = bumpGeneration()
        setSpeaking(true, since: Date())

        // Ceiling: no utterance Chappy produces runs longer than this. Even a
        // long Live-AI answer is well under it, so the watchdog can only ever
        // fire on a genuinely lost callback.
        let ceiling = min(60.0, 8.0 + Double(estimatedCharacters) / 8.0)
        speakingWatchdog?.cancel()
        speakingWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ceiling * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.generationIsCurrent(gen), self.isSpeaking else { return }
                print("⏱️ [TTS] Watchdog: speech never reported completion after \(Int(ceiling))s — releasing the mic gate")
                self.setSpeaking(false, since: nil)
                // Unblock anything still parked on a continuation.
                self.resumeSystemContinuation()
                self.systemSynthesizer?.stopSpeaking(at: .immediate)
            }
        }
        return gen
    }

    /// Release the flag, but only if a newer utterance hasn't already claimed it.
    /// Callers hop to the main thread via Task { @MainActor in ... } — the
    /// method itself stays nonisolated so those Tasks compile.
    private func endSpeaking(_ gen: Int) {
        guard generationIsCurrent(gen) else { return }
        setSpeaking(false, since: nil)
        speakingWatchdog?.cancel()
        speakingWatchdog = nil
        // BUILD 180: hand the music back. This is the single funnel every
        // speaking path exits through (they all `defer` to it), so there is
        // no route out of speech that can leave the duck stuck on.
        ChappyAudio.releaseAfterSpeech()
    }

    /// Resume the system-TTS continuation exactly once, from any thread.
    private func resumeSystemContinuation() {
        continuationLock.lock()
        let cont = systemTTSContinuation
        systemTTSContinuation = nil
        continuationLock.unlock()
        cont?.resume()
    }

    // MARK: - Playback Engine

    private func setupPlaybackEngine() {
        playbackEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let playbackEngine = playbackEngine,
              let playerNode = playerNode,
              let playbackFormat = playbackFormat else {
            print("❌ [TTS] Failed to initialize the playback engine")
            return
        }

        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
        playbackEngine.prepare()
        print("✅ [TTS] Playback engine initialized: Float32 @ 24kHz")
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // AUDIT FIX (CRITICAL): this used to force .playback on EVERY
            // spoken line. Any engine holding a microphone tap — Standby's
            // wake-word ear, Live AI's recorder, Continuous Vision's
            // voice-stop — lost its input the moment Chappy opened his mouth,
            // silently and permanently ("standby stops hearing me").
            // .playAndRecord plays exactly as well and never tears down a
            // recording route.
            // FS-2: this used to force mode .spokenAudio on every spoken line,
            // replacing the .voiceChat mode Translate deliberately sets for
            // hardware echo cancellation — and because startRecording() is
            // guarded by !isRecording, .voiceChat was never restored within a
            // conversation. One bubble tap and AEC was off for the rest of it.
            // It also added .allowBluetooth (which the iPhone-mic path
            // deliberately omits, so input could migrate to the glasses) and
            // cleared the output override set by applyOutputRoute.
            //
            // Leave an existing playAndRecord configuration exactly as it is.
            // Only configure the session when nobody else has.
            // BUILD 180 — DUCK ONLY WHILE ACTUALLY SPEAKING.
            //
            // This asked for .duckOthers on every spoken line and then left
            // it there, so the wearer's music stayed held down for as long
            // as Chappy was open rather than for the two seconds Chappy was
            // talking. Paired with the same option on the wake-word ear, it
            // is the whole reason Apple Music went quiet the moment the app
            // came up and came back the moment it closed.
            //
            // A live conversation (Live AI, Translate) still owns the route
            // outright — .voiceChat there is what gives them hardware echo
            // cancellation, and reconfiguring underneath one is the bug this
            // guard was originally written to stop.
            if session.mode == .voiceChat || ChappyAudio.conversationActive {
                try session.setActive(true)
            } else {
                ChappyAudio.apply(.speaking)
            }
        } catch {
            print("⚠️ [TTS] Audio session configuration failed: \(error.localizedDescription) — continuing")
        }
    }

    /// AUDIT P0 (TTS-STALE): these gated on the self-maintained
    /// `isPlaybackEngineRunning` Bool rather than the engine's real state. iOS
    /// stops an engine on route changes and interruptions without asking, so
    /// that flag drifts out of truth and nothing ever corrects it — the exact
    /// mistake already fixed in LiveTranslateService, where the comment reads
    /// "the code trusted its own Bool". Ask the engine.
    // BUILD 175 — THE COLD-START SURRENDER.
    //
    // This gave up on the FIRST failure, and playPCM immediately threw, and a
    // throw means Apple's voice. At launch that first failure is close to
    // guaranteed: the wake-word ear is claiming the input node in the same
    // moment, the audio session has just been activated, and the route is
    // still settling. AVAudioEngine.start() is entitled to refuse for a few
    // hundred milliseconds and then work perfectly.
    //
    // So the very first thing Chappy said on every launch went out in the
    // robot voice, and nothing anywhere recorded why.
    //
    // Now: if it refuses, rebuild the graph (the usual real cause is a node
    // left detached by an earlier route change) and try once more. Returns
    // whether the engine is actually running, so the caller stops guessing.
    @discardableResult
    private func startPlaybackEngine() -> Bool {
        if let e = playbackEngine, e.isRunning { return true }
        for attempt in 0..<2 {
            if playbackEngine == nil || playerNode?.engine == nil {
                setupPlaybackEngine()
            }
            guard let engine = playbackEngine else { continue }
            do {
                try engine.start()
                isPlaybackEngineRunning = true
                if attempt > 0 {
                    print("🔊 [TTS] Playback engine started on the retry - the real voice was saved")
                }
                return true
            } catch {
                isPlaybackEngineRunning = false
                print("⚠️ [TTS] Playback engine refused (attempt \(attempt + 1)): \(error.localizedDescription)")
                // Give the session a moment to settle, then rebuild the graph
                // outright rather than restarting an engine iOS has invalidated.
                //
                // BUILD 219: this was Thread.sleep, which blocks whatever
                // thread it is called on — routinely the main one, in the
                // middle of answering him. usleep on a retry path is no
                // better in principle but this one is bounded and rare;
                // the real fix is that the retry now happens far less
                // often, because the engine is no longer torn down after
                // every single line.
                if Thread.isMainThread {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.12))
                } else {
                    Thread.sleep(forTimeInterval: 0.12)
                }
                configureAudioSession()
                playbackEngine = nil
                playerNode = nil
            }
        }
        print("❌ [TTS] Playback engine would not start twice - falling back for this line only")
        Self.lastFallbackReason = "the audio output would not start"
        Self.lastFallbackAt = Date()
        return false
    }

    /// BUILD 175 — PRIME THE PATH BEFORE THE FIRST WORD.
    ///
    /// Everything above is a rescue. This is the prevention: bring the session
    /// and the engine up once, quietly, a moment after launch, so the line the
    /// wearer is actually waiting on is never the one paying the setup cost.
    /// Makes no sound and holds nothing open.
    func primeVoicePath() {
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run {
                guard let self else { return }
                guard !self.isSpeaking else { return }
                self.configureAudioSession()
                if self.startPlaybackEngine() {
                    self.stopPlaybackEngine()
                    print("🔊 [TTS] Voice path primed - first line goes out in Chappy's own voice")
                }
            }
        }
    }

    /// BUILD 219 — tear the engine down only once he has actually
    /// stopped being spoken to.
    ///
    /// Four seconds is longer than the gap between sentences in an
    /// answer and shorter than any pause in a conversation, so a run of
    /// lines keeps one engine and a finished answer still releases it.
    private var engineIdleWork: DispatchWorkItem?

    private func scheduleEngineIdle() {
        engineIdleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isSpeaking else { return }
            self.stopPlaybackEngine()
        }
        engineIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func stopPlaybackEngine() {
        if let node = playerNode, node.engine != nil {
            node.stop()
            node.reset()
        }
        if let playbackEngine, playbackEngine.isRunning {
            playbackEngine.stop()
        }
        isPlaybackEngineRunning = false
    }

    /// AUDIT P0 (TTS-STALE): a media-services reset detaches playerNode and
    /// leaves `node.engine == nil` — every later scheduleBuffer would then throw
    /// an ObjC exception straight through Swift's try/catch and take the app
    /// down. TTSService was the only audio component in the app with no
    /// interruption or reset observer at all.
    private func installPlaybackResilience() {
        guard !playbackResilienceInstalled else { return }
        playbackResilienceInstalled = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            print("🔊 [TTS] Media services reset — rebuilding playback engine")
            self.isPlaybackEngineRunning = false
            self.playbackEngine = nil
            self.playerNode = nil
            self.setupPlaybackEngine()
        }
    }

    // MARK: - Public Methods

    /// Pre-configure the audio session (call before stopping the stream)
    func prepareAudioSession() {
        configureAudioSession()
        print("🔊 [TTS] Audio session pre-configured")
    }

    /// Speak text.
    /// Priority: Gemini TTS (natural voice) → Apple system TTS (offline fallback).
    /// The apiKey parameter is accepted for backward compatibility but ignored;
    /// the Gemini key is read from the key store.
    /// FS-11: for saved phrases and replays we already KNOW the language, and
    /// the UI promises they work with no connection. Going through the network
    /// voice first meant a stalled 8-second socket on one bar of EDGE — the
    /// exact condition the feature exists for — with nothing on screen to say
    /// so. This path skips the network entirely.
    func speakOffline(_ text: String, languageCode: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentTask?.cancel()
        stop()
        let gen = beginSpeaking(estimatedCharacters: trimmed.count)
        currentTask = Task { [weak self] in
            guard let self else { return }
            // SB-DEADLOCK FIX: `defer` releases the flag on EVERY exit —
            // normal return, early return, thrown error, cancellation — where
            // the old `if !Task.isCancelled` guard released it on almost none.
            defer { Task { @MainActor in self.endSpeaking(gen) } }

            // BUILD 125: "offline" used to mean "Apple's voice", because the
            // only way to avoid the network was to avoid Gemini. With a disk
            // cache it no longer does — a saved phrase you have heard before
            // plays in Chappy's real voice with the radio off, which is the
            // whole point of saved phrases. Still zero network either way.
            let voice = self.voiceName
            if voice != "System",
               let cached = VoiceCache.shared.load(text: trimmed, voice: voice) {
                do {
                    try await self.playPCM(cached, gen: gen)
                    return
                } catch {
                    if Task.isCancelled { return }
                }
            }
            await self.fallbackToSystemTTS(text: trimmed, languageCode: languageCode)
        }
    }

    // MARK: - BUILD 125: cache warm-up

    /// The lines Chappy actually repeats. Rendering these once on wifi means
    /// the wearer effectively never hears a cold one — every confirmation,
    /// refusal and nav call comes off the disk instantly, in the real voice,
    /// for the rest of the phone's life.
    ///
    /// Pulled from the literal `speak(...)` calls in LiveAIManager, so this is
    /// the vocabulary as it actually exists rather than a guess at it.
    private static let warmPhrases: [String] = [
        "Got it.", "Done.", "Noted.", "Saved.", "No worries.", "I'm listening.",
        "Route's off.", "Map's up.", "Right, heading home.", "Let me get you home.",
        "Opening Live AI.", "Opening Google Maps.", "Memory's open.",
        "Having a look.", "Let me look.", "Let me read it.", "Eyes open.",
        "Reading that now.", "Reading through them now.", "Checking the label.",
        "Where do you want to go?", "What should I log?", "Remember what?",
        "Here's your list.", "Nothing to snooze.", "Nothing new to import.",
        "Nothing photographed today.", "Nothing left to read through.",
        "No GPS fix yet.", "Finding you another way.", "Quiet mode.",
        "Tour mode.", "Budget mode on.", "Back to normal.",
        "One thing at a time - still on the last.",
        "I don't have a reminder like that.",
        "I don't speak that one yet, sorry.",
        "Just quiet, or stop the route as well?",
        "That deserves a proper conversation - give me a moment."
    ]

    /// Render anything in the warm list that isn't cached yet. Serial, gentle,
    /// and silent — it never plays a sound. Safe to call on every launch: once
    /// the set is on disk this does nothing at all.
    func warmCache() {
        // BUILD 272 — WARM THE PROVIDER THAT IS ACTUALLY SPEAKING.
        //
        // Rendering ahead through Google while ElevenLabs does the talking
        // would write into a keyspace the live path never looks in: a Google
        // call per line, bought and thrown away. See warmElevenLabs for why
        // this dispatches rather than simply returning.
        guard ChappyVoiceProvider.current == .gemini else {
            warmElevenLabs(Self.warmPhrases)
            return
        }
        let voice = geminiVoiceName   // a Gemini render, so a Gemini key
        guard voice != "System" else { return }
        let key = APIKeyManager.shared.getGoogleAPIKey() ?? ""
        guard !key.isEmpty else { return }

        let missing = Self.warmPhrases.filter { !VoiceCache.shared.has(text: $0, voice: voice) }
        guard !missing.isEmpty else {
            print("🔊 [TTS] Voice cache warm (\(VoiceCache.shared.fileCount) lines)")
            return
        }

        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            print("🔊 [TTS] Warming the voice cache — \(missing.count) lines to render")
            var made = 0
            for phrase in missing {
                // One at a time, with a breath between, so warming never
                // competes with a line the wearer is actually waiting on.
                if Self.geminiVoiceGaveUp { break }
                do {
                    let audio = try await self.requestGeminiAudio(
                        text: phrase, model: self.ttsModels[0], apiKey: key)
                    VoiceCache.shared.save(audio, text: phrase, voice: voice)
                    CostMeter.shared.addTTSChars(phrase.count)
                    made += 1
                } catch {
                    // A warm-up is a nicety. If it can't run, the normal path
                    // still renders on demand — never surface this.
                    print("🔊 [TTS] Warm-up stopped: \(error.localizedDescription)")
                    break
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            print("🔊 [TTS] Voice cache warmed — \(made) new lines")
        }
    }

    /// Called when the wearer picks a different voice in Settings: the old
    /// voice's audio is dead weight, and the Apple fallback needs to re-match.
    func voiceChanged() {
        VoiceCache.shared.clear()
        Self.repinSystemVoices()
        Self.geminiVoiceGaveUp = false
        warmCache()
    }

    /// BUILD 132 — ONE VOICE ON THE ROAD.
    ///
    /// Nav lines are unique ("Turn left onto Ann Street") so the warm list can
    /// never hold them — every turn was a live network render, and the first
    /// render that failed in traffic latched the Apple fallback for half an
    /// hour. The wearer heard the robot voice precisely when Chappy was doing
    /// its most impressive thing.
    ///
    /// So: the moment a route is computed, render EVERY step of it into the
    /// cache in the background. By the time the wearer reaches turn one, the
    /// whole route speaks from disk — instant, offline-proof, in the ONE voice.
    func prerender(_ lines: [String]) {
        // BUILD 272 — WARM THE PROVIDER THAT IS ACTUALLY SPEAKING.
        //
        // Rendering ahead through Google while ElevenLabs does the talking
        // would write into a keyspace the live path never looks in: a Google
        // call per line, bought and thrown away. See warmElevenLabs for why
        // this dispatches rather than simply returning.
        guard ChappyVoiceProvider.current == .gemini else {
            warmElevenLabs(lines, after: 8_000_000_000)
            return
        }
        let voice = geminiVoiceName   // a Gemini render, so a Gemini key
        guard voice != "System" else { return }
        let key = APIKeyManager.shared.getGoogleAPIKey() ?? ""
        guard !key.isEmpty else { return }
        let missing = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !VoiceCache.shared.has(text: $0, voice: voice) }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // BUILD 135: the route summary is being rendered and SPOKEN right
            // now, over the same network the route lookup just used. Starting
            // the pre-render in the same instant caused the very failure it
            // exists to prevent — a rate-limited render latching the robot
            // voice. Wait for the summary to finish before warming the turns.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            print("🔊 [TTS] Pre-rendering \(missing.count) nav lines")
            for line in missing {
                if Self.geminiVoiceGaveUp { break }
                do {
                    let audio = try await self.requestGeminiAudio(
                        text: line, model: self.ttsModels[0], apiKey: key)
                    VoiceCache.shared.save(audio, text: line, voice: voice)
                    CostMeter.shared.addTTSChars(line.count)
                } catch {
                    // A pre-render is a nicety; the normal path still renders
                    // on demand. Never latch the fallback over one of these.
                    print("🔊 [TTS] Pre-render stopped: \(error.localizedDescription)")
                    break
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    // =================================================================
    // BUILD 158 — SPEAKING LONG ANSWERS WITHOUT THE WAIT
    // =================================================================
    //
    //   Gemini renders audio at roughly 25 tokens a second, so a
    //   paragraph-length answer takes fifteen to twenty seconds to
    //   generate before a single word can play. Quick Vision showed the
    //   text instantly and then sat in silence — which felt broken even
    //   though nothing was.
    //
    //   Every streaming assistant solves this the same way: don't render
    //   the paragraph, render the FIRST SENTENCE. It comes back in about
    //   two seconds and starts playing while sentence two renders behind
    //   it. Same voice, same quality, first word roughly nine times
    //   sooner.
    //
    //   Short lines (one sentence, under ~140 characters) go straight
    //   down the normal path — chunking them would only add overhead.

    /// BUILD 219 — the entry point every spoken reply should use.
    ///
    /// Picks between the two existing paths on the one criterion that
    /// matters: is this exact line already on disk?
    ///
    ///   * Cached — play it whole. This is the fast path and chunking it
    ///     would wreck it, because the pieces are not cached.
    ///   * Not cached, and long enough to have a second sentence — chunk
    ///     it. The first sentence starts while the rest are still being
    ///     rendered, which is the difference between a 1.5 second wait
    ///     and a 0.4 second one.
    ///   * Short — one render. Splitting "Saved." helps nobody.
    ///
    /// The 80-character floor exists so a two-clause acknowledgement is
    /// not split into two network calls to save nothing.
    func speakSmart(_ text: String, languageCode: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // REVIEW FIX (BUILD 272) - provider-aware; see the note in speak().
        let wantsSystemVoice = ChappyVoiceProvider.current == .gemini
            && geminiVoiceName == "System"

        if !wantsSystemVoice, VoiceCache.shared.has(text: trimmed, voice: voiceName) {
            speak(trimmed, languageCode: languageCode)
            return
        }

        // BUILD 260 — THE SHORT-LINE DEVICE VOICE IS GONE, AND IT HAD TO GO.
        //
        // 258 sent every line of thirty characters or less to AVSpeechSynthesizer
        // because Gemini took three and a half seconds to say "Done." That was
        // the right call against a whole-clip renderer. 259 made the renderer
        // stream, so the reason is gone — and the cost was not.
        //
        // HE HEARD IT ON THE GLASSES AND THE PHONE AT THE SAME TIME, and this
        // is why. Two different players were live in the same app:
        // AVSpeechSynthesizer for short lines and AVAudioEngine for everything
        // else. They do not share a route decision. TTSService has never
        // called overrideOutputAudioPort — LiveTranslateService does, which is
        // why translate has always had a working HEAR GLASSES / HEAR PHONE
        // switch and this never did — so each player lands wherever the
        // session's options leave it, and `.speaking` carries BOTH
        // .defaultToSpeaker and .allowBluetooth. Two players, one ambiguous
        // route each, and a window where both are running: stop() resets the
        // engine node while the streaming task may still schedule a buffer or
        // two behind it, and the synthesizer starts on top.
        //
        // One player. One route. If a short line is ever slow again the answer
        // is to make the render faster or pre-warm the cache, not to run a
        // second audio stack alongside the first.
        if trimmed.count >= 80, Self.sentenceChunks(trimmed).count > 1 {
            speakLong(trimmed, languageCode: languageCode)
            return
        }
        speak(trimmed, languageCode: languageCode)
    }

    func speakLong(_ text: String, languageCode: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let chunks = Self.sentenceChunks(trimmed)
        guard chunks.count > 1 else {
            speak(trimmed, languageCode: languageCode)
            return
        }
        // First chunk out loud immediately; the rest queue behind it.
        speak(chunks[0], languageCode: languageCode)
        let rest = Array(chunks.dropFirst())
        // BUILD 162 — WHY THE VOICE WENT HALF-ROBOT.
        //
        // This used to fire prerenderNow(rest) in the same instant as the
        // live render of chunk one — several Gemini TTS calls at once, over
        // the same connection. That is a 429 waiting to happen, and two
        // consecutive failures latch the Apple fallback for five minutes.
        // It is precisely the mistake BUILD 135 documented for navigation,
        // repeated here.
        //
        // Now: warm only ONE chunk ahead, and only after the current one is
        // actually speaking. Same seamlessness, a quarter of the requests,
        // no thundering herd.
        // No chunkTask?.cancel() here: speak(chunks[0]) above already ran
        // stop(), which cancelled and nilled any previous answer's queue —
        // and chunkLoopIsSpeaking is false out here, so that cancel lands.
        // A second one would be a line that can never do anything.
        //
        // Built first, published second. Holding the lock across the Task
        // literal would work — there is no suspension point before the
        // unlock, so the body cannot start and deadlock on the same
        // non-recursive lock — but "works because of where the suspension
        // points happen to be" is not a property worth relying on.
        let task = Task { @MainActor in
            for chunk in rest {
                self.prerenderNow([chunk])
                // Wait for the current line to finish, with a hard ceiling
                // so a stuck player can never freeze the rest of the answer.
                var waited = 0
                while self.isSpeaking && waited < 600 {
                    // BUILD 254: bail on cancel rather than spinning. Once
                    // the task is cancelled Task.sleep returns instantly,
                    // so this loop would burn six hundred immediate awaits
                    // on the main actor before reaching the check below.
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
                if Task.isCancelled { return }
                // BUILD 254: flagged, so the stop() inside speak() does not
                // cancel the very loop that is calling it.
                self.chunkLock.lock(); self.chunkLoopIsSpeaking = true; self.chunkLock.unlock()
                self.speak(chunk, languageCode: languageCode)
                self.chunkLock.lock(); self.chunkLoopIsSpeaking = false; self.chunkLock.unlock()
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
        }
        chunkLock.lock()
        chunkTask = task
        chunkLock.unlock()
    }

    /// Like prerender, but without the eight-second politeness delay —
    /// used when the lines are about to be spoken in the next breath.
    private func prerenderNow(_ lines: [String]) {
        // BUILD 272 — WARM THE PROVIDER THAT IS ACTUALLY SPEAKING.
        //
        // Rendering ahead through Google while ElevenLabs does the talking
        // would write into a keyspace the live path never looks in: a Google
        // call per line, bought and thrown away. See warmElevenLabs for why
        // this dispatches rather than simply returning.
        guard ChappyVoiceProvider.current == .gemini else {
            warmElevenLabs(lines)
            return
        }
        let voice = geminiVoiceName   // a Gemini render, so a Gemini key
        guard voice != "System" else { return }
        let key = APIKeyManager.shared.getGoogleAPIKey() ?? ""
        guard !key.isEmpty else { return }
        // BUILD 258 — DON'T RENDER THE SAME LINE TWICE AT ONCE.
        //
        // `has()` stays false for the three or four seconds a render takes, so
        // asking for the same uncached line twice inside that window fired two
        // identical Gemini renders, charged the meter twice and wrote the same
        // cache file twice. Harmless before, when this was only called from
        // the warm list; it matters now that every short line comes through
        // here — say "flights" twice in quick succession and that is exactly
        // the shape.
        var missing = lines.filter { !VoiceCache.shared.has(text: $0, voice: voice) }
        inFlightLock.lock()
        missing = missing.filter { Self.rendersInFlight.insert($0).inserted }
        inFlightLock.unlock()
        guard !missing.isEmpty else { return }
        let claimed = missing
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // Released on EVERY exit — the break paths above included, or a
            // line that failed once could never be retried for the life of
            // the process.
            defer {
                self.inFlightLock.lock()
                for l in claimed { Self.rendersInFlight.remove(l) }
                self.inFlightLock.unlock()
            }
            for line in missing {
                if Self.geminiVoiceGaveUp { break }
                do {
                    let audio = try await self.requestGeminiAudio(
                        text: line, model: self.ttsModels[0], apiKey: key)
                    VoiceCache.shared.save(audio, text: line, voice: voice)
                    CostMeter.shared.addTTSChars(line.count)
                } catch {
                    // A warm-up is a nicety. It must never contribute to the
                    // failure count that latches the robot voice.
                    print("🔊 [TTS] Warm-up skipped: \(error.localizedDescription)")
                    break
                }
                // BUILD 162: breathing room between renders, same 350ms the
                // nav pre-render has always used. Back-to-back calls are what
                // earn a 429.
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    /// Split on sentence ends, then glue the short ones together — a
    /// three-word sentence on its own costs a whole round trip for
    /// nothing. Target is roughly 140 characters a chunk.
    static func sentenceChunks(_ text: String, target: Int = 140) -> [String] {
        var out: [String] = []
        var current = ""
        var sentence = ""
        for ch in text {
            sentence.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                sentence = ""
                guard !s.isEmpty else { continue }
                if current.isEmpty { current = s }
                else if current.count + s.count + 1 <= target { current += " " + s }
                else { out.append(current); current = s }
            }
        }
        let tail = (current + " " + sentence).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out.filter { !$0.isEmpty }
    }

    /// - Parameters:
    ///   - languageCode: AUDIT P1. The short-line fast path bypassed the
    ///     Gemini call, and with it the language handling — a short Indonesian
    ///     or Thai line was read aloud in an Australian accent. Pass the
    ///     language when you know it.
    ///   - forceNetworkVoice: AUDIT P1. Every voice sample in Settings is under
    ///     90 characters, so the fast path sent them ALL to the system voice —
    ///     the voice picker and "Test the voice" demonstrated a voice you were
    ///     not choosing. Settings passes true so you hear the real thing.
    func speak(_ text: String,
               apiKey: String? = nil,
               languageCode: String? = nil,
               forceNetworkVoice: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any previous speech
        currentTask?.cancel()
        stop()

        lastSpokenLine = trimmed
        lastSpokenAt = Date()
        noticeVoiceChange()
        let gen = beginSpeaking(estimatedCharacters: trimmed.count)
        currentTask = Task { [weak self] in
            guard let self else { return }
            // SB-DEADLOCK FIX: see speakOffline — one release point, all exits.
            defer { Task { @MainActor in self.endSpeaking(gen) } }

            let googleKey = APIKeyManager.shared.getGoogleAPIKey() ?? ""
            // REVIEW FIX (BUILD 272) - PROVIDER-AWARE, AND THIS ONE WOULD
            // HAVE BEEN THE FIRST THING HE HIT.
            //
            // "System" is an entry in the GOOGLE voice list and this test knew
            // nothing about providers. So picking ElevenLabs while "System"
            // was still selected gave Apple's robot voice with Settings
            // showing ElevenLabs as the provider - which is indistinguishable
            // from "the new voice doesn't work", and unfalsifiable from the
            // log.
            let wantsSystemVoice = ChappyVoiceProvider.current == .gemini
                && self.geminiVoiceName == "System"

            // BUILD 125 — ONE VOICE, ALWAYS.
            //
            // BUILD 274 QUALIFIES THIS, and the qualification should be here
            // rather than only in the settings footer. Live AI and Live
            // Translate speak through Gemini's realtime socket, which carries
            // its own voice and knows nothing about providers. So with
            // ElevenLabs selected the app genuinely does have two voices: the
            // fast one for everything on this path, and the Google one inside
            // a live session. There is no cheap fix - no ElevenLabs equivalent
            // exists inside a realtime socket - so it is a deliberate trade,
            // not an oversight, and the claim below is now "one voice on this
            // path" rather than one voice in the app.
            //
            // The old code here split by LENGTH: anything under 90 characters
            // went to Apple's voice because Gemini is a network round trip and
            // short acknowledgements have to be instant. It worked, and it made
            // Chappy change sex every other sentence. Length is not a sane way
            // to choose a voice.
            //
            // Now there is exactly one voice, and speed comes from the disk
            // instead. Short lines repeat — "Route's off", "Map's up", "Saved"
            // — so the first time costs a round trip and every time after is a
            // file read. Faster than what it replaced, in the right voice, and
            // it works with no signal at all.
            //
            // Apple's voice is now a genuine last resort: no key, no cached
            // copy, and no network. When it does speak it speaks as ONE pinned
            // voice (see systemVoice) rather than whatever iOS picks that day.
            let voice = self.voiceName
            // REVIEW FIX - THE ID IS SNAPSHOT HERE, BESIDE THE KEY IT MUST
            // AGREE WITH.
            //
            // My first attempt put these two lines just above the ElevenLabs
            // call, which review correctly called a no-op: there is no await
            // between there and the render, so it was identical to reading the
            // property inline. The window that actually matters is the
            // corrupt-cache retry BELOW this line, which awaits playPCM twice
            // and sleeps 400ms. Tap a different voice inside that window and
            // the old code rendered voice B and filed it under voice A's key -
            // cache poisoning that survives a restart.
            let elevenVoice = ChappyVoiceProvider.elevenVoiceID
            let elevenModel = ChappyVoiceProvider.elevenModel

            // 1. DISK. Instant, offline, right voice.
            if !wantsSystemVoice, !forceNetworkVoice,
               let cached = VoiceCache.shared.load(text: trimmed, voice: voice) {
                do {
                    try await self.playPCM(cached, gen: gen)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    // BUILD 174: this assumed a cached file that won't play is
                    // CORRUPT — so it deleted good audio and re-rendered over
                    // the network. But the usual cause is the audio session
                    // being busy for a moment (camera waking, route changing),
                    // and the file is perfectly fine. Try it once more before
                    // throwing away audio we already paid for.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if Task.isCancelled { return }
                    if let again = VoiceCache.shared.load(text: trimmed, voice: voice),
                       (try? await self.playPCM(again, gen: gen)) != nil {
                        return
                    }
                    if Task.isCancelled { return }
                    try? FileManager.default.removeItem(
                        at: VoiceCache.shared.url(text: trimmed, voice: voice))
                    print("⚠️ [TTS] Cached line wouldn't play twice — re-rendering")
                }
            }

            // 1.5 THE FAST VOICE, IF HE HAS CHOSEN IT.
            //
            // Placed above Google and below the cache, which is the only
            // position that is right: a cached line must never re-render, and
            // a provider that answers in 75ms must never wait behind one that
            // takes seconds.
            //
            // A failure here falls THROUGH to Google rather than out to the
            // Apple voice. That is the whole argument for having two paid
            // providers: they are on different companies, different keys and
            // different quotas, so the failure that took Chappy's voice out on
            // 18 August cannot take both. Three tiers now - ElevenLabs, then
            // Google, then the device - and only the last one is robotic.
            //
            // No latch. The Gemini path has geminiVoiceGaveUp because a Gemini
            // render used to cost twenty seconds, so repeating a doomed one
            // was expensive. A Flash call that is going to fail fails in well
            // under a second, and a latch here would keep him on the slow
            // voice long after the blip had passed.
            // BUILD 275 — SAY WHICH DOOR YOU WENT THROUGH.
            //
            // 274 shipped ElevenLabs and it never once ran on his phone, and
            // NOTHING IN THE LOG SAID SO. All he could see was Gemini 429s -
            // which look identical whether ElevenLabs was tried and failed,
            // or was never reached at all. I had to read the source to find
            // out, and that is the same blindness build 271 fixed for the
            // emergency voice. Once per change, so it cannot go stale and
            // cannot spam.
            let providerNow = ChappyVoiceProvider.current
            let ready = ChappyVoiceProvider.elevenReady
            let stamp = "\(providerNow.rawValue)/\(ready)/\(wantsSystemVoice)"
            if stamp != Self.lastProviderStamp {
                Self.lastProviderStamp = stamp
                if wantsSystemVoice {
                    ChappyStandbyLog.note("🗣️ [TTS] Voice: the phone's own — 'System' is picked in Settings")
                } else if providerNow == .elevenLabs, ready {
                    ChappyStandbyLog.note("🗣️ [TTS] Voice: ElevenLabs, with Google behind it")
                } else if providerNow == .elevenLabs {
                    let noKey = (APIKeyManager.shared.getElevenLabsKey() ?? "").isEmpty
                    ChappyStandbyLog.note("🗣️ [TTS] Voice: GOOGLE — ElevenLabs is selected but "
                        + (noKey ? "there is no key" : "no voice is chosen"))
                } else {
                    ChappyStandbyLog.note("🗣️ [TTS] Voice: Google — ElevenLabs is not selected")
                }
            }

            if !wantsSystemVoice, ChappyVoiceProvider.elevenReady,
               let elevenKey = APIKeyManager.shared.getElevenLabsKey(), !elevenKey.isEmpty {
                do {
                    let audio = try await self.streamElevenLabsAudio(
                        text: trimmed,
                        voiceID: elevenVoice,
                        model: elevenModel,
                        apiKey: elevenKey, gen: gen)
                    VoiceCache.shared.save(audio, text: trimmed, voice: voice)
                    Self.lastElevenFailure = nil     // proof of life
                    // REVIEW FIX - NOT CostMeter.addTTSChars. That bucket gets
                    // multiplied by GOOGLE's per-character rate, so counting
                    // ElevenLabs characters into it makes "Estimated today"
                    // quietly wrong whenever the fast voice is in use. There
                    // is a better number anyway: ElevenLabs reports his real
                    // usage against his real plan, and the settings screen
                    // reads it directly. An exact figure from the source beats
                    // an estimate at the wrong rate.
                    return
                } catch is CancellationError {
                    return                       // barged in on — normal
                } catch {
                    if Task.isCancelled { return }
                    // Remember WHAT it refused with, so voiceStatusLine can
                    // answer "why does it sound like Google" with a fact.
                    if let te = error as? TTSError, case .httpError(let code) = te {
                        Self.lastElevenFailure = (code, Date())
                    } else {
                        Self.lastElevenFailure = (0, Date())
                    }
                    ChappyStandbyLog.note("↩️ [11L] Failed (\(error.localizedDescription)) — Google for this line")
                }
            }

            // 2. NETWORK. Renders, plays, and keeps the audio for next time.
            // REVIEW FIX - AND I BROKE THIS IN THE LAST ROUND.
            //
            // Making wantsSystemVoice provider-aware fixed one bug and opened
            // another: with ElevenLabs selected it is always false, so a user
            // whose GOOGLE voice is still set to "System" now falls into this
            // branch and Chappy sends "voiceName": "System" to Google, which
            // is a 400. Twice per line, 800ms apart, then a five-minute latch
            // - where before he simply got the Apple voice instantly.
            //
            // "System" is not a Google voice under any provider, so the test
            // belongs here as well and not only in wantsSystemVoice.
            if !googleKey.isEmpty, !wantsSystemVoice,
               self.geminiVoiceName != "System", !Self.geminiVoiceGaveUp {
                do {
                    try await self.speakWithGemini(text: trimmed, apiKey: googleKey, gen: gen)
                    // Only charge for audio that genuinely reached the speaker.
                    CostMeter.shared.addTTSChars(trimmed.count)
                    return
                } catch {
                    if Task.isCancelled { return }
                    // BUILD 135 — WHY NAV WENT ROBOT.
                    //
                    // One failed render latched the Apple voice for thirty
                    // minutes — and navigation is EXACTLY where one render
                    // fails: the route lookup, the geocode and the TTS all
                    // hit the network in the same two seconds, and a single
                    // dropped socket or 429 was enough. So the latch now
                    // costs TWO consecutive failures, with a breath between.
                    // Transient blips retry and stay in the real voice;
                    // genuine outages still fall back exactly as before.
                    // BUILD 248 — DON'T RETRY A TIMEOUT.
                    //
                    // THIS is where the 20-30 seconds comes from. The render
                    // timeout is 20s, and on ANY failure this retried the
                    // whole request: 20s + 0.8s + up to 20s more before the
                    // offline voice was even considered. One dropped socket
                    // and he waits forty seconds for a sentence.
                    //
                    // The retry is right for a 429, a 5xx or a dropped
                    // connection — those are transient and a second attempt
                    // usually works. It is pointless for a TIMEOUT: the
                    // service already had twenty seconds and did not answer,
                    // so asking again identically buys nothing and costs
                    // another twenty. Fall back to the offline voice, which
                    // is instant, and let the cooldown logic latch as before.
                    let ns = error as NSError
                    let timedOut = ns.domain == NSURLErrorDomain
                        && (ns.code == NSURLErrorTimedOut
                            || ns.code == NSURLErrorNetworkConnectionLost
                            || ns.code == NSURLErrorNotConnectedToInternet)
                    if timedOut {
                        Self.geminiVoiceGaveUp = true
                        Self.lastFallbackReason = error.localizedDescription
                        Self.lastFallbackAt = Date()
                        ChappyStandbyLog.note("⚠️ [TTS] Render timed out — offline voice now, not retrying (that retry was the second twenty seconds)")
                    } else {
                    do {
                        try await Task.sleep(nanoseconds: 800_000_000)
                        if Task.isCancelled { return }
                        try await self.speakWithGemini(text: trimmed, apiKey: googleKey, gen: gen)
                        CostMeter.shared.addTTSChars(trimmed.count)
                        return
                    } catch {
                        if Task.isCancelled { return }
                        Self.geminiVoiceGaveUp = true
                        Self.lastFallbackReason = error.localizedDescription
                        Self.lastFallbackAt = Date()
                        print("⚠️ [TTS] Gemini TTS failed twice (\(error.localizedDescription)) — Apple voice until the cooldown clears")
                    }
                    }   // BUILD 248: closes the `if timedOut { … } else {`
                }
            } else if googleKey.isEmpty {
                // BUILD 175: this was the quietest failure in the whole app.
                // An empty key here almost never means "the wearer never set
                // one" - it means the Keychain refused the read because the
                // phone was locked. Say which, so the voice status line and
                // the self-test stop shrugging.
                let locked = APIKeyManager.lastKeychainStatus == errSecInteractionNotAllowed
                Self.lastFallbackReason = locked
                    ? "the phone was locked when the key was read"
                    : "no Gemini key is set"
                Self.lastFallbackAt = Date()
                print("⚠️ [TTS] No Gemini key available (\(Self.lastFallbackReason)) - system TTS for this line")
            }

            // 3. LAST RESORT.
            await self.fallbackToSystemTTS(text: trimmed, languageCode: languageCode)
        }
    }

    /// Stop speaking — the sentence AND everything queued behind it.
    func stop() {
        currentTask?.cancel()
        currentTask = nil
        // BUILD 254: the rest of the answer, not just the sentence in the
        // wearer's ear. Skipped when the chunk loop itself is the caller —
        // see chunkLoopIsSpeaking.
        chunkLock.lock()
        let loopIsCalling = chunkLoopIsSpeaking
        let queued = chunkTask
        if !loopIsCalling { chunkTask = nil }
        chunkLock.unlock()
        if !loopIsCalling { queued?.cancel() }
        stopPlaybackEngine()
        systemSynthesizer?.stopSpeaking(at: .immediate)
        // SB-DEADLOCK FIX: atomic, single-resume. The old code read the
        // continuation, resumed it and nilled it in three separate steps with
        // no lock, so a delegate callback landing between them resumed the same
        // continuation twice — an immediate hard crash, not an exception.
        resumeSystemContinuation()
        setSpeaking(false, since: nil)
        speakingWatchdog?.cancel()
        speakingWatchdog = nil
    }

    // MARK: - Gemini TTS

    // BUILD 174 — WHY THE VOICE WAS STILL ONLY MOSTLY GEMINI.
    //
    // This is the one I missed. The render and the PLAYBACK sat inside the
    // same do/catch, so a playback failure threw exactly like a network
    // failure — and the caller treats a throw as "the service is down":
    // it retries the whole render, and if that stumbles too it latches the
    // Apple voice for five minutes.
    //
    // But playback fails for reasons that have nothing to do with Gemini.
    // The audio session gets contested when the glasses camera wakes, when
    // a route change lands, when Live AI takes the mic, when media services
    // reset. Those are the exact moments Chappy speaks most — so the nicer
    // voice was being punished for the audio system's problems, over and
    // over, and it looked random because the cause was invisible.
    //
    // Now the two are separated. A render that SUCCEEDS is proof the
    // service is fine, whatever playback then does: the audio is cached,
    // playback is retried once from that cache, and a playback failure
    // NEVER latches the fallback. Only a genuine render failure can.
    private func speakWithGemini(text: String, apiKey: String, gen: Int) async throws {
        var lastError: Error = TTSError.unknown

        // REVIEW FIX - snapshot the list ONCE.
        //
        // ttsModels is computed from UserDefaults now, and this loop runs on a
        // background task while the picker that writes those defaults runs on
        // the main one. Re-reading it for the bounds check and again for the
        // subscript meant the count could drop to 1 between the two and index
        // 1 would trap. Read it once; the whole call uses one list.
        let models = ttsModels
        for (modelIndex, model) in models.enumerated() {
            let audio: Data
            // BUILD 248 — WHERE THE TWENTY SECONDS GOES.
            //
            // Two models are tried in order, each with its own network
            // timeout, and until now neither the attempt nor its duration was
            // recorded anywhere. So "the first chunk takes 20-30 seconds" had
            // no way to be attributed: a dead first model timing out, a slow
            // render, a slow PLAYBACK start, or the offline fallback kicking
            // in all look identical from the outside — silence, then a voice.
            let began = Date()

            // BUILD 259 — TRY STREAMING FIRST, AND MEAN IT ONLY ONCE.
            //
            // On a streaming-capable model the audio starts on the first
            // chunk, so this branch both renders AND plays, and returns
            // straight out. Anything at all going wrong sends us down the
            // proven whole-clip path below with nothing lost — and switches
            // streaming off for FIVE MINUTES, because a path that failed once
            // in this file has a habit of failing again and the failure mode
            // is silence. Five, not forever: see the note on streamingGaveUp.
            if !Self.streamingGaveUp, modelStreams(model) {
                do {
                    let streamed = try await streamGeminiAudio(text: text, model: model,
                                                               apiKey: apiKey, gen: gen)
                    let ms = Int(Date().timeIntervalSince(began) * 1000)
                    ChappyStandbyLog.note("⚡ [TTS] \(model) streamed \(text.count) characters, \(ms)ms end to end")
                    VoiceCache.shared.save(streamed, text: text, voice: geminiVoiceName)
                    Self.geminiVoiceGaveUp = false
                    return
                } catch is CancellationError {
                    return                     // barged in on — normal
                } catch TTSError.modelNotFound {
                    ChappyStandbyLog.note("⚠️ [TTS] \(model) has no streaming endpoint — whole-clip from here")
                    Self.streamingGaveUp = true
                } catch {
                    if Task.isCancelled { return }
                    ChappyStandbyLog.note("⚠️ [TTS] Streaming failed (\(error.localizedDescription)) — whole-clip for the next five minutes")
                    Self.streamingGaveUp = true
                }
            }

            do {
                audio = try await requestGeminiAudio(text: text, model: model, apiKey: apiKey)
                try Task.checkCancellation()
                let ms = Int(Date().timeIntervalSince(began) * 1000)
                if ms > 1500 {
                    ChappyStandbyLog.note("🐢 [TTS] \(model) took \(ms)ms to render \(text.count) characters")
                }
            } catch TTSError.modelNotFound {
                let ms = Int(Date().timeIntervalSince(began) * 1000)
                ChappyStandbyLog.note("⚠️ [TTS] \(model) not found after \(ms)ms — trying the next one")
                lastError = TTSError.modelNotFound
                continue
            } catch {
                let ms = Int(Date().timeIntervalSince(began) * 1000)
                ChappyStandbyLog.note("⚠️ [TTS] \(model) failed after \(ms)ms: \(error.localizedDescription)")

                // BUILD 271 - THE FALLBACK MODEL WAS NEVER TRIED.
                //
                // This list has two models in it precisely so that a bad day
                // on the first one lands on the second. Only a 404 ever
                // reached the `continue` above; every other failure threw
                // straight out of the loop, so gemini-2.5-flash-preview-tts
                // has sat here unused since the day it was added.
                //
                // That matters most in the exact case he hit. A 429 on a
                // PREVIEW model is the likeliest 429 there is, because Google
                // puts its tightest caps there. What the second model buys is
                // narrower than I first wrote: per-MODEL caps are separate, so
                // it helps when the refusal was this model's own, and not at
                // all when the whole project is capped. See the note on
                // ChappyModels.ttsFallback - all three speech models Google
                // offers are previews and there is no GA one to fall back to.
                // Either way Chappy went mute with a candidate voice one line
                // below it, untried.
                //
                // Retryable only, and only if there is another model left.
                // A malformed request or a bad key will fail identically on
                // the second model, and burning a round trip to prove it is
                // just latency he pays for nothing.
                // `error` is `any Error` here, so the enum case has to be
                // reached through a cast - `if case TTSError.httpError(...)`
                // straight off an existential does not compile.
                // REVIEW FIX - a barge-in must not buy a second request.
                // URLSession surfaces cancellation as NSURLErrorCancelled
                // (-999), which my first cut classified as retryable, so
                // interrupting Chappy mid-sentence fired a fresh render at the
                // fallback model for a line he had already talked over.
                if Task.isCancelled { throw error }

                let ns = error as NSError
                let retryable: Bool
                if let te = error as? TTSError, case .httpError(let code) = te {
                    retryable = code == 429 || code >= 500
                } else {
                    // REVIEW FIX - AND A TIMEOUT IS NOT RETRYABLE. THIS IS
                    // BUILD 248's FINDING AND I NEARLY UNDID IT.
                    //
                    // The render timeout is 20 seconds. Treating a timeout as
                    // retryable turned "stream 20s, whole-clip 20s, fall back"
                    // into "stream 20s, whole-clip 20s, SECOND MODEL 20s, fall
                    // back" - sixty seconds of silence where there were forty,
                    // on exactly the bad-network case build 248 measured and
                    // cut down. My own comment three lines below said not to
                    // burn a round trip to prove a foregone conclusion, and
                    // then this line burned one.
                    //
                    // A service that had twenty seconds and did not answer is
                    // not going to answer the second model any faster.
                    let deadEnds: Set<Int> = [NSURLErrorTimedOut,
                                              NSURLErrorNetworkConnectionLost,
                                              NSURLErrorNotConnectedToInternet,
                                              NSURLErrorCancelled]
                    retryable = ns.domain == NSURLErrorDomain
                        && !deadEnds.contains(ns.code)
                }
                if retryable, modelIndex + 1 < models.count {
                    ChappyStandbyLog.note("↩️ [TTS] Trying \(models[modelIndex + 1]) instead")
                    lastError = error
                    continue
                }
                throw error          // a REAL service failure - the caller may latch
            }

            // The render worked. From here on, nothing that goes wrong is
            // Gemini's fault, and nothing that goes wrong may cost the voice.
            // BUILD 174: cache EVERY successful render, not just short ones.
            // The old 200-character limit meant long answers re-rendered from
            // scratch every time — more network, more chances to fail, and
            // the cache could never protect them.
            // REVIEW FIX - DO NOT CACHE A RENDER FROM THE FALLBACK MODEL.
            //
            // VoiceCache's key is SHA256(voice|text) and the model is not in
            // it - the reason every other render site in this file is pinned
            // to index 0, spelled out in the BUILD 259 note above. Before this
            // build only a 404 could reach index 1, so it never mattered. Now
            // a 429 routinely does, and caching that line would write one 2.5
            // rendering to disk to replay for ever among 3.1 lines. That is
            // Chappy changing person mid-conversation, which is the fault
            // builds 125 and 259 exist to prevent, arriving by the back door
            // of the fix for a different fault.
            //
            // Play it, do not keep it. Next time the primary is healthy the
            // line renders and caches properly.
            if modelIndex == 0 {
                VoiceCache.shared.save(audio, text: text, voice: geminiVoiceName)
            }
            Self.geminiVoiceGaveUp = false   // proof of life, clears any latch
            print("🔊 [TTS] Gemini voice (\(voiceName)) speaking: \(text.prefix(50))…")

            do {
                try await playPCM(audio, gen: gen)
                return
            } catch is CancellationError {
                return                        // barged in on — perfectly normal
            } catch {
                if Task.isCancelled { return }
                // One retry, from the audio we already have. Audio-session
                // contention is usually over in a moment.
                print("⚠️ [TTS] Playback stumbled (\(error.localizedDescription)) — one more go")
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                do {
                    try await playPCM(audio, gen: gen)
                    return
                } catch {
                    // Still no sound. Fall through to the system voice for
                    // THIS LINE ONLY — but never latch, because the service
                    // demonstrably works.
                    print("⚠️ [TTS] Playback failed twice — system voice for this line only")
                    await self.fallbackToSystemTTS(text: text, languageCode: nil)
                    return
                }
            }
        }
        throw lastError
    }

    /// BUILD 259 — SPEAK ON THE FIRST CHUNK, NOT THE LAST.
    ///
    /// `:streamGenerateContent?alt=sse` returns the audio in pieces as it is
    /// generated. Each piece is scheduled into the player node the moment it
    /// lands, so the voice starts after the FIRST chunk instead of after the
    /// whole clip. On a short line that is the difference between three and a
    /// half seconds and a few hundred milliseconds.
    ///
    /// The playback half needed almost nothing new: this file has always used
    /// AVAudioEngine with a player node and scheduled PCM buffers, which is
    /// already the right shape for progressive audio. What is new is a counter
    /// and a gate, because the "am I finished" question changes from "did that
    /// one buffer complete" to "has the stream ended AND has every buffer
    /// drained".
    ///
    /// Returns the whole clip so the caller can still cache it — a cached line
    /// then plays instantly next time and never touches the network at all.
    ///
    /// THROWS on any failure, so the caller can fall back to the whole-clip
    /// path. If audio had already started, the node is stopped and reset on
    /// the way out — otherwise the fallback's buffers QUEUE BEHIND the
    /// fragment already playing and he hears the first half of the line
    /// twice. An earlier draft of this comment claimed the function handled
    /// that by returning rather than throwing; it did not, and review caught
    /// the comment describing code that was never written.
    /// BUILD 272 — A NON-PLAYING ELEVENLABS RENDER, FOR WARMING ONLY.
    ///
    /// The streaming function above renders AND plays; a warm-up must do
    /// neither out loud. This is the plain endpoint (no /stream), same voice,
    /// same pcm_24000, so the bytes it returns are interchangeable with the
    /// streamed ones and land in the same cache under the same key.
    private func renderElevenLabsClip(text: String, voiceID: String,
                                      model: String, apiKey: String) async throws -> Data {
        guard !voiceID.isEmpty else { throw TTSError.modelNotFound }
        let urlString = "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)?output_format=pcm_24000"
        guard let url = URL(string: urlString) else { throw TTSError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "model_id": model
        ])
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TTSError.invalidResponse }
        guard http.statusCode == 200 else { throw TTSError.httpError(http.statusCode) }
        guard !data.isEmpty else { throw TTSError.noAudio }
        return data
    }

    /// BUILD 272 — REVIEW FIX. THE OFFLINE-PROOFING HAD TO SURVIVE THE MOVE.
    ///
    /// My first cut simply returned early from all three warmers when the
    /// provider was not Google, on the reasoning that a 75ms render makes
    /// pre-rendering pointless. Review pointed at the doc comment twelve lines
    /// above one of them: BUILD 132 wrote prerender because "the whole route
    /// speaks from disk — instant, OFFLINE-PROOF, in the ONE voice", after a
    /// render that failed in traffic latched the robot voice.
    ///
    /// Latency was never the only thing it bought. He rides a scooter with
    /// patchy signal; a turn instruction that has to reach the network at the
    /// moment he needs it is the exact failure build 132 removed. Silently
    /// trading that away for the fast voice would have been a regression
    /// dressed as a feature, and it would have shown up as "the new voice
    /// drops turns" a week later, in traffic, with no way to connect it.
    /// `after` mirrors the eight-second wait the Gemini nav pre-render uses.
    /// The route summary is being spoken at that moment, and starting a batch
    /// of renders over the same connection is what BUILD 135 diagnosed as the
    /// cause of nav going robot. Cheaper here, but the reasoning is unchanged.
    private func warmElevenLabs(_ lines: [String], after: UInt64 = 0,
                                gapNanos: UInt64 = 350_000_000) {
        let voice = voiceName
        let id = ChappyVoiceProvider.elevenVoiceID
        let model = ChappyVoiceProvider.elevenModel
        guard !id.isEmpty,
              let key = APIKeyManager.shared.getElevenLabsKey(), !key.isEmpty else { return }
        let missing = lines.filter { !$0.isEmpty && !VoiceCache.shared.has(text: $0, voice: voice) }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if after > 0 { try? await Task.sleep(nanoseconds: after) }
            for line in missing {
                do {
                    let audio = try await self.renderElevenLabsClip(
                        text: line, voiceID: id, model: model, apiKey: key)
                    VoiceCache.shared.save(audio, text: line, voice: voice)
                } catch {
                    // A warm-up is a nicety and must never cost the voice.
                    print("🔊 [11L] Warm-up stopped: \(error.localizedDescription)")
                    break
                }
                try? await Task.sleep(nanoseconds: gapNanos)
            }
        }
    }

    // BUILD 272 — THE FAST VOICE.
    //
    // Deliberately shaped like streamGeminiAudio, because that function has
    // had five builds of bugs beaten out of it and every one of those lessons
    // applies here: the generation-ownership rule, clearing the node before a
    // fallback is allowed to start, the cancellation check before the caller
    // is allowed to cache, and the exact-length completion ceiling.
    //
    // Simpler in one way: ElevenLabs streams RAW PCM. No SSE framing, no
    // base64, no JSON per chunk - just bytes in the order they should be
    // played. And no carry byte, because the accumulator below only ever
    // flushes at an EVEN length, so a sample can never be split across two
    // scheduled buffers. (Gemini needed the carry byte because its chunk
    // boundaries fall wherever the encoder likes; getting that wrong reads
    // PCM16 one byte out of phase, which is full-scale white noise.)
    //
    // Returns the whole clip so the caller can cache it, same contract.
    private func streamElevenLabsAudio(text: String, voiceID: String,
                                       model: String, apiKey: String,
                                       gen: Int) async throws -> Data {
        // An empty voice ID would build ".../text-to-speech//stream", which is
        // a 404 that reads like an outage rather than like "you have not
        // picked a voice". elevenReady already refuses this case, so reaching
        // here means someone added a caller that skipped it - which is exactly
        // when a silent guard is worth least. Say so, then fall through to
        // Google.
        guard !voiceID.isEmpty else {
            ChappyStandbyLog.note("⚠️ [11L] No voice chosen yet — Settings, Chappy's voice, ElevenLabs")
            throw TTSError.modelNotFound
        }
        let urlString = "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)/stream?output_format=pcm_24000"
        guard let url = URL(string: urlString) else { throw TTSError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": model
        ])
        // Fifteen, not the twenty this file uses for Gemini. Flash is quoted at
        // 75ms to first audio; if fifteen seconds have passed something is
        // badly wrong and the honest move is to fall through to Google while
        // he can still be told something, rather than hold the route.
        request.timeoutInterval = 15

        let began = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TTSError.invalidResponse }
        guard http.statusCode == 200 else {
            var errBody = ""
            for try await line in bytes.lines {
                errBody += line
                if errBody.count > 4096 { break }
            }
            // 401 is a bad key, 402 is out of credit, 422 is usually a voice
            // ID his account cannot use - which is the specific trap this
            // build exists to avoid, so it gets named rather than numbered.
            let hint: String
            switch http.statusCode {
            case 401: hint = " - the key was rejected"
            case 402: hint = " - out of characters for this billing period"
            case 404, 422: hint = " - that voice is not available on this account"
            case 429: hint = " - rate limited"
            default: hint = ""
            }
            ChappyStandbyLog.note("⛔️ [11L] HTTP \(http.statusCode)\(hint). \(errBody.prefix(180))")
            throw TTSError.httpError(http.statusCode)
        }

        configureAudioSession()
        startPlaybackEngine()
        guard let playbackEngine, playbackEngine.isRunning,
              let fmt = playbackFormat,
              let node = playerNode, node.engine != nil else {
            scheduleEngineIdle()
            throw TTSError.noAudio
        }
        node.play()

        var whole = Data()
        var pending = Data()
        var lostNode = false
        var scheduled = 0
        var drained = 0
        var streamEnded = false
        var firstChunkAt: Date?
        let tally = NSLock()
        let gate = ResumeGate()

        func settleIfDone() {
            tally.lock()
            let done = streamEnded && drained >= scheduled
            tally.unlock()
            if done { _ = gate.fire() }
        }

        // 2,400 bytes is 50ms of 24 kHz mono PCM16, and 9,600 is 200ms. Small
        // first flush so sound starts as early as the bytes allow - that is
        // the entire point of this provider - then larger ones so a long
        // answer is not thousands of scheduleBuffer calls. Both even, so a
        // sample is never split.
        func flushThreshold() -> Int { firstChunkAt == nil ? 2_400 : 9_600 }

        func flush(force: Bool) {
            guard !pending.isEmpty else { return }
            // REVIEW FIX - A LOST NODE MUST NOT LOOK LIKE SUCCESS.
            //
            // This used to `return` silently when the node had gone (a media
            // services reset, which the Gemini path notes is most likely on
            // exactly this code path). Every remaining byte then fell into the
            // same silent return, the stream ran to completion, firstChunkAt
            // was non-nil so the guard below passed, and the function returned
            // the WHOLE clip as a success. He would hear the first fragment of
            // a sentence, the rest would vanish, the Google fallback would
            // never run, and nothing anywhere would say why.
            guard node.engine != nil else { lostNode = true; return }
            guard force || pending.count >= flushThreshold() else { return }
            let usable = pending.count - (pending.count % 2)
            guard usable > 0 else { return }
            // Data(...) rather than the slice: a Data slice keeps its parent's
            // indices, and this file has already been bitten once by
            // `suffix(from:)` taking an INDEX while the variable held a
            // LENGTH. Rebasing to 0 is what makes the two agree.
            let piece = Data(pending.prefix(usable))
            pending = usable < pending.count ? Data(pending.suffix(from: usable)) : Data()
            // REVIEW FIX - same silent-success class as the lost node. This
            // `return` dropped a piece that had ALREADY been removed from
            // `pending`, so the audio was gone from playback while `whole`
            // still contained it: a clip returned as a success, cached, and
            // only partly heard.
            guard let buf = createPCMBuffer(from: piece, format: fmt) else {
                lostNode = true
                return
            }
            if firstChunkAt == nil {
                firstChunkAt = Date()
                let ms = Int(Date().timeIntervalSince(began) * 1000)
                ChappyStandbyLog.note("⚡ [11L] First audio in \(ms)ms")
            }
            tally.lock(); scheduled += 1; tally.unlock()
            node.scheduleBuffer(buf) {
                tally.lock(); drained += 1; tally.unlock()
                settleIfDone()
            }
        }

        do {
            // REVIEW FIX - one Data append per CHUNK, not two per BYTE.
            //
            // Appending to two Data values for every byte is ~96,000 COW
            // checks per second of speech on top of an AsyncBytes next() per
            // byte. It would probably have held, and "probably held" is not
            // good enough here: falling behind shows up as buffer underrun,
            // which is gaps in the voice, which is the symptom class this file
            // has already spent five builds on. An array with reserved
            // capacity costs nothing and removes the question.
            var scratch = [UInt8]()
            scratch.reserveCapacity(16_384)
            for try await byte in bytes {
                if Task.isCancelled { break }
                scratch.append(byte)
                if scratch.count >= flushThreshold() {
                    let block = Data(scratch)
                    scratch.removeAll(keepingCapacity: true)
                    pending.append(block)
                    whole.append(block)
                    flush(force: false)
                }
            }
            if !scratch.isEmpty {
                let block = Data(scratch)
                pending.append(block)
                whole.append(block)
            }
            if !Task.isCancelled { flush(force: true) }
        } catch {
            // Identical reasoning to the Gemini path: clear the node before
            // any fallback is allowed to schedule behind it, but ONLY if this
            // generation still owns the voice. A cancelled stream throws here
            // milliseconds after a barge-in has already scheduled its
            // replacement, and stopping the node then would discard the new
            // line and leave him in silence with nothing logged.
            let mine = generationIsCurrent(gen)
            if mine {
                if firstChunkAt != nil, node.engine != nil { node.stop(); node.reset() }
                scheduleEngineIdle()
            }
            throw error
        }
        tally.lock(); streamEnded = true; tally.unlock()

        guard firstChunkAt != nil else {
            scheduleEngineIdle()
            throw TTSError.noAudio
        }
        // See flush(). Throwing here rather than returning a clip that was
        // only half played is what sends the caller on to Google.
        // `|| node.engine == nil` because lostNode is only ever set INSIDE
        // flush(): a node that dies after the final flush sets nothing, the
        // drain count never completes, the gate falls through on its timeout
        // and the whole clip is returned as a success. Ask the node directly.
        if lostNode || node.engine == nil {
            ChappyStandbyLog.note("⚠️ [11L] Lost the audio mid-line — Google for this one")
            scheduleEngineIdle()
            throw TTSError.noAudio
        }

        let seconds = Double(whole.count / 2) / fmt.sampleRate
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gate.arm(c)
            settleIfDone()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 3.0) {
                if gate.fire() {
                    print("⏱️ [11L] Completion dropped — unparking after \(String(format: "%.1f", seconds + 3.0))s")
                }
            }
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Before the caller is allowed to cache. A barge-in breaks the loop
        // above holding a PARTIAL clip, and writing that to the cache would
        // pin the truncated version on disk for ever.
        try Task.checkCancellation()

        if generationIsCurrent(gen) { scheduleEngineIdle() }
        let total = Int(Date().timeIntervalSince(began) * 1000)
        ChappyStandbyLog.note("⚡ [11L] \(text.count) characters, \(total)ms end to end")
        return whole
    }

    private func streamGeminiAudio(text: String, model: String,
                                   apiKey: String, gen: Int) async throws -> Data {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse"
        guard let url = URL(string: urlString) else { throw TTSError.invalidURL }

        let body: [String: Any] = [
            "contents": [["parts": [["text": text]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        // BUILD 272: geminiVoiceName, NOT voiceName. voiceName
                        // now carries a provider prefix so the cache keyspaces
                        // stay disjoint, and sending "11l:JBFqn..." to Google
                        // as a prebuilt voice name is a 400 on every render.
                        "prebuiltVoiceConfig": ["voiceName": geminiVoiceName]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        // HEADERS FIRST, THEN THE ENGINE. Review caught the original order:
        // the audio session was ducked and the engine started BEFORE a
        // request with a twenty-second timeout. On a captive wifi or in
        // aeroplane mode his music ducked instantly and then sat in silence
        // for twenty seconds before anything fell back. bytes(for:) returns
        // as soon as the headers land, which is still comfortably ahead of
        // the first chunk — which is all "before the audio arrives" ever
        // needed to mean.
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TTSError.invalidResponse }
        if http.statusCode == 404 { throw TTSError.modelNotFound }
        guard http.statusCode == 200 else {
            // BUILD 271 - the streaming path threw the bare status code and
            // dropped the body on the floor, so a 429 here said nothing about
            // WHICH quota. bytes(for:) has already returned the headers; the
            // error body is short, so draining it costs nothing.
            // Named errBody, not body: this function already has a `body`
            // (the request JSON) in the enclosing scope, and shadowing it
            // here would compile and read like a bug forever after.
            // REVIEW FIX - 800 characters was too small to be worth writing.
            // A 429 body carrying quotaId also carries quotaMetric,
            // quotaDimensions, RetryInfo and a help link, routinely past 1 KB.
            // Truncating mid-object means JSONSerialization fails and
            // quotaReason returns "" - the log line would have been identical
            // to the one I was replacing. Append first, THEN test, so the last
            // chunk is never discarded.
            var errBody = ""
            for try await line in bytes.lines {
                errBody += line
                if errBody.count > 8192 { break }
            }
            if http.statusCode == 429 || http.statusCode >= 500 {
                let reason = Self.quotaReason(from: errBody)
                ChappyStandbyLog.note("⛔️ [TTS] \(model) refused streaming with HTTP \(http.statusCode)\(reason)")
            }
            throw TTSError.httpError(http.statusCode)
        }

        configureAudioSession()
        startPlaybackEngine()
        guard let playbackEngine, playbackEngine.isRunning,
              let fmt = playbackFormat,
              let node = playerNode, node.engine != nil else {
            scheduleEngineIdle()      // reachable after a media-services reset
            throw TTSError.noAudio
        }
        node.play()

        var whole = Data()
        var carry = Data()
        var scheduled = 0
        var drained = 0
        var streamEnded = false
        var firstChunkAt: Date?
        let tally = NSLock()
        let gate = ResumeGate()

        // Resumed exactly once, by whichever gets there first: the last
        // buffer draining, or the safety timeout below.
        func settleIfDone() {
            tally.lock()
            let done = streamEnded && drained >= scheduled
            tally.unlock()
            if done { _ = gate.fire() }
        }

        do {
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, payload != "[DONE]",
                      let jsonData = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let content = candidates.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else { continue }

                for part in parts {
                    // Checked in here too. One SSE event can carry several
                    // parts, and without this a fragment of a killed
                    // utterance gets queued ahead of the new one and plays
                    // first — stopPlaybackEngine leaves the node attached, so
                    // the engine check below does not catch it.
                    if Task.isCancelled { break }
                    guard let inline = part["inlineData"] as? [String: Any],
                          let b64 = inline["data"] as? String,
                          let chunk = Data(base64Encoded: b64), !chunk.isEmpty else { continue }
                    whole.append(chunk)

                    // A CARRY BYTE, because PCM16 samples are two bytes and a
                    // chunk boundary need not respect that. createPCMBuffer
                    // does `count / 2` and drops an odd trailing byte — so
                    // one odd-length chunk would shift every sample after it
                    // by a byte, and PCM16 read one byte out of phase is
                    // full-scale white noise for the rest of the line. It
                    // would also have been invisible on the second play,
                    // because the CACHED copy is byte-exact.
                    // BUILT FROM A FRESH Data, and that is the fix, not a
                    // style choice. `carry + chunk` starts from a COPY OF
                    // carry, and a Data slice keeps its parent's indices — so
                    // after the first odd chunk `joined.startIndex` was 4000,
                    // not 0. `suffix(from:)` takes an INDEX while `usable` is
                    // a LENGTH, so the two silently disagreed: one trace
                    // re-scheduled an entire previous chunk (he hears 83ms
                    // twice, and carry grows for the rest of the line), and
                    // another indexed outside the slice and TRAPPED. Starting
                    // from empty forces startIndex to 0, which makes the two
                    // agree — and keeps the buffer's base pointer 2-byte
                    // aligned for createPCMBuffer's bindMemory.
                    var joined = Data()
                    joined.append(carry)
                    joined.append(chunk)
                    let usable = joined.count - (joined.count % 2)
                    carry = usable < joined.count ? joined.suffix(from: usable) : Data()
                    guard usable > 0,
                          let buf = createPCMBuffer(from: joined.prefix(usable), format: fmt),
                          node.engine != nil else { continue }
                    if firstChunkAt == nil {
                        firstChunkAt = Date()
                        ChappyStandbyLog.note("⚡ [TTS] First audio chunk — speaking now")
                    }
                    tally.lock(); scheduled += 1; tally.unlock()
                    node.scheduleBuffer(buf) {
                        tally.lock(); drained += 1; tally.unlock()
                        settleIfDone()
                    }
                }
            }
        } catch {
            // MID-STREAM FAILURE, AND THE COMMENT USED TO PROMISE SOMETHING
            // THE CODE DID NOT DO. A thrown error here left the node playing
            // whatever had already been scheduled, and the caller then fell
            // through to the whole-clip path — which QUEUES behind it, so he
            // heard "Turn left ont—Turn left onto Ann Street." The node has
            // to be cleared before the fallback is allowed to start.
            // ONLY IF THE VOICE IS STILL MINE. `node` is the SHARED player
            // node, and review caught this reintroducing AUDIT P0
            // (TTS-STALE) verbatim: a cancelled stream throws from
            // bytes.lines a few milliseconds AFTER the barge-in's new line
            // has already found a cache hit and scheduled its buffer — so
            // stopping the node here would discard the new utterance and the
            // map would open in silence with nothing logged.
            let mine = generationIsCurrent(gen)
            if mine {
                // node.engine != nil, same as stopPlaybackEngine does. A media
            // services reset swaps playerNode out from under the `let` bound
            // 130 lines up, and this is the path most likely to meet one.
            if firstChunkAt != nil, node.engine != nil { node.stop(); node.reset() }
                scheduleEngineIdle()
            }
            throw error
        }
        tally.lock(); streamEnded = true; tally.unlock()

        guard firstChunkAt != nil else {
            scheduleEngineIdle()          // nothing played — don't leave the route held
            throw TTSError.noAudio
        }

        // Wait for the audio already scheduled to actually finish. The ceiling
        // is computed from what was scheduled, so it is exact rather than a
        // guess — same reasoning as playPCM's.
        let seconds = Double(whole.count / 2) / fmt.sampleRate
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gate.arm(c)
            settleIfDone()                     // everything may already have drained
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 3.0) {
                if gate.fire() {
                    print("⏱️ [TTS] Streaming completion dropped — unparking after \(String(format: "%.1f", seconds + 3.0))s")
                }
            }
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        // THE CANCELLATION CHECK THAT REVIEW CAUGHT, AND IT WAS THE WORST BUG
        // IN THE BUILD. A barge-in breaks the loop above and falls through
        // here holding a PARTIAL clip — and the caller's next act is to write
        // it to VoiceCache, atomically, over the good copy. Every later play
        // of that line would then load the truncated file, succeed, and never
        // re-render: "Turn left ont—" on that street forever. The whole-clip
        // path has had this exact guard since build 248; the streaming path
        // was written without it.
        try Task.checkCancellation()

        // Same ownership rule as playPCM: only the generation that still owns
        // the voice may stand the engine down.
        let mine = generationIsCurrent(gen)
        if mine { scheduleEngineIdle() }
        return whole
    }

    private func requestGeminiAudio(text: String, model: String, apiKey: String) async throws -> Data {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else { throw TTSError.invalidURL }

        let body: [String: Any] = [
            "contents": [["parts": [["text": text]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        // BUILD 272: geminiVoiceName, NOT voiceName. voiceName
                        // now carries a provider prefix so the cache keyspaces
                        // stay disjoint, and sending "11l:JBFqn..." to Google
                        // as a prebuilt voice name is a 400 on every render.
                        "prebuiltVoiceConfig": ["voiceName": geminiVoiceName]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // BUILD 143 — THE ROBOT'S REAL CAUSE, measured at last. The voice
        // self-test PASSED with a delay: Google takes 5-10s to GENERATE the
        // audio, and this 8s guillotine was beheading half the renders —
        // every casualty fell back to the robot and latched it. Twenty
        // seconds of patience, and the wait is bearable because the cache
        // and the nav pre-render make repeated lines instant anyway.
        // BUILD 248: LEFT AT 20 ON PURPOSE.
        //
        // I changed this to 8 and review caught it: 8 is the exact value
        // BUILD 143 REMOVED, on measurement, because "Google takes 5-10s to
        // GENERATE the audio, and this 8s guillotine was beheading half the
        // renders — every casualty fell back to the robot and latched it."
        // The note is still four comments up this file. Putting it back
        // would have re-created a solved bug, on no evidence, in a build
        // whose whole purpose is to stop doing that.
        //
        // The 20-30s he reports is not this number anyway. See the retry
        // note in speak() — it is one timeout plus a second full attempt.
        // That is what got fixed. This stays until the 🐢 lines above
        // produce a real measurement of how long a render actually takes.
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TTSError.invalidResponse }

        if http.statusCode == 404 { throw TTSError.modelNotFound }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            print("❌ [TTS] Gemini TTS HTTP \(http.statusCode): \(msg.prefix(200))")
            // BUILD 271 - THE QUOTA MESSAGE WAS ONLY EVER IN XCODE.
            //
            // A 429 from Google names the exact quota it refused on, e.g.
            // "GenerateRequestsPerDayPerProjectPerModel-FreeTier". That is
            // the one string that separates "the voice model is capped" from
            // "the whole project is capped because the brain is eating it" -
            // and it went to print(), which he cannot read from a scooter.
            // Onto the log he can actually copy.
            if http.statusCode == 429 || http.statusCode >= 500 {
                let reason = Self.quotaReason(from: msg)
                ChappyStandbyLog.note("⛔️ [TTS] \(model) refused with HTTP \(http.statusCode)\(reason)")
            }
            throw TTSError.httpError(http.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw TTSError.invalidResponse
        }

        for part in parts {
            if let inline = part["inlineData"] as? [String: Any],
               let b64 = inline["data"] as? String,
               let audio = Data(base64Encoded: b64) {
                return audio
            }
        }
        throw TTSError.noAudio
    }

    /// Play raw PCM16 @ 24 kHz and wait for playback to finish.
    /// - Parameter gen: the speech generation that owns this utterance. Used to
    ///   make the teardown conditional — see AUDIT P0 (TTS-STALE) below.
    private func playPCM(_ audioData: Data, gen: Int) async throws {
        configureAudioSession()
        // BUILD 175: startPlaybackEngine now rebuilds and retries, and reports
        // honestly. Nothing below can succeed if it says no.
        startPlaybackEngine()
        guard let playbackEngine, playbackEngine.isRunning,
              let playbackFormat = playbackFormat,
              let buffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            // AUDIT P0: this used to `return`, which is indistinguishable from
            // success to the caller. So a failed playback charged the meter,
            // never latched the fallback, and the wearer got TOTAL SILENCE for
            // every long answer from then on — no voice, no tone, nothing on
            // screen, while the chip still read "Standby on". Throwing is what
            // routes him to the Apple voice instead of into a void.
            print("❌ [TTS] Could not prepare audio for playback")
            throw TTSError.noAudio
        }

        // AUDIT P0 (TTS-STALE): scheduling into a stopped or DETACHED node
        // throws an ObjC exception that goes straight through Swift's try/catch
        // and takes the app down. LiveTranslateService was given exactly this
        // guard; TTSService never was. `node.engine == nil` is the state a
        // media-services reset leaves behind.
        guard let node = playerNode, node.engine != nil else {
            print("❌ [TTS] Player node is detached — skipping playback")
            throw TTSError.noAudio
        }
        node.play()

        // SB-DEADLOCK FIX: scheduleBuffer's completion handler is dropped
        // outright if the engine is stopped before the buffer is consumed — a
        // route change, an interruption, or a concurrent stop() all do it. This
        // await then never returned and isSpeaking stayed true for the life of
        // the app. Duration is known from the buffer itself, so the timeout is
        // exact rather than a guess.
        // A task group would NOT work here: withTaskGroup waits for every child,
        // so a timeout child finishing first still leaves the parked
        // continuation child hanging and the group never returns. The gate has
        // to be the continuation itself, resumed exactly once by whichever of
        // the two racers gets there first.
        let seconds = Double(buffer.frameLength) / playbackFormat.sampleRate
        let gate = ResumeGate()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            gate.arm(cont)
            node.scheduleBuffer(buffer) { gate.fire() }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 3.0) {
                if gate.fire() {
                    print("⏱️ [TTS] Playback completion was dropped — unparking after \(String(format: "%.1f", seconds + 3.0))s")
                }
            }
        }
        // small tail so the last samples aren't clipped
        try? await Task.sleep(nanoseconds: 150_000_000)

        // AUDIT P0 (TTS-STALE): this teardown used to be unconditional. When the
        // wearer barged in — "Chappy, stop… Chappy, navigate to the ATM" — the
        // OLD utterance was still parked on its dropped-completion timeout. It
        // woke up seconds later, after the new answer had already started, and
        // stopped the shared engine out from under it. The new answer died
        // mid-sentence for no visible reason. Only the generation that still
        // owns the voice is allowed to tear it down.
        let mine = generationIsCurrent(gen)
        guard mine else {
            print("🔊 [TTS] Stale utterance finished — leaving the current one alone")
            return
        }
        // BUILD 219 — IDLE, DON'T DEMOLISH.
        //
        // The engine was stopped after every single line and rebuilt for
        // the next one, which costs 20-120ms of silence at the front of
        // every reply and occasionally trips the retry path above. A
        // conversation is a run of lines, not a series of unrelated
        // events; the graph should still be standing when the next one
        // arrives.
        //
        // It is still torn down when the voice genuinely stops — see the
        // idle sweep below — so nothing is left holding the route open
        // indefinitely.
        scheduleEngineIdle()
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = data.count / 2
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let floatData = buffer.floatChannelData?.pointee else { return nil }

        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                floatData[i] = Float(Int16(littleEndian: int16Buffer[i])) / 32768.0
            }
        }
        return buffer
    }

    // MARK: - System TTS Fallback (offline)

    private func fallbackToSystemTTS(text: String, languageCode: String? = nil) async {
        // REVIEW FIX - AND THIS IS A BETTER CANDIDATE FOR THE SILENCE THAN THE
        // ONE I WENT LOOKING FOR.
        //
        // Every route into this function is a Gemini failure, and a Gemini
        // failure leaves the shared AVAudioEngine RUNNING: scheduleEngineIdle()
        // only stops it after four seconds, and only if nothing is speaking.
        // So the usual case is an AVSpeechSynthesizer starting on top of a live
        // AVAudioEngine holding the same audio session - which is a documented
        // way to get an utterance that reports didFinish and produces no sound.
        //
        // That is precisely the two-players-one-route hazard BUILD 260 removed
        // the short-line synthesizer to avoid. 260 removed the common path and
        // left the rare one, and the rare one is the emergency voice - the
        // single path that must work when everything else has failed.
        //
        // Hand the route over cleanly first. The engine restarts on demand.
        stopPlaybackEngine()
        engineIdleWork?.cancel()

        configureAudioSession()

        let synthesizer = AVSpeechSynthesizer()
        systemSynthesizer = synthesizer
        synthesizer.delegate = self

        let utterance = AVSpeechUtterance(string: text)
        // Voice chosen by the TEXT itself — the old app-language setting was
        // still "Chinese" from TurboMeta days and made English sound Chinese.
        // BUILD 54: the CJK-or-English test was too blunt. When the Gemini voice
        // is unavailable (no signal, which is exactly when you're standing in a
        // market), replaying an Indonesian line read it aloud in an Australian
        // accent. Identify the language on-device and use a matching voice.
        // WATCH-LIST FIX: NLLanguageRecognizer returns "zh-Hans"/"zh-Hant" but
        // the installed voices are "zh-CN"/"zh-HK"/"zh-TW", so the prefix match
        // failed and Chinese was read aloud by the Australian English voice.
        // Strip the script subtag, and prefer a language we were TOLD.
        func voiceLanguage(for code: String) -> String? {
            let base = String(code.split(separator: "-").first ?? "")
            let voices = AVSpeechSynthesisVoice.speechVoices().map(\.language)
            if let exact = voices.first(where: { $0.lowercased() == code.lowercased() }) { return exact }
            if base == "en" { return voices.contains("en-AU") ? "en-AU" : "en-US" }
            if base == "zh" {
                if code.lowercased().contains("hant") { return voices.first { $0.hasPrefix("zh-TW") || $0.hasPrefix("zh-HK") } }
                return voices.first { $0.hasPrefix("zh-CN") } ?? voices.first { $0.hasPrefix("zh") }
            }
            return voices.first { $0.hasPrefix(base + "-") || $0 == base }
        }

        var language = "en-AU"
        if let known = languageCode, let v = voiceLanguage(for: known) {
            language = v
        } else {
            let recogniser = NLLanguageRecognizer()
            recogniser.processString(text)
            if let code = recogniser.dominantLanguage?.rawValue, let v = voiceLanguage(for: code) {
                language = v
            }
        }
        // BUILD 125: pinned, not picked. AVSpeechSynthesisVoice(language:)
        // returns whichever voice the system fancies for that language, which
        // can differ between launches and after an iOS update — a second way
        // for Chappy to change person mid-conversation, on top of the one this
        // build removes. Resolve it once, remember the identifier, reuse it.
        utterance.voice = pinnedSystemVoice(for: language)
            ?? AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        // BUILD 271 - THIS LINE WAS ONLY EVER IN XCODE, AND IT IS THE LINE
        // THAT ANSWERS "IS IT SILENT OR IS IT ROBOT?".
        //
        // Every failure ABOVE this point logs to ChappyStandbyLog, which he
        // can read and copy on the phone. The moment the emergency voice
        // takes over, logging switches to print() and he is blind. So when
        // he said "nothing, silence", there was no way to tell whether the
        // Apple voice had been tried and made no sound, or was never reached
        // at all - two completely different bugs, and I had to ask him.
        // I should not have to ask him.
        let q = utterance.voice?.quality.rawValue ?? -1
        ChappyStandbyLog.note("🔊 [TTS] Emergency voice speaking as \(utterance.voice?.name ?? "?") (quality \(q)): \(text.prefix(30))")
        print("🔊 [TTS] System TTS speaking (\(utterance.voice?.name ?? "?")): \(text.prefix(30))")

        // SB-DEADLOCK FIX: the delegate callback is not guaranteed. If iOS
        // reconfigures the audio session under us — which is exactly what
        // ChappyStandby does one instant before this line, installing a mic tap
        // and calling setActive(true) — the utterance can end without ever
        // reporting didFinish or didCancel. This used to park forever.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    guard let self else { cont.resume(); return }
                    self.continuationLock.lock()
                    self.systemTTSContinuation = cont
                    self.continuationLock.unlock()
                    synthesizer.speak(utterance)
                }
            }
            group.addTask { [weak self] in
                // Apple's system voice runs near 3 characters per 100 ms at the
                // default rate; this ceiling sits well clear of any real line.
                let ceiling = min(45.0, 6.0 + Double(text.count) / 6.0)
                try? await Task.sleep(nanoseconds: UInt64(ceiling * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                ChappyStandbyLog.note("⏱️ [TTS] Emergency voice never reported finishing - unparking")
                print("⏱️ [TTS] System voice never reported finishing - unparking")
                self.resumeSystemContinuation()
            }
            await group.next()
            group.cancelAll()
        }
        resumeSystemContinuation()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {
    // SB-DEADLOCK FIX: both callbacks arrive on the synthesizer's own queue and
    // used to read-resume-nil without a lock, racing stop() on the main thread.
    // AUDIT P2: these fired for ANY synthesizer, including a stale one being
    // torn down, so a late didCancel from the previous utterance unparked the
    // CURRENT one and cut it off mid-sentence. Only the live synthesizer counts.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard synthesizer === systemSynthesizer else { return }
        resumeSystemContinuation()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard synthesizer === systemSynthesizer else { return }
        resumeSystemContinuation()
    }
}

// MARK: - Errors

private enum TTSError: LocalizedError {
    case invalidURL
    case invalidResponse
    case modelNotFound
    case noAudio
    case httpError(Int)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid TTS URL"
        case .invalidResponse: return "Invalid TTS response"
        case .modelNotFound: return "TTS model not found"
        case .noAudio: return "No audio in TTS response"
        case .httpError(let code): return "TTS HTTP error \(code)"
        case .unknown: return "Unknown TTS error"
        }
    }
}
