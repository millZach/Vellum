/// The units a canvas shows lengths in, chosen per canvas (ADR-0002). A new canvas starts in feet and inches.
///
/// - Feet and inches round to the nearest 1/16", the usual drafting precision, and reduce the fraction:
///   `12'-6 1/2"`, `0'-3"`, `12'-0"`. A length that rounds up to the next inch or foot carries: 11'-11 31/32" reads
///   `12'-0"`.
/// - Decimal feet round to the hundredth of a foot: `12.54'`.
/// - Metric rounds to the millimetre, shown in millimetres under a metre (`350 mm`) and in metres from a metre up
///   (`12.540 m`).
///
/// Negative lengths carry a leading minus sign; a length that rounds to zero never does.
public enum CanvasUnits: String, CaseIterable, Hashable, Sendable {
    case feetAndInches
    case decimalFeet
    case metric

    /// What a new canvas uses.
    public static let `default` = CanvasUnits.feetAndInches

    /// The denominator feet-and-inches lengths round to: sixteenths of an inch.
    public static let fractionalPrecision = 16

    /// A real length in these units.
    public func format(_ length: Length) -> String {
        switch self {
        case .feetAndInches:
            let sixteenths = Int((length.inches.magnitude * Double(Self.fractionalPrecision)).rounded())
            let perFoot = 12 * Self.fractionalPrecision
            let feet = sixteenths / perFoot
            let inches = Fraction.mixed(sixteenths % perFoot, over: Self.fractionalPrecision)
            return Self.sign(length.inches, nonZero: sixteenths != 0) + "\(feet)'-\(inches)\""
        case .decimalFeet:
            let hundredths = Int((length.feet.magnitude * 100).rounded())
            return Self.sign(length.inches, nonZero: hundredths != 0) + Self.decimal(hundredths, places: 2) + "'"
        case .metric:
            let millimetres = Int(length.millimetres.magnitude.rounded())
            let sign = Self.sign(length.inches, nonZero: millimetres != 0)
            return millimetres < 1000
                ? sign + "\(millimetres) mm"
                : sign + Self.decimal(millimetres, places: 3) + " m"
        }
    }

    /// A printed length read on an NTS sheet: printed inches to the 1/16", marked NTS so it is never read as a real
    /// one (`3 1/2" NTS`). It reads the same in every canvas units, metric too, because it is a length on the paper,
    /// not on the canvas.
    public func format(_ printed: PrintedLength) -> String {
        let sixteenths = Int((printed.inches.magnitude * Double(Self.fractionalPrecision)).rounded())
        return Self.sign(printed.inches, nonZero: sixteenths != 0)
            + Fraction.mixed(sixteenths, over: Self.fractionalPrecision, writeZero: false) + "\" NTS"
    }

    /// A measure in these units: a real length as a length, an NTS one as a printed length marked NTS.
    public func format(_ measure: Measure) -> String {
        switch measure {
        case .real(let length): format(length)
        case .notToScale(let printed): format(printed)
        }
    }

    private static func sign(_ value: Double, nonZero: Bool) -> String { value < 0 && nonZero ? "-" : "" }

    /// `count` in units of 10^-places, written with its decimal point: `decimal(1254, places: 2)` is `12.54`.
    private static func decimal(_ count: Int, places: Int) -> String {
        var divisor = 1
        for _ in 0..<places { divisor *= 10 }
        let fraction = String(count % divisor)
        return "\(count / divisor)." + String(repeating: "0", count: places - fraction.count) + fraction
    }
}

/// Whole-and-fraction inch text, shared by canvas units and drawing scale names.
enum Fraction {
    /// `count / denominator` as a reduced mixed number: `mixed(104, over: 16)` is `6 1/2` and zero is `0`. A fraction
    /// with no whole part is `0 1/2`, the way a feet-and-inches length writes it, unless `writeZero` is off (`1/2`).
    static func mixed(_ count: Int, over denominator: Int, writeZero: Bool = true) -> String {
        let whole = count / denominator
        var numerator = count % denominator
        var reduced = denominator
        while numerator != 0 && numerator % 2 == 0 && reduced % 2 == 0 {
            numerator /= 2
            reduced /= 2
        }
        if numerator == 0 { return "\(whole)" }
        if whole == 0 && !writeZero { return "\(numerator)/\(reduced)" }
        return "\(whole) \(numerator)/\(reduced)"
    }
}
