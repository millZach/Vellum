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
    /// Each frame's step alone: Vellum's own code, before the Core Animation commit that follows it.
    private var stepWork: [Double] = []
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
    /// The placed sheet's left edge on screen, top corner to bottom, for the `sheet_snap` scenario (#57).
    private var edgeFrom = CGPoint.zero
    private var edgeTo = CGPoint.zero
    private var placedSheet: Sheet?
    /// Sheet tiles asked for when the turn's measured frames began.
    private var tilesBeforeTurn = 0
    /// Whether the warm-up waits for the ink tiles to finish drawing.
    private var holdsForTiles = false
    private var holdStart: CFTimeInterval = 0
    /// What ran on the main thread before each measured frame (#42), one per entry in `intervals`.
    private var ledgerFrames: [MainThreadFrame] = []
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
            // #40: the line tool's second point being found over the ink: each frame snaps the tip through the index with
            // a point to work from, catches the angle, and places the loupe, the preview and the guide. Lifted on the last
            // frame, which commits the line.
            Scenario(name: "shape", frames: 240, setUp: { b in
                b.editor.zoomToEverything()
                b.editor.tool = .lineAndShape
                b.editor.lineShape = .line
                guard let view = b.view else { return }
                _ = view.beginInput(at: CGPoint(x: 180, y: view.bounds.midY))
                view.endInput(samples: [CGPoint(x: 180, y: view.bounds.midY)], keep: true)
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
            }, tearDown: { b in
                b.editor.lineShape = .drawIt
                b.editor.tool = .pen
            }),
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
            // #44: the placed sheet twisted with two fingers, a degree and a half a frame, through the catches at each
            // quarter turn: a turn is one transform, and no sheet tile is drawn. Picking the sheet up lifts what comes along
            // out of the ink tiles in the warm-up, which waits for them to redraw; the last frame saves the turn as one record.
            turnScenario(name: "sheet_turn"),
            // #57: the measure tool's Pencil down and wandering back and forth across the placed sheet's left edge, from
            // its top corner to its bottom one: each frame snaps the tip through the ink index and the sheet index, to a
            // sheet corner or a sheet edge or the ink, and moves the loupe. Lifted on the last frame, which takes the point.
            Scenario(name: "sheet_snap", frames: 240, setUp: { b in
                b.zoomToSheet()
                b.editor.tool = .measure
                guard let view = b.view, let corners = b.editor.sheets.last?.corners else { return }
                // Out a little, so the edge is clear of the rail and the bars.
                b.editor.viewport.zoom(by: 0.7, about: ScreenPoint(x: Double(view.bounds.midX), y: Double(view.bounds.midY)))
                view.viewportJumped()
                let top = b.editor.viewport.screenPoint(for: corners[0]), bottom = b.editor.viewport.screenPoint(for: corners[3])
                b.edgeFrom = CGPoint(x: top.x, y: top.y)
                b.edgeTo = CGPoint(x: bottom.x, y: bottom.y)
                b.strokePoint = b.edgeFrom
                _ = view.beginInput(at: b.strokePoint)
            }, step: { b, i in
                guard let view = b.view else { return }
                let t = CGFloat(i) / 239, across = 14 * sin(CGFloat(i) / 6)
                let (dx, dy) = (b.edgeTo.x - b.edgeFrom.x, b.edgeTo.y - b.edgeFrom.y)
                let length = max(hypot(dx, dy), 1)
                b.strokePoint = CGPoint(x: b.edgeFrom.x + dx * t - dy / length * across,
                                        y: b.edgeFrom.y + dy * t + dx / length * across)
                if i == 239 {
                    view.endInput(samples: [b.strokePoint], keep: true)
                } else {
                    view.moveInput(samples: [b.strokePoint], predicted: [])
                }
            }, tearDown: { b in b.editor.tool = .pen }),
        ]
    }

    private static func turnScenario(name: String) -> Scenario {
        Scenario(name: name, frames: 240, setUp: { b in
            b.zoomToSheet()
            b.editor.tool = .lasso
            guard let view = b.view, let sheet = b.placedSheet else { return }
            b.editor.select(CanvasSelection(sheet: sheet.id))
            // The lift: choosing what comes along and building its strokes' paths, on the main thread, once per turn.
            let liftStart = CACurrentMediaTime()
            _ = view.beginSheetTwist(fingerAngle: 0)
            let lift = (CACurrentMediaTime() - liftStart) * 1000
            b.holdsForTiles = true
            b.record("  \(name) came_along=\(view.debugSheetDragStrokes) lift_ms=\(b.format(lift)) pending_at_lift=\(view.pendingRenderCount)")
        }, step: { b, i in
            guard let view = b.view else { return }
            if i == 0 { b.tilesBeforeTurn = view.debugSheetTiles.drawn }
            if i == 239 {
                view.finishSheetDrag(keep: true)
            } else {
                view.twistSheet(fingerAngle: -1.5 * Double(i + 1))
            }
        }, tearDown: { b in
            let drawn = (b.view?.debugSheetTiles.drawn ?? 0) - b.tilesBeforeTurn
            b.record("  \(name) tiles_drawn_during_turn=\(drawn) angle=\(b.editor.sheets.last?.angle ?? -1)")
            b.editor.tool = .pen
        })
    }

    /// How fast this runner is just now, from work that no change to Vellum can touch: a fixed path stroked into a
    /// bitmap, five times, the median in milliseconds. `Scripts/perf-compare.py` scales the Release timing baselines by it.
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

    /// Places the made-up sheet in the middle of the canvas, with no saver (the test canvas is never saved), and
    /// zooms to it.
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
        MainThreadLedger.start()
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
        holdStart = CACurrentMediaTime()
        work.removeAll()
        intervals.removeAll()
        keptRedraws.removeAll()
        stepWork.removeAll()
        ledgerFrames.removeAll()
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
        if holdsForTiles {
            if (view?.pendingRenderCount ?? 0) > 0, now - holdStart < Self.settleLimit { return }
            holdsForTiles = false
        }
        if let last = lastTimestamp {
            let interval = (link.timestamp - last) * 1000
            intervals.append(interval)
            if let ledger = MainThreadLedger.closeFrame(gapMs: interval, keep: true) { ledgerFrames.append(ledger) }
        } else {
            _ = MainThreadLedger.closeFrame(gapMs: 0, keep: false)
        }
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
        stepWork.append((CACurrentMediaTime() - now) * 1000)
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
        let sortedSteps = stepWork.sorted()
        record("  step_ms median=\(format(percentile(sortedSteps, 0.5))) p95=\(format(percentile(sortedSteps, 0.95)))"
            + " max=\(format(sortedSteps.last ?? 0))")
        // Where a slow frame fell, beside the kept layer's drawings, to tell one from the other.
        let slowWork = work.enumerated().filter { $0.element > budget }.map { "\($0.offset):\(format($0.element))" }
        let slowGaps = intervals.enumerated().filter { $0.element > expectedInterval * 1000 * 1.5 }
            .map { "\($0.offset):\(format($0.element))" }
        record("  slow work \(slowWork), long gaps \(slowGaps), kept redraws \(keptRedraws)")
        reportLedger(gapOver: expectedInterval * 1000 * 1.5)
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

    /// What ran on the main thread (#42): each part's total over the scenario and its most in one frame, then for every
    /// frame that came after a long gap, what ran before it. Gap n is between measured frames n and n + 1, as above.
    private func reportLedger(gapOver longGap: Double) {
        var totals: [String: (count: Int, ms: Double, most: Double)] = [:]
        var order: [String] = []
        for frame in ledgerFrames {
            for part in frame.parts {
                if totals[part.name] == nil { order.append(part.name) }
                let was = totals[part.name] ?? (0, 0, 0)
                totals[part.name] = (was.count + part.count, was.ms + part.ms, max(was.most, part.ms))
            }
        }
        let busy = ledgerFrames.map(\.busyMs).sorted()
        record("  main busy_ms median=\(format(percentile(busy, 0.5))) p95=\(format(percentile(busy, 0.95)))"
            + " max=\(format(busy.last ?? 0)); parts " + order.map { name in
                let t = totals[name]!
                return "\(name.replacingOccurrences(of: " ", with: "_"))=\(t.count)/\(format(t.ms))ms(most \(format(t.most)))"
            }.joined(separator: " "))
        for (n, frame) in ledgerFrames.enumerated() where frame.gapMs > longGap {
            record("  gap \(n): \(frame.text)")
        }
    }

    /// What the Speed check adds to a frame's main-thread work, in microseconds (#42): a gesture's per-frame bookkeeping,
    /// three parts timed, and the three run loop observers' work, 20,000 times, on the main thread, the mean.
    private func speedCheckCost() -> Double {
        let rounds = 20_000
        var timing = GestureTiming(start: CACurrentMediaTime(), overSheet: true)
        let start = CACurrentMediaTime()
        for i in 0..<rounds {
            MainThreadLedger.woke()
            for part in [MainThreadLedger.Part.sheetPlan, .inkPlan, .viewMoved] {
                let began = MainThreadLedger.begin()
                MainThreadLedger.end(part, began)
            }
            timing.frame(timestamp: Double(i) / 120, interval: 1.0 / 120)
            MainThreadLedger.willCommit()
            MainThreadLedger.willSleep()
        }
        let perFrame = (CACurrentMediaTime() - start) / Double(rounds) * 1_000_000
        timing.cancel()
        return perFrame
    }

    private func finish() {
        link?.invalidate()
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        let cost = speedCheckCost()
        MainThreadLedger.stop()
        record("speed_check_us_per_frame=\(format(cost)) (off: one branch per hook, nothing else)")
        #if !DEBUG
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
