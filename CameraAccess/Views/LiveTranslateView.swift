/*
 * Live Translate View
 * Live translation main screen
 *
 * TRANSCRIPT v2 — the screen used to show ONE translation at a time plus a
 * single greyed-out line of history, which meant a ten-minute conversation
 * left you with nothing to look back at. It is now a running two-sided
 * transcript in iPhone-message bubbles: what they said above, what it means
 * below, timestamped, themed, scrolling, and structured so Phase 5's memory
 * store can file every turn verbatim with its language, time and place.
 *
 * ChappyBubble and TranslateTurn are declared here but are plain internal
 * types — Live AI and Quick Vision can use the exact same bubbles without a
 * new file having to be added to the Xcode project.
 */

import SwiftUI
import UIKit

// MARK: - Transcript Model

/// One completed exchange: what was heard, and what it meant.
struct TranslateTurn: Identifiable, Codable, Equatable {
    let id: UUID
    let at: Date
    let original: String
    let translated: String
    /// True when the wearer spoke. Decided by on-device language identification,
    /// falling back to which microphone was live.
    let fromWearer: Bool
    /// What language the speech was actually identified as (nil if too short).
    let detectedLanguage: String?
    let sourceCode: String
    let targetCode: String

    init(id: UUID = UUID(),
         at: Date = Date(),
         original: String,
         translated: String,
         fromWearer: Bool,
         detectedLanguage: String? = nil,
         sourceCode: String,
         targetCode: String) {
        self.id = id
        self.at = at
        self.original = original
        self.translated = translated
        self.fromWearer = fromWearer
        self.detectedLanguage = detectedLanguage
        self.sourceCode = sourceCode
        self.targetCode = targetCode
    }
}

// MARK: - Romanisation

extension String {
    /// True when this contains script an English reader can't sound out —
    /// Chinese, Japanese, Korean, Thai, Khmer, Lao, Arabic, Greek, Cyrillic.
    var needsRomanising: Bool {
        unicodeScalars.contains { s in
            (0x0370...0x03FF).contains(s.value) ||   // Greek
            (0x0400...0x04FF).contains(s.value) ||   // Cyrillic
            (0x0600...0x06FF).contains(s.value) ||   // Arabic
            (0x0E00...0x0E7F).contains(s.value) ||   // Thai
            (0x0E80...0x0EFF).contains(s.value) ||   // Lao
            (0x1780...0x17FF).contains(s.value) ||   // Khmer
            (0x3040...0x30FF).contains(s.value) ||   // Kana
            (0x4E00...0x9FFF).contains(s.value) ||   // Han
            (0xAC00...0xD7AF).contains(s.value)      // Hangul
        }
    }

    /// Sound it out. Apple ships this transliteration on-device, so it costs
    /// nothing, works with no signal, and gives you pinyin for Chinese, romaji
    /// for Japanese and readable Thai — the difference between a wall of
    /// characters and something you can actually attempt out loud.
    var romanised: String? {
        guard needsRomanising else { return nil }
        let m = NSMutableString(string: self) as CFMutableString
        guard CFStringTransform(m, nil, kCFStringTransformToLatin, false) else { return nil }
        let out = (m as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return (out.isEmpty || out == self) ? nil : out
    }
}

// MARK: - Shared Bubble

/// One message bubble, themed. `mine` puts it on the right in the accent
/// colour; otherwise it sits left in the card fill — the arrangement every
/// phone owner already knows how to read without being taught.
struct ChappyBubble: View {
    let primary: String
    let secondary: String?
    let at: Date?
    let mine: Bool
    let theme: ChappyTheme
    var live: Bool = false
    /// Language of the foreign side, for spotting a price.
    var foreignCode: String = "id"
    /// Fill the screen with this line so someone can read it across a counter.
    var onShowBig: ((String) -> Void)? = nil
    /// Keep this line for next time.
    var onSave: (() -> Void)? = nil
    /// Hand this line to Messenger, Mail, Telegram — anything installed.
    var onShare: ((String) -> Void)? = nil
    /// Pronunciation line on or off, remembered across sessions.
    @AppStorage("translate_show_pronunciation") private var showPronunciation = true

    /// Formatted amount plus the dollar equivalent, when this line is money.
    private var priceChip: (String, String?)? {
        let source = [secondary, primary].compactMap { $0 }.joined(separator: " ")
        guard let hit = PriceSpotter.find(in: source, languageCode: foreignCode) else { return nil }
        let money = "\(PriceSpotter.formatted(hit.amount)) \(hit.code)"
        return (money, CurrencyRates.shared.inAUD(hit.amount, currency: hit.code))
    }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 44) }

            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                // WHO — the thing that was missing. Without it you can't tell
                // your own sentence from theirs at a glance, and a bubble on
                // the wrong side reads as the app inventing things.
                HStack(spacing: 6) {
                    Text(mine ? "YOU" : "THEM")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.8)
                        .foregroundColor(mine ? theme.accent : theme.textSecondary)
                    if let at {
                        Text(at.formatted(date: .omitted, time: .shortened))
                            .font(AppTypography.caption)
                            .foregroundColor(theme.textSecondary.opacity(0.7))
                    }

                    // REPEAT (BUILD 54): the WHOLE bubble is the button — a
                    // speaker glyph this size is a miserable target one-handed
                    // in a market. This icon is only the hint that it's tappable.
                    // AUDIT FIX (UI-C1): this row had two 20-point buttons sitting
                    // inside a bubble that is itself a tap target. Three
                    // overlapping targets, all under Apple's 44-point minimum,
                    // on a phone held one-handed in a market — you'd hit the
                    // wrong one constantly. Everything except replay now lives
                    // in a press-and-hold menu, where the rows are full width.
                    if !live {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.accent.opacity(0.75))
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12))
                            .foregroundColor(theme.textSecondary.opacity(0.6))
                    }
                }

                // WHAT WAS SAID, in the speaker's own language — full size now,
                // not a grey whisper. When it's your turn this is your English,
                // so you can check Chappy heard you correctly.
                if let secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(AppTypography.body)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(mine ? .trailing : .leading)
                    if showPronunciation, let roman = secondary.romanised {
                        Text(roman)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .italic()
                            .foregroundColor(theme.textSecondary.opacity(0.8))
                            .multilineTextAlignment(mine ? .trailing : .leading)
                    }
                }

                // WHAT WAS SPOKEN ALOUD — the translation, emphasised.
                Text(primary)
                    .font(AppTypography.body)
                    .fontWeight(.semibold)
                    .foregroundColor(theme.textPrimary)
                    .multilineTextAlignment(mine ? .trailing : .leading)

                // SOUND IT OUT: pinyin, romaji, readable Thai. On your own
                // bubble this is the line you try to say yourself.
                if showPronunciation, let roman = primary.romanised {
                    Text(roman)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .italic()
                        .foregroundColor(theme.textPrimary.opacity(0.72))
                        .multilineTextAlignment(mine ? .trailing : .leading)
                }

                // THE PRICE, big and in dollars. Haggling is mostly numbers and
                // a spoken Indonesian sum is a long string of words — this is
                // the line you'll actually look at.
                if !live, let price = priceChip {
                    HStack(spacing: 7) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 11))
                        Text(price.0)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        if let aud = price.1 {
                            Text(aud)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(theme.accent)
                        }
                    }
                    .foregroundColor(theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.cardActive))
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(mine ? theme.accent.opacity(0.22) : theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(mine ? theme.accent.opacity(0.45) : theme.stroke, lineWidth: 1)
            )
            .opacity(live ? 0.72 : 1.0)
            .frame(maxWidth: 320, alignment: mine ? .trailing : .leading)
            // TAP ANYWHERE ON THE BUBBLE to hear the translation again; press
            // and hold for the original. contentShape makes the padding count,
            // so the target is the whole card, not just the glyphs.
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                guard !live, !primary.isEmpty, primary != "…" else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                TTSService.shared.speak(primary)
            }
            // AUDIT FIX (UI-C1): everything else on one press-and-hold. Standard
            // iOS, full-width rows, impossible to mis-tap — and it gives Copy
            // back, which the earlier gesture juggling had taken away.
            .contextMenu {
                if !live {
                    Button {
                        TTSService.shared.speak(primary)
                    } label: { Label("Say it again", systemImage: "speaker.wave.2.fill") }

                    if let secondary, !secondary.isEmpty {
                        Button {
                            TTSService.shared.speak(secondary)
                        } label: { Label("Say the original", systemImage: "quote.bubble") }
                    }

                    Button {
                        onShowBig?(primary)
                    } label: { Label("Show them (big text)", systemImage: "arrow.up.left.and.arrow.down.right") }

                    Button {
                        onSave?()
                    } label: { Label("Save as a phrase", systemImage: "bookmark") }

                    Button {
                        UIPasteboard.general.string = [secondary, primary]
                            .compactMap { $0 }.joined(separator: "\n")
                    } label: { Label("Copy", systemImage: "doc.on.doc") }

                    // SEND IT (BUILD 56): dictate in English, send in their
                    // language. The text is real Unicode, so characters arrive
                    // intact rather than as little boxes.
                    Button {
                        QuickShare.whatsApp(primary)
                    } label: { Label("Send on WhatsApp", systemImage: "paperplane.fill") }

                    Button {
                        onShare?(primary)
                    } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                }
            }

            if !mine { Spacer(minLength: 44) }
        }
    }
}

// MARK: - Main View

struct LiveTranslateView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = LiveTranslateViewModel()
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @State private var showSettings = false
    @State private var showLabelSheet = false
    @State private var bigText: String?
    @State private var showPhrases = false
    @State private var confirmClear = false
    @State private var shareText: String?
    @AppStorage("translate_show_pronunciation") private var showPronunciation = true
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    var body: some View {
        ZStack {
            // Background — themed, so Translate stops being the one black
            // screen in an app where everything else follows your colours.
            LinearGradient(colors: [theme.bgTop, theme.bgBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // Video preview (if image input is enabled)
            if viewModel.imageEnhanceEnabled {
                videoBackground
            }

            VStack(spacing: 0) {
                headerView
                sessionHeader
                languageBar
                defaultPairRow
                transcriptArea
                controlBar
            }
            .padding()
        }
        .onAppear {
            viewModel.connect()
            if viewModel.imageEnhanceEnabled {
                startVideoStream()
            }
        }
        .onDisappear {
            viewModel.disconnect()
            stopVideoStream()
        }
        .sheet(isPresented: $showSettings) {
            LiveTranslateSettingsView(viewModel: viewModel)
        }
        // SHOW THEM: nothing but the words, as big as the glass allows.
        .fullScreenCover(item: Binding(
            get: { bigText.map { BigLine(text: $0) } },
            set: { bigText = $0?.text }
        )) { line in
            BigTextView(text: line.text, theme: theme) { bigText = nil }
        }
        .sheet(isPresented: $showPhrases) {
            PhraseListView(viewModel: viewModel, theme: theme)
        }
        .sheet(item: Binding(
            get: { shareText.map { BigLine(text: $0) } },
            set: { shareText = $0?.text }
        )) { line in
            ShareSheet(items: [line.text])
        }
        .alert("livetranslate.error.title".localized, isPresented: $viewModel.showError) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.imageEnhanceEnabled) { _, newValue in
            if newValue {
                startVideoStream()
            } else {
                stopVideoStream()
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.title2)
                Text("livetranslate.title".localized)
                    .font(AppTypography.title2)
            }
            .foregroundColor(theme.textPrimary)

            Spacer()

            connectionIndicator

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(theme.textPrimary.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(theme.textPrimary.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
    }

    /// BUILD 56: "Connected" was technically true and practically useless — it
    /// looked identical whether the microphone was open and metering or the
    /// screen was just sitting there. Four honest states instead.
    private var connectionIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColour)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(AppTypography.caption)
                .foregroundColor(theme.textSecondary)
        }
    }

    private var statusText: String {
        if viewModel.isRecording { return "Listening" }
        if viewModel.isAsleep { return "Asleep" }
        if viewModel.isConnected { return "Ready" }
        return "livetranslate.connecting".localized
    }

    private var statusColour: Color {
        if viewModel.isRecording { return .red }
        if viewModel.isAsleep { return .gray }
        if viewModel.isConnected { return .green }
        return .orange
    }

    // MARK: - Session Header

    /// When, where, and with whom — the three things you need six weeks later
    /// to know which conversation you are looking at.
    private var sessionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.caption)
                .foregroundColor(theme.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(sessionTitleLine)
                    .font(AppTypography.caption)
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
                if let place = viewModel.sessionPlace {
                    Text(place)
                        .font(AppTypography.caption)
                        .foregroundColor(theme.textSecondary.opacity(0.75))
                        .lineLimit(1)
                }
            }

            Spacer()

            // POLITE / CASUAL — register matters more than it looks. Also
            // switchable by voice: "Chappy, be polite" / "Chappy, casual".
            Button {
                viewModel.politeMode.toggle()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.politeMode ? "hand.raised.fill" : "hand.wave")
                    Text(viewModel.politeMode ? "Polite" : "Casual")
                }
                .font(AppTypography.caption)
                .foregroundColor(viewModel.politeMode ? theme.accent : theme.textSecondary)
                .frame(minWidth: 66, minHeight: 44)
                .contentShape(Rectangle())
            }

            Button {
                showPhrases = true
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundColor(viewModel.phrases.isEmpty ? theme.textSecondary : theme.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            Button {
                showLabelSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.sessionLabel.isEmpty ? "tag" : "tag.fill")
                    Text(viewModel.sessionLabel.isEmpty ? "Name it" : viewModel.sessionLabel)
                        .lineLimit(1)
                }
                .font(AppTypography.caption)
                .foregroundColor(theme.accent)
                .frame(minWidth: 60, minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardFill))
        .padding(.bottom, 4)
        .alert("Name this conversation", isPresented: $showLabelSheet) {
            TextField("e.g. the landlord", text: $viewModel.sessionLabel)
            Button("Save") {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Makes it findable later.")
        }
    }

    private var sessionTitleLine: String {
        let started = viewModel.sessionStartedAt ?? Date()
        let day = started.formatted(date: .abbreviated, time: .omitted)
        let time = started.formatted(date: .omitted, time: .shortened)
        // AUDIT FIX (UI-H2): the full language names ran off the end and left
        // you reading "Indonesian ↔…" — the half that matters was the half that
        // got cut. Flags plus codes always fit.
        let pair = "\(viewModel.sourceLanguage.flag)\(viewModel.sourceLanguage.rawValue.uppercased()) ↔ \(viewModel.targetLanguage.flag)\(viewModel.targetLanguage.rawValue.uppercased())"
        return "\(day) · \(time) · \(pair)"
    }

    // MARK: - Language Bar

    private var languageBar: some View {
        HStack(spacing: 16) {
            // BUILD 54: "Source" and "Target" told you nothing about which one
            // was yours — which is exactly how they ended up backwards.
            languageButton(
                language: viewModel.sourceLanguage,
                label: "You speak"
            ) {
                showSettings = true
            }

            Button {
                viewModel.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.title3)
                    .foregroundColor(theme.textPrimary)
                    .padding(12)
                    .background(Circle().fill(theme.cardActive))
            }

            languageButton(
                language: viewModel.targetLanguage,
                label: "They speak"
            ) {
                showSettings = true
            }
        }
        .padding(.vertical, 12)
    }

    private func languageButton(language: TranslateLanguage, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(label)
                    .font(AppTypography.caption)
                    .foregroundColor(theme.textSecondary)
                HStack(spacing: 6) {
                    Text(language.flag)
                        .font(.title2)
                    Text(language.displayName)
                        .font(AppTypography.body)
                        .foregroundColor(theme.textPrimary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardFill)
            )
        }
    }

    // MARK: - Your Default Pair (BUILD 54)

    /// Set the languages once and every session opens with them. While no
    /// default is set, Chappy keeps correcting the pair for you; the moment you
    /// set one, it stops guessing entirely and does what you told it.
    private var defaultPairRow: some View {
        HStack(spacing: 10) {
            if viewModel.hasOwnDefault {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(theme.accent)
                Text("Opens with \(viewModel.sourceLanguage.displayName) → \(viewModel.targetLanguage.displayName)")
                    .font(AppTypography.caption)
                    .foregroundColor(theme.textSecondary)
                Spacer()
                Button("Change") {
                    viewModel.clearOwnDefault()
                }
                .font(AppTypography.caption)
                .foregroundColor(theme.accent)
                .frame(minWidth: 64, minHeight: 44)
                .contentShape(Rectangle())
            } else {
                Spacer()
                Button {
                    viewModel.saveCurrentAsDefault()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "pin")
                        Text("Always start with these languages")
                    }
                    .font(AppTypography.caption)
                    .foregroundColor(theme.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Transcript

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.transcript.isEmpty
                        && viewModel.streamingOriginal.isEmpty
                        && viewModel.streamingTranslation.isEmpty {
                        Text("livetranslate.placeholder".localized)
                            .font(AppTypography.body)
                            .foregroundColor(theme.textSecondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 60)
                    }

                    ForEach(viewModel.transcript) { turn in
                        ChappyBubble(primary: turn.translated,
                                     secondary: turn.original,
                                     at: turn.at,
                                     mine: turn.fromWearer,
                                     theme: theme,
                                     // AUDIT FIX (TR-C2): the same mistake as the
                                     // phrase store, and it mattered more here —
                                     // "en" has no currency mapping, so a price
                                     // quoted BY THE VENDOR never showed a chip.
                                     // Those are the prices you actually need.
                                     foreignCode: turn.targetCode,
                                     onShowBig: { bigText = $0 },
                                     onSave: { viewModel.savePhrase(from: turn) },
                                     onShare: { shareText = $0 })
                            .id(turn.id)
                    }

                    // The turn currently in flight — dimmed until it lands.
                    if !viewModel.streamingOriginal.isEmpty || !viewModel.streamingTranslation.isEmpty {
                        ChappyBubble(primary: viewModel.streamingTranslation.isEmpty ? "…" : viewModel.streamingTranslation,
                                     secondary: viewModel.streamingOriginal,
                                     at: nil,
                                     mine: false,
                                     theme: theme,
                                     live: true)
                            .id("live-bubble")
                    }

                    Color.clear.frame(height: 1).id("transcript-bottom")
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
            // Follow the conversation without the user having to chase it.
            .onChange(of: viewModel.transcript.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
            // AUDIT FIX (UI-H1): this also fired on every streaming character,
            // so scrolling back to re-read something yanked you to the bottom
            // mid-sentence and you could never look at an earlier price while
            // the conversation continued. New turns still follow; typing doesn't.
        }
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        VStack(spacing: 14) {
            if viewModel.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("livetranslate.recording".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(theme.textSecondary)
                }
            }

            HStack(spacing: 22) {
                // SPK — output out loud for the table, mic stays where it is.
                Button {
                    viewModel.loudSpeaker.toggle()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: viewModel.loudSpeaker
                              ? "speaker.wave.3.fill" : "speaker.slash.fill")
                            .font(.system(size: 20))
                        Text("SPK")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(0.6)
                    }
                    .foregroundColor(viewModel.loudSpeaker ? .white : theme.textSecondary)
                    .frame(width: 58, height: 58)
                    .background(
                        Circle().fill(viewModel.loudSpeaker ? theme.accent : theme.cardFill)
                    )
                    .overlay(
                        Circle().stroke(viewModel.loudSpeaker ? .clear : theme.stroke, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.toggleRecording()
                } label: {
                    ZStack {
                        Circle()
                            .fill(viewModel.isRecording ? Color.red : theme.accent)
                            .frame(width: 72, height: 72)

                        Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                    }
                }
                // Asleep is a valid state to tap from — it wakes and starts.
                .disabled(!viewModel.isConnected && !viewModel.isAsleep)
                .opacity((viewModel.isConnected || viewModel.isAsleep) ? 1.0 : 0.5)

                // Pronunciation line on/off. Sits where the spacer was, so the
                // record button stays centred.
                Button {
                    showPronunciation.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "character.phonetic")
                            .font(.system(size: 20))
                        Text("SAY")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(0.6)
                    }
                    .foregroundColor(showPronunciation ? .white : theme.textSecondary)
                    .frame(width: 58, height: 58)
                    .background(
                        Circle().fill(showPronunciation ? theme.accent : theme.cardFill)
                    )
                    .overlay(
                        Circle().stroke(showPronunciation ? .clear : theme.stroke, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            // AUDIT FIX (UI-C2): Clear sat directly under the record button and
            // wiped the whole conversation instantly, with no undo. One fumbled
            // tap and an hour with a landlord was gone. It asks now.
            if !viewModel.transcript.isEmpty {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Text("livetranslate.clear".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(theme.textSecondary)
                        .frame(minWidth: 88, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .confirmationDialog("Clear this conversation?",
                                    isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Clear \(viewModel.transcript.count) lines", role: .destructive) {
                        viewModel.clearTranslation()
                    }
                    Button("Keep it", role: .cancel) {}
                } message: {
                    Text("Saved phrases aren't affected.")
                }
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - Video Background

    private var videoBackground: some View {
        Group {
            if let frame = streamViewModel.currentVideoFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .opacity(0.3)
            }
        }
        .onChange(of: streamViewModel.currentVideoFrame) { _, frame in
            if let frame = frame {
                viewModel.updateVideoFrame(frame)
            }
        }
    }

    // MARK: - Video Stream

    private func startVideoStream() {
        Task {
            await streamViewModel.startSession()
        }
    }

    private func stopVideoStream() {
        Task {
            await streamViewModel.stopSession()
        }
    }
}

// Preview requires WearablesInterface - use in app context
// #Preview {
//     LiveTranslateView(streamViewModel: ...)
// }

// MARK: - Price Detection (BUILD 55)

/// Pull a money amount out of a sentence. Deliberately conservative: a wrong
/// price on screen during a negotiation is worse than no price at all.
enum PriceSpotter {

    /// Words that mean "this is money", per language we care about.
    private static let moneyWords: Set<String> = [
        "rupiah", "ribu", "juta", "rp", "idr",
        "baht", "thb", "satang",
        "dong", "vnd", "nghìn", "triệu",
        "peso", "piso", "php",
        "riel", "khr", "kip", "lak",
        "yuan", "rmb", "cny", "kuai", "元", "块",
        "yen", "jpy", "円", "won", "krw", "원",
        "dollar", "dollars", "aud", "usd",
        "price", "cost", "harga", "berapa", "ราคา", "giá"
    ]

    /// Returns the amount and the currency code, or nil.
    static func find(in text: String, languageCode: String) -> (amount: Double, code: String)? {
        let lower = text.lowercased()
        let hasMoneyWord = moneyWords.contains { lower.contains($0) }

        // Grab digit groups, tolerating 250.000 / 250,000 / 250 000
        var best: Double = 0
        var current = ""
        var found: [(Double, Int)] = []          // value, digit count
        func flush() {
            guard !current.isEmpty else { return }
            found.append((Double(current) ?? 0, current.count))
            current = ""
        }
        for ch in lower {
            if ch.isNumber { current.append(ch) }
            else if (ch == "," || ch == "." || ch == " ") && !current.isEmpty { continue }
            else { flush() }
        }
        flush()

        // AUDIT FIX (TR-C3): "here's my WhatsApp, 0812 3456 7890" collapsed into
        // one enormous number and showed up as a price. Phone numbers are handed
        // over constantly in these conversations. Ten digits or more is not money.
        found.removeAll { $0.1 >= 10 }
        best = found.map(\.0).max() ?? 0

        // Spoken multipliers: "250 ribu" is 250,000 and "2 juta" is 2,000,000.
        if lower.contains("ribu") || lower.contains("nghìn") { best *= 1_000 }
        if lower.contains("juta") || lower.contains("triệu") { best *= 1_000_000 }

        guard let code = CurrencyRates.currencyForLanguage[languageCode] else { return nil }

        // AUDIT FIX (TR-C3): a bare number is a time, a quantity, a room number,
        // a date or a phone number far more often than it's money. A wrong price
        // on screen mid-negotiation is worse than no price, so require a word
        // that actually means money — the interpreter is instructed to keep the
        // currency word in, and "harga"/"berapa"/"ribu" carry most of the rest.
        let bigCurrency = ["IDR", "VND", "KRW", "LAK", "KHR"].contains(code)
        let threshold: Double = bigCurrency ? 1_000 : 5
        guard hasMoneyWord, best >= threshold else { return nil }

        return (best, code)
    }

    static func formatted(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: amount)) ?? "\(Int(amount))"
    }
}

// MARK: - Show Them (BUILD 55)

/// Wrapper so a plain String can drive a fullScreenCover(item:).
struct BigLine: Identifiable {
    let text: String
    var id: String { text }
}

/// One line, as large as it will go, on a plain background. For handing the
/// phone across a counter, for a market where nobody can hear, for someone
/// hard of hearing. Screen stays awake while it's up.
struct BigTextView: View {
    let text: String
    let theme: ChappyTheme
    let onClose: () -> Void

    @AppStorage("translate_show_pronunciation") private var showPronunciation = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                Text(text)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.35)
                    .lineLimit(6)
                    .padding(.horizontal, 26)

                if showPronunciation, let roman = text.romanised {
                    Text(roman)
                        .font(.system(size: 22, weight: .regular, design: .rounded))
                        .italic()
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                Spacer()

                HStack(spacing: 26) {
                    Button {
                        TTSService.shared.speak(text)
                    } label: {
                        Label("Say it", systemImage: "speaker.wave.2.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(theme.accent.opacity(0.85)))
                    }

                    Button {
                        QuickShare.whatsApp(text)
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.white.opacity(0.16)))
                    }

                    Button {
                        onClose()
                    } label: {
                        Label("Done", systemImage: "xmark")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.white.opacity(0.16)))
                    }
                }
                .padding(.bottom, 40)
            }
        }
        // Nobody wants the screen dimming while a stranger is still reading it.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

// MARK: - Saved Phrases (BUILD 55)

/// The lines you keep needing. Each one was said in a real conversation, so
/// both languages are already on the phone — these play with no signal.
struct PhraseListView: View {
    @ObservedObject var viewModel: LiveTranslateViewModel
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @State private var bigText: String?
    @State private var shareText: String?

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [theme.bgTop, theme.bgBottom],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                if viewModel.phrases.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "bookmark")
                            .font(.system(size: 42))
                            .foregroundColor(theme.textSecondary.opacity(0.5))
                        Text("No saved phrases yet")
                            .font(AppTypography.body)
                            .foregroundColor(theme.textPrimary)
                        Text("Tap the bookmark on any line in a conversation and it lands here — ready to play with one tap, no signal needed.")
                            .font(AppTypography.caption)
                            .foregroundColor(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(viewModel.phrases) { phrase in
                                phraseRow(phrase)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }
                }
            }
            .navigationTitle("Phrases")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fullScreenCover(item: Binding(
            get: { bigText.map { BigLine(text: $0) } },
            set: { bigText = $0?.text }
        )) { line in
            BigTextView(text: line.text, theme: theme) { bigText = nil }
        }
        .sheet(item: Binding(
            get: { shareText.map { BigLine(text: $0) } },
            set: { shareText = $0?.text }
        )) { line in
            ShareSheet(items: [line.text])
        }
    }

    private func phraseRow(_ phrase: SavedPhrase) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(phrase.english)
                .font(AppTypography.caption)
                .foregroundColor(theme.textSecondary)
            Text(phrase.foreign)
                .font(AppTypography.body)
                .fontWeight(.semibold)
                .foregroundColor(theme.textPrimary)
            if let roman = phrase.foreign.romanised {
                Text(roman)
                    .font(.system(size: 13, design: .rounded))
                    .italic()
                    .foregroundColor(theme.textSecondary.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.cardFill))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            viewModel.speakPhrase(phrase)
        }
        .contextMenu {
            Button {
                bigText = phrase.foreign
            } label: {
                Label("Show them", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button {
                QuickShare.whatsApp(phrase.foreign)
            } label: {
                Label("Send on WhatsApp", systemImage: "paperplane.fill")
            }
            Button {
                shareText = phrase.foreign
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                viewModel.deletePhrase(phrase)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Sharing (BUILD 56)

/// Hand a line to anything on the phone — WhatsApp, Messenger, Messages, Mail,
/// Notes, Telegram. The translated text is real Unicode, so Chinese characters,
/// Thai and Khmer arrive intact rather than as boxes.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

enum QuickShare {
    /// One tap straight into WhatsApp with the message already written — you
    /// only pick the person. wa.me needs no URL scheme permission.
    static func whatsApp(_ text: String) {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://wa.me/?text=\(encoded)") else { return }
        UIApplication.shared.open(url)
    }

    /// Opens the mail composer with the line as the body.
    static func mail(_ text: String) {
        let body = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let subject = "Chappy translation".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "mailto:?subject=\(subject)&body=\(body)") else { return }
        UIApplication.shared.open(url)
    }
}
