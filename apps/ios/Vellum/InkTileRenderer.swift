import QuartzCore
import UIKit
import VellumCore

/// Draws finished ink into cached tiles and moves them with the view (ADR-0012).
///
/// Ink is drawn off the main thread into 256-point tiles at a level of detail (`InkTiling`), from paths built once
/// per stroke in model space (`StrokePathCache`). Each level's tiles sit in one container layer whose transform maps
/// the level onto the screen, so a pan or a pinch changes one transform and redraws nothing. Tiles coming into view
/// are drawn as they appear; when the zoom leaves a level, the old level stays up, scaled, until the new level's
/// visible tiles are drawn. A new stroke is drawn over the tiles it touches, and an erase, undo or redo redraws only
/// the tiles it touches. Until a committed stroke's tiles are drawn, a shape layer shows it, so ink never blinks.
@MainActor
final class InkTileRenderer {
    let layer = CALayer()
    private let overlayLayer = CALayer()
    private let index: @MainActor () -> InkIndex
    private var current: TileLevel?
    private var fallback: TileLevel?
    private var viewport: Viewport?
    /// Bumped on every change of ink or colours; a tile is up to date when it was drawn at its latest change.
    private var epoch = 0
    private var overlays: [Overlay] = []
    private let paths = StrokePathCache<CGPath> { points, origin in InkTileRenderer.path(points, from: origin) }
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Vellum ink tiles"
        // Two drawing threads leave the main thread and the render server a core each.
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// Tile drawings waiting or in flight.
    private(set) var pendingCount = 0
    /// Tiles waiting for their strokes to be found, and the frame ticker that takes them a few at a time.
    private var waiting: [(tile: Tile, level: TileLevel)] = []
    private var ticker: FrameTicker?
    /// How much of a frame the main thread spends starting tiles: a quarter of 120 Hz's 8.3 ms.
    private static let frameShare = 0.002

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
    }

    /// The layer committed strokes show on until their tiles are drawn; it goes above the tiles.
    var pendingInkLayer: CALayer { overlayLayer }

    // MARK: The view

    /// Moves the tiles to a new view of the canvas and draws any that came into view.
    func show(_ viewport: Viewport) {
        self.viewport = viewport
        let ppi = viewport.pointsPerInch
        if let level = current, InkTiling.keeps(level: level.tiling.level, at: ppi), !level.tiling.isFar(from: viewport.centre) {
            // Same level: only the transform changes.
        } else {
            switchLevel(to: InkTiling(level: InkTiling.level(for: ppi), anchor: viewport.centre))
        }
        withoutAnimation {
            if let current { place(current, for: viewport) }
            if let fallback { place(fallback, for: viewport) }
            placeOverlays(for: viewport)
        }
        requestVisibleTiles()
    }

    private func switchLevel(to tiling: InkTiling) {
        withoutAnimation {
            fallback?.removeAll()
            fallback = current
            let level = TileLevel(tiling: tiling, epoch: epoch)
            layer.addSublayer(level.container)
            current = level
        }
    }

    /// Maps a level onto the screen: level points scaled by zoom / level scale, offset to where the anchor is.
    private func place(_ level: TileLevel, for viewport: Viewport) {
        let k = viewport.pointsPerInch / level.tiling.scale
        let anchor = viewport.screenPoint(for: CanvasPoint(x: .inches(level.tiling.anchorX), y: .inches(level.tiling.anchorY)))
        level.container.transform = CATransform3DMakeAffineTransform(
            CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: anchor.x, ty: anchor.y))
    }

    private func requestVisibleTiles() {
        guard let level = current, let viewport else { return }
        let visible = InkIndex.Box(viewport.visibleRect)
        let side = InkTiling.tileSize / level.tiling.scale
        let wanted = level.tiling.keyRange(covering: visible)
        // Keep tiles a little way off screen so a pan back finds them; drop the rest.
        let kept = level.tiling.keyRange(covering: visible.grown(by: side))
        withoutAnimation {
            for (key, tile) in level.tiles where !kept.x.contains(key.x) || !kept.y.contains(key.y) {
                tile.layer.removeFromSuperlayer()
                tile.removed = true
                level.tiles[key] = nil
            }
            for y in wanted.y {
                for x in wanted.x {
                    let key = InkTiling.Key(x: x, y: y)
                    guard level.tiles[key] == nil else { continue }
                    let tile = level.addTile(key, epoch: epoch)
                    schedule(tile, in: level, adding: nil)
                }
            }
        }
        dropFallbackIfCovered()
    }

    private func dropFallbackIfCovered() {
        guard let fallback, let level = current, let viewport else { return }
        let wanted = level.tiling.keyRange(covering: InkIndex.Box(viewport.visibleRect))
        for y in wanted.y {
            for x in wanted.x {
                guard let tile = level.tiles[InkTiling.Key(x: x, y: y)], tile.renderedEpoch >= 0 else { return }
            }
        }
        withoutAnimation { fallback.removeAll() }
        self.fallback = nil
    }

    // MARK: Changes of ink

    /// Redraws only what a change of ink touched: a stroke drawn on top is drawn over its tiles; anything else
    /// redraws the tiles it touched.
    func inkChanged(_ change: InkIndex.Change) {
        guard !change.isEmpty else { return }
        paths.remove(change.removed.map(\.id))
        epoch += 1
        withoutAnimation {
            // The old level is stale now; the current one is redrawn where it changed.
            fallback?.removeAll()
            fallback = nil
            for stroke in change.added where change.addedOnTop {
                addOverlay(for: stroke)
            }
        }
        guard let level = current else { return }
        let margin = level.tiling.margin(minimumWidth: Self.minimumWidth)
        var touched: [InkTiling.Key: [InkStroke]] = [:]
        for stroke in change.added + change.removed {
            guard let box = InkIndex.box(of: stroke) else { continue }
            let range = level.tiling.keyRange(covering: box.grown(by: margin))
            for y in range.y {
                for x in range.x {
                    let key = InkTiling.Key(x: x, y: y)
                    guard level.tiles[key] != nil else { continue }
                    touched[key, default: []].append(stroke)
                }
            }
        }
        for (key, strokes) in touched {
            guard let tile = level.tiles[key] else { continue }
            let upToDate = !tile.inFlight && tile.image != nil && tile.renderedEpoch == tile.epoch
            tile.epoch = epoch
            schedule(tile, in: level, adding: change.addedOnTop && upToDate ? strokes : nil)
        }
        removeFinishedOverlays()
    }

    private func redrawEverything() {
        epoch += 1
        withoutAnimation {
            fallback?.removeAll()
            fallback = nil
            for overlay in overlays { overlay.layer.strokeColor = Self.colour(overlay.stroke.colour, dark: isDark) }
        }
        guard let level = current else { return }
        for tile in level.tiles.values {
            tile.epoch = epoch
            schedule(tile, in: level, adding: nil)
        }
    }

    // MARK: Drawing tiles

    /// Starts drawing a tile, unless it is already being drawn (it is drawn again when that finishes). With
    /// `adding`, the strokes are drawn over the tile's current image rather than the tile redrawn.
    private func schedule(_ tile: Tile, in level: TileLevel, adding: [InkStroke]?) {
        guard !tile.inFlight else { return }
        if let adding, let image = tile.image {
            start(tile, in: level, strokes: adding.sorted { $0.id < $1.id }, base: image)
            return
        }
        // Finding a tile's strokes is main-thread work, so tiles wait their turn and each frame takes only a
        // couple of milliseconds of them (`takeWaitingTiles`).
        guard !tile.waiting else { return }
        tile.waiting = true
        waiting.append((tile, level))
        pendingCount += 1
        if ticker == nil {
            ticker = FrameTicker { [weak self] in self?.takeWaitingTiles() }
        }
    }

    /// Starts drawing waiting tiles, nearest the front of the queue first, until this frame's share of main-thread
    /// time is spent.
    private func takeWaitingTiles() {
        let began = CACurrentMediaTime()
        while !waiting.isEmpty {
            let (tile, level) = waiting.removeFirst()
            tile.waiting = false
            pendingCount -= 1
            guard !tile.removed, level.isLive, !tile.inFlight else { continue }
            let tiling = level.tiling
            let box = tiling.box(of: tile.key).grown(by: tiling.margin(minimumWidth: Self.minimumWidth))
            start(tile, in: level, strokes: index().strokes(in: box), base: nil)
            if CACurrentMediaTime() - began > Self.frameShare { break }
        }
        if waiting.isEmpty {
            ticker?.stop()
            ticker = nil
        }
    }

    private func start(_ tile: Tile, in level: TileLevel, strokes: [InkStroke], base: CGImage?) {
        let box = level.tiling.box(of: tile.key)
        let tiling = level.tiling
        let job = TileJob(pixels: Int((InkTiling.tileSize * displayScale).rounded()), displayScale: displayScale,
                          levelScale: tiling.scale, originX: box.minX, originY: box.minY, base: base,
                          strokes: strokes, dark: isDark, paths: paths)
        let jobEpoch = tile.epoch
        tile.inFlight = true
        pendingCount += 1
        queue.addOperation {
            let image = ImageBox(image: Self.draw(job))
            Task { @MainActor in
                self.finish(tile, in: level, epoch: jobEpoch, image: image)
            }
        }
    }

    private func finish(_ tile: Tile, in level: TileLevel, epoch jobEpoch: Int, image: ImageBox) {
        pendingCount -= 1
        tile.inFlight = false
        guard !tile.removed, level.isLive else { return }
        if let image = image.image {
            tile.image = image
            withoutAnimation { tile.layer.contents = image }
        }
        tile.renderedEpoch = jobEpoch
        if tile.epoch > jobEpoch { schedule(tile, in: level, adding: nil) }
        removeFinishedOverlays()
        if level === current { dropFallbackIfCovered() }
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
    }

    private struct ImageBox: @unchecked Sendable { let image: CGImage? }

    /// Draws one tile: its ink at the level's scale, over `base` when only new strokes are added.
    private nonisolated static func draw(_ job: TileJob) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
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
        for stroke in job.strokes {
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

    private final class Overlay {
        let stroke: InkStroke
        let box: InkIndex.Box
        let epoch: Int
        let layer = CAShapeLayer()
        init(stroke: InkStroke, box: InkIndex.Box, epoch: Int) {
            self.stroke = stroke
            self.box = box
            self.epoch = epoch
        }
    }

    private func addOverlay(for stroke: InkStroke) {
        guard let box = InkIndex.box(of: stroke) else { return }
        let overlay = Overlay(stroke: stroke, box: box, epoch: epoch)
        overlay.layer.actions = noAnimations
        overlay.layer.fillColor = nil
        overlay.layer.lineCap = .round
        overlay.layer.lineJoin = .round
        overlay.layer.strokeColor = Self.colour(stroke.colour, dark: isDark)
        overlay.layer.opacity = Float(stroke.tool.opacity)
        overlayLayer.addSublayer(overlay.layer)
        overlays.append(overlay)
        if let viewport { place(overlay, for: viewport) }
    }

    private func placeOverlays(for viewport: Viewport) {
        for overlay in overlays { place(overlay, for: viewport) }
    }

    private func place(_ overlay: Overlay, for viewport: Viewport) {
        let (path, origin) = paths.path(for: overlay.stroke)
        let screen = viewport.screenPoint(for: origin)
        var transform = CGAffineTransform(a: viewport.pointsPerInch, b: 0, c: 0, d: viewport.pointsPerInch,
                                          tx: screen.x, ty: screen.y)
        overlay.layer.frame = layer.bounds
        overlay.layer.path = path.copy(using: &transform)
        overlay.layer.lineWidth = max(overlay.stroke.width.inches * viewport.pointsPerInch, Self.minimumWidth)
    }

    /// Takes away each committed stroke's shape layer once every tile it touches has been drawn with it.
    private func removeFinishedOverlays() {
        guard !overlays.isEmpty else { return }
        let margin = current.map { $0.tiling.margin(minimumWidth: Self.minimumWidth) } ?? 0
        overlays.removeAll { overlay in
            if let level = current {
                let range = level.tiling.keyRange(covering: overlay.box.grown(by: margin))
                for y in range.y {
                    for x in range.x {
                        if let tile = level.tiles[InkTiling.Key(x: x, y: y)],
                           tile.renderedEpoch < overlay.epoch || tile.image == nil { return false }
                    }
                }
            }
            withoutAnimation { overlay.layer.removeFromSuperlayer() }
            return true
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

/// One level of detail's tiles, in one container layer.
@MainActor
private final class TileLevel {
    let tiling: InkTiling
    let container = CALayer()
    var tiles: [InkTiling.Key: Tile] = [:]
    /// False once the level is taken down; drawings finishing for it are dropped.
    private(set) var isLive = true

    init(tiling: InkTiling, epoch: Int) {
        self.tiling = tiling
        container.actions = noAnimations
        container.anchorPoint = .zero
        container.bounds = .zero
        container.position = .zero
    }

    func addTile(_ key: InkTiling.Key, epoch: Int) -> Tile {
        let tile = Tile(key: key, epoch: epoch)
        let side = InkTiling.tileSize
        tile.layer.frame = CGRect(x: Double(key.x) * side, y: Double(key.y) * side, width: side, height: side)
        container.addSublayer(tile.layer)
        tiles[key] = tile
        return tile
    }

    func removeAll() {
        isLive = false
        for tile in tiles.values { tile.removed = true }
        tiles.removeAll()
        container.removeFromSuperlayer()
    }
}

/// One tile: its layer, its image, and which change of ink it was last drawn at.
@MainActor
private final class Tile {
    let key: InkTiling.Key
    let layer = CALayer()
    var image: CGImage?
    /// The latest change of ink that touched the tile.
    var epoch: Int
    /// The change the tile's image was drawn at; -1 before it is first drawn.
    var renderedEpoch = -1
    var inFlight = false
    var waiting = false
    var removed = false

    init(key: InkTiling.Key, epoch: Int) {
        self.key = key
        self.epoch = epoch
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
