import Foundation

/// Composition root for the Google Photos side. Builds the account, the
/// exporter and the queue already wired to each other, so the app entry point
/// only has to hold on to two objects.
@MainActor
final class PhotosStack {
    let account: PhotosAccount
    let queue: UploadQueue
    private let exporter: MediaExporter
    private let transferGate: TransferGate
    private var startTask: Task<Void, Never>?

    init(store: CredentialStore = CredentialStore(), exporter: MediaExporter = MediaExporter()) {
        let account = PhotosAccount(store: store)
        let transferGate = TransferGate(limit: 5)
        let uploader = PhotosUploader(exporter: exporter, client: { await account.currentClient() },
                                     transferGate: transferGate)
        self.account = account
        self.exporter = exporter
        self.transferGate = transferGate
        self.queue = UploadQueue(worker: uploader.worker(), persistence: FileUploadQueuePersistence(),
                                 checkpointCleaner: uploader.checkpointCleaner())
        self.queue.onCredentialRejected = { [weak account] error in account?.report(error) }
    }

    /// How many uploads may have file bytes actively moving at once — see
    /// `TransferGate`. Independent of `queue.setMaxConcurrent`, which caps
    /// how many items are simultaneously being checked/exported/hashed.
    func setMaxConcurrentTransfers(_ value: Int) {
        transferGate.setLimit(value)
    }

    /// Restore the saved account and then sweep only staging files that no
    /// durable queue checkpoint still owns.
    ///
    /// The memoised task must cover *every* step, not just `account.restore()`.
    /// A second caller that returned after only the restore would go on to
    /// inspect a queue that had not been activated yet — on a background-session
    /// relaunch that means `waitUntilBackgroundTransfersHandled()` sees an empty
    /// queue, resolves immediately, and iOS's completion handler fires before a
    /// completed PUT's receipt ever reaches the commit RPC.
    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { @MainActor [account, queue, exporter] in
            await account.restore()
            queue.activateAccount(account.status.email)
            await exporter.purge(excluding: queue.retainedStagingURLs)
        }
        startTask = task
        await task.value
    }

    /// Hand a finished exchange to the account, then let the queue carry on.
    func connect(_ result: TokenExchange.Result) async {
        await account.connect(result)
        queue.activateAccount(account.status.email)
        if account.status.isUsable { queue.resume() }
    }

    func setCellularUploadsAllowed(_ allowed: Bool) {
        account.setCellularUploadsAllowed(allowed)
    }
}
