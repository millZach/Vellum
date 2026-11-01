/// The pen in Zach's hand: the tool picked on the rail, the markup colour, and the line weight each pen is set to.
/// These can change at any moment, with the other hand, while the Pencil is down; a stroke takes what they were when
/// it started (`beginStroke`), so what it commits is what Zach saw as he drew.
public struct PenSettings: Hashable, Sendable {
    public var tool: CanvasTool
    public var colour: MarkupColour
    public var weights: [InkTool: LineWeight]

    public init(tool: CanvasTool = .pen, colour: MarkupColour = .red,
                weights: [InkTool: LineWeight] = [.pen: .default, .highlighter: .default]) {
        self.tool = tool
        self.colour = colour
        self.weights = weights
    }

    /// The line weight a pen is set to.
    public func weight(for ink: InkTool) -> LineWeight { weights[ink] ?? .default }

    /// The weight of the tool in hand, if it leaves ink; setting it on a tool that doesn't does nothing.
    public var weight: LineWeight {
        get { tool.inkTool.map(weight(for:)) ?? .default }
        set { if let ink = tool.inkTool { weights[ink] = newValue } }
    }

    /// Starts a stroke where the Pencil touched down, fixing its pen, colour and real-world width now: the chosen
    /// screen weight at the zoom it is drawn at (ADR-0012). Nil when the tool in hand leaves no ink.
    public func beginStroke(at point: CanvasPoint, pointsPerInch: Double) -> StrokeInProgress? {
        guard let ink = tool.inkTool else { return nil }
        return StrokeInProgress(tool: ink, colour: colour,
                                width: .inches(weight(for: ink).screenWidth(for: ink) / pointsPerInch), start: point)
    }
}

/// A stroke while the Pencil is still down: its pen, colour and width were fixed at touchdown and do not change, only
/// its points grow. `InkSession.commit` turns it into ink when the Pencil lifts.
public struct StrokeInProgress: Hashable, Sendable {
    public let tool: InkTool
    public let colour: MarkupColour
    public let width: Length
    public private(set) var points: [CanvasPoint]

    public init(tool: InkTool, colour: MarkupColour, width: Length, start: CanvasPoint) {
        self.tool = tool
        self.colour = colour
        self.width = width
        points = [start]
    }

    /// Adds a sample unless it lies closer than `spacing` to the last one, which thins the Pencil's many samples
    /// without changing the line.
    public mutating func add(_ point: CanvasPoint, spacing: Length = .zero) {
        if let last = points.last, last.distance(to: point) < spacing { return }
        points.append(point)
    }

    /// Adds the Pencil's last sample whatever its spacing, so the stroke ends exactly where the Pencil lifted.
    public mutating func end(at point: CanvasPoint) {
        if points.last != point { points.append(point) }
    }
}
