/*
 * Simple Live Stream View
 * Simplified live-stream view for screen-record streaming
 */

import SwiftUI

struct SimpleLiveStreamView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showUI = true // Toggle UI visibility

    var body: some View {
        ZStack {
            // Black background
            Color.black
                .edgesIgnoringSafeArea(.all)

            // Video feed
            if let videoFrame = streamViewModel.currentVideoFrame {
                GeometryReader { geometry in
                    Image(uiImage: videoFrame)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .edgesIgnoringSafeArea(.all)
            } else {
                VStack(spacing: AppSpacing.lg) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .foregroundColor(.white)
                    Text("Connecting to the video stream...")
                        .font(AppTypography.body)
                        .foregroundColor(.white)
                }
            }

            // UI elements — tap the screen to hide
            if showUI {
                VStack {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundColor(.white)
                                .padding()
                        }

                        Spacer()

                        // Status indicator
                        HStack(spacing: AppSpacing.sm) {
                            Circle()
                                .fill(streamViewModel.isStreaming ? Color.red : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(streamViewModel.isStreaming ? "Live" : "Not connected")
                                .font(AppTypography.caption)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.xs)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(AppCornerRadius.lg)
                        .padding(AppSpacing.md)
                    }

                    Spacer()

                    // Instructions
                    VStack(spacing: AppSpacing.md) {
                        Text("Streaming tips")
                            .font(AppTypography.headline)
                            .foregroundColor(.white)

                        Text("1. Open your live-streaming platform")
                            .font(AppTypography.caption)
                            .foregroundColor(.white.opacity(0.8))

                        Text("2. Choose the screen-recording feature")
                            .font(AppTypography.caption)
                            .foregroundColor(.white.opacity(0.8))

                        Text("3. Start screen recording this view to go live")
                            .font(AppTypography.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(AppSpacing.lg)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(AppCornerRadius.lg)
                    .padding(.bottom, AppSpacing.xl)
                }
                .transition(.opacity)
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                showUI.toggle()
            }
        }
        .onAppear {
            // Start the video stream
            Task {
                print("🎥 SimpleLiveStreamView: Start the video stream")
                await streamViewModel.handleStartStreaming()
            }
        }
        .onDisappear {
            // Stop the video stream
            Task {
                print("🎥 SimpleLiveStreamView: Stop the video stream")
                if streamViewModel.streamingStatus != .stopped {
                    await streamViewModel.stopSession()
                }
            }
        }
    }
}
