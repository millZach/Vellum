#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation

/// A canvas's ink on the Duo (ADR-0014): a snapshot of the ink and its undo history, and an append-only log of every
/// change since.
///
/// Each change is appended to the log with a plain `write` as it happens. That puts it in the kernel's file cache at
/// once, which survives the app crashing, being force-quit or being killed by iOS, so those lose at most the stroke
/// still being drawn. Only a sudden power cut can lose what the cache has not yet written out, so `flush` pushes it to
/// storage with `F_FULLFSYNC` in batches: every few seconds while drawing, and when the app leaves the screen. When the
/// log outgrows the snapshot, it is compacted into a new snapshot at a quiet moment, in three steps so the slow one
/// (encoding and writing the snapshot) can run on another queue while changes keep being appended: `beginCompaction`,
/// `writeSnapshot`, `finishCompaction`.
///
/// Every step is ordered so a failure or a crash at any point leaves files that reopen with every change appended:
/// the new snapshot records where in the old log it was taken, so until the new log replaces the old one, the old
/// log's changes after that point are replayed on top of it.
///
/// Not thread-safe: the app keeps one per open canvas on its saver's serial queue, off the main thread. Only
/// `writeSnapshot`, which touches nothing of the store's, runs elsewhere.
public final class InkStore {
    /// The file names inside a canvas folder.
    public static let snapshotName = "ink.snapshot"
    public static let logName = "ink.log"

    /// What opening found and set right.
    public struct Recovery: Hashable, Sendable {
        /// Bytes at the end of the log that were not a whole record (a record cut short by a crash), and were dropped.
        public var droppedBytes = 0
        /// Whether the log was left over from before the last compaction and set aside, its changes already in the
        /// snapshot.
        public var discardedStaleLog = false
        /// Changes the old log held after the point the snapshot was taken, carried into the new log because
        /// compaction stopped before it replaced the log.
        public var carriedEvents = 0
        /// How many changes the log replayed on top of the snapshot.
        public var replayedEvents = 0
    }

    public enum OpenError: Error, CustomStringConvertible {
        case notInkFile(String)
        case unsupportedVersion(String, UInt16)
        case damagedSnapshot(String)
        case logAheadOfSnapshot

        public var description: String {
            switch self {
            case .notInkFile(let name): "\(name) is not a Vellum ink file"
            case .unsupportedVersion(let name, let version): "\(name) is version \(version), newer than this Vellum"
            case .damagedSnapshot(let reason): "The ink snapshot is damaged: \(reason)"
            case .logAheadOfSnapshot: "The ink log is newer than its snapshot"
            }
        }
    }

    /// Why the store refuses to append until it is reopened, rather than risk a change that would not reopen.
    public struct WriterLost: StorageFailure, CustomStringConvertible {
        public let reason: String
        public var isOutOfSpace: Bool { false }
        public var description: String { "The ink log can't be written: \(reason)" }
    }

    static let version: UInt16 = 1
    static let snapshotMagic: [UInt8] = Array("VINK".utf8)
    static let logMagic: [UInt8] = Array("VLOG".utf8)
    /// The log's header: magic (4), version (2), reserved (2), generation (8).
    static let headerSize = 16
    /// The snapshot's header: the same, then where in the previous generation's log the snapshot was taken (8).
    static let snapshotHeaderSize = 24

    public let folder: URL
    /// The ink and undo history exactly as saved: the snapshot with every logged change replayed on it.
    public private(set) var session: InkSession
    public let recovery: Recovery
    /// The log is compacted into a new snapshot once it is larger than both this and the snapshot.
    public var compactionThreshold: Int

    /// The snapshot's generation, and the log's: the same except while a compaction's new log is still to replace the
    /// old one, when the log is one behind.
    private var generation: UInt64
    private var logGeneration: UInt64
    private var logFD: Int32
    private var logSize: Int
    private var snapshotSize: Int
    /// Whether the log on disk may be longer than `logSize` (a torn write whose trim failed), so it must be trimmed
    /// before anything else is appended.
    private var logEndUncertain = false
    /// Whether a rename's folder entry may not have reached storage yet; the next `flush` retries it.
    private var folderNeedsFlush = false
    /// Set between `beginCompaction` and `finishCompaction` or `cancelCompaction`.
    private var compacting: CompactionPlan?
    /// The records appended to the log since the compaction in progress (or the one awaiting its new log) was
    /// planned: what the new log must start with.
    private var carryOver: [UInt8] = []
    private var isClosed = false

    private var snapshotURL: URL { folder.appendingPathComponent(Self.snapshotName) }
    private var logURL: URL { folder.appendingPathComponent(Self.logName) }
    private static func temporaryURL(_ name: String, in folder: URL) -> URL {
        folder.appendingPathComponent(".\(name).compacting")
    }

    /// Opens the ink in a canvas folder, creating empty ink if there is none. A log whose last record was cut short
    /// opens without it and is trimmed back to its last whole record; that is never an error.
    public init(folder: URL, compactionThreshold: Int = 1 << 20) throws {
        self.folder = folder
        self.compactionThreshold = compactionThreshold
        var recovery = Recovery()
        let snapshotURL = folder.appendingPathComponent(Self.snapshotName)
        let logURL = folder.appendingPathComponent(Self.logName)
        // A compaction stopped part way leaves its unfinished files; what they hold is still in the snapshot and log.
        for name in [Self.snapshotName, Self.logName] { unlink(Self.temporaryURL(name, in: folder).path) }

        // The snapshot: written whole by rename, so it is either there and complete or not there.
        var session = InkSession()
        var generation: UInt64 = 0
        var takenAt = Self.headerSize
        var snapshotSize = 0
        if let bytes = try DurableFile.read(snapshotURL) {
            (generation, takenAt) = try Self.readSnapshotHeader(bytes)
            let (payloads, end) = InkCodec.unframe(bytes, from: Self.snapshotHeaderSize)
            guard payloads.count == 1, end == bytes.count else { throw OpenError.damagedSnapshot("checksum or length") }
            do {
                session = try InkCodec.decodeSession(payloads[0])
            } catch {
                throw OpenError.damagedSnapshot("\(error)")
            }
            snapshotSize = bytes.count
        }

        // The log: every change since the snapshot, the last one possibly cut short.
        var logSize = Self.headerSize
        var freshLog: [UInt8]?
        if let bytes = try DurableFile.read(logURL), bytes.count >= Self.headerSize {
            let logGeneration = try Self.readHeader(bytes, magic: Self.logMagic, name: Self.logName)
            if logGeneration > generation {
                throw OpenError.logAheadOfSnapshot
            } else if logGeneration == generation {
                let good = Self.replay(bytes, from: Self.headerSize, onto: &session, count: &recovery.replayedEvents)
                recovery.droppedBytes = bytes.count - good
                logSize = good
            } else if logGeneration + 1 == generation, takenAt <= bytes.count {
                // Compaction committed the new snapshot and stopped before the new log replaced the old one. The old
                // log's changes after the point the snapshot was taken are not in the snapshot: carry them over.
                let good = Self.replay(bytes, from: takenAt, onto: &session, count: &recovery.carriedEvents)
                recovery.discardedStaleLog = recovery.carriedEvents == 0
                freshLog = Self.header(magic: Self.logMagic, generation: generation) + Array(bytes[takenAt..<good])
            } else {
                // Older still: everything in it is in the snapshot.
                recovery.discardedStaleLog = true
                freshLog = Self.header(magic: Self.logMagic, generation: generation)
            }
        } else {
            freshLog = Self.header(magic: Self.logMagic, generation: generation)
        }

        if let freshLog {
            try DurableFile.writeAtomically(freshLog, to: logURL)
            logSize = freshLog.count
        }
        let fd = try DurableFile.open(logURL, flags: O_WRONLY | O_APPEND)
        if recovery.droppedBytes > 0 {
            do {
                try DurableFile.truncate(fd, to: logSize, path: logURL.path)
                try DurableFile.flush(fd, path: logURL.path)
            } catch {
                close(fd)
                throw error
            }
        }
        session.dropUnsavedEvents()
        self.session = session
        self.generation = generation
        self.logGeneration = generation
        self.snapshotSize = snapshotSize
        self.logSize = logSize
        self.logFD = fd
        self.recovery = recovery
    }

    deinit { if !isClosed { close(logFD) } }

    /// Replays a log's whole records from `offset` onto a session and returns where the last one replayed ends.
    private static func replay(_ bytes: [UInt8], from offset: Int, onto session: inout InkSession, count: inout Int) -> Int {
        let (payloads, _) = InkCodec.unframe(bytes, from: offset)
        var good = offset
        for payload in payloads {
            // A record that passes its checksum but does not decode is from a newer Vellum or damaged; stop there
            // rather than guess, and keep everything before it.
            guard let event = try? InkCodec.decodeEvent(payload) else { break }
            session.apply(event)
            count += 1
            good = payload.endIndex
        }
        return good
    }

    /// Lets go of the log. The store does nothing more after this; for a canvas being deleted or no longer open.
    public func closeFiles() {
        guard !isClosed else { return }
        isClosed = true
        close(logFD)
        if let plan = compacting { unlink(plan.temporarySnapshot.path) }
        compacting = nil
    }

    /// The bytes on the Duo: the snapshot and the log.
    public var bytesOnDisk: Int { snapshotSize + logSize }

    /// Names what is saved now, so a thumbnail can say which saved ink it shows: it changes with every append and
    /// every compaction.
    public var savedVersion: String { "\(generation).\(logGeneration).\(logSize)" }

    /// Appends changes to the end of the log: one `write`, the new changes' bytes only, never the canvas. If the write
    /// fails (the Duo is full), the log is trimmed back to before the attempt and nothing here changes, so the same
    /// changes can be appended again later. If the trim fails too, nothing more is appended until a later attempt
    /// trims it, so a torn record never sits in front of a later change.
    public func append(_ events: [InkEvent]) throws {
        guard !events.isEmpty else { return }
        guard !isClosed else { throw WriterLost(reason: "the canvas was closed") }
        if logEndUncertain { try restoreLogEnd() }
        var bytes: [UInt8] = []
        for event in events { InkCodec.frame(InkCodec.encode(event), into: &bytes) }
        do {
            try DurableFile.write(bytes, to: logFD, path: logURL.path)
        } catch {
            // Leave no partial record behind for the next append to follow.
            logEndUncertain = true
            try? restoreLogEnd()
            throw error
        }
        logSize += bytes.count
        if compacting != nil || logGeneration != generation { carryOver += bytes }
        hasUnflushedChanges = true
        for event in events { session.apply(event) }
        session.dropUnsavedEvents()
    }

    /// Trims the log back to its last whole record after a write that may have left part of one.
    private func restoreLogEnd() throws {
        let size = try DurableFile.size(of: logFD, path: logURL.path)
        if size > logSize { try DurableFile.truncate(logFD, to: logSize, path: logURL.path) }
        logEndUncertain = false
    }

    /// Whether changes have been appended since the last `flush`: they survive a crash, not yet a power cut.
    public private(set) var hasUnflushedChanges = false

    /// Whether anything is waiting to reach storage: appended changes, or a compaction's last steps.
    public var needsFlush: Bool { hasUnflushedChanges || folderNeedsFlush || logGeneration != generation }

    /// Pushes appended changes from the file cache to storage with `F_FULLFSYNC`, so they survive a power cut too. It
    /// also finishes what a failed compaction left: the new log, and a folder flush after a rename.
    public func flush() throws {
        guard !isClosed else { return }
        if hasUnflushedChanges {
            try DurableFile.flush(logFD, path: logURL.path)
            hasUnflushedChanges = false
        }
        if logGeneration != generation, compacting == nil { try replaceLog() }
        if folderNeedsFlush {
            try DurableFile.flushFolder(folder)
            folderNeedsFlush = false
        }
    }

    // MARK: Compaction

    /// Whether the log has grown past the snapshot, so it is time to compact at the next quiet moment.
    public var needsCompaction: Bool {
        !isClosed && compacting == nil && logGeneration == generation && logSize > max(compactionThreshold, snapshotSize)
    }

    /// What a compaction writes: the ink and undo history as they were at one point in the log.
    public struct CompactionPlan: Sendable {
        let session: InkSession
        let generation: UInt64
        let takenAt: Int
        let temporarySnapshot: URL
    }

    /// A compaction's snapshot written to storage under a temporary name, ready to be put in place.
    public struct PreparedSnapshot: Sendable {
        let plan: CompactionPlan
        let size: Int
    }

    /// Starts a compaction: takes the ink and undo history as they are now. Nil when one is already under way, or a
    /// failed one's new log is still to be written (the next `flush` writes it).
    public func beginCompaction() -> CompactionPlan? {
        guard !isClosed, compacting == nil, logGeneration == generation else { return nil }
        let plan = CompactionPlan(session: session, generation: generation + 1, takenAt: logSize,
                                  temporarySnapshot: Self.temporaryURL(Self.snapshotName, in: folder))
        compacting = plan
        carryOver = []
        return plan
    }

    /// Encodes the snapshot and writes it to storage under a temporary name. The slow step: it touches nothing of the
    /// store's, so it runs on another queue while changes keep being appended.
    public static func writeSnapshot(_ plan: CompactionPlan) throws -> PreparedSnapshot {
        var w = ByteWriter()
        w.raw(snapshotMagic)
        w.u16(version)
        w.u16(0)
        w.u64(plan.generation)
        w.u64(UInt64(plan.takenAt))
        var bytes = w.bytes
        InkCodec.frame(InkCodec.encode(plan.session), into: &bytes)
        let fd = try DurableFile.open(plan.temporarySnapshot, flags: O_WRONLY | O_CREAT | O_TRUNC)
        do {
            try DurableFile.write(bytes, to: fd, path: plan.temporarySnapshot.path)
            try DurableFile.flush(fd, path: plan.temporarySnapshot.path)
        } catch {
            close(fd)
            unlink(plan.temporarySnapshot.path)
            throw error
        }
        close(fd)
        return PreparedSnapshot(plan: plan, size: bytes.count)
    }

    /// Puts the new snapshot in place, then starts the new log with the changes appended since the plan.
    ///
    /// The snapshot's rename is the commit: before it, the old snapshot and log hold everything; after it, the new
    /// snapshot and the old log's changes after `takenAt` do. If the rename fails, the compaction is abandoned and
    /// nothing has changed. If the new log can't be written, appends carry on into the old log, which still reopens
    /// correctly, and the next `flush` tries the new log again; it throws so the caller can say so.
    public func finishCompaction(_ prepared: PreparedSnapshot) throws {
        guard !isClosed, let plan = compacting, plan.temporarySnapshot == prepared.plan.temporarySnapshot,
              plan.generation == prepared.plan.generation else {
            unlink(prepared.plan.temporarySnapshot.path)
            return
        }
        do {
            try DurableFile.move(plan.temporarySnapshot, to: snapshotURL)
        } catch {
            cancelCompaction()
            throw error
        }
        compacting = nil
        generation = plan.generation
        snapshotSize = prepared.size
        folderNeedsFlush = true
        try replaceLog()
        try flush()
    }

    /// Abandons a compaction in progress: the old snapshot and log stay as they were.
    public func cancelCompaction() {
        guard let plan = compacting else { return }
        unlink(plan.temporarySnapshot.path)
        compacting = nil
        carryOver = []
    }

    /// Replaces the old log with a new one of the snapshot's generation holding the changes carried over. The new log
    /// is written and opened under a temporary name first, so the rename swaps the file and the descriptor appends go
    /// to in one step: nothing is ever appended to a log that has been replaced.
    private func replaceLog() throws {
        let temporary = Self.temporaryURL(Self.logName, in: folder)
        let bytes = Self.header(magic: Self.logMagic, generation: generation) + carryOver
        let fd = try DurableFile.open(temporary, flags: O_WRONLY | O_CREAT | O_TRUNC | O_APPEND)
        do {
            try DurableFile.write(bytes, to: fd, path: temporary.path)
            try DurableFile.flush(fd, path: temporary.path)
            try DurableFile.move(temporary, to: logURL)
        } catch {
            close(fd)
            unlink(temporary.path)
            throw error
        }
        close(logFD)
        logFD = fd
        logGeneration = generation
        logSize = bytes.count
        carryOver = []
        logEndUncertain = false
        hasUnflushedChanges = false
        folderNeedsFlush = true
    }

    /// Compacts in one go, on the calling thread: the three steps back to back.
    public func compact() throws {
        if logGeneration != generation { try replaceLog() }
        guard let plan = beginCompaction() else { return }
        let prepared: PreparedSnapshot
        do {
            prepared = try Self.writeSnapshot(plan)
        } catch {
            cancelCompaction()
            throw error
        }
        try finishCompaction(prepared)
    }

    static func header(magic: [UInt8], generation: UInt64) -> [UInt8] {
        var w = ByteWriter()
        w.raw(magic)
        w.u16(version)
        w.u16(0)
        w.u64(generation)
        return w.bytes
    }

    private static func readHeader(_ bytes: [UInt8], magic: [UInt8], name: String) throws -> UInt64 {
        guard bytes.count >= headerSize, Array(bytes[0..<4]) == magic else { throw OpenError.notInkFile(name) }
        var r = ByteReader(bytes[4..<headerSize])
        let version = try r.u16()
        guard version <= Self.version else { throw OpenError.unsupportedVersion(name, version) }
        _ = try r.u16()
        return try r.u64()
    }

    /// The snapshot's generation and where in the previous generation's log it was taken.
    private static func readSnapshotHeader(_ bytes: [UInt8]) throws -> (UInt64, Int) {
        let generation = try readHeader(bytes, magic: snapshotMagic, name: snapshotName)
        guard bytes.count >= snapshotHeaderSize else { throw OpenError.damagedSnapshot("header cut short") }
        var r = ByteReader(bytes[headerSize..<snapshotHeaderSize])
        return (generation, Int(clamping: try r.u64()))
    }
}

/// When an open canvas's appended changes are flushed from the file cache to storage: once `interval` after the first
/// append since the last flush, so continuous drawing costs one flush every `interval` seconds however many strokes it
/// makes, and immediately when the app leaves the screen (ADR-0014). The interval bounds what a sudden power cut can
/// take; a crash or a kill takes nothing appended.
public struct FlushSchedule: Hashable, Sendable {
    public static let interval: Double = 3

    /// Whether a flush is already scheduled.
    public private(set) var isPending = false

    public init() {}

    /// After an append: true when a flush should be scheduled `interval` from now, false when one already is.
    public mutating func didAppend() -> Bool {
        guard !isPending else { return false }
        isPending = true
        return true
    }

    /// The scheduled flush has run.
    public mutating func didFlush() { isPending = false }
}

extension InkSession {
    /// Forgets unsaved events without returning them: for a session rebuilt from what is already on the Duo.
    mutating func dropUnsavedEvents() { _ = takeEvents() }
}
