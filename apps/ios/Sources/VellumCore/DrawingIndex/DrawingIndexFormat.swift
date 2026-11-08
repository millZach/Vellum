import Foundation

/// The drawing index, format 1, as the laptop indexer writes it to `Dropbox/Vellum/Index` (ADR-0017,
/// `docs/drawing-index-format.md`). The Duo reads it and never writes it. Keys a reader does not know are ignored, so the
/// laptop can add one without a new format; a format other than 1 is refused and the Duo keeps the copy it has.
public enum DrawingIndexFormat {
    /// The one format this Vellum reads.
    public static let supported = 1
    /// The index's folder in Dropbox.
    public static let folder = SyncPaths.root + "/Index"
    /// The index manifest's file name in that folder.
    public static let manifestName = "index.json"

    /// The name a shard or thumbnail of these bytes has: the first 32 hex digits of their SHA-256.
    public static func contentName(of bytes: [UInt8]) -> String {
        SHA256.hash(bytes).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `file` is a shard's name as the manifest gives it: `shards/<32 hex>.json` and nothing else, so a manifest
    /// can never name a file outside the index's folder.
    public static func isShardFile(_ file: String) -> Bool {
        guard file.hasPrefix("shards/"), file.hasSuffix(".json") else { return false }
        return isHex32(file.dropFirst("shards/".count).dropLast(".json".count))
    }

    /// Whether `name` is a thumbnail's name as an entry gives it: `<32 hex>.png`.
    public static func isThumbnailName(_ name: String) -> Bool {
        guard name.hasSuffix(".png") else { return false }
        return isHex32(name.dropLast(".png".count))
    }

    /// The hash a content-named file's name says its bytes have: the 32 hex digits of `shards/<hex>.json` or `<hex>.png`.
    public static func namedHash(_ file: String) -> String {
        let name = file.split(separator: "/").last.map(String.init) ?? file
        return String(name.prefix(32))
    }

    private static func isHex32(_ text: Substring) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Reads a manifest; refuses another format, or one naming a file that is not a shard's.
    public static func manifest(from bytes: [UInt8]) throws(DrawingIndexError) -> DrawingIndexManifest {
        let format = try formatNumber(bytes)
        guard format == supported else { throw .newerFormat(format) }
        guard let manifest = try? JSONDecoder().decode(DrawingIndexManifest.self, from: Data(bytes)),
              manifest.shards.allSatisfy({ isShardFile($0.file) }) else { throw .unreadable }
        return manifest
    }

    /// Reads a shard; refuses another format.
    public static func shard(from bytes: [UInt8]) throws(DrawingIndexError) -> DrawingIndexShard {
        let format = try formatNumber(bytes)
        guard format == supported else { throw .newerFormat(format) }
        guard let shard = try? JSONDecoder().decode(DrawingIndexShard.self, from: Data(bytes)) else { throw .unreadable }
        return shard
    }

    private static func formatNumber(_ bytes: [UInt8]) throws(DrawingIndexError) -> Int {
        struct Format: Decodable { let format: Int }
        guard let read = try? JSONDecoder().decode(Format.self, from: Data(bytes)) else { throw .unreadable }
        return read.format
    }
}

/// Why the Duo would not read an index file.
public enum DrawingIndexError: Error, Equatable, Sendable {
    /// The laptop wrote a format this Vellum does not read; the Duo keeps the copy it has.
    case newerFormat(Int)
    /// Not JSON of the index's shape, or it names a file it may not.
    case unreadable
}

/// `index.json`: the format, a generation that goes up with each change, and one line per project's shard.
public struct DrawingIndexManifest: Codable, Equatable, Sendable {
    public struct Shard: Codable, Equatable, Hashable, Sendable {
        public var project: String?
        public var projectPath: String?
        /// Relative to `Index/`: `shards/<32 hex>.json`.
        public var file: String
        public var drawings: Int
        public var bytes: Int

        public init(project: String?, projectPath: String?, file: String, drawings: Int, bytes: Int) {
            self.project = project
            self.projectPath = projectPath
            self.file = file
            self.drawings = drawings
            self.bytes = bytes
        }
    }

    public var format: Int
    public var generation: Int
    /// When this generation was written, `YYYY-MM-DDTHH:MM:SSZ`.
    public var updated: String?
    public var drawings: Int
    public var thumbnailBox: Int?
    public var shards: [Shard]

    public init(format: Int = DrawingIndexFormat.supported, generation: Int, updated: String?, drawings: Int,
                thumbnailBox: Int? = 128, shards: [Shard]) {
        self.format = format
        self.generation = generation
        self.updated = updated
        self.drawings = drawings
        self.thumbnailBox = thumbnailBox
        self.shards = shards
    }

    /// When this generation was written, or nil when the manifest doesn't say.
    public var updatedDate: Date? {
        guard let updated else { return nil }
        return ISO8601DateFormatter().date(from: updated)
    }
}

/// One project's drawings.
public struct DrawingIndexShard: Codable, Equatable, Sendable {
    public var format: Int
    public var project: String?
    public var projectPath: String?
    public var drawings: [DrawingEntry]

    public init(format: Int = DrawingIndexFormat.supported, project: String?, projectPath: String?,
                drawings: [DrawingEntry]) {
        self.format = format
        self.project = project
        self.projectPath = projectPath
        self.drawings = drawings
    }
}

/// One entry of the drawing index: a titled sheet (a DWG layout), a DWG whose title blocks are not read yet, or a PDF
/// with no DWG. Title block fields are as written in the title block, each nil when unknown.
public struct DrawingEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public struct DWG: Codable, Equatable, Hashable, Sendable {
        public var path: String
        public var size: Int?
        public var modified: String?
        /// False only while the file is online-only on the laptop and not downloaded and read yet.
        public var read: Bool

        public init(path: String, size: Int? = nil, modified: String? = nil, read: Bool = true) {
            self.path = path
            self.size = size
            self.modified = modified
            self.read = read
        }
    }

    public struct PDF: Codable, Equatable, Hashable, Sendable {
        public var path: String
        public var size: Int?
        public var modified: String?
        public var read: Bool
        /// True for a plot the laptop fitted to the page, not to scale (a Model-tab DWG's fallback, #92), which is placed
        /// as an NTS sheet whatever the title block says; nil on every other PDF, and in an index from before 1.1.2, so
        /// it is never encoded unless true. Declared beside `read`, where it fits in the padding before `contentHash`,
        /// so an entry is no bigger than before #92 (`index_copy_bytes_20000`, docs/perf/baselines/drawing-index.json).
        public var fitted: Bool?
        /// Dropbox's content hash, which names the PDF kept on the Duo (`SheetPDFs`); nil while unread.
        public var contentHash: String?
        public var pages: Int?
        /// The first page's width and height in inches as it is viewed.
        public var paperInches: [Double]?

        public init(path: String, size: Int? = nil, modified: String? = nil, read: Bool = true,
                    contentHash: String? = nil, pages: Int? = nil, paperInches: [Double]? = nil, fitted: Bool? = nil) {
            self.path = path
            self.size = size
            self.modified = modified
            self.read = read
            self.contentHash = contentHash
            self.pages = pages
            self.paperInches = paperInches
            self.fitted = fitted
        }
    }

    public var id: String
    public var path: String
    public var name: String
    public var layout: String?
    public var folder: String?
    public var project: String?
    public var projectPath: String?
    public var number: String?
    public var title: String?
    public var revision: String?
    public var scale: String?
    public var date: String?
    public var fieldsFrom: String?
    public var dwg: DWG?
    public var pdf: PDF?
    public var otherPdfs: [String]?
    public var pairedBy: String?
    /// Its file in `thumbnails/`, or nil.
    public var thumbnail: String?

    public init(id: String, path: String, name: String, layout: String? = nil, folder: String? = nil,
                project: String? = nil, projectPath: String? = nil, number: String? = nil, title: String? = nil,
                revision: String? = nil, scale: String? = nil, date: String? = nil, fieldsFrom: String? = nil,
                dwg: DWG? = nil, pdf: PDF? = nil, otherPdfs: [String]? = [], pairedBy: String? = nil,
                thumbnail: String? = nil) {
        self.id = id
        self.path = path
        self.name = name
        self.layout = layout
        self.folder = folder
        self.project = project
        self.projectPath = projectPath
        self.number = number
        self.title = title
        self.revision = revision
        self.scale = scale
        self.date = date
        self.fieldsFrom = fieldsFrom
        self.dwg = dwg
        self.pdf = pdf
        self.otherPdfs = otherPdfs
        self.pairedBy = pairedBy
        self.thumbnail = thumbnail
    }
}
