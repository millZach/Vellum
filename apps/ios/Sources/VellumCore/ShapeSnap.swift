#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A stroke snapped to a shape (#7): a straight line, a rectangle, or an ellipse (a circle when it is nearly round).
/// The shape becomes the stroke's points, so a snapped stroke is saved and drawn like any other.
public enum SnappedShape: Hashable, Sendable {
    case line(CanvasPoint, CanvasPoint)
    /// Centred on `centre`, `width` along the direction `angle` (radians) and `height` across it.
    case rectangle(centre: CanvasPoint, width: Length, height: Length, angle: Double)
    /// Centred on `centre`, with radius `radiusX` along the direction `angle` (radians) and `radiusY` across it.
    case ellipse(centre: CanvasPoint, radiusX: Length, radiusY: Length, angle: Double)

    /// How many segments an ellipse is drawn with: smooth on the Duo's screen at any size it fits on.
    public static let ellipseSegments = 72

    /// The stroke's points: a line's two ends; a rectangle's four corners and back to the first; an ellipse's
    /// `ellipseSegments` segments, closed.
    public var points: [CanvasPoint] {
        switch self {
        case .line(let a, let b):
            return [a, b]
        case .rectangle(let centre, let width, let height, let angle):
            let (c, s) = (cos(angle), sin(angle))
            let corners: [(Double, Double)] = [(-1, -1), (1, -1), (1, 1), (-1, 1), (-1, -1)]
            return corners.map { u, v in
                let x = u * width.inches / 2, y = v * height.inches / 2
                return CanvasPoint(x: .inches(centre.x.inches + x * c - y * s), y: .inches(centre.y.inches + x * s + y * c))
            }
        case .ellipse(let centre, let rx, let ry, let angle):
            let (c, s) = (cos(angle), sin(angle))
            return (0...Self.ellipseSegments).map { i in
                let t = Double(i % Self.ellipseSegments) / Double(Self.ellipseSegments) * 2 * Double.pi
                let x = rx.inches * cos(t), y = ry.inches * sin(t)
                return CanvasPoint(x: .inches(centre.x.inches + x * c - y * s), y: .inches(centre.y.inches + x * s + y * c))
            }
        }
    }

    /// What the shape is called, for VoiceOver and the status bar: "straight line", "rectangle", "circle", "ellipse".
    public var name: String {
        switch self {
        case .line: "straight line"
        case .rectangle: "rectangle"
        case .ellipse(_, let rx, let ry, _): rx == ry ? "circle" : "ellipse"
        }
    }
}

/// Recognising a stroke as a straight line, a rectangle or an ellipse, when Zach holds the Pencil still at its end
/// (`StrokeHold`) or lifts it with the line and shape tool (#7). It runs once per hold, never per Pencil sample: it
/// reads the stroke's points twice (its length, then 64 points evenly spaced along it), and fits the shapes to those 64.
///
/// Every test is relative to the stroke's own size, so it recognises a shape the same way at any zoom:
/// - An open stroke is a line when it runs nearly straight from end to end: no point strays from the line between its
///   ends by more than `lineTolerance` of its length, and the stroke is barely longer than that line.
/// - A stroke whose ends meet (closer than `closingGap` of its size) is closed. Its smallest bounding rectangle at any
///   angle is found, and the stroke is a rectangle when its points lie along that rectangle's sides (within
///   `rectangleTolerance`), or an ellipse when they lie along the ellipse inside it (within `ellipseTolerance`),
///   whichever fits better.
/// - Shapes within `squareAngle` of level square up to it, and an ellipse whose radii are within `roundness` of each
///   other becomes a circle. Anything else, wobbly or a near miss, stays freehand.
public enum ShapeSnap {
    /// How long the Pencil is held still at the end of a stroke before it snaps: half a second, as in Apple Notes.
    public static let holdInterval = 0.5
    /// How far, in screen points, the Pencil may drift and still be held still.
    public static let holdRadius = 4.0
    /// A stroke smaller than this on screen, in points, is a tick or a dot and is never snapped.
    public static let minimumScreenSize = 12.0

    static let samples = 64
    static let lineTolerance = 0.05
    static let lineStraightness = 0.9
    static let closingGap = 0.2
    static let rectangleTolerance = 0.045
    static let ellipseTolerance = 0.08
    static let thinness = 0.12
    static let squareAngle = 5 * Double.pi / 180
    static let roundness = 0.1

    /// What recognising a stroke looked at, for the work budgets: the stroke's points read, and the evenly spaced
    /// points tested against each candidate shape and angle.
    public struct Work: Hashable, Sendable {
        public var pointsRead = 0
        public var pointsTested = 0
        public init() {}
    }

    /// The shape a stroke snaps to, or nil when it should stay freehand. `minimumSize` is the smallest stroke, across
    /// its bounds, that snaps.
    public static func recognize(_ points: [CanvasPoint], minimumSize: Length = .zero) -> SnappedShape? {
        var work = Work()
        return recognize(points, minimumSize: minimumSize, work: &work)
    }

    public static func recognize(_ points: [CanvasPoint], minimumSize: Length, work: inout Work) -> SnappedShape? {
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        // One pass: the stroke's length and its bounds.
        var length = 0.0
        var minX = first.x.inches, maxX = minX, minY = first.y.inches, maxY = minY
        for i in 1..<points.count {
            let (x, y) = (points[i].x.inches, points[i].y.inches)
            length += hypot(x - points[i - 1].x.inches, y - points[i - 1].y.inches)
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        work.pointsRead += points.count
        let size = hypot(maxX - minX, maxY - minY)
        guard size > 0, size >= minimumSize.inches, length > 0 else { return nil }
        let gap = first.distance(to: last).inches

        if gap > closingGap * size {
            // Open: a straight line, or nothing.
            guard gap >= lineStraightness * length else { return nil }
            let path = resample(points, length: length, work: &work)
            let (ax, ay, bx, by) = (first.x.inches, first.y.inches, last.x.inches, last.y.inches)
            var worst = 0.0
            for (x, y) in path {
                worst = max(worst, abs((bx - ax) * (ay - y) - (ax - x) * (by - ay)) / gap)
            }
            work.pointsTested += path.count
            guard worst <= lineTolerance * gap else { return nil }
            return .line(first, squaredUp(first, last))
        }

        // Closed: the smallest bounding rectangle at any angle, then the rectangle or the ellipse inside it.
        var path = resample(points, length: length, work: &work)
        path.removeLast()  // the closing point repeats the first, near enough; don't count it twice
        let cx = path.reduce(0) { $0 + $1.0 } / Double(path.count)
        let cy = path.reduce(0) { $0 + $1.1 } / Double(path.count)
        var best = (area: Double.infinity, angle: 0.0)
        for degree in 0..<90 {
            let angle = Double(degree) * Double.pi / 180
            let frame = bounds(path, cx, cy, angle)
            work.pointsTested += path.count
            let area = (frame.maxU - frame.minU) * (frame.maxV - frame.minV)
            if area < best.area { best = (area, angle) }
        }
        var angle = best.angle
        if angle < squareAngle || angle > Double.pi / 2 - squareAngle { angle = 0 }
        let frame = bounds(path, cx, cy, angle)
        let halfU = (frame.maxU - frame.minU) / 2, halfV = (frame.maxV - frame.minV) / 2
        guard halfU > 0, halfV > 0, min(halfU, halfV) >= thinness * max(halfU, halfV) else { return nil }
        let midU = (frame.minU + frame.maxU) / 2, midV = (frame.minV + frame.maxV) / 2
        let (c, s) = (cos(angle), sin(angle))
        var rectangleError = 0.0, ellipseError = 0.0
        for (x, y) in path {
            let u = (x - cx) * c + (y - cy) * s - midU
            let v = -(x - cx) * s + (y - cy) * c - midV
            rectangleError += max(0, min(halfU - abs(u), halfV - abs(v)))
            ellipseError += abs(hypot(u / halfU, v / halfV) - 1)
        }
        work.pointsTested += path.count
        rectangleError /= Double(path.count) * (halfU + halfV)
        ellipseError /= Double(path.count)
        let centre = CanvasPoint(x: .inches(cx + midU * c - midV * s), y: .inches(cy + midU * s + midV * c))
        let rectangleFits = rectangleError <= rectangleTolerance
        let ellipseFits = ellipseError <= ellipseTolerance
        if rectangleFits && (!ellipseFits || rectangleError / rectangleTolerance <= ellipseError / ellipseTolerance) {
            return .rectangle(centre: centre, width: .inches(2 * halfU), height: .inches(2 * halfV), angle: angle)
        }
        guard ellipseFits else { return nil }
        if abs(halfU - halfV) <= roundness * max(halfU, halfV) {
            let r = Length.inches((halfU + halfV) / 2)
            return .ellipse(centre: centre, radiusX: r, radiusY: r, angle: 0)
        }
        // An ellipse's axes are its points' principal axes, which pin its angle down better than its smallest
        // bounding rectangle does.
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for (x, y) in path {
            sxx += (x - cx) * (x - cx); syy += (y - cy) * (y - cy); sxy += (x - cx) * (y - cy)
        }
        work.pointsTested += path.count
        var axis = 0.5 * atan2(2 * sxy, sxx - syy)
        if axis < 0 { axis += Double.pi / 2 }
        if axis < squareAngle || axis > Double.pi / 2 - squareAngle { axis = 0 }
        let e = bounds(path, cx, cy, axis)
        let (eu, ev) = ((e.minU + e.maxU) / 2, (e.minV + e.maxV) / 2)
        let (ec, es) = (cos(axis), sin(axis))
        return .ellipse(centre: CanvasPoint(x: .inches(cx + eu * ec - ev * es), y: .inches(cy + eu * es + ev * ec)),
                        radiusX: .inches((e.maxU - e.minU) / 2), radiusY: .inches((e.maxV - e.minV) / 2), angle: axis)
    }

    /// The line tool's shape for a stroke that is not a line, rectangle or ellipse: a straight line from where the
    /// Pencil touched down to where it lifted.
    public static func straightLine(_ points: [CanvasPoint]) -> SnappedShape? {
        guard let first = points.first, let last = points.last, first != last else { return nil }
        return .line(first, squaredUp(first, last))
    }

    /// The end of a line within `squareAngle` of level or plumb, swung onto it about the start.
    static func squaredUp(_ start: CanvasPoint, _ end: CanvasPoint) -> CanvasPoint {
        let dx = end.x.inches - start.x.inches, dy = end.y.inches - start.y.inches
        let angle = atan2(abs(dy), abs(dx))
        let length = hypot(dx, dy)
        if angle < squareAngle {
            return CanvasPoint(x: .inches(start.x.inches + (dx < 0 ? -length : length)), y: start.y)
        }
        if angle > Double.pi / 2 - squareAngle {
            return CanvasPoint(x: start.x, y: .inches(start.y.inches + (dy < 0 ? -length : length)))
        }
        return end
    }

    /// `samples` points evenly spaced along the stroke, first and last included.
    static func resample(_ points: [CanvasPoint], length: Double, work: inout Work) -> [(Double, Double)] {
        let step = length / Double(samples - 1)
        var out: [(Double, Double)] = [(points[0].x.inches, points[0].y.inches)]
        out.reserveCapacity(samples)
        var travelled = 0.0, next = step
        for i in 1..<points.count {
            let (ax, ay) = (points[i - 1].x.inches, points[i - 1].y.inches)
            let (bx, by) = (points[i].x.inches, points[i].y.inches)
            let segment = hypot(bx - ax, by - ay)
            while segment > 0, next <= travelled + segment, out.count < samples - 1 {
                let t = (next - travelled) / segment
                out.append((ax + (bx - ax) * t, ay + (by - ay) * t))
                next += step
            }
            travelled += segment
        }
        work.pointsRead += points.count
        out.append((points[points.count - 1].x.inches, points[points.count - 1].y.inches))
        return out
    }

    /// The points' extent along a direction (u) and across it (v), about a centre.
    private static func bounds(_ path: [(Double, Double)], _ cx: Double, _ cy: Double, _ angle: Double)
        -> (minU: Double, maxU: Double, minV: Double, maxV: Double) {
        let (c, s) = (cos(angle), sin(angle))
        var minU = Double.infinity, maxU = -Double.infinity, minV = Double.infinity, maxV = -Double.infinity
        for (x, y) in path {
            let u = (x - cx) * c + (y - cy) * s, v = -(x - cx) * s + (y - cy) * c
            minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
        }
        return (minU, maxU, minV, maxV)
    }
}

/// Whether the Pencil has been held still at the end of a stroke long enough to snap it (`ShapeSnap.holdInterval`,
/// within `ShapeSnap.holdRadius` screen points). The canvas asks once a display frame with where the Pencil is, never
/// per sample; it says yes once per hold, and moving on starts a new hold.
public struct StrokeHold: Hashable, Sendable {
    private var anchor: ScreenPoint?
    private var since = 0.0
    private var fired = false

    public init() {}

    /// Where the Pencil is at `time` (seconds). True the first time it has stayed within the radius for the interval.
    public mutating func update(at point: ScreenPoint, time: Double) -> Bool {
        if let anchor, hypot(point.x - anchor.x, point.y - anchor.y) <= ShapeSnap.holdRadius {
            guard !fired, time - since >= ShapeSnap.holdInterval else { return false }
            fired = true
            return true
        }
        anchor = point
        since = time
        fired = false
        return false
    }
}

extension StrokeInProgress {
    /// The stroke snapped to a shape: the same pen, colour and width, the shape's points.
    public func snapped(to shape: SnappedShape) -> StrokeInProgress {
        var stroke = StrokeInProgress(tool: tool, colour: colour, width: width, start: shape.points[0])
        for point in shape.points.dropFirst() { stroke.end(at: point) }
        return stroke
    }
}
