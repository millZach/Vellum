import Foundation

/// What Dropbox already holds of a canvas, as the sync ledger remembers it: enough to work out what changed.
public struct SyncedPosition: Codable, Hashable, Sendable {
    /// The generation of the snapshot uploaded, or nil when none is (a canvas never compacted has none on the Duo
    /// either).
    public var snapshotGeneration: UInt64?
    /// The generation of the log parts uploaded, and how many bytes of that log they hold from its start.
    public var logGeneration: UInt64?
    public var logOffset: Int
    /// The SHA-256 of the `canvas.json` uploaded, nil when none is.
    public var manifestDigest: String?
    /// The PDFs in `sheets/` uploaded, by name (their content hash), each once, ever.
    public var sheets: Set<String>

    public init(snapshotGeneration: UInt64? = nil, logGeneration: UInt64? = nil, logOffset: Int = 0,
                manifestDigest: String? = nil, sheets: Set<String> = []) {
        self.snapshotGeneration = snapshotGeneration
        self.logGeneration = logGeneration
        self.logOffset = logOffset
        self.manifestDigest = manifestDigest
        self.sheets = sheets
    }

    public static let nothing = SyncedPosition()
}

/// A canvas folder as it stands on the Duo, read for syncing on its saver's queue (`CanvasSaver.captureForSync`), so no
/// write, compaction or delete runs while it is read: only what Dropbox may not have yet is read whole.
public struct CanvasSyncCapture: Sendable {
    public var manifest: CanvasManifest
    /// `canvas.json` as it is on the Duo, byte for byte.
    public var manifestBytes: [UInt8]
    /// The snapshot's generation; 0 with no snapshot (a canvas never compacted).
    public var snapshotGeneration: UInt64
    /// The snapshot's bytes, read only when its generation is not the one Dropbox has; nil otherwise or when there is
    /// none.
    public var snapshotBytes: [UInt8]?
    /// The log's generation (always the snapshot's) and its whole records from `logOffset` to `logEnd`. At offset 0
    /// the bytes start with the log's header.
    public var logGeneration: UInt64
    public var logOffset: Int
    public var logBytes: [UInt8]
    public var logEnd: Int { logOffset + logBytes.count }
    /// Whether the log is shorter than Dropbox's copy of the same generation, which only damage on the Duo can do: its
    /// uploaded parts are thrown away and it is uploaded again from the start.
    public var logRestarted: Bool
    /// Every PDF in `sheets/`, by name.
    public var sheets: [String]
}

public enum CanvasSyncReadError: Error, Equatable, Sendable {
    /// The canvas is not on the Duo any more.
    case gone
    /// The folder's files are mid-compaction or torn; reading again after the saver has set them right works.
    case notReady
}

enum SyncCaptureReader {
    /// Reads what `known` says Dropbox lacks. `live` is the open store's position, which is authoritative; without
    /// one (the canvas is closed and nothing writes it), the files are read and only whole, readable records count,
    /// exactly what opening the canvas would keep.
    static func read(folder: URL, known: SyncedPosition, live: (generation: UInt64, logSize: Int)?) throws
        -> CanvasSyncCapture {
        let manifestURL = folder.appendingPathComponent(CanvasManifest.fileName)
        guard let manifestBytes = try DurableFile.read(manifestURL) else { throw CanvasSyncReadError.gone }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(CanvasManifest.self, from: Data(manifestBytes)) else {
            throw CanvasSyncReadError.notReady
        }

        // The snapshot: its header says its generation; it is read whole only when Dropbox has another.
        let snapshotURL = folder.appendingPathComponent(InkStore.snapshotName)
        var snapshotGeneration: UInt64 = 0
        var snapshotBytes: [UInt8]?
        if let header = try prefix(of: snapshotURL, count: InkStore.headerSize) {
            guard let generation = generation(in: header, magic: InkStore.snapshotMagic) else {
                throw CanvasSyncReadError.notReady
            }
            snapshotGeneration = generation
            if known.snapshotGeneration != generation {
                guard let bytes = try DurableFile.read(snapshotURL),
                      self.generation(in: bytes, magic: InkStore.snapshotMagic) == generation,
                      InkCodec.unframe(bytes, from: InkStore.snapshotHeaderSize).end == bytes.count
                else { throw CanvasSyncReadError.notReady }
                snapshotBytes = bytes
            }
        }
        if let live, live.generation != snapshotGeneration { throw CanvasSyncReadError.notReady }

        // The log: only the bytes past what Dropbox has, and only whole records.
        let logURL = folder.appendingPathComponent(InkStore.logName)
        guard let header = try prefix(of: logURL, count: InkStore.headerSize),
              let logGeneration = generation(in: header, magic: InkStore.logMagic),
              logGeneration == snapshotGeneration else { throw CanvasSyncReadError.notReady }
        let fileSize = try size(of: logURL)
        let size = live.map { min($0.logSize, fileSize) } ?? fileSize
        var start = 0
        var restarted = false
        if known.logGeneration == logGeneration, known.logOffset >= InkStore.headerSize {
            if known.logOffset <= size { start = known.logOffset } else { restarted = true }
        }
        var bytes = start == size ? [] : try range(of: logURL, from: start, to: size)
        if live == nil {
            // A closed canvas's log may end in a record cut short, or one this Vellum can't read, which opening it
            // would trim: never upload those.
            let from = start == 0 ? InkStore.headerSize : 0
            let (payloads, _) = InkCodec.unframe(bytes, from: from)
            var good = from
            for payload in payloads {
                guard (try? InkCodec.decodeEvent(payload)) != nil else { break }
                good = payload.endIndex
            }
            if good < bytes.count { bytes.removeSubrange(good...) }
            if start == 0 && bytes.count < InkStore.headerSize { throw CanvasSyncReadError.notReady }
        }

        let sheetsFolder = folder.appendingPathComponent(CanvasLibrary.sheetsFolderName, isDirectory: true)
        let sheets = ((try? FileManager.default.contentsOfDirectory(atPath: sheetsFolder.path)) ?? [])
            .filter { $0.hasSuffix(".pdf") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(4)) }
            .sorted()

        return CanvasSyncCapture(manifest: manifest, manifestBytes: manifestBytes, snapshotGeneration: snapshotGeneration,
                                 snapshotBytes: snapshotBytes, logGeneration: logGeneration, logOffset: start,
                                 logBytes: bytes, logRestarted: restarted, sheets: sheets)
    }

    /// An ink file's generation, from its header, if the header is whole and has the magic.
    static func generation(in bytes: [UInt8], magic: [UInt8]) -> UInt64? {
        guard bytes.count >= InkStore.headerSize, Array(bytes[0..<4]) == magic else { return nil }
        var reader = ByteReader(bytes[8..<InkStore.headerSize])
        return try? reader.u64()
    }

    private static func size(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    /// The first `count` bytes of a file, or nil when it does not exist.
    private static func prefix(of url: URL, count: Int) throws -> [UInt8]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try range(of: url, from: 0, to: count)
    }

    private static func range(of url: URL, from start: Int, to end: Int) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.read(upToCount: max(0, end - start)) ?? Data()
        return [UInt8](data)
    }
}
