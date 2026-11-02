#if DEBUG
import Foundation
import VellumCore

/// `--ui-appearance-steps <a,b,...>`, Debug builds only, for the simulator captures (#26): sets the appearance to each
/// value in turn, a second apart, as picking it from the top bar's menu does, so a capture taken after the last step
/// proves a change after Light still takes effect (Light then Dark, Light then System). The last step is left set.
@MainActor
enum DebugAppearanceSteps {
    private static var started = false

    static func run() {
        guard !started, let list = DebugLaunch.argument("--ui-appearance-steps") else { return }
        started = true
        let steps = list.split(separator: ",").compactMap { AppearanceSetting(rawValue: String($0)) }
        Task { @MainActor in
            for step in steps {
                UserDefaults.standard.set(step.rawValue, forKey: AppearanceSetting.storageKey)
                print("appearance step: \(step.rawValue)")
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
#endif
