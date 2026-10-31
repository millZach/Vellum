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

/// The scale bar in the status bar: a round length in the canvas units whose bar fits a space on screen.
public enum ScaleBar {
    /// The longest round length whose bar is no longer than `maximumPoints` at this zoom. Feet and inches and decimal
    /// feet step 1/16", 1/8", 1/4", 1/2", 1", 2", 3", 6", then 1', 2', 5', 10', 20', 50' and on by 1-2-5; metric
    /// steps 1, 2 and 5 times a power of ten millimetres. At a zoom so far out that even the shortest is too long,
    /// the shortest comes back.
    public static func length(fitting maximumPoints: Double, pointsPerInch: Double, units: CanvasUnits) -> Length {
        let longest = maximumPoints / pointsPerInch
        let candidates = steps(for: units)
        return candidates.last { $0.inches <= longest } ?? candidates[0]
    }

    /// The bar's length on screen for a length.
    public static func points(for length: Length, pointsPerInch: Double) -> Double { length.inches * pointsPerInch }

    private static let imperialSteps: [Length] = {
        var steps: [Length] = [1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2, 3, 6].map { .inches($0) }
        var decade = 1.0
        while decade <= 1_000_000 {
            steps += [1, 2, 5].map { .feet($0 * decade) }
            decade *= 10
        }
        return steps
    }()

    private static let metricSteps: [Length] = {
        var steps: [Length] = []
        var decade = 1.0
        while decade <= 100_000_000 {
            steps += [1, 2, 5].map { .millimetres($0 * decade) }
            decade *= 10
        }
        return steps
    }()

    private static func steps(for units: CanvasUnits) -> [Length] {
        units == .metric ? metricSteps : imperialSteps
    }
}

extension CanvasUnits {
    /// A canvas position for the status bar, `X 12'-6"  Y -3'-0"`. Y is shown counting up the screen, as AutoCAD's
    /// model space and the prototype count it, though canvas points store y running down.
    public func formatPosition(_ point: CanvasPoint) -> String {
        "X \(format(point.x))  Y \(format(-point.y))"
    }
}
