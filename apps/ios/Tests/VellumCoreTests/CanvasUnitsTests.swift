import XCTest
@testable import VellumCore

final class CanvasUnitsTests: XCTestCase {
    private func feetAndInches(_ length: Length) -> String { CanvasUnits.feetAndInches.format(length) }
    private func decimalFeet(_ length: Length) -> String { CanvasUnits.decimalFeet.format(length) }
    private func metric(_ length: Length) -> String { CanvasUnits.metric.format(length) }

    func testFeetAndInchesWriteTheDraftingWay() {
        XCTAssertEqual(feetAndInches(.feet(12, inches: 6.5)), "12'-6 1/2\"")
        XCTAssertEqual(feetAndInches(.feet(12)), "12'-0\"")
        XCTAssertEqual(feetAndInches(.inches(3)), "0'-3\"")
        XCTAssertEqual(feetAndInches(.inches(0.5)), "0'-0 1/2\"")
        XCTAssertEqual(feetAndInches(.feet(1, inches: 11 + 15.0 / 16)), "1'-11 15/16\"")
        XCTAssertEqual(feetAndInches(.feet(144)), "144'-0\"")
        XCTAssertEqual(feetAndInches(.feet(5280)), "5280'-0\"")
    }

    func testFeetAndInchesReduceTheFraction() {
        XCTAssertEqual(feetAndInches(.inches(4.25)), "0'-4 1/4\"")
        XCTAssertEqual(feetAndInches(.inches(4.375)), "0'-4 3/8\"")
        XCTAssertEqual(feetAndInches(.inches(4.0625)), "0'-4 1/16\"")
    }

    func testFeetAndInchesRoundToTheNearestSixteenth() {
        XCTAssertEqual(CanvasUnits.fractionalPrecision, 16)
        XCTAssertEqual(feetAndInches(.inches(6.53)), "0'-6 1/2\"")
        XCTAssertEqual(feetAndInches(.inches(6.55)), "0'-6 9/16\"")
        XCTAssertEqual(feetAndInches(.inches(1.0 / 64)), "0'-0\"")
        XCTAssertEqual(feetAndInches(.inches(1.0 / 32)), "0'-0 1/16\"")   // a half sixteenth rounds up
    }

    func testFeetAndInchesCarryIntoTheNextInchAndFoot() {
        XCTAssertEqual(feetAndInches(.inches(6 + 31.0 / 32 + 0.001)), "0'-7\"")
        XCTAssertEqual(feetAndInches(.feet(11, inches: 11.99)), "12'-0\"")
        XCTAssertEqual(feetAndInches(.inches(11.97)), "1'-0\"")
    }

    func testFeetAndInchesZeroAndNegatives() {
        XCTAssertEqual(feetAndInches(.zero), "0'-0\"")
        XCTAssertEqual(feetAndInches(.inches(-0.01)), "0'-0\"")   // never "-0'-0\""
        XCTAssertEqual(feetAndInches(-.feet(12, inches: 6.5)), "-12'-6 1/2\"")
        XCTAssertEqual(feetAndInches(.inches(-3)), "-0'-3\"")
        XCTAssertEqual(feetAndInches(.feet(-11, inches: -11.99)), "-12'-0\"")
    }

    func testDecimalFeet() {
        XCTAssertEqual(decimalFeet(.feet(12.54)), "12.54'")
        XCTAssertEqual(decimalFeet(.feet(12, inches: 6.5)), "12.54'")
        XCTAssertEqual(decimalFeet(.feet(3)), "3.00'")
        XCTAssertEqual(decimalFeet(.feet(0.05)), "0.05'")
        XCTAssertEqual(decimalFeet(.feet(9.996)), "10.00'")
        XCTAssertEqual(decimalFeet(.zero), "0.00'")
        XCTAssertEqual(decimalFeet(.feet(-0.001)), "0.00'")
        XCTAssertEqual(decimalFeet(.feet(-12.54)), "-12.54'")
    }

    func testMetric() {
        XCTAssertEqual(metric(.millimetres(350)), "350 mm")
        XCTAssertEqual(metric(.inches(1)), "25 mm")
        XCTAssertEqual(metric(.millimetres(999.4)), "999 mm")
        XCTAssertEqual(metric(.millimetres(999.6)), "1.000 m")
        XCTAssertEqual(metric(.metres(12.54)), "12.540 m")
        XCTAssertEqual(metric(.feet(96)), "29.261 m")
        XCTAssertEqual(metric(.zero), "0 mm")
        XCTAssertEqual(metric(.millimetres(-0.4)), "0 mm")
        XCTAssertEqual(metric(.millimetres(-350)), "-350 mm")
        XCTAssertEqual(metric(.metres(-2.005)), "-2.005 m")
    }

    func testPrintedLengthsAreMarkedNTS() {
        XCTAssertEqual(CanvasUnits.feetAndInches.format(PrintedLength.inches(3.5)), "3 1/2\" NTS")
        XCTAssertEqual(CanvasUnits.decimalFeet.format(PrintedLength.inches(0.25)), "1/4\" NTS")
        XCTAssertEqual(CanvasUnits.feetAndInches.format(PrintedLength.inches(14)), "14\" NTS")
        XCTAssertEqual(CanvasUnits.feetAndInches.format(PrintedLength.zero), "0\" NTS")
        // NTS lengths read in printed inches whatever the canvas units, metric included.
        for units in CanvasUnits.allCases {
            XCTAssertEqual(units.format(PrintedLength.inches(3.5)), "3 1/2\" NTS", "\(units)")
            XCTAssertEqual(units.format(Measure.notToScale(.inches(3.5))), "3 1/2\" NTS", "\(units)")
        }
        XCTAssertEqual(CanvasUnits.metric.format(PrintedLength.millimetres(89)), "3 1/2\" NTS")
        XCTAssertEqual(CanvasUnits.feetAndInches.format(Measure.notToScale(.inches(1))), "1\" NTS")
        XCTAssertEqual(CanvasUnits.decimalFeet.format(Measure.real(.feet(2))), "2.00'")
    }

    func testLengthConversions() {
        XCTAssertEqual(Length.feet(1).inches, 12)
        XCTAssertEqual(Length.millimetres(25.4).inches, 1, accuracy: 1e-12)
        XCTAssertEqual(Length.metres(1).millimetres, 1000, accuracy: 1e-9)
        XCTAssertEqual(Length.inches(-5).magnitude, .inches(5))
        XCTAssertEqual(Length.feet(2) - .inches(6), .inches(18))
        XCTAssertLessThan(Length.inches(11), .feet(1))
    }
}
