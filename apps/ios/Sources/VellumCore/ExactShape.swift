#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Straight lines catching by themselves (#40): a line within `range` degrees of a multiple of 45° pulls onto it and shows
/// a guide. There is no lock button; other angles close to those are typed.
///
/// Angles read counter-clockwise from east (+X), as AutoCAD does. The canvas's y runs down, so a line going up the screen
/// reads 90°.
public enum AngleCatch {
    public static let range = 4.0
    public static let step = 45.0

    /// The direction from one point to another, from 0 up to 360 degrees; 0 when they are the same.
    public static func angle(from a: CanvasPoint, to b: CanvasPoint) -> Double {
        let dx = b.x.inches - a.x.inches, dy = b.y.inches - a.y.inches
        guard dx != 0 || dy != 0 else { return 0 }
        return SheetAngle.normalized(atan2(-dy, dx) * 180 / .pi)
    }

    /// The point `length` from `start` in the direction `angle`, exact on a quarter turn.
    public static func point(from start: CanvasPoint, length: Length, angle: Double) -> CanvasPoint {
        let (c, s) = SheetAngle.cosineAndSine(angle)
        return CanvasPoint(x: .inches(start.x.inches + length.inches * c), y: .inches(start.y.inches - length.inches * s))
    }

    /// Where the end of a line from `anchor` lands: pulled square onto the catch's line when within range, with the angle
    /// caught for the guide; or left where it is, with no guide.
    public static func caught(from anchor: CanvasPoint, to point: CanvasPoint) -> (point: CanvasPoint, guide: Double?) {
        let length = anchor.distance(to: point)
        guard length.inches > 0 else { return (point, nil) }
        let angle = angle(from: anchor, to: point)
        let nearest = (angle / step).rounded() * step
        let off = abs(angle - nearest)
        guard off <= range else { return (point, nil) }
        let guide = SheetAngle.normalized(nearest)
        return (self.point(from: anchor, length: length * SheetAngle.cosineAndSine(off).cos, angle: guide), guide)
    }
}

/// What the line and shape tool draws, chosen from its flyout on the rail (#40). Draw it is today's behaviour: draw by hand
/// and it straightens on lift.
public enum LineShape: String, CaseIterable, Identifiable, Hashable, Sendable {
    case drawIt
    case line
    case polyline
    case rectangle
    case circle
    case arc
    case polygon

    /// What the tool starts on: what it always did.
    public static let `default` = LineShape.drawIt
    /// A polygon's sides until they are typed.
    public static let defaultSides = 6

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .drawIt: "Draw it"
        case .line: "Line"
        case .polyline: "Polyline"
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .arc: "Arc"
        case .polygon: "Polygon"
        }
    }

    /// The status bar's prompt before anything is placed.
    public var prompt: String {
        switch self {
        case .drawIt: "Draw a line, box or circle"
        case .line: "Tap or drag: first point"
        case .polyline: "Tap the first point"
        case .rectangle: "Tap or drag a corner"
        case .circle, .polygon: "Tap or drag from the centre"
        case .arc: "Tap the arc's start"
        }
    }

    /// What it does, for VoiceOver.
    public var hint: String {
        switch self {
        case .drawIt: "Draw by hand and it straightens when you lift"
        case .line: "A drag or two taps. Lines catch on 0, 45 and 90 degrees"
        case .polyline: "A tap per bend. Finish with Done, by tapping the last point again, or by closing on the first"
        case .rectangle: "A drag or two taps, corner to corner"
        case .circle: "A drag or two taps, from the centre to the edge"
        case .arc: "Tap the start, the end, then the bulge"
        case .polygon: "A drag or two taps, from the centre to a corner. Six sides until you type others"
        }
    }

    /// Whether its points are found with the angle catch.
    var catchesAngles: Bool { self == .line || self == .polyline || self == .polygon }
}

/// A shape just drawn, which its tag shows the size of and the number pad corrects (#40). It lasts only until the next
/// thing starts, because ink keeps no shape to come back to: what is saved is the stroke's points, as for any stroke.
public struct DrawnShape: Hashable, Sendable {
    /// A value the number pad can set.
    public enum Field: String, CaseIterable, Hashable, Sendable {
        case length, angle, width, height, diameter, radius, sides, side

        public var title: String {
            switch self {
            case .length: "Length"
            case .angle: "Angle"
            case .width: "Width"
            case .height: "Height"
            case .diameter: "Diameter"
            case .radius: "Radius"
            case .sides: "Sides"
            case .side: "Side"
            }
        }
    }

    public private(set) var shape: SnappedShape
    /// A rectangle's corner that stays put when it is corrected: -1 or 1 along its width and across it.
    private var fixedCorner = (u: -1.0, v: -1.0)

    public init(_ shape: SnappedShape) { self.shape = shape }

    public static func == (a: DrawnShape, b: DrawnShape) -> Bool {
        a.shape == b.shape && a.fixedCorner == b.fixedCorner
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(shape)
        hasher.combine(fixedCorner.u)
        hasher.combine(fixedCorner.v)
    }

    /// A rectangle from one corner to the opposite one, square to the canvas, which keeps the first corner when corrected.
    public static func rectangle(from a: CanvasPoint, to b: CanvasPoint) -> DrawnShape {
        let dx = b.x.inches - a.x.inches, dy = b.y.inches - a.y.inches
        var drawn = DrawnShape(.rectangle(centre: CanvasPoint(x: .inches(a.x.inches + dx / 2), y: .inches(a.y.inches + dy / 2)),
                                          width: .inches(abs(dx)), height: .inches(abs(dy)), angle: 0))
        drawn.fixedCorner = (dx < 0 ? 1 : -1, dy < 0 ? 1 : -1)
        return drawn
    }

    /// A circle from its centre and a point on its edge.
    public static func circle(centre: CanvasPoint, edge: CanvasPoint) -> DrawnShape {
        let r = centre.distance(to: edge)
        return DrawnShape(.ellipse(centre: centre, radiusX: r, radiusY: r, angle: 0))
    }

    /// A regular polygon from its centre and a corner.
    public static func polygon(centre: CanvasPoint, corner: CanvasPoint, sides: Int = LineShape.defaultSides) -> DrawnShape {
        DrawnShape(.polygon(centre: centre, sides: sides, radius: centre.distance(to: corner),
                            rotation: AngleCatch.angle(from: centre, to: corner)))
    }

    /// An arc from `start` to `end`, bulging as far from the line between them as `bulge` is, on that side; a straight line
    /// when the bulge is on that line.
    public static func arc(start: CanvasPoint, end: CanvasPoint, bulge: CanvasPoint) -> DrawnShape {
        let chord = start.distance(to: end).inches
        guard chord > 0 else { return DrawnShape(.line(start, end)) }
        let (mx, my) = ((start.x.inches + end.x.inches) / 2, (start.y.inches + end.y.inches) / 2)
        let (nx, ny) = (-(end.y.inches - start.y.inches) / chord, (end.x.inches - start.x.inches) / chord)
        let height = (bulge.x.inches - mx) * nx + (bulge.y.inches - my) * ny
        guard abs(height) >= chord * 1e-3 else { return DrawnShape(.line(start, end)) }
        let sag = abs(height), side = height > 0 ? 1.0 : -1.0
        let radius = (chord * chord / 4 + sag * sag) / (2 * sag)
        let centre = CanvasPoint(x: .inches(mx - nx * (radius - sag) * side), y: .inches(my - ny * (radius - sag) * side))
        return DrawnShape(arcShape(start: start, end: end, centre: centre, radius: radius, side: side))
    }

    /// The arc round `centre` from `start` to `end` on `side` of the line between them.
    private static func arcShape(start: CanvasPoint, end: CanvasPoint, centre: CanvasPoint, radius: Double,
                                 side: Double) -> SnappedShape {
        let from = AngleCatch.angle(from: centre, to: start)
        let to = AngleCatch.angle(from: centre, to: end)
        var sweep = SheetAngle.normalized(to - from)
        let chord = start.distance(to: end).inches
        let (mx, my) = ((start.x.inches + end.x.inches) / 2, (start.y.inches + end.y.inches) / 2)
        let (nx, ny) = (-(end.y.inches - start.y.inches) / chord, (end.x.inches - start.x.inches) / chord)
        let middle = AngleCatch.point(from: centre, length: .inches(radius), angle: from + sweep / 2)
        if ((middle.x.inches - mx) * nx + (middle.y.inches - my) * ny) * side < 0 { sweep -= 360 }
        return .arc(centre: centre, radius: .inches(radius), start: from, sweep: sweep)
    }

    // MARK: What the tag and the pad show

    /// The values the number pad sets, in the order it shows them.
    public var fields: [Field] {
        switch shape {
        case .line, .polyline: [.length, .angle]
        case .rectangle: [.width, .height]
        case .ellipse(_, let rx, let ry, _): rx == ry ? [.diameter] : [.width, .height]
        case .arc: [.radius]
        case .polygon: [.sides, .side]
        }
    }

    /// A polyline's last segment: what its tag shows and its pad corrects.
    private var lastSegment: (from: CanvasPoint, to: CanvasPoint)? {
        switch shape {
        case .line(let a, let b): (a, b)
        case .polyline(let points) where points.count >= 2: (points[points.count - 2], points[points.count - 1])
        default: nil
        }
    }

    /// A length's value, or nil for a field that isn't one or isn't this shape's.
    public func length(of field: Field) -> Length? {
        switch (shape, field) {
        case (.line, .length), (.polyline, .length):
            return lastSegment.map { $0.from.distance(to: $0.to) }
        case (.rectangle(_, let width, _, _), .width): return width
        case (.rectangle(_, _, let height, _), .height): return height
        case (.ellipse(_, let rx, let ry, _), .diameter) where rx == ry: return rx * 2
        case (.ellipse(_, let rx, _, _), .width): return rx * 2
        case (.ellipse(_, _, let ry, _), .height): return ry * 2
        case (.arc(_, let radius, _, _), .radius): return radius
        case (.polygon(_, let sides, let radius, _), .side):
            return radius * (2 * sin(Double.pi / Double(sides)))
        default: return nil
        }
    }

    /// What a field shows until something is typed in it.
    public func reading(of field: Field, units: CanvasUnits) -> String {
        switch field {
        case .angle:
            return lastSegment.map { SheetAngle.reading(AngleCatch.angle(from: $0.from, to: $0.to)) } ?? ""
        case .sides:
            if case .polygon(_, let sides, _, _) = shape { return "\(sides)" }
            return ""
        default:
            return length(of: field).map(units.format) ?? ""
        }
    }

    /// The tag: length and angle for a line or a polyline's last segment, W × H, a diameter, sides × side length, a radius.
    public func tag(units: CanvasUnits) -> String {
        switch shape {
        case .line, .polyline:
            return reading(of: .length, units: units) + "  " + reading(of: .angle, units: units)
        case .rectangle:
            return reading(of: .width, units: units) + " × " + reading(of: .height, units: units)
        case .ellipse(_, let rx, let ry, _):
            return rx == ry ? "⌀ " + reading(of: .diameter, units: units)
                : reading(of: .width, units: units) + " × " + reading(of: .height, units: units)
        case .arc:
            return "R " + reading(of: .radius, units: units)
        case .polygon:
            return reading(of: .sides, units: units) + " × " + reading(of: .side, units: units)
        }
    }

    /// Where on the canvas the tag sits: a line's or last segment's middle, a closed shape's centre, the top of an arc.
    public var spot: CanvasPoint {
        switch shape {
        case .line, .polyline:
            guard let (a, b) = lastSegment else { return shape.points.first ?? .origin }
            return CanvasPoint(x: .inches((a.x.inches + b.x.inches) / 2), y: .inches((a.y.inches + b.y.inches) / 2))
        case .rectangle(let centre, _, _, _), .ellipse(let centre, _, _, _), .polygon(let centre, _, _, _):
            return centre
        case .arc(let centre, let radius, let start, let sweep):
            return AngleCatch.point(from: centre, length: radius, angle: start + sweep / 2)
        }
    }

    // MARK: Correcting

    /// What a correction was given: a length, an angle or a count of sides.
    public enum Value: Hashable, Sendable {
        case length(Length)
        case angle(Double)
        case sides(Int)
    }

    /// The shape with these values set, and everything else as it was: a line keeps its start, a rectangle the corner it
    /// was started from, a circle and a polygon their centres, an arc its ends and side. Nil when no such shape exists: an
    /// arc's radius less than half the distance between its ends.
    public func corrected(_ values: [Field: Value]) -> DrawnShape? {
        func length(_ field: Field) -> Length? {
            if case .length(let value)? = values[field] { return value }
            return nil
        }
        var result = self
        switch shape {
        case .line, .polyline:
            guard let (from, to) = lastSegment else { return self }
            let newLength = length(.length) ?? from.distance(to: to)
            var newAngle = AngleCatch.angle(from: from, to: to)
            if case .angle(let typed)? = values[.angle] { newAngle = typed }
            let end = AngleCatch.point(from: from, length: newLength, angle: newAngle)
            if case .polyline(var points) = shape {
                // A closed polyline stays closed: its first point is its last.
                if points.count > 3, points[0] == points[points.count - 1] { points[0] = end }
                points[points.count - 1] = end
                result.shape = .polyline(points)
            } else {
                result.shape = .line(from, end)
            }
        case .rectangle(let centre, let width, let height, let angle):
            let w = length(.width) ?? width, h = length(.height) ?? height
            let (c, s) = (cos(angle), sin(angle))
            let (u, v) = fixedCorner
            // The fixed corner stays where it is; the centre goes half the new size away from it.
            let du = u * (width.inches - w.inches) / 2, dv = v * (height.inches - h.inches) / 2
            result.shape = .rectangle(centre: CanvasPoint(x: .inches(centre.x.inches + du * c - dv * s),
                                                          y: .inches(centre.y.inches + du * s + dv * c)),
                                      width: w, height: h, angle: angle)
        case .ellipse(let centre, let rx, let ry, let angle):
            if rx == ry, let diameter = length(.diameter) {
                result.shape = .ellipse(centre: centre, radiusX: diameter / 2, radiusY: diameter / 2, angle: angle)
            } else {
                result.shape = .ellipse(centre: centre, radiusX: length(.width).map { $0 / 2 } ?? rx,
                                        radiusY: length(.height).map { $0 / 2 } ?? ry, angle: angle)
            }
        case .arc(let centre, let radius, let start, let sweep):
            guard let newRadius = length(.radius) else { return self }
            let from = AngleCatch.point(from: centre, length: radius, angle: start)
            let to = AngleCatch.point(from: centre, length: radius, angle: start + sweep)
            let chord = from.distance(to: to).inches
            // Half the distance is a half circle, the ends' own rounding allowed for.
            guard chord > 0, newRadius.inches >= chord / 2 - 1e-9 else { return nil }
            let (mx, my) = ((from.x.inches + to.x.inches) / 2, (from.y.inches + to.y.inches) / 2)
            let (nx, ny) = (-(to.y.inches - from.y.inches) / chord, (to.x.inches - from.x.inches) / chord)
            // The side the arc bulges to, and whether its centre is on that side too (more than half a circle).
            let middle = AngleCatch.point(from: centre, length: radius, angle: start + sweep / 2)
            let side = (middle.x.inches - mx) * nx + (middle.y.inches - my) * ny > 0 ? 1.0 : -1.0
            let centreSide = (centre.x.inches - mx) * nx + (centre.y.inches - my) * ny > 0 ? 1.0 : -1.0
            let beyond = max(0, newRadius.inches * newRadius.inches - chord * chord / 4).squareRoot()
            let newCentre = CanvasPoint(x: .inches(mx + nx * beyond * centreSide), y: .inches(my + ny * beyond * centreSide))
            result.shape = Self.arcShape(start: from, end: to, centre: newCentre, radius: newRadius.inches, side: side)
        case .polygon(let centre, let sides, let radius, let rotation):
            var newSides = sides
            if case .sides(let typed)? = values[.sides] { newSides = typed }
            let side = length(.side) ?? (radius * (2 * sin(Double.pi / Double(sides))))
            result.shape = .polygon(centre: centre, sides: newSides,
                                    radius: side / (2 * sin(Double.pi / Double(newSides))), rotation: rotation)
        }
        return result
    }
}

/// The number pad (#40): what has been typed in each of a shape's fields, and which field the keys go to.
public struct NumberPad: Hashable, Sendable {
    /// The pad's keys in order, after the prototype's, with `-` added so a fraction can follow a whole number. The last
    /// two rows are `/ . -` and backspace beside Enter.
    public static let keys = ["7", "8", "9", "4", "5", "6", "1", "2", "3", "'", "0", "\"", "/", ".", "-"]

    public let shape: DrawnShape
    public let units: CanvasUnits
    public private(set) var active: DrawnShape.Field
    public private(set) var typed: [DrawnShape.Field: String] = [:]
    /// The field Enter couldn't read, until it is typed in again.
    public private(set) var problem: DrawnShape.Field?

    public init(shape: DrawnShape, units: CanvasUnits) {
        self.shape = shape
        self.units = units
        active = shape.fields.first ?? .length
    }

    public mutating func select(_ field: DrawnShape.Field) {
        guard shape.fields.contains(field) else { return }
        active = field
    }

    public mutating func press(_ key: String) {
        typed[active, default: ""] += key
        problem = nil
    }

    public mutating func backspace() {
        guard var text = typed[active], !text.isEmpty else { return }
        text.removeLast()
        typed[active] = text.isEmpty ? nil : text
        problem = nil
    }

    /// What a field shows: what was typed, or the shape's value as it stands.
    public func text(of field: DrawnShape.Field) -> String {
        typed[field] ?? shape.reading(of: field, units: units)
    }

    /// Enter: the shape with what was typed, or nil with `problem` set on the field that can't be read. A field left alone
    /// keeps its value.
    public mutating func enter() -> DrawnShape? {
        var values: [DrawnShape.Field: DrawnShape.Value] = [:]
        for field in shape.fields {
            guard let text = typed[field] else { continue }
            let value: DrawnShape.Value?
            switch field {
            case .angle: value = ExactEntry.angle(text).map(DrawnShape.Value.angle)
            case .sides: value = ExactEntry.sides(text).map(DrawnShape.Value.sides)
            default: value = units.parseLength(text).map(DrawnShape.Value.length)
            }
            guard let value else {
                problem = field
                active = field
                return nil
            }
            values[field] = value
        }
        guard let corrected = shape.corrected(values) else {
            problem = active
            return nil
        }
        return corrected
    }
}

/// A shape part way through being drawn with the line and shape tool (#40): the points placed so far, not yet ink.
/// Line, rectangle, circle and polygon take two points, by a drag or two taps; a polyline a tap per bend; an arc its start,
/// its end, then the bulge.
public struct ShapeDraft: Hashable, Sendable {
    /// How near the first point on screen, in points, a polyline's tap closes it.
    public static let closingReach = 12.0
    /// How near the last point on screen, in points, a polyline's tap finishes it.
    public static let finishingReach = 6.0
    /// How near the last point on screen, in points, a tap is the same place.
    public static let samePlaceReach = 2.0

    public let kind: LineShape
    /// The pen, colour and width fixed when the shape started, as a stroke's are at touchdown (ADR-0012): what it commits as,
    /// whatever the tool in hand is by then. Nil only in tests of the points alone.
    public let pen: StrokeInProgress?
    public private(set) var placed: [CanvasPoint] = []
    public private(set) var isClosed = false
    /// The points as they stood before each change, so an undo puts back a bend or a size alike.
    private var earlier: [[CanvasPoint]] = []

    public init(kind: LineShape, pen: StrokeInProgress? = nil) {
        self.kind = kind
        self.pen = pen
    }

    /// The stroke a shape from this draft becomes: the pen, colour and width it started with, the shape's points.
    public func inked(_ shape: DrawnShape) -> StrokeInProgress? { pen?.snapped(to: shape.shape) }

    /// The point perpendicular, tangent and the angle catch work from: the last one placed.
    public var anchor: CanvasPoint? { placed.last }

    /// Where the tip lands: a snap point if it found one, which beats the angle catch; or the tip, caught on an angle if the
    /// shape's points catch and one is placed; with the angle for the guide.
    public func resolve(_ target: PointSnap.Target) -> (point: CanvasPoint, guide: Double?) {
        if target.kind != nil { return (target.point, nil) }
        guard kind.catchesAngles, let anchor else { return (target.point, nil) }
        return AngleCatch.caught(from: anchor, to: target.point)
    }

    /// What happened when a point was placed.
    public enum Placement: Hashable, Sendable {
        /// The shape waits for more.
        case waiting
        /// The shape is finished: it goes on the canvas as ink.
        case finished(DrawnShape)
    }

    /// Places a point. `screenDistance` is the distance between two canvas points on screen, for a polyline's tap on its
    /// first or last point.
    public mutating func place(_ point: CanvasPoint, screenDistance: (CanvasPoint, CanvasPoint) -> Double) -> Placement {
        if kind == .polyline {
            if let last = placed.last {
                if placed.count > 2, screenDistance(point, placed[0]) < Self.closingReach {
                    placed.append(placed[0])
                    isClosed = true
                    return finish().map(Placement.finished) ?? .waiting
                }
                if screenDistance(point, last) < Self.finishingReach {
                    return finish().map(Placement.finished) ?? .waiting
                }
            }
            earlier.append(placed)
            placed.append(point)
            return .waiting
        }
        // The same place twice isn't a second point: a line or a circle needs a length, an arc its two ends.
        if let last = placed.last, screenDistance(point, last) < Self.samePlaceReach { return .waiting }
        earlier.append(placed)
        placed.append(point)
        guard placed.count >= (kind == .arc ? 3 : 2) else { return .waiting }
        return finish().map(Placement.finished) ?? .waiting
    }

    /// Takes the last change back, a point placed or a size corrected: an undo while drawing, or a drag let go. False when
    /// nothing is left placed.
    @discardableResult
    public mutating func undo() -> Bool {
        if let before = earlier.popLast() { placed = before }
        return !placed.isEmpty
    }

    /// Corrects the placed points of a polyline being drawn, its last segment set through its tag. One undo puts them back.
    /// They are ink only when the polyline is.
    public mutating func correct(to points: [CanvasPoint]) {
        earlier.append(placed)
        placed = points
    }

    /// The shape as the points placed make it; nil when too few are placed. A polyline's Done comes here.
    public func finish() -> DrawnShape? { shape(with: placed) }

    /// The shape if the tip's point were placed next, for the preview.
    public func preview(to tip: CanvasPoint) -> DrawnShape? { shape(with: placed + [tip]) }

    private func shape(with points: [CanvasPoint]) -> DrawnShape? {
        guard points.count >= 2 else { return nil }
        let (a, b) = (points[0], points[1])
        switch kind {
        case .drawIt, .line: return a == b ? nil : DrawnShape(.line(a, b))
        case .polyline: return DrawnShape(.polyline(points))
        case .rectangle: return a == b ? nil : DrawnShape.rectangle(from: a, to: b)
        case .circle: return a == b ? nil : DrawnShape.circle(centre: a, edge: b)
        case .polygon: return a == b ? nil : DrawnShape.polygon(centre: a, corner: b)
        case .arc:
            if points.count < 3 { return a == b ? nil : DrawnShape(.line(a, b)) }
            return DrawnShape.arc(start: a, end: b, bulge: points[2])
        }
    }

    /// The status bar's prompt for what comes next.
    public var prompt: String {
        guard !placed.isEmpty else { return kind.prompt }
        switch kind {
        case .polyline: return placed.count > 1 ? "Tap the next bend, or Done" : "Tap the next bend"
        case .arc: return placed.count == 1 ? "Tap the arc's end" : "Tap or drag the bulge"
        case .rectangle: return "Tap the opposite corner"
        case .circle: return "Tap a point on the edge"
        case .polygon: return "Tap a corner"
        case .drawIt, .line: return "Tap the second point"
        }
    }
}

/// Where the tag, the pad and the loupe go on the canvas screen (#40): always clear of the rail, the top bar, the status bar
/// and the tab rail, and below any strip open under the top bar.
public struct ExactPlacement: Hashable, Sendable {
    /// How far they stay off the chrome, in points.
    public static let margin = 4.0

    public let left: Double
    public let top: Double
    public let right: Double
    public let bottom: Double

    /// The free part of a screen `width` by `height`, given the space the chrome takes and how far down an open strip reaches
    /// (nil with no strip open).
    public init(width: Double, height: Double, chrome: ScreenInsets, stripBottom: Double? = nil) {
        left = chrome.left + Self.margin
        top = max(chrome.top, stripBottom ?? 0) + Self.margin
        right = width - chrome.right - Self.margin
        bottom = height - chrome.bottom - Self.margin
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { max(low, min(value, max(low, high))) }

    /// The middle of a tag of this size, over a shape's spot on screen.
    public func tagCentre(spot: ScreenPoint, width: Double, height: Double) -> ScreenPoint {
        ScreenPoint(x: clamp(spot.x, left + width / 2, right - width / 2),
                    y: clamp(spot.y - 22, top + height / 2, bottom - height / 2))
    }

    /// The top-left corner of a pad of this size, beside a shape's spot on screen.
    public func padOrigin(spot: ScreenPoint, width: Double, height: Double) -> ScreenPoint {
        ScreenPoint(x: clamp(spot.x + 16, left, right - width), y: clamp(spot.y - height / 2, top, bottom - height))
    }

    /// The middle of a loupe of this radius for a tip: `lift` above it, or beside it when that would slide under the top bar
    /// or an open strip; never under any chrome.
    public func loupeCentre(tip: ScreenPoint, radius: Double, lift: Double) -> ScreenPoint {
        var centre = ScreenPoint(x: tip.x, y: tip.y - lift)
        if centre.y - radius < top {
            let aside = lift + 6
            centre = ScreenPoint(x: tip.x + (tip.x < (left + right) / 2 ? aside : -aside), y: tip.y)
        }
        return ScreenPoint(x: clamp(centre.x, left + radius, right - radius),
                           y: clamp(centre.y, top + radius, bottom - radius))
    }

    /// The top-left corner of the running size beside the tip: up and to the right of its point, or the first of the other
    /// corners round it, then beside, under or over the loupe, that is clear of the loupe and on the free part of the screen.
    public func labelOrigin(spot: ScreenPoint, tip: ScreenPoint, width: Double, height: Double, loupeRadius: Double,
                            loupeLift: Double) -> ScreenPoint {
        let loupe = loupeCentre(tip: tip, radius: loupeRadius, lift: loupeLift)
        let candidates = [ScreenPoint(x: spot.x + 14, y: spot.y - 34), ScreenPoint(x: spot.x - 14 - width, y: spot.y - 34),
                          ScreenPoint(x: spot.x + 14, y: spot.y + 16), ScreenPoint(x: spot.x - 14 - width, y: spot.y + 16),
                          ScreenPoint(x: loupe.x - loupeRadius - 4 - width, y: spot.y - 34),
                          ScreenPoint(x: loupe.x + loupeRadius + 4, y: spot.y - 34),
                          ScreenPoint(x: spot.x + 14, y: loupe.y + loupeRadius + 4),
                          ScreenPoint(x: spot.x + 14, y: loupe.y - loupeRadius - 4 - height)]
        var placed = ScreenPoint(x: 0, y: 0)
        for candidate in candidates {
            placed = ScreenPoint(x: clamp(candidate.x, left, right - width), y: clamp(candidate.y, top, bottom - height))
            // The nearest the box comes to the loupe's centre, against its radius.
            let dx = max(placed.x - loupe.x, 0, loupe.x - placed.x - width)
            let dy = max(placed.y - loupe.y, 0, loupe.y - placed.y - height)
            if dx * dx + dy * dy > loupeRadius * loupeRadius { return placed }
        }
        return placed
    }

    /// The top-left corner of the polyline's Done button, in the free part's bottom right corner.
    public func doneOrigin(width: Double, height: Double) -> ScreenPoint {
        ScreenPoint(x: right - width, y: bottom - height)
    }
}
