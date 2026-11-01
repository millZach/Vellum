import Foundation
import XCTest
@testable import VellumCore

/// The canvas renderer's work budgets (docs/perf/README.md): deterministic counts of work on the made-up
/// 10,000-stroke canvas, each checked against `docs/perf/baselines/canvas-rendering.json`. A count above its budget
/// fails; a count well under it means the budget should be lowered in the same change. Each test also works out what
/// main at bd44a9a did for the same job (its "before"), from the way that renderer worked.
final class CanvasRenderingBudgetTests: XCTestCase {
    private static let ink = MadeUpInk.largeWalkdown()
    private static let index = InkIndex(ink)
    private static let totalPoints = ink.strokes.reduce(0) { $0 + $1.points.count }

    /// The canvas view on the unfolded Duo, zoomed to everything between the chrome, as the benchmark starts.
    private static var everything: Viewport {
        var viewport = Viewport(pointsPerInch: 1, screenWidth: 951, screenHeight: 669)
        viewport.fit(ink.bounds!, insets: ScreenInsets(top: 56, left: 70, bottom: 50, right: 92))
        return viewport
    }

    // MARK: The baseline file

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

    private func check(_ metric: String, _ measured: Double, before: Double, file: StaticString = #filePath,
                       line: UInt = #line) {
        print("budget \(metric): measured \(measured), before (main bd44a9a) \(before)")
        guard let budget = Self.baseline[metric] else {
            XCTFail("No budget for \(metric) in docs/perf/baselines/canvas-rendering.json", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(measured, budget, "\(metric) is over its budget", file: file, line: line)
    }

    func testTheFixtureIsTheOneTheBaselinesWereMeasuredOn() {
        XCTAssertEqual(Self.ink.strokes.count, 10_000)
        XCTAssertEqual(Self.totalPoints, Self.ink.strokes.reduce(0) { $0 + $1.points.count })
        print("fixture points \(Self.totalPoints)")
    }

    // MARK: Counts

    /// Culling a close-up view (four times the zoom of everything): strokes whose bounds are compared. Main compared
    /// every stroke's bounds, and worked each one out again from all its points.
    func testCullingAViewVisitsOnlyNearbyStrokes() {
        var viewport = Self.everything
        viewport.zoom(by: 4, about: ScreenPoint(x: 951 / 2, y: 669 / 2))
        var work = InkIndex.Work()
        let visible = Self.index.strokeIDs(in: InkIndex.Box(viewport.visibleRect), work: &work)
        XCTAssertGreaterThan(visible.count, 100)
        check("cull_strokes_visited", Double(work.strokesVisited), before: Double(Self.ink.strokes.count))
        check("cull_points_inspected", Double(work.pointsInspected), before: Double(Self.totalPoints))
    }

    /// The benchmark's eraser sweep at everything: stroke points looked at per Pencil sample, on average. Main
    /// worked out every remaining stroke's bounds from all its points for every sample, then measured every segment
    /// of each stroke near the tip.
    func testAnEraserSampleInspectsFewPoints() {
        let viewport = Self.everything
        var session = InkSession(ink: Self.ink)
        var index = Self.index
        let tolerance = viewport.canvasLength(ofScreen: 8)
        var work = InkIndex.Work()
        var beforePoints = 0
        var samples = 0
        session.beginEraserSweep()
        var x = 100.0
        func sample(_ x: Double) -> CanvasPoint {
            let phase = (x / 60).truncatingRemainder(dividingBy: 2)
            let y = 669 / 2 - 100 + 200 * (phase < 1 ? phase : 2 - phase)
            return viewport.canvasPoint(for: ScreenPoint(x: x, y: y))
        }
        for _ in 0..<479 {
            let point = sample(x)
            x += 1.5
            // Main: every stroke's bounds from its points, then every segment of those within reach.
            for stroke in session.ink.strokes {
                beforePoints += stroke.points.count
                if let box = stroke.bounds?.insetBy(-tolerance), box.contains(point) { beforePoints += stroke.points.count }
            }
            let hits = index.strokes(hitAt: point, tolerance: tolerance, work: &work)
            let erased = session.erase(at: point, tolerance: tolerance, index: index)
            XCTAssertEqual(hits.map(\.id), erased.map(\.id))
            index.sync(with: session.ink)
            samples += 1
        }
        XCTAssertLessThan(session.ink.strokes.count, 10_000, "the sweep erases ink")
        check("eraser_points_inspected_per_sample", (Double(work.pointsInspected) / Double(samples)).rounded(.up),
              before: (Double(beforePoints) / Double(samples)).rounded(.up))
        check("eraser_strokes_visited_per_sample", (Double(work.strokesVisited) / Double(samples)).rounded(.up),
              before: Double(Self.ink.strokes.count))
    }

    /// A pan, and a pinch to the next level, after the view was drawn once: paths built for the tiles the renderer's
    /// book asks for. Main built a path for every visible stroke on every redraw.
    func testARedrawRebuildsNoPaths() {
        let harness = InkTileHarness(index: Self.index)
        var viewport = Self.everything
        harness.book.show(viewport)
        harness.drawAll()
        let firstBuilds = harness.paths.buildCount
        XCTAssertEqual(firstBuilds, Self.ink.strokes.count, "everything is in view, so every path is built once")
        viewport.pan(dx: 240, dy: 60)
        harness.book.show(viewport)
        harness.drawAll()
        viewport.zoom(by: 1.3, about: ScreenPoint(x: 400, y: 300))
        harness.book.show(viewport)
        harness.drawAll()
        XCTAssertGreaterThan(harness.book.work.tilesDrawn, 0, "the pan and the zoom drew tiles")
        let visibleAtEverything = Self.index.strokeIDs(in: InkIndex.Box(Self.everything.visibleRect)).count
        check("paths_rebuilt_per_redraw", Double(harness.paths.buildCount - firstBuilds), before: Double(visibleAtEverything))
    }

    /// A short stroke, 60 by 30 points, drawn in the middle of the screen at everything: the screen area of the tiles
    /// the renderer's book asks to draw for it. Main redrew the whole view, background and grid included.
    func testANewStrokeRedrawsOnlyTheTilesItTouches() {
        let viewport = Self.everything
        let harness = InkTileHarness(index: Self.index)
        harness.book.show(viewport)
        harness.drawAll()
        let corner = viewport.canvasPoint(for: ScreenPoint(x: 951 / 2 - 30, y: 669 / 2 - 15))
        let size = viewport.canvasLength(ofScreen: 60), height = viewport.canvasLength(ofScreen: 30)
        let stroke = InkStroke(id: StrokeID(99_999), tool: .pen, colour: .red, width: viewport.canvasLength(ofScreen: 3),
                               points: [corner, corner.offsetBy(dx: size, dy: height)])
        harness.book.work = .init()
        harness.book.inkChanged(InkIndex.Change(added: [stroke], addedOnTop: true))
        XCTAssertTrue(harness.requests.allSatisfy { $0.adding?.map(\.id) == [stroke.id] }, "drawn over, not redrawn")
        check("area_invalidated_per_new_stroke_pt2", harness.book.work.areaDrawn.rounded(.up), before: 951 * 669)
    }

    /// The same measure catches a renderer that redraws everything: a full redraw asks for at least the screen.
    func testTheInvalidationMeasureSeesAFullRedraw() {
        let harness = InkTileHarness(index: Self.index)
        harness.book.show(Self.everything)
        harness.drawAll()
        harness.book.work = .init()
        harness.book.redrawEverything()
        XCTAssertGreaterThanOrEqual(harness.book.work.areaDrawn, 951 * 669)
        XCTAssertGreaterThan(harness.book.work.areaDrawn, Self.baseline["area_invalidated_per_new_stroke_pt2"] ?? 0)
    }

    /// Erasing a stroke that spans the whole plant while zoomed all the way in: tile positions looked at to find the
    /// tiles it touched. Looking at every position its bounds span (what #23 first did) is hundreds of millions.
    func testErasingALongStrokeLooksOnlyAtCachedTiles() {
        let bounds = Self.ink.bounds!
        let long = InkStroke(id: StrokeID(99_998), tool: .pen, colour: .red, width: .inches(1),
                             points: [bounds.origin, bounds.origin.offsetBy(dx: bounds.size.width, dy: bounds.size.height)])
        var index = Self.index
        index.insert(long)
        let harness = InkTileHarness(index: index)
        var viewport = Self.everything
        viewport.zoom(by: Viewport.maximumPointsPerInch / viewport.pointsPerInch, about: ScreenPoint(x: 951 / 2, y: 669 / 2))
        viewport.centre = CanvasPoint(x: .inches(bounds.origin.x.inches + bounds.size.width.inches / 2),
                                      y: .inches(bounds.origin.y.inches + bounds.size.height.inches / 2))
        harness.book.show(viewport)
        harness.drawAll()
        let level = harness.book.current!
        let range = level.tiling.keyRange(covering: InkIndex.box(of: long)!.grown(by: level.tiling.margin(minimumWidth: 1)))
        harness.book.work = .init()
        harness.book.inkChanged(InkIndex.Change(removed: [long], addedOnTop: false))
        XCTAssertLessThanOrEqual(harness.book.work.keysProbed, level.tiles.count)
        check("tile_keys_probed_per_erased_stroke", Double(harness.book.work.keysProbed),
              before: Double(range.x.count) * Double(range.y.count))
    }

    /// The stroke being drawn, 10,000 samples long, two a move and two predicted: points turned into path per move,
    /// at most. Main rebuilt the whole stroke and its prediction on every move.
    func testALiveStrokeMoveRebuildsABoundedPath() {
        var chunks = LiveStrokeChunks()
        var count = 1
        _ = chunks.update(pointCount: 1)
        var most = 0
        for _ in 0..<5_000 {
            count += 2
            let update = chunks.update(pointCount: count)
            let tail = 1 + 2
            most = max(most, update.open.count + update.newlyFrozen.reduce(0) { $0 + $1.count } + tail)
        }
        check("live_path_points_per_move", Double(most), before: Double(count + 2))
    }

    // MARK: Tiling

    func testTheLevelNeverMagnifiesAndShrinksByAtMostRootTwo() {
        var ppi = Viewport.minimumPointsPerInch
        while ppi <= Viewport.maximumPointsPerInch {
            let level = InkTiling.level(for: ppi)
            let ratio = ppi / InkTiling.scale(level: level)
            XCTAssertLessThanOrEqual(ratio, 1 + 1e-9)
            XCTAssertGreaterThan(ratio, 0.7071)
            XCTAssertTrue(InkTiling.keeps(level: level, at: ppi))
            ppi *= 1.07
        }
    }

    /// Draw with finger (#24): a finger stroke a second finger cancels inside the window commits nothing and saves
    /// nothing, and a cancelled finger eraser sweep erases nothing. There was no finger path before, so "before" is 0.
    func testACancelledFingerStrokeCommitsAndSavesNothing() throws {
        var stroke = FingerCanvas()
        stroke.down(at: 0, x: 1)
        stroke.move(at: 0.03, x: 1.5)
        stroke.secondFinger(at: 0.06)
        stroke.up(x: 2)
        check("finger_cancelled_strokes_committed",
              Double(stroke.session.ink.strokes.count + stroke.session.undoSteps), before: 0)
        check("finger_cancelled_bytes_saved", Double(try stroke.bytesSaved()), before: 0)

        var sweep = FingerCanvas(strokesAcross: 3)
        _ = try sweep.bytesSaved()
        sweep.tool = .eraser
        sweep.down(at: 0, x: 0.5, y: 0.5)
        sweep.move(at: 0.05, x: 0.5, y: 2.5)
        sweep.secondFinger(at: 0.08)
        check("finger_cancelled_sweep_strokes_erased", Double(3 - sweep.session.ink.strokes.count), before: 0)
    }

    func testTilesCoverTheirRegionWithoutGaps() {
        let tiling = InkTiling(level: 3, anchor: CanvasPoint(x: .inches(1_000), y: .inches(-500)))
        let box = InkIndex.Box(minX: 990, minY: -530, maxX: 1_200, maxY: -400)
        let keys = tiling.keys(covering: box)
        for key in keys { XCTAssertTrue(tiling.box(of: key).intersects(box)) }
        // Every corner and the middle lie in some tile.
        for (x, y) in [(990.0, -530.0), (1_200, -400), (1_095, -465)] {
            XCTAssertTrue(keys.contains { let b = tiling.box(of: $0); return x >= b.minX && x <= b.maxX && y >= b.minY && y <= b.maxY })
        }
        XCTAssertFalse(tiling.isFar(from: CanvasPoint(x: .inches(1_100), y: .inches(-500))))
        XCTAssertTrue(tiling.isFar(from: CanvasPoint(x: .inches(1e7), y: .inches(0))))
    }

    func testThePathCacheBuildsEachStrokeOnceAndForgetsErasedOnes() {
        let cache = StrokePathCache<[CanvasPoint]> { points, origin in
            points.map { CanvasPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        }
        let stroke = Self.ink.strokes[0]
        let (path, origin) = cache.path(for: stroke)
        XCTAssertEqual(origin, stroke.points[0])
        XCTAssertEqual(path.first, .origin)
        _ = cache.path(for: stroke)
        XCTAssertEqual(cache.buildCount, 1)
        cache.remove([stroke.id])
        XCTAssertEqual(cache.count, 0)
    }
}
