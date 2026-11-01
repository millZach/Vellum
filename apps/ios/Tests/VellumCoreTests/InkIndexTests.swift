import XCTest
@testable import VellumCore

/// The spatial index of ink: kept in step with the ink, and finding exactly what a look at every stroke would.
final class InkIndexTests: XCTestCase {
    /// A small, fixed random generator, so every run tests the same made-up ink.
    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func range(_ low: Double, _ high: Double) -> Double { low + next() * (high - low) }
    }

    /// Made-up ink at every scale the canvas has: dots, handwriting a few inches across, redlines feet long and plant
    /// runs hundreds of feet long, spread over a few hundred feet.
    private func randomInk(count: Int, seed: UInt64) -> InkSession {
        var random = Random(state: seed)
        var session = InkSession()
        for _ in 0..<count {
            let size = [0.0, 0.05, 3, 40, 2_000][Int(random.next() * 5)]
            let pointCount = size == 0 ? 1 : 2 + Int(random.next() * 30)
            var x = random.range(-3_000, 3_000), y = random.range(-2_000, 2_000)
            var points: [CanvasPoint] = []
            for _ in 0..<pointCount {
                points.append(CanvasPoint(x: .inches(x), y: .inches(y)))
                x += random.range(-1, 1) * size / 4
                y += random.range(-1, 1) * size / 4
            }
            let width = Length.inches([0.01, 0.3, 3, 40][Int(random.next() * 4)])
            session.draw(points, tool: random.next() < 0.9 ? .pen : .highlighter, colour: .red, width: width)
        }
        return session
    }

    private func bruteForce(_ ink: Ink, in box: InkIndex.Box) -> [StrokeID] {
        ink.strokes.filter { stroke in
            guard let b = stroke.bounds else { return false }
            return InkIndex.Box(b).intersects(box)
        }.map(\.id)
    }

    func testFindsTheSameStrokesAsALookAtEveryStrokeOnRandomInk() {
        let session = randomInk(count: 1_500, seed: 7)
        let index = InkIndex(session.ink)
        XCTAssertEqual(index.count, 1_500)
        var random = Random(state: 99)
        for _ in 0..<300 {
            let w = [0.01, 1, 50, 1_000, 10_000][Int(random.next() * 5)]
            let x = random.range(-3_500, 3_500), y = random.range(-2_500, 2_500)
            let box = InkIndex.Box(minX: x, minY: y, maxX: x + w, maxY: y + w * random.range(0.2, 2))
            XCTAssertEqual(index.strokeIDs(in: box), bruteForce(session.ink, in: box))
            XCTAssertEqual(index.strokes(in: box).map(\.id), bruteForce(session.ink, in: box))
        }
    }

    func testEraserHitsMatchALookAtEveryStrokeOnRandomInk() {
        let session = randomInk(count: 1_500, seed: 11)
        let index = InkIndex(session.ink)
        var random = Random(state: 5)
        var hitsSeen = 0
        for _ in 0..<2_000 {
            let point = CanvasPoint(x: .inches(random.range(-3_200, 3_200)), y: .inches(random.range(-2_200, 2_200)))
            let tolerance = Length.inches([0.01, 1, 20, 300][Int(random.next() * 4)])
            let expected = session.ink.strokes(hitAt: point, tolerance: tolerance).map(\.id)
            XCTAssertEqual(index.strokes(hitAt: point, tolerance: tolerance).map(\.id), expected)
            hitsSeen += expected.count
        }
        XCTAssertGreaterThan(hitsSeen, 100, "the random probes should hit some ink")
    }

    func testABoxOnTheEdgeOfAStrokeFindsIt() {
        var session = InkSession()
        session.draw([CanvasPoint(x: .inches(0), y: .inches(0)), CanvasPoint(x: .inches(10), y: .inches(0))],
                     tool: .pen, colour: .blue, width: .inches(2))
        let index = InkIndex(session.ink)
        // The ink reaches an inch either side of its centre line.
        XCTAssertEqual(index.strokeIDs(in: InkIndex.Box(minX: 11, minY: 1, maxX: 12, maxY: 2)).count, 1)
        XCTAssertEqual(index.strokeIDs(in: InkIndex.Box(minX: 11.01, minY: 1, maxX: 12, maxY: 2)).count, 0)
        XCTAssertEqual(index.bounds(of: StrokeID(1)), InkIndex.Box(minX: -1, minY: -1, maxX: 11, maxY: 1))
    }

    func testInsertAndRemoveKeepLookupsRight() {
        let session = randomInk(count: 400, seed: 3)
        var index = InkIndex()
        for stroke in session.ink.strokes { index.insert(stroke) }
        let everything = InkIndex.Box(minX: -1e6, minY: -1e6, maxX: 1e6, maxY: 1e6)
        XCTAssertEqual(index.strokeIDs(in: everything), session.ink.strokes.map(\.id))

        var kept = session.ink.strokes
        for stroke in session.ink.strokes where stroke.id.value % 3 == 0 {
            XCTAssertEqual(index.remove(stroke.id)?.id, stroke.id)
            kept.removeAll { $0.id == stroke.id }
        }
        XCTAssertNil(index.remove(StrokeID(3)), "a stroke already taken out is not there to remove")
        XCTAssertEqual(index.count, kept.count)
        XCTAssertEqual(index.strokeIDs(in: everything), kept.map(\.id))
        XCTAssertFalse(index.contains(StrokeID(3)))
        XCTAssertTrue(index.contains(StrokeID(1)))
        XCTAssertEqual(index.latestID, kept.last?.id)
    }

    func testSyncFollowsDrawingErasingUndoAndRedo() {
        var session = randomInk(count: 200, seed: 21)
        var index = InkIndex()
        var change = index.sync(with: session.ink)
        XCTAssertEqual(change.added.count, 200)
        XCTAssertTrue(change.addedOnTop)

        // A new stroke is drawn on top of the rest.
        session.draw([CanvasPoint(x: .inches(5), y: .inches(5))], tool: .pen, colour: .green, width: .inches(1))
        change = index.sync(with: session.ink)
        XCTAssertEqual(change.added.map(\.id), [StrokeID(201)])
        XCTAssertTrue(change.removed.isEmpty)
        XCTAssertTrue(change.addedOnTop)

        // An eraser sweep takes strokes out, found through the index.
        session.beginEraserSweep()
        var erased: [InkStroke] = []
        var random = Random(state: 8)
        while erased.isEmpty {
            let point = CanvasPoint(x: .inches(random.range(-3_000, 3_000)), y: .inches(random.range(-2_000, 2_000)))
            erased = session.erase(at: point, tolerance: .inches(200), index: index)
        }
        change = index.sync(with: session.ink)
        XCTAssertEqual(Set(change.removed.map(\.id)), Set(erased.map(\.id)))
        XCTAssertTrue(change.added.isEmpty)

        // Undo puts them back where they were, under newer strokes, so they are not on top.
        session.undo()
        change = index.sync(with: session.ink)
        XCTAssertEqual(Set(change.added.map(\.id)), Set(erased.map(\.id)))
        XCTAssertFalse(change.addedOnTop)

        session.redo()
        change = index.sync(with: session.ink)
        XCTAssertEqual(Set(change.removed.map(\.id)), Set(erased.map(\.id)))

        XCTAssertTrue(index.sync(with: session.ink).isEmpty, "a second sync finds nothing new")
        let everything = InkIndex.Box(minX: -1e6, minY: -1e6, maxX: 1e6, maxY: 1e6)
        XCTAssertEqual(index.strokeIDs(in: everything), session.ink.strokes.map(\.id))
    }

    func testErasingThroughTheIndexMatchesErasingWithout() {
        var withIndex = randomInk(count: 600, seed: 31)
        var without = withIndex
        var index = InkIndex(withIndex.ink)
        var random = Random(state: 17)
        withIndex.beginEraserSweep(); without.beginEraserSweep()
        for _ in 0..<400 {
            let point = CanvasPoint(x: .inches(random.range(-3_000, 3_000)), y: .inches(random.range(-2_000, 2_000)))
            let a = withIndex.erase(at: point, tolerance: .inches(30), index: index)
            let b = without.erase(at: point, tolerance: .inches(30))
            XCTAssertEqual(a.map(\.id), b.map(\.id))
            index.sync(with: withIndex.ink)
        }
        XCTAssertEqual(withIndex.ink, without.ink)
        withIndex.undo(); without.undo()
        XCTAssertEqual(withIndex.ink, without.ink)
    }

    func testStrokesOfEverySizeLandOnALevelWhoseCellsHoldThem() {
        for extent in [0.0, 1e-6, 0.003, 0.5, 1, 1.0000001, 3, 1_000, 4_096, 1e9] {
            let box = InkIndex.Box(minX: 0, minY: 0, maxX: extent, maxY: extent / 2)
            let level = InkIndex.level(for: box)
            XCTAssertGreaterThanOrEqual(InkIndex.cellSize(level), extent, "extent \(extent)")
            if level > InkIndex.finestLevel {
                XCTAssertLessThan(InkIndex.cellSize(level - 1), extent, "extent \(extent) on the smallest level that fits")
            }
        }
    }

    func testAHugeQueryAtTheFinestLevelStaysQuick() {
        // Many tiny dots and one query over the whole plant: the index walks the cells that hold ink, not the billions
        // of empty ones the box covers.
        var session = InkSession()
        for i in 0..<2_000 {
            session.draw([CanvasPoint(x: .inches(Double(i) * 0.37), y: .inches(Double(i % 50)))],
                         tool: .pen, colour: .sketch, width: .inches(0.001))
        }
        let index = InkIndex(session.ink)
        let found = index.strokeIDs(in: InkIndex.Box(minX: -1e7, minY: -1e7, maxX: 1e7, maxY: 1e7))
        XCTAssertEqual(found.count, 2_000)
    }

    // MARK: The stroke being drawn

    func testLiveChunksDrawEverySegmentOnceAndFreezeFullChunks() {
        var chunks = LiveStrokeChunks(chunkSize: 5)
        var frozenSoFar: [Range<Int>] = []
        var count = 1
        _ = chunks.update(pointCount: 1)
        // Samples arrive in batches of different sizes, as coalesced touches do.
        for batch in [1, 3, 2, 7, 1, 1, 12, 4] {
            count += batch
            let update = chunks.update(pointCount: count)
            frozenSoFar += update.newlyFrozen
            XCTAssertEqual(chunks.frozen, frozenSoFar, "frozen chunks never change")
            XCTAssertLessThanOrEqual(update.open.count, 5)
            XCTAssertEqual(update.open.upperBound, count)
            // Every segment (i, i+1) is in exactly one chunk.
            var segments = [Int](repeating: 0, count: count - 1)
            for range in chunks.frozen + [update.open] {
                XCTAssertLessThanOrEqual(range.count, 5)
                for i in range.dropLast() { segments[i] += 1 }
            }
            XCTAssertEqual(segments, [Int](repeating: 1, count: count - 1), "after \(count) points")
            // Chunks meet on a shared point.
            for (a, b) in zip(chunks.frozen, chunks.frozen.dropFirst() + [update.open]) {
                XCTAssertEqual(a.upperBound - 1, b.lowerBound)
            }
        }
    }

    func testLiveChunkWorkStaysBoundedOverALongStroke() {
        // A 10,000-sample stroke: each update touches the open chunk and at most the chunks a batch fills.
        var chunks = LiveStrokeChunks()
        var count = 1
        _ = chunks.update(pointCount: 1)
        var most = 0
        for _ in 0..<5_000 {
            count += 2
            let update = chunks.update(pointCount: count)
            most = max(most, update.open.count + update.newlyFrozen.reduce(0) { $0 + $1.count })
        }
        XCTAssertLessThanOrEqual(most, 2 * LiveStrokeChunks.defaultChunkSize)
        XCTAssertEqual(chunks.frozen.count, (count - 2) / (LiveStrokeChunks.defaultChunkSize - 1))
    }

    func testThePredictedTailStartsOnTheLastConfirmedPoint() {
        let a = CanvasPoint(x: .inches(0), y: .inches(0)), b = CanvasPoint(x: .inches(1), y: .inches(0))
        let p = CanvasPoint(x: .inches(2), y: .inches(0))
        XCTAssertEqual(LiveStrokeChunks.tail(confirmed: [a, b], predicted: [p]), [b, p])
        XCTAssertEqual(LiveStrokeChunks.tail(confirmed: [a, b], predicted: []), [])
        XCTAssertEqual(LiveStrokeChunks.tail(confirmed: [], predicted: [p]), [])
    }
}
