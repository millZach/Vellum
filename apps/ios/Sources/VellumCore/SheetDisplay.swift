/// How a sheet's PDF is shown (ADR-0011). In light mode a sheet shows as printed. In dark mode it is inverted to light
/// linework on dark paper, the way AutoCAD shows model space, unless it inverts badly (a coloured or scanned PDF), when
/// it still shows as printed: white paper and its true colours on the dark canvas (#100).
public enum SheetDisplay: String, Hashable, Sendable {
    case asPrinted
    case inverted

    public static func display(dark: Bool, invertsBadly: Bool) -> SheetDisplay {
        guard dark, !invertsBadly else { return .asPrinted }
        return .inverted
    }

    /// Whether the sheet's paper is drawn light, so sketch ink over it stays dark (`MarkupColour.rgb`).
    public var paperIsLight: Bool { self != .inverted }

    /// The sheets whose paper shows light in dark mode (those drawn as printed, #11, #100), for the colour of markup
    /// over them. Empty in light mode, where the canvas is light anyway.
    public static func lightPaper(_ sheets: [Sheet], dark: Bool) -> [Sheet] {
        dark ? sheets.filter { display(dark: dark, invertsBadly: $0.invertsBadly).paperIsLight } : []
    }

    /// Whether markup starting at a point lies over light paper: the point is on one of `lightPaper`'s sheets. Ink starts
    /// at its first point, a text box at its top-left corner and a dimension at its first point.
    public static func isOverLightPaper(_ point: CanvasPoint?, in lightPaper: [Sheet]) -> Bool {
        guard let point, !lightPaper.isEmpty else { return false }
        return lightPaper.contains { $0.contains(point) }
    }
}
