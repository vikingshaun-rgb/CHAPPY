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
    /// BUILD 58: a marker row rather than a spoken turn — "Now translating
    /// German". Changing language mid-session is nearly always a new
    /// conversation, but throwing the old one away without asking is rude and
    /// asking every time is worse. A line across the screen says it plainly and
    /// costs nothing.
    let isDivider: Bool
    /// BUILD 98: a photographed menu / sign / brochure, translated. It lives in
    /// the SAME transcript as the speech, because that is where it happened —
    /// scroll back a week later and the menu is sitting next to what you both
    /// said about it. JPEG rather than a file path so it survives in the saved
    /// conversation with no separate asset store.
    let documentJPEG: Data?
    /// BUILD 58: the transcriber came back with a language that is neither
    /// yours nor theirs — so it misheard, and everything downstream of it is
    /// built on a wrong sentence. Better to say so than to show the user a line
    /// of Korean and let them conclude the app is broken.
    let misheard: Bool

    init(id: UUID = UUID(),
         at: Date = Date(),
         original: String,
         translated: String,
         fromWearer: Bool,
         detectedLanguage: String? = nil,
         sourceCode: String,
         targetCode: String,
         isDivider: Bool = false,
         misheard: Bool = false,
         documentJPEG: Data? = nil) {
        self.id = id
        self.at = at
        self.original = original
        self.translated = translated
        self.fromWearer = fromWearer
        self.detectedLanguage = detectedLanguage
        self.sourceCode = sourceCode
        self.targetCode = targetCode
        self.isDivider = isDivider
        self.misheard = misheard
        self.documentJPEG = documentJPEG
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
            (0x0900...0x097F).contains(s.value) ||   // Devanagari (Hindi)
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


/// A photographed menu / sign / label, translated. Deliberately NOT a speech
/// bubble: it isn't something anyone said, and dressing it as one would make
/// the transcript lie about what happened. Wide, bordered, with the photo, so
/// scrolling back a week later it reads as "here is the thing he showed me".
struct DocumentCard: View {
    let jpeg: Data?
    let original: String
    let translated: String
    let at: Date?
    let theme: ChappyTheme
    var onReadAloud: (() -> Void)? = nil
    var onBig: ((String) -> Void)? = nil
    @State private var showOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.accent)
                Text("SCANNED")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.8)
                    .foregroundColor(theme.accent)
                if let at {
                    Text(at.formatted(date: .omitted, time: .shortened))
                        .font(AppTypography.caption)
                        .foregroundColor(theme.textSecondary.opacity(0.7))
                }
                Spacer()
                Button { showOriginal.toggle() } label: {
                    Text(showOriginal ? "English" : "Original")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.accent)
                }
            }

            if let jpeg, let ui = UIImage(data: jpeg) {
                Image(uiImage: ui)
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 130)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Text(showOriginal ? original : translated)
                .font(.system(size: 15))
                .foregroundColor(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 14) {
                Button { onReadAloud?() } label: {
                    Label("Read aloud", systemImage: "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                Button { onBig?(showOriginal ? original : translated) } label: {
                    Label("Show them", systemImage: "textformat.size.larger")
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
            }
            .foregroundColor(theme.accent)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.accent.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Shared Bubble

/// One message bubble, themed. `mine` puts it on the right in the accent
/// colour; otherwise it sits left in the card fill — the arrangement every
/// phone owner already knows how to read without being taught.
struct ChappyBubble: View {
    /// The line in YOUR language — what you said, or what they meant.
    let wearerLine: String
    /// The line in THEIR language — what was spoken aloud, or what they said.
    let foreignLine: String
    let at: Date?
    let mine: Bool
    let theme: ChappyTheme
    var live: Bool = false
    /// Language of the foreign side, for spotting a price.
    var foreignCode: String = "id"
    /// Chappy misheard this one — shown dimmed with a plain warning.
    var misheard: Bool = false
    /// Fill the screen with this line so someone can read it across a counter.
    var onShowBig: ((String) -> Void)? = nil
    /// Keep this line for next time.
    var onSave: (() -> Void)? = nil
    /// Hand this line to Messenger, Mail, Telegram — anything installed.
    var onShare: ((String) -> Void)? = nil
    /// FS-3: every spoken line goes through the view model so "SPEAK off"
    /// genuinely means silent — bubble taps included.
    var onSpeak: ((String) -> Void)? = nil
    /// Pronunciation line on or off, remembered across sessions.
    @AppStorage("translate_show_pronunciation") private var showPronunciation = true

    /// Formatted amount plus the dollar equivalent, when this line is money.
    private var priceChip: (String, String?)? {
        // SB-1: scan ONLY the foreign line. Concatenating both put the model's
        // already-expanded "250,000" next to the transcript's "250 ribu" in one
        // string, and the multiplier was then applied to the expanded number —
        // a thousand times too large, rendered 19pt bold with a dollar figure
        // beside it, on the one line you actually look at mid-haggle.
        guard let hit = PriceSpotter.find(in: foreignLine, languageCode: foreignCode) else { return nil }
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

                // BUILD 57: ENGLISH ALWAYS LEADS. It used to show the ORIGINAL
                // small and the TRANSLATION big, on both sides — which meant
                // your own bubbles led with Indonesian in bold and hid your
                // English in a whisper. Scanning back through a conversation,
                // half of it was in a language you can't read. Every bubble now
                // leads with the line YOU understand; the foreign line sits
                // under it, still there, still tappable, still shareable.
                if misheard {
                    // WATCH-LIST: this is the one message that requires you to
                    // act, and it was 10pt fixed (ignoring Dynamic Type) inside
                    // a bubble knocked to 0.6 opacity. Readable now.
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("MISHEARD — SAY IT AGAIN")
                            .fontWeight(.heavy)
                    }
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .accessibilityLabel("Chappy misheard this. Say it again.")
                }

                Text(wearerLine)
                    .font(AppTypography.body)
                    .fontWeight(.semibold)
                    .foregroundColor(misheard ? theme.textSecondary : theme.textPrimary)
                    .multilineTextAlignment(mine ? .trailing : .leading)

                if !foreignLine.isEmpty {
                    Text(foreignLine)
                        .font(AppTypography.body)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(mine ? .trailing : .leading)

                    if showPronunciation, let roman = foreignLine.romanised {
                        Text(roman)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .italic()
                            .foregroundColor(theme.textSecondary.opacity(0.8))
                            .multilineTextAlignment(mine ? .trailing : .leading)
                    }
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
            .opacity(live ? 0.72 : (misheard ? 0.6 : 1.0))
            .frame(maxWidth: 320, alignment: mine ? .trailing : .leading)
            // TAP ANYWHERE ON THE BUBBLE to hear the translation again; press
            // and hold for the original. contentShape makes the padding count,
            // so the target is the whole card, not just the glyphs.
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                // Tap plays whatever the OTHER party needs to hear: on your
                // bubble that's the foreign line, on theirs it's the English.
                let line = mine ? foreignLine : wearerLine
                guard !live, !line.isEmpty, line != "…" else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onSpeak?(line)
            }
            // AUDIT FIX (UI-C1): everything else on one press-and-hold. Standard
            // iOS, full-width rows, impossible to mis-tap — and it gives Copy
            // back, which the earlier gesture juggling had taken away.
            .contextMenu {
                if !live {
                    Button {
                        onSpeak?(mine ? foreignLine : wearerLine)
                    } label: { Label("Say it again", systemImage: "speaker.wave.2.fill") }

                    Button {
                        onSpeak?(mine ? wearerLine : foreignLine)
                    } label: { Label("Say the other language", systemImage: "quote.bubble") }

                    Button {
                        // Always show them THEIR language — that's the point.
                        onShowBig?(foreignLine.isEmpty ? wearerLine : foreignLine)
                    } label: { Label("Show them (big text)", systemImage: "arrow.up.left.and.arrow.down.right") }

                    Button {
                        onSave?()
                    } label: { Label("Save as a phrase", systemImage: "bookmark") }

                    Button {
                        UIPasteboard.general.string = [wearerLine, foreignLine]
                            .filter { !$0.isEmpty }.joined(separator: "\n")
                    } label: { Label("Copy", systemImage: "doc.on.doc") }

                    // SEND IT (BUILD 56): dictate in English, send in their
                    // language. The text is real Unicode, so characters arrive
                    // intact rather than as little boxes.
                    Button {
                        QuickShare.whatsApp(foreignLine.isEmpty ? wearerLine : foreignLine)
                    } label: { Label("Send on WhatsApp", systemImage: "paperplane.fill") }

                    Button {
                        onShare?(foreignLine.isEmpty ? wearerLine : foreignLine)
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
            // BUILD 58: was .padding() all round, which added 16pt under the
            // record button on top of the home-indicator inset and left the
            // controls floating. Sides and top only — the bar sits low now.
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chappyRetargetTranslate)) { note in
            // "Chappy, switch to Thai" while a session is live — retarget in
            // place rather than tearing down and starting again.
            if let code = note.object as? String,
               let lang = TranslateLanguage(rawValue: code) {
                viewModel.targetLanguage = lang
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chappyWakeCameraForScan)) { _ in
            startVideoStream()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { viewModel.scanDocument() }
        }
        .onAppear {
            ChappyStandby.LiveTranslateIsOpen = true
            viewModel.connect()
            if viewModel.imageEnhanceEnabled {
                startVideoStream()
            }
        }
        .onDisappear {
            ChappyStandby.LiveTranslateIsOpen = false
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
            BigTextView(text: line.text, theme: theme,
                        onSpeak: { viewModel.say($0) }) { bigText = nil }
        }
        .sheet(isPresented: $showPhrases) {
            PhraseListView(viewModel: viewModel, theme: theme)
        }
        .sheet(item: Binding(
            get: { shareText.map { BigLine(text: $0) } },
            set: { shareText = $0?.text }
        )) { line in
            ChappyShareSheet(items: [line.text])
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
        // SB-4: this used to say "Listening" into a dead socket while every
        // buffer was silently discarded — and billed. Say what's true.
        if viewModel.lostConnection { return "No connection — tap to retry" }
        if viewModel.isAsleep { return "Asleep" }
        if viewModel.isConnected { return "Ready" }
        return "livetranslate.connecting".localized
    }

    private var statusColour: Color {
        if viewModel.isRecording { return .red }
        if viewModel.lostConnection { return .orange }
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
                    .accessibilityLabel("Swap languages")
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
                        if turn.isDivider {
                            dividerRow(turn)
                        } else if turn.documentJPEG != nil {
                            DocumentCard(jpeg: turn.documentJPEG,
                                         original: turn.original,
                                         translated: turn.translated,
                                         at: turn.at,
                                         theme: theme,
                                         onReadAloud: { viewModel.readLastScan() },
                                         onBig: { bigText = $0 })
                        } else {
                        ChappyBubble(wearerLine: turn.fromWearer ? turn.original : turn.translated,
                                     foreignLine: turn.fromWearer ? turn.translated : turn.original,
                                     at: turn.at,
                                     mine: turn.fromWearer,
                                     theme: theme,
                                     // AUDIT FIX (TR-C2): the same mistake as the
                                     // phrase store, and it mattered more here —
                                     // "en" has no currency mapping, so a price
                                     // quoted BY THE VENDOR never showed a chip.
                                     // Those are the prices you actually need.
                                     foreignCode: turn.targetCode,
                                     misheard: turn.misheard,
                                     onShowBig: { bigText = $0 },
                                     onSave: { viewModel.savePhrase(from: turn) },
                                     onShare: { shareText = $0 },
                                     onSpeak: { viewModel.say($0) })
                            .id(turn.id)
                        }
                    }

                    // The turn currently in flight — dimmed until it lands.
                    if !viewModel.streamingOriginal.isEmpty || !viewModel.streamingTranslation.isEmpty {
                        ChappyBubble(wearerLine: viewModel.streamingTranslation.isEmpty ? "…" : viewModel.streamingTranslation,
                                     foreignLine: viewModel.streamingOriginal,
                                     at: nil,
                                     mine: false,
                                     theme: theme,
                                     live: true)
                            .id("live-bubble")
                    }

                    // BUILD 58: breathing room so the newest bubble never sits
                    // behind the controls — it was half-hidden before.
                    Color.clear.frame(height: 10).id("transcript-bottom")
                }
                .padding(.top, 8)
            }
            .frame(maxHeight: .infinity)
            // Follow the conversation without the user having to chase it.
            .onChange(of: viewModel.transcript.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
            // FS-13: also follow the LIVE bubble while it grows, otherwise the
            // translation of what is being said right now slides below the fold
            // and you have to thumb-scroll one-handed mid-conversation. New
            // turns always follow; streaming follows too.
            .onChange(of: viewModel.streamingTranslation) { _, _ in
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        }
    }

    /// A quiet line across the transcript when the language changes. Nothing is
    /// deleted — the old conversation stays scrollable above it, which matters
    /// if the price you agreed was three turns back. "Start fresh" is there for
    /// when you do want a clean slate.
    private func dividerRow(_ turn: TranslateTurn) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(theme.stroke).frame(height: 1)
            Text(turn.translated)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.textSecondary)
                .lineLimit(1)
            Button("Start fresh") {
                confirmClear = true
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(theme.accent)
            .frame(minHeight: 44)
            Rectangle().fill(theme.stroke).frame(height: 1)
        }
        .padding(.vertical, 2)
        .id(turn.id)
    }

    // MARK: - Control Bar

    /// BUILD 57: three small toggles in a row ABOVE the record button, rather
    /// than crowded either side of it. The old arrangement had no room for a
    /// third control without pushing the record button off-centre, and this is
    /// the row that will keep growing.
    /// BUILD 58: these were 54-point circles in a row of their own, and with the
    /// 72-point record button under them the controls were eating a third of the
    /// screen and hiding the newest bubble behind themselves. One slim capsule
    /// instead — same three controls, same 44-point tap height, a third of the
    /// footprint.
    // MARK: The one output question, with three answers

    /// OFF → GLASSES → PHONE → OFF. One tap, always shows where you are.
    private var hearLabel: String {
        guard viewModel.audioOutputEnabled else { return "HEAR OFF" }
        return viewModel.loudSpeaker ? "HEAR PHONE" : "HEAR GLASSES"
    }
    private var hearIcon: String {
        guard viewModel.audioOutputEnabled else { return "speaker.slash.fill" }
        return viewModel.loudSpeaker ? "speaker.wave.3.fill" : "speaker.wave.1.fill"
    }
    private var hearExplainer: String {
        guard viewModel.audioOutputEnabled else {
            return "Silent — translations appear on screen only. Tap HEAR to turn the voice on."
        }
        return viewModel.loudSpeaker
            ? "Out loud from the iPhone — for putting it on a table between you."
            : "Through your glasses — only you hear it. Tap HEAR for the phone speaker."
    }

    /// Cycling beats two independent toggles here: LOUD was meaningless while
    /// SPEAK was off, which is exactly the kind of dead state that makes people
    /// think a control is broken.
    private func cycleHearMode() {
        if !viewModel.audioOutputEnabled {
            viewModel.audioOutputEnabled = true
            viewModel.loudSpeaker = false          // OFF → GLASSES
        } else if !viewModel.loudSpeaker {
            viewModel.loudSpeaker = true           // GLASSES → PHONE
        } else {
            viewModel.audioOutputEnabled = false   // PHONE → OFF
            viewModel.loudSpeaker = false
        }
    }

    private func toggleSegment(_ label: String,
                               icon: String,
                               on: Bool,
                               dimmed: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.4)
            }
            .foregroundColor(on ? .white : theme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(on ? theme.accent : Color.clear)
            )
            .opacity(dimmed ? 0.4 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
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

            // RELABEL (build 76). The old row read SPEAK · LOUD · SAY, and it
            // was not understandable — the owner's own reading was that SPEAK
            // meant "out of the phone" and SPEAK-off meant "out of the
            // glasses". That is what LOUD did. SPEAK was a mute switch.
            //
            // Two booleans that both sound like they're about the speaker will
            // always be guessed at. They are really ONE question with three
            // answers — where does the sound come out, or does it not come out
            // at all — so they are now one control that cycles and always shows
            // the current answer as a word:
            //
            //     HEAR ▸ OFF        silent, read-only interpreter
            //     HEAR ▸ GLASSES    through the Ray-Bans (private)
            //     HEAR ▸ PHONE      out loud from the iPhone (for a table)
            //
            // And because there is also a MIC control, both are prefixed and
            // carry distinct icons — a speaker for output, a microphone for
            // input — so "GLASSES" can never be ambiguous between them.
            // LAYOUT FIX (build 103). This row was ONE HStack of four segments
            // with .fixedSize() on it. fixedSize tells SwiftUI "give me my ideal
            // width and ignore the parent" — and four segments with full words
            // in them are wider than an iPhone. The row won, the root view grew
            // past the screen, and EVERYTHING got clipped: the close button, the
            // header, and both edges of every message bubble.
            //
            // Two rows of two. The long labels get half a screen each, which is
            // plenty, and nothing has to be abbreviated back into jargon.
            VStack(spacing: 3) {
              HStack(spacing: 3) {
                toggleSegment(hearLabel,
                              icon: hearIcon,
                              on: viewModel.audioOutputEnabled) {
                    cycleHearMode()
                }

                toggleSegment(viewModel.usePhoneMic ? "MIC PHONE" : "MIC GLASSES",
                              icon: "mic.fill",
                              on: viewModel.usePhoneMic) {
                    viewModel.switchMicSource()
                }
              }
              HStack(spacing: 3) {

                // BUILD 158 — SCAN REMOVED. It never worked reliably inside a
                // live conversation (the camera is off, the mic is busy, and
                // the scan fought both), and the Reader on the Home screen
                // does the same job properly with on-device OCR. One good
                // door beats two, one of which sticks.

                // SAY — pronunciation line under non-Latin script.
                toggleSegment("SAY",
                              icon: "character.phonetic",
                              on: showPronunciation) {
                    showPronunciation.toggle()
                }
              }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.cardFill))
            .padding(.horizontal, 12)

            // One quiet line of plain English. The row above is three words of
            // jargon otherwise, and this screen gets used by someone standing
            // in a market trying to buy a boat ticket.
            Text(hearExplainer)
                .font(.system(size: 10))
                .foregroundColor(theme.textSecondary.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.top, 2)

            Button {
                viewModel.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(viewModel.isRecording ? Color.red : theme.accent)
                        .frame(width: 62, height: 62)

                    Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .accessibilityLabel(viewModel.isRecording ? "Stop listening" : "Start listening")
                }
            }
            // Asleep is a valid state to tap from — it wakes and starts.
            .disabled(!viewModel.isConnected && !viewModel.isAsleep && !viewModel.lostConnection)
            .opacity((viewModel.isConnected || viewModel.isAsleep || viewModel.lostConnection) ? 1.0 : 0.5)

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
        .padding(.bottom, 0)
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
            // FS-4: forward nil too — that is how the view model learns the
            // camera has stopped and must stop uploading the last dead frame.
            viewModel.updateVideoFrame(frame)
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
    ///
    /// SB-1: the old version took the LARGEST digit group anywhere in the
    /// sentence and then multiplied it by 1,000 if "ribu" appeared anywhere and
    /// by 1,000,000 if "juta" appeared anywhere — with no link between the word
    /// and the number it modifies, and both multipliers stacking. Verified
    /// results included 250,000,000 IDR for an ordinary "250 ribu" turn, and a
    /// room number winning over the price. This version binds each number to the
    /// word that immediately follows it, sums the parts, and refuses to answer
    /// when two candidates disagree.
    static func find(in text: String, languageCode: String) -> (amount: Double, code: String)? {
        let lower = text.lowercased()
        // CRASH FIX (ordering): the currency lookup used to come FIRST, so every
        // rendered bubble — "hello", "thank you", anything — reached into the
        // currency tables. That is what turned a data bug in one dictionary into
        // a crash on the first sentence of every conversation. Cheapest, most
        // selective test first: no money word, no lookup, no work at all.
        let hasMoneyWord = moneyWords.contains { lower.contains($0) }
        guard hasMoneyWord else { return nil }
        guard let code = CurrencyRates.currency(forLanguage: languageCode) else { return nil }

        // Tokenise on whitespace and punctuation that can't be a separator.
        let raw = lower.split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == "-" })
        var tokens: [String] = []
        for piece in raw { tokens.append(String(piece)) }

        // A number token: digits with optional , or . thousands groups.
        func numberValue(_ tok: String) -> (value: Double, digits: Int)? {
            let stripped = tok.filter { $0.isNumber || $0 == "," || $0 == "." || $0 == ":" }
            guard !stripped.isEmpty, stripped.first?.isNumber == true else { return nil }
            // A time (10:30, 10.30 with exactly two trailing digits) is not money.
            if stripped.contains(":") { return nil }
            let digitsOnly = stripped.filter { $0.isNumber }
            guard digitsOnly.count > 0, digitsOnly.count < 10 else { return nil }
            // Proper thousands grouping: 250.000 / 250,000 / 2.500.000
            let grouped = stripped.split(whereSeparator: { $0 == "," || $0 == "." }).map(String.init)
            if grouped.count > 1, grouped.dropFirst().allSatisfy({ $0.count == 3 }) {
                return (Double(digitsOnly) ?? 0, digitsOnly.count)
            }
            if grouped.count > 1 { return nil }   // 2,5 or 17.08 — ambiguous, refuse
            return (Double(digitsOnly) ?? 0, digitsOnly.count)
        }

        let multipliers: [String: Double] = [
            "ribu": 1_000, "rb": 1_000, "nghìn": 1_000, "nghin": 1_000, "k": 1_000,
            "juta": 1_000_000, "jt": 1_000_000, "triệu": 1_000_000, "trieu": 1_000_000
        ]

        // Build (value x multiplier) pairs, binding each number to the word that
        // FOLLOWS it. Adjacent parts sum: "2 juta 500 ribu" = 2,500,000.
        var candidates: [Double] = []
        var running: Double = 0
        var sawMultiplier = false
        var i = 0
        while i < tokens.count {
            guard let n = numberValue(tokens[i]) else {
                if running > 0 { candidates.append(running); running = 0; sawMultiplier = false }
                i += 1
                continue
            }
            var value = n.value
            // Already expanded (4+ digits): never multiply it again.
            if n.digits < 4, i + 1 < tokens.count,
               let mult = multipliers[tokens[i + 1].filter({ $0.isLetter })] {
                value *= mult
                sawMultiplier = true
                i += 1
            }
            running += value
            i += 1
        }
        if running > 0 { candidates.append(running) }

        let bigCurrency = ["IDR", "VND", "KRW", "LAK", "KHR", "COP", "PYG"].contains(code)
        let floor: Double = bigCurrency ? 1_000 : 5
        let plausible = candidates.filter { $0 >= floor }
        guard let best = plausible.max() else { return nil }

        // Two materially different candidates means we can't tell which is the
        // price. No chip beats a wrong chip — that is this function's own rule.
        if plausible.count > 1, let low = plausible.min(), best > low * 1.5 { return nil }
        // A bare number with no multiplier in a big-denomination currency is
        // more likely a room, a year or a quantity than a price.
        if bigCurrency, !sawMultiplier, best < 10_000 { return nil }

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
    var onSpeak: ((String) -> Void)? = nil
    let onClose: () -> Void

    @AppStorage("translate_show_pronunciation") private var showPronunciation = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                // WATCH-LIST: lineLimit(6) with no scroll silently truncated a
                // long pharmacy explanation with "…", in the hands of a stranger
                // who has no way to scroll it.
                ScrollView {
                    Text(text)
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.4)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 8)
                }

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
                        onSpeak?(text)
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
            BigTextView(text: line.text, theme: theme,
                        onSpeak: { viewModel.say($0) }) { bigText = nil }
        }
        .sheet(item: Binding(
            get: { shareText.map { BigLine(text: $0) } },
            set: { shareText = $0?.text }
        )) { line in
            ChappyShareSheet(items: [line.text])
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
///
/// BUILD 57 FIX: named ChappyShareSheet, not ShareSheet — PhotoPreviewView
/// already declares a ShareSheet(photo:) for sharing images, and two types with
/// the same name in one module is a compile error that also breaks THEIR call
/// sites. The build error blamed their file for a collision I caused.
struct ChappyShareSheet: UIViewControllerRepresentable {
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
