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

/// A rectangle on the canvas with a paper size and a drawing scale, such as 24 × 36 at 1/4" = 1'-0", with its top-left
/// corner at `origin`. It prints, exports or goes to an agent as one sheet.
public struct Frame: Hashable, Sendable {
    public var paper: PaperSize
    public var scale: DrawingScale
    public var origin: CanvasPoint

    public init(paper: PaperSize, scale: DrawingScale, origin: CanvasPoint = .origin) {
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
}
