#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import XCTest
@testable import VellumCore

/// Measure, dimension, frame and window (#8): the lengths they read in every canvas units, the dimension's
/// orientation from its third point, snapping taps to ink, the frame a drag makes, and dimensions and frames saved as
/// their own events that replay, undo and reopen exactly. Every stroke, dimension and frame here is made up for the
/// test.
final class MeasureFrameTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .inches(x), y: .inches(y)) }

    private func dimension(_ start: CanvasPoint, _ end: CanvasPoint, through: CanvasPoint) -> CanvasDimension {
        CanvasDimension.pulled(id: DimensionID(1), start: start, end: end, through: through, colour: .sketch,
                         textHeight: .inches(6))
    }

    // MARK: Lengths in every canvas units

    /// The header run from the prototype, exactly 13'-7 5/16", and lengths either side of a sixteenth, read as a
    /// dimension in each canvas units: feet and inches to the nearest 1/16", decimal feet to the hundredth, metric to
    /// the millimetre.
    func testADimensionReadsInTheCanvasUnitsRoundingFeetAndInchesToASixteenth() {
        let header = dimension(p(60, 48), p(223.3125, 48), through: p(100, 24))
        XCTAssertEqual(header.orientation, .horizontal)
        XCTAssertEqual(header.length, .inches(163.3125))
        let canvas = Canvas()
        XCTAssertEqual(canvas.format(canvas.measure(header)), "13'-7 5/16\"")
        XCTAssertEqual(Canvas(units: .decimalFeet).format(canvas.measure(header)), "13.61'")
        XCTAssertEqual(Canvas(units: .metric).format(canvas.measure(header)), "4.148 m")

        // 1/32" either side of a sixteenth rounds to it; feet and inches carry.
        let cases: [(Double, String)] = [
            (6.53, "0'-6 1/2\""), (6.55, "0'-6 9/16\""), (6 + 1.0 / 32, "0'-6 1/16\""), (143.99, "12'-0\""),
            (12 * 12 + 6.5, "12'-6 1/2\""),
        ]
        for (inches, shown) in cases {
            let d = dimension(p(0, 0), p(inches, 0), through: p(1, -10))
            XCTAssertEqual(canvas.format(canvas.measure(d)), shown, "\(inches) in")
        }
        // Decimal feet and metric stay as the canvas units set them.
        let d = dimension(p(0, 0), p(150.5, 0), through: p(1, -10))
        XCTAssertEqual(Canvas(units: .decimalFeet).format(canvas.measure(d)), "12.54'")
        XCTAssertEqual(Canvas(units: .metric).format(canvas.measure(d)), "3.823 m")
        let short = dimension(p(0, 0), p(13.78, 0), through: p(1, -10))
        XCTAssertEqual(Canvas(units: .metric).format(canvas.measure(short)), "350 mm")
    }

    /// A measure reads the same way: the straight distance between its two points.
    func testAMeasureReadsTheStraightDistanceInTheCanvasUnits() {
        let canvas = Canvas()
        let measure = canvas.measure(from: p(0, 0), to: p(36, 48))
        XCTAssertEqual(measure, .real(.feet(5)))
        XCTAssertEqual(canvas.format(measure), "5'-0\"")
        XCTAssertEqual(Canvas(units: .metric).format(measure), "1.524 m")
    }

    /// On an NTS sheet a dimension reads the printed length marked NTS, in every canvas units, never a real one.
    func testOnAnNTSSheetADimensionReadsPrintedInchesMarkedNTS() {
        let loop = Sheet(paper: .tabloid, scale: .notToScale, origin: p(1_000, 0))
        let canvas = Canvas(sheets: [loop])
        let onSheet = dimension(p(1_002, 2), p(1_005.5, 2), through: p(1_003, 1))
        XCTAssertEqual(canvas.measure(onSheet), .notToScale(.inches(3.5)))
        for units in CanvasUnits.allCases {
            XCTAssertEqual(Canvas(units: units, sheets: [loop]).format(canvas.measure(onSheet)), "3 1/2\" NTS")
        }
        // One end off the sheet is still NTS; both off it is real.
        let halfOn = dimension(p(990, 2), p(1_002, 2), through: p(995, 1))
        XCTAssertTrue(canvas.measure(halfOn).isNotToScale)
        let off = dimension(p(0, 0), p(12, 0), through: p(5, -1))
        XCTAssertEqual(canvas.measure(off), .real(.feet(1)))
    }

    // MARK: Pulling a dimension off

    /// The AutoCAD rule (#8, "pull it off"): above or below the two points is horizontal, beside them vertical, out at
    /// an angle aligned; each reads its own distance, and the line passes through the third point.
    func testTheThirdPointChoosesHorizontalVerticalOrAligned() {
        let a = p(0, 0), b = p(48, 36)   // 4' across, 3' down, 5' straight
        let above = dimension(a, b, through: p(20, -30))
        XCTAssertEqual(above.orientation, .horizontal)
        XCTAssertEqual(above.length, .feet(4))
        XCTAssertEqual(above.line.0, p(0, -30))
        XCTAssertEqual(above.line.1, p(48, -30))
        let below = dimension(a, b, through: p(30, 80))
        XCTAssertEqual(below.orientation, .horizontal)

        let beside = dimension(a, b, through: p(70, 10))
        XCTAssertEqual(beside.orientation, .vertical)
        XCTAssertEqual(beside.length, .feet(3))
        XCTAssertEqual(beside.line.0, p(70, 0))
        XCTAssertEqual(beside.line.1, p(70, 36))
        XCTAssertEqual(dimension(a, b, through: p(-20, 20)).orientation, .vertical)

        let angled = dimension(a, b, through: p(-12, 60))
        XCTAssertEqual(angled.orientation, .aligned)
        XCTAssertEqual(angled.length, .feet(5))
        // Parallel to the two points, offset so it passes through the third.
        let (d1, d2) = angled.line
        XCTAssertEqual(d2.x.inches - d1.x.inches, 48, accuracy: 1e-9)
        XCTAssertEqual(d2.y.inches - d1.y.inches, 36, accuracy: 1e-9)
        let along = ((-12 - d1.x.inches) * 36 - (60 - d1.y.inches) * 48)
        XCTAssertEqual(along, 0, accuracy: 1e-9, "the third point is on the line")
        // Inside both spans (between the points) is aligned too.
        XCTAssertEqual(dimension(a, b, through: p(24, 18)).orientation, .aligned)
    }

    /// Level points pulled above or below read across; plumb points pulled beside read up and down.
    func testLevelAndPlumbPointsPullTheObviousWay() {
        let level = dimension(p(0, 0), p(30, 0), through: p(10, -8))
        XCTAssertEqual(level.orientation, .horizontal)
        XCTAssertEqual(level.length, .inches(30))
        let plumb = dimension(p(0, 0), p(0, 30), through: p(8, 10))
        XCTAssertEqual(plumb.orientation, .vertical)
        XCTAssertEqual(plumb.length, .inches(30))
        XCTAssertEqual(plumb.textPosition, p(8, 15))
    }

    // MARK: Snapping a tap

    private func index(_ strokes: [[CanvasPoint]]) -> InkIndex {
        var session = InkSession()
        for points in strokes { session.draw(points, tool: .pen, colour: .sketch, width: .inches(0.5)) }
        return InkIndex(session.ink)
    }

    /// At 2 points an inch, 20 screen points is 10 inches: a tap snaps to an end, a corner or a centre within that,
    /// the nearest first, and to nothing beyond it.
    func testATapSnapsToEndsCornersAndCentresWithinTwentyPoints() {
        let line = SnappedShape.line(p(0, 0), p(200, 0)).points
        let box = SnappedShape.rectangle(centre: p(400, 100), width: .inches(100), height: .inches(60), angle: 0).points
        let circle = SnappedShape.ellipse(centre: p(100, 300), radiusX: .inches(40), radiusY: .inches(40), angle: 0).points
        let ink = index([line, box, circle])
        let ppi = 2.0

        let end = PointSnap.target(at: p(196, 3), pointsPerInch: ppi, in: ink)
        XCTAssertEqual(end, PointSnap.Target(point: p(200, 0), kind: .end))
        let corner = PointSnap.target(at: p(447, 74), pointsPerInch: ppi, in: ink)
        XCTAssertEqual(corner, PointSnap.Target(point: p(450, 70), kind: .corner))
        let firstCorner = PointSnap.target(at: p(352, 72), pointsPerInch: ppi, in: ink)
        XCTAssertEqual(firstCorner.point, p(350, 70), "a closed stroke's ends meet at a corner")
        XCTAssertEqual(firstCorner.kind, .corner)
        let centre = PointSnap.target(at: p(104, 297), pointsPerInch: ppi, in: ink)
        XCTAssertEqual(centre.kind, .centre)
        XCTAssertEqual(centre.point.x.inches, 100, accuracy: 1e-3)
        XCTAssertEqual(centre.point.y.inches, 300, accuracy: 1e-3)

        // 10 inches is the edge; just past it there is nothing, and the tip itself is the point.
        XCTAssertEqual(PointSnap.target(at: p(209.9, 0), pointsPerInch: ppi, in: ink).kind, .end)
        let beyond = PointSnap.target(at: p(210.1, 0), pointsPerInch: ppi, in: ink)
        XCTAssertEqual(beyond, PointSnap.Target(point: p(210.1, 0), kind: nil))
        // Zoomed in ten times, the same tap 9.9 inches away is 198 points away: no snap.
        XCTAssertNil(PointSnap.target(at: p(209.9, 0), pointsPerInch: 20, in: ink).kind)
        // Out on blank canvas: the tip.
        XCTAssertNil(PointSnap.target(at: p(-500, -500), pointsPerInch: ppi, in: ink).kind)
    }

    /// The nearest point wins, whatever its kind; a hand-drawn wobble is not a corner, and a rectangle has no centre.
    func testTheNearestPointWinsAndWobblesAndBoxesStayPlain() {
        let wobble = (0..<60).map { k in p(Double(k) * 2, sin(Double(k) * 0.3)) }
        let ink = index([wobble, SnappedShape.rectangle(centre: p(0, 100), width: .inches(20), height: .inches(20),
                                                        angle: 0).points])
        XCTAssertNil(PointSnap.target(at: p(60, 0), pointsPerInch: 1, in: ink).kind, "a wobble's middle is no corner")
        XCTAssertEqual(PointSnap.target(at: p(1, 1), pointsPerInch: 0.5, in: ink).point, p(0, 0))
        let middleOfBox = PointSnap.target(at: p(0, 100), pointsPerInch: 1.5, in: ink)
        XCTAssertNil(middleOfBox.kind, "a rectangle's middle is not a centre")
    }

    /// A tap looks only at the strokes near it, through the index, never the whole canvas: on the made-up
    /// 10,000-stroke canvas, at the zoom that fits it all, the strokes compared and the points read stay within their
    /// budgets in docs/perf/baselines/canvas-rendering.json.
    func testATapLooksOnlyAtStrokesNearIt() throws {
        let ink = MadeUpInk.largeWalkdown()
        let index = InkIndex(ink)
        var viewport = Viewport(pointsPerInch: 1, screenWidth: 951, screenHeight: 669)
        viewport.fit(try XCTUnwrap(ink.bounds), insets: ScreenInsets(top: 56, left: 70, bottom: 50, right: 92))
        // Ten taps across the middle of the canvas, the worst of them counted.
        var visited = 0, inspected = 0
        for i in 0..<10 {
            let tip = viewport.canvasPoint(for: ScreenPoint(x: 150 + Double(i) * 65, y: 330))
            var work = InkIndex.Work()
            _ = PointSnap.target(at: tip, pointsPerInch: viewport.pointsPerInch, in: index, work: &work)
            visited = max(visited, work.strokesVisited)
            inspected = max(inspected, work.pointsInspected)
        }
        MeasureFrameBaseline.check("point_snap_strokes_visited_per_tap", visited, area: "canvas-rendering",
                                   before: ink.count)
        MeasureFrameBaseline.check("point_snap_points_inspected_per_tap", inspected, area: "canvas-rendering",
                                   before: ink.strokes.reduce(0) { $0 + $1.points.count })
    }

    // MARK: A frame from a drag

    /// The prototype's frames: the boiler house (80' × 50') on 24 × 36 fits at 3/8" = 1'-0" (96' × 64'), since 1/2"
    /// would give only 72' across; the whole site (240' × 150') at 1/8" = 1'-0" (288' × 192'); a small drag at full
    /// size. Each is the largest standard scale whose paper still covers the drag.
    func testADragGetsTheLargestStandardScaleWhosePaperCoversIt() {
        func fit(_ w: Double, _ h: Double, _ paper: PaperSize = .archD, units: CanvasUnits = .feetAndInches) -> Frame {
            Frame.fitting(CanvasRect(origin: p(0, 0), size: CanvasSize(width: .feet(w), height: .feet(h))),
                          paper: paper, units: units)
        }
        let boiler = fit(80, 50)
        XCTAssertEqual(boiler.scale, .architectural(inchesPerFoot: 0.375))
        XCTAssertEqual(boiler.paper, .inches(36, by: 24), "landscape for a wide drag")
        XCTAssertEqual(boiler.label, "24×36 at 3/8\" = 1'-0\"")
        XCTAssertEqual(fit(97, 50).scale, .architectural(inchesPerFoot: 0.25), "past 96' it takes 1/4\" = 1'-0\"")
        XCTAssertEqual(fit(240, 150).scale, .architectural(inchesPerFoot: 0.125), "the site")
        XCTAssertEqual(fit(300, 150).scale, .engineering(feetPerInch: 10), "past 288' it takes 1\" = 10'")
        XCTAssertEqual(fit(2, 1).scale, .fullSize)
        // Every frame covers its drag, and the next larger scale would not.
        let scales = DrawingScale.frameScales(for: .feetAndInches)
        for (w, h) in [(1.0, 1.0), (13, 7), (80, 50), (97, 50), (240, 150), (900, 300)] {
            let frame = fit(w, h)
            XCTAssertGreaterThanOrEqual(frame.bounds.size.width.inches, w * 12)
            XCTAssertGreaterThanOrEqual(frame.bounds.size.height.inches, h * 12)
            if let i = scales.firstIndex(of: frame.scale), i > 0 {
                let larger = scales[i - 1]
                XCTAssertFalse(larger.realLength(of: frame.paper.width).inches >= w * 12
                               && larger.realLength(of: frame.paper.height).inches >= h * 12, "\(w) × \(h)")
            }
        }
        // A tall drag stands the paper up, and the frame is centred on the drag.
        let tall = fit(30, 70)
        XCTAssertEqual(tall.paper, .inches(24, by: 36))
        XCTAssertEqual(tall.bounds.center.x.inches, 15 * 12, accuracy: 1e-3)
        XCTAssertEqual(tall.bounds.center.y.inches, 35 * 12, accuracy: 1e-3)
        // Too big for every scale: the smallest scale there is.
        XCTAssertEqual(fit(100_000, 10).scale, scales.last)
        // Metric canvases take the ratio scales.
        let metric = fit(31, 20, .archD, units: .metric)
        XCTAssertEqual(metric.scale.notation, .ratio)
        XCTAssertEqual(metric.scale.realPerPrinted, 20, "36\" at 1:10 is 30', short of 31'; at 1:20 it is 60'")
        XCTAssertEqual(fit(8, 5, .letter).label, "8.5×11 at 1\" = 1'-0\"")
    }

    func testThePaperSizesAFrameOffersAreNamedTheTradesWay() {
        XCTAssertEqual(PaperSize.frameSizes.map(\.name), ["8.5×11", "11×17", "24×36", "30×42"])
        XCTAssertEqual(PaperSize.archD.landscape.name, "24×36")
        XCTAssertEqual(PaperSize.defaultFrame, .archD)
    }

    // MARK: Saving, replaying and undoing

    /// Ink, a text box, two dimensions and two frames, then every kind of selection change over them, an undo and a
    /// redo: every new event, each a step.
    private func everyKindOfChange() -> (InkSession, [InkEvent]) {
        var session = InkSession()
        var events: [InkEvent] = []
        func take() { events += session.takeEvents() }
        for i in 0..<3 {
            session.draw([p(Double(i) * 10, 0), p(Double(i) * 10 + 5, 3)], tool: .pen, colour: .red, width: .inches(0.2))
        }
        session.addText("Made-up note", at: p(0, 20), size: CanvasSize(width: .inches(30), height: .inches(4)),
                        fontSize: .inches(2), colour: .blue)
        let d1 = session.addDimension(start: p(0, 0), end: p(48.3, 0.2), through: p(10, -12), colour: .sketch,
                                      textHeight: .inches(3))
        XCTAssertEqual(d1?.orientation, .horizontal)
        let d2 = session.addDimension(start: p(0, 0), end: p(30, 40), through: p(-20, 50), colour: .red,
                                      textHeight: .inches(3))
        XCTAssertEqual(d2?.orientation, .aligned)
        let f1 = session.addFrame(paper: PaperSize.archD.landscape, scale: .architectural(inchesPerFoot: 0.25),
                                  origin: p(-100, -100))
        session.addFrame(paper: .letter, scale: .ratio(50), origin: p(1_000.1, 3))
        take()
        let picked = CanvasSelection(strokes: [StrokeID(1)], dimensions: [DimensionID(1)], frames: [f1.id])
        session.transform(picked, by: .translation(dx: .inches(7), dy: .inches(-3)))
        session.transform(CanvasSelection(dimensions: [DimensionID(2)]),
                          by: .scaling(by: 2, about: p(0, 0)))
        let copies = session.duplicate(picked, by: .translation(dx: .inches(2), dy: .inches(2)))
        XCTAssertEqual(copies.dimensions, [DimensionID(3)])
        XCTAssertEqual(copies.frames, [FrameID(3)])
        session.delete(CanvasSelection(dimensions: [DimensionID(2)], frames: [FrameID(2)]))
        session.undo()
        session.redo()
        session.undo()
        take()
        return (session, events)
    }

    func testEveryNewEventRoundTripsThroughTheCodec() throws {
        let (_, events) = everyKindOfChange()
        var kinds = Set<String>()
        for event in events {
            switch event {
            case .addDimension: kinds.insert("addDimension")
            case .addFrame: kinds.insert("addFrame")
            case .transform(let s, _) where !s.dimensions.isEmpty || !s.frames.isEmpty: kinds.insert("transform")
            case .duplicate(let s, _, _, _, _, _) where !s.frames.isEmpty: kinds.insert("duplicate")
            case .delete(let s) where !s.dimensions.isEmpty: kinds.insert("delete")
            default: break
            }
            XCTAssertEqual(try InkCodec.decodeEvent(InkCodec.encode(event)[...]), event)
        }
        XCTAssertEqual(kinds, ["addDimension", "addFrame", "transform", "duplicate", "delete"])
    }

    /// A move of ink alone keeps #7's bytes, so the 1,000-stroke budgets hold and an older Vellum's log reads.
    func testASelectionOfInkAloneKeepsItsVersionTwoBytes() {
        let ink = CanvasSelection(strokes: [StrokeID(1), StrokeID(2)], texts: [TextBoxID(1)])
        let move = InkEvent.transform(ink, .translation(dx: .inches(1), dy: .zero))
        XCTAssertEqual(InkCodec.encode(move).first, 5)
        XCTAssertEqual(InkCodec.encode(.delete(ink)).first, 7)
        let withDimension = CanvasSelection(strokes: [StrokeID(1)], dimensions: [DimensionID(4)])
        XCTAssertEqual(InkCodec.encode(.delete(withDimension)).first, 14)
    }

    func testReplayingTheEventsRebuildsDimensionsFramesAndHistoryExactly() {
        let (session, events) = everyKindOfChange()
        var replayed = InkSession()
        for event in events { replayed.apply(event) }
        XCTAssertEqual(replayed, session)
        XCTAssertEqual(replayed.dimensions.count, 3)
        XCTAssertEqual(replayed.frames.count, 3)
        var a = session, b = replayed
        while a.canUndo {
            a.undo(); b.undo()
            XCTAssertEqual(a, b)
        }
        XCTAssertTrue(a.dimensions.isEmpty)
        XCTAssertTrue(a.frames.isEmpty)
        while a.canRedo {
            a.redo(); b.redo()
            XCTAssertEqual(a, b)
        }
        XCTAssertEqual(a.dimensions, session.dimensions)
    }

    /// Placing a dimension or a frame is one undo step each; undo takes it away and redo puts it back the same. A
    /// dimension's points are kept on the ink grid, and two taps in the same place make none.
    func testDimensionsAndFramesAreUndoSteps() throws {
        var session = InkSession()
        let d = try XCTUnwrap(session.addDimension(start: p(0.123456789, 0), end: p(10, 0), through: p(5, -3),
                                                   colour: .blue, textHeight: .inches(1)))
        XCTAssertEqual(d.start, p(0.123456789, 0).onInkGrid)
        XCTAssertEqual(session.lastChange.addedDimensions, [d])
        let f = session.addFrame(paper: .tabloid, scale: .fullSize, origin: p(3, 3))
        XCTAssertEqual(session.undoSteps, 2)
        session.undo()
        XCTAssertNil(session.frame(f.id))
        XCTAssertEqual(session.lastChange.removedFrames, [f.id])
        session.undo()
        XCTAssertNil(session.dimension(d.id))
        session.redo()
        session.redo()
        XCTAssertEqual(session.dimension(d.id), d)
        XCTAssertEqual(session.frame(f.id), f)
        XCTAssertNil(session.addDimension(start: p(1, 1), end: p(1, 1), through: p(2, 2), colour: .red,
                                          textHeight: .inches(1)))
        XCTAssertEqual(session.undoSteps, 2)
        // The next ones take the next ids, even after an undo.
        session.undo()
        XCTAssertEqual(session.addFrame(paper: .letter, scale: .fullSize, origin: .origin).id, FrameID(2))
    }

    /// The lasso takes a dimension by the middle of its line and a frame only when the loop goes round all of it; a
    /// move carries them, a resize scales a dimension and moves a frame without changing its paper or scale.
    func testTheLassoSelectsMovesAndDeletesDimensionsAndFrames() throws {
        var session = InkSession()
        let d = try XCTUnwrap(session.addDimension(start: p(0, 0), end: p(20, 0), through: p(10, -5), colour: .sketch,
                                                   textHeight: .inches(1)))
        let f = session.addFrame(paper: .letter, scale: .fullSize, origin: p(100, 100))
        let square = { (x0: Double, y0: Double, x1: Double, y1: Double) in
            try XCTUnwrap(Lasso([self.p(x0, y0), self.p(x1, y0), self.p(x1, y1), self.p(x0, y1)]))
        }
        let roundTheText = try square(5, -8, 15, -2)
        XCTAssertEqual(roundTheText.select(in: InkIndex(), texts: [], dimensions: session.dimensions,
                                           frames: session.frames),
                       CanvasSelection(dimensions: [d.id]))
        let insideTheFrame = try square(101, 101, 107, 109)
        XCTAssertTrue(insideTheFrame.select(in: InkIndex(), texts: [], dimensions: session.dimensions,
                                            frames: session.frames).isEmpty)
        let roundTheFrame = try square(99, 99, 110, 112)
        XCTAssertEqual(roundTheFrame.select(in: InkIndex(), texts: [], dimensions: [], frames: session.frames),
                       CanvasSelection(frames: [f.id]))

        let both = CanvasSelection(dimensions: [d.id], frames: [f.id])
        session.transform(both, by: .scaling(by: 2, about: .origin))
        let scaled = try XCTUnwrap(session.dimension(d.id))
        XCTAssertEqual(scaled.end, p(40, 0))
        XCTAssertEqual(scaled.textHeight, .inches(2))
        XCTAssertEqual(scaled.length, .inches(40))
        let moved = try XCTUnwrap(session.frame(f.id))
        XCTAssertEqual(moved.paper, f.paper)
        XCTAssertEqual(moved.scale, f.scale)
        XCTAssertEqual(moved.bounds.center.x.inches, f.bounds.center.x.inches * 2, accuracy: 1e-4)
        XCTAssertEqual(session.selectionAfterLastChange, both)
        session.delete(both)
        XCTAssertTrue(session.dimensions.isEmpty)
        XCTAssertTrue(session.frames.isEmpty)
        session.undo()
        XCTAssertEqual(session.dimension(d.id), scaled)
        XCTAssertEqual(session.selectionAfterLastChange, both)
    }

    /// A snapshot holds dimensions, frames and their history, and reads back the same; a snapshot of a canvas that
    /// never had either reads under version 2 as before.
    func testASnapshotHoldsDimensionsFramesAndTheirHistory() throws {
        let (session, _) = everyKindOfChange()
        let decoded = try InkCodec.decodeSession(InkCodec.encode(session)[...])
        XCTAssertEqual(decoded, session)
        var a = session, b = decoded
        while a.canUndo {
            a.undo(); b.undo()
            XCTAssertEqual(a, b)
        }
        while a.canRedo {
            a.redo(); b.redo()
            XCTAssertEqual(a, b)
        }

        var plain = InkSession()
        plain.draw([p(0, 0), p(1, 1)], tool: .pen, colour: .red, width: .inches(0.1))
        plain.addText("Made up", at: .origin, size: CanvasSize(width: .inches(2), height: .inches(1)),
                      fontSize: .inches(0.5), colour: .sketch)
        XCTAssertEqual(try InkCodec.decodeSession(InkCodec.encode(plain)[...], version: 2), plain)
        // A canvas whose only dimension was undone still keeps its next id.
        plain.addDimension(start: .origin, end: p(5, 0), through: p(2, -1), colour: .sketch, textHeight: .inches(1))
        plain.undo()
        XCTAssertEqual(try InkCodec.decodeSession(InkCodec.encode(plain)[...]), plain)
    }

    func testDimensionsAndFramesReopenFromTheDuoThroughTheLogAndTheSnapshot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-dim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (session, events) = everyKindOfChange()
        let store = try InkStore(folder: folder)
        try store.append(events)
        try store.flush()
        store.closeFiles()
        XCTAssertEqual(try InkStore(folder: folder).session, session, "from the log")

        let again = try InkStore(folder: folder)
        try again.compact()
        again.closeFiles()
        let reopened = try InkStore(folder: folder)
        XCTAssertEqual(reopened.session, session, "from the snapshot")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(files), [InkStore.snapshotName, InkStore.logName], "still only the ink files")
    }

    /// A canvas saved by version 2 (its files' headers say 2) still opens, and takes dimensions and frames.
    func testAVersionTwoCanvasStillOpensAndTakesDimensionsAndFrames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var session = InkSession()
        let store = try InkStore(folder: folder)
        session.draw([p(0, 0), p(4, 4)], tool: .pen, colour: .red, width: .inches(0.2))
        session.addText("Made up", at: .origin, size: CanvasSize(width: .inches(2), height: .inches(1)),
                        fontSize: .inches(0.5), colour: .sketch)
        try store.append(session.takeEvents())
        try store.compact()
        session.draw([p(10, 0), p(14, 4)], tool: .pen, colour: .red, width: .inches(0.2))
        try store.append(session.takeEvents())
        try store.flush()
        store.closeFiles()
        for name in [InkStore.snapshotName, InkStore.logName] {
            let url = folder.appendingPathComponent(name)
            var bytes = try [UInt8](Data(contentsOf: url))
            bytes[4] = 2
            bytes[5] = 0
            try Data(bytes).write(to: url)
        }
        let old = try InkStore(folder: folder)
        XCTAssertEqual(old.session, session)
        session.addDimension(start: p(0, 0), end: p(14, 0), through: p(7, -2), colour: .sketch, textHeight: .inches(1))
        session.addFrame(paper: .tabloid, scale: .fullSize, origin: p(-1, -1))
        try old.append(session.takeEvents())
        try old.compact()
        old.closeFiles()
        XCTAssertEqual(try InkStore(folder: folder).session, session)
    }

    // MARK: Budgets

    /// A dimension or a frame placed appends one small record, whatever is on the canvas.
    func testADimensionOrAFrameAppendsOneSmallRecord() throws {
        var session = InkSession()
        for i in 0..<50 {
            session.draw((0..<20).map { p(Double(i) + Double($0), sin(Double($0))) }, tool: .pen, colour: .red,
                         width: .inches(0.2))
        }
        _ = session.takeEvents()
        // A dimension 30' long, 100' from the origin, at a plant zoom.
        session.addDimension(start: p(1_200, 1_200), end: p(1_560, 1_210), through: p(1_400, 1_150), colour: .sketch,
                             textHeight: .inches(8))
        let dimensionBytes = session.takeEvents().reduce(0) { $0 + InkCodec.encode($1).count + InkCodec.frameSize }
        MeasureFrameBaseline.check("bytes-appended-per-dimension", dimensionBytes, area: "storage", before: nil)
        session.addFrame(paper: PaperSize.archD.landscape, scale: .architectural(inchesPerFoot: 0.25),
                         origin: p(1_000, 900))
        let frameBytes = session.takeEvents().reduce(0) { $0 + InkCodec.encode($1).count + InkCodec.frameSize }
        MeasureFrameBaseline.check("bytes-appended-per-frame", frameBytes, area: "storage", before: nil)
    }
}

/// The #8 budgets, read from their area's baseline file so it is the single source of each number.
enum MeasureFrameBaseline {
    private struct Entry: Decodable {
        let metric: String
        let kind: String
        let value: Double
    }

    private struct Wrapped: Decodable { let entries: [Entry] }

    private static func entries(_ area: String) -> [String: Double] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // Tests/VellumCoreTests
            .appendingPathComponent("../../../../docs/perf/baselines/\(area).json").standardizedFileURL
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let list = (try? JSONDecoder().decode(Wrapped.self, from: data).entries)
            ?? (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        return Dictionary(list.filter { $0.kind == "count" }.map { ($0.metric, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    static func check(_ metric: String, _ measured: Int, area: String, before: Int?, file: StaticString = #filePath,
                      line: UInt = #line) {
        print("PERF \(area) \(metric)=\(measured)" + (before.map { " (before: \($0))" } ?? ""))
        guard let budget = entries(area)[metric] else {
            return XCTFail("no count baseline named \(metric) in docs/perf/baselines/\(area).json", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(Double(measured), budget, "\(metric) is over its budget", file: file, line: line)
        if Double(measured) < budget { print("PERF \(area) \(metric) came in under its budget \(Int(budget))") }
    }
}

/// The lengths the #8 simulator captures show (Vellum/DebugMeasureFrame.swift), worked out from the same points of
/// the made-up fixture, in feet: "Done when lengths on the simulator match the unit-tested model".
final class MeasureFrameCaptureTests: XCTestCase {
    private func ft(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .feet(x), y: .feet(y)) }

    func testTheCaptureLengthsMatchTheModel() {
        let canvas = Canvas()
        XCTAssertEqual(canvas.format(canvas.measure(from: ft(4, 10), to: ft(40, 17))), "36'-8 1/16\"")
        let top = CanvasDimension.pulled(id: DimensionID(1), start: ft(50, -6), end: ft(58, -6), through: ft(54, -9),
                                   colour: .sketch, textHeight: .inches(12))
        XCTAssertEqual(top.orientation, .horizontal)
        XCTAssertEqual(canvas.format(canvas.measure(top)), "8'-0\"")
        let across = CanvasDimension.pulled(id: DimensionID(2), start: ft(40, 17), end: ft(54, 4), through: ft(49, 13.5),
                                      colour: .blue, textHeight: .inches(12))
        XCTAssertEqual(across.orientation, .aligned)
        XCTAssertEqual(canvas.format(canvas.measure(across)), "19'-1 1/4\"")
        let frame = Frame.fitting(CanvasRect(origin: ft(24, 5), size: CanvasSize(width: .feet(12), height: .feet(11))),
                                  paper: .archD, units: .feetAndInches)
        XCTAssertEqual(frame.label, "24×36 at 1 1/2\" = 1'-0\"")
    }
}
