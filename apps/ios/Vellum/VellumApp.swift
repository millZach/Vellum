import SwiftUI
import VellumCore

@main
struct VellumApp: App {
    init() {
        #if DEBUG
        // Storage file work on the main thread stops a debug build at once (the simulator captures run one), so a
        // change that puts it there is caught the first time it runs.
        FileWork.trapsOnMainThread = true
        // `--ui-draw-with-finger` turns Draw with finger on for this launch only, for the simulator captures, which
        // have no Pencil: a registered default, never written to the Duo's settings.
        if ProcessInfo.processInfo.arguments.contains("--ui-draw-with-finger") {
            UserDefaults.standard.register(defaults: [FingerDrawingSetting.storageKey: true])
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
