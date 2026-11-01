import XCTest
@testable import VellumCore

/// The zoom from a whole plant to a valve, proved in numbers (AGENTS.md: scale is the product).
final class ViewportTests: XCTestCase {
    private let duoWidth = 951.0, duoHeight = 669.0

    private func duo(pointsPerInch: Double = 1, centre: CanvasPoint = .origin) -> Viewport {
        Viewport(centre: centre, pointsPerInch: pointsPerInch, screenWidth: duoWidth, screenHeight: duoHeight)
    }

    func testScreenAndCanvasPointsRoundTrip() {
        let viewport = duo(pointsPerInch: 0.37, centre: CanvasPoint(x: .feet(120), y: .feet(-35)))
        let point = CanvasPoint(x: .feet(97, inches: 3.5), y: .feet(-12))
        let back = viewport.canvasPoint(for: viewport.screenPoint(for: point))
        XCTAssertEqual(back.x.inches, point.x.inches, accuracy: 1e-9)
        XCTAssertEqual(back.y.inches, point.y.inches, accuracy: 1e-9)
        XCTAssertEqual(viewport.screenPoint(for: viewport.centre), ScreenPoint(x: duoWidth / 2, y: duoHeight / 2))
    }

    func testTheZoomOutShowsAWholePlantAcrossTheDuo() {
        // Hundreds of feet on screen, with room to spare: at the least zoom more than five miles fit across.
        let least = duo(pointsPerInch: Viewport.minimumPointsPerInch)
        XCTAssertGreaterThan(least.visibleRect.size.width.feet, 26_400)
        // A 1,000-foot plant fits within the zoom range.
        var plant = duo()
        plant.fit(CanvasRect(origin: .origin, size: CanvasSize(width: .feet(1_000), height: .feet(600))))
        XCTAssertGreaterThan(plant.pointsPerInch, Viewport.minimumPointsPerInch)
        XCTAssertGreaterThanOrEqual(plant.visibleRect.size.width.feet, 1_000)
    }

    func testTheZoomInShowsAValveInInches() {
        let most = duo(pointsPerInch: Viewport.maximumPointsPerInch)
        XCTAssertLessThan(most.visibleRect.size.width.inches, 1)
        // A 4" valve fits within the zoom range and fills the screen.
        var valve = duo()
        valve.fit(CanvasRect(origin: .origin, size: CanvasSize(width: .inches(4), height: .inches(3))))
        XCTAssertLessThan(valve.pointsPerInch, Viewport.maximumPointsPerInch)
        XCTAssertEqual(valve.visibleRect.size.width.inches, 4 / 0.9 * 951 / 951, accuracy: 0.6)
    }

    func testAPinchKeepsTheCanvasPointUnderTheFingersStill() {
        var viewport = duo(pointsPerInch: 0.5, centre: CanvasPoint(x: .feet(40), y: .feet(10)))
        let fingers = ScreenPoint(x: 700, y: 120)
        let under = viewport.canvasPoint(for: fingers)
        viewport.zoom(by: 37, about: fingers)
        XCTAssertEqual(viewport.pointsPerInch, 18.5, accuracy: 1e-12)
        let after = viewport.screenPoint(for: under)
        XCTAssertEqual(after.x, fingers.x, accuracy: 1e-9)
        XCTAssertEqual(after.y, fingers.y, accuracy: 1e-9)
    }

    func testZoomStopsAtItsLimits() {
        var viewport = duo()
        viewport.zoom(by: 1e9, about: ScreenPoint(x: 10, y: 10))
        XCTAssertEqual(viewport.pointsPerInch, Viewport.maximumPointsPerInch)
        viewport.zoom(by: 1e-15, about: ScreenPoint(x: 10, y: 10))
        XCTAssertEqual(viewport.pointsPerInch, Viewport.minimumPointsPerInch)
        viewport.zoom(by: 0, about: ScreenPoint(x: 10, y: 10))
        viewport.zoom(by: .nan, about: ScreenPoint(x: 10, y: 10))
        XCTAssertEqual(viewport.pointsPerInch, Viewport.minimumPointsPerInch)
    }

    func testPanningMovesTheCanvasWithTheFingers() {
        var viewport = duo(pointsPerInch: 2)
        let point = CanvasPoint(x: .feet(3), y: .feet(1))
        let before = viewport.screenPoint(for: point)
        viewport.pan(dx: 40, dy: -24)
        let after = viewport.screenPoint(for: point)
        XCTAssertEqual(after.x - before.x, 40, accuracy: 1e-9)
        XCTAssertEqual(after.y - before.y, -24, accuracy: 1e-9)
    }

    func testFittingCentresTheRegionInTheSpaceTheChromeLeaves() {
        // The drafting rail's chrome: rail on the left, top bar, status bar, tab rail on the right.
        let insets = ScreenInsets(top: 56, left: 70, bottom: 50, right: 92)
        let region = CanvasRect(origin: CanvasPoint(x: .feet(-10), y: .feet(-5)), size: CanvasSize(width: .feet(200), height: .feet(50)))
        var viewport = duo()
        viewport.fit(region, insets: insets, fill: 0.9)
        // Width limits: 951 - 162 = 789 free points for 2,400 inches, filled to 90%.
        XCTAssertEqual(viewport.pointsPerInch, 789.0 / 2_400 * 0.9, accuracy: 1e-12)
        let topLeft = viewport.screenPoint(for: region.origin)
        let bottomRight = viewport.screenPoint(for: CanvasPoint(x: region.maxX, y: region.maxY))
        XCTAssertEqual((topLeft.x + bottomRight.x) / 2, (70 + (951 - 92)) / 2, accuracy: 1e-9)
        XCTAssertEqual((topLeft.y + bottomRight.y) / 2, (56 + (669 - 50)) / 2, accuracy: 1e-9)
        XCTAssertEqual(bottomRight.x - topLeft.x, 789 * 0.9, accuracy: 1e-9)
    }

    func testFittingAPointKeepsTheZoom() {
        var viewport = duo(pointsPerInch: 3)
        viewport.fit(CanvasRect(origin: CanvasPoint(x: .feet(5), y: .feet(5)), size: CanvasSize(width: .zero, height: .zero)))
        XCTAssertEqual(viewport.pointsPerInch, 3)
        XCTAssertEqual(viewport.centre, CanvasPoint(x: .feet(5), y: .feet(5)))
    }

    // MARK: Scale bar

    func testTheScaleBarIsTheLongestRoundLengthThatFits() {
        // 90 points at 1 point per inch: 6' is too long (72" fits, 120" doesn't) — 5' is the round length.
        XCTAssertEqual(ScaleBar.length(fitting: 90, pointsPerInch: 1, units: .feetAndInches), .feet(5))
        XCTAssertEqual(CanvasUnits.feetAndInches.format(ScaleBar.length(fitting: 90, pointsPerInch: 1, units: .feetAndInches)), "5'-0\"")
        // Zoomed out on a plant, 0.01 pt/in: 9,000 inches fit, so 500'.
        XCTAssertEqual(ScaleBar.length(fitting: 90, pointsPerInch: 0.01, units: .feetAndInches), .feet(500))
        // Zoomed in on a valve, 100 pt/in: 0.9" fits, so 1/2".
        XCTAssertEqual(ScaleBar.length(fitting: 90, pointsPerInch: 100, units: .feetAndInches), .inches(0.5))
        // Metric at 1 pt/in: 90" is 2,286 mm, so 2 m.
        XCTAssertEqual(ScaleBar.length(fitting: 90, pointsPerInch: 1, units: .metric), .millimetres(2_000))
        XCTAssertEqual(CanvasUnits.metric.format(Length.millimetres(2_000)), "2.000 m")
    }

    func testTheScaleBarIsNeverLongerThanItsSpaceAcrossTheWholeZoomRange() {
        var ppi = Viewport.minimumPointsPerInch * 1.0001
        while ppi < Viewport.maximumPointsPerInch {
            for units in CanvasUnits.allCases {
                let length = ScaleBar.length(fitting: 90, pointsPerInch: ppi, units: units)
                XCTAssertLessThanOrEqual(ScaleBar.points(for: length, pointsPerInch: ppi), 90 + 1e-9, "\(units) at \(ppi)")
                XCTAssertGreaterThan(ScaleBar.points(for: length, pointsPerInch: ppi), 30, "\(units) at \(ppi)")
            }
            ppi *= 1.37
        }
    }

    /// The zooms to check the scale bar at: from the least to the most zoom in small steps, both limits included.
    private var zoomRange: [Double] {
        var zooms: [Double] = []
        var ppi = Viewport.minimumPointsPerInch
        while ppi < Viewport.maximumPointsPerInch {
            zooms.append(ppi)
            ppi *= 1.07
        }
        return zooms + [Viewport.maximumPointsPerInch]
    }

    func testTheScaleBarsLabelReadsItsLengthExactlyAtEveryZoomInEveryUnits() {
        for units in CanvasUnits.allCases {
            for ppi in zoomRange {
                let mark = ScaleBar.mark(fitting: 90, pointsPerInch: ppi, units: units)
                guard let read = Self.inches(readFrom: mark.label) else {
                    XCTFail("\(units) at \(ppi): can't read \(mark.label)")
                    continue
                }
                XCTAssertEqual(read, mark.length.inches, accuracy: 1e-9, "\(units) at \(ppi): \(mark.label)")
                let points = ScaleBar.points(for: mark.length, pointsPerInch: ppi)
                XCTAssertLessThanOrEqual(points, 90 + 1e-9, "\(units) at \(ppi)")
                if ppi > Viewport.minimumPointsPerInch { XCTAssertGreaterThan(points, 30, "\(units) at \(ppi)") }
            }
        }
    }

    func testDecimalFeetScaleBarsAreWholeHundredthsOrASixteenthInInches() {
        // At the most zoom 90 points is 0.09", shorter than 0.01' (0.12"), so the bar is 1/16" and says so in inches.
        let closest = ScaleBar.mark(fitting: 90, pointsPerInch: Viewport.maximumPointsPerInch, units: .decimalFeet)
        XCTAssertEqual(closest.length, .inches(1.0 / 16))
        XCTAssertEqual(closest.label, "1/16\"")
        // At 700 pt/in, 0.01' is 84 points and fits.
        let hundredth = ScaleBar.mark(fitting: 90, pointsPerInch: 700, units: .decimalFeet)
        XCTAssertEqual(hundredth.label, "0.01'")
        XCTAssertEqual(hundredth.length.inches, 0.12, accuracy: 1e-12)
        // At 1 pt/in, 7.5' fits: 5.00'.
        XCTAssertEqual(ScaleBar.mark(fitting: 90, pointsPerInch: 1, units: .decimalFeet).label, "5.00'")
        // At 30 pt/in, 3" (0.25') fits: 0.20'.
        XCTAssertEqual(ScaleBar.mark(fitting: 90, pointsPerInch: 30, units: .decimalFeet).label, "0.20'")
    }

    /// The length a scale bar label reads, in inches: `12'-6 1/2"`, `1/16"`, `12.54'`, `350 mm` or `12.540 m`.
    private static func inches(readFrom label: String) -> Double? {
        func fraction(_ text: Substring) -> Double? {
            let parts = text.split(separator: "/")
            if parts.count == 1 { return Double(parts[0]) }
            guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]) else { return nil }
            return n / d
        }
        func mixed(_ text: Substring) -> Double? {
            var total = 0.0
            for part in text.split(separator: " ") {
                guard let value = fraction(part) else { return nil }
                total += value
            }
            return total
        }
        if label.hasSuffix(" mm") { return Double(label.dropLast(3)).map { $0 / 25.4 } }
        if label.hasSuffix(" m") { return Double(label.dropLast(2)).map { $0 * 1000 / 25.4 } }
        if label.hasSuffix("\""), let dash = label.firstIndex(of: "-") {
            guard let feet = Double(label[..<dash].dropLast()),
                  let inches = mixed(label[label.index(after: dash)...].dropLast()) else { return nil }
            return feet * 12 + inches
        }
        if label.hasSuffix("\"") { return mixed(label.dropLast()[...]) }
        if label.hasSuffix("'") { return Double(label.dropLast()).map { $0 * 12 } }
        return nil
    }

    // MARK: Position

    func testThePositionReadsInCanvasUnitsWithYCountingUp() {
        let point = CanvasPoint(x: .feet(12, inches: 6), y: .feet(3))
        XCTAssertEqual(CanvasUnits.feetAndInches.formatPosition(point), "X 12'-6\"  Y -3'-0\"")
        XCTAssertEqual(CanvasUnits.decimalFeet.formatPosition(point), "X 12.50'  Y -3.00'")
        XCTAssertEqual(CanvasUnits.feetAndInches.formatPosition(.origin), "X 0'-0\"  Y 0'-0\"")
    }
}
