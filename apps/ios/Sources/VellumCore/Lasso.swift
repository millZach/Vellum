/// A loop drawn with the lasso, and what it selects (#7).
///
/// The rule: a stroke is selected when at least half of its points lie inside the loop (`insideShare`), so a stroke
/// the loop mostly encloses is taken even if its tail pokes out, and one it only clips is left. A long stroke is
/// judged on at most `pointsTested` of its points, evenly spaced, so a selection costs the same however finely the
/// strokes were drawn. A text box is selected when its centre is inside the loop.
///
/// Only strokes whose bounds meet the loop's bounds are looked at, found through the `InkIndex`, never the whole
/// canvas. The loop is kept to at most `maximumVertices` corners, and its edges are sorted into horizontal bands, so
/// testing a point looks only at the few edges crossing its band.
public struct Lasso: Sendable {
    /// The share of a stroke's points that must lie inside the loop for it to be selected.
    public static let insideShare = 0.5
    /// The most points of one stroke tested.
    public static let pointsTested = 32
    /// The most corners the loop keeps.
    public static let maximumVertices = 256
    static let bandCount = 64

    private let xs: [Double]
    private let ys: [Double]
    /// For each band, the edges (by their first corner) that cross it.
    private let bands: [[Int]]
    private let minY: Double
    private let bandHeight: Double
    /// The loop's bounds.
    public let box: InkIndex.Box

    /// The loop through these points, closed back to the first. Nil when it encloses nothing: fewer than three
    /// points, or no area.
    public init?(_ points: [CanvasPoint]) {
        guard points.count >= 3 else { return nil }
        let stride = max(1, (points.count + Self.maximumVertices - 1) / Self.maximumVertices)
        var xs: [Double] = [], ys: [Double] = []
        for i in Swift.stride(from: 0, to: points.count, by: stride) {
            xs.append(points[i].x.inches)
            ys.append(points[i].y.inches)
        }
        guard xs.count >= 3 else { return nil }
        let box = InkIndex.Box(minX: xs.min()!, minY: ys.min()!, maxX: xs.max()!, maxY: ys.max()!)
        guard box.maxX > box.minX, box.maxY > box.minY else { return nil }
        let height = (box.maxY - box.minY) / Double(Self.bandCount)
        var bands = [[Int]](repeating: [], count: Self.bandCount)
        for i in 0..<xs.count {
            let j = (i + 1) % xs.count
            let low = min(ys[i], ys[j]), high = max(ys[i], ys[j])
            let first = Self.band(low, box.minY, height), last = Self.band(high, box.minY, height)
            for b in first...last { bands[b].append(i) }
        }
        self.xs = xs
        self.ys = ys
        self.bands = bands
        self.box = box
        minY = box.minY
        bandHeight = height
    }

    private static func band(_ y: Double, _ minY: Double, _ height: Double) -> Int {
        min(bandCount - 1, max(0, Int((y - minY) / height)))
    }

    /// Whether a point is inside the loop (even-odd: a loop that crosses itself encloses what a ray from the point
    /// crosses an odd number of times).
    public func contains(_ point: CanvasPoint) -> Bool {
        contains(point.x.inches, point.y.inches)
    }

    func contains(_ px: Double, _ py: Double) -> Bool {
        guard px >= box.minX, px <= box.maxX, py >= box.minY, py <= box.maxY else { return false }
        var inside = false
        for i in bands[Self.band(py, minY, bandHeight)] {
            let j = (i + 1) % xs.count
            let (yi, yj) = (ys[i], ys[j])
            guard (yi > py) != (yj > py) else { continue }
            let x = xs[i] + (py - yi) / (yj - yi) * (xs[j] - xs[i])
            if px < x { inside.toggle() }
        }
        return inside
    }

    /// Whether the rule selects a stroke.
    public func selects(_ stroke: InkStroke) -> Bool {
        var work = InkIndex.Work()
        return selects(stroke, work: &work)
    }

    func selects(_ stroke: InkStroke, work: inout InkIndex.Work) -> Bool {
        let points = stroke.points
        guard !points.isEmpty else { return false }
        let step = max(1, (points.count + Self.pointsTested - 1) / Self.pointsTested)
        var tested = 0, inside = 0
        var i = 0
        while i < points.count {
            tested += 1
            if contains(points[i].x.inches, points[i].y.inches) { inside += 1 }
            i += step
        }
        work.pointsInspected += tested
        return Double(inside) >= Self.insideShare * Double(tested)
    }

    /// What the loop selects among the ink in an index and a canvas's text boxes.
    public func select(in index: InkIndex, texts: [TextBox]) -> CanvasSelection {
        var work = InkIndex.Work()
        return select(in: index, texts: texts, work: &work)
    }

    public func select(in index: InkIndex, texts: [TextBox], work: inout InkIndex.Work) -> CanvasSelection {
        let strokes = index.strokes(in: box, work: &work).filter { selects($0, work: &work) }
        let boxes = texts.filter { contains($0.rect.center) }
        return CanvasSelection(strokes: strokes.map(\.id), texts: boxes.map(\.id))
    }
}
