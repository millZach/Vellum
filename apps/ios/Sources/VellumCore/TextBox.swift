/// One text box's identity within a canvas. Text boxes are numbered in the order they are placed, apart from strokes.
public struct TextBoxID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public static func < (lhs: TextBoxID, rhs: TextBoxID) -> Bool { lhs.value < rhs.value }
    public var description: String { "text box \(value)" }
}

/// Typed text placed on the canvas (CONTEXT.md "Text box"): its top-left corner and size in model space, the height
/// of its letters as a real-world length, its markup colour and its text. Like a stroke's width, the letter height is
/// fixed when the box is placed (the screen size at the zoom it was placed at), so the text zooms with the ink around
/// it. The text wraps inside the box's width; the box's height is what the text needed when it was last edited.
public struct TextBox: Hashable, Sendable, Identifiable {
    public let id: TextBoxID
    public var origin: CanvasPoint
    public var size: CanvasSize
    public var fontSize: Length
    public var colour: MarkupColour
    public var text: String

    /// The letter height of a new text box on screen, in points, at the zoom it is placed at.
    public static let screenFontSize = 16.0
    /// The width of a new text box on screen, in points, at the zoom it is placed at.
    public static let screenWidth = 240.0

    public init(id: TextBoxID, origin: CanvasPoint, size: CanvasSize, fontSize: Length, colour: MarkupColour,
                text: String) {
        self.id = id
        self.origin = origin
        self.size = size
        self.fontSize = fontSize
        self.colour = colour
        self.text = text
    }

    /// The rectangle the box covers.
    public var rect: CanvasRect { CanvasRect(origin: origin, size: size) }

    /// The box moved and scaled by a transform: its corner moves, its size and letters scale.
    public func transformed(by transform: CanvasTransform) -> TextBox {
        var box = self
        box.origin = transform.apply(origin)
        box.size = CanvasSize(width: size.width * transform.scale, height: size.height * transform.scale)
        box.fontSize = fontSize * transform.scale
        return box
    }

    /// The same box under another id: for a duplicate.
    func withID(_ id: TextBoxID) -> TextBox {
        TextBox(id: id, origin: origin, size: size, fontSize: fontSize, colour: colour, text: text)
    }
}

/// A move and a uniform resize of things on the canvas: every point p goes to p × scale + (dx, dy). Resizing keeps
/// the proportions, so handwriting and circles keep their shape (#7). A transform is what the ink log records for a
/// move or a resize, with the ids it applies to; the moved strokes' points are never written again.
public struct CanvasTransform: Hashable, Sendable {
    public var scale: Double
    public var dx: Length
    public var dy: Length

    public init(scale: Double = 1, dx: Length = .zero, dy: Length = .zero) {
        self.scale = scale
        self.dx = dx
        self.dy = dy
    }

    public static let identity = CanvasTransform()

    public var isIdentity: Bool { scale == 1 && dx == .zero && dy == .zero }

    public static func translation(dx: Length, dy: Length) -> CanvasTransform { CanvasTransform(dx: dx, dy: dy) }

    /// Scales by a factor about a point, which stays where it is.
    public static func scaling(by factor: Double, about anchor: CanvasPoint) -> CanvasTransform {
        CanvasTransform(scale: factor, dx: anchor.x * (1 - factor), dy: anchor.y * (1 - factor))
    }

    public func apply(_ point: CanvasPoint) -> CanvasPoint {
        CanvasPoint(x: .inches(point.x.inches * scale + dx.inches), y: .inches(point.y.inches * scale + dy.inches))
    }

    public func apply(_ rect: CanvasRect) -> CanvasRect {
        CanvasRect(origin: apply(rect.origin),
                   size: CanvasSize(width: rect.size.width * scale, height: rect.size.height * scale))
    }

    /// This transform, then `next`.
    public func then(_ next: CanvasTransform) -> CanvasTransform {
        CanvasTransform(scale: scale * next.scale, dx: .inches(dx.inches * next.scale + next.dx.inches),
                        dy: .inches(dy.inches * next.scale + next.dy.inches))
    }
}

extension InkStroke {
    /// The stroke moved and scaled by a transform, its points kept on the ink grid and its width scaled with it, under
    /// the same id (a move) or another (a duplicate).
    public func transformed(by transform: CanvasTransform, id newID: StrokeID? = nil) -> InkStroke {
        InkStroke(id: newID ?? id, tool: tool, colour: colour, width: width * transform.scale,
                  points: points.map { transform.apply($0).onInkGrid })
    }
}

/// What the lasso has selected: strokes and text boxes, by id, each list in ascending order without repeats. A
/// selection is not saved; it lives on the canvas screen and follows undo and redo (#7).
public struct CanvasSelection: Hashable, Sendable {
    public private(set) var strokes: [StrokeID]
    public private(set) var texts: [TextBoxID]

    public init(strokes: [StrokeID] = [], texts: [TextBoxID] = []) {
        self.strokes = Array(Set(strokes)).sorted()
        self.texts = Array(Set(texts)).sorted()
    }

    public static let empty = CanvasSelection()
    public var isEmpty: Bool { strokes.isEmpty && texts.isEmpty }
    public var count: Int { strokes.count + texts.count }
}
