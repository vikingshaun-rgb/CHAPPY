/*
 * Main Tab View
 * Main tab navigation view
 */

import SwiftUI

struct MainTabView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var wearablesViewModel: WearablesViewModel

    @State private var selectedTab = 0

    // Read API Key from secure storage
    private var apiKey: String {
        APIKeyManager.shared.getAPIKey() ?? ""
    }

    var body: some View {
        // BUILD 231: one line, and every module in the app can put a
        // real email on screen with the report attached — including the
        // ones raised by voice from a manager that has no view context.
        tabs.chappyMailHost()
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            // Home - Feature entry
            TurboMetaHomeView(streamViewModel: streamViewModel, wearablesViewModel: wearablesViewModel, apiKey: apiKey)
                .tabItem {
                    Label("tab.home".localized, systemImage: "house.fill")
                }
                .tag(0)

            // BUILD 137 — RECORDS RETIRED. Everything Records showed is folded
            // into the one memory store at launch, so this tab now opens the
            // Memory browser: one place, searchable, with the map — instead of
            // a second, staler view of the same life.
            ChappyMemoryBrowser()
                .tabItem {
                    Label("Memory", systemImage: "brain.head.profile")
                }
                .tag(1)

            // Gallery
            GalleryView()
                .tabItem {
                    Label("tab.gallery".localized, systemImage: "photo.on.rectangle")
                }
                .tag(2)

            // Settings
            SettingsView(streamViewModel: streamViewModel, apiKey: apiKey)
                .tabItem {
                    Label("tab.settings".localized, systemImage: "person.fill")
                }
                .tag(3)
        }
        .accentColor(AppColors.primary)
    }
}
