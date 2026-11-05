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
        // `--ui-speed-check` turns the Speed check on for this launch only (#42), the same way, and
        // `--ui-speed-check-gestures` lists two made-up timed gestures in Settings for its capture.
        if ProcessInfo.processInfo.arguments.contains("--ui-speed-check") {
            UserDefaults.standard.register(defaults: [SpeedCheckSetting.storageKey: true])
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-speed-check-gestures") {
            SpeedCheckRecorder.shared.addMadeUpGestures()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
