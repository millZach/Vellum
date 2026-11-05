#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The Speed check (#42): a switch in Settings, off by default and kept on the Duo, that times each pan and pinch on a
/// canvas and keeps only the numbers, never the drawing, in memory, for Zach to copy into an issue. This holds what is
/// testable without a device: the switch's key, what a run of frame timestamps says, and the line a gesture is copied as.
public enum SpeedCheckSetting {
    /// The UserDefaults key the switch is kept under.
    public static let storageKey = "speedCheck"
    public static let `default` = false
    /// How many timed gestures Settings lists, newest first. Older ones are let go.
    public static let kept = 10
    /// How many of a gesture's worst frames carry what ran on the main thread.
    public static let worstFramesKept = 3

    public static func footer(isOn: Bool) -> String {
        isOn
            ? "Vellum times each pan and pinch on this Duo and keeps only the numbers, never the drawing. Turn it off when you are done."
            : "Times each pan and pinch on this Duo, to find slow frames. Off unless you turn it on."
    }
}

/// What a run of display frames says about how smooth it was.
public struct FrameSummary: Equatable, Sendable {
    /// Frames drawn: one per timestamp.
    public var frames: Int
    /// Frames the display had time for and was not given: for each gap longer than one and a half frames, the whole
    /// frames it spans less the one that was drawn.
    public var missed: Int
    /// The longest gap between two frames, in milliseconds; 0 with fewer than two frames.
    public var worstGapMs: Double
    /// Gaps longer than 50 ms, the stalls anyone would feel.
    public var gapsOver50ms: Int
    /// The index of each gap longer than one and a half frames: gap i is between frame i - 1 and frame i.
    public var longGaps: [Int]

    public init(frames: Int, missed: Int, worstGapMs: Double, gapsOver50ms: Int, longGaps: [Int]) {
        self.frames = frames
        self.missed = missed
        self.worstGapMs = worstGapMs
        self.gapsOver50ms = gapsOver50ms
        self.longGaps = longGaps
    }
}

public enum FrameTiming {
    /// A gap this many frames long or more is a missed frame; less is the display's own jitter.
    public static let longGapFactor = 1.5

    /// Sums up display frames from their timestamps, in seconds, at the display's frame interval, in seconds.
    public static func summary(timestamps: [Double], frameInterval: Double) -> FrameSummary {
        var missed = 0, worst = 0.0, over50 = 0
        var long: [Int] = []
        if timestamps.count > 1 {
            for i in 1..<timestamps.count {
                let gap = timestamps[i] - timestamps[i - 1]
                worst = max(worst, gap)
                if gap * 1000 > 50 { over50 += 1 }
                if frameInterval > 0, gap > frameInterval * longGapFactor {
                    long.append(i)
                    missed += max(1, Int((gap / frameInterval).rounded()) - 1)
                }
            }
        }
        return FrameSummary(frames: timestamps.count, missed: missed, worstGapMs: worst * 1000, gapsOver50ms: over50,
                            longGaps: long)
    }

    /// The display's rate in whole frames a second, from its frame interval in seconds.
    public static func rate(frameInterval: Double) -> Int {
        frameInterval > 0 ? Int((1 / frameInterval).rounded()) : 0
    }
}

/// What the main thread did between two display frames (#42), counted by the app's ledger: how long it was busy in
/// all, and the parts of that it can name.
public struct MainThreadFrame: Equatable, Sendable {
    /// One kind of work: how many times it ran and how long it took in all, in milliseconds.
    public struct Part: Equatable, Sendable {
        public var name: String
        public var count: Int
        public var ms: Double

        public init(name: String, count: Int, ms: Double) {
            self.name = name
            self.count = count
            self.ms = ms
        }
    }

    /// The gap that ended at this frame, in milliseconds.
    public var gapMs: Double
    /// How long the main thread was awake in that gap, in milliseconds.
    public var busyMs: Double
    /// How much of that it really ran on a core, in milliseconds, when the clock was read: awake time well above it is
    /// the thread waiting for a core, not work.
    public var cpuMs: Double?
    /// The named parts, in the order the ledger keeps them; parts that did not run are left out.
    public var parts: [Part]

    public init(gapMs: Double, busyMs: Double, cpuMs: Double? = nil, parts: [Part]) {
        self.gapMs = gapMs
        self.busyMs = busyMs
        self.cpuMs = cpuMs
        self.parts = parts.filter { $0.count > 0 }
    }

    /// Busy time no part accounts for: SwiftUI, UIKit and the system.
    public var otherMs: Double { max(0, busyMs - parts.reduce(0) { $0 + $1.ms }) }

    /// `gap 92.4 ms, main 61.2 ms (cpu 20.3 ms): sheet tiles landed 3 in 12.5 ms, commit 1 in 30.1 ms, other 18.6 ms`.
    public var text: String {
        var pieces = parts.map { "\($0.name) \($0.count) in \(SpeedCheckText.ms($0.ms)) ms" }
        pieces.append("other \(SpeedCheckText.ms(otherMs)) ms")
        let cpu = cpuMs.map { " (cpu \(SpeedCheckText.ms($0)) ms)" } ?? ""
        return "gap \(SpeedCheckText.ms(gapMs)) ms, main \(SpeedCheckText.ms(busyMs)) ms\(cpu): " + pieces.joined(separator: ", ")
    }
}

/// One timed pan or pinch.
public struct SpeedCheckGesture: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case pan, pinch
    }

    public var id: Int
    public var kind: Kind
    /// Whether a placed sheet was on screen when it started or ended.
    public var overSheet: Bool
    /// The time of day it started, as the Duo's clock read it.
    public var hour: Int
    public var minute: Int
    /// Touch-down to the end of the gesture, in seconds.
    public var seconds: Double
    /// The display's rate while it ran, in frames a second.
    public var rate: Int
    public var summary: FrameSummary
    /// The frames with the longest gaps, longest first, with what ran on the main thread before each.
    public var worstFrames: [MainThreadFrame]

    public init(id: Int, kind: Kind, overSheet: Bool, hour: Int, minute: Int, seconds: Double, rate: Int,
                summary: FrameSummary, worstFrames: [MainThreadFrame]) {
        self.id = id
        self.kind = kind
        self.overSheet = overSheet
        self.hour = hour
        self.minute = minute
        self.seconds = seconds
        self.rate = rate
        self.summary = summary
        self.worstFrames = worstFrames
    }

    /// "Pinch over a sheet", "Pan".
    public var title: String {
        let name = kind == .pan ? "Pan" : "Pinch"
        return overSheet ? name + " over a sheet" : name
    }

    /// "17:58".
    public var timeOfDay: String { SpeedCheckText.twoDigits(hour) + ":" + SpeedCheckText.twoDigits(minute) }

    /// What Settings shows beside the title: "1.9 s · 4 missed".
    public var lengthAndMissed: String { "\(SpeedCheckText.seconds(seconds)) s · \(summary.missed) missed" }

    /// "worst 92.4 ms".
    public var worst: String { "worst \(SpeedCheckText.ms(summary.worstGapMs)) ms" }

    /// The line Copy all puts on the pasteboard for this gesture: the build, the Duo's posture and the display's rate
    /// first, then the gesture and its numbers, then what ran on the main thread in its worst frames. A sheet is named
    /// only as a sheet, never by its number, so a pasted line carries nothing of the drawing.
    public func line(build: String, unfolded: Bool) -> String {
        var line = "Vellum speed check, build \(build), Duo \(unfolded ? "unfolded" : "folded"), \(rate) Hz, \(timeOfDay): "
            + "\(title.lowercased()), \(SpeedCheckText.seconds(seconds)) s, \(summary.frames) frames, "
            + "\(summary.missed) missed, worst gap \(SpeedCheckText.ms(summary.worstGapMs)) ms, "
            + "gaps over 50 ms: \(summary.gapsOver50ms)"
        if !worstFrames.isEmpty {
            line += "; worst frames: " + worstFrames.map(\.text).joined(separator: "; ")
        }
        return line
    }
}

/// Number formats for the Speed check, the same on every locale, so a pasted line always reads alike.
public enum SpeedCheckText {
    /// One decimal: "92.4".
    public static func ms(_ value: Double) -> String { oneDecimal(value) }

    /// One decimal: "1.9".
    public static func seconds(_ value: Double) -> String { oneDecimal(value) }

    static func oneDecimal(_ value: Double) -> String {
        let tenths = Int((max(0, value) * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }

    static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}
