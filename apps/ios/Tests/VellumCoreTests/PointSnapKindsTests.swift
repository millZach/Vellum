import XCTest
@testable import VellumCore

private func p(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .inches(x), y: .inches(y)) }

/// Every snap point as an exact number (#40). At 2 points per inch the 20 points' reach is 10 inches.
final class PointSnapKindsTests: XCTestCase {
    private let ppi = 2.0

    private func index(_ strokes: [[CanvasPoint]]) -> InkIndex {
        var session = InkSession()
        for points in strokes { session.draw(points, tool: .pen, colour: .sketch, width: .inches(0.01)) }
        return InkIndex(session.ink)
    }

    private func assertSnap(_ target: PointSnap.Target, _ kind: PointSnap.Kind?, _ x: Double, _ y: Double, accuracy: Double = 1e-4,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(target.kind, kind, file: file, line: line)
        XCTAssertEqual(target.point.x.inches, x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(target.point.y.inches, y, accuracy: accuracy, file: file, line: line)
    }

    func testEveryKindHasAName() {
        XCTAssertEqual(PointSnap.Kind.allCases.map(\.title),
                       ["End", "Corner", "Centre", "Mid", "Intersection", "Perpendicular", "Tangent", "Sheet corner",
                        "Sheet edge"])
    }

    func testMidIsTheMiddleOfAStraightRunDownToASixteenth() {
        let ink = index([SnappedShape.line(p(0, 0), p(200.125, 0)).points,
                         SnappedShape.rectangle(centre: p(400, 100), width: .inches(100), height: .inches(60), angle: 0).points,
                         SnappedShape.polyline([p(0, 300), p(60, 300), p(60, 340)]).points])
        assertSnap(PointSnap.target(at: p(99, 3), pointsPerInch: ppi, in: ink), .mid, 100.0625, 0, accuracy: 1 / 65536)
        assertSnap(PointSnap.target(at: p(401, 73), pointsPerInch: ppi, in: ink), .mid, 400, 70)
        assertSnap(PointSnap.target(at: p(447, 101), pointsPerInch: ppi, in: ink), .mid, 450, 100)
        assertSnap(PointSnap.target(at: p(30, 302), pointsPerInch: ppi, in: ink), .mid, 30, 300)
        assertSnap(PointSnap.target(at: p(61, 322), pointsPerInch: ppi, in: ink), .mid, 60, 320)
        assertSnap(PointSnap.target(at: p(58, 302), pointsPerInch: ppi, in: ink), .corner, 60, 300)
    }

    /// A circle, an arc and a hand-drawn stroke have no mids: their segments aren't straight runs.
    func testCurvesAndHandDrawnStrokesHaveNoMids() {
        let wobble = (0..<60).map { k in p(Double(k) * 4, sin(Double(k) * 0.3)) }
        let circle = SnappedShape.ellipse(centre: p(0, 300), radiusX: .inches(100), radiusY: .inches(100), angle: 0).points
        let arc = DrawnShape.arc(start: p(300, 300), end: p(500, 300), bulge: p(400, 250)).shape.points
        let ink = index([wobble, circle, arc])
        XCTAssertNil(PointSnap.target(at: p(120, 0), pointsPerInch: ppi, in: ink).kind)
        XCTAssertNil(PointSnap.target(at: p(0, 200), pointsPerInch: ppi, in: ink).kind, "the top of a circle")
        XCTAssertNil(PointSnap.target(at: p(100, 300), pointsPerInch: ppi, in: ink).kind, "a circle has no corner where it closes")
        XCTAssertNil(PointSnap.target(at: p(400, 250), pointsPerInch: ppi, in: ink).kind, "the top of an arc")
    }

    func testIntersectionOfTwoLinesDownToASixteenth() {
        let ink = index([SnappedShape.line(p(0, 3.125), p(120, 3.125)).points,
                         SnappedShape.line(p(30.0625, -40), p(30.0625, 80)).points])
        let hit = PointSnap.target(at: p(31, 5), pointsPerInch: ppi, in: ink)
        XCTAssertEqual(hit.kind, .intersection)
        XCTAssertEqual(hit.point, p(30.0625, 3.125), "exact")
        XCTAssertEqual(CanvasUnits.feetAndInches.format(hit.point.x), "2'-6 1/16\"")
    }

    func testStrokesThatDontCrossHaveNoIntersection() {
        let ink = index([SnappedShape.line(p(0, 0), p(100, 0)).points, SnappedShape.line(p(0, 5), p(100, 5)).points,
                         SnappedShape.line(p(30, 3), p(30, 80)).points])
        XCTAssertNil(PointSnap.target(at: p(30, 1), pointsPerInch: 20, in: ink).kind, "parallel, and one stopping short")
    }

    /// A stroke doesn't intersect itself; two strokes meeting at an end do.
    func testAStrokesOwnBendIsACornerAndStrokesMeetingAtAnEndIntersect() {
        let bent = index([SnappedShape.polyline([p(0, 0), p(50, 0), p(50, 50)]).points])
        assertSnap(PointSnap.target(at: p(51, 1), pointsPerInch: ppi, in: bent), .corner, 50, 0)
        let meeting = index([SnappedShape.line(p(0, 0), p(50, 0)).points, SnappedShape.line(p(50, 0), p(50, 50)).points])
        assertSnap(PointSnap.target(at: p(51, 1), pointsPerInch: ppi, in: meeting), .intersection, 50, 0)
    }

    /// On the true circle, not its chords: at this size a chord falls 0.05 inch inside, most of a sixteenth.
    func testALineCrossesATrueCircle() {
        let circle = SnappedShape.ellipse(centre: .origin, radiusX: .inches(60), radiusY: .inches(60), angle: 0).points
        let ink = index([circle, SnappedShape.line(p(0, 36), p(100, 36)).points])
        assertSnap(PointSnap.target(at: p(47, 37), pointsPerInch: ppi, in: ink), .intersection, 48, 36, accuracy: 1e-3)
    }

    func testTwoCirclesCrossTrue() {
        let a = SnappedShape.ellipse(centre: .origin, radiusX: .inches(50), radiusY: .inches(50), angle: 0).points
        let b = SnappedShape.ellipse(centre: p(60, 0), radiusX: .inches(50), radiusY: .inches(50), angle: 0).points
        assertSnap(PointSnap.target(at: p(31, 41), pointsPerInch: ppi, in: index([a, b])), .intersection, 30, 40, accuracy: 1e-3)
        assertSnap(PointSnap.target(at: p(31, -41), pointsPerInch: ppi, in: index([a, b])), .intersection, 30, -40, accuracy: 1e-3)
    }

    func testAnArcSnapsAtItsEndsItsCentreAndWhereItCrossesAndNotBeyond() {
        let arc = DrawnShape.arc(start: p(0, 0), end: p(100, 0), bulge: p(50, -25)).shape.points
        let across = SnappedShape.line(p(50, -50), p(50, 10)).points
        let offEnd = SnappedShape.line(p(50, 90), p(50, 110)).points
        let ink = index([arc, across, offEnd])
        assertSnap(PointSnap.target(at: p(1, 2), pointsPerInch: ppi, in: ink), .end, 0, 0)
        assertSnap(PointSnap.target(at: p(99, 2), pointsPerInch: ppi, in: ink), .end, 100, 0)
        assertSnap(PointSnap.target(at: p(52, 38), pointsPerInch: ppi, in: ink), .centre, 50, 37.5, accuracy: 1e-3)
        assertSnap(PointSnap.target(at: p(51, -24), pointsPerInch: ppi, in: ink), .intersection, 50, -25, accuracy: 1e-3)
        // The whole circle would cross this line at (50, 100); the arc stops short of it.
        assertSnap(PointSnap.target(at: p(51, 100), pointsPerInch: ppi, in: ink), .mid, 50, 100)
    }

    /// The index keeps an arc's centre through a removal and a replacement, as it does the arc.
    func testTheIndexFollowsAnArcsCentre() {
        var session = InkSession()
        let arc = session.draw(DrawnShape.arc(start: p(0, 0), end: p(100, 0), bulge: p(50, -25)).shape.points, tool: .pen,
                               colour: .sketch, width: .inches(0.01))!
        var index = InkIndex(session.ink)
        XCTAssertEqual(PointSnap.target(at: p(52, 38), pointsPerInch: ppi, in: index).kind, .centre)
        index.remove(arc.id)
        XCTAssertNil(PointSnap.target(at: p(52, 38), pointsPerInch: ppi, in: index).kind)
        // Forty-nine points that aren't on a circle are no arc.
        var other = InkSession()
        other.draw((0..<49).map { k in p(Double(k), sin(Double(k))) }, tool: .pen, colour: .sketch, width: .inches(0.01))
        XCTAssertTrue(InkIndex(other.ink).arcCentres.isEmpty)
    }

    /// A hand line of exactly 49 points, 6 inches long with a 0.03 inch wobble, is no arc: its circle would be huge, and its
    /// centre would pull the tip from empty canvas. Made up with a fixed walk, so the numbers don't change.
    func testANearlyStraightHandStrokeOfFortyNinePointsIsNoArc() {
        var points: [CanvasPoint] = []
        var x = 0.0
        for k in 0..<49 {
            points.append(p(x, 0.03 * sin(Double(k) * 1.7)))
            x += 0.0625 + 0.125 * (0.5 + 0.5 * sin(Double(k) * 2.3))
        }
        var session = InkSession()
        session.draw(points, tool: .pen, colour: .sketch, width: .inches(0.01))
        let ink = InkIndex(session.ink)
        XCTAssertTrue(ink.arcCentres.isEmpty, "no centre")
        XCTAssertNil(PointSnap.arcCentre(of: session.ink.strokes[0].points))
        // It keeps its segments, as a stroke that isn't round does: a line crossing a gentler one is found.
        var gentle: [CanvasPoint] = []
        x = 0
        for k in 0..<49 {
            gentle.append(p(x, 0.005 * sin(Double(k) * 1.7)))
            x += 0.0625 + 0.125 * (0.5 + 0.5 * sin(Double(k) * 2.3))
        }
        let both = index([gentle, SnappedShape.line(p(3, -2), p(3, 4)).points])
        XCTAssertTrue(both.arcCentres.isEmpty)
        XCTAssertEqual(PointSnap.target(at: p(3.1, 0.1), pointsPerInch: 40, in: both).kind, .intersection)
    }

    /// A real arc is still an arc after a move, a turn at 33.5° and a scale change, each rounded to the grid as ink is.
    func testARealArcStaysAnArcThroughAMoveATurnAndAScale() throws {
        var points = DrawnShape.arc(start: p(0, 0), end: p(100, 0), bulge: p(50, -25)).shape.points.map(\.onInkGrid)
        var centre = p(50, 37.5)
        let motions = [SheetMotion(centre: .origin, dx: .inches(7.13), dy: .inches(-3.3)),
                       SheetMotion(centre: p(10, 10), turn: 33.5),
                       SheetMotion(centre: p(-4, 2), scale: 2.5),
                       SheetMotion(centre: p(3, 3), turn: 33.5, scale: 0.4)]
        for motion in motions {
            points = points.map { motion.apply($0).onInkGrid }
            centre = motion.apply(centre)
            let found = try XCTUnwrap(PointSnap.arcCentre(of: points), "\(motion)")
            XCTAssertEqual(found.x, centre.x.inches, accuracy: 1e-2)
            XCTAssertEqual(found.y, centre.y.inches, accuracy: 1e-2)
            let ink = index([points])
            let tip = centre.offsetBy(dx: .inches(1), dy: .inches(1))
            XCTAssertEqual(PointSnap.target(at: tip, pointsPerInch: ppi, in: ink).kind, .centre, "\(motion)")
            // And round: a line across its middle takes the true curve.
            XCTAssertEqual(ink.arcCentres.count, 1)
        }
    }

    /// The arc's centre to the 1/16" the app shows, with a height of at least 1/200 of its length. A shallower arc can't reach
    /// it on the ink grid: the limit is stated in the PR and in `PointSnap.arcFit`.
    func testAnArcsCentreIsGoodToASixteenthUntilItIsVeryShallow() throws {
        // Bulging up the screen with its centre below, at the radius asked.
        func centreError(chord: Double, radius: Double) throws -> Double {
            let beyond = (radius * radius - chord * chord / 4).squareRoot()
            let drawn = try XCTUnwrap(DrawnShape.arc(start: p(0, 0), end: p(chord, 0), bulge: p(chord / 2, -chord / 8))
                .corrected([.radius: .length(.inches(radius))]))
            let found = try XCTUnwrap(PointSnap.arcCentre(of: drawn.shape.points.map(\.onInkGrid)))
            return hypot(found.x - chord / 2, found.y - beyond)
        }
        for (chord, radius) in [(600.0, 1000.0), (100, 1000), (100, 120), (12, 200), (12, 100), (12, 50)] {
            XCTAssertLessThan(try centreError(chord: chord, radius: radius), 1.0 / 16, "\(chord) \(radius)")
        }
        // 12 inches long at a radius of 83'-4 1/16": 0.018 inch of height, 1/667 of its length, the case that showed the limit.
        XCTAssertLessThan(try centreError(chord: 12, radius: 1000.0625), 2)
    }

    /// A circle exactly touching a line takes an Intersection, though rounding leaves its fitted radius just short; a line
    /// clearly missing takes none.
    func testALineTouchingACircleIntersectsAndOneMissingDoesNot() {
        let circle = SnappedShape.ellipse(centre: .origin, radiusX: .inches(60), radiusY: .inches(60), angle: 0).points
        let touching = index([circle, SnappedShape.line(p(-80, 60), p(100, 60)).points])
        assertSnap(PointSnap.target(at: p(0, 60), pointsPerInch: 10, in: touching), .intersection, 0, 60)
        let missing = index([circle, SnappedShape.line(p(-80, 60.01), p(100, 60.01)).points])
        XCTAssertNil(PointSnap.target(at: p(0, 60), pointsPerInch: 10, in: missing).kind)
    }

    /// Arc centres are found by place: thousands far from the tip cost nothing. The budget is in
    /// docs/perf/baselines/canvas-rendering.json.
    func testArcCentresFarFromTheTipAreNotRead() {
        var session = InkSession()
        for i in 0..<5000 {
            let centre = p(100_000 + Double(i % 100) * 500, 100_000 + Double(i / 100) * 500)
            session.draw(SnappedShape.arc(centre: centre, radius: .inches(50), start: 0, sweep: 90).points, tool: .pen,
                         colour: .sketch, width: .inches(0.01))
        }
        for centre in [p(2, 3), p(-4, 5), p(-6, -7)] {
            session.draw(SnappedShape.arc(centre: centre, radius: .inches(50), start: 0, sweep: 90).points, tool: .pen,
                         colour: .sketch, width: .inches(0.01))
        }
        let ink = InkIndex(session.ink)
        XCTAssertEqual(ink.arcCentres.count, 5003)
        var work = InkIndex.Work()
        let near = PointSnap.target(at: p(0, 0), pointsPerInch: ppi, in: ink, work: &work)
        XCTAssertEqual(near.kind, .centre)
        XCTAssertEqual(near.point, p(2, 3))
        MeasureFrameBaseline.check("point_snap_arc_centres_visited_per_lookup", work.arcCentresVisited, area: "canvas-rendering",
                                   before: 5003)
        var nowhere = InkIndex.Work()
        _ = PointSnap.target(at: p(-5000, -5000), pointsPerInch: ppi, in: ink, work: &nowhere)
        XCTAssertEqual(nowhere.arcCentresVisited, 0)
        // Taking one out takes it from its place too.
        var fewer = ink
        fewer.remove(session.ink.strokes[5000].id)
        XCTAssertEqual(PointSnap.target(at: p(1, 2), pointsPerInch: ppi, in: fewer).point, p(-4, 5))
    }

    /// A pile of circles through the tip: pairs stop at the cap. The budget is in docs/perf/baselines/canvas-rendering.json.
    func testAPileOfCirclesStopsAtTheRoundLimit() {
        var session = InkSession()
        for i in 0..<300 {
            session.draw(SnappedShape.ellipse(centre: p(Double(i) * 0.01, 0), radiusX: .inches(60), radiusY: .inches(60),
                                              angle: 0).points, tool: .pen, colour: .sketch, width: .inches(0.01))
        }
        var work = InkIndex.Work()
        _ = PointSnap.target(at: p(60, 0), pointsPerInch: ppi, in: InkIndex(session.ink), work: &work)
        MeasureFrameBaseline.check("point_snap_crowded_round_pairs_per_lookup", work.segmentPairsTested, area: "canvas-rendering",
                                   before: 300 * 299 / 2)
    }

    func testAPolygonSnapsAtItsCentreCornersAndMids() {
        let hexagon = DrawnShape.polygon(centre: p(200, 200), corner: p(248, 200)).shape.points
        let ink = index([hexagon])
        assertSnap(PointSnap.target(at: p(201, 201), pointsPerInch: ppi, in: ink), .centre, 200, 200)
        assertSnap(PointSnap.target(at: p(247, 201), pointsPerInch: ppi, in: ink), .corner, 248, 200)
        assertSnap(PointSnap.target(at: p(225, 158), pointsPerInch: ppi, in: ink), .corner, 224, 200 - 48 * sin(Double.pi / 3))
        // The middle of the side between the first two corners.
        assertSnap(PointSnap.target(at: p(237, 180), pointsPerInch: ppi, in: ink), .mid, 236, 200 - 24 * sin(Double.pi / 3))
    }

    /// 24 sides turn only 15° at each corner, and are still corners with a centre.
    func testAPolygonOfTwentyFourSides() throws {
        let many = try XCTUnwrap(DrawnShape.polygon(centre: .origin, corner: p(100, 0)).corrected([.sides: .sides(24)]))
        let points = many.shape.points
        let ink = index([points])
        let r = points[0].distance(to: .origin).inches
        assertSnap(PointSnap.target(at: p(0, 1), pointsPerInch: ppi, in: ink), .centre, 0, 0)
        let corner = points[3]
        assertSnap(PointSnap.target(at: corner.offsetBy(dx: .inches(0.5), dy: .inches(0.5)), pointsPerInch: 20, in: ink), .corner,
                   corner.x.inches, corner.y.inches)
        XCTAssertGreaterThan(r, 100)
    }

    func testPerpendicularWorksFromTheAnchor() {
        let ink = index([SnappedShape.line(p(0, 0), p(100, 0)).points])
        let anchor = p(30.0625, 50)
        XCTAssertNil(PointSnap.target(at: p(31, 2), pointsPerInch: ppi, in: ink).kind, "without a point to work from, nothing")
        let foot = PointSnap.target(at: p(31, 2), pointsPerInch: ppi, in: ink, anchor: anchor)
        assertSnap(foot, .perpendicular, 30.0625, 0)
        // Past the line's end there is no foot.
        XCTAssertNil(PointSnap.target(at: p(120, 2), pointsPerInch: ppi, in: ink, anchor: p(120, 50)).kind)
        // On a slope, the foot is square to it.
        let slope = index([SnappedShape.line(p(0, 0), p(100, 100)).points])
        assertSnap(PointSnap.target(at: p(26, 24), pointsPerInch: ppi, in: slope, anchor: p(0, 50)), .perpendicular, 25, 25)
    }

    func testTangentAndPerpendicularOnACircle() {
        let circle = SnappedShape.ellipse(centre: p(100, 0), radiusX: .inches(20), radiusY: .inches(20), angle: 0).points
        let ink = index([circle])
        let anchor = p(0, 0)
        // Distance 100, radius 20: the tangent points lie 96 along and 19.5959 across.
        let across = 20 * (1 - 0.04).squareRoot()
        XCTAssertNil(PointSnap.target(at: p(96, -19), pointsPerInch: ppi, in: ink).kind)
        assertSnap(PointSnap.target(at: p(96, -19), pointsPerInch: ppi, in: ink, anchor: anchor), .tangent, 96, -across)
        assertSnap(PointSnap.target(at: p(96, 19), pointsPerInch: ppi, in: ink, anchor: anchor), .tangent, 96, across)
        assertSnap(PointSnap.target(at: p(81, 1), pointsPerInch: ppi, in: ink, anchor: anchor), .perpendicular, 80, 0)
        // From inside the circle no line touches it.
        XCTAssertNil(PointSnap.target(at: p(96, -19), pointsPerInch: ppi, in: ink, anchor: p(100, 1)).kind)
    }

    /// The nearest wins whatever its kind; a kind only decides between points in one place.
    func testTheNearestWinsAndRankOnlySettlesOnePlace() {
        let ink = index([SnappedShape.line(p(0, 0), p(10, 0)).points])
        XCTAssertEqual(PointSnap.target(at: p(2, 0), pointsPerInch: ppi, in: ink).kind, .end)
        XCTAssertEqual(PointSnap.target(at: p(4, 0), pointsPerInch: ppi, in: ink).kind, .mid)
        let two = index([SnappedShape.line(p(0, 0), p(100, 0)).points, SnappedShape.line(p(50, 0), p(50, 80)).points])
        XCTAssertEqual(PointSnap.target(at: p(50, 1), pointsPerInch: ppi, in: two).kind, .intersection, "over the mid and the end")
    }

    /// Scale: a snap point on a stroke saved and reopened is still the same number; the grid is finer than the 1/16" shown.
    func testASnappedLengthReadsToTheSixteenth() {
        let ink = index([SnappedShape.line(p(0, 0), p(150.125, 0)).points])
        let mid = PointSnap.target(at: p(75, 1), pointsPerInch: ppi, in: ink)
        XCTAssertEqual(CanvasUnits.feetAndInches.format(mid.point.x), "6'-3 1/16\"")
    }

    /// The budget for a snap lookup on a crowded canvas (docs/perf/baselines/canvas-rendering.json): the tip in a thicket of
    /// hand-drawn strokes crossing, zoomed out, with a point to work from. Crossings are looked for only near the tip, and a
    /// pair that can't touch is never tested; the whole thicket would be millions of pairs. Since #57 the canvas holds
    /// 1,002 made-up sheets: one under the thicket, a letter page in it, and 1,000 far off, which cost nothing.
    func testACrowdedSnapTestsOnlyPairsNearTheTip() {
        var session = InkSession()
        var totalSegments = 0
        for i in 0..<400 {
            let angle = Double(i) * 0.137
            let (c, s) = (cos(angle), sin(angle))
            let stroke = (0..<80).map { k -> CanvasPoint in
                let along = (Double(k) - 40) * 12
                let wobble = sin(Double(k) * 0.7) * 2
                return p(along * c - wobble * s, along * s + wobble * c)
            }
            totalSegments += stroke.count - 1
            session.draw(stroke, tool: .pen, colour: .sketch, width: .inches(0.25))
        }
        let index = InkIndex(session.ink)
        let far = (0..<1000).map { i in
            Sheet(id: SheetID(3 + i), paper: .letter, scale: .notToScale,
                  origin: p(100_000 + Double(i % 40) * 20, 100_000 + Double(i / 40) * 20))
        }
        let sheets = SheetIndex([Sheet(id: SheetID(1), paper: .inches(10, by: 10), scale: .drawn(.ratio(48))),
                                 Sheet(id: SheetID(2), paper: .letter, scale: .notToScale, origin: p(200, 60))] + far)
        // A hundred points per screen at this zoom, and points to work from; the worst of a sweep across the thicket's edge.
        var worst = InkIndex.Work()
        for i in 0..<10 {
            let tip = p(150 + Double(i) * 17, 40 + Double(i) * 9)
            var work = InkIndex.Work()
            _ = PointSnap.target(at: tip, pointsPerInch: 0.25, in: index, sheets: sheets, anchor: p(600, 600), work: &work)
            worst.segmentPairsTested = max(worst.segmentPairsTested, work.segmentPairsTested)
            worst.pointsInspected = max(worst.pointsInspected, work.pointsInspected)
            worst.strokesVisited = max(worst.strokesVisited, work.strokesVisited)
            worst.sheetsVisited = max(worst.sheetsVisited, work.sheetsVisited)
        }
        MeasureFrameBaseline.check("point_snap_crowded_sheets_visited_per_lookup", worst.sheetsVisited, area: "canvas-rendering",
                                   before: sheets.count)
        MeasureFrameBaseline.check("point_snap_crowded_segment_pairs_per_lookup", worst.segmentPairsTested, area: "canvas-rendering",
                                   before: totalSegments * (totalSegments - 1) / 2)
        MeasureFrameBaseline.check("point_snap_crowded_points_per_lookup", worst.pointsInspected, area: "canvas-rendering",
                                   before: totalSegments + 400)
        XCTAssertLessThanOrEqual(worst.segmentPairsTested, PointSnap.intersectionSegmentLimit * PointSnap.intersectionSegmentLimit / 2)
    }

    /// However crowded, the pairs are bounded by the segments looked at.
    func testAThicketStopsAtTheSegmentLimit() {
        var session = InkSession()
        for i in 0..<60 {
            let stroke = (0..<40).map { k in p(Double(k) * 0.5 + Double(i) * 0.1, sin(Double(k)) * 8 + Double(i) * 0.2) }
            session.draw(stroke, tool: .pen, colour: .sketch, width: .inches(0.1))
        }
        var work = InkIndex.Work()
        _ = PointSnap.target(at: p(10, 2), pointsPerInch: 1, in: InkIndex(session.ink), work: &work)
        XCTAssertLessThanOrEqual(work.segmentPairsTested, PointSnap.intersectionSegmentLimit * PointSnap.intersectionSegmentLimit / 2)
    }
}
