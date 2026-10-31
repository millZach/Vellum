/// A real-world length on the canvas, such as the 96 feet a 24-inch sheet edge covers at 1/4" = 1'-0" (ADR-0002).
///
/// Lengths are kept in inches as a `Double`. Inches make every architectural and engineering scale an exact binary
/// multiple (1/4" = 1'-0" is ×48, 1/8" is ×96), and a `Double` keeps 1/16" exact out past a hundred miles, far beyond
/// any plant on one canvas. Metric lengths convert at exactly 25.4 mm to the inch.
///
/// A length read on paper is a `PrintedLength`, a different type: the only way from one to the other is through a
/// `DrawingScale`, so a printed length cannot be mistaken for a real one.
public struct Length: Hashable, Comparable, Sendable {
    /// The length in inches. Negative when it runs backwards along an axis.
    public var inches: Double

    public init(inches: Double) { self.inches = inches }

    public static let zero = Length(inches: 0)

    public static func inches(_ inches: Double) -> Length { Length(inches: inches) }
    public static func feet(_ feet: Double) -> Length { Length(inches: feet * 12) }
    /// A length written the drafting way, such as `feet(12, inches: 6.5)` for 12'-6 1/2".
    public static func feet(_ feet: Double, inches: Double) -> Length { Length(inches: feet * 12 + inches) }
    public static func millimetres(_ millimetres: Double) -> Length { Length(inches: millimetres / 25.4) }
    public static func metres(_ metres: Double) -> Length { Length(inches: metres * 1000 / 25.4) }

    public var feet: Double { inches / 12 }
    public var millimetres: Double { inches * 25.4 }
    public var metres: Double { millimetres / 1000 }
    /// The length without its direction.
    public var magnitude: Length { Length(inches: inches.magnitude) }

    public static func < (lhs: Length, rhs: Length) -> Bool { lhs.inches < rhs.inches }
    public static func + (lhs: Length, rhs: Length) -> Length { Length(inches: lhs.inches + rhs.inches) }
    public static func - (lhs: Length, rhs: Length) -> Length { Length(inches: lhs.inches - rhs.inches) }
    public static prefix func - (length: Length) -> Length { Length(inches: -length.inches) }
    public static func * (lhs: Length, rhs: Double) -> Length { Length(inches: lhs.inches * rhs) }
    public static func / (lhs: Length, rhs: Double) -> Length { Length(inches: lhs.inches / rhs) }
}

/// A length as it is printed on paper, such as the 3 1/2" between two marks on a sheet. It becomes a real `Length`
/// only through a `DrawingScale`; on an NTS sheet it stays printed and is shown marked NTS.
public struct PrintedLength: Hashable, Comparable, Sendable {
    /// The printed length in inches.
    public var inches: Double

    public init(inches: Double) { self.inches = inches }

    public static let zero = PrintedLength(inches: 0)

    public static func inches(_ inches: Double) -> PrintedLength { PrintedLength(inches: inches) }
    public static func millimetres(_ millimetres: Double) -> PrintedLength { PrintedLength(inches: millimetres / 25.4) }

    public var millimetres: Double { inches * 25.4 }

    public static func < (lhs: PrintedLength, rhs: PrintedLength) -> Bool { lhs.inches < rhs.inches }
    public static func + (lhs: PrintedLength, rhs: PrintedLength) -> PrintedLength {
        PrintedLength(inches: lhs.inches + rhs.inches)
    }
    public static func - (lhs: PrintedLength, rhs: PrintedLength) -> PrintedLength {
        PrintedLength(inches: lhs.inches - rhs.inches)
    }
}

/// A position on the canvas in real-world lengths. `x` runs right and `y` runs down, as on the Duo's screen and on a
/// PDF page as it is drawn, so a sheet's or frame's origin is its top-left corner.
public struct CanvasPoint: Hashable, Sendable {
    public var x: Length
    public var y: Length

    public init(x: Length, y: Length) {
        self.x = x
        self.y = y
    }

    public static let origin = CanvasPoint(x: .zero, y: .zero)

    public func offsetBy(dx: Length, dy: Length) -> CanvasPoint { CanvasPoint(x: x + dx, y: y + dy) }

    /// The straight-line distance to another point.
    public func distance(to other: CanvasPoint) -> Length {
        let dx = other.x.inches - x.inches
        let dy = other.y.inches - y.inches
        return Length(inches: (dx * dx + dy * dy).squareRoot())
    }
}

/// A width and height on the canvas in real-world lengths.
public struct CanvasSize: Hashable, Sendable {
    public var width: Length
    public var height: Length

    public init(width: Length, height: Length) {
        self.width = width
        self.height = height
    }
}

/// A rectangle on the canvas: its top-left corner and its size.
public struct CanvasRect: Hashable, Sendable {
    public var origin: CanvasPoint
    public var size: CanvasSize

    public init(origin: CanvasPoint, size: CanvasSize) {
        self.origin = origin
        self.size = size
    }

    public var minX: Length { origin.x }
    public var minY: Length { origin.y }
    public var maxX: Length { origin.x + size.width }
    public var maxY: Length { origin.y + size.height }

    /// Whether the point lies inside the rectangle or on its edge.
    public func contains(_ point: CanvasPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}

/// A position on a sheet's or frame's paper, in printed lengths from its top-left corner.
public struct PaperPoint: Hashable, Sendable {
    public var x: PrintedLength
    public var y: PrintedLength

    public init(x: PrintedLength, y: PrintedLength) {
        self.x = x
        self.y = y
    }
}
