import Foundation
import XCTest
@testable import VellumCore

// Opening a drawing from search in the viewer and placing it on a canvas (#69). The drawings are the laptop indexer's
// made-up fixture index (laptop/tests/fixtures/drawing-index) and made-up title blocks; nothing here is anyone's drawing.
final class DrawingOpeningTests: XCTestCase {
    // MARK: Which PDF opens

    func testAnEntryOpensItsOwnPDF() {
        let entry = IndexFixture.entry("M-101")
        let pdf = DrawingOpening.pdf(for: entry)
        XCTAssertEqual(pdf, DrawingOpening.PDF(
            path: "/Projects/Made-up School Addition/Mechanical/PDF/Issued set 2026-10-12.pdf",
            name: "Issued set 2026-10-12.pdf", contentHash: entry.pdf?.contentHash, size: 1193, pages: 1))
        XCTAssertEqual(pdf?.keptName, entry.pdf?.contentHash)
    }

    func testEachLayoutOfADWGWithSeveralOpensItsOwnLayoutsPDF() {
        // Pump house.dwg has two titled layouts, two drawings, one DWG.
        let e210 = IndexFixture.entry("E-210"), e211 = IndexFixture.entry("E-211")
        XCTAssertEqual(e210.dwg, e211.dwg)
        XCTAssertEqual(e210.path, e211.path)
        XCTAssertEqual(DrawingOpening.pdf(for: e210)?.path, "/Projects/Made-up Plant Upgrade/Electrical/PDF/Pump house-E-210.pdf")
        XCTAssertEqual(DrawingOpening.pdf(for: e211)?.path, "/Projects/Made-up Plant Upgrade/Electrical/PDF/Pump house-E-211.pdf")
        XCTAssertEqual(DrawingOpening.pdf(for: e210)?.name, "Pump house-E-210.pdf")
        XCTAssertEqual(DrawingOpening.pdf(for: e210)?.size, 1189)
        XCTAssertNotEqual(DrawingOpening.pdf(for: e210)?.keptName, DrawingOpening.pdf(for: e211)?.keptName)
    }

    func testAMultiPagePDFSaysItsPages() {
        XCTAssertEqual(DrawingOpening.pdf(for: IndexFixture.entry("M-501"))?.pages, 3)
    }

    func testADWGWithNoPlotHasNoPDFToOpen() {
        let entry = IndexFixture.entry("E-201")
        XCTAssertNil(entry.pdf)
        XCTAssertNil(DrawingOpening.pdf(for: entry))
        XCTAssertEqual(DrawingOpening.decide(entry, online: true, pdfsOnThisDuo: []), .noPDFYet)
        XCTAssertEqual(DrawingOpening.decide(entry, online: false, pdfsOnThisDuo: []), .noPDFYet)
    }

    func testAPDFTheLaptopHasNotReadOpensByItsPathOnline() {
        // I-302's PDF is online-only on the laptop: no hash yet, but Dropbox has it, so online it downloads.
        let entry = IndexFixture.entry("I-302")
        let pdf = DrawingOpening.pdf(for: entry)!
        XCTAssertNil(pdf.contentHash)
        XCTAssertNil(pdf.keptName)
        XCTAssertEqual(DrawingOpening.decide(entry, online: true, pdfsOnThisDuo: []), .download(pdf))
        XCTAssertEqual(DrawingOpening.decide(entry, online: false, pdfsOnThisDuo: []), .notOnThisDuo(pdf))
    }

    // MARK: Offline, and not on this Duo

    func testAPDFOnTheDuoOpensWithNoDownloadOnlineOrOff() {
        let entry = IndexFixture.entry("E-210")
        let pdf = DrawingOpening.pdf(for: entry)!
        let kept: Set<String> = [pdf.keptName!]
        XCTAssertEqual(DrawingOpening.decide(entry, online: true, pdfsOnThisDuo: kept), .openKept(pdf))
        XCTAssertEqual(DrawingOpening.decide(entry, online: false, pdfsOnThisDuo: kept), .openKept(pdf))
    }

    func testAPDFNeverOpenedDownloadsOnlineAndIsNotOnThisDuoOffline() {
        let entry = IndexFixture.entry("E-210")
        let pdf = DrawingOpening.pdf(for: entry)!
        let other: Set<String> = [DrawingOpening.pdf(for: IndexFixture.entry("E-211"))!.keptName!]
        XCTAssertEqual(DrawingOpening.decide(entry, online: true, pdfsOnThisDuo: other), .download(pdf))
        XCTAssertEqual(DrawingOpening.decide(entry, online: false, pdfsOnThisDuo: other), .notOnThisDuo(pdf))
        XCTAssertEqual(DrawingOpening.notOnThisDuoText(number: "E-210"),
                       "E-210's PDF isn't on this Duo yet. It downloads when you're back online; searching works offline.")
        XCTAssertEqual(DrawingOpening.notOnThisDuoText(number: nil),
                       "This drawing's PDF isn't on this Duo yet. It downloads when you're back online; searching works offline.")
    }

    /// The viewer refuses exactly the rows that say "Not on this Duo", for every fixture entry, online and off, with
    /// none, some or all of their PDFs on the Duo.
    func testTheViewerRefusesExactlyTheRowsMarkedNotOnThisDuo() {
        let entries = IndexFixture.entries
        let all = Set(entries.compactMap { DrawingOpening.pdf(for: $0)?.keptName })
        let some = Set(all.sorted().prefix(3))
        var refused = 0
        for kept in [Set<String>(), some, all] {
            for online in [true, false] {
                for entry in entries {
                    let marked = DrawingMarker.of(entry, online: online, pdfsOnThisDuo: kept).contains(.notOnThisDuo)
                    var decided = false
                    if case .notOnThisDuo = DrawingOpening.decide(entry, online: online, pdfsOnThisDuo: kept) {
                        decided = true
                        refused += 1
                    }
                    XCTAssertEqual(decided, marked, "\(entry.number ?? entry.name) online \(online), \(kept.count) kept")
                }
            }
        }
        // Offline with nothing kept, the eight entries with a PDF; offline with three kept, five; with all kept, only
        // I-302, whose PDF has no hash yet.
        XCTAssertEqual(entries.filter { $0.pdf != nil }.count, 8)
        XCTAssertEqual(all.count, 7)
        XCTAssertEqual(refused, 8 + 5 + 1)
    }

    // MARK: The index's scale text

    func testTheIndexScaleTextIsParsedInEveryFormItCanTake() {
        let quarter = Sheet.Scale.drawn(.architectural(inchesPerFoot: 0.25))
        // Architectural
        XCTAssertEqual(DrawingOpening.scale(indexText: "1/4\" = 1'-0\""), quarter)
        XCTAssertEqual(DrawingOpening.scale(indexText: "1/4\"=1'-0\""), quarter)
        XCTAssertEqual(DrawingOpening.scale(indexText: "SCALE: 1/4\" = 1'-0\""), quarter)
        XCTAssertEqual(DrawingOpening.scale(indexText: "1/4″ = 1′-0″"), quarter)
        XCTAssertEqual(DrawingOpening.scale(indexText: "1/8\" = 1'-0\""), .drawn(.architectural(inchesPerFoot: 0.125)))
        XCTAssertEqual(DrawingOpening.scale(indexText: "1 1/2\" = 1'-0\""), .drawn(.architectural(inchesPerFoot: 1.5)))
        XCTAssertEqual(DrawingOpening.scale(indexText: "3/32\" = 1'-0\""), .drawn(.architectural(inchesPerFoot: 0.09375)))
        // Engineering
        XCTAssertEqual(DrawingOpening.scale(indexText: "1\" = 20'"), .drawn(.engineering(feetPerInch: 20)))
        XCTAssertEqual(DrawingOpening.scale(indexText: "1\" = 20'-0\""), .drawn(.engineering(feetPerInch: 20)))
        XCTAssertEqual(DrawingOpening.scale(indexText: "1\"=100'"), .drawn(.engineering(feetPerInch: 100)))
        // Metric ratios
        XCTAssertEqual(DrawingOpening.scale(indexText: "1:20"), .drawn(.ratio(20)))
        XCTAssertEqual(DrawingOpening.scale(indexText: "1:50"), .drawn(.ratio(50)))
        XCTAssertEqual(DrawingOpening.scale(indexText: " 1 : 100 "), .drawn(.ratio(100)))
        XCTAssertEqual(DrawingOpening.scale(indexText: "FULL SIZE"), .drawn(.fullSize))
        // Not to scale
        for nts in ["NTS", "N.T.S.", "nts", "NOT TO SCALE", "SCALE: NTS"] {
            XCTAssertEqual(DrawingOpening.scale(indexText: nts), .notToScale, nts)
        }
        // Asks: AS NOTED and its kin, blank, missing, garbage
        for asks in ["AS NOTED", "as noted", "SCALE: AS NOTED", "AS SHOWN", "AS INDICATED", "VARIES", "", "   ",
                     "1/4 = 1", "1:", ":20", "1/4\" = ", "SEE PLAN", "1/4\" = 1'-0\" & 1:20", "1/4\" = 1'-0\" AS NOTED",
                     "nan:1", "-1:20"] {
            XCTAssertNil(DrawingOpening.scale(indexText: asks), asks)
        }
        XCTAssertNil(DrawingOpening.scale(indexText: nil))
    }

    func testEveryFixtureScaleIsReadAsTheIndexWritesIt() {
        let read = Dictionary(uniqueKeysWithValues: IndexFixture.entries.compactMap { entry in
            entry.number.map { ($0, DrawingOpening.scale(indexText: entry.scale)) }
        })
        XCTAssertEqual(read["M-101"], .drawn(.architectural(inchesPerFoot: 0.25)))
        XCTAssertEqual(read["E-210"], .drawn(.ratio(20)))
        XCTAssertEqual(read["E-211"], .drawn(.ratio(50)))
        XCTAssertEqual(read["I-301"], .notToScale)
        XCTAssertEqual(read["V-12"], .drawn(.ratio(20)))
        XCTAssertEqual(read["M-501"], .some(nil), "AS NOTED asks")
    }

    // MARK: Placed from search lands as placed through Add sheet

    /// A made-up 36 × 24 title block's scale line, bottom right.
    private func titleBlock(_ number: String, scale: String) -> [PageText] {
        [.at(31, 22.6, scale, width: 2.4, height: 0.14), .at(31, 23.0, number, width: 1, height: 0.3)]
    }

    /// The sheet Add sheet's confirm step places: from the PDF it listed (`DropboxFile`), at the scale it read, or the
    /// scale picked when it asks.
    private func addSheetSheet(_ reading: SheetReading, file: DropboxFile, page: Int, picked: Sheet.Scale? = nil) -> Sheet {
        let scale = reading.asksForScale ? picked! : reading.suggestedScale!
        return reading.sheet(placedAt: scale,
                             page: SheetPage(file: file.keptName, name: file.name, path: file.path, index: page,
                                             number: reading.sheetNumber),
                             invertsBadly: false)
    }

    /// The sheet the viewer places: the index entry's scale text parsed, or the scale picked when it asks.
    private func searchSheet(_ entry: DrawingEntry, reading: SheetReading, page: Int, picked: Sheet.Scale? = nil)
        -> (sheet: Sheet, asked: Bool) {
        let pdf = DrawingOpening.pdf(for: entry)!
        let read = DrawingOpening.scale(indexText: entry.scale)
        let sheet = DrawingOpening.sheet(entry, pdf: pdf, keptName: pdf.keptName!, page: page, reading: reading,
                                         scale: read ?? picked!, invertsBadly: false)
        return (sheet, read == nil)
    }

    /// The same PDF as Add sheet lists it: the path, name, size and hash the index gives.
    private func listed(_ entry: DrawingEntry) -> DropboxFile {
        let pdf = DrawingOpening.pdf(for: entry)!
        return DropboxFile(id: "id:madeup", name: pdf.name, path: pdf.path, size: pdf.size!, contentHash: pdf.contentHash!,
                           rev: "madeup1")
    }

    private func entry(number: String, scale: String, pages: Int = 1) -> DrawingEntry {
        DrawingEntry(id: number.lowercased(), path: "/Projects/Made-up/CAD/\(number).dwg", name: "\(number).dwg",
                     layout: "Layout1", number: number, title: "Made-up \(number)", revision: "A", scale: scale,
                     dwg: .init(path: "/Projects/Made-up/CAD/\(number).dwg"),
                     pdf: .init(path: "/Projects/Made-up/PDF/\(number).pdf", size: 4096,
                                contentHash: "madeup" + String(repeating: "0", count: 52) + number.filter(\.isNumber),
                                pages: pages, paperInches: [36, 24]))
    }

    func testAQuarterInchPlanLandsTheSameFromSearchAsFromAddSheet() {
        let page = MadeUpSheets.quarterInchPlan
        let reading = SheetReading.read(page.texts, paper: page.paper)
        let entry = entry(number: "M-101", scale: "1/4\" = 1'-0\"")
        let fromSearch = searchSheet(entry, reading: reading, page: 0)
        let fromAddSheet = addSheetSheet(reading, file: listed(entry), page: 0)
        XCTAssertFalse(fromSearch.asked)
        XCTAssertEqual(fromSearch.sheet, fromAddSheet)
        XCTAssertEqual(fromSearch.sheet.scale, .drawn(.architectural(inchesPerFoot: 0.25)))
        // 36" × 24" at 48 real inches a printed inch: 144'-0" × 96'-0".
        XCTAssertEqual(fromSearch.sheet.size, CanvasSize(width: .inches(1728), height: .inches(1152)))
        XCTAssertEqual(fromSearch.sheet.size.width, .feet(144))
        XCTAssertEqual(fromSearch.sheet.areas, [])
        XCTAssertEqual(fromSearch.sheet.page, SheetPage(file: listed(entry).keptName, name: "M-101.pdf",
                                                         path: "/Projects/Made-up/PDF/M-101.pdf", index: 0, number: "M-101"))
        // Its printed 6" dimension reads 24'-0" on the canvas either way.
        XCTAssertEqual(Length(inches: 6 * fromSearch.sheet.canvasPerPrinted), .feet(24))
    }

    func testAOneToTwentySheetLandsTheSameFromSearchAsFromAddSheet() {
        let reading = SheetReading.read(titleBlock("E-210", scale: "SCALE: 1:20"), paper: .inches(36, by: 24))
        let entry = entry(number: "E-210", scale: "1:20")
        let fromSearch = searchSheet(entry, reading: reading, page: 0)
        XCTAssertFalse(fromSearch.asked)
        XCTAssertEqual(fromSearch.sheet, addSheetSheet(reading, file: listed(entry), page: 0))
        XCTAssertEqual(fromSearch.sheet.scale, .drawn(.ratio(20)))
        // 36" × 24" at 20: 720" × 480", 18.288 m × 12.192 m.
        XCTAssertEqual(fromSearch.sheet.size, CanvasSize(width: .inches(720), height: .inches(480)))
        XCTAssertEqual(fromSearch.sheet.size.width.inches * 25.4, 18_288, accuracy: 1e-9)
        XCTAssertEqual(fromSearch.sheet.areas, [])
        XCTAssertEqual(fromSearch.sheet.page?.number, "E-210")
    }

    func testAnNTSSheetLandsAtItsPrintedSizeFromSearchAsFromAddSheet() {
        let page = MadeUpSheets.loopDiagram
        let reading = SheetReading.read(page.texts, paper: page.paper)
        let entry = entry(number: "L-1042", scale: "NTS")
        let fromSearch = searchSheet(entry, reading: reading, page: 0)
        XCTAssertFalse(fromSearch.asked)
        XCTAssertEqual(fromSearch.sheet, addSheetSheet(reading, file: listed(entry), page: 0))
        XCTAssertEqual(fromSearch.sheet.scale, .notToScale)
        XCTAssertTrue(fromSearch.sheet.isNotToScale)
        // An NTS sheet: its 11" × 8.5" paper, on the canvas at printed size.
        XCTAssertEqual(fromSearch.sheet.size, CanvasSize(width: .inches(11), height: .inches(8.5)))
        XCTAssertEqual(fromSearch.sheet.areas, [])
    }

    // MARK: A plot fitted to the page (#92)

    /// A made-up Model-tab DWG's entry whose title block says 1/4" = 1'-0", with its plot on an 11" × 8.5" sheet, fitted
    /// to the page or not.
    private func modelTabEntry(fitted: Bool?) -> DrawingEntry {
        DrawingEntry(id: "0123456789abcdef", path: "/Projects/Made-up/CAD/M-101.dwg", name: "M-101.dwg", layout: "Model",
                     number: "M-101", title: "Made-up model", scale: "1/4\" = 1'-0\"",
                     dwg: .init(path: "/Projects/Made-up/CAD/M-101.dwg"),
                     pdf: .init(path: "/Vellum/Plots/Made-up/M-101 - Model - 2026-11-08 120000 - 0a1b2c3d.pdf",
                                size: 4096, contentHash: "madeup" + String(repeating: "0", count: 54) + "0101",
                                pages: 1, paperInches: [11, 8.5], fitted: fitted),
                     pairedBy: "plotted")
    }

    func testAFittedPlotPlacesAsAnNTSSheetAndItsLengthsReadPrintedMarkedNTS() {
        let entry = modelTabEntry(fitted: true)
        let pdf = DrawingOpening.pdf(for: entry)!
        XCTAssertTrue(pdf.fitted)
        // The header's scale and the confirm step are an NTS drawing's, whatever the title block says.
        XCTAssertEqual(DrawingOpening.scaleText(for: entry, pdf: pdf), "NTS")
        XCTAssertEqual(DrawingOpening.confirmation(for: entry).prefilled, .notToScale)
        XCTAssertEqual(DrawingOpening.confirmation(for: entry, pdf: pdf).prefilled, .notToScale)
        XCTAssertFalse(DrawingOpening.confirmation(for: entry).asks)
        XCTAssertEqual(DrawingOpening.note(for: pdf, plot: nil), "Plotted to fit, not to scale")

        let reading = SheetReading.read([], paper: .inches(11, by: 8.5))
        let sheet = DrawingOpening.sheet(entry, pdf: pdf, keptName: pdf.keptName!, page: 0, reading: reading,
                                         scale: DrawingOpening.confirmation(for: entry).prefilled!, invertsBadly: false)
        XCTAssertEqual(sheet.scale, .notToScale)
        XCTAssertTrue(sheet.isNotToScale)
        // On the canvas at its printed size: 11" × 8.5", one printed inch a canvas inch.
        XCTAssertEqual(sheet.size, CanvasSize(width: .inches(11), height: .inches(8.5)))
        XCTAssertEqual(sheet.canvasPerPrinted, 1)
        XCTAssertEqual(sheet.areas, [])
        // A printed 3 1/2" reads 3 1/2" NTS, never 14'-0".
        let placed = Sheet(paper: sheet.paper, scale: sheet.scale, origin: CanvasPoint(x: .feet(10), y: .feet(5)),
                           page: sheet.page)
        let canvas = Canvas(sheets: [placed])
        let measure = canvas.measure(from: placed.canvasPoint(at: PaperPoint(x: .inches(1), y: .inches(1))),
                                     to: placed.canvasPoint(at: PaperPoint(x: .inches(4.5), y: .inches(1))))
        XCTAssertNil(measure.realLength)
        XCTAssertEqual(measure, .notToScale(.inches(3.5)))
        XCTAssertEqual(canvas.format(measure), "3 1/2\" NTS")
    }

    func testAPlotNotFittedPlacesAtItsTitleBlocksScaleAsBefore() {
        let quarter = Sheet.Scale.drawn(.architectural(inchesPerFoot: 0.25))
        for fitted in [false, nil] as [Bool?] {
            let entry = modelTabEntry(fitted: fitted)
            let pdf = DrawingOpening.pdf(for: entry)!
            XCTAssertFalse(pdf.fitted)
            XCTAssertEqual(DrawingOpening.scaleText(for: entry, pdf: pdf), "1/4\" = 1'-0\"")
            XCTAssertEqual(DrawingOpening.confirmation(for: entry).prefilled, quarter)
            XCTAssertNil(DrawingOpening.note(for: pdf, plot: nil))
            let reading = SheetReading.read([], paper: .inches(11, by: 8.5))
            let sheet = DrawingOpening.sheet(entry, pdf: pdf, keptName: pdf.keptName!, page: 0, reading: reading,
                                             scale: quarter, invertsBadly: false)
            // 11" × 8.5" at 48 real inches a printed inch: 44'-0" × 34'-0".
            XCTAssertEqual(sheet.size, CanvasSize(width: .feet(44), height: .feet(34)))
            let canvas = Canvas(sheets: [sheet])
            let measure = canvas.measure(from: sheet.canvasPoint(at: PaperPoint(x: .inches(1), y: .inches(1))),
                                         to: sheet.canvasPoint(at: PaperPoint(x: .inches(4.5), y: .inches(1))))
            XCTAssertEqual(measure, .real(.feet(14)))
        }
    }

    func testTheIndexsFittedMarkIsReadAndAnIndexWithoutItReadsAsBefore() throws {
        func shard(_ pdf: String) -> [UInt8] {
            Array(("{\"format\":1,\"project\":null,\"projectPath\":null,\"drawings\":[{\"id\":\"0123456789abcdef\","
                + "\"path\":\"/Projects/Made-up/CAD/M-101.dwg\",\"name\":\"M-101.dwg\",\"layout\":\"Model\","
                + "\"scale\":\"1/4\\\" = 1'-0\\\"\",\"dwg\":{\"path\":\"/Projects/Made-up/CAD/M-101.dwg\",\"read\":true},"
                + "\"pdf\":\(pdf),\"otherPdfs\":[\"/Vellum/Plots/Made-up/M-101 - Model - old.pdf\"],"
                + "\"pairedBy\":\"plotted\"}]}").utf8)
        }
        let fitted = try DrawingIndexFormat.shard(from: shard(
            "{\"path\":\"/Vellum/Plots/Made-up/M-101 - Model - new.pdf\",\"read\":true,\"pages\":1,\"fitted\":true}"))
        let entry = try XCTUnwrap(fitted.drawings.first)
        XCTAssertEqual(entry.pdf?.fitted, true)
        XCTAssertEqual(entry.otherPdfs, ["/Vellum/Plots/Made-up/M-101 - Model - old.pdf"])
        XCTAssertEqual(DrawingOpening.confirmation(for: entry).prefilled, .notToScale)
        let before = try DrawingIndexFormat.shard(from: shard(
            "{\"path\":\"/Vellum/Plots/Made-up/M-101 - Model - old.pdf\",\"read\":true,\"pages\":1}"))
        let old = try XCTUnwrap(before.drawings.first)
        XCTAssertNil(old.pdf?.fitted)
        XCTAssertEqual(old.scale, "1/4\" = 1'-0\"")
        XCTAssertEqual(DrawingOpening.confirmation(for: old).prefilled, .drawn(.architectural(inchesPerFoot: 0.25)))
        // Every entry of the laptop's fixture index, written before #92, reads unfitted.
        XCTAssertTrue(IndexFixture.entries.allSatisfy { $0.pdf?.fitted == nil })
    }

    func testAnASNotedDrawingAsksAndGivenAnEighthLandsTheSameFromSearchAsFromAddSheet() {
        let page = MadeUpSheets.detailSheet
        let reading = SheetReading.read(page.texts, paper: page.paper)
        let entry = entry(number: "D-501", scale: "AS NOTED", pages: 3)
        let eighth = Sheet.Scale.drawn(.architectural(inchesPerFoot: 0.125))
        XCTAssertTrue(reading.asksForScale, "Add sheet asks too")
        let fromSearch = searchSheet(entry, reading: reading, page: 1, picked: eighth)
        XCTAssertTrue(fromSearch.asked)
        let fromAddSheet = addSheetSheet(reading, file: listed(entry), page: 1, picked: eighth)
        XCTAssertEqual(fromSearch.sheet, fromAddSheet)
        XCTAssertEqual(fromSearch.sheet.scale, eighth)
        // 17" × 11" at 96 real inches a printed inch: 136'-0" × 88'-0".
        XCTAssertEqual(fromSearch.sheet.size, CanvasSize(width: .inches(1632), height: .inches(1056)))
        // Every detail is at another scale than 1/8", so all three are scale areas, each reading its own scale.
        XCTAssertEqual(fromSearch.sheet.areas.map(\.name), ["Detail 1", "Detail 2", "Detail 3"])
        XCTAssertEqual(fromSearch.sheet.areas.map(\.scale), [.drawn(.architectural(inchesPerFoot: 1)),
                                                             .drawn(.architectural(inchesPerFoot: 1.5)), .notToScale])
        XCTAssertEqual(fromSearch.sheet.areas, fromAddSheet.areas)
        XCTAssertEqual(fromSearch.sheet.areas, reading.areas(placedAt: eighth))
        XCTAssertEqual(fromSearch.sheet.page?.index, 1)
        XCTAssertEqual(fromSearch.sheet.page?.number, "D-501")
    }

    func testASheetWithNoNumberReadTakesTheIndexsNumber() {
        let reading = SheetReading.read([.at(31, 22.6, "SCALE: 1:50", width: 2.4, height: 0.14)], paper: .inches(36, by: 24))
        XCTAssertNil(reading.sheetNumber)
        let entry = entry(number: "E-211", scale: "1:50")
        XCTAssertEqual(searchSheet(entry, reading: reading, page: 0).sheet.page?.number, "E-211")
    }

    // MARK: A new canvas's name

    func testANewCanvasIsNamedForTheDrawingsNumberAndTitle() {
        XCTAssertEqual(DrawingOpening.canvasName(for: IndexFixture.entry("E-210")), "E-210 Pump house power plan")
        XCTAssertEqual(DrawingOpening.canvasName(for: IndexFixture.entry("M-501")), "M-501 Mechanical details")
        var entry = IndexFixture.entry("E-210")
        entry.title = "  Pump house\n power plan "
        XCTAssertEqual(DrawingOpening.canvasName(for: entry), "E-210 Pump house power plan")
        entry.title = "E-210 Pump house power plan"
        XCTAssertEqual(DrawingOpening.canvasName(for: entry), "E-210 Pump house power plan", "the number once")
        entry.title = nil
        XCTAssertEqual(DrawingOpening.canvasName(for: entry), "E-210")
        entry.title = "Pump house power plan"
        entry.number = " "
        XCTAssertEqual(DrawingOpening.canvasName(for: entry), "Pump house power plan")
        entry.title = nil
        entry.number = nil
        XCTAssertEqual(DrawingOpening.canvasName(for: entry), "Pump house")
        entry.name = "Made-up loose sketch.PDF"
        XCTAssertEqual(DrawingOpening.canvasName(for: entry), "Made-up loose sketch")
        entry.name = ".dwg"
        XCTAssertEqual(DrawingOpening.canvasName(for: entry), CanvasName.untitled)
    }

    // MARK: Kept once, by its hash

    private func tempPDFs() throws -> SheetPDFs {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-viewer-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return SheetPDFs(folder: folder)
    }

    func testAPDFOpenedFromSearchIsKeptUnderItsHashAndNeverDownloadedAgain() async throws {
        let pdfs = try tempPDFs()
        let bytes = Data("%PDF-1.4 made-up viewer page".utf8)
        let hash = DropboxContentHash.of([UInt8](bytes))
        let downloads = DownloadCounter()
        let download: @Sendable () async throws -> DropboxDownload = {
            downloads.add()
            return DropboxDownload(bytes: bytes, contentHash: hash)
        }
        let first = try await pdfs.pdf(at: "/Made-up/E-210.pdf", contentHash: hash, size: bytes.count, download: download)
        XCTAssertEqual(first.keptName, hash)
        XCTAssertEqual(try Data(contentsOf: first.url), bytes)
        let again = try await pdfs.pdf(at: "/Made-up/E-210.pdf", contentHash: hash, size: bytes.count, download: download)
        XCTAssertEqual(again, first)
        XCTAssertEqual(downloads.value, 1)
        XCTAssertEqual(pdfs.bytesDownloaded, bytes.count)
        // Add sheet listing the same PDF finds the same file and downloads nothing.
        let listed = DropboxFile(id: "id:x", name: "E-210.pdf", path: "/Made-up/E-210.pdf", size: bytes.count,
                                 contentHash: hash, rev: "r1")
        XCTAssertTrue(pdfs.holds(listed))
        XCTAssertEqual(pdfs.url(for: listed), first.url)
    }

    func testAPDFChangedSinceTheIndexIsKeptUnderTheHashDropboxGives() async throws {
        let pdfs = try tempPDFs()
        let bytes = Data("%PDF-1.4 made-up, plotted again".utf8)
        let now = DropboxContentHash.of([UInt8](bytes))
        let kept = try await pdfs.pdf(at: "/Made-up/E-210.pdf", contentHash: "0123456789abcdef", size: 99) {
            DropboxDownload(bytes: bytes, contentHash: now)
        }
        XCTAssertEqual(kept.keptName, now)
        XCTAssertFalse(pdfs.holds(keptName: "0123456789abcdef", size: nil))
        // A reply that gives no hash is hashed here, as Dropbox would.
        let other = Data("%PDF-1.4 made-up, no header".utf8)
        let hashed = try await pdfs.pdf(at: "/Made-up/E-211.pdf", contentHash: nil, size: nil) {
            DropboxDownload(bytes: other, contentHash: nil)
        }
        XCTAssertEqual(hashed.keptName, DropboxContentHash.of([UInt8](other)))
    }

    func testTwoOpensOfOnePDFAtOnceShareOneDownload() async throws {
        let pdfs = try tempPDFs()
        let bytes = Data(repeating: 0x25, count: 4096)
        let downloads = DownloadCounter()
        let download: @Sendable () async throws -> DropboxDownload = {
            downloads.add()
            try await Task.sleep(nanoseconds: 50_000_000)
            return DropboxDownload(bytes: bytes, contentHash: nil)
        }
        async let a = pdfs.pdf(at: "/Made-up/Big.pdf", contentHash: nil, size: nil, download: download)
        async let b = pdfs.pdf(at: "/made-up/big.PDF", contentHash: nil, size: nil, download: download)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, second)
        XCTAssertEqual(downloads.value, 1)
    }

    // MARK: Found again by its path (review of #77)

    /// An entry whose PDF is at `path`, with `hash` as the index has it.
    private func indexed(path: String, hash: String?) -> DrawingEntry {
        DrawingEntry(id: "e-210", path: "/Made-up/E-210.dwg", name: "E-210.dwg", number: "E-210", scale: "1:20",
                     dwg: .init(path: "/Made-up/E-210.dwg"),
                     pdf: .init(path: path, size: 99, contentHash: hash, pages: 1, paperInches: [36, 24]))
    }

    private func openedOnceThenOffline(indexHash: String?) async throws {
        let pdfs = try tempPDFs()
        let bytes = Data("%PDF-1.4 made-up, plotted again since the index".utf8)
        let now = DropboxContentHash.of([UInt8](bytes))
        let entry = indexed(path: "/Made-up/PDF/E-210.pdf", hash: indexHash)
        let downloads = DownloadCounter()
        let download: @Sendable () async throws -> DropboxDownload = {
            downloads.add()
            return DropboxDownload(bytes: bytes, contentHash: now)
        }
        // Never opened: online it downloads, offline it doesn't open.
        XCTAssertEqual(DrawingOpening.decide(entry, online: false, pdfsOnThisDuo: [], pdfPathsOnThisDuo: pdfs.keptPaths()),
                       .notOnThisDuo(DrawingOpening.pdf(for: entry)!))
        let first = try await pdfs.pdf(at: entry.pdf!.path, contentHash: indexHash, size: 99, download: download)
        XCTAssertEqual(first.keptName, now)
        // Opened once: kept under the hash Dropbox gave, found by its path, online and off, with no second download.
        let hashes = Set([now]), paths = pdfs.keptPaths()
        XCTAssertEqual(paths, ["/made-up/pdf/e-210.pdf"])
        let pdf = DrawingOpening.pdf(for: entry)!
        XCTAssertEqual(DrawingOpening.decide(entry, online: false, pdfsOnThisDuo: hashes, pdfPathsOnThisDuo: paths),
                       .openKept(pdf))
        XCTAssertEqual(DrawingOpening.decide(entry, online: true, pdfsOnThisDuo: hashes, pdfPathsOnThisDuo: paths),
                       .openKept(pdf))
        XCTAssertFalse(DrawingMarker.of(entry, online: false, pdfsOnThisDuo: hashes, pdfPathsOnThisDuo: paths)
            .contains(.notOnThisDuo))
        let again = try await pdfs.pdf(at: "/made-up/PDF/E-210.PDF", contentHash: indexHash, size: 99, download: download)
        XCTAssertEqual(again, first)
        XCTAssertEqual(downloads.value, 1)
        // A fresh cache over the same folder, as after a relaunch, remembers the path too.
        let relaunched = SheetPDFs(folder: pdfs.folder)
        XCTAssertEqual(relaunched.keptPaths(), paths)
        XCTAssertEqual(relaunched.keptName(forPath: "/Made-up/PDF/E-210.pdf"), now)
        let afterRelaunch = try await relaunched.pdf(at: entry.pdf!.path, contentHash: indexHash, size: 99,
                                                     download: download)
        XCTAssertEqual(afterRelaunch, first)
        XCTAssertEqual(downloads.value, 1)
    }

    func testAPDFOpenedOnceWithAStaleIndexHashOpensAgainOfflineByItsPath() async throws {
        try await openedOnceThenOffline(indexHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    }

    func testAPDFOpenedOnceWithNoIndexHashOpensAgainOfflineByItsPath() async throws {
        try await openedOnceThenOffline(indexHash: nil)
    }

    /// Add sheet and the viewer asking for one path at once start one download between them.
    func testAddSheetAndTheViewerAskingForOnePathAtOnceShareOneDownload() async throws {
        let pdfs = try tempPDFs()
        let bytes = Data(repeating: 0x25, count: 2048)
        let hash = DropboxContentHash.of([UInt8](bytes))
        let file = DropboxFile(id: "id:1", name: "E-210.pdf", path: "/Made-up/PDF/E-210.pdf", size: bytes.count,
                               contentHash: hash, rev: "r1")
        let downloads = DownloadCounter()
        async let fromAddSheet = pdfs.pdf(for: file) {
            downloads.add()
            try await Task.sleep(nanoseconds: 100_000_000)
            return bytes
        }
        async let fromViewer = pdfs.pdf(at: "/made-up/pdf/e-210.pdf", contentHash: hash, size: bytes.count) {
            downloads.add()
            try await Task.sleep(nanoseconds: 100_000_000)
            return DropboxDownload(bytes: bytes, contentHash: hash)
        }
        let (url, kept) = try await (fromAddSheet, fromViewer)
        XCTAssertEqual(url, kept.url)
        XCTAssertEqual(kept.keptName, file.keptName)
        XCTAssertEqual(downloads.value, 1)
        XCTAssertEqual(pdfs.bytesDownloaded, bytes.count)
    }

    // MARK: Zach confirms the scale (review of #77)

    func testPlacingFromTheViewerConfirmsThePrefilledIndexScaleOrAsks() {
        let quarter = Sheet.Scale.drawn(.architectural(inchesPerFoot: 0.25))
        XCTAssertEqual(DrawingOpening.confirmation(for: IndexFixture.entry("M-101")).prefilled, quarter)
        XCTAssertFalse(DrawingOpening.confirmation(for: IndexFixture.entry("M-101")).asks)
        XCTAssertEqual(DrawingOpening.confirmation(for: IndexFixture.entry("E-210")).prefilled, .drawn(.ratio(20)))
        XCTAssertEqual(DrawingOpening.confirmation(for: IndexFixture.entry("I-301")).prefilled, .notToScale)
        XCTAssertNil(DrawingOpening.confirmation(for: IndexFixture.entry("M-501")).prefilled)
        XCTAssertTrue(DrawingOpening.confirmation(for: IndexFixture.entry("M-501")).asks)
        var unreadable = IndexFixture.entry("M-101")
        unreadable.scale = "1/4 = 1"
        XCTAssertTrue(DrawingOpening.confirmation(for: unreadable).asks)
    }

    // MARK: A new canvas with its sheet (review of #77)

    func testANewCanvasIsMadeWithItsSheetSavedBeforeItIsListed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-new-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = CanvasLibrary(root: root.appendingPathComponent("Canvases"))
        let pdf = root.appendingPathComponent("E-210.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("%PDF-1.4 made-up E-210".utf8)
        try bytes.write(to: pdf)
        let reading = SheetReading.read([.at(31, 22.6, "SCALE: 1:20", width: 2.4, height: 0.14)], paper: .inches(36, by: 24))
        let sheet = reading.sheet(placedAt: .drawn(.ratio(20)),
                                  page: SheetPage(file: "madeupe210", name: "E-210.pdf", path: "/Made-up/E-210.pdf", index: 0),
                                  invertsBadly: false)
        let made = try library.create(name: "E-210 Pump house power plan", sheet: sheet, pdf: pdf, keptName: "madeupe210")
        XCTAssertEqual(try library.list().map(\.id), [made.id])
        XCTAssertEqual(made.name, "E-210 Pump house power plan")
        let store = try library.openInk(made.id)
        defer { store.closeFiles() }
        let placed = try XCTUnwrap(store.session.sheets.first)
        XCTAssertEqual(store.session.sheets.count, 1)
        XCTAssertEqual(placed.scale, .drawn(.ratio(20)))
        XCTAssertEqual(placed.size, CanvasSize(width: .inches(720), height: .inches(480)))
        // In the middle of the canvas.
        XCTAssertEqual(placed.origin, CanvasPoint(x: .inches(-360), y: .inches(-240)))
        XCTAssertEqual(try Data(contentsOf: library.sheetPDF(named: "madeupe210", in: made.id)), bytes)
        // Nothing half made is left beside it.
        let names = try FileManager.default.contentsOfDirectory(atPath: library.root.path)
        XCTAssertEqual(names, [made.id.uuidString])
    }

    func testANewCanvasWhoseSheetCantBeSavedIsNeverListed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-new-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = CanvasLibrary(root: root.appendingPathComponent("Canvases"))
        let sheet = Sheet(paper: .inches(36, by: 24), scale: .drawn(.ratio(20)))
        XCTAssertThrowsError(try library.create(name: "E-210", sheet: sheet, pdf: root.appendingPathComponent("gone.pdf"),
                                                keptName: "gone"))
        XCTAssertEqual(try library.list(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.root.path), [])
    }

    func testADownloadThroughTheSessionReadsTheHashDropboxGives() async throws {
        let dropbox = MadeUpDropbox()
        let bytes = [UInt8]("%PDF-1.4 made-up E-210".utf8)
        dropbox.changeOnTheLaptop("/Projects/Made-up/PDF/E-210.pdf", to: bytes)
        let session = DropboxSession(appKey: DropboxAppKey(buildSetting: "madeupviewer01")!, transport: dropbox,
                                     store: DropboxMemoryTokenStore(DropboxTokens(accessToken: "made-up", refreshToken: "made-up",
                                                                                  expiresAt: .distantFuture)))
        let download = try await session.downloadPDF(path: "/Projects/Made-up/PDF/E-210.pdf")
        XCTAssertEqual(download, DropboxDownload(bytes: Data(bytes), contentHash: DropboxContentHash.of(bytes)))
        let missing = try await session.downloadPDF(path: "/Projects/Made-up/PDF/E-999.pdf")
        XCTAssertNil(missing)
    }
}

/// A count shared with a `@Sendable` closure.
private final class DownloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
