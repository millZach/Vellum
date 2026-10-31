import SwiftUI
import VellumCore

/// The iOS tab bar with Canvases, Drawings, Jobs and Meetings. Each tab is empty until its ticket builds it; the
/// canvas screen is ticket #6.
struct RootView: View {
    @State private var selection: AppTab = .canvases

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    PlaceholderScreen(tab: tab)
                }
            }
        }
    }
}

/// An empty screen that says, in one line, what its tab will hold.
struct PlaceholderScreen: View {
    let tab: AppTab

    var body: some View {
        ContentUnavailableView(tab.title, systemImage: tab.systemImage, description: Text(tab.placeholder))
    }
}

#Preview(traits: .fixedLayout(width: 951, height: 669)) {
    RootView()
}
