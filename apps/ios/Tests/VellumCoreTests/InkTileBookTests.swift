import Foundation
import XCTest
@testable import VellumCore

/// The renderer's bookkeeping: coverage kept through quick pinches, and the path cache's behaviour under the two
/// drawing threads.
final class InkTileBookTests: XCTestCase {
    private static let ink = MadeUpInk.largeWalkdown(strokes: 2_000)

    private var everything: Viewport {
        var viewport = Viewport(pointsPerInch: 1, screenWidth: 951, screenHeight: 669)
        viewport.fit(Self.ink.bounds!, insets: ScreenInsets(top: 56, left: 70, bottom: 50, right: 92))
        return viewport
    }

    // MARK: Coverage

    func testAQuickPinchKeepsTheDrawnLevelUntilTheNewOneCoversTheScreen() {
        let harness = InkTileHarness(index: InkIndex(Self.ink))
        var viewport = everything
        harness.book.show(viewport)
        harness.drawAll()
        let drawn = harness.book.current!
        XCTAssertTrue(harness.book.covers(drawn))

        // Two level changes before anything new is drawn: the drawn level stays, the unfinished one goes.
        viewport.zoom(by: 1.6, about: ScreenPoint(x: 400, y: 300))
        harness.book.show(viewport)
        let unfinished = harness.book.current!
        XCTAssertFalse(unfinished === drawn)
        XCTAssertTrue(harness.book.fallback === drawn)
        viewport.zoom(by: 1.6, about: ScreenPoint(x: 400, y: 300))
        harness.book.show(viewport)
        XCTAssertTrue(harness.book.fallback === drawn, "the drawn level is kept, not the unfinished one")
        XCTAssertFalse(unfinished.isLive)
        XCTAssertTrue(drawn.isLive)

        // Once the new level is drawn, the old one goes.
        harness.drawAll()
        XCTAssertTrue(harness.book.covers(harness.book.current!))
        XCTAssertNil(harness.book.fallback)
        XCTAssertFalse(drawn.isLive)
    }

    func testAPinchBackOutKeepsALevelThatStillCovers() {
        let harness = InkTileHarness(index: InkIndex(Self.ink))
        var viewport = everything
        viewport.zoom(by: 4, about: ScreenPoint(x: 475, y: 335))
        harness.book.show(viewport)
        harness.drawAll()
        viewport.zoom(by: 1.6, about: ScreenPoint(x: 475, y: 335))
        harness.book.show(viewport)
        harness.drawAll()
        let second = harness.book.current!
        // In again, then straight back out: the second level still covers the screen, so it becomes the one kept.
        viewport.zoom(by: 1.6, about: ScreenPoint(x: 475, y: 335))
        harness.book.show(viewport)
        viewport.zoom(by: 1 / 1.6, about: ScreenPoint(x: 475, y: 335))
        harness.book.show(viewport)
        XCTAssertNotNil(harness.book.fallback)
        XCTAssertTrue(harness.book.fallback!.isLive)
        XCTAssertTrue(harness.book.fallback === second || harness.book.current!.tiling.level == second.tiling.level)
    }

    func testAStrokeDrawnOnTopKeepsTheFallbackAndAnEraseDropsIt() {
        let harness = InkTileHarness(index: InkIndex(Self.ink))
        var viewport = everything
        harness.book.show(viewport)
        harness.drawAll()
        viewport.zoom(by: 1.6, about: ScreenPoint(x: 400, y: 300))
        harness.book.show(viewport)
        let stroke = InkStroke(id: StrokeID(50_000), tool: .pen, colour: .red, width: .inches(1),
                               points: [viewport.centre, viewport.centre.offsetBy(dx: .inches(10), dy: .inches(3))])
        harness.book.inkChanged(InkIndex.Change(added: [stroke], addedOnTop: true))
        XCTAssertNotNil(harness.book.fallback, "a new stroke shows on its live layers; the kept level is still right")
        harness.book.inkChanged(InkIndex.Change(removed: [stroke], addedOnTop: false))
        XCTAssertNil(harness.book.fallback, "the kept level would still show erased ink")
    }

    func testATileBeingDrawnIsAskedForOnceAndRedrawnIfInkChangedMeanwhile() {
        let harness = InkTileHarness(index: InkIndex(Self.ink))
        let viewport = everything
        harness.book.show(viewport)
        let level = harness.book.current!
        let tile = level.tiles.values.first!
        XCTAssertTrue(harness.book.begin(tile, in: level))
        let startedAt = tile.epoch
        let stroke = Self.ink.strokes.first { InkIndex.box(of: $0)!.intersects(level.tiling.box(of: tile.key)) }!
        let before = harness.book.work.tilesDrawn
        harness.book.inkChanged(InkIndex.Change(removed: [stroke], addedOnTop: false))
        XCTAssertGreaterThan(tile.epoch, startedAt)
        harness.book.finished(tile, in: level, epoch: startedAt, drewImage: true)
        XCTAssertFalse(tile.isUpToDate)
        XCTAssertTrue(tile.waiting, "redrawn after the drawing that was in flight")
        XCTAssertGreaterThan(harness.book.work.tilesDrawn, before)
    }

    // MARK: The path cache under two drawing threads

    /// Counts calls to the build function from any thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testThreadsWantingTheSamePathBuildItOnce() {
        let builds = Counter()
        let cache = StrokePathCache<Int> { points, _ in
            builds.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return points.count
        }
        let stroke = Self.ink.strokes[0]
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            XCTAssertEqual(cache.path(for: stroke).path, stroke.points.count)
        }
        XCTAssertEqual(builds.count, 1)
        XCTAssertEqual(cache.buildCount, 1)
        XCTAssertEqual(cache.count, 1)
    }

    func testAStrokeErasedWhileItsPathIsBuiltIsNotPutBack() {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let builds = Counter()
        let cache = StrokePathCache<Int> { points, _ in
            builds.increment()
            if builds.count == 1 {
                started.signal()
                release.wait()
            }
            return points.count
        }
        let stroke = Self.ink.strokes[1]
        DispatchQueue.global().async {
            _ = cache.path(for: stroke)
            done.signal()
        }
        started.wait()
        cache.remove([stroke.id])
        release.signal()
        done.wait()
        XCTAssertEqual(cache.count, 0, "the older job's path is not published after the erase")
        // Undo brings the stroke back: it is built again, fresh.
        XCTAssertEqual(cache.path(for: stroke).path, stroke.points.count)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(builds.count, 2)
    }
}
