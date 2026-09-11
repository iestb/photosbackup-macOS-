import Foundation

/// The durable subset of a media source. Picker-only selections cannot be
/// reconstructed after process death, while library assets and file URLs can.
enum PersistedMediaSource: Codable, Equatable, Sendable {
    case asset(String)
    case file(String)

    init?(_ source: MediaSource) {
        switch source {
        case .asset(let identifier): self = .asset(identifier)
        case .file(let url): self = .file(url.standardizedFileURL.path)
        case .picked: return nil
        }
    }

    var mediaSource: MediaSource {
        switch self {
        case .asset(let identifier): return .asset(localIdentifier: identifier)
        case .file(let path): return .file(URL(fileURLWithPath: path))
        }
    }
}

/// Durable hand-off between export, background PUT, and commit. A checkpoint
/// without `prepared` resumes preflight; one with a nil receipt reattaches to
/// the background task; one with a receipt skips straight to commit.
struct UploadCheckpoint: Codable, Equatable, Sendable {
    let filePath: String
    let filename: String
    let modified: Date
    let byteCount: Int64
    let temporary: Bool
    var prepared: PreparedUpload?
    var continuesAfterProcessExit: Bool? = nil
    /// Set once an unusable receipt has already cost this item a fresh transfer.
    /// A second identical rejection is not the receipt, so the item fails
    /// instead of re-uploading its bytes for every remaining attempt.
    var retriedAfterInvalidReceipt: Bool? = nil

    var fileURL: URL { URL(fileURLWithPath: filePath) }
    var isBackgroundTransfer: Bool { prepared != nil && continuesAfterProcessExit == true }
}

struct PersistedUploadItem: Codable, Equatable, Sendable {
    let id: UUID
    let source: PersistedMediaSource
    let name: String
    let byteCount: Int64
    let attempts: Int
    let failureReason: String?
    let failureRetryable: Bool
    let checkpoint: UploadCheckpoint?
    /// Optional so snapshots written by earlier releases remain decodable.
    let cancelled: Bool?

    init(id: UUID, source: PersistedMediaSource, name: String, byteCount: Int64,
         attempts: Int, failureReason: String?, failureRetryable: Bool,
         checkpoint: UploadCheckpoint? = nil, cancelled: Bool? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.byteCount = byteCount
        self.attempts = attempts
        self.failureReason = failureReason
        self.failureRetryable = failureRetryable
        self.checkpoint = checkpoint
        self.cancelled = cancelled
    }
}

struct UploadQueueSnapshot: Codable, Equatable, Sendable {
    static let version = 1

    let version: Int
    let accountIdentifier: String
    let items: [PersistedUploadItem]
    let completedSourceKeys: [String]
    /// Optional so snapshots written by earlier releases remain decodable.
    let isUserPaused: Bool?

    init(version: Int, accountIdentifier: String, items: [PersistedUploadItem],
         completedSourceKeys: [String], isUserPaused: Bool? = nil) {
        self.version = version
        self.accountIdentifier = accountIdentifier
        self.items = items
        self.completedSourceKeys = completedSourceKeys
        self.isUserPaused = isUserPaused
    }
}

protocol UploadQueuePersisting {
    func load() throws -> UploadQueueSnapshot?
    func save(_ snapshot: UploadQueueSnapshot) throws
    /// Block until everything already handed to `save` has reached disk.
    /// Stores that write asynchronously must honour this: it is what the
    /// quit-time flush relies on to not lose the last snapshot.
    func drain()
    var storesCompletionLedgerSeparately: Bool { get }
    func loadCompletedSourceKeys(for accountIdentifier: String) throws -> [String]
    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws
    func recordCompletedSourceKeys(_ keys: [String], for accountIdentifier: String) throws
    func removeCompletedSourceKeys(_ keys: Set<String>, for accountIdentifier: String) throws
}

extension UploadQueuePersisting {
    func drain() {}
    var storesCompletionLedgerSeparately: Bool { false }
    func loadCompletedSourceKeys(for accountIdentifier: String) throws -> [String] {
        guard let snapshot = try load(), snapshot.accountIdentifier == accountIdentifier else { return [] }
        return snapshot.completedSourceKeys
    }
    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws {}
    func recordCompletedSourceKeys(_ keys: [String], for accountIdentifier: String) throws {
        for key in keys { try recordCompletedSourceKey(key, for: accountIdentifier) }
    }
    func removeCompletedSourceKeys(_ keys: Set<String>, for accountIdentifier: String) throws {}
}

/// Encodes and writes queue snapshots on a serial background queue.
///
/// The queue asks for a snapshot up to several times a second while a backup
/// drains, and one holding a whole library encodes to megabytes of JSON —
/// far too much to spend on the main actor, where it stalled the UI in
/// proportion to how fast uploads were completing. Serial, so a slower older
/// snapshot can never land on top of a newer one.
private final class SnapshotWriter: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.g8row.photosbackup.queue-snapshot", qos: .utility)
    private let lock = NSLock()
    private var pendingError: Error?

    init(url: URL) { self.url = url }

    /// A write failure surfaces from the *next* call, since this one no
    /// longer has a synchronous result to throw. One cycle of delay before
    /// the warning appears is not worth doing this work on the main actor.
    func write(_ snapshot: UploadQueueSnapshot) throws {
        if let error = takePendingError() { throw error }
        let url = self.url
        queue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
                applyDataProtectionIfAvailable(atPath: url.path)
            } catch {
                self?.store(error)
            }
        }
    }

    /// Wait for anything already queued. Both reading the file back and the
    /// quit-time flush depend on the writes having landed first.
    func drain() { queue.sync {} }

    private func store(_ error: Error) {
        lock.lock(); pendingError = error; lock.unlock()
    }

    private func takePendingError() -> Error? {
        lock.lock(); defer { lock.unlock() }
        let error = pendingError
        pendingError = nil
        return error
    }
}

/// Appends to the completion ledger through one long-lived file handle.
///
/// Opening, seeking, writing and closing a file for every completed photo
/// cost roughly six syscalls each, on the main actor, dozens of times a
/// second while a large library reconciled. The handle already sits at the
/// end of the file, so an append is now a single write.
private final class LedgerWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL) { self.url = url }
    deinit { try? handle?.close() }

    func append(_ payload: Data) throws {
        guard !payload.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if handle == nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                applyDataProtectionIfAvailable(atPath: url.path)
            }
            let opened = try FileHandle(forWritingTo: url)
            try opened.seekToEnd()
            handle = opened
        }
        try handle?.write(contentsOf: payload)
    }

    /// Compaction and key removal both rewrite the file underneath us, so the
    /// cached handle — and its offset — has to be dropped when they do.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}

/// Stores one account-scoped queue atomically in Application Support. The file
/// remains readable after the first device unlock so an iOS background task can
/// restore it while the phone is locked.
struct FileUploadQueuePersistence: UploadQueuePersisting {
    private let url: URL
    private let ledgerURL: URL
    private let snapshotWriter: SnapshotWriter
    private let ledgerWriter: LedgerWriter

    init(url: URL? = nil) {
        let queueURL: URL
        let logURL: URL
        if let url {
            queueURL = url
            logURL = url.deletingLastPathComponent().appendingPathComponent("completed-sources-v1.log")
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PhotosBackup", isDirectory: true)
            queueURL = base.appendingPathComponent("upload-queue-v1.json")
            logURL = base.appendingPathComponent("completed-sources-v1.log")
        }
        self.url = queueURL
        ledgerURL = logURL
        snapshotWriter = SnapshotWriter(url: queueURL)
        ledgerWriter = LedgerWriter(url: logURL)
    }

    var storesCompletionLedgerSeparately: Bool { true }

    func load() throws -> UploadQueueSnapshot? {
        snapshotWriter.drain()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(UploadQueueSnapshot.self, from: Data(contentsOf: url))
    }

    func save(_ snapshot: UploadQueueSnapshot) throws {
        try snapshotWriter.write(snapshot)
    }

    func drain() { snapshotWriter.drain() }

    func loadCompletedSourceKeys(for accountIdentifier: String) throws -> [String] {
        var keys: [String] = []
        if let snapshot = try load(), snapshot.accountIdentifier == accountIdentifier {
            keys.append(contentsOf: snapshot.completedSourceKeys)
        }
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return keys }
        let account = Data(accountIdentifier.utf8).base64EncodedString()
        let contents = try String(contentsOf: ledgerURL, encoding: .utf8)
        var lineCount = 0
        var seen = Set<String>()
        var ownKeys: [String] = []
        var otherAccountLines: [String] = []
        for line in contents.split(whereSeparator: \.isNewline) {
            lineCount += 1
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0] == Substring(account),
                  let data = Data(base64Encoded: String(parts[1])) else {
                otherAccountLines.append(String(line))
                continue
            }
            let key = String(decoding: data, as: UTF8.self)
            if seen.insert(key).inserted { ownKeys.append(key) }
        }
        keys.append(contentsOf: ownKeys)
        // The ledger only ever appends, so a source that is re-verified or
        // re-uploaded leaves a line each time. Rewrite it once the duplicates
        // outweigh the real entries, otherwise every launch pays to parse them.
        let distinct = ownKeys.count + otherAccountLines.count
        if lineCount > 512, lineCount > distinct * 2 {
            try? rewriteLedger(ownKeys: ownKeys, account: account, otherLines: otherAccountLines)
        }
        return keys
    }

    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws {
        try recordCompletedSourceKeys([key], for: accountIdentifier)
    }

    /// Append in one pass. The snapshot-to-ledger migration hands over every
    /// remembered key at once, and opening a file handle per key made the first
    /// launch after upgrading a large library take minutes.
    func recordCompletedSourceKeys(_ keys: [String], for accountIdentifier: String) throws {
        guard !keys.isEmpty else { return }
        let account = Data(accountIdentifier.utf8).base64EncodedString()
        let payload = keys
            .map { account + "\t" + Data($0.utf8).base64EncodedString() + "\n" }
            .joined()
        try ledgerWriter.append(Data(payload.utf8))
    }

    private func rewriteLedger(ownKeys: [String], account: String, otherLines: [String]) throws {
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let own = ownKeys.map { account + "\t" + Data($0.utf8).base64EncodedString() }
        let lines = otherLines + own
        let output = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        ledgerWriter.invalidate()
        try output.write(to: ledgerURL, atomically: true, encoding: .utf8)
        applyDataProtectionIfAvailable(atPath: ledgerURL.path)
    }

    func removeCompletedSourceKeys(_ keys: Set<String>, for accountIdentifier: String) throws {
        guard !keys.isEmpty else { return }
        // Snapshot may still carry keys written before the separate ledger existed.
        if let snapshot = try load(), snapshot.accountIdentifier == accountIdentifier,
           !snapshot.completedSourceKeys.isEmpty {
            let remaining = snapshot.completedSourceKeys.filter { !keys.contains($0) }
            if remaining.count != snapshot.completedSourceKeys.count {
                try save(UploadQueueSnapshot(version: snapshot.version,
                                            accountIdentifier: snapshot.accountIdentifier,
                                            items: snapshot.items,
                                            completedSourceKeys: remaining,
                                            isUserPaused: snapshot.isUserPaused))
            }
        }
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return }
        let account = Data(accountIdentifier.utf8).base64EncodedString()
        let contents = try String(contentsOf: ledgerURL, encoding: .utf8)
        var kept: [String] = []
        var removed = false
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0] == Substring(account),
                  let data = Data(base64Encoded: String(parts[1])) else {
                kept.append(String(line))
                continue
            }
            if keys.contains(String(decoding: data, as: UTF8.self)) { removed = true }
            else { kept.append(String(line)) }
        }
        guard removed else { return }
        let directory = ledgerURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        ledgerWriter.invalidate()
        try output.write(to: ledgerURL, atomically: true, encoding: .utf8)
        applyDataProtectionIfAvailable(atPath: ledgerURL.path)
    }
}

final class MemoryUploadQueuePersistence: UploadQueuePersisting {
    var snapshot: UploadQueueSnapshot?
    /// How many whole-snapshot writes the queue has asked for. The real file
    /// store encodes and atomically replaces the file on each one, so a bulk
    /// command that writes per row is a main-thread stall proportional to the
    /// square of the queue length.
    private(set) var saveCount = 0

    init(snapshot: UploadQueueSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() throws -> UploadQueueSnapshot? { snapshot }
    func save(_ snapshot: UploadQueueSnapshot) throws {
        saveCount += 1
        self.snapshot = snapshot
    }

    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws {
        guard let snapshot, snapshot.accountIdentifier == accountIdentifier,
              !snapshot.completedSourceKeys.contains(key) else { return }
        self.snapshot = UploadQueueSnapshot(version: snapshot.version,
                                            accountIdentifier: snapshot.accountIdentifier,
                                            items: snapshot.items,
                                            completedSourceKeys: snapshot.completedSourceKeys + [key],
                                            isUserPaused: snapshot.isUserPaused)
    }

    func removeCompletedSourceKeys(_ keys: Set<String>, for accountIdentifier: String) throws {
        guard !keys.isEmpty, let snapshot, snapshot.accountIdentifier == accountIdentifier else { return }
        let remaining = snapshot.completedSourceKeys.filter { !keys.contains($0) }
        guard remaining.count != snapshot.completedSourceKeys.count else { return }
        self.snapshot = UploadQueueSnapshot(version: snapshot.version,
                                            accountIdentifier: snapshot.accountIdentifier,
                                            items: snapshot.items,
                                            completedSourceKeys: remaining,
                                            isUserPaused: snapshot.isUserPaused)
    }
}
