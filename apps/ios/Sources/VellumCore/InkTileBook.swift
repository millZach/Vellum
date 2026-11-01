/// The finished-ink renderer's bookkeeping (ADR-0012): which levels of tiles exist, which tiles each holds, which of
/// them are drawn and up to date, and which to draw next. The renderer owns the layers, images and drawing threads;
/// every decision about what to draw is made here, so the work budgets (docs/perf) count what the renderer really
/// asks for rather than a picture of it.
///
/// The book talks to the renderer through hooks: it makes and discards a level's and a tile's payload (the renderer's
/// layers) and asks for a tile to be drawn. A draw request either redraws the tile or, with `adding`, draws new
/// strokes over its current image. The renderer reports back with `begin` when a waiting tile's drawing starts and
/// `finished` when it ends.
///
/// Rules it keeps:
/// - A change of ink touches only the tiles that exist and intersect it, found by looking at the cached tiles or at
///   the stroke's tile range, whichever is smaller, never every tile position a long stroke spans.
/// - When the zoom leaves a level, the old level stays up until the new one covers the screen. A second level change
///   before that keeps whichever of the old levels already covers the screen (or the one already kept), so a quick
///   pinch never shows blank canvas where ink was.
/// - A tile being drawn is not asked for again; it is redrawn when that drawing finishes, if ink changed meanwhile.
///
/// Main-thread only.
public final class InkTileBook<LevelPayload, TilePayload> {
    public final class Level {
        public let tiling: InkTiling
        public let payload: LevelPayload
        public fileprivate(set) var tiles: [InkTiling.Key: Tile] = [:]
        /// False once the level is taken down; drawings finishing for it are dropped.
        public fileprivate(set) var isLive = true

        fileprivate init(tiling: InkTiling, payload: LevelPayload) {
            self.tiling = tiling
            self.payload = payload
        }
    }

    public final class Tile {
        public let key: InkTiling.Key
        public let payload: TilePayload
        /// The latest change of ink that touched the tile.
        public fileprivate(set) var epoch: Int
        /// The change the tile's image was drawn at; -1 before it is first drawn.
        public fileprivate(set) var renderedEpoch = -1
        public fileprivate(set) var hasImage = false
        public fileprivate(set) var inFlight = false
        public fileprivate(set) var waiting = false
        /// Set when the tile leaves the screen or its level is taken down.
        public fileprivate(set) var removed = false

        fileprivate init(key: InkTiling.Key, payload: TilePayload, epoch: Int) {
            self.key = key
            self.payload = payload
            self.epoch = epoch
        }

        /// Drawn, with an image, at the latest change that touched it.
        public var isUpToDate: Bool { !inFlight && hasImage && renderedEpoch == epoch }
    }

    /// What the book has asked the renderer to do, for the work budgets.
    public struct Work: Sendable {
        /// Tile drawings requested.
        public var tilesDrawn = 0
        /// The screen area those tiles cover at the view they were requested in, in square points.
        public var areaDrawn = 0.0
        /// Tile positions looked up (or cached tiles looked at) to find what a change of ink touched.
        public var keysProbed = 0
        public init() {}
    }

    public struct Hooks {
        public var makeLevel: (InkTiling) -> LevelPayload
        public var makeTile: (InkTiling.Key, Level) -> TilePayload
        public var discardLevel: (Level) -> Void
        public var discardTile: (Tile, Level) -> Void
        /// Draw this tile: over its current image with `adding`, or from scratch with nil.
        public var draw: (Tile, Level, _ adding: [InkStroke]?) -> Void

        public init(makeLevel: @escaping (InkTiling) -> LevelPayload,
                    makeTile: @escaping (InkTiling.Key, Level) -> TilePayload,
                    discardLevel: @escaping (Level) -> Void, discardTile: @escaping (Tile, Level) -> Void,
                    draw: @escaping (Tile, Level, [InkStroke]?) -> Void) {
            self.makeLevel = makeLevel
            self.makeTile = makeTile
            self.discardLevel = discardLevel
            self.discardTile = discardTile
            self.draw = draw
        }
    }

    public private(set) var current: Level?
    /// The level kept up, scaled, while `current` is still being drawn.
    public private(set) var fallback: Level?
    public private(set) var viewport: Viewport?
    /// Bumped on every change of ink or colours.
    public private(set) var epoch = 0
    public var work = Work()
    /// How far beyond a stroke's ink a tile still holds some of it: ink is never drawn thinner than this many screen
    /// points.
    public let minimumWidth: Double
    private let hooks: Hooks

    public init(minimumWidth: Double, hooks: Hooks) {
        self.minimumWidth = minimumWidth
        self.hooks = hooks
    }

    // MARK: The view

    /// Moves to a new view of the canvas: changes level if the zoom left the current one, adds the tiles that came
    /// into view and asks for them to be drawn, and drops tiles well off screen.
    public func show(_ viewport: Viewport) {
        self.viewport = viewport
        let ppi = viewport.pointsPerInch
        if let level = current, InkTiling.keeps(level: level.tiling.level, at: ppi),
           !level.tiling.isFar(from: viewport.centre) {
            // Same level: the renderer changes one transform.
        } else {
            switchLevel(to: InkTiling(level: InkTiling.level(for: ppi), anchor: viewport.centre))
        }
        requestVisibleTiles()
    }

    private func switchLevel(to tiling: InkTiling) {
        let outgoing = current
        current = Level(tiling: tiling, payload: hooks.makeLevel(tiling))
        guard let outgoing else { return }
        // Keep the outgoing level if it covers the screen or nothing else is kept; otherwise it was never finished
        // and the level already kept is the better one to show.
        if fallback == nil || covers(outgoing) {
            if let fallback { discard(fallback) }
            fallback = outgoing
        } else {
            discard(outgoing)
        }
    }

    /// Whether every tile of a level on screen is there and drawn.
    public func covers(_ level: Level) -> Bool {
        guard let viewport else { return false }
        let range = level.tiling.keyRange(covering: InkIndex.Box(viewport.visibleRect))
        let (count, overflow) = range.x.count.multipliedReportingOverflow(by: range.y.count)
        guard !overflow, count <= level.tiles.count else { return false }
        for y in range.y {
            for x in range.x {
                guard let tile = level.tiles[InkTiling.Key(x: x, y: y)], tile.renderedEpoch >= 0 else { return false }
            }
        }
        return true
    }

    private func requestVisibleTiles() {
        guard let level = current, let viewport else { return }
        let visible = InkIndex.Box(viewport.visibleRect)
        let side = InkTiling.tileSize / level.tiling.scale
        let wanted = level.tiling.keyRange(covering: visible)
        // Keep tiles a tile's width off screen so a pan back finds them; drop the rest.
        let kept = level.tiling.keyRange(covering: visible.grown(by: side))
        for (key, tile) in level.tiles where !kept.x.contains(key.x) || !kept.y.contains(key.y) {
            tile.removed = true
            level.tiles[key] = nil
            hooks.discardTile(tile, level)
        }
        for y in wanted.y {
            for x in wanted.x {
                let key = InkTiling.Key(x: x, y: y)
                guard level.tiles[key] == nil else { continue }
                let tile = Tile(key: key, payload: hooks.makeTile(key, level), epoch: epoch)
                level.tiles[key] = tile
                needsDrawing(tile, in: level, adding: nil)
            }
        }
        dropFallbackIfCovered()
    }

    private func dropFallbackIfCovered() {
        guard let fallback, let level = current, covers(level) else { return }
        discard(fallback)
        self.fallback = nil
    }

    private func discard(_ level: Level) {
        level.isLive = false
        for tile in level.tiles.values { tile.removed = true }
        hooks.discardLevel(level)
        level.tiles.removeAll()
    }

    // MARK: Changes of ink

    /// The existing tiles of a level that hold some of a region: whichever is fewer of the region's tile positions
    /// and the level's cached tiles is looked at.
    public func tiles(of level: Level, touching box: InkIndex.Box) -> [Tile] {
        let range = level.tiling.keyRange(covering: box)
        let (count, overflow) = range.x.count.multipliedReportingOverflow(by: range.y.count)
        if !overflow, count <= level.tiles.count {
            work.keysProbed += count
            var found: [Tile] = []
            for y in range.y {
                for x in range.x {
                    if let tile = level.tiles[InkTiling.Key(x: x, y: y)] { found.append(tile) }
                }
            }
            return found
        }
        work.keysProbed += level.tiles.count
        return level.tiles.values.filter { range.x.contains($0.key.x) && range.y.contains($0.key.y) }
    }

    /// Redraws only what a change of ink touched: strokes drawn on top are drawn over the tiles that hold them;
    /// anything else redraws the tiles it touched.
    public func inkChanged(_ change: InkIndex.Change) {
        guard !change.isEmpty else { return }
        epoch += 1
        if !change.addedOnTop || !change.removed.isEmpty, let fallback {
            // The kept level still shows erased ink, and it shows through the current level's clear pixels.
            discard(fallback)
            self.fallback = nil
        }
        guard let level = current else { return }
        let margin = level.tiling.margin(minimumWidth: minimumWidth)
        var touched: [InkTiling.Key: (tile: Tile, strokes: [InkStroke])] = [:]
        for stroke in change.added + change.removed {
            guard let box = InkIndex.box(of: stroke) else { continue }
            for tile in tiles(of: level, touching: box.grown(by: margin)) {
                touched[tile.key, default: (tile, [])].strokes.append(stroke)
            }
        }
        for (tile, strokes) in touched.values {
            let upToDate = tile.isUpToDate
            tile.epoch = epoch
            needsDrawing(tile, in: level, adding: change.addedOnTop && upToDate ? strokes.sorted { $0.id < $1.id } : nil)
        }
    }

    /// Redraws every tile on screen, for a change of colours or display scale.
    public func redrawEverything() {
        epoch += 1
        if let fallback {
            discard(fallback)
            self.fallback = nil
        }
        guard let level = current else { return }
        for tile in level.tiles.values {
            tile.epoch = epoch
            needsDrawing(tile, in: level, adding: nil)
        }
    }

    // MARK: Drawing

    private func needsDrawing(_ tile: Tile, in level: Level, adding: [InkStroke]?) {
        // A drawing in flight is followed by another when it finishes, if the tile changed meanwhile.
        guard !tile.inFlight else { return }
        if let adding, tile.hasImage {
            tile.inFlight = true
            count(tile, in: level)
            hooks.draw(tile, level, adding)
            return
        }
        guard !tile.waiting else { return }
        tile.waiting = true
        count(tile, in: level)
        hooks.draw(tile, level, nil)
    }

    private func count(_ tile: Tile, in level: Level) {
        work.tilesDrawn += 1
        guard let viewport else { return }
        let side = InkTiling.tileSize * viewport.pointsPerInch / level.tiling.scale
        work.areaDrawn += side * side
    }

    /// A waiting tile's drawing is starting. False when it no longer needs one (it left, or is already drawing).
    public func begin(_ tile: Tile, in level: Level) -> Bool {
        tile.waiting = false
        guard !tile.removed, level.isLive, !tile.inFlight else { return false }
        tile.inFlight = true
        return true
    }

    /// A tile's drawing, made at `epoch`, finished; `drewImage` is false when it was cancelled.
    public func finished(_ tile: Tile, in level: Level, epoch drawnAt: Int, drewImage: Bool) {
        tile.inFlight = false
        guard !tile.removed, level.isLive else { return }
        if drewImage { tile.hasImage = true }
        tile.renderedEpoch = drawnAt
        if tile.epoch > drawnAt { needsDrawing(tile, in: level, adding: nil) }
        if level === current { dropFallbackIfCovered() }
    }
}
