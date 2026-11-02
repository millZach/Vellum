import Foundation

/// The PDFs picked in Add sheet, downloaded once and kept in the app's Caches folder while Zach looks at their pages
/// (#11). A PDF is named by its Dropbox content hash, so picking it again, from any canvas, downloads nothing; placing a
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
    public func url(for file: DropboxFile) -> URL { folder.appendingPathComponent(file.keptName + ".pdf") }

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
}
