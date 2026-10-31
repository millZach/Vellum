import XCTest
@testable import VellumCore

final class AppTabTests: XCTestCase {
    func testTheTabBarShowsFourTabsInOrder() {
        XCTAssertEqual(AppTab.allCases.map(\.descriptor.title), ["Canvases", "Drawings", "Jobs", "Meetings"])
    }

    func testEveryTabSaysWhatItWillHold() {
        for tab in AppTab.allCases {
            XCTAssertFalse(tab.descriptor.placeholder.isEmpty, "\(tab) has no placeholder line")
            XCTAssertFalse(tab.descriptor.systemImage.isEmpty, "\(tab) has no symbol")
        }
    }

    func testTabIdentitiesAreUnique() {
        XCTAssertEqual(Set(AppTab.allCases.map(\.id)).count, AppTab.allCases.count)
    }

    func testATabIsFoundByItsName() {
        XCTAssertEqual(AppTab(rawValue: "meetings"), .meetings)
        XCTAssertNil(AppTab(rawValue: "sheets"))
    }
}
