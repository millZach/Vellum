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
