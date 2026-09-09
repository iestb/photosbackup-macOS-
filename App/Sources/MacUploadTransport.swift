#if os(macOS)
import Foundation

/// Default file-upload transport for the macOS build. iOS needs a delegate-
/// driven background `URLSession` because the app can be suspended or
/// terminated mid-upload and relaunched by the system; macOS has no such
/// suspension here, since the app runs continuously as a login-item menu-bar
/// agent (see `MacBackgroundBackupAgent`). A plain, long-lived foreground
/// session is enough: uploads keep running for as long as the process does,
/// and the durable queue checkpoint picks up anything interrupted by a quit.
enum AppFileUploadTransport {
    static let shared: any FileUploadTransport = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 24 * 60 * 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = UploadQueue.concurrencyRange.upperBound
        let session = URLSession(configuration: configuration)
        return ForegroundFileUploadTransport(session: session)
    }()
}
#endif
