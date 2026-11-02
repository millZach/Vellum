#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// How a placed sheet's PDF page is cut into tiles and which of them to draw (#11, ADR-0012's amendment for sheets).
///
/// A page is drawn off the main thread into 256-point tiles of its paper at a level of detail half an octave apart, as
/// ink is: level n draws 2^(n/2) screen points per printed inch of the page. The renderer draws at the smallest level at
/// or above what the zoom asks for, so a tile is never magnified and is shrunk by at most √2, which keeps the tiles on
/// screen to at most 7 × 5 on the unfolded Duo; past `maxLevel` tiles are magnified rather than drawn finer. Each level's
/// tiles sit in one layer whose transform puts them on screen, so a pan or a pinch moves layers and draws nothing that
/// is already drawn. Drawn tiles are kept, newest used last, up to `cacheLimit` bytes; going back over a part of a sheet
/// already seen draws nothing.
///
/// This type decides; the app's renderer draws. It counts what it asks for, so the budgets in
/// `docs/perf/baselines/sheets.json` count the renderer's real work.
public struct SheetTileBook: Sendable {
    /// A tile's edge in screen points at its own level.
    public static let tileSize = 256.0
    /// The finest level: 2^9 = 512 screen points per printed inch, 1,536 pixels per printed inch on a 3x screen.
    public static let maxLevel = 18
    /// The most bytes of drawn tiles kept: 96 MB, about forty 768-pixel tiles, two screens' worth at 3x.
    public static let cacheLimit = 96 << 20

    /// One tile: a sheet, its display (printed, inverted or dimmed), its level, and its column and row on the paper.
    public struct Key: Hashable, Sendable {
        public var sheet: SheetID
        public var display: SheetDisplay
        public var level: Int
        public var x: Int
        public var y: Int

        public init(sheet: SheetID, display: SheetDisplay, level: Int, x: Int, y: Int) {
            self.sheet = sheet
            self.display = display
            self.level = level
            self.x = x
            self.y = y
        }

        /// The tile's rectangle on its sheet's paper, in printed inches.
        public var paperRect: PaperRect {
            let side = SheetTileBook.paperSide(level: level)
            return .inches(x: Double(x) * side, y: Double(y) * side, width: side, height: side)
        }
    }

    /// What a sheet shows for a view: its level, and the tiles covering what is on screen.
    public struct Showing: Hashable, Sendable {
        public var sheet: SheetID
        public var display: SheetDisplay
        public var level: Int
        public var keys: [Key]
        /// Whether every one of `keys` is drawn, so other levels can be let go from the screen.
        public var covered: Bool
    }

    /// What one view needs.
    public struct Plan: Sendable {
        public var showing: [Showing]
        /// Tiles to draw now: on screen and neither drawn nor being drawn.
        public var draw: [Key]
        /// Tiles let go to stay under the cache limit, least recently shown first.
        public var evict: [Key]
    }

    private enum State: Sendable { case drawing, drawn }
    private struct Entry: Sendable {
        var state: State
        var lastShown: Int
    }

    /// Bytes one drawn tile takes: its pixels squared, four bytes each.
    public let tileBytes: Int
    private var entries: [Key: Entry] = [:]
    private var clock = 0
    /// Tiles asked to be drawn, ever: the work budgets' count.
    public private(set) var tilesDrawn = 0
    /// Bytes held by drawn and drawing tiles.
    public var cachedBytes: Int { entries.count * tileBytes }
    public var cachedCount: Int { entries.count }

    public init(displayScale: Double) {
        let pixels = Int((Self.tileSize * displayScale).rounded(.up))
        tileBytes = pixels * pixels * 4
    }

    /// Screen points per printed inch a level draws at: 2^(n/2).
    public static func scale(level: Int) -> Double { pow(2, Double(level) / 2) }

    /// A tile's edge in printed inches at a level.
    public static func paperSide(level: Int) -> Double { tileSize / scale(level: level) }

    /// The level for a sheet at a zoom: the smallest whose screen points per printed inch are at least the zoom's
    /// (`pointsPerInch` canvas inches times the sheet's canvas inches per printed inch), no finer than `maxLevel`, and
    /// no coarser than the level at which the whole page fits one tile.
    public static func level(for sheet: Sheet, pointsPerInch: Double) -> Int {
        let wanted = pointsPerInch * sheet.canvasPerPrinted
        var level = Int((2 * log2(max(wanted, 1e-9))).rounded(.up))
        while scale(level: level) < wanted * (1 - 1e-12) { level += 1 }
        while scale(level: level - 1) >= wanted { level -= 1 }
        let longest = max(sheet.paper.width.inches, sheet.paper.height.inches)
        let coarsest = Int((2 * log2(tileSize / longest)).rounded(.down))
        return min(maxLevel, max(coarsest, level))
    }

    /// The tiles of a sheet at a level that cover a region of its paper, row by row, within the page.
    public static func keys(for sheet: Sheet, display: SheetDisplay, level: Int, covering rect: PaperRect) -> [Key] {
        let side = paperSide(level: level)
        let columns = Int((sheet.paper.width.inches / side).rounded(.up)), rows = Int((sheet.paper.height.inches / side).rounded(.up))
        func index(_ value: Double, _ count: Int) -> Int { min(count - 1, max(0, Int((value / side).rounded(.down)))) }
        guard columns > 0, rows > 0, rect.maxX > 0, rect.maxY > 0, rect.minX < sheet.paper.width.inches,
              rect.minY < sheet.paper.height.inches else { return [] }
        var keys: [Key] = []
        for y in index(rect.minY, rows)...index(rect.maxY, rows) {
            for x in index(rect.minX, columns)...index(rect.maxX, columns) {
                keys.append(Key(sheet: sheet.id, display: display, level: level, x: x, y: y))
            }
        }
        return keys
    }

    /// What a view of the canvas needs: for each sheet on screen, its level and tiles; which of those to draw; and
    /// what to let go to stay under `cacheLimit`. A tile already drawn, or being drawn, is never asked for again while
    /// it is kept.
    public mutating func plan(_ sheets: [Sheet], viewport: Viewport, display: (Sheet) -> SheetDisplay) -> Plan {
        clock += 1
        let visible = viewport.visibleRect
        var showing: [Showing] = []
        var draw: [Key] = []
        for sheet in sheets where sheet.bounds.intersects(visible) {
            let k = sheet.canvasPerPrinted
            let rect = PaperRect.inches(x: (visible.minX - sheet.origin.x).inches / k,
                                        y: (visible.minY - sheet.origin.y).inches / k,
                                        width: visible.size.width.inches / k, height: visible.size.height.inches / k)
            let shown = display(sheet)
            let level = Self.level(for: sheet, pointsPerInch: viewport.pointsPerInch)
            let keys = Self.keys(for: sheet, display: shown, level: level, covering: rect)
            var covered = true
            for key in keys {
                if var entry = entries[key] {
                    entry.lastShown = clock
                    entries[key] = entry
                    if entry.state != .drawn { covered = false }
                } else {
                    entries[key] = Entry(state: .drawing, lastShown: clock)
                    draw.append(key)
                    tilesDrawn += 1
                    covered = false
                }
            }
            showing.append(Showing(sheet: sheet.id, display: shown, level: level, keys: keys, covered: covered))
        }
        return Plan(showing: showing, draw: draw, evict: evictOverLimit())
    }

    /// A tile asked for is drawn.
    public mutating func didDraw(_ key: Key) {
        guard var entry = entries[key] else { return }
        entry.state = .drawn
        entries[key] = entry
    }

    /// A tile asked for could not be drawn (its sheet went, or its PDF could not be read): it may be asked for again.
    public mutating func didFail(_ key: Key) { entries[key] = nil }

    /// Lets go of every tile of a sheet (taken away by an undo) or every tile (dark mode or the screen changed).
    public mutating func forget(sheet: SheetID? = nil) -> [Key] {
        let gone = entries.keys.filter { sheet == nil || $0.sheet == sheet }
        for key in gone { entries[key] = nil }
        return gone
    }

    /// Whether a tile is drawn and kept.
    public func isDrawn(_ key: Key) -> Bool { entries[key]?.state == .drawn }

    /// The least recently shown drawn tiles, beyond the cache limit; tiles shown in this view are never let go.
    private mutating func evictOverLimit() -> [Key] {
        guard cachedBytes > Self.cacheLimit else { return [] }
        let excess = (cachedBytes - Self.cacheLimit + tileBytes - 1) / tileBytes
        let candidates = entries.filter { $0.value.lastShown < clock && $0.value.state == .drawn }
            .sorted { $0.value.lastShown < $1.value.lastShown }
            .prefix(excess).map { $0.key }
        for key in candidates { entries[key] = nil }
        return Array(candidates)
    }
}
