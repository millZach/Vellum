import XCTest
@testable import VellumCore

private func p(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .inches(x), y: .inches(y)) }

private func assertPoint(_ point: CanvasPoint?, _ x: Double, _ y: Double, accuracy: Double = 1e-9, _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    guard let point else { return XCTFail("no point \(message)", file: file, line: line) }
    XCTAssertEqual(point.x.inches, x, accuracy: accuracy, message, file: file, line: line)
    XCTAssertEqual(point.y.inches, y, accuracy: accuracy, message, file: file, line: line)
}

/// What the number pad accepts (#40). A bare number means inches on a feet-and-inches canvas, like AutoCAD.
final class ExactEntryTests: XCTestCase {
    func testEveryFeetAndInchesFormThePadAccepts() {
        let forms: [(String, Double)] = [
            ("12", 12), ("12'", 144), ("12'6", 150), ("12'6\"", 150), ("12'-6\"", 150), ("12' 6\"", 150), ("12'-6", 150),
            ("12'-6 1/2\"", 150.5), ("12'6-1/2", 150.5), ("12'6 1/2", 150.5), ("12'-6-1/2\"", 150.5),
            ("6\"", 6), ("6 1/2", 6.5), ("6-1/2", 6.5), ("6-1/2\"", 6.5), ("1/2", 0.5), ("1/2\"", 0.5), ("1/16", 0.0625),
            ("15/16", 0.9375), ("1 1/16", 1.0625), ("1-1/16", 1.0625), ("11/16", 0.6875), ("12.5", 12.5), ("12.5'", 150),
            (".5", 0.5), ("0'6", 6), ("12'0", 144), ("0'-0 1/16\"", 0.0625), ("139'11 15/16", 1679.9375), (" 12' ", 144),
        ]
        for (text, inches) in forms {
            XCTAssertEqual(CanvasUnits.feetAndInches.parseLength(text)?.inches, inches, "\(text)")
        }
    }

    /// Nothing is guessed: what can't be read as one length is refused.
    func testWhatThePadRefuses() {
        for text in ["", " ", "'", "\"", "/", "0", "0'", "0\"", "-12", "1/0", "61/2", "3/2", "12'6'", "12''", "1.5/2", "6.5 1/2",
                     "abc", "1 2", "1e3", "1..2", "12\"6", "1/2'", "6-", "99999999999"] {
            XCTAssertNil(CanvasUnits.feetAndInches.parseLength(text), "\(text)")
        }
    }

    /// Whatever the canvas shows can be typed back, to the 1/16" it shows.
    func testEveryLengthShownDownToASixteenthReadsBackExactly() {
        for sixteenths in 1...(3 * 192 + 7) {
            let inches = Double(sixteenths) / 16
            let shown = CanvasUnits.feetAndInches.format(Length.inches(inches))
            XCTAssertEqual(CanvasUnits.feetAndInches.parseLength(shown)?.inches, inches, shown)
        }
    }

    /// A bare number on a canvas in other units means that canvas's unit; the marks still mean feet and inches.
    func testABareNumberMeansTheCanvasUnit() throws {
        let feet = try XCTUnwrap(CanvasUnits.decimalFeet.parseLength("12.54"))
        XCTAssertEqual(feet.inches, 150.48, accuracy: 1e-9)
        XCTAssertEqual(CanvasUnits.decimalFeet.format(feet), "12.54'")
        XCTAssertEqual(CanvasUnits.decimalFeet.parseLength("6\"")?.inches, 6)
        XCTAssertEqual(CanvasUnits.decimalFeet.parseLength("2'6")?.inches, 30)

        let millimetres = try XCTUnwrap(CanvasUnits.metric.parseLength("350"))
        XCTAssertEqual(millimetres.millimetres, 350, accuracy: 1e-9)
        XCTAssertEqual(CanvasUnits.metric.format(millimetres), "350 mm")
        XCTAssertEqual(CanvasUnits.metric.format(try XCTUnwrap(CanvasUnits.metric.parseLength("12540"))), "12.540 m")
        XCTAssertEqual(CanvasUnits.metric.parseLength("12'")?.inches, 144)
    }

    func testAnglesAndSides() {
        XCTAssertEqual(ExactEntry.angle("30"), 30)
        XCTAssertEqual(ExactEntry.angle("45.5"), 45.5)
        XCTAssertEqual(ExactEntry.angle("-30"), 330)
        XCTAssertEqual(ExactEntry.angle("360"), 0)
        XCTAssertEqual(ExactEntry.angle("450"), 90)
        for text in ["", "a", "1/2", "12'", "-"] { XCTAssertNil(ExactEntry.angle(text), text) }
        XCTAssertEqual(ExactEntry.sides("3"), 3)
        XCTAssertEqual(ExactEntry.sides("24"), 24)
        for text in ["", "2", "25", "6.5", "6'", "-6"] { XCTAssertNil(ExactEntry.sides(text), text) }
    }
}

/// The catch at 4°, read counter-clockwise from east on a canvas whose y runs down (#40).
final class AngleCatchTests: XCTestCase {
    func testAnglesReadCounterClockwiseFromEast() {
        XCTAssertEqual(AngleCatch.angle(from: .origin, to: p(10, 0)), 0)
        XCTAssertEqual(AngleCatch.angle(from: .origin, to: p(10, -10)), 45, "up the screen and right")
        XCTAssertEqual(AngleCatch.angle(from: .origin, to: p(0, -10)), 90, "up the screen")
        XCTAssertEqual(AngleCatch.angle(from: .origin, to: p(-10, 0)), 180)
        XCTAssertEqual(AngleCatch.angle(from: .origin, to: p(0, 10)), 270, "down the screen")
        assertPoint(AngleCatch.point(from: p(1, 2), length: .inches(10), angle: 90), 1, -8, accuracy: 0)
        assertPoint(AngleCatch.point(from: p(1, 2), length: .inches(10), angle: 180), -9, 2, accuracy: 0)
    }

    func testALineWithinFourDegreesOfEveryMultipleOfFortyFiveCatches() {
        for multiple in 0..<8 {
            let target = Double(multiple) * 45
            for off in [-3.99, 3.99, 0, 2] {
                let end = AngleCatch.point(from: .origin, length: .inches(100), angle: target + off)
                let caught = AngleCatch.caught(from: .origin, to: end)
                XCTAssertEqual(caught.guide, target, "\(target) \(off)")
                XCTAssertEqual(AngleCatch.angle(from: .origin, to: caught.point), target, accuracy: 1e-9)
                // Pulled square onto the guide, as long as the end's shadow on it.
                XCTAssertEqual(caught.point.distance(to: .origin).inches, 100 * cos(off * .pi / 180), accuracy: 1e-9)
            }
            for off in [-4.01, 4.01, 22] {
                let end = AngleCatch.point(from: .origin, length: .inches(100), angle: target + off)
                let caught = AngleCatch.caught(from: .origin, to: end)
                XCTAssertNil(caught.guide, "\(target) \(off)")
                XCTAssertEqual(caught.point, end)
            }
        }
    }

    /// Level and plumb are exact to the last bit.
    func testLevelAndPlumbCatchesAreExact() {
        let level = AngleCatch.caught(from: p(5, 7), to: p(105, 9))
        XCTAssertEqual(level.guide, 0)
        XCTAssertEqual(level.point.y.inches, 7)
        let plumb = AngleCatch.caught(from: p(5, 7), to: p(6, -93))
        XCTAssertEqual(plumb.guide, 90)
        XCTAssertEqual(plumb.point.x.inches, 5)
    }

    func testTheSameTwoPointsCatchNothing() {
        XCTAssertNil(AngleCatch.caught(from: p(1, 1), to: p(1, 1)).guide)
    }
}

/// Each new shape, drawn and corrected, as exact numbers (#40): what the tag says is what the ink measures.
final class DrawnShapeTests: XCTestCase {
    private let ftIn = CanvasUnits.feetAndInches

    func testALineCorrectedToTwelveSixAtThirtyDegrees() throws {
        let drawn = DrawnShape(.line(p(10, 20), p(50, 20)))
        XCTAssertEqual(drawn.fields, [.length, .angle])
        XCTAssertEqual(drawn.tag(units: ftIn), "3'-4\"  0°")
        let exact = try XCTUnwrap(drawn.corrected([.length: .length(.inches(150)), .angle: .angle(30)]))
        XCTAssertEqual(exact.tag(units: ftIn), "12'-6\"  30°")
        let points = exact.shape.points
        assertPoint(points[0], 10, 20)
        assertPoint(points[1], 10 + 150 * cos(Double.pi / 6), 20 - 75)
        XCTAssertEqual(points[0].distance(to: points[1]).inches, 150, accuracy: 1e-9)
        // Length alone keeps the angle; angle alone keeps the length.
        let longer = try XCTUnwrap(exact.corrected([.length: .length(.inches(0.0625))]))
        XCTAssertEqual(longer.tag(units: ftIn), "0'-0 1/16\"  30°")
        let turned = try XCTUnwrap(exact.corrected([.angle: .angle(90)]))
        assertPoint(turned.shape.points[1], 10, 20 - 150)
    }

    func testARectangleKeepsTheCornerItStartedFrom() throws {
        let drawn = DrawnShape.rectangle(from: p(10, 20), to: p(30, 50))
        XCTAssertEqual(drawn.fields, [.width, .height])
        let exact = try XCTUnwrap(drawn.corrected([.width: .length(.inches(96)), .height: .length(.inches(48))]))
        XCTAssertEqual(exact.tag(units: ftIn), "8'-0\" × 4'-0\"")
        assertPoint(exact.shape.points[0], 10, 20, "the first corner stays")
        assertPoint(exact.shape.points[2], 106, 68)

        let backwards = DrawnShape.rectangle(from: p(30, 50), to: p(10, 20))
        let fixed = try XCTUnwrap(backwards.corrected([.width: .length(.inches(96)), .height: .length(.inches(48))]))
        assertPoint(fixed.shape.points[2], 30, 50, "drawn the other way, that first corner stays")
        assertPoint(fixed.shape.points[0], -66, 2)

        let heightAlone = try XCTUnwrap(drawn.corrected([.height: .length(.inches(1.0625))]))
        XCTAssertEqual(heightAlone.tag(units: ftIn), "1'-8\" × 0'-1 1/16\"")
    }

    func testACircleShowsItsDiameter() throws {
        let drawn = DrawnShape.circle(centre: p(5, 5), edge: p(35, 5))
        XCTAssertEqual(drawn.fields, [.diameter])
        XCTAssertEqual(drawn.tag(units: ftIn), "⌀ 5'-0\"")
        let exact = try XCTUnwrap(drawn.corrected([.diameter: .length(.inches(72.0625))]))
        XCTAssertEqual(exact.tag(units: ftIn), "⌀ 6'-0 1/16\"")
        XCTAssertEqual(exact.shape.points.count, SnappedShape.ellipseSegments + 1)
        for point in exact.shape.points {
            XCTAssertEqual(point.distance(to: p(5, 5)).inches, 36.03125, accuracy: 1e-9)
        }
    }

    func testAPolygonOfSixSidesByDefault() throws {
        let drawn = DrawnShape.polygon(centre: .origin, corner: p(24, 0))
        XCTAssertEqual(drawn.fields, [.sides, .side])
        XCTAssertEqual(drawn.tag(units: ftIn), "6 × 2'-0\"", "a hexagon's side is its radius")
        let points = drawn.shape.points
        XCTAssertEqual(points.count, 7)
        XCTAssertEqual(points.first, points.last)
        assertPoint(points[0], 24, 0)
        assertPoint(points[1], 12, -24 * sin(Double.pi / 3), "the next corner, counter-clockwise")

        // Sides typed alone keep the side's length, and the corners stay as far apart on all sides.
        let eight = try XCTUnwrap(drawn.corrected([.sides: .sides(8)]))
        XCTAssertEqual(eight.tag(units: ftIn), "8 × 2'-0\"")
        for i in 1...8 {
            XCTAssertEqual(eight.shape.points[i - 1].distance(to: eight.shape.points[i]).inches, 24, accuracy: 1e-9)
        }
        let small = try XCTUnwrap(drawn.corrected([.sides: .sides(3), .side: .length(.inches(0.0625))]))
        XCTAssertEqual(small.tag(units: ftIn), "3 × 0'-0 1/16\"")
        XCTAssertEqual(small.shape.points[0].distance(to: small.shape.points[1]).inches, 0.0625, accuracy: 1e-9)
    }

    func testAnArcFromStartEndAndBulge() throws {
        let drawn = DrawnShape.arc(start: p(0, 0), end: p(100, 0), bulge: p(50, -25))
        XCTAssertEqual(drawn.fields, [.radius])
        XCTAssertEqual(drawn.tag(units: ftIn), "R 5'-2 1/2\"")
        var points = drawn.shape.points
        XCTAssertEqual(points.count, SnappedShape.arcSegments + 1)
        assertPoint(points[0], 0, 0)
        assertPoint(points[48], 100, 0)
        assertPoint(points[24], 50, -25, "it bulges up the screen, through the height asked")
        assertPoint(drawn.spot, 50, -25)
        for point in points { XCTAssertEqual(point.distance(to: p(50, 37.5)).inches, 62.5, accuracy: 1e-9) }

        // The other side.
        points = DrawnShape.arc(start: p(0, 0), end: p(100, 0), bulge: p(50, 25)).shape.points
        assertPoint(points[24], 50, 25)
        // Drawn the other way round it runs the other way and bulges the same.
        points = DrawnShape.arc(start: p(100, 0), end: p(0, 0), bulge: p(50, -25)).shape.points
        assertPoint(points[24], 50, -25)
        assertPoint(points[0], 100, 0)
        // On the line between its ends it is a line.
        XCTAssertEqual(DrawnShape.arc(start: p(0, 0), end: p(100, 0), bulge: p(50, 0)).shape, .line(p(0, 0), p(100, 0)))
    }

    func testAnArcCorrectedKeepsItsEndsAndItsSide() throws {
        let drawn = DrawnShape.arc(start: p(0, 0), end: p(100, 0), bulge: p(50, -25))
        let exact = try XCTUnwrap(drawn.corrected([.radius: .length(.inches(120))]))
        XCTAssertEqual(exact.tag(units: ftIn), "R 10'-0\"")
        let beyond = (120.0 * 120 - 2500).squareRoot()
        assertPoint(exact.shape.points[0], 0, 0, accuracy: 1e-8)
        assertPoint(exact.shape.points[48], 100, 0, accuracy: 1e-8)
        assertPoint(exact.shape.points[24], 50, beyond - 120, accuracy: 1e-8)

        // More than half a circle stays more than half a circle.
        let major = DrawnShape.arc(start: p(0, 0), end: p(100, 0), bulge: p(50, -75))
        assertPoint(major.shape.points[24], 50, -75)
        let wider = try XCTUnwrap(major.corrected([.radius: .length(.inches(60))]))
        assertPoint(wider.shape.points[0], 0, 0, accuracy: 1e-8)
        assertPoint(wider.shape.points[24], 50, -(3600.0 - 2500).squareRoot() - 60, accuracy: 1e-8)

        // No arc of a radius under half the distance between its ends exists; half is a half circle.
        XCTAssertNil(drawn.corrected([.radius: .length(.inches(49.9))]))
        let half = try XCTUnwrap(drawn.corrected([.radius: .length(.inches(50))]))
        assertPoint(half.shape.points[24], 50, -50, accuracy: 1e-8)

        let sixteenth = try XCTUnwrap(drawn.corrected([.radius: .length(.inches(75.0625))]))
        XCTAssertEqual(sixteenth.tag(units: ftIn), "R 6'-3 1/16\"")
    }

    func testAPolylineShowsAndCorrectsItsLastSegment() throws {
        let drawn = DrawnShape(.polyline([p(0, 0), p(100, 0), p(100, -100)]))
        XCTAssertEqual(drawn.fields, [.length, .angle])
        XCTAssertEqual(drawn.tag(units: ftIn), "8'-4\"  90°")
        assertPoint(drawn.spot, 100, -50)
        let exact = try XCTUnwrap(drawn.corrected([.length: .length(.inches(60)), .angle: .angle(45)]))
        XCTAssertEqual(exact.tag(units: ftIn), "5'-0\"  45°")
        let points = exact.shape.points
        assertPoint(points[0], 0, 0)
        assertPoint(points[1], 100, 0)
        assertPoint(points[2], 100 + 60 * cos(Double.pi / 4), -60 * sin(Double.pi / 4))

        let closed = DrawnShape(.polyline([p(0, 0), p(100, 0), p(100, -100), p(0, 0)]))
        let still = try XCTUnwrap(closed.corrected([.length: .length(.inches(120))])).shape.points
        XCTAssertEqual(still.first, still.last, "closed stays closed")
        XCTAssertEqual(still[2], p(100, -100))
        XCTAssertEqual(still[2].distance(to: still[3]).inches, 120, accuracy: 1e-9)
    }

    /// A shape Draw it recognised shows its size too.
    func testARecognisedEllipseShowsBothDiameters() throws {
        let drawn = DrawnShape(.ellipse(centre: .origin, radiusX: .inches(30), radiusY: .inches(12), angle: 0))
        XCTAssertEqual(drawn.fields, [.width, .height])
        XCTAssertEqual(drawn.tag(units: ftIn), "5'-0\" × 2'-0\"")
        let exact = try XCTUnwrap(drawn.corrected([.height: .length(.inches(48))]))
        XCTAssertEqual(exact.shape, .ellipse(centre: .origin, radiusX: .inches(30), radiusY: .inches(24), angle: 0))
    }

    func testTheTagReadsInTheCanvasUnits() {
        let drawn = DrawnShape(.line(.origin, p(120, 0)))
        XCTAssertEqual(drawn.tag(units: .decimalFeet), "10.00'  0°")
        XCTAssertEqual(drawn.tag(units: .metric), "3.048 m  0°")
    }
}

final class NumberPadTests: XCTestCase {
    func testKeysAndEnterSetTheField() throws {
        var pad = NumberPad(shape: DrawnShape(.line(.origin, p(10, 0))), units: .feetAndInches)
        XCTAssertEqual(pad.active, .length)
        XCTAssertEqual(pad.text(of: .length), "0'-10\"", "until something is typed, the value as it stands")
        for key in ["1", "2", "'", "6", "-", "1", "/", "2"] { pad.press(key) }
        XCTAssertEqual(pad.text(of: .length), "12'6-1/2")
        pad.select(.angle)
        for key in ["3", "0", "9"] { pad.press(key) }
        pad.backspace()
        XCTAssertEqual(pad.text(of: .angle), "30")
        let exact = try XCTUnwrap(pad.enter())
        XCTAssertEqual(exact.tag(units: .feetAndInches), "12'-6 1/2\"  30°")
    }

    func testABareNumberIsInchesAndFeetTakeTheMark() throws {
        var pad = NumberPad(shape: DrawnShape(.line(.origin, p(10, 0))), units: .feetAndInches)
        pad.press("1"); pad.press("2")
        XCTAssertEqual(try XCTUnwrap(pad.enter()).length(of: .length)?.inches ?? 0, 12, accuracy: 1e-9)
        pad.press("'")
        XCTAssertEqual(try XCTUnwrap(pad.enter()).length(of: .length)?.inches ?? 0, 144, accuracy: 1e-9)
    }

    /// What can't be read stays on the pad, marked, and changes nothing.
    func testWhatCantBeReadIsMarkedAndKeepsThePadOpen() {
        var pad = NumberPad(shape: DrawnShape(.line(.origin, p(10, 0))), units: .feetAndInches)
        for key in ["1", "/", "0"] { pad.press(key) }
        XCTAssertNil(pad.enter())
        XCTAssertEqual(pad.problem, .length)
        pad.backspace()
        XCTAssertNil(pad.problem, "typing again clears it")

        var arc = NumberPad(shape: DrawnShape.arc(start: .origin, end: p(100, 0), bulge: p(50, -25)), units: .feetAndInches)
        for key in ["1", "'"] { arc.press(key) }
        XCTAssertNil(arc.enter(), "no arc this small reaches its ends")
        XCTAssertEqual(arc.problem, .radius)
    }

    func testEnterWithNothingTypedLeavesTheShape() {
        let shape = DrawnShape.polygon(centre: .origin, corner: p(24, 0))
        var pad = NumberPad(shape: shape, units: .feetAndInches)
        XCTAssertEqual(pad.enter(), shape)
        XCTAssertEqual(pad.active, .sides)
        XCTAssertEqual(pad.text(of: .sides), "6")
    }
}

final class ShapeDraftTests: XCTestCase {
    private let onScreen: (CanvasPoint, CanvasPoint) -> Double = { $0.distance(to: $1).inches * 2 }

    private func finished(_ placement: ShapeDraft.Placement, file: StaticString = #filePath, line: UInt = #line) -> DrawnShape? {
        guard case .finished(let shape) = placement else {
            XCTFail("not finished", file: file, line: line)
            return nil
        }
        return shape
    }

    func testTwoPointsFinishALineRectangleCircleAndPolygon() {
        for (kind, name) in [(LineShape.line, "straight line"), (.rectangle, "rectangle"), (.circle, "circle"), (.polygon, "polygon")] {
            var draft = ShapeDraft(kind: kind)
            XCTAssertEqual(draft.place(p(0, 0), screenDistance: onScreen), .waiting)
            XCTAssertEqual(finished(draft.place(p(100, 40), screenDistance: onScreen))?.shape.name, name)
        }
    }

    func testTheSamePlaceTwiceIsNotASecondPoint() {
        for kind in [LineShape.line, .rectangle, .circle, .polygon, .arc] {
            var draft = ShapeDraft(kind: kind)
            _ = draft.place(p(0, 0), screenDistance: onScreen)
            XCTAssertEqual(draft.place(p(0.5, 0), screenDistance: onScreen), .waiting, kind.title)
            XCTAssertEqual(draft.placed.count, 1, kind.title)
        }
    }

    func testAnArcTakesThreePoints() {
        var draft = ShapeDraft(kind: .arc)
        XCTAssertEqual(draft.place(p(0, 0), screenDistance: onScreen), .waiting)
        XCTAssertEqual(draft.place(p(100, 0), screenDistance: onScreen), .waiting)
        XCTAssertEqual(draft.preview(to: p(50, -25))?.tag(units: .feetAndInches), "R 5'-2 1/2\"")
        assertPoint(finished(draft.place(p(50, -25), screenDistance: onScreen))?.shape.points[24], 50, -25)
    }

    func testAPolylineFinishesOnTheLastPointAndClosesOnTheFirst() {
        var draft = ShapeDraft(kind: .polyline)
        for point in [p(0, 0), p(100, 0), p(100, 100)] {
            XCTAssertEqual(draft.place(point, screenDistance: onScreen), .waiting)
        }
        let open = finished(draft.place(p(101, 100), screenDistance: onScreen))
        XCTAssertEqual(open?.shape.points, [p(0, 0), p(100, 0), p(100, 100)], "1 inch is 2 points: the last point again")

        var closing = ShapeDraft(kind: .polyline)
        for point in [p(0, 0), p(100, 0), p(100, 100)] { _ = closing.place(point, screenDistance: onScreen) }
        let closed = finished(closing.place(p(3, 3), screenDistance: onScreen))
        XCTAssertEqual(closed?.shape.points, [p(0, 0), p(100, 0), p(100, 100), p(0, 0)], "within 12 points of the first")
        XCTAssertTrue(closing.isClosed)

        // Two points placed can't close: the first is the last but one, so it is just another bend.
        var two = ShapeDraft(kind: .polyline)
        for point in [p(0, 0), p(100, 0)] { _ = two.place(point, screenDistance: onScreen) }
        XCTAssertEqual(two.place(p(3, 3), screenDistance: onScreen), .waiting)
        XCTAssertEqual(two.placed.count, 3)

        // One point tapped twice is nothing yet.
        var one = ShapeDraft(kind: .polyline)
        _ = one.place(p(0, 0), screenDistance: onScreen)
        XCTAssertEqual(one.place(p(0, 0), screenDistance: onScreen), .waiting)
        XCTAssertEqual(one.placed.count, 1)
        XCTAssertNil(one.finish())
    }

    /// A snap point beats the angle catch, and only lines, polylines and polygons catch.
    func testASnapPointBeatsTheAngleCatch() {
        var draft = ShapeDraft(kind: .line)
        _ = draft.place(.origin, screenDistance: onScreen)
        let tip = AngleCatch.point(from: .origin, length: .inches(100), angle: 2)
        let free = draft.resolve(PointSnap.Target(point: tip, kind: nil))
        XCTAssertEqual(free.guide, 0)
        XCTAssertEqual(free.point.y.inches, 0)
        let snapped = draft.resolve(PointSnap.Target(point: tip, kind: .end))
        XCTAssertNil(snapped.guide)
        XCTAssertEqual(snapped.point, tip)

        for kind in [LineShape.rectangle, .circle, .arc] {
            var other = ShapeDraft(kind: kind)
            _ = other.place(.origin, screenDistance: onScreen)
            XCTAssertNil(other.resolve(PointSnap.Target(point: tip, kind: nil)).guide, kind.title)
        }
        XCTAssertNil(ShapeDraft(kind: .line).resolve(PointSnap.Target(point: tip, kind: nil)).guide, "nothing placed yet")
    }

    /// Checked by hand too: every prompt is 28 characters or fewer, the most the status bar shows in full.
    func testEveryPromptFitsTheStatusBar() {
        for kind in LineShape.allCases {
            var draft = ShapeDraft(kind: kind)
            XCTAssertLessThanOrEqual(draft.prompt.count, 28, draft.prompt)
            XCTAssertEqual(CanvasTool.lineAndShape.prompt(fingerDraws: false, hasSelection: false, shape: kind), kind.prompt)
            for x in 0..<3 {
                _ = draft.place(p(Double(x) * 100, Double(x * x) * 40), screenDistance: onScreen)
                XCTAssertLessThanOrEqual(draft.prompt.count, 28, draft.prompt)
            }
        }
        XCTAssertEqual(CanvasTool.lineAndShape.prompt(fingerDraws: false, hasSelection: false, step: .drawing("Tap a corner")),
                       "Tap a corner")
        XCTAssertEqual(CanvasTool.lineAndShape.prompt(fingerDraws: false, hasSelection: false), "Draw a line, box or circle",
                       "Draw it is what the tool always said")
        XCTAssertEqual(CanvasTool.pen.prompt(fingerDraws: false, hasSelection: false, shape: .polygon), "Draw with the Pencil")
    }

    /// Resting a finger, then using the Pencil: the Pencil takes over, and nothing lands under the finger.
    func testAFingerRestingHandsOverToThePencil() {
        var gate = FingerStrokeGate()
        gate.fingerDown(at: 0)
        _ = gate.tick(at: 1)
        XCTAssertFalse(gate.takenOverByPencil(moved: false), "rested, however long")
        gate.fingerDown(at: 0)
        _ = gate.tick(at: 1)
        XCTAssertTrue(gate.takenOverByPencil(moved: true), "a confirmed drag stands")
        gate.fingerDown(at: 0)
        XCTAssertFalse(gate.takenOverByPencil(moved: true), "not yet clearly one finger")
    }
}

/// The tag, the pad and the loupe stay clear of the chrome on the unfolded Duo (#40).
final class ExactPlacementTests: XCTestCase {
    private let chrome = ScreenInsets(top: 56, left: 70, bottom: 50, right: 92)
    private var free: ExactPlacement { ExactPlacement(width: 951, height: 669, chrome: chrome) }

    func testTheTagStaysClearOfTheChromeWhereverTheShapeIs() {
        let (w, h) = (120.0, 28.0)
        XCTAssertEqual(free.tagCentre(spot: ScreenPoint(x: 400, y: 300), width: w, height: h), ScreenPoint(x: 400, y: 278),
                       "just over the shape in the open")
        for spot in [ScreenPoint(x: -500, y: -500), ScreenPoint(x: 2000, y: 2000), ScreenPoint(x: 10, y: 660), ScreenPoint(x: 945, y: 5)] {
            let c = free.tagCentre(spot: spot, width: w, height: h)
            XCTAssertGreaterThanOrEqual(c.x - w / 2, 74)
            XCTAssertLessThanOrEqual(c.x + w / 2, 855)
            XCTAssertGreaterThanOrEqual(c.y - h / 2, 60)
            XCTAssertLessThanOrEqual(c.y + h / 2, 615)
        }
    }

    func testThePadStaysClearOfTheChromeWhereverTheShapeIs() {
        let (w, h) = (162.0, 300.0)
        XCTAssertEqual(free.padOrigin(spot: ScreenPoint(x: 400, y: 300), width: w, height: h), ScreenPoint(x: 416, y: 150))
        for spot in [ScreenPoint(x: -500, y: -500), ScreenPoint(x: 2000, y: 2000), ScreenPoint(x: 10, y: 660), ScreenPoint(x: 945, y: 5)] {
            let o = free.padOrigin(spot: spot, width: w, height: h)
            XCTAssertGreaterThanOrEqual(o.x, 74)
            XCTAssertLessThanOrEqual(o.x + w, 855)
            XCTAssertGreaterThanOrEqual(o.y, 60)
            XCTAssertLessThanOrEqual(o.y + h, 615)
        }
    }

    func testTheyClampBelowAnOpenStrip() {
        let strip = ExactPlacement(width: 951, height: 669, chrome: chrome, stripBottom: 92)
        XCTAssertEqual(strip.top, 96)
        XCTAssertEqual(strip.tagCentre(spot: ScreenPoint(x: 400, y: 70), width: 100, height: 28).y, 110)
        XCTAssertEqual(strip.padOrigin(spot: ScreenPoint(x: 400, y: 70), width: 162, height: 300).y, 96)
        XCTAssertEqual(ExactPlacement(width: 951, height: 669, chrome: chrome, stripBottom: 20).top, 60, "a strip higher than the bar")
    }

    func testTheLoupeMovesAsideRatherThanSlidingUnderTheChrome() {
        let (r, lift) = (60.0, 104.0)
        XCTAssertEqual(free.loupeCentre(tip: ScreenPoint(x: 400, y: 400), radius: r, lift: lift), ScreenPoint(x: 400, y: 296),
                       "above the tip in the open")
        let left = free.loupeCentre(tip: ScreenPoint(x: 300, y: 150), radius: r, lift: lift)
        XCTAssertEqual(left, ScreenPoint(x: 410, y: 150), "too near the top bar: to the side, the roomier way")
        let right = free.loupeCentre(tip: ScreenPoint(x: 700, y: 150), radius: r, lift: lift)
        XCTAssertEqual(right, ScreenPoint(x: 590, y: 150))
        XCTAssertEqual(free.loupeCentre(tip: ScreenPoint(x: 80, y: 400), radius: r, lift: lift).x, 134, "clear of the rail")
        XCTAssertEqual(free.loupeCentre(tip: ScreenPoint(x: 850, y: 400), radius: r, lift: lift).x, 795, "clear of the tab rail")
        let strip = ExactPlacement(width: 951, height: 669, chrome: chrome, stripBottom: 92)
        XCTAssertEqual(strip.loupeCentre(tip: ScreenPoint(x: 300, y: 200), radius: r, lift: lift).x, 410, "below a strip it goes aside sooner")
        XCTAssertGreaterThanOrEqual(free.loupeCentre(tip: ScreenPoint(x: 300, y: 10), radius: r, lift: lift).y - r, 60)
        XCTAssertLessThanOrEqual(free.loupeCentre(tip: ScreenPoint(x: 475, y: 668), radius: r, lift: lift).y + r, 615)
    }
}

/// A correction goes through the ink log like any other change (#40): its own undo step, kept through a relaunch.
final class CorrectStrokeTests: XCTestCase {
    private func drawn() -> (InkSession, InkStroke) {
        var session = InkSession()
        let stroke = session.draw([p(0, 0), p(10, 0)], tool: .pen, colour: .red, width: .inches(0.1))!
        return (session, stroke)
    }

    func testACorrectionIsItsOwnUndoStep() throws {
        var (session, stroke) = drawn()
        _ = session.takeEvents()
        let corrected = try XCTUnwrap(session.correct(stroke.id, to: [p(0, 0), p(150, 0)]))
        XCTAssertEqual(corrected.id, stroke.id)
        XCTAssertEqual(corrected.colour, .red)
        XCTAssertEqual(corrected.width, stroke.width)
        XCTAssertEqual(session.lastChange.removed, [stroke.id])
        XCTAssertEqual(session.lastChange.added, [corrected])
        XCTAssertEqual(session.takeEvents(), [.correctStroke(corrected)])

        session.undo()
        XCTAssertEqual(session.ink.strokes, [stroke], "the drawn shape comes back; no stroke is lost")
        XCTAssertEqual(session.lastChange.removed, [stroke.id])
        session.undo()
        XCTAssertTrue(session.ink.strokes.isEmpty, "the next undo takes the shape")
        session.redo(); session.redo()
        XCTAssertEqual(session.ink.strokes, [corrected])
    }

    func testACorrectionThatChangesNothingOrNamesNoStrokeDoesNothing() {
        var (session, stroke) = drawn()
        _ = session.takeEvents()
        XCTAssertNil(session.correct(stroke.id, to: stroke.points))
        XCTAssertNil(session.correct(StrokeID(99), to: [p(1, 1), p(2, 2)]))
        XCTAssertNil(session.correct(stroke.id, to: []))
        XCTAssertTrue(session.takeEvents().isEmpty)
    }

    /// Exact to the ink grid, as drawn ink is.
    func testACorrectionIsOnTheInkGrid() throws {
        var (session, stroke) = drawn()
        let end = AngleCatch.point(from: .origin, length: .inches(150), angle: 30)
        let corrected = try XCTUnwrap(session.correct(stroke.id, to: [.origin, end]))
        XCTAssertEqual(corrected.points[1], end.onInkGrid)
        XCTAssertEqual(CanvasUnits.feetAndInches.format(corrected.points[0].distance(to: corrected.points[1])), "12'-6\"")
    }

    func testEventsAndTheSnapshotHoldACorrectionAndItsUndo() throws {
        var (session, stroke) = drawn()
        session.correct(stroke.id, to: [p(0, 0), p(150, 0)])
        let events = session.takeEvents()
        for event in events {
            XCTAssertEqual(try InkCodec.decodeEvent(InkCodec.encode(event)[...]), event)
        }
        var replayed = InkSession()
        for event in events { replayed.apply(event) }
        XCTAssertEqual(replayed, session)

        var decoded = try InkCodec.decodeSession(InkCodec.encode(session)[...])
        XCTAssertEqual(decoded, session)
        decoded.undo()
        XCTAssertEqual(decoded.ink.strokes, [stroke], "the snapshot held the stroke as it was")
        var undone = try InkCodec.decodeSession(InkCodec.encode(decoded)[...])
        XCTAssertEqual(undone, decoded)
        undone.redo()
        XCTAssertEqual(undone.ink.strokes[0].points, [p(0, 0), p(150, 0)], "and as it is")
    }

    func testACorrectionSurvivesARelaunchAndAddsOnlyOneRecordToTheLog() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-correct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var (session, stroke) = drawn()
        let store = try InkStore(folder: folder)
        try store.append(session.takeEvents())
        try store.flush()
        let log = folder.appendingPathComponent(InkStore.logName)
        let before = try Data(contentsOf: log)

        let corrected = try XCTUnwrap(session.correct(stroke.id, to: [p(0, 0), p(150, 0)]))
        try store.append(session.takeEvents())
        try store.flush()
        store.closeFiles()
        let after = try Data(contentsOf: log)
        XCTAssertEqual(after.prefix(before.count), before, "what was saved stays as it was")
        // The record's frame, its tag and the stroke's two points: a few dozen bytes, however large the canvas.
        XCTAssertLessThanOrEqual(after.count - before.count, 64)

        var reopened = try InkStore(folder: folder).session
        XCTAssertEqual(reopened.ink.strokes, [corrected])
        reopened.undo()
        XCTAssertEqual(reopened.ink.strokes, [stroke])
    }
}
