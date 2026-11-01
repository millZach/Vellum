/// Where every stroke of ink is on the canvas, so the renderer and the eraser look only at the strokes near a place
/// instead of every stroke on the canvas (ADR-0012).
///
/// The canvas zooms over a factor of 500,000, so strokes run from a fraction of an inch to hundreds of feet, and one
/// grid size cannot suit them all. The index is a stack of uniform grids in model space whose cells double in size
/// from 1/256 inch upwards. A stroke goes in exactly one cell: on the level whose cells are at least as large as the
/// stroke, in the cell holding its bounds' lower corner. A stroke therefore reaches at most one cell further right and
/// down than its own, so a query looks one cell further up and left on each level and never meets a stroke twice.
///
/// Each stroke's bounds are worked out once, when it goes in. The index is a value; `sync(with:)` keeps it in step
/// with the ink after any edit, undo or redo and reports what changed, so the renderer knows what to redraw.
public struct InkIndex: Sendable {
    /// A rectangle in inches, kept as plain `Double`s for the hot loops.
    public struct Box: Hashable, Sendable {
        public var minX: Double
        public var minY: Double
        public var maxX: Double
        public var maxY: Double

        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }

        public init(_ rect: CanvasRect) {
            let (x0, x1, y0, y1) = (rect.minX.inches, rect.maxX.inches, rect.minY.inches, rect.maxY.inches)
            self.init(minX: min(x0, x1), minY: min(y0, y1), maxX: max(x0, x1), maxY: max(y0, y1))
        }

        /// A box `amount` larger on every side.
        public func grown(by amount: Double) -> Box {
            Box(minX: minX - amount, minY: minY - amount, maxX: maxX + amount, maxY: maxY + amount)
        }

        public func intersects(_ other: Box) -> Bool {
            minX <= other.maxX && other.minX <= maxX && minY <= other.maxY && other.minY <= maxY
        }

        public var rect: CanvasRect {
            CanvasRect(origin: CanvasPoint(x: .inches(minX), y: .inches(minY)),
                       size: CanvasSize(width: .inches(maxX - minX), height: .inches(maxY - minY)))
        }
    }

    struct Cell: Hashable, Sendable {
        var x: Int
        var y: Int
    }

    struct Entry: Sendable {
        var stroke: InkStroke
        var box: Box
        var level: Int
        var cell: Cell
    }

    /// The smallest cells are 2^-8 inch across; the largest 2^40 inches, far past any plant.
    static let finestLevel = -8
    static let coarsestLevel = 40

    private var entries: [StrokeID: Entry] = [:]
    /// The strokes in each cell, level by level.
    private var levels: [Int: [Cell: [StrokeID]]] = [:]
    /// Every stroke's id, in ascending order, which is the order the ink keeps them in.
    private var ids: [StrokeID] = []

    public init() {}

    /// An index of all of this ink.
    public init(_ ink: Ink) {
        for stroke in ink.strokes { insert(stroke) }
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public func contains(_ id: StrokeID) -> Bool { entries[id] != nil }
    public func stroke(_ id: StrokeID) -> InkStroke? { entries[id]?.stroke }
    /// The latest stroke's id.
    public var latestID: StrokeID? { ids.last }

    /// The rectangle a stroke's ink covers, worked out once when it went in.
    public func bounds(of id: StrokeID) -> Box? { entries[id]?.box }

    // MARK: Keeping in step

    /// Adds a stroke. A stroke already in the index is replaced; a stroke with no points is left out.
    public mutating func insert(_ stroke: InkStroke) {
        if entries[stroke.id] != nil { remove(stroke.id) }
        guard let box = Self.box(of: stroke) else { return }
        let level = Self.level(for: box)
        let size = Self.cellSize(level)
        let cell = Cell(x: Self.cellIndex(box.minX, size), y: Self.cellIndex(box.minY, size))
        entries[stroke.id] = Entry(stroke: stroke, box: box, level: level, cell: cell)
        levels[level, default: [:]][cell, default: []].append(stroke.id)
        let at = Self.insertionPoint(of: stroke.id, in: ids)
        ids.insert(stroke.id, at: at)
    }

    /// Takes a stroke out; returns it, or nil when it was not in the index.
    @discardableResult
    public mutating func remove(_ id: StrokeID) -> InkStroke? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        if var cells = levels[entry.level], var members = cells[entry.cell] {
            members.removeAll { $0 == id }
            if members.isEmpty { cells[entry.cell] = nil } else { cells[entry.cell] = members }
            levels[entry.level] = cells.isEmpty ? nil : cells
        }
        let at = Self.insertionPoint(of: id, in: ids)
        if at < ids.count, ids[at] == id { ids.remove(at: at) }
        return entry.stroke
    }

    /// What one `sync(with:)` changed.
    public struct Change: Sendable {
        public var added: [InkStroke] = []
        public var removed: [InkStroke] = []
        /// True when nothing was removed and every added stroke is newer than every stroke already there, so it is
        /// drawn on top of all of them: a renderer can draw it over what it has rather than redraw.
        public var addedOnTop = true

        public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    }

    /// Brings the index in step with the ink, whatever changed it (a stroke, an erase, undo, redo or a canvas loaded),
    /// and returns what changed. Ink keeps its strokes in the order drawn, which is ascending id, so this is one walk
    /// down two sorted lists; ink in any other order falls back to a lookup per stroke.
    @discardableResult
    public mutating func sync(with ink: Ink) -> Change {
        var change = Change()
        let latestBefore = ids.last
        var added: [InkStroke] = []
        var removedIDs: [StrokeID] = []
        let strokes = ink.strokes
        var i = 0, j = 0
        var sorted = true
        var previous: StrokeID?
        while i < strokes.count {
            let id = strokes[i].id
            if let previous, id <= previous { sorted = false; break }
            previous = id
            if j < ids.count, ids[j] < id {
                removedIDs.append(ids[j]); j += 1
            } else if j < ids.count, ids[j] == id {
                i += 1; j += 1
            } else {
                added.append(strokes[i]); i += 1
            }
        }
        if sorted {
            while j < ids.count { removedIDs.append(ids[j]); j += 1 }
        } else {
            added = strokes.filter { entries[$0.id] == nil }
            let present = Set(strokes.map(\.id))
            removedIDs = ids.filter { !present.contains($0) }
        }
        for id in removedIDs {
            if let stroke = remove(id) { change.removed.append(stroke) }
        }
        for stroke in added { insert(stroke) }
        change.added = added
        change.addedOnTop = removedIDs.isEmpty && added.allSatisfy { latestBefore == nil || $0.id > latestBefore! }
        return change
    }

    // MARK: Looking things up

    /// The work a lookup did, for the work budgets (docs/perf): strokes whose cached bounds it compared, and stroke
    /// points it looked at.
    public struct Work: Hashable, Sendable {
        public var strokesVisited = 0
        public var pointsInspected = 0
        public init() {}
    }

    /// The ids of the strokes whose ink touches a rectangle, in the order they were drawn (bottom first).
    public func strokeIDs(in box: Box) -> [StrokeID] {
        var work = Work()
        return strokeIDs(in: box, work: &work)
    }

    public func strokeIDs(in box: Box, work: inout Work) -> [StrokeID] {
        var found: [StrokeID] = []
        visit(box, &work) { found.append($0.stroke.id) }
        found.sort()
        return found
    }

    /// The strokes whose ink touches a rectangle, in the order they were drawn (bottom first).
    public func strokes(in box: Box) -> [InkStroke] {
        var found: [Entry] = []
        var work = Work()
        visit(box, &work) { found.append($0) }
        found.sort { $0.stroke.id < $1.stroke.id }
        return found.map(\.stroke)
    }

    public func strokes(in rect: CanvasRect) -> [InkStroke] { strokes(in: Box(rect)) }

    /// The strokes the eraser touches at a point, topmost (latest) first: those whose ink lies within `tolerance` of
    /// it, the same test as `InkStroke.isHit`, made with squared distances and stopping at the first segment close
    /// enough.
    public func strokes(hitAt point: CanvasPoint, tolerance: Length) -> [InkStroke] {
        var work = Work()
        return strokes(hitAt: point, tolerance: tolerance, work: &work)
    }

    public func strokes(hitAt point: CanvasPoint, tolerance: Length, work: inout Work) -> [InkStroke] {
        let px = point.x.inches, py = point.y.inches, t = tolerance.inches
        let probe = Box(minX: px, minY: py, maxX: px, maxY: py).grown(by: t)
        var hits: [InkStroke] = []
        var inspected = 0
        visit(probe, &work) { entry in
            if Self.isHit(entry, px, py, t, inspected: &inspected) { hits.append(entry.stroke) }
        }
        work.pointsInspected += inspected
        hits.sort { $0.id > $1.id }
        return hits
    }

    /// Calls `body` once for every stroke whose bounds touch `box`.
    private func visit(_ box: Box, _ work: inout Work, _ body: (Entry) -> Void) {
        for (level, cells) in levels {
            let size = Self.cellSize(level)
            // A stroke reaches at most one cell past its own, so look one cell further up and left.
            let lowX = (box.minX / size).rounded(.down) - 1, highX = (box.maxX / size).rounded(.down)
            let lowY = (box.minY / size).rounded(.down) - 1, highY = (box.maxY / size).rounded(.down)
            let span = (highX - lowX + 1) * (highY - lowY + 1)
            if span.isFinite, span <= Double(cells.count), abs(lowX) < 1e15, abs(highX) < 1e15, abs(lowY) < 1e15,
               abs(highY) < 1e15 {
                for x in Int(lowX)...Int(highX) {
                    for y in Int(lowY)...Int(highY) {
                        guard let members = cells[Cell(x: x, y: y)] else { continue }
                        work.strokesVisited += members.count
                        for id in members {
                            if let entry = entries[id], entry.box.intersects(box) { body(entry) }
                        }
                    }
                }
            } else {
                // Fewer cells hold ink on this level than the box covers: look at the ones that do.
                for (cell, members) in cells {
                    let x = Double(cell.x), y = Double(cell.y)
                    guard x >= lowX, x <= highX, y >= lowY, y <= highY else { continue }
                    work.strokesVisited += members.count
                    for id in members {
                        if let entry = entries[id], entry.box.intersects(box) { body(entry) }
                    }
                }
            }
        }
    }

    // MARK: Geometry

    /// The stroke's ink rectangle, the same as `InkStroke.bounds`, in one pass over its points.
    public static func box(of stroke: InkStroke) -> Box? {
        guard let first = stroke.points.first else { return nil }
        var minX = first.x.inches, maxX = minX, minY = first.y.inches, maxY = minY
        for p in stroke.points.dropFirst() {
            let x = p.x.inches, y = p.y.inches
            if x < minX { minX = x } else if x > maxX { maxX = x }
            if y < minY { minY = y } else if y > maxY { maxY = y }
        }
        return Box(minX: minX, minY: minY, maxX: maxX, maxY: maxY).grown(by: stroke.width.inches / 2)
    }

    /// Whether the eraser at (px, py) with tolerance t touches the stroke: inside its bounds grown by t, then within
    /// half its width plus t of a segment, compared squared, stopping at the first segment that is.
    static func isHit(_ entry: Entry, _ px: Double, _ py: Double, _ t: Double, inspected: inout Int) -> Bool {
        let b = entry.box
        guard px >= b.minX - t, px <= b.maxX + t, py >= b.minY - t, py <= b.maxY + t else { return false }
        let reach = entry.stroke.width.inches / 2 + t
        let reachSquared = reach * reach
        let points = entry.stroke.points
        guard let first = points.first else { return false }
        if points.count == 1 {
            inspected += 1
            let dx = first.x.inches - px, dy = first.y.inches - py
            return dx * dx + dy * dy <= reachSquared
        }
        var ax = first.x.inches, ay = first.y.inches
        inspected += 1
        for i in 1..<points.count {
            inspected += 1
            let bx = points[i].x.inches, by = points[i].y.inches
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            var t = lengthSquared == 0 ? 0 : ((px - ax) * dx + (py - ay) * dy) / lengthSquared
            t = t < 0 ? 0 : (t > 1 ? 1 : t)
            let cx = ax + t * dx - px, cy = ay + t * dy - py
            if cx * cx + cy * cy <= reachSquared { return true }
            ax = bx; ay = by
        }
        return false
    }

    /// The level whose cells are at least as large as the box, within the levels the index keeps.
    static func level(for box: Box) -> Int {
        let extent = max(box.maxX - box.minX, box.maxY - box.minY)
        guard extent.isFinite, extent > cellSize(finestLevel) else { return finestLevel }
        // The binary exponent is log2 rounded down, exact; a box between powers of two needs the next one up.
        var level = Int(extent.exponent)
        if cellSize(level) < extent { level += 1 }
        return min(max(level, finestLevel), coarsestLevel)
    }

    static func cellSize(_ level: Int) -> Double { Double(sign: .plus, exponent: level, significand: 1) }

    static func cellIndex(_ value: Double, _ size: Double) -> Int {
        let index = (value / size).rounded(.down)
        return Int(max(-1e15, min(1e15, index)))
    }

    /// Where an id goes in the sorted list of ids.
    private static func insertionPoint(of id: StrokeID, in ids: [StrokeID]) -> Int {
        // Strokes are nearly always added newest, at the end.
        if let last = ids.last, last < id { return ids.count }
        var low = 0, high = ids.count
        while low < high {
            let mid = (low + high) / 2
            if ids[mid] < id { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
