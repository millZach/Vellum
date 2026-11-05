import XCTest
@testable import VellumCore

private func p(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .inches(x), y: .inches(y)) }

/// Snapping to a placed sheet's outline (#57), and a mark on an edge keeping its sheet and scale through many turns (#49),
/// with exact numbers. The sheets are made up for the tests: 10 × 10 printed inches, at 1:48 unless said otherwise, with a
/// 1:24 scale area in the top-left corner whose top and left edges are the sheet's own there.
final class SheetSnapTests: XCTestCase {
    private let angles = [0, 90, 33.5, 123.4] as [Double]
    private let fortyEight = Sheet.Scale.drawn(.ratio(48))
    private let twentyFour = Sheet.Scale.drawn(.ratio(24))

    private func sheet(_ scale: Sheet.Scale? = nil, area: Sheet.Scale? = .drawn(.ratio(24)),
                       areaRect: PaperRect = .inches(x: 0, y: 0, width: 4, height: 4), angle: Double = 0,
                       origin: CanvasPoint = p(0.3, 0.7).onInkGrid, id: Int = 1) -> Sheet {
        let flat = Sheet(id: SheetID(id), paper: .inches(10, by: 10), scale: scale ?? fortyEight, origin: origin,
                         areas: area.map { [ScaleArea(name: "Detail", rect: areaRect, scale: $0)] } ?? [])
        return angle == 0 ? flat : flat.turned(to: angle).sheet
    }

    private func on(_ sheet: Sheet, _ x: Double, _ y: Double) -> CanvasPoint {
        sheet.canvasPoint(at: PaperPoint(x: .inches(x), y: .inches(y)))
    }

    /// The zoom at which the 20 points' reach is 5/6 of a printed inch on this sheet: 40 inches at 1:48.
    private func ppi(_ sheet: Sheet) -> Double { 24 / sheet.canvasPerPrinted }

    private func snap(_ tip: CanvasPoint, on sheet: Sheet, among sheets: [Sheet]? = nil, ink: InkIndex = InkIndex(),
                      anchor: CanvasPoint? = nil) -> PointSnap.Target {
        PointSnap.target(at: tip, pointsPerInch: ppi(sheet), in: ink, sheets: SheetIndex(sheets ?? [sheet]), anchor: anchor)
    }

    private func read(_ a: CanvasPoint, _ b: CanvasPoint, on sheets: [Sheet]) -> String {
        let canvas = Canvas(sheets: sheets)
        return canvas.format(canvas.measure(from: a, to: b))
    }

    private func assertNear(_ a: CanvasPoint, _ b: CanvasPoint, _ message: String, file: StaticString = #filePath,
                            line: UInt = #line) {
        // The snapped point is on the ink grid: within half a step of the exact one on each axis.
        let step = 1 / CanvasPoint.gridUnitsPerInch
        XCTAssertEqual(a.x.inches, b.x.inches, accuracy: step / 2 + 1e-12, message, file: file, line: line)
        XCTAssertEqual(a.y.inches, b.y.inches, accuracy: step / 2 + 1e-12, message, file: file, line: line)
    }

    func testTheLoupeNamesSheetCornersAndEdges() {
        XCTAssertEqual(PointSnap.Kind.sheetCorner.title, "Sheet corner")
        XCTAssertEqual(PointSnap.Kind.sheetEdge.title, "Sheet edge")
    }

    // MARK: Corners and edges

    /// Each of the four corners, and each of the four edges anywhere along it, at 0°, a quarter turn and two oblique angles.
    /// The tip by a corner is nearer the edge than the corner, and the corner still wins: a point beats an edge.
    func testEveryCornerAndEveryEdgeSnapsAtEveryAngle() {
        for angle in angles {
            let s = sheet(angle: angle)
            let corners: [(tip: (Double, Double), at: (Double, Double))] = [
                ((0.2, 0.3), (0, 0)), ((9.7, 0.2), (10, 0)), ((9.8, 9.6), (10, 10)), ((0.3, 9.8), (0, 10)),
            ]
            for corner in corners {
                let target = snap(on(s, corner.tip.0, corner.tip.1), on: s)
                XCTAssertEqual(target.kind, .sheetCorner, "\(angle) \(corner.at)")
                XCTAssertEqual(target.point, on(s, corner.at.0, corner.at.1).onInkGrid, "\(angle) \(corner.at)")
                XCTAssertNil(target.along)
                XCTAssertTrue(s.contains(target.point), "\(angle) \(corner.at)")
            }
            // Top, right, bottom and left, each by a point well along it; `along` is the edge's direction round the paper.
            let edges: [(tip: (Double, Double), at: (Double, Double), from: Int)] = [
                ((5, 0.4), (5, 0), 0), ((9.5, 3.3), (10, 3.3), 1), ((6.2, 9.7), (6.2, 10), 2), ((0.4, 2), (0, 2), 3),
            ]
            let outline = s.corners
            for edge in edges {
                let target = snap(on(s, edge.tip.0, edge.tip.1), on: s)
                XCTAssertEqual(target.kind, .sheetEdge, "\(angle) \(edge.at)")
                assertNear(target.point, on(s, edge.at.0, edge.at.1), "\(angle) \(edge.at)")
                let (a, b) = (outline[edge.from], outline[(edge.from + 1) % 4])
                XCTAssertEqual(target.along ?? .nan, atan2(b.y.inches - a.y.inches, b.x.inches - a.x.inches), accuracy: 1e-12)
                XCTAssertTrue(s.contains(target.point), "\(angle) \(edge.at)")
            }
        }
    }

    /// The middle of an edge is no point of its own: a tip by it takes the edge, at the foot under the tip.
    func testTheMiddleOfAnEdgeIsNoPoint() {
        let s = sheet()
        let target = snap(on(s, 5.1, 0.3), on: s)
        XCTAssertEqual(target.kind, .sheetEdge)
        assertNear(target.point, on(s, 5.1, 0), "foot")
    }

    /// Beyond the reach nothing catches, and inside the sheet away from its outline nothing catches either.
    func testNothingCatchesOutOfReach() {
        let s = sheet(angle: 33.5)
        for tip in [on(s, -0.9, 5), on(s, 5, 5), on(s, 5, 0.9)] {
            XCTAssertNil(snap(tip, on: s).kind)
        }
    }

    // MARK: What a snapped mark reads

    /// A measure from a snapped corner to a snapped edge point, printed 2" apart along the area's edge, which is the sheet's:
    /// 4'-0" at the area's 1:24 (it would be 8'-0" at the sheet's 1:48), with each point in the area, at every angle.
    func testAMeasureSnappedToACornerAndAnEdgeReadsTheAreasScaleAtEveryAngle() {
        for angle in angles {
            let s = sheet(angle: angle)
            let corner = snap(on(s, 0.2, 0.3), on: s), edge = snap(on(s, 0.4, 2), on: s)
            XCTAssertEqual([corner.kind, edge.kind], [.sheetCorner, .sheetEdge], "\(angle)")
            XCTAssertEqual(s.area(at: corner.point)?.name, "Detail", "\(angle)")
            XCTAssertEqual(s.area(at: edge.point)?.name, "Detail", "\(angle)")
            XCTAssertEqual(read(corner.point, edge.point, on: [s]), "4'-0\"", "\(angle)")
            XCTAssertEqual(read(edge.point, corner.point, on: [s]), "4'-0\"", "\(angle)")
        }
    }

    /// With no area, the same points read the sheet's own 1:48: 8'-0".
    func testAMeasureSnappedToASheetsOutlineReadsTheSheetsScale() {
        for angle in angles {
            let s = sheet(area: nil, angle: angle)
            let corner = snap(on(s, 0.2, 0.3), on: s), edge = snap(on(s, 0.4, 2), on: s)
            XCTAssertEqual(s.scale(at: corner.point), fortyEight)
            XCTAssertEqual(s.scale(at: edge.point), fortyEight)
            XCTAssertTrue(s.contains(corner.point) && s.contains(edge.point), "\(angle)")
            XCTAssertEqual(read(corner.point, edge.point, on: [s]), "8'-0\"", "\(angle)")
        }
    }

    /// An NTS sheet's corner and edge stay NTS: printed 2", marked.
    func testAnNTSSheetsEdgeStaysNTS() {
        for angle in angles {
            let s = sheet(.notToScale, area: nil, angle: angle)
            let corner = snap(on(s, 0.2, 0.3), on: s), edge = snap(on(s, 0.4, 2), on: s)
            XCTAssertEqual([corner.kind, edge.kind], [.sheetCorner, .sheetEdge], "\(angle)")
            XCTAssertTrue(s.contains(corner.point) && s.contains(edge.point), "\(angle)")
            XCTAssertEqual(read(corner.point, edge.point, on: [s]), "2\" NTS", "\(angle)")
            // From the edge out onto the bare canvas it is still marked: one point on an NTS sheet is enough.
            XCTAssertTrue(Canvas(sheets: [s]).measure(from: edge.point, to: on(s, -5, 2)).isNotToScale, "\(angle)")
        }
    }

    /// An NTS area's edge, which is the sheet's: 2" NTS.
    func testAnNTSAreasEdgeOnTheSheetsOutlineStaysNTS() {
        for angle in angles {
            let s = sheet(area: .notToScale, angle: angle)
            let corner = snap(on(s, 0.2, 0.3), on: s), edge = snap(on(s, 0.4, 2), on: s)
            XCTAssertEqual(read(corner.point, edge.point, on: [s]), "2\" NTS", "\(angle)")
        }
    }

    /// A hundredth of a printed inch outside a sheet or an area reads outside, and a hundredth inside reads inside: the
    /// allowance for a mark on an edge is far smaller, on a sheet at 1:48 and on one at full size or NTS.
    func testAPointAHundredthOfAnInchOutsideReadsOutside() {
        for scale in [fortyEight, .drawn(.ratio(1)), .notToScale] {
            for angle in angles {
                let s = sheet(scale, angle: angle)
                XCTAssertFalse(s.contains(on(s, -0.01, 2)), "\(scale) \(angle)")
                XCTAssertFalse(s.contains(on(s, 10.01, 2)), "\(scale) \(angle)")
                XCTAssertFalse(s.contains(on(s, 5, -0.01)), "\(scale) \(angle)")
                XCTAssertTrue(s.contains(on(s, 0.01, 2)), "\(scale) \(angle)")
                XCTAssertNil(s.area(at: on(s, 4.01, 2)), "\(scale) \(angle)")
                XCTAssertNil(s.area(at: on(s, 2, 4.01)), "\(scale) \(angle)")
                XCTAssertEqual(s.area(at: on(s, 3.99, 2))?.name, "Detail", "\(scale) \(angle)")
            }
        }
        // Printed 2" a hundredth outside the 1:24 area reads the sheet's 1:48.
        let s = sheet(angle: 33.5)
        XCTAssertEqual(read(on(s, 4.01, 1), on(s, 4.01, 3), on: [s]), "8'-0\"")
    }

    // MARK: A point beats an edge

    /// A tip nearer the sheet's edge than an ink corner beside it takes the ink corner.
    func testAnInkCornerBeatsANearerSheetEdge() {
        for angle in angles {
            let s = sheet(angle: angle)
            var session = InkSession()
            // An L whose corner is 0.63 printed inch from the tip, its ends and mids out of reach.
            session.draw([on(s, 1.5, 2.3), on(s, 0.7, 2.3), on(s, 0.7, 3.1)], tool: .pen, colour: .sketch,
                         width: .inches(0.25))
            let ink = InkIndex(session.ink)
            let corner = session.ink.strokes[0].points[1]
            let tip = on(s, 0.15, 2)
            let target = snap(tip, on: s, ink: ink)
            XCTAssertEqual(target.kind, .corner, "\(angle)")
            XCTAssertEqual(target.point, corner, "\(angle)")
            // Without the ink, the edge 0.15 printed inch away.
            XCTAssertEqual(snap(tip, on: s).kind, .sheetEdge, "\(angle)")
        }
    }

    /// A perpendicular is a point too: with a point to work from, the foot on a stroke beats the sheet's edge.
    func testAPerpendicularBeatsASheetEdge() {
        let s = sheet()
        var session = InkSession()
        // Its mid, at (0.5, 2.5), is in reach but farther than the foot.
        session.draw([on(s, 0.5, 1), on(s, 0.5, 4)], tool: .pen, colour: .sketch, width: .inches(0.25))
        let target = snap(on(s, 0.2, 2), on: s, ink: InkIndex(session.ink), anchor: on(s, 3, 2))
        XCTAssertEqual(target.kind, .perpendicular)
        assertNear(target.point, on(s, 0.5, 2), "foot")
    }

    /// Where an ink end lies on a sheet's corner, both name one point and the ink's wins.
    func testAnInkEndOnASheetCornerIsTheInksEnd() {
        let s = sheet(angle: 33.5)
        var session = InkSession()
        session.draw([on(s, 0, 0).onInkGrid, on(s, -3, -2)], tool: .pen, colour: .sketch, width: .inches(0.25))
        let target = snap(on(s, 0.2, 0.3), on: s, ink: InkIndex(session.ink))
        XCTAssertEqual(target.kind, .end)
    }

    // MARK: Sheets that touch or overlap

    /// Two sheets side by side, touching along the left one's right edge. Each has an area along that edge: the left's at
    /// 1:24, the right's (placed after, so on top) at 1:12. A measure snapped to the shared edge, printed 2" along it, reads
    /// the topmost sheet's area: 2'-0", not 4'-0".
    func testWhereSheetsTouchAMarkOnTheSharedEdgeReadsTheTopmost() {
        let origin = p(0.3, 0.7).onInkGrid
        let left = sheet(areaRect: .inches(x: 6, y: 0, width: 4, height: 10), origin: origin, id: 1)
        let right = sheet(area: .drawn(.ratio(12)), areaRect: .inches(x: 0, y: 0, width: 4, height: 10),
                          origin: origin.offsetBy(dx: .inches(480), dy: .zero), id: 2)
        let sheets = [left, right]
        let a = snap(on(right, 0.1, 2), on: right, among: sheets), b = snap(on(right, -0.1, 4), on: right, among: sheets)
        XCTAssertEqual([a.kind, b.kind], [.sheetEdge, .sheetEdge])
        for point in [a.point, b.point] {
            XCTAssertTrue(left.contains(point) && right.contains(point))
            XCTAssertEqual(left.area(at: point)?.scale, twentyFour)
            XCTAssertEqual(right.area(at: point)?.scale, .drawn(.ratio(12)))
        }
        XCTAssertEqual(read(a.point, b.point, on: sheets), "2'-0\"")
        // Placed the other way round, the left one is on top: 4'-0".
        XCTAssertEqual(read(a.point, b.point, on: [right, left]), "4'-0\"")
    }

    /// The same sheets overlapping by 2 printed inches: a mark on either sheet's edge inside both areas reads the topmost's.
    func testWhereSheetsOverlapAMarkOnEitherEdgeReadsTheTopmost() {
        let origin = p(0.3, 0.7).onInkGrid
        let left = sheet(areaRect: .inches(x: 6, y: 0, width: 4, height: 10), origin: origin, id: 1)
        let right = sheet(area: .drawn(.ratio(12)), areaRect: .inches(x: 0, y: 0, width: 4, height: 10),
                          origin: origin.offsetBy(dx: .inches(384), dy: .zero), id: 2)
        let sheets = [left, right]
        // The right sheet's left edge, over the left sheet at its paper x = 8.
        let a = snap(on(right, 0.1, 2), on: right, among: sheets), b = snap(on(right, 0.1, 4), on: right, among: sheets)
        XCTAssertEqual([a.kind, b.kind], [.sheetEdge, .sheetEdge])
        assertNear(a.point, on(left, 8, 2), "over the left sheet")
        XCTAssertEqual(read(a.point, b.point, on: sheets), "2'-0\"")
        // The left sheet's right edge, over the right sheet at its paper x = 2.
        let c = snap(on(left, 9.9, 2), on: left, among: sheets), d = snap(on(left, 9.9, 4), on: left, among: sheets)
        XCTAssertEqual([c.kind, d.kind], [.sheetEdge, .sheetEdge])
        XCTAssertEqual(read(c.point, d.point, on: sheets), "2'-0\"")
    }

    /// Where two edges are as near, the topmost sheet's is taken; where one is nearer, it is.
    func testAmongEdgesTheNearestWinsAndTheTopmostOnATie() {
        // Whole inches, so the two distances come out exactly equal.
        let origin = p(0, 0)
        let left = sheet(area: nil, origin: origin, id: 1)
        let right = sheet(area: nil, origin: origin.offsetBy(dx: .inches(480 + 20), dy: .zero), id: 2)
        // 10 inches from each, so the gap's middle: the right sheet's edge, which is on top.
        let middle = snap(on(left, 10, 5).offsetBy(dx: .inches(10), dy: .zero), on: left, among: [left, right])
        XCTAssertEqual(middle.kind, .sheetEdge)
        assertNear(middle.point, on(right, 0, 5), "topmost")
        let nearer = snap(on(left, 10, 5).offsetBy(dx: .inches(6), dy: .zero), on: left, among: [left, right])
        assertNear(nearer.point, on(left, 10, 5), "nearest")
    }

    /// An NTS sheet touching a scaled one: a mark on the shared edge reads NTS whichever is on top, as every length with a
    /// point on an NTS sheet does (ADR-0002).
    func testAnNTSSheetTouchingAScaledOneReadsNTSOnTheSharedEdge() {
        let scaled = sheet(area: nil, id: 1)
        // 10 inches square, its right edge along the top of the scaled sheet's left edge.
        let nts = sheet(.notToScale, area: nil, origin: scaled.origin.offsetBy(dx: .inches(-10), dy: .zero), id: 2)
        for sheets in [[scaled, nts], [nts, scaled]] {
            // Zoomed in to the NTS sheet: 5/6 inch of reach.
            let a = snap(on(nts, 10.2, 4), on: nts, among: sheets), b = snap(on(nts, 9.8, 6), on: nts, among: sheets)
            XCTAssertEqual([a.kind, b.kind], [.sheetEdge, .sheetEdge])
            assertNear(a.point, on(nts, 10, 4), "shared edge")
            XCTAssertTrue(nts.contains(a.point) && scaled.contains(a.point))
            XCTAssertTrue(Canvas(sheets: sheets).measure(from: a.point, to: b.point).isNotToScale)
        }
    }

    // MARK: Many turns and a scale change (#49)

    /// A dimension snapped to the sheet's corner and edge, printed 2" along the area's edge, through 1,000 turns of the
    /// sheet to angles in tenths of a degree, each rounding its points to the ink grid again, then a scale change to 1:50,
    /// then 1,000 more: it reads 4'-0" in the 1:24 area and 2" NTS in an NTS area or on an NTS sheet at every step, and
    /// its points stay in the area and on the sheet. Before #49, one ink-grid step of allowance lost a point in about half
    /// of ten-turn runs.
    func testAMarkOnAnEdgeKeepsItsSheetAndScaleThroughManyTurnsAndARescale() {
        let cases: [(sheet: Sheet, rescale: Sheet.Scale, expected: String)] = [
            (sheet(area: twentyFour), .drawn(.ratio(50)), "4'-0\""),
            (sheet(area: .notToScale), .drawn(.ratio(50)), "2\" NTS"),
            (sheet(.notToScale, area: nil), .notToScale, "2\" NTS"),
        ]
        for (start, rescale, expected) in cases {
            var s = start
            let corner = snap(on(s, 0.2, 0.3), on: s), edge = snap(on(s, 0.4, 2), on: s)
            XCTAssertEqual([corner.kind, edge.kind], [.sheetCorner, .sheetEdge])
            var dimension = CanvasDimension(id: DimensionID(1), start: corner.point, end: edge.point,
                                            through: on(s, -0.5, 1).onInkGrid, orientation: .aligned, colour: .blue,
                                            textHeight: .inches(4))
            var seed: UInt64 = 57
            var failed = false
            for turn in 1...2000 where !failed {
                if turn == 1001 {
                    let (after, motion) = s.rescaled(to: rescale)
                    s = after
                    dimension = dimension.moved(by: motion)
                }
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let (turned, motion) = s.turned(to: Double((seed >> 33) % 3600) / 10)
                s = turned
                dimension = dimension.moved(by: motion)
                let canvas = Canvas(sheets: [s])
                let onIt = s.contains(dimension.start) && s.contains(dimension.end)
                let inArea = s.areas.isEmpty
                    || (s.area(at: dimension.start)?.name == "Detail" && s.area(at: dimension.end)?.name == "Detail")
                let reads = canvas.format(canvas.measure(dimension))
                if !onIt || !inArea || reads != expected {
                    XCTFail("\(start.scale) turn \(turn) at \(s.angle)°: on \(onIt), in area \(inArea), reads \(reads)")
                    failed = true
                }
            }
        }
    }

    // MARK: Looking only near the tip

    func testTheIndexHoldsTheSheetsInOrderAndFindsOnlyThoseNearTheTip() {
        let near = sheet(area: nil, id: 1)
        let top = sheet(.notToScale, area: nil, origin: p(100, 100), id: 2)
        let far = (0..<500).map { i in
            sheet(.notToScale, area: nil, origin: p(100_000 + Double(i % 25) * 20, -100_000 + Double(i / 25) * 20), id: 3 + i)
        }
        let index = SheetIndex([near, top] + far)
        XCTAssertEqual(index.count, 502)
        var work = InkIndex.Work()
        let found = index.outlines(in: InkIndex.Box(minX: 90, minY: 90, maxX: 120, maxY: 120), work: &work)
        XCTAssertEqual(found.map(\.order), [1, 0])
        XCTAssertEqual(work.sheetsVisited, 2)
        var nowhere = InkIndex.Work()
        XCTAssertTrue(index.outlines(in: InkIndex.Box(minX: -9000, minY: 9000, maxX: -8000, maxY: 9500), work: &nowhere).isEmpty)
        XCTAssertEqual(nowhere.sheetsVisited, 0)
        // Zoomed far out, the box covers every sheet.
        var everything = InkIndex.Work()
        XCTAssertEqual(index.outlines(in: InkIndex.Box(minX: -1e7, minY: -1e7, maxX: 1e7, maxY: 1e7), work: &everything).count, 502)
    }

    /// No sheets: the lookup costs nothing and finds what it did before.
    func testNoSheetsCostNothing() {
        var work = InkIndex.Work()
        let target = PointSnap.target(at: p(1, 1), pointsPerInch: 1, in: InkIndex(), work: &work)
        XCTAssertNil(target.kind)
        XCTAssertEqual(work.sheetsVisited, 0)
    }
}
