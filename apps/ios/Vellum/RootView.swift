import SwiftUI
import VellumCore

/// The iOS tab bar with Canvases, Drawings, Jobs and Meetings. Drawings shows Zach's Dropbox (#10); the other tabs are
/// empty until their tickets build them, and the canvas screen is ticket #6.
struct RootView: View {
    @State private var selection: AppTab = RootView.launchTab

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.descriptor.title, systemImage: tab.descriptor.systemImage, value: tab) {
                    if tab == .drawings {
                        DrawingsScreen()
                    } else {
                        PlaceholderScreen(tab: tab)
                    }
                }
            }
        }
    }

    /// The tab the app opens on. Debug builds accept `--ui-tab <name>` so the simulator captures can open each tab.
    private static var launchTab: AppTab {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--ui-tab"), flag + 1 < arguments.count,
           let tab = AppTab(rawValue: arguments[flag + 1]) {
            return tab
        }
        #endif
        return .canvases
    }
}

/// An empty screen that says, in one line, what its tab will hold.
struct PlaceholderScreen: View {
    let tab: AppTab

    var body: some View {
        ContentUnavailableView(tab.descriptor.title, systemImage: tab.descriptor.systemImage,
                               description: Text(tab.descriptor.placeholder))
    }
}

#Preview(traits: .fixedLayout(width: 951, height: 669)) {
    RootView()
}
