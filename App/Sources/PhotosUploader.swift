import Foundation

/// Serialises and rate-limits the phase callbacks `GPMCClient` fires
/// synchronously from its hashing loop and its `URLSessionTaskDelegate`.
///
/// The previous `Task { await emit(...) }` per callback spawned one unstructured
/// task per progress tick — thousands for a large video — and unstructured tasks
/// carry no ordering guarantee, so a later fraction could be applied before an
/// earlier one and the bar would visibly jump backwards. A single consumer keeps
/// the order, and coalescing to the newest pending state keeps the main actor
/// out of a hot loop it gains nothing from.
final class UploadPhaseRelay: @unchecked Sendable {
    /// How often a *single* item may report progress, set by `PhotosStack`
    /// from the current concurrency.
    ///
    /// Every report mutates the queue's `@Published` items, and that
    /// invalidates every view observing the queue — not just the row that
    /// moved. A fixed per-item rate therefore costs (rate × concurrency)
    /// whole-UI invalidations a second, which at the concurrency a first
    /// macOS reconcile wants is hundreds. Progress fractions are cosmetic, so
    /// the per-item rate drops as concurrency rises; phase changes still
    /// arrive immediately via `flush()`, which ignores the interval.
    static let reportInterval = IntervalBox(0.1)

    /// A relay's interval is fixed at init, and relays are created per item,
    /// so a change takes effect on the next item to start rather than
    /// mid-upload. That is deliberate: nothing here is worth a lock on the
    /// progress path.
    static func interval(forConcurrency concurrency: Int) -> TimeInterval {
        min(0.75, max(0.1, 0.025 * Double(concurrency)))
    }

    final class IntervalBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval

        init(_ value: TimeInterval) { self.value = value }

        var current: TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func set(_ newValue: TimeInterval) {
            lock.lock(); value = newValue; lock.unlock()
        }
    }

    private let lock = NSLock()
    private var pending: UploadItem.State?
    private var lastSentAt = Date.distantPast
    private var draining = false
    private var stopped = false
    private let emit: UploadEventSink
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.1, emit: @escaping UploadEventSink) {
        self.interval = interval
        self.emit = emit
    }

    /// Safe to call from any thread, including a delegate queue.
    func report(_ state: UploadItem.State) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        pending = state
        let shouldStart = !draining
        if shouldStart { draining = true }
        lock.unlock()
        guard shouldStart else { return }
        Task { await self.drain() }
    }

    /// Flush whatever is pending, ignoring the rate limit. Used for the phase
    /// changes that matter for the row's meaning rather than its percentage.
    /// Drop anything still pending and refuse further reports. Called once the
    /// worker has a terminal outcome, so a late progress tick cannot land on a
    /// row that has already moved on.
    func stop() {
        lock.lock()
        stopped = true
        pending = nil
        lock.unlock()
    }

    func flush() async {
        let state: UploadItem.State?
        lock.lock()
        state = pending
        pending = nil
        lastSentAt = Date()
        lock.unlock()
        if let state { await emit(.state(state)) }
    }

    private func drain() async {
        while true {
            let wait: TimeInterval
            let state: UploadItem.State?
            lock.lock()
            let elapsed = Date().timeIntervalSince(lastSentAt)
            if elapsed >= interval, let next = pending {
                state = next
                pending = nil
                lastSentAt = Date()
                wait = 0
            } else if pending != nil {
                state = nil
                wait = max(0, interval - elapsed)
            } else {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()
            if let state { await emit(.state(state)) }
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
    }
}

/// Caps how many uploads may have file bytes actively moving (the PUT
/// transfer and the small commit that finalizes it) at once — independent of
/// `UploadQueue.maxConcurrent`, which caps how many items are simultaneously
/// being exported/hashed/duplicate-checked. That earlier stage is cheap
/// network-metadata work (or nothing at all, for an item already backed up),
/// so a queue reconciling a large library benefits from a high number there.
/// The transfer stage is bandwidth-bound: the same high number applied to
/// actual multi-megabyte file transfers saturates a typical upload
/// connection, and everything — including the small "finishing" commit call
/// for an item whose bytes already went through — crawls. Without the split,
/// one concurrency setting could never be right for both phases at once.
///
/// A plain lock-based class, not an actor: `release()` needs to be callable
/// synchronously from a `defer`, which can't `await` an actor hop.
final class TransferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        let clamped = max(1, limit)
        self.limit = clamped
        self.available = clamped
    }

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if available > 0 {
                available -= 1
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume()
        } else {
            available = min(limit, available + 1)
            lock.unlock()
        }
    }

    /// Live setting changes, same philosophy as `UploadQueue.setMaxConcurrent`:
    /// raising the limit wakes waiters immediately; lowering it never
    /// preempts a transfer already in flight, it just stops handing out new
    /// permits until usage falls back within the new limit.
    func setLimit(_ newLimit: Int) {
        lock.lock()
        let clamped = max(1, newLimit)
        let delta = clamped - limit
        limit = clamped
        guard delta > 0 else {
            available = max(0, available + delta)
            lock.unlock()
            return
        }
        available += delta
        var toWake: [CheckedContinuation<Void, Never>] = []
        while available > 0, !waiters.isEmpty {
            toWake.append(waiters.removeFirst())
            available -= 1
        }
        lock.unlock()
        toWake.forEach { $0.resume() }
    }
}

/// The one real `UploadWorker`: export the item to a file, hand it to
/// `GPMCClient`, and retain it across retry/relaunch boundaries until the
/// transfer commits or reaches a terminal state.
///
/// Kept separate from `UploadQueue` so the queue's state machine can be tested
/// with a stub worker and no photo library, network or credential in sight.
struct PhotosUploader {
    let exporter: MediaExporter
    /// Resolved per item rather than captured, so a reconnect swaps the client
    /// under a queue that is already running.
    let client: @Sendable () async -> GPMCClient?
    let transferGate: TransferGate

    func worker() -> UploadWorker {
        let exporter = self.exporter
        let client = self.client
        let transferGate = self.transferGate
        return { id, source, restoredCheckpoint, options, emit in
            let relay = UploadPhaseRelay(interval: UploadPhaseRelay.reportInterval.current, emit: emit)
            defer { relay.stop() }
            guard let client = await client() else {
                throw GPMCError(kind: .credentialRejected, message: "No Google account is connected. Connect one and try again.")
            }
            var checkpoint = restoredCheckpoint
            if let restoredCheckpoint,
               !FileManager.default.fileExists(atPath: restoredCheckpoint.filePath) {
                checkpoint = nil
                await emit(.checkpoint(nil))
            }
            if checkpoint == nil {
                await emit(.state(.exporting))
                let media = try await exporter.export(source, allowsNetworkAccess: options.allowsICloudDownload)
                checkpoint = UploadCheckpoint(
                    filePath: media.url.standardizedFileURL.path,
                    filename: media.filename,
                    modified: media.modified,
                    byteCount: media.byteCount,
                    temporary: media.temporary,
                    prepared: nil,
                    continuesAfterProcessExit: await client.usesBackgroundFileTransfers
                )
                await emit(.described(name: media.filename, byteCount: media.byteCount))
                await emit(.checkpoint(checkpoint))
            }
            guard var checkpoint else {
                throw GPMCError(message: "Could not stage the upload.")
            }
            try Task.checkCancellation()

            if checkpoint.prepared == nil {
                let preparation = try await client.prepareUpload(
                    file: checkpoint.fileURL,
                    filename: checkpoint.filename,
                    modified: checkpoint.modified
                ) { phase in
                    relay.report(phase.itemState)
                }
                await relay.flush()
                switch preparation {
                case .alreadyBackedUp(let mediaKey):
                    await exporter.discard(checkpoint.exportedMedia)
                    await emit(.checkpoint(nil))
                    return .alreadyBackedUp(mediaKey: mediaKey)
                case .ready(let prepared):
                    checkpoint.prepared = prepared
                    // This write is the hand-off: after it returns, relaunch can
                    // safely find the body and reattach to the task by `id`.
                    await emit(.checkpoint(checkpoint))
                }
            }

            guard let prepared = checkpoint.prepared else {
                throw GPMCError(message: "Could not prepare the upload.")
            }
            // Only the transfer + commit below need the gate: everything
            // above this point (export, hashing, the duplicate check) is
            // cheap network-metadata work or nothing at all, so it stays
            // gated only by UploadQueue.maxConcurrent, same as before.
            await transferGate.acquire()
            defer { transferGate.release() }
            let completed: PreparedUpload
            do {
                completed = try await client.transfer(prepared, file: checkpoint.fileURL, transferID: id,
                                                      foreground: checkpoint.continuesAfterProcessExit == false) { phase in
                    relay.report(phase.itemState)
                }
                await relay.flush()
            } catch {
                await client.forgetTransfer(id)
                // A failed upload URL may no longer be reusable. Keep the
                // expensive staged body, but obtain a fresh upload ID on retry.
                checkpoint.prepared = nil
                if (error as? GPMCError)?.kind == .invalidUploadReceipt {
                    // Persist the fallback so a relaunch does not send the
                    // retry through the same background transport again.
                    checkpoint.continuesAfterProcessExit = false
                    checkpoint.retriedAfterInvalidReceipt = true
                }
                await emit(.checkpoint(checkpoint))
                throw error
            }
            checkpoint.prepared = completed
            await emit(.checkpoint(checkpoint))

            let outcome: UploadOutcome
            do {
                // Read from `options`, not from `completed`: a checkpoint
                // restored from an earlier session predates any toggle the user
                // has flipped since, and the committed policy has to be the
                // current one.
                outcome = try await client.commit(completed,
                                                  useQuota: options.useQuota,
                                                  saver: options.storageSaver) { phase in
                    relay.report(phase.itemState)
                }
            } catch let error as GPMCError where error.kind == .invalidUploadReceipt {
                await client.forgetTransfer(id)
                checkpoint.prepared = nil
                checkpoint.continuesAfterProcessExit = false
                // One recovery per item. Google rejects the commit arguments
                // for more than a stale upload token, and a rejection that
                // survives a fresh preflight and transfer is one of those —
                // re-uploading the bytes again would not fix it either.
                guard checkpoint.retriedAfterInvalidReceipt != true else {
                    await emit(.checkpoint(checkpoint))
                    throw GPMCError(kind: .malformed, message: error.message, status: error.status)
                }
                checkpoint.retriedAfterInvalidReceipt = true
                await emit(.checkpoint(checkpoint))
                throw error
            }
            await relay.flush()
            await client.forgetTransfer(id)
            await exporter.discard(checkpoint.exportedMedia)
            await emit(.checkpoint(nil))
            return outcome
        }
    }

    func checkpointCleaner() -> UploadCheckpointCleaner {
        let exporter = self.exporter
        let client = self.client
        return { id, checkpoint in
            if let client = await client() { await client.cancelTransfer(id) }
            else { await AppFileUploadTransport.shared.cancel(transferID: id) }
            await exporter.discard(checkpoint.exportedMedia)
        }
    }
}

private extension UploadCheckpoint {
    var exportedMedia: ExportedMedia {
        ExportedMedia(url: fileURL, filename: filename, modified: modified,
                      byteCount: byteCount, temporary: temporary)
    }
}

extension UploadPhase {
    /// Byte-level client progress mapped onto the row states the activity list shows.
    var itemState: UploadItem.State {
        switch self {
        case .hashing(let fraction): return .hashing(fraction: fraction)
        case .checkingDuplicate: return .checkingDuplicate
        case .preparing: return .uploading(fraction: 0)
        case .sending(let sent, let total): return .uploading(fraction: total > 0 ? min(1, Double(sent) / Double(total)) : 0)
        case .finalizing: return .finalizing
        }
    }
}
