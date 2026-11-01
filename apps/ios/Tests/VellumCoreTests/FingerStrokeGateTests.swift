import XCTest
@testable import VellumCore

/// Draw with finger (#24): when a finger stroke becomes ink, and that a stroke cancelled by a second finger leaves
/// nothing behind. Every stroke here is made up for the test.
final class FingerStrokeGateTests: XCTestCase {
    private let window = FingerStrokeGate.secondFingerWindow

    // MARK: The switch

    func testTheSwitchIsOffByDefault() {
        XCTAssertFalse(FingerDrawingSetting.default)
        XCTAssertEqual(FingerDrawingSetting.storageKey, "drawsWithFinger")
    }

    func testWithTheSwitchOffAFingerNeverDraws() {
        XCTAssertFalse(FingerDrawingSetting.draws(.finger, fingerDraws: false))
        XCTAssertTrue(FingerDrawingSetting.draws(.finger, fingerDraws: true))
    }

    func testThePencilAlwaysDraws() {
        XCTAssertTrue(FingerDrawingSetting.draws(.pencil, fingerDraws: false))
        XCTAssertTrue(FingerDrawingSetting.draws(.pencil, fingerDraws: true))
    }

    func testTheCanvasDescribesBothPositionsOfTheSwitch() {
        XCTAssertEqual(FingerDrawingSetting.accessibilityHint(fingerDraws: false),
                       "Draw with the Apple Pencil. Pan and pinch with your fingers.")
        XCTAssertEqual(FingerDrawingSetting.accessibilityHint(fingerDraws: true),
                       "Draw with the Apple Pencil or one finger. Pan and pinch with two fingers.")
    }

    func testTheWindowIsAShortOne() {
        XCTAssertGreaterThanOrEqual(window, 0.120)
        XCTAssertLessThanOrEqual(window, 0.150)
    }

    // MARK: The gate

    func testOneFingerIsConfirmedOnceTheWindowPassesAndKeptWhenItLifts() {
        var gate = FingerStrokeGate()
        gate.fingerDown(at: 10)
        XCTAssertTrue(gate.isPending)
        XCTAssertFalse(gate.tick(at: 10 + window / 2))
        XCTAssertTrue(gate.isPending)
        XCTAssertTrue(gate.tick(at: 10 + window))
        XCTAssertEqual(gate.phase, .confirmed)
        XCTAssertFalse(gate.tick(at: 11), "confirmed once, not again")
        XCTAssertTrue(gate.lift())
        XCTAssertEqual(gate.phase, .idle)
    }

    func testAShortStrokeLiftedInsideTheWindowIsKept() {
        var gate = FingerStrokeGate()
        gate.fingerDown(at: 0)
        XCTAssertTrue(gate.lift(), "a dot or a tick lifted before a second finger came was one finger")
    }

    func testASecondFingerInsideTheWindowCancels() {
        var gate = FingerStrokeGate()
        gate.fingerDown(at: 5)
        XCTAssertEqual(gate.secondFinger(at: 5 + window - 0.001), .cancel)
        XCTAssertEqual(gate.phase, .cancelled)
        XCTAssertFalse(gate.lift())
        XCTAssertFalse(gate.interrupted())
    }

    func testASecondFingerAfterTheWindowEndsTheStrokeKept() {
        var gate = FingerStrokeGate()
        gate.fingerDown(at: 5)
        XCTAssertEqual(gate.secondFinger(at: 5 + window), .end, "at the window's edge it is already one finger")

        gate.fingerDown(at: 20)
        gate.tick(at: 20.5)
        XCTAssertEqual(gate.secondFinger(at: 21), .end)
        XCTAssertEqual(gate.phase, .idle)
    }

    func testAnInterruptionKeepsAConfirmedStrokeAndDropsAPendingOne() {
        var gate = FingerStrokeGate()
        gate.fingerDown(at: 0)
        XCTAssertFalse(gate.interrupted())
        gate.fingerDown(at: 1)
        gate.tick(at: 2)
        XCTAssertTrue(gate.interrupted())
        XCTAssertEqual(gate.phase, .idle)
    }

    func testAPencilStrokeNeverEntersTheGateSoASecondFingerDoesNothing() {
        var gate = FingerStrokeGate()
        XCTAssertEqual(gate.secondFinger(at: 0), .none)
        XCTAssertFalse(gate.lift())
        XCTAssertEqual(gate.phase, .idle)
    }

    // MARK: Through the ink, as the canvas view routes it

    func testOneFingerDrawsAStrokeThatIsCommittedAndSaved() throws {
        var finger = FingerCanvas()
        finger.down(at: 0, x: 1)
        for i in 1...20 { finger.move(at: Double(i) * 0.01, x: 1 + Double(i) * 0.1) }
        finger.up(x: 3.1)
        XCTAssertEqual(finger.session.ink.strokes.count, 1)
        XCTAssertTrue(finger.session.canUndo)
        XCTAssertGreaterThan(try finger.bytesSaved(), 0)
    }

    func testASecondFingerInsideTheWindowCommitsAndSavesNothing() throws {
        var finger = FingerCanvas()
        finger.down(at: 0, x: 1)
        finger.move(at: 0.03, x: 1.5)
        XCTAssertTrue(finger.isShowingLiveInk, "live ink shows at once, even while pending")
        finger.secondFinger(at: 0.06)
        XCTAssertFalse(finger.isShowingLiveInk, "the live ink is removed")
        finger.up(x: 2)
        XCTAssertEqual(finger.session.ink.strokes.count, 0)
        XCTAssertFalse(finger.session.canUndo)
        XCTAssertEqual(try finger.bytesSaved(), 0)
    }

    func testASecondFingerAfterTheWindowKeepsTheStrokeDrawnSoFar() {
        var finger = FingerCanvas()
        finger.down(at: 0, x: 1)
        for i in 1...30 { finger.move(at: Double(i) * 0.01, x: 1 + Double(i) * 0.1) }
        finger.secondFinger(at: 0.31)
        XCTAssertEqual(finger.session.ink.strokes.count, 1)
        XCTAssertEqual(finger.session.ink.strokes[0].points.count, 31)
    }

    func testAFingerEraserSweepHoldsItsSamplesUntilConfirmed() {
        var finger = FingerCanvas(strokesAcross: 3)
        finger.tool = .eraser
        finger.down(at: 0, x: 0.5, y: 0.5)
        finger.move(at: 0.05, x: 0.5, y: 1.5)
        XCTAssertEqual(finger.session.ink.strokes.count, 3, "nothing is erased while pending")
        finger.move(at: 0.2, x: 0.5, y: 2.5)
        XCTAssertEqual(finger.session.ink.strokes.count, 0, "confirmed: what it held is erased")
        finger.up(x: 0.5, y: 2.5)
        finger.session.undo()
        XCTAssertEqual(finger.session.ink.strokes.count, 3, "one sweep, one undo step")
    }

    func testACancelledFingerEraserSweepErasesNothing() throws {
        var finger = FingerCanvas(strokesAcross: 3)
        finger.tool = .eraser
        _ = try finger.bytesSaved()
        finger.down(at: 0, x: 0.5, y: 0.5)
        finger.move(at: 0.05, x: 0.5, y: 1.5)
        finger.secondFinger(at: 0.08)
        finger.up(x: 0.5, y: 2.5)
        XCTAssertEqual(finger.session.ink.strokes.count, 3)
        XCTAssertEqual(finger.session.undoSteps, 3, "only the strokes drawn for the test")
        XCTAssertEqual(try finger.bytesSaved(), 0)
    }
}

/// The canvas view's finger path (`InkCanvasUIView`) on an `InkSession`, without UIKit: a finger stroke drawn live,
/// committed when kept; an eraser sweep held while pending. Bytes saved are what the ink log would be handed.
struct FingerCanvas {
    var session = InkSession()
    var gate = FingerStrokeGate()
    var tool = CanvasTool.pen
    private var live: StrokeInProgress?
    private var erasing = false
    private var holdsEraser = false
    private var held: [CanvasPoint] = []
    private static let tolerance = Length.inches(0.1)

    /// A canvas with level strokes at y 0.5, 1.5, …, each from x 0 to 1, for the eraser.
    init(strokesAcross count: Int = 0) {
        for i in 0..<count {
            let y = Double(i) + 0.5
            session.draw([CanvasPoint(x: .inches(0), y: .inches(y)), CanvasPoint(x: .inches(1), y: .inches(y))],
                         tool: .pen, colour: .red, width: .inches(0.02))
        }
    }

    var isShowingLiveInk: Bool { live != nil }

    private func point(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: .inches(x), y: .inches(y)) }

    mutating func down(at time: Double, x: Double, y: Double = 0) {
        let p = point(x, y)
        if tool == .eraser {
            erasing = true
            holdsEraser = true
            held.append(p)
        } else {
            live = PenSettings(tool: tool).beginStroke(at: p, pointsPerInch: 100)
        }
        gate.fingerDown(at: time)
    }

    mutating func move(at time: Double, x: Double, y: Double = 0) {
        if gate.isPending, gate.tick(at: time) { release() }
        let p = point(x, y)
        if erasing {
            if holdsEraser { held.append(p) } else { session.erase(at: p, tolerance: Self.tolerance) }
        } else {
            live?.add(p)
        }
    }

    mutating func secondFinger(at time: Double) {
        switch gate.secondFinger(at: time) {
        case .cancel: finish(keep: false)
        case .end: finish(keep: true)
        case .none: break
        }
    }

    mutating func up(x: Double, y: Double = 0) {
        guard live != nil || erasing else { return }
        let p = point(x, y)
        if erasing {
            if holdsEraser { held.append(p) } else { session.erase(at: p, tolerance: Self.tolerance) }
        } else {
            live?.end(at: p)
        }
        finish(keep: gate.lift())
    }

    private mutating func release() {
        guard holdsEraser else { return }
        holdsEraser = false
        session.beginEraserSweep()
        for p in held { session.erase(at: p, tolerance: Self.tolerance) }
        held.removeAll(keepingCapacity: true)
    }

    private mutating func finish(keep: Bool) {
        if holdsEraser {
            if keep { release() } else { holdsEraser = false; held.removeAll(keepingCapacity: true) }
        }
        if keep, let live { session.commit(live) }
        live = nil
        erasing = false
        gate = FingerStrokeGate()
    }

    /// Bytes of ink-log records the changes since the last call would write.
    mutating func bytesSaved() throws -> Int {
        session.takeEvents().reduce(0) { total, event in
            var framed: [UInt8] = []
            InkCodec.frame(InkCodec.encode(event), into: &framed)
            return total + framed.count
        }
    }
}
