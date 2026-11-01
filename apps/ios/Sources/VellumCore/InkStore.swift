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
/// storage in batches: every few seconds while drawing, and when the app leaves the screen. When the log outgrows the
/// snapshot, `compact` folds the two into a new snapshot at a quiet moment.
///
/// Not thread-safe: the app keeps one per open canvas on a serial queue, off the main thread.
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

    static let version: UInt16 = 1
    static let snapshotMagic: [UInt8] = Array("VINK".utf8)
    static let logMagic: [UInt8] = Array("VLOG".utf8)
    /// magic (4), version (2), reserved (2), generation (8).
    static let headerSize = 16

    public let folder: URL
    /// The ink and undo history exactly as saved: the snapshot with every logged change replayed on it.
    public private(set) var session: InkSession
    public let recovery: Recovery
    /// The log is compacted into a new snapshot once it is larger than both this and the snapshot.
    public var compactionThreshold: Int

    private var generation: UInt64
    private var logFD: Int32
    private var logSize: Int
    private var snapshotSize: Int

    private var snapshotURL: URL { folder.appendingPathComponent(Self.snapshotName) }
    private var logURL: URL { folder.appendingPathComponent(Self.logName) }

    /// Opens the ink in a canvas folder, creating empty ink if there is none. A log whose last record was cut short
    /// opens without it and is trimmed back to its last whole record; that is never an error.
    public init(folder: URL, compactionThreshold: Int = 1 << 20) throws {
        self.folder = folder
        self.compactionThreshold = compactionThreshold
        var recovery = Recovery()
        let snapshotURL = folder.appendingPathComponent(Self.snapshotName)
        let logURL = folder.appendingPathComponent(Self.logName)

        // The snapshot: written whole by rename, so it is either there and complete or not there.
        var session = InkSession()
        var generation: UInt64 = 0
        var snapshotSize = 0
        if let bytes = try DurableFile.read(snapshotURL) {
            generation = try Self.readHeader(bytes, magic: Self.snapshotMagic, name: Self.snapshotName)
            let (payloads, end) = InkCodec.unframe(bytes, from: Self.headerSize)
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
        var needsFreshLog = true
        if let bytes = try DurableFile.read(logURL), bytes.count >= Self.headerSize {
            let logGeneration = try Self.readHeader(bytes, magic: Self.logMagic, name: Self.logName)
            if logGeneration < generation {
                // Compaction wrote the new snapshot and was stopped before it started a new log.
                recovery.discardedStaleLog = true
            } else if logGeneration > generation {
                throw OpenError.logAheadOfSnapshot
            } else {
                let (payloads, _) = InkCodec.unframe(bytes, from: Self.headerSize)
                var good = Self.headerSize
                for payload in payloads {
                    // A record that passes its checksum but does not decode is from a newer Vellum or damaged; stop
                    // there rather than guess, and keep everything before it.
                    guard let event = try? InkCodec.decodeEvent(payload) else { break }
                    session.apply(event)
                    recovery.replayedEvents += 1
                    good = payload.endIndex
                }
                recovery.droppedBytes = bytes.count - good
                logSize = good
                needsFreshLog = false
            }
        }

        if needsFreshLog {
            try DurableFile.writeAtomically(Self.header(magic: Self.logMagic, generation: generation), to: logURL)
            logSize = Self.headerSize
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
        self.snapshotSize = snapshotSize
        self.logSize = logSize
        self.logFD = fd
        self.recovery = recovery
    }

    deinit { close(logFD) }

    /// The bytes on the Duo: the snapshot and the log.
    public var bytesOnDisk: Int { snapshotSize + logSize }

    /// Appends changes to the end of the log: one `write`, the new changes' bytes only, never the canvas. If the write
    /// fails (the Duo is full), the log is trimmed back to before the attempt and nothing here changes, so the same
    /// changes can be appended again later.
    public func append(_ events: [InkEvent]) throws {
        guard !events.isEmpty else { return }
        var bytes: [UInt8] = []
        for event in events { InkCodec.frame(InkCodec.encode(event), into: &bytes) }
        do {
            try DurableFile.write(bytes, to: logFD, path: logURL.path)
        } catch {
            // Leave no partial record behind for the next append to follow.
            _ = ftruncate(logFD, off_t(logSize))
            throw error
        }
        logSize += bytes.count
        hasUnflushedChanges = true
        for event in events { session.apply(event) }
        session.dropUnsavedEvents()
    }

    /// Whether changes have been appended since the last `flush`: they survive a crash, not yet a power cut.
    public private(set) var hasUnflushedChanges = false

    /// Pushes appended changes from the file cache to storage, so they survive a power cut too.
    public func flush() throws {
        guard hasUnflushedChanges else { return }
        try DurableFile.flush(logFD, path: logURL.path, full: false)
        hasUnflushedChanges = false
    }

    /// Whether the log has grown past the snapshot, so it is time to `compact` at the next quiet moment.
    public var needsCompaction: Bool { logSize > max(compactionThreshold, snapshotSize) }

    /// Writes the ink and its undo history as a new snapshot and starts an empty log. The snapshot goes first, by
    /// rename, under the next generation; a crash before the new log is in place leaves the old log behind, which the
    /// next open recognises as already in the snapshot by its older generation.
    public func compact() throws {
        let next = generation + 1
        var snapshot = Self.header(magic: Self.snapshotMagic, generation: next)
        InkCodec.frame(InkCodec.encode(session), into: &snapshot)
        try DurableFile.writeAtomically(snapshot, to: snapshotURL)
        generation = next
        snapshotSize = snapshot.count
        try DurableFile.writeAtomically(Self.header(magic: Self.logMagic, generation: next), to: logURL)
        let fd = try DurableFile.open(logURL, flags: O_WRONLY | O_APPEND)
        close(logFD)
        logFD = fd
        logSize = Self.headerSize
        hasUnflushedChanges = false
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
