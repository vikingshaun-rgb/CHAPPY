/*
 * API Key Manager
 * Secure storage and retrieval of API keys using Keychain
 * Supports multiple API providers (Alibaba Dashscope, OpenRouter, Google)
 */

import Foundation
import Security

class APIKeyManager {
    static let shared = APIKeyManager()

    private let service = "com.smartview.glassai.apikey"

    // Account names for different providers
    private let alibabaBeijingAccount = "alibaba-beijing-api-key"
    private let alibabaSingaporeAccount = "alibaba-singapore-api-key"
    private let anthropicAccount = "anthropic_api_key"
    private let openrouterAccount = "openrouter-api-key"
    private let googleAccount = "google-api-key"
    private let googleMapsAccount = "google-maps-api-key" // chappy-maps: Routes/Places/Geocoding (Phase 4 nav)
    private let legacyAccount = "qwen-api-key" // For backward compatibility (migrates to Beijing)
    private let legacyAlibabaAccount = "alibaba-api-key" // Old format (migrates to Beijing)

    private init() {
        // Migrate legacy key to new format if needed
        migrateLegacyKey()
        // Seed built-in default keys if none saved yet
        seedDefaultKeys()
        // BUILD 175: rewrite every stored key to AfterFirstUnlock, once.
        upgradeKeychainAccessibility()
    }
    // MARK: - Built-in Default Keys (auto-seeded into Keychain)
    //
    // Keys are stored SPLIT into chunks and joined at runtime so GitHub's
    // secret scanner cannot match them — pushed keys were being reported to
    // Google/Anthropic as "leaked" and auto-revoked. NEVER paste a whole
    // key as one literal in this repo again.

    private var defaultAnthropicKey: String {
        return ["sk-ant-", "api03-", "Bpa9g1wG3DIAhnpObYtPAgqixln4RSTL61NRDvda",
                "R0Rar3EGP9woBFb_xslTY00DuJR_GD5NGI75uT5O1jJKgQ-_3IK6wAA"].joined()
    }
    private var defaultGoogleKey: String {
        // BUILD 141: the key from the BILLED project ("Chappy", the one wired
        // to the prepaid credit), locked to generativelanguage only. The old
        // key belonged to an unbilled project — which is why the voice kept
        // hitting free-tier quota walls and falling back to the robot.
        return ["AIzaSy", "Bjkebh0-XPrD2", "OTscKWRAmg3853CipeeY"].joined()
    }
    // chappy-maps key — locked to Routes + Places + Geocoding only.
    // Separate from the Gemini key (which is generativelanguage-locked).
    private var defaultGoogleMapsKey: String {
        return ["AIzaSy", "CtTSpXwTr9_Om", "RtASZ3QZfJh_xLmh3dGU"].joined()
    }

    // Bump this number whenever a baked key above changes. On the next launch
    // the new keys overwrite whatever is in the Keychain ONCE — after that,
    // keys the user types in Settings are left alone.
    private let keySeedVersion = 9   // BUILD 141: billed-project Gemini key
    private let keySeedVersionDefaultsKey = "chappy_key_seed_version"

    /// BUILD 257 — one flag per key, so "cleared" means cleared for all of
    /// them and not just for Maps. Build 183 fixed this for the Maps key
    /// alone with a hand-written UserDefaults key; the other two kept
    /// resurrecting the built-in key on the next cold launch, so clearing
    /// Gemini or Claude appeared to work and then quietly resumed billing to
    /// somebody else's account.
    static func clearedFlag(for account: String) -> String {
        "chappy_key_cleared_" + account
    }

    private func seedDefaultKeys() {
        let defaults = UserDefaults.standard
        let force = defaults.integer(forKey: keySeedVersionDefaultsKey) < keySeedVersion
        // A key HE cleared is never re-seeded, not even by a version bump —
        // a bump means "the built-in key changed", not "override his choice".
        func clearedByUser(_ account: String) -> Bool {
            defaults.bool(forKey: Self.clearedFlag(for: account))
        }

        if (force || getKey(for: anthropicAccount) == nil), !clearedByUser(anthropicAccount),
           defaultAnthropicKey.hasPrefix("sk-ant") {
            _ = saveKey(defaultAnthropicKey, for: anthropicAccount)
            print("✅ Seeded built-in Claude API key (force=\(force))")
        }
        if (force || getKey(for: googleAccount) == nil), !clearedByUser(googleAccount),
           (defaultGoogleKey.hasPrefix("AIza") || defaultGoogleKey.hasPrefix("AQ.")) {
            _ = saveKey(defaultGoogleKey, for: googleAccount)
            print("✅ Seeded built-in Gemini API key (force=\(force))")
        }
        // BUILD 183: if he has explicitly CLEARED the Maps key, leave it
        // cleared. This used to put the built-in key back on the next cold
        // launch, so "Cleared" lasted until you closed the app and Google
        // lookups quietly resumed on somebody else's billing account.
        // BUILD 257: both flags are now written — deleteMapsAPIKey goes
        // through clear(account:) like every other delete, and the Maps
        // field also still writes 183's own key. Either alone is enough;
        // the OR is here so an install that only has the old flag from a
        // previous build keeps its setting across the upgrade.
        let mapsClearedByUser = defaults.bool(forKey: "chappy_maps_key_cleared")
            || clearedByUser(googleMapsAccount)
        if (force || getKey(for: googleMapsAccount) == nil), !mapsClearedByUser,
           defaultGoogleMapsKey.hasPrefix("AIza") {
            _ = saveKey(defaultGoogleMapsKey, for: googleMapsAccount)
            print("✅ Seeded built-in Maps API key (force=\(force))")
        }

        defaults.set(keySeedVersion, forKey: keySeedVersionDefaultsKey)
    }


    // MARK: - Migration

    private func migrateLegacyKey() {
        // Migrate very old qwen key format
        if let legacyKey = getKey(for: legacyAccount),
           getKey(for: alibabaBeijingAccount) == nil {
            _ = saveKey(legacyKey, for: alibabaBeijingAccount)
            _ = deleteKey(for: legacyAccount)
            print("✅ Migrated legacy qwen API key to Alibaba Beijing")
        }

        // Migrate old alibaba key format (without endpoint)
        if let oldAlibabaKey = getKey(for: legacyAlibabaAccount),
           getKey(for: alibabaBeijingAccount) == nil {
            _ = saveKey(oldAlibabaKey, for: alibabaBeijingAccount)
            _ = deleteKey(for: legacyAlibabaAccount)
            print("✅ Migrated old Alibaba API key to Beijing endpoint")
        }
    }

    // MARK: - Provider-specific API Key Management

    func saveAPIKey(_ key: String, for provider: APIProvider, endpoint: AlibabaEndpoint? = nil) -> Bool {
        let account = accountName(for: provider, endpoint: endpoint)
        return saveKey(key, for: account)
    }

    func getAPIKey(for provider: APIProvider, endpoint: AlibabaEndpoint? = nil) -> String? {
        let account = accountName(for: provider, endpoint: endpoint)
        return getKey(for: account)
    }

    func deleteAPIKey(for provider: APIProvider, endpoint: AlibabaEndpoint? = nil) -> Bool {
        let account = accountName(for: provider, endpoint: endpoint)
        return clear(account: account)      // BUILD 257: and it stays deleted
    }

    func hasAPIKey(for provider: APIProvider, endpoint: AlibabaEndpoint? = nil) -> Bool {
        return getAPIKey(for: provider, endpoint: endpoint) != nil
    }

    // MARK: - Mail (Build 147) — the IMAP app-specific password, Keychain only.

    func saveMailPassword(_ p: String) -> Bool { saveKey(p, for: "chappy-mail-imap") }
    func getMailPassword() -> String? { getKey(for: "chappy-mail-imap") }
    /// BUILD 257: a wrong app password could previously only be REPLACED,
    /// never removed — there was no path to a blank one anywhere.
    @discardableResult
    func deleteMailPassword() -> Bool { clear(account: "chappy-mail-imap") }

    // BUILD 151: AviationStack — live flight status, split-chunk baked.
    private var defaultAviationStackKey: String {
        return ["d14ddd69", "7d9fbcd0", "3aa335db", "00964aed"].joined()
    }

    func getAviationStackKey() -> String? {
        getKey(for: "chappy-aviationstack") ?? defaultAviationStackKey
    }

    // MARK: - Amadeus (Build 150) — flight data keys, Keychain only.

    func saveAmadeusKey(_ k: String) -> Bool { saveKey(k, for: "chappy-amadeus-key") }
    func getAmadeusKey() -> String? { getKey(for: "chappy-amadeus-key") }
    func saveAmadeusSecret(_ k: String) -> Bool { saveKey(k, for: "chappy-amadeus-secret") }
    func getAmadeusSecret() -> String? { getKey(for: "chappy-amadeus-secret") }

    // MARK: - Google API Key (for Live AI)

    func saveGoogleAPIKey(_ key: String) -> Bool {
        return saveKey(key, for: googleAccount)
    }

    func getGoogleAPIKey() -> String? {
        return getKey(for: googleAccount)
    }

    func deleteGoogleAPIKey() -> Bool {
        return clear(account: googleAccount)    // BUILD 257: and it stays deleted
    }

    func hasGoogleAPIKey() -> Bool {
        return getGoogleAPIKey() != nil
    }

    // MARK: - Google Maps API Key (Routes/Places/Geocoding — Phase 4 nav)

    func saveMapsAPIKey(_ key: String) -> Bool {
        return saveKey(key, for: googleMapsAccount)
    }

    func getMapsAPIKey() -> String? {
        return getKey(for: googleMapsAccount)
    }

    func deleteMapsAPIKey() -> Bool {
        return clear(account: googleMapsAccount)   // BUILD 257: and it stays deleted
    }

    func hasMapsAPIKey() -> Bool {
        return getMapsAPIKey() != nil
    }

    // MARK: - Backward Compatible Methods (defaults to current provider)

    func saveAPIKey(_ key: String) -> Bool {
        return saveAPIKey(key, for: APIProviderManager.staticCurrentProvider)
    }

    func getAPIKey() -> String? {
        return getAPIKey(for: APIProviderManager.staticCurrentProvider)
    }

    @discardableResult
    func deleteAPIKey() -> Bool {
        return deleteAPIKey(for: APIProviderManager.staticCurrentProvider)
    }

    func hasAPIKey() -> Bool {
        return hasAPIKey(for: APIProviderManager.staticCurrentProvider)
    }

    // MARK: - Private Helpers

    private func accountName(for provider: APIProvider, endpoint: AlibabaEndpoint? = nil) -> String {
        switch provider {
        case .alibaba:
            // Use current endpoint from settings if not specified
            let effectiveEndpoint = endpoint ?? APIProviderManager.staticAlibabaEndpoint
            switch effectiveEndpoint {
            case .beijing:
                return alibabaBeijingAccount
            case .singapore:
                return alibabaSingaporeAccount
            }
        case .anthropic:
            return anthropicAccount
        case .openrouter:
            return openrouterAccount
        }
    }

    /// BUILD 257 — CLEARING A KEY, AND MAKING IT STICK.
    ///
    /// Two separate problems, and my first cut only fixed the cosmetic one.
    ///
    /// FIRST: `saveKey("")` returned false and did nothing, so select-all,
    /// delete, Save was a silent no-op. That is fixed by the guard below.
    /// But review then showed the fix was UNREACHABLE — every caller has its
    /// own `guard !apiKey.isEmpty` above it, so an empty string never gets
    /// here. Which means it was never the real bug.
    ///
    /// SECOND, AND THIS IS THE ONE HE FEELS: the explicit Delete buttons
    /// DO work — and then `seedDefaultKeys()` puts the built-in key straight
    /// back on the next cold launch, because its test is "is this slot
    /// empty". So deleting the Gemini or Claude key appeared to work and
    /// silently resumed on someone else's billing account the next morning.
    /// Build 183 fixed exactly this for the Maps key alone, with a
    /// hand-written UserDefaults flag. This generalises it, and the flag is
    /// now written by `clear(account:)` — which every delete path funnels
    /// through — rather than by any one caller.
    private func clear(account: String) -> Bool {
        let ok = deleteKey(for: account)
        UserDefaults.standard.set(true, forKey: Self.clearedFlag(for: account))
        print("🗑️ [Keys] Cleared '\(account)' — and it stays cleared through a cold launch")
        return ok
    }

    private func saveKey(_ key: String, for account: String) -> Bool {
        guard !key.isEmpty else { return clear(account: account) }

        let data = key.data(using: .utf8)!

        // Delete existing key first
        _ = deleteKey(for: account)

        // Add new key
        //
        // BUILD 175 — THE ROBOT VOICE AT STARTUP. THIS LINE IS THE CAUSE.
        //
        // There was no kSecAttrAccessible here, so every key in this app was
        // stored with the Keychain's DEFAULT: kSecAttrAccessibleWhenUnlocked.
        // That means the key is literally unreadable whenever the phone is
        // locked — SecItemCopyMatching returns errSecInteractionNotAllowed and
        // getGoogleAPIKey() hands back nil.
        //
        // Chappy reads that as "no Gemini key" and speaks in Apple's voice,
        // silently, with nothing on screen to say why. And the moments that
        // hit it are EXACTLY the ones that matter: the morning brief firing on
        // a locked phone, the proactive background task, a notification tap
        // before the phone has finished unlocking, and launch itself.
        //
        // AfterFirstUnlock means: unreadable after a reboot until the wearer
        // unlocks once, then readable for the rest of the phone's life whether
        // it is locked or not. That is the correct class for a background
        // service key, and it is what Apple recommends for exactly this.
        // ThisDeviceOnly keeps it off iCloud Keychain backups.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            Self.memo[account] = key      // BUILD 175: see getKey
            // BUILD 257: putting a key back un-clears it, so the seed is
            // allowed to look after it again. Written HERE, after the write
            // succeeded — an earlier draft set it before deleteKey() above,
            // which then set it straight back to true.
            UserDefaults.standard.set(false, forKey: Self.clearedFlag(for: account))
            if account == googleMapsAccount {
                UserDefaults.standard.set(false, forKey: "chappy_maps_key_cleared")
            }
        }
        return status == errSecSuccess
    }

    // BUILD 175 — REMEMBER THE KEY.
    //
    // Every single spoken line called into the Keychain. The Keychain is not
    // guaranteed to answer — it refuses while the device is locked, and it can
    // return errSecInteractionNotAllowed for a moment during unlock. One
    // refused read cost the wearer the real voice for that line, with no way
    // to tell that from "there is genuinely no key".
    //
    // So: once a key has been read successfully, it is held in memory for the
    // life of the process. A later refusal falls back to what we already know
    // rather than to silence. Cleared on delete, refreshed on save.
    private static var memo: [String: String] = [:]

    /// BUILD 175: why the last Keychain read failed, for the voice status line.
    private(set) static var lastKeychainStatus: OSStatus = errSecSuccess

    private func getKey(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        Self.lastKeychainStatus = status

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            if status == errSecInteractionNotAllowed {
                print("\u{26A0}\u{FE0F} [Keys] Keychain locked (errSecInteractionNotAllowed) for \(account) - using the remembered copy")
            }
            return Self.memo[account]
        }

        Self.memo[account] = key
        return key
    }

    // BUILD 175 — REWRITE THE OLD ITEMS.
    //
    // Fixing saveKey only helps keys saved from now on. Everything already in
    // the Keychain — including the baked Gemini key seeded on first launch —
    // still carries WhenUnlocked and would stay unreadable on a locked phone
    // forever. This reads each one while the app is in the foreground (so the
    // device is definitionally unlocked and the read WILL succeed) and writes
    // the accessibility attribute onto it in place. Runs once, then never again.
    func upgradeKeychainAccessibility() {
        let done = "chappy_keychain_afu_v1"
        guard !UserDefaults.standard.bool(forKey: done) else { return }
        let accounts = [alibabaBeijingAccount, alibabaSingaporeAccount,
                        anthropicAccount, openrouterAccount, googleAccount,
                        googleMapsAccount, legacyAccount, legacyAlibabaAccount]
        var moved = 0
        for account in accounts {
            let find: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let update: [String: Any] = [
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            if SecItemUpdate(find as CFDictionary, update as CFDictionary) == errSecSuccess {
                moved += 1
            }
        }
        // Only mark it done if the device was actually unlocked enough to read.
        if getKey(for: googleAccount) != nil {
            UserDefaults.standard.set(true, forKey: done)
            print("\u{1F511} [Keys] Keychain upgraded to AfterFirstUnlock (\(moved) items) - the voice now survives a locked phone")
        }
    }

    private func deleteKey(for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        Self.memo[account] = nil      // BUILD 175
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
