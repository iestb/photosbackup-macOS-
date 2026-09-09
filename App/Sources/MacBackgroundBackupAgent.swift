#if os(macOS)
import AppKit
import SwiftUI

/// Keeps the app (and automatic backup) running after the main window closes,
/// so the menu-bar icon and the login-item agent stay meaningful — without
/// this, SwiftUI would quit the process along with its last window.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The `MenuBarExtra` dropdown: connection status, a manual trigger, a way
/// back to the full window, and the launch-at-login toggle — the pieces of
/// the iOS app's automatic-backup surface that make sense with no window open.
struct MenuBarContentView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var automaticBackup: AutomaticBackupCoordinator
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var loginItems: LoginItemManager
    @Environment(\.openWindow) private var openWindow

    @State private var isStartingManualRun = false
    @State private var manualRunMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Photos Backup").font(.headline)
            Text(statusLine).font(.subheadline).foregroundStyle(.secondary)

            Divider()

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Photos Backup", systemImage: "macwindow")
            }

            Button {
                backUpNow()
            } label: {
                Label(isStartingManualRun ? "Backing Up…" : "Back Up Now", systemImage: "arrow.up.circle")
            }
            .disabled(isStartingManualRun || !account.status.isUsable || preferences.selectedAlbumIDs.isEmpty)

            if let manualRunMessage {
                Text(manualRunMessage).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { loginItems.isEnabled },
                set: { loginItems.setEnabled($0) }
            ))

            Divider()

            Button("Quit Photos Backup") {
                NSApp.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private var statusLine: String {
        if !account.status.isUsable { return "Not connected" }
        if !queue.isIdle { return "Backing up · \(queue.activeCount) remaining" }
        if queue.failedCount > 0 { return "\(queue.failedCount) items failed" }
        return "Up to date"
    }

    private func backUpNow() {
        guard !isStartingManualRun else { return }
        isStartingManualRun = true
        manualRunMessage = nil
        Task {
            let outcome = await automaticBackup.backUpSelectedAlbumsNow()
            isStartingManualRun = false
            manualRunMessage = DashboardView.message(for: outcome)
        }
    }
}
#endif
