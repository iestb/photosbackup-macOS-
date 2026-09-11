import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Small cross-version, cross-platform shims. The app deploys to iOS 15 (where a
// few SwiftUI APIs used elsewhere are iOS 16+) and to macOS 13, and shares
// almost all of its view code between the two platforms.

extension View {
    /// `.scrollIndicators(.hidden)` is iOS 16+ / macOS 13+. On iOS 15 the
    /// indicators simply show (a minor cosmetic difference). Prefer
    /// `ScrollView(showsIndicators:)` where the initializer is in reach; this
    /// covers the cases where it is not.
    @ViewBuilder
    func hiddenScrollIndicators() -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            self.scrollIndicators(.hidden)
        } else {
            self
        }
    }

    /// `.fullScreenCover` is iOS/tvOS/watchOS only. macOS has no equivalent
    /// modal presentation, so a plain sheet stands in for it there.
    @ViewBuilder
    func fullScreenCoverCompat<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
#if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
#else
        self.sheet(isPresented: isPresented, content: content)
#endif
    }

    /// `.navigationBarTitleDisplayMode` is iOS/tvOS only; macOS has no
    /// equivalent (there is no navigation bar to collapse), so this is a no-op
    /// there.
    @ViewBuilder
    func inlineNavigationTitleCompat() -> some View {
#if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    /// `InsetGroupedListStyle` is iOS/tvOS only. macOS gets the platform's own
    /// default list appearance.
    @ViewBuilder
    func insetGroupedListStyleCompat() -> some View {
#if os(iOS)
        self.listStyle(.insetGrouped)
#else
        self.listStyle(.inset(alternatesRowBackgrounds: true))
#endif
    }

    /// `.textInputAutocapitalization` is iOS/tvOS/watchOS only — macOS text
    /// fields have no autocapitalization concept, so this is a no-op there.
    @ViewBuilder
    func noAutocapitalizationCompat() -> some View {
#if os(iOS)
        self.textInputAutocapitalization(.never)
#else
        self
#endif
    }
}

/// Single-column navigation root for a top-level screen (a tab's content, a
/// sheet). `NavigationView` in `.stack` style on iOS 15, where
/// `NavigationStack` (iOS 16+) isn't available yet. `NavigationStack` on
/// macOS: plain `NavigationView` there defaults to a sidebar/detail *split*
/// style with no true single-pane equivalent (unlike iOS's `.stack`), which
/// reads as a broken half-empty sidebar for a screen that's just one column
/// of content — `NavigationStack` (macOS 13+, our minimum) always renders as
/// a single stack and still hosts `NavigationLink` pushes the same way.
struct NavigationRoot<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
#if os(iOS)
        NavigationView { content }
            .navigationViewStyle(.stack)
#else
        NavigationStack { content }
#endif
    }
}

extension ToolbarItemPlacement {
    /// `.navigationBarTrailing` is iOS/tvOS/watchOS only.
    static var trailingCompat: ToolbarItemPlacement {
#if os(iOS)
        .navigationBarTrailing
#else
        .automatic
#endif
    }
}

/// A label/value row, the iOS 15-safe stand-in for `LabeledContent`.
struct LabeledRow<Value: View>: View {
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

extension LabeledRow where Value == Text {
    init(_ title: String, value: String) {
        self.init(title) { Text(value).foregroundColor(.secondary) }
    }
}

/// Whether the app process is currently in the foreground, in the sense that
/// matters for pausing network-heavy work. iOS suspends background execution
/// and expects that distinction to be honoured; the macOS build runs
/// continuously as a login-item agent with no such suspension, so it is
/// always considered active.
enum PlatformState {
    static var isApplicationActive: Bool {
#if os(iOS)
        UIApplication.shared.applicationState == .active
#else
        true
#endif
    }
}

/// The system pasteboard, one call across platforms.
enum Pasteboard {
    static func copy(_ string: String) {
#if os(iOS)
        UIPasteboard.general.string = string
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
#endif
    }
}

/// Human-readable OS version, for the About/Diagnostics screens.
enum PlatformVersion {
    static var name: String {
#if os(iOS)
        "iOS"
#else
        "macOS"
#endif
    }

    static var version: String {
#if os(iOS)
        UIDevice.current.systemVersion
#else
        ProcessInfo.processInfo.operatingSystemVersionString
#endif
    }
}

/// iOS Data Protection (`FileProtectionType`) has no macOS equivalent — macOS
/// relies on FileVault and per-user home-directory permissions instead, which
/// already apply to everything the app writes. A no-op there keeps every call
/// site identical across platforms.
func applyDataProtectionIfAvailable(atPath path: String) {
#if os(iOS)
    try? FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: path
    )
#endif
}

/// Opens the place a user grants (or fixes) photo-library access: the app's
/// own Settings page on iOS, the Photos pane of System Settings' Privacy &
/// Security on macOS.
enum PlatformPrivacySettings {
    static var url: URL? {
#if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
#else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")
#endif
    }
}
