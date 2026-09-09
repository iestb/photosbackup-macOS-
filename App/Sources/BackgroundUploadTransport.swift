#if os(iOS)
import Foundation
import UIKit

/// The default file-upload transport for this platform. See
/// `MacUploadTransport.swift` for the macOS counterpart.
enum AppFileUploadTransport {
    static let shared: any FileUploadTransport = BackgroundFileUploadTransport.shared
}

/// Delegate-driven file transport owned for the lifetime of the process. The
/// URL session itself is owned by iOS, so PUTs keep running while the app is
/// suspended or terminated and are reattached by their queue-item UUID.
final class BackgroundFileUploadTransport: NSObject, FileUploadTransport, @unchecked Sendable {
    static let shared = BackgroundFileUploadTransport()
    static let sessionIdentifier = "com.g8row.photosbackup.background-upload"

    let continuesAfterProcessExit = true

    private struct StoredResult: Codable {
        let url: URL?
        let statusCode: Int?
        let headers: [String: String]
        let body: Data
        let errorCode: Int?
        let errorDescription: String?
    }

    private typealias Waiter = CheckedContinuation<FileUploadResult, Error>
    private let lock = NSLock()
    private let delegateQueue: OperationQueue
    private var waiters: [UUID: [Waiter]] = [:]
    private var progressHandlers: [UUID: @Sendable (Int64, Int64) -> Void] = [:]
    private var responseBodies: [Int: Data] = [:]
    private var starting: Set<UUID> = []
    private var discarded: Set<UUID> = []
    private var relaunchCompletions: [() -> Void] = []
    /// Last time each live transfer reported bytes on the wire, so a wedged
    /// task can be failed instead of sitting on "Uploading" forever.
    private var lastProgressAt: [UUID: Date] = [:]
    private var watchdog: Timer?
    private var eventsFinished = false
    private var eventsDrainer: (@Sendable () async -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 7 * 24 * 60 * 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        // A background session's configuration is fixed once the session
        // exists, so this has to allow for the widest concurrency the user can
        // choose. The queue is what actually limits how many run at a time.
        configuration.httpMaximumConnectionsPerHost = UploadQueue.concurrencyRange.upperBound
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private override init() {
        let queue = OperationQueue()
        queue.name = "PhotosBackup.BackgroundUploadDelegate"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        delegateQueue = queue
        super.init()
        // Do not create `session` here. On an iOS relaunch, UIKit must first
        // provide and let us store its completion handler in handleEvents().
        // Creating the session earlier can deliver all queued delegate messages
        // before that handler exists.
    }

    func upload(_ request: URLRequest, fromFile file: URL, transferID: UUID,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> FileUploadResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var shouldReconcile = false
                var wasCancelled = false
                lock.lock()
                if discarded.contains(transferID) {
                    wasCancelled = true
                } else {
                    waiters[transferID, default: []].append(continuation)
                    progressHandlers[transferID] = progress
                    if starting.insert(transferID).inserted { shouldReconcile = true }
                }
                lock.unlock()

                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let stored = loadResult(for: transferID) {
                    resolve(transferID, with: stored)
                } else if shouldReconcile {
                    noteProgress(for: transferID)
                    startWatchdogIfNeeded()
                    reconcileOrStart(request, file: file, transferID: transferID)
                }
            }
        } onCancel: {
            self.discardAndCancel(transferID: transferID)
        }
    }

    /// A transfer that has moved no bytes for this long is treated as wedged.
    /// The session's seven-day request timeout plus `waitsForConnectivity`
    /// means URLSession itself will never give up on it.
    private static let stallTimeout: TimeInterval = 15 * 60

    func cancel(transferID: UUID) async {
        discardAndCancel(transferID: transferID)
    }

    private func noteProgress(for transferID: UUID) {
        lock.lock()
        lastProgressAt[transferID] = Date()
        lock.unlock()
    }

    private func startWatchdogIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.watchdog == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.failStalledTransfers()
            }
            timer.tolerance = 15
            self.watchdog = timer
        }
    }

    private func stopWatchdogIfIdle() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let idle = self.lastProgressAt.isEmpty
            self.lock.unlock()
            guard idle else { return }
            self.watchdog?.invalidate()
            self.watchdog = nil
        }
    }

    private func failStalledTransfers() {
        let cutoff = Date().addingTimeInterval(-Self.stallTimeout)
        lock.lock()
        let stalled = lastProgressAt.filter { $0.value < cutoff }.map(\.key)
        for id in stalled { lastProgressAt[id] = nil }
        lock.unlock()
        for id in stalled {
            // Retryable on purpose: the queue backs off and tries again, and if
            // the real cause is a dead network its own policy pause holds it.
            resolve(id, with: StoredResult(
                url: nil, statusCode: nil, headers: [:], body: Data(),
                errorCode: URLError.timedOut.rawValue,
                errorDescription: "the upload stopped making progress"
            ))
            cancelTask(transferID: id)
        }
        stopWatchdogIfIdle()
    }

    func forget(transferID: UUID) async {
        try? FileManager.default.removeItem(at: resultURL(for: transferID))
        clearRuntimeState(for: transferID)
    }

    private func clearRuntimeState(for transferID: UUID) {
        lock.lock()
        waiters[transferID] = nil
        progressHandlers[transferID] = nil
        starting.remove(transferID)
        lastProgressAt[transferID] = nil
        lock.unlock()
        stopWatchdogIfIdle()
    }

    /// Installed by the composition root. iOS's relaunch completion is delayed
    /// until the durable receipt has had a chance to reach Google's commit RPC.
    func setEventsDrainer(_ drainer: @escaping @Sendable () async -> Void) {
        lock.lock()
        eventsDrainer = drainer
        lock.unlock()
        finishRelaunchIfPossible()
    }

    func handleEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        eventsFinished = false
        relaunchCompletions.append(completionHandler)
        lock.unlock()
        _ = session
        finishRelaunchIfPossible()
    }

    private func reconcileOrStart(_ request: URLRequest, file: URL, transferID: UUID) {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            if let task = tasks.first(where: { $0.taskDescription == transferID.uuidString }) {
                self.lock.lock()
                let shouldDiscard = self.discarded.contains(transferID)
                self.starting.remove(transferID)
                let reporter = self.progressHandlers[transferID]
                self.lock.unlock()
                if shouldDiscard {
                    task.cancel()
                    return
                }
                reporter?(task.countOfBytesSent, max(task.countOfBytesExpectedToSend, task.countOfBytesSent))
                if task.state == .suspended { task.resume() }
                return
            }

            guard FileManager.default.fileExists(atPath: file.path) else {
                self.resolve(transferID, with: StoredResult(
                    url: request.url, statusCode: nil, headers: [:], body: Data(),
                    errorCode: NSFileNoSuchFileError,
                    errorDescription: "The staged upload file is missing."
                ))
                return
            }
            self.lock.lock()
            let wasDiscarded = self.discarded.contains(transferID)
            if wasDiscarded {
                self.starting.remove(transferID)
                self.discarded.remove(transferID)
            }
            self.lock.unlock()
            guard !wasDiscarded else { return }
            // Create outside the lock: `uploadTask(with:fromFile:)` must not
            // run while holding `lock`. `starting` still contains the ID, so a
            // concurrent cancel either finds this task via `getAllTasks` or
            // leaves its marker for the re-check below.
            let task = self.session.uploadTask(with: request, fromFile: file)
            task.taskDescription = transferID.uuidString
            self.lock.lock()
            let racedDiscard = self.discarded.contains(transferID)
            self.starting.remove(transferID)
            self.lock.unlock()
            if racedDiscard {
                task.cancel()
                return
            }
            task.resume()
        }
    }

    private func cancelTask(transferID: UUID) {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            if let task = tasks.first(where: { $0.taskDescription == transferID.uuidString }) {
                task.cancel()
                return
            }
            self.lock.lock()
            if !self.starting.contains(transferID) {
                self.discarded.remove(transferID)
            }
            self.lock.unlock()
        }
    }

    private func discardAndCancel(transferID: UUID) {
        try? FileManager.default.removeItem(at: resultURL(for: transferID))
        lock.lock()
        discarded.insert(transferID)
        let continuations = waiters.removeValue(forKey: transferID) ?? []
        progressHandlers[transferID] = nil
        lastProgressAt[transferID] = nil
        lock.unlock()
        stopWatchdogIfIdle()
        // Checked continuations are not resumed automatically when their Swift
        // task is cancelled. Always release callers before discarding the URL
        // session delegate completion, otherwise UploadQueue.running can retain
        // the worker forever and block every subsequent account.
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        cancelTask(transferID: transferID)
    }

    /// Turn a URL-loading failure into something a failed row can be acted on.
    /// `localizedDescription` is "unknown error" for `NSURLErrorUnknown`, which
    /// is exactly the code the Simulator returns for every background-session
    /// upload — background sessions are not supported there, so a row that says
    /// only "unknown error" sends you hunting for a bug that is not in the app.
    static func describeFailure(_ detail: String, code: Int?) -> String {
        let vague = detail.isEmpty || detail.localizedCaseInsensitiveContains("unknown error")
        guard vague else { return "Could not reach Google: \(detail)" }
#if targetEnvironment(simulator)
        if code == NSURLErrorUnknown {
            return "The Simulator cannot run background uploads. Try this on a device."
        }
#endif
        guard let code else { return "Could not reach Google: the upload failed." }
        return "Could not reach Google: URLError \(code)."
    }

    private func resolve(_ transferID: UUID, with stored: StoredResult) {
        lock.lock()
        let continuations = waiters.removeValue(forKey: transferID) ?? []
        progressHandlers[transferID] = nil
        starting.remove(transferID)
        lastProgressAt[transferID] = nil
        lock.unlock()
        stopWatchdogIfIdle()
        guard !continuations.isEmpty else { return }

        let outcome: Result<FileUploadResult, Error>
        if stored.errorCode == NSURLErrorCancelled {
            outcome = .failure(CancellationError())
        } else if let detail = stored.errorDescription {
            outcome = .failure(GPMCError(kind: .transport,
                                         message: Self.describeFailure(detail, code: stored.errorCode)))
        } else if let url = stored.url, let status = stored.statusCode,
                  let response = HTTPURLResponse(url: url, statusCode: status,
                                                 httpVersion: "HTTP/1.1", headerFields: stored.headers) {
            outcome = .success(FileUploadResult(data: stored.body, response: response))
        } else {
            outcome = .failure(GPMCError(message: "Invalid server response."))
        }
        for continuation in continuations { continuation.resume(with: outcome) }
    }

    private var resultsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotosBackup", isDirectory: true)
            .appendingPathComponent("BackgroundUploadResults", isDirectory: true)
    }

    private func resultURL(for transferID: UUID) -> URL {
        resultsDirectory.appendingPathComponent(transferID.uuidString).appendingPathExtension("json")
    }

    private func loadResult(for transferID: UUID) -> StoredResult? {
        try? JSONDecoder().decode(StoredResult.self, from: Data(contentsOf: resultURL(for: transferID)))
    }

    private func store(_ result: StoredResult, for transferID: UUID) {
        do {
            try FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
            let url = resultURL(for: transferID)
            try JSONEncoder().encode(result).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            // A live waiter still receives the result below. If there is no live
            // waiter, the queue checkpoint deliberately remains and retries PUT.
        }
    }

    private func finishRelaunchIfPossible() {
        lock.lock()
        guard eventsFinished, !relaunchCompletions.isEmpty, let drainer = eventsDrainer else {
            lock.unlock()
            return
        }
        eventsFinished = false
        let completions = relaunchCompletions
        relaunchCompletions = []
        lock.unlock()
        Task {
            await drainer()
            await MainActor.run { completions.forEach { $0() } }
        }
    }
}

extension BackgroundFileUploadTransport: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard let value = task.taskDescription, let transferID = UUID(uuidString: value) else { return }
        noteProgress(for: transferID)
        lock.lock()
        let reporter = progressHandlers[transferID]
        lock.unlock()
        reporter?(totalBytesSent, max(totalBytesExpectedToSend, totalBytesSent))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let value = task.taskDescription, let transferID = UUID(uuidString: value) else { return }
        lock.lock()
        let body = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        let shouldDiscard = discarded.remove(transferID) != nil
        lock.unlock()
        if shouldDiscard { return }
        let http = task.response as? HTTPURLResponse
        let headers = http?.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key)] = String(describing: pair.value)
        } ?? [:]
        let urlError = error as? URLError
        let stored = StoredResult(
            url: http?.url ?? task.originalRequest?.url,
            statusCode: http?.statusCode,
            headers: headers,
            body: body,
            errorCode: urlError?.errorCode,
            errorDescription: error?.localizedDescription
        )
        store(stored, for: transferID)
        resolve(transferID, with: stored)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        eventsFinished = true
        lock.unlock()
        finishRelaunchIfPossible()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundFileUploadTransport.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundFileUploadTransport.shared.handleEvents(completionHandler: completionHandler)
    }
}
#endif
