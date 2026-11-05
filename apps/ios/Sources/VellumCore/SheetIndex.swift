/// Where each placed sheet's outline is on the canvas, so a snap (#57) looks only at the sheets near the tip, never every
/// sheet on the canvas. Built once when the sheets change (placed, turned, moved, rescaled, undone), never per frame.
///
/// Sheets run from a letter page at its printed size to an E1 at 1" = 100'-0", so like `InkIndex` it keeps a stack of
/// uniform grids whose cells double in size, and a sheet goes in one cell: on the level whose cells are at least as large
/// as its bounds, in the cell holding their lower corner. A lookup reads only the cells round the tip, so sheets far from
/// it cost nothing.
public struct SheetIndex: Sendable {
    /// A sheet's outline as a snap reads it: its four corners on the canvas in order round the paper, and the box square
    /// to the canvas round them.
    struct Outline: Sendable {
        /// Its place in the canvas's list: higher is on top.
        let order: Int
        let xs: [Double]
        let ys: [Double]
        let box: InkIndex.Box
    }

    private var all: [Outline] = []
    /// The outlines in each cell, level by level, by their place in `all`.
    private var levels: [Int: [InkIndex.Cell: [Int]]] = [:]

    public init() {}

    /// An index of these sheets, in the canvas's order, the last on top.
    public init(_ sheets: [Sheet]) {
        for (order, sheet) in sheets.enumerated() {
            let corners = sheet.corners
            let xs = corners.map(\.x.inches), ys = corners.map(\.y.inches)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { continue }
            let box = InkIndex.Box(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
            let level = InkIndex.level(for: box)
            let size = InkIndex.cellSize(level)
            let cell = InkIndex.Cell(x: InkIndex.cellIndex(box.minX, size), y: InkIndex.cellIndex(box.minY, size))
            levels[level, default: [:]][cell, default: []].append(all.count)
            all.append(Outline(order: order, xs: xs, ys: ys, box: box))
        }
    }

    public var count: Int { all.count }
    public var isEmpty: Bool { all.isEmpty }

    /// The outlines whose box meets a box, topmost first. What it looks at is counted in `work.sheetsVisited`.
    func outlines(in box: InkIndex.Box, work: inout InkIndex.Work) -> [Outline] {
        var found: [Int] = []
        for (level, cells) in levels {
            let size = InkIndex.cellSize(level)
            // A sheet reaches at most one cell past its own, so look one cell further up and left.
            let lowX = (box.minX / size).rounded(.down) - 1, highX = (box.maxX / size).rounded(.down)
            let lowY = (box.minY / size).rounded(.down) - 1, highY = (box.maxY / size).rounded(.down)
            func look(_ members: [Int]) {
                work.sheetsVisited += members.count
                for i in members where all[i].box.intersects(box) { found.append(i) }
            }
            let span = (highX - lowX + 1) * (highY - lowY + 1)
            if span.isFinite, span <= Double(cells.count), abs(lowX) < 1e15, abs(highX) < 1e15, abs(lowY) < 1e15,
               abs(highY) < 1e15 {
                for x in Int(lowX)...Int(highX) {
                    for y in Int(lowY)...Int(highY) {
                        if let members = cells[InkIndex.Cell(x: x, y: y)] { look(members) }
                    }
                }
            } else {
                // Fewer cells hold sheets on this level than the box covers: look at the ones that do.
                for (cell, members) in cells {
                    let x = Double(cell.x), y = Double(cell.y)
                    guard x >= lowX, x <= highX, y >= lowY, y <= highY else { continue }
                    look(members)
                }
            }
        }
        found.sort { all[$0].order > all[$1].order }
        return found.map { all[$0] }
    }
}
