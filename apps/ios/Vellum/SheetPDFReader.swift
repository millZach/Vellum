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

    /// The page's text in lines, each with where it is on the paper. Each character and its box are read by PDFKit's
    /// own character index (`numberOfCharacters`, a one-character selection, `characterBounds(at:)`), so they always
    /// belong together (`page.string`'s indices can drift from the boxes'). Characters are joined while they sit on
    /// one line with no wide gap, so two labels side by side stay two lines, the way they read on the sheet. A page
    /// with more than `characterLimit` characters is read by PDFKit's own lines instead, which is quicker.
    static func lines(of page: PDFPage, paper: PaperSize) -> [PageText] {
        let count = page.numberOfCharacters
        guard count > 0 else { return [] }
        let toDisplay = page.pageRef?.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0,
                                                                                width: paper.width.inches * 72,
                                                                                height: paper.height.inches * 72),
                                                          rotate: 0, preserveAspectRatio: true) ?? .identity
        let height = paper.height.inches
        func paperRect(_ rect: CGRect) -> PaperRect {
            .inches(x: Double(rect.minX) / 72, y: height - Double(rect.maxY) / 72, width: Double(rect.width) / 72,
                    height: Double(rect.height) / 72)
        }
        if count > characterLimit {
            let lines = page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []
            return lines.compactMap { line in
                guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    return nil
                }
                return PageText(text, paperRect(line.bounds(for: page).applying(toDisplay)))
            }
        }
        var lines: [PageText] = []
        var current = ""
        var rect = CGRect.null
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !rect.isNull { lines.append(PageText(trimmed, paperRect(rect))) }
            current = ""
            rect = .null
        }
        for i in 0..<count {
            let character = page.selection(for: NSRange(location: i, length: 1))?.string ?? ""
            if character.contains(where: \.isNewline) {
                flush()
                continue
            }
            let box = page.characterBounds(at: i).applying(toDisplay)
            if character.allSatisfy(\.isWhitespace) || box.width <= 0 || box.height <= 0 {
                if !current.isEmpty { current += " " }
                continue
            }
            if !rect.isNull {
                let size = max(rect.height, box.height)
                let sameLine = abs(box.midY - rect.midY) < size * 0.5
                let gap = box.minX - rect.maxX
                if !sameLine || gap > size * 1.5 || gap < -size { flush() }
            }
            current += character
            rect = rect.isNull ? box : rect.union(box)
        }
        flush()
        return lines
    }

    /// Past this many characters a page is read by PDFKit's lines rather than character by character.
    static let characterLimit = 20_000
}

/// A page's thumbnail handed back from the reader.
struct SheetThumbnail: @unchecked Sendable {
    let image: UIImage
}
