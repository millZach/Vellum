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
///
/// Strokes are numbered in the order they are drawn and never renumbered, and every change keeps them in that order
/// (an undone erase puts a stroke back where it was), so the ink is always sorted by `StrokeID`. That lets a stroke be
/// found by binary search and lets erasing and restoring many strokes run in one pass instead of one search and one
/// shift per stroke.
///
/// The strokes live in one buffer shared copy-on-write, like an array. `work` counts what changing them cost, so the
/// budget tests can hold the ink model to its baselines (`docs/perf/baselines/storage.json`).
public struct Ink: Hashable, Sendable {
    /// What changing the ink has cost since it was made. Not part of the ink: two inks with the same strokes are equal.
    public struct Work: Hashable, Sendable {
        /// Times the whole stroke list was copied because another value shared it when it changed. One owner keeps
        /// this at zero.
        public var copies = 0
        /// Strokes moved or merged by erasing and restoring.
        public var strokesMoved = 0
    }

    private final class Storage: @unchecked Sendable {
        var strokes: [InkStroke]
        init(_ strokes: [InkStroke]) { self.strokes = strokes }
    }

    private var storage: Storage
    public private(set) var work = Work()

    /// Ink holding these strokes, put in drawing order (by id) if they are not already.
    public init(strokes: [InkStroke] = []) {
        let inOrder = zip(strokes, strokes.dropFirst()).allSatisfy { $0.id < $1.id }
        storage = Storage(inOrder ? strokes : strokes.sorted { $0.id < $1.id })
    }

    /// Every stroke, in the order drawn.
    public var strokes: [InkStroke] { storage.strokes }
    public var isEmpty: Bool { storage.strokes.isEmpty }
    public var count: Int { storage.strokes.count }

    /// The strokes the eraser touches at a point, topmost (latest) first.
    public func strokes(hitAt point: CanvasPoint, tolerance: Length) -> [InkStroke] {
        storage.strokes.reversed().filter { $0.isHit(at: point, tolerance: tolerance) }
    }

    /// The rectangle all the ink covers; nil when there is none.
    public var bounds: CanvasRect? { CanvasRect.union(storage.strokes.compactMap(\.bounds)) }

    /// Where the stroke with this id is, found by binary search; nil when it is not on the canvas.
    func index(of id: StrokeID) -> Int? {
        let i = insertionIndex(of: id)
        return i < storage.strokes.count && storage.strokes[i].id == id ? i : nil
    }

    func contains(_ id: StrokeID) -> Bool { index(of: id) != nil }

    /// The index of the first stroke whose id is not below `id`.
    private func insertionIndex(of id: StrokeID) -> Int {
        var low = 0, high = storage.strokes.count
        while low < high {
            let mid = (low + high) / 2
            if storage.strokes[mid].id < id { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Takes the stroke list out of shared storage to change it, copying it only if another value shares it.
    private mutating func withUniqueStrokes<T>(_ body: (inout [InkStroke]) -> T) -> T {
        if !isKnownUniquelyReferenced(&storage) {
            storage = Storage(storage.strokes)
            work.copies += 1
        }
        var strokes = storage.strokes
        storage.strokes = []
        defer { storage.strokes = strokes }
        return body(&strokes)
    }

    /// Removes the strokes with these ids, in one pass over the strokes after the first of them, and returns the ones
    /// that were there, in drawing order. Ids not on the canvas are ignored.
    @discardableResult
    mutating func remove(_ ids: [StrokeID]) -> [InkStroke] {
        var indices = ids.compactMap(index(of:))
        guard !indices.isEmpty else { return [] }
        indices.sort()
        let first = indices[0]
        var removed: [InkStroke] = []
        removed.reserveCapacity(indices.count)
        let moved = withUniqueStrokes { strokes -> Int in
            var write = first, next = 0
            for read in first..<strokes.count {
                if next < indices.count, indices[next] == read {
                    // The same id twice in `ids` gives the same index twice; take the stroke once.
                    removed.append(strokes[read])
                    while next < indices.count, indices[next] == read { next += 1 }
                } else {
                    strokes[write] = strokes[read]
                    write += 1
                }
            }
            let moved = strokes.count - first
            strokes.removeLast(strokes.count - write)
            return moved
        }
        work.strokesMoved += moved
        return removed
    }

    /// Puts strokes back in their places by id, merging them with the strokes after the first of them in one pass. A
    /// stroke whose id is already on the canvas is left out.
    mutating func restore(_ restored: [InkStroke]) {
        guard !restored.isEmpty else { return }
        let adding = zip(restored, restored.dropFirst()).allSatisfy { $0.id < $1.id }
            ? restored : restored.sorted { $0.id < $1.id }
        let from = insertionIndex(of: adding[0].id)
        let moved = withUniqueStrokes { strokes -> Int in
            if from == strokes.count {
                // Restoring on top of everything, as redoing a stroke does: an append.
                var last = strokes.last?.id
                for stroke in adding where last.map({ stroke.id > $0 }) ?? true {
                    strokes.append(stroke)
                    last = stroke.id
                }
                return adding.count
            }
            let tail = Array(strokes[from...])
            strokes.removeLast(tail.count)
            strokes.reserveCapacity(strokes.count + tail.count + adding.count)
            var t = 0, a = 0
            while t < tail.count || a < adding.count {
                if a == adding.count || (t < tail.count && tail[t].id <= adding[a].id) {
                    if a < adding.count, tail[t].id == adding[a].id { a += 1 }  // already there
                    strokes.append(tail[t])
                    t += 1
                } else {
                    if strokes.last.map({ $0.id < adding[a].id }) ?? true { strokes.append(adding[a]) }
                    a += 1
                }
            }
            return tail.count + adding.count
        }
        work.strokesMoved += moved
    }

    public static func == (lhs: Ink, rhs: Ink) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.strokes == rhs.storage.strokes
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(storage.strokes) }
}

/// What one change did to the ink: the strokes it added and the ids of the strokes it took away. The canvas screen
/// passes it on to whatever keeps state in step with the ink, so nothing has to diff or copy the whole canvas to
/// follow a change.
public struct InkChange: Hashable, Sendable {
    public var added: [InkStroke] = []
    public var removed: [StrokeID] = []

    public init(added: [InkStroke] = [], removed: [StrokeID] = []) {
        self.added = added
        self.removed = removed
    }

    public static let none = InkChange()
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
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
/// The undo history keeps the last `undoLimit` steps, and no more of them than keep the geometry only the history
/// holds (erased strokes, undone strokes) under `historyPointBudget` points; the newest step is always kept, however
/// big. It is saved with the ink (ADR-0014), so undo and redo survive a relaunch.
public struct InkSession: Hashable, Sendable {
    /// How many undo steps are kept. Older steps are dropped, oldest first.
    public static let undoLimit = 500
    /// How many points of ink the undo history may hold that are not on the canvas: about 16 MB of geometry. Older
    /// steps are dropped, oldest first, to keep under it.
    public static let historyPointBudget = 1_000_000

    public private(set) var ink: Ink
    private(set) var undoStack: [Edit] = []
    private(set) var redoStack: [Edit] = []
    private(set) var nextID: Int
    /// Points held only by the history: erased strokes in undo steps, undone strokes in redo steps.
    public private(set) var historyPoints = 0
    /// Whether the top undo step belongs to the eraser sweep in progress, so the sweep's next hit joins it.
    private var sweepHasEntry = false
    /// Changes made since `takeEvents` last collected them.
    public private(set) var unsavedEvents: [InkEvent] = []
    /// What the last change did to the ink.
    public private(set) var lastChange = InkChange.none

    /// One undoable step: a stroke drawn, or every stroke one eraser sweep took. Strokes keep their ids, and the ink
    /// is in id order, so undo and redo put each back exactly where it was without remembering positions.
    enum Edit: Hashable, Sendable {
        case draw(InkStroke)
        case erase([InkStroke])
    }

    public init(ink: Ink = Ink()) {
        self.ink = ink
        nextID = (ink.strokes.last?.id.value ?? 0) + 1
    }

    /// A session restored from a snapshot, with its undo history.
    init(ink: Ink, undoStack: [Edit], redoStack: [Edit], nextID: Int) {
        self.ink = ink
        self.undoStack = undoStack
        self.redoStack = redoStack
        self.nextID = max(nextID, (ink.strokes.last?.id.value ?? 0) + 1)
        historyPoints = undoStack.reduce(0) { $0 + Self.heldPoints($1, inUndo: true) }
            + redoStack.reduce(0) { $0 + Self.heldPoints($1, inUndo: false) }
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoSteps: Int { undoStack.count }

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
    /// erased. An `index` kept in step with this ink finds them without looking at every stroke.
    @discardableResult
    public mutating func erase(at point: CanvasPoint, tolerance: Length, index: InkIndex? = nil) -> [InkStroke] {
        let hit = index?.strokes(hitAt: point, tolerance: tolerance) ?? ink.strokes(hitAt: point, tolerance: tolerance)
        guard !hit.isEmpty else { return [] }
        let continuing: Bool
        if sweepHasEntry, case .erase? = undoStack.last { continuing = true } else { continuing = false }
        perform(.erase(hit.map(\.id), continuingSweep: continuing))
        // An index a step behind the ink could name a stroke already gone; return only what this erase removed.
        let removed = Set(lastChange.removed)
        return hit.filter { removed.contains($0.id) }
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

    /// Replays one saved change and returns what it did to the ink. Replaying a canvas's events in the order they were
    /// made rebuilds its ink and undo history exactly; an event that no longer fits (an undo with nothing to undo, an
    /// erase of strokes not there) does nothing rather than fail, so a damaged history never stops a canvas opening.
    @discardableResult
    public mutating func apply(_ event: InkEvent) -> InkChange {
        let change = applying(event)
        lastChange = change
        return change
    }

    private mutating func applying(_ event: InkEvent) -> InkChange {
        switch event {
        case .draw(let stroke):
            guard !stroke.points.isEmpty, !ink.contains(stroke.id) else { return .none }
            nextID = max(nextID, stroke.id.value + 1)
            ink.restore([stroke])
            record(.draw(stroke))
            return InkChange(added: [stroke])
        case .erase(let ids, let continuing):
            let removed = ink.remove(ids)
            guard !removed.isEmpty else { return .none }
            if continuing, case .erase? = undoStack.last {
                clearRedo()
                // Grow the sweep's step in place: taken off the stack, it is the only owner of its strokes.
                guard case .erase(var earlier) = undoStack.removeLast() else { return .none }
                earlier.append(contentsOf: removed)
                undoStack.append(.erase(earlier))
                historyPoints += Self.points(removed)
                trimHistory()
            } else {
                record(.erase(removed))
            }
            sweepHasEntry = true
            return InkChange(removed: removed.map(\.id))
        case .undo:
            guard let edit = undoStack.popLast() else { return .none }
            sweepHasEntry = false
            historyPoints += Self.heldPoints(edit, inUndo: false) - Self.heldPoints(edit, inUndo: true)
            redoStack.append(edit)
            trimHistory()
            switch edit {
            case .draw(let stroke):
                ink.remove([stroke.id])
                return InkChange(removed: [stroke.id])
            case .erase(let strokes):
                ink.restore(strokes)
                return InkChange(added: strokes)
            }
        case .redo:
            guard let edit = redoStack.popLast() else { return .none }
            sweepHasEntry = false
            historyPoints += Self.heldPoints(edit, inUndo: true) - Self.heldPoints(edit, inUndo: false)
            undoStack.append(edit)
            trimHistory()
            switch edit {
            case .draw(let stroke):
                ink.restore([stroke])
                return InkChange(added: [stroke])
            case .erase(let strokes):
                ink.remove(strokes.map(\.id))
                return InkChange(removed: strokes.map(\.id))
            }
        }
    }

    private mutating func record(_ edit: Edit) {
        clearRedo()
        undoStack.append(edit)
        historyPoints += Self.heldPoints(edit, inUndo: true)
        trimHistory()
        sweepHasEntry = false
    }

    private mutating func clearRedo() {
        guard !redoStack.isEmpty else { return }
        for edit in redoStack { historyPoints -= Self.heldPoints(edit, inUndo: false) }
        redoStack.removeAll()
    }

    /// Keeps the history within `undoLimit` undo steps and `historyPointBudget` points, counting the redo steps as
    /// well as the undo steps. Over the budget, the redo steps furthest from the ink go first, then the oldest undo
    /// steps. The newest step is always kept (the one just undone, or the one just done), however big. Replaying the
    /// same events trims the same steps, so a reopened canvas has exactly the history it was saved with.
    private mutating func trimHistory() {
        var held = historyPoints
        var dropRedo = 0
        while held > Self.historyPointBudget, redoStack.count - dropRedo > 1 {
            held -= Self.heldPoints(redoStack[dropRedo], inUndo: false)
            dropRedo += 1
        }
        let keepUndo = redoStack.count - dropRedo > 0 ? 0 : 1
        var drop = 0
        while undoStack.count - drop > Self.undoLimit
                || (held > Self.historyPointBudget && undoStack.count - drop > keepUndo) {
            held -= Self.heldPoints(undoStack[drop], inUndo: true)
            drop += 1
        }
        guard drop > 0 || dropRedo > 0 else { return }
        redoStack.removeFirst(dropRedo)
        undoStack.removeFirst(drop)
        historyPoints = held
    }

    /// The points of an edit's strokes that only the history holds: an undo step's erased strokes, and a redo step's
    /// undone stroke. A drawn stroke in an undo step, or erased strokes in a redo step, are on the canvas.
    static func heldPoints(_ edit: Edit, inUndo: Bool) -> Int {
        switch (edit, inUndo) {
        case (.erase(let strokes), true): points(strokes)
        case (.draw(let stroke), false): stroke.points.count
        default: 0
        }
    }

    private static func points(_ strokes: [InkStroke]) -> Int { strokes.reduce(0) { $0 + $1.points.count } }

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
