import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var log: ProbeLog
    @EnvironmentObject private var preferences: BackupPreferences

    var body: some View {
        Group {
            if preferences.completedOnboarding {
                MainAppView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .tint(BackupTheme.blue)
        .animation(.easeInOut(duration: 0.3), value: preferences.completedOnboarding)
        .onAppear { markBuildStep() }
    }

    private func markBuildStep() {
        if log.steps.first(where: { $0.id == ProbeLog.build })?.state == .pending {
            log.set(ProbeLog.build, .passed, "app launched on \(PlatformVersion.name) \(PlatformVersion.version)")
        }
    }
}

private struct MainAppView: View {
    @State private var selectedTab = 0
    @State private var showConnectionTutorial = false

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(
                onConnect: { showConnectionTutorial = true },
                onAccount: { selectedTab = 3 }
            )
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            FolderSelectionView()
                .tabItem { Label("Albums", systemImage: "rectangle.stack.fill") }
                .tag(1)

            UploadsView()
                .tabItem { Label("Activity", systemImage: "arrow.up.circle.fill") }
                .tag(2)

            SettingsView { showConnectionTutorial = true }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        // Full screen, like onboarding's connect step. As a sheet, an
        // accidental downward swipe discards a single-use oauth_token and the
        // whole Google sign-in has to be repeated. (macOS has no full-screen
        // cover; a sheet is the closest equivalent there.)
        .fullScreenCoverCompat(isPresented: $showConnectionTutorial) {
            ConnectionTutorialView()
        }
    }
}
