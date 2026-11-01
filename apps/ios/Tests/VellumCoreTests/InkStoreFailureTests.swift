#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import XCTest
@testable import VellumCore

/// Nothing loses a stroke (AGENTS.md), even when the Duo's storage fails part way: a failure or a crash injected at
/// every step of compaction and of a torn append leaves files that reopen with every change that was appended. Every
/// stroke here is made up for the test.
final class InkStoreFailureTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        DurableFile.Fault.inject(nil)
        try? FileManager.default.removeItem(at: folder)
    }

    private var logURL: URL { folder.appendingPathComponent(InkStore.logName) }

    private func wave(_ i: Int) -> [CanvasPoint] {
        (0..<20).map { k in CanvasPoint(x: .feet(Double(i) + Double(k) * 0.05), y: .feet(Double(i % 5) + 0.1 * sin(Double(k)))) }
    }

    /// The app's way of saving: a session that makes changes, and what a failed append left, written again ahead of
    /// the next changes.
    private struct Writer {
        var session = InkSession()
        var unwritten: [InkEvent] = []

        mutating func draw(_ points: [CanvasPoint], into store: InkStore) {
            session.draw(points, tool: .pen, colour: .blue, width: .inches(0.5))
            unwritten += session.takeEvents()
            if (try? store.append(unwritten)) != nil { unwritten.removeAll() }
        }

        mutating func undo(into store: InkStore) {
            session.undo()
            unwritten += session.takeEvents()
            if (try? store.append(unwritten)) != nil { unwritten.removeAll() }
        }
    }

    /// The file calls one compaction makes, in order, so each test can fail or crash at every one of them.
    private func compactionSteps() throws -> Int {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-steps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = try InkStore(folder: scratch)
        var writer = Writer()
        for i in 0..<5 { writer.draw(wave(i), into: store) }
        let counter = Counter()
        DurableFile.Fault.inject { _, _ in counter.next(); return nil }
        defer { DurableFile.Fault.inject(nil) }
        try store.compact()
        return counter.value
    }

    // MARK: Compaction fails at each step

    /// A failure at any one file call of a compaction, once or from then on until it clears: the compaction may or
    /// may not happen, drawing carries on, and once storage works again every change is written and reopens.
    func testAFailureAtAnyStepOfCompactionLosesNothing() throws {
        let steps = try compactionSteps()
        XCTAssertGreaterThanOrEqual(steps, 8, "open, write and flush the snapshot, rename it, the same for the log, and the folder flushes")
        for persistent in [false, true] {
            for failAt in 0..<steps {
                let folder = self.folder.appendingPathComponent("\(persistent)-\(failAt)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let store = try InkStore(folder: folder)
                var writer = Writer()
                for i in 0..<8 { writer.draw(wave(i), into: store) }
                writer.undo(into: store)

                let counter = Counter()
                DurableFile.Fault.inject { _, _ in
                    let n = counter.next()
                    return (n == failAt || (persistent && n > failAt)) ? .error(EIO) : nil
                }
                // The three steps, with strokes finished while the snapshot was being written and after.
                if let plan = store.beginCompaction() {
                    writer.draw(wave(20), into: store)
                    if let prepared = try? InkStore.writeSnapshot(plan) {
                        writer.draw(wave(21), into: store)
                        try? store.finishCompaction(prepared)
                    } else {
                        store.cancelCompaction()
                    }
                }
                writer.draw(wave(22), into: store)
                try? store.flush()
                DurableFile.Fault.inject(nil)

                // Storage works again: what was kept is written, and drawing carries on.
                if !writer.unwritten.isEmpty { try store.append(writer.unwritten); writer.unwritten.removeAll() }
                writer.draw(wave(23), into: store)
                XCTAssertTrue(writer.unwritten.isEmpty)
                try store.flush()
                XCTAssertEqual(store.session, writer.session)
                store.closeFiles()

                let reopened = try InkStore(folder: folder)
                XCTAssertEqual(reopened.session, writer.session,
                               "failing step \(failAt)\(persistent ? " onwards" : "") lost or doubled a change")
                // And it compacts cleanly afterwards.
                try reopened.compact()
                XCTAssertEqual(try InkStore(folder: folder).session, writer.session)
            }
        }
    }

    // MARK: A crash at each step of compaction

    /// A crash can stop compaction before any of its file calls. Copy the folder as it is just before each one, as a
    /// crash there would leave it, and reopen the copy: every stroke appended by then is there, none twice.
    func testACrashAtAnyStepOfCompactionLosesNothing() throws {
        let store = try InkStore(folder: folder)
        var writer = Writer()
        for i in 0..<8 { writer.draw(wave(i), into: store) }
        writer.undo(into: store)

        let crashes = Crashes(folder: folder, scratch: self.folder.appendingPathComponent("crashes"))
        crashes.expected = writer.session
        DurableFile.Fault.inject { _, _ in crashes.record(); return nil }
        let plan = try XCTUnwrap(store.beginCompaction())
        writer.draw(wave(20), into: store)
        crashes.expected = writer.session
        let prepared = try InkStore.writeSnapshot(plan)
        writer.draw(wave(21), into: store)
        crashes.expected = writer.session
        try store.finishCompaction(prepared)
        writer.draw(wave(22), into: store)
        crashes.expected = writer.session
        DurableFile.Fault.inject(nil)

        XCTAssertGreaterThanOrEqual(crashes.taken.count, 12)
        var carried = 0
        for (index, crash) in crashes.taken.enumerated() {
            let reopened = try InkStore(folder: crash.folder)
            XCTAssertEqual(reopened.session.ink, crash.expected.ink, "a crash before file call \(index) lost a stroke")
            XCTAssertEqual(reopened.session, crash.expected)
            if reopened.recovery.carriedEvents > 0 { carried += 1 }
        }
        XCTAssertGreaterThan(carried, 0,
                             "some crash fell between the new snapshot and the new log, and carried the old log's changes over")
    }

    /// The snapshot's rename succeeds and the new log can't be written: appends carry on into the old log, which still
    /// reopens with them, and the next flush writes the new log.
    func testWhenTheNewLogCannotBeWrittenAppendsCarryOnSafely() throws {
        let store = try InkStore(folder: folder)
        var writer = Writer()
        for i in 0..<6 { writer.draw(wave(i), into: store) }
        let plan = try XCTUnwrap(store.beginCompaction())
        let prepared = try InkStore.writeSnapshot(plan)
        DurableFile.Fault.inject { operation, path in
            operation == .open && path.hasSuffix(".ink.log.compacting") ? .error(ENOSPC) : nil
        }
        XCTAssertThrowsError(try store.finishCompaction(prepared))
        XCTAssertNil(store.beginCompaction(), "no new compaction until the new log is in place")
        for i in 10..<14 { writer.draw(wave(i), into: store) }
        XCTAssertTrue(writer.unwritten.isEmpty, "the old log takes the appends")
        // A crash now: the new snapshot and the old log still reopen with everything.
        let copy = folder.appendingPathComponent("../\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.copyItem(at: folder, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let crashed = try InkStore(folder: copy)
        XCTAssertEqual(crashed.session, writer.session)
        XCTAssertEqual(crashed.recovery.carriedEvents, 4)

        XCTAssertThrowsError(try store.flush(), "the flush says it could not finish")
        DurableFile.Fault.inject(nil)
        try store.flush()
        XCTAssertTrue(store.needsFlush == false)
        writer.draw(wave(30), into: store)
        store.closeFiles()
        let reopened = try InkStore(folder: folder)
        XCTAssertEqual(reopened.session, writer.session)
        XCTAssertEqual(reopened.recovery.carriedEvents, 0, "the new log was in place")
    }

    // MARK: A torn append whose trim fails

    /// A write tears part way through a record and the trim back fails too. Nothing more is appended behind the torn
    /// bytes: the next appends are refused until the trim works, and then everything reopens.
    func testATornAppendWhoseTrimFailsIsNeverFollowed() throws {
        let store = try InkStore(folder: folder)
        var writer = Writer()
        for i in 0..<4 { writer.draw(wave(i), into: store) }
        let whole = try Data(contentsOf: logURL).count

        DurableFile.Fault.inject { operation, _ in
            switch operation {
            case .write: .shortWrite(11, ENOSPC)
            case .truncate: .error(EIO)
            default: nil
            }
        }
        writer.draw(wave(4), into: store)
        XCTAssertEqual(writer.unwritten.count, 1, "the torn append failed")
        XCTAssertEqual(try Data(contentsOf: logURL).count, whole + 11, "the torn bytes are still there")

        // Storage has room again but still can't trim: the next append is refused rather than follow the torn bytes.
        DurableFile.Fault.inject { operation, _ in operation == .truncate ? .error(EIO) : nil }
        writer.draw(wave(5), into: store)
        XCTAssertEqual(writer.unwritten.count, 2)
        XCTAssertEqual(try Data(contentsOf: logURL).count, whole + 11, "nothing was written behind the torn record")

        DurableFile.Fault.inject(nil)
        writer.draw(wave(6), into: store)
        XCTAssertTrue(writer.unwritten.isEmpty)
        store.closeFiles()
        let reopened = try InkStore(folder: folder)
        XCTAssertEqual(reopened.recovery.droppedBytes, 0)
        XCTAssertEqual(reopened.session, writer.session)
        XCTAssertEqual(reopened.session.ink.count, 7)
    }

    /// The same torn append, its trim working: the next append goes straight on.
    func testATornAppendIsTrimmedBeforeTheNextOne() throws {
        let store = try InkStore(folder: folder)
        var writer = Writer()
        writer.draw(wave(0), into: store)
        DurableFile.Fault.inject { operation, _ in operation == .write ? .shortWrite(5, ENOSPC) : nil }
        writer.draw(wave(1), into: store)
        XCTAssertEqual(writer.unwritten.count, 1)
        DurableFile.Fault.inject(nil)
        writer.draw(wave(2), into: store)
        XCTAssertTrue(writer.unwritten.isEmpty)
        let reopened = try InkStore(folder: folder)
        XCTAssertEqual(reopened.recovery.droppedBytes, 0)
        XCTAssertEqual(reopened.session, writer.session)
    }

    // MARK: Undo history

    /// Undoing big strokes moves their points into redo steps; the history's budget counts them and drops the redo
    /// steps furthest away, keeping the one just undone.
    func testRedoStepsCountTowardTheHistoryBudget() {
        var session = InkSession()
        let big = 400_000
        let points = (0..<big).map { CanvasPoint(x: .inches(Double($0) * 0.001), y: .zero) }
        for _ in 0..<4 { session.draw(points, tool: .pen, colour: .sketch, width: .inches(0.5)) }
        var most = 0
        for _ in 0..<4 {
            session.undo()
            most = max(most, session.historyPoints)
        }
        XCTAssertLessThanOrEqual(most, InkSession.historyPointBudget)
        XCTAssertTrue(session.ink.isEmpty)
        XCTAssertTrue(session.canRedo, "the step just undone is kept")
        session.redo()
        XCTAssertEqual(session.ink.count, 1)
        XCTAssertEqual(session.ink.strokes.first?.id, StrokeID(1), "the one undone last comes back first")
        // Replaying the same events keeps the same history.
        var replayed = InkSession()
        var source = InkSession()
        for _ in 0..<4 { source.draw(points, tool: .pen, colour: .sketch, width: .inches(0.5)) }
        for _ in 0..<4 { source.undo() }
        source.redo()
        for event in source.takeEvents() { replayed.apply(event) }
        XCTAssertEqual(replayed, session)
    }
}

/// Counts calls from any thread; `next` returns the count before this call.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    @discardableResult func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count - 1 }
}

/// Copies of a canvas folder as a crash would leave it at given moments, with what each must reopen as.
private final class Crashes: @unchecked Sendable {
    struct Crash { let folder: URL; let expected: InkSession }
    let folder: URL, scratch: URL
    var taken: [Crash] = []
    /// What the folder must reopen as if a crash came now.
    var expected = InkSession()

    init(folder: URL, scratch: URL) {
        self.folder = folder
        self.scratch = scratch
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    func record() {
        let copy = scratch.appendingPathComponent("\(taken.count)")
        try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name != "crashes" {
            try? FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: copy.appendingPathComponent(name))
        }
        taken.append(Crash(folder: copy, expected: expected))
    }
}
