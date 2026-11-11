#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import XCTest
@testable import VellumCore

/// Placing PDF sheets at their drawing scale (#11): reading SCALE off a title block, scale areas on an AS NOTED sheet,
/// where a placed sheet lands and how big it is, and the "done when": on each made-up PDF a measured length matches
/// its printed dimension. Every title block here is made up for the test.
final class SheetReadingTests: XCTestCase {
    private func read(_ lines: [PageText], paper: PaperSize = .inches(36, by: 24)) -> SheetReading {
        SheetReading.read(lines, paper: paper)
    }

    /// A title block line in the bottom-right corner of a 36 × 24 sheet.
    private func titleLine(_ text: String) -> PageText { .at(31, 22.6, text, width: 2.4, height: 0.14) }

    func testAnArchitecturalScaleIsRead() {
        let reading = read([titleLine("SCALE: 1/4\" = 1'-0\"")])
        XCTAssertEqual(reading.titleBlock, .scale(.architectural(inchesPerFoot: 0.25)))
        XCTAssertEqual(reading.suggestedScale, .drawn(.architectural(inchesPerFoot: 0.25)))
        XCTAssertFalse(reading.asksForScale)
        XCTAssertEqual(reading.caption, "1/4\" = 1'-0\"")
    }

    func testAnEngineeringScaleIsRead() {
        XCTAssertEqual(read([titleLine("Scale: 1\" = 20'")]).titleBlock, .scale(.engineering(feetPerInch: 20)))
        XCTAssertEqual(read([titleLine("SCALE 1\"=40'-0\"")]).titleBlock, .scale(.engineering(feetPerInch: 40)))
    }

    func testAMetricRatioIsRead() {
        let reading = read([titleLine("SCALE 1:50")])
        XCTAssertEqual(reading.titleBlock, .scale(.ratio(50)))
        XCTAssertEqual(reading.caption, "1:50")
    }

    func testNotToScaleIsRead() {
        for text in ["SCALE: NTS", "SCALE: N.T.S.", "NOT TO SCALE", "Scale: Not to scale"] {
            let reading = read([titleLine(text)])
            XCTAssertEqual(reading.titleBlock, .notToScale, text)
            XCTAssertEqual(reading.suggestedScale, .notToScale, text)
            XCTAssertFalse(reading.asksForScale, text)
        }
    }

    func testAsNotedAsksAndOffersTheDetailsScales() {
        let reading = read(MadeUpSheets.detailSheet.texts, paper: MadeUpSheets.detailSheet.paper)
        XCTAssertEqual(reading.titleBlock, .asNoted)
        XCTAssertTrue(reading.asksForScale)
        XCTAssertEqual(reading.caption, "AS NOTED")
        XCTAssertEqual(reading.detailScales, [.drawn(.architectural(inchesPerFoot: 1)),
                                              .drawn(.architectural(inchesPerFoot: 1.5)), .notToScale])
        XCTAssertEqual(reading.details.map(\.name), ["Detail 1", "Detail 2", "Detail 3"])
        XCTAssertEqual(reading.suggestedScale, .drawn(.architectural(inchesPerFoot: 1)), "the first detail's scale")
        XCTAssertEqual(reading.sheetNumber, "D-501")
    }

    func testNoScaleAsksWithNothingPicked() {
        let reading = read([.at(31, 22, "BOILER HOUSE PLAN"), .at(33, 22.6, "M-101", width: 1.2, height: 0.42)])
        XCTAssertEqual(reading.titleBlock, .none)
        XCTAssertTrue(reading.asksForScale)
        XCTAssertNil(reading.suggestedScale)
        XCTAssertEqual(reading.caption, "No scale read")
        XCTAssertEqual(reading.sheetNumber, "M-101")
    }

    func testAScanHasNoTextAndAsks() {
        let reading = read([])
        XCTAssertEqual(reading.titleBlock, .scan)
        XCTAssertTrue(reading.isScan)
        XCTAssertTrue(reading.asksForScale)
        XCTAssertNil(reading.suggestedScale)
    }

    func testSeveralScalesAskWithTheTitleBlocksPicked() {
        let reading = read([titleLine("SCALE: 1/4\" = 1'-0\""), .at(4, 12, "1  ENLARGED PLAN", width: 2.4),
                            .at(4, 12.3, "SCALE: 1/2\" = 1'-0\"", width: 2)])
        XCTAssertEqual(reading.titleBlock, .scale(.architectural(inchesPerFoot: 0.25)))
        XCTAssertTrue(reading.asksForScale, "two scales on one sheet")
        XCTAssertEqual(reading.suggestedScale, .drawn(.architectural(inchesPerFoot: 0.25)))
        XCTAssertEqual(reading.caption, "Several scales")
        XCTAssertEqual(reading.areas(placedAt: .drawn(.architectural(inchesPerFoot: 0.25))).count, 1)
    }

    func testJunkAfterScaleIsNotGuessedAt() {
        let reading = read([titleLine("SCALE: 1/4 = 1")])
        XCTAssertEqual(reading.titleBlock, .unreadable("1/4 = 1"))
        XCTAssertTrue(reading.asksForScale)
        XCTAssertNil(reading.suggestedScale)
    }

    func testAScaleLabelReadsTheValueBesideOrBelowIt() {
        XCTAssertEqual(read([.at(31, 22.6, "SCALE:", width: 0.6), .at(31.8, 22.6, "3/8\" = 1'-0\"", width: 1.2)])
            .titleBlock, .scale(.architectural(inchesPerFoot: 0.375)))
        XCTAssertEqual(read([.at(31, 22.4, "SCALE", width: 0.6), .at(31, 22.65, "1\" = 10'", width: 1)]).titleBlock,
                       .scale(.engineering(feetPerInch: 10)))
    }

    func testDimensionTextAndOtherWordsAreNeverTakenForAScale() {
        let reading = read([.at(5, 5, "12'-0\""), .at(5, 6, "1/4\" = 1'-0\""), .at(5, 7, "GRAYSCALE PRINT"),
                            .at(5, 8, "PLANTS AND NOTES")])
        XCTAssertEqual(reading.titleBlock, .none)
    }

    func testSheetNumbers() {
        for good in ["M-101", "E1.01", "L-1042", "A5", "FP-2"] { XCTAssertTrue(SheetReading.isSheetNumber(good), good) }
        for bad in ["24'-0\"", "MECHANICAL", "M-", "101", "ABCD-1", "M-101A"] {
            XCTAssertFalse(SheetReading.isSheetNumber(bad), bad)
        }
        XCTAssertEqual(read([.at(30, 22, "SHEET: E1.01", width: 2)]).sheetNumber, "E1.01")
        // The tallest wins: the title block's number over a tag in the drawing.
        XCTAssertEqual(read([.at(4, 4, "FT-1042", width: 1, height: 0.18),
                             .at(33, 22.6, "L-1042", width: 1.2, height: 0.42)]).sheetNumber, "L-1042")
    }

    /// PDFKit's character boxes can split one printed line; the pieces are joined, and labels inches apart are not.
    func testPiecesOfOnePrintedLineAreJoined() {
        let reading = read([.at(31, 22.6, "SCALE: 1/4\" =", width: 1.2, height: 0.14),
                            .at(32.25, 22.6, "1'-0\"", width: 0.4, height: 0.14),
                            .at(33, 23, "M-", width: 0.5, height: 0.42), .at(33.5, 23, "101", width: 0.7, height: 0.42)])
        XCTAssertEqual(reading.titleBlock, .scale(.architectural(inchesPerFoot: 0.25)))
        XCTAssertEqual(reading.sheetNumber, "M-101")
        let notes = read([.at(31, 22.6, "SCALE: AS", width: 0.9, height: 0.14), .at(32, 22.6, "NOTED", width: 0.6, height: 0.14)])
        XCTAssertEqual(notes.titleBlock, .asNoted)
        // Two details' scales on one row, inches apart, stay two.
        let apart = SheetReading.joinFragments([.at(1, 7.6, "SCALE: 1\" = 1'-0\"", width: 1.8, height: 0.16),
                                                .at(5.8, 7.6, "SCALE: NTS", width: 1.2, height: 0.16)])
        XCTAssertEqual(apart.count, 2)
    }

    func testDetailNames() {
        XCTAssertEqual(SheetReading.detailName("2  PIPE SUPPORT"), "Detail 2")
        XCTAssertEqual(SheetReading.detailName("DETAIL B - VALVE"), "Detail B")
    }
}

final class ScaleAreaTests: XCTestCase {
    private let detail = MadeUpSheets.detailSheet
    private lazy var reading = SheetReading.read(detail.texts, paper: detail.paper)
    private let main = Sheet.Scale.drawn(.architectural(inchesPerFoot: 1))

    private func placed(at origin: CanvasPoint = CanvasPoint(x: .feet(100), y: .feet(-20))) -> Sheet {
        Sheet(paper: detail.paper, scale: main, origin: origin, areas: reading.areas(placedAt: main))
    }

    /// Each detail's area holds its own drawing and printed dimension, and no other's.
    func testEachDetailsAreaHoldsItsDimension() {
        XCTAssertEqual(reading.details.count, 3)
        for (detail, dimension) in zip(reading.details, self.detail.dimensions) {
            XCTAssertTrue(detail.area.contains(dimension.from), "\(detail.name) holds its dimension's start")
            XCTAssertTrue(detail.area.contains(dimension.to), "\(detail.name) holds its dimension's end")
        }
        let areas = reading.details.map(\.area)
        for (i, a) in areas.enumerated() {
            for b in areas[(i + 1)...] { XCTAssertFalse(a.maxX > b.minX && b.maxX > a.minX && a.maxY > b.minY && b.maxY > a.minY) }
        }
        XCTAssertLessThan(areas.map(\.maxY).max()!, MadeUpSheets.titleBlockBox(detail.paper).minY,
                          "no area takes in the title block")
    }

    /// Placed at its first detail's scale, the sheet keeps the other two details as scale areas.
    func testTheAreasAreTheDetailsAtOtherScales() {
        let areas = reading.areas(placedAt: main)
        XCTAssertEqual(areas.map(\.name), ["Detail 2", "Detail 3"])
        XCTAssertEqual(areas.map(\.scale), [.drawn(.architectural(inchesPerFoot: 1.5)), .notToScale])
        XCTAssertEqual(areas[0].label, "Detail 2 · 1 1/2\" = 1'-0\"")
        XCTAssertEqual(placed().label, "Sheet · 1\" = 1'-0\" + 2 scale areas")
    }

    /// The sheet's size on the canvas comes from its main scale: 17 × 11 at 1" = 1'-0" covers 17' × 11'.
    func testThePlacementSizeUsesTheMainScale() {
        let sheet = placed()
        XCTAssertEqual(sheet.bounds.size.width.feet, 17, accuracy: 1e-9)
        XCTAssertEqual(sheet.bounds.size.height.feet, 11, accuracy: 1e-9)
        let quarter = Sheet(paper: .inches(36, by: 24), scale: .drawn(.architectural(inchesPerFoot: 0.25)))
        XCTAssertEqual(quarter.bounds.size.width.feet, 144, accuracy: 1e-9)
        XCTAssertEqual(quarter.bounds.size.height.feet, 96, accuracy: 1e-9)
    }

    /// Which scale a point reads: its area's inside one, the sheet's outside, and the topmost sheet's where two overlap.
    func testWhichScaleAPointReads() {
        let sheet = placed()
        let inDetail2 = sheet.canvasPoint(at: PaperPoint(x: .inches(7), y: .inches(4)))
        let inDetail3 = sheet.canvasPoint(at: PaperPoint(x: .inches(11), y: .inches(4)))
        let inDetail1 = sheet.canvasPoint(at: PaperPoint(x: .inches(3), y: .inches(4)))
        let offSheet = CanvasPoint(x: .feet(-500), y: .zero)
        XCTAssertEqual(sheet.scale(at: inDetail2), .drawn(.architectural(inchesPerFoot: 1.5)))
        XCTAssertEqual(sheet.scale(at: inDetail3), .notToScale)
        XCTAssertEqual(sheet.scale(at: inDetail1), main)
        XCTAssertNil(sheet.area(at: offSheet))
        XCTAssertEqual(sheet.paperPoint(at: inDetail2), PaperPoint(x: .inches(7), y: .inches(4)))
    }

    /// Measures and dimensions read a scale area's scale inside it: Detail 2's 3" printed reads 2'-0", Detail 3's 2"
    /// reads 2" NTS, Detail 1 at the sheet's scale reads 3'-0".
    func testMeasuresAndDimensionsReadTheAreasScale() {
        let canvas = Canvas(sheets: [placed()])
        let sheet = canvas.sheets[0]
        func at(_ x: Double, _ y: Double) -> CanvasPoint { sheet.canvasPoint(at: PaperPoint(x: .inches(x), y: .inches(y))) }
        XCTAssertEqual(canvas.format(canvas.measure(from: at(6, 3.8), to: at(9, 3.8))), "2'-0\"")
        XCTAssertEqual(canvas.format(canvas.measure(from: at(10.5, 3.8), to: at(12.5, 3.8))), "2\" NTS")
        XCTAssertEqual(canvas.format(canvas.measure(from: at(1.5, 3.8), to: at(4.5, 3.8))), "3'-0\"")
        let dimension = CanvasDimension.pulled(id: DimensionID(1), start: at(6, 3.8), end: at(9, 3.8),
                                               through: at(7.5, 3), colour: .sketch, textHeight: .inches(4))
        XCTAssertEqual(canvas.format(canvas.measure(dimension)), "2'-0\"")
        // Off the sheet the canvas is real as ever.
        XCTAssertEqual(canvas.format(canvas.measure(from: CanvasPoint(x: .feet(-50), y: .zero),
                                                    to: CanvasPoint(x: .feet(-40), y: .zero))), "10'-0\"")
    }
}

/// The "done when" of #11: each made-up PDF placed at the scale Vellum reads off its title block, and a measure between
/// the ends of each printed dimension reads what is printed on it.
final class MadeUpSheetTests: XCTestCase {
    func testEveryMadeUpSheetMeasuresItsPrintedDimensions() {
        let pages = [MadeUpSheets.quarterInchPlan, MadeUpSheets.detailSheet, MadeUpSheets.loopDiagram]
        var checked = 0
        for (i, page) in pages.enumerated() {
            let reading = SheetReading.read(page.texts, paper: page.paper)
            XCTAssertEqual(reading.sheetNumber, page.number)
            guard let scale = reading.suggestedScale else { return XCTFail("\(page.number): no scale read") }
            let sheet = Sheet(paper: page.paper, scale: scale, origin: CanvasPoint(x: .feet(Double(i) * 300), y: .feet(7)),
                              areas: reading.areas(placedAt: scale))
            let canvas = Canvas(sheets: [sheet])
            for dimension in page.dimensions {
                let measured = canvas.format(canvas.measure(from: sheet.canvasPoint(at: dimension.from),
                                                            to: sheet.canvasPoint(at: dimension.to)))
                print("made-up \(page.number) at \(scale): printed \(dimension.text), measured \(measured)")
                XCTAssertEqual(measured, dimension.text, "\(page.number)'s printed dimension")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 5)
    }

    func testTheQuarterInchPlanCovers144By96Feet() {
        let page = MadeUpSheets.quarterInchPlan
        let reading = SheetReading.read(page.texts, paper: page.paper)
        let sheet = Sheet(paper: page.paper, scale: reading.suggestedScale!)
        XCTAssertEqual(Canvas(sheets: [sheet]).format(.real(sheet.bounds.size.width)), "144'-0\"")
        XCTAssertEqual(Canvas(sheets: [sheet]).format(.real(sheet.bounds.size.height)), "96'-0\"")
    }

    /// An NTS sheet goes on at its printed size: 11 × 8.5 covers 11" × 8.5".
    func testTheNTSSheetGoesOnAtPrintedSize() {
        let page = MadeUpSheets.loopDiagram
        let sheet = Sheet(paper: page.paper, scale: SheetReading.read(page.texts, paper: page.paper).suggestedScale!)
        XCTAssertEqual(sheet.bounds.size.width.inches, 11, accuracy: 1e-12)
        XCTAssertEqual(sheet.bounds.size.height.inches, 8.5, accuracy: 1e-12)
    }

    func testTheScanAsksForAScale() {
        let reading = SheetReading.read(MadeUpSheets.scan.texts, paper: MadeUpSheets.scan.paper)
        XCTAssertTrue(reading.isScan)
        XCTAssertNil(reading.suggestedScale)
    }

    func testTheMadeUpFilesAreMadeUp() {
        XCTAssertEqual(MadeUpSheets.files.count, 4)
        for file in MadeUpSheets.files {
            XCTAssertTrue(file.name.contains("(example)"), file.name)
            for page in file.pages { XCTAssertTrue(page.title.contains("(EXAMPLE)"), page.title) }
        }
    }
}

/// Placing a sheet is one undo step, saved in the ink log and the snapshot, and replays exactly (ADR-0014's #11
/// amendment).
final class SheetSavingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-sheets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        DurableFile.Fault.inject(nil)
        try? FileManager.default.removeItem(at: folder)
    }

    private func detailSheet(at origin: CanvasPoint) -> Sheet {
        let page = MadeUpSheets.detailSheet
        let reading = SheetReading.read(page.texts, paper: page.paper)
        let main = reading.suggestedScale!
        return Sheet(paper: page.paper, scale: main, origin: origin,
                     page: SheetPage(file: "madeup02", name: "IFC set (example).pdf",
                                     path: "/Projects (example)/IFC set (example).pdf", index: 1,
                                     number: reading.sheetNumber),
                     areas: reading.areas(placedAt: main), invertsBadly: false)
    }

    func testPlacingASheetIsOneUndoStep() {
        var session = InkSession()
        session.draw([CanvasPoint(x: .feet(1), y: .feet(1)), CanvasPoint(x: .feet(2), y: .feet(1))], tool: .pen,
                     colour: .red, width: .inches(1))
        let placed = session.addSheet(detailSheet(at: CanvasPoint(x: .inches(10.123456789), y: .feet(-3))))
        XCTAssertEqual(placed.id, SheetID(1))
        XCTAssertEqual(placed.origin, placed.origin.onInkGrid, "kept on the ink grid, so it reopens exactly")
        XCTAssertEqual(session.lastChange.addedSheets, [placed])
        let second = session.addSheet(Sheet(paper: .letter, scale: .notToScale, invertsBadly: true))
        XCTAssertEqual(second.id, SheetID(2))
        XCTAssertEqual(session.sheets.map(\.id), [SheetID(1), SheetID(2)])
        session.undo()
        XCTAssertEqual(session.lastChange.removedSheets, [SheetID(2)])
        XCTAssertEqual(session.sheets.map(\.id), [SheetID(1)])
        session.redo()
        XCTAssertEqual(session.sheets.count, 2)
        session.undo()
        session.undo()
        XCTAssertTrue(session.sheets.isEmpty)
        XCTAssertEqual(session.ink.count, 1, "undo took the sheets, not the stroke")
        // A new sheet after undoing takes a new id; the redo steps go.
        let third = session.addSheet(Sheet(paper: .tabloid, scale: .drawn(.ratio(50))))
        XCTAssertEqual(third.id, SheetID(3))
        XCTAssertFalse(session.canRedo)
    }

    func testTheSheetEventRoundTripsThroughTheCodec() throws {
        for sheet in [detailSheet(at: CanvasPoint(x: .feet(12), y: .feet(-4)).onInkGrid),
                      Sheet(id: SheetID(9), paper: .letter, scale: .notToScale, invertsBadly: true),
                      Sheet(id: SheetID(4), paper: .archE1, scale: .drawn(.ratio(100)),
                            page: SheetPage(file: "h", name: "ünïcødé (example).pdf", path: "/ü/x.pdf", index: 41))] {
            let event = InkEvent.addSheet(sheet)
            let bytes = InkCodec.encode(event)
            XCTAssertEqual(try InkCodec.decodeEvent(bytes[...]), event)
            print("sheet event: \(bytes.count) bytes, \(sheet.areas.count) areas")
            XCTAssertLessThan(bytes.count, 400)
            // Cut short anywhere, it is refused, never read as something else.
            for cut in [1, bytes.count / 2, bytes.count - 1] {
                XCTAssertThrowsError(try InkCodec.decodeEvent(bytes[..<cut]))
            }
        }
    }

    func testTheSnapshotKeepsSheetsAndTheirHistory() throws {
        var session = InkSession()
        session.addSheet(detailSheet(at: CanvasPoint(x: .feet(3), y: .feet(4))))
        session.addSheet(Sheet(paper: .letter, scale: .notToScale, invertsBadly: true))
        session.undo()
        let decoded = try InkCodec.decodeSession(InkCodec.encode(session)[...])
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.sheets.count, 1)
        XCTAssertTrue(decoded.canRedo)
        var redone = decoded
        redone.redo()
        XCTAssertEqual(redone.sheets.count, 2)
    }

    /// A canvas that never had a sheet is written exactly as version 3 wrote it, so its budgets hold and version 3
    /// reads it.
    func testACanvasWithNoSheetsIsWrittenAsVersion3Did() throws {
        var session = InkSession()
        session.draw([CanvasPoint(x: .feet(1), y: .feet(1))], tool: .pen, colour: .blue, width: .inches(1))
        session.addFrame(paper: .archD, scale: .architectural(inchesPerFoot: 0.25), origin: .origin)
        let bytes = InkCodec.encode(session)
        XCTAssertEqual(try InkCodec.decodeSession(bytes[...], version: 3), session)
        XCTAssertEqual(try InkCodec.decodeSession(bytes[...], version: 4), session)
    }

    /// Placed sheets reopen from the log, and from a snapshot after compaction, with their undo history.
    func testPlacedSheetsReopenFromTheLogAndTheSnapshot() throws {
        let store = try InkStore(folder: folder)
        var session = InkSession()
        session.draw([CanvasPoint(x: .feet(1), y: .feet(1)), CanvasPoint(x: .feet(3), y: .feet(2))], tool: .pen,
                     colour: .sketch, width: .inches(1))
        session.addSheet(detailSheet(at: CanvasPoint(x: .feet(-30), y: .feet(10))))
        session.addSheet(Sheet(paper: .letter, scale: .notToScale, origin: CanvasPoint(x: .feet(50), y: .zero)))
        session.undo()
        try store.append(session.takeEvents())
        try store.flush()
        store.closeFiles()
        let reopened = try InkStore(folder: folder)
        XCTAssertEqual(reopened.session, session)
        XCTAssertEqual(reopened.session.sheets.first?.areas.count, 2)
        try reopened.compact()
        reopened.closeFiles()
        XCTAssertEqual(try InkStore(folder: folder).session, session)
    }

    /// A sheet's PDF is kept in the canvas folder's `sheets` folder, once, and a failed write leaves nothing half
    /// written.
    func testTheSheetsPDFIsKeptInTheCanvasFolder() throws {
        let library = CanvasLibrary(root: folder.appendingPathComponent("Canvases"))
        let canvas = try library.create(name: "Made-up canvas")
        let source = folder.appendingPathComponent("download.pdf")
        let bytes = Data("%PDF-1.4 made up for the test\n%%EOF\n".utf8)
        try bytes.write(to: source)
        XCTAssertTrue(try library.keepSheetPDF(from: source, named: "madeup01", in: canvas.id))
        XCTAssertFalse(try library.keepSheetPDF(from: source, named: "madeup01", in: canvas.id), "kept once")
        let kept = library.sheetPDF(named: "madeup01", in: canvas.id)
        XCTAssertEqual(try Data(contentsOf: kept), bytes)
        let files = try FileManager.default.contentsOfDirectory(atPath: library.folder(for: canvas.id).path)
            .filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(files, ["canvas.json", "ink.log", "sheets"])

        // A write that fails part way leaves no PDF under the name, so the sheet is never placed on half a PDF.
        DurableFile.Fault.inject { operation, _ in operation == .write ? .shortWrite(5, ENOSPC) : nil }
        XCTAssertThrowsError(try library.keepSheetPDF(from: source, named: "madeup02", in: canvas.id))
        DurableFile.Fault.inject(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.sheetPDF(named: "madeup02", in: canvas.id).path))
        XCTAssertTrue(try library.keepSheetPDF(from: source, named: "madeup02", in: canvas.id))
    }
}

/// The "inverts badly" test (#11, ADR-0011): line drawings invert; scans and coloured pages show as printed, on white
/// paper (#100).
final class SheetToneTests: XCTestCase {
    /// A made-up 96 × 64 sample: paper of one colour with lines of another every `every` rows and columns.
    private func sample(paper: (UInt8, UInt8, UInt8), line: (UInt8, UInt8, UInt8), every: Int,
                        fill: (rect: (Int, Int, Int, Int), colour: (UInt8, UInt8, UInt8))? = nil) -> [UInt8] {
        var pixels: [UInt8] = []
        for y in 0..<64 {
            for x in 0..<96 {
                var c = (x % every == 0 || y % every == 0) ? line : paper
                if let fill, x >= fill.rect.0, y >= fill.rect.1, x < fill.rect.2, y < fill.rect.3 { c = fill.colour }
                pixels += [c.0, c.1, c.2, 255]
            }
        }
        return pixels
    }

    func testALineDrawingInverts() {
        let reading = SheetTone.read(rgba: sample(paper: (255, 255, 255), line: (0, 0, 0), every: 12), hasText: true)
        XCTAssertFalse(reading.invertsBadly, "\(reading)")
        XCTAssertEqual(SheetDisplay.display(dark: true, invertsBadly: reading.invertsBadly), .inverted)
    }

    func testAScanShowsAsPrinted() {
        let grey = SheetTone.read(rgba: sample(paper: (205, 200, 185), line: (60, 60, 60), every: 12), hasText: true)
        XCTAssertTrue(grey.invertsBadly, "grey, yellowed paper: \(grey)")
        let noText = SheetTone.read(rgba: sample(paper: (255, 255, 255), line: (0, 0, 0), every: 12), hasText: false)
        XCTAssertTrue(noText.invertsBadly, "no text: a scan")
        XCTAssertEqual(SheetDisplay.display(dark: true, invertsBadly: true), .asPrinted)
    }

    func testColouredFillsShowAsPrinted() {
        let coloured = SheetTone.read(rgba: sample(paper: (255, 255, 255), line: (0, 0, 0), every: 12,
                                                   fill: ((10, 10, 40, 30), (40, 120, 220))), hasText: true)
        XCTAssertTrue(coloured.invertsBadly, "\(coloured)")
        let dark = SheetTone.read(rgba: sample(paper: (255, 255, 255), line: (0, 0, 0), every: 12,
                                               fill: ((0, 0, 60, 40), (20, 20, 20))), hasText: true)
        XCTAssertTrue(dark.invertsBadly, "a large black fill: \(dark)")
    }

    /// The made-up coloured P&ID the dark-mode capture shows on white paper is coloured well past the limit, so it is
    /// shown as printed: its fills alone cover several times `colourfulLimit` of the page.
    func testTheMadeUpColouredDiagramIsColouredEnoughToShowAsPrinted() {
        let page = MadeUpSheets.colouredDiagram
        let filled = page.fills.reduce(0) { $0 + $1.rect.width.inches * $1.rect.height.inches }
        let share = filled / (page.paper.width.inches * page.paper.height.inches)
        XCTAssertGreaterThan(share, SheetTone.colourfulLimit * 3, "fills cover \(share) of the page")
        for fill in page.fills {
            let c = [Int(fill.colour.red), Int(fill.colour.green), Int(fill.colour.blue)]
            XCTAssertGreaterThanOrEqual(c.max()! - c.min()!, 48, "\(fill.colour) is clearly coloured")
        }
        XCTAssertFalse(page.isScan)
        XCTAssertFalse(page.texts.isEmpty)
    }
}

/// Which tiles of a placed sheet are drawn, and the work budgets in `docs/perf/baselines/sheets.json`.
final class SheetTileTests: XCTestCase {
    private static let sheet = Sheet(id: SheetID(1), paper: .inches(36, by: 24),
                                     scale: .drawn(.architectural(inchesPerFoot: 0.25)))

    /// The canvas view at 2 points per inch, centred on the sheet: 96 points per printed inch, level 14 (128).
    private func view(_ pointsPerInch: Double = 2) -> Viewport {
        Viewport(centre: Self.sheet.bounds.center, pointsPerInch: pointsPerInch, screenWidth: 951, screenHeight: 669)
    }

    private static let baseline: [String: Double] = {
        struct Baseline: Decodable {
            struct Entry: Decodable { let metric: String; let kind: String; let value: Double }
            let entries: [Entry]
        }
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/perf/baselines/sheets.json")
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(Baseline.self, from: data) else { return [:] }
        return Dictionary(decoded.entries.filter { $0.kind == "count" }.map { ($0.metric, $0.value) },
                          uniquingKeysWith: { a, _ in a })
    }()

    private func check(_ metric: String, _ measured: Double, file: StaticString = #filePath, line: UInt = #line) {
        print("budget \(metric): measured \(measured)")
        guard let budget = Self.baseline[metric] else {
            return XCTFail("No budget for \(metric) in docs/perf/baselines/sheets.json", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(measured, budget, "\(metric) is over its budget", file: file, line: line)
    }

    private func plan(_ book: inout SheetTileBook, _ viewport: Viewport) -> SheetTileBook.Plan {
        let plan = book.plan([Self.sheet], viewport: viewport) { _ in .asPrinted }
        for key in plan.draw { book.didDraw(key) }
        return plan
    }

    func testLevels() {
        XCTAssertEqual(SheetTileBook.level(for: Self.sheet, pointsPerInch: 2), 14)
        XCTAssertEqual(SheetTileBook.level(for: Self.sheet, pointsPerInch: 2.5), 14)
        XCTAssertEqual(SheetTileBook.level(for: Self.sheet, pointsPerInch: 3), 15)
        XCTAssertEqual(SheetTileBook.level(for: Self.sheet, pointsPerInch: 1_000), SheetTileBook.maxLevel)
        XCTAssertEqual(SheetTileBook.level(for: Self.sheet, pointsPerInch: 0.002), 5, "the whole page in one tile")
        XCTAssertEqual(SheetTileBook.paperSide(level: 14), 2, accuracy: 1e-12)
    }

    /// The first view draws only the tiles on screen; panning a screen across draws only the tiles that came into
    /// view; panning back, or pinching within the level, draws none.
    /// Measured at 2x, where both screens' tiles fit the cache; at 3x the 44 tiles are two over it, so going back
    /// draws the two least recently shown again (`testTheCacheStaysUnderItsLimit` holds the limit).
    func testPanningAndPinchingDrawOnlyNewTiles() {
        var book = SheetTileBook(displayScale: 2)
        let first = plan(&book, view())
        check("sheet_tiles_drawn_first_view", Double(first.draw.count))
        XCTAssertEqual(first.showing.first?.covered, false)
        XCTAssertEqual(plan(&book, view()).showing.first?.covered, true)

        var right = view()
        right.pan(dx: -951, dy: 0)
        check("sheet_tiles_drawn_per_screen_pan", Double(plan(&book, right).draw.count))
        check("sheet_tiles_drawn_panning_back", Double(plan(&book, view()).draw.count))

        var pinched = view()
        pinched.zoom(by: 1.25, about: ScreenPoint(x: 475.5, y: 334.5))
        check("sheet_tiles_drawn_per_pinch_within_level", Double(plan(&book, pinched).draw.count))
        XCTAssertEqual(book.tilesDrawn, first.draw.count + 20)
    }

    /// However far Zach pans, the tiles kept stay under the cache limit, and the ones on screen are never let go.
    func testTheCacheStaysUnderItsLimit() {
        var book = SheetTileBook(displayScale: 3)
        var viewport = view(6)
        var largest = 0
        for step in 0..<60 {
            viewport.pan(dx: step % 20 < 10 ? -400 : 400, dy: step % 7 == 0 ? -300 : 0)
            let plan = plan(&book, viewport)
            for showing in plan.showing { for key in showing.keys { XCTAssertTrue(book.isDrawn(key)) } }
            largest = max(largest, book.cachedBytes)
        }
        check("sheet_tile_cache_bytes", Double(largest))
        XCTAssertLessThanOrEqual(largest, SheetTileBook.cacheLimit)
    }

    func testAnUndoneSheetsTilesGo() {
        var book = SheetTileBook(displayScale: 3)
        _ = plan(&book, view())
        XCTAssertGreaterThan(book.cachedCount, 0)
        XCTAssertEqual(book.forget(sheet: SheetID(1)).count, 24)
        XCTAssertEqual(book.cachedCount, 0)
    }

    /// Bytes downloaded for a placed sheet are the PDF's, once: picking it again, from another canvas, or placing it
    /// twice downloads nothing more.
    func testAPDFIsDownloadedOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-pdfs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data(repeating: 0x25, count: 12_345)
        let file = DropboxFile(id: "id:9", name: "M-101 (example).pdf", path: "/Made up/M-101 (example).pdf",
                               size: bytes.count, contentHash: "abc123", rev: "015f")
        let dropbox = BytesDropbox(bytes)
        let session = DropboxSession(appKey: DropboxAppKey(buildSetting: "abcdefgh1234567")!, transport: dropbox,
                                     store: DropboxMemoryTokenStore(DropboxTokens(accessToken: "a", refreshToken: "r",
                                                                                  expiresAt: .distantFuture)))
        let pdfs = SheetPDFs(folder: folder)
        for _ in 0..<3 {
            let url = try await pdfs.pdf(for: file) { try await session.download(file) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        let library = CanvasLibrary(root: folder.appendingPathComponent("Canvases"))
        for _ in 0..<2 {
            let canvas = try library.create()
            try library.keepSheetPDF(from: pdfs.url(for: file), named: file.keptName, in: canvas.id)
        }
        check("sheet_downloads_per_pdf", Double(dropbox.requests.count))
        check("sheet_bytes_downloaded_per_pdf_byte", Double(pdfs.bytesDownloaded) / Double(bytes.count))
        let request = try XCTUnwrap(dropbox.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://content.dropboxapi.com/2/files/download")
        XCTAssertEqual(request.headers["Dropbox-API-Arg"], #"{"path":"rev:015f"}"#)
        XCTAssertEqual(request.headers["Authorization"], "Bearer a")
    }

    func testADownloadCutShortIsNotKept() async throws {
        let file = DropboxFile(id: "id:9", name: "x (example).pdf", path: "/x (example).pdf", size: 100,
                               contentHash: "short", rev: "1")
        let session = DropboxSession(appKey: DropboxAppKey(buildSetting: "abcdefgh1234567")!,
                                     transport: BytesDropbox(Data(count: 60)),
                                     store: DropboxMemoryTokenStore(DropboxTokens(accessToken: "a", refreshToken: "r",
                                                                                  expiresAt: .distantFuture)))
        do {
            _ = try await session.download(file)
            XCTFail("a short download was accepted")
        } catch {
            XCTAssertEqual(error as? DropboxError, .unexpectedReply)
        }
    }

    func testAListingKeepsPDFsBesideFolders() async throws {
        let body = #"""
        {"entries":[
         {".tag":"folder","name":"Superseded","path_display":"/P/Superseded","id":"id:1"},
         {".tag":"file","name":"M-101 (example).pdf","path_display":"/P/M-101 (example).pdf","id":"id:2","size":2048,"content_hash":"h2","rev":"r2"},
         {".tag":"file","name":"notes.txt","path_display":"/P/notes.txt","id":"id:3","size":10},
         {".tag":"file","name":"A-1 (example).PDF","path_display":"/P/A-1 (example).PDF","id":"id:4","size":10,"content_hash":"h4","rev":"r4"}],
         "cursor":"c1","has_more":false}
        """#
        let session = DropboxSession(appKey: DropboxAppKey(buildSetting: "abcdefgh1234567")!,
                                     transport: BytesDropbox(Data(body.utf8)),
                                     store: DropboxMemoryTokenStore(DropboxTokens(accessToken: "a", refreshToken: "r",
                                                                                  expiresAt: .distantFuture)))
        let contents = try await session.contents(of: "/P")
        XCTAssertEqual(contents.folders.map(\.name), ["Superseded"])
        XCTAssertEqual(contents.pdfs.map(\.name), ["A-1 (example).PDF", "M-101 (example).pdf"])
        XCTAssertEqual(contents.pdfs.last?.size, 2048)
        XCTAssertEqual(contents.pdfs.last?.contentHash, "h2")
    }

    /// A listing kept before #11 has no PDFs; it is listed afresh rather than asked only for changes.
    func testAListingKeptBeforePDFsIsListedAgain() throws {
        let old = #"{"folders":[],"cursor":"c","checkedAt":0}"#
        let listing = try JSONDecoder().decode(DropboxListing.self, from: Data(old.utf8))
        XCTAssertFalse(listing.listsPDFs)
        let roundTrip = try JSONDecoder().decode(DropboxListing.self, from: JSONEncoder().encode(listing))
        XCTAssertFalse(roundTrip.listsPDFs)
        XCTAssertTrue(DropboxListing(folders: [], cursor: "c", checkedAt: Date()).listsPDFs)
    }
}

/// Answers every request with the same bytes.
private final class BytesDropbox: DropboxTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let body: Data
    private var sent: [DropboxHTTPRequest] = []
    init(_ body: Data) { self.body = body }
    func send(_ request: DropboxHTTPRequest) async throws -> DropboxHTTPResponse {
        lock.withLock { sent.append(request) }
        return DropboxHTTPResponse(status: 200, body: body)
    }
    var requests: [DropboxHTTPRequest] { lock.withLock { sent } }
}
