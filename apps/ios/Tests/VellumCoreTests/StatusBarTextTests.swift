import XCTest
@testable import VellumCore

final class StatusBarTextTests: XCTestCase {
    private let longest = -(139.0 * 12 + 11 + 15.0 / 16)

    func testTheLongPositionIsTheCharactersKeptForIt() {
        let point = CanvasPoint(x: .inches(longest), y: .inches(-longest))
        let text = CanvasUnits.feetAndInches.formatPosition(point)
        XCTAssertEqual(text, "X -139'-11 15/16\"  Y -139'-11 15/16\"")
        XCTAssertEqual(text.count, StatusBarText.longPositionCharacters)
    }

    func testAnyPositionUnderAHundredFeetFitsTheUsualWidth() {
        let inches = -(99.0 * 12 + 11 + 15.0 / 16)
        let text = CanvasUnits.feetAndInches.formatPosition(CanvasPoint(x: .inches(inches), y: .inches(-inches)))
        XCTAssertEqual(text, "X -99'-11 15/16\"  Y -99'-11 15/16\"")
        XCTAssertEqual(text.count, StatusBarText.usualPositionCharacters)
    }

    /// Work count: the pen wandering over every length up to the long one, a sixteenth at a time, moves the neighbours
    /// at most once.
    func testThePenMovingChangesTheWidthAtMostOnce() {
        var reserved = StatusBarText.usualPositionCharacters
        var changes = 0
        var sixteenths = Int(longest * 16)
        while sixteenths <= 0 {
            let inches = Double(sixteenths) / 16
            let text = CanvasUnits.feetAndInches.formatPosition(CanvasPoint(x: .inches(inches), y: .inches(-inches)))
            let next = StatusBarText.reservedCharacters(reserved, showing: text.count)
            if next != reserved { changes += 1 }
            reserved = next
            sixteenths += 1
        }
        XCTAssertEqual(reserved, StatusBarText.longPositionCharacters)
        XCTAssertEqual(changes, 1)
    }

    func testTheWidthNeverShrinksAndGrowsForAnythingLonger() {
        XCTAssertEqual(StatusBarText.reservedCharacters(36, showing: 12), 36)
        XCTAssertEqual(StatusBarText.reservedCharacters(34, showing: 35), 36)
        XCTAssertEqual(StatusBarText.reservedCharacters(36, showing: 40), 40)
    }

    func testTheCountsGetShorterAndKeepTheirNumbers() {
        XCTAssertEqual(StatusBarText.counts(sheets: 1, frames: 0), ["1 sheet · 0 frames", "1 sh · 0 fr", "1 · 0"])
        XCTAssertEqual(StatusBarText.counts(sheets: 12, frames: 1), ["12 sheets · 1 frame", "12 sh · 1 fr", "12 · 1"])
    }

    func testTheWindowMenusDisabledSendReachesTheContrastOnItsPill() {
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(ChromeColourPair.windowMenuDisabled(dark: dark).contrast, 4.5, "dark \(dark)")
        }
        XCTAssertEqual(ChromeColourPair.windowMenuDisabled(dark: false).fill, 0x1D1D1F)
        XCTAssertEqual(ChromeColourPair.windowMenuDisabled(dark: true).fill, 0x3A3B40)
    }
}
