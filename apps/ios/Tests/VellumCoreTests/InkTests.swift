import XCTest
@testable import VellumCore

/// Ink in model space: markup colours, widths, the eraser and undo.
final class InkTests: XCTestCase {
    private func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [CanvasPoint] {
        [CanvasPoint(x: .feet(x0), y: .feet(y0)), CanvasPoint(x: .feet(x1), y: .feet(y1))]
    }

    // MARK: Markup colours (ADR-0009)

    func testEachMarkupColourCarriesItsMeaning() {
        XCTAssertEqual(MarkupColour.red.meaning, .add)
        XCTAssertEqual(MarkupColour.green.meaning, .delete)
        XCTAssertEqual(MarkupColour.blue.meaning, .note)
        XCTAssertEqual(MarkupColour.sketch.meaning, .sketch)
        XCTAssertEqual(MarkupColour.allCases.map(\.title), ["Add", "Delete", "Note", "Sketch"])
    }

    func testAStrokeKeepsTheMarkupColourItWasDrawnIn() {
        var session = InkSession()
        for colour in MarkupColour.allCases {
            session.draw(line(0, 0, 10, 0), tool: .pen, colour: colour, width: .inches(3))
        }
        XCTAssertEqual(session.ink.strokes.map(\.colour), [.red, .green, .blue, .sketch])
    }

    func testSketchInkFlipsToStayReadableAndMarkupColoursKeepTheirHue() {
        let darkGround = InkRGB(hex: 0x1C1D20), lightGround = InkRGB(hex: 0xF3EFE6)
        let sketchLight = MarkupColour.sketch.rgb(dark: false), sketchDark = MarkupColour.sketch.rgb(dark: true)
        XCTAssertLessThan(sketchLight.luminance, 0.1)
        XCTAssertGreaterThan(sketchDark.luminance, 0.7)
        // Readable (WCAG 4.5:1) on the ground it is drawn over, in both modes.
        XCTAssertGreaterThan(sketchLight.contrast(with: lightGround), 4.5)
        XCTAssertGreaterThan(sketchDark.contrast(with: darkGround), 4.5)
        // Over a sheet drawn light in dark mode (a dimmed sheet), sketch ink stays dark.
        XCTAssertEqual(MarkupColour.sketch.rgb(dark: true, overLightPaper: true), sketchLight)

        for (colour, channel) in [(MarkupColour.red, \InkRGB.red), (.green, \InkRGB.green), (.blue, \InkRGB.blue)] {
            for dark in [false, true] {
                let rgb = colour.rgb(dark: dark)
                let others = [rgb.red, rgb.green, rgb.blue].filter { $0 != rgb[keyPath: channel] }
                XCTAssertTrue(others.allSatisfy { $0 < rgb[keyPath: channel] }, "\(colour) stays \(colour) when dark is \(dark)")
                XCTAssertGreaterThan(rgb.contrast(with: dark ? darkGround : lightGround), 3, "\(colour), dark \(dark)")
            }
        }
    }

    // MARK: Widths

    func testAStrokesWidthIsItsScreenWeightAtTheZoomItWasDrawnAt() {
        let pen = PenSettings()
        // At 2 points per inch a 3-point medium pen covers 1.5 real inches.
        let closeUp = pen.beginStroke(at: .origin, pointsPerInch: 2)!
        XCTAssertEqual(closeUp.width, .inches(1.5))
        // Zoomed out to 0.01 points per inch (a plant), the same weight covers 300 real inches, 25 feet.
        let far = pen.beginStroke(at: .origin, pointsPerInch: 0.01)!
        XCTAssertEqual(far.width.feet, 25, accuracy: 1e-9)
    }

    func testWeightsGetHeavierAndTheHighlighterIsWiderAndSeeThrough() {
        for tool in InkTool.allCases {
            let widths = LineWeight.allCases.map { $0.screenWidth(for: tool) }
            XCTAssertEqual(widths, widths.sorted())
            XCTAssertEqual(Set(widths).count, 3)
        }
        XCTAssertGreaterThan(LineWeight.fine.screenWidth(for: .highlighter), LineWeight.bold.screenWidth(for: .pen))
        XCTAssertEqual(InkTool.pen.opacity, 1)
        XCTAssertLessThan(InkTool.highlighter.opacity, 0.5)
    }

    func testAStrokeWithNoPointsLeavesNothing() {
        var session = InkSession()
        XCTAssertNil(session.draw([], tool: .pen, colour: .red, width: .inches(1)))
        XCTAssertTrue(session.ink.isEmpty)
        XCTAssertFalse(session.canUndo)
    }

    // MARK: Geometry

    func testAStrokesBoundsTakeInItsWidth() {
        let stroke = InkStroke(id: StrokeID(1), tool: .pen, colour: .red, width: .inches(2),
                               points: line(0, 0, 10, 5))
        XCTAssertEqual(stroke.pathBounds?.maxX, .feet(10))
        XCTAssertEqual(stroke.bounds?.minX, .inches(-1))
        XCTAssertEqual(stroke.bounds?.maxY, .inches(61))
    }

    func testTheEraserHitsAStrokeWithinItsWidthAndTolerance() {
        let stroke = InkStroke(id: StrokeID(1), tool: .pen, colour: .red, width: .inches(2), points: line(0, 0, 10, 0))
        // 1" of half-width plus 1" of tolerance reaches 2" off the line, along it and off its ends.
        XCTAssertTrue(stroke.isHit(at: CanvasPoint(x: .feet(5), y: .inches(2)), tolerance: .inches(1)))
        XCTAssertFalse(stroke.isHit(at: CanvasPoint(x: .feet(5), y: .inches(2.01)), tolerance: .inches(1)))
        XCTAssertTrue(stroke.isHit(at: CanvasPoint(x: .feet(10) + .inches(2), y: .zero), tolerance: .inches(1)))
        XCTAssertFalse(stroke.isHit(at: CanvasPoint(x: .feet(10) + .inches(2.1), y: .zero), tolerance: .inches(1)))
        // A one-point stroke (a dot) is hit around its point.
        let dot = InkStroke(id: StrokeID(2), tool: .pen, colour: .blue, width: .inches(1), points: [.origin])
        XCTAssertTrue(dot.isHit(at: CanvasPoint(x: .inches(0.6), y: .inches(0.6)), tolerance: .inches(0.5)))
    }

    func testInkFarFromTheOriginKeepsSixteenthInchPrecision() {
        // A valve a hundred miles out on the canvas, drawn in sixteenths: model space in inches as Double holds them.
        let far = Length.feet(528_000)
        let a = CanvasPoint(x: far, y: far), b = CanvasPoint(x: far + .inches(1.0 / 16), y: far)
        XCTAssertEqual(a.distance(to: b).inches, 1.0 / 16, accuracy: 1e-9)
        var viewport = Viewport(centre: a, pointsPerInch: Viewport.maximumPointsPerInch, screenWidth: 951, screenHeight: 669)
        let onScreen = viewport.screenPoint(for: b)
        XCTAssertEqual(onScreen.x - 951.0 / 2, 62.5, accuracy: 1e-6)
        viewport.pan(dx: 0, dy: 0)
        XCTAssertEqual(viewport.canvasPoint(for: onScreen).x.inches, b.x.inches, accuracy: 1e-6)
    }

    // MARK: Erasing and undo

    func testTheEraserTakesWholeStrokesAndUndoPutsThemBackInOrder() {
        var session = InkSession()
        let a = session.draw(line(0, 0, 10, 0), tool: .pen, colour: .red, width: .inches(1))!
        let b = session.draw(line(0, 5, 10, 5), tool: .pen, colour: .green, width: .inches(1))!
        let c = session.draw(line(0, 10, 10, 10), tool: .highlighter, colour: .blue, width: .inches(1))!

        // One sweep crosses b then a: one undo step.
        session.beginEraserSweep()
        XCTAssertEqual(session.erase(at: CanvasPoint(x: .feet(5), y: .feet(5)), tolerance: .inches(1)).map(\.id), [b.id])
        XCTAssertEqual(session.erase(at: CanvasPoint(x: .feet(5), y: .zero), tolerance: .inches(1)).map(\.id), [a.id])
        XCTAssertEqual(session.ink.strokes.map(\.id), [c.id])

        session.undo()
        XCTAssertEqual(session.ink.strokes.map(\.id), [a.id, b.id, c.id])
        session.redo()
        XCTAssertEqual(session.ink.strokes.map(\.id), [c.id])
        session.undo()
        session.undo()
        XCTAssertEqual(session.ink.strokes.map(\.id), [a.id, b.id])
    }

    func testEachEraserSweepIsItsOwnUndoStepEvenWhenItStartsOnBlankCanvas() {
        var session = InkSession()
        let a = session.draw(line(0, 0, 10, 0), tool: .pen, colour: .red, width: .inches(1))!
        let b = session.draw(line(0, 5, 10, 5), tool: .pen, colour: .green, width: .inches(1))!

        // Sweep one erases a.
        session.beginEraserSweep()
        session.erase(at: CanvasPoint(x: .feet(5), y: .zero), tolerance: .inches(1))
        // Sweep two touches down on blank canvas, then crosses b.
        session.beginEraserSweep()
        XCTAssertTrue(session.erase(at: CanvasPoint(x: .feet(5), y: .feet(2)), tolerance: .inches(1)).isEmpty)
        XCTAssertEqual(session.erase(at: CanvasPoint(x: .feet(5), y: .feet(5)), tolerance: .inches(1)).map(\.id), [b.id])
        XCTAssertTrue(session.ink.isEmpty)

        // Undo brings back b alone, then a.
        session.undo()
        XCTAssertEqual(session.ink.strokes.map(\.id), [b.id])
        session.undo()
        XCTAssertEqual(session.ink.strokes.map(\.id), [a.id, b.id])
        // The next undo is the drawing of b, not more erasing.
        session.undo()
        XCTAssertEqual(session.ink.strokes.map(\.id), [a.id])
    }

    func testASweepDoesNotJoinAnEraseFromBeforeAnUndo() {
        var session = InkSession()
        let a = session.draw(line(0, 0, 10, 0), tool: .pen, colour: .red, width: .inches(1))!
        let b = session.draw(line(0, 5, 10, 5), tool: .pen, colour: .green, width: .inches(1))!
        let c = session.draw(line(0, 10, 10, 10), tool: .pen, colour: .blue, width: .inches(1))!
        session.beginEraserSweep()
        session.erase(at: CanvasPoint(x: .feet(5), y: .zero), tolerance: .inches(1))
        session.erase(at: CanvasPoint(x: .feet(5), y: .feet(5)), tolerance: .inches(1))
        // Undo mid-sweep (the other hand), then the same sweep crosses c: a step of its own.
        session.undo()
        session.erase(at: CanvasPoint(x: .feet(5), y: .feet(10)), tolerance: .inches(1))
        XCTAssertEqual(session.ink.strokes.map(\.id), [a.id, b.id])
        session.undo()
        XCTAssertEqual(session.ink.strokes.map(\.id), [a.id, b.id, c.id])
    }

    func testErasingEmptyCanvasLeavesNoUndoStep() {
        var session = InkSession()
        XCTAssertTrue(session.erase(at: .origin, tolerance: .inches(1)).isEmpty)
        XCTAssertFalse(session.canUndo)
    }

    func testDrawingAfterUndoClearsRedo() {
        var session = InkSession()
        session.draw(line(0, 0, 1, 0), tool: .pen, colour: .red, width: .inches(1))
        session.undo()
        XCTAssertTrue(session.canRedo)
        session.draw(line(0, 0, 2, 0), tool: .pen, colour: .blue, width: .inches(1))
        XCTAssertFalse(session.canRedo)
        XCTAssertEqual(session.ink.strokes.map(\.colour), [.blue])
    }

    func testUndoAndRedoWalkTheWholeSessionBackAndForth() {
        var session = InkSession()
        for i in 0..<5 {
            session.draw(line(0, Double(i), 1, Double(i)), tool: .pen, colour: .sketch, width: .inches(1))
        }
        let full = session.ink
        while session.canUndo { session.undo() }
        XCTAssertTrue(session.ink.isEmpty)
        while session.canRedo { session.redo() }
        XCTAssertEqual(session.ink, full)
    }

    func testNewStrokesNeverReuseAnIDFromInkTheSessionStartedWith() {
        let existing = InkStroke(id: StrokeID(41), tool: .pen, colour: .red, width: .inches(1), points: [.origin])
        var session = InkSession(ink: Ink(strokes: [existing]))
        XCTAssertEqual(session.draw([.origin], tool: .pen, colour: .red, width: .inches(1))?.id, StrokeID(42))
    }

    // MARK: The canvas

    func testExtentsTakeInSheetsFramesAndInk() {
        XCTAssertNil(Canvas().extents)
        var session = InkSession()
        session.draw(line(-20, -10, 0, 0), tool: .pen, colour: .red, width: .inches(2))
        let sheet = Sheet(paper: PaperSize.archD.landscape, scale: .drawn(.architectural(inchesPerFoot: 0.25)))
        let canvas = Canvas(sheets: [sheet], ink: session.ink)
        let extents = canvas.extents!
        XCTAssertEqual(extents.minX, .feet(-20) - .inches(1))
        XCTAssertEqual(extents.minY, .feet(-10) - .inches(1))
        XCTAssertEqual(extents.maxX, .feet(144))
        XCTAssertEqual(extents.maxY, .feet(96))
    }
}
