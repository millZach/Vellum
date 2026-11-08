/// Opening a drawing found in the Drawings tab's search (#69, prototype/drawing-search variant B): which PDF the drawing
/// viewer shows, whether it can open now, the drawing scale its index entry gives, what a new canvas made from it is
/// called, and the sheet it becomes when it is placed. The viewer and both of its ways to a canvas, Place on a canvas
/// and Open in a new canvas, decide here, so the tests hold every rule the Duo follows.
public enum DrawingOpening {
    /// The PDF the viewer shows for an entry: its own `pdf`, so each layout of a DWG with several titled layouts opens
    /// its own plot, never another layout's.
    public struct PDF: Hashable, Sendable {
        /// Its Dropbox path.
        public var path: String
        /// Its file name, as a placed sheet's page names it.
        public var name: String
        /// Dropbox's content hash when the laptop read it, which names the PDF kept on the Duo; nil while unread.
        public var contentHash: String?
        /// Its size in bytes, when the index knows it.
        public var size: Int?
        /// Its page count, when the index knows it.
        public var pages: Int?
        /// Whether it is a plot the laptop fitted to the page, not to scale (#92), from the index or the plot's answer:
        /// it is placed as an NTS sheet.
        public var fitted: Bool

        public init(path: String, name: String, contentHash: String?, size: Int?, pages: Int?, fitted: Bool = false) {
            self.path = path
            self.name = name
            self.contentHash = contentHash
            self.size = size
            self.pages = pages
            self.fitted = fitted
        }

        /// The name it is kept under on the Duo, when the index gives its hash.
        public var keptName: String? { contentHash.map { SheetPDFs.keptName(contentHash: $0, rev: "") } }
    }

    /// The entry's PDF, or nil for a DWG with no plot yet (or an entry with neither file).
    public static func pdf(for entry: DrawingEntry) -> PDF? {
        guard let pdf = entry.pdf else { return nil }
        let name = pdf.path.split(separator: "/").last.map(String.init) ?? pdf.path
        return PDF(path: pdf.path, name: name, contentHash: pdf.contentHash, size: pdf.size, pages: pdf.pages,
                   fitted: pdf.fitted == true)
    }

    /// The plot the Duo has of a DWG the index lists with no PDF yet (#70), as the PDF to show, once it is done.
    public static func pdf(plotted plot: PlotProgress) -> PDF? {
        guard plot.stage == .done, let path = plot.pdfPath else { return nil }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return PDF(path: path, name: name, contentHash: plot.contentHash, size: nil, pages: nil, fitted: plot.fitted)
    }

    /// The viewer's one line about the PDF shown: the plot's own note while the PDF is that plot, else for a plot the
    /// index marks fitted, "Plotted to fit, not to scale" (#92).
    public static func note(for pdf: PDF?, plot: PlotProgress?) -> String? {
        if let note = plot?.note(forPDFAt: pdf?.path) { return note }
        return pdf?.fitted == true ? PlotAnswer.fittedNote : nil
    }

    /// What a tap on a row does.
    public enum Decision: Hashable, Sendable {
        /// The PDF is on the Duo: open it from there, with no download.
        case openKept(PDF)
        /// Online, and not on the Duo yet: download it once, then open it.
        case download(PDF)
        /// Offline, and never opened on this Duo: the viewer doesn't open, and says why (ADR-0010).
        case notOnThisDuo(PDF)
        /// A DWG with no plot: nothing to open until the laptop plots it (#70).
        case noPDFYet
    }

    /// Decides a tap. `pdfsOnThisDuo` holds the kept names of the PDFs in `SheetPDFs`, as `DrawingMarker` reads them, so
    /// the viewer refuses exactly the rows marked "Not on this Duo".
    /// `pdfPathsOnThisDuo` holds the lower-cased Dropbox paths those PDFs came from (`SheetPDFs.keptPaths()`), so a
    /// PDF opened once opens again, offline too, when the index's hash is stale or missing.
    public static func decide(_ entry: DrawingEntry, online: Bool, pdfsOnThisDuo: Set<String>,
                              pdfPathsOnThisDuo: Set<String> = []) -> Decision {
        guard let indexed = entry.pdf, let pdf = pdf(for: entry) else { return .noPDFYet }
        if DrawingMarker.isOnThisDuo(indexed, pdfsOnThisDuo, pdfPathsOnThisDuo) { return .openKept(pdf) }
        return online ? .download(pdf) : .notOnThisDuo(pdf)
    }

    /// What the Drawings tab says when a tap meets a PDF that isn't on the Duo while it is offline, as the prototype
    /// says it; the viewer doesn't open.
    public static func notOnThisDuoText(number: String?) -> String {
        "\(number ?? "This drawing")'s PDF isn't on this Duo yet. It downloads when you're back online; searching works "
            + "offline."
    }

    // MARK: The scale

    /// The scale text placing reads and the viewer's header shows for the PDF shown: `NTS` for a plot fitted to the page
    /// (#92), which no title block scale fits, else the index's `scale`.
    public static func scaleText(for entry: DrawingEntry, pdf: PDF?) -> String? {
        pdf?.fitted == true ? "NTS" : entry.scale
    }

    /// The drawing scale the index entry's `scale` text gives, as the title block writes it: `1/4" = 1'-0"`, `1" = 20'`,
    /// `1:20`, `NTS`. Nil when Vellum must ask for the scale before the sheet is placed: AS NOTED (or AS SHOWN, AS
    /// INDICATED, VARIES), a blank, or text it can't read whole (ADR-0002). It never guesses from part of the text.
    public static func scale(indexText text: String?) -> Sheet.Scale? {
        guard let text else { return nil }
        let letters = text.uppercased().filter(\.isLetter)
        for noted in ["ASNOTED", "ASSHOWN", "ASINDICATED", "VARIES"] where letters.contains(noted) { return nil }
        switch DrawingScale.read(text) {
        case .scale(let scale): return .drawn(scale)
        case .notToScale: return .notToScale
        case .cantTell: return nil
        }
    }

    /// How placing from the viewer asks for the scale, with Add sheet's own confirm step (ADR-0002: Vellum reads the
    /// scale and Zach confirms it): prefilled with the index's scale, so a right one is one tap; or, for AS NOTED or a
    /// scale Vellum can't read, nothing prefilled, asking for one to be picked or typed.
    public struct Confirmation: Hashable, Sendable {
        /// The scale the confirm step starts on, from the index; nil when it asks.
        public var prefilled: Sheet.Scale?
        /// Whether it asks for a scale to be picked or typed.
        public var asks: Bool { prefilled == nil }
    }

    /// For the entry's own PDF; a fitted one (#92) starts on NTS.
    public static func confirmation(for entry: DrawingEntry) -> Confirmation {
        confirmation(for: entry, pdf: pdf(for: entry))
    }

    /// For the PDF shown, which may be a plot the index doesn't list yet; a fitted one (#92) starts on NTS.
    public static func confirmation(for entry: DrawingEntry, pdf: PDF?) -> Confirmation {
        Confirmation(prefilled: scale(indexText: scaleText(for: entry, pdf: pdf)))
    }

    // MARK: The sheet it becomes

    /// The sheet a page of the drawing's PDF becomes, waiting for where it goes, at `scale`: the same sheet Add sheet
    /// makes from the same page at the same scale (`SheetReading.sheet(placedAt:page:invertsBadly:)`), so its size and
    /// scale areas are the same whichever way it came. `keptName` is the name the PDF is kept under on the Duo.
    public static func sheet(_ entry: DrawingEntry, pdf: PDF, keptName: String, page: Int, reading: SheetReading,
                             scale: Sheet.Scale, invertsBadly: Bool) -> Sheet {
        let page = SheetPage(file: keptName, name: pdf.name, path: pdf.path, index: page,
                             number: reading.sheetNumber ?? entry.number)
        return reading.sheet(placedAt: scale, page: page, invertsBadly: invertsBadly)
    }

    // MARK: A new canvas

    /// What Open in a new canvas (or New canvas in the Place on a canvas picker) calls the canvas: the drawing's number
    /// and title, `E-210 Pump house power plan`, as the prototype names it; the one it has when it lacks the other; and
    /// the file's name without `.dwg` or `.pdf` when it has neither.
    public static func canvasName(for entry: DrawingEntry) -> String {
        let number = entry.number.flatMap(trimmed)
        let title = entry.title.flatMap(trimmed)
        switch (number, title) {
        case let (number?, title?): return title.uppercased().hasPrefix(number.uppercased()) ? title : "\(number) \(title)"
        case let (number?, nil): return number
        case let (nil, title?): return title
        case (nil, nil):
            var name = entry.name
            for suffix in [".dwg", ".pdf"] where name.lowercased().hasSuffix(suffix) { name = String(name.dropLast(4)) }
            return trimmed(name) ?? CanvasName.untitled
        }
    }

    private static func trimmed(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}

extension SheetReading {
    /// The sheet this page becomes at `scale`, its origin still to come: its paper, its scale areas for that scale
    /// (every detail drawn at another, #11), and whether it dims in dark mode. Add sheet's confirm step, the drawing
    /// viewer and the captures all make a sheet here, so a page placed any way lands the same.
    public func sheet(placedAt scale: Sheet.Scale, page: SheetPage, invertsBadly: Bool) -> Sheet {
        Sheet(paper: paper, scale: scale, page: page, areas: areas(placedAt: scale), invertsBadly: invertsBadly)
    }
}
