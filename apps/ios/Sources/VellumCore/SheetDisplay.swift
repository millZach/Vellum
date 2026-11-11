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
}
