/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CameraAccessApp.swift
//
// Main entry point for the CameraAccess sample app demonstrating the Meta Wearables DAT SDK.
// This app shows how to connect to wearable devices (like Ray-Ban Meta smart glasses),
// stream live video from their cameras, and capture photos. It provides a complete example
// of DAT SDK integration including device registration, permissions, and media streaming.
//

import Foundation
import MWDATCore
import SwiftUI

#if DEBUG
import MWDATMockDevice
#endif

@main
struct TurboMetaApp: App {
  #if DEBUG
  // Debug menu for simulating device connections during development
  @StateObject private var debugMenuViewModel = DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif
  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel

  init() {
    // BGTaskScheduler REQUIRES registration before launch finishes.
    ChappyProactive.shared.registerBackgroundTask()

    do {
      try Wearables.configure()
      print("✅ [Chappy] Wearables SDK configured successfully")
    } catch {
      print("❌ [Chappy] Wearables.configure() failed: \(error) | \(error.localizedDescription)")
    }
    let wearables = Wearables.shared
    self.wearables = wearables
    self._wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      // Main app view with access to the shared Wearables SDK instance
      // The Wearables.shared singleton provides the core DAT API
      MainAppView(wearables: Wearables.shared, viewModel: wearablesViewModel)
        .onAppear {
          ChappyProactive.shared.start()            // 8 scheduled check-ins
          ChappyLists.shared.startAtLaunch()        // re-arm shop geofences
          ChappyTimers.shared.restoreAfterLaunch()  // re-arm spoken timers
          ChappyPulse.shared.start()                // ambient memory dial
          ChappyPhotoIngest.shared.start()          // wi-fi monitor for ingest
          // BUILD 175: bring the audio path up quietly before the first
          // spoken line needs it, so launch never sounds robotic.
          TTSService.shared.primeVoicePath()
          // BUILD 182: rates were only ever fetched when a currency or
          // travel screen was opened. Until then every conversion silently
          // failed and the cost engine fell back to un-converted numbers —
          // rupiah added to dollars, spoken aloud and put in the brief.
          Task { await ChappyFX.shared.refresh() }
          ChappyGlance.write()   // the widget was only ever written by the flight poller
          // BUILD 189: the price journal. Runs on launch, checks only the
          // watches that are actually due (a fare weekly, a visa rule
          // monthly), and stays quiet unless something moved. A watch
          // that pings every week gets muted in a fortnight, and then it
          // is worth nothing at all.
          Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await ChappyWatch.shared.run()
          }
          // BUILD 190: the watch only ever ran when the app was opened,
          // so a week without opening it was a week of nothing checked.
          ChappyProactive.shared.onBackgroundWake = {
            await ChappyWatch.shared.run()
          }
        }
        // Show error alerts for view model failures
        .alert("Error", isPresented: $wearablesViewModel.showError) {
          Button("OK") {
            wearablesViewModel.dismissError()
          }
        } message: {
          Text(wearablesViewModel.errorMessage)
        }
        #if DEBUG
      // Bug 图标已隐藏
      // .sheet(isPresented: $debugMenuViewModel.showDebugMenu) {
      //   MockDeviceKitView(viewModel: debugMenuViewModel.mockDeviceKitViewModel)
      // }
      // .overlay {
      //   DebugMenuView(debugMenuViewModel: debugMenuViewModel)
      // }
        #endif

      // Registration view handles the flow for connecting to the glasses via Meta AI
      RegistrationView(viewModel: wearablesViewModel)
    }
  }
}
