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

/// A PDF page placed on the canvas at its drawing scale, with its top-left corner at `origin` (ADR-0002). A scaled
/// sheet covers real-world lengths; an NTS sheet sits at its printed size and every length read on it is a printed
/// length marked NTS.
public struct Sheet: Hashable, Sendable {
    /// How the sheet is scaled: at a drawing scale, or not to scale.
    public enum Scale: Hashable, Sendable {
        case drawn(DrawingScale)
        case notToScale
    }

    public var paper: PaperSize
    public var scale: Scale
    public var origin: CanvasPoint

    public init(paper: PaperSize, scale: Scale, origin: CanvasPoint = .origin) {
        self.paper = paper
        self.scale = scale
        self.origin = origin
    }

    public var isNotToScale: Bool { scale == .notToScale }

    /// The rectangle the sheet covers on the canvas.
    public var bounds: CanvasRect {
        CanvasRect(origin: origin, size: CanvasSize(width: canvasLength(of: paper.width),
                                                    height: canvasLength(of: paper.height)))
    }

    public func contains(_ point: CanvasPoint) -> Bool { bounds.contains(point) }

    /// Where a point on the sheet's paper lands on the canvas.
    public func canvasPoint(at paperPoint: PaperPoint) -> CanvasPoint {
        origin.offsetBy(dx: canvasLength(of: paperPoint.x), dy: canvasLength(of: paperPoint.y))
    }

    /// What a length printed on this sheet reads as: a real length on a scaled sheet, the printed length marked NTS on
    /// an NTS sheet.
    public func measure(printed: PrintedLength) -> Measure {
        switch scale {
        case .drawn(let drawingScale): .real(drawingScale.realLength(of: printed))
        case .notToScale: .notToScale(printed)
        }
    }

    /// How long a printed length is on the canvas. An NTS sheet is placed at its printed size, so there the canvas
    /// length has the printed length's value but is not a real one: read lengths on a sheet through `measure` or
    /// `Canvas.measure`, which mark them NTS, never off its bounds.
    private func canvasLength(of printed: PrintedLength) -> Length {
        switch scale {
        case .drawn(let drawingScale): drawingScale.realLength(of: printed)
        case .notToScale: Length(inches: printed.inches)
        }
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
