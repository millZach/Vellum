import SwiftUI
import UIKit
import VellumCore

/// The iOS tab bar with Canvases, Drawings, Jobs and Meetings. Canvases holds the list of canvases and, over it, the
/// canvas screen for the one open; Drawings searches the drawing index (#68); the other tabs are empty until their
/// tickets build them.
struct RootView: View {
    @State private var selection: AppTab = RootView.launchTab
    /// The canvases and the open canvas live here, above the tabs, so switching tabs keeps the canvas open.
    @State private var canvases = CanvasesModel()
    /// The Duo's copy of the drawing index and its search (#68), kept fresh from launch whichever tab is open.
    @State private var drawings = DrawingIndexModel()
    @Environment(\.scenePhase) private var scenePhase
    /// Light, Dark or System (ADR-0011), chosen from the canvas screen's top bar.
    @AppStorage(AppearanceSetting.storageKey) private var appearance = AppearanceSetting.default.rawValue

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.descriptor.title, systemImage: tab.descriptor.systemImage, value: tab) {
                    if tab == .canvases {
                        CanvasesTab(model: canvases)
                            .environment(canvases)
                    } else if tab == .drawings {
                        DrawingsScreen(index: drawings,
                                       handoff: DrawingHandoff(canvases: canvases, showCanvases: { selection = .canvases }))
                    } else {
                        PlaceholderScreen(tab: tab)
                    }
                }
            }
        }
        .background(WindowAppearance(style: (AppearanceSetting(rawValue: appearance) ?? .default).interfaceStyle))
        // A plot that came in while Zach was elsewhere calls him back to it (#70): floating at the top of whichever tab
        // is showing, shifted right into the free space beside the screen's title row and clear of its buttons and of
        // the tab rail (Zach, 2026-11-08). Nothing on the screen moves for it. Where it goes on each screen is
        // `PlotBannerPlace`.
        .overlay {
            if let entry = drawings.plotBanner {
                GeometryReader { proxy in
                    let place = PlotBannerPlace(size: proxy.size, safe: proxy.safeAreaInsets, tab: selection,
                                                canvasOpen: canvases.openEditor != nil,
                                                placingSheet: canvases.openEditor?.placingSheet != nil)
                    PlotBanner(entry: entry,
                               view: {
                                   selection = .drawings
                                   drawings.viewBanner()
                               },
                               dismiss: { drawings.plotBanner = nil })
                        .frame(maxWidth: place.maxWidth, alignment: .trailing)
                        .padding(.top, place.top)
                        .padding(.trailing, place.trailing)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .ignoresSafeArea()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: drawings.plotBanner?.id)
        .onChange(of: drawings.debugTab) { _, tab in
            if let tab { selection = tab }
        }
        .task {
            // The drawing index is read and refreshed off the main thread; nothing here waits for it.
            Task { await DrawingIndexSetup.start(drawings) }
            #if DEBUG
            DebugAppearanceSteps.run()
            #endif
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
            if phase != .active { canvases.appWillLeaveScreen(background: phase == .background) }
            if phase == .background { drawings.appLeftScreen() }
            if phase == .active {
                canvases.appDidBecomeActive()
                drawings.appBecameActive()
            }
        }
        .onChange(of: DropboxConnection.app.isSignedIn) { _, signedIn in
            canvases.dropboxSignInChanged()
            drawings.signInChanged(signedIn: signedIn)
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

/// Pins the window to Light or Dark, or lets it follow the Duo, by setting the window's own
/// `overrideUserInterfaceStyle`. SwiftUI's `.preferredColorScheme` stopped updating once it had been set, so after
/// picking Light neither Dark nor System came back (#26). The window's style reaches every view and sheet in it.
private struct WindowAppearance: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> WindowStyleView { WindowStyleView() }

    func updateUIView(_ view: WindowStyleView, context: Context) { view.style = style }
}

final class WindowStyleView: UIView {
    var style: UIUserInterfaceStyle = .unspecified {
        didSet { if style != oldValue { apply() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        guard let scene = window?.windowScene else { return }
        for sceneWindow in scene.windows where sceneWindow.overrideUserInterfaceStyle != style {
            sceneWindow.overrideUserInterfaceStyle = style
        }
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
