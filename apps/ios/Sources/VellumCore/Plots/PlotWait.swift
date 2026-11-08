import Foundation

/// Where a plot the Duo asked for has got to, as the row and the drawing viewer show it (#70, prototype/drawing-search
/// variant B). Decided in one place (`PlotStage.of`) from what the Duo knows: whether the request is in Dropbox yet,
/// the laptop's latest answer, the check-in's age, the connection, and whether the PDF is on the Duo.
public enum PlotStage: Hashable, Sendable {
    /// Offline, and the request not uploaded yet: it waits in the sync outbox on this Duo.
    case queuedOnThisDuo
    /// The request is going to Dropbox, or is there with no answer yet, the laptop seen lately.
    case asking
    /// The laptop has the request, `queued` or `plotting`, and was seen lately.
    case plotting
    /// The laptop's check-in is older than `PlotRequestFormat.staleAfter`, or there is none: the laptop is off. `lastSeen`
    /// is the check-in's `server_modified`, nil when the laptop has never checked in.
    case waitingForLaptop(lastSeen: Date?)
    /// The laptop plotted it, and its PDF is coming down.
    case downloading
    /// The laptop plotted it, but the Duo is offline, so its PDF downloads when it is back online.
    case plottedOffline
    /// The PDF is on the Duo.
    case done
    /// The laptop won't plot it, for this reason, in its own words. Asking again is a new request.
    case failed(reason: String)

    /// Decides the stage. `sent` is whether the request is in Dropbox; `answer` the laptop's latest answer read;
    /// `checkedIn` the check-in's `server_modified` when it was last looked at (nil when there is none, or it hasn't
    /// been looked at yet and `checkInKnown` is false); `pdfKept` whether the plot's PDF is on the Duo.
    public static func of(sent: Bool, answer: PlotAnswer?, checkedIn: Date?, checkInKnown: Bool, online: Bool,
                          pdfKept: Bool, now: Date) -> PlotStage {
        if pdfKept { return .done }
        if let answer {
            switch answer.state {
            case .failed:
                return .failed(reason: answer.reason.map(PlotAnswer.sentence) ?? "The laptop couldn't plot it.")
            case .done:
                return online ? .downloading : .plottedOffline
            case .queued, .plotting:
                break
            }
        }
        if !sent { return online ? .asking : .queuedOnThisDuo }
        if checkInKnown, isStale(checkedIn: checkedIn, now: now) { return .waitingForLaptop(lastSeen: checkedIn) }
        return answer == nil ? .asking : .plotting
    }

    /// The staleness rule: the laptop is off when its check-in is older than `PlotRequestFormat.staleAfter`, or there is
    /// none. At exactly the limit it still counts as seen.
    public static func isStale(checkedIn: Date?, now: Date) -> Bool {
        guard let checkedIn else { return true }
        return now.timeIntervalSince(checkedIn) > PlotRequestFormat.staleAfter
    }

    /// Whether the plot is still to come: the Duo keeps looking.
    public var isWaiting: Bool {
        switch self {
        case .done, .failed: false
        default: true
        }
    }

    /// The row's words, as the prototype's plot tag has them.
    public var shortText: String {
        switch self {
        case .queuedOnThisDuo: "Queued on this Duo"
        case .asking: "Asking the laptop…"
        case .plotting: "Plotting on the laptop…"
        case .waitingForLaptop: "Waiting for the laptop"
        case .downloading: "Downloading the PDF…"
        case .plottedOffline: "Plotted · downloads when online"
        case .done: "PDF plotted"
        case .failed: "Couldn't plot"
        }
    }

    /// The prototype's three steps while plotting: asked (0), plotting (1), downloading the PDF (2); nil outside them.
    public var step: Int? {
        switch self {
        case .asking: 0
        case .plotting: 1
        case .downloading: 2
        default: nil
        }
    }

    /// The row's words for an entry with no PDF that nobody has asked for yet.
    public static let notAskedText = "No PDF yet · plots on open"

    /// "a moment ago", "12 min ago", "3 h ago", "2 days ago": how long ago the laptop was last seen, as the prototype's
    /// Waiting for the laptop says it.
    public static func lastSeenText(_ lastSeen: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(lastSeen))
        if seconds < 60 { return "a moment ago" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 48 { return "\(hours) h ago" }
        return "\(Int((seconds / 86400).rounded())) days ago"
    }
}

/// What the app shows for one drawing index entry's plot.
public struct PlotProgress: Hashable, Sendable {
    /// The entry's id.
    public var entry: String
    /// The request's own id.
    public var request: String
    public var stage: PlotStage
    /// The plot, once the laptop has said where it is: its Dropbox path and content hash.
    public var pdfPath: String?
    public var contentHash: String?
    /// The name the PDF is kept under on the Duo (`SheetPDFs`), once it is.
    public var keptName: String?
    /// The laptop's warning or fallback line (`PlotAnswer.note`), shown in one short line with the PDF.
    public var note: String?

    public init(entry: String, request: String, stage: PlotStage, pdfPath: String? = nil, contentHash: String? = nil,
                keptName: String? = nil, note: String? = nil) {
        self.entry = entry
        self.request = request
        self.stage = stage
        self.pdfPath = pdfPath
        self.contentHash = contentHash
        self.keptName = keptName
        self.note = note
    }
}
