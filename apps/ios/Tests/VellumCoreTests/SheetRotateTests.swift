import XCTest
@testable import VellumCore

/// Turning, moving and changing the scale of a placed sheet (#44): lengths with exact numbers, what comes along, the ink
/// log, undo, and what a canvas saved before it opens as. The sheets are `MadeUpSheets`', made up for the tests.
final class SheetRotateTests: XCTestCase {
    private let angles = [0, 30, 45, 90, 123.4, 180, 270, 359.9]
    private let quarter = Sheet.Scale.drawn(.architectural(inchesPerFoot: 0.25))
    private let eighth = Sheet.Scale.drawn(.architectural(inchesPerFoot: 0.125))
    private let inch = Sheet.Scale.drawn(.architectural(inchesPerFoot: 1))
    private let halfInch = Sheet.Scale.drawn(.architectural(inchesPerFoot: 0.5))

    private func plan(at origin: CanvasPoint = CanvasPoint(x: .feet(100), y: .feet(-20)), id: SheetID = SheetID(1)) -> Sheet {
        Sheet(id: id, paper: MadeUpSheets.quarterInchPlan.paper, scale: quarter, origin: origin)
    }

    private lazy var detailReading = SheetReading.read(MadeUpSheets.detailSheet.texts, paper: MadeUpSheets.detailSheet.paper)

    private func detail(at main: Sheet.Scale? = nil) -> Sheet {
        let scale = main ?? inch
        return Sheet(id: SheetID(1), paper: MadeUpSheets.detailSheet.paper, scale: scale,
                     origin: CanvasPoint(x: .feet(-30), y: .feet(10)), areas: detailReading.areas(placedAt: scale))
    }

    private func reading(_ printed: MadeUpSheets.PrintedDimension, on sheet: Sheet) -> String {
        let canvas = Canvas(sheets: [sheet])
        return canvas.format(canvas.measure(from: sheet.canvasPoint(at: printed.from), to: sheet.canvasPoint(at: printed.to)))
    }

    private func assertSame(_ a: CanvasPoint, _ x: Double, _ y: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x.inches, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.y.inches, y, accuracy: 1e-9, file: file, line: line)
    }

    private func at(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .inches(x), y: .inches(y)) }

    // MARK: Angles

    func testATwistCatchesWithinThreeDegreesOfAQuarterTurn() {
        for (angle, expected, caught) in [(87.0, 90.0, true), (86.9, 86.9, false), (93.0, 90.0, true), (93.1, 93.1, false),
                                          (2.96, 0, true), (357.5, 0, true), (356.9, 356.9, false), (178.5, 180, true),
                                          (-1.0, 0, true), (271.5, 270, true), (45.04, 45, false), (-90.0, 270, true)] {
            let shaped = SheetAngle.shaped(angle)
            XCTAssertEqual(shaped.angle, expected, accuracy: 1e-9, "\(angle)")
            XCTAssertEqual(shaped.caught, caught, "\(angle)")
        }
    }

    func testTheTurnButtonsStepAQuarterAndKeepTheTenths() {
        XCTAssertEqual(SheetAngle.stepped(0, by: 90), 90)
        XCTAssertEqual(SheetAngle.stepped(0, by: -90), 270)
        XCTAssertEqual(SheetAngle.stepped(270, by: 90), 0)
        XCTAssertEqual(SheetAngle.stepped(12.3, by: 90), 102.3)
    }

    func testTheAngleReads() {
        XCTAssertEqual(SheetAngle.reading(0), "0°")
        XCTAssertEqual(SheetAngle.reading(90), "90°")
        XCTAssertEqual(SheetAngle.reading(33.5), "33.5°")
        XCTAssertEqual(SheetAngle.reading(359.96), "0°")
    }

    // MARK: Where a turned sheet is

    /// A 36 × 24 sheet at 1/4" = 1'-0" is 1,728" × 1,152": at 90° counter-clockwise its printed top-left corner goes to
    /// its bottom left on screen, exactly, and its size does not change.
    func testAQuarterTurnIsExact() {
        let sheet = plan(at: .origin).turned(to: 90).sheet
        assertSame(sheet.centre, 864, 576)
        XCTAssertEqual(sheet.size.width.inches, 1_728)
        XCTAssertEqual(sheet.size.height.inches, 1_152)
        XCTAssertEqual(sheet.corners[0].x.inches, 288)
        XCTAssertEqual(sheet.corners[0].y.inches, 1_440)
        XCTAssertEqual(sheet.corners[1].x.inches, 288)
        XCTAssertEqual(sheet.corners[1].y.inches, -288)
        XCTAssertEqual(sheet.bounds.minX.inches, 288)
        XCTAssertEqual(sheet.bounds.minY.inches, -288)
        XCTAssertEqual(sheet.bounds.size.width.inches, 1_152)
        XCTAssertEqual(sheet.bounds.size.height.inches, 1_728)
    }

    func testPaperAndCanvasPointsRoundTripAtEveryAngle() {
        for angle in angles {
            let sheet = plan().turned(to: angle).sheet
            let printed = PaperPoint(x: .inches(7.25), y: .inches(3.5))
            let back = sheet.paperPoint(at: sheet.canvasPoint(at: printed))
            XCTAssertEqual(back.x.inches, 7.25, accuracy: 1e-9, "\(angle)")
            XCTAssertEqual(back.y.inches, 3.5, accuracy: 1e-9, "\(angle)")
        }
    }

    func testHitTestsFollowTheTurnNotTheBoundingBox() {
        let sheet = plan(at: .origin).turned(to: 45).sheet
        XCTAssertTrue(sheet.contains(sheet.centre))
        // A corner of the box round it, which an axis-aligned test would call on the sheet.
        XCTAssertTrue(sheet.bounds.contains(CanvasPoint(x: sheet.bounds.minX, y: sheet.bounds.minY).offsetBy(dx: .inches(1), dy: .inches(1))))
        XCTAssertFalse(sheet.contains(CanvasPoint(x: sheet.bounds.minX, y: sheet.bounds.minY).offsetBy(dx: .inches(1), dy: .inches(1))))
        XCTAssertTrue(sheet.contains(sheet.canvasPoint(at: PaperPoint(x: .inches(0.01), y: .inches(0.01)))))
    }

    func testZoomToEverythingHoldsATurnedSheet() {
        let sheet = plan(at: .origin).turned(to: 90).sheet
        XCTAssertEqual(Canvas(sheets: [sheet]).extents, sheet.bounds)
    }

    // MARK: Lengths

    /// A printed 24'-0" reads 24'-0" at any angle.
    func testAPrintedLengthReadsTheSameAtAnyAngle() {
        let printed = MadeUpSheets.quarterInchPlan.dimensions[0]
        for angle in angles {
            XCTAssertEqual(reading(printed, on: plan().turned(to: angle).sheet), "24'-0\"", "\(angle)")
        }
    }

    /// A scale area's lengths read the area's own scale at any angle, and an NTS area's stay marked NTS.
    func testScaleAreasAndNTSReadTheirOwnAtAnyAngle() {
        let printed = MadeUpSheets.detailSheet.dimensions
        for angle in angles {
            let sheet = detail().turned(to: angle).sheet
            XCTAssertEqual(reading(printed[0], on: sheet), "3'-0\"", "\(angle)")
            XCTAssertEqual(reading(printed[1], on: sheet), "2'-0\"", "\(angle)")
            XCTAssertEqual(reading(printed[2], on: sheet), "2\" NTS", "\(angle)")
            XCTAssertEqual(sheet.area(at: sheet.canvasPoint(at: printed[1].from))?.name, "Detail 2")
            XCTAssertEqual(sheet.scale(at: sheet.canvasPoint(at: printed[2].from)), .notToScale)
        }
    }

    func testAnNTSSheetStaysMarkedAtAnyAngle() {
        let page = MadeUpSheets.loopDiagram
        for angle in angles {
            let sheet = Sheet(paper: page.paper, scale: .notToScale, origin: at(40, 40)).turned(to: angle).sheet
            XCTAssertEqual(reading(page.dimensions[0], on: sheet), "4\" NTS", "\(angle)")
        }
    }

    func testAMoveChangesNoLength() {
        let printed = MadeUpSheets.quarterInchPlan.dimensions[0]
        let (moved, motion) = plan().turned(to: 30).sheet.moved(dx: .feet(12), dy: .feet(-7))
        XCTAssertEqual(reading(printed, on: moved), "24'-0\"")
        XCTAssertEqual(moved.origin.x.inches, 1_344)
        XCTAssertEqual(moved.origin.y.inches, -324)
        XCTAssertEqual(moved.angle, 30)
        XCTAssertEqual(motion.dx.inches, 144)
        XCTAssertEqual(motion.dy.inches, -84)
        XCTAssertEqual(motion.turn, 0)
    }

    /// After a scale change a length reads what the new scale says, and the sheet takes the size it gives, about its
    /// centre.
    func testAScaleChangeReadsTheNewScale() {
        let printed = MadeUpSheets.quarterInchPlan.dimensions[0]
        for angle in angles {
            let before = plan().turned(to: angle).sheet
            let (after, motion) = before.rescaled(to: eighth)
            XCTAssertEqual(reading(printed, on: after), "48'-0\"", "\(angle)")
            XCTAssertEqual(after.size.width.inches, 3_456)
            XCTAssertEqual(after.size.height.inches, 2_304)
            XCTAssertEqual(after.angle, angle)
            assertSame(after.centre, before.centre.x.inches, before.centre.y.inches)
            XCTAssertEqual(motion.scale, 2)
        }
    }

    /// Changing the main scale keeps each area at its own, and a detail at the old main scale becomes an area of its own
    /// when it is read again, since it now differs from the main scale.
    func testAScaleChangeKeepsTheAreasOwnScales() {
        let printed = MadeUpSheets.detailSheet.dimensions
        let main = halfInch
        for angle in [0, 30, 90] as [Double] {
            let (after, _) = detail().turned(to: angle).sheet.rescaled(to: main, areas: detailReading.areas(placedAt: main))
            XCTAssertEqual(after.areas.map(\.name), ["Detail 1", "Detail 2", "Detail 3"])
            XCTAssertEqual(reading(printed[0], on: after), "3'-0\"", "\(angle)")
            XCTAssertEqual(reading(printed[1], on: after), "2'-0\"", "\(angle)")
            XCTAssertEqual(reading(printed[2], on: after), "2\" NTS", "\(angle)")
        }
        // Keeping the areas it has (a page that can't be read again): the areas it holds still read their own.
        let (kept, _) = detail().rescaled(to: main)
        XCTAssertEqual(kept.areas.map(\.name), ["Detail 2", "Detail 3"])
        XCTAssertEqual(reading(printed[1], on: kept), "2'-0\"")
    }

    /// An NTS sheet given a scale takes that scale's size and its lengths read real; a scaled sheet made NTS goes to its
    /// printed size and its lengths are marked.
    func testAScaleChangeToAndFromNTS() {
        let printed = MadeUpSheets.quarterInchPlan.dimensions[0]
        let nts = plan().rescaled(to: .notToScale)
        XCTAssertEqual(nts.sheet.size.width.inches, 36)
        XCTAssertEqual(nts.motion.scale, 1.0 / 48)
        XCTAssertTrue(nts.sheet.isNotToScale)
        XCTAssertEqual(reading(printed, on: nts.sheet), "6\" NTS")
        let back = nts.sheet.rescaled(to: quarter)
        XCTAssertEqual(back.sheet.size.width.inches, 1_728)
        XCTAssertEqual(back.motion.scale, 48)
        XCTAssertEqual(reading(printed, on: back.sheet), "24'-0\"")
    }

    /// D-501 turned and then moved: every length still reads its own scale, and the lookups name the right areas.
    func testATurnedAndMovedDetailSheetReadsItsOwnScales() {
        let printed = MadeUpSheets.detailSheet.dimensions
        for angle in [30, 33.5, 90, 123.4, 270] as [Double] {
            let sheet = detail().turned(to: angle).sheet.moved(dx: .feet(40), dy: .feet(-25)).sheet
            XCTAssertEqual(reading(printed[0], on: sheet), "3'-0\"", "\(angle)")
            XCTAssertEqual(reading(printed[1], on: sheet), "2'-0\"", "\(angle)")
            XCTAssertEqual(reading(printed[2], on: sheet), "2\" NTS", "\(angle)")
            XCTAssertNil(sheet.area(at: sheet.canvasPoint(at: printed[0].from)), "Detail 1 is at the sheet's own scale")
            XCTAssertEqual(sheet.area(at: sheet.canvasPoint(at: printed[1].from))?.name, "Detail 2", "\(angle)")
            let third = sheet.area(at: sheet.canvasPoint(at: printed[2].from))
            XCTAssertEqual(third?.name, "Detail 3", "\(angle)")
            XCTAssertEqual(third?.scale, .notToScale, "\(angle)")
        }
    }

    /// To NTS and back at an oblique angle, as at 0°: 6" NTS, then 24'-0" again, about the same centre.
    func testAScaleChangeToAndFromNTSAtAnObliqueAngle() {
        let printed = MadeUpSheets.quarterInchPlan.dimensions[0]
        for angle in [30, 123.4] as [Double] {
            let turned = plan().turned(to: angle).sheet
            let nts = turned.rescaled(to: .notToScale)
            XCTAssertEqual(nts.sheet.angle, angle)
            XCTAssertEqual(nts.sheet.size.width.inches, 36)
            XCTAssertEqual(reading(printed, on: nts.sheet), "6\" NTS", "\(angle)")
            let back = nts.sheet.rescaled(to: quarter)
            XCTAssertEqual(back.sheet.angle, angle)
            XCTAssertEqual(back.sheet.size.width.inches, 1_728)
            XCTAssertEqual(reading(printed, on: back.sheet), "24'-0\"", "\(angle)")
            assertSame(back.sheet.centre, turned.centre.x.inches, turned.centre.y.inches)
        }
    }

    /// D-501 made NTS at an angle. With its page read again, Detail 3 is at the sheet's own scale, so it stops being an
    /// area and still reads NTS, and Detail 1 becomes an area at its own 1" = 1'-0", so nothing reads differently. With
    /// the areas it had (a page that can't be read), Detail 1 has no area and reads its printed inches marked NTS.
    func testADetailSheetMadeNTSAtAnAngle() {
        let printed = MadeUpSheets.detailSheet.dimensions
        for angle in [30, 123.4] as [Double] {
            let turned = detail().turned(to: angle).sheet
            let read = turned.rescaled(to: .notToScale, areas: detailReading.areas(placedAt: .notToScale)).sheet
            XCTAssertEqual(read.areas.map(\.name), ["Detail 1", "Detail 2"])
            XCTAssertEqual(reading(printed[0], on: read), "3'-0\"", "\(angle)")
            XCTAssertEqual(reading(printed[1], on: read), "2'-0\"", "\(angle)")
            XCTAssertEqual(reading(printed[2], on: read), "2\" NTS", "\(angle)")
            let kept = turned.rescaled(to: .notToScale).sheet
            XCTAssertEqual(kept.areas.map(\.name), ["Detail 2", "Detail 3"])
            XCTAssertEqual(reading(printed[0], on: kept), "3\" NTS", "\(angle)")
            XCTAssertEqual(reading(printed[1], on: kept), "2'-0\"", "\(angle)")
            XCTAssertEqual(reading(printed[2], on: kept), "2\" NTS", "\(angle)")
        }
    }

    // MARK: A mark exactly on an edge

    private let edgeAngles = [45, 33.5, 123.4] as [Double]
    private let oneToFortyEight = Sheet.Scale.drawn(.ratio(48))

    /// A 10 × 10 sheet at 1:48 holding an area at (1, 1, 4, 4) printed inches, at the area's scale.
    private func edgeSheet(area: Sheet.Scale, origin: CanvasPoint = .origin) -> Sheet {
        Sheet(id: SheetID(1), paper: .inches(10, by: 10), scale: oneToFortyEight, origin: origin,
              areas: [ScaleArea(name: "Detail", rect: .inches(x: 1, y: 1, width: 4, height: 4), scale: area)])
    }

    /// A dimension between two paper points on a sheet at 0°, kept on the ink grid as a placed one is.
    private func edgeDimension(_ sheet: Sheet, _ a: (Double, Double), _ b: (Double, Double)) -> CanvasDimension {
        func at(_ p: (Double, Double)) -> CanvasPoint { sheet.canvasPoint(at: PaperPoint(x: .inches(p.0), y: .inches(p.1))) }
        return CanvasDimension.pulled(id: DimensionID(1), start: at(a), end: at(b), through: at((0.5, 2)), colour: .blue,
                                      textHeight: .inches(4)).onInkGrid
    }

    private func read(_ dimension: CanvasDimension, on sheet: Sheet) -> String {
        let canvas = Canvas(sheets: [sheet])
        return canvas.format(canvas.measure(dimension))
    }

    /// Printed 2" along the area's edge, 4'-0" at 1:24 and 8'-0" at the sheet's 1:48. Turned, its points land on the ink
    /// grid a fraction of a step off the edge, and must still read the area's scale.
    func testAMarkOnAScaleAreasEdgeKeepsItsScaleThroughATurn() {
        let sheet = edgeSheet(area: .drawn(.ratio(24)))
        let dimension = edgeDimension(sheet, (1, 1), (1, 3))
        XCTAssertEqual(read(dimension, on: sheet), "4'-0\"")
        for angle in edgeAngles {
            let (turned, motion) = sheet.turned(to: angle)
            let moved = dimension.moved(by: motion)
            XCTAssertEqual(turned.area(at: moved.start)?.name, "Detail", "\(angle)")
            XCTAssertEqual(turned.area(at: moved.end)?.name, "Detail", "\(angle)")
            XCTAssertEqual(read(moved, on: turned), "4'-0\"", "\(angle)")
        }
    }

    func testAMarkOnAnNTSAreasEdgeKeepsItsMarkThroughATurn() {
        let sheet = edgeSheet(area: .notToScale)
        let dimension = edgeDimension(sheet, (1, 1), (1, 3))
        XCTAssertEqual(read(dimension, on: sheet), "2\" NTS")
        for angle in edgeAngles {
            let (turned, motion) = sheet.turned(to: angle)
            XCTAssertEqual(read(dimension.moved(by: motion), on: turned), "2\" NTS", "\(angle)")
        }
    }

    /// An NTS sheet's own edge: a mark along it stays marked NTS.
    func testAMarkOnAnNTSSheetsEdgeKeepsItsMarkThroughATurn() {
        let sheet = Sheet(id: SheetID(1), paper: .inches(10, by: 10), scale: .notToScale)
        let dimension = edgeDimension(sheet, (0, 1), (0, 3))
        XCTAssertEqual(read(dimension, on: sheet), "2\" NTS")
        for angle in edgeAngles {
            let (turned, motion) = sheet.turned(to: angle)
            let moved = dimension.moved(by: motion)
            XCTAssertTrue(turned.contains(moved.start), "\(angle)")
            XCTAssertEqual(read(moved, on: turned), "2\" NTS", "\(angle)")
        }
    }

    /// A scale change rounds too, at 0° as well: 1:48 to 1:50 from a corner off the grid's even steps. Printed 2" in the
    /// 1:24 area is still 4'-0", and in the NTS area still 2" NTS.
    func testAMarkOnAScaleAreasEdgeKeepsItsScaleThroughARescale() {
        let origin = at(0.3, 0.7).onInkGrid
        let main = Sheet.Scale.drawn(.ratio(50))
        for (area, expected) in [(Sheet.Scale.drawn(.ratio(24)), "4'-0\""), (.notToScale, "2\" NTS")] {
            let sheet = edgeSheet(area: area, origin: origin)
            let dimension = edgeDimension(sheet, (1, 1), (1, 3))
            XCTAssertEqual(read(dimension, on: sheet), expected)
            let (after, motion) = sheet.rescaled(to: main)
            let moved = dimension.moved(by: motion)
            XCTAssertEqual(after.area(at: moved.start)?.name, "Detail")
            XCTAssertEqual(after.area(at: moved.end)?.name, "Detail")
            XCTAssertEqual(read(moved, on: after), expected)
        }
    }

    /// The allowance is 1/1024 printed inch (`Sheet.edgeAllowance`, #49): a point clearly outside still reads outside, turned
    /// or not.
    func testAPointClearlyOutsideStillReadsOutside() {
        let sheet = edgeSheet(area: .drawn(.ratio(24)))
        // A hundredth of a printed inch: 655 grid steps at full size, far past the allowance.
        for angle in [0] + edgeAngles {
            let turned = sheet.turned(to: angle).sheet
            let beside = turned.canvasPoint(at: PaperPoint(x: .inches(0.99), y: .inches(2)))
            XCTAssertNil(turned.area(at: beside), "\(angle)")
            let inside = turned.canvasPoint(at: PaperPoint(x: .inches(1.01), y: .inches(2)))
            XCTAssertEqual(turned.area(at: inside)?.name, "Detail", "\(angle)")
            XCTAssertFalse(turned.contains(turned.canvasPoint(at: PaperPoint(x: .inches(-0.01), y: .inches(2)))), "\(angle)")
            XCTAssertFalse(turned.contains(turned.canvasPoint(at: PaperPoint(x: .inches(10.01), y: .inches(2)))), "\(angle)")
            // Printed 2" just outside the area reads the sheet's 1:48.
            let start = turned.canvasPoint(at: PaperPoint(x: .inches(0.99), y: .inches(1)))
            let end = turned.canvasPoint(at: PaperPoint(x: .inches(0.99), y: .inches(3)))
            let canvas = Canvas(sheets: [turned])
            XCTAssertEqual(canvas.format(canvas.measure(from: start, to: end)), "8'-0\"", "\(angle)")
        }
    }

    /// A turn keeps the corner the sheet stands on, so 360 turns of a degree leave it where it was, to the bit.
    func testTurnsNeverDrift() {
        var sheet = plan()
        for i in 1...360 { sheet = sheet.turned(to: Double(i)).sheet }
        XCTAssertEqual(sheet.origin, plan().origin)
        XCTAssertEqual(sheet.angle, 0)
    }

    // MARK: What comes along

    private func stroke(_ id: Int, _ points: [CanvasPoint]) -> InkStroke {
        InkStroke(id: StrokeID(id), tool: .pen, colour: .red, width: .inches(1), points: points)
    }

    func testMarkupsWithMoreThanHalfTheirLengthOnTheSheetComeAlong() {
        // The sheet covers 0 to 1,728 across and 0 to 1,152 down, and its edges reach `Sheet.edgeAllowance` further:
        // 1/1024 printed inch, 0.046875 inch on the canvas at 1/4" = 1'-0" (#49).
        let sheet = plan(at: .origin)
        let reach = sheet.edgeAllowanceOnCanvas
        XCTAssertEqual(reach, 0.046875)
        let mostlyOn = stroke(1, [at(1_600, 100), at(1_800, 100)])    // 128 of 200 on
        let half = stroke(2, [at(1_628 + reach, 200), at(1_828 + reach, 200)])    // exactly half: stays
        let mostlyOff = stroke(3, [at(1_700, 300), at(1_900, 300)])
        let inside = stroke(4, [at(10, 10), at(20, 20), at(30, 10)])
        let outside = stroke(5, [at(-500, -500), at(-400, -400)])
        let dot = stroke(6, [at(500, 500)])
        let index = InkIndex(Ink(strokes: [mostlyOn, half, mostlyOff, inside, outside, dot]))
        let onBox = TextBox(id: TextBoxID(1), origin: at(100, 100), size: CanvasSize(width: .inches(10), height: .inches(2)),
                            fontSize: .inches(1), colour: .blue, text: "made up")
        let offBox = TextBox(id: TextBoxID(2), origin: at(1_725, 100), size: CanvasSize(width: .inches(10), height: .inches(2)),
                             fontSize: .inches(1), colour: .blue, text: "made up")
        func dim(_ id: Int, _ a: CanvasPoint, _ b: CanvasPoint) -> CanvasDimension {
            .pulled(id: DimensionID(id), start: a, end: b, through: at(a.x.inches, a.y.inches - 40), colour: .blue,
                    textHeight: .inches(4))
        }
        let picked = sheet.markups(in: index, texts: [onBox, offBox],
                                   dimensions: [dim(1, at(100, 100), at(200, 100)), dim(2, at(1_700, 100), at(1_800, 100))])
        XCTAssertEqual(picked.strokes.map(\.value), [1, 4, 6])
        XCTAssertEqual(picked.texts.map(\.value), [1])
        XCTAssertEqual(picked.dimensions.map(\.value), [1])
        XCTAssertTrue(picked.frames.isEmpty)
    }

    func testMarkupsAreJudgedAgainstTheTurnedSheet() {
        // Turned 90° about (864, 576), the sheet covers 288 to 1,440 across and -288 to 1,440 down.
        let sheet = plan(at: .origin).turned(to: 90).sheet
        let inBoxOfUpright = stroke(1, [at(100, 100), at(150, 100)])     // on the upright sheet, off the turned one
        let onlyWhenTurned = stroke(2, [at(800, -200), at(850, -200)])   // above the upright sheet, on the turned one
        let index = InkIndex(Ink(strokes: [inBoxOfUpright, onlyWhenTurned]))
        XCTAssertEqual(sheet.markups(in: index, texts: [], dimensions: []).strokes.map(\.value), [2])
    }

    func testTheMarkupPassReadsOnlyStrokesCrossingTheEdge() {
        let sheet = plan(at: .origin)
        var strokes: [InkStroke] = []
        func wave(_ x: Double, _ y: Double) -> [CanvasPoint] { (0..<120).map { at(x + Double($0) * 0.5, y + Double($0 % 7)) } }
        for i in 1...1_000 { strokes.append(stroke(i, wave(Double(i % 25) * 60 + 20, Double(i % 40) * 25 + 20))) }
        // Three strokes across the right-hand edge at 1,728, most of each on the sheet.
        for i in 1_001...1_003 { strokes.append(stroke(i, wave(1_680, Double(i - 1_000) * 80))) }
        var work = InkIndex.Work()
        let picked = sheet.markups(in: InkIndex(Ink(strokes: strokes)), texts: [], dimensions: [], work: &work)
        XCTAssertEqual(picked.strokes.count, 1_000 + 3)
        MeasureFrameBaseline.check("sheet_markup_points_inspected", work.pointsInspected, area: "sheets", before: nil)
    }

    // MARK: Undo and the log

    /// A session with a sheet, ink on it, ink off it, a text box and a level dimension on it, and a frame.
    private func marked() -> (InkSession, Sheet, CanvasSelection) {
        var session = InkSession()
        let sheet = session.addSheet(plan(at: .origin))
        session.draw([at(100, 100), at(300, 200)], tool: .pen, colour: .red, width: .inches(2))
        session.draw([at(-900, 0), at(-800, 0)], tool: .pen, colour: .blue, width: .inches(2))
        session.addText("Made up", at: at(400, 400), size: CanvasSize(width: .inches(100), height: .inches(40)),
                        fontSize: .inches(10), colour: .sketch)
        // Over the plan's printed 24'-0", 288" long, pulled above it to read across.
        session.addDimension(start: at(192, 480), end: at(480, 480), through: at(300, 440), colour: .blue, textHeight: .inches(12))
        session.addFrame(paper: .letter, scale: .fullSize, origin: at(50, 50))
        let markups = sheet.markups(in: InkIndex(session.ink), texts: session.texts, dimensions: session.dimensions)
        return (session, sheet, markups)
    }

    func testATurnBringsItsMarkupsAndUndoesAsOneStep() {
        var (session, sheet, markups) = marked()
        XCTAssertEqual(markups.strokes.map(\.value), [1])
        let before = session
        let steps = session.undoSteps
        let (after, motion) = sheet.turned(to: 90)
        XCTAssertTrue(session.changeSheet(to: after, markups: markups, motion: motion))
        XCTAssertEqual(session.undoSteps, steps + 1)
        XCTAssertEqual(session.sheet(sheet.id)?.angle, 90)
        XCTAssertEqual(session.selectionAfterLastChange?.sheet, sheet.id)
        // (100, 100) about (864, 576): 90° counter-clockwise on screen.
        XCTAssertEqual(session.ink.strokes[0].points[0], at(388, 1_340))
        // The ink off the sheet stays, and so does the frame.
        XCTAssertEqual(session.ink.strokes[1], before.ink.strokes[1])
        XCTAssertEqual(session.frames, before.frames)
        // The text box's centre goes round, its text stays level at its size.
        XCTAssertEqual(session.texts[0].rect.center.x.inches, 864 + (420 - 576), accuracy: 1e-9)
        XCTAssertEqual(session.texts[0].size, before.texts[0].size)
        session.undo()
        XCTAssertEqual(session.sheets, before.sheets)
        XCTAssertEqual(session.ink, before.ink)
        XCTAssertEqual(session.texts, before.texts)
        XCTAssertEqual(session.dimensions, before.dimensions)
        XCTAssertEqual(session.selectionAfterLastChange?.sheet, sheet.id)
        session.redo()
        XCTAssertEqual(session.sheet(sheet.id), after)
        XCTAssertEqual(session.ink.strokes[0].points[0], at(388, 1_340))
    }

    /// A kept dimension that comes along reads the same at any angle, though it read "across" when placed; after a
    /// scale change it reads what the new scale says.
    func testAKeptDimensionReadsTheSameThroughTurnsAndAScaleChange() {
        for angle in angles where angle != 0 {
            var (session, sheet, markups) = marked()
            XCTAssertEqual(session.dimensions[0].orientation, .horizontal)
            let turned = sheet.turned(to: angle)
            session.changeSheet(to: turned.sheet, markups: markups, motion: turned.motion)
            let canvas = Canvas(sheets: session.sheets)
            XCTAssertEqual(canvas.format(canvas.measure(session.dimensions[0])), "24'-0\"", "\(angle)")
            let (a, b) = session.dimensions[0].line
            XCTAssertEqual(a.distance(to: b).inches, 288, accuracy: 0.001, "\(angle)")
            let rescaled = turned.sheet.rescaled(to: eighth)
            session.changeSheet(to: rescaled.sheet, markups: markups, motion: rescaled.motion)
            let after = Canvas(sheets: session.sheets)
            XCTAssertEqual(after.format(after.measure(session.dimensions[0])), "48'-0\"", "\(angle)")
            XCTAssertEqual(session.dimensions[0].textHeight.inches, 24, accuracy: 1e-9)
        }
    }

    func testAScaleChangeScalesItsMarkupsAboutTheCentre() {
        var (session, sheet, markups) = marked()
        let width = session.ink.strokes[0].width
        let (after, motion) = sheet.rescaled(to: eighth)
        session.changeSheet(to: after, markups: markups, motion: motion)
        // (100, 100) is 764 left of and 476 above the centre (864, 576): twice as far now.
        XCTAssertEqual(session.ink.strokes[0].points[0], at(864 - 1_528, 576 - 952))
        XCTAssertEqual(session.ink.strokes[0].width, width * 2)
        XCTAssertEqual(session.texts[0].fontSize.inches, 20)
        // Still on the same spot of the paper.
        let paper = after.paperPoint(at: session.ink.strokes[0].points[0])
        XCTAssertEqual(paper.x.inches, 100.0 / 48, accuracy: 1e-4)
        XCTAssertEqual(paper.y.inches, 100.0 / 48, accuracy: 1e-4)
    }

    func testAMoveOfNothingIsNoStep() {
        var (session, sheet, markups) = marked()
        let steps = session.undoSteps
        let (after, motion) = sheet.moved(dx: .zero, dy: .zero)
        XCTAssertFalse(session.changeSheet(to: after, markups: markups, motion: motion))
        XCTAssertEqual(session.undoSteps, steps)
        XCTAssertFalse(session.changeSheet(to: Sheet(id: SheetID(9), paper: .letter, scale: quarter), motion: motion))
    }

    func testTheSelectionHoldsASheet() {
        let selection = CanvasSelection(sheet: SheetID(2))
        XCTAssertFalse(selection.isEmpty)
        XCTAssertEqual(selection.count, 1)
        XCTAssertFalse(selection.holdsAnnotations)
        XCTAssertEqual(CanvasTool.lasso.prompt(fingerDraws: false, hasSelection: true, hasSheet: true), "Twist or drag the sheet")
        XCTAssertEqual(CanvasTool.lasso.prompt(fingerDraws: false, hasSelection: true, hasSheet: true, step: .turningSheet(12.3)),
                       "Turning: 12.3°")
        XCTAssertEqual(CanvasTool.lasso.prompt(fingerDraws: false, hasSelection: true, hasSheet: true, step: .caughtSheet(90)),
                       "Caught at 90°")
    }

    // MARK: Saving

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-rotate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testAChangeRoundTripsThroughTheCodec() throws {
        let page = SheetPage(file: "madeup02", name: "IFC set (example).pdf", path: "/Projects (example)/IFC set (example).pdf",
                             index: 1, number: "D-501")
        var sheet = detail()
        sheet.page = page
        let turned = sheet.turned(to: 33.5)
        for sheet in [sheet, turned.sheet] {
            let event = InkEvent.addSheet(sheet)
            XCTAssertEqual(try InkCodec.decodeEvent(InkCodec.encode(event)[...]), event)
        }
        let rescaled = turned.sheet.rescaled(to: halfInch, areas: detailReading.areas(placedAt: halfInch))
        let change = SheetChange(id: sheet.id, origin: rescaled.sheet.origin, angle: 33.5,
                                 rescaled: .init(scale: halfInch, areas: rescaled.sheet.areas),
                                 markups: CanvasSelection(strokes: [StrokeID(3), StrokeID(9)], texts: [TextBoxID(1)],
                                                          dimensions: [DimensionID(2)]),
                                 motion: rescaled.motion)
        XCTAssertEqual(try InkCodec.decodeEvent(InkCodec.encode(.changeSheet(change))[...]), .changeSheet(change))
        let dimension = CanvasDimension(id: DimensionID(1), start: at(0, 0), end: at(5, 5), through: at(1, 1),
                                        orientation: .horizontal, colour: .blue, textHeight: .inches(1), axisAngle: 30)
        let event = InkEvent.addDimension(dimension)
        XCTAssertEqual(try InkCodec.decodeEvent(InkCodec.encode(event)[...]), event)
    }

    func testChangesReplayAndSurviveARelaunchAndACompaction() throws {
        let folder = try temporaryFolder()
        let store = try InkStore(folder: folder)
        var (session, sheet, markups) = marked()
        let turned = sheet.turned(to: 33.5)
        session.changeSheet(to: turned.sheet, markups: markups, motion: turned.motion)
        let moved = turned.sheet.moved(dx: .feet(10), dy: .feet(4))
        session.changeSheet(to: moved.sheet, markups: markups, motion: moved.motion)
        let rescaled = moved.sheet.rescaled(to: eighth)
        session.changeSheet(to: rescaled.sheet, markups: markups, motion: rescaled.motion)
        session.undo()
        try store.append(session.takeEvents())
        try store.flush()
        store.closeFiles()
        let reopened = try InkStore(folder: folder)
        XCTAssertEqual(reopened.session, session)
        XCTAssertEqual(reopened.session.sheet(sheet.id)?.angle, 33.5)
        var replay = reopened.session
        replay.redo()
        XCTAssertEqual(replay.sheet(sheet.id)?.scale, eighth)
        try reopened.compact()
        reopened.closeFiles()
        let compacted = try InkStore(folder: folder)
        XCTAssertEqual(compacted.session, session)
        var undone = compacted.session
        undone.undo()
        undone.undo()
        XCTAssertEqual(undone.sheet(sheet.id)?.angle, 0)
        XCTAssertEqual(undone.ink.strokes[0].points[0], at(100, 100))
    }

    /// A sheet at 0° is written byte for byte as #11 wrote it, by hand here, so a canvas saved before #44 reads with its
    /// sheets at 0°.
    func testASheetSavedBeforeThisReadsAtZeroDegrees() throws {
        var w = ByteWriter()
        w.varint(4)
        w.f64(36)
        w.f64(24)
        w.u8(2)            // NTS
        w.signedVarint(0)
        w.signedVarint(0)
        w.u8(1)            // inverts badly
        w.u8(0)            // no page
        w.varint(0)        // no areas
        var r = ByteReader(w.bytes[...])
        let read = try r.sheet()
        XCTAssertEqual(read.angle, 0)
        XCTAssertTrue(read.invertsBadly)
        XCTAssertTrue(r.isAtEnd)
        var again = ByteWriter()
        again.sheet(read)
        XCTAssertEqual(again.bytes, w.bytes)
    }

    /// A canvas saved by version 4 (its files' headers say 4) opens with its sheets at 0°, and takes a turn.
    func testAVersionFourCanvasOpensAndTakesATurn() throws {
        let folder = try temporaryFolder()
        let store = try InkStore(folder: folder)
        var session = InkSession()
        let sheet = session.addSheet(plan(at: .origin))
        session.draw([at(10, 10), at(20, 20)], tool: .pen, colour: .red, width: .inches(1))
        try store.append(session.takeEvents())
        try store.compact()
        session.addSheet(Sheet(paper: .letter, scale: .notToScale, origin: at(-50, 0)))
        try store.append(session.takeEvents())
        try store.flush()
        store.closeFiles()
        for name in [InkStore.snapshotName, InkStore.logName] {
            let url = folder.appendingPathComponent(name)
            var bytes = try [UInt8](Data(contentsOf: url))
            bytes[4] = 4
            bytes[5] = 0
            try Data(bytes).write(to: url)
        }
        let old = try InkStore(folder: folder)
        XCTAssertEqual(old.session, session)
        XCTAssertEqual(old.session.sheets.map(\.angle), [0, 0])
        let turned = sheet.turned(to: 90)
        session.changeSheet(to: turned.sheet, motion: turned.motion)
        try old.append(session.takeEvents())
        try old.compact()
        old.closeFiles()
        XCTAssertEqual(try InkStore(folder: folder).session, session)
    }

    /// A turn writes its ids and motion, never a stroke's points: the same bytes however long the strokes.
    func testATurnAppendsOneSmallRecord() {
        let sheet = plan(at: .origin)
        let turned = sheet.turned(to: 90)
        let change = SheetChange(id: SheetID(1), origin: .origin, angle: 90,
                                 markups: CanvasSelection(strokes: [StrokeID(1), StrokeID(2), StrokeID(3)]), motion: turned.motion)
        let bytes = InkCodec.frameSize + InkCodec.encode(.changeSheet(change)).count
        MeasureFrameBaseline.check("bytes-appended-per-sheet-change", bytes, area: "storage", before: nil)
    }

    // MARK: Tiles

    private func fitted(_ sheet: Sheet) -> Viewport {
        var view = Viewport(pointsPerInch: 1, screenWidth: 951, screenHeight: 669)
        view.fit(sheet.bounds, insets: ScreenInsets(top: 56, left: 70, bottom: 50, right: 92))
        return view
    }

    /// A whole turn of a sheet in view draws no tile: a turn is a transform, and tiles are keyed by the paper.
    func testATurnDrawsNoTiles() {
        let sheet = plan()
        var book = SheetTileBook(displayScale: 3)
        let view = fitted(sheet)
        func asked(_ s: Sheet) -> SheetTileBook.Plan {
            let plan = book.plan([s], viewport: view) { _ in .asPrinted }
            for key in plan.draw { book.didDraw(key) }
            return plan
        }
        let first = asked(sheet).draw.count
        XCTAssertGreaterThan(first, 0)
        var redrawn = 0
        for degree in stride(from: 1.0, to: 360, by: 1) { redrawn += asked(sheet.turned(to: degree).sheet).draw.count }
        MeasureFrameBaseline.check("sheet_tiles_drawn_per_turn", redrawn, area: "sheets", before: nil)
        XCTAssertEqual(book.tilesDrawn, first)
    }

    /// Going right round, zoomed in, draws each tile that comes into view once and never again.
    func testATurnedSheetDrawsOnlyTheTilesInView() {
        let sheet = plan(at: .origin).turned(to: 45).sheet
        var view = Viewport(pointsPerInch: 2, screenWidth: 951, screenHeight: 669)
        view.centre = sheet.centre
        var book = SheetTileBook(displayScale: 2)
        let first = book.plan([sheet], viewport: view) { _ in .asPrinted }
        MeasureFrameBaseline.check("sheet_tiles_drawn_first_view_at_45_degrees", first.draw.count, area: "sheets", before: nil)
        // Every tile asked for touches the view; the paper under the view's corners is among them.
        let corners = [ScreenPoint(x: 0, y: 0), ScreenPoint(x: 951, y: 0), ScreenPoint(x: 951, y: 669), ScreenPoint(x: 0, y: 669)]
        for corner in corners {
            let paper = sheet.paperPoint(at: view.canvasPoint(for: corner))
            XCTAssertTrue(first.draw.contains { $0.paperRect.contains(paper) }, "\(corner)")
        }
    }

    func testASheetTurnedOutOfViewIsNotShown() {
        // A long thin sheet whose bounding box reaches a view it does not touch.
        let sheet = Sheet(id: SheetID(1), paper: .inches(100, by: 1), scale: .notToScale, origin: .origin).turned(to: 45).sheet
        var view = Viewport(pointsPerInch: 40, screenWidth: 400, screenHeight: 400)
        view.centre = CanvasPoint(x: sheet.bounds.minX, y: sheet.bounds.minY).offsetBy(dx: .inches(5), dy: .inches(5))
        XCTAssertTrue(sheet.bounds.intersects(view.visibleRect))
        var book = SheetTileBook(displayScale: 2)
        let plan = book.plan([sheet], viewport: view) { _ in .asPrinted }
        XCTAssertTrue(plan.showing.isEmpty)
        XCTAssertTrue(plan.draw.isEmpty)
    }

    // MARK: Labels

    private let sheetName = LabelSize(width: 170, height: 18)

    private func labelAreas(_ sheet: Sheet, k: Double) -> (LabelQuad, [SheetLabelLayout.Area]) {
        func quad(_ corners: [CanvasPoint]) -> LabelQuad {
            LabelQuad(corners: corners.map { LabelPoint(x: $0.x.inches * k, y: $0.y.inches * k) })
        }
        let line = LabelSize(width: 38, height: 12)
        let areas = sheet.areas.map { area -> SheetLabelLayout.Area in
            let scale = area.scale == .notToScale ? LabelSize(width: 22, height: 12) : LabelSize(width: 66, height: 12)
            return SheetLabelLayout.Area(quad: quad(sheet.canvasCorners(of: area.rect)), name: line, scale: scale)
        }
        return (quad(sheet.corners), areas)
    }

    /// At every angle and zoom every label is level, wholly inside its sheet or area, and clear of every other.
    func testLabelsAreNeverCutNorOverEachOtherAtAnyAngle() {
        for angle in stride(from: 0.0, to: 360, by: 7.5) {
            for k in [0.5, 1, 1.5, 3, 6] as [Double] {
                let sheet = detail(at: halfInch).turned(to: angle).sheet
                let (quad, areas) = labelAreas(sheet, k: k)
                let laid = SheetLabelLayout.lay(sheet: quad, sheetName: sheetName, areas: areas)
                var boxes: [LabelRect] = []
                if let box = laid.sheetName {
                    XCTAssertTrue(quad.contains(box), "name at \(angle), \(k)")
                    boxes.append(box)
                }
                for (area, placed) in zip(areas, laid.areas) {
                    switch placed.fit {
                    case .outlineOnly:
                        XCTAssertNil(placed.box)
                    case .twoLines, .scaleAlone:
                        guard let box = placed.box else { XCTFail("no box"); continue }
                        XCTAssertTrue(area.quad.contains(box), "area at \(angle), \(k)")
                        boxes.append(box)
                    }
                }
                for (i, a) in boxes.enumerated() {
                    for b in boxes[(i + 1)...] { XCTAssertFalse(a.intersects(b), "overlap at \(angle), \(k)") }
                }
            }
        }
    }

    /// Filling the Duo, D-501 shows all its labels at each of the angles the captures show; much smaller, none of the
    /// areas can hold one, and the fallbacks run in order.
    func testTheD501FallsBackInOrderOnATurnedSheet() {
        let sheet = detail(at: halfInch).turned(to: 30).sheet
        let large = labelAreas(sheet, k: 40.0 / 24)
        let laid = SheetLabelLayout.lay(sheet: large.0, sheetName: sheetName, areas: large.1)
        XCTAssertNotNil(laid.sheetName)
        XCTAssertEqual(laid.areas.map(\.fit), [.twoLines, .twoLines, .twoLines])
        let tiny = labelAreas(sheet, k: 0.15)
        let none = SheetLabelLayout.lay(sheet: tiny.0, sheetName: sheetName, areas: tiny.1)
        XCTAssertNil(none.sheetName)
        XCTAssertEqual(none.areas.map(\.fit), [.outlineOnly, .outlineOnly, .outlineOnly])
    }

    /// At 0° the layout is #35's, to the point.
    func testAtZeroDegreesTheLayoutIsUnchanged() {
        let rect = LabelRect(x: 10, y: 20, width: 400, height: 300)
        let area = LabelRect(x: 10, y: 20, width: 200, height: 100)
        let name = LabelSize(width: 100, height: 18)
        let flat = SheetLabelLayout.lay(sheet: rect, sheetName: name,
                                        areas: [.init(rect: area, name: LabelSize(width: 38, height: 12),
                                                      scale: LabelSize(width: 22, height: 12))])
        let quad = SheetLabelLayout.lay(sheet: LabelQuad(rect), sheetName: name,
                                        areas: [.init(quad: LabelQuad(area), name: LabelSize(width: 38, height: 12),
                                                      scale: LabelSize(width: 22, height: 12))])
        XCTAssertEqual(flat, quad)
    }
}
