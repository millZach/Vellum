/// A sheet of paper's printed width and height, as a PDF page or a frame has it.
///
/// The named sizes are written short side by long side, as the trade says them (24 × 36), so they stand portrait;
/// `landscape` turns one on its side, as most drawings are plotted.
public struct PaperSize: Hashable, Sendable {
    public var width: PrintedLength
    public var height: PrintedLength

    public init(width: PrintedLength, height: PrintedLength) {
        self.width = width
        self.height = height
    }

    /// A paper size in printed inches, for a custom size or a PDF page's own.
    public static func inches(_ width: Double, by height: Double) -> PaperSize {
        PaperSize(width: .inches(width), height: .inches(height))
    }

    /// 8.5 × 11, ANSI A.
    public static let letter = inches(8.5, by: 11)
    /// 11 × 17, ANSI B.
    public static let tabloid = inches(11, by: 17)
    /// 24 × 36, ARCH D.
    public static let archD = inches(24, by: 36)
    /// 30 × 42, ARCH E1.
    public static let archE1 = inches(30, by: 42)

    /// The same paper with its long side across.
    public var landscape: PaperSize {
        width >= height ? self : PaperSize(width: height, height: width)
    }
}

/// One sheet's identity within a canvas. Sheets are numbered in the order they are placed (#11).
public struct SheetID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public static func < (lhs: SheetID, rhs: SheetID) -> Bool { lhs.value < rhs.value }
    public var description: String { "sheet \(value)" }
}

/// A rectangle on a sheet's paper, in printed inches from the paper's top-left corner, y running down the page.
public struct PaperRect: Hashable, Sendable {
    public var x: PrintedLength
    public var y: PrintedLength
    public var width: PrintedLength
    public var height: PrintedLength

    public init(x: PrintedLength, y: PrintedLength, width: PrintedLength, height: PrintedLength) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// A rectangle in printed inches.
    public static func inches(x: Double, y: Double, width: Double, height: Double) -> PaperRect {
        PaperRect(x: .inches(x), y: .inches(y), width: .inches(width), height: .inches(height))
    }

    public var minX: Double { x.inches }
    public var minY: Double { y.inches }
    public var maxX: Double { x.inches + width.inches }
    public var maxY: Double { y.inches + height.inches }
    public var midX: Double { x.inches + width.inches / 2 }
    public var midY: Double { y.inches + height.inches / 2 }

    public func contains(_ point: PaperPoint) -> Bool {
        point.x.inches >= minX && point.x.inches <= maxX && point.y.inches >= minY && point.y.inches <= maxY
    }

    /// Whether a point is inside, or within `slack` printed inches of an edge.
    func contains(_ point: PaperPoint, within slack: Double) -> Bool {
        point.x.inches >= minX - slack && point.x.inches <= maxX + slack
            && point.y.inches >= minY - slack && point.y.inches <= maxY + slack
    }

    /// The smallest rectangle holding both.
    public func union(_ other: PaperRect) -> PaperRect {
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        return .inches(x: x0, y: y0, width: max(maxX, other.maxX) - x0, height: max(maxY, other.maxY) - y0)
    }
}

/// Which page of which PDF a sheet shows: the PDF as it is kept on the Duo (its Dropbox content hash names the file in
/// the canvas folder's `sheets` folder, ADR-0014), where it came from in Dropbox, and the sheet number Vellum read off
/// the page's title block.
public struct SheetPage: Hashable, Sendable {
    /// The PDF's name on the Duo: its Dropbox content hash, so the same PDF placed twice is kept once.
    public var file: String
    /// The PDF's file name, as Dropbox shows it.
    public var name: String
    /// Where the PDF is in Dropbox, as Dropbox writes it.
    public var path: String
    /// The page, counting from 0.
    public var index: Int
    /// The sheet number read off the title block, such as `M-101`; nil when none was read.
    public var number: String?

    public init(file: String, name: String, path: String, index: Int, number: String? = nil) {
        self.file = file
        self.name = name
        self.path = path
        self.index = index
        self.number = number
    }

    /// What the sheet is called on the canvas: its sheet number, or its file name and page.
    public var title: String { number ?? "\(name) p\(index + 1)" }
}

/// A region of a sheet's paper drawn at a scale of its own, such as a detail marked `SCALE: 1 1/2" = 1'-0"` on an AS
/// NOTED sheet (#11, CONTEXT.md "Scale area"). The sheet is placed at its main scale; inside the area, a measure or a
/// dimension reads the area's scale instead, or printed inches marked NTS when the area is not to scale.
public struct ScaleArea: Hashable, Sendable {
    /// What the area is called on the sheet: `Detail 2`.
    public var name: String
    /// Where it is on the paper.
    public var rect: PaperRect
    public var scale: Sheet.Scale

    public init(name: String, rect: PaperRect, scale: Sheet.Scale) {
        self.name = name
        self.rect = rect
        self.scale = scale
    }

    /// The area's label on the canvas: `Detail 2 · 1 1/2" = 1'-0"`.
    public var label: String { "\(name) · \(scale)" }
}

/// A PDF page placed on the canvas at its drawing scale (ADR-0002). `origin` is its top-left corner before it is turned,
/// so its centre is `origin` plus half its size at any angle, and `angle` turns it about that centre (#44). A scaled
/// sheet covers real-world lengths; an NTS sheet sits at its printed size and every length read on it is a printed
/// length marked NTS. Since #11 a sheet can hold scale areas, details drawn at scales of their own, where lengths read
/// at the area's scale; the sheet itself is placed at its main scale.
public struct Sheet: Hashable, Sendable, Identifiable {
    /// How the sheet is scaled: at a drawing scale, or not to scale.
    public enum Scale: Hashable, Sendable, CustomStringConvertible {
        case drawn(DrawingScale)
        case notToScale

        /// Canvas inches per printed inch: the scale's real inches per printed inch, or 1 for NTS, which is placed at
        /// its printed size.
        public var canvasPerPrinted: Double {
            switch self {
            case .drawn(let scale): scale.realPerPrinted
            case .notToScale: 1
            }
        }

        /// `1/4" = 1'-0"`, or `NTS`.
        public var description: String {
            switch self {
            case .drawn(let scale): scale.description
            case .notToScale: "NTS"
            }
        }
    }

    public let id: SheetID
    public var paper: PaperSize
    public var scale: Scale
    public var origin: CanvasPoint
    /// The PDF page the sheet shows; nil for a sheet made in a test.
    public var page: SheetPage?
    /// The details drawn at scales other than the sheet's own (#11).
    public var areas: [ScaleArea]
    /// Whether the page inverts badly (a scan, coloured fills), so dark mode shows it dimmed rather than inverted
    /// (`SheetDisplay`, `SheetTone`). Decided once, when the sheet is placed.
    public var invertsBadly: Bool
    /// How far the sheet is turned about its centre, in degrees counter-clockwise on screen, from 0 up to 360 (#44).
    public var angle: Double

    public init(id: SheetID = SheetID(0), paper: PaperSize, scale: Scale, origin: CanvasPoint = .origin,
                page: SheetPage? = nil, areas: [ScaleArea] = [], invertsBadly: Bool = false, angle: Double = 0) {
        self.id = id
        self.paper = paper
        self.scale = scale
        self.origin = origin
        self.page = page
        self.areas = areas
        self.invertsBadly = invertsBadly
        self.angle = angle
    }

    public var isNotToScale: Bool { scale == .notToScale }

    /// Canvas inches per printed inch of the sheet's paper.
    public var canvasPerPrinted: Double { scale.canvasPerPrinted }

    /// The sheet's width and height on the canvas, whatever its angle.
    public var size: CanvasSize {
        CanvasSize(width: canvasLength(of: paper.width), height: canvasLength(of: paper.height))
    }

    /// The point the sheet turns about.
    public var centre: CanvasPoint {
        let size = self.size
        return origin.offsetBy(dx: size.width / 2, dy: size.height / 2)
    }

    /// The smallest rectangle square to the canvas holding the sheet: exactly the sheet at 0°. For culling and zoom to
    /// everything; use `size` for how big the sheet is, and `contains` for what is on it.
    public var bounds: CanvasRect {
        if angle == 0 { return CanvasRect(origin: origin, size: size) }
        return CanvasRect.enclosing(corners)
    }

    /// The paper's four corners on the canvas: its top left, top right, bottom right and bottom left as printed.
    public var corners: [CanvasPoint] {
        canvasCorners(of: PaperRect(x: .inches(0), y: .inches(0), width: paper.width, height: paper.height))
    }

    /// Whether a canvas point is on the sheet, within `edgeAllowance` of its edge.
    public func contains(_ point: CanvasPoint) -> Bool {
        PaperRect(x: .inches(0), y: .inches(0), width: paper.width, height: paper.height)
            .contains(paperPoint(at: point), within: edgeAllowanceOnPaper)
    }

    /// How far past an edge of the sheet or a scale area, in ink-grid steps on the canvas, a point still reads as on it:
    /// 64 steps, 1/1024 inch, 64 times finer than the sixteenth the app shows. A mark's points are kept on the grid, so each
    /// turn or scale change of the sheet rounds a point that lay exactly on an edge again, and a snap to a sheet's edge
    /// (#57) rounds the point it takes. The roundings add up like a random walk: about 26 steps at worst after 1,000 turns
    /// and 51 after 5,000 in a simulation, so 64 keeps a mark on an edge in its sheet and scale area through many turns (#49).
    /// Without it a mark on a scale area's edge would lose the area's scale, or its NTS.
    public static let edgeAllowance = 64 / CanvasPoint.gridUnitsPerInch

    /// `edgeAllowance` in printed inches of this sheet.
    private var edgeAllowanceOnPaper: Double { Self.edgeAllowance / canvasPerPrinted }

    /// Where a point on the sheet's paper lands on the canvas.
    public func canvasPoint(at paperPoint: PaperPoint) -> CanvasPoint {
        let flat = origin.offsetBy(dx: canvasLength(of: paperPoint.x), dy: canvasLength(of: paperPoint.y))
        return angle == 0 ? flat : SheetAngle.turn(flat, about: centre, by: angle)
    }

    /// Where a canvas point falls on the sheet's paper.
    public func paperPoint(at point: CanvasPoint) -> PaperPoint {
        let flat = angle == 0 ? point : SheetAngle.turn(point, about: centre, by: -angle)
        return PaperPoint(x: .inches((flat.x - origin.x).inches / canvasPerPrinted),
                          y: .inches((flat.y - origin.y).inches / canvasPerPrinted))
    }

    /// A rectangle of the paper's four corners on the canvas: its top left, top right, bottom right and bottom left as
    /// printed.
    public func canvasCorners(of rect: PaperRect) -> [CanvasPoint] {
        [(rect.minX, rect.minY), (rect.maxX, rect.minY), (rect.maxX, rect.maxY), (rect.minX, rect.maxY)].map {
            canvasPoint(at: PaperPoint(x: .inches($0.0), y: .inches($0.1)))
        }
    }

    /// The scale area a canvas point falls in, if any; the last one listed wins where two overlap.
    public func area(at point: CanvasPoint) -> ScaleArea? {
        guard contains(point), !areas.isEmpty else { return nil }
        let onPaper = paperPoint(at: point)
        return areas.last { $0.rect.contains(onPaper, within: edgeAllowanceOnPaper) }
    }

    /// The scale lengths read at a canvas point on this sheet: its scale area's, or the sheet's own.
    public func scale(at point: CanvasPoint) -> Scale { area(at: point)?.scale ?? scale }

    /// What a length printed on this sheet reads as: a real length on a scaled sheet, the printed length marked NTS on
    /// an NTS sheet.
    public func measure(printed: PrintedLength) -> Measure {
        Self.measure(printed: printed, at: scale)
    }

    /// What a printed length reads as at a scale.
    public static func measure(printed: PrintedLength, at scale: Scale) -> Measure {
        switch scale {
        case .drawn(let drawingScale): .real(drawingScale.realLength(of: printed))
        case .notToScale: .notToScale(printed)
        }
    }

    /// The sheet's label on the canvas: its title and scale, `M-101 · 1/4" = 1'-0"`, with how many scale areas it
    /// holds: `D-501 · 1" = 1'-0" + 2 scale areas`.
    public var label: String {
        var text = "\(page?.title ?? "Sheet") · \(scale)"
        if !areas.isEmpty { text += " + \(areas.count) scale area\(areas.count == 1 ? "" : "s")" }
        return text
    }

    /// The same sheet under another id.
    func withID(_ id: SheetID) -> Sheet {
        Sheet(id: id, paper: paper, scale: scale, origin: origin, page: page, areas: areas, invertsBadly: invertsBadly,
              angle: angle)
    }

    /// How long a printed length is on the canvas. An NTS sheet is placed at its printed size, so there the canvas
    /// length has the printed length's value but is not a real one: read lengths on a sheet through `measure` or
    /// `Canvas.measure`, which mark them NTS, never off its bounds.
    private func canvasLength(of printed: PrintedLength) -> Length {
        Length(inches: printed.inches * canvasPerPrinted)
    }
}

/// One frame's identity within a canvas. Frames are numbered in the order they are placed (#8).
public struct FrameID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public static func < (lhs: FrameID, rhs: FrameID) -> Bool { lhs.value < rhs.value }
    public var description: String { "frame \(value)" }
}

/// A rectangle on the canvas with a paper size and a drawing scale, such as 24 × 36 at 1/4" = 1'-0", with its top-left
/// corner at `origin`. It prints, exports or goes to an agent as one sheet. A canvas holds any number of them, each
/// numbered by its `id` in the order placed.
public struct Frame: Hashable, Sendable, Identifiable {
    public let id: FrameID
    public var paper: PaperSize
    public var scale: DrawingScale
    public var origin: CanvasPoint

    public init(id: FrameID = FrameID(0), paper: PaperSize, scale: DrawingScale, origin: CanvasPoint = .origin) {
        self.id = id
        self.paper = paper
        self.scale = scale
        self.origin = origin
    }

    /// The region of the canvas the frame takes in.
    public var bounds: CanvasRect {
        CanvasRect(origin: origin, size: CanvasSize(width: scale.realLength(of: paper.width),
                                                    height: scale.realLength(of: paper.height)))
    }

    public func contains(_ point: CanvasPoint) -> Bool { bounds.contains(point) }

    /// The frame's label on the canvas: its paper and its scale, `24×36 at 1/4" = 1'-0"`.
    public var label: String { "\(paper.name) at \(scale)" }

    /// The frame moved by a transform: its centre goes where the transform takes it. A frame's size is its paper at
    /// its scale, so resizing a selection moves a frame but never changes its paper or scale.
    public func transformed(by transform: CanvasTransform, id newID: FrameID? = nil) -> Frame {
        let box = bounds
        let centre = transform.apply(box.center)
        let origin = CanvasPoint(x: centre.x - box.size.width / 2, y: centre.y - box.size.height / 2)
        return Frame(id: newID ?? id, paper: paper, scale: scale, origin: origin.onInkGrid)
    }

    /// The same frame under another id.
    func withID(_ id: FrameID) -> Frame { Frame(id: id, paper: paper, scale: scale, origin: origin) }

    /// The frame of a paper size that takes in a dragged rectangle, centred on it (#8, "drag a box"): the paper turned
    /// the way the drag is (landscape for a drag wider than tall, portrait otherwise) at the largest standard drawing
    /// scale whose paper still covers the drag, the one with the fewest real inches to the printed inch
    /// (`DrawingScale.frameScales`). A drag larger than the paper covers at every standard scale gets the smallest
    /// scale there is. Its corner is kept on the ink grid, so it reopens exactly.
    public static func fitting(_ rect: CanvasRect, paper: PaperSize, units: CanvasUnits, id: FrameID = FrameID(0))
        -> Frame {
        let width = rect.size.width.inches.magnitude, height = rect.size.height.inches.magnitude
        let turned = width > height ? paper.landscape : paper.portrait
        let scales = DrawingScale.frameScales(for: units)
        let scale = scales.first {
            $0.realLength(of: turned.width).inches >= width && $0.realLength(of: turned.height).inches >= height
        } ?? scales[scales.count - 1]
        let size = CanvasSize(width: scale.realLength(of: turned.width), height: scale.realLength(of: turned.height))
        let centre = CanvasPoint(x: .inches(min(rect.minX.inches, rect.maxX.inches) + width / 2),
                                 y: .inches(min(rect.minY.inches, rect.maxY.inches) + height / 2))
        let origin = CanvasPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2).onInkGrid
        return Frame(id: id, paper: turned, scale: scale, origin: origin)
    }
}

extension PaperSize {
    /// The paper sizes a frame offers, smallest first: 8.5 × 11, 11 × 17, 24 × 36 and 30 × 42.
    public static let frameSizes: [PaperSize] = [.letter, .tabloid, .archD, .archE1]

    /// The paper a new frame starts on: 24 × 36, ARCH D.
    public static let defaultFrame = PaperSize.archD

    /// The same paper with its long side down.
    public var portrait: PaperSize {
        width <= height ? self : PaperSize(width: height, height: width)
    }

    /// The paper's name, short side first, as the trade says it: `24×36`, `8.5×11`. It is the same either way round.
    public var name: String {
        let short = min(width.inches, height.inches), long = max(width.inches, height.inches)
        return "\(Self.number(short))×\(Self.number(long))"
    }

    private static func number(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        let tenths = (value * 10).rounded()
        if tenths == value * 10 { return "\(Int(tenths) / 10).\(Int(tenths) % 10)" }
        return String(value)
    }
}

extension DrawingScale {
    /// The standard drawing scales a frame dragged on the canvas chooses from, in the order tried: fewest real inches
    /// to the printed inch first. A feet-and-inches or decimal-feet canvas takes full size, the architectural scales
    /// and the engineering scales; a metric canvas takes the ratio scales 1:1 to 1:5000 in 1-2-5 steps.
    public static func frameScales(for units: CanvasUnits) -> [DrawingScale] {
        switch units {
        case .feetAndInches, .decimalFeet: imperialFrameScales
        case .metric: metricFrameScales
        }
    }

    private static let imperialFrameScales: [DrawingScale] =
        ([fullSize] + architecturalScales + engineeringScales).sorted { $0.realPerPrinted < $1.realPerPrinted }

    private static let metricFrameScales: [DrawingScale] =
        [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000].map { ratio(Double($0)) }
}
