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
    /// An enum, not raw tab indices: macOS drops the Activity tab below (the
    /// menu bar's Status tab and Dashboard's own Stop button cover what it
    /// was for there), and a hardcoded `selectedTab = 3` for Settings would
    /// have silently pointed at the wrong tab on whichever platform doesn't
    /// have four of them.
    private enum Tab: Hashable {
        case home, albums, activity, settings
    }
    @State private var selectedTab: Tab = .home
    @State private var showConnectionTutorial = false

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(
                onConnect: { showConnectionTutorial = true },
                onAccount: { selectedTab = .settings }
            )
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            FolderSelectionView()
                .tabItem { Label("Albums", systemImage: "rectangle.stack.fill") }
                .tag(Tab.albums)

#if os(iOS)
            UploadsView()
                .tabItem { Label("Activity", systemImage: "arrow.up.circle.fill") }
                .tag(Tab.activity)
#endif

            SettingsView { showConnectionTutorial = true }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
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
