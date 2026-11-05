import QuartzCore
import VellumCore

/// Counts what runs on the main thread between display frames (#42), for the benchmark in Debug and BENCHMARK builds
/// and for the Speed check on the Duo, so a copy from the Duo answers the question CI answers.
///
/// Off, which is always unless one of those is timing, every hook is one branch on `isOn` and nothing else runs: no run
/// loop observer, no clock read. On, three run loop observers note when the main thread wakes, when Core Animation is
/// about to commit and when it goes back to sleep, and each named part reads the clock twice. Parts are timed
/// exclusive of the parts they call, so they never add up to more than the time the main thread was awake.
@MainActor
enum MainThreadLedger {
    /// The work the ledger names. Everything else the main thread does is "other": SwiftUI, UIKit and the system.
    enum Part: Int, CaseIterable {
        /// Sheet tiles drawn off the main thread, handed to their layers (`SheetRenderer`).
        case sheetTilesLanded
        /// Planning which sheet tiles a view needs and placing the sheets' layers (`SheetRenderer.show`).
        case sheetPlan
        /// Ink tiles handed to their layers (`InkTileRenderer`).
        case inkTilesLanded
        /// Ink tiles started: finding a tile's strokes before it is drawn off the main thread.
        case inkTilesStarted
        /// Planning which ink tiles a view needs and placing their levels (`InkTileRenderer.show`).
        case inkPlan
        /// The canvas view placing everything else for a new view: grid, overlays, text boxes, dimensions.
        case viewMoved
        /// Core Animation's commit at the end of a run loop turn, and anything after it before the thread sleeps.
        case commit

        var name: String {
            switch self {
            case .sheetTilesLanded: "sheet tiles landed"
            case .sheetPlan: "sheet plan"
            case .inkTilesLanded: "ink tiles landed"
            case .inkTilesStarted: "ink tiles started"
            case .inkPlan: "ink plan"
            case .viewMoved: "view moved"
            case .commit: "commit"
            }
        }
    }

    /// Whether anything is counting. Read by every hook; nothing else runs while it is false.
    private(set) static var isOn = false
    private static var users = 0
    private static var observers: [CFRunLoopObserver] = []
    private static var counts = [Int](repeating: 0, count: Part.allCases.count)
    private static var times = [Double](repeating: 0, count: Part.allCases.count)
    /// Time spent by parts called from inside the part running now, one entry per part under way.
    private static var nested: [Double] = []
    private static var busy = 0.0
    private static var wokeAt: Double?
    private static var commitAt: Double?

    /// Starts counting; each `start` is matched by a `stop`.
    static func start() {
        users += 1
        guard users == 1 else { return }
        reset()
        nested.removeAll(keepingCapacity: true)
        wokeAt = CACurrentMediaTime()
        // Core Animation commits from a before-waiting observer at order 2,000,000; just before it, and last of all.
        let woke = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { MainThreadLedger.woke() }
        }
        let committing = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_999) { _, _ in
            MainActor.assumeIsolated { MainThreadLedger.willCommit() }
        }
        let sleeping = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { MainThreadLedger.willSleep() }
        }
        observers = [woke, committing, sleeping].compactMap { $0 }
        for observer in observers { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        isOn = true
    }

    static func stop() {
        guard users > 0 else { return }
        users -= 1
        guard users == 0 else { return }
        isOn = false
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers.removeAll()
    }

    /// The clock at the start of a part, or 0 when nothing is counting. Pass it to `end`.
    @inline(__always)
    static func begin() -> Double {
        guard isOn else { return 0 }
        nested.append(0)
        return CACurrentMediaTime()
    }

    /// The end of a part begun with `begin`.
    @inline(__always)
    static func end(_ part: Part, _ start: Double) {
        guard isOn, start > 0, let inner = nested.popLast() else { return }
        let elapsed = CACurrentMediaTime() - start
        counts[part.rawValue] += 1
        times[part.rawValue] += elapsed - inner
        if !nested.isEmpty { nested[nested.count - 1] += elapsed }
    }

    /// Ends the frame, which runs from the last call to now: returns what ran when `keep` is true, and starts the next.
    /// Called from a display link, in the middle of the main thread's turn: the turn so far counts to this frame, the
    /// rest of it to the next.
    static func closeFrame(gapMs: Double, keep: Bool) -> MainThreadFrame? {
        guard isOn else { return nil }
        let now = CACurrentMediaTime()
        if let wokeAt { busy += now - wokeAt }
        wokeAt = now
        defer { reset() }
        guard keep else { return nil }
        return MainThreadFrame(gapMs: gapMs, busyMs: busy * 1000, parts: Part.allCases.map {
            MainThreadFrame.Part(name: $0.name, count: counts[$0.rawValue], ms: times[$0.rawValue] * 1000)
        })
    }

    private static func reset() {
        for i in counts.indices {
            counts[i] = 0
            times[i] = 0
        }
        busy = 0
    }

    // The run loop observers' work, called by them and by the benchmark's measure of what the ledger costs.

    static func woke() { wokeAt = CACurrentMediaTime() }

    static func willCommit() { commitAt = CACurrentMediaTime() }

    static func willSleep() {
        let now = CACurrentMediaTime()
        if let commitAt {
            counts[Part.commit.rawValue] += 1
            times[Part.commit.rawValue] += now - commitAt
        }
        commitAt = nil
        if let wokeAt { busy += now - wokeAt }
        wokeAt = nil
    }
}
