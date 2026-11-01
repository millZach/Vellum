/// One unbounded drawing surface measured in real-world lengths, the way AutoCAD's model space is (ADR-0002): its
/// name, its canvas units, the sheets and frames placed on it, and its ink.
///
/// SwiftUI has a `Canvas` view too; app code that imports both writes `VellumCore.Canvas`.
public struct Canvas: Hashable, Sendable {
    public var name: String
    public var units: CanvasUnits
    public var sheets: [Sheet]
    public var frames: [Frame]
    public var ink: Ink

    public init(name: String = "Untitled canvas", units: CanvasUnits = .default, sheets: [Sheet] = [],
                frames: [Frame] = [], ink: Ink = Ink()) {
        self.name = name
        self.units = units
        self.sheets = sheets
        self.frames = frames
        self.ink = ink
    }

    /// The rectangle everything on the canvas covers (sheets, frames and ink), for zoom to everything; nil for an
    /// empty canvas.
    public var extents: CanvasRect? {
        CanvasRect.union(sheets.map(\.bounds) + frames.map(\.bounds) + [ink.bounds].compactMap { $0 })
    }

    /// The length between two points on the canvas. It is real wherever the canvas is real, across any number of
    /// sheets at different scales, because every scaled sheet sits at real-world size. When either point lies on an
    /// NTS sheet the length is the printed length marked NTS, never a real one, even where that sheet overlaps others.
    public func measure(from start: CanvasPoint, to end: CanvasPoint) -> Measure {
        let distance = start.distance(to: end)
        let onNotToScaleSheet = sheets.contains { $0.isNotToScale && ($0.contains(start) || $0.contains(end)) }
        return onNotToScaleSheet ? .notToScale(PrintedLength(inches: distance.inches)) : .real(distance)
    }

    /// A measure shown in this canvas's units.
    public func format(_ measure: Measure) -> String { units.format(measure) }
}

/// A length read off the canvas between two points, which is not kept: a real length, or a printed length marked NTS
/// when it was read on an NTS sheet.
public enum Measure: Hashable, Sendable {
    case real(Length)
    case notToScale(PrintedLength)

    /// The real length, or nil for a length read on an NTS sheet.
    public var realLength: Length? {
        if case .real(let length) = self { return length }
        return nil
    }

    public var isNotToScale: Bool {
        if case .notToScale = self { return true }
        return false
    }
}
