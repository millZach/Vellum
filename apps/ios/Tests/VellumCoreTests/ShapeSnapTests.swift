import Foundation
import XCTest
@testable import VellumCore

/// Snapping a stroke to a line, a rectangle or a circle when the Pencil holds still at its end (#7). Every stroke here
/// is made up for the test: shapes drawn with a made-up hand's jitter, and near misses that must stay freehand.
final class ShapeSnapTests: XCTestCase {
    // MARK: Made-up hands

    /// A repeatable jitter, -1 to 1.
    private struct Jitter {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    /// Feet, to inches on the canvas.
    private func p(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .feet(x), y: .feet(y)) }

    /// A polyline through corners, `per` samples a side, each nudged by up to `jitter` feet.
    private func hand(_ corners: [(Double, Double)], per: Int, jitter: Double, seed: UInt64) -> [CanvasPoint] {
        var j = Jitter(state: seed)
        var out: [CanvasPoint] = []
        for i in 0..<(corners.count - 1) {
            let (a, b) = (corners[i], corners[i + 1])
            for k in 0..<per {
                let t = Double(k) / Double(per)
                out.append(p(a.0 + (b.0 - a.0) * t + jitter * j.next(), a.1 + (b.1 - a.1) * t + jitter * j.next()))
            }
        }
        out.append(p(corners[corners.count - 1].0, corners[corners.count - 1].1))
        return out
    }

    private func ellipse(rx: Double, ry: Double, samples: Int = 80, jitter: Double, seed: UInt64, turn: Double = 1,
                         rotation: Double = 0) -> [CanvasPoint] {
        var j = Jitter(state: seed)
        return (0...samples).map { i in
            let t = Double(i) / Double(samples) * 2 * Double.pi * turn
            let (x, y) = (rx * cos(t), ry * sin(t))
            return p(x * cos(rotation) - y * sin(rotation) + jitter * j.next(),
                     x * sin(rotation) + y * cos(rotation) + jitter * j.next())
        }
    }

    private func radial(_ radius: (Double) -> Double, samples: Int = 80) -> [CanvasPoint] {
        (0...samples).map { i in
            let t = Double(i) / Double(samples) * 2 * Double.pi
            return p(radius(t) * cos(t), radius(t) * sin(t))
        }
    }

    // MARK: Lines

    func testAStrokeDrawnStraightSnapsToALineBetweenItsEnds() throws {
        let stroke = hand([(0, 0), (10, 4)], per: 60, jitter: 0.08, seed: 1)
        guard case .line(let a, let b) = try XCTUnwrap(ShapeSnap.recognize(stroke)) else { return XCTFail("not a line") }
        XCTAssertEqual(a, stroke.first)
        XCTAssertEqual(b, stroke.last)
    }

    func testALineNearlyLevelSquaresUpToLevel() throws {
        let stroke = hand([(0, 0), (10, 0.4)], per: 60, jitter: 0.05, seed: 2)
        guard case .line(let a, let b) = try XCTUnwrap(ShapeSnap.recognize(stroke)) else { return XCTFail("not a line") }
        XCTAssertEqual(a.y, b.y, "within 5 degrees of level, a line is level")
        XCTAssertEqual(b.distance(to: a).inches, stroke.last!.distance(to: a).inches, accuracy: 1e-9,
                       "and keeps its length")
        let plumb = try XCTUnwrap(ShapeSnap.recognize(hand([(0, 0), (0.3, -9)], per: 50, jitter: 0.04, seed: 3)))
        guard case .line(let c, let d) = plumb else { return XCTFail("not a line") }
        XCTAssertEqual(c.x, d.x)
    }

    func testWobblyOpenStrokesStayFreehand() {
        let zigzag = (0..<50).map { i in p(Double(i) * 0.2, i % 2 == 0 ? -0.6 : 0.6) }
        XCTAssertNil(ShapeSnap.recognize(zigzag), "a zigzag")
        let sCurve = (0..<100).map { i in p(Double(i) * 0.1, 1.2 * sin(Double(i) * 0.06)) }
        XCTAssertNil(ShapeSnap.recognize(sCurve), "a gentle bow")
        XCTAssertNil(ShapeSnap.recognize(ellipse(rx: 5, ry: 5, jitter: 0.02, seed: 3, turn: 0.5)), "a half circle")
        let bowed = (0...60).map { i -> CanvasPoint in
            let t = Double(i) / 60
            return p(10 * t, 0.9 * sin(t * Double.pi))  // bows out 9% of its length
        }
        XCTAssertNil(ShapeSnap.recognize(bowed), "a line bowed by 9% is a curve")
        let handwriting = (0..<120).map { i in
            p(Double(i) * 0.05, 0.3 * sin(Double(i) / 3) + 0.1 * sin(Double(i) * 1.7))
        }
        XCTAssertNil(ShapeSnap.recognize(handwriting), "handwriting")
    }

    // MARK: Closed shapes

    func testAClosedBoxSnapsToARectangle() throws {
        let box = hand([(0, 0), (8, 0), (8, 5), (0, 5), (0.2, 0.3)], per: 40, jitter: 0.08, seed: 4)
        guard case .rectangle(let centre, let width, let height, let angle) = try XCTUnwrap(ShapeSnap.recognize(box))
        else { return XCTFail("not a rectangle") }
        XCTAssertEqual(angle, 0, "square to the canvas")
        XCTAssertEqual(width.feet, 8, accuracy: 0.3)
        XCTAssertEqual(height.feet, 5, accuracy: 0.3)
        XCTAssertEqual(centre.x.feet, 4, accuracy: 0.2)
        XCTAssertEqual(centre.y.feet, 2.5, accuracy: 0.2)
        let points = SnappedShape.rectangle(centre: centre, width: width, height: height, angle: angle).points
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points.first, points.last, "a closed rectangle")
    }

    func testATurnedBoxSnapsToATurnedRectangle() throws {
        let turn = 0.5
        let box = hand([(0, 0), (8, 0), (8, 5), (0, 5), (0.1, 0.2)], per: 40, jitter: 0.06, seed: 5).map { q in
            CanvasPoint(x: .inches(q.x.inches * cos(turn) - q.y.inches * sin(turn)),
                        y: .inches(q.x.inches * sin(turn) + q.y.inches * cos(turn)))
        }
        guard case .rectangle(_, let width, let height, let angle) = try XCTUnwrap(ShapeSnap.recognize(box))
        else { return XCTFail("not a rectangle") }
        // The rectangle is the same whichever side is called its width.
        let sides = [width.feet, height.feet].sorted()
        XCTAssertEqual(sides[0], 5, accuracy: 0.3)
        XCTAssertEqual(sides[1], 8, accuracy: 0.3)
        let turned = angle.truncatingRemainder(dividingBy: Double.pi / 2)
        XCTAssertEqual(min(abs(turned - turn), abs(turned - (turn - Double.pi / 2))), 0, accuracy: 2 * Double.pi / 180)
    }

    func testARoundedBoxIsStillARectangle() throws {
        // Corners drawn round, as a quick hand does.
        var points: [CanvasPoint] = []
        let (w, h, r) = (8.0, 5.0, 0.5)
        let sides: [((Double, Double), (Double, Double))] = [((r, 0), (w - r, 0)), ((w, r), (w, h - r)),
                                                             ((w - r, h), (r, h)), ((0, h - r), (0, r))]
        let corners: [(Double, Double, Double)] = [(w - r, r, -90), (w - r, h - r, 0), (r, h - r, 90), (r, r, 180)]
        for k in 0..<4 {
            let (a, b) = sides[k]
            for i in 0..<20 {
                let t = Double(i) / 20
                points.append(p(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t))
            }
            let (cx, cy, start) = corners[k]
            for i in 0..<8 {
                let angle = (start + 90 * Double(i) / 8) * Double.pi / 180
                points.append(p(cx + r * cos(angle), cy + r * sin(angle)))
            }
        }
        points.append(points[0])
        guard case .rectangle? = ShapeSnap.recognize(points) else { return XCTFail("not a rectangle") }
    }

    func testAClosedRoundStrokeSnapsToACircle() throws {
        let round = ellipse(rx: 5, ry: 5, jitter: 0.1, seed: 6)
        guard case .ellipse(let centre, let rx, let ry, _) = try XCTUnwrap(ShapeSnap.recognize(round))
        else { return XCTFail("not a circle") }
        XCTAssertEqual(rx, ry, "nearly round is a circle")
        XCTAssertEqual(rx.feet, 5, accuracy: 0.2)
        XCTAssertEqual(centre.x.feet, 0, accuracy: 0.2)
        XCTAssertEqual(SnappedShape.ellipse(centre: centre, radiusX: rx, radiusY: ry, angle: 0).name, "circle")
        // Not quite closed, as a quick circle often isn't.
        guard case .ellipse? = ShapeSnap.recognize(ellipse(rx: 5, ry: 5, jitter: 0.1, seed: 7, turn: 0.93)) else {
            return XCTFail("an almost closed circle")
        }
    }

    func testAnOvalSnapsToAnEllipseAtItsAngle() throws {
        let oval = ellipse(rx: 8, ry: 4, jitter: 0.1, seed: 8, rotation: 0.3)
        guard case .ellipse(_, let rx, let ry, let angle) = try XCTUnwrap(ShapeSnap.recognize(oval))
        else { return XCTFail("not an ellipse") }
        XCTAssertNotEqual(rx, ry)
        XCTAssertEqual(max(rx.feet, ry.feet), 8, accuracy: 0.3)
        XCTAssertEqual(min(rx.feet, ry.feet), 4, accuracy: 0.3)
        XCTAssertEqual(angle, 0.3, accuracy: 2 * Double.pi / 180)
        let points = SnappedShape.ellipse(centre: .origin, radiusX: rx, radiusY: ry, angle: angle).points
        XCTAssertEqual(points.count, SnappedShape.ellipseSegments + 1)
        XCTAssertEqual(points.first!.distance(to: points.last!).inches, 0, accuracy: 1e-9)
    }

    func testWobblyClosedShapesAndNearMissesStayFreehand() {
        XCTAssertNil(ShapeSnap.recognize(hand([(0, 0), (8, 0), (4, 7), (0.1, 0.2)], per: 40, jitter: 0.05, seed: 9)),
                     "a triangle")
        let star = (0...10).map { i -> CanvasPoint in
            let r = i % 2 == 0 ? 5.0 : 2.0, a = Double(i) * Double.pi / 5
            return p(r * cos(a), r * sin(a))
        }
        XCTAssertNil(ShapeSnap.recognize(star), "a star")
        XCTAssertNil(ShapeSnap.recognize(radial { 5 + 1.5 * sin(3 * $0) }), "a three-lobed blob")
        XCTAssertNil(ShapeSnap.recognize(radial { 5 + 0.8 * sin(7 * $0) }), "a wobbly circle, a cloud")
        XCTAssertNil(ShapeSnap.recognize(hand([(0, 0), (8, 0), (8, 5), (0, 5), (0, 0)], per: 40, jitter: 0.6, seed: 10)),
                     "a box drawn too shakily")
        XCTAssertNil(ShapeSnap.recognize(hand([(0, 0), (10, 0.3), (0.2, 0.1)], per: 40, jitter: 0.02, seed: 11)),
                     "a line drawn there and back is too thin to be a shape")
    }

    func testATickTooSmallOnScreenNeverSnaps() {
        let tick = hand([(0, 0), (0.5, 0.2)], per: 10, jitter: 0, seed: 12)
        XCTAssertNotNil(ShapeSnap.recognize(tick))
        XCTAssertNil(ShapeSnap.recognize(tick, minimumSize: .feet(1)))
        XCTAssertNil(ShapeSnap.recognize([p(1, 1)]))
        XCTAssertNil(ShapeSnap.recognize([p(1, 1), p(1, 1)]))
    }

    /// The line and shape tool's fallback: a stroke that is no shape becomes a straight line from end to end.
    func testTheLineToolFallsBackToAStraightLine() throws {
        let squiggle = (0..<50).map { i in p(Double(i) * 0.2, i % 2 == 0 ? -0.6 : 0.6) }
        guard case .line(let a, let b) = try XCTUnwrap(ShapeSnap.straightLine(squiggle)) else { return XCTFail() }
        XCTAssertEqual(a, squiggle.first)
        XCTAssertEqual(b.x, squiggle.last!.x)
        XCTAssertNil(ShapeSnap.straightLine([p(1, 1)]))
    }

    /// Snapping keeps the stroke's pen, colour and width, and takes the shape's points.
    func testASnappedStrokeKeepsItsPenAndTakesTheShape() {
        var stroke = StrokeInProgress(tool: .pen, colour: .green, width: .inches(0.5), start: p(0, 0))
        for q in hand([(0, 0), (10, 4)], per: 30, jitter: 0.05, seed: 13).dropFirst() { stroke.add(q) }
        let shape = SnappedShape.line(p(0, 0), p(10, 4))
        let snapped = stroke.snapped(to: shape)
        XCTAssertEqual(snapped.points, [p(0, 0), p(10, 4)])
        XCTAssertEqual(snapped.colour, .green)
        XCTAssertEqual(snapped.width, .inches(0.5))
        var session = InkSession()
        session.commit(snapped)
        XCTAssertEqual(session.ink.strokes.first?.points.count, 2, "a snapped line is one two-point stroke")
        XCTAssertEqual(session.undoSteps, 1, "and one undo step")
    }

    // MARK: Holding still

    func testHoldingStillForTheIntervalSnapsOnce() {
        var hold = StrokeHold()
        XCTAssertEqual(ShapeSnap.holdInterval, 0.5)
        XCTAssertFalse(hold.update(at: ScreenPoint(x: 100, y: 100), time: 10))
        XCTAssertFalse(hold.update(at: ScreenPoint(x: 102, y: 101), time: 10.3), "drifting within the radius")
        XCTAssertTrue(hold.update(at: ScreenPoint(x: 101, y: 103), time: 10.5), "held for the interval")
        XCTAssertFalse(hold.update(at: ScreenPoint(x: 101, y: 103), time: 11.5), "once per hold")
        XCTAssertFalse(hold.update(at: ScreenPoint(x: 140, y: 100), time: 11.6), "moving on starts a new hold")
        XCTAssertFalse(hold.update(at: ScreenPoint(x: 140, y: 100), time: 12.0))
        XCTAssertTrue(hold.update(at: ScreenPoint(x: 140, y: 100), time: 12.1))
    }

    func testMovingKeepsAHoldFromFiring() {
        var hold = StrokeHold()
        for i in 0..<120 {
            XCTAssertFalse(hold.update(at: ScreenPoint(x: Double(i) * 5, y: 0), time: Double(i) / 60))
        }
    }

    /// Recognising runs once at the hold, on 64 points evenly spaced, whatever the stroke's length: its cost after
    /// reading the stroke does not grow with the stroke.
    func testRecognitionTestsAFixedNumberOfPointsHoweverLongTheStroke() {
        var short = ShapeSnap.Work(), long = ShapeSnap.Work()
        _ = ShapeSnap.recognize(ellipse(rx: 5, ry: 5, samples: 80, jitter: 0, seed: 14), minimumSize: .zero,
                                work: &short)
        _ = ShapeSnap.recognize(ellipse(rx: 5, ry: 5, samples: 8_000, jitter: 0, seed: 14), minimumSize: .zero,
                                work: &long)
        XCTAssertEqual(short.pointsTested, long.pointsTested)
        XCTAssertEqual(long.pointsRead, 2 * 8_001)
    }
}
