/// The four places the iOS tab bar leads to, in the order they appear (ADR-0011).
public enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case canvases
    case drawings
    case jobs
    case meetings

    /// What the tab bar and the tab's empty screen show for one tab.
    public struct Descriptor: Sendable, Equatable {
        /// The tab's name in the tab bar.
        public let title: String
        /// The SF Symbol the tab bar shows beside the title.
        public let systemImage: String
        /// One line saying what the tab will hold, shown until it is built.
        public let placeholder: String
    }

    public var id: String { rawValue }

    public var descriptor: Descriptor {
        switch self {
        case .canvases:
            Descriptor(title: "Canvases", systemImage: "pencil.and.outline",
                       placeholder: "Your canvases will be listed here.")
        case .drawings:
            Descriptor(title: "Drawings", systemImage: "doc.text.magnifyingglass",
                       placeholder: "Search the drawing index for any drawing in Dropbox.")
        case .jobs:
            Descriptor(title: "Jobs", systemImage: "paperplane",
                       placeholder: "Jobs you send to Sotto, and what their threads return.")
        case .meetings:
            Descriptor(title: "Meetings", systemImage: "waveform",
                       placeholder: "Meetings you record, with their transcripts and summaries.")
        }
    }
}
