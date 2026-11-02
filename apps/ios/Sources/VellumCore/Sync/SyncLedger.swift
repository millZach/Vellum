import Foundation

/// What the Duo knows about each canvas's copy in Dropbox, and the outbox of work still to do there (#12). It is
/// kept in one small JSON file in the app's Application Support folder (`SyncLedgerFile`), not Caches: the system
/// may clear Caches, and losing this would lose the deletes queued offline and make every canvas upload whole again.
/// It holds no token and no ink: folder names, Dropbox revisions, byte counts and canvas ids.
public struct SyncLedger: Codable, Hashable, Sendable {
    public static let currentFormat = 1

    public var format = SyncLedger.currentFormat
    /// By canvas id (its uuidString).
    public var canvases: [String: CanvasSyncRecord] = [:]
    /// Deleted canvases whose Dropbox folder is still to be moved to `Vellum/.deleted`, oldest first.
    public var deletes: [PendingDelete] = []

    public init() {}

    public subscript(id: UUID) -> CanvasSyncRecord? {
        get { canvases[id.uuidString] }
        set { canvases[id.uuidString] = newValue }
    }

    /// The canvases with changes still to upload, in no particular order.
    public var pending: [UUID] { canvases.compactMap { $0.value.pending ? UUID(uuidString: $0.key) : nil } }
}

/// One canvas's copy in Dropbox.
public struct CanvasSyncRecord: Codable, Hashable, Sendable {
    /// Its folder in `Dropbox/Vellum`, fixed at its first sync (or at its making, since #12).
    public var folder: String
    /// What is uploaded.
    public var uploaded: SyncedPosition
    /// Dropbox's revisions of the `canvas.json` and `ink.snapshot` Vellum last wrote, so an upload replaces only those
    /// (`update`), and a file changed in Dropbox meanwhile is noticed.
    public var manifestRev: String?
    public var snapshotRev: String?
    /// Log generations whose parts a newer snapshot has replaced, still to be deleted from Dropbox.
    public var staleLogGenerations: [UInt64]
    /// Whether the Duo holds changes Dropbox doesn't have: the outbox entry.
    public var pending: Bool
    /// Bumped every time the canvas is queued, so a sync that started before the last change doesn't clear `pending`.
    public var queued: Int
    /// Upload everything again and replace whatever Dropbox holds: after a file changed in Dropbox underneath, or a
    /// sign-out (the next sign-in may be another Dropbox).
    public var replaceAll: Bool
    /// Times Dropbox's copy had been changed by something other than this Duo, and the Duo's replaced it (Dropbox
    /// keeps the replaced version in its version history).
    public var replaced: [SyncReplacement]

    public init(folder: String) {
        self.folder = folder
        uploaded = .nothing
        staleLogGenerations = []
        pending = true
        queued = 1
        replaceAll = false
        replaced = []
    }
}

/// A file in Dropbox the Duo found changed underneath it and replaced with its own copy.
public struct SyncReplacement: Codable, Hashable, Sendable {
    public var file: String
    public var at: Date

    public init(file: String, at: Date) {
        self.file = file
        self.at = at
    }
}

/// A canvas deleted on the Duo whose Dropbox folder is still to be moved to `Vellum/.deleted`.
public struct PendingDelete: Codable, Hashable, Sendable {
    public var id: UUID
    public var folder: String

    public init(id: UUID, folder: String) {
        self.id = id
        self.folder = folder
    }
}

/// Where the ledger is kept.
public protocol SyncLedgerStore: Sendable {
    /// The ledger kept, or an empty one when there is none (or it can't be read).
    func load() -> SyncLedger
    func save(_ ledger: SyncLedger) throws
}

/// The ledger in a file, written whole and flushed to storage each time (write, flush, rename), so a crash leaves the
/// old ledger or the new one, never half of one.
public struct SyncLedgerFile: SyncLedgerStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `Application Support/Sync/ledger.json`.
    public static func onThisDevice() throws -> SyncLedgerFile {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return SyncLedgerFile(url: support.appendingPathComponent("Sync", isDirectory: true)
            .appendingPathComponent("ledger.json"))
    }

    public func load() -> SyncLedger {
        guard let bytes = try? DurableFile.read(url) else { return SyncLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SyncLedger.self, from: Data(bytes))) ?? SyncLedger()
    }

    public func save(_ ledger: SyncLedger) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ledger)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFile.writeAtomically([UInt8](data), to: url)
    }
}

/// A ledger in memory, for tests and the made-up Dropbox's captures.
public final class SyncLedgerMemory: SyncLedgerStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ledger: SyncLedger
    public private(set) var saves = 0

    public init(_ ledger: SyncLedger = SyncLedger()) { self.ledger = ledger }

    public func load() -> SyncLedger { lock.withLock { ledger } }
    public func save(_ ledger: SyncLedger) throws {
        lock.withLock {
            self.ledger = ledger
            saves += 1
        }
    }
}
