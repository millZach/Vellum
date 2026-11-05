#if DEBUG
import QuartzCore
import UIKit
import VellumCore

/// Debug-only launch argument for the simulator captures of #40, which cannot hold a Pencil. `--ui-drawing <step>` drives the
/// canvas view's own input paths on a made-up scene: a rectangle, a circle and two crossing lines, each drawn with the tool.
///
/// - `flyout`: the flyout open, with the line weight at its foot.
/// - `tag`: a line drawn, with its tag.
/// - `pad`, `corrected`: the pad over that line with 12'6 and 30 typed, then after Enter, the tag reading 12'-6"  30°.
/// - `guide`: a line's second point held within 3° of level, with the angle guide.
/// - `mid`, `intersection`, `perpendicular`, `tangent`: the tip held near each, with the loupe naming it.
/// - `line`, `polyline`, `rectangle`, `circle`, `arc`, `polygon`: each shape drawn, with its tag.
/// - `polyline-switch`: three bends, then a change of colour and of tool, to Measure, the lasso and the highlighter in turn:
///   each time the polyline must be ink, as a pen stroke, in its first colour and width, with one undo step. Writes what it
///   found to `drawing-switch.txt` in Documents, ending in `done`, for the captures job's log.
/// - `tag-chrome`, `pad-chrome`, `loupe-chrome`: a shape under the top bar and by the rail, with the tag, the pad and the loupe
///   clear of them.
@MainActor
enum DebugDrawingTools {
    private static var started = false

    static func attach(_ view: InkCanvasUIView, editor: CanvasEditor) {
        guard let step = DebugLaunch.argument("--ui-drawing"), !started, view.bounds.width > 0 else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            await run(step, view, editor)
            print("drawing: \(step), tag \(view.debugShapeDrawing.debugTag), step \(editor.toolStep)")
        }
    }

    /// A tap: down, a frame or two still, up.
    private static func tap(_ x: CGFloat, _ y: CGFloat, on view: InkCanvasUIView) async {
        let at = CGPoint(x: x, y: y)
        guard view.beginInput(at: at) else { return }
        try? await Task.sleep(for: .milliseconds(40))
        view.endInput(samples: [at], keep: true)
        try? await Task.sleep(for: .milliseconds(80))
    }

    /// A drag to a point, held there with the Pencil still down.
    private static func hold(from: CGPoint, to: CGPoint, on view: InkCanvasUIView) async {
        guard view.beginInput(at: from) else { return }
        for i in 1...12 {
            let t = CGFloat(i) / 12
            try? await Task.sleep(for: .milliseconds(10))
            view.moveInput(samples: [CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)], predicted: [])
        }
        try? await Task.sleep(for: .milliseconds(120))
    }

    private static func draw(_ shape: LineShape, _ points: [(CGFloat, CGFloat)], _ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        editor.lineShape = shape
        for (x, y) in points { await tap(x, y, on: view) }
    }

    /// The rectangle (200, 180)-(420, 320), the circle round (620, 250) of radius 80, and the lines y = 440 and x = 620.
    private static func scene(_ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        editor.tool = .lineAndShape
        editor.colour = .sketch
        await draw(.rectangle, [(200, 180), (420, 320)], view, editor)
        await draw(.circle, [(620, 250), (700, 250)], view, editor)
        await draw(.line, [(140, 440), (780, 440)], view, editor)
        await draw(.line, [(620, 110), (620, 530)], view, editor)
        view.debugShapeDrawing.clearTag()
        editor.colour = .red
    }

    private static func polylineSwitch(_ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        var lines: [String] = []
        for (i, tool) in [CanvasTool.measure, .lasso, .highlighter].enumerated() {
            editor.tool = .lineAndShape
            editor.colour = .red
            try? await Task.sleep(for: .milliseconds(300))
            let before = editor.ink.count
            let y = CGFloat(180 + i * 120)
            await draw(.polyline, [(180, y), (360, y + 60), (540, y)], view, editor)
            let width = editor.pen.beginStroke(at: .origin, pointsPerInch: editor.viewport.pointsPerInch)?.width
            editor.colour = .blue
            editor.tool = tool
            // SwiftUI hands the tool to the view a moment after the editor takes it.
            try? await Task.sleep(for: .milliseconds(400))
            let stroke = editor.ink.strokes.last
            let inked = editor.ink.count == before + 1 && stroke?.tool == .pen && stroke?.colour == .red
                && stroke?.width == width && stroke?.points.count == 3
            editor.undo()
            let oneStep = editor.ink.count == before
            editor.redo()
            lines.append("\(inked && oneStep ? "ok" : "LOST") \(tool.rawValue) strokes \(editor.ink.count - before) "
                + "pen \(stroke?.tool.rawValue ?? "none") colour \(stroke?.colour.rawValue ?? "none")")
        }
        lines.append("done")
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("drawing-switch.txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private static func run(_ step: String, _ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        editor.tool = .lineAndShape
        let drawing = view.debugShapeDrawing
        switch step {
        case "flyout":
            editor.lineShape = .line
            editor.showsShapeFlyout = true
        case "tag":
            await draw(.line, [(150, 540), (420, 470)], view, editor)
        case "pad", "corrected":
            await draw(.line, [(150, 480), (420, 410)], view, editor)
            drawing.debugOpenPad()
            drawing.debugPress(["1", "2", "'", "6"])
            drawing.debugSelect(.angle)
            drawing.debugPress(["3", "0"])
            if step == "corrected" { drawing.debugEnter() }
        case "guide":
            editor.lineShape = .line
            await tap(150, 300, on: view)
            await hold(from: CGPoint(x: 280, y: 300), to: CGPoint(x: 560, y: 315), on: view)
        case "mid":
            await scene(view, editor)
            editor.lineShape = .line
            await hold(from: CGPoint(x: 330, y: 200), to: CGPoint(x: 314, y: 185), on: view)
        case "intersection":
            await scene(view, editor)
            editor.lineShape = .line
            await hold(from: CGPoint(x: 660, y: 480), to: CGPoint(x: 624, y: 444), on: view)
        case "perpendicular":
            await scene(view, editor)
            editor.lineShape = .line
            await tap(500, 560, on: view)
            await hold(from: CGPoint(x: 520, y: 500), to: CGPoint(x: 503, y: 445), on: view)
        case "tangent":
            await scene(view, editor)
            editor.lineShape = .line
            await tap(460, 540, on: view)
            // Where a line from (460, 540) just touches the circle, on its left.
            let (dx, dy) = (460.0 - 620, 540.0 - 250)
            let d = hypot(dx, dy), base = atan2(dy, dx), off = acos(80 / d)
            let at = CGPoint(x: 620 + 80 * cos(base + off), y: 250 + 80 * sin(base + off))
            await hold(from: CGPoint(x: at.x - 30, y: at.y + 20), to: CGPoint(x: at.x - 3, y: at.y + 2), on: view)
        case "line":
            await draw(.line, [(220, 460), (620, 240)], view, editor)
        case "polyline":
            await draw(.polyline, [(180, 480), (360, 240), (560, 400), (740, 200)], view, editor)
        case "rectangle":
            await draw(.rectangle, [(240, 200), (640, 460)], view, editor)
        case "circle":
            await draw(.circle, [(470, 330), (620, 330)], view, editor)
        case "arc":
            await draw(.arc, [(220, 420), (680, 420), (450, 180)], view, editor)
        case "polygon":
            await draw(.polygon, [(470, 330), (620, 330)], view, editor)
        case "polyline-switch":
            await polylineSwitch(view, editor)
        case "tag-chrome":
            await draw(.line, [(220, 24), (640, 24)], view, editor)
        case "pad-chrome":
            await draw(.line, [(20, 640), (150, 640)], view, editor)
            drawing.debugOpenPad()
        case "loupe-chrome":
            await scene(view, editor)
            editor.lineShape = .line
            await hold(from: CGPoint(x: 300, y: 110), to: CGPoint(x: 310, y: 90), on: view)
        default:
            break
        }
    }
}
#endif
