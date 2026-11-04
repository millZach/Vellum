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

    /// The labels the readout's room is set for (#45): `Scripts/status-bar-check.py` holds the count to its full wording
    /// beside these, and a label outside them may shorten it.
    func testTheUsualZoomsShowOnlyTheScaleLabelsTheFullCountIsHeldTo() {
        var labels: [String] = []
        var pointsPerInch = 0.0501
        while pointsPerInch <= 60 {
            let label = ScaleBar.mark(fitting: StatusBarText.scaleBarLongest, pointsPerInch: pointsPerInch,
                                      units: .feetAndInches).label
            if labels.last != label { labels.append(label) }
            pointsPerInch *= 1.01
        }
        XCTAssertEqual(labels, ["50'-0\"", "20'-0\"", "10'-0\"", "5'-0\"", "2'-0\"", "1'-0\"",
                                "0'-6\"", "0'-3\"", "0'-2\"", "0'-1\""])
    }

    /// Work count: the readout's width follows its label, and a pinch across the whole zoom changes the label only at a
    /// mark, never once per frame.
    func testAPinchAcrossTheWholeZoomChangesTheScaleLabelOnlyAtAMark() {
        let unitsAndChanges: [(CanvasUnits, Int)] = [(.feetAndInches, 18), (.decimalFeet, 17), (.metric, 17)]
        for (units, most) in unitsAndChanges {
            var changes = 0
            var frames = 0
            var last: String?
            var pointsPerInch = Viewport.minimumPointsPerInch
            while pointsPerInch <= Viewport.maximumPointsPerInch {
                let label = ScaleBar.mark(fitting: StatusBarText.scaleBarLongest, pointsPerInch: pointsPerInch,
                                          units: units).label
                if let last, last != label { changes += 1 }
                last = label
                frames += 1
                pointsPerInch *= 1.005
            }
            XCTAssertGreaterThan(frames, 2_000, "\(units)")
            XCTAssertLessThanOrEqual(changes, most, "\(units)")
        }
    }

    func testTheWindowMenusDisabledSendReachesTheContrastOnItsPill() {
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(ChromeColourPair.windowMenuDisabled(dark: dark).contrast, 4.5, "dark \(dark)")
        }
        XCTAssertEqual(ChromeColourPair.windowMenuDisabled(dark: false).fill, 0x1D1D1F)
        XCTAssertEqual(ChromeColourPair.windowMenuDisabled(dark: true).fill, 0x3A3B40)
    }
}
