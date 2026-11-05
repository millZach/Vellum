import Foundation
import Observation
import QuartzCore
import VellumCore

/// The Speed check's timed gestures (#42): the last ten, newest first, in memory only. Nothing is written to disk or
/// sent anywhere, and they are gone when the app quits. Settings lists them, with Copy all and Clear.
@MainActor
@Observable
final class SpeedCheckRecorder {
    static let shared = SpeedCheckRecorder()

    private(set) var gestures: [SpeedCheckGesture] = []
    @ObservationIgnored private var nextID = 0

    /// Keeps a finished gesture; one too short to have a gap between two frames says nothing and is let go.
    func add(_ gesture: GestureTiming.Finished) {
        guard gesture.summary.frames > 1 else { return }
        nextID += 1
        let parts = Calendar.current.dateComponents([.hour, .minute], from: gesture.startedAt)
        let timed = SpeedCheckGesture(id: nextID, kind: gesture.kind, overSheet: gesture.overSheet, hour: parts.hour ?? 0,
                                      minute: parts.minute ?? 0, seconds: gesture.seconds, rate: gesture.rate,
                                      summary: gesture.summary, worstFrames: gesture.worstFrames)
        gestures.insert(timed, at: 0)
        if gestures.count > SpeedCheckSetting.kept { gestures.removeLast(gestures.count - SpeedCheckSetting.kept) }
    }

    func clear() { gestures.removeAll() }

    /// One line per gesture, newest first, as Copy all puts them on the pasteboard.
    func copyText(unfolded: Bool) -> String {
        gestures.map { $0.line(build: Self.build, unfolded: unfolded) }.joined(separator: "\n")
    }

    /// The build number TestFlight shows (`Scripts/build-number.sh`).
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown" }

    #if DEBUG
    /// Two made-up gestures for the Settings capture (`--ui-speed-check-gestures`). Their numbers are invented.
    func addMadeUpGestures() {
        let day = Calendar.current.startOfDay(for: Date())
        add(.init(kind: .pan, overSheet: false, startedAt: day.addingTimeInterval(9 * 3600 + 41 * 60), seconds: 1.2, rate: 120,
                  summary: FrameSummary(frames: 144, missed: 0, worstGapMs: 9.1, gapsOver50ms: 0, longGaps: []),
                  worstFrames: []))
        add(.init(kind: .pinch, overSheet: true, startedAt: day.addingTimeInterval(9 * 3600 + 43 * 60), seconds: 1.9, rate: 120,
                  summary: FrameSummary(frames: 224, missed: 4, worstGapMs: 41.7, gapsOver50ms: 0, longGaps: [97]),
                  worstFrames: [MainThreadFrame(gapMs: 41.7, busyMs: 12.4, parts: [
                      .init(name: MainThreadLedger.Part.sheetTilesLanded.name, count: 2, ms: 3.1),
                  ])]))
    }
    #endif
}

/// One pan or pinch being timed, from touch-down to the fingers lifting. The canvas has no deceleration: a pan or a
/// pinch stops where the fingers leave it, so the gesture ends there. Each display frame costs an append and the
/// ledger's close; what ran on the main thread is kept only for the few frames with the longest gaps.
@MainActor
struct GestureTiming {
    struct Finished {
        var kind: SpeedCheckGesture.Kind
        var overSheet: Bool
        var startedAt: Date
        var seconds: Double
        var rate: Int
        var summary: FrameSummary
        var worstFrames: [MainThreadFrame]
    }

    private let start: Double
    private let startedAt: Date
    var kind = SpeedCheckGesture.Kind.pan
    var overSheet: Bool
    private var timestamps: [Double] = []
    /// The display's frame interval as each frame reported it; the median is the rate the gesture ran at.
    private var intervals: [Double] = []
    private var worst: [MainThreadFrame] = []

    /// Starts timing at touch-down: `start` in the clock touches and display links use (`CACurrentMediaTime`).
    init(start: Double, overSheet: Bool) {
        self.start = start
        startedAt = Date(timeIntervalSinceNow: start - CACurrentMediaTime())
        self.overSheet = overSheet
        timestamps.reserveCapacity(1024)
        intervals.reserveCapacity(1024)
        MainThreadLedger.start()
    }

    /// A display frame: its timestamp, and the frame interval the display link reports now.
    mutating func frame(timestamp: Double, interval: Double) {
        let gap = timestamps.last.map { (timestamp - $0) * 1000 } ?? 0
        timestamps.append(timestamp)
        intervals.append(interval)
        let keep = worst.count < SpeedCheckSetting.worstFramesKept || gap > worst[worst.count - 1].gapMs
        guard let frame = MainThreadLedger.closeFrame(gapMs: gap, keep: keep && timestamps.count > 1) else { return }
        worst.append(frame)
        worst.sort { $0.gapMs > $1.gapMs }
        if worst.count > SpeedCheckSetting.worstFramesKept { worst.removeLast() }
    }

    /// The fingers lifted at `end`: the gesture's numbers. The ledger stops counting.
    func finish(end: Double) -> Finished {
        MainThreadLedger.stop()
        let interval = intervals.isEmpty ? 1.0 / 120 : intervals.sorted()[intervals.count / 2]
        return Finished(kind: kind, overSheet: overSheet, startedAt: startedAt, seconds: max(0, end - start),
                        rate: FrameTiming.rate(frameInterval: interval),
                        summary: FrameTiming.summary(timestamps: timestamps, frameInterval: interval),
                        worstFrames: worst)
    }

    /// Dropped without a record (the fingers turned out to move a sheet, or the switch went off).
    func cancel() { MainThreadLedger.stop() }
}
