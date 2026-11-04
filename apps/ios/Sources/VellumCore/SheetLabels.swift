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

        public init(rect: LabelRect, name: LabelSize, scale: LabelSize) {
            self.rect = rect
            self.name = name
            self.scale = scale
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

    private static func place(_ area: Area, avoiding taken: [LabelRect]) -> Placed {
        let twoLines = LabelSize(width: max(area.name.width, area.scale.width) + areaHorizontalPadding * 2,
                                 height: area.name.height + area.scale.height + areaVerticalPadding * 2)
        let scaleAlone = LabelSize(width: area.scale.width + areaHorizontalPadding * 2,
                                   height: area.scale.height + areaVerticalPadding * 2)
        for (fit, size) in [(ScaleAreaLabelFit.twoLines, twoLines), (.scaleAlone, scaleAlone)] {
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
