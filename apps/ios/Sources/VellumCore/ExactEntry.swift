/// Reading what Zach types on the number pad (#40). It accepts what a drafter writes and nothing it would have to guess.
///
/// On a feet-and-inches canvas a bare number means inches, as in AutoCAD: `12` is 12 inches, `12'` is 12 feet, `12'6` is
/// 12'-6". The inches may carry a fraction, after a space or a hyphen: `6 1/2`, `6-1/2`, `12'6-1/2`, `12'-6 1/2"`, `1/16`.
/// On a canvas in other units a bare number means that canvas's unit: feet in decimal feet, millimetres in metric. The
/// marks `'` and `"` mean feet and inches whatever the units.
///
/// A fraction written with no space before it must be less than one, so `61/2` is refused rather than read as either
/// 30 1/2 or 6 1/2. A length of zero or less, or one past `maximumInches`, is refused too.
public enum ExactEntry {
    /// The longest length that can be typed: about 15,000 miles, far past any plant and well inside the ink grid.
    public static let maximumInches = 1e9
    /// A polygon has from 3 to 24 sides, as the prototype's pad allows.
    public static let sides = 3...24

    /// The angle typed, in degrees, from 0 up to 360; nil when it isn't a number. A minus sign turns the other way.
    public static func angle(_ text: String) -> Double? {
        var scanner = Scanner(text)
        scanner.skipSpaces()
        let negative = scanner.take("-")
        guard let (value, _) = scanner.number() else { return nil }
        scanner.skipSpaces()
        guard scanner.isAtEnd else { return nil }
        return SheetAngle.normalized(negative ? -value : value)
    }

    /// The number of sides typed; nil unless it is a whole number from 3 to 24.
    public static func sides(_ text: String) -> Int? {
        var scanner = Scanner(text)
        scanner.skipSpaces()
        guard let (value, whole) = scanner.number(), whole else { return nil }
        scanner.skipSpaces()
        guard scanner.isAtEnd, value <= Double(sides.upperBound), value >= Double(sides.lowerBound) else { return nil }
        return Int(value)
    }

    /// Walks the characters of what was typed.
    private struct Scanner {
        let characters: [Character]
        var position = 0

        init(_ text: String) { characters = Array(text) }

        var isAtEnd: Bool { position >= characters.count }
        var next: Character? { isAtEnd ? nil : characters[position] }

        mutating func skipSpaces() {
            while next == " " { position += 1 }
        }

        mutating func take(_ character: Character) -> Bool {
            guard next == character else { return false }
            position += 1
            return true
        }

        /// Digits with at most one point, and whether it had no point.
        mutating func number() -> (value: Double, whole: Bool)? {
            let start = position
            var digits = 0, points = 0
            while let c = next, c.isASCII, c.isNumber || c == "." {
                if c == "." { points += 1 } else { digits += 1 }
                position += 1
            }
            guard digits > 0, points <= 1, let value = Double(String(characters[start..<position])) else {
                position = start
                return nil
            }
            return (value, points == 0)
        }

        /// A proper fraction, its numerator already read: `/` and a whole denominator greater than the numerator.
        mutating func fraction(over numerator: Double) -> Double? {
            guard take("/"), let (denominator, whole) = number(), whole, denominator > 0, numerator < denominator else {
                return nil
            }
            return numerator / denominator
        }

        /// An amount: `6`, `6.5`, `1/2`, or a whole number and a fraction after a space or a hyphen: `6 1/2`, `6-1/2`.
        mutating func amount() -> Double? {
            guard let (first, whole) = number() else { return nil }
            if next == "/" { return whole ? fraction(over: first) : nil }
            let afterFirst = position
            skipSpaces()
            let hyphen = take("-")
            skipSpaces()
            if hyphen || position != afterFirst {
                // Something must follow a space only if it is a fraction; trailing spaces are fine.
                if isAtEnd && !hyphen { return first }
                guard whole, let (numerator, wholeTop) = number(), wholeTop, let part = fraction(over: numerator) else {
                    return nil
                }
                return first + part
            }
            return first
        }
    }

    /// The length typed, in inches, read in `units`; nil when it can't be read as a length greater than zero.
    static func inches(_ text: String, units: CanvasUnits) -> Double? {
        var scanner = Scanner(text)
        scanner.skipSpaces()
        let start = scanner.position
        var inches: Double?
        if let (feet, _) = scanner.number(), scanner.take("'") {
            // Feet, then any inches: a space or a hyphen may stand between them, and the inch mark is optional.
            scanner.skipSpaces()
            _ = scanner.take("-")
            scanner.skipSpaces()
            if scanner.isAtEnd {
                inches = feet * 12
            } else if let more = scanner.amount() {
                _ = scanner.take("\"")
                inches = feet * 12 + more
            }
        } else {
            scanner.position = start
            if let amount = scanner.amount() {
                if scanner.take("\"") {
                    inches = amount
                } else {
                    switch units {
                    case .feetAndInches: inches = amount
                    case .decimalFeet: inches = amount * 12
                    case .metric: inches = amount / 25.4
                    }
                }
            }
        }
        scanner.skipSpaces()
        guard scanner.isAtEnd, let inches, inches > 0, inches <= maximumInches else { return nil }
        return inches
    }
}

extension CanvasUnits {
    /// The length typed on the number pad in these units (`ExactEntry`); nil when it can't be read.
    public func parseLength(_ text: String) -> Length? {
        ExactEntry.inches(text, units: self).map(Length.inches)
    }
}
