import Foundation
import UIKit
import VellumCore

/// The pictures and counts the Canvases list shows, kept in the app's Caches folder beside (not inside) the canvas
/// folders: they are made from the ink and can always be made again, so #12 has no reason to sync them.
enum CanvasPreviews {
    /// The thumbnail's size in points: the preview pane on the Duo unfolded.
    static let size = CGSize(width: 520, height: 400)

    struct Info: Codable, Hashable, Sendable {
        var strokeCount: Int
        var sheetCount: Int
        /// Which saved ink the thumbnail shows (`InkStore.savedVersion`), so a stale or missing one is drawn again.
        var version: String?
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
    static func write(for id: UUID, ink: Ink, version: String?) {
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
        // The info goes last: a thumbnail is only taken as current once both pictures are written.
        let info = Info(strokeCount: thumbnail.strokeCount, sheetCount: 0, version: version)
        if let data = try? JSONEncoder().encode(info) { try? data.write(to: infoURL(for: id), options: .atomic) }
    }

    static func remove(for id: UUID) {
        for url in [imageURL(for: id, dark: false), imageURL(for: id, dark: true), infoURL(for: id)] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// The canvases' thumbnails for the savers: drawn on a saver's maintenance queue, never the main thread.
struct PreviewThumbnails: CanvasThumbnails {
    /// Told, on the maintenance queue, when a canvas's thumbnail has been drawn, so the list can show it.
    var didWrite: @Sendable (UUID) -> Void = { _ in }

    func isCurrent(_ id: UUID, version: String) -> Bool {
        guard let info = CanvasPreviews.info(for: id), info.version == version else { return false }
        return [false, true].allSatisfy { FileManager.default.fileExists(atPath: CanvasPreviews.imageURL(for: id, dark: $0).path) }
    }

    func write(_ id: UUID, ink: Ink, version: String) {
        CanvasPreviews.write(for: id, ink: ink, version: version)
        didWrite(id)
    }

    func remove(_ id: UUID) {
        CanvasPreviews.remove(for: id)
    }
}
