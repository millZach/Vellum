import Foundation

/// What the status bar and the Canvases list say about saving and syncing (#12, Zach's decision 4, variant B of the
/// tag `prototype/sync-status`).
///
/// Saving comes first: while a change is not on the Duo, the status bar says so exactly as before ("Not saved: will
/// retry", in amber). Amber also marks a canvas whose changes are waiting offline, so that wording always starts
/// "Saved": the two never read alike. The status bar's sync wording is never longer than "Saved on this Duo", which it
/// replaces, so every tool prompt (28 characters at most) still shows in full on the Duo's 951 points; the list and
/// VoiceOver say it in full.
public struct SyncStatusLine: Hashable, Sendable {
    public enum Tone: Hashable, Sendable {
        /// Grey: all is well.
        case calm
        /// Amber: a change is not saved on the Duo (ADR-0014).
        case notSaved
        /// Amber, tinted, with a warning sign: saved on the Duo, waiting offline to reach Dropbox.
        case offline
        /// The text colour, with an action beside it: syncing needs Zach (a failure to retry, a sign-in).
        case attention
    }

    public enum Action: Hashable, Sendable {
        case retry, signIn

        public var title: String {
            switch self {
            case .retry: "Retry"
            case .signIn: "Sign in"
            }
        }

        public var accessibilityLabel: String {
            switch self {
            case .retry: "Retry syncing to Dropbox"
            case .signIn: "Sign in to Dropbox"
            }
        }
    }

    public var text: String
    public var tone: Tone
    public var action: Action?
    /// What VoiceOver says, in full.
    public var accessibilityLabel: String

    public init(text: String, tone: Tone, action: Action? = nil, accessibilityLabel: String) {
        self.text = text
        self.tone = tone
        self.action = action
        self.accessibilityLabel = accessibilityLabel
    }

    /// Whether it shows the warning sign: only waiting offline does.
    public var showsWarning: Bool { tone == .offline }

    /// The longest the status bar's wording may be, its action and warning sign counted (a sign as two characters):
    /// "Saved on this Duo", which it replaces.
    public static let longestStatusBar = SaveState.savedOnThisDuo.title.count

    /// How many characters the line takes in the status bar.
    public var statusBarLength: Int { text.count + (action?.title.count ?? 0) + (showsWarning ? 2 : 0) }

    // MARK: The status bar

    /// The canvas screen's status: saving first, then syncing. `edited` is whether the canvas has changed since it was
    /// opened, which Dropbox gets when Zach leaves it.
    public static func statusBar(save: SaveState, sync: CanvasSyncState, edited: Bool, online: Bool) -> SyncStatusLine {
        guard save.isSaved else {
            return SyncStatusLine(text: save.title, tone: save == .neverSaved ? .calm : .notSaved,
                                  accessibilityLabel: save.title)
        }
        switch sync {
        case .off:
            return SyncStatusLine(text: save.title, tone: .calm, accessibilityLabel: save.title)
        case .signedOut:
            return signedOut
        case .failed:
            return failed
        case .waitingForConnection:
            return offline
        case .pending, .uploading:
            return online ? saved : offline
        case .synced:
            if edited { return online ? saved : offline }
            return SyncStatusLine(text: "Synced to Dropbox", tone: .calm,
                                  accessibilityLabel: "Saved on this Duo and synced to Dropbox")
        }
    }

    static let saved = SyncStatusLine(
        text: SaveState.savedOnThisDuo.title, tone: .calm,
        accessibilityLabel: "Saved on this Duo. It syncs to Dropbox when you leave the canvas")
    static let offline = SyncStatusLine(
        text: "Saved · offline", tone: .offline,
        accessibilityLabel: "Saved on this Duo. Offline, so not in Dropbox yet; it syncs when a connection returns")
    static let failed = SyncStatusLine(
        text: "Sync failed", tone: .attention, action: .retry,
        accessibilityLabel: "Saved on this Duo. Sync to Dropbox failed; Vellum will retry")
    static let signedOut = SyncStatusLine(
        text: "Signed out", tone: .attention, action: .signIn,
        accessibilityLabel: "Saved on this Duo. Dropbox is signed out, so nothing syncs until you sign in")

    // MARK: The Canvases list

    /// The note after a canvas's details in the list ("Today 9:41 AM · 17 strokes · waiting for Dropbox"), or nil.
    public static func listNote(_ state: CanvasSyncState) -> SyncStatusLine? {
        switch state {
        case .off, .synced:
            nil
        case .pending:
            SyncStatusLine(text: "waiting to sync", tone: .calm, accessibilityLabel: "Waiting to sync to Dropbox")
        case .uploading:
            SyncStatusLine(text: "uploading…", tone: .calm, accessibilityLabel: "Uploading to Dropbox")
        case .waitingForConnection:
            SyncStatusLine(text: "waiting for Dropbox", tone: .offline,
                           accessibilityLabel: "Saved on this Duo, waiting offline to sync to Dropbox")
        case .failed:
            SyncStatusLine(text: "sync failed · will retry", tone: .attention,
                           accessibilityLabel: "Sync to Dropbox failed; Vellum will retry")
        case .signedOut:
            SyncStatusLine(text: "Dropbox signed out", tone: .attention,
                           accessibilityLabel: "Dropbox is signed out, so this canvas isn't syncing")
        }
    }

    /// The line at the top of the list, or nil. `names` gives a canvas's name by id.
    public static func listBanner(_ report: SyncReport, canvases: [UUID], names: [UUID: String]) -> SyncStatusLine? {
        guard report.available else { return nil }
        if report.signedOut {
            return SyncStatusLine(text: "Dropbox signed out. Your canvases are saved on this Duo and sync once you sign in.",
                                  tone: .attention, action: .signIn,
                                  accessibilityLabel: "Dropbox signed out. Your canvases are saved on this Duo and sync once you sign in.")
        }
        let states = canvases.map { report.state(of: $0) }
        let waiting = states.filter { $0 == .waitingForConnection }.count
        if waiting > 0 {
            let text = waiting == 1
                ? "Offline. 1 canvas isn’t in Dropbox yet. It syncs when a connection returns."
                : "Offline. \(waiting) canvases aren’t in Dropbox yet. They sync when a connection returns."
            return SyncStatusLine(text: text, tone: .offline, accessibilityLabel: text)
        }
        let failedNames = canvases.filter { report.state(of: $0) == .failed }.compactMap { names[$0] }.sorted()
        if !failedNames.isEmpty || states.contains(.failed) {
            let which = failedNames.isEmpty ? "a canvas" : failedNames.map { "“\($0)”" }.joined(separator: ", ")
            let text = "Sync failed for \(which). Vellum will retry."
            return SyncStatusLine(text: text, tone: .attention, action: .retry, accessibilityLabel: text)
        }
        return nil
    }
}
