/// Scaling a selection by a factor with its corner resize (#41, Zach's choice on 2026-11-06, kept as the tag
/// `prototype/scale-factor`): the factor shows in the status bar while a corner is dragged, and the drag catches at the
/// round factors ½×, 1×, 2×, 3× and 4×, so a clean 2× is easy. Between them it is free, as before. The anchor stays the
/// opposite corner, and a drag is one undo step, as before.
public enum ResizeCatch {
    /// The factors a drag catches at.
    public static let catches: [Double] = [0.5, 1, 2, 3, 4]
    /// How near a catch a factor is caught: within 4% of it, so 1.92× to 2.08× reads 2×. As a share of the factor
    /// rather than screen points, it catches the same at any zoom and any size of selection, and the catches never
    /// overlap (½× and 1× are 100% apart).
    public static let window = 0.04
    /// The smallest factor a drag gives, so a selection never turns inside out or vanishes.
    public static let smallest = 0.05

    /// The factor a corner dragged from `corner` to `point` gives about `anchor`, the opposite corner: how far along the
    /// diagonal the point has come, as today's resize works it out; never under `smallest`.
    public static func factor(anchor: CanvasPoint, corner: CanvasPoint, point: CanvasPoint) -> Double {
        let (vx, vy) = (corner.x.inches - anchor.x.inches, corner.y.inches - anchor.y.inches)
        let (px, py) = (point.x.inches - anchor.x.inches, point.y.inches - anchor.y.inches)
        let lengthSquared = vx * vx + vy * vy
        let raw = lengthSquared > 0 ? (px * vx + py * vy) / lengthSquared : 1
        return max(raw, smallest)
    }

    /// The factor after the catch: the round factor it is within `window` of, else itself.
    public static func caught(_ factor: Double) -> (factor: Double, isCaught: Bool) {
        for round in catches where abs(factor / round - 1) <= window { return (round, true) }
        return (factor, false)
    }

    /// What the status bar says while the corner is dragged, 28 characters or fewer: `Scale 2×`, `Scale 1.5×`,
    /// `Scale 0.37×`, to the hundredth.
    public static func label(_ factor: Double) -> String {
        let hundredths = Int((factor * 100).rounded())
        var text = "\(hundredths / 100)"
        let rest = hundredths % 100
        if rest != 0 { text += rest % 10 == 0 ? ".\(rest / 10)" : (rest < 10 ? ".0\(rest)" : ".\(rest)") }
        return "Scale \(text)×"
    }
}
