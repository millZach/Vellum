import Foundation

/// The folders Vellum last saw directly inside one Dropbox folder, with the cursor Dropbox gave for that view, so a
/// later visit asks Dropbox only what changed since (`list_folder/continue`) instead of listing everything again.
public struct DropboxListing: Codable, Sendable, Equatable {
    /// By name, the order the screen shows them in.
    public var folders: [DropboxFolder]
    public var cursor: String
    /// When Dropbox last confirmed this listing.
    public var checkedAt: Date

    public init(folders: [DropboxFolder], cursor: String, checkedAt: Date) {
        self.folders = folders
        self.cursor = cursor
        self.checkedAt = checkedAt
    }
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
