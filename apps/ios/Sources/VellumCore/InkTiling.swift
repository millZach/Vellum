#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// How finished ink is cut into cached tiles (ADR-0012). The renderer draws ink into square tiles at a level of
/// detail, keeps them, and moves and scales them as Zach pans and pinches; only tiles that come into view, or that a
/// change of ink touches, are drawn again.
///
/// Levels are half an octave apart: level n draws at 2^(n/2) screen points per inch. The renderer draws at the
/// smallest level at or above the zoom, so a tile is never magnified (it stays sharp) and is shrunk by at most √2. It
/// keeps a level while the zoom stays between 0.6 and 1.05 of it, so a pinch hovering on a boundary does not redraw.
///
/// Tile coordinates count from an anchor, a canvas point near where the level was made, so the numbers Core
/// Animation sees stay small even far out on a plant-sized canvas at the closest zoom.
public struct InkTiling: Hashable, Sendable {
    /// A tile's edge in screen points at its own level.
    public static let tileSize = 256.0

    /// A tile at a level: column and row from the anchor.
    public struct Key: Hashable, Sendable {
        public var x: Int
        public var y: Int
        public init(x: Int, y: Int) { self.x = x; self.y = y }
    }

    public let level: Int
    /// The canvas point, in inches, tile (0, 0) starts at.
    public let anchorX: Double
    public let anchorY: Double

    public init(level: Int, anchor: CanvasPoint) {
        self.level = level
        anchorX = anchor.x.inches
        anchorY = anchor.y.inches
    }

    /// Screen points per inch the level draws at.
    public var scale: Double { Self.scale(level: level) }

    public static func scale(level: Int) -> Double { pow(2, Double(level) / 2) }

    /// The level to draw at for a zoom: the smallest at or above it.
    public static func level(for pointsPerInch: Double) -> Int {
        var level = Int((2 * log2(pointsPerInch)).rounded(.up))
        while scale(level: level) < pointsPerInch * (1 - 1e-12) { level += 1 }
        while scale(level: level - 1) >= pointsPerInch { level -= 1 }
        return level
    }

    /// Whether a level still suits a zoom: shrunk no more than to 0.6, magnified no more than 5%.
    public static func keeps(level: Int, at pointsPerInch: Double) -> Bool {
        let ratio = pointsPerInch / scale(level: level)
        return ratio >= 0.6 && ratio <= 1.05
    }

    /// Whether a canvas point is so far from the anchor, in this level's points, that Core Animation's precision would
    /// suffer: time for a new anchor.
    public func isFar(from point: CanvasPoint) -> Bool {
        let dx = (point.x.inches - anchorX) * scale, dy = (point.y.inches - anchorY) * scale
        return abs(dx) > 1_000_000 || abs(dy) > 1_000_000
    }

    /// The region of the canvas a tile covers.
    public func box(of key: Key) -> InkIndex.Box {
        let side = Self.tileSize / scale
        let minX = anchorX + Double(key.x) * side, minY = anchorY + Double(key.y) * side
        return InkIndex.Box(minX: minX, minY: minY, maxX: minX + side, maxY: minY + side)
    }

    /// The range of tiles covering a region of the canvas.
    public func keyRange(covering box: InkIndex.Box) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        let side = Self.tileSize / scale
        func index(_ value: Double) -> Int { Int(max(-1e9, min(1e9, (value / side).rounded(.down)))) }
        return (index(box.minX - anchorX)...index(box.maxX - anchorX), index(box.minY - anchorY)...index(box.maxY - anchorY))
    }

    /// Every tile covering a region of the canvas, row by row.
    public func keys(covering box: InkIndex.Box) -> [Key] {
        let range = keyRange(covering: box)
        var keys: [Key] = []
        keys.reserveCapacity(range.x.count * range.y.count)
        for y in range.y { for x in range.x { keys.append(Key(x: x, y: y)) } }
        return keys
    }

    /// How far beyond a stroke's ink a tile still has to be redrawn: ink is never drawn thinner than `minimumWidth`
    /// screen points, which can reach past its real width, plus a point for antialiasing.
    public func margin(minimumWidth: Double) -> Double { (minimumWidth / 2 + 1) / scale }
}

/// Each stroke's path built once, in model space relative to the stroke's first point, and kept until the stroke
/// leaves the canvas (ADR-0012). The renderer builds a path the first time a tile needs it and every later tile, pan
/// or zoom reuses it. Safe to use from the tile-drawing threads.
public final class StrokePathCache<Path>: @unchecked Sendable {
    private let build: @Sendable ([CanvasPoint], CanvasPoint) -> Path
    private var paths: [StrokeID: Path] = [:]
    private let lock = SpinLock()
    /// How many paths have been built, for the work budgets (docs/perf).
    public private(set) var buildCount = 0

    /// `build` makes a path from a stroke's points relative to an origin (its first point).
    public init(build: @escaping @Sendable ([CanvasPoint], CanvasPoint) -> Path) { self.build = build }

    /// A stroke's path, and the canvas point its coordinates count from.
    public func path(for stroke: InkStroke) -> (path: Path, origin: CanvasPoint) {
        let origin = stroke.points.first ?? .origin
        lock.lock()
        if let path = paths[stroke.id] { lock.unlock(); return (path, origin) }
        lock.unlock()
        let path = build(stroke.points, origin)
        lock.lock()
        if paths[stroke.id] == nil { paths[stroke.id] = path; buildCount += 1 }
        let kept = paths[stroke.id]!
        lock.unlock()
        return (kept, origin)
    }

    /// Forgets the paths of strokes that left the canvas.
    public func remove(_ ids: [StrokeID]) {
        lock.lock()
        for id in ids { paths[id] = nil }
        lock.unlock()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return paths.count
    }
}

/// A plain lock that builds on Linux and Darwin without Foundation.
final class SpinLock: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>

    init() {
        mutex = .allocate(capacity: 1)
        pthread_mutex_init(mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    func lock() { pthread_mutex_lock(mutex) }
    func unlock() { pthread_mutex_unlock(mutex) }
}
