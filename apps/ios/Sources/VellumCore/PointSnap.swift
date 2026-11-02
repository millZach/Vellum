#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Finding the point a measure or dimension tap means (#8, "snap with a loupe"): the nearest ink end, corner or
/// circle centre within `screenRadius` points of the tip on screen, or the tip itself when there is none.
///
/// It looks only at the strokes whose bounds come within the radius of the tip, found through the `InkIndex`, never
/// the whole canvas, and reads each of those strokes' points once:
/// - **Ends**: an open stroke's first and last points.
/// - **Corners**: a point where the stroke turns by more than `cornerTurn` (a snapped rectangle's four corners, a
///   polyline's bends), and the ends of a closed stroke, which meet at one.
/// - **Centres**: the centre of a closed stroke of at least `centreMinimumPoints` points whose points stay within a
///   factor `centreRoundness` of each other's distance from it, which a snapped circle or ellipse does. The centre is
///   the mean of its points (less the closing one), which for a snapped ellipse, evenly spaced around it, is exactly
///   its centre.
///
/// The nearest wins; at equal distance a centre beats a corner and a corner beats an end, and then the latest stroke.
public enum PointSnap {
    /// How far from the tip on screen, in points, a point is snapped to.
    public static let screenRadius = 20.0
    /// The turn, in radians, that makes a corner: 45°, past the wobble of a line drawn by hand.
    public static let cornerTurn = Double.pi / 4
    /// The fewest points a closed stroke needs to have a centre: more than a rectangle's five.
    public static let centreMinimumPoints = 12
    /// How far apart a closed stroke's points' distances from its centre may be: the farthest no more than this many
    /// times the nearest.
    public static let centreRoundness = 3.0

    /// What kind of point a tap snapped to.
    public enum Kind: String, Hashable, Sendable {
        case end
        case corner
        case centre

        /// The name the loupe and the status bar show: "End", "Corner", "Centre".
        public var title: String {
            switch self {
            case .end: "End"
            case .corner: "Corner"
            case .centre: "Centre"
            }
        }

        fileprivate var rank: Int {
            switch self {
            case .centre: 0
            case .corner: 1
            case .end: 2
            }
        }
    }

    /// Where a tap lands: the snapped point and what it is, or the tip itself (`kind` nil).
    public struct Target: Hashable, Sendable {
        public let point: CanvasPoint
        public let kind: Kind?

        public init(point: CanvasPoint, kind: Kind?) {
            self.point = point
            self.kind = kind
        }
    }

    /// The point a tap at `tip` takes, at a zoom of `pointsPerInch`, among the ink in an index.
    public static func target(at tip: CanvasPoint, pointsPerInch: Double, in index: InkIndex) -> Target {
        var work = InkIndex.Work()
        return target(at: tip, pointsPerInch: pointsPerInch, in: index, work: &work)
    }

    /// The same, counting the strokes looked at and the points read, for the budget tests.
    public static func target(at tip: CanvasPoint, pointsPerInch: Double, in index: InkIndex,
                              work: inout InkIndex.Work) -> Target {
        let radius = screenRadius / pointsPerInch
        let tx = tip.x.inches, ty = tip.y.inches
        let probe = InkIndex.Box(minX: tx, minY: ty, maxX: tx, maxY: ty).grown(by: radius)
        var best: (distance: Double, rank: Int, point: CanvasPoint, kind: Kind)?
        let radiusSquared = radius * radius
        func consider(_ x: Double, _ y: Double, _ kind: Kind) {
            let dx = x - tx, dy = y - ty
            let d = dx * dx + dy * dy
            guard d <= radiusSquared else { return }
            if let b = best, d > b.distance || (d == b.distance && kind.rank >= b.rank) { return }
            best = (d, kind.rank, CanvasPoint(x: .inches(x), y: .inches(y)), kind)
        }
        // Latest stroke first, so on a tie the stroke on top wins.
        for stroke in index.strokes(in: probe, work: &work).reversed() {
            let points = stroke.points
            guard let first = points.first, let last = points.last else { continue }
            work.pointsInspected += points.count
            let span = InkIndex.box(of: stroke).map { max($0.maxX - $0.minX, $0.maxY - $0.minY) } ?? 0
            let closed = points.count > 2 && first.distance(to: last).inches <= span * 1e-6
            if closed {
                consider(first.x.inches, first.y.inches, .corner)
            } else {
                consider(first.x.inches, first.y.inches, .end)
                if points.count > 1 { consider(last.x.inches, last.y.inches, .end) }
            }
            if points.count > 2 {
                let cosTurn = cos(cornerTurn)
                for i in 1..<(points.count - 1) where points[i] != points[i - 1] {
                    let (ax, ay) = (points[i].x.inches - points[i - 1].x.inches, points[i].y.inches - points[i - 1].y.inches)
                    let (bx, by) = (points[i + 1].x.inches - points[i].x.inches, points[i + 1].y.inches - points[i].y.inches)
                    let la = (ax * ax + ay * ay).squareRoot(), lb = (bx * bx + by * by).squareRoot()
                    guard la > 0, lb > 0, (ax * bx + ay * by) / (la * lb) < cosTurn else { continue }
                    consider(points[i].x.inches, points[i].y.inches, .corner)
                }
            }
            if closed, points.count >= centreMinimumPoints, let centre = centre(of: points.dropLast()) {
                consider(centre.x, centre.y, .centre)
            }
        }
        guard let best else { return Target(point: tip, kind: nil) }
        return Target(point: best.point, kind: best.kind)
    }

    /// The mean of a closed stroke's points, when they lie roughly round it; nil otherwise.
    private static func centre(of points: ArraySlice<CanvasPoint>) -> (x: Double, y: Double)? {
        var sx = 0.0, sy = 0.0
        for p in points {
            sx += p.x.inches
            sy += p.y.inches
        }
        let n = Double(points.count)
        let cx = sx / n, cy = sy / n
        var nearest = Double.infinity, farthest = 0.0
        for p in points {
            let dx = p.x.inches - cx, dy = p.y.inches - cy
            let d = dx * dx + dy * dy
            nearest = min(nearest, d)
            farthest = max(farthest, d)
        }
        guard nearest > 0, farthest <= nearest * centreRoundness * centreRoundness else { return nil }
        return (cx, cy)
    }
}
