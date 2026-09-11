#if os(macOS)
import AppKit
import SwiftUI

/// Keeps the app (and automatic backup) running after the main window closes,
/// so the menu-bar icon and the login-item agent stay meaningful — without
/// this, SwiftUI would quit the process along with its last window.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The `MenuBarExtra` dropdown: at-a-glance counts, a manual trigger, a way
/// back to the full window, and a Settings pane condensed enough to fit here
/// — the pieces of the iOS app's automatic-backup surface that make sense
/// with no window open, plus the everyday settings so changing them doesn't
/// require opening the full window at all.
struct MenuBarContentView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var automaticBackup: AutomaticBackupCoordinator
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var loginItems: LoginItemManager
    @Environment(\.openWindow) private var openWindow

    private enum Tab: String, CaseIterable, Identifiable {
        case status = "Status"
        case settings = "Settings"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .status
    @State private var isStartingManualRun = false
    @State private var manualRunMessage: String?
    @State private var showingStopConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Photos Backup").font(.headline)
                Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)

            Divider().padding(.top, 10)

            Group {
                switch tab {
                case .status: statusTab
                case .settings: settingsTab
                }
            }
            .padding(14)

            Divider()

            Button("Quit Photos Backup") {
                NSApp.terminate(nil)
            }
            .padding(14)
        }
        .frame(width: 300)
        .confirmationDialog(
            "Stop all backups?",
            isPresented: $showingStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Backup", role: .destructive) { stopBackup() }
            Button("Keep Backing Up", role: .cancel) {}
        } message: {
            Text(stopBackupMessage)
        }
    }

    private var statusTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            statRow(label: "Backed up", value: queue.completedSourceCount.formatted())
            statRow(label: "In queue", value: queue.activeCount.formatted())
            if queue.deferredForICloudCount > 0 {
                statRow(label: "Waiting on iCloud", value: queue.deferredForICloudCount.formatted())
            }
            if queue.failedCount > 0 {
                statRow(label: "Failed", value: queue.failedCount.formatted(), color: .red)
                Button {
                    queue.retryAllFailed()
                } label: {
                    Label("Retry Failed", systemImage: "arrow.clockwise.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if !queue.isIdle {
                ProgressView(value: queue.overallFraction).tint(BackupTheme.blue).padding(.top, 2)
            }

            if !queue.isIdle || queue.isUserPaused {
                HStack(spacing: 8) {
                    if queue.isUserPaused {
                        Button {
                            queue.resumeUserPausedUploads()
                        } label: {
                            Label("Resume", systemImage: "play.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!account.status.isUsable)
                    } else if queue.pauseReason == nil {
                        Button {
                            queue.pauseAfterCurrentUploads()
                        } label: {
                            Label("Pause", systemImage: "pause.circle")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    if !queue.isIdle {
                        Button(role: .destructive) {
                            showingStopConfirmation = true
                        } label: {
                            Label("Stop", systemImage: "stop.circle")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }

            Divider().padding(.vertical, 4)

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
        }
    }

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Automatic Backup", isOn: $preferences.automaticBackup)

            LabeledContentCompat("Connection") {
                Picker("", selection: $preferences.connection) {
                    ForEach(BackupConnection.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            LabeledContentCompat("Simultaneous Uploads") {
                Picker("", selection: $preferences.concurrentUploads) {
                    ForEach(Array(UploadQueue.concurrencyRange), id: \.self) { Text($0.formatted()).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Toggle("Storage Saver", isOn: $preferences.storageSaver)

            Toggle("Launch at Login", isOn: Binding(
                get: { loginItems.isEnabled },
                set: { loginItems.setEnabled($0) }
            ))
        }
    }

    private func statRow(label: String, value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.monospacedDigit().weight(.semibold)).foregroundStyle(color)
        }
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

    private var stopBackupMessage: String {
        if preferences.automaticBackup {
            return "Uploads in progress will be cancelled, the queue will be cleared, and Automatic Backup will be turned off. Photos already backed up are not affected."
        }
        return "Uploads in progress will be cancelled and the queue will be cleared. Photos already backed up are not affected."
    }

    private func stopBackup() {
        preferences.automaticBackup = false
        queue.cancelAll()
    }
}

/// `LabeledContent` needs iOS 16/macOS 13 — fine for the Mac-only menu bar
/// content, but `LabeledRow` (the app's existing iOS-15-safe stand-in) forces
/// its value into a `Text`, which doesn't fit a `Picker`. A small local
/// version that takes any content, kept private to this file since nothing
/// else needs it.
private struct LabeledContentCompat<Value: View>: View {
    let title: String
    let value: Value

    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            value
        }
    }
}
#endif
