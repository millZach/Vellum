import Foundation
import XCTest
@testable import VellumCore

/// A placed plot fitted to the page, not to scale, stays NTS (#96): the fitted mark is saved on the sheet, through the
/// log, the snapshot and a relaunch; a canvas without one is written byte for byte as before; nothing through the model
/// gives the sheet a scale, undo included; and lengths on it read as printed lengths marked NTS. Every sheet, path and
/// name here is made up for the test.
final class FittedSheetTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-fitted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let page = SheetPage(file: "madeupfit01", name: "M-101 - Model (example).pdf",
                                 path: "/Vellum/Plots/Made-up/M-101 - Model (example).pdf", index: 0, number: "M-101")

    /// A made-up fitted plot on an 11" × 8.5" sheet, as search, Open in a new canvas and Add sheet make it.
    private func fittedSheet(at origin: CanvasPoint = .origin) -> Sheet {
        var sheet = SheetReading.read([], paper: .inches(11, by: 8.5))
            .sheet(placedAt: .drawn(.architectural(inchesPerFoot: 0.25)), page: page, invertsBadly: false, fitted: true)
        sheet.origin = origin
        return sheet
    }

    // MARK: Saved

    /// The 24 bytes #11 and #44 write for a made-up NTS letter sheet, id 9, at the origin, inverting badly, with no page
    /// and no areas: the event code, the id, 8.5 and 11 as little-endian 64-bit floats, NTS, the corner, the flags, no
    /// page, no areas.
    private let oldSheetBytes: [UInt8] = [15, 9,
                                          0, 0, 0, 0, 0, 0, 0x21, 0x40,
                                          0, 0, 0, 0, 0, 0, 0x26, 0x40,
                                          2, 0, 0, 1, 0, 0]

    func testASheetWithoutTheMarkIsWrittenAndReadByteForByteAsBefore() throws {
        let old = Sheet(id: SheetID(9), paper: .letter, scale: .notToScale, invertsBadly: true)
        XCTAssertFalse(old.fitted)
        XCTAssertEqual(InkCodec.encode(.addSheet(old)), oldSheetBytes)
        let decoded = try InkCodec.decodeEvent(oldSheetBytes[...])
        XCTAssertEqual(decoded, .addSheet(old))
        guard case .addSheet(let sheet) = decoded else { return XCTFail("not a sheet") }
        XCTAssertFalse(sheet.fitted)
        XCTAssertTrue(sheet.offersScaleChange)
        XCTAssertEqual(InkCodec.encode(decoded), oldSheetBytes, "read and written again, byte for byte")
    }

    func testTheMarkIsOneBitOfTheFlagsByteAndRoundTrips() throws {
        let fitted = Sheet(id: SheetID(9), paper: .letter, scale: .notToScale, invertsBadly: true, fitted: true)
        var expected = oldSheetBytes
        expected[21] = 1 | 4
        let bytes = InkCodec.encode(.addSheet(fitted))
        XCTAssertEqual(bytes, expected, "the same 24 bytes, bit 2 of the flags set")
        XCTAssertEqual(try InkCodec.decodeEvent(bytes[...]), .addSheet(fitted))

        // Turned, with a page: the angle still follows the areas, and the mark still reads back.
        let turned = Sheet(id: SheetID(3), paper: .inches(11, by: 8.5), scale: .notToScale,
                           origin: CanvasPoint(x: .feet(20), y: .feet(-3)).onInkGrid, page: page, angle: 33.5,
                           fitted: true)
        let turnedBytes = InkCodec.encode(.addSheet(turned))
        guard case .addSheet(let back) = try InkCodec.decodeEvent(turnedBytes[...]) else { return XCTFail("not a sheet") }
        XCTAssertEqual(back, turned)
        XCTAssertTrue(back.fitted)
        XCTAssertEqual(back.angle, 33.5)
        XCTAssertEqual(turnedBytes.count, InkCodec.encode(.addSheet(Sheet(
            id: SheetID(3), paper: turned.paper, scale: .notToScale, origin: turned.origin, page: page, angle: 33.5))).count,
                       "the mark costs no byte")
    }

    /// The mark survives the snapshot (what compaction and sync upload) and a relaunch from the log and the snapshot.
    func testTheMarkSurvivesTheSnapshotAndARelaunch() throws {
        var session = InkSession()
        session.draw([CanvasPoint(x: .feet(1), y: .feet(1)), CanvasPoint(x: .feet(2), y: .feet(1))], tool: .pen,
                     colour: .red, width: .inches(0.5))
        let placed = session.addSheet(fittedSheet(at: CanvasPoint(x: .feet(20), y: .feet(-3))))
        session.addSheet(Sheet(paper: .letter, scale: .notToScale, origin: CanvasPoint(x: .feet(50), y: .zero)))
        XCTAssertTrue(placed.fitted)

        let decoded = try InkCodec.decodeSession(InkCodec.encode(session)[...])
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.sheets.map(\.fitted), [true, false])

        let store = try InkStore(folder: folder)
        try store.append(session.takeEvents())
        try store.flush()
        store.closeFiles()
        let reopened = try InkStore(folder: folder)
        XCTAssertEqual(reopened.session.sheets.map(\.fitted), [true, false])
        XCTAssertEqual(reopened.session, session)
        try reopened.compact()
        reopened.closeFiles()
        let fromSnapshot = try InkStore(folder: folder)
        defer { fromSnapshot.closeFiles() }
        XCTAssertEqual(fromSnapshot.session.sheets.map(\.fitted), [true, false])
        XCTAssertEqual(fromSnapshot.session, session)
    }

    /// Open in a new canvas writes the sheet with its mark, and the canvas opens with it.
    func testOpenInANewCanvasKeepsTheMark() throws {
        let library = CanvasLibrary(root: folder.appendingPathComponent("Canvases"))
        let pdf = folder.appendingPathComponent("download.pdf")
        try Data("%PDF-1.4 made up for the test\n%%EOF\n".utf8).write(to: pdf)
        let canvas = try library.create(name: "M-101 Made-up model", sheet: fittedSheet(), pdf: pdf,
                                        keptName: "madeupfit01")
        let store = try InkStore(folder: library.folder(for: canvas.id))
        defer { store.closeFiles() }
        XCTAssertEqual(store.session.sheets.count, 1)
        XCTAssertTrue(store.session.sheets[0].fitted)
        XCTAssertEqual(store.session.sheets[0].scale, .notToScale)
    }

    // MARK: No scale

    func testAFittedSheetOffersNoScaleChangeAndTheModelRefusesOne() {
        let sheet = fittedSheet()
        XCTAssertFalse(sheet.offersScaleChange)
        XCTAssertEqual(sheet.scale, .notToScale)
        XCTAssertEqual(sheet.areas, [])

        // Made with a scale and areas, it is still NTS with none.
        let forced = Sheet(paper: .inches(11, by: 8.5), scale: .drawn(.ratio(50)),
                           areas: [ScaleArea(name: "Detail 1", rect: .inches(x: 1, y: 1, width: 2, height: 2),
                                             scale: .drawn(.architectural(inchesPerFoot: 1)))],
                           fitted: true)
        XCTAssertEqual(forced.scale, .notToScale)
        XCTAssertEqual(forced.areas, [])

        // Rescaling it gives it back as it was, moving nothing.
        let quarter = Sheet.Scale.drawn(.architectural(inchesPerFoot: 0.25))
        let area = ScaleArea(name: "Detail 2", rect: .inches(x: 1, y: 1, width: 2, height: 2), scale: quarter)
        let rescaled = sheet.rescaled(to: quarter, areas: [area])
        XCTAssertEqual(rescaled.sheet, sheet)
        XCTAssertTrue(rescaled.motion.isIdentity)

        // The session refuses a scale change however it is made: from a sheet built by hand, or as an event from sync.
        var session = InkSession()
        let placed = session.addSheet(sheet)
        XCTAssertEqual(session.takeEvents().count, 1)
        var scaled = Sheet(id: placed.id, paper: placed.paper, scale: quarter, origin: placed.origin, page: placed.page)
        scaled.areas = [area]
        XCTAssertFalse(session.changeSheet(to: scaled, motion: SheetMotion(centre: placed.centre, scale: 48)))
        let areasOnly = Sheet(id: placed.id, paper: placed.paper, scale: .notToScale, origin: placed.origin,
                              page: placed.page, areas: [area])
        XCTAssertFalse(session.changeSheet(to: areasOnly, motion: SheetMotion(centre: placed.centre)))
        XCTAssertTrue(session.takeEvents().isEmpty, "a refused change writes nothing to the log")
        let event = InkEvent.changeSheet(SheetChange(id: placed.id, origin: placed.origin, angle: 0,
                                                     rescaled: .init(scale: quarter, areas: []), markups: .empty,
                                                     motion: SheetMotion(centre: placed.centre, scale: 48)))
        XCTAssertTrue(session.apply(event).isEmpty)
        XCTAssertEqual(session.sheets, [placed])
        XCTAssertEqual(session.sheets[0].scale, .notToScale)

        // A sheet that is not fitted still changes scale as before.
        let plain = session.addSheet(Sheet(paper: .letter, scale: .notToScale, origin: CanvasPoint(x: .feet(40), y: .zero)))
        XCTAssertTrue(plain.offersScaleChange)
        let change = plain.rescaled(to: quarter)
        XCTAssertTrue(session.changeSheet(to: change.sheet, motion: change.motion))
        XCTAssertEqual(session.sheet(plain.id)?.scale, quarter)
    }

    /// Moving, turning and undoing a fitted sheet work as before, and undo and redo never bring a scale.
    func testMovingTurningAndUndoKeepItNTS() throws {
        var session = InkSession()
        let placed = session.addSheet(fittedSheet(at: CanvasPoint(x: .feet(20), y: .feet(-3))))
        let turned = placed.turned(to: 90)
        XCTAssertTrue(session.changeSheet(to: turned.sheet, motion: turned.motion))
        let now = try XCTUnwrap(session.sheet(placed.id))
        let moved = now.moved(dx: .feet(5), dy: .feet(-2))
        XCTAssertTrue(session.changeSheet(to: moved.sheet, motion: moved.motion))
        XCTAssertEqual(session.sheet(placed.id)?.angle, 90)
        XCTAssertTrue(session.sheet(placed.id)?.fitted == true)
        for step in 0..<4 {
            if step < 2 { session.undo() } else { session.redo() }
            let sheet = try XCTUnwrap(session.sheet(placed.id))
            XCTAssertTrue(sheet.fitted, "step \(step)")
            XCTAssertEqual(sheet.scale, .notToScale, "step \(step)")
            XCTAssertEqual(sheet.areas, [], "step \(step)")
        }
        XCTAssertEqual(session.sheet(placed.id), moved.sheet)
        session.undo()
        session.undo()
        XCTAssertEqual(session.sheet(placed.id), placed)
        session.undo()
        XCTAssertNil(session.sheet(placed.id), "undoing the placing takes it away")
        session.redo()
        XCTAssertEqual(session.sheet(placed.id), placed)
        // The history, read back from the snapshot, still holds a fitted sheet only.
        let decoded = try InkCodec.decodeSession(InkCodec.encode(session)[...])
        XCTAssertEqual(decoded, session)
        var redone = decoded
        redone.redo()
        redone.redo()
        XCTAssertEqual(redone.sheet(placed.id), moved.sheet)
        XCTAssertTrue(redone.sheet(placed.id)?.fitted == true)
    }

    // MARK: Lengths

    /// On a fitted 11" × 8.5" sheet at 20'-0", -3'-0", whose title block said 1/4" = 1'-0", a printed 3" reads 3" NTS
    /// (never 12'-0"), a 3-4-5 diagonal 5" NTS, and a printed 3 1/2" 3 1/2" NTS; the same after it is saved and reopened.
    func testLengthsOnItReadAsPrintedLengthsMarkedNTSBeforeAndAfterAReload() throws {
        var session = InkSession()
        let placed = session.addSheet(fittedSheet(at: CanvasPoint(x: .feet(20), y: .feet(-3))))
        XCTAssertEqual(placed.size, CanvasSize(width: .inches(11), height: .inches(8.5)))

        func check(_ sheet: Sheet, _ label: String) {
            let canvas = Canvas(sheets: [sheet])
            func at(_ x: Double, _ y: Double) -> CanvasPoint { sheet.canvasPoint(at: PaperPoint(x: .inches(x), y: .inches(y))) }
            let across = canvas.measure(from: at(1, 1), to: at(4, 1))
            XCTAssertEqual(across, .notToScale(.inches(3)), label)
            XCTAssertNil(across.realLength, label)
            XCTAssertEqual(canvas.format(across), "3\" NTS", label)
            XCTAssertEqual(canvas.format(canvas.measure(from: at(1, 1), to: at(4, 5))), "5\" NTS", label)
            XCTAssertEqual(canvas.format(canvas.measure(from: at(1, 6), to: at(4.5, 6))), "3 1/2\" NTS", label)
            let dimension = CanvasDimension.pulled(id: DimensionID(1), start: at(1, 1), end: at(4, 1),
                                                   through: at(2.5, 0.5), colour: .sketch, textHeight: .inches(0.125))
            XCTAssertEqual(canvas.format(canvas.measure(dimension)), "3\" NTS", label)
        }
        check(placed, "before")

        let store = try InkStore(folder: folder)
        try store.append(session.takeEvents())
        try store.flush()
        store.closeFiles()
        let reopened = try InkStore(folder: folder)
        defer { reopened.closeFiles() }
        check(try XCTUnwrap(reopened.session.sheets.first), "after a reload")
    }
}
