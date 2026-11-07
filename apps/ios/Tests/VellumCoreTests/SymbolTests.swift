import Foundation
import XCTest
@testable import VellumCore

// Every symbol, sheet, name, key and token here is made up for the test.
private let symbolKey = DropboxAppKey(buildSetting: "madeupsymbolkey1")!
private let symbolTokens = DropboxTokens(accessToken: "made-up", refreshToken: "made-up", expiresAt: .distantFuture)

/// Symbols (#41): a symbol's drawing placed as plain ink at its printed size at the scale under the tap, Save as symbol,
/// instrument tags, the symbol file and the library's sync with Dropbox.
final class SymbolTests: XCTestCase {
    private func symbol(_ id: String) -> Symbol { Symbol.starters.first { $0.id == id }! }

    private func p(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .inches(x), y: .inches(y)) }

    private func assertClose(_ a: CanvasPoint, _ b: CanvasPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x.inches, b.x.inches, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.y.inches, b.y.inches, accuracy: 1e-9, file: file, line: line)
    }

    /// M-201, a made-up 36 × 24 sheet at 1/4" = 1'-0", with DETAIL 2 at 1" = 1'-0" on its paper from (1, 4) to (5, 6).
    private let m201 = Sheet(id: SheetID(1), paper: .inches(36, by: 24),
                             scale: .drawn(.architectural(inchesPerFoot: 0.25)), origin: .origin,
                             page: SheetPage(file: "madeup", name: "made-up.pdf", path: "/made-up.pdf", index: 0,
                                             number: "M-201"),
                             areas: [ScaleArea(name: "DETAIL 2", rect: .inches(x: 1, y: 4, width: 4, height: 2),
                                               scale: .drawn(.architectural(inchesPerFoot: 1)))])
    /// A made-up NTS loop diagram, 17 × 11, far off to the right.
    private let nts = Sheet(id: SheetID(2), paper: .inches(17, by: 11), scale: .notToScale,
                            origin: CanvasPoint(x: .inches(5000), y: .zero),
                            page: SheetPage(file: "madeup2", name: "loop.pdf", path: "/loop.pdf", index: 0, number: "L-1"))

    // MARK: Geometry

    func testTheStarterLibraryIsTheSixAtVariantAsPrintedSizes() {
        XCTAssertEqual(Symbol.starters.map(\.name), ["Gate valve", "Ball valve", "Control valve", "Instrument bubble",
                                                     "Junction box", "Motor"])
        XCTAssertEqual(Symbol.starters.map(\.printedSize.inches), [0.25, 0.25, 0.25, 0.375, 0.375, 0.375])
        XCTAssertEqual(Symbol.starters.filter(\.hasTagSlot).map(\.id), ["bubble"])
        XCTAssertEqual(symbol("bubble").tagLetters, "FT")
    }

    /// A gate valve 18" across centred on (100, 50): two lines, each from end to end across its width, with its points
    /// exactly at the centre plus 18" times the drawing's.
    func testASymbolsDrawingBecomesStrokesAtACentreAndSize() {
        let placed = symbol("gate").placed(at: p(100, 50), size: .inches(18), lineWidth: .inches(0.5))
        XCTAssertEqual(placed.strokes.count, 2)
        XCTAssertTrue(placed.texts.isEmpty)
        XCTAssertNil(placed.tag)
        let first = placed.strokes[0].points
        XCTAssertEqual(first.count, 4)
        for (got, want) in zip(first, [p(91, 50), p(91, 44.6), p(109, 55.4), p(109, 50)]) { assertClose(got, want) }
        // Lines no wider than 6% of the symbol, whatever the pen's weight at this zoom.
        XCTAssertEqual(placed.strokes[0].width.inches, 0.5)
        let zoomedOut = symbol("gate").placed(at: p(100, 50), size: .inches(18), lineWidth: .inches(40))
        XCTAssertEqual(zoomedOut.strokes[0].width.inches, 18 * 0.06, accuracy: 1e-12)

        // A bubble: a circle of 41 points, each 9" from the centre, and its tag slot in the middle.
        let bubble = symbol("bubble").placed(at: p(10, 20), size: .inches(18), lineWidth: .inches(0.5))
        XCTAssertEqual(bubble.strokes.count, 1)
        XCTAssertEqual(bubble.strokes[0].points.count, Symbol.circleSegments + 1)
        for point in bubble.strokes[0].points { XCTAssertEqual(point.distance(to: p(10, 20)).inches, 9, accuracy: 1e-9) }
        XCTAssertEqual(bubble.tag?.centre, p(10, 20))
        XCTAssertEqual(bubble.tag?.fontSize.inches ?? 0, 0.24 * 18, accuracy: 1e-12)
        XCTAssertEqual(bubble.bounds.size.width.inches, 18, accuracy: 1e-9)

        // A junction box: its box, and JB as a text box centred on it, 30% of its width tall.
        let jb = symbol("jb").placed(at: p(0, 0), size: .inches(12), lineWidth: .inches(0.25))
        XCTAssertEqual(jb.texts.count, 1)
        XCTAssertEqual(jb.texts[0].text, "JB")
        XCTAssertEqual(jb.texts[0].fontSize.inches, 3.6, accuracy: 1e-12)
        let middle = CanvasRect(origin: jb.texts[0].origin, size: jb.texts[0].size).center
        assertClose(middle, p(0, 0))
    }

    // MARK: Printed size at the scale under the tap

    /// A 3/8" bubble at 1/4" = 1'-0" is 18" across; in a 1" = 1'-0" scale area the same 18" on the canvas, which
    /// measures 4 1/2" there; on an NTS sheet 3/8"; off a sheet 18".
    func testABubblesPrintedSizeAtTheScaleUnderTheTap() {
        let bubble = symbol("bubble").printedSize
        let sheets = [m201, nts]
        let units = CanvasUnits.feetAndInches

        let onSheet = SymbolScale.at(p(20 * 48, 2 * 48), sheets: sheets, frames: [])
        XCTAssertEqual(onSheet.canvasSize(of: bubble), .inches(18))
        XCTAssertEqual(onSheet.measure(of: bubble), .real(.inches(18)))
        XCTAssertEqual(onSheet.label(for: bubble, units: units), "3/8\" printed · 1'-6\" in M-201")

        let inArea = SymbolScale.at(p(3 * 48, 5 * 48), sheets: sheets, frames: [])
        XCTAssertEqual(inArea.canvasSize(of: bubble), .inches(18), "the same on the paper as the rest of the sheet")
        XCTAssertEqual(inArea.measure(of: bubble), .real(.inches(4.5)))
        XCTAssertEqual(inArea.label(for: bubble, units: units), "3/8\" printed · 0'-4 1/2\" in DETAIL 2")

        let onNTS = SymbolScale.at(p(5005, 5), sheets: sheets, frames: [])
        XCTAssertEqual(onNTS.canvasSize(of: bubble), .inches(0.375))
        XCTAssertEqual(onNTS.measure(of: bubble), .notToScale(.inches(0.375)))
        XCTAssertEqual(onNTS.label(for: bubble, units: units), "3/8\" printed · 3/8\" NTS in L-1")

        let off = SymbolScale.at(p(-500, -500), sheets: sheets, frames: [])
        XCTAssertEqual(off.canvasSize(of: bubble), .inches(18))
        XCTAssertEqual(off.measure(of: bubble), .real(.inches(18)))
        XCTAssertEqual(off.label(for: bubble, units: units), "3/8\" printed · off a sheet, at 1/4\" = 1'-0\"")

        // Off a sheet inside a frame at 1/8" = 1'-0", the frame's scale counts: what it prints at.
        let frame = Frame(id: FrameID(1), paper: .inches(36, by: 24), scale: .architectural(inchesPerFoot: 0.125),
                          origin: p(-2000, -2000))
        let inFrame = SymbolScale.at(p(-1900, -1900), sheets: sheets, frames: [frame])
        XCTAssertEqual(inFrame.canvasSize(of: bubble), .inches(36))
        XCTAssertEqual(inFrame.label(for: bubble, units: units), "3/8\" printed · 3'-0\" in the frame")
        // A sheet over a frame wins.
        XCTAssertEqual(SymbolScale.at(p(20 * 48, 2 * 48), sheets: sheets, frames: [frame]).canvasSize(of: bubble),
                       .inches(18))
    }

    /// The status bar's short label fits its 28 characters.
    func testTheShortLabelFitsTheStatusBar() {
        let scale = SymbolScale.at(p(3 * 48, 5 * 48), sheets: [m201], frames: [])
        let label = scale.shortLabel(for: .inches(0.375), units: .feetAndInches)
        XCTAssertEqual(label, "3/8\" printed · 0'-4 1/2\"")
        XCTAssertLessThanOrEqual(label.count, 28)
        XCTAssertEqual(SymbolScale.printedText(.inches(1.5)), "1 1/2\"")
        XCTAssertEqual(CanvasTool.symbolsPrompt(named: "Gate valve"), "Tap to place: Gate valve")
        XCTAssertEqual(CanvasTool.symbolsPrompt(named: "Instrument bubble"), CanvasTool.symbolsPrompt)
    }

    // MARK: Placing as plain ink

    /// Placing is one undo step of plain strokes and text boxes, in the colour given; a bubble's tag typed as it lands
    /// joins that step, so one undo takes both and one redo puts both back.
    func testPlacingIsOneUndoStepAndTheTagJoinsIt() {
        var session = InkSession()
        session.draw([p(0, 0), p(1, 1)], tool: .pen, colour: .red, width: .inches(0.1))
        let placed = symbol("bubble").placed(at: p(10, 10), size: .inches(18), lineWidth: .inches(0.5))
        let selection = session.place(strokes: placed.strokes, texts: placed.texts, colour: .blue)
        XCTAssertEqual(selection.strokes, [StrokeID(2)])
        let tag = placed.tag!.text(letters: "FT", number: "101")!
        XCTAssertEqual(tag.text, "FT\n101")
        let tagged = session.place(strokes: [], texts: [tag], colour: .blue, joiningLast: true)
        XCTAssertEqual(tagged.texts, [TextBoxID(1)])
        XCTAssertEqual(session.undoSteps, 2, "the stroke drawn, then the bubble with its tag")
        XCTAssertEqual(session.ink.strokes.last?.colour, .blue)
        XCTAssertEqual(session.ink.strokes.last?.tool, .pen)
        XCTAssertEqual(session.texts.first?.text, "FT\n101")
        let before = session
        session.undo()
        XCTAssertEqual(session.ink.count, 1)
        XCTAssertTrue(session.texts.isEmpty)
        session.redo()
        XCTAssertEqual(session.ink, before.ink)
        XCTAssertEqual(session.texts, before.texts)

        // Plain ink: the lasso and Select take it, and nothing links it to the library.
        let all = CanvasSelection(strokes: [StrokeID(2)], texts: [TextBoxID(1)])
        let tagX = session.texts[0].origin.x.inches
        XCTAssertEqual(tagX, tag.origin.x.inches, accuracy: 1.0 / 65_536, "kept on the ink grid")
        XCTAssertTrue(session.transform(all, by: .translation(dx: .inches(5), dy: .zero)))
        XCTAssertEqual(session.texts[0].origin.x.inches, tagX + 5, accuracy: 1e-9)
    }

    /// The placing events round-trip through the codec, replay to the same session, and the undo step round-trips
    /// through a snapshot.
    func testPlacingIsSavedAndReplaysExactly() throws {
        var session = InkSession()
        let placed = symbol("jb").placed(at: p(3, 4), size: .inches(18), lineWidth: .inches(0.5))
        session.place(strokes: placed.strokes, texts: placed.texts, colour: .red)
        let bubble = symbol("bubble").placed(at: p(40, 4), size: .inches(18), lineWidth: .inches(0.5))
        session.place(strokes: bubble.strokes, texts: [], colour: .green)
        session.place(strokes: [], texts: [bubble.tag!.text(letters: "PT", number: "230")!], colour: .green,
                      joiningLast: true)
        session.undo()
        let events = session.takeEvents()
        XCTAssertEqual(events.count, 4)
        for event in events { XCTAssertEqual(try InkCodec.decodeEvent(InkCodec.encode(event)[...]), event) }
        var replayed = InkSession()
        for event in events { replayed.apply(event) }
        XCTAssertEqual(replayed, session)
        let reopened = try InkCodec.decodeSession(InkCodec.encode(session)[...])
        XCTAssertEqual(reopened, session)
        var a = session, b = reopened
        a.redo(); b.redo()
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.texts.map(\.text), ["JB", "PT\n230"])
        XCTAssertEqual(InkStore.version, 7)
    }

    // MARK: Save as symbol

    /// The selection's ink is centred on the middle of what it covers and measured in its width, so it places at any
    /// size; placed back at the same centre and size it gives back the same ink.
    func testSaveAsSymbolNormalisesAndPlacesBackTheSameInk() throws {
        let strokes = [
            InkStroke(id: StrokeID(1), tool: .pen, colour: .sketch, width: .inches(0.5),
                      points: [p(100, 200), p(124, 200), p(124, 212), p(100, 212), p(100, 200)].map(\.onInkGrid)),
            InkStroke(id: StrokeID(2), tool: .pen, colour: .sketch, width: .inches(0.5),
                      points: [p(106, 203.5), p(118, 208.25)].map(\.onInkGrid)),
        ]
        let text = TextBox(id: TextBoxID(1), origin: p(109, 204), size: CanvasSize(width: .inches(6), height: .inches(4)),
                           fontSize: .inches(3), colour: .sketch, text: "Y")
        let drawing = try XCTUnwrap(SymbolDrawing.of(strokes: strokes, texts: [text]))
        XCTAssertEqual(drawing.unit, .inches(24))
        XCTAssertEqual(drawing.centre, p(112, 206))
        XCTAssertNil(drawing.tagLetters)
        guard case .line(let box) = drawing.parts[0] else { return XCTFail("a line first") }
        XCTAssertEqual(box[0], SymbolPoint(-0.5, -0.25))
        XCTAssertEqual(box[2], SymbolPoint(0.5, 0.25))
        // Its printed size where it was drawn, off a sheet at 1/4" = 1'-0": 24" is 1/2" printed.
        let scale = SymbolScale.at(drawing.centre, sheets: [], frames: [])
        XCTAssertEqual(scale.printed(of: drawing.unit), .inches(0.5))

        let saved = Symbol(id: "made-up", name: "Strainer", printedSize: .inches(0.5), parts: drawing.parts)
        let placed = saved.placed(at: drawing.centre, size: drawing.unit, lineWidth: .inches(0.5))
        XCTAssertEqual(placed.strokes.map { $0.points.map(\.onInkGrid) }, strokes.map(\.points))
        XCTAssertEqual(placed.texts.count, 1)
        assertClose(placed.texts[0].origin, text.origin)
        XCTAssertEqual(placed.texts[0].size.width.inches, 6, accuracy: 1e-9)
        XCTAssertEqual(placed.texts[0].size.height.inches, 4, accuracy: 1e-9)
        XCTAssertEqual(placed.texts[0].fontSize.inches, 3, accuracy: 1e-9)
        XCTAssertEqual(placed.texts[0].text, "Y")

        // A tall thin selection is measured in its height.
        let pole = InkStroke(id: StrokeID(3), tool: .pen, colour: .red, width: .inches(0.5), points: [p(0, 0), p(1, 40)])
        XCTAssertEqual(SymbolDrawing.of(strokes: [pole], texts: [])?.unit, .inches(40))

        // A tag of letters over a number becomes the symbol's tag slot.
        let tag = TextBox(id: TextBoxID(2), origin: p(0, 0), size: CanvasSize(width: .inches(4), height: .inches(4)),
                          fontSize: .inches(1.5), colour: .red, text: "LT\n304")
        let ring = InkStroke(id: StrokeID(4), tool: .pen, colour: .red, width: .inches(0.5),
                             points: [p(-2, 2), p(6, 2)])
        XCTAssertEqual(SymbolDrawing.of(strokes: [ring], texts: [tag])?.tagLetters, "LT")
    }

    // MARK: Tags

    func testTheNextTagIsOnePastTheHighestOfItsLettersFrom101() {
        func box(_ id: Int, _ text: String) -> TextBox {
            TextBox(id: TextBoxID(id), origin: .origin, size: CanvasSize(width: .inches(1), height: .inches(1)),
                    fontSize: .inches(1), colour: .red, text: text)
        }
        let texts = [box(1, "FT\n101"), box(2, "FT\n107"), box(3, "PT\n230"), box(4, "ft 120"), box(5, "FT\nlater"),
                     box(6, "Note: FT 900 is the spare")]
        XCTAssertEqual(SymbolTag.next(letters: "FT", in: texts), 121)
        XCTAssertEqual(SymbolTag.next(letters: "PT", in: texts), 231)
        XCTAssertEqual(SymbolTag.next(letters: "LT", in: texts), 101)
        XCTAssertEqual(SymbolTag.next(letters: "FT", in: []), 101)
        let slot = PlacedSymbol.Tag(centre: .origin, fontSize: .inches(1), letters: "FT")
        XCTAssertNil(slot.text(letters: " ", number: ""), "Skip, or both emptied, leaves no tag")
        XCTAssertEqual(slot.text(letters: "", number: "101")?.text, "101")
    }

    // MARK: The symbol file

    func testTheSymbolFileRoundTripsAndIsTheSameBytesEveryTime() throws {
        let drawn = Symbol(id: "0f6c2a9e-made-up", name: "Y-strainer", printedSize: .inches(0.5), tagLetters: "LT",
                           parts: [.line([SymbolPoint(-0.5, 0.123456789012345), SymbolPoint(0.5, -1.0 / 3)]),
                                   .text(centre: SymbolPoint(0.1, 0.2), height: 0.3, text: "Y", width: 0.4,
                                         boxHeight: 0.5),
                                   .tag(centre: SymbolPoint(0, 0.25), height: 0.2)])
        for symbol in Symbol.starters + [drawn] {
            let bytes = SymbolFile.encode(symbol)
            XCTAssertEqual(try SymbolFile.decode(bytes), symbol, symbol.name)
            XCTAssertEqual(SymbolFile.encode(try SymbolFile.decode(bytes)), bytes, "the same bytes again")
        }
        let file = String(decoding: SymbolFile.encode(drawn), as: UTF8.self)
        XCTAssertTrue(file.contains("\"format\":1"), file)
        XCTAssertTrue(file.contains("\"name\":\"Y-strainer\""), file)
        // The file's name wins over the id inside.
        XCTAssertEqual(try SymbolFile.decode(SymbolFile.encode(drawn), fileID: "copy").id, "copy")
        XCTAssertEqual(SymbolFile.fileName(for: "abc"), "abc.vsym")
        XCTAssertEqual(SymbolFile.id(fromFileName: "Strainer.VSYM"), "Strainer")
        XCTAssertNil(SymbolFile.id(fromFileName: ".vsym"))
        XCTAssertNil(SymbolFile.id(fromFileName: "notes.txt"))
        XCTAssertThrowsError(try SymbolFile.decode(Array("{}".utf8)))
        XCTAssertThrowsError(try SymbolFile.decode(Array(
            "{\"format\":1,\"id\":\"a\",\"name\":\"a\",\"printedSize\":0.5,\"parts\":[{\"circle\":[0,0,-1]}]}".utf8)))
        XCTAssertThrowsError(try SymbolFile.decode(Array(
            "{\"format\":9,\"id\":\"a\",\"name\":\"a\",\"printedSize\":0.5,\"parts\":[{\"circle\":[0,0,1]}]}".utf8)))
    }

    /// Dropbox's content hash of a small file is the SHA-256 of its one block's SHA-256.
    func testTheContentHashIsDropboxs() {
        let bytes = Array("made-up symbol".utf8)
        let expected = SHA256.hash(SHA256.hash(bytes)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(DropboxContentHash.of(bytes), expected)
        XCTAssertEqual(DropboxContentHash.of([]), SHA256.hash(SHA256.hash([])).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: Factor scale

    /// The corner resize catches at ½×, 1×, 2×, 3× and 4×, within 4% of each (#41): just inside each catch reads the
    /// catch, just outside reads itself, and 1.5× is left free.
    func testTheCornerResizeCatchesAtRoundFactors() {
        for round in ResizeCatch.catches {
            for inside in [round * 1.039, round * 0.961, round] {
                XCTAssertEqual(ResizeCatch.caught(inside).factor, round, "\(inside) catches at \(round)")
                XCTAssertTrue(ResizeCatch.caught(inside).isCaught)
            }
            for outside in [round * 1.041, round * 0.959] {
                XCTAssertEqual(ResizeCatch.caught(outside).factor, outside, "\(outside) is free")
                XCTAssertFalse(ResizeCatch.caught(outside).isCaught)
            }
        }
        XCTAssertEqual(ResizeCatch.caught(1.5).factor, 1.5)
        XCTAssertFalse(ResizeCatch.caught(1.5).isCaught)
        XCTAssertEqual(ResizeCatch.caught(5).factor, 5, "past 4× it is free")
        XCTAssertEqual(ResizeCatch.label(2), "Scale 2×")
        XCTAssertEqual(ResizeCatch.label(1.5), "Scale 1.5×")
        XCTAssertEqual(ResizeCatch.label(0.5), "Scale 0.5×")
        XCTAssertEqual(ResizeCatch.label(0.37), "Scale 0.37×")
        XCTAssertEqual(ResizeCatch.label(0.05), "Scale 0.05×")
        XCTAssertEqual(ResizeCatch.label(12.25), "Scale 12.25×")
        for factor in stride(from: 0.05, through: 40, by: 0.01) {
            XCTAssertLessThanOrEqual(ResizeCatch.label(factor).count, 28)
        }
    }

    /// The factor is how far along the diagonal from the anchor, the opposite corner, the dragged corner has come; a
    /// drag past the anchor gives the smallest factor, never a flipped selection.
    func testTheFactorFromTheDrag() {
        let anchor = p(0, 0), corner = p(1, 2)
        XCTAssertEqual(ResizeCatch.factor(anchor: anchor, corner: corner, point: p(2, 4)), 2)
        XCTAssertEqual(ResizeCatch.factor(anchor: anchor, corner: corner, point: p(1.5, 3)), 1.5)
        XCTAssertEqual(ResizeCatch.factor(anchor: anchor, corner: corner, point: p(-1, -2)), ResizeCatch.smallest)
        XCTAssertEqual(ResizeCatch.factor(anchor: anchor, corner: anchor, point: p(3, 3)), 1)
    }

    /// A selection scaled by the caught 2× about its anchor corner, as one undo step: a 1" line from (0, 0) to (1, 0)
    /// runs to (2, 0), its width doubles, and a text box's letters double.
    func testAScaleByACaughtFactorIsOneUndoStep() {
        var session = InkSession()
        session.draw([p(0, 0), p(1, 0)], tool: .pen, colour: .red, width: .inches(0.1))
        session.addText("FT", at: p(0, 1), size: CanvasSize(width: .inches(1), height: .inches(1)),
                        fontSize: .inches(0.5), colour: .red)
        let all = CanvasSelection(strokes: [StrokeID(1)], texts: [TextBoxID(1)])
        // The selection covers (0, 0) to (1, 2); the corner at (1, 2) is dragged to (2.03, 4.06), 2.03×, caught at 2×.
        let raw = ResizeCatch.factor(anchor: p(0, 0), corner: p(1, 2), point: p(2.03, 4.06))
        let factor = ResizeCatch.caught(raw).factor
        XCTAssertEqual(factor, 2)
        XCTAssertTrue(session.transform(all, by: .scaling(by: factor, about: p(0, 0))))
        XCTAssertEqual(session.ink.strokes[0].points, [p(0, 0), p(2, 0)])
        XCTAssertEqual(session.ink.strokes[0].width.inches, 0.2, accuracy: 1e-12)
        XCTAssertEqual(session.texts[0].fontSize.inches, 1)
        XCTAssertEqual(session.texts[0].origin, p(0, 2))
        XCTAssertEqual(session.undoSteps, 3, "one undo step")
        session.undo()
        XCTAssertEqual(session.ink.strokes[0].points, [p(0, 0), p(1, 0)])
    }
}

/// The symbol library's sync with `Dropbox/Vellum/Symbols` (#41, ADR-0016), through the made-up Dropbox behind the live
/// client's transport seam.
final class SymbolSyncTests: XCTestCase {
    private func file(_ name: String, _ id: String) -> (String, [UInt8]) {
        let symbol = Symbol(id: id, name: name, printedSize: .inches(0.5),
                            parts: [.circle(centre: SymbolPoint(0, 0), radius: 0.5)])
        return (SymbolFile.fileName(for: id), SymbolFile.encode(symbol))
    }

    private func engine(_ dropbox: MadeUpDropbox, _ store: SymbolFolderMemory, _ ledger: SymbolSyncLedgerMemory)
        -> SymbolSync {
        let session = DropboxSession(appKey: symbolKey, transport: dropbox, store: DropboxMemoryTokenStore(symbolTokens))
        return SymbolSync(session: session, store: store, ledger: ledger, makeID: { "kept-from-duo" })
    }

    func testThePlanMovesOnlyNewOrChangedFiles() {
        let steps = SymbolSyncPlan.steps(
            local: ["duo.vsym": "d", "same.vsym": "s", "duoChanged.vsym": "d2", "lapChanged.vsym": "l1", "both.vsym": "b2",
                    "agreeNow.vsym": "a"],
            remote: ["laptop.vsym": "l", "SAME.vsym": "s", "duoChanged.vsym": "d1", "lapChanged.vsym": "l2",
                     "both.vsym": "b3", "agreeNow.vsym": "a"],
            synced: ["same.vsym": "s", "duoChanged.vsym": "d1", "lapChanged.vsym": "l1", "both.vsym": "b1"])
        XCTAssertEqual(steps, [.agree("agreeNow.vsym"), .keepBoth("both.vsym"), .upload("duo.vsym"),
                               .upload("duoChanged.vsym"), .download("lapChanged.vsym"), .download("laptop.vsym")])
        XCTAssertEqual(SymbolSyncPlan.steps(local: ["a.vsym": "x"], remote: ["a.vsym": "x"], synced: ["a.vsym": "x"]), [])
    }

    /// A symbol saved on the Duo goes up; one the laptop puts there comes down; the next sync moves nothing.
    func testADuoSymbolUploadsALaptopSymbolDownloadsAndThenNothingMoves() async throws {
        let dropbox = MadeUpDropbox()
        let (duoName, duoBytes) = file("Strainer", "duo-made")
        let store = SymbolFolderMemory([duoName: duoBytes])
        let ledger = SymbolSyncLedgerMemory()
        let (laptopName, laptopBytes) = file("Damper", "laptop-made")
        dropbox.changeOnTheLaptop("\(SymbolSync.folder)/\(laptopName)", to: laptopBytes)
        let sync = engine(dropbox, store, ledger)

        let changed = await sync.sync()
        XCTAssertTrue(changed, "the laptop's symbol came down")
        XCTAssertEqual(dropbox.files(in: SymbolSync.folder)[duoName], duoBytes)
        XCTAssertEqual(try store.files()[laptopName], laptopBytes)
        XCTAssertEqual(store.symbols().map(\.name), ["Damper", "Strainer"])
        XCTAssertEqual(ledger.load().synced.count, 2)

        dropbox.resetCounts()
        let again = await sync.sync()
        XCTAssertFalse(again)
        let steps = await sync.lastSteps
        XCTAssertEqual(steps, [])
        XCTAssertEqual(dropbox.requests, ["list \(SymbolSync.folder)"], "only the listing: nothing moves")
        XCTAssertEqual(dropbox.bytesUploaded, 0)
    }

    /// Offline nothing moves and nothing on the Duo changes; the connection back, the Duo's symbol goes up.
    func testOfflineKeepsEverythingUntilTheConnectionReturns() async throws {
        let dropbox = MadeUpDropbox()
        let (name, bytes) = file("Strainer", "duo-made")
        let store = SymbolFolderMemory([name: bytes])
        let ledger = SymbolSyncLedgerMemory()
        let sync = engine(dropbox, store, ledger)
        dropbox.offline = true
        let offline = await sync.sync()
        XCTAssertFalse(offline)
        XCTAssertEqual(try store.files(), [name: bytes])
        XCTAssertEqual(ledger.load(), SymbolSyncLedger())
        dropbox.offline = false
        _ = await sync.sync()
        XCTAssertEqual(dropbox.files(in: SymbolSync.folder)[name], bytes)
    }

    /// Changed on the laptop since the last sync, it comes down; changed on both, both are kept.
    func testAChangeOnTheLaptopComesDownAndAChangeOnBothKeepsBoth() async throws {
        let dropbox = MadeUpDropbox()
        let (name, first) = file("Strainer", "shared")
        let store = SymbolFolderMemory([name: first])
        let ledger = SymbolSyncLedgerMemory()
        let sync = engine(dropbox, store, ledger)
        _ = await sync.sync()
        let (_, laptopEdit) = file("Strainer, laptop", "shared")
        dropbox.changeOnTheLaptop("\(SymbolSync.folder)/\(name)", to: laptopEdit)
        _ = await sync.sync()
        XCTAssertEqual(try store.files()[name], laptopEdit)

        let (_, duoEdit) = file("Strainer, Duo", "shared")
        try store.write(duoEdit, named: name)
        let (_, laptopAgain) = file("Strainer, laptop again", "shared")
        dropbox.changeOnTheLaptop("\(SymbolSync.folder)/\(name)", to: laptopAgain)
        _ = await sync.sync()
        let steps = await sync.lastSteps
        XCTAssertEqual(steps, [.keepBoth(name)])
        XCTAssertEqual(try store.files()[name], laptopAgain)
        XCTAssertEqual(store.symbols().map(\.name).sorted(), ["Strainer, Duo (Duo)", "Strainer, laptop again"])
        XCTAssertNotNil(dropbox.files(in: SymbolSync.folder)["kept-from-duo.vsym"])
    }
}

/// What placing a symbol costs on the 10,000-stroke canvas (#41, `docs/perf/baselines/canvas-rendering.json`): the
/// strokes it adds and the tiles it asks the renderer to draw, as a new stroke does.
final class SymbolPlacementBudgetTests: XCTestCase {
    private struct Baseline: Decodable {
        struct Entry: Decodable {
            let metric: String
            let kind: String
            let value: Double
        }
        let entries: [Entry]
    }

    private static let baseline: [String: Double] = {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/perf/baselines/canvas-rendering.json")
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(Baseline.self, from: data) else { return [:] }
        return Dictionary(decoded.entries.filter { $0.kind == "count" }.map { ($0.metric, $0.value) },
                          uniquingKeysWith: { a, _ in a })
    }()

    private func check(_ metric: String, _ measured: Double, file: StaticString = #filePath, line: UInt = #line) {
        print("budget \(metric): measured \(measured)")
        guard let budget = Self.baseline[metric] else {
            return XCTFail("No budget for \(metric) in docs/perf/baselines/canvas-rendering.json", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(measured, budget, "\(metric) is over its budget", file: file, line: line)
    }

    /// A gate valve placed in the middle of the screen at zoom to everything on the 10,000-stroke canvas: its two strokes
    /// go in as one change, through the same path as a drawn stroke, and the renderer draws only the tiles they touch.
    /// The time it takes is recorded.
    func testPlacingASymbolAddsItsStrokesAndRedrawsOnlyTheirTiles() throws {
        let ink = MadeUpInk.largeWalkdown()
        var session = InkSession(ink: ink)
        var index = InkIndex(ink)
        var viewport = Viewport(pointsPerInch: 1, screenWidth: 951, screenHeight: 669)
        viewport.fit(try XCTUnwrap(ink.bounds), insets: ScreenInsets(top: 56, left: 70, bottom: 50, right: 92))
        let harness = InkTileHarness(index: index)
        harness.book.show(viewport)
        harness.drawAll()
        harness.book.work = .init()
        let centre = viewport.centre
        let gate = Symbol.starters[0]
        let start = Date()
        let scale = SymbolScale.at(centre, sheets: [], frames: [])
        let placed = gate.placed(at: centre, size: scale.canvasSize(of: gate.printedSize),
                                 lineWidth: viewport.canvasLength(ofScreen: 2.2))
        session.place(strokes: placed.strokes, texts: placed.texts, colour: .red)
        let change = index.apply(session.lastChange)
        harness.index = index
        harness.book.inkChanged(change)
        let took = Date().timeIntervalSince(start)
        print("PERF symbol place-on-10000-stroke-canvas \(took * 1e6) µs")
        let events = session.takeEvents()
        XCTAssertEqual(events.count, 1, "one event, saved before anything else")
        check("symbol_place_strokes_added", Double(change.added.count))
        check("symbol_place_area_invalidated_pt2", harness.book.work.areaDrawn.rounded(.up))
        XCTAssertTrue(harness.requests.allSatisfy { $0.adding != nil }, "drawn over, not redrawn")
    }
}
