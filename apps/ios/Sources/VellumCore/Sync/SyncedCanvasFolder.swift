import Foundation

/// A canvas folder as Dropbox holds it (#12), and the rule that turns it back into the Duo's files, for the laptop
/// and the tests (ADR-0014's #12 amendment):
///
/// - `canvas.json`, `ink.snapshot` (absent until the canvas's first compaction) and `sheets/<hash>.pdf` are the Duo's
///   files as they are.
/// - The log is in parts, `ink.log.parts/<generation>/<offset>.part`. Take the snapshot's generation (0 with no
///   snapshot); start at that generation's part at offset 0, and append each next part, the one whose offset is where
///   the log so far ends, until there is none. That is the Duo's `ink.log`. Parts of other generations, and parts not in
///   that chain, are left over from before and ignored.
public enum SyncedCanvasFolder {
    public struct Rebuilt: Hashable, Sendable {
        public var manifest: [UInt8]
        public var snapshot: [UInt8]?
        public var log: [UInt8]
        public var sheets: [String: [UInt8]]
    }

    public enum RebuildError: Error, Equatable {
        case noManifest
        case noLog(generation: UInt64)
    }

    /// Rebuilds the Duo's files from the files of a canvas folder in Dropbox, keyed by their path inside the folder
    /// ("canvas.json", "ink.log.parts/3/000000000016.part").
    public static func rebuild(_ files: [String: [UInt8]]) throws -> Rebuilt {
        guard let manifest = files[SyncPlan.manifestFile] else { throw RebuildError.noManifest }
        let snapshot = files[SyncPlan.snapshotFile]
        let generation = snapshot.flatMap { SyncCaptureReader.generation(in: $0, magic: InkStore.snapshotMagic) } ?? 0
        var log: [UInt8] = []
        while let part = files[SyncPlan.logPartFile(generation: generation, offset: log.count)], !part.isEmpty {
            log += part
        }
        guard !log.isEmpty else { throw RebuildError.noLog(generation: generation) }
        var sheets: [String: [UInt8]] = [:]
        let prefix = CanvasLibrary.sheetsFolderName + "/"
        for (path, bytes) in files where path.hasPrefix(prefix) && path.hasSuffix(".pdf") {
            sheets[String(path.dropFirst(prefix.count).dropLast(4))] = bytes
        }
        return Rebuilt(manifest: manifest, snapshot: snapshot, log: log, sheets: sheets)
    }

    /// Writes rebuilt files out as a canvas folder the Duo's `InkStore` opens.
    public static func write(_ rebuilt: Rebuilt, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(rebuilt.manifest).write(to: folder.appendingPathComponent(CanvasManifest.fileName))
        if let snapshot = rebuilt.snapshot {
            try Data(snapshot).write(to: folder.appendingPathComponent(InkStore.snapshotName))
        }
        try Data(rebuilt.log).write(to: folder.appendingPathComponent(InkStore.logName))
        if !rebuilt.sheets.isEmpty {
            let sheets = folder.appendingPathComponent(CanvasLibrary.sheetsFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
            for (name, bytes) in rebuilt.sheets { try Data(bytes).write(to: sheets.appendingPathComponent(name + ".pdf")) }
        }
    }
}
