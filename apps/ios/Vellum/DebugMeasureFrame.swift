#if DEBUG
import QuartzCore
import UIKit
import VellumCore

/// Debug-only launch arguments for the simulator captures of #8, which cannot hold a Pencil. Each drives the canvas
/// view's own input paths on the fixture (`DebugFixture`, in feet), tapping a few points off the ink so the taps
/// visibly snap to it. The lengths they show are the ones `MeasureFrameCaptureTests.testTheCaptureLengthsMatchTheModel`
/// works out from the same points:
///
/// - `--ui-measure`: a measure from the pump run's end to the old branch's end, 36'-8 1/16".
/// - `--ui-dimension`: two dimensions kept: the tank's top edge pulled above it, horizontal, 8'-0"; and from the old
///   branch's end to the pipe run's corner pulled out between them, aligned, 19'-1 1/4".
/// - `--ui-loupe`: the measure's first point taken, then the Pencil held down by the old branch's end, so the loupe
///   is up.
/// - `--ui-frame`: a 24 × 36 frame dragged round the valve and its bypass (12' × 11'): 1 1/2" = 1'-0".
/// - `--ui-window`: a window dragged round the tank, its menu up.
/// - `--ui-long-coordinates`: the pen's position at the longest the status bar plans for (#33),
///   `X -139'-11 15/16"  Y -139'-11 15/16"`, with the fixture otherwise untouched.
@MainActor
enum DebugMeasureFrame {
    private static var started = false

    static func attach(_ view: InkCanvasUIView, editor: CanvasEditor) {
        let wanted = ["--ui-measure", "--ui-dimension", "--ui-loupe", "--ui-frame", "--ui-window",
                      "--ui-long-coordinates"].filter(DebugLaunch.has)
        guard !wanted.isEmpty, !started, view.bounds.width > 0 else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if wanted.contains("--ui-measure") { await measure(view, editor) }
            if wanted.contains("--ui-dimension") { await dimensions(view, editor) }
            if wanted.contains("--ui-loupe") { await loupe(view, editor) }
            if wanted.contains("--ui-frame") { await frame(view, editor) }
            if wanted.contains("--ui-window") { await window(view, editor) }
            if wanted.contains("--ui-long-coordinates") {
                let inches = -(139.0 * 12 + 11 + 15.0 / 16)
                editor.penPosition = CanvasPoint(x: .inches(inches), y: .inches(-inches))
            }
            print("measure-frame: step \(editor.toolStep), shown \(view.debugAnnotationLabels)")
        }
    }

    /// A point of the fixture, in feet, on screen, nudged by a few points.
    private static func screen(_ x: Double, _ y: Double, _ editor: CanvasEditor, nudge: CGFloat = 0) -> CGPoint {
        let s = editor.viewport.screenPoint(for: CanvasPoint(x: .feet(x), y: .feet(y)))
        return CGPoint(x: s.x + nudge, y: s.y + nudge * 0.6)
    }

    /// A tap: down, a frame or two still, up.
    private static func tap(_ at: CGPoint, on view: InkCanvasUIView) async {
        guard view.beginInput(at: at) else { return }
        try? await Task.sleep(for: .milliseconds(60))
        view.moveInput(samples: [at], predicted: [])
        try? await Task.sleep(for: .milliseconds(60))
        view.endInput(samples: [at], keep: true)
        try? await Task.sleep(for: .milliseconds(120))
    }

    /// A drag through screen points, a point a frame, lifted at the end unless `lift` is off.
    private static func drag(_ from: CGPoint, _ to: CGPoint, on view: InkCanvasUIView, lift: Bool = true) async {
        guard view.beginInput(at: from) else { return }
        for i in 1...30 {
            let t = CGFloat(i) / 30
            try? await Task.sleep(for: .milliseconds(10))
            view.moveInput(samples: [CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)],
                           predicted: [])
        }
        try? await Task.sleep(for: .milliseconds(60))
        if lift { view.endInput(samples: [to], keep: true) }
    }

    private static func measure(_ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        editor.tool = .measure
        await tap(screen(4, 10, editor, nudge: -6), on: view)
        await tap(screen(40, 17, editor, nudge: -4), on: view)
    }

    private static func dimensions(_ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        editor.tool = .dimension
        editor.colour = .sketch
        await tap(screen(50, -6, editor, nudge: 5), on: view)
        await tap(screen(58, -6, editor, nudge: -5), on: view)
        await tap(screen(54, -9, editor), on: view)
        editor.colour = .blue
        await tap(screen(40, 17, editor, nudge: 4), on: view)
        await tap(screen(54, 4, editor, nudge: -4), on: view)
        await tap(screen(49, 13.5, editor), on: view)
    }

    private static func loupe(_ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        editor.tool = .measure
        await tap(screen(4, 10, editor, nudge: -6), on: view)
        // Down by the old branch's end, moving a little, and held.
        await drag(screen(40, 17, editor, nudge: -12), screen(40, 17, editor, nudge: -6), on: view, lift: false)
    }

    private static func frame(_ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        editor.tool = .frame
        editor.framePaper = .archD
        await drag(screen(24, 5, editor), screen(36, 16, editor), on: view)
    }

    private static func window(_ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        editor.tool = .window
        await drag(screen(46, -9, editor), screen(62, 6, editor), on: view)
    }
}
#endif
