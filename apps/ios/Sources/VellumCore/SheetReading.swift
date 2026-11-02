/// A line of text on a PDF page, as PDFKit gives it in the app, with where it sits on the paper: printed inches from
/// the page's top-left corner, y running down.
public struct PageText: Hashable, Sendable {
    public var text: String
    public var rect: PaperRect

    public init(_ text: String, _ rect: PaperRect) {
        self.text = text
        self.rect = rect
    }

    /// A line at a corner, in printed inches, with a made-up size: for tests and the made-up sheets.
    public static func at(_ x: Double, _ y: Double, _ text: String, width: Double = 2, height: Double = 0.16)
        -> PageText {
        PageText(text, .inches(x: x, y: y, width: width, height: height))
    }
}

/// What Vellum read off one PDF page's text (#11, ADR-0002): the title block's SCALE, the sheet number, and the scales
/// written under its details, with Vellum's guess at each detail's area. Only lines that say SCALE, NTS or NOT TO
/// SCALE are read for scales, so a dimension's text such as `12'-0"` is never taken for one.
///
/// The title block's scale is the scale line nearest the page's bottom-right corner, where title blocks sit; any
/// other scale line is a detail's. A detail's area is Vellum's guess from where its scale line is, since details are
/// titled underneath: from the line's bottom up to the next detail's title above it (or the top margin), and across to
/// halfway between it and the details either side (or the margins, stopping short of the title block).
public struct SheetReading: Hashable, Sendable {
    /// What the title block says about the sheet's scale.
    public enum TitleBlock: Hashable, Sendable {
        /// `SCALE: 1/4" = 1'-0"`.
        case scale(DrawingScale)
        /// `SCALE: NTS`, `NOT TO SCALE`.
        case notToScale
        /// `SCALE: AS NOTED` (or `AS SHOWN`, `VARIES`): each detail says its own.
        case asNoted
        /// A SCALE Vellum can't read whole: `SCALE: 1/4 = 1`.
        case unreadable(String)
        /// No SCALE anywhere on the page.
        case none
        /// No text at all: a scan.
        case scan
    }

    /// A scale written under one detail, and the area Vellum takes the detail to fill.
    public struct Detail: Hashable, Sendable {
        public var name: String
        public var scale: Sheet.Scale
        /// The detail's title and scale lines.
        public var label: PaperRect
        public var area: PaperRect
    }

    public var paper: PaperSize
    public var titleBlock: TitleBlock
    /// Where the title block's scale line is, when there is one.
    public var titleBlockLabel: PaperRect?
    /// The sheet number read off the title block, such as `M-101`.
    public var sheetNumber: String?
    public var details: [Detail]

    /// Reads a page's lines of text.
    public static func read(_ lines: [PageText], paper: PaperSize) -> SheetReading {
        let lines = joinFragments(lines.filter { !$0.text.allSatisfy { $0 == " " } })
        guard !lines.isEmpty else {
            return SheetReading(paper: paper, titleBlock: .scan, titleBlockLabel: nil, sheetNumber: nil, details: [])
        }
        var found: [(line: PageText, says: ScaleText)] = []
        for (i, line) in lines.enumerated() {
            guard var says = ScaleText.read(line.text) else { continue }
            var rect = line.rect
            if case .labelOnly = says, let value = Self.valueBeside(lines[i], in: lines, skipping: i) {
                says = ScaleText.read("SCALE: " + value.text) ?? .unreadable(value.text)
                rect = rect.union(value.rect)
            }
            found.append((line: PageText(line.text, rect), says: says))
        }
        let number = Self.sheetNumber(in: lines, paper: paper)
        guard !found.isEmpty else {
            return SheetReading(paper: paper, titleBlock: .none, titleBlockLabel: nil, sheetNumber: number, details: [])
        }
        // The title block's line is the one nearest the bottom-right corner.
        let w = paper.width.inches, h = paper.height.inches
        let titleIndex = found.indices.max { a, b in
            let ra = found[a].line.rect, rb = found[b].line.rect
            return ra.midX / w + ra.midY / h < rb.midX / w + rb.midY / h
        }!
        let title = found[titleIndex]
        let titleBlock: TitleBlock
        switch title.says {
        case .scale(let scale): titleBlock = .scale(scale)
        case .notToScale: titleBlock = .notToScale
        case .asNoted: titleBlock = .asNoted
        case .unreadable(let text): titleBlock = .unreadable(text)
        case .labelOnly: titleBlock = .unreadable("")
        }
        var labels: [(name: String?, scale: Sheet.Scale, rect: PaperRect)] = []
        for (i, entry) in found.enumerated() where i != titleIndex {
            let scale: Sheet.Scale
            switch entry.says {
            case .scale(let s): scale = .drawn(s)
            case .notToScale: scale = .notToScale
            default: continue
            }
            var rect = entry.line.rect
            let name = Self.detailTitle(above: entry.line, in: lines)
            if let name { rect = rect.union(name.rect) }
            labels.append((name: name.map { Self.detailName($0.text) }, scale: scale, rect: rect))
        }
        let areas = Self.areas(for: labels.map { $0.rect }, titleBlock: title.line.rect, paper: paper)
        let details = labels.enumerated().map { i, label in
            Detail(name: label.name ?? "Detail \(i + 1)", scale: label.scale, label: label.rect, area: areas[i])
        }
        return SheetReading(paper: paper, titleBlock: titleBlock, titleBlockLabel: title.line.rect, sheetNumber: number,
                            details: details)
    }

    /// Joins pieces of one printed line that text extraction split apart (`SCALE: 1/4" =` and `1'-0"`, `M-` and `101`):
    /// lines on the same row whose gap is under about a letter's height. Labels set side by side, inches apart, stay
    /// separate.
    static func joinFragments(_ lines: [PageText]) -> [PageText] {
        var lines = lines.sorted { ($0.rect.midY, $0.rect.minX) < ($1.rect.midY, $1.rect.minX) }
        var joined = true
        while joined {
            joined = false
            outer: for i in lines.indices {
                for j in lines.indices where j != i {
                    let a = lines[i].rect, b = lines[j].rect
                    let h = max(a.height.inches, b.height.inches, 0.01)
                    let gap = b.minX - a.maxX
                    guard abs(a.midY - b.midY) < h * 0.5, gap > -h * 0.5, gap < h * 1.1, b.midX > a.midX else { continue }
                    let space = gap > h * 0.15 && !lines[i].text.hasSuffix(" ") && !lines[j].text.hasPrefix(" ")
                    lines[i] = PageText(lines[i].text + (space ? " " : "") + lines[j].text, a.union(b))
                    lines.remove(at: j)
                    joined = true
                    break outer
                }
            }
        }
        return lines
    }

    // MARK: What it means for placing the sheet

    /// The scales written under the details, each once, in the order found.
    public var detailScales: [Sheet.Scale] {
        var seen: [Sheet.Scale] = []
        for detail in details where !seen.contains(detail.scale) { seen.append(detail.scale) }
        return seen
    }

    /// The scale the confirm step starts on: the title block's, or for AS NOTED the first detail's; nil when Zach has
    /// to pick or type one (no scale read, a scan, junk).
    public var suggestedScale: Sheet.Scale? {
        switch titleBlock {
        case .scale(let scale): .drawn(scale)
        case .notToScale: .notToScale
        case .asNoted, .unreadable, .none, .scan: detailScales.first
        }
    }

    /// Whether the confirm step asks Zach for the scale rather than naming the one read: no scale, a scan, AS NOTED,
    /// junk, or several scales on the sheet (ADR-0002).
    public var asksForScale: Bool {
        switch titleBlock {
        case .scale(let scale): detailScales.contains { $0 != .drawn(scale) }
        case .notToScale: detailScales.contains { $0 != .notToScale }
        case .asNoted, .unreadable, .none, .scan: true
        }
    }

    /// The scale areas when the sheet goes on at `main`: every detail drawn at another scale (#11, ADR-0002).
    public func areas(placedAt main: Sheet.Scale) -> [ScaleArea] {
        details.filter { $0.scale != main }.map { ScaleArea(name: $0.name, rect: $0.area, scale: $0.scale) }
    }

    /// What the page grid says under a page's thumbnail: the scale read, `AS NOTED`, `NTS`, `no scale read`, `scan`.
    public var caption: String {
        switch titleBlock {
        case .scale(let scale): asksForScale ? "Several scales" : scale.description
        case .notToScale: "NTS"
        case .asNoted: "AS NOTED"
        case .unreadable: "Scale unreadable"
        case .none: "No scale read"
        case .scan: "Scan"
        }
    }

    /// Whether the page has no text, so it is a scan: its title block can't be read, and it dims in dark mode.
    public var isScan: Bool { titleBlock == .scan }

    // MARK: Finding things on the page

    /// The value of a SCALE label written on its own: the nearest line to its right on the same row, else the nearest
    /// line just below it.
    private static func valueBeside(_ label: PageText, in lines: [PageText], skipping skip: Int) -> PageText? {
        let r = label.rect
        var best: (PageText, Double)?
        for (i, line) in lines.enumerated() where i != skip {
            let o = line.rect
            let sameRow = abs(o.midY - r.midY) < max(r.height.inches, 0.1) && o.minX >= r.midX
            let below = o.minY >= r.midY && o.minY - r.maxY < 0.4 && o.minX < r.maxX + 0.2 && o.maxX > r.minX - 0.2
            guard sameRow || below, ScaleText.read(line.text) == nil else { continue }
            let d = sameRow ? o.minX - r.maxX : 10 + o.minY - r.maxY
            if best == nil || d < best!.1 { best = (line, d) }
        }
        return best?.0
    }

    /// A detail's title: a line just above its scale line, across from it, that is not itself a scale.
    private static func detailTitle(above scaleLine: PageText, in lines: [PageText]) -> PageText? {
        let r = scaleLine.rect
        var best: (PageText, Double)?
        for line in lines where line != scaleLine && ScaleText.read(line.text) == nil {
            let o = line.rect
            let gap = r.minY - o.maxY
            guard gap >= -0.02, gap < 0.45, o.minX < r.maxX, o.maxX > r.minX else { continue }
            if best == nil || gap < best!.1 { best = (line, gap) }
        }
        return best?.0
    }

    /// `Detail 2` from a detail's title: `2  PIPE SUPPORT`, `DETAIL 2 - PIPE SUPPORT`, `DETAIL B`.
    static func detailName(_ title: String) -> String {
        let words = title.uppercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
        var rest = words[...]
        if rest.first == "DETAIL" || rest.first == "DET." { rest = rest.dropFirst() }
        guard let mark = rest.first else { return "Detail" }
        let cleaned = mark.filter { $0.isLetter || $0.isNumber }
        guard !cleaned.isEmpty, cleaned.count <= 3 else { return title }
        return "Detail \(cleaned)"
    }

    /// The sheet number: a line that is a sheet number alone (`M-101`, `E1.01`, `L-1042`), or follows `SHEET` or
    /// `DWG`, preferring the tallest text, then the one nearest the bottom-right corner.
    private static func sheetNumber(in lines: [PageText], paper: PaperSize) -> String? {
        let w = paper.width.inches, h = paper.height.inches
        var best: (String, Double, Double)?
        for line in lines {
            let words = line.text.uppercased().split(separator: " ").map(String.init)
            var candidate: String?
            if words.count == 1, isSheetNumber(words[0]) {
                candidate = words[0]
            } else if let i = words.firstIndex(where: { $0.hasPrefix("SHEET") || $0.hasPrefix("DWG") }),
                      let next = words[(i + 1)...].first(where: { $0 != "NO." && $0 != "NO" && $0 != ":" }) {
                let token = String(next.drop { $0 == ":" })
                if isSheetNumber(token) { candidate = token }
            }
            guard let candidate else { continue }
            let tall = line.rect.height.inches, corner = line.rect.midX / w + line.rect.midY / h
            if best == nil || tall > best!.1 + 1e-9 || (abs(tall - best!.1) <= 1e-9 && corner > best!.2) {
                best = (candidate, tall, corner)
            }
        }
        return best?.0
    }

    /// One to three letters, an optional `-` or `.`, then digits, with optional `.digits`: `M-101`, `E1.01`, `A5`.
    static func isSheetNumber(_ token: String) -> Bool {
        var chars = Substring(token)
        let letters = chars.prefix { $0.isASCII && $0.isLetter }
        guard (1...3).contains(letters.count) else { return false }
        chars = chars.dropFirst(letters.count)
        if chars.first == "-" || chars.first == "." { chars = chars.dropFirst() }
        let digits = chars.prefix { $0.isASCII && $0.isNumber }
        guard (1...4).contains(digits.count) else { return false }
        chars = chars.dropFirst(digits.count)
        if chars.first == "." {
            chars = chars.dropFirst()
            let more = chars.prefix { $0.isASCII && $0.isNumber }
            guard !more.isEmpty else { return false }
            chars = chars.dropFirst(more.count)
        }
        return chars.isEmpty
    }

    /// Each detail's area, from where its label sits (see the type's comment).
    static func areas(for labels: [PaperRect], titleBlock: PaperRect, paper: PaperSize) -> [PaperRect] {
        let margin = 0.5, gap = 0.1
        let w = paper.width.inches, h = paper.height.inches
        return labels.enumerated().map { i, label in
            let others = labels.enumerated().filter { $0.offset != i }.map { $0.element }
            let sameRow = others.filter { abs($0.midY - label.midY) < 1 }
            var left = margin, right = w - margin
            if let neighbour = sameRow.filter({ $0.midX < label.midX }).max(by: { $0.midX < $1.midX }) {
                left = (neighbour.midX + label.midX) / 2
            }
            if let neighbour = sameRow.filter({ $0.midX > label.midX }).min(by: { $0.midX < $1.midX }) {
                right = (neighbour.midX + label.midX) / 2
            }
            // Stop short of a title block to the right, along the right edge.
            if titleBlock.minX > label.maxX { right = min(right, titleBlock.minX - gap) }
            var top = margin
            let above = others.filter { $0.maxY < label.minY && $0.midX > left && $0.midX < right }
            if let nearest = above.max(by: { $0.maxY < $1.maxY }) { top = nearest.maxY + gap }
            let bottom = min(label.maxY + gap, h - margin)
            return .inches(x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0))
        }
    }
}

/// What one line of text says about scale, if anything.
enum ScaleText: Hashable, Sendable {
    case scale(DrawingScale)
    case notToScale
    case asNoted
    case unreadable(String)
    /// `SCALE:` with its value on another line.
    case labelOnly

    /// Reads a line: nil when it says nothing about scale.
    static func read(_ line: String) -> ScaleText? {
        let upper = line.uppercased()
        let letters = String(upper.filter { $0.isLetter || $0 == " " })
        let words = letters.split(separator: " ")
        if upper.contains("NOT TO SCALE") || words.contains("NTS")
            || upper.replacingSpaces().contains("N.T.S") { return .notToScale }
        guard let range = upper.firstRange(of: "SCALE") else { return nil }
        // `SCALE` must be a word of its own (not `GRAYSCALE`, `SCALED`).
        if range.lowerBound > upper.startIndex, upper[upper.index(before: range.lowerBound)].isLetter { return nil }
        if range.upperBound < upper.endIndex, upper[range.upperBound].isLetter { return nil }
        var rest = upper[range.upperBound...].drop { $0 == " " }
        if rest.first == ":" || rest.first == "=" { rest = rest.dropFirst().drop { $0 == " " } }
        let value = String(rest).trimmedSpaces()
        if value.isEmpty { return .labelOnly }
        let compact = value.filter(\.isLetter)
        if compact.hasPrefix("ASNOTED") || compact.hasPrefix("ASSHOWN") || compact.hasPrefix("ASINDICATED")
            || compact == "VARIES" { return .asNoted }
        switch DrawingScale.read(value) {
        case .scale(let scale): return .scale(scale)
        case .notToScale: return .notToScale
        case .cantTell: return .unreadable(value)
        }
    }
}

extension String {
    fileprivate func trimmedSpaces() -> String {
        String(drop { $0 == " " }.reversed().drop { $0 == " " }.reversed())
    }

    fileprivate func replacingSpaces() -> String { filter { $0 != " " } }
}
