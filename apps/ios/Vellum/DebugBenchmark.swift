#if DEBUG
import QuartzCore
import UIKit
import VellumCore

/// Debug-only frame timing for the canvas (#21). With `--ui-benchmark`, usually on the made-up 10,000-stroke canvas
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
        // Let the first render of the canvas finish before measuring anything.
        Task { @MainActor in
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
    private var tickStart: CFTimeInterval?
    private var lastTimestamp: CFTimeInterval?
    private var work: [Double] = []
    private var intervals: [Double] = []
    private var expectedInterval = 1.0 / 120
    private var settleStart: CFTimeInterval?
    private var lines: [String] = []
    private var measurements: [String: Double] = [:]
    private var strokePoint = CGPoint.zero

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
        ]
    }

    private func start() {
        record("benchmark strokes=\(editor.ink.strokes.count) view=\(Int(view?.bounds.width ?? 0))x\(Int(view?.bounds.height ?? 0)) maximumFramesPerSecond=\(view?.window?.windowScene?.screen.maximumFramesPerSecond ?? 0) promotionOptIn=\(Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool ?? false)")
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
        scenarios[scenarioIndex].setUp(self)
        frame = 0
        warmUp = 30
        work.removeAll()
        intervals.removeAll()
        lastTimestamp = nil
        tickStart = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        // A tick arriving before the run loop slept means the main thread was busy the whole frame.
        if let start = tickStart, warmUp == 0 { work.append((now - start) * 1000) }
        tickStart = nil

        if let settleStart {
            // Waiting for background tile renders to finish after a scenario.
            if (view?.pendingRenderCount ?? 0) == 0 || now - settleStart > 5 {
                record("  settled_ms=\(format((now - settleStart) * 1000))")
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
        scenario.step(self, outOfTime ? scenario.frames - 1 : frame)
        frame = outOfTime ? scenario.frames : frame + 1
        if frame == scenario.frames {
            scenario.tearDown(self)
            report(scenario)
            settleStart = now
        }
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
        measurements["\(scenario.name)_frame_ms_p50"] = percentile(sortedWork, 0.5)
        measurements["\(scenario.name)_frame_ms_p95"] = percentile(sortedWork, 0.95)
        measurements["\(scenario.name)_frame_ms_max"] = sortedWork.last ?? 0
    }

    private func finish() {
        link?.invalidate()
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        // The timings in the form Scripts/perf-compare.py reads, for comparing with docs/perf/baselines.
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let entries = measurements.keys.sorted().map { ["metric": $0, "value": (measurements[$0]! * 100).rounded() / 100] as [String: Any] }
        let json: [String: Any] = ["area": "canvas-rendering", "unit": "ms", "measurements": entries]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("benchmark.json"))
        }
        record("done")
    }

    private func record(_ line: String) {
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
