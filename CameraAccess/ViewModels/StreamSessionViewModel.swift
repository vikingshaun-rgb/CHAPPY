/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model for video streaming from Meta wearable devices.
// Updated for DAT SDK 0.7.0: the old StreamSession API was replaced by
// DeviceSession (session lifecycle) + Stream (camera capability).
// Public surface (published properties + methods) unchanged so existing
// views keep working.
//

import MWDATCamera
import MWDATCore
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shaun.chappy", category: "StreamSession")

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped {
    // POCKET-MODE KEEPALIVE: while the glasses are streaming, hold the
    // screen awake — iOS stalls the frame pipeline when the display
    // sleeps (audio survives, video freezes). Auto-releases on stop so
    // normal auto-lock returns. Covers every start/stop path because
    // ALL of them flow through streamingStatus.
    didSet {
      UIApplication.shared.isIdleTimerDisabled = (streamingStatus != .stopped)
    }
  }
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  // Timer properties
  @Published var activeTimeLimit: StreamTimeLimit = .noLimit
  @Published var remainingTime: TimeInterval = 0

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false
  @Published var showVisionRecognition: Bool = false
  @Published var showOmniRealtime: Bool = false
  @Published var showLeanEat: Bool = false

  private var timerTask: Task<Void, Never>?

  // DAT SDK 0.7.0: a DeviceSession owns the device connection; a Stream is a
  // capability added to a *started* session. Sessions are single-use — once
  // stopped they are terminal, so we create a fresh session on every start.
  private var deviceSession: DeviceSession?
  private var stream: MWDATCamera.Stream?

  // Listener tokens manage DAT SDK event subscriptions
  private var streamStateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private var sessionErrorTask: Task<Void, Never>?
  private var sessionStateTask: Task<Void, Never>?

  // Fast-lane frame conversion (off-main; one in flight, freshest wins)
  nonisolated(unsafe) private static var frameConversionBusy = false
  private static let frameQueue = DispatchQueue(label: "chappy.frameconvert", qos: .userInteractive)

  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var isProcessingFrame = false

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    logger.info("🟢 StreamSessionViewModel init (SDK 0.7)")

    // One-time quality upgrade (the saved-value-beats-new-default lesson):
    // an old saved "medium" was just the old default, not a user choice —
    // scrub it once so the new "high" default applies. A saved "low" is
    // left alone (deliberate bandwidth choice).
    let defaults = UserDefaults.standard
    if !defaults.bool(forKey: "video_quality_high_migrated_v1") {
      if defaults.string(forKey: "video_quality") == "medium" {
        defaults.set("high", forKey: "video_quality")
        logger.info("🟢 Migrated video_quality medium → high (one-time)")
      }
      defaults.set(true, forKey: "video_quality_high_migrated_v1")
    }
    // Let the SDK auto-select from available devices
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      for await device in deviceSelector.activeDeviceStream() {
        logger.info("📱 Device changed: \(device != nil ? "connected" : "disconnected")")
        self.hasActiveDevice = device != nil
      }
    }

    logger.info("🟢 StreamSessionViewModel init complete")
  }

  // MARK: - Configuration

  private func makeStreamConfiguration() -> StreamConfiguration {
    // Saved video quality setting from UserDefaults.
    // DEFAULT RAISED medium → high (2026-08-03): the stream source was the
    // sharpness ceiling — "read this" and eagle vision can only be as sharp
    // as what the glasses send. Live AI still downsizes its 2fps frames to
    // 512px before upload, so websocket latency is unaffected; the full-res
    // frame benefits the hi-res "read this" grab and Quick Vision snaps.
    let savedQuality = UserDefaults.standard.string(forKey: "video_quality") ?? "high"
    let resolution: StreamingResolution
    switch savedQuality {
    case "low":
      resolution = .low
    case "high":
      resolution = .high
    default:
      resolution = .medium
    }
    logger.info("🟢 Using video quality: \(savedQuality) -> \(String(describing: resolution))")
    return StreamConfiguration(
      videoCodec: .raw,
      resolution: resolution,
      frameRate: 24)
  }

  // MARK: - Permissions + Start

  func handleStartStreaming() async {
    logger.info("▶️ handleStartStreaming called")
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      logger.info("▶️ Permission status: \(String(describing: status))")
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      logger.info("▶️ Permission request result: \(String(describing: requestStatus))")
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      logger.error("❌ Permission error: \(error.localizedDescription)")
      showError("Permission error: \(error.localizedDescription)")
    }
  }

  func startSession() async {
    logger.info("🚀 startSession START")

    // Reset to unlimited time when starting a new stream
    activeTimeLimit = .noLimit
    remainingTime = 0
    stopTimer()

    // Reset frame state
    hasReceivedFirstFrame = false

    // Tear down any previous session (sessions are single-use in 0.7)
    await teardownSession()

    streamingStatus = .waiting

    do {
      // 1. Create + start the DeviceSession
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      self.deviceSession = session

      // Surface session errors (e.g. glasses-side DAT app needs an update)
      sessionErrorTask = Task { @MainActor [weak self] in
        for await error in session.errorStream() {
          logger.error("❌ Session error: \(String(describing: error))")
          self?.showError(Self.describe(error))
        }
      }

      // Track session state; a stopped session ends the stream UI
      sessionStateTask = Task { @MainActor [weak self] in
        for await state in session.stateStream() {
          logger.info("📊 Session state: \(String(describing: state))")
          if state == .stopped {
            self?.currentVideoFrame = nil
            self?.streamingStatus = .stopped
          }
        }
      }

      logger.info("🚀 Starting device session…")
      try session.start()

      // Wait for the session to reach .started before adding capabilities
      for await state in session.stateStream() {
        if state == .started { break }
        if state == .stopped {
          logger.error("❌ Session stopped before starting")
          showError("Couldn't connect to the glasses. Please try again.")
          return
        }
      }
      logger.info("🚀 Device session started")

      // 2. Add the Stream capability
      guard let stream = try session.addStream(config: makeStreamConfiguration()) else {
        showError("Couldn't start the camera stream. Please try again.")
        return
      }
      self.stream = stream

      // Subscribe to stream state changes
      streamStateListenerToken = stream.statePublisher.listen { [weak self] state in
        Task { @MainActor [weak self] in
          logger.info("📊 Stream state: \(String(describing: state))")
          self?.updateStatusFromState(state)
        }
      }

      // Subscribe to video frames.
      // PERF FIX (iPhone 11): conversion used to run on the MAIN thread —
      // high-res frames backed up behind the UI and the "current" frame
      // went seconds stale. Now: dedicated queue, one conversion in flight,
      // freshest frame always wins, main thread only receives the result.
      videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
        guard !Self.frameConversionBusy else { return }
        Self.frameConversionBusy = true
        Self.frameQueue.async { [weak self] in
          let image = videoFrame.makeUIImage()
          Self.frameConversionBusy = false
          guard let image else { return }
          Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentVideoFrame = image
            if !self.hasReceivedFirstFrame {
              logger.info("🎥 First frame received and converted (fast path)")
              self.hasReceivedFirstFrame = true
            }
          }
        }
      }

      // Subscribe to photo capture
      photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
        Task { @MainActor [weak self] in
          guard let self else { return }
          logger.info("📸 Photo captured - size: \(photoData.data.count) bytes")
          if let uiImage = UIImage(data: photoData.data) {
            self.capturedPhoto = uiImage
            self.showPhotoPreview = true
          }
        }
      }

      // 3. Start the stream capability
      logger.info("🚀 Starting stream…")
      await stream.start()
      logger.info("🚀 startSession END - stream started")

    } catch {
      logger.error("❌ startSession failed: \(error.localizedDescription)")
      showError(Self.describe(error))
      streamingStatus = .stopped
    }
  }

  func stopSession() async {
    logger.info("⏹️ stopSession START")
    stopTimer()
    await teardownSession()
    currentVideoFrame = nil
    streamingStatus = .stopped
    logger.info("⏹️ stopSession END")
  }

  private func teardownSession() async {
    if let stream {
      await stream.stop()
    }
    deviceSession?.stop()
    streamStateListenerToken = nil
    videoFrameListenerToken = nil
    photoDataListenerToken = nil
    sessionErrorTask?.cancel()
    sessionErrorTask = nil
    sessionStateTask?.cancel()
    sessionStateTask = nil
    stream = nil
    deviceSession = nil
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
    // RIDER: glasses trouble reaches the EARS, not just the screen —
    // battery-critical / overheating / closed hinges get spoken.
    let lower = message.lowercased()
    if lower.contains("temperature") || lower.contains("battery") || lower.contains("hinges") {
        TTSService.shared.speak(message)
    }
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func setTimeLimit(_ limit: StreamTimeLimit) {
    activeTimeLimit = limit
    remainingTime = limit.durationInSeconds ?? 0

    if limit.isTimeLimited {
      startTimer()
    } else {
      stopTimer()
    }
  }

  func capturePhoto() {
    stream?.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func startTimer() {
    stopTimer()
    timerTask = Task { @MainActor [weak self] in
      while let self, remainingTime > 0 {
        try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
        guard !Task.isCancelled else { break }
        remainingTime -= 1
      }
      if let self, !Task.isCancelled {
        await stopSession()
      }
    }
  }

  private func stopTimer() {
    timerTask?.cancel()
    timerTask = nil
  }

  private func updateStatusFromState(_ state: StreamState) {
    logger.info("📊 updateStatusFromState: \(String(describing: state))")
    switch state {
    case .stopped:
      logger.info("📊 Stream STOPPED - clearing frame")
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      logger.info("📊 Stream WAITING (\(String(describing: state)))")
      streamingStatus = .waiting
    case .streaming:
      logger.info("📊 Stream STREAMING ✅")
      streamingStatus = .streaming
    @unknown default:
      streamingStatus = .waiting
    }
  }

  /// Human-readable message for any SDK error, with a helpful hint for the
  /// known glasses-side-app-update case.
  private static func describe(_ error: Error) -> String {
    let raw = String(describing: error)
    if raw.contains("datAppOnTheGlassesUpdateRequired") {
      return "The app on your glasses needs an update. Open Meta AI → App Connections and update it, then try again."
    }
    if raw.contains("noEligibleDevice") {
      return "No compatible glasses found. Make sure they're on, nearby, and Developer Mode is enabled in the Meta AI app."
    }
    if raw.contains("permissionDenied") {
      return "Camera permission denied. Please grant permission via the Meta AI app."
    }
    if raw.contains("hingesClosed") {
      return "Glasses hinges are closed. Please open them to continue."
    }
    if raw.contains("thermal") {
      return "Device temperature is too high. Streaming paused."
    }
    if raw.contains("timeout") {
      return "The operation timed out. Please try again."
    }
    return "Streaming error: \(error.localizedDescription)"
  }

  /// Full cleanup of all resources - call when ViewModel is no longer needed
  func cleanup() async {
    logger.info("🔴 cleanup START")
    stopTimer()
    deviceMonitorTask?.cancel()
    deviceMonitorTask = nil
    await teardownSession()
    logger.info("🔴 cleanup END")
  }
}
