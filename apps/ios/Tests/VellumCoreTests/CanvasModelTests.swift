import XCTest
@testable import VellumCore

/// Sheets, frames and measures on the canvas: the numbers ADR-0002 promises.
final class CanvasModelTests: XCTestCase {
    private let quarterInch = DrawingScale.architectural(inchesPerFoot: 0.25)
    private let eighthInch = DrawingScale.architectural(inchesPerFoot: 0.125)

    func testA24By36SheetAtAQuarterInchCovers96By144Feet() {
        let sheet = Sheet(paper: .archD, scale: .drawn(quarterInch))
        XCTAssertEqual(sheet.bounds.size.width.feet, 96)
        XCTAssertEqual(sheet.bounds.size.height.feet, 144)
        XCTAssertEqual(sheet.bounds.size.width, .feet(96))
    }

    func testASheetSitsAtItsOrigin() {
        let origin = CanvasPoint(x: .feet(-50), y: .feet(10))
        let sheet = Sheet(paper: PaperSize.archD.landscape, scale: .drawn(quarterInch), origin: origin)
        XCTAssertEqual(sheet.bounds.minX, .feet(-50))
        XCTAssertEqual(sheet.bounds.maxX, .feet(94))
        XCTAssertEqual(sheet.bounds.maxY, .feet(106))
        XCTAssertEqual(sheet.canvasPoint(at: PaperPoint(x: .inches(1), y: .inches(2))),
                       CanvasPoint(x: .feet(-46), y: .feet(18)))
    }

    func testAMeasureAcrossSheetsOfDifferentScalesAgreesWithEachSheetsPrintedDimension() {
        // A 1/4" sheet, and a 1/8" sheet butted against its right edge, as two plans of one plant would lie.
        let quarter = Sheet(paper: .archD, scale: .drawn(quarterInch))
        let eighth = Sheet(paper: .archD, scale: .drawn(eighthInch), origin: CanvasPoint(x: .feet(96), y: .zero))
        let canvas = Canvas(sheets: [quarter, eighth])

        // 12" in from the quarter sheet's left edge, to 6" in on the eighth sheet, along one line.
        let start = quarter.canvasPoint(at: PaperPoint(x: .inches(12), y: .inches(10)))
        let end = eighth.canvasPoint(at: PaperPoint(x: .inches(6), y: .inches(5)))
        XCTAssertEqual(start.y, end.y)

        // The part on the quarter sheet is 12" printed there (24" - 12"); the part on the eighth sheet is 6" printed.
        let onQuarter = quarter.measure(printed: .inches(12)).realLength!
        let onEighth = eighth.measure(printed: .inches(6)).realLength!
        XCTAssertEqual(onQuarter, .feet(48))
        XCTAssertEqual(onEighth, .feet(48))

        let measure = canvas.measure(from: start, to: end)
        XCTAssertEqual(measure, .real(onQuarter + onEighth))
        XCTAssertEqual(canvas.format(measure), "96'-0\"")
    }

    func testAMeasureOnOneSheetReadsThePrintedDimensionAtItsScale() {
        let sheet = Sheet(paper: .archD, scale: .drawn(.engineering(feetPerInch: 20)))
        let canvas = Canvas(sheets: [sheet])
        let start = sheet.canvasPoint(at: PaperPoint(x: .inches(1), y: .inches(1)))
        let end = sheet.canvasPoint(at: PaperPoint(x: .inches(4), y: .inches(5)))   // 3-4-5: 5" printed
        XCTAssertEqual(canvas.measure(from: start, to: end).realLength!.feet, 100, accuracy: 1e-9)
    }

    func testAnNTSSheetSitsAtItsPrintedSize() {
        let sheet = Sheet(paper: .tabloid, scale: .notToScale)
        XCTAssertEqual(sheet.bounds.size.width.inches, 11)
        XCTAssertEqual(sheet.bounds.size.height.inches, 17)
    }

    func testLengthsOnAnNTSSheetNeverComeBackReal() {
        let loop = Sheet(paper: .tabloid, scale: .notToScale, origin: CanvasPoint(x: .feet(200), y: .zero))
        let plan = Sheet(paper: .archD, scale: .drawn(quarterInch))
        let canvas = Canvas(sheets: [plan, loop])

        let start = loop.canvasPoint(at: PaperPoint(x: .inches(1), y: .inches(1)))
        let end = loop.canvasPoint(at: PaperPoint(x: .inches(4.5), y: .inches(1)))
        let measure = canvas.measure(from: start, to: end)
        XCTAssertNil(measure.realLength)
        XCTAssertTrue(measure.isNotToScale)
        XCTAssertEqual(measure, .notToScale(.inches(3.5)))
        XCTAssertEqual(canvas.format(measure), "3 1/2\" NTS")
        XCTAssertEqual(Canvas(units: .metric).format(measure), "3 1/2\" NTS")

        // Reading a printed length on the sheet itself is NTS too.
        XCTAssertNil(loop.measure(printed: .inches(2)).realLength)

        // One end on the NTS sheet, the other on the scaled plan: still never real.
        let onPlan = plan.canvasPoint(at: PaperPoint(x: .inches(2), y: .inches(2)))
        XCTAssertNil(canvas.measure(from: onPlan, to: start).realLength)
        XCTAssertNil(canvas.measure(from: start, to: onPlan).realLength)
    }

    func testAnNTSSheetOverlappingAScaledOneStillReadsNTS() {
        let plan = Sheet(paper: .archD, scale: .drawn(quarterInch))
        let loop = Sheet(paper: .letter, scale: .notToScale, origin: CanvasPoint(x: .feet(10), y: .feet(10)))
        let canvas = Canvas(sheets: [plan, loop])
        let point = CanvasPoint(x: .feet(10).offsetInches(2), y: .feet(10).offsetInches(2))
        XCTAssertTrue(plan.contains(point))
        XCTAssertTrue(canvas.measure(from: point, to: point.offsetBy(dx: .inches(1), dy: .zero)).isNotToScale)
    }

    func testAMeasureOffEverySheetIsReal() {
        let canvas = Canvas(sheets: [Sheet(paper: .letter, scale: .notToScale)])
        let measure = canvas.measure(from: CanvasPoint(x: .feet(100), y: .zero), to: CanvasPoint(x: .feet(112.5), y: .zero))
        XCTAssertEqual(measure, .real(.feet(12.5)))
    }

    func testAFrameIsAPaperSizeAtAScale() {
        let frame = Frame(paper: PaperSize.archD.landscape, scale: quarterInch,
                          origin: CanvasPoint(x: .feet(20), y: .feet(30)))
        XCTAssertEqual(frame.bounds.size, CanvasSize(width: .feet(144), height: .feet(96)))
        XCTAssertTrue(frame.contains(CanvasPoint(x: .feet(164), y: .feet(126))))
        XCTAssertFalse(frame.contains(CanvasPoint(x: .feet(165), y: .feet(126))))

        let letter = Frame(paper: .letter, scale: .engineering(feetPerInch: 10))
        XCTAssertEqual(letter.bounds.size, CanvasSize(width: .feet(85), height: .feet(110)))
        let custom = Frame(paper: .inches(18, by: 24), scale: .fullSize)
        XCTAssertEqual(custom.bounds.size, CanvasSize(width: .inches(18), height: .inches(24)))
        XCTAssertEqual(Frame(paper: .archE1, scale: .ratio(50)).bounds.size.width.inches, 1500)
    }

    func testTheNamedPaperSizes() {
        XCTAssertEqual(PaperSize.letter, .inches(8.5, by: 11))
        XCTAssertEqual(PaperSize.tabloid, .inches(11, by: 17))
        XCTAssertEqual(PaperSize.archD, .inches(24, by: 36))
        XCTAssertEqual(PaperSize.archE1, .inches(30, by: 42))
        XCTAssertEqual(PaperSize.archD.landscape, .inches(36, by: 24))
        XCTAssertEqual(PaperSize.archD.landscape.landscape, .inches(36, by: 24))
    }

    func testANewCanvasIsInFeetAndInches() {
        XCTAssertEqual(Canvas().units, .feetAndInches)
    }
}

private extension Length {
    func offsetInches(_ inches: Double) -> Length { self + .inches(inches) }
}
