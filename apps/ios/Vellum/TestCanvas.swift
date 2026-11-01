import SwiftUI
import VellumCore

/// The made-up 10,000-stroke test canvas (#21), reachable in every build so Zach can feel pan, pinch, draw and erase
/// on the Duo through TestFlight: a long press on the canvas name offers to open it, and again to go back. It is the
/// canvas the renderer's work budgets and benchmark measure (`MadeUpInk.largeWalkdown`), built in memory and kept
/// apart from Zach's own canvas, which stays as it was. Nothing in it comes from a real drawing.
enum TestCanvas {
    static let name = "Test canvas, 10,000 strokes (made up)"

    nonisolated static func make() -> VellumCore.Canvas {
        VellumCore.Canvas(name: name, ink: MadeUpInk.largeWalkdown())
    }

    /// An editor for the test canvas, in memory only. It has no saver, so nothing drawn or erased on it is written,
    /// listed or reopened; the check stops the app, in any build, if that ever changes.
    @MainActor
    static func editor(for canvas: VellumCore.Canvas, index: InkIndex) -> CanvasEditor {
        let editor = CanvasEditor(canvas: canvas, index: index, startingView: .everything)
        precondition(editor.saver == nil && editor.canvasID == nil, "the test canvas must never be saved")
        return editor
    }
}

/// Opens or closes the test canvas; the canvas screen's top bar offers it on a long press of the canvas name.
struct TestCanvasSwitch {
    /// Whether the test canvas is the one on screen.
    let isOpen: Bool
    let toggle: @MainActor () -> Void
}

private struct TestCanvasSwitchKey: EnvironmentKey {
    static var defaultValue: TestCanvasSwitch? { nil }
}

extension EnvironmentValues {
    var testCanvas: TestCanvasSwitch? {
        get { self[TestCanvasSwitchKey.self] }
        set { self[TestCanvasSwitchKey.self] = newValue }
    }
}
