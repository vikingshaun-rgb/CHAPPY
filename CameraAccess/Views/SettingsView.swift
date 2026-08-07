/*
 * Settings View
 * Profile — device management and settings
 */

import EventKit
import SwiftUI
import MWDATCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var languageManager = LanguageManager.shared
    @ObservedObject var providerManager = APIProviderManager.shared
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
                } header: {
                    Text("Voice")
                } footer: {
                    Text(standbyAutoArm
                         ? "Say “Chappy” then your command. Turning Standby off by hand keeps it off until you next open the app."
                         : "You'll need to tap Standby on the home screen each time before voice commands work.")
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
                    SecureField("settings.apikey.placeholder".localized, text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                    SecureField("settings.apikey.placeholder".localized, text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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

    private let voices: [(name: String, description: String)] = [
        ("Kore", "Warm, friendly female - the Chappy default"),
        ("Aoede", "Bright, upbeat female"),
        ("Leda", "Calm, soothing female"),
        ("Puck", "Energetic male"),
        ("Charon", "Deep, steady male"),
        ("Fenrir", "Strong, confident male"),
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
        }
        .navigationTitle("Voice check")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { rows = ChappyStandby.diagnostics() }
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
