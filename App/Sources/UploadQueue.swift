import Foundation
import SwiftUI

struct UploadOptions: Equatable, Sendable {
    /// Upload against the account's storage quota rather than as a device backup.
    var useQuota = false
    /// Ask Google to re-encode ("Storage saver") instead of keeping the original.
    var storageSaver = false
    /// Background processing must never spend its short CPU window downloading
    /// a cloud-only PhotoKit resource. Foreground work may opt back in.
    var allowsICloudDownload = true
}

/// One row of the activity list.
struct UploadItem: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case queued
        case waitingToRetry(attempt: Int)
        case waitingForICloud
        case exporting
        case hashing(fraction: Double)
        case checkingDuplicate
        case uploading(fraction: Double)
        case finalizing
        case alreadyBackedUp
        case done
        case cancelled
        case failed(reason: String, retryable: Bool)

        var isFinished: Bool {
            switch self {
            case .alreadyBackedUp, .done, .cancelled, .failed: return true
            default: return false
            }
        }
        var isWorking: Bool {
            switch self {
            case .exporting, .hashing, .checkingDuplicate, .uploading, .finalizing: return true
            default: return false
            }
        }
        /// 0…1 for a progress bar; nil where there is nothing meaningful to show.
        var fraction: Double? {
            switch self {
            case .hashing(let f): return f * 0.1
            case .checkingDuplicate: return 0.1
            case .uploading(let f): return 0.1 + f * 0.85
            case .finalizing: return 0.95
            case .alreadyBackedUp, .done: return 1
            default: return nil
            }
        }
        var label: String {
            switch self {
            case .queued: return "Waiting"
            case .waitingToRetry(let attempt): return "Retrying (attempt \(attempt + 1))"
            case .waitingForICloud: return "Will download from iCloud when you open the app"
            case .exporting: return "Preparing"
            case .hashing: return "Checking"
            case .checkingDuplicate: return "Looking for a copy"
            case .uploading: return "Uploading"
            case .finalizing: return "Finishing"
            case .alreadyBackedUp: return "Already backed up"
            case .done: return "Backed up"
            case .cancelled: return "Cancelled"
            case .failed(let reason, _): return reason
            }
        }
    }

    let id: UUID
    let source: MediaSource
    var name: String
    var byteCount: Int64
    var state: State
    var attempts: Int
    var mediaKey: String?
    var checkpoint: UploadCheckpoint?

    init(id: UUID = UUID(), source: MediaSource, name: String = "Preparing…") {
        self.id = id; self.source = source; self.name = name
        byteCount = 0; state = .queued; attempts = 0
    }
}

/// What a worker tells the queue while it runs one item.
enum UploadEvent: Equatable, Sendable {
    case described(name: String, byteCount: Int64)
    case state(UploadItem.State)
    case checkpoint(UploadCheckpoint?)
}

typealias UploadEventSink = @Sendable (UploadEvent) async -> Void
typealias UploadWorker = @Sendable (UUID, MediaSource, UploadCheckpoint?, UploadOptions, @escaping UploadEventSink) async throws -> UploadOutcome
typealias UploadCheckpointCleaner = @Sendable (UUID, UploadCheckpoint) async -> Void

private extension MediaSource {
    /// Album scans can contain the same asset through multiple selected albums.
    /// Stable keys keep automatic enqueue linear even for large libraries.
    var queueDeduplicationKey: String? {
        switch self {
        case .asset(let identifier): return "asset:\(identifier)"
        case .file(let url): return "file:\(url.standardizedFileURL.path)"
        case .picked: return nil
        }
    }
}

/// One failure, kept after its row is gone so support has something to read.
struct UploadFailure: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let name: String
    let reason: String
    /// `google.rpc.Code` when Google sent one, for a reader who needs the
    /// canonical code rather than the prose.
    let statusCode: Int?

    var summary: String {
        let stamp = date.formatted(date: .omitted, time: .standard)
        return statusCode.map { "\(stamp)  \(name)  [code \($0)]  \(reason)" }
            ?? "\(stamp)  \(name)  \(reason)"
    }
}

/// The activity queue: a bounded number of items in flight, per-item progress,
/// cancellation, and retry with backoff.
///
/// Retry deliberately does *not* re-do what `GPMCClient` already handles — that
/// actor refreshes an access token that is near expiry and spends one forced
/// re-auth on a mid-flight 401/403. What is left over, and lives here, is the
/// whole-item retry for transport and 5xx failures, and the hard stop when the
/// credential itself is refused: no other item in the queue can succeed either,
/// so the queue halts and waits for the account to be reconnected.
@MainActor
final class UploadQueue: ObservableObject {
    @Published private(set) var items: [UploadItem] = []
    /// Non-nil when the queue stopped itself because the account needs attention.
    @Published private(set) var haltReason: String?
    /// Non-nil while the selected connection policy does not permit uploads.
    @Published private(set) var networkPauseReason: String?
    /// Set when iOS ends a background execution window before the queue drains.
    @Published private(set) var systemPauseReason: String?
    /// A durable user pause. Current uploads finish; new uploads wait.
    /// Resets the scan cursor: a pause changes which rows count as startable,
    /// so rows the scan already skipped have to be reconsidered.
    @Published private(set) var isUserPaused = false { didSet { scanCursor = 0 } }
    /// A non-fatal warning when the durable queue cannot be read or written.
    @Published private(set) var persistenceWarning: String?
    @Published var options = UploadOptions()
    /// The most recent failures, newest first, and how many there have been in
    /// this session. A row's reason lives on the row, which Retry and Clear
    /// Finished both take away — so the only record of what Google actually
    /// said used to disappear exactly when someone went looking for it. Bounded,
    /// in memory only, and read by Diagnostics.
    @Published private(set) var recentFailures: [UploadFailure] = []
    @Published private(set) var failureCount = 0
    private static let recentFailureLimit = 25

    /// Called once when Google refuses the credential, so the account state can follow.
    var onCredentialRejected: ((Error) -> Void)?

    /// How many uploads the user may run at once. Bounded at the top because
    /// each in-flight item stages a full-size copy on disk and hashes it end to
    /// end, so the ceiling costs real disk and CPU, and because the background
    /// session's per-host connection limit is fixed when that session is
    /// created — going wider than that limit would not widen the transfers.
    ///
    /// macOS gets a higher ceiling: it isn't battery- or cellular-metered the
    /// way a phone is, its hashing pass now genuinely runs off the main actor
    /// (see `GPMCClient.sha1`), and a first backup on a new Mac routinely
    /// means reconciling a library iOS already finished — tens of thousands
    /// of items that just need a cheap "already backed up" check, which is
    /// one small network round trip, not disk/CPU work, once hashed.
    ///
    /// 48 is a deliberately experimental upper bound, not a value backed by
    /// any published rate limit for Google's undocumented mobile API — there
    /// isn't one to look up. If raising this starts increasing the failure
    /// count instead of throughput, that is the signal to come back down.
#if os(macOS)
    static let concurrencyRange = 1...48
#else
    static let concurrencyRange = 1...10
#endif

    /// How many uploads may have file bytes actively moving at once — see
    /// `TransferGate`. Deliberately the same on both platforms and much
    /// narrower than `concurrencyRange`: this is bandwidth-bound, not
    /// CPU/battery-bound, and a typical upload connection saturates well
    /// before this ceiling regardless of what device is asking.
    static let transferConcurrencyRange = 1...10

    private(set) var maxConcurrent: Int
    let maxAttempts: Int
    private let worker: UploadWorker
    private let sleeper: @Sendable (Double) async -> Void
    private let persistence: UploadQueuePersisting?
    private let checkpointCleaner: UploadCheckpointCleaner?
    private var running: [UUID: Task<Void, Never>] = [:]
    private var userCancelled: Set<UUID> = []
    private var requeueCancelled: Set<UUID> = []
    private var accountIdentifier: String?
    /// The durable per-account set of sources known to be backed up. Published
    /// because the dashboard's "Backed up" metric is derived from its count.
    @Published private(set) var completedSourceKeys: Set<String> = []
    private var completionLedgerHealthy = true
    /// Same reasoning as `isUserPaused`: this narrows what `pump` may start.
    private var drainsBackgroundCompletionsOnly = false { didSet { scanCursor = 0 } }
    /// Set while a `cancelAll` is settling, so the rows it cancels are dropped
    /// instead of persisted as durable "skip this source" markers.
    private var discardsCancelledRows = false
    private var persistScheduled = false
    private var lastPersistAt = Date.distantPast

    // MARK: - Derived state
    //
    // A whole-library queue is tens of thousands of rows. Every aggregate below
    // used to be a `filter` over all of them, recomputed by SwiftUI on both the
    // dashboard and the activity list for every publish — and there is a publish
    // for every progress tick. Together with the linear `firstIndex` lookups on
    // the event path, and a `pump` that rescanned the whole finished prefix on
    // every completion, the queue's cost grew with the square of its length.
    // That is what made the activity list, navigation and the backup itself all
    // slow down as a large backup progressed. Everything here is maintained
    // incrementally instead, so the per-event cost no longer depends on how many
    // rows the queue holds.

    private struct RowCounts {
        /// Rows that are not finished — the queue's "still to do" count.
        var unfinished = 0
        var failed = 0
        var waitingForICloud = 0
        /// `.done` plus `.alreadyBackedUp`.
        var completed = 0
        var finished = 0
    }

    private var counts = RowCounts()
    /// Row offset by id, so the event path does not scan for its own row.
    private var indexByID: [UUID: Int] = [:]
    /// Dedup keys for every row `items` currently holds, whatever its state, so
    /// an automatic rescan does not rebuild that set from the whole queue.
    private var queuedSourceKeys: Set<String> = []
    /// Rows whose state carries a live progress fraction. Never more than
    /// `maxConcurrent` of them, so `overallFraction` sums a handful of rows
    /// rather than the entire queue.
    private var fractionalIDs: Set<UUID> = []
    /// Where the search for the next startable row left off. `setState` pulls it
    /// back whenever an earlier row returns to `.queued`, and the pause flags
    /// reset it because they change which rows count as startable.
    private var scanCursor = 0

    private func index(of id: UUID) -> Int? { indexByID[id] }

    private func tally(_ state: UploadItem.State, by delta: Int) {
        switch state {
        case .done, .alreadyBackedUp: counts.completed += delta; counts.finished += delta
        case .failed: counts.failed += delta; counts.finished += delta
        case .cancelled: counts.finished += delta
        case .waitingForICloud: counts.waitingForICloud += delta; counts.unfinished += delta
        default: counts.unfinished += delta
        }
    }

    /// The one place a row's state changes, so the counters, the progress set
    /// and the scan cursor cannot drift away from `items`.
    private func setState(_ state: UploadItem.State, at index: Int) {
        let id = items[index].id
        tally(items[index].state, by: -1)
        tally(state, by: 1)
        items[index].state = state
        if !state.isFinished, state.fraction != nil { fractionalIDs.insert(id) }
        else { fractionalIDs.remove(id) }
        if state == .queued { scanCursor = min(scanCursor, index) }
    }

    /// Append rows and extend the derived state to cover them.
    private func appendRows(_ rows: [UploadItem]) {
        guard !rows.isEmpty else { return }
        indexByID.reserveCapacity(items.count + rows.count)
        for (offset, row) in rows.enumerated() {
            indexByID[row.id] = items.count + offset
            if let key = row.source.queueDeduplicationKey { queuedSourceKeys.insert(key) }
            tally(row.state, by: 1)
        }
        scanCursor = min(scanCursor, items.count)
        items.append(contentsOf: rows)
    }

    /// Recompute everything derived from `items`. Row offsets shift on removal,
    /// so every path that removes or replaces rows ends here — all of them are
    /// user actions or a one-off restore, never the per-tick event path.
    private func rebuildDerivedState() {
        counts = RowCounts()
        indexByID.removeAll(keepingCapacity: true)
        queuedSourceKeys.removeAll(keepingCapacity: true)
        fractionalIDs.removeAll(keepingCapacity: true)
        scanCursor = 0
        indexByID.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            indexByID[item.id] = offset
            if let key = item.source.queueDeduplicationKey { queuedSourceKeys.insert(key) }
            tally(item.state, by: 1)
            if !item.state.isFinished, item.state.fraction != nil { fractionalIDs.insert(item.id) }
        }
    }

    init(worker: @escaping UploadWorker,
         maxConcurrent: Int = 2,
         maxAttempts: Int = 3,
         persistence: UploadQueuePersisting? = nil,
         checkpointCleaner: UploadCheckpointCleaner? = nil,
         sleeper: @escaping @Sendable (Double) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.worker = worker
        self.maxConcurrent = Self.clampedConcurrency(maxConcurrent)
        self.maxAttempts = max(1, maxAttempts)
        self.persistence = persistence
        self.checkpointCleaner = checkpointCleaner
        self.sleeper = sleeper
    }

    // MARK: - Aggregates for the UI

    var activeCount: Int { counts.unfinished }
    var failedCount: Int { counts.failed }
    /// Items held back because their bytes are only in iCloud. They are not
    /// stalled — they resume when the app is foregrounded — but they do sit in
    /// `activeCount`, so the UI has to be able to explain them.
    var deferredForICloudCount: Int { counts.waitingForICloud }
    var isIdle: Bool { counts.unfinished == 0 }
    /// Whether the activity list has anything to clear.
    var hasFinishedItems: Bool { counts.finished > 0 }
    /// Whether any unfinished row can still make progress on its own. Rows
    /// parked on an iCloud download are unfinished but inert until the export
    /// can fetch their bytes, so a caller that waits on `activeCount` alone
    /// would wait on them forever.
    var hasWorkableItems: Bool { counts.unfinished > counts.waitingForICloud }
    var pauseReason: String? {
        haltReason
            ?? (isUserPaused ? "You paused backup. Resume to continue." : nil)
            ?? networkPauseReason
            ?? systemPauseReason
    }
    var retainedStagingURLs: Set<URL> { Set(items.compactMap { $0.checkpoint?.fileURL }) }
    /// Cancelled and failed rows are excluded, finished ones count as a whole
    /// item, and the only rows left with a moving fraction are the ones actually
    /// in flight — so this sums at most `maxConcurrent` rows however long the
    /// queue is. Both the dashboard hero and the activity header read it on
    /// every publish, which is why it may not walk the queue.
    var overallFraction: Double {
        let tracked = counts.unfinished + counts.completed
        guard tracked > 0 else { return 0 }
        var sum = Double(counts.completed)
        for id in fractionalIDs {
            guard let index = indexByID[id] else { continue }
            sum += items[index].state.fraction ?? 0
        }
        return sum / Double(tracked)
    }

    // MARK: - Commands

    /// What one `enqueue` call did. `reachedLimit` is the part callers with a
    /// change token care about: when the limit cut the batch short, some
    /// sources were never looked at, so the caller must not record the scan as
    /// fully handled.
    struct EnqueueOutcome {
        let accepted: [UUID]
        let reachedLimit: Bool
    }

    @discardableResult
    func enqueue(_ sources: [MediaSource], skippingExisting: Bool = false, limit: Int? = nil) -> [UUID] {
        enqueueReportingLimit(sources, skippingExisting: skippingExisting, limit: limit).accepted
    }

    @discardableResult
    func enqueueReportingLimit(_ sources: [MediaSource],
                               skippingExisting: Bool = false,
                               limit: Int? = nil) -> EnqueueOutcome {
        var reachedLimit = false
        var accepted: [UploadItem] = []
        // A failed row is already the durable retry handle for its source, and
        // so is a cancelled one: automatic rescans must not append another
        // identical row on every window, and a cancellation the user made
        // deliberately must not silently undo itself on the next scan. Both are
        // released by Retry or Clear Finished in the Activity UI.
        // `queuedSourceKeys` tracks the rows already present, so this no longer
        // rebuilds a key set over the whole queue every time a scan window runs.
        var acceptedKeys: Set<String> = []
        for source in sources {
            if let limit, accepted.count >= max(0, limit) {
                reachedLimit = true
                break
            }
            if skippingExisting {
                if let key = source.queueDeduplicationKey {
                    guard !completedSourceKeys.contains(key), !queuedSourceKeys.contains(key),
                          acceptedKeys.insert(key).inserted else { continue }
                } else {
                    let isAlreadyTracked = items.contains { $0.source == source }
                    if isAlreadyTracked || accepted.contains(where: { $0.source == source }) { continue }
                }
            }
            accepted.append(UploadItem(source: source))
        }
        appendRows(accepted)
        persistNow()
        pump()
        return EnqueueOutcome(accepted: accepted.map(\.id), reachedLimit: reachedLimit)
    }

    func cancel(_ id: UUID) {
        guard let index = index(of: id), !items[index].state.isFinished else { return }
        userCancelled.insert(id)
        if let task = running[id] {
            task.cancel()
        } else {
            setState(.cancelled, at: index)
            userCancelled.remove(id)
            requeueCancelled.remove(id)
            cleanCheckpoint(for: index)
            persistNow()
        }
    }

    /// Stop everything and discard the queue. Unlike a single-row cancel, the
    /// resulting rows are dropped rather than kept as durable "don't retry this"
    /// markers — Stop means start over, so a later rescan must be free to pick
    /// these sources up again.
    ///
    /// Deliberately does not go through `cancel(_:)` row by row. That path
    /// writes the whole snapshot for every row it touches, so stopping a
    /// full-library queue meant thousands of encode-and-replace passes over a
    /// file that is itself thousands of rows long — all on the main actor,
    /// which locked the UI up for as long as it took. One pass, one write.
    func cancelAll() {
        isUserPaused = false
        var cancelledInFlight = false
        for index in items.indices where !items[index].state.isFinished {
            let id = items[index].id
            if let task = running[id] {
                // Settles in `finish`, which drops the row rather than keeping
                // it, because `discardsCancelledRows` is set below.
                userCancelled.insert(id)
                task.cancel()
                cancelledInFlight = true
            } else {
                userCancelled.remove(id)
                requeueCancelled.remove(id)
                setState(.cancelled, at: index)
                cleanCheckpoint(for: index)
            }
        }
        // Only meaningful while in-flight rows are still settling; leaving it
        // set would silently discard the next single-row cancel as well.
        discardsCancelledRows = cancelledInFlight
        items.removeAll { $0.state == .cancelled }
        rebuildDerivedState()
        persistNow()
    }

    static func clampedConcurrency(_ value: Int) -> Int {
        min(concurrencyRange.upperBound, max(concurrencyRange.lowerBound, value))
    }

    static func clampedTransferConcurrency(_ value: Int) -> Int {
        min(transferConcurrencyRange.upperBound, max(transferConcurrencyRange.lowerBound, value))
    }

    /// Change how many uploads run at once. Raising it starts more immediately;
    /// lowering it never cancels work already in flight, it just stops the queue
    /// starting replacements until the count falls back within the new limit.
    func setMaxConcurrent(_ value: Int) {
        let clamped = Self.clampedConcurrency(value)
        guard clamped != maxConcurrent else { return }
        maxConcurrent = clamped
        objectWillChange.send()
        pump()
    }

    /// Stop scheduling new work without throwing away queue state or staged
    /// files. The pause is durable: it survives the queue draining and a
    /// relaunch, and only an explicit resume or stop clears it. Anything else
    /// would let an automatic rescan quietly restart work the user paused.
    func pauseAfterCurrentUploads() {
        guard !isUserPaused else { return }
        isUserPaused = true
        persistNow()
    }

    func resumeUserPausedUploads() {
        guard isUserPaused else { return }
        isUserPaused = false
        persistNow()
        pump()
    }

    func retry(_ id: UUID) {
        guard let index = index(of: id), items[index].state.isFinished,
              items[index].state != .done, items[index].state != .alreadyBackedUp else { return }
        requeue(at: index)
        persistNow()
        pump()
    }

    /// Same one-pass-one-write rule as `cancelAll`: retrying row by row would
    /// rewrite the entire snapshot once per failure.
    func retryAllFailed() {
        releaseFailures { _ in true }
    }

    /// Requeue failures a later attempt could plausibly fix, and report how
    /// many were released.
    ///
    /// The per-item retry with backoff only covers one worker run; once an item
    /// exhausts `maxAttempts` it lands in `.failed`, where the dedup treats it
    /// as a durable handle and no automatic scan ever touches it again. Without
    /// this, a transient network blip parks those photos until someone notices
    /// and taps Retry — which is not what a backup is for. Errors marked
    /// non-retryable (a missing asset, a refused credential) are left alone.
    @discardableResult
    func retryRetryableFailures() -> Int {
        releaseFailures { $0 }
    }

    /// Requeue every failed row whose `retryable` flag the predicate accepts,
    /// in a single pass with a single snapshot write. Returns how many moved.
    @discardableResult
    private func releaseFailures(_ isIncluded: (Bool) -> Bool) -> Int {
        var released = 0
        for index in items.indices {
            guard case .failed(_, let retryable) = items[index].state, isIncluded(retryable) else { continue }
            requeue(at: index)
            released += 1
        }
        guard released > 0 else { return 0 }
        persistNow()
        pump()
        return released
    }

    private func requeue(at index: Int) {
        items[index].attempts = 0
        setState(.queued, at: index)
    }

    func clearFinished() {
        items.removeAll { $0.state.isFinished }
        rebuildDerivedState()
        persistNow()
    }

    /// Number of distinct sources the queue knows are backed up for the
    /// connected account. This is the count the dashboard shows and the one the
    /// Settings verify action uses to explain what will be re-checked: it is a
    /// set, so re-verifying an item that is already in the cloud re-records the
    /// same key and the total does not move.
    var completedSourceCount: Int { completedSourceKeys.count }

    /// A snapshot test for "is this library asset already backed up", safe to
    /// hand to a background task computing per-album progress.
    func backedUpAssetLookup() -> @Sendable (String) -> Bool {
        let keys = completedSourceKeys
        return { identifier in keys.contains("asset:\(identifier)") }
    }

    /// Forget remembered completions so the next enqueue re-checks them against
    /// Google (hash lookup) and re-uploads anything deleted in the cloud.
    /// Finished rows for the same sources are removed as well, otherwise the
    /// in-memory dedup in `enqueue(skippingExisting:)` would skip them again.
    /// Returns the number of sources forgotten.
    @discardableResult
    func forgetCompletedSources(for sources: [MediaSource]) -> Int {
        let keys = Set(sources.compactMap(\.queueDeduplicationKey)).intersection(completedSourceKeys)
        guard !keys.isEmpty else { return 0 }
        completedSourceKeys.subtract(keys)
        items.removeAll { item in
            guard item.state.isFinished,
                  let key = item.source.queueDeduplicationKey else { return false }
            return keys.contains(key)
        }
        rebuildDerivedState()
        if let accountIdentifier, let persistence {
            do {
                try persistence.removeCompletedSourceKeys(keys, for: accountIdentifier)
                if completionLedgerHealthy { persistenceWarning = nil }
            } catch {
                completionLedgerHealthy = false
                persistenceWarning = "Upload completion could not be saved: \(error.localizedDescription)"
            }
        }
        persistNow()
        return keys.count
    }

    /// Forget + re-enqueue in one step for Settings. The worker's hash lookup
    /// short-circuits items still in the cloud to `alreadyBackedUp`; only
    /// genuinely missing bytes are uploaded again.
    /// Returns `(forgotten, enqueued)`.
    @discardableResult
    func reverify(_ sources: [MediaSource], limit: Int? = nil) -> (forgotten: Int, enqueued: Int) {
        let forgotten = forgetCompletedSources(for: sources)
        let enqueued = enqueue(sources, skippingExisting: true, limit: limit).count
        return (forgotten, enqueued)
    }

    /// Select and restore the durable queue for the connected account. A queue
    /// is never reused for a different Google account.
    func activateAccount(_ identifier: String?) {
        let next = identifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized = next.flatMap { $0.isEmpty ? nil : $0 }
        guard normalized != accountIdentifier else { return }

        if accountIdentifier != nil {
            persistNow()
            for index in items.indices { cleanCheckpoint(for: index) }
            for task in running.values { task.cancel() }
        }
        accountIdentifier = normalized
        items = []
        rebuildDerivedState()
        completedSourceKeys = []
        completionLedgerHealthy = true
        haltReason = nil
        systemPauseReason = nil
        isUserPaused = false
        persistenceWarning = nil

        guard let normalized, let persistence else { return }
        do {
            let ledgerKeys = try persistence.loadCompletedSourceKeys(for: normalized)
            guard let snapshot = try persistence.load(),
                  snapshot.version == UploadQueueSnapshot.version,
                  snapshot.accountIdentifier == normalized else {
                completedSourceKeys = Set(ledgerKeys)
                persistNow()
                return
            }
            if persistence.storesCompletionLedgerSeparately {
                // One batched append. Per-key writes here meant one file-handle
                // open and close for every photo the library had ever backed up.
                do { try persistence.recordCompletedSourceKeys(snapshot.completedSourceKeys, for: normalized) }
                catch { completionLedgerHealthy = false }
            }
            completedSourceKeys = Set(snapshot.completedSourceKeys)
            completedSourceKeys.formUnion(ledgerKeys)
            isUserPaused = snapshot.isUserPaused ?? false
            items = snapshot.items.compactMap { stored in
                if let key = stored.source.mediaSource.queueDeduplicationKey,
                   completedSourceKeys.contains(key) { return nil }
                var item = UploadItem(id: stored.id, source: stored.source.mediaSource, name: stored.name)
                item.byteCount = stored.byteCount
                item.attempts = stored.attempts
                item.checkpoint = stored.checkpoint
                if stored.cancelled == true {
                    item.state = .cancelled
                } else if let reason = stored.failureReason {
                    item.state = .failed(reason: reason, retryable: stored.failureRetryable)
                } else {
                    item.state = .queued
                }
                return item
            }
            rebuildDerivedState()
            if persistence.storesCompletionLedgerSeparately,
               !snapshot.completedSourceKeys.isEmpty { persistNow() }
            pump()
        } catch {
            persistenceWarning = "The saved upload queue could not be restored: \(error.localizedDescription)"
        }
    }

    /// Write any coalesced snapshot immediately. Called when the app is about
    /// to be suspended, where the next main-actor turn may never come.
    func flushPendingWrites() {
        guard persistScheduled else { return }
        persistNow()
    }

    /// Clear the halt after the account has been reconnected; everything that
    /// was stopped mid-flight went back to `queued` and picks up here.
    func resume() {
        haltReason = nil
        pump()
    }

    /// Apply the current user-selected connection policy. Losing an allowed
    /// transport cancels in-flight work and requeues it so no upload can leak
    /// onto cellular after Wi-Fi disappears.
    func setNetworkAccess(allowed: Bool, pauseReason: String? = nil) {
        let nextReason = allowed ? nil : (pauseReason ?? "Waiting for an allowed connection")
        guard networkPauseReason != nextReason else { return }
        networkPauseReason = nextReason
        if allowed { pump() }
        // A background transfer keeps the `allowsCellularAccess` it was created
        // with, so iOS will happily finish it over cellular after the policy
        // says otherwise. Losing an allowed transport therefore has to cancel
        // those too — unlike a background-window expiry, which leaves them
        // running on purpose. The staged file survives, so a retry only repeats
        // the hash and the upload-URL request.
        else { cancelRunningForRequeue(includingBackgroundTransfers: true) }
    }

    /// Called by the background-task expiration handler. Work remains queued
    /// for the next system execution window or foreground launch.
    func suspendForBackgroundExpiration() {
        systemPauseReason = "Paused until iOS gives the app more time"
        cancelRunningForRequeue()
        flushPendingWrites()
    }

    func resumeSystemWork() {
        drainsBackgroundCompletionsOnly = false
        systemPauseReason = nil
        pump()
    }

    /// A background-URLSession wake is for consuming transfer results, not for
    /// starting a fresh library export. Set this before queue restoration.
    /// Prefer `noteBackgroundTransferCompletionsPending()` before restoration
    /// (sets the filter without pumping an empty queue), then call this after
    /// the queue is restored and policy applied to start the drain.
    func resumeBackgroundTransferCompletions() {
        drainsBackgroundCompletionsOnly = true
        systemPauseReason = nil
        pump()
    }

    /// Mark that a background-URLSession wake is pending without starting work
    /// yet. Call this before `activateAccount` so its internal pump already
    /// runs in drains-only mode instead of starting fresh exports.
    func noteBackgroundTransferCompletionsPending() {
        drainsBackgroundCompletionsOnly = true
        systemPauseReason = nil
    }

    func finishBackgroundTransferCompletions() {
        drainsBackgroundCompletionsOnly = false
        suspendForBackgroundExpiration()
    }

    func setICloudDownloadsAllowed(_ allowed: Bool) {
        guard options.allowsICloudDownload != allowed else { return }
        options.allowsICloudDownload = allowed
        if allowed {
            for index in items.indices where items[index].state == .waitingForICloud {
                setState(.queued, at: index)
            }
            persist()
            pump()
        } else {
            cancelRunningForRequeue()
        }
    }

    /// Wait for all unfinished queue work. Cancellation is how a background
    /// task tells this loop that its execution window has expired.
    func waitUntilSettled() async -> Bool {
        while !isIdle {
            if Task.isCancelled { return false }
            if networkPauseReason != nil || systemPauseReason != nil { return false }
            if isUserPaused && running.isEmpty { return false }
            if running.isEmpty && !hasWorkableItems {
                return haltReason == nil
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return haltReason == nil
    }

    /// Used by the app delegate relaunch path. Do not hold iOS's completion
    /// handler for unrelated queued work; only wait until received PUT results
    /// have either committed or been durably retained. The deadline leaves
    /// margin for iOS's ~30s relaunch window while covering an auth refresh
    /// plus the small commit RPC.
    func waitUntilBackgroundTransfersHandled() async {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, items.contains(where: { item in
            guard let prepared = item.checkpoint?.prepared else { return false }
            return prepared.receipt != nil || (running[item.id] != nil && item.state.isWorking)
        }) {
            if networkPauseReason != nil || systemPauseReason != nil { return }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Scheduling

    private func pump() {
        guard haltReason == nil, networkPauseReason == nil, systemPauseReason == nil else { return }
        while running.count < maxConcurrent, let index = nextStartableIndex() {
            start(at: index)
        }
    }

    /// The next row that could start now, resuming from `scanCursor` instead of
    /// the front of the queue. A full-library backup finishes rows front to
    /// back, so scanning from zero on every completion re-walked the entire
    /// finished prefix — the queue got slower the more of it had succeeded, and
    /// the cost landed on the main actor between every pair of uploads.
    private func nextStartableIndex() -> Int? {
        while scanCursor < items.count {
            if items[scanCursor].state == .queued {
                // A pause still lets a row whose bytes are already moving in an
                // iOS-owned background transfer come back to collect its result.
                guard drainsBackgroundCompletionsOnly || isUserPaused else { return scanCursor }
                if items[scanCursor].checkpoint?.isBackgroundTransfer == true { return scanCursor }
            }
            scanCursor += 1
        }
        return nil
    }

    private func start(at index: Int) {
        let id = items[index].id
        setState(.exporting, at: index)
        items[index].attempts += 1
        let source = items[index].source
        let checkpoint = items[index].checkpoint
        let options = self.options
        let worker = self.worker
        running[id] = Task { [weak self] in
            let outcome: Result<UploadOutcome, Error>
            do {
                outcome = .success(try await worker(id, source, checkpoint, options) { [weak self] event in
                    await self?.apply(event, to: id)
                })
            }
            catch { outcome = .failure(error) }
            self?.finish(id, outcome)
        }
    }

    private func apply(_ event: UploadEvent, to id: UUID) {
        guard let index = index(of: id) else { return }
        switch event {
        case .described(let name, let byteCount):
            items[index].name = name; items[index].byteCount = byteCount
            persist()
        case .state(let state):
            guard !items[index].state.isFinished else { return }
            setState(state, at: index)
        case .checkpoint(let checkpoint):
            items[index].checkpoint = checkpoint
            // The durable hand-off to the background transfer: this must be on
            // disk before the worker proceeds, not on the next turn.
            persistNow()
        }
    }

    private func finish(_ id: UUID, _ outcome: Result<UploadOutcome, Error>) {
        running[id] = nil
        defer { pump() }
        guard let index = index(of: id) else { return }
        switch outcome {
        case .success(let result):
            let settled: UploadItem.State = { if case .alreadyBackedUp = result { return .alreadyBackedUp } else { return .done } }()
            items[index].mediaKey = result.mediaKey
            setState(settled, at: index)
            if let key = items[index].source.queueDeduplicationKey { completedSourceKeys.insert(key) }
            items[index].checkpoint = nil
            recordCompletion(for: items[index])
            persist()
        case .failure(let error):
            if userCancelled.remove(id) != nil {
                requeueCancelled.remove(id)
                setState(.cancelled, at: index)
                cleanCheckpoint(for: index)
                if discardsCancelledRows {
                    items.remove(at: index)
                    rebuildDerivedState()
                    if userCancelled.isEmpty { discardsCancelledRows = false }
                }
                persist()
                return
            }
            // Policy, credential and background-expiration pauses all cancel
            // in-flight work for requeue. A later pump restarts it unchanged.
            if requeueCancelled.remove(id) != nil { setState(.queued, at: index); persist(); return }
            if error is CancellationError {
                setState(.cancelled, at: index); cleanCheckpoint(for: index); persist(); return
            }
            if error as? MediaExporter.Failure == .iCloudDownloadRequired {
                items[index].attempts = max(0, items[index].attempts - 1)
                setState(.waitingForICloud, at: index)
                persist()
                return
            }
            let gpmc = error as? GPMCError
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // A refused credential and a full account both mean no other item
            // can succeed either, so the queue stops rather than failing every
            // remaining row one at a time. The row goes back to `queued` and
            // picks up where it left off when the user resumes.
            if let gpmc, gpmc.kind == .credentialRejected || gpmc.kind == .tokenBound
                || gpmc.kind == .storageFull {
                setState(.queued, at: index)
                persist()
                halt(gpmc)
                return
            }
            let retryable = gpmc?.isRetryable ?? false
            if retryable, items[index].attempts < maxAttempts {
                let attempt = items[index].attempts
                setState(.waitingToRetry(attempt: attempt), at: index)
                persist()
                scheduleRetry(id, after: min(30, pow(2, Double(attempt))))
            } else {
                setState(.failed(reason: reason, retryable: retryable), at: index)
                recordFailure(name: items[index].name, reason: reason, status: gpmc?.status)
                cleanCheckpoint(for: index)
                persist()
            }
        }
    }

    private func halt(_ error: GPMCError) {
        guard haltReason == nil else { return }
        haltReason = error.message
        recordFailure(name: "Backup stopped", reason: error.message, status: error.status)
        cancelRunningForRequeue()
        // Only a credential failure asks the app to reconnect the account. A
        // full account stops the queue just as hard, but the fix is in Google,
        // and prompting for a reconnection there would send the user nowhere.
        if error.kind == .credentialRejected || error.kind == .tokenBound {
            onCredentialRejected?(error)
        }
    }

    /// Keep the newest failures and drop the oldest, so a long backup that goes
    /// wrong in one way does not bury the one that went wrong differently.
    private func recordFailure(name: String, reason: String, status: GoogleStatus?) {
        failureCount += 1
        recentFailures.insert(UploadFailure(name: name, reason: reason, statusCode: status?.rawCode), at: 0)
        if recentFailures.count > Self.recentFailureLimit { recentFailures.removeLast() }
    }

    private func cancelRunningForRequeue(includingBackgroundTransfers: Bool = false) {
        for (id, task) in running {
            if !includingBackgroundTransfers,
               let index = index(of: id),
               items[index].checkpoint?.isBackgroundTransfer == true {
                continue
            }
            requeueCancelled.insert(id)
            task.cancel()
        }
    }

    private func scheduleRetry(_ id: UUID, after seconds: Double) {
        let sleeper = self.sleeper
        Task { [weak self] in
            await sleeper(seconds)
            guard let self else { return }
            guard let index = self.index(of: id) else { return }
            guard case .waitingToRetry = self.items[index].state else { return }
            self.setState(.queued, at: index)
            self.persist()
            self.pump()
        }
    }

    /// Coalesce the snapshot write. `persist()` is called from every queue
    /// event — described, each checkpoint, each finish — and each call encodes
    /// the whole items array. Batching to one write per main-actor turn keeps
    /// the durability guarantee (nothing yields between the mutation and the
    /// flush) while collapsing the five or six writes an item used to cost.
    ///
    /// That one-write-per-turn coalescing still meant a full walk of `items`
    /// (to build the snapshot, excluding finished rows) on nearly every
    /// completion once a large queue was draining fast — harmless at normal
    /// sizes, but a real, main-actor-bound cost once a first-time
    /// reconciliation of tens of thousands of items was finishing dozens of
    /// rows a second: raising upload concurrency to push more network work
    /// through made the app *less* responsive, because it also raised how
    /// often this ran. `persistMinInterval` caps how often a new coalescing
    /// window can start; it does not change how many writes one burst
    /// collapses to; a row's in-memory state still updates immediately, only
    /// the durable copy on disk can now lag by up to this long.
    private static let persistMinInterval: TimeInterval = 0.3

    private func persist() {
        guard persistence != nil, accountIdentifier != nil else { return }
        guard !persistScheduled else { return }
        persistScheduled = true
        let wait = max(0, Self.persistMinInterval - Date().timeIntervalSince(lastPersistAt))
        Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self, self.persistScheduled else { return }
            self.persistScheduled = false
            self.persistNow()
        }
    }

    /// Write immediately. Used where a later flush would be too late: the
    /// checkpoint hand-off before a background PUT starts, and anything that
    /// runs as the process is about to be suspended.
    private func persistNow() {
        persistScheduled = false
        lastPersistAt = Date()
        guard let accountIdentifier, let persistence else { return }
        let storedItems = items.compactMap { item -> PersistedUploadItem? in
            guard let source = PersistedMediaSource(item.source)
                    ?? item.checkpoint.map({ .file($0.filePath) }) else { return nil }
            switch item.state {
            case .alreadyBackedUp, .done:
                return nil
            case .cancelled:
                // Kept so a deliberate cancellation is not silently undone by
                // the next automatic scan. Cleared by Retry or Clear Finished.
                return PersistedUploadItem(id: item.id, source: source, name: item.name,
                                           byteCount: item.byteCount, attempts: item.attempts,
                                           failureReason: nil, failureRetryable: false,
                                           checkpoint: nil, cancelled: true)
            case .failed(let reason, let retryable):
                return PersistedUploadItem(id: item.id, source: source, name: item.name,
                                           byteCount: item.byteCount, attempts: item.attempts,
                                           failureReason: reason, failureRetryable: retryable,
                                           checkpoint: item.checkpoint)
            default:
                // Working and retry-delay states intentionally restore queued.
                return PersistedUploadItem(id: item.id, source: source, name: item.name,
                                           byteCount: item.byteCount, attempts: item.attempts,
                                           failureReason: nil, failureRetryable: false,
                                           checkpoint: item.checkpoint)
            }
        }
        let snapshot = UploadQueueSnapshot(
            version: UploadQueueSnapshot.version,
            accountIdentifier: accountIdentifier,
            items: storedItems,
            completedSourceKeys: persistence.storesCompletionLedgerSeparately && completionLedgerHealthy
                ? [] : Array(completedSourceKeys),
            isUserPaused: isUserPaused
        )
        do {
            try persistence.save(snapshot)
            if completionLedgerHealthy { persistenceWarning = nil }
        } catch {
            persistenceWarning = "Upload progress could not be saved: \(error.localizedDescription)"
        }
    }

    private func recordCompletion(for item: UploadItem) {
        guard let accountIdentifier, let persistence,
              let key = item.source.queueDeduplicationKey,
              persistence.storesCompletionLedgerSeparately else { return }
        do {
            try persistence.recordCompletedSourceKey(key, for: accountIdentifier)
        } catch {
            completionLedgerHealthy = false
            persistenceWarning = "Upload completion could not be saved: \(error.localizedDescription)"
        }
    }

    private func cleanCheckpoint(for index: Int) {
        guard let checkpoint = items[index].checkpoint else { return }
        let id = items[index].id
        items[index].checkpoint = nil
        guard let checkpointCleaner else { return }
        Task { await checkpointCleaner(id, checkpoint) }
    }
}
