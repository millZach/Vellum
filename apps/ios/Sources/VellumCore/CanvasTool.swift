/// The tools on the canvas screen's rail, top to bottom (ADR-0011): pen, highlighter, eraser, line and shape, symbols; then
/// select, lasso and text box; then measure, dimension, frame and window. Every one works since #8; a tool a later ticket
/// adds goes on the rail disabled, with a hint saying it is coming, so the rail Zach learns is the rail he keeps.
public enum CanvasTool: String, CaseIterable, Identifiable, Hashable, Sendable {
    case pen
    case highlighter
    case eraser
    case lineAndShape
    case symbols
    case select
    case lasso
    case textBox
    case measure
    case dimension
    case frame
    case window

    /// The rail's three groups, top to bottom, with a divider between each.
    public enum Group: CaseIterable, Hashable, Sendable {
        /// Pen, highlighter, eraser, line and shape, and symbols (#41).
        case ink
        /// Select, lasso and text box.
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
                       help: "Draw a line, a rectangle or a circle; it straightens when you lift or hold still. "
                           + "Tap it again to pick a shape and the line weight")
        case .symbols:
            Descriptor(title: "Symbols", systemImage: "square.on.circle", group: .ink, comingIn: nil, inkTool: nil,
                       prompt: Self.symbolsPrompt,
                       help: "Tap the canvas to place the symbol picked, at its printed size at the scale under the tap. "
                           + "Tap Symbols again to pick another from the library")
        case .select:
            Descriptor(title: "Select", systemImage: "cursorarrow", group: .selectionAndText, comingIn: nil,
                       inkTool: nil, prompt: Self.selectPrompt,
                       help: "Tap a stroke, text box, dimension, frame or sheet to select it, and tap another to add it. "
                           + "Drag to move it. Tap empty canvas to let go. Loop round several with the Lasso")
        case .lasso:
            Descriptor(title: "Lasso", systemImage: "lasso", group: .selectionAndText, comingIn: nil, inkTool: nil,
                       prompt: "Loop ink, or tap a sheet",
                       help: "Draw a loop around ink or text to select it, then move, resize, duplicate or delete it. "
                           + "Tap a sheet to turn it, move it or change its scale")
        case .textBox:
            Descriptor(title: "Text box", systemImage: "character.textbox", group: .selectionAndText, comingIn: nil,
                       inkTool: nil, prompt: "Tap to place a text box",
                       help: "Tap to place a text box or edit one, then type, or write with the Pencil and it becomes text")
        case .measure:
            Descriptor(title: "Measure", systemImage: "ruler", group: .lengthsAndRegions, comingIn: nil, inkTool: nil,
                       prompt: "Measure: tap first point",
                       help: "Tap two points to read the length between them in the canvas units. A tap snaps to "
                           + "the nearest end, corner, centre, mid, intersection, perpendicular or tangent, named in a "
                           + "magnifier while you touch")
        case .dimension:
            Descriptor(title: "Dimension", systemImage: "arrow.left.and.right", group: .lengthsAndRegions,
                       comingIn: nil, inkTool: nil, prompt: "Dimension: tap first point",
                       help: "Tap two points, then drag or tap where the dimension line goes: above or below for "
                           + "horizontal, beside for vertical, out at an angle for aligned. It stays on the canvas")
        case .frame:
            Descriptor(title: "Frame", systemImage: "rectangle.inset.filled", group: .lengthsAndRegions, comingIn: nil,
                       inkTool: nil, prompt: "Drag a box for a frame",
                       help: "Pick a paper size, then drag a box round what the frame takes in. Vellum picks the "
                           + "drawing scale whose paper covers it")
        case .window:
            Descriptor(title: "Window", systemImage: "square.dashed", group: .lengthsAndRegions, comingIn: nil,
                       inkTool: nil, prompt: "Drag a window over a region",
                       help: "Drag a box round a region, then zoom to it or make a frame from it")
        }
    }

    /// Where a measure, dimension or window is up to, for the status bar's prompt (#8).
    public enum Step: Hashable, Sendable {
        /// Nothing started: the tool's own prompt.
        case start
        /// A measure or dimension has its first point and waits for the second.
        case secondPoint
        /// A dimension has both points and waits for the third, which pulls its line off them.
        case pullOff
        /// A window is drawn and waits for what to do with it.
        case chooseWindowAction
        /// A sheet confirmed in Add sheet waits, as a true-size outline, for a tap where it goes (#11). It belongs to no
        /// tool: whatever is in hand, the next tap places the sheet.
        case placeSheet
        /// A selected sheet is being twisted, at this angle in degrees (#44).
        case turningSheet(Double)
        /// A selected sheet's twist has caught on this quarter turn (#44).
        case caughtSheet(Double)
        /// A shape part way through being drawn, with what it waits for (`ShapeDraft.prompt`, #40).
        case drawing(String)
        /// A word for a moment about what the Pencil just did, such as Select's drag on empty canvas (#64). It goes
        /// before whatever the selection would say.
        case hint(String)
    }

    /// The status bar's prompt part way through a measure, dimension or window.
    public static func prompt(for step: Step) -> String? {
        switch step {
        case .start: nil
        case .secondPoint: "Tap the second point"
        case .pullOff: "Drag or tap to place line"
        case .chooseWindowAction: "Zoom or make a frame"
        case .placeSheet: Self.placeSheetPrompt
        case .turningSheet(let angle): "Turning: \(SheetAngle.reading(angle))"
        case .caughtSheet(let angle): "Caught at \(SheetAngle.reading(angle))"
        case .drawing(let prompt): prompt
        case .hint(let hint): hint
        }
    }

    /// The status bar's prompt while a sheet waits to be placed, whatever the tool.
    public static let placeSheetPrompt = "Tap where the sheet goes"

    /// What VoiceOver says while a sheet waits to be placed.
    public static let placeSheetHint = "Tap the canvas where the sheet's centre goes. Pan and pinch to find the spot first"

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

    /// Whether the tool picks things up: Select and the lasso, which share a selection, so taking one from the other keeps
    /// it (#64). Any other tool lets go of it.
    public var selects: Bool { self == .select || self == .lasso }

    /// The status bar's prompt for Symbols (#41): a tap places the symbol picked.
    public static let symbolsPrompt = "Tap to place the symbol"

    /// The status bar's prompt for Symbols with a symbol picked, 28 characters or fewer: `Tap to place: Gate valve`, or
    /// the plain prompt when the name won't fit.
    public static func symbolsPrompt(named name: String) -> String {
        let prompt = "Tap to place: " + name
        return prompt.count <= 28 ? prompt : symbolsPrompt
    }

    /// The status bar's prompt while a bubble's tag is typed (#41).
    public static let tagPrompt = "Type the tag, or keep it"

    /// The status bar's prompt for Select with nothing selected (#64).
    public static let selectPrompt = "Tap anything to select it"

    /// What the status bar says for a moment after a drag with Select on empty canvas (#64), which does nothing: Select
    /// takes one thing a tap, and the lasso loops round many. Each hint fits the status bar's 28 characters.
    public static let selectDragHint = "Loop several with the Lasso"

    /// What the status bar says for a moment after a drag with Select on a sheet that isn't selected (#64).
    public static let selectSheetDragHint = "Tap the sheet, then drag it"

    /// The status bar's prompt for the lasso while something is selected.
    public static let selectionPrompt = "Drag the selection"

    /// The status bar's prompt for the lasso or Select while a sheet is selected (#44): as long as the longest prompt it stands
    /// beside, so the sheet and frame count keeps its room.
    public static let sheetSelectedPrompt = "Twist or drag the sheet"

    /// The status bar's prompt, given whether the lasso or Select has a selection: with one, it says to drag it; and, for a
    /// measure, dimension or window part way through, what it waits for next (#8); and for the line and shape tool, what the
    /// shape picked expects (#40).
    public func prompt(fingerDraws: Bool, hasSelection: Bool, hasSheet: Bool = false, shape: LineShape = .default,
                       step: Step = .start) -> String {
        if step == .placeSheet { return Self.placeSheetPrompt }
        if case .hint(let hint) = step { return hint }
        if selects, hasSheet {
            switch step {
            case .turningSheet, .caughtSheet: return Self.prompt(for: step) ?? Self.sheetSelectedPrompt
            default: return Self.sheetSelectedPrompt
            }
        }
        if selects, hasSelection { return Self.selectionPrompt }
        if let next = Self.prompt(for: step) { return next }
        if self == .lineAndShape { return shape.prompt }
        return prompt(fingerDraws: fingerDraws)
    }

    /// The accessibility hint: what the tool does, or that it is not built yet.
    public var hint: String {
        isAvailable ? (descriptor.help ?? prompt) : "Not available yet. \(title) comes in a later update."
    }
}
