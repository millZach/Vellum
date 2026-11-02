import Foundation

/// One request's worth of syncing a canvas.
public enum SyncStep: Hashable, Sendable {
    /// A sheet's PDF, `sheets/<name>.pdf`: uploaded once, ever. Its name is its content hash, so a file already there
    /// holds the same bytes.
    case sheet(String)
    /// `canvas.json`, when its bytes changed: a rename or new canvas units.
    case manifest
    /// The log's new whole records as one part, `ink.log.parts/<generation>/<offset>.part`.
    case logPart(generation: UInt64, offset: Int)
    /// The snapshot, after a compaction: uploaded once per compaction.
    case snapshot(generation: UInt64)
    /// A replaced generation's log parts, once the snapshot that replaces them is in Dropbox.
    case deleteLogGeneration(UInt64)
}

/// What a sync uploads: only what changed since Dropbox last heard (ADR-0014's #12 amendment).
///
/// Dropbox has no append, so the log goes up in parts: each sync uploads the log's whole records since the last as one
/// file named by the generation and the byte offset it starts at. Within a generation the Duo's log only ever grows,
/// so every part holds exactly the Duo's bytes at its offset, and joining a generation's parts from offset 0, each
/// starting where the one before ends, gives the Duo's `ink.log` (`SyncedCanvasFolder`). A compaction starts a new
/// generation: its snapshot and the new log's first part go up, then the old generation's parts are deleted.
///
/// The order keeps Dropbox's copy whole at every step for the laptop: a sheet's PDF before the log that places it;
/// the new generation's first part before the snapshot that needs it, and the old generation's parts until after.
public enum SyncPlan {
    public static func steps(for capture: CanvasSyncCapture, record: CanvasSyncRecord) -> [SyncStep] {
        var steps: [SyncStep] = []
        for name in capture.sheets where !record.uploaded.sheets.contains(name) { steps.append(.sheet(name)) }
        if digest(capture.manifestBytes) != record.uploaded.manifestDigest { steps.append(.manifest) }
        if capture.logRestarted { steps.append(.deleteLogGeneration(capture.logGeneration)) }
        if !capture.logBytes.isEmpty {
            steps.append(.logPart(generation: capture.logGeneration, offset: capture.logOffset))
        }
        if capture.snapshotBytes != nil { steps.append(.snapshot(generation: capture.snapshotGeneration)) }
        var stale = record.staleLogGenerations
        if let old = record.uploaded.logGeneration, old != capture.logGeneration, !stale.contains(old) { stale.append(old) }
        for generation in stale where generation != capture.logGeneration { steps.append(.deleteLogGeneration(generation)) }
        return steps
    }

    /// The SHA-256 of a file's bytes, in hex.
    public static func digest(_ bytes: [UInt8]) -> String {
        SHA256.hash(bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Paths in Dropbox

    public static let manifestFile = CanvasManifest.fileName
    public static let snapshotFile = InkStore.snapshotName
    /// The folder of the log's parts, one folder per generation.
    public static let logPartsFolder = "ink.log.parts"

    public static func logPartFile(generation: UInt64, offset: Int) -> String {
        let digits = String(offset)
        return "\(logPartsFolder)/\(generation)/\(String(repeating: "0", count: max(0, 12 - digits.count)))\(digits).part"
    }

    public static func logGenerationFolder(_ generation: UInt64) -> String { "\(logPartsFolder)/\(generation)" }

    public static func sheetFile(_ name: String) -> String { "\(CanvasLibrary.sheetsFolderName)/\(name).pdf" }
}
