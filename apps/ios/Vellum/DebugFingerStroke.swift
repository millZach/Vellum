#if DEBUG
import QuartzCore
import UIKit
import VellumCore

/// `--ui-finger-stroke`, Debug builds only, for the simulator captures (#24), which cannot put a finger on the glass.
/// With Draw with finger on (`--ui-draw-with-finger`), it drives the canvas view's own finger path: first the start of
/// a two-finger pan (a finger, then a second one 50 ms later, inside the window), which must leave no ink; then a wave
/// drawn with one finger over half a second, which is kept. With the switch off it draws nothing.
@MainActor
enum DebugFingerStroke {
    private static var started = false

    /// Called by the canvas view once it has a size.
    static func attach(_ view: InkCanvasUIView) {
        guard DebugLaunch.has("--ui-finger-stroke"), !started, view.bounds.width > 0 else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            await run(on: view)
        }
    }

    private static func run(on view: InkCanvasUIView) async {
        guard view.fingerDraws else {
            print("finger stroke: Draw with finger is off, so the finger draws nothing")
            return
        }
        let mid = CGPoint(x: view.bounds.midX, y: view.bounds.midY)

        // The first finger of a pan: drawn live, then dropped when the second lands inside the window.
        let panStart = CGPoint(x: mid.x - 220, y: mid.y - 140)
        let down = CACurrentMediaTime()
        guard view.fingerDown(at: panStart, time: down) else { return }
        view.moveInput(samples: [CGPoint(x: panStart.x + 30, y: panStart.y + 10)], predicted: [])
        view.secondFingerDown(at: down + 0.05)
        print("finger stroke: second finger at 50 ms dropped the stroke")

        // One finger alone: a wave across the middle of the screen, kept.
        let frames = 60
        func point(_ i: Int) -> CGPoint {
            let t = Double(i) / Double(frames)
            return CGPoint(x: mid.x - 240 + 480 * t, y: mid.y + 70 * sin(t * 4 * .pi))
        }
        guard view.fingerDown(at: point(0), time: CACurrentMediaTime()) else { return }
        for i in 1..<frames {
            try? await Task.sleep(for: .milliseconds(8))
            view.fingerTick(at: CACurrentMediaTime())
            view.moveInput(samples: [point(i)], predicted: [])
        }
        view.fingerUp(samples: [point(frames)])
        print("finger stroke: one finger drew a wave and lifted")
    }
}
#endif
