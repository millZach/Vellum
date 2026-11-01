#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import XCTest
@testable import VellumCore

/// The app's saver (`CanvasSaver`, `CanvasSavers`), driven as the app drives it: one owner per canvas, so reopening
/// and deleting wait for pending writes; a full Duo never drops ink; maintenance never holds up an append; and no file
/// work on the calling (main) thread. Every stroke here is made up for the test.
final class CanvasSaverTests: XCTestCase {
    private var library: CanvasLibrary!
    private var states: StateLog!
    private var clock: VirtualClock!
    private var thumbnails: CountingThumbnails!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-saver-\(UUID().uuidString)")
        library = CanvasLibrary(root: root)
        states = StateLog()
        clock = VirtualClock()
        thumbnails = CountingThumbnails()
    }

    override func tearDownWithError() throws {
        DurableFile.Fault.inject(nil)
        try? FileManager.default.removeItem(at: library.root)
    }

    private func savers(compactionThreshold: Int = 1 << 20) -> CanvasSavers {
        let states = states!
        return CanvasSavers(library: library, clock: clock, thumbnails: thumbnails,
                            compactionThreshold: compactionThreshold, report: { id, state in states.add(id, state) })
    }

    static func wave(_ i: Int, points: Int = 30) -> [CanvasPoint] {
        (0..<points).map { k in
            CanvasPoint(x: .feet(Double(i % 40) + Double(k) * 0.03), y: .feet(Double(i / 40) + 0.1 * sin(Double(k) / 3)))
        }
    }

    /// Draws strokes on a session and hands each to the saver, the way the canvas screen does.
    private func draw(_ range: Range<Int>, on session: inout InkSession, saver: CanvasSaver) {
        for i in range {
            session.draw(Self.wave(i), tool: .pen, colour: .blue, width: .inches(0.5))
            saver.save(session.takeEvents())
        }
    }

    /// The ink as the files hold it, opened afresh.
    private func onDisk(_ id: UUID) throws -> InkSession {
        try InkStore(folder: library.folder(for: id)).session
    }

    // MARK: One writer per canvas

    func testReopeningWhileSavesArePendingReusesTheSaverAndSeesEveryStroke() async throws {
        let id = try library.create().id
        let savers = savers()
        var (_, first, saver) = try await savers.open(id)
        draw(0..<200, on: &first, saver: saver)
        savers.close(saver)
        // Reopened at once, before those writes have finished.
        var (_, second, again) = try await savers.open(id)
        XCTAssertTrue(again === saver, "the canvas's one saver, not a second writer")
        XCTAssertEqual(second, first, "the reopened canvas has every stroke handed over before it")
        draw(200..<210, on: &second, saver: again)
        let ids = second.ink.strokes.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no stroke id is used twice")
        savers.close(again)
        await again.idle()
        XCTAssertEqual(try onDisk(id), second)
        XCTAssertEqual(try onDisk(id).ink.count, 210)
        XCTAssertTrue(savers.active.isEmpty, "everything written, so the saver let go")
    }

    func testReopeningDuringCompactionWaitsForNothingAndLosesNothing() async throws {
        let id = try library.create().id
        let savers = savers(compactionThreshold: 2_000)
        var (_, session, saver) = try await savers.open(id)
        let gate = Gate()
        saver.afterSnapshotWritten = { gate.wait() }
        saver.setPencilDown(true)
        draw(0..<40, on: &session, saver: saver)
        saver.setPencilDown(false)  // a quiet moment: the log has outgrown the snapshot, so compaction starts
        await gate.reached()

        // The snapshot is being written; a stroke finished now is appended at once, not after it.
        saver.setPencilDown(true)
        draw(40..<41, on: &session, saver: saver)
        await saver.appendsIdle()
        let copy = library.root.appendingPathComponent("crash-copy")
        try FileManager.default.copyItem(at: library.folder(for: id), to: copy)
        XCTAssertEqual(try InkStore(folder: copy).session.ink.count, 41,
                       "killed mid-compaction, the stroke finished during it is on the Duo")

        // Closed and reopened mid-compaction: the same saver, every stroke.
        savers.close(saver)
        let (_, reopened, again) = try await savers.open(id)
        XCTAssertTrue(again === saver)
        XCTAssertEqual(reopened, session)
        gate.open()
        again.setPencilDown(false)
        await again.idle()
        savers.close(again)
        await again.idle()
        XCTAssertEqual(try onDisk(id), session)
        let snapshot = try Data(contentsOf: library.folder(for: id).appendingPathComponent(InkStore.snapshotName))
        XCTAssertGreaterThan(snapshot.count, 2_000, "the compaction finished")
        XCTAssertTrue(savers.active.isEmpty)
    }

    func testDeletingWhileWritesArePendingWaitsForThemAndLeavesNothing() async throws {
        let id = try library.create().id
        let savers = savers(compactionThreshold: 2_000)
        var (_, session, saver) = try await savers.open(id)
        draw(0..<300, on: &session, saver: saver)
        savers.close(saver)
        try await savers.delete(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.folder(for: id).path))
        XCTAssertTrue(savers.active.isEmpty)
        XCTAssertEqual(thumbnails.removed.value, 1)
        do {
            _ = try await savers.open(id)
            XCTFail("a deleted canvas does not open")
        } catch {}
        XCTAssertTrue(savers.active.isEmpty)
        XCTAssertTrue(try library.list().isEmpty)
    }

    // MARK: Never drop unsaved ink

    func testAFullDuoKeepsTheInkSaysSoAndWritesItWhenThereIsRoom() async throws {
        let id = try library.create().id
        let savers = savers()
        var (_, session, saver) = try await savers.open(id)
        draw(0..<3, on: &session, saver: saver)
        await saver.idle()
        DurableFile.Fault.inject { operation, path in
            operation == .write && path.hasSuffix(InkStore.logName) ? .error(ENOSPC) : nil
        }
        draw(3..<8, on: &session, saver: saver)
        await saver.idle()
        XCTAssertEqual(states.last(id), .notSaved(outOfSpace: true))
        XCTAssertEqual(SaveState.notSaved(outOfSpace: true).title, "Not saved: this Duo is full")

        // Back to the list: the saver and its unwritten ink stay alive.
        savers.close(saver)
        await saver.idle()
        XCTAssertEqual(savers.active, [id], "closing never drops unwritten ink")
        clock.advance(by: 60)
        await saver.idle()
        XCTAssertEqual(states.last(id), .notSaved(outOfSpace: true), "still full, still trying")
        XCTAssertEqual(savers.active, [id])

        DurableFile.Fault.inject(nil)
        for _ in 0..<3 {
            clock.advance(by: CanvasSaver.longestRetry)
            await saver.idle()
        }
        XCTAssertEqual(states.last(id), .savedOnThisDuo)
        XCTAssertEqual(try onDisk(id), session)
        XCTAssertTrue(savers.active.isEmpty, "written, so the saver let go")
    }

    func testAFailingFlushIsRetriedUntilItWorks() async throws {
        let id = try library.create().id
        let savers = savers()
        var (_, session, saver) = try await savers.open(id)
        DurableFile.Fault.inject { operation, _ in operation == .fsync ? .error(EIO) : nil }
        draw(0..<2, on: &session, saver: saver)
        await saver.appendsIdle()
        clock.advance(by: CanvasSaver.flushInterval)
        await saver.idle()
        XCTAssertEqual(states.last(id), .notSaved(outOfSpace: false))
        DurableFile.Fault.inject(nil)
        clock.advance(by: CanvasSaver.longestRetry)
        await saver.idle()
        XCTAssertEqual(states.last(id), .savedOnThisDuo)
        savers.close(saver)
        await saver.idle()
        XCTAssertEqual(try onDisk(id), session)
    }

    // MARK: The main thread

    /// The canvas screen calls the saver on the main thread; none of the saver's file work may run there.
    func testTheSaverDoesNoFileWorkOnTheCallingThread() throws {
        XCTAssertTrue(Thread.isMainThread)
        let id = try library.create().id
        let savers = savers(compactionThreshold: 2_000)
        let before = FileWork.current
        let opened = expectation(description: "opened")
        nonisolated(unsafe) var result: (CanvasManifest, InkSession, CanvasSaver)?
        Task.detached { result = try? await savers.open(id); opened.fulfill() }
        wait(for: [opened], timeout: 10)
        var (_, session, saver) = try XCTUnwrap(result)
        saver.setPencilDown(true)
        draw(0..<60, on: &session, saver: saver)
        saver.setPencilDown(false)
        let appended = expectation(description: "appended")
        Task.detached { await saver.appendsIdle(); appended.fulfill() }
        wait(for: [appended], timeout: 10)
        clock.advance(by: CanvasSaver.flushInterval)
        let flushed = expectation(description: "flushed")
        saver.flushNow { _ in flushed.fulfill() }
        wait(for: [flushed], timeout: 10)
        let closed = expectation(description: "closed")
        savers.close(saver) { _ in closed.fulfill() }
        wait(for: [closed], timeout: 10)
        let work = FileWork.current - before
        XCTAssertGreaterThan(work.operations, 60)
        XCTAssertEqual(work.onMainThread, 0, "saver file work ran on the main thread")
    }

    // MARK: Thumbnails

    func testAMissingThumbnailIsDrawnOnOpeningAndAStaleOneAfterEdits() async throws {
        let id = try library.create().id
        let savers = savers()
        var (_, session, saver) = try await savers.open(id)
        await saver.idle()
        XCTAssertEqual(thumbnails.written.value, 1, "no thumbnail yet, so one is drawn on opening")
        savers.close(saver)
        await saver.idle()
        XCTAssertEqual(thumbnails.written.value, 1, "closing with nothing changed draws nothing")

        (_, session, saver) = try await savers.open(id)
        await saver.idle()
        XCTAssertEqual(thumbnails.written.value, 1, "the thumbnail shows the saved ink, so it is kept")
        draw(0..<5, on: &session, saver: saver)
        await saver.appendsIdle()
        clock.advance(by: CanvasSaver.flushInterval)
        await saver.idle()
        XCTAssertEqual(thumbnails.written.value, 2, "drawn again after the edits")
        XCTAssertEqual(thumbnails.lastInkCount, 5)

        thumbnails.forget()  // Caches purged
        savers.close(saver)
        await saver.idle()
        (_, session, saver) = try await savers.open(id)
        await saver.idle()
        XCTAssertEqual(thumbnails.written.value, 3, "a purged thumbnail is drawn again on reopening")
        savers.close(saver)
    }
}

// MARK: Test doubles

/// A clock the test moves by hand.
final class VirtualClock: SaverClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0.0
    private var timers: [(due: Double, work: @Sendable () -> Void)] = []

    func after(_ seconds: Double, _ work: @escaping @Sendable () -> Void) {
        lock.lock()
        timers.append((now + seconds, work))
        lock.unlock()
    }

    /// Moves time on and runs every timer that falls due.
    func advance(by seconds: Double) {
        lock.lock()
        now += seconds
        let due = timers.filter { $0.due <= now }
        timers.removeAll { $0.due <= now }
        lock.unlock()
        for timer in due { timer.work() }
    }
}

final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [UUID: [SaveState]] = [:]
    func add(_ id: UUID, _ state: SaveState) { lock.lock(); states[id, default: []].append(state); lock.unlock() }
    func last(_ id: UUID) -> SaveState? { lock.lock(); defer { lock.unlock() }; return states[id]?.last }
}

final class CountingThumbnails: CanvasThumbnails, @unchecked Sendable {
    let written = Counter(), removed = Counter()
    private let lock = NSLock()
    private var versions: [UUID: String] = [:]
    private var inkCount = 0
    var lastInkCount: Int { lock.lock(); defer { lock.unlock() }; return inkCount }

    func isCurrent(_ id: UUID, version: String) -> Bool { lock.lock(); defer { lock.unlock() }; return versions[id] == version }
    func write(_ id: UUID, ink: Ink, version: String) {
        lock.lock(); versions[id] = version; inkCount = ink.count; lock.unlock()
        written.next()
    }
    func remove(_ id: UUID) { lock.lock(); versions[id] = nil; lock.unlock(); removed.next() }
    func forget() { lock.lock(); versions.removeAll(); lock.unlock() }
}

/// Holds the maintenance queue at a point until the test opens it.
final class Gate: @unchecked Sendable {
    private let arrived = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    func wait() { arrived.signal(); release.wait() }
    func open() { release.signal() }
    func reached() async { await withCheckedContinuation { c in DispatchQueue.global().async { self.arrived.wait(); c.resume() } } }
}
