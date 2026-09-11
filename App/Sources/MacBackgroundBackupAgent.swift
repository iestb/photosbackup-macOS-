#if os(macOS)
import AppKit
import SwiftUI

/// Keeps the app (and automatic backup) running after the main window closes,
/// so the menu-bar icon and the login-item agent stay meaningful — without
/// this, SwiftUI would quit the process along with its last window.
///
/// Also the home for the two lifecycle hooks `PhotosBackupApp.init()` wires
/// up, because this app is an `LSUIElement` accessory: macOS does not
/// auto-open a `WindowGroup` window for one at launch, so `.task` on the
/// window's content (where iOS's equivalent startup lives) may never run on
/// a real login-item launch. `applicationDidFinishLaunching` fires every
/// time regardless of whether any window ever opens; `applicationWillTerminate`
/// is the only reliable quit-time hook on macOS — there is no scenePhase-style
/// suspend signal the way there is on iOS.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    var onLaunch: (() -> Void)?
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        onLaunch?()
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }

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
    @EnvironmentObject private var albums: PhotoAlbumStore
    @EnvironmentObject private var loginItems: LoginItemManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    private enum Tab: String, CaseIterable, Identifiable {
        case status = "Status"
        case albums = "Albums"
        case settings = "Settings"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .status
    @State private var isStartingManualRun = false
    @State private var manualRunMessage: String?
    @State private var showingStopConfirmation = false
    @State private var showingDisconnectConfirmation = false
    @State private var albumSearch = ""

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
                case .albums: albumsTab
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
        .frame(width: 320)
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
        .confirmationDialog(
            "Disconnect Google Photos?",
            isPresented: $showingDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { Task { await account.disconnect() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New backups will stop until you connect again. Photos already backed up are not affected.")
        }
        .onAppear { loginItems.refresh() }
    }

    private var statusTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            accountRow

            Divider()

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

            if let reason = queue.networkPauseReason {
                Label(reason, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            LabeledContentCompat("Simultaneous Uploads") {
                Picker("", selection: $preferences.concurrentUploads) {
                    ForEach(Array(UploadQueue.concurrencyRange), id: \.self) { Text($0.formatted()).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .help("How many items are checked against Google Photos and prepared at once. Cheap, network-light work — safe to keep high.")

            LabeledContentCompat("Simultaneous Transfers") {
                Picker("", selection: $preferences.concurrentTransfers) {
                    ForEach(Array(UploadQueue.transferConcurrencyRange), id: \.self) { Text($0.formatted()).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .help("How many are actually sending file bytes at once. Bandwidth-heavy — a high value here can slow everything down.")

            Toggle("Storage Saver", isOn: $preferences.storageSaver)

            Toggle("Launch at Login", isOn: Binding(
                get: { loginItems.isEnabled },
                set: { loginItems.setEnabled($0) }
            ))
        }
    }

    private var albumsTab: some View {
        Group {
            if albums.authorization == .notDetermined {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow photo access to choose albums.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Allow Photo Access") { Task { await albums.requestAccess() } }
                }
            } else if !albums.canRead {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Photo access is off.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        if let url = PlatformPrivacySettings.url { openURL(url) }
                    }
                }
            } else if albums.isLoading && albums.albums.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading albums…").foregroundStyle(.secondary)
                }
            } else if albums.albums.isEmpty {
                Text("No albums found.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search albums", text: $albumSearch)
                        .textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredAlbums) { album in albumRow(album) }
                        }
                    }
                    .frame(maxHeight: 260)
                    Text("\(preferences.selectedAlbumIDs.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { albums.refreshInBackground() }
    }

    private var filteredAlbums: [PhotoAlbum] {
        guard !albumSearch.isEmpty else { return albums.albums }
        return albums.albums.filter { $0.title.localizedCaseInsensitiveContains(albumSearch) }
    }

    private func albumRow(_ album: PhotoAlbum) -> some View {
        let isSelected = preferences.selectedAlbumIDs.contains(album.id)
        return Button {
            preferences.toggle(albumID: album.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: album.symbol)
                    .foregroundStyle(BackupTheme.blue)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title).font(.caption.weight(.medium)).lineLimit(1)
                    Text("\(album.count.formatted()) items").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? BackupTheme.blue : .secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var accountRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(accountTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(accountSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if account.status.isUsable {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        if account.status.isUsable {
            Button("Disconnect", role: .destructive) { showingDisconnectConfirmation = true }
                .controlSize(.small)
        } else {
            Button {
                openWindow(id: "connect")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Connect Google Account", systemImage: "person.badge.key")
            }
            .controlSize(.small)
        }
    }

    private var accountTitle: String {
        switch account.status {
        case .loading: return "Checking account…"
        case .disconnected: return "Not connected"
        case .connected(let email, _): return email
        case .rejected(let email, _): return email.isEmpty ? "Sign in again" : email
        }
    }

    private var accountSubtitle: String {
        switch account.status {
        case .loading: return "Looking for a saved credential"
        case .disconnected: return "Connect to start backing up"
        case .connected(_, let since): return "Connected · \(since.formatted(date: .abbreviated, time: .omitted))"
        case .rejected(_, let reason): return reason
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

/// The dedicated "connect" window's content — the same sign-in flow
/// `ConnectionTutorialView` presents as a sheet on iOS, adapted to close its
/// own window (via `dismissWindow`) instead of the sheet-oriented `dismiss()`
/// environment action, since this is a real `WindowGroup` window, not a
/// presentation.
struct MacConnectAccountWindow: View {
    @EnvironmentObject private var connector: AccountConnector
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        AccountConnectView(
            onCaptured: { token in
                dismissWindow(id: "connect")
                Task { await connector.ingestWebToken(token) }
            },
            onCancel: { dismissWindow(id: "connect") }
        )
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
