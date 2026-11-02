#if DEBUG
import QuartzCore
import UIKit
import VellumCore

/// Debug-only launch arguments for the simulator captures of #7, which cannot hold a Pencil. Each drives the canvas
/// view's own input paths, the way the Pencil does:
///
/// - `--ui-snap` (on a new canvas): a wobbly line and a rough box drawn with the pen and held still at their ends, so
///   they snap to a straight line and a rectangle; then a rough circle drawn with the line and shape tool, which snaps
///   when it lifts.
/// - `--ui-lasso` (on the fixture): a lasso loop round the bypass and the valve, leaving them selected with the
///   selection's box, handles and menu.
/// - `--ui-lasso-move` (on the fixture): the same, then the selection dragged down and to the right.
/// - `--ui-text` (on a new canvas): two text boxes placed with the text box tool and typed into.
@MainActor
enum DebugSelection {
    private static var started = false

    static func attach(_ view: InkCanvasUIView, editor: CanvasEditor) {
        let wanted = ["--ui-snap", "--ui-lasso", "--ui-lasso-move", "--ui-text"].filter(DebugLaunch.has)
        guard !wanted.isEmpty, !started, view.bounds.width > 0 else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if wanted.contains("--ui-snap") { await snap(view, editor) }
            if wanted.contains("--ui-lasso") || wanted.contains("--ui-lasso-move") {
                await lasso(view, editor, move: wanted.contains("--ui-lasso-move"))
            }
            if wanted.contains("--ui-text") { await text(view, editor) }
        }
    }

    /// Draws through screen points, two a frame, then holds still for `hold` seconds before lifting.
    private static func draw(_ points: [CGPoint], on view: InkCanvasUIView, hold: Double) async {
        guard let first = points.first, view.beginInput(at: first) else { return }
        var rest = Array(points.dropFirst())
        while !rest.isEmpty {
            try? await Task.sleep(for: .milliseconds(8))
            let batch = Array(rest.prefix(2))
            rest.removeFirst(batch.count)
            view.moveInput(samples: batch, predicted: [])
        }
        if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
        view.endInput(samples: [], keep: true)
    }

    private static func snap(_ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        editor.tool = .pen
        editor.colour = .red
        // A wobbly line, held still at its end.
        let line = (0...80).map { i -> CGPoint in
            let t = CGFloat(i) / 80
            return CGPoint(x: 200 + 300 * t, y: 190 + 70 * t + 3 * sin(t * 40))
        }
        await draw(line, on: view, hold: 0.8)
        print("snap: line held \(editor.ink.strokes.last.map { "\($0.points.count) points" } ?? "none")")
        // A rough box, held still where it closes.
        editor.colour = .blue
        var box: [CGPoint] = []
        let corners = [CGPoint(x: 560, y: 170), CGPoint(x: 790, y: 176), CGPoint(x: 786, y: 330), CGPoint(x: 562, y: 326),
                       CGPoint(x: 566, y: 178)]
        for i in 0..<(corners.count - 1) {
            for k in 0..<30 {
                let t = CGFloat(k) / 30
                box.append(CGPoint(x: corners[i].x + (corners[i + 1].x - corners[i].x) * t + 2 * sin(CGFloat(k)),
                                   y: corners[i].y + (corners[i + 1].y - corners[i].y) * t + 2 * cos(CGFloat(k))))
            }
        }
        box.append(corners[corners.count - 1])
        await draw(box, on: view, hold: 0.8)
        print("snap: box held \(editor.ink.strokes.last.map { "\($0.points.count) points" } ?? "none")")
        // A rough circle with the line and shape tool, lifted at once.
        editor.tool = .lineAndShape
        editor.colour = .sketch
        let circle = (0...90).map { i -> CGPoint in
            let a = CGFloat(i) / 90 * 2 * .pi
            let r = 75 + 4 * sin(a * 5)
            return CGPoint(x: 360 + r * cos(a), y: 440 + r * sin(a))
        }
        await draw(circle, on: view, hold: 0)
        print("snap: line tool circle \(editor.ink.strokes.last.map { "\($0.points.count) points" } ?? "none")")
    }

    private static func lasso(_ view: InkCanvasUIView, _ editor: CanvasEditor, move: Bool) async {
        editor.tool = .lasso
        try? await Task.sleep(for: .milliseconds(300))
        // A loop round the bypass and the valve of the fixture (in feet), drawn as a wobbly ellipse.
        let centre = editor.viewport.screenPoint(for: CanvasPoint(x: .feet(29.25), y: .feet(12)))
        let rx = 7.2 * 12 * editor.viewport.pointsPerInch, ry = 5.2 * 12 * editor.viewport.pointsPerInch
        let loop = (0...120).map { i -> CGPoint in
            let a = Double(i) / 120 * 2 * .pi
            return CGPoint(x: centre.x + rx * cos(a) * (1 + 0.03 * sin(a * 6)), y: centre.y + ry * sin(a))
        }
        view.debugLasso(loop)
        print("lasso: \(editor.selection.strokes.count) strokes, \(editor.selection.texts.count) text boxes selected")
        guard move else { return }
        try? await Task.sleep(for: .milliseconds(400))
        let start = CGPoint(x: centre.x, y: centre.y)
        let path = (0...40).map { i -> CGPoint in
            let t = CGFloat(i) / 40
            return CGPoint(x: start.x + 150 * t, y: start.y + 90 * t)
        }
        await draw(path, on: view, hold: 0)
        print("lasso: moved, \(editor.selection.count) still selected, undo steps \(editor.canUndo)")
    }

    private static func text(_ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        editor.tool = .textBox
        try? await Task.sleep(for: .milliseconds(300))
        editor.colour = .blue
        view.placeText(at: CGPoint(x: 220, y: 200))
        view.debugTextOverlay.debugType("Pump 1A: check the suction strainer before restart (example)")
        view.debugTextOverlay.finishEditing()
        editor.colour = .sketch
        view.placeText(at: CGPoint(x: 520, y: 380))
        view.debugTextOverlay.debugType("Made-up note typed into a text box")
        view.debugTextOverlay.finishEditing()
        print("text: \(editor.texts.count) text boxes: \(editor.texts.map(\.text))")
    }
}
#endif
