import Foundation

/// What refreshing the Duo's index copy does (#68, ADR-0017), as pure decisions the keeper carries out:
///
/// 1. `check`: Dropbox's listing of `Vellum/Index` gives `index.json`'s content hash. The same as the copy's own
///    manifest: nothing changed, and nothing is downloaded.
/// 2. Otherwise the manifest comes down, and `step` says what to do with it: refuse a newer format and keep the copy;
///    fetch the shards it names that the Duo has not got; and only once every one is here, swap the new manifest in,
///    whole, and delete the shards nothing names any more. The keeper downloads what `fetch` lists and asks again, so
///    a refresh cut short (offline, a failed download) never swaps, and the copy never mixes two generations.
/// 3. Thumbnails come down one at a time as rows need them (`thumbnailFetch`), never again once on the Duo; after a
///    swap, `thumbnailsToDelete` drops the ones no entry names.
public enum DrawingIndexPlan {
    public enum Check: Equatable, Sendable {
        /// Dropbox has no index yet: the laptop indexer has not run.
        case noIndex
        /// The manifest is the one the copy has; nothing to download.
        case unchanged
        /// The manifest changed: download it.
        case downloadManifest
    }

    /// `listedHash` is `index.json`'s content hash in Dropbox's listing, nil when there is none; `keptHash` the
    /// content hash of the manifest the copy was swapped in with, nil when the Duo has no copy.
    public static func check(listedHash: String?, keptHash: String?) -> Check {
        guard let listedHash else { return .noIndex }
        return listedHash == keptHash ? .unchanged : .downloadManifest
    }

    public enum Step: Equatable, Sendable {
        /// A format this Vellum does not read: keep the copy as it is and say so.
        case refuse(format: Int)
        /// The manifest could not be read (damaged, or not the index's shape): keep the copy as it is.
        case keep
        /// Download these shards (`shards/<hash>.json`, in the manifest's order), then ask again. Nothing is swapped
        /// or deleted yet.
        case fetch([String])
        /// Every shard the manifest names is here: write the manifest as the copy's, then delete these shards, which
        /// it no longer names.
        case swap(delete: [String])
    }

    /// `manifest` is the downloaded manifest read, or the newer format that refused it; `held` the shard files on the
    /// Duo (`shards/<hash>.json`).
    public static func step(_ manifest: Result<DrawingIndexManifest, DrawingIndexError>, held: Set<String>) -> Step {
        let read: DrawingIndexManifest
        switch manifest {
        case .success(let manifest): read = manifest
        case .failure(.newerFormat(let format)): return .refuse(format: format)
        case .failure(.unreadable): return .keep
        }
        var named: Set<String> = []
        var missing: [String] = []
        for shard in read.shards where named.insert(shard.file).inserted && !held.contains(shard.file) {
            missing.append(shard.file)
        }
        if !missing.isEmpty { return .fetch(missing) }
        return .swap(delete: held.subtracting(named).sorted())
    }

    /// The thumbnails on the Duo that no entry of the copy names, to delete after a swap.
    public static func thumbnailsToDelete(referenced: Set<String>, held: Set<String>) -> [String] {
        held.subtracting(referenced).sorted()
    }

    /// Whether a row's thumbnail is downloaded: only one the copy names, the Duo lacks and Dropbox can be asked for now.
    public static func thumbnailFetch(_ name: String, referenced: Set<String>, held: Set<String>, online: Bool) -> Bool {
        online && referenced.contains(name) && !held.contains(name) && DrawingIndexFormat.isThumbnailName(name)
    }
}
