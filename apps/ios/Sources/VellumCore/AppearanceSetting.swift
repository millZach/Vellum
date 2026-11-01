/// Whether Vellum follows the Duo's light or dark setting or is pinned to one (ADR-0011).
public enum AppearanceSetting: String, CaseIterable, Identifiable, Hashable, Sendable {
    case system
    case light
    case dark

    public static let `default` = AppearanceSetting.system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Whether the canvas is dark, given whether the Duo is.
    public func isDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .system: systemIsDark
        case .light: false
        case .dark: true
        }
    }
}
