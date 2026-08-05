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

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 44) }

            VStack(alignment: mine ? .trailing : .leading, spacing: 5) {
                // What was actually said, in the speaker's own language.
                if let secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(AppTypography.caption)
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(mine ? .trailing : .leading)
                }

                // What it means — the line you actually read.
                Text(primary)
                    .font(AppTypography.body)
                    .foregroundColor(theme.textPrimary)
                    .multilineTextAlignment(mine ? .trailing : .leading)
                    .textSelection(.enabled)

                if let at {
                    Text(at.formatted(date: .omitted, time: .shortened))
                        .font(AppTypography.caption)
                        .foregroundColor(theme.textSecondary.opacity(0.7))
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
            }
            .padding(.horizontal, 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(theme.textPrimary.opacity(0.8))
            }
        }
        .padding(.vertical, 8)
    }

    private var connectionIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(viewModel.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(viewModel.isConnected ? "livetranslate.connected".localized : "livetranslate.connecting".localized)
                .font(AppTypography.caption)
                .foregroundColor(theme.textSecondary)
        }
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
        let pair = "\(viewModel.sourceLanguage.flag) \(viewModel.sourceLanguage.displayName) ↔ \(viewModel.targetLanguage.flag) \(viewModel.targetLanguage.displayName)"
        return "\(day) · \(time) · \(pair)"
    }

    // MARK: - Language Bar

    private var languageBar: some View {
        HStack(spacing: 16) {
            languageButton(
                language: viewModel.sourceLanguage,
                label: "livetranslate.source".localized
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
                label: "livetranslate.target".localized
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
                                     theme: theme)
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
            .onChange(of: viewModel.streamingTranslation) { _, _ in
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
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
            .disabled(!viewModel.isConnected)
            .opacity(viewModel.isConnected ? 1.0 : 0.5)

            if !viewModel.transcript.isEmpty {
                Button {
                    viewModel.clearTranslation()
                } label: {
                    Text("livetranslate.clear".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(theme.textSecondary)
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
