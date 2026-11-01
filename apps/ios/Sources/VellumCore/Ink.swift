#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// What a colour of ink means to an agent (ADR-0009): red is something to add, green is something to delete, blue is a
/// note, and sketch ink is read for context only. Every stroke records one, so the meaning travels with the ink to a
/// job rather than being guessed from a picture.
public enum MarkupColour: String, CaseIterable, Hashable, Sendable {
    case red
    case green
    case blue
    case sketch

    public enum Meaning: String, Hashable, Sendable {
        case add
        case delete
        case note
        case sketch
    }

    public var meaning: Meaning {
        switch self {
        case .red: .add
        case .green: .delete
        case .blue: .note
        case .sketch: .sketch
        }
    }

    /// The colour's name on the rail, by what it means: Add, Delete, Note, Sketch.
    public var title: String {
        switch self {
        case .red: "Add"
        case .green: "Delete"
        case .blue: "Note"
        case .sketch: "Sketch"
        }
    }

    /// The colour the ink is drawn in. Red, green and blue stay red, green and blue in both modes, a little brighter
    /// on a dark ground so they read as well. Sketch ink flips between near-black and near-white to stay readable over
    /// whatever is under it, like AutoCAD's colour 7 (ADR-0011). `overLightPaper` is for ink lying on a sheet that is
    /// drawn light (any sheet in light mode, a dimmed sheet in dark mode); an inverted sheet is dark paper.
    public func rgb(dark: Bool, overLightPaper: Bool = false) -> InkRGB {
        let darkGround = dark && !overLightPaper
        switch (self, darkGround) {
        case (.red, false): return InkRGB(hex: 0xD6342C)
        case (.red, true): return InkRGB(hex: 0xFF5A4F)
        case (.green, false): return InkRGB(hex: 0x1F9D55)
        case (.green, true): return InkRGB(hex: 0x3CCF7A)
        case (.blue, false): return InkRGB(hex: 0x2563EB)
        case (.blue, true): return InkRGB(hex: 0x5B8DFF)
        case (.sketch, false): return InkRGB(hex: 0x3A3A3A)
        case (.sketch, true): return InkRGB(hex: 0xE6E6E6)
        }
    }
}

/// An sRGB colour, kept here rather than as a UIColor so the colour rules are testable without a device.
public struct InkRGB: Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }

    /// Relative luminance, 0 for black to 1 for white (WCAG's formula).
    public var luminance: Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The WCAG contrast ratio between two colours, from 1 (none) to 21 (black on white).
    public func contrast(with other: InkRGB) -> Double {
        let (a, b) = (luminance + 0.05, other.luminance + 0.05)
        return max(a, b) / min(a, b)
    }
}

/// The pens that leave ink: the pen and the highlighter. The eraser removes ink rather than leaving it.
public enum InkTool: String, CaseIterable, Hashable, Sendable {
    case pen
    case highlighter

    /// How opaque the ink is drawn: the highlighter is see-through so linework reads through it.
    public var opacity: Double {
        switch self {
        case .pen: 1
        case .highlighter: 0.3
        }
    }
}

/// The line weights a pen offers. The USB-C Pencil has no pressure (ADR-0001), so weight comes from this choice alone.
public enum LineWeight: String, CaseIterable, Hashable, Sendable {
    case fine
    case medium
    case bold

    public static let `default` = LineWeight.medium

    public var title: String {
        switch self {
        case .fine: "Fine"
        case .medium: "Medium"
        case .bold: "Bold"
        }
    }

    /// The weight on screen, in points, as the stroke is drawn.
    public func screenWidth(for tool: InkTool) -> Double {
        switch (tool, self) {
        case (.pen, .fine): 1.5
        case (.pen, .medium): 3
        case (.pen, .bold): 6
        case (.highlighter, .fine): 10
        case (.highlighter, .medium): 18
        case (.highlighter, .bold): 28
        }
    }
}

/// One stroke's identity within a canvas, so the eraser and undo can name it.
public struct StrokeID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public static func < (lhs: StrokeID, rhs: StrokeID) -> Bool { lhs.value < rhs.value }
    public var description: String { "stroke \(value)" }
}

/// One stroke of ink in model space: its points in real-world lengths, the pen that drew it, its markup colour and its
/// width.
///
/// The width is a real-world length, fixed when the stroke is drawn as the chosen screen weight at the zoom it was
/// drawn at. Ink is then like ink on paper: a redline drawn over a valve stays the width it was drawn relative to that
/// valve, and handwriting written close up shrinks with its letters when Zach zooms out rather than swelling into a
/// blob. Renderers draw no thinner than a hairline so zoomed-out ink never vanishes.
public struct InkStroke: Hashable, Sendable, Identifiable {
    public let id: StrokeID
    public var tool: InkTool
    public var colour: MarkupColour
    public var width: Length
    public var points: [CanvasPoint]

    public init(id: StrokeID, tool: InkTool, colour: MarkupColour, width: Length, points: [CanvasPoint]) {
        self.id = id
        self.tool = tool
        self.colour = colour
        self.width = width
        self.points = points
    }

    /// The rectangle the stroke's centre line covers, without its width; nil for a stroke with no points.
    public var pathBounds: CanvasRect? {
        guard let first = points.first else { return nil }
        var minX = first.x.inches, maxX = minX, minY = first.y.inches, maxY = minY
        for p in points.dropFirst() {
            minX = min(minX, p.x.inches); maxX = max(maxX, p.x.inches)
            minY = min(minY, p.y.inches); maxY = max(maxY, p.y.inches)
        }
        return CanvasRect(origin: CanvasPoint(x: .inches(minX), y: .inches(minY)),
                          size: CanvasSize(width: .inches(maxX - minX), height: .inches(maxY - minY)))
    }

    /// The rectangle the stroke's ink covers, its width included.
    public var bounds: CanvasRect? { pathBounds?.insetBy(-width / 2) }

    /// The distance from a point to the stroke's centre line.
    public func distance(to point: CanvasPoint) -> Length {
        guard let first = points.first else { return Length(inches: .infinity) }
        if points.count == 1 { return first.distance(to: point) }
        var best = Double.infinity
        for i in 1..<points.count {
            best = min(best, Self.segmentDistance(point, points[i - 1], points[i]))
        }
        return .inches(best)
    }

    /// Whether the ink lies within `tolerance` of a point: the eraser's test.
    public func isHit(at point: CanvasPoint, tolerance: Length) -> Bool {
        if let box = bounds?.insetBy(-tolerance), !box.contains(point) { return false }
        return distance(to: point) <= width / 2 + tolerance
    }

    private static func segmentDistance(_ p: CanvasPoint, _ a: CanvasPoint, _ b: CanvasPoint) -> Double {
        let (ax, ay, bx, by) = (a.x.inches, a.y.inches, b.x.inches, b.y.inches)
        let (px, py) = (p.x.inches, p.y.inches)
        let (dx, dy) = (bx - ax, by - ay)
        let lengthSquared = dx * dx + dy * dy
        var t = lengthSquared == 0 ? 0 : ((px - ax) * dx + (py - ay) * dy) / lengthSquared
        t = max(0, min(1, t))
        let (cx, cy) = (ax + t * dx - px, ay + t * dy - py)
        return (cx * cx + cy * cy).squareRoot()
    }
}

/// All the ink on a canvas, in the order it was drawn.
public struct Ink: Hashable, Sendable {
    public private(set) var strokes: [InkStroke]

    public init(strokes: [InkStroke] = []) { self.strokes = strokes }

    public var isEmpty: Bool { strokes.isEmpty }

    /// The strokes the eraser touches at a point, topmost (latest) first.
    public func strokes(hitAt point: CanvasPoint, tolerance: Length) -> [InkStroke] {
        strokes.reversed().filter { $0.isHit(at: point, tolerance: tolerance) }
    }

    /// The rectangle all the ink covers; nil when there is none.
    public var bounds: CanvasRect? { CanvasRect.union(strokes.compactMap(\.bounds)) }

    mutating func insert(_ stroke: InkStroke, at index: Int) { strokes.insert(stroke, at: index) }
    mutating func remove(at index: Int) -> InkStroke { strokes.remove(at: index) }
    func index(of id: StrokeID) -> Int? { strokes.firstIndex { $0.id == id } }
}

/// One change to a canvas's ink, as it is written to the Duo (ADR-0014): a stroke drawn, strokes erased, an undo or a
/// redo. Replaying a canvas's events in order through `InkSession.apply` rebuilds its ink and its undo history exactly.
public enum InkEvent: Hashable, Sendable {
    /// A stroke drawn, added on top of the ink.
    case draw(InkStroke)
    /// Strokes the eraser took, whole, in the order it took them. `continuingSweep` is true when they join the undo
    /// step of the sweep in progress rather than starting a new one.
    case erase([StrokeID], continuingSweep: Bool)
    case undo
    case redo
}

/// Drawing and erasing ink with undo and redo on a canvas. Every change it makes is also kept as an `InkEvent` until
/// `takeEvents` hands it to be saved, so what is written to the Duo is exactly what was done.
///
/// The undo history keeps the last `undoLimit` steps. It is saved with the ink (ADR-0014), so undo and redo survive a
/// relaunch.
public struct InkSession: Hashable, Sendable {
    /// How many undo steps are kept. Older steps are dropped, oldest first.
    public static let undoLimit = 500

    public private(set) var ink: Ink
    private(set) var undoStack: [Edit] = []
    private(set) var redoStack: [Edit] = []
    private(set) var nextID: Int
    /// Whether the top undo step belongs to the eraser sweep in progress, so the sweep's next hit joins it.
    private var sweepHasEntry = false
    /// Changes made since `takeEvents` last collected them.
    public private(set) var unsavedEvents: [InkEvent] = []

    /// One undoable step. An erase records every stroke it removed, with the index it was removed from, in the order
    /// they went, so undo can put each back exactly where it was.
    enum Edit: Hashable, Sendable {
        case draw(InkStroke, index: Int)
        case erase([Removal])
    }

    struct Removal: Hashable, Sendable {
        var index: Int
        var stroke: InkStroke
    }

    public init(ink: Ink = Ink()) {
        self.ink = ink
        nextID = (ink.strokes.map(\.id.value).max() ?? 0) + 1
    }

    /// A session restored from a snapshot, with its undo history.
    init(ink: Ink, undoStack: [Edit], redoStack: [Edit], nextID: Int) {
        self.ink = ink
        self.undoStack = undoStack
        self.redoStack = redoStack
        self.nextID = max(nextID, (ink.strokes.map(\.id.value).max() ?? 0) + 1)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Hands over the changes made since the last call, for saving, and forgets them.
    public mutating func takeEvents() -> [InkEvent] {
        defer { unsavedEvents.removeAll() }
        return unsavedEvents
    }

    /// Commits a stroke the Pencil has finished, with the pen, colour and width it took at touchdown.
    @discardableResult
    public mutating func commit(_ stroke: StrokeInProgress) -> InkStroke? {
        draw(stroke.points, tool: stroke.tool, colour: stroke.colour, width: stroke.width)
    }

    /// Adds a stroke with a real-world width. A stroke with no points leaves nothing and returns nil. Its points are
    /// kept on the ink grid (1/65,536 inch, ADR-0014), so the ink in memory is exactly the ink saved.
    @discardableResult
    public mutating func draw(_ points: [CanvasPoint], tool: InkTool, colour: MarkupColour, width: Length) -> InkStroke? {
        guard !points.isEmpty else { return nil }
        let stroke = InkStroke(id: StrokeID(nextID), tool: tool, colour: colour, width: width,
                               points: points.map(\.onInkGrid))
        perform(.draw(stroke))
        return stroke
    }

    /// Starts a sweep of the eraser: everything one sweep erases, from touchdown to lift, undoes as one step, and a
    /// new sweep is always a new step, even when it starts on blank canvas.
    public mutating func beginEraserSweep() { sweepHasEntry = false }

    /// Erases every stroke within `tolerance` of a point, whole, as part of the current sweep. Returns the strokes
    /// erased.
    @discardableResult
    public mutating func erase(at point: CanvasPoint, tolerance: Length) -> [InkStroke] {
        let hit = ink.strokes(hitAt: point, tolerance: tolerance)
        guard !hit.isEmpty else { return [] }
        let continuing: Bool
        if sweepHasEntry, case .erase? = undoStack.last { continuing = true } else { continuing = false }
        perform(.erase(hit.map(\.id), continuingSweep: continuing))
        return hit
    }

    public mutating func undo() {
        guard canUndo else { return }
        perform(.undo)
    }

    public mutating func redo() {
        guard canRedo else { return }
        perform(.redo)
    }

    private mutating func perform(_ event: InkEvent) {
        apply(event)
        unsavedEvents.append(event)
    }

    /// Replays one saved change. Replaying a canvas's events in the order they were made rebuilds its ink and undo
    /// history exactly; an event that no longer fits (an undo with nothing to undo, an erase of strokes not there) does
    /// nothing rather than fail, so a damaged history never stops a canvas opening.
    public mutating func apply(_ event: InkEvent) {
        switch event {
        case .draw(let stroke):
            // Strokes are numbered in the order drawn, so only an id below the next one can already be on the canvas.
            guard !stroke.points.isEmpty, stroke.id.value >= nextID || ink.index(of: stroke.id) == nil else { return }
            nextID = max(nextID, stroke.id.value + 1)
            let index = ink.strokes.count
            ink.insert(stroke, at: index)
            record(.draw(stroke, index: index))
        case .erase(let ids, let continuing):
            var removed: [Removal] = []
            for id in ids {
                guard let index = ink.index(of: id) else { continue }
                removed.append(Removal(index: index, stroke: ink.remove(at: index)))
            }
            guard !removed.isEmpty else { return }
            if continuing, case .erase(let earlier)? = undoStack.last {
                redoStack.removeAll()
                undoStack[undoStack.count - 1] = .erase(earlier + removed)
            } else {
                record(.erase(removed))
            }
            sweepHasEntry = true
        case .undo:
            guard let edit = undoStack.popLast() else { return }
            sweepHasEntry = false
            switch edit {
            case .draw(_, let index):
                _ = ink.remove(at: index)
            case .erase(let removed):
                for item in removed.reversed() { ink.insert(item.stroke, at: item.index) }
            }
            redoStack.append(edit)
        case .redo:
            guard let edit = redoStack.popLast() else { return }
            sweepHasEntry = false
            switch edit {
            case .draw(let stroke, let index):
                ink.insert(stroke, at: index)
            case .erase(let removed):
                for item in removed { _ = ink.remove(at: item.index) }
            }
            undoStack.append(edit)
        }
    }

    private mutating func record(_ edit: Edit) {
        redoStack.removeAll()
        undoStack.append(edit)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        sweepHasEntry = false
    }

    /// Two sessions are equal when their ink and undo history are; unsaved events and the sweep in progress are not
    /// part of what is saved.
    public static func == (lhs: InkSession, rhs: InkSession) -> Bool {
        lhs.ink == rhs.ink && lhs.undoStack == rhs.undoStack && lhs.redoStack == rhs.redoStack && lhs.nextID == rhs.nextID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ink)
        hasher.combine(nextID)
    }
}

extension CanvasRect {
    /// The rectangle grown (negative amount) or shrunk (positive) by `amount` on every side.
    public func insetBy(_ amount: Length) -> CanvasRect {
        CanvasRect(origin: origin.offsetBy(dx: amount, dy: amount),
                   size: CanvasSize(width: size.width - amount * 2, height: size.height - amount * 2))
    }

    /// The smallest rectangle holding all of them; nil for none.
    public static func union(_ rects: [CanvasRect]) -> CanvasRect? {
        guard let first = rects.first else { return nil }
        var minX = first.minX, minY = first.minY, maxX = first.maxX, maxY = first.maxY
        for r in rects.dropFirst() {
            minX = min(minX, r.minX); minY = min(minY, r.minY)
            maxX = max(maxX, r.maxX); maxY = max(maxY, r.maxY)
        }
        return CanvasRect(origin: CanvasPoint(x: minX, y: minY), size: CanvasSize(width: maxX - minX, height: maxY - minY))
    }

    public var center: CanvasPoint { origin.offsetBy(dx: size.width / 2, dy: size.height / 2) }

    /// Whether two rectangles overlap or touch.
    public func intersects(_ other: CanvasRect) -> Bool {
        minX <= other.maxX && other.minX <= maxX && minY <= other.maxY && other.minY <= maxY
    }
}
