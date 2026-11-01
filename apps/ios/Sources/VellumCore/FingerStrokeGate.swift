/// The Draw with finger setting (#24): off by default, as in Apple Notes, and kept on the Duo. Off, only the Pencil
/// draws and fingers pan and pinch. On, one finger also draws, erases or uses whichever tool is selected, and two
/// fingers pan and pinch.
public enum FingerDrawingSetting {
    /// The UserDefaults key the switch is kept under.
    public static let storageKey = "drawsWithFinger"
    public static let `default` = false

    /// What a touch does to the canvas.
    public enum Touch: Sendable {
        case pencil
        case finger
    }

    /// Whether a touch of this kind draws. The Pencil always does; a finger only with the switch on.
    @inlinable
    public static func draws(_ touch: Touch, fingerDraws: Bool) -> Bool {
        touch == .pencil || fingerDraws
    }

    /// How the canvas describes itself to VoiceOver, for the switch's two positions.
    public static func accessibilityHint(fingerDraws: Bool) -> String {
        fingerDraws
            ? "Draw with the Apple Pencil or one finger. Pan and pinch with two fingers."
            : "Draw with the Apple Pencil. Pan and pinch with your fingers."
    }
}

/// Decides when a finger stroke becomes ink, with Draw with finger on (#24). The Pencil never goes through it.
///
/// A finger stroke starts pending: it is drawn live at once, but it is not yet clearly one finger, since a two-finger
/// pan or pinch starts with one finger too. A second finger within `secondFingerWindow` of touchdown cancels it:
/// nothing is committed, saved or put on the undo stack, and the fingers pan and pinch. Once the window has passed
/// with one finger, or the finger lifts inside it, the stroke is confirmed; a second finger after that ends the stroke
/// where it is, kept, and the fingers pan. An eraser sweep holds its samples while pending and erases them once
/// confirmed, so a cancelled sweep erases nothing.
///
/// Times are seconds on one clock (a `UITouch` timestamp or a display link's, both since boot).
public struct FingerStrokeGate: Equatable, Sendable {
    /// How long after touchdown a second finger turns a finger stroke into a pan or pinch: 130 ms, long enough for two
    /// fingers put down together to land, short enough that an eraser sweep held for it is barely noticed. Live ink
    /// is never held: it shows at once either way.
    public static let secondFingerWindow = 0.130

    public enum Phase: Equatable, Sendable {
        /// No finger stroke.
        case idle
        /// Drawn live but not yet ink: a second finger before `since + secondFingerWindow` cancels it.
        case pending(since: Double)
        /// Clearly one finger: the stroke is ink, and is committed when the finger lifts.
        case confirmed
        /// A second finger came within the window: nothing is kept.
        case cancelled
    }

    /// What a second finger does to the finger stroke in progress.
    public enum SecondFinger: Equatable, Sendable {
        /// Drop the stroke: remove its live ink and commit nothing. The fingers pan and pinch.
        case cancel
        /// Keep the stroke as drawn so far and end it. The fingers pan and pinch.
        case end
        /// There is no finger stroke in progress.
        case none
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    /// Whether the stroke is still waiting to be clearly one finger.
    public var isPending: Bool {
        if case .pending = phase { return true }
        return false
    }

    /// A finger touched down, alone on the glass, and started a stroke or an eraser sweep.
    public mutating func fingerDown(at time: Double) {
        phase = .pending(since: time)
    }

    /// The finger moved or a frame passed. Returns true when this call confirmed the stroke, because the window has
    /// passed with one finger; an eraser sweep then erases the samples it held.
    @discardableResult
    public mutating func tick(at time: Double) -> Bool {
        guard case .pending(let since) = phase, time >= since + Self.secondFingerWindow else { return false }
        phase = .confirmed
        return true
    }

    /// Another finger touched down while the stroke's finger is on the glass. The window is compared as a deadline
    /// (`since + secondFingerWindow`), not as an elapsed time, so a finger landing exactly at the edge is after it
    /// whatever the rounding of the subtraction.
    public mutating func secondFinger(at time: Double) -> SecondFinger {
        switch phase {
        case .pending(let since) where time < since + Self.secondFingerWindow:
            phase = .cancelled
            return .cancel
        case .pending, .confirmed:
            phase = .idle
            return .end
        case .idle, .cancelled:
            return .none
        }
    }

    /// The finger lifted. Returns whether to keep the stroke: a stroke lifted inside the window was one finger, so it
    /// is kept; only a cancelled one is not.
    public mutating func lift() -> Bool {
        defer { phase = .idle }
        switch phase {
        case .pending, .confirmed: return true
        case .idle, .cancelled: return false
        }
    }

    /// The system interrupted the finger (a gesture took it, or a call came in). Returns whether to keep the stroke:
    /// a confirmed one is ink and is kept; a pending one is most likely the start of a pan and is dropped.
    public mutating func interrupted() -> Bool {
        defer { phase = .idle }
        return phase == .confirmed
    }
}
