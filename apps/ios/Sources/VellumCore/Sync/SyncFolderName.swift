import Foundation

/// Where canvases live in Zach's Dropbox (#12): `Dropbox/Vellum/<name> <short id>`, which the laptop's Dropbox
/// mirrors to its disk.
public enum SyncPaths {
    /// The Dropbox folder every canvas folder is in.
    public static let root = "/Vellum"
    /// Where a deleted canvas's folder is moved to, so a wrong delete can be recovered (Zach, on #9).
    public static let deleted = "/Vellum/.deleted"

    public static func folder(_ name: String) -> String { "\(root)/\(name)" }
}

/// A canvas's Dropbox folder name: its name when it was made, made safe for Dropbox and for Windows (the laptop's
/// Dropbox writes every name to an NTFS disk), and the first characters of its id, so two canvases of one name never
/// share a folder. It is fixed when the canvas is made and never follows a rename, so the laptop's paths stay put; the
/// current name lives in `canvas.json`.
public enum SyncFolderName {
    /// The longest a name's part of the folder name may be, in characters and in UTF-8 bytes, so the laptop's full
    /// path (`C:\Users\…\Dropbox\Vellum\<folder>\ink.log.parts\12\000001234567.part`) stays well inside Windows' 260.
    public static let maximumCharacters = 60
    public static let maximumBytes = 180
    /// The short id's length: "7f3a". Lengthened only when another canvas's folder already has the name.
    public static let shortIDLength = 4

    /// Characters Windows refuses in a file name, which Dropbox then can't put on the laptop.
    static let refused: Set<Character> = ["/", "\\", "<", ">", ":", "\"", "|", "?", "*"]

    /// The folder name for a canvas named `name` with id `id`, unlike every name in `taken` (compared as Dropbox
    /// does, ignoring case).
    public static func make(name: String, id: UUID, taken: Set<String> = []) -> String {
        let safe = safeName(name)
        let hex = id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let takenLowered = Set(taken.map { $0.lowercased() })
        var length = shortIDLength
        while true {
            let candidate = "\(safe) \(hex.prefix(length))"
            if !takenLowered.contains(candidate.lowercased()) || length >= hex.count { return candidate }
            length += 2
        }
    }

    /// A canvas's name as Dropbox and Windows will take it: the refused characters and control characters become
    /// "-", runs of white space one space, leading dots go (no hidden folders, and never `.deleted`), it is cut to
    /// `maximumCharacters` and `maximumBytes`, and trailing dots and spaces go, which Windows drops. Nothing left
    /// becomes "Canvas".
    public static func safeName(_ name: String) -> String {
        var out = ""
        var lastWasSpace = false
        for character in name.precomposedStringWithCanonicalMapping {
            if character.isWhitespace || character.isNewline {
                if !lastWasSpace && !out.isEmpty { out.append(" ") }
                lastWasSpace = true
                continue
            }
            lastWasSpace = false
            if refused.contains(character) || character.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                out.append("-")
            } else {
                out.append(character)
            }
        }
        while out.first == "." || out.first == " " { out.removeFirst() }
        var cut = ""
        for character in out {
            guard cut.count < maximumCharacters, cut.utf8.count + String(character).utf8.count <= maximumBytes else { break }
            cut.append(character)
        }
        while cut.last == "." || cut.last == " " { cut.removeLast() }
        return cut.isEmpty ? "Canvas" : cut
    }
}
