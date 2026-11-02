import Foundation
import XCTest
@testable import VellumCore

/// Moving, resizing, duplicating and deleting a selection, and placing and editing text boxes (#7): each one undo
/// step, the selection following undo and redo, and every change saved as its own event that replays exactly and
/// reopens from the Duo. Every stroke and text here is made up for the test.
final class SelectionTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .inches(x), y: .inches(y)) }

    private func wave(_ i: Int, points: Int = 12) -> [CanvasPoint] {
        (0..<points).map { k in p(Double(i) * 10 + Double(k) * 0.37, Double(i % 3) + sin(Double(k) / 2)) }
    }

    /// Three strokes and a text box.
    private func canvas() -> InkSession {
        var session = InkSession()
        for i in 0..<3 { session.draw(wave(i), tool: .pen, colour: .red, width: .inches(0.2)) }
        session.addText("Check the bypass", at: p(5, 20), size: CanvasSize(width: .inches(30), height: .inches(4)),
                        fontSize: .inches(2), colour: .blue)
        return session
    }

    private var everything: CanvasSelection {
        CanvasSelection(strokes: [StrokeID(1), StrokeID(2), StrokeID(3)], texts: [TextBoxID(1)])
    }

    // MARK: Moving and resizing

    func testAMoveKeepsIdsMovesPointsOnTheGridAndIsOneUndoStep() throws {
        var session = canvas()
        let before = session
        let steps = session.undoSteps
        let move = CanvasTransform.translation(dx: .inches(12.3), dy: .inches(-4))
        XCTAssertTrue(session.transform(CanvasSelection(strokes: [StrokeID(2)], texts: [TextBoxID(1)]), by: move))
        XCTAssertEqual(session.undoSteps, steps + 1)
        let moved = try XCTUnwrap(session.ink.strokes.first { $0.id == StrokeID(2) })
        let original = try XCTUnwrap(before.ink.strokes.first { $0.id == StrokeID(2) })
        for (a, b) in zip(moved.points, original.points) {
            XCTAssertEqual(a, move.apply(b).onInkGrid)
            XCTAssertEqual(a.x.inches, b.x.inches + 12.3, accuracy: 1e-4)
        }
        XCTAssertEqual(session.ink.strokes.map(\.id), before.ink.strokes.map(\.id), "the ink keeps its order")
        let box = try XCTUnwrap(session.text(TextBoxID(1)))
        XCTAssertEqual(box.origin.x.inches, 17.3, accuracy: 1e-12)
        XCTAssertEqual(box.origin.y.inches, 16, accuracy: 1e-12)
        XCTAssertEqual(session.lastChange.removed, [StrokeID(2)])
        XCTAssertEqual(session.lastChange.added, [moved])
        session.undo()
        XCTAssertEqual(session.ink, before.ink, "undo puts the strokes back exactly")
        XCTAssertEqual(session.texts, before.texts)
        session.redo()
        XCTAssertEqual(session.ink.strokes.first { $0.id == StrokeID(2) }, moved, "redo moves them exactly again")
    }

    func testAResizeScalesPointsWidthsAndLettersAboutTheAnchor() throws {
        var session = canvas()
        let original = session.ink.strokes[0]
        let resize = CanvasTransform.scaling(by: 2, about: p(0, 0))
        session.transform(everything, by: resize)
        let stroke = session.ink.strokes[0]
        XCTAssertEqual(stroke.width, .inches(0.4))
        XCTAssertEqual(stroke.points, original.points.map { resize.apply($0).onInkGrid })
        XCTAssertEqual(stroke.points[1].x.inches, 2 * original.points[1].x.inches, accuracy: 1e-9)
        let box = try XCTUnwrap(session.text(TextBoxID(1)))
        XCTAssertEqual(box.origin, p(10, 40))
        XCTAssertEqual(box.size, CanvasSize(width: .inches(60), height: .inches(8)))
        XCTAssertEqual(box.fontSize, .inches(4))
    }

    func testAMoveThatChangesNothingIsNoStep() {
        var session = canvas()
        let steps = session.undoSteps
        XCTAssertFalse(session.transform(everything, by: .identity))
        XCTAssertFalse(session.transform(CanvasSelection(strokes: [StrokeID(99)]), by: .translation(dx: .inches(1), dy: .zero)))
        XCTAssertEqual(session.undoSteps, steps)
        XCTAssertTrue(session.takeEvents().allSatisfy { if case .transform = $0 { return false } else { return true } })
    }

    // MARK: Duplicating and deleting

    func testADuplicateAddsCopiesUnderNewIdsAndSelectsThem() throws {
        var session = canvas()
        let offset = CanvasTransform.translation(dx: .inches(1), dy: .inches(1))
        let copies = session.duplicate(everything, by: offset)
        XCTAssertEqual(copies.strokes, [StrokeID(4), StrokeID(5), StrokeID(6)])
        XCTAssertEqual(copies.texts, [TextBoxID(2)])
        XCTAssertEqual(session.ink.count, 6)
        XCTAssertEqual(session.texts.count, 2)
        XCTAssertEqual(session.ink.strokes[3].points, session.ink.strokes[0].points.map { offset.apply($0).onInkGrid })
        XCTAssertEqual(session.text(TextBoxID(2))?.text, "Check the bypass")
        XCTAssertEqual(session.selectionAfterLastChange, copies)
        session.draw(wave(9), tool: .pen, colour: .sketch, width: .inches(0.2))
        XCTAssertEqual(session.ink.strokes.last?.id, StrokeID(7), "the next stroke comes after the copies")
    }

    func testADeleteTakesStrokesAndTextBoxesAsOneStep() {
        var session = canvas()
        let before = session
        session.delete(CanvasSelection(strokes: [StrokeID(1), StrokeID(3)], texts: [TextBoxID(1)]))
        XCTAssertEqual(session.ink.strokes.map(\.id), [StrokeID(2)])
        XCTAssertTrue(session.texts.isEmpty)
        XCTAssertEqual(session.selectionAfterLastChange, .empty)
        session.undo()
        XCTAssertEqual(session.ink, before.ink)
        XCTAssertEqual(session.texts, before.texts)
    }

    // MARK: The selection follows undo and redo

    func testTheSelectionSurvivesUndoAndRedoOfEverySelectionStep() {
        var session = canvas()
        let picked = CanvasSelection(strokes: [StrokeID(1), StrokeID(2)], texts: [TextBoxID(1)])

        session.transform(picked, by: .translation(dx: .inches(3), dy: .zero))
        XCTAssertEqual(session.selectionAfterLastChange, picked)
        session.undo()
        XCTAssertEqual(session.selectionAfterLastChange, picked, "undoing a move keeps what was moved selected")
        session.redo()
        XCTAssertEqual(session.selectionAfterLastChange, picked)

        let copies = session.duplicate(picked, by: .translation(dx: .inches(1), dy: .inches(1)))
        session.undo()
        XCTAssertEqual(session.selectionAfterLastChange, picked, "undoing a duplicate selects the originals again")
        session.redo()
        XCTAssertEqual(session.selectionAfterLastChange, copies, "redoing it selects the copies")

        session.delete(copies)
        XCTAssertEqual(session.selectionAfterLastChange, .empty)
        session.undo()
        XCTAssertEqual(session.selectionAfterLastChange, copies, "undoing a delete selects what comes back")
        session.redo()
        XCTAssertEqual(session.selectionAfterLastChange, .empty)

        session.draw(wave(5), tool: .pen, colour: .red, width: .inches(0.2))
        XCTAssertNil(session.selectionAfterLastChange, "a stroke drawn says nothing about the selection")
    }

    // MARK: Text boxes

    func testATextBoxIsPlacedEditedAndEmptiedAsUndoSteps() throws {
        var session = InkSession()
        XCTAssertNil(session.addText("", at: p(0, 0), size: CanvasSize(width: .inches(10), height: .inches(2)),
                                     fontSize: .inches(1), colour: .sketch), "an empty box is never placed")
        let box = try XCTUnwrap(session.addText("Pump 1A", at: p(0, 0),
                                                size: CanvasSize(width: .inches(10), height: .inches(2)),
                                                fontSize: .inches(1), colour: .sketch))
        XCTAssertEqual(box.id, TextBoxID(1))
        XCTAssertTrue(session.editText(box.id, text: "Pump 1A suction\nstrainer", height: .inches(4)))
        XCTAssertEqual(session.text(box.id)?.text, "Pump 1A suction\nstrainer")
        XCTAssertEqual(session.text(box.id)?.size.height, .inches(4))
        XCTAssertFalse(session.editText(box.id, text: "Pump 1A suction\nstrainer", height: .inches(4)),
                       "no change, no step")
        XCTAssertEqual(session.undoSteps, 2)
        session.undo()
        XCTAssertEqual(session.text(box.id)?.text, "Pump 1A")
        session.redo()
        XCTAssertTrue(session.editText(box.id, text: ""))
        XCTAssertNil(session.text(box.id), "emptied, it is deleted")
        session.undo()
        XCTAssertEqual(session.text(box.id)?.text, "Pump 1A suction\nstrainer")
        session.undo()
        session.undo()
        XCTAssertTrue(session.texts.isEmpty)
    }

    // MARK: Saving

    /// A canvas worked with every kind of change, as its events.
    private func everyKindOfChange() -> (InkSession, [InkEvent]) {
        var session = InkSession()
        var events: [InkEvent] = []
        func take() { events += session.takeEvents() }
        for i in 0..<5 { session.draw(wave(i), tool: .pen, colour: .red, width: .inches(0.2)) }
        session.addText("Héllo, 東京 ✏️", at: p(1, 2), size: CanvasSize(width: .inches(20), height: .inches(3)),
                        fontSize: .inches(1.5), colour: .green)
        take()
        session.transform(CanvasSelection(strokes: [StrokeID(1), StrokeID(4)], texts: [TextBoxID(1)]),
                          by: .translation(dx: .inches(2.25), dy: .inches(-1)))
        session.transform(CanvasSelection(strokes: [StrokeID(2)]), by: .scaling(by: 0.75, about: p(3, 3)))
        let copies = session.duplicate(CanvasSelection(strokes: [StrokeID(1), StrokeID(2)], texts: [TextBoxID(1)]),
                                       by: .translation(dx: .inches(1), dy: .inches(1)))
        session.delete(CanvasSelection(strokes: [StrokeID(3)]))
        session.editText(copies.texts[0], text: "Copy, edited", height: .inches(3.5))
        session.undo()
        session.undo()
        session.redo()
        take()
        session.beginEraserSweep()
        session.erase(at: wave(4)[3], tolerance: .inches(0.5))
        take()
        return (session, events)
    }

    func testEveryNewEventRoundTripsThroughTheCodec() throws {
        let (_, events) = everyKindOfChange()
        let kinds = Set(events.map { event -> String in
            switch event {
            case .draw: "draw"
            case .erase: "erase"
            case .undo: "undo"
            case .redo: "redo"
            case .transform: "transform"
            case .duplicate: "duplicate"
            case .delete: "delete"
            case .addText: "addText"
            case .editText: "editText"
            }
        })
        XCTAssertEqual(kinds.count, 9, "every kind of event, \(kinds.sorted())")
        for event in events {
            XCTAssertEqual(try InkCodec.decodeEvent(InkCodec.encode(event)[...]), event)
        }
    }

    func testReplayingTheEventsRebuildsInkTextAndHistoryExactly() {
        let (session, events) = everyKindOfChange()
        var replayed = InkSession()
        for event in events { replayed.apply(event) }
        XCTAssertEqual(replayed, session)
        // And the undo history still works the same, all the way back.
        var a = session, b = replayed
        while a.canUndo {
            a.undo(); b.undo()
            XCTAssertEqual(a, b)
        }
        XCTAssertTrue(a.ink.isEmpty)
        XCTAssertTrue(a.texts.isEmpty)
    }

    /// A snapshot holds moved strokes and their history: a stroke's id on the canvas is no longer enough to name the
    /// one an undo step holds, since a move keeps the id.
    func testASnapshotHoldsTextBoxesAndTheHistoryOfMovedStrokes() throws {
        let (session, _) = everyKindOfChange()
        let decoded = try InkCodec.decodeSession(InkCodec.encode(session)[...])
        XCTAssertEqual(decoded, session)
        var a = session, b = decoded
        while a.canUndo {
            a.undo(); b.undo()
            XCTAssertEqual(a, b)
        }
        while a.canRedo {
            a.redo(); b.redo()
            XCTAssertEqual(a, b)
        }
    }

    /// A canvas of ink alone writes its snapshot as version 1 did, byte for byte, so the 10,000-stroke budgets hold
    /// and a version 1 snapshot reads as one with no text boxes.
    func testAnInkOnlySnapshotIsTheVersionOneFormat() throws {
        var session = InkSession()
        for i in 0..<4 { session.draw(wave(i), tool: .pen, colour: .blue, width: .inches(0.2)) }
        session.undo()
        let bytes = InkCodec.encode(session)
        XCTAssertEqual(try InkCodec.decodeSession(bytes[...], version: 1), session)
        XCTAssertEqual(try InkCodec.decodeSession(bytes[...], version: 2), session)
    }

    func testTextBoxesAndMovesReopenFromTheDuoThroughTheLogAndTheSnapshot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-sel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (session, events) = everyKindOfChange()
        let store = try InkStore(folder: folder)
        try store.append(events)
        try store.flush()
        store.closeFiles()
        XCTAssertEqual(try InkStore(folder: folder).session, session, "from the log")

        let again = try InkStore(folder: folder)
        try again.compact()
        again.closeFiles()
        let reopened = try InkStore(folder: folder)
        XCTAssertEqual(reopened.session, session, "from the snapshot")
        XCTAssertEqual(reopened.session.texts.map(\.text).sorted(), session.texts.map(\.text).sorted())
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(files), [InkStore.snapshotName, InkStore.logName], "still only the ink files")
    }

    /// A canvas saved by version 1 (its files' headers say 1) still opens, and takes the new events.
    func testAVersionOneCanvasStillOpensAndTakesTheNewEvents() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-v1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var session = InkSession()
        let store = try InkStore(folder: folder)
        for i in 0..<3 { session.draw(wave(i), tool: .pen, colour: .red, width: .inches(0.2)) }
        try store.append(session.takeEvents())
        try store.compact()
        session.draw(wave(4), tool: .pen, colour: .red, width: .inches(0.2))
        try store.append(session.takeEvents())
        try store.flush()
        store.closeFiles()
        // Mark both files version 1, as the last Vellum wrote them.
        for name in [InkStore.snapshotName, InkStore.logName] {
            let url = folder.appendingPathComponent(name)
            var bytes = try [UInt8](Data(contentsOf: url))
            bytes[4] = 1
            bytes[5] = 0
            try Data(bytes).write(to: url)
        }
        let old = try InkStore(folder: folder)
        XCTAssertEqual(old.session, session)
        session.transform(CanvasSelection(strokes: [StrokeID(1)]), by: .translation(dx: .inches(5), dy: .zero))
        session.addText("New", at: p(0, 0), size: CanvasSize(width: .inches(5), height: .inches(1)),
                        fontSize: .inches(0.5), colour: .sketch)
        try old.append(session.takeEvents())
        old.closeFiles()
        XCTAssertEqual(try InkStore(folder: folder).session, session)
    }

    // MARK: The history budget

    /// A moved stroke's old points are held by the history alone, and count toward its budget; undoing the move puts
    /// them back on the canvas.
    func testAMovesOldPointsCountTowardTheHistoryBudget() {
        var session = canvas()
        XCTAssertEqual(session.historyPoints, 0)
        session.transform(CanvasSelection(strokes: [StrokeID(1), StrokeID(2)]), by: .translation(dx: .inches(1), dy: .zero))
        XCTAssertEqual(session.historyPoints, 24)
        session.undo()
        XCTAssertEqual(session.historyPoints, 0)
        let copies = session.duplicate(CanvasSelection(strokes: [StrokeID(1)]), by: .identity)
        XCTAssertEqual(session.historyPoints, 0)
        session.undo()
        XCTAssertEqual(session.historyPoints, 12, "undone copies are held by the history")
        session.redo()
        session.delete(copies)
        XCTAssertEqual(session.historyPoints, 12)
    }
}
