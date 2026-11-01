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

    public init(id: UUID, name: String, units: CanvasUnits, created: Date) {
        format = Self.currentFormat
        self.id = id
        self.name = name
        self.units = units.rawValue
        self.created = created
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
/// Each folder holds `canvas.json` (name and canvas units), `ink.snapshot` and `ink.log` (ADR-0014), and nothing else,
/// so #12 can mirror the folders to `Dropbox/Vellum` as they are.
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
        let manifest = CanvasManifest(id: id, name: CanvasName.cleaned(name ?? "") ?? CanvasName.untitled(after: existing),
                                      units: units, created: now)
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

    public func manifest(for id: UUID) throws -> CanvasManifest {
        try readManifest(in: folder(for: id))
    }

    /// Opens a canvas's ink for drawing on and saving.
    public func openInk(_ id: UUID, compactionThreshold: Int = 1 << 20) throws -> InkStore {
        try InkStore(folder: folder(for: id), compactionThreshold: compactionThreshold)
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
