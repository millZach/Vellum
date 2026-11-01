/// Whether a canvas's changes are saved on the Duo (ADR-0003, ADR-0013), as the status bar says it. Syncing to Dropbox
/// is #12; until it is built nothing here claims a canvas is anywhere but on this Duo.
public enum SaveState: Hashable, Sendable {
    /// Every change is written to the Duo's storage.
    case savedOnThisDuo
    /// A change is still being written. The status bar only shows this when writing takes long enough to notice.
    case saving
    /// Writing failed; the changes are kept in memory and written with the next change. `outOfSpace` says why when
    /// it is the Duo being full.
    case notSaved(outOfSpace: Bool)

    public var title: String {
        switch self {
        case .savedOnThisDuo: "Saved on this Duo"
        case .saving: "Saving…"
        case .notSaved(let outOfSpace): outOfSpace ? "Not saved: this Duo is full" : "Not saved: will retry"
        }
    }

    /// Whether everything is on the Duo's storage.
    public var isSaved: Bool { self == .savedOnThisDuo }
}
