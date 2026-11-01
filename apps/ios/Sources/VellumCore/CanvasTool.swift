/// The tools on the canvas screen's rail, top to bottom (ADR-0011): pen, highlighter, eraser, line and shape; then
/// lasso and text box; then measure, dimension, frame and window. Tools a later ticket builds are on the rail but
/// disabled, with a hint saying they are coming, so the rail Zach learns now is the rail he keeps.
public enum CanvasTool: String, CaseIterable, Identifiable, Hashable, Sendable {
    case pen
    case highlighter
    case eraser
    case lineAndShape
    case lasso
    case textBox
    case measure
    case dimension
    case frame
    case window

    /// The rail's three groups, top to bottom, with a divider between each.
    public enum Group: CaseIterable, Hashable, Sendable {
        /// Pen, highlighter, eraser, line and shape.
        case ink
        /// Lasso and text box.
        case selectionAndText
        /// Measure, dimension, frame and window: real-world lengths and regions.
        case lengthsAndRegions

        /// The group's tools, in rail order.
        public var tools: [CanvasTool] { CanvasTool.allCases.filter { $0.group == self } }
    }

    /// Everything the rail and status bar show about one tool, kept together so a tool is described in one place.
    public struct Descriptor: Hashable, Sendable {
        public let title: String
        /// The SF Symbol on the rail.
        public let systemImage: String
        public let group: Group
        /// The ticket that builds the tool, while it is still to come; nil once it works.
        public let comingIn: Int?
        /// The ink the tool leaves; nil for the tools that don't leave ink.
        public let inkTool: InkTool?
        /// What the tool expects next, for the status bar.
        public let prompt: String
        /// The accessibility hint, when it says more than the prompt.
        public var help: String? = nil
    }

    public var descriptor: Descriptor {
        switch self {
        case .pen:
            Descriptor(title: "Pen", systemImage: "pencil.tip", group: .ink, comingIn: nil, inkTool: .pen,
                       prompt: "Draw with the Pencil",
                       help: "Draw with the Pencil. Hold still at the end of a stroke to snap it to a line or a shape")
        case .highlighter:
            Descriptor(title: "Highlighter", systemImage: "highlighter", group: .ink, comingIn: nil,
                       inkTool: .highlighter, prompt: "Highlight with the Pencil")
        case .eraser:
            Descriptor(title: "Eraser", systemImage: "eraser", group: .ink, comingIn: nil, inkTool: nil,
                       prompt: "Touch ink to erase a stroke")
        case .lineAndShape:
            Descriptor(title: "Line and shape", systemImage: "line.diagonal", group: .ink, comingIn: nil,
                       inkTool: .pen, prompt: "Draw a line, box or circle",
                       help: "Draw a line, a rectangle or a circle; it straightens when you lift or hold still")
        case .lasso:
            Descriptor(title: "Lasso", systemImage: "lasso", group: .selectionAndText, comingIn: nil, inkTool: nil,
                       prompt: "Circle ink or text to select",
                       help: "Draw a loop around ink or text to select it, then move, resize, duplicate or delete it")
        case .textBox:
            Descriptor(title: "Text box", systemImage: "character.textbox", group: .selectionAndText, comingIn: nil,
                       inkTool: nil, prompt: "Tap where the text box goes",
                       help: "Tap to place a text box or edit one, then type, or write with the Pencil and it becomes text")
        case .measure:
            Descriptor(title: "Measure", systemImage: "ruler", group: .lengthsAndRegions, comingIn: 8, inkTool: nil,
                       prompt: "Measure: tap the first point")
        case .dimension:
            Descriptor(title: "Dimension", systemImage: "arrow.left.and.right", group: .lengthsAndRegions,
                       comingIn: 8, inkTool: nil, prompt: "Dimension: tap the first point")
        case .frame:
            Descriptor(title: "Frame", systemImage: "rectangle.inset.filled", group: .lengthsAndRegions, comingIn: 8,
                       inkTool: nil, prompt: "Tap to place a frame")
        case .window:
            Descriptor(title: "Window", systemImage: "square.dashed", group: .lengthsAndRegions, comingIn: 8,
                       inkTool: nil, prompt: "Drag a window around a region")
        }
    }

    public var id: String { rawValue }
    public var title: String { descriptor.title }
    public var systemImage: String { descriptor.systemImage }
    public var group: Group { descriptor.group }
    public var comingIn: Int? { descriptor.comingIn }
    public var inkTool: InkTool? { descriptor.inkTool }
    public var prompt: String { descriptor.prompt }

    /// The status bar's prompt with Draw with finger on (#24): the pen and highlighter say a finger draws too. The
    /// other tools' prompts don't name what touches the glass, so they are unchanged.
    public func prompt(fingerDraws: Bool) -> String {
        guard fingerDraws else { return prompt }
        switch self {
        case .pen: return "Draw with Pencil or finger"
        case .highlighter: return "Highlight: Pencil or finger"
        default: return prompt
        }
    }

    public var isAvailable: Bool { comingIn == nil }

    /// The status bar's prompt for the lasso while something is selected.
    public static let selectionPrompt = "Drag to move the selection"

    /// The status bar's prompt, given whether the lasso has a selection: with one, it says to drag it.
    public func prompt(fingerDraws: Bool, hasSelection: Bool) -> String {
        if self == .lasso, hasSelection { return Self.selectionPrompt }
        return prompt(fingerDraws: fingerDraws)
    }

    /// The accessibility hint: what the tool does, or that it is not built yet.
    public var hint: String {
        isAvailable ? (descriptor.help ?? prompt) : "Not available yet. \(title) comes in a later update."
    }
}
