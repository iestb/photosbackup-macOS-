#if os(macOS)
import Foundation
import ServiceManagement

/// Registers the app itself (not a separate helper) to launch at login, using
/// `SMAppService.mainApp` — the macOS 13+ replacement for the old embedded-
/// helper login-item API. Backs the "Launch at Login" toggle in Settings; the
/// agent otherwise has no other way to be running before the user opens it,
/// since automatic backup on macOS depends on the process staying alive
/// (see `MacBackgroundBackupAgent`).
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled: Bool

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Nothing actionable to surface here beyond reflecting reality:
            // System Settings > General > Login Items & Extensions is the
            // fallback if registration silently fails (e.g. an unsigned
            // build, or the user removed it there directly).
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
#endif
