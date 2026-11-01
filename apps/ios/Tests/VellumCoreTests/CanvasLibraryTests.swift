import Foundation
import XCTest
@testable import VellumCore

/// The canvases on the Duo: making, renaming, deleting, and the folder each one keeps for #12 to mirror.
final class CanvasLibraryTests: XCTestCase {
    private var library: CanvasLibrary!

    override func setUpWithError() throws {
        library = CanvasLibrary(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-library-\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: library.root)
    }

    func testANewCanvasIsAFolderWithItsNameUnitsAndAnEmptyLog() throws {
        let made = try library.create(name: "  Pump house sketch  ", units: .metric)
        XCTAssertEqual(made.name, "Pump house sketch")
        XCTAssertEqual(made.units, .metric)
        let files = try FileManager.default.contentsOfDirectory(atPath: library.folder(for: made.id).path).sorted()
        XCTAssertEqual(files, ["canvas.json", "ink.log"])
        let json = try String(contentsOf: library.folder(for: made.id).appendingPathComponent("canvas.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"name\" : \"Pump house sketch\""), json)
        XCTAssertTrue(json.contains("\"units\" : \"metric\""), json)
        XCTAssertTrue(try library.openInk(made.id).session.ink.isEmpty)
    }

    func testNewCanvasesAreNumberedUntitledAndTheListIsNewestFirst() throws {
        let t0 = Date().addingTimeInterval(-3_600)
        let a = try library.create(now: t0)
        let b = try library.create(now: t0.addingTimeInterval(60))
        let c = try library.create(name: "   ", now: t0.addingTimeInterval(120))
        XCTAssertEqual([a.name, b.name, c.name], ["Untitled canvas", "Untitled canvas 2", "Untitled canvas 3"])
        XCTAssertEqual(CanvasName.untitled(after: ["Untitled canvas", "Untitled canvas 3"]), "Untitled canvas 2")

        // Drawing on the oldest makes it the most recently changed.
        Thread.sleep(forTimeInterval: 0.02)
        let store = try library.openInk(a.id)
        var session = store.session
        session.draw([.origin, CanvasPoint(x: .feet(1), y: .feet(1))], tool: .pen, colour: .red, width: .inches(1))
        try store.append(session.takeEvents())
        XCTAssertEqual(try library.list().first?.id, a.id)
    }

    func testRenamingKeepsTheFolderAndRefusesABlankName() throws {
        let made = try library.create(name: "Boiler 4")
        XCTAssertEqual(try library.rename(made.id, to: " Boiler 4 walkdown "), "Boiler 4 walkdown")
        XCTAssertEqual(try library.rename(made.id, to: "   "), "Boiler 4 walkdown")
        XCTAssertEqual(try library.summary(for: made.id).name, "Boiler 4 walkdown")
        try library.setUnits(made.id, to: .decimalFeet)
        XCTAssertEqual(try library.manifest(for: made.id).canvasUnits, .decimalFeet)
        XCTAssertEqual(try library.list().map(\.id), [made.id])
    }

    func testDeletingRemovesTheCanvasAndAllItsInk() throws {
        let keep = try library.create(name: "Keep")
        let gone = try library.create(name: "Gone")
        let store = try library.openInk(gone.id)
        var session = store.session
        session.draw([.origin], tool: .pen, colour: .blue, width: .inches(1))
        try store.append(session.takeEvents())
        try library.delete(gone.id)
        XCTAssertEqual(try library.list().map(\.id), [keep.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.folder(for: gone.id).path))
        let hidden = try FileManager.default.contentsOfDirectory(atPath: library.root.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(hidden, [])
    }

    func testHalfMadeOrHalfDeletedCanvasesNeverShowInTheList() throws {
        let made = try library.create(name: "Real")
        for leftover in [".\(UUID().uuidString).creating", ".\(UUID().uuidString).deleting", "not-a-canvas"] {
            try FileManager.default.createDirectory(at: library.root.appendingPathComponent(leftover),
                                                    withIntermediateDirectories: true)
        }
        XCTAssertEqual(try library.list().map(\.id), [made.id])
        library.removeLeftovers()
        let names = try FileManager.default.contentsOfDirectory(atPath: library.root.path).sorted()
        XCTAssertEqual(names, [made.id.uuidString, "not-a-canvas"].sorted())
    }

    func testAnUnknownUnitsNameFromANewerVellumReadsAsTheDefault() throws {
        var manifest = CanvasManifest(id: UUID(), name: "x", units: .metric, created: Date())
        manifest.units = "cubits"
        XCTAssertEqual(manifest.canvasUnits, .default)
    }
}

/// The Canvases list's picture of a canvas.
final class InkThumbnailTests: XCTestCase {
    func testTheInkIsFittedCentredAndKeepsItsProportions() throws {
        var session = InkSession()
        // A 40 × 10 foot run of ink.
        session.draw([CanvasPoint(x: .feet(0), y: .feet(0)), CanvasPoint(x: .feet(40), y: .feet(10))],
                     tool: .pen, colour: .red, width: .inches(1))
        let thumb = InkThumbnail(ink: session.ink, width: 420, height: 300, padding: 10)
        let line = try XCTUnwrap(thumb.lines.first)
        XCTAssertEqual(thumb.strokeCount, 1)
        // The width is the limit: 400 points for 40 feet (plus the stroke's inch), centred top to bottom.
        XCTAssertEqual(line.xs.first!, 420 - line.xs.last!, accuracy: 1e-6)
        XCTAssertEqual(line.xs.last! - line.xs.first!, 400, accuracy: 1)
        XCTAssertEqual((line.ys.first! + line.ys.last!) / 2, 150, accuracy: 1e-6)
        XCTAssertEqual((line.ys.last! - line.ys.first!) / (line.xs.last! - line.xs.first!), 0.25, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(line.width, 0.75, "never thinner than a hairline")
    }

    func testAThumbnailOfAHugeCanvasDrawsFewPoints() {
        var session = InkSession()
        for i in 0..<2_000 {
            let points = (0..<200).map { k in CanvasPoint(x: .inches(Double(i * 10 + k) * 0.01), y: .inches(Double(i % 50))) }
            session.draw(points, tool: .pen, colour: .sketch, width: .inches(0.5))
        }
        let thumb = InkThumbnail(ink: session.ink, width: 500, height: 360)
        XCTAssertEqual(thumb.strokeCount, 2_000)
        XCTAssertLessThan(thumb.pointCount, 2_000 * 200 / 10, "thinned to what a thumbnail can show")
        XCTAssertTrue(thumb.lines.allSatisfy { $0.xs.count >= 1 })
    }

    func testEmptyInkHasNoLines() {
        let thumb = InkThumbnail(ink: Ink(), width: 100, height: 100)
        XCTAssertEqual(thumb.lines, [])
        XCTAssertEqual(thumb.strokeCount, 0)
    }
}
