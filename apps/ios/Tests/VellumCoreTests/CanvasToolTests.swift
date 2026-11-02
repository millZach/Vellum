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
        XCTAssertEqual(CanvasTool.Group.allCases.map(\.tools), [
            [.pen, .highlighter, .eraser, .lineAndShape],
            [.lasso, .textBox],
            [.measure, .dimension, .frame, .window],
        ])
    }

    /// Since #8 every tool on the rail works, measure, dimension, frame and window included.
    func testEveryToolOnTheRailWorks() {
        XCTAssertEqual(CanvasTool.allCases.filter(\.isAvailable), CanvasTool.allCases)
        for tool in CanvasTool.allCases {
            XCTAssertNil(tool.comingIn, tool.title)
            XCTAssertFalse(tool.hint.hasPrefix("Not available yet"), tool.title)
        }
    }

    /// The #8 tools' hints say how they work: the snap and loupe, pulling a dimension off, the frame's scale.
    func testTheMeasureDimensionFrameAndWindowHintsSayHowTheyWork() {
        XCTAssertTrue(CanvasTool.measure.hint.contains("snaps"), CanvasTool.measure.hint)
        XCTAssertTrue(CanvasTool.dimension.hint.contains("above or below for horizontal"), CanvasTool.dimension.hint)
        XCTAssertTrue(CanvasTool.frame.hint.contains("drawing scale"), CanvasTool.frame.hint)
        XCTAssertTrue(CanvasTool.window.hint.contains("zoom to it"), CanvasTool.window.hint)
        XCTAssertNil(CanvasTool.measure.inkTool)
        XCTAssertNil(CanvasTool.frame.inkTool)
    }

    /// The pen, the highlighter and the line and shape tool (#7) leave ink; the line tool's is the pen's.
    func testThePensAndTheLineToolLeaveInk() {
        XCTAssertEqual(CanvasTool.pen.inkTool, .pen)
        XCTAssertEqual(CanvasTool.highlighter.inkTool, .highlighter)
        XCTAssertEqual(CanvasTool.lineAndShape.inkTool, .pen)
        XCTAssertNil(CanvasTool.eraser.inkTool)
        XCTAssertNil(CanvasTool.lasso.inkTool)
        XCTAssertNil(CanvasTool.textBox.inkTool)
    }

    /// The new tools' hints say how they work (#7): the pen's names the hold that snaps, the text box's the Pencil.
    func testTheNewToolsHintsSayHowTheyWork() {
        XCTAssertTrue(CanvasTool.pen.hint.contains("Hold still"), CanvasTool.pen.hint)
        XCTAssertTrue(CanvasTool.lasso.hint.contains("move, resize, duplicate or delete"), CanvasTool.lasso.hint)
        XCTAssertTrue(CanvasTool.textBox.hint.contains("write with the Pencil"), CanvasTool.textBox.hint)
        XCTAssertTrue(CanvasTool.lineAndShape.hint.contains("rectangle"), CanvasTool.lineAndShape.hint)
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

    func testTheSaveStateSaysTheCanvasIsOnThisDuoAndNeverClaimsDropbox() {
        XCTAssertEqual(SaveState.savedOnThisDuo.title, "Saved on this Duo")
        XCTAssertEqual(SaveState.saving.title, "Saving…")
        XCTAssertEqual(SaveState.notSaved(outOfSpace: true).title, "Not saved: this Duo is full")
        XCTAssertEqual(SaveState.notSaved(outOfSpace: false).title, "Not saved: will retry")
        XCTAssertEqual(SaveState.neverSaved.title, "Never saved")
        XCTAssertFalse(SaveState.neverSaved.isSaved)
        for state in [SaveState.savedOnThisDuo, .saving, .notSaved(outOfSpace: true), .notSaved(outOfSpace: false),
                      .neverSaved] {
            XCTAssertFalse(state.title.localizedCaseInsensitiveContains("dropbox"))
            XCTAssertFalse(state.title.localizedCaseInsensitiveContains("synced"))
        }
        XCTAssertTrue(SaveState.savedOnThisDuo.isSaved)
        XCTAssertFalse(SaveState.saving.isSaved)
    }
}

/// The status bar leaves the prompt about 170 points between the scale bar and the sheet count; a prompt longer than
/// about 28 characters is cut off there.
final class CanvasToolPromptTests: XCTestCase {
    func testTheWorkingToolsPromptsFitTheStatusBar() {
        for tool in CanvasTool.allCases where tool.isAvailable {
            for fingerDraws in [false, true] {
                for hasSelection in [false, true] {
                    let prompt = tool.prompt(fingerDraws: fingerDraws, hasSelection: hasSelection)
                    XCTAssertLessThanOrEqual(prompt.count, 28, prompt)
                }
            }
        }
    }

    /// Part way through a measure, dimension or window, the prompt says what comes next (#8), and fits.
    func testThePromptsPartWayThroughFitAndSayWhatComesNext() {
        let steps: [CanvasTool.Step] = [.start, .secondPoint, .pullOff, .chooseWindowAction, .placeSheet]
        for tool in CanvasTool.allCases {
            for step in steps {
                let prompt = tool.prompt(fingerDraws: false, hasSelection: false, step: step)
                XCTAssertLessThanOrEqual(prompt.count, 28, prompt)
            }
        }
        XCTAssertEqual(CanvasTool.lasso.prompt(fingerDraws: false, hasSelection: true, step: .placeSheet),
                       "Tap where the sheet goes", "placing a sheet comes before any tool's prompt (#11)")
        XCTAssertEqual(CanvasTool.measure.prompt(fingerDraws: false, hasSelection: false), "Measure: tap first point")
        XCTAssertEqual(CanvasTool.dimension.prompt(fingerDraws: false, hasSelection: false, step: .secondPoint),
                       "Tap the second point")
        XCTAssertEqual(CanvasTool.dimension.prompt(fingerDraws: false, hasSelection: false, step: .pullOff),
                       "Drag or tap to place line")
        XCTAssertEqual(CanvasTool.window.prompt(fingerDraws: false, hasSelection: false, step: .chooseWindowAction),
                       "Zoom or make a frame")
    }

    /// With something selected, the lasso's prompt says to drag it (#7); the other tools ignore a selection.
    func testTheLassoPromptSaysToDragASelection() {
        XCTAssertEqual(CanvasTool.lasso.prompt(fingerDraws: false, hasSelection: true), "Drag the selection")
        XCTAssertEqual(CanvasTool.lasso.prompt(fingerDraws: false, hasSelection: false), "Loop ink or text to select")
        XCTAssertEqual(CanvasTool.pen.prompt(fingerDraws: false, hasSelection: true), "Draw with the Pencil")
    }

    /// Draw with finger (#24): with the switch on, the pen and highlighter don't tell Zach to use the Pencil only.
    func testWithDrawWithFingerOnThePromptsNameTheFinger() {
        XCTAssertEqual(CanvasTool.pen.prompt(fingerDraws: false), "Draw with the Pencil")
        XCTAssertEqual(CanvasTool.highlighter.prompt(fingerDraws: false), "Highlight with the Pencil")
        for tool in [CanvasTool.pen, .highlighter] {
            XCTAssertTrue(tool.prompt(fingerDraws: true).contains("finger"), tool.prompt(fingerDraws: true))
        }
        for tool in CanvasTool.allCases where tool != .pen && tool != .highlighter {
            XCTAssertEqual(tool.prompt(fingerDraws: true), tool.prompt)
        }
    }
}
