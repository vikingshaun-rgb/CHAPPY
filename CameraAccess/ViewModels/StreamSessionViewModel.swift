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
  // CAMERA WATCHDOG: last time a frame ARRIVED from the glasses (set at
  // arrival, NOT after conversion — else a slow phone looks like a dead
  // stream and the watchdog kick-cycles, making everything worse).
  nonisolated(unsafe) private var lastFrameAt = Date()
  private var frameWatchdogTask: Task<Void, Never>?
  private var stallKicks = 0
  // PREVIEW THROTTLE: iPhone 11 can't convert 24fps of high-res — cap
  // preview conversions at ~12fps; the freshest frame still always wins.
  nonisolated(unsafe) private static var lastConvertAt = Date.distantPast
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
    // FRAME RATE 24→15 (2026-08-05): the 0.8 WiFi transport really delivers
    // what we ask for — 24fps of high-res raw drowned the iPhone 11's CPU
    // (heat, jank, watchdog false alarms). 15fps is smooth to the eye, halves
    // the load, and Gemini only samples ~3fps anyway.
    return StreamConfiguration(
      videoCodec: .raw,
      resolution: resolution,
      frameRate: 15)
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

  /// BUILD 218 — one start at a time.
  ///
  /// Nothing guarded this, and startSession opens by tearing down
  /// whatever was there. Two overlapping starts therefore destroyed each
  /// other's session — which is exactly what happens when a view's
  /// onAppear fires while a voice command is already bringing the camera
  /// up. LiveAIManager's own start path has checked this since build
  /// 145; this one never did.
  private var isStarting = false

  /// BUILD 218 — set by the state watcher, polled by the bounded wait.
  /// nil while still unknown, so "never answered" and "answered no" stay
  /// distinguishable.
  private var startedProbe: Bool?

  func startSession() async {
    logger.info("🚀 startSession START")

    if isStarting {
      logger.info("🚀 startSession ignored — one already in flight")
      return
    }
    isStarting = true
    defer { isStarting = false }

    // Reset to unlimited time when starting a new stream
    activeTimeLimit = .noLimit
    remainingTime = 0
    stopTimer()

    // Reset frame state
    hasReceivedFirstFrame = false

    // BUILD 218 — THE FREEZE.
    //
    // This line is the whole bug. currentVideoFrame was never cleared
    // here, so the frame left over from the session about to be torn
    // down stayed on screen while the new one came up — and if the new
    // one failed to come up, it stayed there forever.
    //
    // That is what "Live AI opens but freezes, no movement" was. Not a
    // frozen video: a photograph of the last thing the previous session
    // saw, held up in front of him with the audio working normally
    // behind it. Silence and failure looking identical again.
    currentVideoFrame = nil

    // Both of these are process-wide and were never reset, so a
    // conversion that died mid-flight left the gate shut for the life of
    // the app — preview dead, audio fine, watchdog none the wiser
    // because it watches ARRIVAL, not conversion.
    Self.frameConversionBusy = false
    Self.lastConvertAt = .distantPast

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

      // BUILD 218 — WAIT, BUT NOT FOREVER.
      //
      // This loop had no timeout. A session that never reaches .started
      // parked here indefinitely: addStream never ran, no frames were
      // ever subscribed to, status stayed .waiting, and the screen kept
      // showing whatever was there before. Combined with the stale frame
      // above, that is a permanent, convincing freeze.
      //
      // Twenty seconds is the same budget LiveAIManager already uses for
      // the equivalent wait, so this now behaves the same way whichever
      // door the camera is opened through.
      // Everything here stays on the main actor deliberately: the
      // session object is not Sendable, so racing it through a task
      // group would mean shipping it across an isolation boundary. A
      // probe property and a polled deadline do the same job with none
      // of that.
      startedProbe = nil
      let waiter = Task { @MainActor [weak self] in
        for await state in session.stateStream() {
          if state == .started { self?.startedProbe = true; return }
          if state == .stopped { self?.startedProbe = false; return }
        }
        self?.startedProbe = false
      }
      let deadline = Date().addingTimeInterval(20)
      while startedProbe == nil, Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      waiter.cancel()

      guard startedProbe == true else {
        logger.error("❌ Session never reached .started")
        // AUDIT: the old early returns left streamingStatus on .waiting,
        // so anything polling for .streaming hung to its own timeout and
        // the idle timer stayed disabled for the rest of the session.
        streamingStatus = .stopped
        currentVideoFrame = nil
        showError("The glasses didn't wake up. Check they're on your face and connected, then try again.")
        return
      }
      logger.info("🚀 Device session started")

      // 2. Add the Stream capability
      // NOTE (2026-08-05): docs describe an addCamera API but SDK 0.8.0's
      // real surface keeps addStream — proven working in build 42 once the
      // NSLocalNetworkUsageDescription permission was added (that was the
      // actual camera fix, not the API).
      guard let stream = try session.addStream(config: makeStreamConfiguration()) else {
        // BUILD 218: was leaving the status on .waiting forever.
        streamingStatus = .stopped
        currentVideoFrame = nil
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
        // Arrival marker FIRST — the watchdog watches delivery, not conversion
        self?.lastFrameAt = Date()
        let now = Date()
        guard !Self.frameConversionBusy,
              now.timeIntervalSince(Self.lastConvertAt) > 0.08 else { return }
        Self.frameConversionBusy = true
        Self.lastConvertAt = now
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
            // VOICE SHUTTER: an intentional photo lands in iOS Photos —
            // time+GPS-stamped by the system, ready for Phase 5 photo ingest.
            // AUDIT FIX (QV-C5): gated — Quick Vision's working snaps no longer
            // spam the camera roll.
            if self.saveNextPhotoToRoll {
              self.saveNextPhotoToRoll = false
              UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
            }
            ChappyHaptics.shared.shutter()
          }
        }
      }

      // 3. Start the stream capability
      logger.info("🚀 Starting stream…")
      await stream.start()
      logger.info("🚀 startSession END - stream started")

      // CAMERA WATCHDOG: the WiFi transport can stall silently (frozen
      // preview, voice fine). If no frame lands for 6+ seconds while we
      // believe we're streaming, kick the stream — stop/start heals the
      // transport without touching the session or the conversation.
      lastFrameAt = Date()
      frameWatchdogTask?.cancel()
      stallKicks = 0
      frameWatchdogTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 3_000_000_000)
          guard let self, let stream = self.stream else { continue }
          // BUILD 218: the `hasReceivedFirstFrame` condition meant the
          // watchdog only protected a stream that had ALREADY worked. The
          // case he actually hit — opened, never moved — was the one case
          // it could not see. Now it kicks either way.
          if Date().timeIntervalSince(self.lastFrameAt) > 6 {
            self.stallKicks += 1
            if self.stallKicks >= 3 {
              // Two kicks didn't revive it — the transport is wedged.
              // Nuclear: full camera session restart (conversation unaffected).
              logger.warning("🩺 Stream kicks failed — FULL session restart")
              self.stallKicks = 0
              await self.stopSession()
              await self.startSession()
              return // startSession spawns a fresh watchdog
            }
            logger.warning("🩺 Camera stalled >6s — kicking the stream (\(self.stallKicks))")
            self.lastFrameAt = Date() // debounce: one kick per stall window
            await stream.stop()
            await stream.start()
          } else if Date().timeIntervalSince(self.lastFrameAt) < 3 {
            self.stallKicks = 0 // frames flowing again — reset escalation
          }
        }
      }

    } catch {
      logger.error("❌ startSession failed: \(error.localizedDescription)")
      // BUILD 218: never leave a dead frame up after a failed start.
      currentVideoFrame = nil
      streamingStatus = .stopped
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
    frameWatchdogTask?.cancel()
    frameWatchdogTask = nil
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

  /// AUDIT FIX (QV-C5): only an explicit voice shutter ("Chappy, take a photo")
  /// writes to the camera roll. Quick Vision snaps used the same path, so every
  /// "what am I looking at" also dumped a JPEG into Photos — hundreds a day on a
  /// travel day, and it buried the user's real photos.
  private var saveNextPhotoToRoll = false

  func capturePhoto(saveToRoll: Bool = false) {
    saveNextPhotoToRoll = saveToRoll
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
