import XCTest
@testable import VellumCore

/// Fitting a sheet's labels (#35). The text sizes are SF semibold at 10 pt as the app measures them, rounded up; the
/// captures' `sheets.txt` prints the real ones beside the decision.
final class SheetLabelTests: XCTestCase {
    private let detail = MadeUpSheets.detailSheet
    private lazy var reading = SheetReading.read(detail.texts, paper: detail.paper)
    private let nameText = LabelSize(width: 38, height: 12)

    private func scaleSize(_ scale: Sheet.Scale) -> LabelSize {
        switch scale.description {
        case "NTS": LabelSize(width: 22, height: 12)
        case "1\" = 1'-0\"": LabelSize(width: 48, height: 12)
        default: LabelSize(width: 66, height: 12)
        }
    }

    /// D-501's scale areas at a zoom, in screen points of a sheet at (0, 0).
    private func areas(placedAt main: Sheet.Scale, pointsPerPrinted k: Double) -> [SheetLabelLayout.Area] {
        reading.areas(placedAt: main).map { area in
            SheetLabelLayout.Area(rect: LabelRect(x: area.rect.minX * k, y: area.rect.minY * k,
                                                  width: area.rect.width.inches * k, height: area.rect.height.inches * k),
                                  name: nameText, scale: scaleSize(area.scale))
        }
    }

    private func layout(placedAt main: Sheet.Scale, k: Double, sheetName: LabelSize? = nil) -> SheetLabelLayout {
        SheetLabelLayout.lay(sheet: LabelRect(x: 0, y: 0, width: 17 * k, height: 11 * k), sheetName: sheetName,
                             areas: areas(placedAt: main, pointsPerPrinted: k))
    }

    private let inch = Sheet.Scale.drawn(.architectural(inchesPerFoot: 1))
    private let halfInch = Sheet.Scale.drawn(.architectural(inchesPerFoot: 0.5))

    func testTwoLinesThenTheScaleAloneThenOnlyTheOutline() {
        let scale = LabelSize(width: 22, height: 12)
        XCTAssertEqual(SheetLabelLayout.fit(area: LabelSize(width: 46, height: 28), name: nameText, scale: scale), .twoLines)
        XCTAssertEqual(SheetLabelLayout.fit(area: LabelSize(width: 45.9, height: 28), name: nameText, scale: scale), .scaleAlone)
        XCTAssertEqual(SheetLabelLayout.fit(area: LabelSize(width: 46, height: 27.9), name: nameText, scale: scale), .scaleAlone)
        XCTAssertEqual(SheetLabelLayout.fit(area: LabelSize(width: 30, height: 16), name: nameText, scale: scale), .scaleAlone)
        XCTAssertEqual(SheetLabelLayout.fit(area: LabelSize(width: 29.9, height: 16), name: nameText, scale: scale), .outlineOnly)
        XCTAssertEqual(SheetLabelLayout.fit(area: LabelSize(width: 30, height: 15.9), name: nameText, scale: scale), .outlineOnly)
    }

    /// A scale wider than the name goes straight from two lines to the outline: part of it never shows.
    func testAWideScaleNeverFallsBackToPartOfItself() {
        let scale = LabelSize(width: 66, height: 12)
        XCTAssertEqual(SheetLabelLayout.fit(area: LabelSize(width: 74, height: 100), name: nameText, scale: scale), .twoLines)
        XCTAssertEqual(SheetLabelLayout.fit(area: LabelSize(width: 73, height: 100), name: nameText, scale: scale), .outlineOnly)
    }

    func testTheD501AtTheZoomsWhereEachApplies() {
        // At 1" = 1'-0": Detail 2 (1 1/2") and Detail 3 (NTS). Filling the Duo, both have two lines.
        XCTAssertEqual(layout(placedAt: inch, k: 44).areas.map(\.fit), [.twoLines, .twoLines])
        // Detail 3 keeps two lines after Detail 2, whose scale is the widest, has gone to its outline.
        let d2Narrower = layout(placedAt: inch, k: 15)
        XCTAssertEqual(d2Narrower.areas.map(\.fit), [.outlineOnly, .twoLines])
        XCTAssertEqual(layout(placedAt: inch, k: 10).areas.map(\.fit), [.outlineOnly, .scaleAlone])
        XCTAssertEqual(layout(placedAt: inch, k: 5).areas.map(\.fit), [.outlineOnly, .outlineOnly])
    }

    /// The capture's view: placed at 1/2" = 1'-0", Detail 1 also becomes a scale area, and all three states show at once.
    func testTwoLinesAndTheScaleAloneShowTogether() {
        let fits = layout(placedAt: halfInch, k: 13).areas.map(\.fit)
        XCTAssertEqual(fits, [.twoLines, .outlineOnly, .scaleAlone])
    }

    func testAScaleShownIsAlwaysWholeAndInsideItsArea() {
        for main in [inch, halfInch] {
            for k in stride(from: 1.0, through: 200, by: 0.5) {
                let all = areas(placedAt: main, pointsPerPrinted: k)
                let laid = layout(placedAt: main, k: k)
                for (area, placed) in zip(all, laid.areas) {
                    guard let box = placed.box else { continue }
                    XCTAssertTrue(area.rect.contains(box), "k \(k)")
                    XCTAssertGreaterThanOrEqual(box.width, area.scale.width + 8, "k \(k)")
                }
            }
        }
    }

    /// The kept layer scales everything alike during a pinch, so what fitted when drawn fits on screen until redrawn.
    func testAFittedLabelStaysInsideItsAreaWhileScaledByTheKeptLayer() {
        let drawn = areas(placedAt: inch, pointsPerPrinted: 20)
        let laid = layout(placedAt: inch, k: 20)
        for k in [0.5, 0.75, 1.3, 2] {
            for (area, placed) in zip(drawn, laid.areas) {
                guard let box = placed.box else { continue }
                let scaled = LabelRect(x: box.x * k, y: box.y * k, width: box.width * k, height: box.height * k)
                let areaOnScreen = LabelRect(x: area.rect.x * k, y: area.rect.y * k,
                                             width: area.rect.width * k, height: area.rect.height * k)
                XCTAssertTrue(areaOnScreen.contains(scaled), "scaled by \(k)")
            }
        }
    }

    func testASheetNarrowerThanItsNameHidesIt() {
        let box = LabelSize(width: 100, height: 17)
        let fits = SheetLabelLayout.lay(sheet: LabelRect(x: 10, y: 20, width: 112, height: 29), sheetName: box, areas: [])
        XCTAssertEqual(fits.sheetName, LabelRect(x: 16, y: 26, width: 100, height: 17))
        for sheet in [LabelRect(x: 10, y: 20, width: 111.9, height: 29), LabelRect(x: 10, y: 20, width: 112, height: 28.9)] {
            XCTAssertNil(SheetLabelLayout.lay(sheet: sheet, sheetName: box, areas: []).sheetName)
        }
    }

    /// A scale area starting in the sheet's corner: its label drops below the sheet's name, and they never overlap.
    func testAnAreaInTheSheetsCornerGoesBelowTheSheetsName() {
        let area = SheetLabelLayout.Area(rect: LabelRect(x: 0, y: 0, width: 200, height: 100), name: nameText,
                                         scale: LabelSize(width: 66, height: 12))
        let laid = SheetLabelLayout.lay(sheet: LabelRect(x: 0, y: 0, width: 400, height: 300),
                                        sheetName: LabelSize(width: 100, height: 17), areas: [area])
        XCTAssertEqual(laid.areas[0].fit, .twoLines)
        XCTAssertEqual(laid.areas[0].box?.y, 23)
        XCTAssertFalse(laid.sheetName!.intersects(laid.areas[0].box!))
    }

    /// With only room for one line under the name, the scale alone; with none, the outline.
    func testAnAreaUnderTheSheetsNameFallsBackWhenTheRoomRunsOut() {
        func fit(height: Double) -> ScaleAreaLabelFit {
            let area = SheetLabelLayout.Area(rect: LabelRect(x: 0, y: 0, width: 200, height: height), name: nameText,
                                             scale: LabelSize(width: 66, height: 12))
            return SheetLabelLayout.lay(sheet: LabelRect(x: 0, y: 0, width: 400, height: 300),
                                        sheetName: LabelSize(width: 100, height: 17), areas: [area]).areas[0].fit
        }
        XCTAssertEqual(fit(height: 51), .twoLines)
        XCTAssertEqual(fit(height: 39), .scaleAlone)
        XCTAssertEqual(fit(height: 38), .outlineOnly)
    }

    func testOneAreasLabelNeverCoversAnothers() {
        let wide = LabelSize(width: 66, height: 12)
        let overlapping = [
            SheetLabelLayout.Area(rect: LabelRect(x: 0, y: 0, width: 200, height: 100), name: nameText, scale: wide),
            SheetLabelLayout.Area(rect: LabelRect(x: 10, y: 5, width: 200, height: 100), name: nameText, scale: wide),
        ]
        let laid = SheetLabelLayout.lay(sheet: LabelRect(x: 0, y: 0, width: 400, height: 300), sheetName: nil, areas: overlapping)
        XCTAssertFalse(laid.areas[0].box!.intersects(laid.areas[1].box!))
        XCTAssertEqual(laid.areas[1].fit, .twoLines)
        XCTAssertEqual(laid.areas[1].box?.y, 28)
    }

    func testTheDisabledButtonColoursReachTheContrastInBothThemes() {
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(ChromeColourPair.disabledButton(dark: dark).contrast, 4.5, "dark \(dark)")
        }
        XCTAssertEqual(ChromeColourPair(text: 0xFFFFFF, fill: 0x000000).contrast, 21, accuracy: 0.001)
    }
}
