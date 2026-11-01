import Foundation
import XCTest
@testable import VellumCore

/// Saving ink on the Duo (ADR-0014): the log and snapshot, a crash at any byte, undo across a relaunch, compaction.
/// Every stroke here is made up for the test.
final class InkStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-ink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var logURL: URL { folder.appendingPathComponent(InkStore.logName) }
    private var snapshotURL: URL { folder.appendingPathComponent(InkStore.snapshotName) }

    /// A wavy stroke of `points` samples starting near (x, y) feet, the shape a hand makes.
    private func wave(_ x: Double, _ y: Double, points: Int = 24) -> [CanvasPoint] {
        (0..<points).map { i in
            let t = Double(i)
            return CanvasPoint(x: .feet(x + t * 0.05), y: .feet(y + 0.2 * sin(t / 3)))
        }
    }

    /// Draws `count` strokes, appending each one as the app does, and returns the session.
    @discardableResult
    private func drawStrokes(_ count: Int, into store: InkStore, session: inout InkSession) throws -> [Int] {
        var logSizes: [Int] = []
        for i in 0..<count {
            session.draw(wave(Double(i), Double(i % 7)), tool: i % 5 == 0 ? .highlighter : .pen,
                         colour: MarkupColour.allCases[i % 4], width: .inches(0.5 + Double(i % 3)))
            try store.append(session.takeEvents())
            logSizes.append(try fileSize(logURL))
        }
        return logSizes
    }

    private func fileSize(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: The test the issue names

    /// Kill the app mid-drawing and reopen: everything but the open stroke is there. A kill can stop the log's last
    /// write at any byte, so cut the log at every byte inside the last record: the canvas always opens, with all N
    /// strokes when the record is whole and N-1 otherwise, and drawing carries on from there.
    func testACrashAtAnyByteOfTheLastStrokeLosesAtMostThatStroke() throws {
        let n = 12
        var session = InkSession()
        let sizes: [Int]
        do {
            let store = try InkStore(folder: folder)
            sizes = try drawStrokes(n, into: store, session: &session)
        }
        let whole = try Data(contentsOf: logURL)
        let lastStart = sizes[n - 2], lastEnd = sizes[n - 1]
        XCTAssertEqual(whole.count, lastEnd)
        XCTAssertGreaterThan(lastEnd - lastStart, 60, "the last record is long enough to cut in many places")

        for cut in lastStart...lastEnd {
            try whole.prefix(cut).write(to: logURL)
            let store: InkStore
            do {
                store = try InkStore(folder: folder)
            } catch {
                XCTFail("cut at byte \(cut) of \(lastEnd) would not open: \(error)")
                continue
            }
            let expected = cut == lastEnd ? n : n - 1
            XCTAssertEqual(store.session.ink.strokes.count, expected, "cut at byte \(cut)")
            XCTAssertEqual(store.session.ink.strokes, Array(session.ink.strokes.prefix(expected)), "cut at byte \(cut)")
            XCTAssertEqual(store.recovery.droppedBytes, cut - (cut == lastEnd ? lastEnd : lastStart))

            // The torn tail is trimmed, so the next stroke appends cleanly and survives the next reopen.
            var carryOn = store.session
            carryOn.draw(wave(50, 50), tool: .pen, colour: .blue, width: .inches(1))
            try store.append(carryOn.takeEvents())
            let reopened = try InkStore(folder: folder)
            XCTAssertEqual(reopened.session.ink.strokes.count, expected + 1, "after cut \(cut), one more stroke")
            XCTAssertEqual(reopened.recovery.droppedBytes, 0)
        }
    }

    func testDamagedBytesInTheLastRecordAreDroppedNotFatal() throws {
        var session = InkSession()
        let sizes = try drawStrokes(5, into: try InkStore(folder: folder), session: &session)
        var bytes = try Data(contentsOf: logURL)
        bytes[sizes[3] + 12] ^= 0xFF  // inside the last stroke's points
        try bytes.write(to: logURL)
        let store = try InkStore(folder: folder)
        XCTAssertEqual(store.session.ink.strokes, Array(session.ink.strokes.prefix(4)))
        XCTAssertEqual(store.recovery.droppedBytes, sizes[4] - sizes[3])
    }

    func testAnEmptyFolderOpensAsEmptyInkAndAnEmptyLogIsAllHeader() throws {
        let store = try InkStore(folder: folder)
        XCTAssertTrue(store.session.ink.isEmpty)
        XCTAssertEqual(try fileSize(logURL), InkStore.headerSize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    func testAFileThatIsNotVellumInkIsRefusedRatherThanOverwritten() throws {
        try Data("not ink at all, but long enough".utf8).write(to: logURL)
        XCTAssertThrowsError(try InkStore(folder: folder))
        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8), "not ink at all, but long enough")
    }

    // MARK: Undo across a relaunch

    func testUndoAndRedoSurviveARelaunch() throws {
        var session = InkSession()
        do {
            let store = try InkStore(folder: folder)
            try drawStrokes(3, into: store, session: &session)
            // One eraser sweep takes two strokes: one undo step.
            session.beginEraserSweep()
            session.erase(at: wave(0, 0)[3], tolerance: .inches(1))
            session.erase(at: wave(1, 1)[3], tolerance: .inches(1))
            session.undo()
            session.redo()
            session.undo()  // the two strokes are back; redo would take them again
            try store.append(session.takeEvents())
        }
        let store = try InkStore(folder: folder)
        XCTAssertEqual(store.session, session)
        XCTAssertEqual(store.session.ink.strokes.count, 3)
        XCTAssertTrue(store.session.canRedo)

        var reopened = store.session
        reopened.redo()
        XCTAssertEqual(reopened.ink.strokes.count, 1, "redo after a relaunch erases the sweep's two strokes as one step")
        reopened.undo()
        reopened.undo()
        reopened.undo()
        XCTAssertEqual(reopened.ink.strokes.count, 1, "and undo walks back through the strokes drawn before it")
    }

    /// Whatever Zach does, replaying what was saved rebuilds the same ink and the same undo history.
    func testReplayingSavedEventsRebuildsTheSameInkAndHistory() throws {
        var generator = SplitMix(seed: 9)
        var session = InkSession()
        let store = try InkStore(folder: folder, compactionThreshold: 4_000)
        for step in 0..<600 {
            switch generator.next() % 10 {
            case 0...4:
                session.draw(wave(Double(generator.next() % 40), Double(generator.next() % 40), points: 3 + Int(generator.next() % 30)),
                             tool: .pen, colour: .red, width: .inches(2))
            case 5, 6:
                session.beginEraserSweep()
                for _ in 0..<3 {
                    let p = CanvasPoint(x: .feet(Double(generator.next() % 42)), y: .feet(Double(generator.next() % 40)))
                    session.erase(at: p, tolerance: .feet(1))
                }
            case 7, 8:
                session.undo()
            default:
                session.redo()
            }
            try store.append(session.takeEvents())
            if step % 50 == 0, store.needsCompaction { try store.compact() }
            XCTAssertEqual(store.session, session, "step \(step)")
        }
        XCTAssertEqual(try InkStore(folder: folder).session, session)
    }

    // MARK: Compaction

    func testCompactionFoldsTheLogIntoASnapshotWithItsUndoHistory() throws {
        var session = InkSession()
        let store = try InkStore(folder: folder, compactionThreshold: 2_000)
        try drawStrokes(40, into: store, session: &session)
        session.undo()
        try store.append(session.takeEvents())
        XCTAssertTrue(store.needsCompaction)
        try store.compact()
        XCTAssertFalse(store.needsCompaction)
        XCTAssertEqual(try fileSize(logURL), InkStore.headerSize)
        try drawStrokes(2, into: store, session: &session)

        let reopened = try InkStore(folder: folder)
        XCTAssertEqual(reopened.session, session)
        XCTAssertEqual(reopened.session.ink.strokes.count, 41)
        XCTAssertTrue(reopened.session.canUndo)
        XCTAssertFalse(reopened.session.canRedo, "drawing after the undo cleared redo, before and after compaction")
    }

    /// Compaction writes the snapshot first and the new log second. Stopped in between, the old log is still there
    /// with every change already in the snapshot; the next open must not apply them twice.
    func testACrashBetweenTheNewSnapshotAndTheNewLogAppliesNothingTwice() throws {
        var session = InkSession()
        let store = try InkStore(folder: folder)
        try drawStrokes(6, into: store, session: &session)
        session.undo()
        try store.append(session.takeEvents())
        let oldLog = try Data(contentsOf: logURL)
        try store.compact()
        try oldLog.write(to: logURL)  // as if the crash came before the new log replaced it

        let reopened = try InkStore(folder: folder)
        XCTAssertTrue(reopened.recovery.discardedStaleLog)
        XCTAssertEqual(reopened.session, session)
        XCTAssertEqual(reopened.session.ink.strokes.count, 5)
        // And the stale log has been replaced, so drawing carries on.
        var carryOn = reopened.session
        carryOn.draw(wave(9, 9), tool: .pen, colour: .green, width: .inches(1))
        try reopened.append(carryOn.takeEvents())
        XCTAssertEqual(try InkStore(folder: folder).session.ink.strokes.count, 6)
    }

    func testFlushIsOnlyNeededAfterAnAppend() throws {
        var session = InkSession()
        let store = try InkStore(folder: folder)
        XCTAssertFalse(store.hasUnflushedChanges)
        try drawStrokes(1, into: store, session: &session)
        XCTAssertTrue(store.hasUnflushedChanges)
        try store.flush()
        XCTAssertFalse(store.hasUnflushedChanges)
    }

    // MARK: The ink grid and the bytes

    /// Scale is the product: a point saves and reopens on the ink grid, never more than half a grid step from where
    /// the Pencil put it, wherever it is on the canvas, and a grid point reopens exactly.
    func testPointsReopenWithinHalfAGridStepAnywhereOnTheCanvas() throws {
        let step = 1 / CanvasPoint.gridUnitsPerInch
        let xs: [Double] = [0, 1e-7, 0.123456789, -3.75, 1_234.5678, 52_800 * 12, -9_999_999.99]
        var session = InkSession()
        let raw = xs.map { CanvasPoint(x: .inches($0), y: .inches(-$0 / 3)) }
        let stroke = try XCTUnwrap(session.draw(raw, tool: .pen, colour: .red, width: .inches(1)))
        for (drawn, kept) in zip(raw, stroke.points) {
            XCTAssertEqual(kept.x.inches, drawn.x.inches, accuracy: step / 2)
            XCTAssertEqual(kept.y.inches, drawn.y.inches, accuracy: step / 2)
        }
        let store = try InkStore(folder: folder)
        try store.append(session.takeEvents())
        XCTAssertEqual(try InkStore(folder: folder).session.ink.strokes.first?.points, stroke.points)
        XCTAssertEqual(stroke.points.map(\.onInkGrid), stroke.points, "a grid point stays put")
    }

    func testVarintsRoundTripAtTheirEdges() throws {
        let values: [Int64] = [0, 1, -1, 63, -64, 64, 1 << 20, -(1 << 20), Int64(1) << 50, -(Int64(1) << 50), .max, .min]
        var w = ByteWriter()
        for v in values { w.signedVarint(v) }
        var r = ByteReader(w.bytes[...])
        for v in values { XCTAssertEqual(try r.signedVarint(), v) }
        XCTAssertTrue(r.isAtEnd)
        XCTAssertEqual({ var w = ByteWriter(); w.signedVarint(-1); return w.bytes.count }(), 1)
    }
}

/// A small seeded generator, so the replay test does the same thing on every machine.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
