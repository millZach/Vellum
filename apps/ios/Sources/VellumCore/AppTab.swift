/// The four places the iOS tab bar leads to, in the order they appear (ADR-0011).
public enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case canvases
    case drawings
    case jobs
    case meetings

    public var id: String { rawValue }

    /// The tab's name in the tab bar.
    public var title: String {
        switch self {
        case .canvases: "Canvases"
        case .drawings: "Drawings"
        case .jobs: "Jobs"
        case .meetings: "Meetings"
        }
    }

    /// The SF Symbol the tab bar shows beside the title.
    public var systemImage: String {
        switch self {
        case .canvases: "pencil.and.outline"
        case .drawings: "doc.text.magnifyingglass"
        case .jobs: "paperplane"
        case .meetings: "waveform"
        }
    }

    /// One line saying what the tab will hold, shown until it is built.
    public var placeholder: String {
        switch self {
        case .canvases: "Your canvases will be listed here."
        case .drawings: "Search the drawing index for any drawing in Dropbox."
        case .jobs: "Jobs you send to Sotto, and what their threads return."
        case .meetings: "Meetings you record, with their transcripts and summaries."
        }
    }
}
