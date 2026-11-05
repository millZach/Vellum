#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A sheet's angle (#44): degrees counter-clockwise on screen, from 0 up to 360, as AutoCAD reads them. A sheet turns
/// freely to a tenth of a degree and catches on a quarter turn within `catchRange`.
public enum SheetAngle {
    /// How near a quarter turn, in degrees, a twist catches on it (Zach's pick on #44).
    public static let catchRange = 3.0

    /// An angle from 0 up to 360.
    public static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        return positive >= 360 || positive == 0 ? 0 : positive
    }

    /// The angle a twist reaches: the quarter turn it caught on (`caught`), or the angle to a tenth of a degree.
    public static func shaped(_ degrees: Double) -> (angle: Double, caught: Bool) {
        let angle = normalized(degrees)
        let quarter = (angle / 90).rounded() * 90
        if abs(angle - quarter) <= catchRange { return (normalized(quarter), true) }
        return (tenth(angle), false)
    }

    /// An angle a quarter turn on: a tap of a turn button, keeping any tenths it stood at.
    public static func stepped(_ degrees: Double, by quarter: Double) -> Double { tenth(normalized(degrees + quarter)) }

    private static func tenth(_ degrees: Double) -> Double { normalized((degrees * 10).rounded() / 10) }

    /// The angle as the selected sheet shows it: `90°`, `33.5°`.
    public static func reading(_ degrees: Double) -> String {
        let tenths = Int((normalized(degrees) * 10).rounded()) % 3600
        return tenths % 10 == 0 ? "\(tenths / 10)°" : "\(tenths / 10).\(tenths % 10)°"
    }

    /// The cosine and sine of an angle, exactly 0 and ±1 on a quarter turn, so a sheet at 90° is square to the canvas
    /// to the last bit.
    public static func cosineAndSine(_ degrees: Double) -> (cos: Double, sin: Double) {
        let angle = normalized(degrees)
        switch angle {
        case 0: return (1, 0)
        case 90: return (0, 1)
        case 180: return (-1, 0)
        case 270: return (0, -1)
        default:
            let radians = angle * .pi / 180
            return (cos(radians), sin(radians))
        }
    }

    /// A point turned counter-clockwise on screen about another. The canvas's y runs down the screen, as a screen's does.
    public static func turn(_ point: CanvasPoint, about centre: CanvasPoint, by degrees: Double) -> CanvasPoint {
        let (c, s) = cosineAndSine(degrees)
        let dx = point.x.inches - centre.x.inches, dy = point.y.inches - centre.y.inches
        return CanvasPoint(x: .inches(centre.x.inches + dx * c + dy * s), y: .inches(centre.y.inches - dx * s + dy * c))
    }
}

/// What a sheet's turn, move or scale change does to the markups that come along (#44): every point turns and scales
/// about the sheet's centre before the change, then moves. It keeps shapes, so a length on the sheet stays the same
/// length of paper. The ink log records it with the ids it applies to; the moved strokes' points are never written again.
public struct SheetMotion: Hashable, Sendable {
    public var centre: CanvasPoint
    /// Degrees counter-clockwise.
    public var turn: Double
    public var scale: Double
    public var dx: Length
    public var dy: Length

    public init(centre: CanvasPoint = .origin, turn: Double = 0, scale: Double = 1, dx: Length = .zero, dy: Length = .zero) {
        self.centre = centre
        self.turn = SheetAngle.normalized(turn)
        self.scale = scale
        self.dx = dx
        self.dy = dy
    }

    public var isIdentity: Bool { turn == 0 && scale == 1 && dx == .zero && dy == .zero }

    public func apply(_ point: CanvasPoint) -> CanvasPoint {
        let (c, s) = SheetAngle.cosineAndSine(turn)
        let x = (point.x.inches - centre.x.inches) * scale, y = (point.y.inches - centre.y.inches) * scale
        return CanvasPoint(x: .inches(centre.x.inches + x * c + y * s + dx.inches),
                           y: .inches(centre.y.inches - x * s + y * c + dy.inches))
    }
}

/// One turn, move or scale change of a sheet, as the ink log records it (#44): where the sheet stands now, and the
/// markups that came along with how they moved. Its PDF, paper and id never change, so nothing here touches the PDF.
public struct SheetChange: Hashable, Sendable {
    public var id: SheetID
    public var origin: CanvasPoint
    public var angle: Double
    /// The new scale and scale areas after a scale change; nil when they stayed.
    public var rescaled: Rescale?
    public var markups: CanvasSelection
    public var motion: SheetMotion

    public struct Rescale: Hashable, Sendable {
        public var scale: Sheet.Scale
        public var areas: [ScaleArea]

        public init(scale: Sheet.Scale, areas: [ScaleArea]) {
            self.scale = scale
            self.areas = areas
        }
    }

    public init(id: SheetID, origin: CanvasPoint, angle: Double, rescaled: Rescale? = nil, markups: CanvasSelection,
                motion: SheetMotion) {
        self.id = id
        self.origin = origin
        self.angle = angle
        self.rescaled = rescaled
        self.markups = markups
        self.motion = motion
    }

    /// The sheet as this change leaves it.
    func applied(to sheet: Sheet) -> Sheet {
        var after = sheet
        after.origin = origin
        after.angle = angle
        if let rescaled {
            after.scale = rescaled.scale
            after.areas = rescaled.areas
        }
        return after
    }
}

extension Sheet {
    /// The sheet turned about its centre to an angle, and how its markups turn with it. Its corner stays put, so a turn
    /// costs a sheet's position nothing however many times it is made.
    public func turned(to degrees: Double) -> (sheet: Sheet, motion: SheetMotion) {
        var after = self
        after.angle = SheetAngle.normalized(degrees)
        // A quarter turn between two angles stays exactly one, however the subtraction rounds.
        let turn = after.angle - angle, quarters = (turn / 90).rounded()
        return (after, SheetMotion(centre: centre, turn: abs(turn - quarters * 90) < 1e-9 ? quarters * 90 : turn))
    }

    /// The sheet moved by a distance, its corner kept on the ink grid, and how its markups move with it, by the distance
    /// the corner really went.
    public func moved(dx: Length, dy: Length) -> (sheet: Sheet, motion: SheetMotion) {
        var after = self
        after.origin = origin.offsetBy(dx: dx, dy: dy).onInkGrid
        return (after, SheetMotion(centre: centre, dx: after.origin.x - origin.x, dy: after.origin.y - origin.y))
    }

    /// The sheet at another drawing scale, with the size that scale gives it, about its centre, and how its markups scale
    /// with it, so each stays on the same spot of the paper. `areas` are its scale areas at that scale; nil keeps them.
    /// A sheet turned or not, or NTS on either side, works the same way: an NTS sheet's canvas inches are printed inches.
    public func rescaled(to new: Scale, areas newAreas: [ScaleArea]? = nil) -> (sheet: Sheet, motion: SheetMotion) {
        var after = self
        let old = centre
        after.scale = new
        if let newAreas { after.areas = newAreas }
        let size = after.size
        after.origin = CanvasPoint(x: old.x - size.width / 2, y: old.y - size.height / 2).onInkGrid
        return (after, SheetMotion(centre: old, scale: new.canvasPerPrinted / scale.canvasPerPrinted))
    }

    /// Which markups come along when the sheet turns, moves or changes scale: ink and dimensions with more than half
    /// their length on it, and text boxes with their centre on it. Looked up through the index, and a stroke's points
    /// are read only when its cached bounds cross the sheet's edge, so this costs little on a large canvas.
    public func markups(in index: InkIndex, texts: [TextBox], dimensions: [CanvasDimension], work: inout InkIndex.Work)
        -> CanvasSelection {
        let edges = SheetEdges(self)
        // Grown by the edge allowance, so a stroke along an edge, just outside it on the grid, is looked at.
        let strokes = index.strokeIDs(in: InkIndex.Box(bounds).grown(by: edgeAllowanceOnCanvas), work: &work).filter { id in
            guard let box = index.bounds(of: id), let stroke = index.stroke(id) else { return false }
            switch edges.relation(of: box) {
            case .inside: return true
            case .outside: return false
            case .crossing:
                work.pointsInspected += stroke.points.count
                return edges.isMostlyOn(stroke.points)
            }
        }
        return CanvasSelection(strokes: strokes, texts: texts.filter { contains($0.rect.center) }.map(\.id),
                               dimensions: dimensions.filter { edges.isMostlyOn([$0.start, $0.end]) }.map(\.id))
    }

    public func markups(in index: InkIndex, texts: [TextBox], dimensions: [CanvasDimension]) -> CanvasSelection {
        var work = InkIndex.Work()
        return markups(in: index, texts: texts, dimensions: dimensions, work: &work)
    }
}

/// A sheet in its own frame: points turned back about its centre and measured from its corner, for what is on it. Its edges
/// reach `Sheet.edgeAllowance` past the paper's, as `Sheet.contains` does, so a mark snapped along an edge, a fraction of an
/// ink-grid step outside it, comes along when the sheet turns, moves or changes scale (#57, #49).
private struct SheetEdges {
    let origin: CanvasPoint
    let centre: CanvasPoint
    let angle: Double
    let width: Double
    let height: Double
    /// `Sheet.edgeAllowance` on the canvas.
    let slack: Double

    enum Relation { case inside, outside, crossing }

    init(_ sheet: Sheet) {
        origin = sheet.origin
        centre = sheet.centre
        angle = sheet.angle
        width = sheet.size.width.inches
        height = sheet.size.height.inches
        slack = sheet.edgeAllowanceOnCanvas
    }

    private func isOn(_ p: (x: Double, y: Double)) -> Bool {
        p.x >= -slack && p.x <= width + slack && p.y >= -slack && p.y <= height + slack
    }

    private func local(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let point = CanvasPoint(x: .inches(x), y: .inches(y))
        let flat = angle == 0 ? point : SheetAngle.turn(point, about: centre, by: -angle)
        return (flat.x.inches - origin.x.inches, flat.y.inches - origin.y.inches)
    }

    /// Where a stroke's cached bounds lie against the sheet.
    func relation(of box: InkIndex.Box) -> Relation {
        let corners = [local(box.minX, box.minY), local(box.maxX, box.minY), local(box.maxX, box.maxY), local(box.minX, box.maxY)]
        let xs = corners.map(\.x), ys = corners.map(\.y)
        if corners.allSatisfy(isOn) { return .inside }
        if xs.max()! < -slack || xs.min()! > width + slack || ys.max()! < -slack || ys.min()! > height + slack {
            return .outside
        }
        return .crossing
    }

    /// Whether more than half a line's length is on the sheet; a single point, or a line of no length, when it is.
    func isMostlyOn(_ points: [CanvasPoint]) -> Bool {
        guard let first = points.first else { return false }
        var a = local(first.x.inches, first.y.inches)
        var total = 0.0, on = 0.0
        for point in points.dropFirst() {
            let b = local(point.x.inches, point.y.inches)
            let length = hypot(b.x - a.x, b.y - a.y)
            total += length
            on += length * shareOn(a, b)
            a = b
        }
        if total == 0 { return isOn(local(first.x.inches, first.y.inches)) }
        return on * 2 > total
    }

    /// The share of a segment on the sheet: Liang and Barsky's clip against its four edges, each `slack` out.
    private func shareOn(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        var enter = 0.0, leave = 1.0
        let (dx, dy) = (b.x - a.x, b.y - a.y)
        for (p, q) in [(-dx, a.x + slack), (dx, width + slack - a.x), (-dy, a.y + slack), (dy, height + slack - a.y)] {
            if p == 0 {
                if q < 0 { return 0 }
            } else if p < 0 {
                enter = max(enter, q / p)
            } else {
                leave = min(leave, q / p)
            }
        }
        return max(0, leave - enter)
    }
}

extension InkStroke {
    /// The stroke turned, moved and scaled with a sheet, under the same id, its points kept on the ink grid and its width
    /// scaled with it.
    public func moved(by motion: SheetMotion) -> InkStroke {
        InkStroke(id: id, tool: tool, colour: colour, width: width * motion.scale,
                  points: points.map { motion.apply($0).onInkGrid })
    }
}

extension TextBox {
    /// The box moved and scaled with a sheet: its centre goes where the sheet takes it, its size and letters scale, and
    /// its text stays level (#44).
    public func moved(by motion: SheetMotion) -> TextBox {
        var box = self
        let centre = motion.apply(rect.center)
        box.size = CanvasSize(width: size.width * motion.scale, height: size.height * motion.scale)
        box.fontSize = fontSize * motion.scale
        box.origin = CanvasPoint(x: centre.x - box.size.width / 2, y: centre.y - box.size.height / 2)
        return box
    }
}

extension CanvasDimension {
    /// The dimension turned, moved and scaled with a sheet: its axes turn with it, so it reads the same length of paper
    /// at any angle, and its text scales with it.
    public func moved(by motion: SheetMotion) -> CanvasDimension {
        CanvasDimension(id: id, start: motion.apply(start).onInkGrid, end: motion.apply(end).onInkGrid,
                        through: motion.apply(through).onInkGrid, orientation: orientation, colour: colour,
                        textHeight: textHeight * motion.scale,
                        axisAngle: orientation == .aligned ? 0 : SheetAngle.normalized(axisAngle + motion.turn))
    }
}

extension CanvasRect {
    /// The smallest rectangle holding these points.
    public static func enclosing(_ points: [CanvasPoint]) -> CanvasRect {
        guard let first = points.first else { return CanvasRect(origin: .origin, size: CanvasSize(width: .zero, height: .zero)) }
        var minX = first.x.inches, maxX = minX, minY = first.y.inches, maxY = minY
        for p in points.dropFirst() {
            minX = min(minX, p.x.inches); maxX = max(maxX, p.x.inches)
            minY = min(minY, p.y.inches); maxY = max(maxY, p.y.inches)
        }
        return CanvasRect(origin: CanvasPoint(x: .inches(minX), y: .inches(minY)),
                          size: CanvasSize(width: .inches(maxX - minX), height: .inches(maxY - minY)))
    }
}
