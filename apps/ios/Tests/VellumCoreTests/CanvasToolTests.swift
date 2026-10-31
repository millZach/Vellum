import XCTest
@testable import VellumCore

/// The drafting rail's tools, the appearance setting and the sheet display rule (ADR-0011).
final class CanvasToolTests: XCTestCase {
    func testTheRailRunsInTheOrderADR0011Gives() {
        XCTAssertEqual(CanvasTool.allCases.map(\.title), [
            "Pen", "Highlighter", "Eraser", "Line and shape",
            "Lasso", "Text box",
            "Measure", "Dimension", "Frame", "Window",
        ])
        XCTAssertEqual(CanvasTool.allCases.map(\.group), [0, 0, 0, 0, 1, 1, 2, 2, 2, 2])
    }

    func testOnlyThePenHighlighterAndEraserWorkYetAndTheRestSaySo() {
        XCTAssertEqual(CanvasTool.allCases.filter(\.isAvailable), [.pen, .highlighter, .eraser])
        for tool in CanvasTool.allCases where !tool.isAvailable {
            XCTAssertTrue(tool.hint.hasPrefix("Not available yet"), tool.title)
        }
        XCTAssertEqual(CanvasTool.lassoTicket, 7)
        XCTAssertEqual(CanvasTool.measure.comingIn, 8)
    }

    func testOnlyThePenAndHighlighterLeaveInk() {
        XCTAssertEqual(CanvasTool.pen.inkTool, .pen)
        XCTAssertEqual(CanvasTool.highlighter.inkTool, .highlighter)
        XCTAssertNil(CanvasTool.eraser.inkTool)
    }

    func testEveryToolSaysWhatItExpectsNext() {
        for tool in CanvasTool.allCases { XCTAssertFalse(tool.prompt.isEmpty) }
    }

    func testTheAppearanceSettingFollowsTheDuoOrPinsIt() {
        XCTAssertEqual(AppearanceSetting.default, .system)
        XCTAssertTrue(AppearanceSetting.system.isDark(systemIsDark: true))
        XCTAssertFalse(AppearanceSetting.system.isDark(systemIsDark: false))
        XCTAssertFalse(AppearanceSetting.light.isDark(systemIsDark: true))
        XCTAssertTrue(AppearanceSetting.dark.isDark(systemIsDark: false))
    }

    func testSheetsInvertInDarkModeAndDimWhenTheyInvertBadly() {
        XCTAssertEqual(SheetDisplay.display(dark: false, invertsBadly: false), .asPrinted)
        XCTAssertEqual(SheetDisplay.display(dark: false, invertsBadly: true), .asPrinted)
        XCTAssertEqual(SheetDisplay.display(dark: true, invertsBadly: false), .inverted)
        XCTAssertEqual(SheetDisplay.display(dark: true, invertsBadly: true), .dimmed)
        XCTAssertFalse(SheetDisplay.inverted.paperIsLight)
        XCTAssertTrue(SheetDisplay.dimmed.paperIsLight)
    }

    func testTheCanvasSaysItIsNotSavedYet() {
        XCTAssertEqual(SaveState.notSavedYet.title, "Not saved yet")
    }
}

private extension CanvasTool {
    static var lassoTicket: Int? { CanvasTool.lasso.comingIn }
}
