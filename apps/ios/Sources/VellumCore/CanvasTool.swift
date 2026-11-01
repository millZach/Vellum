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

    public var id: String { rawValue }

    /// Which of the rail's three groups the tool sits in: ink, selection and text, then real-world lengths and regions.
    public var group: Int {
        switch self {
        case .pen, .highlighter, .eraser, .lineAndShape: 0
        case .lasso, .textBox: 1
        case .measure, .dimension, .frame, .window: 2
        }
    }

    public var title: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lineAndShape: "Line and shape"
        case .lasso: "Lasso"
        case .textBox: "Text box"
        case .measure: "Measure"
        case .dimension: "Dimension"
        case .frame: "Frame"
        case .window: "Window"
        }
    }

    /// The SF Symbol on the rail.
    public var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lineAndShape: "line.diagonal"
        case .lasso: "lasso"
        case .textBox: "character.textbox"
        case .measure: "ruler"
        case .dimension: "arrow.left.and.right"
        case .frame: "rectangle.inset.filled"
        case .window: "square.dashed"
        }
    }

    /// The ticket that builds the tool, while it is still to come; nil once it works.
    public var comingIn: Int? {
        switch self {
        case .pen, .highlighter, .eraser: nil
        case .lineAndShape, .lasso, .textBox: 7
        case .measure, .dimension, .frame, .window: 8
        }
    }

    public var isAvailable: Bool { comingIn == nil }

    /// The ink a drawing tool leaves; nil for the tools that don't leave ink.
    public var inkTool: InkTool? {
        switch self {
        case .pen: .pen
        case .highlighter: .highlighter
        default: nil
        }
    }

    /// The accessibility hint: what the tool does, or that it is not built yet.
    public var hint: String {
        isAvailable ? prompt : "Not available yet. \(title) comes in a later update."
    }

    /// What the tool expects next, for the status bar.
    public var prompt: String {
        switch self {
        case .pen: "Draw with the Pencil"
        case .highlighter: "Highlight with the Pencil"
        case .eraser: "Touch ink to erase a stroke"
        case .lineAndShape: "Draw a straight line"
        case .lasso: "Circle ink or text to select it"
        case .textBox: "Tap where the text box goes"
        case .measure: "Measure: tap the first point"
        case .dimension: "Dimension: tap the first point"
        case .frame: "Tap to place a frame"
        case .window: "Drag a window around a region"
        }
    }
}

/// Whether Vellum follows the Duo's light or dark setting or is pinned to one (ADR-0011).
public enum AppearanceSetting: String, CaseIterable, Identifiable, Hashable, Sendable {
    case system
    case light
    case dark

    public static let `default` = AppearanceSetting.system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Whether the canvas is dark, given whether the Duo is.
    public func isDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .system: systemIsDark
        case .light: false
        case .dark: true
        }
    }
}

/// How a sheet's PDF is shown (ADR-0011). In light mode a sheet shows as printed. In dark mode it is inverted to light
/// linework on dark paper, the way AutoCAD shows model space, unless it inverts badly (a coloured or scanned PDF),
/// when it is dimmed instead. Sheets arrive in #11; this is the rule they will be drawn by.
public enum SheetDisplay: String, Hashable, Sendable {
    case asPrinted
    case inverted
    case dimmed

    public static func display(dark: Bool, invertsBadly: Bool) -> SheetDisplay {
        guard dark else { return .asPrinted }
        return invertsBadly ? .dimmed : .inverted
    }

    /// Whether the sheet's paper is drawn light, so sketch ink over it stays dark (`MarkupColour.rgb`).
    public var paperIsLight: Bool { self != .inverted }
}

/// Whether a canvas is saved on the Duo and synced to Dropbox (ADR-0003). Saving is #9; until then ink lives only in
/// memory and the status bar says so.
public enum SaveState: Hashable, Sendable {
    case notSavedYet

    public var title: String {
        switch self {
        case .notSavedYet: "Not saved yet"
        }
    }
}
