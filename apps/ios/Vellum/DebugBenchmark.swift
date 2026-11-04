#if DEBUG || BENCHMARK
import QuartzCore
import UIKit
import VellumCore

/// Frame timing for the canvas (#21), in Debug builds and in the optimised build `Scripts/capture-duo.sh` makes with
/// the BENCHMARK flag; never in a TestFlight build. With `--ui-benchmark`, usually on the made-up 10,000-stroke canvas
/// (`--ui-fixture-large`), it drives a pan, a pinch, a drawn stroke and an eraser sweep through the canvas view's own
/// input paths, one step per display frame, and logs for every frame how long the main thread was busy from the
/// display link's tick until the run loop went back to sleep (input, model, SwiftUI updates and the Core Animation
/// commit), and the interval between display-link frames. The results go to the console and to `benchmark.txt` in the
/// app's Documents folder, which `Scripts/capture-duo.sh` copies out. Numbers on the simulator are indicative only.
@MainActor
final class DebugBenchmark: NSObject {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("--ui-benchmark") }
    private static var shared: DebugBenchmark?

    /// Called by the canvas view once it has a size; starts the run the first time when `--ui-benchmark` is given.
    static func attach(_ view: InkCanvasUIView, editor: CanvasEditor) {
        guard isRequested, shared == nil, view.bounds.width > 0 else { return }
        let benchmark = DebugBenchmark(view: view, editor: editor)
        shared = benchmark
        // Let the first render of the canvas finish before measuring anything. The made-up 1/4" plan for the sheet
        // scenarios (#11) is read now, off the main thread, and placed only when they start, so the earlier scenarios
        // run on the canvas they always have.
        Task { @MainActor in
            benchmark.sheet = await DebugSheetSource.pending(file: 1, page: 0)
            try? await Task.sleep(for: .seconds(4))
            benchmark.start()
        }
    }

    private struct Scenario {
        let name: String
        let frames: Int
        let setUp: @MainActor (DebugBenchmark) -> Void
        let step: @MainActor (DebugBenchmark, Int) -> Void
        let tearDown: @MainActor (DebugBenchmark) -> Void
    }

    private weak var view: InkCanvasUIView?
    private let editor: CanvasEditor
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var scenarios: [Scenario] = []
    private var scenarioIndex = 0
    private var frame = 0
    /// Frames of settling before a scenario's measured frames.
    private var warmUp = 0
    private var scenarioStart: CFTimeInterval = 0
    private static let scenarioTimeLimit: CFTimeInterval = 20
    /// How long to wait for background tile renders after a scenario. A wait that reaches it is not a measurement.
    private static let settleLimit: CFTimeInterval = 5
    private var tickStart: CFTimeInterval?
    private var lastTimestamp: CFTimeInterval?
    private var work: [Double] = []
    private var intervals: [Double] = []
    private var expectedInterval = 1.0 / 120
    private var settleStart: CFTimeInterval?
    /// The scenario whose last step ran; it is reported once that frame's work is counted.
    private var finishing: Scenario?
    private var lines: [String] = []
    private var measurements: [String: Double] = [:]
    private var strokePoint = CGPoint.zero
    /// The kept layer's drawings during the scenario, each with the frame it fell in.
    private var keptRedraws: [String] = []
    /// The made-up sheet the sheet scenarios place over the canvas.
    private var sheet: CanvasEditor.PendingSheet?
    private var placedSheet: Sheet?
    /// The speed probe's time before each scenario.
    private var probes: [Double] = []
    private static let probePath: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 128))
        for i in 1..<4000 {
            path.addLine(to: CGPoint(x: CGFloat(i).truncatingRemainder(dividingBy: 256), y: 128 + 100 * sin(CGFloat(i) / 7)))
        }
        return path
    }()

    private init(view: InkCanvasUIView, editor: CanvasEditor) {
        self.view = view
        self.editor = editor
        super.init()
        scenarios = Self.makeScenarios()
    }

    private static func makeScenarios() -> [Scenario] {
        [
            Scenario(name: "pan", frames: 240, setUp: { $0.editor.zoomToEverything() }, step: { b, i in
                // Back and forth across the canvas at 6 points a frame, the speed of a brisk finger.
                let direction: CGFloat = (i / 60) % 2 == 0 ? 1 : -1
                b.view?.panBy(dx: 6 * direction, dy: 2 * direction)
            }, tearDown: { _ in }),
            Scenario(name: "pinch", frames: 240, setUp: { $0.editor.zoomToEverything() }, step: { b, i in
                // In by about 11x over a second, then back out.
                guard let view = b.view else { return }
                let factor: CGFloat = i < 120 ? 1.02 : 1 / 1.02
                view.zoomBy(factor, about: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            }, tearDown: { _ in }),
            Scenario(name: "draw", frames: 240, setUp: { b in
                b.editor.zoomToEverything()
                b.editor.tool = .pen
                guard let view = b.view else { return }
                b.strokePoint = CGPoint(x: 120, y: view.bounds.midY)
                _ = view.beginInput(at: b.strokePoint)
            }, step: { b, i in
                // Two coalesced samples a frame, 2.5 points apart, and two predicted ahead: a wavy line across the
                // screen.
                guard let view = b.view else { return }
                var samples: [CGPoint] = []
                for _ in 0..<2 {
                    b.strokePoint.x += 1.4
                    samples.append(CGPoint(x: b.strokePoint.x, y: view.bounds.midY + 80 * sin(b.strokePoint.x / 40)))
                }
                let predicted = (1...2).map { k in
                    CGPoint(x: b.strokePoint.x + 1.4 * CGFloat(k),
                            y: view.bounds.midY + 80 * sin((b.strokePoint.x + 1.4 * CGFloat(k)) / 40))
                }
                if i == 239 {
                    view.endInput(samples: samples, keep: true)
                } else {
                    view.moveInput(samples: samples, predicted: predicted)
                }
            }, tearDown: { _ in }),
            Scenario(name: "erase", frames: 240, setUp: { b in
                b.editor.zoomToEverything()
                b.editor.tool = .eraser
                guard let view = b.view else { return }
                b.strokePoint = CGPoint(x: 100, y: view.bounds.midY - 100)
                _ = view.beginInput(at: b.strokePoint)
            }, step: { b, i in
                // A zigzag sweep across the middle of the canvas, two samples a frame.
                guard let view = b.view else { return }
                var samples: [CGPoint] = []
                for _ in 0..<2 {
                    b.strokePoint.x += 1.5
                    let phase = (b.strokePoint.x / 60).truncatingRemainder(dividingBy: 2)
                    samples.append(CGPoint(x: b.strokePoint.x,
                                           y: view.bounds.midY - 100 + 200 * (phase < 1 ? phase : 2 - phase)))
                }
                if i == 239 {
                    view.endInput(samples: samples, keep: true)
                } else {
                    view.moveInput(samples: samples, predicted: [])
                }
            }, tearDown: { b in b.editor.tool = .pen }),
            // #7: dragging a lasso selection. The loop is taken above the eraser's band, round a few hundred strokes,
            // and the Pencil lands on it in the set-up, which lifts the strokes onto their own layer; each frame then
            // moves them by one transform, and the last frame drops them, which saves the move as one record.
            Scenario(name: "drag", frames: 240, setUp: { b in
                b.editor.zoomToEverything()
                b.editor.tool = .lasso
                guard let view = b.view else { return }
                let centre = CGPoint(x: view.bounds.midX, y: 150)
                let loop = (0..<120).map { i -> CanvasPoint in
                    let a = Double(i) / 120 * 2 * .pi
                    return b.editor.viewport.canvasPoint(for: ScreenPoint(x: Double(centre.x) + 160 * cos(a), y: Double(centre.y) + 60 * sin(a)))
                }
                b.editor.selectInLoop(loop)
                b.record("  drag selection strokes=\(b.editor.selection.strokes.count)")
                b.strokePoint = centre
                _ = view.beginInput(at: centre)
            }, step: { b, i in
                guard let view = b.view else { return }
                b.strokePoint.x += i < 120 ? 1.5 : -1.5
                b.strokePoint.y += 0.5
                if i == 239 {
                    view.endInput(samples: [b.strokePoint], keep: true)
                } else {
                    view.moveInput(samples: [b.strokePoint], predicted: [])
                }
            }, tearDown: { b in
                b.editor.tool = .pen
            }),
            // #7: a rough box drawn with the pen over 120 frames, held still for 80 (the hold snaps it to a
            // rectangle, recognised once), then lifted.
            Scenario(name: "snap", frames: 200, setUp: { b in
                b.editor.zoomToEverything()
                b.editor.tool = .pen
                guard let view = b.view else { return }
                b.strokePoint = CGPoint(x: 160, y: 440)
                _ = view.beginInput(at: b.strokePoint)
            }, step: { b, i in
                guard let view = b.view else { return }
                if i < 120 {
                    // Round the box's four sides, 30 frames each, with a little wobble.
                    let corners = [CGPoint(x: 160, y: 440), CGPoint(x: 420, y: 444), CGPoint(x: 416, y: 580),
                                   CGPoint(x: 162, y: 576), CGPoint(x: 164, y: 446)]
                    let side = i / 30, t = CGFloat(i % 30 + 1) / 30
                    let a = corners[side], c = corners[side + 1]
                    b.strokePoint = CGPoint(x: a.x + (c.x - a.x) * t + sin(CGFloat(i)), y: a.y + (c.y - a.y) * t)
                    view.moveInput(samples: [b.strokePoint], predicted: [])
                } else if i == 199 {
                    view.endInput(samples: [], keep: true)
                }
            }, tearDown: { _ in }),
            // #8: a frame dragged across the middle of the canvas, a point and a half a frame: each frame finds the
            // smallest covering scale and places the ghost frame and its label; the last frame places the frame.
            Scenario(name: "frame", frames: 240, setUp: { b in
                b.editor.zoomToEverything()
                b.editor.tool = .frame
                guard let view = b.view else { return }
                b.strokePoint = CGPoint(x: 200, y: 160)
                _ = view.beginInput(at: b.strokePoint)
            }, step: { b, i in
                guard let view = b.view else { return }
                b.strokePoint.x += 1.6
                b.strokePoint.y += 1.1
                if i == 239 {
                    view.endInput(samples: [b.strokePoint], keep: true)
                } else {
                    view.moveInput(samples: [b.strokePoint], predicted: [])
                }
            }, tearDown: { b in b.editor.tool = .pen }),
            // #8: the measure tool's Pencil down and wandering over the ink: each frame snaps the tip through the
            // index and moves the loupe, which shows the tiles already drawn. Lifted on the last frame, which takes the
            // first point.
            Scenario(name: "loupe", frames: 240, setUp: { b in
                b.editor.zoomToEverything()
                b.editor.tool = .measure
                guard let view = b.view else { return }
                b.strokePoint = CGPoint(x: 220, y: view.bounds.midY)
                _ = view.beginInput(at: b.strokePoint)
            }, step: { b, i in
                guard let view = b.view else { return }
                b.strokePoint.x += 2
                b.strokePoint.y = view.bounds.midY + 120 * sin(b.strokePoint.x / 50)
                if i == 239 {
                    view.endInput(samples: [b.strokePoint], keep: true)
                } else {
                    view.moveInput(samples: [b.strokePoint], predicted: [])
                }
            }, tearDown: { b in b.editor.tool = .pen }),
            // #11: a 36 x 24 sheet at 1/4" = 1'-0" placed in the middle of the canvas (its tiles drawn from the PDF off
            // the main thread), panned across back and forth, as the pan above...
            Scenario(name: "sheet_pan", frames: 240, setUp: { b in
                b.placeSheet()
            }, step: { b, i in
                let direction: CGFloat = (i / 60) % 2 == 0 ? 1 : -1
                b.view?.panBy(dx: 6 * direction, dy: 2 * direction)
            }, tearDown: { b in b.logSheetTiles() }),
            // ...pinched in and out over it...
            Scenario(name: "sheet_pinch", frames: 240, setUp: { b in b.zoomToSheet() }, step: { b, i in
                guard let view = b.view else { return }
                let factor: CGFloat = i < 120 ? 1.02 : 1 / 1.02
                view.zoomBy(factor, about: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            }, tearDown: { b in b.logSheetTiles() }),
            // ...and drawn over with the pen, so ink over a sheet is measured against ink on the bare canvas.
            Scenario(name: "sheet_draw", frames: 240, setUp: { b in
                b.zoomToSheet()
                b.editor.tool = .pen
                guard let view = b.view else { return }
                b.strokePoint = CGPoint(x: 120, y: view.bounds.midY)
                _ = view.beginInput(at: b.strokePoint)
            }, step: { b, i in
                guard let view = b.view else { return }
                var samples: [CGPoint] = []
                for _ in 0..<2 {
                    b.strokePoint.x += 1.4
                    samples.append(CGPoint(x: b.strokePoint.x, y: view.bounds.midY + 80 * sin(b.strokePoint.x / 40)))
                }
                if i == 239 {
                    view.endInput(samples: samples, keep: true)
                } else {
                    view.moveInput(samples: samples, predicted: [])
                }
            }, tearDown: { _ in }),
        ]
    }

    /// Places the made-up sheet in the middle of the canvas, with no saver (the test canvas is never saved), and
    /// zooms to it.
    /// How fast this runner is just now, from work that no change to Vellum can touch: a fixed path stroked into a
    /// bitmap, five times, the median in milliseconds. `Scripts/perf-compare.py` scales the timing baselines by it.
    private func speedProbe() -> Double {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return 0 }
        var times: [Double] = []
        for _ in 0..<5 {
            let start = CACurrentMediaTime()
            guard let context = CGContext(data: nil, width: 768, height: 768, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return 0 }
            context.addPath(Self.probePath)
            context.setLineWidth(1)
            context.strokePath()
            _ = context.makeImage()
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        return percentile(times.sorted(), 0.5)
    }

    private func placeSheet() {
        guard let pending = sheet, placedSheet == nil else { return zoomToSheet() }
        editor.zoomToEverything()
        let centre = editor.viewport.centre
        editor.beginPlacing(pending)
        Task { @MainActor in
            placedSheet = await editor.placeSheet(centredAt: centre)
            record("  sheet placed=\(placedSheet?.label ?? "none")")
            zoomToSheet()
        }
    }

    private func zoomToSheet() {
        guard let placedSheet else { return editor.zoomToEverything() }
        editor.zoom(to: placedSheet.bounds)
    }

    private func logSheetTiles() {
        guard let tiles = view?.debugSheetTiles else { return }
        record("  sheet tiles drawn=\(tiles.drawn) kept=\(tiles.kept)")
    }

    private func start() {
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        record("benchmark build=\(build) strokes=\(editor.ink.strokes.count) view=\(Int(view?.bounds.width ?? 0))x\(Int(view?.bounds.height ?? 0)) maximumFramesPerSecond=\(view?.window?.windowScene?.screen.maximumFramesPerSecond ?? 0) promotionOptIn=\(Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool ?? false)")
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true,
                                                          CFIndex.max) { _, _ in
            MainActor.assumeIsolated { DebugBenchmark.shared?.runLoopWillSleep() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        beginScenario()
    }

    private func beginScenario() {
        guard scenarioIndex < scenarios.count else { finish(); return }
        probes.append(speedProbe())
        scenarios[scenarioIndex].setUp(self)
        frame = 0
        warmUp = 30
        work.removeAll()
        intervals.removeAll()
        keptRedraws.removeAll()
        lastTimestamp = nil
        tickStart = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        // A tick arriving before the run loop slept means the main thread was busy the whole frame.
        if let start = tickStart, warmUp == 0 { work.append((now - start) * 1000) }
        tickStart = nil

        if let scenario = finishing {
            // The last step's frame (the Pencil lifting and the stroke committing) is counted by now, so every
            // scenario reports all its frames.
            finishing = nil
            scenario.tearDown(self)
            report(scenario)
            settleStart = now
            return
        }

        if let settleStart {
            // Waiting for background tile renders to finish after a scenario.
            let pending = view?.pendingRenderCount ?? 0
            if pending == 0 || now - settleStart > Self.settleLimit {
                // Cut off, the number is only a lower bound, and it is written so that nothing reads it as a time.
                record(pending == 0 ? "  settled_ms=\(format((now - settleStart) * 1000))"
                                    : "  settled_ms>=\(format(Self.settleLimit * 1000)) still_pending=\(pending)")
                self.settleStart = nil
                scenarioIndex += 1
                beginScenario()
            }
            return
        }
        if warmUp > 0 {
            warmUp -= 1
            return
        }
        if let last = lastTimestamp { intervals.append((link.timestamp - last) * 1000) }
        lastTimestamp = link.timestamp
        expectedInterval = link.targetTimestamp - link.timestamp
        let scenario = scenarios[scenarioIndex]
        if frame == 0 { scenarioStart = now }
        // A renderer too slow to finish in 20 seconds gets its last step now (which lifts the Pencil), and the frames
        // it managed are reported.
        let outOfTime = now - scenarioStart > Self.scenarioTimeLimit
        tickStart = now
        let redrawsBefore = view?.debugKeptRedraws.count ?? 0
        scenario.step(self, outOfTime ? scenario.frames - 1 : frame)
        if let redraws = view?.debugKeptRedraws, redraws.count > redrawsBefore {
            keptRedraws += redraws[redrawsBefore...].map { "frame \(frame): \($0)" }
        }
        frame = outOfTime ? scenario.frames : frame + 1
        if frame == scenario.frames { finishing = scenario }
    }

    private func runLoopWillSleep() {
        guard let start = tickStart else { return }
        work.append((CACurrentMediaTime() - start) * 1000)
        tickStart = nil
    }

    private func report(_ scenario: Scenario) {
        let budget = 1000.0 / 120
        let sortedWork = work.sorted(), sortedIntervals = intervals.sorted()
        let long = intervals.filter { $0 > expectedInterval * 1000 * 1.5 }.count
        record("scenario=\(scenario.name) frames=\(work.count) strokes=\(editor.ink.strokes.count)"
            + " work_ms median=\(format(percentile(sortedWork, 0.5))) p95=\(format(percentile(sortedWork, 0.95)))"
            + " max=\(format(sortedWork.last ?? 0)) over_8.3ms=\(work.filter { $0 > budget }.count)"
            + " interval_ms median=\(format(percentile(sortedIntervals, 0.5)))"
            + " p95=\(format(percentile(sortedIntervals, 0.95))) max=\(format(sortedIntervals.last ?? 0))"
            + " long_frames=\(long) display_interval_ms=\(format(expectedInterval * 1000))")
        // Where a slow frame fell, beside the kept layer's drawings, to tell one from the other.
        let slowWork = work.enumerated().filter { $0.element > budget }.map { "\($0.offset):\(format($0.element))" }
        let slowGaps = intervals.enumerated().filter { $0.element > expectedInterval * 1000 * 1.5 }
            .map { "\($0.offset):\(format($0.element))" }
        record("  slow work \(slowWork), long gaps \(slowGaps), kept redraws \(keptRedraws)")
        // An optimised build's metrics end in _release, so both builds compare with their own baselines.
        #if DEBUG
        let suffix = ""
        #else
        let suffix = "_release"
        #endif
        measurements["\(scenario.name)_frame_ms_p50\(suffix)"] = percentile(sortedWork, 0.5)
        measurements["\(scenario.name)_frame_ms_p95\(suffix)"] = percentile(sortedWork, 0.95)
        measurements["\(scenario.name)_frame_ms_max\(suffix)"] = sortedWork.last ?? 0
    }

    private func finish() {
        link?.invalidate()
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        #if DEBUG
        measurements["speed_probe_ms"] = percentile(probes.sorted(), 0.5)
        #else
        measurements["speed_probe_ms_release"] = percentile(probes.sorted(), 0.5)
        #endif
        record("speed_probe_ms=\(format(percentile(probes.sorted(), 0.5)))")
        // The timings in the form Scripts/perf-compare.py reads, for comparing with docs/perf/baselines.
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let entries = measurements.keys.sorted().map { ["metric": $0, "value": (measurements[$0]! * 100).rounded() / 100] as [String: Any] }
        let json: [String: Any] = ["area": "canvas-rendering", "unit": "ms", "measurements": entries]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("benchmark.json"))
        }
        record("done")
    }

    fileprivate func record(_ line: String) {
        print("VellumBenchmark: " + line)
        lines.append(line)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("benchmark.txt"),
                                                          atomically: true, encoding: .utf8)
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    private func format(_ value: Double) -> String { String(format: "%.2f", value) }
}
#endif
