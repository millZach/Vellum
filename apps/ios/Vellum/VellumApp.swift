import SwiftUI
import VellumCore

@main
struct VellumApp: App {
    /// Light, Dark or System (ADR-0011), chosen from the canvas screen's top bar.
    @AppStorage(AppearanceSetting.storageKey) private var appearance = AppearanceSetting.default.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme((AppearanceSetting(rawValue: appearance) ?? .default).colorScheme)
        }
    }
}
