import Foundation

/// A size or a rectangle in screen points, for laying out a sheet's labels. The app measures the text; the rule is here
/// so it can be tested without a font.
public struct LabelSize: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct LabelRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(_ other: LabelRect) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }

    public func intersects(_ other: LabelRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }
}

/// A sheet's or scale area's four corners on screen, its paper's top left first and going round as printed (#44). A sheet
/// at 0° is a plain rectangle; turned, labels stay level and have to fit inside it at an angle.
public struct LabelQuad: Hashable, Sendable {
    public var corners: [LabelPoint]

    public init(corners: [LabelPoint]) { self.corners = corners }

    public init(_ rect: LabelRect) {
        corners = [LabelPoint(x: rect.x, y: rect.y), LabelPoint(x: rect.maxX, y: rect.y),
                   LabelPoint(x: rect.maxX, y: rect.maxY), LabelPoint(x: rect.x, y: rect.maxY)]
    }

    /// The rectangle this is, when it stands as printed: top left first, edges square to the screen.
    public var upright: LabelRect? {
        let (a, b, c, d) = (corners[0], corners[1], corners[2], corners[3])
        guard a.y == b.y, c.y == d.y, a.x == d.x, b.x == c.x, b.x >= a.x, d.y >= a.y else { return nil }
        return LabelRect(x: a.x, y: a.y, width: b.x - a.x, height: d.y - a.y)
    }

    var centre: LabelPoint {
        LabelPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
    }

    /// Whether a rectangle lies wholly inside.
    public func contains(_ box: LabelRect) -> Bool {
        var area = 0.0
        for i in 0..<4 {
            let (u, v) = (corners[i], corners[(i + 1) % 4])
            area += u.x * v.y - v.x * u.y
        }
        for (x, y) in [(box.x, box.y), (box.maxX, box.y), (box.maxX, box.maxY), (box.x, box.maxY)] {
            for i in 0..<4 {
                let (u, v) = (corners[i], corners[(i + 1) % 4])
                let side = (v.x - u.x) * (y - u.y) - (v.y - u.y) * (x - u.x)
                if area >= 0 ? side < 0 : side > 0 { return false }
            }
        }
        return true
    }
}

public struct LabelPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// What a scale area shows (#35, Zach's B): its name over its scale, or its scale alone, or only its outline. A label is
/// always its whole text at full size, so part of a scale never shows.
public enum ScaleAreaLabelFit: Hashable, Sendable {
    case twoLines
    case scaleAlone
    case outlineOnly
}

/// Where a sheet's labels go in one view of it (#35). The sheet's name takes the sheet's top-left corner, or hides when
/// the sheet can't hold it. Each scale area's label sits inside the area's top-left corner, dropping below the sheet's
/// name or an earlier area's label if one is there, and falls back to its scale alone and then its outline when it no
/// longer fits inside the area. Every size scales alike under the kept layer's transform during a pinch, so what fits
/// when drawn still fits on screen until it is drawn again.
///
/// On a turned sheet (#44) every label stays level. Each starts in the paper's corner, wherever that has turned to, and
/// slides towards the middle of its sheet or area until it fits wholly inside and clear of the labels placed before it.
/// The fallbacks are the same: name over scale, then scale alone, then outline only. Never cut, never over another.
public struct SheetLabelLayout: Hashable, Sendable {
    /// The sheet's name stands this far inside the sheet's corner, as in the prototype.
    public static let sheetNameInset = 6.0
    /// A scale area's backing round its text.
    public static let areaHorizontalPadding = 4.0
    public static let areaVerticalPadding = 2.0

    /// One scale area: where it is on screen, and its measured text.
    public struct Area: Hashable, Sendable {
        public var rect: LabelRect
        public var name: LabelSize
        public var scale: LabelSize
        /// Its corners on screen.
        public var quad: LabelQuad

        public init(rect: LabelRect, name: LabelSize, scale: LabelSize) {
            self.rect = rect
            self.name = name
            self.scale = scale
            quad = LabelQuad(rect)
        }

        /// Its label with its backing, name over scale.
        public var twoLinesSize: LabelSize {
            LabelSize(width: max(name.width, scale.width) + areaHorizontalPadding * 2,
                      height: name.height + scale.height + areaVerticalPadding * 2)
        }

        /// Its label with its backing, the scale alone.
        public var scaleAloneSize: LabelSize {
            LabelSize(width: scale.width + areaHorizontalPadding * 2, height: scale.height + areaVerticalPadding * 2)
        }

        public init(quad: LabelQuad, name: LabelSize, scale: LabelSize) {
            rect = quad.upright ?? LabelRect(x: 0, y: 0, width: 0, height: 0)
            self.name = name
            self.scale = scale
            self.quad = quad
        }
    }

    /// What one area shows and where; `box` is nil for an outline.
    public struct Placed: Hashable, Sendable {
        public var fit: ScaleAreaLabelFit
        public var box: LabelRect?
    }

    /// Where the sheet's name goes; nil when it is hidden.
    public var sheetName: LabelRect?
    /// One entry per area, in order.
    public var areas: [Placed]

    /// The decision alone, for an area with nothing else in its corner.
    public static func fit(area: LabelSize, name: LabelSize, scale: LabelSize) -> ScaleAreaLabelFit {
        let rect = LabelRect(x: 0, y: 0, width: area.width, height: area.height)
        return place(Area(rect: rect, name: name, scale: scale), avoiding: []).fit
    }

    /// Lays out a sheet at `sheet` on screen; `sheetName` is the name's measured size with its backing, nil for none.
    public static func lay(sheet: LabelRect, sheetName: LabelSize?, areas: [Area]) -> SheetLabelLayout {
        var taken: [LabelRect] = []
        var nameBox: LabelRect?
        if let sheetName {
            let box = LabelRect(x: sheet.x + sheetNameInset, y: sheet.y + sheetNameInset,
                                width: sheetName.width, height: sheetName.height)
            let room = LabelRect(x: sheet.x, y: sheet.y, width: sheet.width - sheetNameInset, height: sheet.height - sheetNameInset)
            if room.contains(box) {
                nameBox = box
                taken.append(box)
            }
        }
        var placed: [Placed] = []
        for area in areas {
            let result = place(area, avoiding: taken)
            if let box = result.box { taken.append(box) }
            placed.append(result)
        }
        return SheetLabelLayout(sheetName: nameBox, areas: placed)
    }

    /// Lays out a sheet standing at any angle: the same labels and fallbacks as `lay(sheet:sheetName:areas:)`, which it
    /// is when the sheet stands as printed.
    public static func lay(sheet: LabelQuad, sheetName: LabelSize?, areas: [Area]) -> SheetLabelLayout {
        if let upright = sheet.upright { return lay(sheet: upright, sheetName: sheetName, areas: areas) }
        var taken: [LabelRect] = []
        var nameBox: LabelRect?
        if let sheetName, let box = spot(in: sheet, size: sheetName, avoiding: taken) {
            nameBox = box
            taken.append(box)
        }
        var placed: [Placed] = []
        for area in areas {
            let result = place(area, avoiding: taken)
            if let box = result.box { taken.append(box) }
            placed.append(result)
        }
        return SheetLabelLayout(sheetName: nameBox, areas: placed)
    }

    /// Steps along the way from a quad's first corner to its middle a level box may stop at, as the prototype's.
    private static let spotSteps = 24

    /// The first spot a level box fits inside a quad and clear of what is taken, sliding from its first corner to its
    /// middle; nil when there is none.
    private static func spot(in quad: LabelQuad, size: LabelSize, avoiding taken: [LabelRect]) -> LabelRect? {
        let corner = quad.corners[0], centre = quad.centre
        let startX = corner.x + (centre.x >= corner.x ? 1 : -1) * (size.width / 2 + 0.5)
        let startY = corner.y + (centre.y >= corner.y ? 1 : -1) * (size.height / 2 + 0.5)
        for step in 0...spotSteps {
            let t = Double(step) * 0.04
            let box = LabelRect(x: startX + (centre.x - startX) * t - size.width / 2,
                                y: startY + (centre.y - startY) * t - size.height / 2,
                                width: size.width, height: size.height)
            if quad.contains(box), !taken.contains(where: { $0.intersects(box) }) { return box }
        }
        return nil
    }

    private static func place(_ area: Area, avoiding taken: [LabelRect]) -> Placed {
        let twoLines = area.twoLinesSize, scaleAlone = area.scaleAloneSize
        for (fit, size) in [(ScaleAreaLabelFit.twoLines, twoLines), (.scaleAlone, scaleAlone)] {
            guard area.quad.upright != nil else {
                if let box = spot(in: area.quad, size: size, avoiding: taken) { return Placed(fit: fit, box: box) }
                continue
            }
            var box = LabelRect(x: area.rect.x, y: area.rect.y, width: size.width, height: size.height)
            // Each step moves below something it hit, so this ends after at most one step per label.
            while let hit = taken.first(where: { $0.intersects(box) }) { box.y = hit.maxY }
            if area.rect.contains(box) { return Placed(fit: fit, box: box) }
        }
        return Placed(fit: .outlineOnly, box: nil)
    }
}

/// A colour pair of a control's text on its fill, as `0xRRGGBB`.
public struct ChromeColourPair: Hashable, Sendable {
    public var text: UInt32
    public var fill: UInt32

    public init(text: UInt32, fill: UInt32) {
        self.text = text
        self.fill = fill
    }

    /// The WCAG contrast ratio of the text on the fill.
    public var contrast: Double {
        let (a, b) = (Self.luminance(text), Self.luminance(fill))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// A disabled button (#35, Zach's C): faded blue, at 4.5:1 or better. It looks like the enabled Cancel and Change
    /// scale beside it, which was stated and accepted.
    public static func disabledButton(dark: Bool) -> ChromeColourPair {
        dark ? ChromeColourPair(text: 0x9CC4EC, fill: 0x2C3A4A) : ChromeColourPair(text: 0x47688A, fill: 0xE6EDF5)
    }

    /// The window menu's disabled "Send… (later)" on the menu's own pill, which is near black in light and dark grey in
    /// dark (#33, Zach's C): the prototype's lighter blues, since `disabledButton`'s light text reaches only 2.9:1 there.
    /// The menu takes its pill's colour from `fill`.
    public static func windowMenuDisabled(dark: Bool) -> ChromeColourPair {
        dark ? ChromeColourPair(text: 0xB8D6F2, fill: 0x3A3B40) : ChromeColourPair(text: 0x9CC4EC, fill: 0x1D1D1F)
    }

    private static func luminance(_ colour: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((colour >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
