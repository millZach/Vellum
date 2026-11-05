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
    /// NTS sheet or in an NTS area the length is the printed length marked NTS, never a real one, even where a scaled
    /// sheet lies on top. Inside a scale area (#11) of the topmost sheet under a point the length reads at the area's
    /// scale: as the printed length it spans on the sheet, turned into a real length by the area's drawing scale. A
    /// lower sheet's scale area does not read under a sheet on top of it (#60).
    public func measure(from start: CanvasPoint, to end: CanvasPoint) -> Measure {
        Self.measure(start.distance(to: end), between: start, and: end, on: sheets)
    }

    /// What a canvas length between two points reads as on these sheets (`measure(from:to:)`): `length` is the
    /// canvas length measured, which for a dimension may be its horizontal or vertical run rather than the distance.
    public static func measure(_ length: Length, between start: CanvasPoint, and end: CanvasPoint, on sheets: [Sheet])
        -> Measure {
        // NTS first, as before #11: a point on an NTS sheet, or in an NTS area, reads printed inches marked NTS.
        for point in [start, end] {
            for sheet in sheets.reversed() where sheet.contains(point) && sheet.scale(at: point) == .notToScale {
                return .notToScale(PrintedLength(inches: length.inches / sheet.canvasPerPrinted))
            }
        }
        // Then a scale area at a scale other than its sheet's, read only on the topmost sheet containing the point
        // (#60): the first point's, else the second's. A lower sheet's area never reads under a sheet on top, which
        // there reads its own scale, a real length. The length spans length / k printed inches on that sheet, which
        // the area's scale makes real.
        for point in [start, end] {
            guard let sheet = sheets.last(where: { $0.contains(point) }),
                  let area = sheet.area(at: point), area.scale != sheet.scale else { continue }
            let printed = PrintedLength(inches: length.inches / sheet.canvasPerPrinted)
            return Sheet.measure(printed: printed, at: area.scale)
        }
        return .real(length)
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
