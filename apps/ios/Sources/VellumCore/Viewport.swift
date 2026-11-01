/// A point on the Duo's screen, in points from the top-left corner of the canvas view.
public struct ScreenPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Space the screen's chrome takes from each edge of the canvas view, in points.
public struct ScreenInsets: Hashable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = ScreenInsets()
}

/// The part of the canvas on screen: which canvas point sits at the centre of the view and how many screen points a
/// real inch takes. Everything drawn on the canvas, and every Pencil touch read off it, goes through this one mapping,
/// in `Double`, so a stroke drawn over a sheet lands on the same real-world spot at any zoom.
///
/// The zoom spans a whole plant to a valve: at the least, 0.002 points per inch puts about six miles across the
/// unfolded Duo; at the most, 1,000 points per inch puts under an inch across it. The most zoom stops where 1/16",
/// the finest length the canvas units show, still fits the status bar's 90-point scale bar.
public struct Viewport: Hashable, Sendable {
    /// The least zoom: about 33,000 feet across the Duo's 951 points.
    public static let minimumPointsPerInch = 0.002
    /// The most zoom: about 0.95 inch across the Duo's 951 points.
    public static let maximumPointsPerInch = 1_000.0

    /// The canvas point at the centre of the view.
    public var centre: CanvasPoint
    /// Screen points per real inch.
    public private(set) var pointsPerInch: Double
    public var screenWidth: Double
    public var screenHeight: Double

    public init(centre: CanvasPoint = .origin, pointsPerInch: Double = 1, screenWidth: Double, screenHeight: Double) {
        self.centre = centre
        self.pointsPerInch = Self.clamp(pointsPerInch)
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    /// Where a canvas point is on screen.
    public func screenPoint(for point: CanvasPoint) -> ScreenPoint {
        ScreenPoint(x: (point.x.inches - centre.x.inches) * pointsPerInch + screenWidth / 2,
                    y: (point.y.inches - centre.y.inches) * pointsPerInch + screenHeight / 2)
    }

    /// The canvas point under a screen point: where a Pencil touch lands.
    public func canvasPoint(for screen: ScreenPoint) -> CanvasPoint {
        CanvasPoint(x: .inches(centre.x.inches + (screen.x - screenWidth / 2) / pointsPerInch),
                    y: .inches(centre.y.inches + (screen.y - screenHeight / 2) / pointsPerInch))
    }

    /// A screen length as a real one at this zoom.
    public func canvasLength(ofScreen points: Double) -> Length { .inches(points / pointsPerInch) }

    /// The region of the canvas on screen.
    public var visibleRect: CanvasRect {
        CanvasRect(origin: canvasPoint(for: ScreenPoint(x: 0, y: 0)),
                   size: CanvasSize(width: canvasLength(ofScreen: screenWidth), height: canvasLength(ofScreen: screenHeight)))
    }

    /// Zooms by `factor`, keeping the canvas point under `anchor` where it is: a pinch about its fingers. The zoom
    /// stops at the limits.
    public mutating func zoom(by factor: Double, about anchor: ScreenPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let fixed = canvasPoint(for: anchor)
        pointsPerInch = Self.clamp(pointsPerInch * factor)
        centre = CanvasPoint(x: .inches(fixed.x.inches - (anchor.x - screenWidth / 2) / pointsPerInch),
                             y: .inches(fixed.y.inches - (anchor.y - screenHeight / 2) / pointsPerInch))
    }

    /// Moves the canvas with the fingers, by a distance in screen points.
    public mutating func pan(dx: Double, dy: Double) {
        centre = centre.offsetBy(dx: canvasLength(ofScreen: -dx), dy: canvasLength(ofScreen: -dy))
    }

    /// Fits a region of the canvas into the part of the view the chrome leaves free, filling `fill` of it (0.9 leaves
    /// a margin), within the zoom limits. An empty region keeps the zoom and centres on it.
    public mutating func fit(_ rect: CanvasRect, insets: ScreenInsets = .zero, fill: Double = 0.9) {
        let freeWidth = max(1, screenWidth - insets.left - insets.right)
        let freeHeight = max(1, screenHeight - insets.top - insets.bottom)
        let w = rect.size.width.inches.magnitude, h = rect.size.height.inches.magnitude
        if w > 0 || h > 0 {
            let across = w > 0 ? freeWidth / w : .infinity
            let down = h > 0 ? freeHeight / h : .infinity
            pointsPerInch = Self.clamp(min(across, down) * fill)
        }
        // The middle of the free area is offset from the middle of the view by half the inset difference.
        let offsetX = (insets.left - insets.right) / 2, offsetY = (insets.top - insets.bottom) / 2
        let middle = rect.center
        centre = CanvasPoint(x: .inches(middle.x.inches - offsetX / pointsPerInch),
                             y: .inches(middle.y.inches - offsetY / pointsPerInch))
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return value == .infinity ? maximumPointsPerInch : minimumPointsPerInch }
        return min(maximumPointsPerInch, max(minimumPointsPerInch, value))
    }
}

/// The scale bar in the status bar: a round length whose bar fits a space on screen, labelled exactly. Every length
/// it offers is one its label shows without rounding, so the bar and its label never disagree ("Scale is the
/// product").
public enum ScaleBar {
    /// A bar's length and the label under it, which reads that length exactly.
    public struct Mark: Hashable, Sendable {
        public let length: Length
        public let label: String
    }

    /// The longest round length whose bar is no longer than `maximumPoints` at this zoom, with its label.
    ///
    /// - Feet and inches steps 1/16", 1/8", 1/4", 1/2", 1", 2", 3", 6", then 1', 2', 5', 10', 20', 50' and on by
    ///   1-2-5: every one a whole number of sixteenths, which the units show exactly.
    /// - Decimal feet steps 0.01', 0.02', 0.05', 0.1' and on by 1-2-5: every one a whole number of hundredths of a
    ///   foot, which the units show exactly. Closer in than 0.01' fits, the bar falls back to 1/16", labelled in
    ///   inches, because 1/16" is not a whole hundredth of a foot.
    /// - Metric steps 1, 2 and 5 times a power of ten millimetres: whole millimetres, shown exactly.
    ///
    /// At a zoom so far out that even the shortest is too long, the shortest comes back.
    public static func mark(fitting maximumPoints: Double, pointsPerInch: Double, units: CanvasUnits) -> Mark {
        let longest = maximumPoints / pointsPerInch
        let candidates = marks(for: units)
        return candidates.last { $0.length.inches <= longest } ?? candidates[0]
    }

    /// The length of `mark(fitting:pointsPerInch:units:)`, for spacing the grid.
    public static func length(fitting maximumPoints: Double, pointsPerInch: Double, units: CanvasUnits) -> Length {
        mark(fitting: maximumPoints, pointsPerInch: pointsPerInch, units: units).length
    }

    /// The bar's length on screen for a length.
    public static func points(for length: Length, pointsPerInch: Double) -> Double { length.inches * pointsPerInch }

    /// 1, 2, 5, 10, 20, 50, ... for `decades` decades.
    private static func oneTwoFive(decades: Int) -> [Int] {
        var steps: [Int] = []
        var decade = 1
        for _ in 0..<decades {
            steps += [1, 2, 5].map { $0 * decade }
            decade *= 10
        }
        return steps
    }

    private static let feetAndInchesMarks: [Mark] = {
        let sixteenths = [1, 2, 4, 8, 16, 32, 48, 96] + oneTwoFive(decades: 7).map { $0 * 12 * 16 }
        return sixteenths.map { mark(.inches(Double($0) / 16), in: .feetAndInches) }
    }()

    private static let decimalFeetMarks: [Mark] = {
        let sixteenth = Length.inches(1.0 / 16)
        let fallback = Mark(length: sixteenth, label: Fraction.mixed(1, over: 16, writeZero: false) + "\"")
        return [fallback] + oneTwoFive(decades: 9).map { mark(.feet(Double($0) / 100), in: .decimalFeet) }
    }()

    private static let metricMarks: [Mark] = oneTwoFive(decades: 9).map { mark(.millimetres(Double($0)), in: .metric) }

    private static func mark(_ length: Length, in units: CanvasUnits) -> Mark { Mark(length: length, label: units.format(length)) }

    private static func marks(for units: CanvasUnits) -> [Mark] {
        switch units {
        case .feetAndInches: feetAndInchesMarks
        case .decimalFeet: decimalFeetMarks
        case .metric: metricMarks
        }
    }
}

extension CanvasUnits {
    /// A canvas position for the status bar, `X 12'-6"  Y -3'-0"`. Y is shown counting up the screen, as AutoCAD's
    /// model space and the prototype count it, though canvas points store y running down.
    public func formatPosition(_ point: CanvasPoint) -> String {
        "X \(format(point.x))  Y \(format(-point.y))"
    }
}
