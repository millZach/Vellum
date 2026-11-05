import XCTest
@testable import VellumCore

private func p(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .inches(x), y: .inches(y)) }

/// Where sheets overlap, a scale area reads only on the topmost sheet under a point (#60): its area if the point is in
/// one, otherwise the sheet's own scale, a real length. A point on an NTS sheet or in an NTS area still reads NTS whatever
/// lies on top. The sheets are made up for the tests.
///
/// The lower sheet is a 20 × 10 detail sheet at 1/4" = 1'-0", corner at the canvas origin, so 960 × 480 canvas inches;
/// its Detail 4, the left 10 × 10 printed inches, is at 1" = 1'-0", canvas x 0 to 480. The plan on top is 20 × 20 printed
/// inches at 1/4" = 1'-0", corner at (240, -240), so it covers canvas x 240 to 1200 and y -240 to 720, centred on
/// (720, 240): it lies over the right half of Detail 4, and any point within 480 canvas inches of its centre stays on it
/// at any angle.
final class OverlapScaleAreaTests: XCTestCase {
    private let quarter = Sheet.Scale.drawn(.architectural(inchesPerFoot: 0.25))
    private let eighth = Sheet.Scale.drawn(.architectural(inchesPerFoot: 0.125))
    private let inch = Sheet.Scale.drawn(.architectural(inchesPerFoot: 1))
    private let inchAndHalf = Sheet.Scale.drawn(.architectural(inchesPerFoot: 1.5))

    private func lower(_ area: Sheet.Scale? = nil) -> Sheet {
        Sheet(id: SheetID(1), paper: .inches(20, by: 10), scale: quarter, origin: p(0, 0),
              areas: [ScaleArea(name: "Detail 4", rect: .inches(x: 0, y: 0, width: 10, height: 10), scale: area ?? inch)])
    }

    private func plan(areas: [ScaleArea] = []) -> Sheet {
        Sheet(id: SheetID(2), paper: .inches(20, by: 20), scale: quarter, origin: p(240, -240), areas: areas)
    }

    private func read(_ a: CanvasPoint, _ b: CanvasPoint, on sheets: [Sheet]) -> String {
        let canvas = Canvas(sheets: sheets)
        return canvas.format(canvas.measure(from: a, to: b))
    }

    // Two points on the plan, over Detail 4, 120 canvas inches apart.
    private let a = p(336, 96), b = p(456, 96)

    /// The issue's example: a 1/4" plan with no area over a lower sheet's 1" detail measures at 1/4", a real length:
    /// 120 canvas inches is 10'-0". Before #60 it read Detail 4's 1": 2 1/2" printed, 2'-6".
    func testAPlanWithNoAreaOverALowerDetailReadsThePlansOwnScale() {
        let detail = lower(), plan = plan()
        for point in [a, b] {
            XCTAssertTrue(plan.contains(point))
            XCTAssertNil(plan.area(at: point))
            XCTAssertEqual(detail.area(at: point)?.scale, inch)
        }
        let canvas = Canvas(sheets: [detail, plan])
        XCTAssertEqual(canvas.measure(from: a, to: b), .real(.inches(120)))
        XCTAssertEqual(canvas.format(canvas.measure(from: a, to: b)), "10'-0\"")
        XCTAssertEqual(canvas.measure(from: b, to: a), .real(.inches(120)))
        // A kept dimension between them reads the same.
        let dimension = CanvasDimension.pulled(id: DimensionID(1), start: a, end: b, through: p(396, 48), colour: .sketch,
                                               textHeight: .inches(4))
        XCTAssertEqual(canvas.format(canvas.measure(dimension)), "10'-0\"")
        // With the detail sheet on top instead, Detail 4 reads, as it always has.
        XCTAssertEqual(read(a, b, on: [plan, detail]), "2'-6\"")
    }

    /// The same with the plan turned and changed in scale: still a real length, the 120 canvas inches between the points,
    /// whatever the plan's angle or scale.
    func testATurnedAndRescaledPlanOverALowerDetailStillReadsReal() {
        for angle in [33.5, 90, 123.4] {
            for scale in [quarter, eighth] {
                let turned = plan().turned(to: angle).sheet
                let top = scale == quarter ? turned : turned.rescaled(to: scale).sheet
                XCTAssertEqual(top.angle, angle)
                XCTAssertEqual(top.scale, scale)
                for point in [a, b] {
                    XCTAssertTrue(top.contains(point), "\(angle) \(scale)")
                    XCTAssertEqual(lower().area(at: point)?.scale, inch)
                }
                let canvas = Canvas(sheets: [lower(), top])
                XCTAssertEqual(canvas.measure(from: a, to: b), .real(.inches(120)), "\(angle) \(scale)")
                XCTAssertEqual(canvas.format(canvas.measure(from: b, to: a)), "10'-0\"", "\(angle) \(scale)")
            }
        }
    }

    /// A point in the top plan's own scale area reads that area, not the lower detail's nor the plan's: 2 1/2" printed at
    /// 1 1/2" = 1'-0" is 1'-8" (Detail 4 would read 2'-6", the plan 10'-0"). Turned, the area turns with the plan.
    func testAPointInTheTopSheetsOwnAreaReadsThatArea() {
        let areas = [ScaleArea(name: "Detail A", rect: .inches(x: 0, y: 0, width: 6, height: 20), scale: inchAndHalf)]
        let top = plan(areas: areas)
        XCTAssertEqual(top.paperPoint(at: a), PaperPoint(x: .inches(2), y: .inches(7)))
        XCTAssertEqual(top.area(at: a)?.scale, inchAndHalf)
        XCTAssertEqual(lower().area(at: a)?.scale, inch)
        XCTAssertEqual(read(a, b, on: [lower(), top]), "1'-8\"")
        // Only the first point in the area: it still sets the scale, as on a single sheet (#11).
        XCTAssertNil(top.area(at: p(600, 96)))
        XCTAssertEqual(read(a, p(600, 96), on: [lower(), top]), "3'-8\"")
        for angle in [33.5, 123.4] {
            let turned = top.turned(to: angle).sheet
            let c = turned.canvasPoint(at: PaperPoint(x: .inches(2), y: .inches(7)))
            let d = turned.canvasPoint(at: PaperPoint(x: .inches(4.5), y: .inches(7)))
            XCTAssertEqual(read(c, d, on: [lower(), turned]), "1'-8\"", "\(angle)")
        }
    }

    /// A point on the lower sheet outside the plan still reads Detail 4: 144 canvas inches is 3" printed, 3'-0".
    func testALowerSheetsAreaStillReadsOutsideTheTopSheet() {
        let c = p(48, 96), d = p(192, 96)
        for point in [c, d] { XCTAssertFalse(plan().contains(point)) }
        XCTAssertEqual(read(c, d, on: [lower(), plan()]), "3'-0\"")
    }

    /// From a point on the plan to one on Detail 4 alone, either way round, the length reads Detail 4's scale: one point in
    /// a scale area sets the scale, as it does on a single sheet (#11); the plan's point has no area to offer. From a, over
    /// the detail, to e, 240 canvas inches is 5" printed, 5'-0"; from f, on the plan clear of the detail sheet, 960 canvas
    /// inches is 20" printed, 20'-0".
    func testALengthFromTheTopSheetToALowerAreaAloneReadsThatArea() {
        let e = p(96, 96), f = p(1_056, 96)
        let sheets = [lower(), plan()]
        XCTAssertFalse(plan().contains(e))
        XCTAssertFalse(lower().contains(f))
        XCTAssertEqual(read(a, e, on: sheets), "5'-0\"")
        XCTAssertEqual(read(e, a, on: sheets), "5'-0\"")
        XCTAssertEqual(read(f, e, on: sheets), "20'-0\"")
        XCTAssertEqual(read(e, f, on: sheets), "20'-0\"")
    }

    /// An NTS area on a lower sheet still reads NTS under a scaled sheet on top: 120 canvas inches is 2 1/2" printed on
    /// the lower sheet, marked NTS, whether the plan is flat or turned.
    func testAnNTSAreaOnALowerSheetUnderAScaledSheetStillReadsNTS() {
        for top in [plan(), plan().turned(to: 33.5).sheet] {
            let canvas = Canvas(sheets: [lower(.notToScale), top])
            XCTAssertTrue(top.contains(a) && top.contains(b))
            XCTAssertEqual(canvas.measure(from: a, to: b), .notToScale(.inches(2.5)))
            XCTAssertEqual(canvas.format(canvas.measure(from: b, to: a)), "2 1/2\" NTS")
            // One point under the plan in the NTS area, the other on the plan alone: still NTS.
            XCTAssertTrue(canvas.measure(from: p(1_056, 96), to: a).isNotToScale)
        }
    }

    /// An NTS sheet under a scaled plan still reads NTS: 120 printed inches, the sheet being at its printed size.
    func testAnNTSSheetUnderAScaledSheetStillReadsNTS() {
        let loop = Sheet(id: SheetID(1), paper: .inches(200, by: 200), scale: .notToScale, origin: p(300, 0))
        let canvas = Canvas(sheets: [loop, plan()])
        XCTAssertTrue(plan().contains(a) && plan().contains(b) && loop.contains(a) && loop.contains(b))
        XCTAssertEqual(canvas.measure(from: a, to: b), .notToScale(.inches(120)))
    }
}
