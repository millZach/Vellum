import XCTest
@testable import VellumCore

/// The Speed check (#42): what a run of made-up frame timestamps says, and the line a timed gesture is copied as.
final class SpeedCheckTests: XCTestCase {
    private let frame120 = 1.0 / 120

    /// Timestamps at a steady interval, with some frames left out.
    private func frames(_ count: Int, interval: Double, skipping skipped: Set<Int> = []) -> [Double] {
        (0..<count).filter { !skipped.contains($0) }.map { Double($0) * interval }
    }

    // MARK: The switch

    func testTheSwitchIsOffByDefaultAndKeepsTenGestures() {
        XCTAssertFalse(SpeedCheckSetting.default)
        XCTAssertEqual(SpeedCheckSetting.storageKey, "speedCheck")
        XCTAssertEqual(SpeedCheckSetting.kept, 10)
    }

    func testTheFooterSaysWhatItDoesOffAndOn() {
        XCTAssertEqual(SpeedCheckSetting.footer(isOn: false),
                       "Times each pan and pinch on this Duo, to find slow frames. Off unless you turn it on.")
        XCTAssertEqual(SpeedCheckSetting.footer(isOn: true),
                       "Vellum times each pan and pinch on this Duo and keeps only the numbers, never the drawing. Turn it off when you are done.")
    }

    // MARK: The summary

    func testASmoothRunMissesNothing() {
        let summary = FrameTiming.summary(timestamps: frames(240, interval: frame120), frameInterval: frame120)
        XCTAssertEqual(summary.frames, 240)
        XCTAssertEqual(summary.missed, 0)
        XCTAssertEqual(summary.worstGapMs, 1000.0 / 120, accuracy: 1e-9)
        XCTAssertEqual(summary.gapsOver50ms, 0)
        XCTAssertEqual(summary.longGaps, [])
    }

    func testEachLongGapCountsTheFramesItSpans() {
        // Frame 10 left out: a gap of two frames, one missed. Frames 50 to 59 left out: a gap of eleven, ten missed.
        let skipped = Set([10] + Array(50...59))
        let summary = FrameTiming.summary(timestamps: frames(240, interval: frame120, skipping: skipped),
                                          frameInterval: frame120)
        XCTAssertEqual(summary.frames, 229)
        XCTAssertEqual(summary.missed, 11)
        XCTAssertEqual(summary.worstGapMs, 11000.0 / 120, accuracy: 1e-9)
        XCTAssertEqual(summary.gapsOver50ms, 1)
        // Gap i ends at frame i of those drawn: frame 11 is the tenth drawn, frame 60 the forty-ninth.
        XCTAssertEqual(summary.longGaps, [10, 49])
    }

    func testJitterUnderHalfAFrameIsNotAMiss() {
        // 8.33, 12.4 (under one and a half frames), then 8.33 again.
        let times = [0, 1.0 / 120, 1.0 / 120 + 0.0124, 2.0 / 120 + 0.0124]
        let summary = FrameTiming.summary(timestamps: times, frameInterval: frame120)
        XCTAssertEqual(summary.missed, 0)
        XCTAssertEqual(summary.longGaps, [])
        XCTAssertEqual(summary.worstGapMs, 12.4, accuracy: 1e-9)
    }

    func testAGapJustOverOneAndAHalfFramesIsOneMiss() {
        // 13 ms at 120 Hz is 1.56 frames: rounds to two frames, one missed.
        let summary = FrameTiming.summary(timestamps: [0, 0.013], frameInterval: frame120)
        XCTAssertEqual(summary.missed, 1)
        XCTAssertEqual(summary.longGaps, [1])
    }

    func testAt60HzTheSameGapIsFewerMissedFrames() {
        // A 50.1 ms gap is six frames at 120 Hz (five missed) and three at 60 Hz (two missed); it is over 50 ms either way.
        let times = [0, 0.0501]
        XCTAssertEqual(FrameTiming.summary(timestamps: times, frameInterval: frame120).missed, 5)
        let at60 = FrameTiming.summary(timestamps: times, frameInterval: 1.0 / 60)
        XCTAssertEqual(at60.missed, 2)
        XCTAssertEqual(at60.gapsOver50ms, 1)
        XCTAssertEqual(at60.longGaps, [1])
    }

    func testNoFramesOrOneFrameHasNoGaps() {
        XCTAssertEqual(FrameTiming.summary(timestamps: [], frameInterval: frame120),
                       FrameSummary(frames: 0, missed: 0, worstGapMs: 0, gapsOver50ms: 0, longGaps: []))
        XCTAssertEqual(FrameTiming.summary(timestamps: [3], frameInterval: frame120),
                       FrameSummary(frames: 1, missed: 0, worstGapMs: 0, gapsOver50ms: 0, longGaps: []))
    }

    // MARK: A whole gesture, touch-down to lift (#42 review)

    /// `count` frames `step` apart from `first`, each reporting `step` as its interval.
    private func steady(from first: Double, count: Int, step: Double) -> (times: [Double], intervals: [Double]) {
        ((0..<count).map { first + Double($0) * step }, Array(repeating: step, count: count))
    }

    func testTheSpansFromTouchDownAndToLiftAreGapsLikeAnyOther() {
        // Touch-down at 0, the first frame 100 ms later, ten frames at 120 Hz, and the fingers lift 100 ms after the last.
        let (times, intervals) = steady(from: 0.1, count: 10, step: frame120)
        let summary = FrameTiming.gesture(start: 0, timestamps: times, intervals: intervals, end: times.last! + 0.1)
        XCTAssertEqual(summary.frames, 10)
        // Each 100 ms span is twelve frames at 120 Hz, eleven missed.
        XCTAssertEqual(summary.missed, 22)
        XCTAssertEqual(summary.worstGapMs, 100, accuracy: 1e-9)
        XCTAssertEqual(summary.gapsOver50ms, 2)
        // Gap 0 runs from touch-down to frame 0; gap 10 from frame 9 to the lift.
        XCTAssertEqual(summary.longGaps, [0, 10])
    }

    func testASmoothGestureFromTouchDownToLiftMissesNothing() {
        let (times, intervals) = steady(from: 0.004, count: 120, step: frame120)
        let summary = FrameTiming.gesture(start: 0, timestamps: times, intervals: intervals, end: times.last! + 0.006)
        XCTAssertEqual(summary.missed, 0)
        XCTAssertEqual(summary.longGaps, [])
        XCTAssertEqual(summary.worstGapMs, 1000.0 / 120, accuracy: 1e-9)
    }

    func testEachGapIsJudgedAtTheRateTheDisplayReportedForIt() {
        // Sixty frames at 120 Hz, then the display drops to 80 Hz for forty: 12.5 ms frames, each as long as one and a half
        // 120 Hz frames, and no stall. Judged at a single 120 Hz rate they would sit on the line; at their own, none is missed.
        let fast = steady(from: 0.004, count: 60, step: frame120)
        let slow = steady(from: fast.times.last! + 1.0 / 80, count: 40, step: 1.0 / 80)
        // The last 120 Hz frame reports the 80 Hz interval that follows it.
        var intervals = fast.intervals + slow.intervals
        intervals[59] = 1.0 / 80
        let times = fast.times + slow.times
        let smooth = FrameTiming.gesture(start: 0, timestamps: times, intervals: intervals, end: times.last! + 0.006)
        XCTAssertEqual(smooth.frames, 100)
        XCTAssertEqual(smooth.missed, 0)
        XCTAssertEqual(smooth.longGaps, [])

        // The same with a real stall at 80 Hz: frame 80 lands 62.5 ms after frame 79, five 80 Hz frames, four missed.
        var stalled = times
        for i in 80..<stalled.count { stalled[i] += 0.0625 - 1.0 / 80 }
        let summary = FrameTiming.gesture(start: 0, timestamps: stalled, intervals: intervals, end: stalled.last! + 0.006)
        XCTAssertEqual(summary.missed, 4)
        XCTAssertEqual(summary.worstGapMs, 62.5, accuracy: 1e-9)
        XCTAssertEqual(summary.gapsOver50ms, 1)
        XCTAssertEqual(summary.longGaps, [80])
    }

    func testAGestureWithNoFramesHasNoGaps() {
        XCTAssertEqual(FrameTiming.gesture(start: 0, timestamps: [], intervals: [], end: 0.2),
                       FrameSummary(frames: 0, missed: 0, worstGapMs: 0, gapsOver50ms: 0, longGaps: []))
    }

    func testTheRateIsWholeFramesASecond() {
        XCTAssertEqual(FrameTiming.rate(frameInterval: 1.0 / 120), 120)
        XCTAssertEqual(FrameTiming.rate(frameInterval: 0.016_67), 60)
        XCTAssertEqual(FrameTiming.rate(frameInterval: 0), 0)
    }

    // MARK: What ran on the main thread

    func testAFrameNamesItsPartsAndWhatIsLeft() {
        let frame = MainThreadFrame(gapMs: 92.44, busyMs: 61.2, parts: [
            .init(name: "sheet tiles landed", count: 3, ms: 12.5),
            .init(name: "ink tiles landed", count: 0, ms: 0),
            .init(name: "commit", count: 1, ms: 30.1),
        ])
        XCTAssertEqual(frame.parts.map(\.name), ["sheet tiles landed", "commit"])
        XCTAssertEqual(frame.otherMs, 18.6, accuracy: 1e-9)
        XCTAssertEqual(frame.text, "gap 92.4 ms, main 61.2 ms: sheet tiles landed 3 in 12.5 ms, commit 1 in 30.1 ms, other 18.6 ms")
    }

    func testTheMainThreadsCPUTimeFollowsItsAwakeTime() {
        let frame = MainThreadFrame(gapMs: 65.07, busyMs: 55.18, cpuMs: 3.04, parts: [.init(name: "sheet plan", count: 2, ms: 0.2)])
        XCTAssertEqual(frame.text, "gap 65.1 ms, main 55.2 ms (cpu 3.0 ms): sheet plan 2 in 0.2 ms, other 55.0 ms")
    }

    func testOtherIsNeverBelowNothing() {
        let frame = MainThreadFrame(gapMs: 16.7, busyMs: 1, parts: [.init(name: "commit", count: 1, ms: 1.2)])
        XCTAssertEqual(frame.otherMs, 0)
    }

    // MARK: The copied line

    private func gesture(overSheet: Bool, worst: [MainThreadFrame] = []) -> SpeedCheckGesture {
        SpeedCheckGesture(id: 1, kind: .pinch, overSheet: overSheet, hour: 7, minute: 5, seconds: 1.94, rate: 120,
                          summary: FrameSummary(frames: 228, missed: 4, worstGapMs: 92.44, gapsOver50ms: 1, longGaps: [41]),
                          unfolded: true, worstFrames: worst)
    }

    func testAGestureIsCopiedAsOneLineStartingWithTheBuildThePostureAndTheRate() {
        XCTAssertEqual(gesture(overSheet: true).line(build: "20261105.175835"),
                       "Vellum speed check, build 20261105.175835, Duo unfolded, 120 Hz, 07:05: pinch over a sheet, 1.9 s, "
                       + "228 frames, 4 missed, worst gap 92.4 ms, gaps over 50 ms: 1")
        var pan = gesture(overSheet: false)
        pan.kind = .pan
        pan.hour = 17
        pan.minute = 58
        pan.unfolded = false
        XCTAssertEqual(pan.line(build: "20261105.175835"),
                       "Vellum speed check, build 20261105.175835, Duo folded, 120 Hz, 17:58: pan, 1.9 s, "
                       + "228 frames, 4 missed, worst gap 92.4 ms, gaps over 50 ms: 1")
    }

    func testTheWorstFramesFollowTheNumbers() {
        let worst = [
            MainThreadFrame(gapMs: 92.4, busyMs: 61.2, parts: [.init(name: "sheet tiles landed", count: 3, ms: 12.5)]),
            MainThreadFrame(gapMs: 41.7, busyMs: 2, parts: []),
        ]
        XCTAssertEqual(gesture(overSheet: true, worst: worst).line(build: "1"),
                       "Vellum speed check, build 1, Duo unfolded, 120 Hz, 07:05: pinch over a sheet, 1.9 s, 228 frames, "
                       + "4 missed, worst gap 92.4 ms, gaps over 50 ms: 1; worst frames: "
                       + "gap 92.4 ms, main 61.2 ms: sheet tiles landed 3 in 12.5 ms, other 48.7 ms; "
                       + "gap 41.7 ms, main 2.0 ms: other 2.0 ms")
    }

    func testEachCopiedLineCarriesThePostureItsGestureWasTimedIn() {
        // Timed unfolded, then folded, then copied: each line keeps its own posture, whatever the Duo is at the copy.
        var unfolded = gesture(overSheet: true)
        unfolded.hour = 9
        var folded = gesture(overSheet: false)
        folded.kind = .pan
        folded.hour = 10
        folded.unfolded = false
        XCTAssertEqual(SpeedCheckGesture.copyText([folded, unfolded], build: "7"),
                       "Vellum speed check, build 7, Duo folded, 120 Hz, 10:05: pan, 1.9 s, 228 frames, 4 missed, "
                       + "worst gap 92.4 ms, gaps over 50 ms: 1\n"
                       + "Vellum speed check, build 7, Duo unfolded, 120 Hz, 09:05: pinch over a sheet, 1.9 s, 228 frames, "
                       + "4 missed, worst gap 92.4 ms, gaps over 50 ms: 1")
    }

    func testSettingsShowsTheTitleTimeAndWorstGap() {
        let shown = gesture(overSheet: true)
        XCTAssertEqual(shown.title, "Pinch over a sheet")
        XCTAssertEqual(shown.timeOfDay, "07:05")
        XCTAssertEqual(shown.worst, "worst 92.4 ms")
    }

    func testNumbersRoundToOneDecimal() {
        XCTAssertEqual(SpeedCheckText.ms(0), "0.0")
        XCTAssertEqual(SpeedCheckText.ms(8.333), "8.3")
        XCTAssertEqual(SpeedCheckText.ms(33.36), "33.4")
        XCTAssertEqual(SpeedCheckText.ms(191.84), "191.8")
        XCTAssertEqual(SpeedCheckText.seconds(12.06), "12.1")
    }
}
