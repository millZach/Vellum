import Foundation

/// A marker on a row of the Drawings tab's search (#68, prototype/drawing-search variant B), as
/// `docs/drawing-index-format.md` ("What the Duo's markers read") defines each.
public enum DrawingMarker: String, CaseIterable, Sendable, Hashable {
    /// A DWG with no plot: the laptop plots it when it is first opened (#67, #70).
    case noPDFYet
    /// A PDF with no DWG behind it: it can be marked up but not redlined back to a DWG.
    case pdfOnly
    /// The laptop has not read the file yet: it is online-only there and waits for its download (#66).
    case notReadYet
    /// The Duo is offline and the drawing's PDF has never been downloaded to it, so it can't open now (ADR-0010).
    case notOnThisDuo

    /// The marker's words, as the prototype has them.
    public var text: String {
        switch self {
        case .noPDFYet: "No PDF yet"
        case .pdfOnly: "PDF only · no DWG"
        case .notReadYet: "Not read yet"
        case .notOnThisDuo: "Not on this Duo"
        }
    }

    /// The markers an entry shows. `online` is whether the Duo has a connection now; `pdfsOnThisDuo` the content hashes
    /// of the PDFs kept on the Duo (`SheetPDFs`, named by Dropbox's content hash); `pdfPathsOnThisDuo` the lower-cased
    /// Dropbox paths they were downloaded from (#69), so a PDF opened once is found even when the index's hash is stale
    /// or missing.
    public static func of(_ entry: DrawingEntry, online: Bool, pdfsOnThisDuo: Set<String>,
                          pdfPathsOnThisDuo: Set<String> = []) -> [DrawingMarker] {
        var markers: [DrawingMarker] = []
        if entry.dwg != nil, entry.pdf == nil { markers.append(.noPDFYet) }
        if entry.pdf != nil, entry.dwg == nil { markers.append(.pdfOnly) }
        if entry.dwg?.read == false || entry.pdf?.read == false { markers.append(.notReadYet) }
        if !online, let pdf = entry.pdf, !isOnThisDuo(pdf, pdfsOnThisDuo, pdfPathsOnThisDuo) {
            markers.append(.notOnThisDuo)
        }
        return markers
    }

    /// Whether an entry's PDF is kept on the Duo: by the index's hash, or by the path it was downloaded from.
    static func isOnThisDuo(_ pdf: DrawingEntry.PDF, _ hashes: Set<String>, _ paths: Set<String>) -> Bool {
        if let hash = pdf.contentHash, hashes.contains(SheetPDFs.keptName(contentHash: hash, rev: "")) { return true }
        return paths.contains(pdf.path.lowercased())
    }
}

/// What a row of the Drawings tab says about an entry (#68): its number and title, then rev, scale and date, then its
/// project. An entry whose DWG or PDF the laptop has not read yet (`read: false`, an online-only file waiting for its
/// download) is a quiet row: its file name, then its path, and none of its fields, even a number taken from its name.
public struct DrawingRowText: Equatable, Sendable {
    /// The drawing number, or nil.
    public var number: String?
    /// The title, or the file name when there is no title.
    public var title: String
    /// `Rev A · 1/4" = 1'-0" · 2026-10-02`, with only the parts the entry has; nil when it has none.
    public var details: String?
    /// The project, else the folder; for a quiet row, the path.
    public var place: String
    /// Its DWG or PDF not read yet: shown quietly, by file name and path.
    public var quiet: Bool

    public init(number: String?, title: String, details: String?, place: String, quiet: Bool) {
        self.number = number
        self.title = title
        self.details = details
        self.place = place
        self.quiet = quiet
    }

    public init(_ entry: DrawingEntry) {
        quiet = entry.dwg?.read == false || entry.pdf?.read == false
        if quiet {
            number = nil
            title = entry.name
            details = nil
            place = entry.path
            return
        }
        number = entry.number
        title = entry.title ?? entry.name
        var parts: [String] = []
        if let revision = entry.revision { parts.append("Rev \(revision)") }
        if let scale = entry.scale { parts.append(scale) }
        if let date = entry.date { parts.append(date) }
        details = parts.isEmpty ? nil : parts.joined(separator: " · ")
        let folder = entry.folder ?? String(entry.path.prefix(upTo: entry.path.lastIndex(of: "/") ?? entry.path.endIndex))
        place = entry.project ?? (folder.isEmpty ? "/" : folder)
    }
}
