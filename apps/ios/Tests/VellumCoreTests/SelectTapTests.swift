import XCTest
@testable import VellumCore

private func p(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .inches(x), y: .inches(y)) }

/// What a tap with Select picks up (#64), with exact numbers. Everything here is made up for the test. Most taps are at
/// one screen point to the canvas inch, so the 10-point reach is 10 inches and a text box's 4-point slack is 4 inches.
/// Coordinates and widths are powers of two apart, so the edge cases are exact in binary.
final class SelectTapTests: XCTestCase {
    /// Two sheets of letter paper at 1:48, 408 × 528 inches, the second laid over the first's bottom-right corner.
    private let under = Sheet(id: SheetID(1), paper: .letter, scale: .drawn(.ratio(48)), origin: p(200, 0))
    private let over = Sheet(id: SheetID(2), paper: .letter, scale: .drawn(.ratio(48)), origin: p(400, 300))

    private struct Scene {
        var ink = InkIndex()
        var texts: [TextBox] = []
        var dimensions: [CanvasDimension] = []
        var frames: [Frame] = []
        var sheets = SheetIndex()
    }

    /// A level stroke 1/4 inch wide, so its ink reaches 1/8 inch either side of its line.
    private func stroke(_ session: inout InkSession, from a: CanvasPoint, to b: CanvasPoint) -> StrokeID {
        session.draw([a, b], tool: .pen, colour: .red, width: .inches(0.25))!.id
    }

    private func pick(_ point: CanvasPoint, in canvas: Scene, pointsPerInch: Double = 1) -> SelectTap.Pick? {
        SelectTap.pick(at: point, pointsPerInch: pointsPerInch, ink: canvas.ink, texts: canvas.texts,
                       dimensions: canvas.dimensions, frames: canvas.frames, sheets: canvas.sheets)
    }

    // MARK: What a tap picks

    func testInkOverASheetIsPickedAndBarePaperPicksTheSheet() {
        var session = InkSession()
        let cloud = stroke(&session, from: p(300, 100), to: p(340, 100))
        let canvas = Scene(ink: InkIndex(session.ink), sheets: SheetIndex([under, over]))
        XCTAssertEqual(pick(p(320, 100), in: canvas), .stroke(cloud), "the ink on top, not the sheet under it")
        XCTAssertEqual(pick(p(320, 108), in: canvas), .stroke(cloud), "within reach of the ink")
        XCTAssertEqual(pick(p(320, 200), in: canvas), .sheet(SheetID(1)), "bare paper")
        XCTAssertNil(pick(p(1_000, 1_000), in: canvas), "empty canvas")
    }

    func testOverlappingSheetsPickTheTopmost() {
        let canvas = Scene(sheets: SheetIndex([under, over]))
        XCTAssertEqual(pick(p(500, 400), in: canvas), .sheet(SheetID(2)), "where they overlap, the one placed last")
        XCTAssertEqual(pick(p(300, 400), in: canvas), .sheet(SheetID(1)), "the one under, where it shows")
        XCTAssertEqual(pick(p(700, 700), in: canvas), .sheet(SheetID(2)))
        // A sheet turned a quarter: its paper is where it now stands, not where it was.
        let turned = Sheet(id: SheetID(3), paper: .letter, scale: .drawn(.ratio(48)), origin: p(2_000, 0))
            .turned(to: 90).sheet
        let alone = Scene(sheets: SheetIndex([turned]))
        XCTAssertEqual(pick(turned.centre.offsetBy(dx: .inches(250), dy: .zero), in: alone), .sheet(SheetID(3)),
                       "528 inches across once turned")
        XCTAssertNil(pick(turned.centre.offsetBy(dx: .zero, dy: .inches(250)), in: alone), "204 inches up and down")
    }

    /// A thin line can be tapped at any zoom: the reach is 10 screen points from the ink's edge, however far that is on
    /// the canvas.
    func testAThinStrokeIsHitWithinTheReachInScreenPoints() {
        var session = InkSession()
        let line = stroke(&session, from: p(0, 0), to: p(100, 0))
        let canvas = Scene(ink: InkIndex(session.ink))
        // At 1 point to the inch: 10 inches of reach and 1/8 of ink.
        XCTAssertEqual(pick(p(50, 10.125), in: canvas), .stroke(line), "at the reach's edge")
        XCTAssertNil(pick(p(50, 10.25), in: canvas), "just past it")
        XCTAssertEqual(pick(p(-10.125, 0), in: canvas), .stroke(line), "past its end, as far")
        // Four times closer, 2 1/2 inches of reach.
        XCTAssertEqual(pick(p(50, -2.625), in: canvas, pointsPerInch: 4), .stroke(line))
        XCTAssertNil(pick(p(50, -2.75), in: canvas, pointsPerInch: 4))
        // A thousand times further out, 10,000 inches: a hairline across a plant is still a tap away.
        XCTAssertEqual(pick(p(50, 10_000), in: canvas, pointsPerInch: 0.001), .stroke(line))
    }

    func testTheLatestStrokeIsOnTop() {
        var session = InkSession()
        _ = stroke(&session, from: p(0, 0), to: p(100, 0))
        let later = stroke(&session, from: p(0, 4), to: p(100, 4))
        XCTAssertEqual(pick(p(50, 2), in: Scene(ink: InkIndex(session.ink))), .stroke(later))
    }

    func testATextBoxIsPickedAnywhereOnItAndOverInk() {
        var session = InkSession()
        let under = stroke(&session, from: p(-210, 10), to: p(-140, 10))
        let box = TextBox(id: TextBoxID(1), origin: p(-200, 0), size: CanvasSize(width: .inches(50), height: .inches(20)),
                          fontSize: .inches(5), colour: .blue, text: "Made-up note")
        let canvas = Scene(ink: InkIndex(session.ink), texts: [box])
        XCTAssertEqual(pick(p(-180, 10), in: canvas), .text(TextBoxID(1)), "the text box lies over the ink through it")
        XCTAssertEqual(pick(p(-180, 18), in: canvas), .text(TextBoxID(1)), "on the box, off its text")
        XCTAssertEqual(pick(p(-180, 24), in: canvas), .text(TextBoxID(1)), "4 points below it")
        XCTAssertNil(pick(p(-180, 24.25), in: canvas), "just past that")
        XCTAssertEqual(pick(p(-145, 10), in: canvas), .stroke(under), "the ink past the box's slack")
    }

    /// A dimension 8'-4" long, its line level at y = 260 with 10-inch text: picked within reach of its line, or on the
    /// box its length sits in, 30 inches each way across and 15 up and down from the line's middle, and 4 more.
    func testADimensionIsPickedByItsLineAndByItsText() {
        let dimension = CanvasDimension.pulled(id: DimensionID(1), start: p(0, 300), end: p(100, 300), through: p(50, 260),
                                               colour: .blue, textHeight: .inches(10))
        XCTAssertEqual(dimension.orientation, .horizontal)
        let canvas = Scene(dimensions: [dimension])
        XCTAssertEqual(pick(p(95, 268), in: canvas), .dimension(DimensionID(1)), "on its line, far from its text")
        XCTAssertEqual(pick(p(100, 270), in: canvas), .dimension(DimensionID(1)), "at the reach's edge from its line")
        XCTAssertNil(pick(p(100, 270.25), in: canvas))
        XCTAssertEqual(pick(p(50, 241), in: canvas), .dimension(DimensionID(1)), "by its text, 19 inches off its line")
        XCTAssertNil(pick(p(50, 240.75), in: canvas), "past its text")
        XCTAssertNil(pick(p(0, 300), in: canvas), "a point it measures is not the dimension")
    }

    /// A frame of letter paper at 1:48, 408 × 528 inches: picked by its dashed edge, never by the middle of what it takes
    /// in, so the ink inside it can still be tapped.
    func testAFrameIsPickedByItsEdge() {
        var session = InkSession()
        let inside = stroke(&session, from: p(-300, -300), to: p(-280, -300))
        let frame = Frame(id: FrameID(1), paper: .letter, scale: .ratio(48), origin: p(-500, -500))
        let canvas = Scene(ink: InkIndex(session.ink), frames: [frame])
        XCTAssertEqual(pick(p(-497, -300), in: canvas), .frame(FrameID(1)), "just inside its edge")
        XCTAssertEqual(pick(p(-510, -300), in: canvas), .frame(FrameID(1)), "the reach outside it")
        XCTAssertNil(pick(p(-510.25, -300), in: canvas), "just past the reach")
        XCTAssertEqual(pick(p(-400, 28), in: canvas), .frame(FrameID(1)), "its bottom edge, at y = 28")
        XCTAssertNil(pick(p(-400, -100), in: canvas), "the middle of what it takes in")
        XCTAssertEqual(pick(p(-290, -300), in: canvas), .stroke(inside), "ink inside it")
    }

    // MARK: What the selection becomes

    func testTapToAdd() {
        let stroke = SelectTap.Pick.stroke(StrokeID(3)), text = SelectTap.Pick.text(TextBoxID(1))
        let first = SelectTap.selection(after: stroke, given: .empty)
        XCTAssertEqual(first, CanvasSelection(strokes: [StrokeID(3)]))
        let second = SelectTap.selection(after: text, given: first)
        XCTAssertEqual(second, CanvasSelection(strokes: [StrokeID(3)], texts: [TextBoxID(1)]), "another thing is added")
        XCTAssertEqual(SelectTap.selection(after: stroke, given: second), second, "what's selected stays, to be dragged")
        let third = SelectTap.selection(after: .dimension(DimensionID(2)), given: second)
        let fourth = SelectTap.selection(after: .frame(FrameID(4)), given: third)
        XCTAssertEqual(fourth, CanvasSelection(strokes: [StrokeID(3)], texts: [TextBoxID(1)], dimensions: [DimensionID(2)],
                                               frames: [FrameID(4)]))
        XCTAssertEqual(fourth.count, 4)
    }

    func testATapOnEmptyCanvasLetsGoOfEverything() {
        let selected = CanvasSelection(strokes: [StrokeID(1), StrokeID(2)], texts: [TextBoxID(1)])
        XCTAssertEqual(SelectTap.selection(after: nil, given: selected), .empty)
        XCTAssertEqual(SelectTap.selection(after: nil, given: CanvasSelection(sheet: SheetID(1))), .empty)
        XCTAssertEqual(SelectTap.selection(after: nil, given: .empty), .empty)
    }

    /// A sheet is selected alone, so its strip turns, moves and rescales it and nothing else.
    func testASheetIsSelectedAlone() {
        let ink = CanvasSelection(strokes: [StrokeID(1)], frames: [FrameID(1)])
        XCTAssertEqual(SelectTap.selection(after: .sheet(SheetID(2)), given: ink), CanvasSelection(sheet: SheetID(2)),
                       "a sheet tapped lets go of the ink")
        let sheet = CanvasSelection(sheet: SheetID(2))
        XCTAssertEqual(SelectTap.selection(after: .stroke(StrokeID(5)), given: sheet),
                       CanvasSelection(strokes: [StrokeID(5)]), "ink tapped lets go of the sheet")
        XCTAssertEqual(SelectTap.selection(after: .sheet(SheetID(2)), given: sheet), sheet)
        XCTAssertEqual(SelectTap.selection(after: .sheet(SheetID(1)), given: sheet), CanvasSelection(sheet: SheetID(1)))
    }

    /// Inside the selection's dashed box a tap on nothing, or on a sheet's paper under it, is a tap on the selection.
    func testATapInsideTheSelectionsBoxKeepsIt() {
        let selected = CanvasSelection(strokes: [StrokeID(1)], frames: [FrameID(1)])
        XCTAssertEqual(SelectTap.selection(after: nil, given: selected, onSelection: true), selected)
        XCTAssertEqual(SelectTap.selection(after: .sheet(SheetID(1)), given: selected, onSelection: true), selected)
        XCTAssertEqual(SelectTap.selection(after: .stroke(StrokeID(2)), given: selected, onSelection: true),
                       CanvasSelection(strokes: [StrokeID(1), StrokeID(2)], frames: [FrameID(1)]), "another thing is added")
    }

    /// The taps the prototype walks through, one after another, through both halves.
    func testAWalkThroughTheTaps() {
        var session = InkSession()
        let cloud = stroke(&session, from: p(300, 100), to: p(340, 100))
        let beside = stroke(&session, from: p(-50, -50), to: p(-20, -50))
        let canvas = Scene(ink: InkIndex(session.ink), sheets: SheetIndex([under, over]))
        var selection = CanvasSelection.empty
        func tap(_ point: CanvasPoint) { selection = SelectTap.selection(after: pick(point, in: canvas), given: selection) }
        tap(p(320, 100))
        XCTAssertEqual(selection, CanvasSelection(strokes: [cloud]))
        tap(p(-35, -50))
        XCTAssertEqual(selection, CanvasSelection(strokes: [cloud, beside]))
        tap(p(320, 200))
        XCTAssertEqual(selection, CanvasSelection(sheet: SheetID(1)))
        tap(p(320, 100))
        XCTAssertEqual(selection, CanvasSelection(strokes: [cloud]))
        tap(p(-1_000, 0))
        XCTAssertEqual(selection, .empty)
    }

    // MARK: The tool

    func testSelectSitsBesideTheLassoAndKeepsTheSelection() {
        XCTAssertEqual(CanvasTool.Group.selectionAndText.tools, [.select, .lasso, .textBox])
        XCTAssertEqual(CanvasTool.select.title, "Select")
        XCTAssertNil(CanvasTool.select.inkTool)
        XCTAssertTrue(CanvasTool.select.selects)
        XCTAssertTrue(CanvasTool.lasso.selects)
        XCTAssertFalse(CanvasTool.pen.selects)
        XCTAssertEqual(CanvasTool.select.prompt(fingerDraws: false, hasSelection: false), "Tap anything to select it")
        XCTAssertEqual(CanvasTool.select.prompt(fingerDraws: true, hasSelection: false), "Tap anything to select it")
        XCTAssertEqual(CanvasTool.select.prompt(fingerDraws: false, hasSelection: true), "Drag the selection")
        XCTAssertEqual(CanvasTool.select.prompt(fingerDraws: false, hasSelection: true, hasSheet: true),
                       "Twist or drag the sheet")
        XCTAssertEqual(CanvasTool.select.prompt(fingerDraws: false, hasSelection: true, hasSheet: true,
                                                step: .turningSheet(12.3)), "Turning: 12.3°")
        // A drag on empty canvas says what to use instead, over whatever the selection would say.
        XCTAssertEqual(CanvasTool.select.prompt(fingerDraws: false, hasSelection: true,
                                                step: .hint(CanvasTool.selectDragHint)),
                       "Loop several with the Lasso")
        XCTAssertEqual(CanvasTool.select.prompt(fingerDraws: false, hasSelection: false,
                                                step: .hint(CanvasTool.selectSheetDragHint)),
                       "Tap the sheet, then drag it")
        XCTAssertEqual(CanvasTool.lasso.prompt(fingerDraws: false, hasSelection: false), "Loop ink, or tap a sheet")
        // Every prompt Select shows fits the status bar's 28 characters (`CanvasToolPromptTests`).
        for prompt in [CanvasTool.selectPrompt, CanvasTool.selectDragHint, CanvasTool.selectSheetDragHint] {
            XCTAssertLessThanOrEqual(prompt.count, 28, prompt)
        }
    }
}
