# Photos Backup for iOS and macOS

<p align="center">
  <img src="App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="160" alt="Photos Backup app icon">
</p>

An experimental, fully on-device app for backing up selected photos, videos,
and albums to Google Photos, for iPhone and, as of this fork, Mac. It is a
single SwiftUI codebase, shared between an iOS app and a macOS menu-bar
agent, that completes Google account setup in an in-app web view — so
everything happens on-device without a separate desktop companion or hosted
service. See [macOS](#macos) below for what differs between the two builds.

> [!WARNING]
> This project uses Google's private, undocumented Photos endpoints and an
> Android-style authentication flow. It is not affiliated with or endorsed by
> Google, and the integration may stop working without notice. Treat it as
> experimental software and use it at your own risk.

## What it can do

- Connect a Google account through Google's EmbeddedSetup flow, in an in-app web view.
- Capture the single-use `oauth_token` in-process from the web view's cookie store.
- Exchange the token for a Google Photos credential entirely on the device.
- Select albums from the local Photos library.
- Queue individual photos, videos, or all items in selected albums.
- Show hashing, duplicate-check, upload, and finalization progress per item.
- Avoid re-uploading media already present in Google Photos.
- Retry transient failures, cancel work, and resume after reconnecting.
- Show why an upload failed in Google's own words, copyable from the row and
  from Diagnostics, and stop the queue when the Google account is out of space.
- Restore pending album uploads after an app restart and remember completed
  library assets per Google account.
- Show per-album backup progress, and re-upload assets edited after backup.
- Upload in original quality or request Google's Storage Saver processing.
- Choose how many uploads run at once, from 1 to 10.
- Enforce Wi-Fi-only or Wi-Fi-and-cellular policy at queue and request level,
  cancelling in-flight background transfers when the allowed transport is lost.
- Request recurring iOS background-processing windows for selected-album backup.
- Keep file PUTs running in an iOS-owned background `URLSession`, then commit
  completed receipts when iOS relaunches the app.
- Track PhotoKit persistent changes on iOS 16+ so backdated imports are found.
- Store usable long-lived credentials in the iOS Keychain when signing permits.

## Current status

The complete authentication path has been proven on an iOS 17 device and
simulator: the in-app web view receives the `oauth_token`, the app reads it from
the web view's own cookie store, exchanges it for an unbound master token and
Photos credential, and an authenticated `photosdata-pa` request succeeds.

The Xcode project, app target, and scheme are named `PhotosBackup`; the
user-facing app is named **Photos Backup**.

Latest release: **0.3.5** ([releases](https://github.com/g8row/PhotosBackup/releases)).
132 tests run on an iPhone simulator: 130 pass, with 2 opt-in live tests
skipped.

### App identity (since 0.0.2)

| Piece | Value |
| --- | --- |
| App bundle ID | `com.g8row.photosbackup` |
| Background task | `com.g8row.photosbackup.background-backup` |
| Background upload session | `com.g8row.photosbackup.background-upload` |

> [!IMPORTANT]
> The bundle ID and Keychain service changed in 0.0.2. After updating from an
> older build, reconnect the Google account once, then force-quit and reopen
> to confirm it stays connected.

## Requirements

- macOS with Xcode 16.4 and an installed iOS Simulator runtime
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.40 or newer
- iOS 15.0 or newer
- A Google account for the live connection flow
- For a physical device: an Apple signing identity, or a sideloading tool such
  as SideStore or AltStore

Install XcodeGen with Homebrew if needed:

```sh
brew install xcodegen
```

## Build and run

Generate the Xcode project:

```sh
xcodegen generate
open PhotosBackup.xcodeproj
```

Select the `PhotosBackup` scheme and an iPhone simulator in Xcode, then run the
app. A command-line simulator build also works:

```sh
xcodebuild \
  -project PhotosBackup.xcodeproj \
  -scheme PhotosBackup \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For a signed device build, set `DEVELOPMENT_TEAM` in `project.yml`, regenerate
the project, and let Xcode manage signing.

### macOS

`xcodegen generate` also produces a `PhotosBackupMac` target and scheme,
sharing all of `App/Sources` and `GPMC/Core` with the iOS app. Select the
`PhotosBackupMac` scheme and run:

```sh
xcodebuild \
  -project PhotosBackup.xcodeproj \
  -scheme PhotosBackupMac \
  -destination 'platform=macOS' \
  build
```

The macOS build is sandboxed (`App/Resources/PhotosBackupMac.entitlements`)
and reads its own `App/Resources/Info-macOS.plist`. It differs from the iOS
app in three places where iOS APIs have no macOS equivalent:

- **Photo picker.** macOS has no `PHPickerViewController`, so `PhotoPicker`
  is a native SwiftUI grid backed directly by `PHPhotoLibrary` there instead.
- **Automatic backup scheduling.** There is no `BGTaskScheduler` on macOS.
  The app instead runs continuously as a menu-bar accessory that can launch
  at login (`LoginItemManager`, via `SMAppService`), and
  `AutomaticBackupCoordinator` re-scans the library on a periodic in-process
  timer instead of an OS-scheduled processing window.
- **Uploads.** iOS uses a delegate-driven background `URLSession` so uploads
  survive suspension/termination. macOS uses the existing
  `ForegroundFileUploadTransport` on a long-lived session, since the app is
  expected to keep running as a background agent instead.

This macOS port has not been built or run on an actual Mac/Xcode yet — it
was written and reviewed without one available. Treat the first build as a
bring-up: check the console for anything the compiler or `xcodegen`
disagrees with.

### Test background execution

Debug builds expose **Settings → Diagnostics → Simulate Background Run**. This
runs the same scan/enqueue/wait path immediately and is the fastest normal test
loop.

To exercise the actual `BGProcessingTask` launch handler on a connected device,
run the app from Xcode, background it, pause the debugger, and enter this in the
LLDB console:

```text
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.g8row.photosbackup.background-backup"]
```

The Diagnostics screen also has a button that copies this command.

### Build an unsigned IPA

The repository includes a packaging script for SideStore/AltStore-style
sideloading:

```sh
./Scripts/make-ipa.sh
```

The script defaults to `DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer`.
Override it only if Xcode lives elsewhere:

```sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer ./Scripts/make-ipa.sh
```

The unsigned package is written to `build/PhotosBackup.ipa`. The sideloading
tool re-signs it with the Apple ID configured on the device.

## Install via SideStore

Prebuilt unsigned IPAs are attached to each
[GitHub release](https://github.com/g8row/PhotosBackup/releases).

> [!TIP]
> On your iPhone (with SideStore or AltStore installed), one-tap install of
> the latest release:
>
> - **[Install Photos Backup](https://g8row.github.io/PhotosBackup/install.html)** —
>   open on the iPhone and tap Install with SideStore / AltStore.
>
> GitHub strips custom `sidestore://` / `altstore://` URL schemes in markdown,
> so the buttons live on that page instead of directly in this README. It
> installs
> `https://github.com/g8row/PhotosBackup/releases/latest/download/PhotosBackup.ipa`.

- AirDrop `PhotosBackup.ipa` to the iPhone and save it in Files.
- Turn on LocalDevVPN.
- In SideStore, tap +, choose `PhotosBackup.ipa`, and install it.
- After updating across the 0.0.2 bundle-ID change, reconnect the Google
  account once.

## Connect a Google account

1. Install and launch Photos Backup.
2. In onboarding (or Settings → Connect Account), tap **Connect Google Account**.
3. Sign in and accept Google's consent prompt in the in-app window. The page may
   remain on a spinner afterward; that is expected — the app captures the token
   and closes the window on its own.
4. Grant the desired Photos access and select albums.

The captured `oauth_token` is single-use and is read once from the web view's
cookie store, then the web session is discarded.

## Authentication and credential handling

The normal flow is:

```text
In-app EmbeddedSetup web view
        │  oauth_token (read from WKHTTPCookieStore)
        ▼
Android master token → Photos access token → private Photos API
```

- The exchange runs locally; there is no companion backend.
- Credentials are stored as a single Keychain item using
  `AfterFirstUnlockThisDeviceOnly` when Keychain access is available.
- Exported Photos-library items are staged in protected Application Support,
  retained while a background transfer owns them, and removed afterward.
- The `oauth_token` is read in-process from the app's own non-persistent web
  view cookie store; it never leaves the app via an extension, App Group, or
  custom URL scheme.
- Bound/encrypted Google tokens are rejected because token binding is not
  implemented.

## Known limitations

- Google can change or disable the private authentication and Photos endpoints.
- Live Photos currently upload only their still image; the motion component is
  ignored.
- Background album backup is opportunistic: iOS decides when each processing
  request runs and may delay it based on usage, battery, and system policy.
- Background scans enqueue bounded batches of 250. The limit bounds memory, not
  how much a window uploads: the queue is durable, so whatever a window cannot
  finish waits for the next one. Foreground scans and the manual Back Up Now and
  Re-check Backups buttons queue the whole selection at once, so the count they
  report is the full run and the queue's concurrency setting decides how much of
  it moves at a time.
  iOS 16+ background scans use a persistent PhotoKit change token; iOS 15 and
  expired-token recovery use a correctness-first current-library scan. The token
  advances once a scan's sources have all been handed to the queue, so a
  saturated queue stops re-enumerating the library on every window.
- Export, hashing, duplicate lookup, and upload initialization still need an
  execution window. Once initialized, the file PUT continues under iOS even if
  the processing window expires; the app persists the receipt before commit.
- Cloud-only PhotoKit resources are deferred during short background processing
  windows and resume with network access when the app is foregrounded.
- Unsigned simulator builds cannot persist the credential in the Keychain.
  Free personal-team builds normally expire after seven days and must be
  refreshed.
- Google accounts that receive a bound/encrypted master token are unsupported.
- This is not an App Store-ready release.

## Tests

Run the offline unit test suite against any installed simulator:

```sh
xcodebuild \
  -project PhotosBackup.xcodeproj \
  -scheme PhotosBackup \
  -destination 'platform=iOS Simulator,name=<your simulator>' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

List available simulator names with:

```sh
xcrun simctl list devices available
```

Live tests are opt-in because they contact Google. The full exchange test also
requires a fresh, single-use `oauth_token`:

```sh
TEST_RUNNER_GPMC_LIVE=1 \
xcodebuild ... test \
  -only-testing:PhotosBackupTests/LiveExchangeTests/testInvalidTokenIsRejectedByGoogleNotByUs

TEST_RUNNER_GPMC_LIVE=1 \
TEST_RUNNER_GPMC_OAUTH_TOKEN=oauth_XXXX \
xcodebuild ... test \
  -only-testing:PhotosBackupTests/LiveExchangeTests/testFullExchangeWithRealToken
```

Never commit tokens or captured account credentials.

## Repository layout

```text
App/Sources/                  SwiftUI app, onboarding, account, and upload queue
App/Sources/AutomaticBackupCoordinator.swift  BGProcessingTask scheduling
App/Sources/BackgroundUploadTransport.swift   Relaunch-safe file PUT transport
App/Sources/PhotoLibraryChangeTracker.swift   Persistent PhotoKit scan token
App/Sources/NetworkPolicy.swift               Wi-Fi-only / cellular enforcement
App/Sources/UploadQueuePersistence.swift      Durable account-scoped queue
App/Resources/                Info.plist and app icon assets
App/Sources/AccountConnectWebView.swift       In-app EmbeddedSetup web view
GPMC/Core/                    Photos protocol client and protobuf helpers
Tests/PhotosBackupTests/      Offline unit tests and gated live tests
Scripts/make-ipa.sh           Unsigned IPA packaging
docs/                         Feasibility log and authentication ADR
project.yml                   XcodeGen project definition
```

For implementation history and protocol details, see:

- [`docs/ADR-001-auth-route.md`](docs/ADR-001-auth-route.md)
- [`docs/feasibility-probe.md`](docs/feasibility-probe.md)

## Acknowledgements

The protocol work is based on [GPMC by xob0t](https://github.com/xob0t/gpmc),
and the browser authentication route is based on gotohp. The pinned upstream
revisions and design rationale are recorded in the authentication ADR.

## License

This project is available under the [MIT License](LICENSE).
