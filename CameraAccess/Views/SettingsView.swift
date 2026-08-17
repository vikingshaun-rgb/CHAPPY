/*
 * Settings View
 * Profile — device management and settings
 */

import EventKit
import SwiftUI
import MWDATCore
import UniformTypeIdentifiers
import Combine   // BUILD 244: Timer.publish for the live standby log

struct SettingsView: View {
    // BUILD 157 — the advanced-tools switch, read by the Home grid.
    @AppStorage("chappy_show_advanced") private var showAdvancedTools = false
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var languageManager = LanguageManager.shared
    @ObservedObject var providerManager = APIProviderManager.shared
    // BUILD 137: the memory controls, visible at last.
    @ObservedObject private var pulse = ChappyPulse.shared
    @ObservedObject private var keeper = ChappyMemoryKeeper.shared
    let apiKey: String

    @State private var showAPIKeySettings = false
    @State private var showProviderSettings = false
    @State private var showModelSettings = false
    @State private var showLanguageSettings = false
    @State private var showAppLanguageSettings = false
    @State private var showQualitySettings = false
    @State private var showLiveAIProviderSettings = false
    @State private var showGoogleAPIKeySettings = false
    @State private var showQuickVisionSettings = false
    @State private var showLiveAISettings = false
    @State private var showLiveTranslateSettings = false
    @State private var showOpenClawSettings = false
    @ObservedObject var quickVisionModeManager = QuickVisionModeManager.shared
    @ObservedObject var liveAIModeManager = LiveAIModeManager.shared
    @State private var selectedModel = "qwen3-omni-flash-realtime"
    // FIXED: was an orphan @State hardcoded to zh-CN and never saved —
    // now persisted to UserDefaults and defaults to English
    @State private var selectedLanguage = UserDefaults.standard.string(forKey: "output_language") ?? "en-US"
    @State private var selectedQuality = UserDefaults.standard.string(forKey: "video_quality") ?? "high"
    @State private var hasAPIKey = false // changed to a State variable
    @State private var hasGoogleAPIKey = false // Google API Key Status
    // POCKET LAW: wake word armed the moment the app opens. Default ON —
    // the Action Button gesture exists precisely so the phone stays pocketed.
    @AppStorage("chappy_standby_autoarm") private var standbyAutoArm = true
    // How Chappy answers his name — see ChappyEarcon's design note.
    @AppStorage("chappy_wake_style") private var wakeStyle = "tone"
    @AppStorage("chappy_user_name") private var userName = "Shaun"
    /// Falls back to this when location and history can't decide.
    @AppStorage("translate_usual_language") private var usualLanguage = ""
    /// PHASE 5 — glasses capture ingest. Defaults ON: the whole point is that
    /// "Hey Meta, take a picture" works with Chappy closed and still ends up
    /// in memory without you doing anything.
    @AppStorage("chappy_ingest_enabled") private var ingestEnabled = true
    @State private var ingestStatus = ""
    @State private var recordsStatus = ""
    /// Default OFF — the online model hears brand names far better, and it
    /// falls back to on-device by itself the moment there is no signal.
    @AppStorage("chappy_hearing_offline_only") private var hearingOfflineOnly = false
    /// Counted once in onAppear. `factsPending` decodes the whole conversation
    /// archive out of UserDefaults, which is not something to do on every
    /// SwiftUI body evaluation.
    @State private var recordsPending = 0
    @AppStorage("chappy_quiet_hours") private var quietHours = true
    @AppStorage("chappy_morning_brief") private var morningBrief = true
    // BACKUP & RESTORE
    @State private var showRestoreImporter = false
    @State private var restoreResultMessage = ""
    @State private var showRestoreResult = false

    init(streamViewModel: StreamSessionViewModel, apiKey: String) {
        self.streamViewModel = streamViewModel
        self.apiKey = apiKey
    }

    // Refresh API key state
    private func refreshAPIKeyStatus() {
        hasAPIKey = providerManager.hasAPIKey
        hasGoogleAPIKey = APIKeyManager.shared.hasGoogleAPIKey()
    }

    // Present the iOS share sheet for the backup file
    private func presentShareSheet(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(activity, animated: true)
    }

    var body: some View {
        NavigationView {
            List {
                // Device management
                Section {
                    // Connection status
                    HStack {
                        Image(systemName: "eye.circle.fill")
                            .foregroundColor(AppColors.primary)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ray-Ban Meta")
                                .font(AppTypography.headline)
                                .foregroundColor(AppColors.textPrimary)
                            Text(streamViewModel.hasActiveDevice ? "settings.device.connected".localized : "settings.device.notconnected".localized)
                                .font(AppTypography.caption)
                                .foregroundColor(streamViewModel.hasActiveDevice ? .green : AppColors.textSecondary)
                        }

                        Spacer()

                        // Connection status indicator
                        Circle()
                            .fill(streamViewModel.hasActiveDevice ? Color.green : Color.gray)
                            .frame(width: 12, height: 12)
                    }
                    .padding(.vertical, AppSpacing.sm)

                    // Device info
                    if streamViewModel.hasActiveDevice {
                        InfoRow(title: "settings.device.status".localized, value: "settings.device.online".localized)

                        if streamViewModel.isStreaming {
                            InfoRow(title: "settings.device.stream".localized, value: "settings.device.stream.active".localized)
                        } else {
                            InfoRow(title: "settings.device.stream".localized, value: "settings.device.stream.inactive".localized)
                        }

                        // TODO: Fetch more device info from the SDK
                        // InfoRow(title: "Battery", value: "85%")
                        // InfoRow(title: "Firmware version", value: "v20.0")
                    }
                } header: {
                    Text("settings.device".localized)
                }

                // AI Settings
                Section {
                    Button {
                        showAppLanguageSettings = true
                    } label: {
                        HStack {
                            Image(systemName: "globe.asia.australia.fill")
                                .foregroundColor(AppColors.primary)
                            Text("settings.applanguage".localized)
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(languageManager.currentLanguage.displayName)
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }

                    // SETTINGS CLEANUP: dead Alibaba-era rows (API Provider /
                    // Vision Model qwen picker) removed — Chappy is Gemini +
                    // Claude only. The sheets remain in code but unreachable.

                    Button {
                        showLanguageSettings = true
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundColor(AppColors.translate)
                            Text("settings.language".localized)
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(languageDisplayName(selectedLanguage))
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }

                    Button {
                        showAPIKeySettings = true
                    } label: {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundColor(AppColors.wordLearn)
                            Text("settings.apikey".localized)
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(hasAPIKey ? "settings.apikey.configured".localized : "settings.apikey.notconfigured".localized)
                                .font(AppTypography.caption)
                                .foregroundColor(hasAPIKey ? .green : .red)
                            Image(systemName: "chevron.right")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }

                    Button {
                        showQualitySettings = true
                    } label: {
                        HStack {
                            Image(systemName: "video.fill")
                                .foregroundColor(AppColors.liveStream)
                            Text("settings.quality".localized)
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(qualityDisplayName(selectedQuality))
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }

                    // Quick Vision Settings
                    Button {
                        showQuickVisionSettings = true
                    } label: {
                        HStack {
                            Image(systemName: "eye.circle.fill")
                                .foregroundColor(AppColors.quickVision)
                            Text("quickvision.settings".localized)
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(quickVisionModeManager.currentMode.displayName)
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }
                } header: {
                    Text("settings.ai".localized)
                }

                // Live AI Settings
                Section {
                    // Live AI Provider
                    Button {
                        showLiveAIProviderSettings = true
                    } label: {
                        HStack {
                            Image(systemName: "waveform.circle.fill")
                                .foregroundColor(AppColors.primary)
                            Text("settings.liveai.provider".localized)
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(providerManager.liveAIProvider.displayName)
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }

                    // Google API Key (only show when Google is selected for Live AI)
                    if providerManager.liveAIProvider == .google {
                        Button {
                            showGoogleAPIKeySettings = true
                        } label: {
                            HStack {
                                Image(systemName: "key.fill")
                                    .foregroundColor(.orange)
                                Text("Google API Key")
                                    .foregroundColor(AppColors.textPrimary)
                                Spacer()
                                Text(hasGoogleAPIKey ? "settings.apikey.configured".localized : "settings.apikey.notconfigured".localized)
                                    .font(AppTypography.caption)
                                    .foregroundColor(hasGoogleAPIKey ? .green : .red)
                                Image(systemName: "chevron.right")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textTertiary)
                            }
                        }
                    }

                    // Live AI Mode Settings
                    Button {
                        showLiveAISettings = true
                    } label: {
                        HStack {
                            Image(systemName: "brain.head.profile")
                                .foregroundColor(AppColors.liveAI)
                            Text("liveai.settings".localized)
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(liveAIModeManager.currentMode.displayName)
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }

                    // Live Translate Settings
                    Button {
                        showLiveTranslateSettings = true
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundColor(AppColors.translate)
                            Text("livetranslate.settings.title".localized)
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }
                } header: {
                    Text("settings.liveai".localized)
                }

                // Chappy Voice
                Section {
                    NavigationLink {
                        ChappyVoiceSettingsView()
                    } label: {
                        HStack {
                            Image(systemName: "waveform.circle.fill")
                                .foregroundColor(.orange)
                            Text("Chappy's Voice")
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(UserDefaults.standard.string(forKey: "chappy_tts_voice") ?? "Kore")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }
                    // PHASE 5 — what the glasses captured on their own.
                    // "Hey Meta, take a picture" works with Chappy closed, and
                    // this is how those photos and clips become memories.
                    Toggle(isOn: $ingestEnabled) {
                        HStack {
                            Image(systemName: "eyeglasses")
                                .foregroundColor(.cyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Import glasses captures")
                                    .foregroundColor(AppColors.textPrimary)
                                Text("Photos and videos you took with \"Hey Meta\" get captioned and filed — only while charging on Wi-Fi, so it costs no battery or data")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                    Button {
                        ingestStatus = "Looking…"
                        Task {
                            await ChappyIngest.shared.run(manual: true)
                            ingestStatus = ChappyIngest.shared.lastResult
                        }
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                                .foregroundColor(.cyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Import now")
                                    .foregroundColor(AppColors.textPrimary)
                                Text(ingestStatus.isEmpty
                                     ? (ChappyIngest.shared.lastRun == nil
                                        ? "Never run — turn on auto-import in the Meta AI app first"
                                        : "Last checked " + DateFormatter.localizedString(
                                            from: ChappyIngest.shared.lastRun ?? Date(),
                                            dateStyle: .short, timeStyle: .short))
                                     : ingestStatus)
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            Spacer()
                        }
                    }
                    NavigationLink {
                        CalendarPickerView()
                    } label: {
                        HStack {
                            Image(systemName: "calendar").foregroundColor(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Calendars")
                                    .foregroundColor(AppColors.textPrimary)
                                Text("iCloud, Outlook, Google — whatever's on this phone. Choose which ones Chappy reads out")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                    // PHASE 5.5 — the pocket channel, one switch per kind.
                    NavigationLink {
                        NotificationChannelsView()
                    } label: {
                        HStack {
                            Image(systemName: "bell.badge").foregroundColor(.pink)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("What Chappy can notify you about")
                                    .foregroundColor(AppColors.textPrimary)
                                Text("Only fires when speaking wouldn't have reached you — so it never doubles up on the voice")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                    // PHASE 5.5 — reminders that don't wake the house.
                    Toggle(isOn: $quietHours) {
                        HStack {
                            Image(systemName: "moon.zzz.fill").foregroundColor(.indigo)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Quiet hours 10pm – 7am")
                                    .foregroundColor(AppColors.textPrimary)
                                Text("Reminders land silently overnight and come back in the morning brief. Anything marked must-not-miss — flights, visas, medication — still comes through")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                    Toggle(isOn: $morningBrief) {
                        HStack {
                            Image(systemName: "sun.horizon.fill").foregroundColor(.yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Morning brief")
                                    .foregroundColor(AppColors.textPrimary)
                                Text("One spoken paragraph the first time you pick the phone up: what's due, what's overdue, the weather, and your visa countdown")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                    // BUILD 104 — how well the ear hears proper nouns.
                    Toggle(isOn: $hearingOfflineOnly) {
                        HStack {
                            Image(systemName: "ear.trianglebadge.exclamationmark")
                                .foregroundColor(.teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Offline hearing only")
                                    .foregroundColor(AppColors.textPrimary)
                                Text("Off is better: Chappy uses Apple's online speech model, which is far better at names like McDonald's or Gojek. Turn on to stay fully offline — free either way, and it falls back by itself with no signal")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                    // PHASE 5 — the old Live AI conversations. Folded in at
                    // launch; this is the AI pass that reads them properly.
                    Button {
                        recordsStatus = "Reading…"
                        Task {
                            await ChappyMemory.shared.runFactExtraction(manual: true)
                            recordsPending = ChappyMemory.shared.factsPending
                            recordsStatus = recordsPending == 0
                                ? "All caught up"
                                : "\(recordsPending) still to read"
                        }
                    } label: {
                        HStack {
                            Image(systemName: "text.book.closed")
                                .foregroundColor(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Read my old conversations")
                                    .foregroundColor(AppColors.textPrimary)
                                Text(recordsStatus.isEmpty
                                     ? (recordsPending == 0
                                        ? "All caught up — everything in Records is in Memory"
                                        : "\(recordsPending) conversations still to read through")
                                     : recordsStatus)
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            Spacer()
                        }
                    }
                    // POCKET LAW: the Action Button opens Chappy and the ear
                    // should already be listening. Off only for the user who
                    // deliberately wants a quiet, tap-to-listen phone.
                    Toggle(isOn: $standbyAutoArm) {
                        HStack {
                            Image(systemName: "ear.badge.checkmark")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Standby on at launch")
                                    .foregroundColor(AppColors.textPrimary)
                                Text("Wake word ready the moment Chappy opens — no need to take the phone out")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                    // How Chappy answers his name. Tone always; words rarely.
                    Picker(selection: $wakeStyle) {
                        Text("Tone, greeting now and then").tag("tone")
                        Text("Tone and a greeting every time").tag("greeting")
                        Text("Silent — buzz only").tag("silent")
                    } label: {
                        HStack {
                            Image(systemName: "bell.badge.fill")
                                .foregroundColor(.orange)
                            Text("When you say “Chappy”")
                                .foregroundColor(AppColors.textPrimary)
                        }
                    }

                    HStack {
                        Image(systemName: "person.fill")
                            .foregroundColor(.teal)
                        Text("Call me")
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        TextField("optional", text: $userName)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(AppColors.textSecondary)
                            .frame(maxWidth: 140)
                    }
                    // Pin the language you'll mostly need. Before a trip you
                    // know where you're going but aren't there yet, so location
                    // can't help and "last used" is empty — this fills that gap.
                    Picker(selection: $usualLanguage) {
                        Text("Ask me each time").tag("")
                        Text("Indonesian").tag("id")
                        Text("Thai").tag("th")
                        Text("Vietnamese").tag("vi")
                        Text("Filipino").tag("fil")
                        Text("Japanese").tag("ja")
                        Text("Korean").tag("ko")
                        Text("Chinese").tag("zh")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Spanish").tag("es")
                        Text("Italian").tag("it")
                        Text("Portuguese").tag("pt")
                    } label: {
                        HStack {
                            Image(systemName: "character.bubble.fill")
                                .foregroundColor(AppColors.translate)
                            Text("Usual language")
                                .foregroundColor(AppColors.textPrimary)
                        }
                    }

                    NavigationLink {
                        VoiceCheckView()
                    } label: {
                        HStack {
                            Image(systemName: "stethoscope")
                                .foregroundColor(.red)
                            Text("Voice check")
                                .foregroundColor(AppColors.textPrimary)
                        }
                    }

                    // BUILD 245: the same idea for the other failure that
                    // only happens when nobody can see a console.
                    NavigationLink {
                        LiveAICheckView()
                    } label: {
                        HStack {
                            Image(systemName: "waveform.badge.exclamationmark")
                                .foregroundColor(.orange)
                            Text("Live AI check")
                                .foregroundColor(AppColors.textPrimary)
                        }
                    }

                    // BUILD 247: the router's own record, finally visible.
                    NavigationLink {
                        CommandLogView()
                    } label: {
                        HStack {
                            Image(systemName: "list.bullet.rectangle")
                                .foregroundColor(.cyan)
                            Text("What Chappy did")
                                .foregroundColor(AppColors.textPrimary)
                        }
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text(standbyAutoArm
                         ? "Say “Chappy” then your command. Turning Standby off by hand keeps it off until you next open the app."
                         : "You'll need to tap Standby on the home screen each time before voice commands work.")
                        .font(AppTypography.caption)
                }

                // BUILD 137 — CHAPPY'S MEMORY, FINALLY ON A SCREEN.
                // The Pulse dial and the Codex were voice-only: real controls
                // with no visible state. Now the dial is a picker you can see,
                // and the Codex is a list you can read and prune — because a
                // profile you can't inspect is a profile you can't trust.
                Section {
                    Picker(selection: Binding(
                        get: { pulse.tier },
                        set: { pulse.setTier($0, speak: false) }
                    )) {
                        ForEach(ChappyPulse.Tier.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "camera.metering.matrix")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ambient memory (Pulse)")
                                    .foregroundColor(AppColors.textPrimary)
                                Text(pulse.tier == .off
                                     ? "Off — the camera only wakes when you ask"
                                     : "\(pulse.captionsToday) moments today · $\(String(format: "%.4f", pulse.spentTodayUSD)) spent")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                    NavigationLink {
                        CodexFactsList()
                    } label: {
                        HStack {
                            Image(systemName: "brain.head.profile")
                                .foregroundColor(.mint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("What Chappy knows about you")
                                    .foregroundColor(AppColors.textPrimary)
                                Text(keeper.facts.isEmpty
                                     ? "Nothing yet — the Codex distils facts as you live"
                                     : "\(keeper.facts.count) facts held — tap to read or remove them")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                    // BUILD 138 — the Trail's one switch.
                    Toggle(isOn: Binding(
                        get: { ChappyTrail.shared.isEnabled },
                        set: { ChappyTrail.shared.isEnabled = $0 }
                    )) {
                        HStack {
                            Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Daily trail")
                                    .foregroundColor(AppColors.textPrimary)
                                Text("Draws where you've been, day by day — visits and the path between them. Needs location on Always; stays on this phone; days expire after 90.")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                } header: {
                    Text("Chappy's memory")
                } footer: {
                    Text("Pulse quietly captions what the glasses see so days are remembered. Facts and captions stay on this phone; ambient moments expire after 45 days unless pinned.")
                        .font(AppTypography.caption)
                }

                // BUILD 147 — MAIL AND MESSAGES.
                Section {
                    NavigationLink {
                        MailSetupView()
                    } label: {
                        HStack {
                            Image(systemName: "envelope.badge")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Mail & Messages")
                                    .foregroundColor(AppColors.textPrimary)
                                Text(ChappyMail.shared.isConfigured
                                     ? "Connected: \(ChappyMail.shared.address) — say \u{201C}check my email\u{201D} or \u{201C}any texts\u{201D}"
                                     : "Connect your inbox — email AND your TelTel texts, read and answered by voice")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                } footer: {
                    Text("Uses an app-specific password over an encrypted connection, stored only in this phone's Keychain. Reading a summary never marks mail as read.")
                        .font(AppTypography.caption)
                }

                // BUILD 180 — YOUR MUSIC.
                Section {
                    NavigationLink {
                        AudioPolicyView()
                    } label: {
                        HStack {
                            Image(systemName: "speaker.wave.2.circle.fill")
                                .foregroundColor(.pink)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Music & other audio")
                                    .foregroundColor(AppColors.textPrimary)
                                Text(ChappyAudio.policyLine)
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                }

                // BUILD 177 — TRAVEL DESK: the one open door in travel data.
                Section {
                    NavigationLink {
                        TravelKeysView()
                    } label: {
                        HStack {
                            Image(systemName: "map.circle.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Travel Desk")
                                    .foregroundColor(AppColors.textPrimary)
                                Text(ChappyPlaces.shared.hasTripAdvisorKey
                                     ? "Tripadvisor connected \u{2014} ratings and reviews on every leg"
                                     : "Add a free Tripadvisor key for ratings and reviews")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                }

                // BUILD 230 — API KEYS, WITH A LIGHT ON EACH.
                Section {
                    NavigationLink {
                        ChappyKeysView()
                    } label: {
                        HStack {
                            Image(systemName: "key.horizontal.fill")
                                .foregroundColor(.cyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("API keys")
                                    .foregroundColor(AppColors.textPrimary)
                                Text(ChappyKeysView.summaryLine)
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            Spacer()
                            Circle()
                                .fill(ChappyKeysView.summaryColour)
                                .frame(width: 9, height: 9)
                        }
                    }
                    NavigationLink {
                        FlightKeysView()
                    } label: {
                        HStack {
                            Image(systemName: "airplane.circle.fill")
                                .foregroundColor(.cyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Fare data")
                                    .foregroundColor(AppColors.textPrimary)
                                Text(ChappyFareSource.isConfigured
                                     ? "On — the Fares tab has a live day grid"
                                     : "Add the free Travelpayouts token")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                } footer: {
                    Text("Every key the app uses, each one tested against the real provider rather than just checked for the right shape. Green means it authenticated; red carries the reason.")
                        .font(AppTypography.caption)
                }

                // BUILD 234 — HOW MUCH IT SAYS WITHOUT BEING ASKED.
                Section {
                    Picker("Speaks up", selection: Binding(
                        get: { ChappyNotify.unprompted },
                        set: { ChappyNotify.unprompted = $0 })) {
                        ForEach(ChappyNotify.Unprompted.allCases) { u in
                            Text(u.label).tag(u)
                        }
                    }
                    Text(ChappyNotify.unprompted.detail)
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                } header: {
                    Text("Talking to you")
                } footer: {
                    Text("Anything Chappy is not allowed to say out loud arrives as a notification instead — it is never thrown away. You can also just say \u{201C}Chappy, be quiet\u{201D}.")
                        .font(AppTypography.caption)
                }

                // BUILD 231 — WHO REPORTS GO TO.
                //
                // Stored once so "email my partner the Bali report" has
                // somewhere to send to. Without this the voice route can
                // only open an empty composer and hope you type an
                // address one-handed at an airport.
                Section {
                    NavigationLink {
                        ChappyPartnerView()
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .foregroundColor(.cyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Who reports go to")
                                    .foregroundColor(AppColors.textPrimary)
                                Text(ChappyHandoff.partner.isEmpty
                                     ? "Not set — say an address or type one"
                                     : ChappyHandoff.partner)
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                } footer: {
                    Text("Say \u{201C}email my partner the report\u{201D} and it goes here, attached, with one tap left to send. Nothing is ever sent without you tapping send — iOS does not allow an app to send mail on its own, and it never will.")
                        .font(AppTypography.caption)
                }


                // BUILD 157 — ADVANCED TOOLS. RTMP, Screen Stream and LeanEat
                // are leftovers from the project this app grew out of. They
                // still work; they just don't earn a place on the Home screen
                // unless you say so.
                Section {
                    Toggle(isOn: $showAdvancedTools) {
                        HStack {
                            Image(systemName: "wrench.adjustable.fill")
                                .foregroundColor(.gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show advanced tools")
                                    .foregroundColor(AppColors.textPrimary)
                                Text("RTMP Streaming, Screen Stream, LeanEat")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                } footer: {
                    Text("Off by default — these are experimental leftovers, not part of Chappy. Turning this on puts them back on the Home screen.")
                        .font(AppTypography.caption)
                }

                // BUILD 153 — RIDES & FOOD (Grab / Uber / Gojek handoff).
                Section {
                    NavigationLink {
                        RideSetupView()
                    } label: {
                        HStack {
                            Image(systemName: "car.circle.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Rides & Food")
                                    .foregroundColor(AppColors.textPrimary)
                                Text("Say \u{201C}get me a \(ChappyRide.shared.provider.display) to the airport\u{201D} or \u{201C}order food\u{201D}")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }
                    }
                } footer: {
                    Text("Chappy prices the trip and opens Grab, Uber or Gojek with the drop-off pre-filled — you confirm and pay in their app. Fares are estimates from the tariff table below, not live quotes.")
                        .font(AppTypography.caption)
                }

                // Appearance — Chappy theme picker
                Section {
                    NavigationLink {
                        ThemePickerList()
                    } label: {
                        HStack {
                            Image(systemName: "paintbrush.fill")
                                .foregroundColor(.pink)
                            Text("Theme")
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(UserDefaults.standard.string(forKey: "chappy_theme") ?? "Midnight Jade")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }

                    NavigationLink {
                        AvatarPickerList()
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.mint)
                            Text("Avatar")
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(UserDefaults.standard.string(forKey: "chappy_avatar") ?? "Auto (match theme)")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }
                } header: {
                    Text("Appearance")
                }

                // Usage — rough AI cost meter
                Section {
                    NavigationLink {
                        CostMeterView()
                    } label: {
                        HStack {
                            Image(systemName: "dollarsign.circle.fill")
                                .foregroundColor(.green)
                            Text("AI Usage")
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(String(format: "~$%.2f today", CostMeter.shared.today().4))
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }
                } header: {
                    Text("Usage")
                }

                // Backup & Restore — migration + lost-phone insurance
                Section {
                    Button {
                        if let url = ChappyBackup.shared.createBackup() {
                            presentShareSheet(url: url)
                        } else {
                            restoreResultMessage = "Backup failed — could not read app storage."
                            showRestoreResult = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.doc.fill")
                                .foregroundColor(.blue)
                            Text("Back Up Now")
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text("journal · records · settings")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }

                    Button {
                        showRestoreImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.doc.fill")
                                .foregroundColor(.orange)
                            Text("Restore from Backup")
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Back Up Now bundles your journal, spots, notes, conversation records and settings into one file — save it to iCloud Drive. On a new phone, install Chappy from TestFlight, then Restore from Backup.")
                }

                // OpenClaw
                Section {
                    Button {
                        showOpenClawSettings = true
                    } label: {
                        HStack {
                            Image(systemName: "link.circle.fill")
                                .foregroundColor(.purple)
                            Text("OpenClaw")
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(openClawStatusColor)
                                    .frame(width: 8, height: 8)
                                Text(openClawStatusText)
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }
                } header: {
                    Text("settings.integrations".localized)
                }

                // About
                Section {
                    InfoRow(title: "settings.version".localized, value: "2.0.0")
                    InfoRow(title: "settings.sdkversion".localized, value: "0.7.0")
                } header: {
                    Text("settings.about".localized)
                }
            }
            .navigationTitle("settings.title".localized)
            .sheet(isPresented: $showAPIKeySettings) {
                if providerManager.currentProvider == .alibaba {
                    APIKeySettingsView(provider: providerManager.currentProvider, endpoint: providerManager.alibabaEndpoint)
                } else {
                    APIKeySettingsView(provider: providerManager.currentProvider)
                }
            }
            .onChange(of: showAPIKeySettings) { isShowing in
                // Refresh state when the API key sheet closes
                if !isShowing {
                    refreshAPIKeyStatus()
                }
            }
            .sheet(isPresented: $showProviderSettings) {
                APIProviderSettingsView()
            }
            .onChange(of: showProviderSettings) { isShowing in
                if !isShowing {
                    refreshAPIKeyStatus()
                }
            }
            .sheet(isPresented: $showModelSettings) {
                VisionModelSettingsView()
            }
            .sheet(isPresented: $showLanguageSettings) {
                LanguageSettingsView(selectedLanguage: $selectedLanguage)
            }
            .sheet(isPresented: $showQualitySettings) {
                VideoQualitySettingsView(selectedQuality: $selectedQuality)
            }
            .fileImporter(isPresented: $showRestoreImporter,
                          allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    restoreResultMessage = ChappyBackup.shared.restore(from: url)
                case .failure(let error):
                    restoreResultMessage = "Could not open that file: \(error.localizedDescription)"
                }
                showRestoreResult = true
            }
            .alert("Backup", isPresented: $showRestoreResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(restoreResultMessage)
            }
            .sheet(isPresented: $showAppLanguageSettings) {
                AppLanguageSettingsView()
            }
            .sheet(isPresented: $showLiveAIProviderSettings) {
                LiveAIProviderSettingsView()
            }
            .sheet(isPresented: $showGoogleAPIKeySettings) {
                GoogleAPIKeySettingsView()
            }
            .onChange(of: showGoogleAPIKeySettings) { isShowing in
                // Refresh state when the Gemini API key sheet closes
                if !isShowing {
                    refreshAPIKeyStatus()
                }
            }
            .sheet(isPresented: $showQuickVisionSettings) {
                QuickVisionSettingsView()
            }
            .sheet(isPresented: $showLiveAISettings) {
                LiveAISettingsView()
            }
            .sheet(isPresented: $showLiveTranslateSettings) {
                LiveTranslateSettingsView(viewModel: LiveTranslateViewModel())
            }
            .sheet(isPresented: $showOpenClawSettings) {
                OpenClawSettingsView()
            }
            .onAppear {
                // Refresh API key state on appear
                refreshAPIKeyStatus()
                // Counted once, off the main thread: this decodes the whole
                // conversation archive out of UserDefaults.
                DispatchQueue.global(qos: .utility).async {
                    let n = ChappyMemory.shared.factsPending
                    DispatchQueue.main.async { recordsPending = n }
                }
            }
        }
    }

    private var openClawStatusColor: Color {
        switch OpenClawNodeService.shared.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .waitingForPairing: return .yellow
        default: return .gray
        }
    }

    private var openClawStatusText: String {
        switch OpenClawNodeService.shared.connectionState {
        case .connected: return "openclaw.status.connected".localized
        case .connecting: return "openclaw.status.connecting".localized
        case .disconnected: return "openclaw.status.disconnected".localized
        default: return "openclaw.status.disconnected".localized
        }
    }

    private func languageDisplayName(_ code: String) -> String {
        switch code {
        case "zh-CN": return "Chinese"
        case "en-US": return "English"
        case "ja-JP": return "Japanese"
        case "ko-KR": return "한국어"
        case "es-ES": return "Español"
        case "fr-FR": return "Français"
        default: return "English"
        }
    }

    private func qualityDisplayName(_ code: String) -> String {
        switch code {
        case "low": return "Low quality"
        case "medium": return "Medium quality"
        case "high": return "High quality"
        default: return "Medium quality"
        }
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(AppTypography.body)
                .foregroundColor(AppColors.textPrimary)
            Spacer()
            Text(value)
                .font(AppTypography.body)
                .foregroundColor(AppColors.textSecondary)
        }
    }
}

// MARK: - API Provider Settings

struct APIProviderSettingsView: View {
    @ObservedObject var providerManager = APIProviderManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(APIProvider.allCases, id: \.self) { provider in
                        Button {
                            providerManager.currentProvider = provider
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(provider.displayName)
                                        .foregroundColor(.primary)
                                    Text(provider == .alibaba ? "settings.provider.alibaba.desc".localized : "settings.provider.openrouter.desc".localized)
                                        .font(AppTypography.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                Spacer()
                                if providerManager.currentProvider == provider {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("settings.provider.select".localized)
                } footer: {
                    Text("settings.provider.description".localized)
                }

                // Alibaba endpoint selection (only show when Alibaba is selected)
                if providerManager.currentProvider == .alibaba {
                    Section {
                        ForEach(AlibabaEndpoint.allCases, id: \.self) { endpoint in
                            Button {
                                providerManager.alibabaEndpoint = endpoint
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(endpoint.displayName)
                                            .foregroundColor(.primary)
                                        Text(endpoint == .beijing ? "settings.endpoint.beijing.desc".localized : "settings.endpoint.singapore.desc".localized)
                                            .font(AppTypography.caption)
                                            .foregroundColor(AppColors.textSecondary)
                                    }
                                    Spacer()
                                    if providerManager.alibabaEndpoint == endpoint {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("settings.endpoint".localized)
                    } footer: {
                        Text("settings.endpoint.description".localized)
                    }
                }

                // API Key status for current provider
                Section {
                    HStack {
                        Text("settings.apikey.status".localized)
                        Spacer()
                        if providerManager.hasAPIKey {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("settings.apikey.configured".localized)
                                    .foregroundColor(.green)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.red)
                                Text("settings.apikey.notconfigured".localized)
                                    .foregroundColor(.red)
                            }
                        }
                    }

                    Link(destination: URL(string: providerManager.currentProvider.apiKeyHelpURL)!) {
                        HStack {
                            Text("settings.provider.getapikey".localized)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                } header: {
                    if providerManager.currentProvider == .alibaba {
                        Text("\(providerManager.currentProvider.displayName) (\(providerManager.alibabaEndpoint.displayName)) API Key")
                    } else {
                        Text("\(providerManager.currentProvider.displayName) API Key")
                    }
                }
            }
            .navigationTitle("settings.provider".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - API Key Settings

struct APIKeySettingsView: View {
    let provider: APIProvider
    var endpoint: AlibabaEndpoint? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""
    @State private var showSaveSuccess = false
    @State private var showError = false
    @State private var errorMessage = ""

    private var displayTitle: String {
        if provider == .alibaba, let endpoint = endpoint {
            return "\(provider.displayName) (\(endpoint.displayName))"
        }
        return provider.displayName
    }

    private var apiKeyHelpText: String {
        switch provider {
        case .anthropic:
            return "Paste your Claude API key (starts with sk-ant). Create one at console.anthropic.com under API Keys."
        case .openrouter:
            return "settings.apikey.openrouter.help".localized
        case .alibaba:
            return "settings.apikey.alibaba.help".localized
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    // BUILD 227: same disease as the travel keys — a
                    // SecureField in a Form is claimed by AutoFill, which
                    // eats the placeholder and the keystrokes. These have
                    // not been reported as broken, but they are the same
                    // shape of field holding the same shape of secret,
                    // and re-entering a Gemini key on a rented Mac in
                    // Indonesia is not the moment to discover it.
                    TextField("settings.apikey.placeholder".localized, text: $apiKey)
                        .font(.system(.footnote, design: .monospaced))
                        .textContentType(.none)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                } header: {
                    Text("\(displayTitle) API Key")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(apiKeyHelpText)
                        Link("settings.apikey.get".localized, destination: URL(string: provider.apiKeyHelpURL)!)
                            .font(.caption)
                    }
                }

                Section {
                    Button("save".localized) {
                        saveAPIKey()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(apiKey.isEmpty)

                    if APIKeyManager.shared.hasAPIKey(for: provider, endpoint: endpoint) {
                        Button("settings.apikey.delete".localized, role: .destructive) {
                            deleteAPIKey()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("settings.apikey.manage".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
            .alert("settings.apikey.saved".localized, isPresented: $showSaveSuccess) {
                Button("ok".localized) {
                    dismiss()
                }
            } message: {
                Text("settings.apikey.saved.message".localized)
            }
            .alert("error".localized, isPresented: $showError) {
                Button("ok".localized) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                // Load existing key if available
                if let existingKey = APIKeyManager.shared.getAPIKey(for: provider, endpoint: endpoint) {
                    apiKey = existingKey
                }
            }
        }
    }

    private func saveAPIKey() {
        guard !apiKey.isEmpty else {
            errorMessage = "settings.apikey.empty".localized
            showError = true
            return
        }

        if APIKeyManager.shared.saveAPIKey(apiKey, for: provider, endpoint: endpoint) {
            showSaveSuccess = true
        } else {
            errorMessage = "settings.apikey.savefailed".localized
            showError = true
        }
    }

    private func deleteAPIKey() {
        if APIKeyManager.shared.deleteAPIKey(for: provider, endpoint: endpoint) {
            apiKey = ""
            dismiss()
        } else {
            errorMessage = "settings.apikey.deletefailed".localized
            showError = true
        }
    }
}

// MARK: - Vision Model Settings

struct VisionModelSettingsView: View {
    @ObservedObject var providerManager = APIProviderManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showVisionOnly = true

    var body: some View {
        NavigationView {
            Group {
                if providerManager.currentProvider == .alibaba {
                    alibabaModelList
                } else {
                    openRouterModelList
                }
            }
            .navigationTitle("settings.model".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var alibabaModelList: some View {
        let models = [
            ("qwen3-vl-plus", "Qwen3 VL Plus", "settings.model.qwen3vlplus.desc".localized),
            ("qwen3-vl-max", "Qwen3 VL Max", "settings.model.qwen3vlmax.desc".localized)
        ]

        return List {
            Section {
                ForEach(models, id: \.0) { model in
                    Button {
                        providerManager.selectedModel = model.0
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.1)
                                    .foregroundColor(.primary)
                                Text(model.2)
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            Spacer()
                            if providerManager.selectedModel == model.0 {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            } header: {
                Text("settings.model.alibaba".localized)
            } footer: {
                Text("settings.model.current".localized + ": \(providerManager.selectedModel)")
            }
        }
    }

    private var openRouterModelList: some View {
        VStack {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("settings.model.search".localized, text: $searchText)
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.top, 8)

            // Vision only toggle
            Toggle("settings.model.visiononly".localized, isOn: $showVisionOnly)
                .padding(.horizontal)
                .padding(.vertical, 4)

            if providerManager.isLoadingModels {
                Spacer()
                ProgressView("settings.model.loading".localized)
                Spacer()
            } else if let error = providerManager.modelsError {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("settings.model.retry".localized) {
                        Task {
                            await providerManager.fetchOpenRouterModels()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                Spacer()
            } else {
                List {
                    let filteredModels = getFilteredModels()

                    if filteredModels.isEmpty {
                        Text("settings.model.notfound".localized)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredModels) { model in
                            Button {
                                providerManager.selectedModel = model.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(model.displayName)
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            if model.isVisionCapable {
                                                Image(systemName: "eye.fill")
                                                    .font(.caption)
                                                    .foregroundColor(.purple)
                                            }
                                        }
                                        Text(model.id)
                                            .font(AppTypography.caption)
                                            .foregroundColor(AppColors.textSecondary)
                                            .lineLimit(1)
                                        if !model.priceDisplay.isEmpty {
                                            Text(model.priceDisplay)
                                                .font(.caption2)
                                                .foregroundColor(.green)
                                        }
                                    }
                                    Spacer()
                                    if providerManager.selectedModel == model.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task {
            if providerManager.openRouterModels.isEmpty {
                await providerManager.fetchOpenRouterModels()
            }
        }
    }

    private func getFilteredModels() -> [OpenRouterModel] {
        var models = providerManager.openRouterModels

        if showVisionOnly {
            models = models.filter { $0.isVisionCapable }
        }

        if !searchText.isEmpty {
            models = providerManager.searchModels(searchText)
            if showVisionOnly {
                models = models.filter { $0.isVisionCapable }
            }
        }

        return models
    }
}

// MARK: - Language Settings

struct LanguageSettingsView: View {
    @Binding var selectedLanguage: String
    @Environment(\.dismiss) private var dismiss

    let languages = [
        ("zh-CN", "Chinese"),
        ("en-US", "English"),
        ("ja-JP", "Japanese"),
        ("ko-KR", "한국어"),
        ("es-ES", "Español"),
        ("fr-FR", "Français")
    ]

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(languages, id: \.0) { lang in
                        Button {
                            selectedLanguage = lang.0
                            UserDefaults.standard.set(lang.0, forKey: "output_language")
                        } label: {
                            HStack {
                                Text(lang.1)
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedLanguage == lang.0 {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Choose the output language")
                } footer: {
                    Text("AI This language will be used for spoken and written replies")
                }
            }
            .navigationTitle("Output language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Video Quality Settings

struct VideoQualitySettingsView: View {
    @Binding var selectedQuality: String
    @Environment(\.dismiss) private var dismiss

    var qualities: [(String, String, String)] {
        [
            ("low", "settings.quality.low".localized, "settings.quality.low.desc".localized),
            ("medium", "settings.quality.medium".localized, "settings.quality.medium.desc".localized),
            ("high", "settings.quality.high".localized, "settings.quality.high.desc".localized)
        ]
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(qualities, id: \.0) { quality in
                        Button {
                            selectedQuality = quality.0
                            UserDefaults.standard.set(quality.0, forKey: "video_quality")
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(quality.1)
                                        .foregroundColor(.primary)
                                    Text(quality.2)
                                        .font(AppTypography.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                Spacer()
                                if selectedQuality == quality.0 {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("settings.quality.select".localized)
                } footer: {
                    Text("settings.quality.description".localized)
                }
            }
            .navigationTitle("settings.quality".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - App Language Settings

struct AppLanguageSettingsView: View {
    @ObservedObject var languageManager = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showRestartAlert = false
    @State private var pendingLanguage: AppLanguage?

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Button {
                            // Only prompt to restart when a different language is chosen
                            if languageManager.currentLanguage != language {
                                pendingLanguage = language
                                showRestartAlert = true
                            }
                        } label: {
                            HStack {
                                Text(language.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if languageManager.currentLanguage == language {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("settings.applanguage.select".localized)
                } footer: {
                    Text("settings.applanguage.description".localized)
                }
            }
            .navigationTitle("settings.applanguage".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
            .alert("settings.applanguage.restart.title".localized, isPresented: $showRestartAlert) {
                Button("cancel".localized, role: .cancel) {
                    pendingLanguage = nil
                }
                Button("settings.applanguage.restart.confirm".localized) {
                    if let language = pendingLanguage {
                        languageManager.currentLanguage = language
                        // Exit after a short delay so settings persist
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            exit(0)
                        }
                    }
                }
            } message: {
                Text("settings.applanguage.restart.message".localized)
            }
        }
    }
}

// MARK: - Live AI Provider Settings

struct LiveAIProviderSettingsView: View {
    @ObservedObject var providerManager = APIProviderManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(LiveAIProvider.allCases, id: \.self) { provider in
                        Button {
                            providerManager.liveAIProvider = provider
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(provider.displayName)
                                        .foregroundColor(.primary)
                                    Text(liveAIProviderDescription(provider))
                                        .font(AppTypography.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                Spacer()
                                if providerManager.liveAIProvider == provider {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("settings.liveai.provider.select".localized)
                } footer: {
                    Text("settings.liveai.provider.description".localized)
                }

                // API Key status
                Section {
                    HStack {
                        Text("settings.apikey.status".localized)
                        Spacer()
                        if providerManager.hasLiveAIAPIKey {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("settings.apikey.configured".localized)
                                    .foregroundColor(.green)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.red)
                                Text("settings.apikey.notconfigured".localized)
                                    .foregroundColor(.red)
                            }
                        }
                    }

                    Link(destination: URL(string: providerManager.liveAIProvider.apiKeyHelpURL)!) {
                        HStack {
                            Text("settings.provider.getapikey".localized)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                } header: {
                    Text("\(providerManager.liveAIProvider.displayName) API Key")
                }
            }
            .navigationTitle("settings.liveai.provider".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func liveAIProviderDescription(_ provider: LiveAIProvider) -> String {
        switch provider {
        case .alibaba:
            return "settings.liveai.alibaba.desc".localized
        case .google:
            return "settings.liveai.google.desc".localized
        }
    }
}

// MARK: - Google API Key Settings

struct GoogleAPIKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""
    @State private var showSaveSuccess = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    // BUILD 227: same disease as the travel keys — a
                    // SecureField in a Form is claimed by AutoFill, which
                    // eats the placeholder and the keystrokes. These have
                    // not been reported as broken, but they are the same
                    // shape of field holding the same shape of secret,
                    // and re-entering a Gemini key on a rented Mac in
                    // Indonesia is not the moment to discover it.
                    TextField("settings.apikey.placeholder".localized, text: $apiKey)
                        .font(.system(.footnote, design: .monospaced))
                        .textContentType(.none)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                } header: {
                    Text("Google Gemini API Key")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("settings.apikey.google.help".localized)
                        Link("settings.apikey.get".localized, destination: URL(string: "https://aistudio.google.com/apikey")!)
                            .font(.caption)
                    }
                }

                Section {
                    Button("save".localized) {
                        saveAPIKey()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(apiKey.isEmpty)

                    if APIKeyManager.shared.hasGoogleAPIKey() {
                        Button("settings.apikey.delete".localized, role: .destructive) {
                            deleteAPIKey()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("settings.apikey.manage".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
            .alert("settings.apikey.saved".localized, isPresented: $showSaveSuccess) {
                Button("ok".localized) {
                    dismiss()
                }
            } message: {
                Text("settings.apikey.saved.message".localized)
            }
            .alert("error".localized, isPresented: $showError) {
                Button("ok".localized) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                if let existingKey = APIKeyManager.shared.getGoogleAPIKey() {
                    apiKey = existingKey
                }
            }
        }
    }

    private func saveAPIKey() {
        guard !apiKey.isEmpty else {
            errorMessage = "settings.apikey.empty".localized
            showError = true
            return
        }

        if APIKeyManager.shared.saveGoogleAPIKey(apiKey) {
            showSaveSuccess = true
        } else {
            errorMessage = "settings.apikey.savefailed".localized
            showError = true
        }
    }

    private func deleteAPIKey() {
        if APIKeyManager.shared.deleteGoogleAPIKey() {
            apiKey = ""
            dismiss()
        } else {
            errorMessage = "settings.apikey.deletefailed".localized
            showError = true
        }
    }
}


// MARK: - Chappy Voice Settings

struct ChappyVoiceSettingsView: View {
    @AppStorage("chappy_tts_voice") private var selectedVoice: String = "Kore"
    @ObservedObject private var tts = TTSService.shared

    // BUILD 139: the deep end added — Google ships 30 voices and the picker
    // only showed six. Algenib is the genuinely deep one.
    private let voices: [(name: String, description: String)] = [
        ("Kore", "Warm, friendly female - the Chappy default"),
        ("Aoede", "Bright, upbeat female"),
        ("Leda", "Calm, soothing female"),
        ("Sulafat", "Warm, rich female"),
        ("Gacrux", "Mature, seasoned female"),
        ("Puck", "Energetic male"),
        ("Charon", "Deep, steady male"),
        ("Fenrir", "Strong, confident male"),
        ("Algenib", "Gravelly, DEEP male - the rumble"),
        ("Iapetus", "Low, clear male"),
        ("Orus", "Firm, grounded male"),
        ("Sadaltager", "Knowledgeable male - the professor"),
        ("System", "Apple voice - instant and works offline")
    ]

    var body: some View {
        List {
            Section {
                ForEach(voices, id: \.name) { voice in
                    Button {
                        selectedVoice = voice.name
                        let sample = voice.name == "System"
                            ? "G'day Shaun, this is the offline Apple voice."
                            : "G'day Shaun, I'm Chappy - this is my \(voice.name) voice."
                        TTSService.shared.speak(sample, forceNetworkVoice: true)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.name)
                                    .foregroundColor(AppColors.textPrimary)
                                Text(voice.description)
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            Spacer()
                            if selectedVoice == voice.name {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
            } header: {
                Text("Pick a voice - tap to preview")
            } footer: {
                Text("Gemini voices need internet and your Gemini key. When offline, Chappy automatically falls back to the Apple voice.")
            }

            Section {
                Button {
                    TTSService.shared.speak("No worries - I'll read your answers, translations and alerts in this voice.", forceNetworkVoice: true)
                } label: {
                    HStack {
                        Image(systemName: tts.isSpeaking ? "speaker.wave.3.fill" : "play.circle.fill")
                        Text(tts.isSpeaking ? "Speaking..." : "Play a longer sample")
                    }
                }
                if tts.isSpeaking {
                    Button("Stop") { TTSService.shared.stop() }
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Chappy's Voice")
    }
}

// MARK: - Cost Meter View (Settings → Usage)

struct CostMeterView: View {
    @State private var today: (Double, Int, Int, Int, Double) = CostMeter.shared.today()
    @State private var monthCost: Double = CostMeter.shared.monthCostUSD()

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Estimated today")
                    Spacer()
                    Text(String(format: "$%.2f", today.4))
                        .font(.title3).bold()
                        .foregroundColor(today.4 >= 5 ? .orange : .green)
                }
                HStack {
                    Text("Estimated this month")
                    Spacer()
                    Text(String(format: "$%.2f", monthCost))
                        .bold()
                }
            } header: {
                Text("Spend (rough estimate)")
            }

            Section {
                HStack {
                    Label("Live AI", systemImage: "waveform.circle.fill")
                    Spacer()
                    Text(String(format: "%.0f min", today.0))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Label("Voice (TTS)", systemImage: "speaker.wave.2.fill")
                    Spacer()
                    Text("\(today.1) characters")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Label("Quick Vision", systemImage: "eye.circle.fill")
                    Spacer()
                    Text("\(today.2) looks")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Label("Deep Research", systemImage: "magnifyingglass.circle.fill")
                    Spacer()
                    Text("\(today.3) dives")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Today's activity")
            }

            Section {
                Text("These are ballpark numbers estimated on the phone, rounded up on purpose — a smoke alarm, not a bill. Chappy will also say it out loud when a day passes about $2, $5 and $10. Exact spend lives in your Google Cloud and Anthropic consoles.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("AI Usage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            today = CostMeter.shared.today()
            monthCost = CostMeter.shared.monthCostUSD()
        }
    }
}

// MARK: - Voice check
//
// Built after a week of "the voice commands don't work" with no way to tell
// WHICH of eight things was wrong. Every row is read live from the system at
// the moment you open it — permissions, whether audio is genuinely arriving at
// the microphone, where sound is going, whether the ear can survive
// backgrounding. No self-reported flags: this layer has been burned repeatedly
// by code that trusted its own bookkeeping over the truth.
struct VoiceCheckView: View {
    @State private var rows: [(String, String, Bool)] = []
    @State private var tick = 0
    /// BUILD 244: the arm path's own account of itself.
    @State private var logLines: [String] = []
    @State private var copied = false
    /// A STORED publisher, not one built inside `body`.
    ///
    /// `.onReceive(Timer.publish(...).autoconnect())` written inline
    /// constructs a fresh Autoconnect on every body evaluation, so SwiftUI
    /// resubscribes and restarts the timer each redraw — and since this
    /// handler writes `rows` (an array of tuples, not Equatable, so every
    /// assignment forces another redraw) it can end up never firing at all.
    /// A diagnostic screen that stops updating while it looks like it is
    /// updating is worse than no screen.
    private let logTick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    /// Every line the ear writes is prefixed with a symbol that says how bad
    /// it is. Colouring on that alone means the panel never has to parse the
    /// message — and a log that tries to understand itself is a log that can
    /// be wrong about itself.
    private func tint(_ line: String) -> Color {
        if line.contains("❌") { return .red }
        if line.contains("⚠️") { return .orange }
        if line.contains("✅") { return .green }
        if line.contains("REFUSED") || line.contains("ARM FAILED") { return .orange }
        return AppColors.textSecondary
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top) {
                        Image(systemName: r.2 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(r.2 ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.0).foregroundColor(AppColors.textPrimary)
                            Text(r.1)
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }
                }
            } header: {
                Text("Live status")
            } footer: {
                Text("If tones are missing but everything here is green, check the Ring/Silent switch on the side of the phone — iOS silences all system sounds when it's set to silent, whatever the app does.")
            }

            Section {
                Button {
                    ChappyEarcon.shared.prepare()
                    ChappyEarcon.shared.wake()
                } label: {
                    Label("Play the wake tone", systemImage: "speaker.wave.2.fill")
                }
                Button {
                    TTSService.shared.speak("This is Chappy's voice. If you can hear this, speech output is working.")
                } label: {
                    Label("Test the voice", systemImage: "waveform")
                }
                Button {
                    rows = ChappyStandby.diagnostics(); tick += 1
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("Try it")
            } footer: {
                Text("Hear the tone but not the voice: it's speech output. Hear the voice but not the tone: it's the silent switch. Neither: it's the output route.")
            }

            // ========================================================
            // BUILD 244 — THE STANDBY LOG.
            //
            // The rows above report STATE: armed or not, audio arriving
            // or not. They have been honest all week and they have not
            // been enough, because "wake word armed: no" is the symptom
            // and every build has been a guess at the cause.
            //
            // This is the cause. The arm path narrates every decision it
            // makes — which microphone it chose, what the node's format
            // came back as, which guard turned it away, what the engine
            // said when it refused to start — and all of it went to
            // print(), which on TestFlight goes nowhere at all.
            //
            // Newest last, so it reads like what happened.
            // ========================================================
            Section {
                if logLines.isEmpty {
                    Text("Nothing yet. Tap Standby on the home screen, come back here, and the whole arm attempt will be written out below.")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                } else {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                            .foregroundColor(tint(line))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 10))
                    }
                }
            } header: {
                HStack {
                    Text("Standby log")
                    Spacer()
                    Text("\(ChappyStandbyLog.shared.count) lines")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                }
            } footer: {
                Text("The last \(ChappyStandbyLog.windowSize) lines the ear wrote. Copy takes the whole buffer, not just what fits on screen — the line that explains it is usually the one that scrolled off.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = ChappyStandbyLog.shared.everything
                    copied = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy the whole log",
                          systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                }
                .foregroundColor(copied ? .green : AppColors.textPrimary)

                Button {
                    ChappyStandbyLog.shared.clear()
                    logLines = ChappyStandbyLog.shared.recent
                } label: {
                    Label("Clear the log", systemImage: "trash")
                }
                .foregroundColor(.orange)
            } footer: {
                Text("Clear it, tap Standby, then come straight back — that gives one clean arm attempt with nothing else in the way.")
            }
        }
        .navigationTitle("Voice check")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            rows = ChappyStandby.diagnostics()
            logLines = ChappyStandbyLog.shared.recent
        }
        // The ear keeps writing while this screen is open — arming is
        // asynchronous and its most interesting lines land a second or two
        // after the tap. A static snapshot would miss exactly those.
        .onReceive(logTick) { _ in
            logLines = ChappyStandbyLog.shared.recent
            // Every second is right for the log — the arm path writes several
            // lines a second while it is failing. The diagnostic rows query
            // the audio session, so they refresh every fourth tick instead.
            tick += 1
            if tick % 4 == 0 { rows = ChappyStandby.diagnostics() }
        }
    }
}

// MARK: - Live AI check (BUILD 245)
//
// Live AI works with the app open and dies on screen lock. The console
// that would explain it does not exist on a TestFlight build on a phone in
// a pocket, and by the time he can look at Xcode the session is long gone.
//
// So the log is written to DISK, it survives the app being killed, and it
// spans launches. Reading it back is this screen.
//
// The rows at the top are live state. The panel underneath is the history,
// and the history is the part that matters — the answer is a SEQUENCE, not
// a state: locked, then this, then that, then nothing.
struct LiveAICheckView: View {
    @State private var logLines: [String] = []
    @State private var copied = false
    private let liveTick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private func tint(_ line: String) -> Color {
        if line.contains("❌") || line.contains("⏸️") { return .red }
        if line.contains("⚠️") || line.contains("🔒") { return .orange }
        if line.contains("✅") { return .green }
        if line.contains("────") { return .cyan }
        if line.contains("🌑") || line.contains("🌒") { return .purple }
        return AppColors.textSecondary
    }

    var body: some View {
        List {
            Section {
                Text("Start Live AI, lock the phone, wait about thirty seconds, unlock, then come back here. The sequence below is what actually happened.")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
            } header: {
                Text("How to catch it")
            }

            Section {
                if logLines.isEmpty {
                    Text("Nothing recorded yet. This fills in as soon as a Live AI session starts.")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                } else {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                            .foregroundColor(tint(line))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 10))
                    }
                }
            } header: {
                HStack {
                    Text("Live AI log")
                    Spacer()
                    Text("\(ChappyLiveLog.shared.count) lines")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                }
            } footer: {
                Text("Kept on disk, so it survives the app being closed or killed. A line reading “app launched” directly after a background line means iOS terminated Chappy at that point — which is the one cause no other evidence can show.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = ChappyLiveLog.shared.everything
                    copied = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy the whole log",
                          systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                }
                .foregroundColor(copied ? .green : AppColors.textPrimary)

                Button {
                    ChappyLiveLog.shared.clear()
                    logLines = ChappyLiveLog.shared.recent
                } label: {
                    Label("Clear the log", systemImage: "trash")
                }
                .foregroundColor(.orange)
            } footer: {
                Text("Clear it, then do one clean run: start Live AI, lock, wait, unlock.")
            }

            Section {
                row("⏸️ suspended", "iOS stopped running Chappy entirely. Nothing in the app can act while this is happening.")
                row("🌑 background", "The screen locked or you switched away. The line under it says what Chappy did about it.")
                row("🔌 socket", "The connection to Google. The line under it says whether the app was on screen or backgrounded when it closed.")
                row("🎤 mic", "The microphone being let go or taken back.")
                row("──────", "A launch. Anything above it is a previous run of the app.")
            } header: {
                Text("What the symbols mean")
            }
        }
        .navigationTitle("Live AI check")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { logLines = ChappyLiveLog.shared.recent }
        .onReceive(liveTick) { _ in logLines = ChappyLiveLog.shared.recent }
    }

    private func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(AppColors.textPrimary)
            Text(v)
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textSecondary)
        }
    }
}

// MARK: - What Chappy did (BUILD 247)
//
// ChappyRouterLog has recorded every routed sentence since build 221 — what
// it heard, which tier claimed it, which tool ran, how confident it was,
// what came of it, and how long it took. Twenty-five builds of the single
// most useful record in the app, written to disk, and never once put on a
// screen.
//
// This is the screen that answers "why did Chappy do THAT". When a question
// about the weather comes back as "walking, riding, or a car?", the tier and
// tool columns say exactly which layer claimed the sentence and which tool
// it opened — instead of it being anyone's guess.
struct CommandLogView: View {
    @State private var entries: [ChappyRouterLog.Entry] = []
    @State private var copied = false

    /// BUILD 253 — A STORED PUBLISHER, and the reason is already written
    /// out in this same file, on VoiceCheckView's `logTick`.
    ///
    /// `.onReceive(Timer.publish(...).autoconnect())` written inline builds
    /// a fresh Autoconnect on every body evaluation, so SwiftUI resubscribes
    /// and restarts the countdown on every redraw. This handler assigns a
    /// non-Equatable array, which forces a redraw, which restarts the timer —
    /// and the "Copied" flag flipping back after two seconds is enough on its
    /// own to reset it forever. It can end up never firing at all.
    ///
    /// I wrote the inline version anyway. Review found it by reading the
    /// comment already in this file. That is three times in one build that a
    /// change of mine was contradicted by something a few lines away, which
    /// is worth recording rather than quietly correcting.
    private let logTick = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func tierColour(_ t: String) -> Color {
        switch t {
        case "pocket": return .green
        case "tiles": return .cyan
        case "flow": return .purple
        case "intent": return .orange
        case "plan": return .yellow
        case "ask": return .blue
        // BUILD 253 — two tiers that could not appear before this build
        // (model, untagged), and three that always could and were
        // rendered grey because nobody checked this list against what the
        // router actually writes (answer, reference, net). "pocket" is
        // still here and still has no producer anywhere in the app; left
        // in place because that is a routing gap to look at, not a colour
        // to delete.
        case "answer": return .teal
        case "reference": return .indigo
        case "net": return .brown
        case "model": return .pink
        // Amber, not red. UNTAGGED means the LOG has a gap, not that the
        // command failed — several tiers still don't name themselves. Red
        // would be a claim this screen cannot back up.
        case "untagged": return .orange
        default: return AppColors.textSecondary
        }
    }

    /// BUILD 253 — the delay, coloured, because a number in grey next to
    /// twenty other numbers in grey is not a diagnostic. Under a second is
    /// what it should feel like; past two and a half he has already said
    /// "it's not listening" and repeated himself.
    private func msColour(_ ms: Int) -> Color {
        if ms >= 2500 { return .red }
        if ms >= 1000 { return .orange }
        return AppColors.textSecondary
    }

    var body: some View {
        List {
            Section {
                if entries.isEmpty {
                    Text("Nothing routed yet. Say something to Chappy, or type it in the ask field, then come back.")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(Self.clock.string(from: e.at))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(AppColors.textSecondary)
                                Text(e.tier.uppercased())
                                    .font(.system(size: 9, weight: .heavy))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Capsule().fill(tierColour(e.tier).opacity(0.22)))
                                    .foregroundColor(tierColour(e.tier))
                                Spacer(minLength: 0)
                                Text("\(e.ms)ms")
                                    .font(.system(size: 9,
                                                  weight: e.ms >= 1000 ? .bold : .regular,
                                                  design: .monospaced))
                                    .foregroundColor(msColour(e.ms))
                            }
                            Text("\u{201C}\(e.heard)\u{201D}")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppColors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 5) {
                                if let t = e.tool {
                                    Text(t)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.cyan)
                                }
                                if let c = e.confidence {
                                    Text(String(format: "%.0f%%", c * 100))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(c < 0.5 ? .orange : AppColors.textSecondary)
                                }
                            }
                            Text(e.outcome)
                                .font(.system(size: 10.5))
                                .foregroundColor(AppColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                        .textSelection(.enabled)
                    }
                }
            } header: {
                HStack {
                    Text("Newest first")
                    Spacer()
                    Text("\(entries.count) routed")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                }
            } footer: {
                Text("TIER is which layer claimed the sentence \u{2014} tiles is a screen name, answer is a module answering outright, reference resolved \u{201C}that one\u{201D} to a saved place, flow is a multi-step tool, intent and plan are the smart layers, ask is a general question answered by the cheap brain, model is the session with tools, net is a background network result rather than a routing decision, and UNTAGGED in amber means no tier recorded a working decision at all.\n\nUNTAGGED does NOT mean it failed. Navigation, briefs, timers, lists and the screen openers still don\u{2019}t name themselves in this log, so a command that worked perfectly can land there. It means the RECORD has a gap. If the command also did nothing, that is the line to send me.\n\nThe ms is the wait from when you stopped talking to when that decision was made. Amber past a second, red past two and a half. Before build 253 most tiers wrote a hardcoded 1ms, which looked instant and meant nothing; they all read the same clock now.\n\nTwo limits worth knowing. Say something else within eight seconds and the first sentence\u{2019}s gap check is dropped, rather than risk pinning it on the wrong sentence. And on a compound (\u{201C}do this and do that\u{201D}) a later half can make an earlier half look accounted for.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = entries.map {
                        "\(Self.clock.string(from: $0.at))  [\($0.tier)] \"\($0.heard)\" -> \($0.tool ?? "none") \($0.confidence.map { String(format: "%.2f", $0) } ?? "") : \($0.outcome) (\($0.ms)ms)"
                    }.joined(separator: "\n")
                    copied = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy the whole log",
                          systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                }
                .foregroundColor(copied ? .green : AppColors.textPrimary)
            }
        }
        .navigationTitle("What Chappy did")
        .navigationBarTitleDisplayMode(.inline)
        // BUILD 253: sorted, not just reversed. A gap entry is written
        // eight seconds after the decision it describes but carries the
        // decision's own timestamp, so append order and time order are no
        // longer the same thing. Reversing alone would have put the gap
        // line above the command that came after it.
        //
        // And refreshed on a tick, not only onAppear. With a gap entry
        // landing eight seconds after the decision, the most interesting
        // line on this screen is routinely written WHILE he is looking at
        // it — and a screen that only shows it if you leave and come back
        // is a screen that will be blamed for the gap.
        .onAppear { reload() }
        .onReceive(logTick) { _ in reload() }
    }

    private func reload() {
        entries = ChappyRouterLog.shared.entries.sorted { $0.at > $1.at }
    }
}

/// One switch per kind of notification. Deliberately granular: the fastest way
/// to make someone turn off ALL your notifications is to make them take the
/// noisy one to get the useful one.
struct NotificationChannelsView: View {
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    var body: some View {
        Form {
            Section {
                Text("Chappy speaks when it can. A notification only fires when it couldn't have — the app closed, the ear stood down, or the glasses off your face. So these never repeat something you already heard.")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
            }
            Section("Reminders") {
                HStack {
                    Image(systemName: "bell.fill").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Always on").foregroundColor(AppColors.textPrimary)
                        Text("Every reminder notifies — spoken if Chappy is running, a banner if it isn't. Long-press the banner for Done, 10 minutes, or When I'm home. Quiet hours and the morning brief are the switches for these, back on the main settings page.")
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
                Button("Test a reminder notification in 15 seconds") {
                    ChappyReminders.shared.add(
                        title: "Test reminder - long-press me",
                        at: Date().addingTimeInterval(15),
                        source: "test")
                }
            }
            Section("Everything else") {
                ForEach(ChappyNotify.Channel.allCases, id: \.rawValue) { ch in
                    ChannelToggle(channel: ch)
                }
            }
            Section {
                Button("Send me a test notification") {
                    ChappyNotify.post(.system,
                                      title: "Chappy",
                                      body: "That's what one looks like. Long-press a reminder to snooze it from here.",
                                      force: true)
                }
            } footer: {
                Text("Lock the phone first — it won't show while you're looking at this screen, by design.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ChannelToggle: View {
    let channel: ChappyNotify.Channel
    @State private var on = true
    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.label).foregroundColor(AppColors.textPrimary)
                Text(channel.detail)
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
        .onAppear {
            on = UserDefaults.standard.object(forKey: channel.key) == nil
                ? channel.defaultOn
                : UserDefaults.standard.bool(forKey: channel.key)
        }
        .onChange(of: on) { newValue in
            UserDefaults.standard.set(newValue, forKey: channel.key)
        }
    }
}

/// One row per calendar, grouped by the account it came from. Everything is
/// on until switched off — the common case is muting a work calendar on
/// holiday, not hunting through a checklist before anything happens at all.
struct CalendarPickerView: View {
    @StateObject private var cal = ChappyCalendar.shared
    @AppStorage("chappy_cal_leaveby") private var leaveBy = true
    @State private var tick = 0

    var body: some View {
        Form {
            if !cal.authorised {
                Section {
                    Text("Chappy can't see your calendars yet.")
                        .foregroundColor(AppColors.textPrimary)
                    Button("Allow calendar access") { ChappyCalendar.shared.requestAccess() }
                    Text("If nothing happens, iOS has already asked once — turn it on in Settings › Chappy › Calendars.")
                        .font(AppTypography.caption).foregroundColor(AppColors.textSecondary)
                }
            } else {
                Section {
                    Toggle(isOn: $leaveBy) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tell me when to leave").foregroundColor(AppColors.textPrimary)
                            Text("For any appointment with a place on it, worked out from real travel time from where you actually are — not a fixed countdown")
                                .font(AppTypography.caption).foregroundColor(AppColors.textSecondary)
                        }
                    }
                }
                ForEach(sources, id: \.self) { source in
                    Section(source) {
                        ForEach(cal.allCalendars.filter { ($0.source?.title ?? "Other") == source },
                                id: \.calendarIdentifier) { c in
                            CalendarRow(cal: c, tick: $tick)
                        }
                    }
                }
                .id(tick)
            }
        }
        .navigationTitle("Calendars")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ChappyCalendar.shared.requestAccess() }
    }

    private var sources: [String] {
        var seen: [String] = []
        for c in cal.allCalendars {
            let s = c.source?.title ?? "Other"
            if !seen.contains(s) { seen.append(s) }
        }
        return seen
    }
}

/// BUILD 111 — one row per calendar, with what Chappy should DO about it.
///
/// Four behaviours, because twelve calendars treated identically is unusable:
/// your jobs and a birthday should not get the same treatment, and reading all
/// of it out every morning is how you end up switching the whole thing off.
///
/// It guesses sensibly first — anything that looks like work defaults to Ping,
/// holidays and birthdays to Show — so this screen is somewhere you go to
/// disagree, not somewhere you have to visit before anything works.
struct CalendarRow: View {
    let cal: EKCalendar
    @Binding var tick: Int
    @State private var behaviour: ChappyCalendar.Behaviour = .brief
    @State private var lead: Int = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(cgColor: cal.cgColor ?? UIColor.gray.cgColor))
                    .frame(width: 10, height: 10)
                Text(cal.title)
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                Button {
                    ChappyCalendar.shared.setOn(cal, !ChappyCalendar.shared.isEnabled(cal))
                    tick += 1
                } label: {
                    Image(systemName: ChappyCalendar.shared.isEnabled(cal)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(ChappyCalendar.shared.isEnabled(cal)
                                         ? .accentColor : AppColors.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if ChappyCalendar.shared.isEnabled(cal) {
                Picker("", selection: $behaviour) {
                    ForEach(ChappyCalendar.Behaviour.allCases, id: \.rawValue) { b in
                        Text(b.label).tag(b)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: behaviour) { newValue in
                    ChappyCalendar.shared.setBehaviour(newValue, for: cal)
                }

                Text(behaviour.detail)
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)

                if behaviour == .ping {
                    Stepper("Warn me \(ChappyCalendar.leadLabel(lead))",
                            value: $lead, in: 5...2880, step: lead >= 120 ? 60 : 5)
                        .font(AppTypography.caption)
                        .onChange(of: lead) { newValue in
                            ChappyCalendar.shared.setLeadMinutes(newValue, for: cal)
                        }
                    Text("Plus a leave-by warning worked out from real travel time, for anything with an address on it.")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            behaviour = ChappyCalendar.shared.behaviour(for: cal)
            lead = ChappyCalendar.shared.leadMinutes(for: cal)
        }
    }
}

// BUILD 137 — THE CODEX, READABLE AND PRUNABLE.
//
// Every durable fact Chappy holds about the wearer, on one screen: what it
// is, when it was first learned, when it was last confirmed true. Swipe to
// remove one; the button at the bottom clears the lot. Nothing here is a
// transcript — these are the distilled lines the Codex keeps ("scooter
// rider", "no shellfish") and injects into prompts so Chappy acts like it
// knows you.
struct CodexFactsList: View {
    @ObservedObject private var keeper = ChappyMemoryKeeper.shared
    @State private var confirmWipe = false

    var body: some View {
        List {
            if keeper.facts.isEmpty {
                Section {
                    Text("Nothing yet. The Codex reads the day's memories once a night and keeps only what stays true — where you live, how you get around, what you can't eat. Facts appear here as they're learned.")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                }
            } else {
                Section {
                    ForEach(keeper.facts) { f in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.text)
                                .foregroundColor(AppColors.textPrimary)
                            Text("Learned \(Self.day(f.firstSeen)) · confirmed \(Self.day(f.lastConfirmed))")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }
                    .onDelete { idx in
                        for i in idx { keeper.forget(keeper.facts[i].id) }
                    }
                } footer: {
                    Text("Swipe left to remove a fact. Removed facts are gone — the Codex won't re-add one unless it's genuinely observed again.")
                        .font(AppTypography.caption)
                }
                Section {
                    Button(role: .destructive) {
                        confirmWipe = true
                    } label: {
                        Text("Forget everything")
                    }
                    .confirmationDialog("Remove every fact the Codex holds?",
                                        isPresented: $confirmWipe,
                                        titleVisibility: .visible) {
                        Button("Forget everything", role: .destructive) {
                            keeper.forgetEverything()
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
        }
        .navigationTitle("What Chappy knows")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f.string(from: d)
    }
}


// BUILD 147 — MAIL & MESSAGES SETUP.
//
// One screen, three fields, honest instructions. iCloud needs an
// app-specific password (appleid.apple.com → Sign-In & Security →
// App-Specific Passwords) — the real account password will NOT work and
// is never asked for.
// BUILD 257 — WHY HE COULD NEVER SAVE HIS APP PASSWORD.
//
// Build 227 fixed this exact bug for every API key in the app and this
// screen was missed. It was the LAST SecureField in a Form holding a secret
// anywhere in the settings tree. Read 227's note below ChappyKeyField: iOS
// treats a SecureField in a Form as a new-password field, AutoFill claims
// it, and the binding stays empty however carefully you paste. Then:
//
//     guard !addr.isEmpty, !password.isEmpty, !host.isEmpty else {
//         status = "Fill in the address and password first."; return
//     }
//
// …fires, and he is told to fill in a field he has just filled in. Which is
// precisely what he reported: "I can't enter and save my iCloud app
// password, thought you fixed that."
//
// THREE MORE IN THE SAME SCREEN, all from @State that is never loaded back:
//
//   - `customHost` starts empty and `useICloud` starts true, neither read
//     from what is stored. So a custom IMAP user reopens this screen, sees
//     "iCloud" selected, changes nothing, taps Save — and his host is
//     silently overwritten with imap.mail.me.com.
//   - `password` is never read back either, so the guard above blocks a save
//     of anything ELSE. Changing only the email address was impossible
//     without retyping the app password from scratch.
//   - `mail` was observed and never used, so the view did not re-render.
//     Now it IS used — load() and save() read and write through it. Review
//     caught that my first cut listed this in the fix list and then left the
//     property dangling exactly as it found it.
//
// Every other key screen in this app repopulates in onAppear. This one just
// never did.
struct MailSetupView: View {
    @ObservedObject private var mail = ChappyMail.shared
    @State private var address = ChappyMail.shared.address
    @State private var password = ""
    @State private var useICloud = true
    @State private var customHost = ""
    @State private var status = ""
    /// True when a password is already stored, so the field can be left
    /// blank to keep it rather than demanding a retype.
    @State private var hasStoredPassword = false

    var body: some View {
        Form {
            Section("Email address") {
                TextField("vikingshaun@icloud.com", text: $address)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            Section {
                Picker("Provider", selection: $useICloud) {
                    Text("iCloud").tag(true)
                    Text("Other (IMAP)").tag(false)
                }
                .pickerStyle(.segmented)
                if !useICloud {
                    TextField("imap.example.com", text: $customHost)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                // BUILD 257: the same field every other key in the app has
                // used since 227. textContentType(.none) is the whole fix.
                ChappyKeyField(title: hasStoredPassword
                               ? "App-specific password (saved — leave blank to keep)"
                               : "App-specific password",
                               text: $password,
                               onSave: { save() })
            } footer: {
                Text(useICloud
                     ? "Make the password at appleid.apple.com → Sign-In & Security → App-Specific Passwords. Your real Apple password will not work and is never wanted."
                     : "Your mail host's IMAP server, port 993. Use an app password if the provider offers them.")
            }
            Section {
                Button("Save & test") { save() }
                // BUILD 257: a wrong password could only ever be REPLACED.
                // There was no way to get back to "not set up", so a bad
                // paste left mail permanently half-configured.
                if hasStoredPassword {
                    Button(role: .destructive) {
                        APIKeyManager.shared.deleteMailPassword()
                        hasStoredPassword = false
                        password = ""
                        status = "Password forgotten. Paste a new one when you're ready."
                    } label: { Text("Forget the stored password") }
                }
                if !status.isEmpty {
                    Text(status).font(.footnote).foregroundColor(.secondary)
                }
            } footer: {
                Text("Texts arriving through TelTel (…@teltel.com.au) are announced as texts, and replying to one sends a real SMS back through the gateway.")
            }
        }
        .navigationTitle("Mail & Messages")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    /// BUILD 257: read the stored setup back, so reopening this screen shows
    /// what is actually configured instead of the defaults.
    private func load() {
        address = mail.address
        let host = mail.host
        useICloud = host.isEmpty || host == "imap.mail.me.com"
        customHost = useICloud ? "" : host
        hasStoredPassword = mail.isConfigured
        password = ""
    }

    private func save() {
        let host = useICloud ? "imap.mail.me.com" : customHost.trimmingCharacters(in: .whitespaces)
        let addr = address.trimmingCharacters(in: .whitespaces)
        let pw = password.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty, !host.isEmpty else {
            status = "Fill in the address first."; return
        }
        // BUILD 257: a blank password with one already stored means "keep the
        // one I have", not "refuse to save". That is what made changing the
        // email address alone impossible.
        guard !pw.isEmpty || hasStoredPassword else {
            status = "Paste the app-specific password first."; return
        }
        mail.configure(address: addr, host: host, password: pw.isEmpty ? nil : pw)
        hasStoredPassword = true
        password = ""
        status = "Checking…"
        Task { status = await ChappyMail.shared.check() }
    }
}


// BUILD 150 — FLIGHT KEYS. Two fields, Keychain-stored, addable whenever.
// =====================================================================
// BUILD 227 — THE KEY FIELD.
//
// Every API key in this app was a SecureField, and every one of them was
// unsaveable for the same reason: iOS reads a SecureField in a Form as a
// new-password field, hands it to AutoFill, and AutoFill eats both the
// placeholder and the keystrokes. Save then wrote the empty binding over
// a key that had been pasted correctly.
//
// Four things this does that the old field did not:
//
//   1. textContentType(.none) — the line that actually stops AutoFill
//      claiming it. Without this nothing else here matters.
//   2. A Paste button. He is copying a long random string out of a
//      browser on another device; typing it is not a real option, and a
//      masked field makes a bad paste invisible.
//   3. Show/hide, defaulting to SHOWN, because the entire point of
//      looking at a key you just pasted is to see that it arrived whole.
//   4. A character count. A key that pasted short is obvious at a glance
//      instead of failing silently at the first call.
// =====================================================================

struct ChappyKeyField: View {
    let title: String
    @Binding var text: String
    var onSave: () -> Void

    @State private var hidden = false

    private var masked: String {
        guard hidden, !text.isEmpty else { return text }
        return String(repeating: "•", count: min(text.count, 40))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if hidden {
                    Text(masked.isEmpty ? title : masked)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(text.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(title, text: $text, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1...3)
                        // THE IMPORTANT LINE. Everything else here is
                        // comfort; this is what stops iOS deciding the
                        // field is a password and taking it over.
                        .textContentType(.none)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        .submitLabel(.done)
                }

                // BUILD 228: a 17pt glyph. Legal target now.
                Button { hidden.toggle() } label: {
                    Image(systemName: hidden ? "eye.slash" : "eye")
                        .font(.body)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            HStack(spacing: 14) {
                Button {
                    if let p = UIPasteboard.general.string {
                        text = p.trimmingCharacters(in: .whitespacesAndNewlines)
                        hidden = false
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.subheadline).fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button("Save") { onSave() }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)

                if !text.isEmpty {
                    Button { text = "" } label: {
                        Label("Clear", systemImage: "xmark.circle")
                            .font(.subheadline)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }

                Spacer()

                if !text.isEmpty {
                    Text("\(text.count) characters")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// =====================================================================
// BUILD 230 — THE KEYS SCREEN.
//
// The dot is the smallest part of this. The useful part is the sentence
// under each row saying WHAT STOPS WORKING when that key dies — "Gemini
// is red" means nothing, "the voice is down" means everything.
//
// Tests run when the screen opens and the answers are cached, so opening
// it tells you the truth without pressing anything. AviationStack is the
// exception and says so on the row: testing it spends one of your
// hundred a month, so it runs at most once a day.
// =====================================================================

// BUILD 231 — where reports go.
struct ChappyPartnerView: View {
    @State private var email = ChappyHandoff.partner
    @State private var name = ChappyHandoff.partnerName
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                TextField("name@example.com", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Email address")
            } footer: {
                Text("Every report Chappy builds can go here — the trip plan with the map, the flight brief, the comparison, the memory export.")
            }

            Section {
                TextField("your partner", text: $name)
            } header: {
                Text("What to call them")
            } footer: {
                Text("Only used in what Chappy says back — \u{201C}addressed to Sam, one tap sends it\u{201D}.")
            }

            Section {
                Button {
                    ChappyHandoff.partner = email.trimmingCharacters(in: .whitespacesAndNewlines)
                    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    ChappyHandoff.partnerName = n.isEmpty ? "your partner" : n
                    saved = true
                } label: {
                    Text("Save").fontWeight(.semibold).frame(minHeight: 44)
                }
                if saved {
                    Text("Saved.").font(.footnote).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Who reports go to")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ChappyKeysView: View {

    @ObservedObject private var keys = ChappyKeys.shared
    @State private var tripKey = UserDefaults.standard.string(forKey: "chappy_tripadvisor_key") ?? ""
    @State private var fareKey = UserDefaults.standard.string(forKey: "chappy_tp_token") ?? ""

    /// For the Settings row, so the state is visible before you open it.
    static var summaryLine: String {
        let k = ChappyKeys.shared
        let bad = k.problems
        if !bad.isEmpty {
            return "\(bad.count) not working — \(bad.map(\.label).joined(separator: ", "))"
        }
        let live = ChappyKeys.Slot.allCases.filter { k.status($0).state == .live }.count
        if live == 0 { return "Not checked yet — open to test them" }
        let missing = ChappyKeys.Slot.allCases
            .filter { k.status($0).state == .missing && !$0.baked }
        return missing.isEmpty
            ? "All \(live) answering"
            : "\(live) answering · \(missing.count) still to set up"
    }

    static var summaryColour: Color {
        let k = ChappyKeys.shared
        if !k.problems.isEmpty { return .red }
        if ChappyKeys.Slot.allCases.contains(where: { k.status($0).state == .unknown }) {
            return .orange
        }
        return .green
    }

    var body: some View {
        Form {
            Section {
                Text("Each of these is tested by actually calling the provider — not by checking the key looks right, which is what most apps mean by validating a key and which passes a revoked one every time.")
                    .font(.footnote).foregroundColor(.secondary)
            }

            ForEach(ChappyKeys.Slot.allCases) { slot in
                Section {
                    row(slot)
                    if slot == .tripadvisor {
                        ChappyKeyField(title: "Paste the Tripadvisor key", text: $tripKey) {
                            let k = tripKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            tripKey = k
                            UserDefaults.standard.set(k, forKey: "chappy_tripadvisor_key")
                            Task { await keys.test(.tripadvisor, force: true) }
                        }
                    }
                    if slot == .fares {
                        ChappyKeyField(title: "Paste the Travelpayouts token", text: $fareKey) {
                            let k = fareKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            fareKey = k
                            UserDefaults.standard.set(k, forKey: "chappy_tp_token")
                            ChappyFareSource.shared.forget()
                            Task { await keys.test(.fares, force: true) }
                        }
                    }
                } header: {
                    Text(slot.label)
                }
            }

            Section {
                Button {
                    Task { await keys.testAll(force: false) }
                } label: {
                    Label("Test them all again", systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                }
            } footer: {
                Text("Green means the key authenticated at the time shown. It cannot tell you how much credit is left or when a key expires — no provider exposes that on a key check, and claiming otherwise would be a guess dressed up as a status light.")
            }
        }
        .navigationTitle("API keys")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await keys.testAll(force: false) }
        }
    }

    @ViewBuilder private func row(_ slot: ChappyKeys.Slot) -> some View {
        let st = keys.status(slot)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                if keys.isTesting(slot) {
                    ProgressView().scaleEffect(0.7).frame(width: 14)
                } else {
                    Image(systemName: st.state.dot)
                        .font(.system(size: 13))
                        .foregroundColor(colour(st.state))
                        .frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline(slot, st))
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(colour(st.state))
                    Text(keys.masked(slot))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    Task { await keys.test(slot, force: true) }
                } label: {
                    Text("Test")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(keys.isTesting(slot))
            }

            if !st.detail.isEmpty {
                Text(st.detail)
                    .font(.caption)
                    .foregroundColor(st.state == .failed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(slot.unlocks)
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !slot.testCosts.isEmpty {
                Label(slot.testCosts, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if slot.baked {
                Text("Built into the app — you don't need to enter this one.")
                    .font(.caption2).foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding(.vertical, 3)
    }

    private func headline(_ slot: ChappyKeys.Slot, _ st: ChappyKeys.Status) -> String {
        switch st.state {
        case .live:
            guard let at = st.at else { return "Working" }
            return "Working — checked \(Self.ago(at))"
        case .failed:  return "Not working"
        case .missing: return slot.baked ? "Missing from the build" : "Not set up"
        case .unknown: return "Not checked yet"
        }
    }

    private func colour(_ s: ChappyKeys.State) -> Color {
        switch s {
        case .live:    return .green
        case .failed:  return .red
        case .missing: return .orange
        case .unknown: return .secondary
        }
    }

    private static func ago(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        if m < 2 { return "just now" }
        if m < 60 { return "\(m) min ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        return "\(h / 24)d ago"
    }
}

struct FlightKeysView: View {
    @State private var status = ChappyFlights.shared.isConfigured
        ? "Old Amadeus keys are still stored and still work."
        : "No Amadeus keys — nothing needs them."
    // BUILD 217 — the one on this screen that actually does something.
    @State private var fareKey = ChappyFareSource.token
    @State private var fareStatus = ""

    var body: some View {
        Form {
            // BUILD 217 — FARE DATA.
            //
            // Put first, above the dead Amadeus fields, because it is the
            // only thing on this screen that can still be switched on. It
            // buys the price graph's market line and the cheapest-day
            // grid; without it the graph still runs on the fares you log
            // yourself, which is the half that is unarguably real.
            Section {
                ChappyKeyField(title: "Paste the Travelpayouts token", text: $fareKey) {
                    let k = fareKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    fareKey = k
                    UserDefaults.standard.set(k, forKey: ChappyFareSource.tokenKey)
                    ChappyFareSource.shared.forget()
                    fareStatus = k.isEmpty
                        ? "Cleared. The graph runs on your own journal now."
                        : "Saved \(k.count) characters. Open Flights, Fares tab — the day grid fills in."
                }
                if !fareStatus.isEmpty {
                    Text(fareStatus).font(.footnote).foregroundColor(.secondary)
                }
                HStack {
                    Circle()
                        .fill(ChappyFareSource.isConfigured ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(ChappyFareSource.isConfigured
                         ? "Fare data on"
                         : "Journal only")
                        .font(.footnote).foregroundColor(.secondary)
                }
            } header: {
                Text("Fare data")
            } footer: {
                Text("Sign up free at travelpayouts.com, open the API section and copy the token. It is self-serve — no partner approval, no card. What it gives you is the cheapest fare somebody's search actually RETURNED for each day of a month, with the date it was seen. That is not a live quote and it does not book anything, and Chappy says so every time it shows you one. WITHOUT it, everything still works: the graph draws the fares you log yourself and the verdict on whether a price is any good comes from your own record, which is the only source that cannot be switched off.")
            }

            // BUILD 230 — THE AMADEUS FIELDS ARE GONE.
            //
            // Amadeus paused self-service registrations in March 2026 and
            // decommissioned the developer portal outright on 17 July
            // 2026. There is no signup form left to fill in. A settings
            // field you cannot possibly complete wastes your time twice:
            // once trying, and once wondering whether you should.
            //
            // The flight day always ran on AviationStack, which is baked
            // in and now has a light on it in API keys.
            // BUILD 257 — AND NOW THE SAVE BUTTON IS GONE TOO.
            //
            // The comment above has said "the Amadeus fields are gone" since
            // 230, and the fields were indeed removed — but the Save button
            // was left behind, wired to two @State strings that no input
            // control in this view was ever bound to. So `apiKey` and
            // `apiSecret` were permanently "", the guard could never pass,
            // and tapping Save cleared the status line and did nothing else.
            //
            // A button that cannot work is worse than no button: it reads as
            // "you did not fill this in properly". Removed, and the state it
            // used with it. If old enterprise keys ever matter again they
            // come back as real ChappyKeyFields, like every other key.
            Section {
                if !status.isEmpty { Text(status).font(.footnote).foregroundColor(.secondary) }
            } footer: {
                Text("AMADEUS IS GONE. Amadeus paused self-service registrations in March 2026 and decommissioned the developer portal entirely on 17 July 2026 - keys disabled, no signup form left. This is not an accreditation problem; there is nothing to sign up for. Your flight day runs on AviationStack instead and always did. The entry fields and Save button that used to be here have been removed - they were wired to nothing and did nothing when tapped. Any old enterprise keys already in the Keychain are still read and still used.")
            }
        }
        .navigationTitle("Flights")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// BUILD 153 — RIDES & FOOD settings: provider, tariff band, favourites.
struct RideSetupView: View {
    @State private var provider = UserDefaults.standard.string(forKey: "chappy_ride_provider") ?? "auto"
    @State private var base = UserDefaults.standard.double(forKey: "chappy_ride_base")
    @State private var perKm = UserDefaults.standard.double(forKey: "chappy_ride_perkm")
    @State private var perMin = UserDefaults.standard.double(forKey: "chappy_ride_permin")
    @State private var favs = (UserDefaults.standard.stringArray(forKey: "chappy_food_favs") ?? [])
        .joined(separator: ", ")
    @State private var status = ""

    var body: some View {
        Form {
            Section("Ride service") {
                Picker("Provider", selection: $provider) {
                    Text("Auto (Uber here, Grab overseas)").tag("auto")
                    Text("Grab").tag("grab")
                    Text("Uber").tag("uber")
                    Text("Gojek").tag("gojek")
                }
                .pickerStyle(.menu)
            }
            Section("Fare estimate (leave 0 for sensible defaults)") {
                HStack { Text("Base fare"); Spacer()
                    TextField("0", value: $base, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100) }
                HStack { Text("Per km"); Spacer()
                    TextField("0", value: $perKm, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100) }
                HStack { Text("Per minute"); Spacer()
                    TextField("0", value: $perMin, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100) }
            }
            Section("Favourite eats (comma separated)") {
                TextField("Mama's Warung, Betty's Burgers", text: $favs)
            }
            Section {
                Button("Save") {
                    let d = UserDefaults.standard
                    if provider == "auto" { d.removeObject(forKey: "chappy_ride_provider") }
                    else { d.set(provider, forKey: "chappy_ride_provider") }
                    d.set(base, forKey: "chappy_ride_base")
                    d.set(perKm, forKey: "chappy_ride_perkm")
                    d.set(perMin, forKey: "chappy_ride_permin")
                    ChappyRide.shared.favourites = favs.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    status = "Saved. Say: get me a \(ChappyRide.shared.provider.display) to the airport."
                }
                if !status.isEmpty { Text(status).font(.footnote).foregroundColor(.secondary) }
            } footer: {
                Text("Defaults: UberX Brisbane rates in dollars on Australian time, GrabCar Bali rates in rupiah anywhere else. Fares are spoken as a band — booking and payment always happen inside the provider's own app, where your card stays.")
            }
        }
        .navigationTitle("Rides & Food")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// =====================================================================
// BUILD 177 — TRAVEL DESK KEYS.
//
// Worth being straight about why there is only ONE field here.
//
// Airbnb closed its public API in 2019 — partner only. Booking.com,
// Agoda, Trip.com, Klook and Traveloka all gate theirs behind an
// approved commercial agreement with traffic requirements. Facebook
// Marketplace has never had an API at all. Kiwi moved Tequila to partner
// approval. Amadeus decommissioned self-service outright in July 2026.
//
// Tripadvisor's Content API is the single open door: 5,000 calls a month
// free, self-signup in about five minutes, no company and no partnership.
// It gives real places with real ratings and review counts.
//
// And the Travel Desk works fully WITHOUT it — Apple Maps supplies the
// places, you just don't get the ratings. This is an upgrade, not a
// requirement.
// =====================================================================

struct TravelKeysView: View {
    @State private var key = UserDefaults.standard.string(forKey: "chappy_tripadvisor_key") ?? ""
    @State private var status = ""
    @State private var gkey = APIKeyManager.shared.getMapsAPIKey() ?? ""
    @State private var gstatus = ""
    @ObservedObject private var fx = ChappyFX.shared
    @ObservedObject private var gplaces = ChappyGooglePlaces.shared
    @ObservedObject private var profile = ChappyProfile.shared

    private var profileSummary: String {
        let d = profile.data
        if d.isEmpty { return "Not set up yet — worth two minutes" }
        var bits: [String] = []
        if !d.name.isEmpty { bits.append(d.name) }
        if !d.homeCity.isEmpty { bits.append("from \(d.homeCity)") }
        if let days = profile.passportDaysRemaining(on: Date()) {
            // AUDIT: a lapsed passport returns a NEGATIVE number, which
            // fell into "expiring soon". It has expired. Say that.
            if days < 0 { bits.append("PASSPORT EXPIRED") }
            else if days < 183 { bits.append("passport expiring soon") }
            else { bits.append("passport on file") }
        } else {
            bits.append("no passport expiry")
        }
        return bits.joined(separator: " · ")
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    TravellerProfileView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.text.rectangle.fill")
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Who's travelling").fontWeight(.medium)
                            Text(profileSummary).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Passport expiry, who you fly with, who's coming. Chappy plans for this person rather than a generic Australian — and it checks the six-month passport rule on every trip, which is what actually stops people at the check-in desk.")
            }

            // BUILD 221 — THE SWITCH THIS FEATURE NEVER HAD.
            //
            // Proximity recall — walk past somewhere and Chappy quietly
            // says what happened there — is the best thing in the whole
            // location layer, and it shipped OFF with no control
            // anywhere. The only way to turn it on was to say a phrase
            // nobody would ever guess. A feature with no discoverable
            // switch is a feature nobody has.
            Section {
                Toggle("Remind me where I am", isOn: Binding(
                    get: { ChappyRelevance.shared.isEnabled },
                    set: { ChappyRelevance.shared.isEnabled = $0 }
                ))
                if ChappyRelevance.shared.isEnabled {
                    Text(ChappyRelevance.shared.lastRemark.isEmpty
                         ? "Nothing said yet today."
                         : "Last: \(ChappyRelevance.shared.lastRemark)")
                        .font(.footnote).foregroundColor(.secondary)
                }
            } header: {
                Text("Place memories")
            } footer: {
                Text("When you come back to somewhere you've been, Chappy mentions what happened there — quietly, at most three times a day, never within 45 minutes of the last one, and never between 10pm and 7am. Memories older than four months are archaeology and stay quiet. All of it is worked out on the phone; nothing about where you are is uploaded to say it.")
            }

            Section {
                Picker("Everything is priced in", selection: Binding(
                    get: { fx.home },
                    set: { fx.home = $0 }
                )) {
                    ForEach(ChappyFX.common, id: \.self) { c in
                        Text("\(c) — \(ChappyFX.names[c] ?? c)").tag(c)
                    }
                }
            } header: {
                Text("Home currency")
            } footer: {
                Text("Trip totals, the converter and every report land in this currency. You can still price an individual hotel in rupiah or baht — Chappy converts it.")
            }

            Section {
                ChappyKeyField(title: "Paste the Tripadvisor key", text: $key) {
                    let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    key = k
                    UserDefaults.standard.set(k, forKey: "chappy_tripadvisor_key")
                    status = k.isEmpty
                        ? "Cleared. Places now come from Apple Maps."
                        : "Saved \(k.count) characters. Open a leg and tap Eat & see."
                }
                if !status.isEmpty {
                    Text(status).font(.footnote).foregroundColor(.secondary)
                }
            } header: {
                Text("Tripadvisor content key")
            } footer: {
                Text("Free at tripadvisor.com/developers — sign up, create a key, paste it here. 5,000 calls a month, which is far more than a person can use. A card is required for overage but you will not reach it. WITHOUT this the Travel Desk still works: places come from Apple Maps, you just don't get star ratings and review counts.")
            }

            // BUILD 183 — THE SECOND OPINION.
            Section {
                ChappyKeyField(title: "Google Maps API key", text: $gkey) {
                    let k = gkey.trimmingCharacters(in: .whitespacesAndNewlines)
                    gkey = k
                    if k.isEmpty {
                        _ = APIKeyManager.shared.deleteMapsAPIKey()
                        // AUDIT: seedDefaultKeys() puts the built-in key back
                        // on the next cold launch whenever the slot is empty,
                        // so "Cleared" lasted until you closed the app and
                        // the lookups quietly resumed on someone else's bill.
                        UserDefaults.standard.set(true, forKey: "chappy_maps_key_cleared")
                        gstatus = "Cleared. Places show Tripadvisor ratings only."
                    } else {
                        UserDefaults.standard.set(false, forKey: "chappy_maps_key_cleared")
                        gstatus = APIKeyManager.shared.saveMapsAPIKey(k)
                            ? "Saved. Open a leg and tap Eat & see — you'll get both numbers."
                            : "Couldn't save that to the keychain."
                    }
                    ChappyGooglePlaces.shared.refreshConfigured()
                }
                if !gstatus.isEmpty {
                    Text(gstatus).font(.footnote).foregroundColor(.secondary)
                }
                if let ge = gplaces.error, !ge.isEmpty {
                    Text(ge).font(.footnote).foregroundColor(.orange)
                }
                if gplaces.isConfigured {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: gplaces.fraction)
                            .tint(gplaces.fraction > 0.85 ? .orange : .accentColor)
                        Text(gplaces.meterLine)
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Google ratings")
            } footer: {
                Text("Optional, and it changes what the places list is worth. Google covers the gym, the ice bath, the dive shop and the warung down the lane — none of which Tripadvisor has heard of — and rates them by who actually goes. Where the two disagree by more than half a star, Chappy says so: higher on Google means locals love it and travellers don't, and the reverse is a tourist trap. Console.cloud.google.com, enable Places API (New), 5,000 free lookups a month.\n\nGoogle ratings appear in the APP only, never in the emailed report. Their licence permits storing exactly one thing — the place ID — and a saved document is storage. The report carries Tripadvisor, which does permit it. That split is deliberate.")
            }

            Section("What Chappy can and can't do") {
                Text("Chappy plans, prices, maps and hands off. It cannot book, and neither can any solo developer: Airbnb has had no public API since 2019, and Booking, Agoda, Trip.com, Klook and Traveloka all require an approved commercial agreement. Every booking link in the app carries your dates and party size through to the site, where the real prices are.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Travel Desk")
        .navigationBarTitleDisplayMode(.inline)
    }
}


// =====================================================================
// BUILD 180 — MUSIC & OTHER AUDIO.
//
// The wake word runs on the PHONE, with a live microphone, so that it
// works with the phone in your pocket and no glasses on. That is the
// feature — and it is also why Chappy has an active audio session while
// it is open, which is something "Hey Meta" does not, because that one
// runs on the glasses' own chip.
//
// An active session is not the problem. Asking iOS to hold every other
// app down for the whole time it is active was. This screen is where
// that choice lives.
// =====================================================================

struct AudioPolicyView: View {
    @State private var policy = ChappyAudio.policy

    var body: some View {
        Form {
            Section {
                Picker("Your music", selection: $policy) {
                    Text("Dips only while Chappy talks").tag("speaking")
                    Text("Never touch it").tag("never")
                    Text("Stays down the whole time").tag("always")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: policy) { _, new in
                    ChappyAudio.policy = new
                    // Take effect now, not at the next spoken line.
                    ChappyAudio.apply(.listening)
                }
            } header: {
                Text("While Chappy is open")
            } footer: {
                Text(footerText)
            }

            Section("Why this exists") {
                Text("Chappy's wake word listens on the phone, so it has a live audio session open the whole time the app is running. Until build 180 that session asked iOS to hold every other app's audio down for its entire life, which is why Apple Music went quiet the moment you opened Chappy and came back the moment you closed it.\n\n\u{201C}Hey Meta\u{201D} does not do this because it is not listening on your phone at all \u{2014} it runs on the glasses\u{2019} own always-on chip, and the Meta app only opens a session when you actually invoke it. The trade is that its wake word needs the glasses on your face; Chappy\u{2019}s works from your pocket.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Music & audio")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footerText: String {
        switch policy {
        case "never":
            return "Chappy talks over the top of your music at full volume. Worth knowing: with music coming out of the phone\u{2019}s own speaker, the microphone can hear it, and now and then a lyric sounds enough like the name to wake him. On headphones or through the glasses that can\u{2019}t happen."
        case "always":
            return "The old behaviour. Everything else stays quiet for as long as Chappy is open."
        default:
            return "Recommended. Your music plays at full volume while Chappy listens, dips for the second or two he is speaking, and comes straight back. Live AI and Translate still take the audio properly while a conversation is running \u{2014} that is deliberate."
        }
    }
}


// =====================================================================
// BUILD 184 — THE TRAVELLER SCREEN.
//
// One screen, filled in once, that changes every answer Chappy gives
// afterwards. The passport expiry field at the top is not a preference
// and is not optional in spirit: it is the single most common reason
// an Australian is turned away, and it is turned away at check-in by
// the airline rather than at the border by an official, which is why
// nobody sees it coming.
//
// Deliberately absent: passport NUMBER. Storing one in an app's
// defaults is a liability with no upside — the expiry date is what the
// arithmetic needs and all of what it needs.
// =====================================================================

struct TravellerProfileView: View {
    @ObservedObject private var store = ChappyProfile.shared
    @State private var hasExpiry = false
    /// AUDIT: without this, tapping "I know my expiry date" wrote TODAY
    /// as the expiry before the date picker had even drawn — and today
    /// is inside six months of today, so every trip from then on carried
    /// a red "passport expires in 0 days". Persisted, too.
    @State private var expiryTouched = false
    @State private var expiry = Date()
    @State private var airlineText = ""
    @State private var loyaltyText = ""
    @State private var cardText = ""
    @State private var chainText = ""
    @State private var hotelText = ""
    @State private var interestText = ""
    @State private var visitedText = ""

    private let styles = ["Budget", "Mid-range", "Comfortable", "Luxury"]
    private let cabins = ["Economy", "Premium economy", "Business", "First"]

    /// Split into computed sections deliberately. As one expression this
    /// was a Form with six sections, twenty-two rows and fifteen generic
    /// key-path calls solved as a single constraint system — the exact
    /// shape that produces "unable to type-check in reasonable time" with
    /// no useful diagnostic, on a machine he is renting by the hour.
    var body: some View {
        Form {
            youSection
            passportSection
            partySection
            flyingSection
            stayingSection
            tripSection
        }
        .navigationTitle("Who's travelling")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: hasExpiry) { _ in commitExpiry() }
        .onChange(of: expiry) { _ in expiryTouched = true; commitExpiry() }
    }

    @ViewBuilder private var youSection: some View {
        Group {
            Section {
                TextField("Name", text: binding(\.name))
                TextField("Home city", text: binding(\.homeCity))
                TextField("Home airport code (optional, e.g. BNE)", text: binding(\.homeAirport))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("Passport nationality", text: binding(\.nationality))
                TextField("Second passport, if you have one", text: binding(\.secondPassport))
            } header: {
                Text("You")
            } footer: {
                Text("A second passport is worth entering even if you never use it — it often gives a longer stay or a cheaper visa than the one you'd reach for.")
            }

        }
    }

    @ViewBuilder private var passportSection: some View {
        Group {
            Section {
                Toggle("I know my expiry date", isOn: $hasExpiry)
                if hasExpiry {
                    DatePicker("Expires", selection: $expiry, displayedComponents: .date)
                    if !expiryTouched {
                        Text("Set the date above — nothing is saved until you do.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                if let v = verdict {
                    Label(v.headline, systemImage: v.level == "LOW" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundColor(v.level == "HIGH" ? .red : (v.level == "MEDIUM" ? .orange : .green))
                }
            } header: {
                Text("Passport expiry")
            } footer: {
                Text("Most of Asia wants six months' validity from the day you ARRIVE, and the airline enforces it at check-in because they're liable for carrying you. Chappy checks every trip against the date you'd land, not today.")
            }

        }
    }

    @ViewBuilder private var partySection: some View {
        Group {
            Section {
                Stepper("Adults: \(store.data.adults)", value: binding(\.adults), in: 1...9)
                Stepper("Children: \(store.data.children)", value: binding(\.children), in: 0...9)
                Stepper("Infants: \(store.data.infants)", value: binding(\.infants), in: 0...4)
                Toggle("Travelling with a pet", isOn: binding(\.travellingWithPet))
                TextField("Accessibility requirements", text: binding(\.accessibility), axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text("Who's coming")
            } footer: {
                Text("Accessibility is treated as a requirement, not a preference — it's checked against every stay, transfer and activity Chappy suggests.")
            }

        }
    }

    @ViewBuilder private var flyingSection: some View {
        Group {
            Section {
                Picker("Usual cabin", selection: binding(\.cabinPreference)) {
                    ForEach(cabins, id: \.self) { Text($0).tag($0) }
                }
                TextField("Seat preference", text: binding(\.seatPreference))
                TextField("Meal preference", text: binding(\.mealPreference))
                listField("Preferred airlines", $airlineText, \.preferredAirlines,
                          "Qantas, Singapore Airlines")
                listField("Frequent flyer & status", $loyaltyText, \.frequentFlyer,
                          "Qantas Frequent Flyer — Gold")
            } header: {
                Text("How you fly")
            } footer: {
                Text("Status changes the maths. A fare that keeps you Gold can be worth paying more for, and Chappy will say so rather than just showing you the cheapest number.")
            }

        }
    }

    @ViewBuilder private var stayingSection: some View {
        Group {
            Section {
                listField("Preferred hotel chains", $chainText, \.preferredChains, "Accor, Marriott")
                listField("Hotel loyalty & status", $hotelText, \.hotelLoyalty,
                          "Accor Plus, Marriott Titanium")
                listField("Card travel benefits", $cardText, \.cardBenefits,
                          "Amex Platinum — lounge, travel insurance, rental excess")
            } header: {
                Text("Where you stay, what you carry")
            } footer: {
                Text("Card benefits matter because they stop you buying things twice. If your card already covers travel insurance and rental excess, Chappy shouldn't be recommending you buy them.")
            }

        }
    }

    @ViewBuilder private var tripSection: some View {
        Group {
            Section {
                Picker("Style", selection: binding(\.styleLevel)) {
                    ForEach(styles, id: \.self) { Text($0).tag($0) }
                }
                Toggle("I work while travelling", isOn: binding(\.needsInternetForWork))
                TextField("Dietary", text: binding(\.dietary))
                listField("Interests", $interestText, \.interests,
                          "diving, food, hiking, recovery")
                listField("Already been to", $visitedText, \.visited, "Bali, Thailand, Japan")
            } header: {
                Text("What kind of trip")
            } footer: {
                Text("\"Already been to\" stops Chappy selling you places you know as if they were discoveries — it goes deeper or goes elsewhere instead.")
            }
        }
    }

    private var verdict: ChappyProfile.PassportVerdict? {
        store.passportCheck(entering: Date())
    }

    private func load() {
        if let e = store.data.passportExpiry {
            expiry = e
            hasExpiry = true
            expiryTouched = true
        }
        airlineText = store.data.preferredAirlines.joined(separator: ", ")
        loyaltyText = store.data.frequentFlyer.joined(separator: ", ")
        cardText = store.data.cardBenefits.joined(separator: ", ")
        chainText = store.data.preferredChains.joined(separator: ", ")
        hotelText = store.data.hotelLoyalty.joined(separator: ", ")
        interestText = store.data.interests.joined(separator: ", ")
        visitedText = store.data.visited.joined(separator: ", ")
    }

    private func commitExpiry() {
        store.data.passportExpiry = (hasExpiry && expiryTouched) ? expiry : nil
    }

    /// A plain binding into the store, so every edit persists the moment
    /// it happens. No Save button — a settings screen with a Save button
    /// is a settings screen people leave half-filled.
    private func binding<T>(_ path: WritableKeyPath<ChappyProfile.Profile, T>) -> Binding<T> {
        Binding(get: { store.data[keyPath: path] },
                set: { store.data[keyPath: path] = $0 })
    }

    /// Comma-separated text in, array out. Kept as loose text while
    /// you're typing, because splitting on every keystroke eats the
    /// comma you just pressed.
    private func listField(_ title: String, _ text: Binding<String>,
                           _ path: WritableKeyPath<ChappyProfile.Profile, [String]>,
                           _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField(hint, text: text, axis: .vertical)
                .lineLimit(1...3)
                .onChange(of: text.wrappedValue) { new in
                    store.data[keyPath: path] = new
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
        }
    }
}
