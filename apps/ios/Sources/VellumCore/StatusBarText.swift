/// What the status bar shows and how much room it keeps for it (#33). The pen's position is 11 pt monospaced, so its
/// width is a count of characters.
public enum StatusBarText {
    /// The characters kept for the pen's position at first: any position under 100' either way in feet and inches,
    /// such as `X -99'-11 15/16"  Y -99'-11 15/16"`.
    public static let usualPositionCharacters = 31

    /// The characters for a position of three-digit feet, `X -139'-11 15/16"  Y -139'-11 15/16"`.
    public static let longPositionCharacters = 36

    /// The characters to keep once a position of `showing` characters has been shown, given those kept so far. It only
    /// grows, and goes straight to the long width, so the neighbours move at most about once however the pen moves,
    /// never once per sample.
    public static func reservedCharacters(_ reserved: Int, showing: Int) -> Int {
        showing <= reserved ? reserved : max(longPositionCharacters, showing)
    }

    /// The sheet and frame count, longest first: the status bar shows the first that fits, so the words give way before
    /// the pen's position or the tool's prompt lose anything.
    public static func counts(sheets: Int, frames: Int) -> [String] {
        [
            "\(sheets) sheet\(sheets == 1 ? "" : "s") · \(frames) frame\(frames == 1 ? "" : "s")",
            "\(sheets) sh · \(frames) fr",
            "\(sheets) · \(frames)",
        ]
    }
}
