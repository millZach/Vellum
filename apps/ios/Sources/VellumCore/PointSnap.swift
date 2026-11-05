#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Finding the point a tap means: since #40 all seven kinds of snap point are always on, and the nearest within
/// `screenRadius` points of the tip on screen wins, or the tip itself when there is none. There are no settings. Holding
/// still doesn't cycle through the points in reach; when they crowd, zoom in, as Zach picked.
///
/// It looks only at the strokes whose bounds come within the radius of the tip, found through the `InkIndex`, never the
/// whole canvas, and reads each of those strokes' points once. Everything is worked out from the points, since ink keeps no
/// shape. A stroke's shape is read like this:
/// - A **round** stroke is a snapped circle, or an arc. A circle is closed, with more segments than a polygon has and its
///   points all as far from one centre, within `roundTolerance`. An arc is open, with exactly `SnappedShape.arcSegments`
///   segments of equal length on one circle (`arcFit`). Lengths on it are the true circle's, not its chords'.
/// - A **straight** stroke has at most `straightMaximumSegments` segments and isn't round: a line, a rectangle, a polyline, a
///   polygon. Each of its segments is a straight run; a hand-drawn stroke's many short samples are not.
///
/// The kinds:
/// - **End**: an open stroke's first and last points.
/// - **Corner**: a point where the stroke turns by more than `cornerTurn`, or at all on a straight stroke (a polygon's 24
///   sides turn 15°); and the ends of a closed stroke, which meet at one.
/// - **Centre**: a round stroke's centre, which for an arc the index finds by the centre's own place, since it can lie well off
///   the arc's bounds; a regular polygon's, of 3 or from 5 sides; or that of any other closed stroke of at
///   least `centreMinimumPoints` points that stay within a factor `centreRoundness` of each other's distance from it, which
///   a snapped ellipse does. A rectangle has none, even a square one.
/// - **Mid**: the middle of a straight stroke's segment.
/// - **Intersection**: where two strokes cross or meet, on the true circle for a round one. Found only among the segments
///   within reach of the tip, and no further than the best point so far, since nearer is all that can win. At most
///   `intersectionSegmentLimit` segments and `roundLimit` circles and arcs are looked at, the latest strokes first, so past
///   those a nearer crossing among older strokes can lose to a farther point.
/// - **Perpendicular** and **Tangent** need a point to work from (`anchor`): the foot of the perpendicular on a straight
///   stroke's segment or a circle, and the two points where a line from the anchor just touches a circle. So a measure's or
///   dimension's first point has neither, and its second has both. An arc has neither, as on the prototype.
///
/// The nearest wins. Where two kinds fall on one point (within an ink grid step), the rank decides: intersection, centre,
/// corner, end, mid, perpendicular, tangent. At equal distance the latest stroke wins.
public enum PointSnap {
    /// How far from the tip on screen, in points, a point is snapped to.
    public static let screenRadius = 20.0
    /// The turn, in radians, that makes a corner: 45°, past the wobble of a line drawn by hand.
    public static let cornerTurn = Double.pi / 4
    /// The fewest points a closed stroke needs to have a centre without being a regular polygon: more than a rectangle's five.
    public static let centreMinimumPoints = 12
    /// How far apart a closed stroke's points' distances from its centre may be: the farthest no more than this many
    /// times the nearest.
    public static let centreRoundness = 3.0
    /// The most segments a stroke has and still counts as straight runs. A circle's 72 and an arc's 48 are more.
    public static let straightMaximumSegments = 32
    /// How far a round stroke's points may be from its radius, as a share of it, past the rounding to the ink grid.
    public static let roundTolerance = 1e-3
    /// The most segments intersections are looked for among, so a crowded place stays quick; zooming in leaves fewer.
    public static let intersectionSegmentLimit = 128
    /// The most circles and arcs crossings are looked for among, the latest strokes first, so a pile of them stays quick.
    public static let roundLimit = 32
    /// How far past a circle, in inches, a line still touches it: the rounding of its fitted radius, 4 grid units.
    static let touchReach = 4 / CanvasPoint.gridUnitsPerInch
    /// A polygon's most sides, which is what makes it a regular polygon rather than a circle.
    static let polygonMaximumSides = 24
    /// A turn smaller than this on a straight stroke is the rounding of a straight run, not a corner: 1°.
    static let straightTurn = Double.pi / 180

    /// What kind of point a tap snapped to.
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case end
        case corner
        case centre
        case mid
        case intersection
        case perpendicular
        case tangent

        /// The name the loupe shows.
        public var title: String {
            switch self {
            case .end: "End"
            case .corner: "Corner"
            case .centre: "Centre"
            case .mid: "Mid"
            case .intersection: "Intersection"
            case .perpendicular: "Perpendicular"
            case .tangent: "Tangent"
            }
        }

        fileprivate var rank: Int {
            switch self {
            case .intersection: 0
            case .centre: 1
            case .corner: 2
            case .end: 3
            case .mid: 4
            case .perpendicular: 5
            case .tangent: 6
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

    /// The point a tap at `tip` takes, at a zoom of `pointsPerInch`, among the ink in an index. `anchor` is the point being
    /// worked from, which perpendicular and tangent need.
    public static func target(at tip: CanvasPoint, pointsPerInch: Double, in index: InkIndex,
                              anchor: CanvasPoint? = nil) -> Target {
        var work = InkIndex.Work()
        return target(at: tip, pointsPerInch: pointsPerInch, in: index, anchor: anchor, work: &work)
    }

    /// A true circle, or the part of one an arc covers.
    private struct Round {
        let stroke: Int
        let x: Double
        let y: Double
        let r: Double
        /// An arc's start and sweep, in the canvas's own y-down radians; nil for a whole circle.
        let arc: (start: Double, sweep: Double)?

        func holds(_ px: Double, _ py: Double) -> Bool {
            guard let arc else { return true }
            var along = atan2(py - y, px - x) - arc.start
            let turn = 2 * Double.pi
            if arc.sweep >= 0 {
                while along < 0 { along += turn }
                while along >= turn { along -= turn }
                return along <= arc.sweep + 1e-9 || along >= turn - 1e-9
            }
            while along > 0 { along -= turn }
            while along <= -turn { along += turn }
            return along >= arc.sweep - 1e-9 || along <= -turn + 1e-9
        }
    }

    /// A segment of a stroke near the tip.
    private struct Segment {
        let stroke: Int
        let ax: Double
        let ay: Double
        let bx: Double
        let by: Double
        // Worked out once: the sweep compares them for every pair it looks at.
        let minX: Double
        let maxX: Double
        let minY: Double
        let maxY: Double

        init(stroke: Int, ax: Double, ay: Double, bx: Double, by: Double) {
            self.stroke = stroke
            self.ax = ax
            self.ay = ay
            self.bx = bx
            self.by = by
            minX = min(ax, bx)
            maxX = max(ax, bx)
            minY = min(ay, by)
            maxY = max(ay, by)
        }
    }

    /// The same, counting the strokes looked at, the points read and the pairs tested for crossing, for the budget tests.
    public static func target(at tip: CanvasPoint, pointsPerInch: Double, in index: InkIndex, anchor: CanvasPoint? = nil,
                              work: inout InkIndex.Work) -> Target {
        let radius = screenRadius / pointsPerInch
        let tx = tip.x.inches, ty = tip.y.inches
        let probe = InkIndex.Box(minX: tx, minY: ty, maxX: tx, maxY: ty).grown(by: radius)
        var best: (distance: Double, rank: Int, x: Double, y: Double, kind: Kind)?
        let radiusSquared = radius * radius
        let sameSpot = 1 / CanvasPoint.gridUnitsPerInch
        func consider(_ x: Double, _ y: Double, _ kind: Kind) {
            let dx = x - tx, dy = y - ty
            let d = dx * dx + dy * dy
            guard d <= radiusSquared else { return }
            if let b = best {
                if abs(x - b.x) <= sameSpot, abs(y - b.y) <= sameSpot {
                    guard kind.rank < b.rank else { return }
                } else if d >= b.distance {
                    return
                }
            }
            best = (d, kind.rank, x, y, kind)
        }
        var segments: [Segment] = []
        var rounds: [Round] = []
        let ax = anchor?.x.inches, ay = anchor?.y.inches
        let cosTurn = cos(cornerTurn), cosStraight = cos(straightTurn)

        // Latest stroke first, so on a tie the stroke on top wins.
        var strokeNumber = 0
        for stroke in index.strokes(in: probe, work: &work).reversed() {
            strokeNumber += 1
            let points = stroke.points
            guard let first = points.first, let last = points.last else { continue }
            work.pointsInspected += points.count
            let span = InkIndex.box(of: stroke).map { max($0.maxX - $0.minX, $0.maxY - $0.minY) } ?? 0
            let closed = points.count > 2 && first.distance(to: last).inches <= span * 1e-6
            let round = roundShape(of: points, closed: closed, stroke: strokeNumber)
            let isStraight = round == nil && points.count - 1 <= straightMaximumSegments
            if closed {
                if round == nil { consider(first.x.inches, first.y.inches, .corner) }
            } else {
                consider(first.x.inches, first.y.inches, .end)
                if points.count > 1 { consider(last.x.inches, last.y.inches, .end) }
            }
            if points.count > 2, round == nil {
                let threshold = isStraight ? cosStraight : cosTurn
                for i in 1..<(points.count - 1) where points[i] != points[i - 1] {
                    let (ux, uy) = (points[i].x.inches - points[i - 1].x.inches, points[i].y.inches - points[i - 1].y.inches)
                    let (vx, vy) = (points[i + 1].x.inches - points[i].x.inches, points[i + 1].y.inches - points[i].y.inches)
                    let la = (ux * ux + uy * uy).squareRoot(), lb = (vx * vx + vy * vy).squareRoot()
                    guard la > 0, lb > 0, (ux * vx + uy * vy) / (la * lb) < threshold else { continue }
                    consider(points[i].x.inches, points[i].y.inches, .corner)
                }
            }
            if let round {
                consider(round.x, round.y, .centre)
                if abs((round.x - tx).magnitudeHypot(round.y - ty) - round.r) <= radius, rounds.count < roundLimit {
                    rounds.append(round)
                }
                if round.arc == nil, let ax, let ay { tangentAndPerpendicular(round, ax, ay, consider) }
            } else if closed, let centre = centre(of: points.dropLast()) {
                consider(centre.x, centre.y, .centre)
            }
            // Its segments: the ones within reach, for intersections, and a straight stroke's mids and perpendiculars.
            guard round == nil, points.count > 1 else { continue }
            var (sx, sy) = (first.x.inches, first.y.inches)
            for i in 1..<points.count {
                let (ex, ey) = (points[i].x.inches, points[i].y.inches)
                defer { (sx, sy) = (ex, ey) }
                if isStraight, sx != ex || sy != ey {
                    consider((sx + ex) / 2, (sy + ey) / 2, .mid)
                    if let ax, let ay { perpendicular(sx, sy, ex, ey, ax, ay, consider) }
                }
                guard max(sx, ex) >= probe.minX, min(sx, ex) <= probe.maxX, max(sy, ey) >= probe.minY,
                      min(sy, ey) <= probe.maxY, segments.count < intersectionSegmentLimit else { continue }
                segments.append(Segment(stroke: strokeNumber, ax: sx, ay: sy, bx: ex, by: ey))
            }
        }

        // An arc's centre may be far off its own bounds, so the strokes found above don't always include it.
        index.visitArcCentres(in: probe, work: &work) { consider($0.x, $0.y, .centre) }

        intersections(segments, rounds, tx, ty, radius, best?.distance, &work, consider)

        guard let best else { return Target(point: tip, kind: nil) }
        // On the ink grid, as what is drawn there will be, so a measure reads what a stroke drawn to it would.
        return Target(point: CanvasPoint(x: .inches(best.x), y: .inches(best.y)).onInkGrid, kind: best.kind)
    }

    private static func perpendicular(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double, _ ax: Double, _ ay: Double,
                                      _ consider: (Double, Double, Kind) -> Void) {
        let (dx, dy) = (ex - sx, ey - sy)
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return }
        let t = ((ax - sx) * dx + (ay - sy) * dy) / lengthSquared
        // Past either end there is no foot, and at an end the end is the point already.
        guard t > 0.001, t < 0.999 else { return }
        let (fx, fy) = (sx + t * dx, sy + t * dy)
        guard (fx - ax).magnitudeHypot(fy - ay) > 1e-3 else { return }
        consider(fx, fy, .perpendicular)
    }

    private static func tangentAndPerpendicular(_ round: Round, _ ax: Double, _ ay: Double,
                                                _ consider: (Double, Double, Kind) -> Void) {
        let d = (ax - round.x).magnitudeHypot(ay - round.y)
        guard d > round.r + 1e-6 else { return }
        let base = atan2(ay - round.y, ax - round.x), off = acos(round.r / d)
        consider(round.x + round.r * cos(base + off), round.y + round.r * sin(base + off), .tangent)
        consider(round.x + round.r * cos(base - off), round.y + round.r * sin(base - off), .tangent)
        consider(round.x + round.r * cos(base), round.y + round.r * sin(base), .perpendicular)
    }

    /// Where different strokes' segments and round strokes cross, among those still able to beat the best point so far. The
    /// segments are swept in order along x, so a pair that can't touch is never tested.
    private static func intersections(_ all: [Segment], _ rounds: [Round], _ tx: Double, _ ty: Double, _ radius: Double,
                                      _ bestSquared: Double?, _ work: inout InkIndex.Work,
                                      _ consider: (Double, Double, Kind) -> Void) {
        let reach = min(radius, bestSquared?.squareRoot() ?? radius) + 1 / CanvasPoint.gridUnitsPerInch
        var segments = all.filter { s in
            s.maxX >= tx - reach && s.minX <= tx + reach && s.maxY >= ty - reach && s.minY <= ty + reach
        }
        segments.sort { $0.minX < $1.minX }
        var pairs = 0
        for i in segments.indices {
            let a = segments[i]
            var j = i + 1
            while j < segments.count, segments[j].minX <= a.maxX {
                let b = segments[j]
                j += 1
                guard a.stroke != b.stroke else { continue }
                pairs += 1
                guard b.minY <= a.maxY, a.minY <= b.maxY else { continue }
                if let (x, y) = crossing(a, b) { consider(x, y, .intersection) }
            }
        }
        for round in rounds {
            for segment in segments where segment.stroke != round.stroke {
                pairs += 1
                crossings(segment, round, consider)
            }
        }
        for i in rounds.indices {
            for j in rounds.indices where j > i {
                pairs += 1
                crossings(rounds[i], rounds[j], consider)
            }
        }
        work.segmentPairsTested += pairs
    }

    private static func crossing(_ a: Segment, _ b: Segment) -> (Double, Double)? {
        let (rx, ry) = (a.bx - a.ax, a.by - a.ay), (qx, qy) = (b.bx - b.ax, b.by - b.ay)
        let denominator = rx * qy - ry * qx
        let scale = (rx * rx + ry * ry) * (qx * qx + qy * qy)
        // Parallel, or nearly: no one point. Compared squared, so it means the same at any size.
        guard denominator * denominator > 1e-18 * scale, scale > 0 else { return nil }
        let t = ((b.ax - a.ax) * qy - (b.ay - a.ay) * qx) / denominator
        let u = ((b.ax - a.ax) * ry - (b.ay - a.ay) * rx) / denominator
        guard t >= -1e-6, t <= 1 + 1e-6, u >= -1e-6, u <= 1 + 1e-6 else { return nil }
        return (a.ax + t * rx, a.ay + t * ry)
    }

    private static func crossings(_ segment: Segment, _ round: Round, _ consider: (Double, Double, Kind) -> Void) {
        let (dx, dy) = (segment.bx - segment.ax, segment.by - segment.ay)
        let (fx, fy) = (segment.ax - round.x, segment.ay - round.y)
        let a = dx * dx + dy * dy
        guard a > 0 else { return }
        let b = 2 * (dx * fx + dy * fy), c = fx * fx + fy * fy - round.r * round.r
        var discriminant = b * b - 4 * a * c
        if discriminant < 0 {
            // A line just touching: the rounding of the fitted radius may leave it just outside. How far outside decides.
            let off = abs(dx * fy - dy * fx) / a.squareRoot() - round.r
            guard off <= touchReach else { return }
            discriminant = 0
        }
        let root = discriminant.squareRoot()
        for t in [(-b - root) / (2 * a), (-b + root) / (2 * a)] where t >= -1e-6 && t <= 1 + 1e-6 {
            let (x, y) = (segment.ax + t * dx, segment.ay + t * dy)
            if round.holds(x, y) { consider(x, y, .intersection) }
        }
    }

    private static func crossings(_ a: Round, _ b: Round, _ consider: (Double, Double, Kind) -> Void) {
        let (dx, dy) = (b.x - a.x, b.y - a.y)
        let d = dx.magnitudeHypot(dy)
        guard d > 0, d <= a.r + b.r, d >= abs(a.r - b.r) else { return }
        let along = (d * d + a.r * a.r - b.r * b.r) / (2 * d)
        let across = max(0, a.r * a.r - along * along).squareRoot()
        let (mx, my) = (a.x + along * dx / d, a.y + along * dy / d)
        for side in [1.0, -1.0] {
            let (x, y) = (mx - side * across * dy / d, my + side * across * dx / d)
            if a.holds(x, y), b.holds(x, y) { consider(x, y, .intersection) }
        }
    }

    /// The circle or arc a stroke's points make, if they do. Only strokes of a round count of points get this far, so a pen's
    /// strokes are rarely read twice.
    private static func roundShape(of points: [CanvasPoint], closed: Bool, stroke: Int) -> Round? {
        if closed {
            // A polygon's corners lie on a circle too, but its sides are the line: only more segments than it can have make
            // a stroke round.
            guard points.count - 1 > polygonMaximumSides, let centre = centre(of: points.dropLast()),
                  let r = commonDistance(of: points.dropLast(), from: centre.x, centre.y) else { return nil }
            return Round(stroke: stroke, x: centre.x, y: centre.y, r: r, arc: nil)
        }
        guard let fit = arcFit(points) else { return nil }
        let a = points[0]
        let start = atan2(a.y.inches - fit.y, a.x.inches - fit.x)
        // Its turn at each step, from the first two points, gives the sweep with its direction.
        let second = atan2(points[1].y.inches - fit.y, points[1].x.inches - fit.x)
        var step = second - start
        if step > Double.pi { step -= 2 * Double.pi } else if step < -Double.pi { step += 2 * Double.pi }
        return Round(stroke: stroke, x: fit.x, y: fit.y, r: fit.r,
                     arc: (start: start, sweep: step * Double(SnappedShape.arcSegments)))
    }

    /// Where an arc's centre is, if these points are an arc.
    static func arcCentre(of points: [CanvasPoint]) -> InkIndex.ArcCentre? {
        arcFit(points).map { InkIndex.ArcCentre(x: $0.x, y: $0.y) }
    }

    /// The circle these points lie on, if they are what `SnappedShape.arc` makes: exactly `arcSegments` segments of equal
    /// length, which a hand-drawn stroke's never are, within the rounding of moves, turns and scale changes, all on one circle
    /// fitted to all of them by least squares. Distance from a circle is judged in lengths, never as a share of its radius, or
    /// the huge circle through a nearly straight stroke would take in any wobble.
    ///
    /// The ink grid limits a very shallow arc's centre, which lies far off along its axis. With a height of at least 1/200 of
    /// its length the centre is good to 1/16"; at 1/500 it can be about 0.35 inch out, and shallower is worse.
    private static func arcFit(_ points: [CanvasPoint]) -> (x: Double, y: Double, r: Double)? {
        guard points.count == SnappedShape.arcSegments + 1 else { return nil }
        // Read in order and given up on at the first chord that differs, so a hand-drawn stroke costs a few points.
        let firstChord = points[0].distance(to: points[1]).inches
        guard firstChord > 0 else { return nil }
        let reach = arcChordRounding + 1e-4 * firstChord
        var shortest = firstChord, longest = firstChord
        for i in 2..<points.count {
            let chord = points[i - 1].distance(to: points[i]).inches
            shortest = min(shortest, chord)
            longest = max(longest, chord)
            if longest - shortest > reach { return nil }
        }
        // Worked from the points' mean, which keeps the sums small far from the origin.
        var mx = 0.0, my = 0.0
        for p in points {
            mx += p.x.inches
            my += p.y.inches
        }
        let n = Double(points.count)
        mx /= n
        my /= n
        var suu = 0.0, svv = 0.0, suv = 0.0, suuu = 0.0, svvv = 0.0, suvv = 0.0, svuu = 0.0
        for p in points {
            let u = p.x.inches - mx, v = p.y.inches - my
            suu += u * u
            svv += v * v
            suv += u * v
            suuu += u * u * u
            svvv += v * v * v
            suvv += u * v * v
            svuu += v * u * u
        }
        let determinant = suu * svv - suv * suv
        guard determinant > 0 else { return nil }
        let x = mx + (svv * (suuu + suvv) - suv * (svvv + svuu)) / (2 * determinant)
        let y = my + (suu * (svvv + svuu) - suv * (suuu + suvv)) / (2 * determinant)
        guard x.isFinite, y.isFinite else { return nil }
        var nearest = Double.infinity, farthest = 0.0
        for p in points {
            let d = (p.x.inches - x).magnitudeHypot(p.y.inches - y)
            nearest = min(nearest, d)
            farthest = max(farthest, d)
        }
        guard farthest - nearest <= arcChordRounding + 1e-4 * firstChord else { return nil }
        return (x, y, (nearest + farthest) / 2)
    }

    /// How far, in inches, rounding to the ink grid through a few moves, turns and scale changes can set an arc's chords apart:
    /// 16 grid units, about 1/4096 inch.
    private static let arcChordRounding = 16 / CanvasPoint.gridUnitsPerInch

    /// The distance all these points are from a centre, within `roundTolerance`; nil when they aren't.
    private static func commonDistance(of points: ArraySlice<CanvasPoint>, from x: Double, _ y: Double) -> Double? {
        var nearest = Double.infinity, farthest = 0.0
        for p in points {
            let d = (p.x.inches - x).magnitudeHypot(p.y.inches - y)
            nearest = min(nearest, d)
            farthest = max(farthest, d)
        }
        guard nearest > 0, farthest - nearest <= roundTolerance * farthest + 4 / CanvasPoint.gridUnitsPerInch else { return nil }
        return (nearest + farthest) / 2
    }

    /// The mean of a closed stroke's points, when it has a centre: a regular polygon's, or when they lie roughly round it and
    /// are many enough; nil otherwise.
    private static func centre(of points: ArraySlice<CanvasPoint>) -> (x: Double, y: Double)? {
        var sx = 0.0, sy = 0.0
        for p in points {
            sx += p.x.inches
            sy += p.y.inches
        }
        let n = Double(points.count)
        let cx = sx / n, cy = sy / n
        if points.count < centreMinimumPoints {
            // Few points: only a regular polygon of 3 or from 5 sides. A rectangle has no centre, even a square one.
            guard points.count == 3 || points.count >= 5, commonDistance(of: points, from: cx, cy) != nil,
                  equalSides(points) else { return nil }
            return (cx, cy)
        }
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

    /// Whether a closed stroke's sides, its closing one included, are all the same length.
    private static func equalSides(_ points: ArraySlice<CanvasPoint>) -> Bool {
        guard let first = points.first, let last = points.last else { return false }
        let closing = last.distance(to: first).inches
        var previous = first
        for p in points.dropFirst() {
            let side = previous.distance(to: p).inches
            if abs(side - closing) > roundTolerance * closing + 4 / CanvasPoint.gridUnitsPerInch { return false }
            previous = p
        }
        return true
    }
}

private extension Double {
    /// The length of the vector with this x and that y.
    func magnitudeHypot(_ y: Double) -> Double { hypot(self, y) }
}
