import Foundation

/// A point of a symbol's drawing, in units of the symbol's width: the drawing is centred on (0, 0) and, for the starter
/// symbols, 1 across, x running right and y down as on the canvas (CONTEXT.md "Symbol").
public struct SymbolPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// One part of a symbol's drawing. Lines, circles and arcs become strokes when the symbol is placed; text becomes a
/// text box; a tag slot becomes the tag typed as an instrument bubble lands (`FT` over `101`), a text box too.
public enum SymbolPart: Hashable, Sendable {
    /// A polyline through its points.
    case line([SymbolPoint])
    case circle(centre: SymbolPoint, radius: Double)
    /// An arc from `start` to `end`, in radians, measured as on screen (y down): from π to 2π is the top half.
    case arc(centre: SymbolPoint, radius: Double, start: Double, end: Double)
    /// Letters centred on `centre`, `height` tall. `width` and `boxHeight` are the text box's own size when the symbol
    /// was saved from one; nil sizes it to its letters.
    case text(centre: SymbolPoint, height: Double, text: String, width: Double? = nil, boxHeight: Double? = nil)
    /// Where an instrument tag goes, two lines `height` tall each, centred on `centre`.
    case tag(centre: SymbolPoint, height: Double)
}

/// A drawing kept in the symbol library to place again and again (CONTEXT.md "Symbol"): its drawing in units of its
/// width, the size it prints across, and, for an instrument bubble, the tag letters it starts with. Placed, it is plain
/// ink and text boxes; nothing placed keeps a link back to it.
public struct Symbol: Hashable, Sendable, Identifiable {
    /// The starter symbols' ids are words (`gate`); a saved symbol's is a lower-case UUID, which names its file.
    public var id: String
    public var name: String
    /// How wide it prints, on the paper of any sheet it lands on.
    public var printedSize: PrintedLength
    /// The tag letters an instrument bubble starts with (`FT`); nil for a symbol with no tag slot.
    public var tagLetters: String?
    public var parts: [SymbolPart]

    public init(id: String, name: String, printedSize: PrintedLength, tagLetters: String? = nil, parts: [SymbolPart]) {
        self.id = id
        self.name = name
        self.printedSize = printedSize
        self.tagLetters = tagLetters
        self.parts = parts
    }

    /// Whether it is one of the six Vellum starts with, built into the app and never kept as a file.
    public var isStarter: Bool { Self.starters.contains { $0.id == id } }

    /// Whether it asks for a tag as it lands.
    public var hasTagSlot: Bool { parts.contains { if case .tag = $0 { true } else { false } } }

    /// How many straight pieces a whole circle is drawn with, and a half circle's arc.
    public static let circleSegments = 40

    /// The lines its drawing is made of, in units of its width: each line, circle and arc as a polyline.
    public var polylines: [[SymbolPoint]] {
        parts.compactMap { part -> [SymbolPoint]? in
            switch part {
            case .line(let points):
                return points.isEmpty ? nil : points
            case .circle(let c, let r):
                return Self.arcPoints(c, r, 0, 2 * .pi, segments: Self.circleSegments)
            case .arc(let c, let r, let start, let end):
                let segments = max(4, Int((Double(Self.circleSegments) * abs(end - start) / (2 * .pi)).rounded()))
                return Self.arcPoints(c, r, start, end, segments: segments)
            case .text, .tag:
                return nil
            }
        }
    }

    private static func arcPoints(_ c: SymbolPoint, _ r: Double, _ start: Double, _ end: Double, segments: Int)
        -> [SymbolPoint] {
        (0...segments).map { i in
            let a = start + (end - start) * Double(i) / Double(segments)
            return SymbolPoint(c.x + r * cos(a), c.y + r * sin(a))
        }
    }

    /// The rectangle the drawing covers in units of its width, its letters included: for the flyout's drawings.
    public var extent: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ x: Double, _ y: Double) {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
        for line in polylines { for p in line { add(p.x, p.y) } }
        for part in parts {
            switch part {
            case .text(let c, let h, let text, let w, let bh):
                let size = SymbolText.boxSize(text, height: h, width: w, boxHeight: bh)
                add(c.x - size.width / 2, c.y - size.height / 2)
                add(c.x + size.width / 2, c.y + size.height / 2)
            case .tag(let c, let h):
                let size = SymbolText.boxSize("FT\n101", height: h)
                add(c.x - size.width / 2, c.y - size.height / 2)
                add(c.x + size.width / 2, c.y + size.height / 2)
            default:
                break
            }
        }
        if minX > maxX { return (-0.5, -0.5, 0.5, 0.5) }
        return (minX, minY, maxX, maxY)
    }
}

// MARK: - The starter library

extension Symbol {
    /// A valve body: two triangles meeting point to point, from end to end across the width.
    private static let valveBody: [SymbolPart] = [
        .line([SymbolPoint(-0.5, 0), SymbolPoint(-0.5, -0.3), SymbolPoint(0.5, 0.3), SymbolPoint(0.5, 0)]),
        .line([SymbolPoint(-0.5, 0), SymbolPoint(-0.5, 0.3), SymbolPoint(0.5, -0.3), SymbolPoint(0.5, 0)]),
    ]

    /// The six symbols Vellum starts with, drawn for Vellum from the prototype at the tag `prototype/symbols` at variant
    /// A's printed sizes: valves 1/4" across, the bubble, junction box and motor 3/8".
    public static let starters: [Symbol] = [
        Symbol(id: "gate", name: "Gate valve", printedSize: .inches(0.25), parts: valveBody),
        Symbol(id: "ball", name: "Ball valve", printedSize: .inches(0.25),
               parts: valveBody + [.circle(centre: SymbolPoint(0, 0), radius: 0.1)]),
        Symbol(id: "ctrl", name: "Control valve", printedSize: .inches(0.25),
               parts: valveBody + [
                   .line([SymbolPoint(0, 0), SymbolPoint(0, -0.55)]),
                   .arc(centre: SymbolPoint(0, -0.55), radius: 0.28, start: .pi, end: 2 * .pi),
                   .line([SymbolPoint(-0.28, -0.55), SymbolPoint(0.28, -0.55)]),
               ]),
        Symbol(id: "bubble", name: "Instrument bubble", printedSize: .inches(0.375), tagLetters: "FT",
               parts: [.circle(centre: SymbolPoint(0, 0), radius: 0.5), .tag(centre: SymbolPoint(0, 0), height: 0.24)]),
        Symbol(id: "jb", name: "Junction box", printedSize: .inches(0.375),
               parts: [
                   .line([SymbolPoint(-0.5, -0.35), SymbolPoint(0.5, -0.35), SymbolPoint(0.5, 0.35),
                          SymbolPoint(-0.5, 0.35), SymbolPoint(-0.5, -0.35)]),
                   .text(centre: SymbolPoint(0, 0), height: 0.3, text: "JB"),
               ]),
        Symbol(id: "motor", name: "Motor", printedSize: .inches(0.375),
               parts: [.circle(centre: SymbolPoint(0, 0), radius: 0.5),
                       .text(centre: SymbolPoint(0, 0), height: 0.45, text: "M")]),
    ]
}

// MARK: - Placing

/// A stroke a placed symbol leaves: its points on the canvas and its width. It takes the pen and the markup colour in
/// hand when it goes on (`InkSession.place`).
public struct SymbolStroke: Hashable, Sendable {
    public var points: [CanvasPoint]
    public var width: Length

    public init(points: [CanvasPoint], width: Length) {
        self.points = points
        self.width = width
    }
}

/// A text box a placed symbol leaves: centred on where its letters go, sized to them.
public struct SymbolText: Hashable, Sendable {
    public var origin: CanvasPoint
    public var size: CanvasSize
    public var fontSize: Length
    public var text: String

    public init(origin: CanvasPoint, size: CanvasSize, fontSize: Length, text: String) {
        self.origin = origin
        self.size = size
        self.fontSize = fontSize
        self.text = text
    }

    /// Letters `fontSize` tall centred on a point, in a box sized to them.
    public static func centred(_ text: String, at centre: CanvasPoint, fontSize: Length) -> SymbolText {
        let box = boxSize(text, height: fontSize.inches)
        return centred(text, at: centre, fontSize: fontSize, size: CanvasSize(width: .inches(box.width),
                                                                                height: .inches(box.height)))
    }

    static func centred(_ text: String, at centre: CanvasPoint, fontSize: Length, size: CanvasSize) -> SymbolText {
        SymbolText(origin: CanvasPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2), size: size,
                   fontSize: fontSize, text: text)
    }

    /// The width a letter takes, as a share of the letter height: wide enough for a capital M, so a symbol's letters never
    /// wrap.
    static let letterWidth = 0.8
    /// The height a line takes, as a share of the letter height, as the system font sets it.
    static let lineHeight = 1.2

    /// The box letters `height` tall need: as wide as the longest line, as tall as the lines; or the size given.
    static func boxSize(_ text: String, height: Double, width: Double? = nil, boxHeight: Double? = nil)
        -> (width: Double, height: Double) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map(\.count).max() ?? 1
        return (width ?? Double(max(longest, 1)) * letterWidth * height,
                boxHeight ?? Double(max(lines.count, 1)) * lineHeight * height)
    }
}

/// The scale a symbol lands at (#41): where it is drawn its printed size on the paper.
public struct SymbolScale: Hashable, Sendable {
    /// Canvas inches per printed inch where it lands: the sheet's main scale, which a scale area shares on the canvas;
    /// 1 on an NTS sheet, placed at its printed size.
    public var canvasPerPrinted: Double
    /// The scale lengths read at the point: a scale area's, the sheet's, the frame's or 1/4" = 1'-0" off a sheet.
    public var reading: Sheet.Scale
    /// Where it lands, for the label: a sheet's title, a scale area's name, `the frame`; nil off a sheet.
    public var place: String?

    public init(canvasPerPrinted: Double, reading: Sheet.Scale, place: String?) {
        self.canvasPerPrinted = canvasPerPrinted
        self.reading = reading
        self.place = place
    }

    /// The scale off a sheet and off a frame: 1/4" = 1'-0", as the prototype has it.
    public static let offSheet = DrawingScale.architectural(inchesPerFoot: 0.25)

    /// The scale under a canvas point: the topmost sheet holding it (a scale area's reading inside one), else the
    /// topmost frame holding it (the scale it prints at), else 1/4" = 1'-0".
    public static func at(_ point: CanvasPoint, sheets: [Sheet], frames: [Frame]) -> SymbolScale {
        if let sheet = sheets.last(where: { $0.contains(point) }) {
            let area = sheet.area(at: point)
            return SymbolScale(canvasPerPrinted: sheet.canvasPerPrinted, reading: area?.scale ?? sheet.scale,
                               place: area?.name ?? sheet.page?.title ?? "the sheet")
        }
        if let frame = frames.last(where: { $0.contains(point) }) {
            return SymbolScale(canvasPerPrinted: frame.scale.realPerPrinted, reading: .drawn(frame.scale),
                               place: "the frame")
        }
        return SymbolScale(canvasPerPrinted: offSheet.realPerPrinted, reading: .drawn(offSheet), place: nil)
    }

    /// How wide a symbol of this printed size is on the canvas here.
    public func canvasSize(of printed: PrintedLength) -> Length { Length(inches: printed.inches * canvasPerPrinted) }

    /// What its width reads as here: a real length, or the printed length marked NTS.
    public func measure(of printed: PrintedLength) -> Measure { Sheet.measure(printed: printed, at: reading) }

    /// The printed size a canvas width is here: for Save as symbol's prefilled size.
    public func printed(of length: Length) -> PrintedLength { PrintedLength(inches: length.inches / canvasPerPrinted) }

    /// What the status bar and VoiceOver say about a symbol landing here: `3/8" printed · 1'-6" in M-201`, or off a
    /// sheet, `3/8" printed · off a sheet, at 1/4" = 1'-0"`.
    public func label(for printed: PrintedLength, units: CanvasUnits) -> String {
        let size = Self.printedText(printed) + " printed"
        guard let place else { return size + " · off a sheet, at \(reading)" }
        return size + " · " + units.format(measure(of: printed)) + " in " + place
    }

    /// The short form for the status bar, 28 characters or fewer when it can be: `3/8" printed · 1'-6"`.
    public func shortLabel(for printed: PrintedLength, units: CanvasUnits) -> String {
        Self.printedText(printed) + " printed · " + units.format(measure(of: printed))
    }

    /// A printed size to the 1/32": `3/8"`, `1 1/2"`.
    public static func printedText(_ printed: PrintedLength) -> String {
        let count = Int((printed.inches.magnitude * 32).rounded())
        return Fraction.mixed(count, over: 32, writeZero: false) + "\""
    }
}

/// A symbol's ink on the canvas, worked out before it goes on: its strokes, its text boxes, and the tag slot still to
/// be typed.
public struct PlacedSymbol: Hashable, Sendable {
    public var strokes: [SymbolStroke]
    public var texts: [SymbolText]
    /// Where the tag goes and its letter height, and the letters it starts with; nil for a symbol without a tag slot.
    public var tag: Tag?
    /// The rectangle the symbol covers on the canvas.
    public var bounds: CanvasRect

    public struct Tag: Hashable, Sendable {
        public var centre: CanvasPoint
        public var fontSize: Length
        public var letters: String

        /// The tag's text box: the letters over the number, `FT` over `101`. Empty letters and number make none.
        public func text(letters: String, number: String) -> SymbolText? {
            let l = letters.trimmingCharacters(in: .whitespaces), n = number.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty || !n.isEmpty else { return nil }
            let text = l.isEmpty ? n : n.isEmpty ? l : l + "\n" + n
            return SymbolText.centred(text, at: centre, fontSize: fontSize)
        }
    }
}

extension Symbol {
    /// The share of a symbol's width its lines are at most, so a symbol placed zoomed far out isn't a blot.
    public static let widestLine = 0.06

    /// The symbol's ink centred on a point, `size` across, upright: each point `centre + size × (x, y)`. Its lines are
    /// `lineWidth` wide, but never wider than `widestLine` of the symbol.
    public func placed(at centre: CanvasPoint, size: Length, lineWidth: Length) -> PlacedSymbol {
        let s = size.inches
        func at(_ p: SymbolPoint) -> CanvasPoint {
            CanvasPoint(x: .inches(centre.x.inches + s * p.x), y: .inches(centre.y.inches + s * p.y))
        }
        let width = Length(inches: min(lineWidth.inches, s * Self.widestLine))
        let strokes = polylines.map { SymbolStroke(points: $0.map(at), width: width) }
        var texts: [SymbolText] = []
        var tag: PlacedSymbol.Tag?
        for part in parts {
            switch part {
            case .text(let c, let h, let text, let w, let bh):
                let box = SymbolText.boxSize(text, height: h, width: w, boxHeight: bh)
                texts.append(SymbolText.centred(text, at: at(c), fontSize: .inches(h * s),
                                                size: CanvasSize(width: .inches(box.width * s),
                                                                 height: .inches(box.height * s))))
            case .tag(let c, let h):
                tag = PlacedSymbol.Tag(centre: at(c), fontSize: .inches(h * s), letters: tagLetters ?? "")
            default:
                break
            }
        }
        let e = extent
        let bounds = CanvasRect(origin: CanvasPoint(x: .inches(centre.x.inches + e.minX * s),
                                                    y: .inches(centre.y.inches + e.minY * s)),
                                size: CanvasSize(width: .inches((e.maxX - e.minX) * s),
                                                 height: .inches((e.maxY - e.minY) * s)))
        return PlacedSymbol(strokes: strokes, texts: texts, tag: tag, bounds: bounds)
    }
}

// MARK: - Save as symbol

/// A selection's ink made into a symbol's drawing (#41), as the prototype's Save as symbol does: centred on the middle of
/// what it covers and measured in its width, or its height when it is under a quarter as wide as tall, so it places at
/// any size.
public struct SymbolDrawing: Hashable, Sendable {
    public var parts: [SymbolPart]
    /// The tag letters a text box of letters over a number gave it (`FT` over `101`), which becomes its tag slot.
    public var tagLetters: String?
    /// The canvas length one unit of the drawing is: the selection's width, or its height.
    public var unit: Length
    /// The middle of what the selection covers.
    public var centre: CanvasPoint

    /// The drawing of these strokes and text boxes; nil when they cover nothing.
    public static func of(strokes: [InkStroke], texts: [TextBox]) -> SymbolDrawing? {
        let rects = strokes.compactMap(\.pathBounds) + texts.map(\.rect)
        guard let bounds = CanvasRect.union(rects) else { return nil }
        let w = bounds.size.width.inches.magnitude, h = bounds.size.height.inches.magnitude
        let unit = w < h * 0.25 ? h : w
        guard unit > 0 else { return nil }
        let c = bounds.center
        func local(_ p: CanvasPoint) -> SymbolPoint {
            SymbolPoint((p.x.inches - c.x.inches) / unit, (p.y.inches - c.y.inches) / unit)
        }
        var parts: [SymbolPart] = strokes.filter { !$0.points.isEmpty }.map { .line($0.points.map(local)) }
        var tagLetters: String?
        for box in texts {
            let middle = local(box.rect.center)
            if tagLetters == nil, let letters = SymbolTag.letters(ofTag: box.text) {
                tagLetters = letters
                parts.append(.tag(centre: middle, height: box.fontSize.inches / unit))
            } else {
                parts.append(.text(centre: middle, height: box.fontSize.inches / unit, text: box.text,
                                   width: box.size.width.inches / unit, boxHeight: box.size.height.inches / unit))
            }
        }
        return SymbolDrawing(parts: parts, tagLetters: tagLetters, unit: .inches(unit), centre: c)
    }
}

// MARK: - Tags

/// Instrument tags (#41): letters over a number, `FT` over `101`.
public enum SymbolTag {
    /// The first number a tag's letters take on a canvas.
    public static let first = 101

    /// The number after the highest tag with these letters on the canvas, 101 when there is none: what a bubble's tag
    /// starts at as it lands. Any text box of the letters over a number counts, typed or placed.
    public static func next(letters: String, in texts: [TextBox]) -> Int {
        let wanted = letters.uppercased()
        var highest = first - 1
        for box in texts {
            guard let (l, n) = split(box.text), l == wanted else { continue }
            highest = max(highest, n)
        }
        return highest + 1
    }

    /// The letters of a tag's text, when it is a tag: letters over a number.
    static func letters(ofTag text: String) -> String? { split(text)?.letters }

    private static func split(_ text: String) -> (letters: String, number: Int)? {
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == " " }).map { String($0) }
        guard lines.count == 2, !lines[0].isEmpty, lines[0].allSatisfy({ $0.isLetter }),
              lines[1].count <= 9, lines[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(lines[1]) else { return nil }
        return (lines[0].uppercased(), number)
    }
}
