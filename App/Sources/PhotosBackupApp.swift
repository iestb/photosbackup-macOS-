import SwiftUI

@main
struct PhotosBackupApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var loginItems = LoginItemManager()
#endif
    @StateObject private var log: ProbeLog
    @StateObject private var connector: AccountConnector
    @StateObject private var account: PhotosAccount
    @StateObject private var queue: UploadQueue
    @StateObject private var preferences: BackupPreferences
    @StateObject private var albums: PhotoAlbumStore
#if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
#endif
    private let photos: PhotosStack
    private let network: NetworkPolicyMonitor
    private let automaticBackup: AutomaticBackupCoordinator

    init() {
        let sharedLog = ProbeLog()
        let sharedConnector = AccountConnector(log: sharedLog)
        let stack = PhotosStack()
        let preferences = BackupPreferences()
        let albums = PhotoAlbumStore()
        let network = NetworkPolicyMonitor()
        stack.queue.options.storageSaver = preferences.storageSaver
        stack.queue.options.useQuota = preferences.useQuota
        stack.queue.setMaxConcurrent(preferences.concurrentUploads)
        stack.setMaxConcurrentTransfers(preferences.concurrentTransfers)
        let automaticBackup = AutomaticBackupCoordinator(
            photos: stack,
            account: stack.account,
            queue: stack.queue,
            preferences: preferences,
            albums: albums,
            network: network
        )
#if os(iOS)
        BackgroundFileUploadTransport.shared.setEventsDrainer { [weak automaticBackup] in
            await automaticBackup?.handleBackgroundURLSessionEvents()
        }
#endif
        // A successful exchange is what connects the account; the connector owns
        // the token, the stack owns everything downstream of it.
        sharedConnector.onExchange = { [weak stack] result in await stack?.connect(result) }
        _log = StateObject(wrappedValue: sharedLog)
        _connector = StateObject(wrappedValue: sharedConnector)
        _account = StateObject(wrappedValue: stack.account)
        _queue = StateObject(wrappedValue: stack.queue)
        _preferences = StateObject(wrappedValue: preferences)
        _albums = StateObject(wrappedValue: albums)
        self.photos = stack
        self.network = network
        self.automaticBackup = automaticBackup
        network.onStatusChange = { [weak automaticBackup] _ in automaticBackup?.networkDidChange() }
        network.start()
        automaticBackup.applyNetworkPolicy()
#if os(macOS)
        // Covers the login-item launch the window-scoped .task below cannot
        // reach — see MacAppDelegate. start() is safe to also run again from
        // that .task if a window does open: every step in it already guards
        // against running twice.
        let queueForShutdown = stack.queue
        appDelegate.onLaunch = { [weak automaticBackup] in
            Task { await automaticBackup?.start() }
        }
        appDelegate.onTerminate = { [weak queueForShutdown] in
            MainActor.assumeIsolated { queueForShutdown?.flushPendingWrites() }
        }
#endif
    }

    /// The main window's content, shared between the iOS scene and the macOS
    /// `WindowGroup`. Only the scene composition around it (and the scenePhase
    /// handling, which means something different on each platform) differs.
    private func mainContent() -> some View {
        ContentView()
            .environmentObject(log)
            .environmentObject(connector)
            .environmentObject(account)
            .environmentObject(queue)
            .environmentObject(preferences)
            .environmentObject(albums)
            .environmentObject(automaticBackup)
#if os(macOS)
            .environmentObject(loginItems)
#endif
            .task { await automaticBackup.start() }
            .onChange(of: preferences.connection) { _ in automaticBackup.connectionPreferenceDidChange() }
            .onChange(of: preferences.storageSaver) { value in queue.options.storageSaver = value }
            .onChange(of: preferences.useQuota) { value in queue.options.useQuota = value }
            .onChange(of: preferences.concurrentUploads) { value in queue.setMaxConcurrent(value) }
            .onChange(of: preferences.concurrentTransfers) { value in photos.setMaxConcurrentTransfers(value) }
            .onChange(of: preferences.automaticBackup) { _ in automaticBackup.backupConfigurationDidChange() }
            .onChange(of: preferences.selectedAlbumIDs) { _ in automaticBackup.backupConfigurationDidChange() }
            .onChange(of: preferences.completedOnboarding) { _ in automaticBackup.backupConfigurationDidChange() }
            .onChange(of: account.status) { _ in automaticBackup.accountDidChange() }
    }

    var body: some Scene {
#if os(iOS)
        WindowGroup {
            mainContent()
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        automaticBackup.applicationDidBecomeActive()
                    case .background:
                        automaticBackup.applicationDidEnterBackground()
                    default:
                        break
                    }
                }
        }
#elseif os(macOS)
        // No scenePhase-driven foreground/background switching here: the app
        // runs continuously as a login-item agent (see MacBackgroundBackupAgent
        // and AutomaticBackupCoordinator's macOS periodic-timer path), so
        // there is no OS-imposed suspended state to react to — closing the
        // window does not stop backups.
        WindowGroup("Photos Backup", id: "main") {
            mainContent()
                // Form on macOS lays out a fixed label column sized to the
                // widest row and does not reflow it as the window narrows —
                // below this width its labels and trailing controls clip
                // instead of wrapping. A floor here keeps every tab legible
                // instead of relying on the user never shrinking the window.
                .frame(minWidth: 680, minHeight: 480)
        }
        .defaultSize(width: 900, height: 680)

        // A small window just for the Google sign-in flow, so connecting an
        // account doesn't require opening the full tabbed app: the embedded
        // browser genuinely needs real screen space (unlike the rest of the
        // menu bar surface), and presenting a .sheet from inside a
        // MenuBarExtra's own popover is unreliable on macOS.
        WindowGroup("Connect Google Account", id: "connect") {
            MacConnectAccountWindow()
                .environmentObject(connector)
        }
        .defaultSize(width: 760, height: 640)

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(account)
                .environmentObject(queue)
                .environmentObject(automaticBackup)
                .environmentObject(preferences)
                .environmentObject(albums)
                .environmentObject(loginItems)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
#endif
    }

#if os(macOS)
    private var menuBarSymbol: String {
        if !account.status.isUsable { return "photo.stack" }
        if !queue.isIdle { return "arrow.up.circle" }
        if queue.failedCount > 0 { return "exclamationmark.circle" }
        return "checkmark.circle"
    }
#endif
}
