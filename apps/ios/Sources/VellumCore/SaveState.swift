/// Whether a canvas's changes are saved on the Duo (ADR-0003, ADR-0014), as the status bar says it. Syncing to Dropbox
/// is #12; until it is built nothing here claims a canvas is anywhere but on this Duo.
public enum SaveState: Hashable, Sendable {
    /// Every change is written to the Duo's storage.
    case savedOnThisDuo
    /// A change is still being written. The status bar only shows this when writing takes long enough to notice.
    case saving
    /// Writing or flushing failed; the canvas saver keeps the changes in memory and keeps trying, even after the canvas
    /// is closed, until they are written. `outOfSpace` says why when it is the Duo being full.
    case notSaved(outOfSpace: Bool)
    /// A canvas kept only in memory and never written: the made-up test canvas (#21). Nothing drawn on it is kept.
    case neverSaved

    public var title: String {
        switch self {
        case .savedOnThisDuo: "Saved on this Duo"
        case .saving: "Saving…"
        case .notSaved(let outOfSpace): outOfSpace ? "Not saved: this Duo is full" : "Not saved: will retry"
        case .neverSaved: "Test canvas: never saved"
        }
    }

    /// Whether everything is on the Duo's storage.
    public var isSaved: Bool { self == .savedOnThisDuo }
}
