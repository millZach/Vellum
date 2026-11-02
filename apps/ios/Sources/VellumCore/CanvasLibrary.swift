import Foundation

/// What a canvas folder says about its canvas besides the ink: its name and canvas units. Kept as `canvas.json`, plain
/// JSON a person or the laptop can read once #12 syncs the folder to Dropbox.
public struct CanvasManifest: Codable, Hashable, Sendable {
    public static let fileName = "canvas.json"
    public static let currentFormat = 1

    public var format: Int
    public var id: UUID
    public var name: String
    /// The canvas units' stored name; an unknown one (from a newer Vellum) reads as the default.
    public var units: String
    public var created: Date
    /// The canvas's folder name in `Dropbox/Vellum` (#12): its name when it was made and a short id, fixed then and
    /// never renamed. Nil for a canvas made before #12, whose folder is named when it is first synced.
    public var dropboxFolder: String?

    public init(id: UUID, name: String, units: CanvasUnits, created: Date, dropboxFolder: String? = nil) {
        format = Self.currentFormat
        self.id = id
        self.name = name
        self.units = units.rawValue
        self.created = created
        self.dropboxFolder = dropboxFolder
    }

    public var canvasUnits: CanvasUnits {
        get { CanvasUnits(rawValue: units) ?? .default }
        set { units = newValue.rawValue }
    }
}

/// A canvas as the Canvases list shows it.
public struct CanvasSummary: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var units: CanvasUnits
    public var created: Date
    /// When its ink, name or units last changed.
    public var modified: Date
}

/// Every canvas on the Duo: one folder per canvas under `root`, named by the canvas's id so renaming never moves it.
/// Each folder holds `canvas.json` (name and canvas units), `ink.snapshot` and `ink.log` (ADR-0014), and since #11 a
/// `sheets` folder with the PDFs its sheets show, one file per PDF named by its Dropbox content hash; nothing else, so
/// #12 can mirror the folders to `Dropbox/Vellum` as they are.
///
/// Making and deleting a canvas are atomic: a new canvas is built in a hidden folder and renamed into place, and a
/// deleted one is renamed out of sight before it is removed, so a crash never leaves half a canvas in the list.
public struct CanvasLibrary: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The canvases in the app's own container: `Application Support/Canvases`, not iCloud and not the Files app.
    public static func onThisDevice() throws -> CanvasLibrary {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return CanvasLibrary(root: support.appendingPathComponent("Canvases", isDirectory: true))
    }

    public func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Every canvas, most recently changed first. A folder without a readable `canvas.json` is skipped, not fatal.
    public func list() throws -> [CanvasSummary] {
        try ensureRoot()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var summaries: [CanvasSummary] = []
        for name in names where !name.hasPrefix(".") {
            guard let id = UUID(uuidString: name), let summary = try? summary(for: id) else { continue }
            summaries.append(summary)
        }
        return summaries.sorted { ($0.modified, $0.created) > ($1.modified, $1.created) }
    }

    public func summary(for id: UUID) throws -> CanvasSummary {
        let folder = folder(for: id)
        let manifest = try readManifest(in: folder)
        var modified = manifest.created
        for file in [CanvasManifest.fileName, InkStore.snapshotName, InkStore.logName] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file).path)
            if let date = attributes?[.modificationDate] as? Date, date > modified { modified = date }
        }
        return CanvasSummary(id: manifest.id, name: manifest.name, units: manifest.canvasUnits,
                             created: manifest.created, modified: modified)
    }

    /// Makes a new, empty canvas. A blank or missing name becomes the next free "Untitled canvas" name.
    @discardableResult
    public func create(name: String? = nil, units: CanvasUnits = .default, now: Date = Date()) throws -> CanvasSummary {
        try ensureRoot()
        let existing = (try? list().map(\.name)) ?? []
        let id = UUID()
        let named = CanvasName.cleaned(name ?? "") ?? CanvasName.untitled(after: existing)
        let manifest = CanvasManifest(id: id, name: named, units: units, created: now,
                                      dropboxFolder: SyncFolderName.make(name: named, id: id, taken: dropboxFolders()))
        let building = root.appendingPathComponent(".\(id.uuidString).creating", isDirectory: true)
        try FileManager.default.createDirectory(at: building, withIntermediateDirectories: true)
        do {
            try writeManifest(manifest, in: building)
            _ = try InkStore(folder: building)
            try FileManager.default.moveItem(at: building, to: folder(for: id))
            try DurableFile.flushFolder(root)
        } catch {
            try? FileManager.default.removeItem(at: building)
            throw error
        }
        return try summary(for: id)
    }

    /// Renames a canvas. A blank name is refused and the canvas keeps its old one; returns the name it has now.
    @discardableResult
    public func rename(_ id: UUID, to name: String) throws -> String {
        var manifest = try readManifest(in: folder(for: id))
        guard let cleaned = CanvasName.cleaned(name) else { return manifest.name }
        manifest.name = cleaned
        try writeManifest(manifest, in: folder(for: id))
        return cleaned
    }

    public func setUnits(_ id: UUID, to units: CanvasUnits) throws {
        var manifest = try readManifest(in: folder(for: id))
        guard manifest.canvasUnits != units else { return }
        manifest.canvasUnits = units
        try writeManifest(manifest, in: folder(for: id))
    }

    /// Deletes a canvas and all its ink from the Duo.
    public func delete(_ id: UUID) throws {
        let leaving = root.appendingPathComponent(".\(id.uuidString).deleting", isDirectory: true)
        try? FileManager.default.removeItem(at: leaving)
        try FileManager.default.moveItem(at: folder(for: id), to: leaving)
        try DurableFile.flushFolder(root)
        try FileManager.default.removeItem(at: leaving)
    }

    /// Every canvas's Dropbox folder name that is fixed in its `canvas.json`.
    public func dropboxFolders() -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var folders: Set<String> = []
        for name in names where !name.hasPrefix(".") {
            if let id = UUID(uuidString: name), let folder = try? manifest(for: id).dropboxFolder { folders.insert(folder) }
        }
        return folders
    }

    public func manifest(for id: UUID) throws -> CanvasManifest {
        try readManifest(in: folder(for: id))
    }

    /// Opens a canvas's ink for drawing on and saving.
    public func openInk(_ id: UUID, compactionThreshold: Int = 1 << 20) throws -> InkStore {
        try InkStore(folder: folder(for: id), compactionThreshold: compactionThreshold)
    }

    // MARK: Sheets' PDFs (#11)

    /// The folder in a canvas's folder that holds its sheets' PDFs.
    public static let sheetsFolderName = "sheets"

    /// Where a sheet's PDF is kept in a canvas's folder: `sheets/<name>.pdf`.
    public func sheetPDF(named name: String, in id: UUID) -> URL {
        folder(for: id).appendingPathComponent(Self.sheetsFolderName, isDirectory: true)
            .appendingPathComponent(name + ".pdf")
    }

    /// Keeps a PDF in a canvas's folder, written and flushed to storage, folder and all, before it returns, so the
    /// sheet placed on it never names a PDF the Duo could lose. A PDF already kept under the name is left as it is: the
    /// name is the PDF's content hash, so it holds the same bytes. Returns whether it wrote one.
    @discardableResult
    public func keepSheetPDF(from source: URL, named name: String, in id: UUID) throws -> Bool {
        let target = sheetPDF(named: name, in: id)
        if FileManager.default.fileExists(atPath: target.path) { return false }
        guard let bytes = try DurableFile.read(source) else { throw CocoaError(.fileNoSuchFile) }
        let sheets = target.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: sheets.path) {
            try FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
            try DurableFile.flushFolder(folder(for: id))
        }
        try DurableFile.writeAtomically(bytes, to: target)
        return true
    }

    /// Clears away the hidden folders a crash can leave mid-create or mid-delete.
    public func removeLeftovers() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(".") && (name.hasSuffix(".creating") || name.hasSuffix(".deleting")) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func readManifest(in folder: URL) throws -> CanvasManifest {
        let data = try Data(contentsOf: folder.appendingPathComponent(CanvasManifest.fileName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CanvasManifest.self, from: data)
    }

    private func writeManifest(_ manifest: CanvasManifest, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest) + Data("\n".utf8)
        try DurableFile.writeAtomically([UInt8](data), to: folder.appendingPathComponent(CanvasManifest.fileName))
    }
}

/// The rules for a canvas's name.
public enum CanvasName {
    public static let untitled = "Untitled canvas"

    /// A name with its surrounding space trimmed; nil when nothing is left.
    public static func cleaned(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "Untitled canvas", or "Untitled canvas 2", 3 and on when that is taken.
    public static func untitled(after existing: [String]) -> String {
        let taken = Set(existing)
        if !taken.contains(untitled) { return untitled }
        var n = 2
        while taken.contains("\(untitled) \(n)") { n += 1 }
        return "\(untitled) \(n)"
    }
}
