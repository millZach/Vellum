import SwiftUI
import UIKit
import VellumCore

/// The iOS tab bar with Canvases, Drawings, Jobs and Meetings. Canvases holds the list of canvases and, over it, the
/// canvas screen for the one open; Drawings shows Zach's Dropbox (#10); the other tabs are empty until their tickets
/// build them.
struct RootView: View {
    @State private var selection: AppTab = RootView.launchTab
    /// The canvases and the open canvas live here, above the tabs, so switching tabs keeps the canvas open.
    @State private var canvases = CanvasesModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.descriptor.title, systemImage: tab.descriptor.systemImage, value: tab) {
                    if tab == .canvases {
                        CanvasesTab(model: canvases)
                    } else if tab == .drawings {
                        DrawingsScreen()
                    } else {
                        PlaceholderScreen(tab: tab)
                    }
                }
            }
        }
        .task {
            #if DEBUG || BENCHMARK
            // The 10,000-stroke test canvas for the captures and the benchmark (`--ui-fixture-large`): opened in place
            // of a saved canvas, so it never touches Zach's.
            if ProcessInfo.processInfo.arguments.contains("--ui-fixture-large") {
                await canvases.openTestCanvas()
                canvases.finishLaunch()
                return
            }
            #endif
            #if DEBUG
            if await DebugLaunch.run(canvases) { return }
            #endif
            await canvases.launch()
        }
        .onChange(of: scenePhase) { _, phase in
            // Every change is already written; leaving the screen flushes it to storage so a power cut keeps it too.
            if phase != .active { canvases.appWillLeaveScreen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            canvases.appWillTerminate()
        }
    }

    /// The tab the app opens on. Debug builds accept `--ui-tab <name>` so the simulator captures can open each tab.
    private static var launchTab: AppTab {
        #if DEBUG
        if let name = DebugLaunch.argument("--ui-tab"), let tab = AppTab(rawValue: name) { return tab }
        #endif
        return .canvases
    }
}

/// The canvas screen for the open canvas, or the list when none is open. The made-up test canvas, while it is open,
/// shows in place of the open canvas (`TestCanvas`).
struct CanvasesTab: View {
    let model: CanvasesModel

    var body: some View {
        if let editor = model.testEditor ?? model.openEditor {
            CanvasScreen(editor: editor, showCanvases: { model.closeCanvas() })
                .id(ObjectIdentifier(editor))
                .environment(\.testCanvas, TestCanvasSwitch(isOpen: model.testEditor != nil, toggle: model.toggleTestCanvas))
        } else if !model.hasLaunched {
            // Launch reopens the canvas that was open; until it has, show the ground rather than flash the list.
            Chrome.listGround.ignoresSafeArea()
        } else {
            CanvasListScreen(model: model)
        }
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
