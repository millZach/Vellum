import Foundation

/// The PDFs picked in Add sheet or opened in the drawing viewer, downloaded once and kept in the app's Caches folder
/// while Zach looks at their pages (#11, #69). A PDF is named by its Dropbox content hash, so picking or opening it
/// again, from any canvas or from search, downloads nothing; placing a sheet copies it into the canvas's folder
/// (`CanvasSaver.keepSheetPDF`), from which the sheet is drawn ever after, so reopening a canvas never downloads
/// anything. The system may clear Caches, which only costs a download the next time the PDF is picked.
///
/// Each PDF kept also remembers the Dropbox path it came from (`paths.json` beside the PDFs), so a PDF opened from the
/// drawing index is found again by its path when the index's hash is stale or missing, offline too. There is one
/// download path: a download of a path already under way is shared, whoever asked for it (Add sheet or the viewer).
///
/// Every call does file work, so it runs off the main thread.
public final class SheetPDFs: @unchecked Sendable {
    public let folder: URL
    private let lock = NSLock()
    private var inFlight: [String: Task<KeptPDF, any Error>] = [:]
    private var downloaded = 0
    /// Lower-cased Dropbox path to the name its last download is kept under; read from `paths.json` when first asked.
    private var paths: [String: String]?

    /// The file that remembers which path each PDF came from.
    public static let pathsFileName = "paths.json"

    public init(folder: URL) {
        self.folder = folder
    }

    /// The downloads in the app's Caches folder.
    public static func inCaches() throws -> SheetPDFs {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil,
                                                 create: true)
        return SheetPDFs(folder: caches.appendingPathComponent("SheetPDFs", isDirectory: true))
    }

    /// Bytes downloaded through this cache, for the work budgets (docs/perf/baselines/sheets.json).
    public var bytesDownloaded: Int { lock.withLock { downloaded } }

    /// Where a PDF is, or will be, kept.
    public func url(for file: DropboxFile) -> URL { url(keptName: file.keptName) }

    /// Where the PDF kept under `keptName` is, or will be.
    public func url(keptName: String) -> URL { folder.appendingPathComponent(keptName + ".pdf") }

    /// Whether the PDF kept under `keptName` is here: with `size` bytes when the caller knows its size, else with any.
    public func holds(keptName: String, size: Int?) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url(keptName: keptName).path)
        guard let held = (attributes?[.size] as? NSNumber)?.intValue else { return false }
        if let size { return held == size }
        return held > 0
    }

    /// Whether the PDF is already here, whole.
    public func holds(_ file: DropboxFile) -> Bool { holds(keptName: file.keptName, size: file.size) }

    /// The name the PDF last downloaded from `path` is kept under, when it is still here.
    public func keptName(forPath path: String) -> String? {
        guard let name = lock.withLock({ knownPaths()[path.lowercased()] }), holds(keptName: name, size: nil) else {
            return nil
        }
        return name
    }

    /// The lower-cased Dropbox paths whose PDFs are kept here, for "Not on this Duo" (`DrawingMarker`).
    public func keptPaths() -> Set<String> {
        let known = lock.withLock { knownPaths() }
        return Set(known.filter { holds(keptName: $0.value, size: nil) }.keys)
    }

    /// The PDF on the Duo: the one kept here, or downloaded once with `download` and kept. Callers asking for the same
    /// path at once share one download.
    public func pdf(for file: DropboxFile, download: @escaping @Sendable () async throws -> Data) async throws -> URL {
        if holds(file) {
            remember(file.path, as: file.keptName)
            return url(for: file)
        }
        return try await keep(path: file.path) {
            let data = try await download()
            guard data.count == file.size else { throw DropboxError.unexpectedReply }
            return (data, file.keptName)
        }.url
    }

    /// A drawing's PDF on the Duo, found by its Dropbox path and the content hash the drawing index gives (#69): the
    /// one kept under that hash, which Add sheet's download of the same PDF is too; else the one last downloaded from
    /// that path; else downloaded once with `download` and kept under the content hash Dropbox gives for what came
    /// down (worked out here when it gave none).
    public func pdf(at path: String, contentHash: String?, size: Int?,
                    download: @escaping @Sendable () async throws -> DropboxDownload) async throws -> KeptPDF {
        if let contentHash {
            let name = Self.keptName(contentHash: contentHash, rev: "")
            if holds(keptName: name, size: size) {
                remember(path, as: name)
                return KeptPDF(url: url(keptName: name), keptName: name)
            }
        }
        if let name = keptName(forPath: path) { return KeptPDF(url: url(keptName: name), keptName: name) }
        return try await keep(path: path) {
            let reply = try await download()
            let hash = reply.contentHash ?? DropboxContentHash.of([UInt8](reply.bytes))
            guard !reply.bytes.isEmpty, !hash.isEmpty else { throw DropboxError.unexpectedReply }
            return (reply.bytes, Self.keptName(contentHash: hash, rev: ""))
        }
    }

    /// The one download path: fetches a path's bytes once, however many ask at once, keeps them under the name
    /// `fetch` gives (atomically, so a cut-short write is never kept), counts them and remembers the path.
    private func keep(path: String, fetch: @escaping @Sendable () async throws -> (Data, String)) async throws
        -> KeptPDF {
        let key = path.lowercased()
        let task: Task<KeptPDF, any Error> = lock.withLock {
            if let running = inFlight[key] { return running }
            let task = Task { [self] in
                let (bytes, name) = try await fetch()
                if !holds(keptName: name, size: bytes.count) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try bytes.write(to: url(keptName: name), options: .atomic)
                }
                lock.withLock { downloaded += bytes.count }
                remember(path, as: name)
                return KeptPDF(url: url(keptName: name), keptName: name)
            }
            inFlight[key] = task
            return task
        }
        defer { lock.withLock { if inFlight[key] == task { inFlight[key] = nil } } }
        return try await task.value
    }

    /// Notes that `path`'s PDF is kept under `name`, written to `paths.json` when it changes.
    private func remember(_ path: String, as name: String) {
        let changed: [String: String]? = lock.withLock {
            var known = knownPaths()
            guard known[path.lowercased()] != name else { return nil }
            known[path.lowercased()] = name
            paths = known
            return known
        }
        guard let changed, let data = try? JSONEncoder().encode(changed) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(Self.pathsFileName), options: .atomic)
    }

    /// The paths known, read once; call with the lock held.
    private func knownPaths() -> [String: String] {
        if let paths { return paths }
        let read = (try? Data(contentsOf: folder.appendingPathComponent(Self.pathsFileName)))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        paths = read
        return read
    }

    /// The name a PDF is kept under: its content hash, kept to letters, digits, `-` and `_`; with no hash, its revision.
    public static func keptName(contentHash: String, rev: String) -> String {
        let safe = contentHash.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return safe.isEmpty ? "pdf-" + String(rev.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }) : safe
    }
}

/// A PDF kept on the Duo: where it is, and the name it is kept under, which a placed sheet's page names (`SheetPage.file`).
public struct KeptPDF: Sendable, Hashable {
    public var url: URL
    public var keptName: String

    public init(url: URL, keptName: String) {
        self.url = url
        self.keptName = keptName
    }
}
