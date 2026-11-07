import Foundation

/// The Duo's copy of the drawing index, read into memory: the manifest it was swapped in with and every entry of its
/// shards, in the manifest's order.
public struct DrawingIndexCopy: Sendable {
    public let manifest: DrawingIndexManifest
    public let entries: [DrawingEntry]
    /// The thumbnails its entries name.
    public let thumbnails: Set<String>

    public init(manifest: DrawingIndexManifest, entries: [DrawingEntry]) {
        self.manifest = manifest
        self.entries = entries
        thumbnails = Set(entries.compactMap(\.thumbnail).filter(DrawingIndexFormat.isThumbnailName))
    }
}

/// What a refresh of the copy found.
public enum DrawingIndexRefresh: Equatable, Sendable {
    /// No Dropbox sign-in: nothing was asked.
    case notSignedIn
    /// Dropbox has no index yet: the laptop indexer has not written one.
    case noIndex
    /// The manifest in Dropbox is the copy's: nothing came down but the listing.
    case unchanged
    /// A new generation was swapped in; read the copy again.
    case updated
    /// The laptop wrote a format this Vellum does not read; the copy is kept as it was.
    case newerFormat(Int)
    /// No connection; the copy is kept as it was.
    case offline
    /// Dropbox did not answer, or sent something that is not the index; the copy is kept as it was.
    case failed
    /// The new generation names a shard that is not the index's shape; nothing was swapped in, and the copy is kept as
    /// it was (ADR-0017). `generation` is the manifest's that named it.
    case unreadableShard(generation: Int)
    /// Another refresh is running.
    case busy
}

/// Keeps the Duo's copy of the drawing index (#68, ADR-0017, ADR-0010's #68 amendment) in `Application Support/
/// DrawingIndex`, not Caches, so it survives offline and the system never clears it:
///
/// ```
/// DrawingIndex/index.json          the manifest the copy was last swapped in with
/// DrawingIndex/shards/<hash>.json  the shards it names (and, mid-refresh, the next generation's)
/// DrawingIndex/thumbnails/<hash>.png  thumbnails rows have shown
/// ```
///
/// A refresh does what `DrawingIndexPlan` says: one listing of `Vellum/Index`, then, only when the manifest changed,
/// the manifest and the shards the Duo lacks, each checked against the hash its name gives. The new manifest is
/// written over the old one only once every shard it names is on the Duo, so the copy is never half one generation
/// and half another. Everything here runs off the main thread, on the actor.
public actor DrawingIndexKeeper {
    public nonisolated let root: URL
    private let session: DropboxSession?
    private var running = false
    private var referenced: Set<String> = []
    private var thumbnailsInFlight: [String: Task<Data?, Never>] = [:]
    /// File bytes downloaded by refreshes and thumbnails since this keeper was made, for the budgets and the PR.
    public private(set) var bytesDownloaded = 0

    public init(session: DropboxSession?, root: URL) {
        self.session = session
        self.root = root
    }

    /// The copy's folder on this Duo: `Application Support/DrawingIndex`.
    public static func folderOnThisDevice() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent("DrawingIndex", isDirectory: true)
    }

    private var manifestURL: URL { root.appendingPathComponent(DrawingIndexFormat.manifestName) }
    private var shardsFolder: URL { root.appendingPathComponent("shards", isDirectory: true) }
    private var thumbnailsFolder: URL { root.appendingPathComponent("thumbnails", isDirectory: true) }

    // MARK: Reading the copy

    /// Reads the copy, or nil when the Duo has none. Shards and thumbnails it does not name (left by a refresh cut
    /// short, or no longer named) are deleted.
    public func load() -> DrawingIndexCopy? {
        guard let bytes = try? DurableFile.read(manifestURL),
              let manifest = try? DrawingIndexFormat.manifest(from: bytes) else {
            referenced = []
            return nil
        }
        var entries: [DrawingEntry] = []
        entries.reserveCapacity(manifest.drawings)
        for shard in manifest.shards {
            guard let bytes = try? DurableFile.read(root.appendingPathComponent(shard.file)),
                  let read = try? DrawingIndexFormat.shard(from: bytes) else { continue }
            entries += read.drawings
        }
        let copy = DrawingIndexCopy(manifest: manifest, entries: entries)
        referenced = copy.thumbnails
        // Not while a refresh is part way through: the shards it has fetched are not named yet.
        guard !running else { return copy }
        if case .swap(let delete) = DrawingIndexPlan.step(.success(manifest), held: heldShards()) {
            for file in delete { try? FileManager.default.removeItem(at: root.appendingPathComponent(file)) }
        }
        for name in DrawingIndexPlan.thumbnailsToDelete(referenced: referenced, held: heldThumbnails()) {
            try? FileManager.default.removeItem(at: thumbnailsFolder.appendingPathComponent(name))
        }
        return copy
    }

    /// The shard files on the Duo, as the manifest names them (`shards/<hash>.json`).
    func heldShards() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: shardsFolder.path)) ?? []
        return Set(names.map { "shards/" + $0 }.filter(DrawingIndexFormat.isShardFile))
    }

    /// The thumbnails on the Duo, by name.
    func heldThumbnails() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: thumbnailsFolder.path)) ?? []
        return Set(names.filter(DrawingIndexFormat.isThumbnailName))
    }

    // MARK: Refreshing

    /// Brings the copy up to date with Dropbox, downloading only what changed. A refresh cut short keeps the copy as it
    /// was; the next one carries on, finding the shards that did arrive.
    public func refresh() async -> DrawingIndexRefresh {
        guard !running else { return .busy }
        running = true
        defer { running = false }
        guard let session, await session.isSignedIn else { return .notSignedIn }
        do {
            guard let listed = try await session.files(in: DrawingIndexFormat.folder),
                  let manifestFile = listed.first(where: { $0.name.lowercased() == DrawingIndexFormat.manifestName })
            else { return .noIndex }
            let kept = try? DurableFile.read(manifestURL)
            switch DrawingIndexPlan.check(listedHash: manifestFile.contentHash, keptHash: kept.map(DropboxContentHash.of)) {
            case .noIndex: return .noIndex
            case .unchanged: return .unchanged
            case .downloadManifest: break
            }
            let bytes = [UInt8](try await session.download(manifestFile))
            bytesDownloaded += bytes.count
            let read: Result<DrawingIndexManifest, DrawingIndexError>
            do { read = .success(try DrawingIndexFormat.manifest(from: bytes)) } catch { read = .failure(error) }
            // The second pass finds every shard here; a third would mean a download that did not stay.
            for _ in 0..<2 {
                switch DrawingIndexPlan.step(read, held: heldShards()) {
                case .refuse(let format):
                    return .newerFormat(format)
                case .keep:
                    return .failed
                case .fetch(let files):
                    guard case .success(let manifest) = read else { return .failed }
                    try FileManager.default.createDirectory(at: shardsFolder, withIntermediateDirectories: true)
                    for file in files {
                        let path = DrawingIndexFormat.folder + "/" + file
                        let size = manifest.shards.first { $0.file == file }?.bytes ?? 0
                        let shard = [UInt8](try await session.download(DropboxFile(
                            id: path, name: String(file.dropFirst("shards/".count)), path: path, size: size,
                            contentHash: "", rev: "")))
                        bytesDownloaded += shard.count
                        // Named by its bytes: anything else is damaged, or not what the manifest meant.
                        guard DrawingIndexFormat.contentName(of: shard) == DrawingIndexFormat.namedHash(file) else {
                            return .failed
                        }
                        try DurableFile.writeAtomically(shard, to: root.appendingPathComponent(file))
                    }
                case .swap(let delete):
                    guard case .success(let manifest) = read else { return .failed }
                    // Every shard of the new generation is read before it is promoted: one the Duo can't read (named
                    // right, but damaged at the laptop, or a newer format) would leave drawings out of the copy.
                    for shard in manifest.shards {
                        do {
                            guard let bytes = try? DurableFile.read(root.appendingPathComponent(shard.file)) else {
                                return .failed
                            }
                            _ = try DrawingIndexFormat.shard(from: bytes)
                        } catch .newerFormat(let format) {
                            return .newerFormat(format)
                        } catch {
                            return .unreadableShard(generation: manifest.generation)
                        }
                    }
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try DurableFile.writeAtomically(bytes, to: manifestURL)
                    for file in delete { try? FileManager.default.removeItem(at: root.appendingPathComponent(file)) }
                    return .updated
                }
            }
            return .failed
        } catch let error as DropboxError {
            switch error {
            case .offline: return .offline
            case .notSignedIn, .signInExpired: return .notSignedIn
            default: return .failed
            }
        } catch {
            return .failed
        }
    }

    // MARK: Thumbnails

    /// Where a thumbnail is kept, whether or not it is here yet.
    public nonisolated func thumbnailURL(_ name: String) -> URL {
        root.appendingPathComponent("thumbnails", isDirectory: true).appendingPathComponent(name)
    }

    /// A row's thumbnail on the Duo, downloaded first when the copy names it, the Duo lacks it and `online` (ADR-0017:
    /// thumbnails come down as rows need them, and a name the Duo has is never downloaded again). Nil when it isn't
    /// here and can't come down now.
    public func thumbnail(_ name: String, online: Bool) async -> URL? {
        let url = thumbnailURL(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard DrawingIndexPlan.thumbnailFetch(name, referenced: referenced, held: [], online: online),
              let session else { return nil }
        if let running = thumbnailsInFlight[name] {
            _ = await running.value
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let path = DrawingIndexFormat.folder + "/thumbnails/" + name
        let task = Task<Data?, Never> { (try? await session.download(path: path)) ?? nil }
        thumbnailsInFlight[name] = task
        let data = await task.value
        let kept = data.flatMap { keep(thumbnail: [UInt8]($0), named: name) }
        thumbnailsInFlight[name] = nil
        return kept
    }

    private func keep(thumbnail bytes: [UInt8], named name: String) -> URL? {
        bytesDownloaded += bytes.count
        guard DrawingIndexFormat.contentName(of: bytes) == DrawingIndexFormat.namedHash(name) else { return nil }
        let url = thumbnailURL(name)
        do {
            try FileManager.default.createDirectory(at: thumbnailsFolder, withIntermediateDirectories: true)
            // A thumbnail can always come down again, so it is not flushed to storage as the shards are.
            try Data(bytes).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
