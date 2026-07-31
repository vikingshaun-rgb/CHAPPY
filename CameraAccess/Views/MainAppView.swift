/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MainAppView.swift
//
// Central navigation hub that displays different views based on DAT SDK registration and device states.
// When unregistered, shows the registration flow. When registered, shows the device selection screen
// for choosing which Meta wearable device to stream from.
//

import MWDATCore
import SwiftUI

struct MainAppView: View {
  let wearables: WearablesInterface
  @ObservedObject private var viewModel: WearablesViewModel
  @StateObject private var streamViewModel: StreamSessionViewModel
  @StateObject private var quickVisionManager = QuickVisionManager.shared
  @State private var permissionsGranted = false
  @State private var hasCheckedPermissions = false

  init(wearables: WearablesInterface, viewModel: WearablesViewModel) {
    self.wearables = wearables
    self.viewModel = viewModel
    self._streamViewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    if viewModel.registrationState == .registered || viewModel.hasMockDevice {
      // Registered / device connected
      if !hasCheckedPermissions {
        // First launch — request permissions
        PermissionsRequestView { granted in
          permissionsGranted = granted
          hasCheckedPermissions = true
        }
      } else {
        // Permissions checked — show the main UI
        MainTabView(streamViewModel: streamViewModel, wearablesViewModel: viewModel)
          .onAppear {
            // Set the StreamViewModel reference on QuickVisionManager
            quickVisionManager.setStreamViewModel(streamViewModel)

            // Set up OpenClaw node command routing
            let router = OpenClawCommandRouter(streamViewModel: streamViewModel)
            OpenClawNodeService.shared.setCommandRouter(router)

            // Auto-reconnect if OpenClaw was previously enabled
            if OpenClawNodeService.shared.isEnabled {
              OpenClawNodeService.shared.connect()
            }
          }
      }
    } else {
      // Not registered — show the registration/onboarding flow
      HomeScreenView(viewModel: viewModel)
    }
  }
}
