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
