import PDFKit
import UIKit
import VellumCore

/// Reads one PDF on the Duo for Add sheet (#11), off the main thread: how many pages, each page's paper size and text
/// (for `SheetReading`), a thumbnail of a page, and whether a page inverts badly in dark mode (`SheetTone`). Each
/// answer is worked out once per page and kept.
actor SheetPDFReader {
    let url: URL
    private var document: PDFDocument?
    private var pages: [Int: PageInfo] = [:]
    private var tones: [Int: Bool] = [:]

    /// What Vellum read off a page.
    struct PageInfo: Sendable {
        var paper: PaperSize
        var reading: SheetReading
        var hasText: Bool
    }

    init(url: URL) { self.url = url }

    private func open() -> PDFDocument? {
        if let document { return document }
        document = PDFDocument(url: url)
        return document
    }

    var pageCount: Int { open()?.pageCount ?? 0 }

    /// The page's paper size, as it is shown (turned by the page's rotation), in printed inches.
    static func paper(of page: PDFPage) -> PaperSize {
        let box = page.bounds(for: .cropBox)
        let turned = abs(page.rotation) % 180 == 90
        let w = turned ? box.height : box.width, h = turned ? box.width : box.height
        return .inches(Double(w) / 72, by: Double(h) / 72)
    }

    /// What Vellum reads off a page: its paper, and its title block's scale, sheet number and details.
    func info(page index: Int) -> PageInfo? {
        if let known = pages[index] { return known }
        guard let page = open()?.page(at: index) else { return nil }
        let paper = Self.paper(of: page)
        let lines = Self.lines(of: page, paper: paper)
        let info = PageInfo(paper: paper, reading: SheetReading.read(lines, paper: paper), hasText: !lines.isEmpty)
        pages[index] = info
        return info
    }

    /// The page's lines of text as read, for the captures' log.
    func lines(page index: Int) -> [PageText] {
        guard let page = open()?.page(at: index) else { return [] }
        return Self.lines(of: page, paper: Self.paper(of: page))
    }

    /// A page drawn to fit `side` points on its long side, for the page grid and the confirm step.
    func thumbnail(page index: Int, side: CGFloat) -> SheetThumbnail? {
        guard let page = open()?.page(at: index) else { return nil }
        let paper = Self.paper(of: page)
        let long = max(paper.width.inches, paper.height.inches)
        let size = CGSize(width: side * paper.width.inches / long, height: side * paper.height.inches / long)
        return SheetThumbnail(image: page.thumbnail(of: size, for: .cropBox))
    }

    /// Whether a page inverts badly in dark mode: rendered once at `SheetTone.sampleSide` and looked at.
    func invertsBadly(page index: Int) -> Bool {
        if let known = tones[index] { return known }
        guard let page = open()?.page(at: index), let info = info(page: index) else { return false }
        let long = CGFloat(SheetTone.sampleSide)
        let wide = info.paper.width.inches >= info.paper.height.inches
        let w = wide ? long : (long * info.paper.width.inches / info.paper.height.inches).rounded()
        let h = wide ? (long * info.paper.height.inches / info.paper.width.inches).rounded() : long
        let image = page.thumbnail(of: CGSize(width: w, height: h), for: .cropBox)
        let pixels = Self.rgba(image, width: Int(w), height: Int(h))
        let answer = SheetTone.invertsBadly(rgba: pixels, hasText: info.hasText)
        tones[index] = answer
        return answer
    }

    /// An image's pixels, red, green, blue and alpha, on white.
    private static func rgba(_ image: UIImage, width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0, let cg = image.cgImage else { return [] }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? pixels : []
    }

    /// The page's text in lines, each with where it is on the paper. PDFKit's own lines are used, since a selection's
    /// text and bounds always belong together (character indices can drift from character boxes where PDFKit adds
    /// spaces and line breaks). A line wider than its text accounts for may be labels set side by side on one row, so
    /// it is split at the gaps where a narrow strip of it selects no text.
    static func lines(of page: PDFPage, paper: PaperSize) -> [PageText] {
        guard page.numberOfCharacters > 0 else { return [] }
        let toDisplay = page.pageRef?.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0,
                                                                                width: paper.width.inches * 72,
                                                                                height: paper.height.inches * 72),
                                                          rotate: 0, preserveAspectRatio: true) ?? .identity
        let height = paper.height.inches
        func paperRect(_ rect: CGRect) -> PaperRect {
            .inches(x: Double(rect.minX) / 72, y: height - Double(rect.maxY) / 72, width: Double(rect.width) / 72,
                    height: Double(rect.height) / 72)
        }
        func text(_ selection: PDFSelection?) -> String? {
            guard let string = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !string.isEmpty else { return nil }
            return string
        }
        var out: [PageText] = []
        for line in page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? [] {
            guard let string = text(line) else { continue }
            let bounds = line.bounds(for: page)
            let h = max(bounds.height, 1)
            // About 0.7 of the height a character, generously: wider than that holds gaps worth looking for.
            guard bounds.width > CGFloat(string.count) * h * 0.9 + 2 * h else {
                out.append(PageText(string, paperRect(bounds.applying(toDisplay))))
                continue
            }
            let step = h * 0.5
            var runs: [(CGFloat, CGFloat)] = []
            var start: CGFloat?, emptyFrom: CGFloat?
            var x = bounds.minX
            while x < bounds.maxX {
                let strip = CGRect(x: x, y: bounds.minY + h * 0.2, width: step, height: h * 0.6)
                let filled = text(page.selection(for: strip)) != nil
                if filled {
                    if start == nil { start = x }
                    emptyFrom = nil
                } else if let begun = start {
                    if emptyFrom == nil { emptyFrom = x }
                    // A gap of more than a character and a half ends the run.
                    if let from = emptyFrom, x + step - from > h * 1.5 {
                        runs.append((begun, from))
                        start = nil
                        emptyFrom = nil
                    }
                }
                x += step
            }
            if let begun = start { runs.append((begun, emptyFrom ?? bounds.maxX)) }
            if runs.count <= 1 {
                out.append(PageText(string, paperRect(bounds.applying(toDisplay))))
                continue
            }
            for (from, to) in runs {
                let piece = page.selection(for: CGRect(x: from, y: bounds.minY, width: to - from, height: bounds.height))
                guard let pieceText = text(piece), let pieceBounds = piece?.bounds(for: page) else { continue }
                out.append(PageText(pieceText, paperRect(pieceBounds.applying(toDisplay))))
            }
        }
        return out
    }
}

/// A page's thumbnail handed back from the reader.
struct SheetThumbnail: @unchecked Sendable {
    let image: UIImage
}
