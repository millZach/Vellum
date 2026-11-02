import Foundation

/// Which canvases' Dropbox folders are missing something the sync ledger says Dropbox holds (#37): a canvas folder
/// deleted on the laptop, or a `canvas.json`, snapshot, sheet PDF or log part deleted from one. Each of those canvases
/// is uploaded whole again, so the laptop sees a complete canvas folder.
///
/// Dropbox gives no upload mode that fails when a file's folder is missing (an upload makes every folder on its path),
/// so a normal sync can't notice. Instead `CanvasSync` asks Dropbox once, when the engine starts, when the connection
/// returns and when the app comes back to the foreground, and only when there is something to upload: the first time
/// a recursive listing of `Vellum/`, after that only what changed since (`list_folder/continue` with the cursor kept in
/// the ledger), which is usually a few entries.
public enum SyncFolderCheck {
    /// What the ledger notes as replaced (`SyncReplacement.file`) when a canvas's folder was missing files.
    public static let folderMissing = "folder"

    /// The files a canvas's Dropbox folder holds by the ledger, by their lower-cased path, and its log's generation
    /// folder (nil before any of the log is uploaded).
    public static func expected(_ record: CanvasSyncRecord) -> (files: [String], logFolder: String?) {
        let base = SyncPaths.folder(record.folder).lowercased()
        var files: [String] = []
        if record.uploaded.manifestDigest != nil { files.append("\(base)/\(SyncPlan.manifestFile)".lowercased()) }
        if record.uploaded.snapshotGeneration != nil { files.append("\(base)/\(SyncPlan.snapshotFile)".lowercased()) }
        for name in record.uploaded.sheets.sorted() { files.append("\(base)/\(SyncPlan.sheetFile(name))".lowercased()) }
        var logFolder: String?
        if let generation = record.uploaded.logGeneration, record.uploaded.logOffset > 0 {
            files.append("\(base)/\(SyncPlan.logPartFile(generation: generation, offset: 0))".lowercased())
            logFolder = "\(base)/\(SyncPlan.logGenerationFolder(generation))".lowercased()
        }
        return (files, logFolder)
    }

    /// The canvases worth checking: those with something uploaded that isn't already going up whole.
    public static func checked(_ ledger: SyncLedger) -> [UUID: CanvasSyncRecord] {
        var out: [UUID: CanvasSyncRecord] = [:]
        for (key, record) in ledger.canvases where !record.replaceAll && record.uploaded != .nothing {
            if let id = UUID(uuidString: key) { out[id] = record }
        }
        return out
    }

    /// From a full recursive listing of `Vellum/`: the canvases with a file the ledger expects not in it.
    public static func incomplete(inTree entries: [DropboxTreeEntry], _ records: [UUID: CanvasSyncRecord]) -> Set<UUID> {
        let present = Set(entries.filter { $0.kind == .file }.map(\.path))
        return Set(records.compactMap { entry -> UUID? in
            expected(entry.value).files.allSatisfy(present.contains) ? nil : entry.key
        })
    }

    /// From what changed since the last check, in Dropbox's order: the canvases with an expected file deleted and not
    /// written again after, or any of the current log generation's parts deleted. A deleted folder takes everything in
    /// it, and a file written into it afterwards brings back only that file.
    public static func incomplete(afterChanges entries: [DropboxTreeEntry], _ records: [UUID: CanvasSyncRecord])
        -> Set<UUID> {
        var deleted: Set<String> = []
        var present: Set<String> = []
        for entry in entries {
            switch entry.kind {
            case .deleted:
                deleted.insert(entry.path)
                present = present.filter { !within($0, entry.path) }
            case .file:
                present.insert(entry.path)
            case .folder:
                break
            }
        }
        guard !deleted.isEmpty else { return [] }
        return Set(records.compactMap { entry -> UUID? in
            let id = entry.key
            let (files, logFolder) = expected(entry.value)
            for file in files where !present.contains(file) && deleted.contains(where: { within(file, $0) }) {
                return id
            }
            if let logFolder {
                for gone in deleted where within(logFolder, gone) || (within(gone, logFolder) && !present.contains(gone)) {
                    return id
                }
            }
            return nil
        })
    }

    /// Whether `path` is `folder` or inside it.
    static func within(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }
}
