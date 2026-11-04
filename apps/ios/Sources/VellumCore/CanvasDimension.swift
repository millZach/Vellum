/// One dimension's identity within a canvas. Dimensions are numbered in the order they are placed, apart from strokes
/// and text boxes.
public struct DimensionID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public static func < (lhs: DimensionID, rhs: DimensionID) -> Bool { lhs.value < rhs.value }
    public var description: String { "dimension \(value)" }
}

/// A kept annotation that shows a real-world length between two points (CONTEXT.md "Dimension"), placed the way
/// AutoCAD's DIMLINEAR and DIMALIGNED are (#8): two points on the object, then a third that pulls the dimension line
/// off it. Pulled above or below the two points it reads the horizontal distance between them, pulled beside them the
/// vertical distance, and pulled out at an angle the straight distance, with the line parallel to the two points.
/// Extension lines run from near each point to just past the dimension line.
///
/// Its points are kept on the ink grid, like a stroke's, so it reopens exactly. Its text height is a real-world
/// length fixed when it is placed (`screenTextHeight` at that zoom), so it zooms with the ink around it, as a text
/// box's letters do. It is drawn in its markup colour. The length it shows is never stored: it is read from its
/// points in the canvas units whenever it is drawn (`Canvas.measure(_:)`), so changing the units changes it.
///
/// A dimension that comes along when its sheet turns keeps reading the same length: `axisAngle` turns what "across" and
/// "up and down" mean with it, the way AutoCAD's rotated linear dimension does (#44).
public struct CanvasDimension: Hashable, Sendable, Identifiable {
    /// Which distance between the two points the dimension reads.
    public enum Orientation: String, CaseIterable, Hashable, Sendable {
        /// The distance across: the dimension line is level.
        case horizontal
        /// The distance up and down: the dimension line is plumb.
        case vertical
        /// The straight distance: the dimension line is parallel to the two points.
        case aligned
    }

    public let id: DimensionID
    /// The first point dimensioned.
    public var start: CanvasPoint
    /// The second point dimensioned.
    public var end: CanvasPoint
    /// The point the dimension line was pulled to: it passes through it.
    public var through: CanvasPoint
    public var orientation: Orientation
    public var colour: MarkupColour
    /// The height of its text as a real-world length.
    public var textHeight: Length
    /// How far its "across" is turned from the canvas's, in degrees counter-clockwise; 0 unless a sheet turned it.
    public var axisAngle: Double

    /// The text height of a new dimension on screen, in points, at the zoom it is placed at.
    public static let screenTextHeight = 12.0

    public init(id: DimensionID, start: CanvasPoint, end: CanvasPoint, through: CanvasPoint, orientation: Orientation,
                colour: MarkupColour, textHeight: Length, axisAngle: Double = 0) {
        self.id = id
        self.start = start
        self.end = end
        self.through = through
        self.orientation = orientation
        self.colour = colour
        self.textHeight = textHeight
        self.axisAngle = axisAngle
    }

    /// The orientation a third point pulls a dimension to, the AutoCAD way: within the two points' span across and
    /// outside it up and down (above or below them) is horizontal; within their span up and down and outside it
    /// across (beside them) is vertical; anywhere else, out at an angle or inside both spans, is aligned. Two points
    /// level with each other can only be measured across or straight, and both read the same, so they are horizontal
    /// when pulled above or below and aligned otherwise; plumb points the same way round.
    public static func orientation(start: CanvasPoint, end: CanvasPoint, through: CanvasPoint) -> Orientation {
        let (ax, ay, bx, by) = (start.x.inches, start.y.inches, end.x.inches, end.y.inches)
        let (px, py) = (through.x.inches, through.y.inches)
        let withinX = px >= min(ax, bx) && px <= max(ax, bx)
        let withinY = py >= min(ay, by) && py <= max(ay, by)
        if withinX && !withinY { return .horizontal }
        if withinY && !withinX { return .vertical }
        return .aligned
    }

    /// The dimension a third point pulls two points to.
    public static func pulled(id: DimensionID, start: CanvasPoint, end: CanvasPoint, through: CanvasPoint,
                              colour: MarkupColour, textHeight: Length) -> CanvasDimension {
        CanvasDimension(id: id, start: start, end: end, through: through,
                  orientation: orientation(start: start, end: end, through: through), colour: colour,
                  textHeight: textHeight)
    }

    /// The length the dimension reads, unsigned: the distance across, up and down, or straight, by its orientation.
    public var length: Length {
        if axisAngle != 0, orientation != .aligned {
            let (a, b) = (unturned(start), unturned(end))
            return orientation == .horizontal ? Length(inches: (b.x.inches - a.x.inches).magnitude)
                : Length(inches: (b.y.inches - a.y.inches).magnitude)
        }
        switch orientation {
        case .horizontal: return Length(inches: (end.x.inches - start.x.inches).magnitude)
        case .vertical: return Length(inches: (end.y.inches - start.y.inches).magnitude)
        case .aligned: return start.distance(to: end)
        }
    }

    /// Where the dimension line runs, from the end over `start` to the end over `end`.
    public var line: (CanvasPoint, CanvasPoint) {
        if axisAngle != 0, orientation != .aligned {
            let (a, b, t) = (unturned(start), unturned(end), unturned(through))
            let flat = orientation == .horizontal
                ? (CanvasPoint(x: a.x, y: t.y), CanvasPoint(x: b.x, y: t.y))
                : (CanvasPoint(x: t.x, y: a.y), CanvasPoint(x: t.x, y: b.y))
            return (SheetAngle.turn(flat.0, about: .origin, by: axisAngle),
                    SheetAngle.turn(flat.1, about: .origin, by: axisAngle))
        }
        switch orientation {
        case .horizontal:
            return (CanvasPoint(x: start.x, y: through.y), CanvasPoint(x: end.x, y: through.y))
        case .vertical:
            return (CanvasPoint(x: through.x, y: start.y), CanvasPoint(x: through.x, y: end.y))
        case .aligned:
            let (nx, ny) = Self.normal(start, end)
            let offset = (through.x.inches - start.x.inches) * nx + (through.y.inches - start.y.inches) * ny
            return (CanvasPoint(x: .inches(start.x.inches + nx * offset), y: .inches(start.y.inches + ny * offset)),
                    CanvasPoint(x: .inches(end.x.inches + nx * offset), y: .inches(end.y.inches + ny * offset)))
        }
    }

    /// A point as it would be had the dimension's axes never turned.
    private func unturned(_ point: CanvasPoint) -> CanvasPoint {
        SheetAngle.turn(point, about: .origin, by: -axisAngle)
    }

    /// The middle of the dimension line, where its text sits.
    public var textPosition: CanvasPoint {
        let (a, b) = line
        return CanvasPoint(x: .inches((a.x.inches + b.x.inches) / 2), y: .inches((a.y.inches + b.y.inches) / 2))
    }

    /// The rectangle its points, its lines and room for its text cover.
    public var bounds: CanvasRect {
        let (a, b) = line
        let text = textPosition
        let pad = textHeight.inches * 4
        let textBox = CanvasRect(origin: text.offsetBy(dx: .inches(-pad), dy: .inches(-pad)),
                                 size: CanvasSize(width: .inches(pad * 2), height: .inches(pad * 2)))
        let points = [start, end, a, b].map { CanvasRect(origin: $0, size: CanvasSize(width: .zero, height: .zero)) }
        return CanvasRect.union(points + [textBox])!
    }

    /// The dimension moved and scaled by a transform, its points kept on the ink grid and its text scaled with it,
    /// under the same id (a move) or another (a duplicate).
    public func transformed(by transform: CanvasTransform, id newID: DimensionID? = nil) -> CanvasDimension {
        CanvasDimension(id: newID ?? id, start: transform.apply(start).onInkGrid, end: transform.apply(end).onInkGrid,
                  through: transform.apply(through).onInkGrid, orientation: orientation, colour: colour,
                  textHeight: textHeight * transform.scale, axisAngle: axisAngle)
    }

    /// The same dimension with its points on the ink grid, as it is kept and saved.
    var onInkGrid: CanvasDimension {
        CanvasDimension(id: id, start: start.onInkGrid, end: end.onInkGrid, through: through.onInkGrid,
                  orientation: orientation, colour: colour, textHeight: textHeight, axisAngle: axisAngle)
    }

    /// The unit normal to the line from a to b, pointing up the screen (or left, for a plumb pair): the side an
    /// aligned dimension's offset is measured toward.
    static func normal(_ a: CanvasPoint, _ b: CanvasPoint) -> (Double, Double) {
        let dx = b.x.inches - a.x.inches, dy = b.y.inches - a.y.inches
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return (0, -1) }
        var nx = -dy / length, ny = dx / length
        if ny > 1e-12 || (abs(ny) <= 1e-12 && nx > 0) {
            nx = -nx
            ny = -ny
        }
        return (nx, ny)
    }
}

extension Canvas {
    /// What a dimension reads on this canvas: its real length, or, when either of its points is on an NTS sheet, the
    /// printed length marked NTS (CONTEXT.md "NTS sheet"); in a scale area, at the area's scale (#11).
    public func measure(_ dimension: CanvasDimension) -> Measure {
        Self.measure(dimension.length, between: dimension.start, and: dimension.end, on: sheets)
    }
}
