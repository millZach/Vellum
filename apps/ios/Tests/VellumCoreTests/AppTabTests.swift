import XCTest
@testable import VellumCore

final class AppTabTests: XCTestCase {
    func testTheTabBarShowsFourTabsInOrder() {
        XCTAssertEqual(AppTab.allCases.map(\.title), ["Canvases", "Drawings", "Jobs", "Meetings"])
    }

    func testEveryTabSaysWhatItWillHold() {
        for tab in AppTab.allCases {
            XCTAssertFalse(tab.placeholder.isEmpty, "\(tab.title) has no placeholder line")
            XCTAssertFalse(tab.systemImage.isEmpty, "\(tab.title) has no symbol")
        }
    }

    func testTabIdentitiesAreUnique() {
        XCTAssertEqual(Set(AppTab.allCases.map(\.id)).count, AppTab.allCases.count)
    }

    func testTheAppIsCalledVellum() {
        XCTAssertEqual(AppIdentity.displayName, "Vellum")
    }
}
