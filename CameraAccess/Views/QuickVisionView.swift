/*
 * Quick Vision View
 * Quick Vision screen — one-tap capture & recognize
 */

import SwiftUI

struct QuickVisionView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @StateObject private var quickVisionManager = QuickVisionManager.shared
    @StateObject private var tts = TTSService.shared
    let apiKey: String

    @Environment(\.dismiss) private var dismiss
    @State private var showSiriTip = false

    // Computed properties for button state
    private var buttonDisabled: Bool {
        quickVisionManager.isProcessing || !streamViewModel.hasActiveDevice
    }

    private var buttonText: String {
        if quickVisionManager.isProcessing {
            return "quickvision.processing".localized
        } else if !streamViewModel.hasActiveDevice {
            return "quickvision.glasses.notconnected".localized
        } else {
            return "quickvision.start".localized
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Background
                Color.black.ignoresSafeArea()

                VStack(spacing: AppSpacing.xl) {
                    // Video preview area
                    videoPreviewSection

                    // Status and result
                    statusSection

                    // Action buttons
                    actionButtons

                    Spacer()

                    // Siri Tips
                    siriTipSection
                }
                .padding()
            }
            .navigationTitle("quickvision.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("close".localized) {
                        Task {
                            tts.stop() // Stop speaking
                            await quickVisionManager.stopStream() // Stop the video stream
                        }
                        dismiss()
                    }
                    .foregroundColor(.white)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSiriTip.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.white)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task {
            // Ensure streamViewModel is set
            quickVisionManager.setStreamViewModel(streamViewModel)

            // Wait for the device (max 2 s)
            var deviceWait = 0
            while !streamViewModel.hasActiveDevice && deviceWait < 20 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                deviceWait += 1
            }

            guard streamViewModel.hasActiveDevice else {
                print("❌ [QuickVisionView] No device connected")
                return
            }

            // Auto-run Quick Vision (start stream, capture, stop stream, recognize, speak)
            await quickVisionManager.performQuickVision()
        }
    }

    // MARK: - Video Preview Section

    private var videoPreviewSection: some View {
        ZStack {
            // Prefer the photo saved by QuickVisionManager (survives stream stop)
            // then the streamViewModel photo, finally the live video stream
            if let photo = quickVisionManager.lastImage {
                // Show the photo saved by QuickVisionManager
                Image(uiImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(AppCornerRadius.lg)
            } else if let photo = streamViewModel.capturedPhoto {
                // Show the streamViewModel photo
                Image(uiImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(AppCornerRadius.lg)
            } else if let frame = streamViewModel.currentVideoFrame {
                // Show the video stream
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(AppCornerRadius.lg)
            } else {
                RoundedRectangle(cornerRadius: AppCornerRadius.lg)
                    .fill(Color.gray.opacity(0.3))
                    .overlay {
                        if !streamViewModel.hasActiveDevice {
                            // Device not connected
                            VStack(spacing: AppSpacing.md) {
                                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                    .font(.system(size: 50))
                                    .foregroundColor(.orange)
                                Text("quickvision.glasses.notconnected".localized)
                                    .font(AppTypography.headline)
                                    .foregroundColor(.white)
                                Text("quickvision.error.nodevice".localized)
                                    .font(AppTypography.caption)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        } else if streamViewModel.streamingStatus == .waiting || quickVisionManager.isProcessing {
                            VStack(spacing: AppSpacing.md) {
                                ProgressView()
                                    .scaleEffect(1.5)
                                    .tint(.white)
                                Text(quickVisionManager.isProcessing ? "quickvision.recognizing".localized : "stream.connecting".localized)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        } else {
                            VStack(spacing: AppSpacing.md) {
                                Image(systemName: "eye.circle.fill")
                                    .font(.system(size: 50))
                                    .foregroundColor(.purple.opacity(0.7))
                                Text("quickvision.start".localized)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                    }
            }

            // Processing overlay (only when an image is shown)
            if quickVisionManager.isProcessing && (quickVisionManager.lastImage != nil || streamViewModel.capturedPhoto != nil || streamViewModel.currentVideoFrame != nil) {
                RoundedRectangle(cornerRadius: AppCornerRadius.lg)
                    .fill(Color.black.opacity(0.6))
                    .overlay {
                        VStack(spacing: AppSpacing.md) {
                            ProgressView()
                                .scaleEffect(2)
                                .tint(.white)
                            Text("vision.analyzing".localized)
                                .font(AppTypography.headline)
                                .foregroundColor(.white)
                        }
                    }
            }
        }
        .frame(maxHeight: 350)
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(spacing: AppSpacing.md) {
            // Result
            if let result = quickVisionManager.lastResult {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("quickvision.result".localized)
                            .font(AppTypography.headline)
                            .foregroundColor(.white)
                        Spacer()

                        // Replay-speech button
                        Button {
                            tts.speak(result)
                        } label: {
                            Image(systemName: tts.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2")
                                .foregroundColor(.white)
                                .padding(AppSpacing.sm)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(AppCornerRadius.sm)
                        }
                    }

                    Text(result)
                        .font(AppTypography.body)
                        .foregroundColor(.white.opacity(0.9))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(AppCornerRadius.md)
                }
            }

            // Error message
            if let error = quickVisionManager.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(AppTypography.caption)
                        .foregroundColor(.orange)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(AppCornerRadius.md)
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: AppSpacing.md) {
            // Primary button — Quick Vision
            Button {
                quickVisionManager.triggerQuickVision()
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    if quickVisionManager.isProcessing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "eye.fill")
                    }
                    Text(buttonText)
                }
                .font(AppTypography.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.lg)
                .background(
                    LinearGradient(
                        colors: buttonDisabled ? [.gray, .gray.opacity(0.7)] : [.purple, .purple.opacity(0.7)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(AppCornerRadius.lg)
            }
            .disabled(buttonDisabled)

            // Stop-speech button
            if tts.isSpeaking {
                Button {
                    tts.stop()
                } label: {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("quickvision.stop.speaking".localized)
                    }
                    .font(AppTypography.subheadline)
                    .foregroundColor(.white)
                    .padding(.vertical, AppSpacing.md)
                    .padding(.horizontal, AppSpacing.xl)
                    .background(Color.red.opacity(0.8))
                    .cornerRadius(AppCornerRadius.md)
                }
            }
        }
    }

    // MARK: - Siri Tip Section

    private var siriTipSection: some View {
        VStack(spacing: AppSpacing.sm) {
            if showSiriTip {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("quickvision.siri.tip.title".localized)
                        .font(AppTypography.headline)
                        .foregroundColor(.white)

                    Text("quickvision.siri.tip.description".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.7))

                    VStack(alignment: .leading, spacing: 4) {
                        tipRow("quickvision.siri.tip.voice".localized)
                        tipRow("quickvision.siri.tip.action".localized)
                    }
                }
                .padding()
                .background(Color.white.opacity(0.1))
                .cornerRadius(AppCornerRadius.lg)
            } else {
                Button {
                    showSiriTip = true
                } label: {
                    HStack {
                        Image(systemName: "waveform.circle.fill")
                            .foregroundColor(.purple)
                        Text("quickvision.siri.support".localized)
                            .font(AppTypography.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "chevron.right.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.purple)
            Text(text)
                .font(AppTypography.caption)
                .foregroundColor(.white.opacity(0.8))
        }
    }
}
