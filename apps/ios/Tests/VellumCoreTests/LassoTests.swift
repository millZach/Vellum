import Foundation
import XCTest
@testable import VellumCore

/// The lasso's rule (#7): a stroke is selected when at least half its points lie inside the loop, a text box when its
/// centre does, and only strokes near the loop are looked at. Every stroke here is made up for the test.
final class LassoTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .inches(x), y: .inches(y)) }

    /// A square loop from (0, 0) to (10, 10), drawn as a dense loop the way the Pencil leaves it.
    private func squareLoop(_ size: Double = 10, samples: Int = 400) -> [CanvasPoint] {
        (0..<samples).map { i in
            let t = Double(i) / Double(samples) * 4
            switch Int(t) {
            case 0: return p(size * t, 0)
            case 1: return p(size, size * (t - 1))
            case 2: return p(size * (3 - t), size)
            default: return p(0, size * (4 - t))
            }
        }
    }

    private func stroke(_ id: Int, from a: (Double, Double), to b: (Double, Double), points: Int = 21) -> InkStroke {
        InkStroke(id: StrokeID(id), tool: .pen, colour: .red, width: .inches(0.1),
                  points: (0..<points).map { k in
                      let t = Double(k) / Double(points - 1)
                      return p(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
                  })
    }

    func testAStrokeIsSelectedWhenAtLeastHalfOfItIsInside() throws {
        let lasso = try XCTUnwrap(Lasso(squareLoop()))
        XCTAssertTrue(lasso.selects(stroke(1, from: (2, 5), to: (8, 5))), "wholly inside")
        XCTAssertTrue(lasso.selects(stroke(2, from: (2, 5), to: (13, 5))), "its tail pokes out: 8 of 11 inches inside")
        XCTAssertFalse(lasso.selects(stroke(3, from: (8, 5), to: (20, 5))), "only clipped: 2 of 12 inches inside")
        XCTAssertFalse(lasso.selects(stroke(4, from: (12, 5), to: (20, 5))), "outside")
        XCTAssertEqual(Lasso.insideShare, 0.5)
    }

    /// A two-point line (a snapped line, or a pipe) is judged by how much of its length is inside, not by its ends.
    func testASparseStrokeIsJudgedAlongItsLength() throws {
        let lasso = try XCTUnwrap(Lasso(squareLoop()))
        XCTAssertFalse(lasso.selects(stroke(1, from: (-20, 5), to: (8, 5), points: 2)), "one end inside, a quarter of it")
        XCTAssertTrue(lasso.selects(stroke(2, from: (2, 5), to: (13, 5), points: 2)), "most of it inside")
        XCTAssertTrue(lasso.selects(stroke(3, from: (2, 2), to: (8, 2), points: 2)))
    }

    func testATextBoxIsSelectedWhenItsCentreIsInside() throws {
        let lasso = try XCTUnwrap(Lasso(squareLoop()))
        let inside = TextBox(id: TextBoxID(1), origin: p(6, 4), size: CanvasSize(width: .inches(6), height: .inches(2)),
                             fontSize: .inches(1), colour: .blue, text: "inside")
        let outside = TextBox(id: TextBoxID(2), origin: p(9, 4), size: CanvasSize(width: .inches(6), height: .inches(2)),
                              fontSize: .inches(1), colour: .blue, text: "outside")
        let selection = lasso.select(in: InkIndex(), texts: [inside, outside])
        XCTAssertEqual(selection.texts, [TextBoxID(1)])
        XCTAssertTrue(selection.strokes.isEmpty)
    }

    func testTheLoopClosesBackToItsStartAndEvenOddDecidesInside() throws {
        // An open "C": closing it back to the start makes a square.
        let open = Array(squareLoop()[0..<350])
        let lasso = try XCTUnwrap(Lasso(open))
        XCTAssertTrue(lasso.contains(p(5, 5)))
        XCTAssertFalse(lasso.contains(p(11, 5)))
        XCTAssertNil(Lasso([p(0, 0), p(1, 1)]), "two points enclose nothing")
        XCTAssertNil(Lasso([p(0, 0), p(1, 0), p(2, 0)]), "a straight line encloses nothing")
    }

    func testSelectingLooksOnlyAtStrokesNearTheLoop() throws {
        var strokes: [InkStroke] = []
        for i in 0..<1_000 {
            let x = Double(i % 40) * 10, y = Double(i / 40) * 10
            strokes.append(stroke(i + 1, from: (x + 1, y + 1), to: (x + 4, y + 3)))
        }
        let index = InkIndex(Ink(strokes: strokes))
        let lasso = try XCTUnwrap(Lasso(squareLoop(25).map { $0.offsetBy(dx: .inches(0.5), dy: .inches(0.5)) }))
        var work = InkIndex.Work()
        let selection = lasso.select(in: index, texts: [], work: &work)
        // The strokes in the first three columns of the first three rows lie wholly inside the 25-inch loop.
        XCTAssertEqual(selection.strokes.map(\.value), [1, 2, 3, 41, 42, 43, 81, 82, 83])
        XCTAssertLessThan(work.strokesVisited, 50, "not all 1,000 strokes")
        XCTAssertLessThanOrEqual(work.pointsInspected, selection.strokes.count * Lasso.pointsTested + 50 * Lasso.pointsTested)
    }

    func testALongStrokeIsJudgedOnABoundedNumberOfPoints() throws {
        let lasso = try XCTUnwrap(Lasso(squareLoop()))
        var work = InkIndex.Work()
        XCTAssertTrue(lasso.selects(stroke(1, from: (1, 5), to: (9, 5), points: 10_000), work: &work))
        XCTAssertLessThanOrEqual(work.pointsInspected, Lasso.pointsTested)
    }

    func testAHugeLoopKeepsABoundedNumberOfCorners() throws {
        let lasso = try XCTUnwrap(Lasso(squareLoop(10, samples: 20_000)))
        XCTAssertTrue(lasso.contains(p(5, 5)))
        XCTAssertFalse(lasso.contains(p(-1, 5)))
    }
}
