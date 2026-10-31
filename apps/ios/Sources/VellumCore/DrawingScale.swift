/// The ratio between a sheet's printed size and the real world, such as 1/4" = 1'-0" (ADR-0002). It is the only way
/// a `PrintedLength` becomes a real `Length`.
public struct DrawingScale: Hashable, Sendable, CustomStringConvertible {
    /// How the scale is written: as two lengths (`1/4" = 1'-0"`, `1" = 20'`) or as a ratio (`1:50`).
    public enum Notation: Hashable, Sendable {
        case lengths
        case ratio
    }

    /// The printed side of the scale: the 1/4" of 1/4" = 1'-0". For a ratio, its first number in inches.
    public let printed: PrintedLength
    /// The real side of the scale: the 1'-0" of 1/4" = 1'-0". For a ratio, its second number in inches.
    public let real: Length
    public let notation: Notation

    /// A scale from its two sides, or nil unless both are positive and finite.
    public init?(printed: PrintedLength, real: Length, notation: Notation = .lengths) {
        guard printed.inches > 0, real.inches > 0, printed.inches.isFinite, real.inches.isFinite else { return nil }
        self.printed = printed
        self.real = real
        self.notation = notation
    }

    /// An architectural scale: `architectural(inchesPerFoot: 0.25)` is 1/4" = 1'-0".
    public static func architectural(inchesPerFoot: Double) -> DrawingScale {
        DrawingScale(printed: .inches(inchesPerFoot), real: .feet(1))!
    }

    /// An engineering scale: `engineering(feetPerInch: 20)` is 1" = 20'.
    public static func engineering(feetPerInch: Double) -> DrawingScale {
        DrawingScale(printed: .inches(1), real: .feet(feetPerInch))!
    }

    /// A ratio scale: `ratio(50)` is 1:50.
    public static func ratio(_ realPerPrinted: Double) -> DrawingScale {
        DrawingScale(printed: .inches(1), real: .inches(realPerPrinted), notation: .ratio)!
    }

    /// Full size, 1:1: a printed inch is a real inch.
    public static let fullSize = ratio(1)

    /// The architectural scales Vellum offers when a sheet's scale can't be read, smallest first.
    public static let architecturalScales: [DrawingScale] = {
        let inchesPerFoot: [Double] = [0.0625, 0.09375, 0.125, 0.1875, 0.25, 0.375, 0.5, 0.75, 1, 1.5, 3]
        return inchesPerFoot.map { architectural(inchesPerFoot: $0) }
    }()

    /// The engineering scales Vellum offers, smallest first.
    public static let engineeringScales: [DrawingScale] = {
        let feetPerInch: [Double] = [100, 60, 50, 40, 30, 20, 10]
        return feetPerInch.map { engineering(feetPerInch: $0) }
    }()

    /// The ratio scales Vellum offers, smallest first.
    public static let ratioScales: [DrawingScale] = [ratio(100), ratio(50), fullSize]

    /// Real inches per printed inch: 48 for 1/4" = 1'-0", 240 for 1" = 20', 50 for 1:50.
    public var realPerPrinted: Double { real.inches / printed.inches }

    /// The real length a printed length stands for.
    public func realLength(of printed: PrintedLength) -> Length { Length(inches: printed.inches * realPerPrinted) }

    /// The printed length a real length takes up on paper at this scale.
    public func printedLength(of real: Length) -> PrintedLength {
        PrintedLength(inches: real.inches / realPerPrinted)
    }

    /// The scale as a title block writes it: `1/4" = 1'-0"`, `1" = 20'`, `1:50`.
    public var description: String {
        switch notation {
        case .ratio:
            return "\(Self.formatNumber(printed.inches)):\(Self.formatNumber(real.inches))"
        case .lengths:
            // Both sides are written exactly, never with a measure's 1/16" rounding, so a label reads back as the
            // same conversion.
            let paper = Self.inchText(printed.inches) + "\""
            let feet = (real.inches / 12).rounded(.down)
            let inches = real.inches - feet * 12
            if printed.inches == 1 && inches == 0 && feet != 1 { return paper + " = \(Self.formatNumber(feet))'" }
            return paper + " = \(Self.formatNumber(feet))'-" + Self.inchText(inches) + "\""
        }
    }

    /// Inches exactly: as a fraction when a 64th fits (`3/32`, `1 1/2`, `0`), otherwise as a decimal.
    private static func inchText(_ inches: Double) -> String {
        let sixtyFourths = inches * 64
        guard sixtyFourths == sixtyFourths.rounded() else { return formatNumber(inches) }
        return Fraction.mixed(Int(sixtyFourths), over: 64, writeZero: false)
    }

    private static func formatNumber(_ value: Double) -> String {
        value == value.rounded() && value.magnitude < 1e15 ? String(Int(value)) : String(value)
    }
}

/// What reading a sheet's scale text found: a drawing scale, a sheet that says it is not to scale, or nothing Vellum
/// can trust (`AS NOTED`, several scales, junk), in which case Zach types one (ADR-0002).
public enum ScaleReading: Hashable, Sendable {
    case scale(DrawingScale)
    case notToScale
    case cantTell
}

extension DrawingScale {
    /// Reads scale text as a title block writes it: `SCALE: 1/4" = 1'-0"`, `1/4"=1'-0"`, `1" = 20'`, `1:50`,
    /// `FULL SIZE`, `NTS`, `N.T.S.`, `NOT TO SCALE`. `AS NOTED`, `AS SHOWN` and anything else it can't read whole
    /// come back as `.cantTell`; it never guesses from part of the text.
    ///
    /// Typographic quotes and primes (″ ′ “ ” ‘ ’) and doubled apostrophes (`''`) read as inch and foot marks, as
    /// PDF text extraction often gives them.
    public static func read(_ text: String) -> ScaleReading {
        var s = Substring(normalized(text))
        if s.hasPrefix("SCALE") {
            s = s.dropFirst(5).drop { $0 == " " }
            if s.first == ":" || s.first == "=" { s = s.dropFirst().drop { $0 == " " } }
        }
        let body = String(s)
        if body.isEmpty { return .cantTell }

        if !body.contains(where: \.isNumber) {
            switch body.filter(\.isLetter) {
            case "NTS", "NOTTOSCALE", "NOSCALE": return .notToScale
            case "FULLSIZE", "FULLSCALE": return .scale(.fullSize)
            default: return .cantTell
            }
        }

        let ratioSides = body.split(separator: ":", omittingEmptySubsequences: false)
        if ratioSides.count == 2 {
            guard let printed = parseNumber(ratioSides[0]), let real = parseNumber(ratioSides[1]),
                  let scale = DrawingScale(printed: .inches(printed), real: .inches(real), notation: .ratio)
            else { return .cantTell }
            return .scale(scale)
        }

        let lengthSides = body.split(separator: "=", omittingEmptySubsequences: false)
        if lengthSides.count == 2 && ratioSides.count == 1 {
            guard let printed = inchesOfLength(lengthSides[0]), let real = inchesOfLength(lengthSides[1]),
                  let scale = DrawingScale(printed: .inches(printed), real: .inches(real))
            else { return .cantTell }
            return .scale(scale)
        }
        return .cantTell
    }

    private static func normalized(_ text: String) -> String {
        var out = ""
        for character in text.uppercased() {
            switch character {
            case "″", "“", "”": out.append("\"")
            case "′", "‘", "’", "`": out.append("'")
            case "–", "—", "‐": out.append("-")
            case "\t", "\n", "\r", "\u{00A0}": out.append(" ")
            default: out.append(character)
            }
        }
        out = out.replacingAll("''", with: "\"")
        return out.trimmingSpaces()
    }

    /// A length written with foot and inch marks, in inches: `1'-0"`, `1' 6"`, `20'`, `1/4"`, `1 1/2"`, `1-1/2"`.
    private static func inchesOfLength(_ text: Substring) -> Double? {
        let t = String(text).trimmingSpaces()
        if let footMark = t.firstIndex(of: "'") {
            guard let feet = parseNumber(t[..<footMark]) else { return nil }
            var rest = t[t.index(after: footMark)...].drop { $0 == " " }
            let hyphenated = rest.first == "-"
            if hyphenated { rest = rest.dropFirst().drop { $0 == " " } }
            if rest.isEmpty { return hyphenated ? nil : feet * 12 }   // `1'-` is cut off, not a length
            guard rest.last == "\"", let inches = mixedNumber(rest.dropLast()) else { return nil }
            return feet * 12 + inches
        }
        guard t.last == "\"" else { return nil }
        return mixedNumber(t.dropLast())
    }

    /// `1`, `0.25`, `1/4`, `1 1/2` or `1-1/2`. A hyphen only joins a whole number to its fraction: `-1/4`, `1/4-`
    /// and `1--1/2` are not numbers, since quietly repairing them would hand Zach a scale nobody wrote.
    private static func mixedNumber(_ text: Substring) -> Double? {
        let t = Substring(String(text).trimmingSpaces())
        let parts: [Substring]
        if t.contains("-") {
            parts = t.split(separator: "-", omittingEmptySubsequences: false)
        } else {
            parts = t.split(separator: " ")
        }
        switch parts.count {
        case 1:
            return fraction(parts[0]) ?? parseNumber(parts[0])
        case 2:
            guard !parts[0].contains("/"), let whole = parseNumber(parts[0]), let part = fraction(parts[1])
            else { return nil }
            return whole + part
        default:
            return nil
        }
    }

    private static func fraction(_ text: Substring) -> Double? {
        let sides = text.split(separator: "/", omittingEmptySubsequences: false)
        guard sides.count == 2, let top = parseNumber(sides[0]), let bottom = parseNumber(sides[1]), bottom > 0 else { return nil }
        return top / bottom
    }

    /// A plain decimal number, digits and at most one point. `Double(_:)` alone would also take `nan` and `1e5`.
    private static func parseNumber(_ text: Substring) -> Double? {
        let t = String(text).trimmingSpaces()
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              t.filter({ $0 == "." }).count <= 1, t != "." else { return nil }
        return Double(t)
    }
}

extension String {
    /// Stays off Foundation, so Linux and Apple Swift read scale text the same way.
    fileprivate func trimmingSpaces() -> String {
        String(drop { $0 == " " }.reversed().drop { $0 == " " }.reversed())
    }

    fileprivate func replacingAll(_ target: String, with replacement: String) -> String {
        var out = ""
        var rest = Substring(self)
        while let range = rest.firstRange(of: target) {
            out += rest[..<range.lowerBound] + replacement
            rest = rest[range.upperBound...]
        }
        return out + rest
    }
}
