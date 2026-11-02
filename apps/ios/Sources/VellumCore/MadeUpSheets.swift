/// Made-up PDF pages for testing sheets (#11): their title block text, a printed dimension on each, and a few lines of
/// drawing so they look like sheets. The Debug app draws them into PDFs with `UIGraphicsPDFRenderer`; the tests read
/// the same text and dimensions. Every project, number and title here is invented: the repository is public and holds
/// no client drawing (AGENTS.md).
///
/// Each page's printed dimension is the "done when" of #11: placed at the scale Vellum reads, a measure between its
/// ends reads what is printed on it.
public enum MadeUpSheets {
    /// A dimension printed on a page: its two ends on the paper, the text printed on it, and the scale it is drawn at.
    public struct PrintedDimension: Hashable, Sendable {
        public var from: PaperPoint
        public var to: PaperPoint
        /// What the page prints on the dimension, and so what a measure between its ends must read.
        public var text: String
    }

    /// A line of drawing on the page, in printed inches.
    public struct Segment: Hashable, Sendable {
        public var from: PaperPoint
        public var to: PaperPoint
        /// Drawn in colour (a coloured fill's edge), for the "inverts badly" test.
        public var coloured = false
    }

    public struct Page: Hashable, Sendable {
        public var number: String
        public var title: String
        public var paper: PaperSize
        /// The page's text, as the PDF draws it and PDFKit reads it back.
        public var texts: [PageText]
        public var dimensions: [PrintedDimension]
        public var drawing: [Segment]
        /// A scan: the page is one picture, grey paper and fuzzy lines, with no text.
        public var isScan = false
    }

    /// A made-up PDF in the made-up Dropbox: its file name and pages.
    public struct File: Hashable, Sendable {
        public var name: String
        public var pages: [Page]
        /// A made-up content hash, which names the PDF on the Duo.
        public var contentHash: String
    }

    /// The made-up Dropbox folder Add sheet opens on in the captures.
    public static let folder = "/Projects (example)/Riverside Plant (example)/Drawings"
    /// A folder inside it, to show folders list above PDFs.
    public static let subfolder = "Superseded"

    /// The PDFs in that folder: a three-page set (a 1/4" plan, an AS NOTED detail sheet, an NTS loop diagram), the
    /// plan again on its own, and a scan.
    public static let files: [File] = [
        File(name: "IFC set, Riverside boiler house (example).pdf", pages: [quarterInchPlan, detailSheet, loopDiagram],
             contentHash: "madeup0000000000000000000000000000000000000000000000000000000001"),
        File(name: "M-101 Boiler house plan (example).pdf", pages: [quarterInchPlan],
             contentHash: "madeup0000000000000000000000000000000000000000000000000000000002"),
        File(name: "M-001 Boiler house 1978, scanned (example).pdf", pages: [scan],
             contentHash: "madeup0000000000000000000000000000000000000000000000000000000003"),
    ]

    /// M-101, a 36 × 24 plan at 1/4" = 1'-0", with a 6" printed dimension reading 24'-0".
    public static let quarterInchPlan: Page = {
        let paper = PaperSize.inches(36, by: 24)
        return Page(number: "M-101", title: "BOILER HOUSE PLAN (EXAMPLE)", paper: paper,
                    texts: titleBlock(paper, number: "M-101", title: "BOILER HOUSE PLAN (EXAMPLE)",
                                      scale: "SCALE: 1/4\" = 1'-0\"")
                        + [.at(6.4, 9.35, "24'-0\"", width: 0.7, height: 0.18),
                           .at(4, 3.6, "BOILER B-1", width: 1.2, height: 0.2),
                           .at(14, 3.6, "BOILER B-2", width: 1.2, height: 0.2),
                           .at(4, 18.6, "FEEDWATER PUMPS", width: 2, height: 0.2)],
                    dimensions: [PrintedDimension(from: p(4, 10), to: p(10, 10), text: "24'-0\"")],
                    drawing: rectangle(2, 2, 26, 20) + rectangle(4, 4, 6, 4) + rectangle(14, 4, 6, 4)
                        + rectangle(4, 15, 10, 3) + [Segment(from: p(10, 6), to: p(14, 6)),
                                                     Segment(from: p(7, 8), to: p(7, 15))])
    }()

    /// D-501, a 17 × 11 detail sheet whose title block says AS NOTED, with three details: at 1" = 1'-0" (3" printed,
    /// 3'-0"), at 1 1/2" = 1'-0" (3" printed, 2'-0") and NTS (2" printed, 2" NTS).
    public static let detailSheet: Page = {
        let paper = PaperSize.inches(17, by: 11)
        var texts = titleBlock(paper, number: "D-501", title: "INSTRUMENT DETAILS (EXAMPLE)", scale: "SCALE: AS NOTED")
        texts += [
            // Each detail's title and scale centred under it, as details are titled.
            .at(1.7, 7.3, "1  TRANSMITTER STAND", width: 2.6, height: 0.18),
            .at(2.1, 7.6, "SCALE: 1\" = 1'-0\"", width: 1.8, height: 0.16),
            .at(2.6, 3.35, "3'-0\"", width: 0.6, height: 0.16),
            .at(6.5, 7.3, "2  PIPE SUPPORT", width: 2, height: 0.18),
            .at(6.45, 7.6, "SCALE: 1 1/2\" = 1'-0\"", width: 2.1, height: 0.16),
            .at(7.1, 3.35, "2'-0\"", width: 0.6, height: 0.16),
            .at(10.3, 7.3, "3  TUBING SCHEMATIC", width: 2.4, height: 0.18),
            .at(10.9, 7.6, "SCALE: NTS", width: 1.2, height: 0.16),
            .at(11.2, 3.35, "2\"", width: 0.4, height: 0.16),
        ]
        return Page(number: "D-501", title: "INSTRUMENT DETAILS (EXAMPLE)", paper: paper, texts: texts,
                    dimensions: [PrintedDimension(from: p(1.5, 3.8), to: p(4.5, 3.8), text: "3'-0\""),
                                 PrintedDimension(from: p(6, 3.8), to: p(9, 3.8), text: "2'-0\""),
                                 PrintedDimension(from: p(10.5, 3.8), to: p(12.5, 3.8), text: "2\" NTS")],
                    drawing: rectangle(1.5, 4.5, 3, 2) + rectangle(6, 4.5, 3, 1.5) + rectangle(10.5, 4.5, 2, 2)
                        + [Segment(from: p(3, 4.5), to: p(3, 6.5)), Segment(from: p(10.5, 5.5), to: p(12.5, 5.5))])
    }()

    /// L-1042, an 11 × 8.5 loop diagram, NTS, with a 4" printed dimension reading 4" NTS.
    public static let loopDiagram: Page = {
        let paper = PaperSize.inches(11, by: 8.5)
        return Page(number: "L-1042", title: "LOOP DIAGRAM FT-1042 (EXAMPLE)", paper: paper,
                    texts: titleBlock(paper, number: "L-1042", title: "LOOP DIAGRAM FT-1042 (EXAMPLE)",
                                      scale: "SCALE: NTS")
                        + [.at(2.6, 2.05, "4\"", width: 0.4, height: 0.16),
                           .at(1, 3.4, "FT-1042", width: 0.9, height: 0.18),
                           .at(5.4, 3.4, "JB-12", width: 0.8, height: 0.18)],
                    dimensions: [PrintedDimension(from: p(1, 2.5), to: p(5, 2.5), text: "4\" NTS")],
                    drawing: rectangle(1, 3, 1.4, 1) + rectangle(5.4, 3, 1.4, 1.6)
                        + [Segment(from: p(2.4, 3.5), to: p(5.4, 3.5)), Segment(from: p(2.4, 3.7), to: p(5.4, 3.7))])
    }()

    /// M-001, an 11 × 17 scan: no text, grey paper, so Vellum can't read its scale and dims it in dark mode. Zach
    /// would type its scale; the captures pick 1/8" = 1'-0".
    public static let scan: Page = {
        let paper = PaperSize.inches(17, by: 11)
        return Page(number: "M-001", title: "BOILER HOUSE 1978 (EXAMPLE)", paper: paper, texts: [], dimensions: [],
                    drawing: rectangle(1.5, 1.5, 12, 8) + rectangle(3, 3, 3, 2) + rectangle(8, 3, 3, 2)
                        + [Segment(from: p(1.5, 6.5), to: p(13.5, 6.5))],
                    isScan: true)
    }()

    // MARK: Pieces

    private static func p(_ x: Double, _ y: Double) -> PaperPoint { PaperPoint(x: .inches(x), y: .inches(y)) }

    private static func rectangle(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [Segment] {
        [Segment(from: p(x, y), to: p(x + w, y)), Segment(from: p(x + w, y), to: p(x + w, y + h)),
         Segment(from: p(x + w, y + h), to: p(x, y + h)), Segment(from: p(x, y + h), to: p(x, y))]
    }

    /// A title block in the bottom-right corner: the project, the title, the scale, and the sheet number in large
    /// text.
    private static func titleBlock(_ paper: PaperSize, number: String, title: String, scale: String) -> [PageText] {
        let x = paper.width.inches - 4.2, y = paper.height.inches - 1.6
        return [.at(x, y, "RIVERSIDE PLANT (EXAMPLE)", width: 3, height: 0.14),
                .at(x, y + 0.3, title, width: 3.4, height: 0.16),
                .at(x, y + 0.6, scale, width: 2.2, height: 0.14),
                .at(x + 2.6, y + 0.85, number, width: 1.2, height: 0.42)]
    }

    /// The title block's box, for drawing.
    public static func titleBlockBox(_ paper: PaperSize) -> PaperRect {
        .inches(x: paper.width.inches - 4.4, y: paper.height.inches - 1.8, width: 4.1, height: 1.5)
    }
}
