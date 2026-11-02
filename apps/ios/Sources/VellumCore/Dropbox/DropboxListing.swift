import Foundation

/// A PDF in Zach's Dropbox (#11): what a listing says about it, enough to download it once and know it again.
public struct DropboxFile: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// The file's path with Dropbox's capitalisation.
    public let path: String
    /// Its size in bytes.
    public let size: Int
    /// Dropbox's content hash: the same bytes always have the same hash, so it names the PDF kept on the Duo.
    public let contentHash: String
    /// The revision Dropbox gave this version, so a download fetches exactly the bytes listed.
    public let rev: String

    public init(id: String, name: String, path: String, size: Int, contentHash: String, rev: String) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.contentHash = contentHash
        self.rev = rev
    }

    /// The name the PDF is kept under on the Duo: its content hash, kept to letters, digits, `-` and `_`.
    public var keptName: String {
        let safe = contentHash.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return safe.isEmpty ? "pdf-" + String(rev.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }) : safe
    }

    /// Whether a file name is a PDF's.
    static func isPDF(_ name: String) -> Bool { name.lowercased().hasSuffix(".pdf") }
}

/// What a Dropbox folder holds that Vellum shows: its folders and its PDFs, each by name.
public struct DropboxFolderContents: Sendable, Equatable {
    public var folders: [DropboxFolder]
    public var pdfs: [DropboxFile]

    public init(folders: [DropboxFolder], pdfs: [DropboxFile]) {
        self.folders = folders
        self.pdfs = pdfs
    }
}

/// The folders and PDFs Vellum last saw directly inside one Dropbox folder, with the cursor Dropbox gave for that view,
/// so a later visit asks Dropbox only what changed since (`list_folder/continue`) instead of listing everything again.
public struct DropboxListing: Codable, Sendable, Equatable {
    /// By name, the order the screen shows them in.
    public var folders: [DropboxFolder]
    /// The PDFs, by name (#11). A listing kept before #11 has none, and the next look lists the folder again.
    public var pdfs: [DropboxFile]
    public var cursor: String
    /// When Dropbox last confirmed this listing.
    public var checkedAt: Date
    /// Whether this listing knows the folder's PDFs: false for one kept before #11, which listed folders only.
    public var listsPDFs: Bool

    public init(folders: [DropboxFolder], pdfs: [DropboxFile] = [], cursor: String, checkedAt: Date) {
        self.folders = folders
        self.pdfs = pdfs
        self.cursor = cursor
        self.checkedAt = checkedAt
        listsPDFs = true
    }

    private enum CodingKeys: String, CodingKey { case folders, pdfs, cursor, checkedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = try c.decode([DropboxFolder].self, forKey: .folders)
        let pdfs = try c.decodeIfPresent([DropboxFile].self, forKey: .pdfs)
        self.pdfs = pdfs ?? []
        listsPDFs = pdfs != nil
        cursor = try c.decode(String.self, forKey: .cursor)
        checkedAt = try c.decode(Date.self, forKey: .checkedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folders, forKey: .folders)
        if listsPDFs { try c.encode(pdfs, forKey: .pdfs) }
        try c.encode(cursor, forKey: .cursor)
        try c.encode(checkedAt, forKey: .checkedAt)
    }

    public var contents: DropboxFolderContents { DropboxFolderContents(folders: folders, pdfs: pdfs) }
}

/// Where the listings are kept between launches: a small file in the app's Caches folder, or memory in tests and
/// captures. They hold folder names and cursors, never a token, and go when Zach signs out.
public protocol DropboxListingStore: Sendable {
    /// The kept listings by folder path ("" is the top of the Dropbox); empty when there are none or they can't be read.
    func load() -> [String: DropboxListing]
    func save(_ listings: [String: DropboxListing])
    func delete()
}

/// Listings kept in memory only, gone when the app quits.
public final class DropboxMemoryListingStore: DropboxListingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var listings: [String: DropboxListing]

    public init(_ listings: [String: DropboxListing] = [:]) { self.listings = listings }

    public func load() -> [String: DropboxListing] { lock.withLock { listings } }
    public func save(_ listings: [String: DropboxListing]) { lock.withLock { self.listings = listings } }
    public func delete() { lock.withLock { listings = [:] } }
}

/// How fresh a listing has to be.
public enum DropboxFreshness: Sendable, Equatable {
    /// A listing Dropbox confirmed within `DropboxSession.recentCheck` is used as it is, with no request; an older one
    /// asks Dropbox only for what changed. Opening the Drawings tab uses this.
    case recent
    /// Ask Dropbox now (only for what changed, when a listing is kept). Pull to refresh uses this.
    case now
}
