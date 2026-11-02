/// Whether a PDF page inverts badly in dark mode, so it shows dimmed rather than inverted (ADR-0011, #11 "Vellum
/// decides"). Inverting suits a line drawing: black lines on white paper become light lines on dark. It does not suit
/// a scan, whose paper is grey or yellowed and whose lines are fuzzy, or a page with coloured or large dark fills,
/// which invert to garish complements and glaring blocks.
///
/// The app renders the page once, small (`sampleSide` points on its long side), off the main thread, when the page is
/// chosen, and this looks at its pixels. The answer is kept with the sheet, so it is never worked out again.
public enum SheetTone {
    /// The long side, in pixels, of the rendering the test looks at.
    public static let sampleSide = 96

    /// What the test found, for the PR, the captures' console and the tests.
    public struct Reading: Hashable, Sendable {
        /// The share of pixels with a clear colour (one channel at least 48 of 255 from another).
        public var colourful: Double
        /// The share of pixels darker than mid grey.
        public var dark: Double
        /// The median brightness, 0 to 255: near 255 on white paper, lower on a scan's grey or yellowed paper.
        public var paper: Double
        /// Whether the page has text: a page with none is a scan.
        public var hasText: Bool

        public var invertsBadly: Bool {
            !hasText || colourful > SheetTone.colourfulLimit || dark > SheetTone.darkLimit || paper < SheetTone.paperLimit
        }
    }

    /// More than this share of clearly coloured pixels: a page with coloured fills (a vendor GA, a P&ID with coloured
    /// lines throughout).
    public static let colourfulLimit = 0.03
    /// More than this share of dark pixels: large black fills or a dark scan. Line work at the sample size is a few
    /// per cent.
    public static let darkLimit = 0.25
    /// A median brightness below this: the paper is not white, so the page is a scan or a photocopy.
    public static let paperLimit = 225.0

    /// Reads a page from its sample's pixels, four bytes each (red, green, blue, then alpha or padding, ignored), row
    /// by row.
    public static func read(rgba pixels: [UInt8], hasText: Bool) -> Reading {
        let count = pixels.count / 4
        guard count > 0 else { return Reading(colourful: 0, dark: 0, paper: 255, hasText: hasText) }
        var colourful = 0, dark = 0
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<count {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
            if max(r, g, b) - min(r, g, b) >= 48 { colourful += 1 }
            let luma = (r * 299 + g * 587 + b * 114) / 1000
            if luma < 128 { dark += 1 }
            histogram[luma] += 1
        }
        var seen = 0, median = 255
        for (level, n) in histogram.enumerated() {
            seen += n
            if seen * 2 >= count {
                median = level
                break
            }
        }
        return Reading(colourful: Double(colourful) / Double(count), dark: Double(dark) / Double(count),
                       paper: Double(median), hasText: hasText)
    }

    public static func invertsBadly(rgba pixels: [UInt8], hasText: Bool) -> Bool {
        read(rgba: pixels, hasText: hasText).invertsBadly
    }
}
