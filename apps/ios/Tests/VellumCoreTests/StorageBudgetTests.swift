import Foundation
import XCTest
@testable import VellumCore

/// The storage area's performance baselines (`docs/perf/baselines/storage.json`): work counts held to their budgets,
/// and timings recorded and compared with a warning, never a failure. Every stroke here is made up for the test.
final class StorageBudgetTests: XCTestCase {
    // MARK: The 10,000-stroke canvas

    static let strokes = 10_000, pointsEach = 120

    /// A hand-sized stroke a few inches long, drawn at a plant zoom: samples about a tenth of an inch apart.
    static func handwriting(_ i: Int) -> [CanvasPoint] {
        let ox = Double(i % 100) * 30, oy = Double(i / 100) * 30
        return (0..<pointsEach).map { k in
            let t = Double(k)
            return CanvasPoint(x: .inches(ox + t * 0.1), y: .inches(oy + 2 * sin(t / 7) + 0.3 * sin(t * 1.3)))
        }
    }

    /// A folder holding a 10,000-stroke canvas built the way the app builds one: one append per stroke, a flush every
    /// 50 strokes (a few seconds of drawing), compaction when the log outgrows the snapshot. Built once for the class.
    private struct BuiltCanvas {
        let folder: URL
        let bytesOnDisk: Int
    }

    nonisolated(unsafe) private static var built: BuiltCanvas?

    private static func builtCanvas() throws -> BuiltCanvas {
        if let built { return built }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try InkStore(folder: folder)
        var session = InkSession()
        for i in 0..<strokes {
            session.draw(handwriting(i), tool: .pen, colour: MarkupColour.allCases[i % 4], width: .inches(0.75))
            try store.append(session.takeEvents())
            if i % 50 == 49 { try store.flush() }
            if store.needsCompaction { try store.compact() }
        }
        try store.flush()
        let made = BuiltCanvas(folder: folder, bytesOnDisk: store.bytesOnDisk)
        built = made
        return made
    }

    override class func tearDown() {
        if let built { try? FileManager.default.removeItem(at: built.folder) }
        built = nil
        super.tearDown()
    }

    /// A copy of the built canvas to change, so each test starts from the same files.
    private func copyOfBuiltCanvas() throws -> URL {
        let source = try Self.builtCanvas().folder
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-budget-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        return copy
    }

    // MARK: Bytes

    func testAStrokeAppendsOnlyItsOwnBytesEvenOnAFullCanvas() throws {
        let store = try InkStore(folder: try copyOfBuiltCanvas())
        var session = store.session
        session.draw(Self.handwriting(0), tool: .pen, colour: .red, width: .inches(0.75))
        let before = FileWork.current
        try store.append(session.takeEvents())
        let work = FileWork.current - before
        assertWithinBudget("bytes-appended-per-typical-stroke", work.bytesWritten)
        assertWithinBudget("file-operations-per-append", work.operations)
    }

    func testATenThousandStrokeCanvasOnDisk() throws {
        assertWithinBudget("bytes-on-disk-10000-stroke-canvas", try Self.builtCanvas().bytesOnDisk)
    }

    func testCompactionRewritesOnlyTheSnapshotAndANewLog() throws {
        let store = try InkStore(folder: try copyOfBuiltCanvas())
        let before = FileWork.current
        let start = Date()
        try store.compact()
        let took = Date().timeIntervalSince(start)
        assertWithinBudget("bytes-rewritten-per-compaction", (FileWork.current - before).bytesWritten)
        record("compaction-10000-stroke-canvas", milliseconds: took * 1e3)
    }

    /// A canvas library holding a copy of the built canvas, for driving the app's saver on it.
    private func libraryWithBuiltCanvas() throws -> (CanvasLibrary, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-budget-lib-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = CanvasLibrary(root: root)
        let id = try library.create(name: "Budget (example)").id
        let source = try Self.builtCanvas().folder
        for name in [InkStore.snapshotName, InkStore.logName] {
            let target = library.folder(for: id).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: target)
        }
        return (library, id)
    }

    /// Runs async work to the end from a synchronous test on the main thread, without doing it on the main thread.
    private func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let done = expectation(description: "done")
        nonisolated(unsafe) var result: Result<T, Error>?
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        return try XCTUnwrap(result).get()
    }

    // MARK: Flushing

    /// A minute of continuous drawing through the app's saver, a stroke every half second, on a virtual clock: the log
    /// is flushed once every `FlushSchedule.interval`, however many strokes are drawn.
    func testAMinuteOfDrawingFlushesOnceEveryInterval() throws {
        let library = CanvasLibrary(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-flush-\(UUID().uuidString)"))
        addTeardownBlock { try? FileManager.default.removeItem(at: library.root) }
        let id = try library.create().id
        let clock = VirtualClock()
        let savers = CanvasSavers(library: library, clock: clock)
        let opened = try run { try await savers.open(id) }
        var session = opened.1
        let saver = opened.2
        let before = FileWork.current
        var flushSeconds: [Double] = []
        var i = 0
        var now = 0.0
        while now < 60 {
            let start = Date()
            let fsyncsBefore = FileWork.current.fsyncs
            clock.advance(by: 0.5)
            try run { await saver.appendsIdle() }
            if FileWork.current.fsyncs > fsyncsBefore { flushSeconds.append(Date().timeIntervalSince(start)) }
            session.draw(Self.handwriting(i), tool: .pen, colour: .blue, width: .inches(0.75))
            saver.save(session.takeEvents())
            try run { await saver.appendsIdle() }
            now += 0.5
            i += 1
        }
        let work = FileWork.current - before
        XCTAssertEqual(work.onMainThread, 0)
        XCTAssertEqual(try InkStore(folder: library.folder(for: id)).session.ink.count, 120)
        assertWithinBudget("fsyncs-per-minute-drawing", work.fsyncs)
        record("batch-flush", milliseconds: flushSeconds.reduce(0, +) / Double(max(flushSeconds.count, 1)) * 1e3)
    }

    // MARK: The Pencil's thread

    /// Committing a stroke through the app's saver costs the calling thread (the main thread, in the app) a session
    /// change and a queue hand-off; the write happens on the saver's queue. No file work runs on the calling thread.
    func testCommittingAStrokeDoesNoFileWorkOnTheCallingThread() throws {
        XCTAssertTrue(Thread.isMainThread, "tests run on the main thread, as the Pencil's touches do")
        let (library, id) = try libraryWithBuiltCanvas()
        let savers = CanvasSavers(library: library, clock: VirtualClock())
        let opened = try run { try await savers.open(id) }
        var session = opened.1
        let saver = opened.2
        let points = Self.handwriting(7)
        var callerSeconds = 0.0, slowest = 0.0
        let commits = 500
        let before = FileWork.current
        for _ in 0..<commits {
            var stroke = StrokeInProgress(tool: .pen, colour: .blue, width: .inches(0.5), start: points[0])
            for p in points.dropFirst() { stroke.add(p) }
            let start = Date()
            session.commit(stroke)
            saver.save(session.takeEvents())
            let took = Date().timeIntervalSince(start)
            callerSeconds += took
            slowest = max(slowest, took)
        }
        try run { await saver.appendsIdle() }
        let work = FileWork.current - before
        XCTAssertGreaterThanOrEqual(work.operations, commits, "the saver's queue did the writes")
        assertWithinBudget("main-thread-file-operations-per-stroke", work.onMainThread / commits)
        XCTAssertEqual(work.onMainThread, 0)
        let closed = expectation(description: "closed")
        savers.close(saver) { _ in closed.fulfill() }
        wait(for: [closed], timeout: 60)
        XCTAssertEqual(try InkStore(folder: library.folder(for: id)).session.ink.count, Self.strokes + commits)
        record("append-hand-off-calling-thread", microseconds: callerSeconds / Double(commits) * 1e6)
        print(String(format: "PERF storage append-hand-off-calling-thread slowest=%.1f µs", slowest * 1e6))
    }

    // MARK: Reopening

    func testReopeningATenThousandStrokeCanvas() throws {
        let folder = try Self.builtCanvas().folder
        let start = Date()
        let store = try InkStore(folder: folder)
        let took = Date().timeIntervalSince(start)
        XCTAssertEqual(store.session.ink.count, Self.strokes)
        record("reopen-10000-stroke-canvas", milliseconds: took * 1e3)
    }

    // MARK: The ink model

    /// The canvas screen owns the ink and the saver keeps its own replica, built from the same changes. Each changes
    /// its stroke list in place: the only copy is the one at opening, where both start from the ink as read.
    func testOneOwnerChangesTheInkInPlace() throws {
        let store = try InkStore(folder: try copyOfBuiltCanvas())
        // The canvas screen holds its session in a class, as `CanvasEditor` does.
        final class Owner { var session: InkSession; init(_ s: InkSession) { session = s } }
        let owner = Owner(store.session)
        var rng = SplitMix(seed: 9)
        var edits = 0
        for i in 0..<400 {
            switch rng.next() % 6 {
            case 0: owner.session.undo()
            case 1: owner.session.redo()
            case 2:
                owner.session.beginEraserSweep()
                owner.session.erase(at: Self.handwriting(Int(rng.next() % 10_000))[60], tolerance: .inches(0.5))
            default:
                owner.session.draw(Self.handwriting(i), tool: .pen, colour: .red, width: .inches(0.75))
            }
            let events = owner.session.takeEvents()
            try store.append(events)
            edits += events.count
        }
        let copies = owner.session.ink.work.copies + store.session.ink.work.copies
        XCTAssertGreaterThan(edits, 300)
        XCTAssertEqual(owner.session.ink, store.session.ink)
        assertWithinBudget("ink-copies-per-canvas-open", copies)
        assertWithinBudget("ink-copies-per-edit", (copies - 1) / edits)
    }

    /// Strokes laid out so every eraser sample takes 100 strokes spread across the whole canvas, the worst order for
    /// removing them: one sweep of 100 samples erases all 10,000, then undo puts them back and redo takes them again.
    func testABulkEraseAndItsUndoMoveEachStrokeAFewTimesNotTheWholeCanvas() {
        var session = InkSession()
        let groups = 100
        for i in 0..<Self.strokes {
            // Every stroke of group g starts at the same point, 10 ft from the next group's.
            let g = i % groups
            let start = CanvasPoint(x: .feet(Double(g) * 10), y: .zero)
            let end = CanvasPoint(x: .feet(Double(g) * 10 + 1), y: .feet(1 + Double(i / groups) * 0.01))
            session.draw([start, end], tool: .pen, colour: .sketch, width: .inches(0.25))
        }
        let full = session.ink
        let moved = { session.ink.work.strokesMoved }

        let beforeErase = moved()
        let start = Date()
        session.beginEraserSweep()
        for g in 0..<groups {
            XCTAssertEqual(session.erase(at: CanvasPoint(x: .feet(Double(g) * 10), y: .zero), tolerance: .inches(0.5)).count,
                           Self.strokes / groups)
        }
        let eraseSeconds = Date().timeIntervalSince(start)
        XCTAssertTrue(session.ink.isEmpty)
        XCTAssertEqual(session.undoSteps, InkSession.undoLimit, "the sweep is one undo step on top of the drawing")
        let erase = moved() - beforeErase

        let beforeUndo = moved()
        session.undo()
        let undo = moved() - beforeUndo
        XCTAssertEqual(session.ink, full)
        session.redo()
        XCTAssertTrue(session.ink.isEmpty)

        assertWithinBudget("strokes-moved-per-bulk-erase", erase)
        assertWithinBudget("strokes-moved-per-bulk-erase-undo", undo)
        record("bulk-erase-10000-strokes", milliseconds: eraseSeconds * 1e3)
    }

    /// Erasing 2,000 long strokes (1,000 points each), twenty to a sweep, would keep two million points in the undo
    /// history; the history keeps the newest sweeps under its budget and drops the oldest.
    func testTheUndoHistoryHoldsNoMoreGeometryThanItsBudget() {
        var session = InkSession()
        let groups = 100, perGroup = 20, pointsEach = 1_000
        for i in 0..<(groups * perGroup) {
            // Every stroke of group g starts at the same point, 100 ft from the next group's, and runs off its own way.
            let g = i % groups, slope = Double(i / groups + 1) * 0.05
            let points = (0..<pointsEach).map { k in
                CanvasPoint(x: .feet(Double(g) * 100) + .inches(Double(k) * 0.1), y: .inches(Double(k) * 0.1 * slope))
            }
            session.draw(points, tool: .pen, colour: .sketch, width: .inches(0.25))
        }
        var most = 0
        for g in 0..<groups {
            session.beginEraserSweep()
            XCTAssertEqual(session.erase(at: CanvasPoint(x: .feet(Double(g) * 100), y: .zero), tolerance: .inches(0.05)).count,
                           perGroup)
            most = max(most, session.historyPoints)
        }
        XCTAssertTrue(session.ink.isEmpty)
        assertWithinBudget("history-points-held", most)
        XCTAssertEqual(session.historyPoints, session.undoSteps * perGroup * pointsEach, "only erase steps are left")
        // The newest sweeps are the ones kept: undo brings back the last group erased.
        session.undo()
        XCTAssertEqual(session.ink.count, perGroup)
        XCTAssertEqual(session.ink.strokes.first?.points.first?.x, .feet(Double(groups - 1) * 100))
    }

    /// One sweep bigger than the whole budget is still undoable: the newest step is always kept.
    func testASweepBiggerThanTheBudgetCanStillBeUndone() {
        var session = InkSession()
        let points = (0..<2_000).map { CanvasPoint(x: .inches(Double($0) * 0.01), y: .zero) }
        for _ in 0..<600 { session.draw(points, tool: .pen, colour: .sketch, width: .inches(0.5)) }
        session.beginEraserSweep()
        session.erase(at: points[1_000], tolerance: .inches(0.1))
        XCTAssertGreaterThan(session.historyPoints, InkSession.historyPointBudget)
        XCTAssertEqual(session.undoSteps, 1)
        session.undo()
        XCTAssertEqual(session.ink.count, 600)
    }

    // MARK: Baselines

    func testTheBaselineFileIsRead() {
        XCTAssertFalse(StorageBaseline.all.isEmpty, "docs/perf/baselines/storage.json is missing or unreadable")
    }

    private func assertWithinBudget(_ metric: String, _ measured: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let baseline = StorageBaseline.all[metric], baseline.kind == "count" else {
            return XCTFail("no count baseline named \(metric) in docs/perf/baselines/storage.json", file: file, line: line)
        }
        print("PERF storage \(metric)=\(measured) \(baseline.unit) (budget \(Int(baseline.value)))")
        XCTAssertLessThanOrEqual(Double(measured), baseline.value,
                                 "\(metric) is over its budget in docs/perf/baselines/storage.json", file: file, line: line)
        if Double(measured) < baseline.value {
            print("PERF storage \(metric) came in under its budget: lower it in docs/perf/baselines/storage.json")
        }
    }

    private func record(_ metric: String, microseconds: Double, file: StaticString = #filePath, line: UInt = #line) {
        record(metric, value: microseconds, unit: "µs", file: file, line: line)
    }

    private func record(_ metric: String, milliseconds: Double, file: StaticString = #filePath, line: UInt = #line) {
        record(metric, value: milliseconds, unit: "ms", file: file, line: line)
    }

    /// Records a timing and warns, never fails, when it is worse than its baseline by more than the tolerance.
    private func record(_ metric: String, value measured: Double, unit: String, file: StaticString, line: UInt) {
        guard let baseline = StorageBaseline.all[metric], baseline.kind == "time" else {
            return XCTFail("no time baseline named \(metric) in docs/perf/baselines/storage.json", file: file, line: line)
        }
        XCTAssertEqual(baseline.unit, unit, "\(metric) is recorded in \(unit)", file: file, line: line)
        let shown = String(format: "%.1f", measured)
        print("PERF storage \(metric)=\(shown) \(unit) (baseline \(baseline.value) \(unit))")
        if measured > baseline.value * (1 + baseline.tolerance) {
            print("::warning title=Performance (storage)::\(metric) took \(shown) \(unit), more than "
                + "\(Int(baseline.tolerance * 100))% over its \(baseline.value) \(unit) baseline")
        }
    }
}

/// One entry of the storage area's baseline file.
private struct StorageBaseline: Decodable, Sendable {
    let metric: String
    let kind: String
    let value: Double
    let unit: String
    let tolerance: Double

    /// Read from the repository, so the file is the one place each number lives.
    static let all: [String: StorageBaseline] = {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // Tests/VellumCoreTests
            .appendingPathComponent("../../../../docs/perf/baselines/storage.json").standardizedFileURL
        guard let data = try? Data(contentsOf: file),
              let all = try? JSONDecoder().decode([StorageBaseline].self, from: data) else { return [:] }
        return Dictionary(all.map { ($0.metric, $0) }, uniquingKeysWith: { first, _ in first })
    }()
}
