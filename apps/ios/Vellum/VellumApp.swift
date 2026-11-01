import SwiftUI
import VellumCore

@main
struct VellumApp: App {
    /// Light, Dark or System (ADR-0011), chosen from the canvas screen's top bar.
    @AppStorage(AppearanceSetting.storageKey) private var appearance = AppearanceSetting.default.rawValue

    init() {
        #if DEBUG
        // Storage file work on the main thread stops a debug build at once (the simulator captures run one), so a
        // change that puts it there is caught the first time it runs.
        FileWork.trapsOnMainThread = true
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme((AppearanceSetting(rawValue: appearance) ?? .default).colorScheme)
        }
    }
}
