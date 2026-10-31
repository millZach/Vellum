import XCTest
@testable import VellumCore

final class DrawingScaleTests: XCTestCase {
    func testPrintedToRealConversions() {
        XCTAssertEqual(DrawingScale.architectural(inchesPerFoot: 0.25).realPerPrinted, 48)
        XCTAssertEqual(DrawingScale.architectural(inchesPerFoot: 0.125).realPerPrinted, 96)
        XCTAssertEqual(DrawingScale.architectural(inchesPerFoot: 3).realPerPrinted, 4)
        XCTAssertEqual(DrawingScale.engineering(feetPerInch: 20).realPerPrinted, 240)
        XCTAssertEqual(DrawingScale.ratio(50).realPerPrinted, 50)
        XCTAssertEqual(DrawingScale.fullSize.realPerPrinted, 1)

        let quarter = DrawingScale.architectural(inchesPerFoot: 0.25)
        XCTAssertEqual(quarter.realLength(of: .inches(24)), .feet(96))
        XCTAssertEqual(quarter.printedLength(of: .feet(144)), .inches(36))
        XCTAssertEqual(DrawingScale.ratio(100).realLength(of: .millimetres(10)).metres, 1, accuracy: 1e-12)
    }

    func testEveryOfferedScaleIsNamedTheWayATitleBlockWritesIt() {
        XCTAssertEqual(DrawingScale.architecturalScales.map(\.description), [
            "1/16\" = 1'-0\"", "3/32\" = 1'-0\"", "1/8\" = 1'-0\"", "3/16\" = 1'-0\"", "1/4\" = 1'-0\"",
            "3/8\" = 1'-0\"", "1/2\" = 1'-0\"", "3/4\" = 1'-0\"", "1\" = 1'-0\"", "1 1/2\" = 1'-0\"", "3\" = 1'-0\"",
        ])
        XCTAssertEqual(DrawingScale.engineeringScales.map(\.description),
                       ["1\" = 100'", "1\" = 60'", "1\" = 50'", "1\" = 40'", "1\" = 30'", "1\" = 20'", "1\" = 10'"])
        XCTAssertEqual(DrawingScale.ratioScales.map(\.description), ["1:100", "1:50", "1:1"])
    }

    func testEveryOfferedScaleReadsBackFromItsName() {
        for scale in DrawingScale.architecturalScales + DrawingScale.engineeringScales + DrawingScale.ratioScales {
            XCTAssertEqual(DrawingScale.read(scale.description), .scale(scale), scale.description)
            XCTAssertEqual(DrawingScale.read("SCALE: " + scale.description), .scale(scale), scale.description)
        }
    }

    func testEveryScaleReadsBackAsTheSameConversion() {
        let odd = [
            DrawingScale(printed: .inches(1), real: .inches(1.0 / 32))!,
            DrawingScale(printed: .inches(3.0 / 64), real: .inches(89.3))!,
            DrawingScale(printed: .inches(0.3), real: .feet(7, inches: 1.0 / 64))!,
            DrawingScale(printed: .inches(1), real: .feet(1, inches: 0.1))!,
            DrawingScale(printed: .inches(1), real: .feet(1))!,
            DrawingScale(printed: .inches(2.5), real: .inches(1), notation: .ratio)!,
            DrawingScale.ratio(2.5),
        ]
        for scale in DrawingScale.architecturalScales + DrawingScale.engineeringScales + DrawingScale.ratioScales + odd {
            guard case .scale(let read) = DrawingScale.read(scale.description) else {
                XCTFail("\(scale.description) did not read back")
                continue
            }
            XCTAssertEqual(read.realPerPrinted, scale.realPerPrinted, scale.description)
        }
        // The label is exact, not rounded to a measure's 1/16".
        XCTAssertEqual(odd[0].description, "1\" = 0'-1/32\"")
        XCTAssertEqual(odd[2].description, "0.3\" = 7'-1/64\"")
        XCTAssertEqual(odd[4].description, "1\" = 1'-0\"")
    }

    func testABadScaleCannotBeMade() {
        XCTAssertNil(DrawingScale(printed: .zero, real: .feet(1)))
        XCTAssertNil(DrawingScale(printed: .inches(1), real: .feet(-1)))
        XCTAssertNil(DrawingScale(printed: .inches(.infinity), real: .feet(1)))
    }

    // MARK: Reading scale text

    private func read(_ text: String) -> ScaleReading { DrawingScale.read(text) }
    private func factor(_ text: String) -> Double? {
        if case .scale(let scale) = read(text) { return scale.realPerPrinted }
        return nil
    }

    func testReadsArchitecturalScales() {
        let quarter = ScaleReading.scale(.architectural(inchesPerFoot: 0.25))
        XCTAssertEqual(read("SCALE: 1/4\" = 1'-0\""), quarter)
        XCTAssertEqual(read("1/4\"=1'-0\""), quarter)
        XCTAssertEqual(read("1/4\" = 1'-0\""), quarter)
        XCTAssertEqual(read("scale 1/4\" = 1'"), quarter)
        XCTAssertEqual(read("  SCALE:1/4\"=1' 0\"  "), quarter)
        XCTAssertEqual(read("SCALE = 1/4\" = 1'-0\""), quarter)
        XCTAssertEqual(read("1/4″ = 1′-0″"), quarter)
        XCTAssertEqual(read("1/4” = 1’-0”"), quarter)
        XCTAssertEqual(read("1/4'' = 1'-0''"), quarter)
        XCTAssertEqual(read("1/4\" = 1'–0\""), quarter)
        XCTAssertEqual(read("SCALE:\t1/4\" = 1'-0\""), quarter)
        XCTAssertEqual(factor("1/8\" = 1'-0\""), 96)
        XCTAssertEqual(factor("3/32\"=1'-0\""), 128)
        XCTAssertEqual(factor("1 1/2\" = 1'-0\""), 8)
        XCTAssertEqual(factor("1-1/2\" = 1'-0\""), 8)
        XCTAssertEqual(factor("1.5\" = 1'-0\""), 8)
        XCTAssertEqual(factor("3\" = 1'-0\""), 4)
        XCTAssertEqual(factor("1/2\" = 1'-6\""), 36)
    }

    func testReadsEngineeringScales() {
        XCTAssertEqual(read("1\" = 20'"), .scale(.engineering(feetPerInch: 20)))
        XCTAssertEqual(read("SCALE: 1\"=100'"), .scale(.engineering(feetPerInch: 100)))
        XCTAssertEqual(factor("1\" = 20'-0\""), 240)
        XCTAssertEqual(factor("1\" = 50'"), 600)
    }

    func testReadsRatiosAndFullSize() {
        XCTAssertEqual(read("1:50"), .scale(.ratio(50)))
        XCTAssertEqual(read("SCALE: 1 : 100"), .scale(.ratio(100)))
        XCTAssertEqual(read("1:1"), .scale(.fullSize))
        XCTAssertEqual(read("FULL SIZE"), .scale(.fullSize))
        XCTAssertEqual(read("SCALE: FULL"), .cantTell)
        XCTAssertEqual(factor("2:1"), 0.5)
        XCTAssertEqual(factor("12\" = 1'-0\""), 1)
    }

    func testReadsNotToScale() {
        for text in ["NTS", "N.T.S.", "nts", "SCALE: NTS", "SCALE: N.T.S.", "NOT TO SCALE", "Scale: Not to Scale",
                     "SCALE: NO SCALE"] {
            XCTAssertEqual(read(text), .notToScale, text)
        }
    }

    func testCantTellAsNotedOrAsShown() {
        for text in ["AS NOTED", "SCALE: AS NOTED", "AS SHOWN", "SCALE: AS SHOWN", "AS INDICATED", "VARIES"] {
            XCTAssertEqual(read(text), .cantTell, text)
        }
    }

    func testCantTellMalformedLengths() {
        // Signs, stray hyphens and cut-off lengths are not quietly repaired into a usable scale (ADR-0002).
        for text in ["-1/4\" = 1'-0\"", "1/4-\" = 1'-0\"", "1/4\" = 1'-", "1/4\" = 1' -", "1/4\" = -1'-0\"",
                     "1/4\" = 1'--0\"", "1/4\" = 1'-0-\"", "1/4\" = 1'--1/2\"", "1--1/2\" = 1'-0\"",
                     "1-1/2-\" = 1'-0\"", "-1-1/2\" = 1'-0\"", "1-\" = 20'", "1\" = -20'", "-1:50", "1:-50"] {
            XCTAssertEqual(DrawingScale.read(text), .cantTell, text)
        }
        // The hyphen that joins a whole number to its fraction, and feet to inches, still reads.
        XCTAssertEqual(factor("1-1/2\" = 1'-0\""), 8)
        XCTAssertEqual(factor("1 - 1/2\" = 1' - 0\""), 8)
        XCTAssertEqual(factor("1/4\" = 1'-0\""), 48)
        XCTAssertEqual(factor("1/2\" = 1'-1-1/2\""), 27)
    }

    func testCantTellJunk() {
        for text in ["", "   ", "SCALE:", "SCALE", "1/4", "1/4 = 1", "1/4\"", "1/4\" = ", "= 1'-0\"", "hello",
                     "0\" = 1'-0\"", "1/0\" = 1'-0\"", "1/4\" = 0'", "0:50", "1:0", "1:", ":50", "1:50:2",
                     "1/4\" = 1'-0\" & 1/8\" = 1'-0\"", "1/4\" = 1'-0\" = 2'", "1\" = 20' (24x36)", "nan:1",
                     "1e2:1", "1..2:1", ".:1", "1/4/2\" = 1'", "1 1/2 1/4\" = 1'", "1/2 1/4\" = 1'", "x\" = 1'",
                     "1/4\" = 1'-0", "1/4\" = 1'-x\"", "1/4\" = a'-0\"", "1:50 1:100", "SCALE: 1/4 INCH = 1 FOOT"] {
            XCTAssertEqual(read(text), .cantTell, text)
        }
    }
}
