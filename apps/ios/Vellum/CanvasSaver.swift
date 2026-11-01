import Foundation
import UIKit
import VellumCore

/// Saves one open canvas on the Duo, entirely off the main thread (ADR-0013). The canvas screen hands it each change
/// as the Pencil lifts, which costs the main thread a queue hand-off; on its own serial queue the saver appends the
/// change to the canvas's ink log with a plain write, flushes the log to storage every few seconds while Zach draws,
/// compacts when the Pencil is up, and redraws the canvas's thumbnail for the Canvases list.
final class CanvasSaver: @unchecked Sendable {
    /// How long appended changes may sit in the file cache before they are flushed to storage. They already survive a
    /// crash or a kill; this bounds what a sudden power cut could take.
    static let flushInterval: TimeInterval = 3

    let id: UUID
    private let library: CanvasLibrary
    private let queue: DispatchQueue

    // Everything below is touched only on `queue`.
    private let store: InkStore
    /// Changes a failed write left unsaved, written again ahead of the next ones.
    private var unwritten: [InkEvent] = []
    private var flushScheduled = false
    private var pencilDown = false
    private var thumbnailIsStale = false

    private init(id: UUID, library: CanvasLibrary, store: InkStore, queue: DispatchQueue) {
        self.id = id
        self.library = library
        self.store = store
        self.queue = queue
    }

    /// Opens a canvas off the main thread: its name and units, and its ink with its undo history as saved.
    static func open(_ id: UUID, in library: CanvasLibrary) async throws -> (CanvasManifest, InkSession, CanvasSaver) {
        let queue = DispatchQueue(label: "com.millzach.vellum.saving", qos: .userInitiated)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let manifest = try library.manifest(for: id)
                    let store = try library.openInk(id)
                    let saver = CanvasSaver(id: id, library: library, store: store, queue: queue)
                    continuation.resume(returning: (manifest, store.session, saver))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Hands changes to the queue to be written. `done` is called on the main actor with the canvas's save state once
    /// they are written, or with why not.
    func save(_ events: [InkEvent], done: @escaping @MainActor @Sendable (SaveState) -> Void) {
        queue.async { [self] in
            unwritten += events
            let state: SaveState
            do {
                try store.append(unwritten)
                unwritten.removeAll()
                thumbnailIsStale = true
                scheduleFlush()
                state = .savedOnThisDuo
            } catch {
                state = .notSaved(outOfSpace: (error as? any StorageFailure)?.isOutOfSpace ?? false)
            }
            Task { @MainActor in done(state) }
        }
    }

    /// Whether the Pencil is on the glass, so compaction waits for it to lift.
    func setPencilDown(_ down: Bool) {
        queue.async { [self] in
            pencilDown = down
            if !down { compactIfDue() }
        }
    }

    func setUnits(_ units: CanvasUnits) {
        queue.async { [self] in try? library.setUnits(id, to: units) }
    }

    /// Writes anything a failed write left behind, flushes everything to storage and brings the thumbnail up to date:
    /// for when the app leaves the screen or the canvas is closed. `done` runs on the queue when it is finished.
    func flushNow(done: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            if !unwritten.isEmpty, (try? store.append(unwritten)) != nil {
                unwritten.removeAll()
                thumbnailIsStale = true
            }
            try? store.flush()
            refreshThumbnailIfStale()
            done?()
        }
    }

    /// The same, waiting for it: only for the app being terminated, when there is no later.
    func flushAndWait() {
        queue.sync {
            if !unwritten.isEmpty, (try? store.append(unwritten)) != nil { unwritten.removeAll() }
            try? store.flush()
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.flushInterval) { [self] in
            flushScheduled = false
            try? store.flush()
            compactIfDue()
            refreshThumbnailIfStale()
        }
    }

    /// Folds the log into a new snapshot when it has outgrown the old one, never while the Pencil is down.
    private func compactIfDue() {
        guard !pencilDown, store.needsCompaction else { return }
        try? store.compact()
    }

    private func refreshThumbnailIfStale() {
        guard thumbnailIsStale else { return }
        thumbnailIsStale = false
        CanvasPreviews.write(for: id, ink: store.session.ink)
    }
}

/// The pictures and counts the Canvases list shows, kept in the app's Caches folder beside (not inside) the canvas
/// folders: they are made from the ink and can always be made again, so #12 has no reason to sync them.
enum CanvasPreviews {
    /// The thumbnail's size in points: the preview pane on the Duo unfolded.
    static let size = CGSize(width: 520, height: 400)

    struct Info: Codable, Hashable, Sendable {
        var strokeCount: Int
        var sheetCount: Int
    }

    static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("CanvasPreviews", isDirectory: true)
    }

    static func imageURL(for id: UUID, dark: Bool) -> URL {
        folder.appendingPathComponent("\(id.uuidString)-\(dark ? "dark" : "light").png")
    }

    static func infoURL(for id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    static func info(for id: UUID) -> Info? {
        guard let data = try? Data(contentsOf: infoURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    /// Draws the ink's thumbnail in light and dark and writes it with the stroke count. Runs off the main thread.
    static func write(for id: UUID, ink: Ink) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let thumbnail = InkThumbnail(ink: ink, width: size.width, height: size.height, padding: 20)
        for dark in [false, true] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                let cg = context.cgContext
                cg.setFillColor(Palette.ground(dark: dark).cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                for line in thumbnail.lines {
                    guard let x0 = line.xs.first, let y0 = line.ys.first else { continue }
                    cg.saveGState()
                    cg.setAlpha(line.tool.opacity)
                    cg.setStrokeColor(Palette.ink(line.colour, dark: dark).cgColor)
                    cg.setLineWidth(line.width)
                    cg.move(to: CGPoint(x: x0, y: y0))
                    if line.xs.count == 1 { cg.addLine(to: CGPoint(x: x0, y: y0)) }
                    for i in 1..<max(line.xs.count, 1) { cg.addLine(to: CGPoint(x: line.xs[i], y: line.ys[i])) }
                    cg.strokePath()
                    cg.restoreGState()
                }
            }
            try? image.write(to: imageURL(for: id, dark: dark), options: .atomic)
        }
        let info = Info(strokeCount: thumbnail.strokeCount, sheetCount: 0)
        if let data = try? JSONEncoder().encode(info) { try? data.write(to: infoURL(for: id), options: .atomic) }
    }

    static func remove(for id: UUID) {
        for url in [imageURL(for: id, dark: false), imageURL(for: id, dark: true), infoURL(for: id)] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
