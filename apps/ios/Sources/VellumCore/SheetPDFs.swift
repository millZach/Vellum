import Foundation

/// The PDFs picked in Add sheet or opened in the drawing viewer, downloaded once and kept in the app's Caches folder
/// while Zach looks at their pages (#11, #69). A PDF is named by its Dropbox content hash, so picking or opening it
/// again, from any canvas or from search, downloads nothing; placing a
/// sheet copies it into the canvas's folder (`CanvasSaver.keepSheetPDF`), from which the sheet is drawn ever after, so
/// reopening a canvas never downloads anything. The system may clear Caches, which only costs a download the next time
/// the PDF is picked.
///
/// Every call does file work, so it runs off the main thread.
public final class SheetPDFs: @unchecked Sendable {
    public let folder: URL
    private let lock = NSLock()
    private var inFlight: [String: Task<URL, any Error>] = [:]
    private var downloaded = 0

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
    public func holds(_ file: DropboxFile) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url(for: file).path)
        return (attributes?[.size] as? NSNumber)?.intValue == file.size
    }

    /// The PDF on the Duo: the one kept here, or downloaded once with `download` and kept. Callers asking for the same
    /// PDF at once share one download.
    public func pdf(for file: DropboxFile, download: @escaping @Sendable () async throws -> Data) async throws -> URL {
        if holds(file) { return url(for: file) }
        let task: Task<URL, any Error> = lock.withLock {
            if let running = inFlight[file.keptName] { return running }
            let task = Task { [self] in
                let data = try await download()
                guard data.count == file.size else { throw DropboxError.unexpectedReply }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url(for: file), options: .atomic)
                lock.withLock { downloaded += data.count }
                return url(for: file)
            }
            inFlight[file.keptName] = task
            return task
        }
        defer { lock.withLock { inFlight[file.keptName] = nil } }
        return try await task.value
    }

    /// A drawing's PDF on the Duo, found by its Dropbox path and the content hash the drawing index gives (#69): the
    /// one kept under that hash, which Add sheet's download of the same PDF is too, or downloaded once with `download`
    /// and kept under the content hash Dropbox gives for what came down (worked out here when it gave none). Callers
    /// asking for the same path at once share one download.
    public func pdf(at path: String, contentHash: String?, size: Int?,
                    download: @escaping @Sendable () async throws -> DropboxDownload) async throws -> KeptPDF {
        if let contentHash {
            let name = Self.keptName(contentHash: contentHash, rev: "")
            if holds(keptName: name, size: size) { return KeptPDF(url: url(keptName: name), keptName: name) }
        }
        let key = "path:" + path.lowercased()
        let task: Task<URL, any Error> = lock.withLock {
            if let running = inFlight[key] { return running }
            let task = Task { [self] in
                let reply = try await download()
                let hash = reply.contentHash ?? DropboxContentHash.of([UInt8](reply.bytes))
                let name = Self.keptName(contentHash: hash, rev: "")
                guard !reply.bytes.isEmpty, !hash.isEmpty else { throw DropboxError.unexpectedReply }
                if !holds(keptName: name, size: reply.bytes.count) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try reply.bytes.write(to: url(keptName: name), options: .atomic)
                }
                lock.withLock { downloaded += reply.bytes.count }
                return url(keptName: name)
            }
            inFlight[key] = task
            return task
        }
        defer { lock.withLock { inFlight[key] = nil } }
        let url = try await task.value
        return KeptPDF(url: url, keptName: url.deletingPathExtension().lastPathComponent)
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
