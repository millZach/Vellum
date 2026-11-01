import SwiftUI
import VellumCore

/// The iOS tab bar with Canvases, Drawings, Jobs and Meetings. Canvases holds the canvas screen; Drawings shows Zach's
/// Dropbox (#10); the other tabs are empty until their tickets build them.
struct RootView: View {
    @State private var selection: AppTab = RootView.launchTab
    /// The open canvas lives here, above the tabs, so switching tabs keeps its ink for the session.
    @State private var editor = RootView.launchEditor()

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.descriptor.title, systemImage: tab.descriptor.systemImage, value: tab) {
                    if tab == .canvases {
                        CanvasScreen(editor: editor)
                    } else if tab == .drawings {
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
        if let name = launchArgument("--ui-tab"), let tab = AppTab(rawValue: name) { return tab }
        #endif
        return .canvases
    }

    /// A new, empty canvas. Debug builds accept `--ui-fixture` to open the made-up fixture canvas instead, and
    /// `--ui-zoom closeup` to open it close up on its valve rather than on everything; `--ui-fixture-large` opens the
    /// made-up 10,000-stroke canvas for measuring the renderer.
    private static func launchEditor() -> CanvasEditor {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture-large") {
            return CanvasEditor(canvas: DebugFixture.largeCanvas, startingView: .everything)
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
            let closeUp = launchArgument("--ui-zoom") == "closeup"
            return CanvasEditor(canvas: DebugFixture.canvas,
                                startingView: closeUp ? .region(DebugFixture.valveRegion) : .everything)
        }
        #endif
        return CanvasEditor()
    }

    #if DEBUG
    private static func launchArgument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    #endif
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
