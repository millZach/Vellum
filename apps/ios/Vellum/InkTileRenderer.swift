import QuartzCore
import UIKit
import VellumCore

/// Draws finished ink into cached tiles and moves them with the view (ADR-0012).
///
/// Ink is drawn off the main thread into 256-point tiles at a level of detail (`InkTiling`), from paths built once
/// per stroke in model space, on the drawing threads (`StrokePathCache`). Each level's tiles sit in one container
/// layer whose transform maps the level onto the screen, so a pan or a pinch changes one transform and redraws
/// nothing. Which tiles exist and which to draw is `InkTileBook`'s to decide; this class turns its decisions into
/// layers and drawings. A committed stroke keeps showing on the layers it was drawn live on, moved by one transform,
/// until its tiles are drawn, so ink never blinks and the main thread never builds its path.
@MainActor
final class InkTileRenderer {
    typealias Book = InkTileBook<LevelLayer, TileLayer>

    let layer = CALayer()
    private let overlayLayer = CALayer()
    private let index: @MainActor () -> InkIndex
    private var book: Book!
    private var viewport: Viewport?
    private var overlays: [Overlay] = []
    /// The live stroke's layers, handed over while its commit is in progress.
    private var handover: (layer: CALayer, base: Viewport)?
    private let paths = StrokePathCache<CGPath> { points, origin in InkTileRenderer.path(points, from: origin) }
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Vellum ink tiles"
        // Two drawing threads leave the main thread and the render server a core each.
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// Tiles waiting for their strokes to be found, and the frame ticker that takes them a few at a time.
    private var waiting: [(tile: Book.Tile, level: Book.Level)] = []
    private var inFlight = 0
    private var ticker: FrameTicker?
    /// How much of a frame the main thread spends starting tiles: a quarter of 120 Hz's 8.3 ms.
    private static let frameShare = 0.002

    /// Tile drawings waiting or in flight.
    var pendingCount: Int { waiting.count + inFlight }

    var isDark = false {
        didSet { if isDark != oldValue { redrawEverything() } }
    }
    var displayScale: CGFloat = 3 {
        didSet { if displayScale != oldValue { redrawEverything() } }
    }

    /// Ink is never drawn thinner than this many screen points, so zoomed-out ink never vanishes.
    nonisolated static let minimumWidth = 1.0

    init(index: @escaping @MainActor () -> InkIndex) {
        self.index = index
        layer.actions = noAnimations
        overlayLayer.actions = noAnimations
        let host = layer
        // The book is main-thread only and calls these from the renderer's own calls.
        book = Book(minimumWidth: Self.minimumWidth, hooks: Book.Hooks(
            makeLevel: { _ in
                MainActor.assumeIsolated {
                    let level = LevelLayer()
                    host.addSublayer(level.container)
                    return level
                }
            },
            makeTile: { key, level in
                MainActor.assumeIsolated {
                    let tile = TileLayer()
                    let side = InkTiling.tileSize
                    tile.layer.frame = CGRect(x: Double(key.x) * side, y: Double(key.y) * side, width: side, height: side)
                    level.payload.container.addSublayer(tile.layer)
                    return tile
                }
            },
            discardLevel: { level in
                MainActor.assumeIsolated {
                    for tile in level.tiles.values { tile.payload.cancelled.set() }
                    level.payload.container.removeFromSuperlayer()
                }
            },
            discardTile: { tile, _ in
                MainActor.assumeIsolated {
                    tile.payload.cancelled.set()
                    tile.payload.layer.removeFromSuperlayer()
                }
            },
            draw: { [unowned self] tile, level, adding in
                MainActor.assumeIsolated { self.draw(tile, in: level, adding: adding) }
            }))
    }

    /// The layer committed strokes show on until their tiles are drawn; it goes above the tiles.
    var pendingInkLayer: CALayer { overlayLayer }

    // MARK: The view

    /// Moves the tiles to a new view of the canvas and draws any that came into view.
    func show(_ viewport: Viewport) {
        self.viewport = viewport
        withoutAnimation {
            book.show(viewport)
            if let current = book.current { place(current, for: viewport) }
            if let fallback = book.fallback { place(fallback, for: viewport) }
            for overlay in overlays { overlay.layer.transform = Self.transform(from: overlay.base, to: viewport) }
        }
    }

    /// Maps a level onto the screen: level points scaled by zoom / level scale, offset to where the anchor is.
    private func place(_ level: Book.Level, for viewport: Viewport) {
        let k = viewport.pointsPerInch / level.tiling.scale
        let anchor = viewport.screenPoint(for: CanvasPoint(x: .inches(level.tiling.anchorX), y: .inches(level.tiling.anchorY)))
        level.payload.container.transform = CATransform3DMakeAffineTransform(
            CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: anchor.x, ty: anchor.y))
    }

    /// The transform taking screen points of one view of the canvas to another's: a scale and an offset.
    static func transform(from base: Viewport, to viewport: Viewport) -> CATransform3D {
        let k = viewport.pointsPerInch / base.pointsPerInch
        let origin = viewport.screenPoint(for: base.canvasPoint(for: ScreenPoint(x: 0, y: 0)))
        return CATransform3DMakeAffineTransform(CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: origin.x, ty: origin.y))
    }

    // MARK: Changes of ink

    /// Commits the stroke being drawn: `commit` adds it to the ink, and the layers it was drawn on live, in screen
    /// points of `base`, keep showing it until its tiles are drawn. If the commit adds nothing, the layers go.
    func commitLive(_ live: CALayer, drawnAt base: Viewport, commit: () -> Void) {
        handover = (live, base)
        commit()
        if let handover {
            withoutAnimation { handover.layer.removeFromSuperlayer() }
            self.handover = nil
        }
    }

    /// Redraws only what a change of ink touched (`InkTileBook.inkChanged`).
    func inkChanged(_ change: InkIndex.Change) {
        guard !change.isEmpty else { return }
        paths.remove(change.removed.map(\.id))
        withoutAnimation {
            book.inkChanged(change)
            if !change.removed.isEmpty {
                let removed = Set(change.removed.map(\.id))
                overlays.removeAll { overlay in
                    guard removed.contains(overlay.stroke.id) else { return false }
                    overlay.layer.removeFromSuperlayer()
                    return true
                }
            }
            if let handover, change.addedOnTop, change.removed.isEmpty, change.added.count == 1,
               let stroke = change.added.first, let box = InkIndex.box(of: stroke) {
                self.handover = nil
                let overlay = Overlay(stroke: stroke, box: box, epoch: book.epoch, layer: handover.layer, base: handover.base)
                overlayLayer.addSublayer(overlay.layer)
                if let viewport { overlay.layer.transform = Self.transform(from: overlay.base, to: viewport) }
                overlays.append(overlay)
            }
        }
        removeFinishedOverlays()
    }

    private func redrawEverything() {
        withoutAnimation {
            book.redrawEverything()
            for overlay in overlays {
                for case let shape as CAShapeLayer in overlay.layer.sublayers ?? [] {
                    shape.strokeColor = Self.colour(overlay.stroke.colour, dark: isDark)
                }
            }
        }
    }

    // MARK: Drawing tiles

    /// The book asks for a tile: new strokes over its image start now; a redraw waits its turn, because finding a
    /// tile's strokes is main-thread work and each frame takes only a couple of milliseconds of it.
    private func draw(_ tile: Book.Tile, in level: Book.Level, adding: [InkStroke]?) {
        if let adding, let image = tile.payload.image {
            start(tile, in: level, strokes: adding, base: image)
            return
        }
        waiting.append((tile, level))
        if ticker == nil {
            ticker = FrameTicker { [weak self] in self?.takeWaitingTiles() }
        }
    }

    /// Starts drawing waiting tiles, nearest the front of the queue first, until this frame's share of main-thread
    /// time is spent.
    private func takeWaitingTiles() {
        let began = CACurrentMediaTime()
        var taken = 0
        while taken < waiting.count {
            let (tile, level) = waiting[taken]
            taken += 1
            guard book.begin(tile, in: level) else { continue }
            let tiling = level.tiling
            let box = tiling.box(of: tile.key).grown(by: tiling.margin(minimumWidth: Self.minimumWidth))
            start(tile, in: level, strokes: index().strokes(in: box), base: nil)
            if CACurrentMediaTime() - began > Self.frameShare { break }
        }
        waiting.removeFirst(taken)
        if waiting.isEmpty {
            ticker?.stop()
            ticker = nil
        }
    }

    private func start(_ tile: Book.Tile, in level: Book.Level, strokes: [InkStroke], base: CGImage?) {
        let box = level.tiling.box(of: tile.key)
        let job = TileJob(pixels: Int((InkTiling.tileSize * displayScale).rounded()), displayScale: displayScale,
                          levelScale: level.tiling.scale, originX: box.minX, originY: box.minY, base: base,
                          strokes: strokes, dark: isDark, paths: paths, cancelled: tile.payload.cancelled)
        let jobEpoch = tile.epoch
        inFlight += 1
        // The book's tile and level are main-thread objects; the drawing thread only carries them back.
        let ref = TileRef(tile: tile, level: level)
        queue.addOperation {
            let image = ImageBox(image: Self.draw(job))
            Task { @MainActor in
                self.finish(ref.tile, in: ref.level, epoch: jobEpoch, image: image)
            }
        }
    }

    private func finish(_ tile: Book.Tile, in level: Book.Level, epoch jobEpoch: Int, image: ImageBox) {
        inFlight -= 1
        withoutAnimation {
            if !tile.removed, level.isLive, let image = image.image {
                tile.payload.image = image
                tile.payload.layer.contents = image
            }
            book.finished(tile, in: level, epoch: jobEpoch, drewImage: image.image != nil)
        }
        removeFinishedOverlays()
    }

    private struct TileJob: @unchecked Sendable {
        let pixels: Int
        let displayScale: CGFloat
        let levelScale: Double
        let originX: Double
        let originY: Double
        let base: CGImage?
        let strokes: [InkStroke]
        let dark: Bool
        let paths: StrokePathCache<CGPath>
        let cancelled: Flag
    }

    private struct ImageBox: @unchecked Sendable { let image: CGImage? }

    private struct TileRef: @unchecked Sendable {
        let tile: Book.Tile
        let level: Book.Level
    }
    /// Draws one tile: its ink at the level's scale, over `base` when only new strokes are added.
    private nonisolated static func draw(_ job: TileJob) -> CGImage? {
        // A tile that left the screen, or a level a pinch has already passed, is not worth drawing.
        guard !job.cancelled.isSet, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: job.pixels, height: job.pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        if let base = job.base {
            context.draw(base, in: CGRect(x: 0, y: 0, width: job.pixels, height: job.pixels))
        }
        // Level points with y running down from the tile's top-left corner, then inches from the tile's origin.
        context.translateBy(x: 0, y: CGFloat(job.pixels))
        context.scaleBy(x: job.displayScale, y: -job.displayScale)
        context.scaleBy(x: job.levelScale, y: job.levelScale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let thinnest = minimumWidth / job.levelScale
        for (i, stroke) in job.strokes.enumerated() {
            if i % 256 == 255, job.cancelled.isSet { return nil }
            let (path, origin) = job.paths.path(for: stroke)
            context.saveGState()
            context.translateBy(x: origin.x.inches - job.originX, y: origin.y.inches - job.originY)
            context.setAlpha(stroke.tool.opacity)
            context.setStrokeColor(colour(stroke.colour, dark: job.dark))
            context.setLineWidth(max(stroke.width.inches, thinnest))
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
        }
        return context.makeImage()
    }

    /// A stroke's path in inches from `origin`. A single point is a dot: a zero-length line with round caps.
    nonisolated static func path(_ points: [CanvasPoint], from origin: CanvasPoint) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        let ox = origin.x.inches, oy = origin.y.inches
        path.move(to: CGPoint(x: first.x.inches - ox, y: first.y.inches - oy))
        if points.count == 1 { path.addLine(to: CGPoint(x: first.x.inches - ox, y: first.y.inches - oy)) }
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x.inches - ox, y: point.y.inches - oy))
        }
        return path
    }

    /// The ink colours as CGColors, made once.
    private nonisolated(unsafe) static let colours: [Bool: [MarkupColour: CGColor]] = {
        var table: [Bool: [MarkupColour: CGColor]] = [:]
        for dark in [false, true] {
            for colour in MarkupColour.allCases {
                let rgb = colour.rgb(dark: dark)
                table[dark, default: [:]][colour] = CGColor(srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255,
                                                            blue: CGFloat(rgb.blue) / 255, alpha: 1)
            }
        }
        return table
    }()

    nonisolated static func colour(_ colour: MarkupColour, dark: Bool) -> CGColor { colours[dark]![colour]! }

    // MARK: Committed strokes waiting for their tiles

    /// A committed stroke's live layers, in screen points of the view it was drawn in.
    private final class Overlay {
        let stroke: InkStroke
        let box: InkIndex.Box
        let epoch: Int
        let layer: CALayer
        let base: Viewport
        init(stroke: InkStroke, box: InkIndex.Box, epoch: Int, layer: CALayer, base: Viewport) {
            self.stroke = stroke
            self.box = box
            self.epoch = epoch
            self.layer = layer
            self.base = base
        }
    }

    /// Takes away each committed stroke's live layers once every tile holding it has been drawn with it.
    private func removeFinishedOverlays() {
        guard !overlays.isEmpty else { return }
        withoutAnimation {
            overlays.removeAll { overlay in
                if let level = book.current {
                    let margin = level.tiling.margin(minimumWidth: Self.minimumWidth)
                    for tile in book.tiles(of: level, touching: overlay.box.grown(by: margin))
                    where tile.renderedEpoch < overlay.epoch || !tile.hasImage {
                        return false
                    }
                }
                overlay.layer.removeFromSuperlayer()
                return true
            }
        }
    }

    // MARK: Layers

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// Layer actions that turn off Core Animation's implicit animations, so tiles and strokes move with the fingers.
@MainActor let noAnimations: [String: any CAAction] = [
    "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "path": NSNull(),
    "lineWidth": NSNull(), "strokeColor": NSNull(), "opacity": NSNull(), "hidden": NSNull(), "sublayers": NSNull(),
    "onOrderIn": NSNull(), "onOrderOut": NSNull(), "frame": NSNull(),
]

/// One level of detail's container layer, whose transform maps the level onto the screen.
@MainActor
final class LevelLayer {
    let container = CALayer()

    init() {
        container.actions = noAnimations
        container.anchorPoint = .zero
        container.bounds = .zero
        container.position = .zero
    }
}

/// A tile's layer and image, and the flag that cancels its drawing when it leaves.
@MainActor
final class TileLayer {
    let layer = CALayer()
    var image: CGImage?
    let cancelled = Flag()

    init() {
        layer.actions = noAnimations
        layer.contentsGravity = .resize
        layer.isOpaque = false
    }
}

/// Calls back once a display frame until stopped; a display link needs an Objective-C target.
@MainActor
private final class FrameTicker: NSObject {
    private let body: @MainActor () -> Void
    private var link: CADisplayLink?

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) { body() }

    func stop() {
        link?.invalidate()
        link = nil
    }
}

/// A flag set once on the main thread and read from the drawing threads.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
