import Foundation
import XCTest
@testable import VellumCore

// Asking the laptop to plot a DWG with no PDF and waiting for it (#70, ADR-0018, docs/plot-requests.md). The drawings
// are the laptop indexer's made-up fixture index; the Dropbox is the made-up one, and the laptop is played by the test,
// writing answers and the check-in as `laptop/src/vellum_indexer/plot_requests.py` would. Nothing here is anyone's drawing.
/// The made-up moment each test starts at.
private let t0 = PlotRequestFormat.date("2026-11-07T12:00:00Z")!

final class PlotRequestTests: XCTestCase {
    // MARK: The request's bytes

    /// The request example in docs/plot-requests.md, as written there.
    private static var documentedRequest: String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../docs/plot-requests.md").standardizedFileURL
        let doc = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let section = doc.range(of: "## A request"),
              let open = doc.range(of: "```json\n", range: section.upperBound..<doc.endIndex),
              let close = doc.range(of: "\n```", range: open.upperBound..<doc.endIndex) else { return "" }
        return String(doc[open.upperBound..<close.lowerBound])
    }

    func testARequestIsFormatOneFieldForFieldAsTheDocWritesIt() throws {
        let documented = Self.documentedRequest
        XCTAssertFalse(documented.isEmpty, "the example request in docs/plot-requests.md")
        let request = PlotRequest(request: "6F1C2B9A-0D3E-4A5B-8C7D-1E2F3A4B5C6D", id: "dd0bdad0ab9b9082",
                                  path: "/Projects/Made-up Plant Upgrade/CAD/E-202.dwg", layout: "Layout1",
                                  asked: t0)
        XCTAssertEqual(String(decoding: request.bytes, as: UTF8.self), documented + "\n")
        // Field for field, too, as the laptop reads it.
        let mine = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.bytes)) as? [String: Any])
        let theirs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(documented.utf8)) as? [String: Any])
        XCTAssertEqual(Set(mine.keys), ["format", "id", "path", "layout", "asked"])
        XCTAssertEqual(Set(mine.keys), Set(theirs.keys))
        for key in theirs.keys { XCTAssertEqual("\(mine[key]!)", "\(theirs[key]!)", key) }
    }

    func testARequestForAFixtureDrawingPassesTheLaptopsRules() throws {
        for number in ["E-201", "M-102"] {
            let entry = IndexFixture.entry(number)
            XCTAssertNil(entry.pdf, "\(number) has no PDF yet")
            let request = try XCTUnwrap(PlotRequest.asking(for: entry, at: t0.addingTimeInterval(0.7)))
            let name = "\(request.request).json"
            XCTAssertNil(LaptopRules.refusal(name: name, data: request.bytes), number)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.bytes)) as? [String: Any])
            XCTAssertEqual(body["id"] as? String, entry.id)
            XCTAssertEqual(body["path"] as? String, entry.dwg?.path)
            XCTAssertEqual(body["layout"] as? String, entry.layout)
            XCTAssertEqual(body["asked"] as? String, "2026-11-07T12:00:00Z", "whole seconds, UTC")
            XCTAssertEqual(request.dropboxPath, "/Vellum/Plots/requests/\(name)")
            XCTAssertTrue(PlotRequestFormat.isRequestPath(request.dropboxPath))
        }
        // A DWG whose title blocks aren't read yet asks with a null layout, which the laptop takes.
        var unread = IndexFixture.entry("E-201")
        unread.layout = nil
        let request = try XCTUnwrap(PlotRequest.asking(for: unread, at: t0))
        XCTAssertTrue(String(decoding: request.bytes, as: UTF8.self).contains("\"layout\": null"))
        XCTAssertNil(LaptopRules.refusal(name: "\(request.request).json", data: request.bytes))
        // A PDF with no DWG has nothing to plot.
        XCTAssertNil(PlotRequest.asking(for: IndexFixture.entry("V-12"), at: t0))
    }

    func testTheLaptopsRulesRefuseWhatTheDocSaysTheyRefuse() {
        // The port of `decode` the test above relies on refuses what the doc says, so its pass means something.
        func bytes(_ id: String = "dd0bdad0ab9b9082", path: String = "/A/B.dwg", layout: String = "\"Layout1\"",
                   asked: String = "2026-11-07T12:00:00Z", format: Int = 1) -> [UInt8] {
            Array(#"{"format": \#(format), "id": "\#(id)", "path": \#(PlotRequest.quoted(path)), "layout": \#(layout), "asked": "\#(asked)"}"#.utf8)
        }
        let name = "6F1C2B9A-0D3E-4A5B-8C7D-1E2F3A4B5C6D.json"
        XCTAssertNil(LaptopRules.refusal(name: name, data: bytes()))
        XCTAssertNotNil(LaptopRules.refusal(name: name, data: bytes(format: 2)))
        XCTAssertNotNil(LaptopRules.refusal(name: name, data: bytes("DD0BDAD0AB9B9082")))
        XCTAssertNotNil(LaptopRules.refusal(name: name, data: bytes(path: "/A/../B.dwg")))
        XCTAssertNotNil(LaptopRules.refusal(name: name, data: bytes(path: "/A/B.pdf")))
        XCTAssertNotNil(LaptopRules.refusal(name: name, data: bytes(path: "A\\B.dwg")))
        XCTAssertNotNil(LaptopRules.refusal(name: name, data: bytes(layout: "\"\"")))
        XCTAssertNotNil(LaptopRules.refusal(name: name, data: bytes(asked: "2026-11-07 12:00:00")))
        XCTAssertNotNil(LaptopRules.refusal(name: "short.json", data: bytes()))
        XCTAssertNotNil(LaptopRules.refusal(name: "6F1C2B9A-0D3E-4A5B-8C7D-1E2F3A4B5C6D.answer.json", data: bytes()))
        XCTAssertNotNil(LaptopRules.refusal(name: "-6F1C2B9A-0D3E-4A5B.json", data: bytes()))
    }

    func testTheDuoWritesAndDeletesOnlyRequestsInTheRequestsFolder() {
        let id = UUID().uuidString
        XCTAssertTrue(PlotRequestFormat.isRequestPath("/Vellum/Plots/requests/\(id).json"))
        XCTAssertFalse(PlotRequestFormat.isRequestPath("/Vellum/Plots/requests/\(id).answer.json"))
        XCTAssertFalse(PlotRequestFormat.isRequestPath("/Vellum/Plots/laptop.json"))
        XCTAssertFalse(PlotRequestFormat.isRequestPath("/Vellum/Plots/requests/~$\(id).tmp"))
        XCTAssertFalse(PlotRequestFormat.isRequestPath("/Vellum/Plots/requests/sub/\(id).json"))
        XCTAssertFalse(PlotRequestFormat.isRequestPath("/Vellum/Index/\(id).json"))
        XCTAssertFalse(PlotRequestFormat.isRequestPath("/Vellum/Plots/requests/../\(id).json"))
    }

    // MARK: Where a plot has got to

    func testTheStagesFromAskingToDone() {
        func stage(sent: Bool = true, _ state: PlotAnswer.State? = nil, seen: Double? = -30, known: Bool = true,
                   online: Bool = true, kept: Bool = false) -> PlotStage {
            let answer = state.map { PlotAnswer(request: "r", id: "e", state: $0, reason: $0 == .failed ? "the DWG couldn't be read" : nil) }
            return PlotStage.of(sent: sent, answer: answer, checkedIn: seen.map { t0.addingTimeInterval($0) },
                                checkInKnown: known, online: online, pdfKept: kept, now: t0)
        }
        // Asked, offline: queued on this Duo; online but not sent yet: asking.
        XCTAssertEqual(stage(sent: false, online: false), .queuedOnThisDuo)
        XCTAssertEqual(stage(sent: false), .asking)
        // Sent, no answer yet: asking; before the check-in is known, too.
        XCTAssertEqual(stage(), .asking)
        XCTAssertEqual(stage(seen: nil, known: false), .asking)
        // The laptop has it.
        XCTAssertEqual(stage(.queued), .plotting)
        XCTAssertEqual(stage(.plotting), .plotting)
        // Waiting for the laptop: at the limit it is still seen, just past it it is off.
        XCTAssertEqual(stage(seen: -PlotRequestFormat.staleAfter), .asking)
        XCTAssertEqual(stage(.plotting, seen: -PlotRequestFormat.staleAfter), .plotting)
        let past = t0.addingTimeInterval(-PlotRequestFormat.staleAfter - 1)
        XCTAssertEqual(stage(seen: -PlotRequestFormat.staleAfter - 1), .waitingForLaptop(lastSeen: past))
        XCTAssertEqual(stage(.plotting, seen: -PlotRequestFormat.staleAfter - 1), .waitingForLaptop(lastSeen: past))
        XCTAssertEqual(stage(seen: nil), .waitingForLaptop(lastSeen: nil), "no check-in: the laptop has never run it")
        XCTAssertEqual(PlotRequestFormat.staleAfter, 300)
        // Failed, with the laptop's reason as a sentence.
        XCTAssertEqual(stage(.failed), .failed(reason: "The DWG couldn't be read."))
        XCTAssertEqual(stage(.failed, seen: -1000), .failed(reason: "The DWG couldn't be read."))
        // Done: downloading, or plotted but offline, then the PDF is on the Duo.
        XCTAssertEqual(stage(.done), .downloading)
        XCTAssertEqual(stage(.done, seen: -1000), .downloading)
        XCTAssertEqual(stage(.done, online: false), .plottedOffline)
        XCTAssertEqual(stage(.done, kept: true), .done)
        // The row's words and the steps.
        XCTAssertEqual(PlotStage.queuedOnThisDuo.shortText, "Queued on this Duo")
        XCTAssertEqual(PlotStage.plotting.shortText, "Plotting on the laptop…")
        XCTAssertEqual(PlotStage.waitingForLaptop(lastSeen: nil).shortText, "Waiting for the laptop")
        XCTAssertEqual([PlotStage.asking, .plotting, .downloading].map(\.step), [0, 1, 2])
        XCTAssertEqual(PlotStage.lastSeenText(t0.addingTimeInterval(-20), now: t0), "a moment ago")
        XCTAssertEqual(PlotStage.lastSeenText(t0.addingTimeInterval(-720), now: t0), "12 min ago")
        XCTAssertEqual(PlotStage.lastSeenText(t0.addingTimeInterval(-3 * 3600), now: t0), "3 h ago")
    }

    func testADoneAnswersWarningAndFallbackMakeOneShortLine() throws {
        let plain = try XCTUnwrap(PlotAnswer.read(Laptop.answer("r", "e", "done", pdf: "/Vellum/Plots/x.pdf", hash: "h")))
        XCTAssertNil(plain.note)
        let missing = try XCTUnwrap(PlotAnswer.read(Laptop.answer(
            "r", "e", "done", pdf: "/Vellum/Plots/x.pdf", hash: "h", missing: 2,
            warning: "2 references couldn't be found, so the PDF is missing them")))
        XCTAssertEqual(missing.note, "2 references couldn't be found, so the PDF is missing them.")
        let fallback = try XCTUnwrap(PlotAnswer.read(Laptop.answer(
            "r", "e", "done", pdf: "/Vellum/Plots/x.pdf", hash: "h", pageSetup: "fallback",
            reason: "plotted with DWG To PDF on ANSI D, since the layout's own plotter isn't a PDF one")))
        XCTAssertEqual(fallback.note, "Plotted with DWG To PDF on ANSI D, since the layout's own plotter isn't a PDF one.")
        // An answer in another format, or a state this Vellum doesn't know, is no answer yet.
        XCTAssertNil(PlotAnswer.read(Array(#"{"format": 2, "state": "done"}"#.utf8)))
        XCTAssertNil(PlotAnswer.read(Array(#"{"format": 1, "state": "paused"}"#.utf8)))
    }

    // MARK: Asking and waiting

    func testAPlotIsAskedForWatchedDownloadedOnceAndOnlyThenItsRequestDeleted() async throws {
        let rig = try Rig(t0, test: self)
        let entry = IndexFixture.entry("E-201")
        let pdfBytes = Array("%PDF-1.4 made-up plot of E-201 (example)\n%%EOF\n".utf8)
        let pdfPath = "/Vellum/Plots/Made-up Plant Upgrade/E-201 - Layout1 - 2026-09-21 141500 - 5c0e1d2a.pdf"
        let hash = DropboxContentHash.of(pdfBytes)
        rig.onLook { time in
            if time == t0.addingTimeInterval(5) { rig.laptop.answerAll("queued") }
            if time == t0.addingTimeInterval(10) { rig.laptop.answerAll("plotting") }
            if time == t0.addingTimeInterval(20) {
                rig.dropbox.changeOnTheLaptop(pdfPath, to: pdfBytes)
                rig.laptop.answerAll("done", pdf: pdfPath, hash: hash)
            }
        }
        await rig.watch.start()
        let asked = await rig.watch.ask(entry)
        XCTAssertEqual(asked?.stage, .asking)
        await rig.watch.settled()

        let requests = rig.dropbox.requests
        let request = try XCTUnwrap(requests.first).replacingOccurrences(of: "upload ", with: "")
        XCTAssertTrue(PlotRequestFormat.isRequestPath(request))
        XCTAssertEqual(requests.filter { $0.hasPrefix("upload") }, ["upload \(request)"], "one request, written once")
        XCTAssertEqual(requests.filter { $0 == "download \(pdfPath)" }.count, 1, "the PDF downloaded once")
        let downloaded = try XCTUnwrap(requests.firstIndex(of: "download \(pdfPath)"))
        let deleted = try XCTUnwrap(requests.firstIndex(of: "delete \(request)"))
        XCTAssertLessThan(downloaded, deleted, "the request is deleted after the PDF is down, never before")
        XCTAssertEqual(requests.last, "delete \(request)", "nothing after: the watch has stopped")
        XCTAssertTrue(requests.allSatisfy { !$0.hasPrefix("delete") || $0 == "delete \(request)" })
        // Through the app's SheetPDFs, under the answer's content hash.
        let keptName = SheetPDFs.keptName(contentHash: hash, rev: "")
        XCTAssertTrue(rig.pdfs.holds(keptName: keptName, size: pdfBytes.count))
        XCTAssertEqual(rig.pdfs.bytesDownloaded, pdfBytes.count)
        XCTAssertEqual(rig.pdfs.keptName(forPath: pdfPath), keptName)
        // The answer is the laptop's to delete; the request is gone.
        XCTAssertNotNil(rig.dropbox.allFiles[request.replacingOccurrences(of: ".json", with: ".answer.json")])
        XCTAssertNil(rig.dropbox.allFiles[request])
        // The plot is kept for the entry until the index lists it, so the row never says "No PDF yet" meanwhile.
        let ledger = await rig.watch.ledgerNow
        XCTAssertTrue(ledger.open.isEmpty)
        XCTAssertEqual(ledger.plotted[entry.id], PlottedPDF(path: pdfPath, contentHash: hash, keptName: keptName, note: nil))
        let done = await rig.watch.current[entry.id]
        XCTAssertEqual(done?.stage, .done)
        XCTAssertEqual(done?.keptName, keptName)
        // The stages the app heard, in order.
        XCTAssertEqual(rig.reports.stages(entry.id).removingRepeats, [.asking, .plotting, .downloading, .done])
        await rig.watch.indexLists(pdfsFor: [entry.id])
        let forgotten = await rig.watch.current[entry.id]
        XCTAssertNil(forgotten)
        // Waiting has stopped: nothing open, so nothing more is asked of Dropbox.
        let watching = await rig.watch.isWatching
        XCTAssertFalse(watching)
        let count = rig.dropbox.requests.count
        await rig.watch.setOnline(false)
        await rig.watch.setOnline(true)
        await rig.watch.settled()
        XCTAssertEqual(rig.dropbox.requests.count, count)
        PlotBudget.check("plot_request_uploads_per_ask", requests.filter { $0.hasPrefix("upload") }.count)
        PlotBudget.check("plot_request_bytes", rig.dropbox.bytesUploaded)
        PlotBudget.check("plot_pdf_downloads_per_plot", requests.filter { $0 == "download \(pdfPath)" }.count)
    }

    func testADoneWithAWarningKeepsItsLine() async throws {
        let rig = try Rig(t0, test: self)
        let entry = IndexFixture.entry("M-102")
        let pdfBytes = Array("%PDF-1.4 made-up plot of M-102 (example)\n%%EOF\n".utf8)
        let pdfPath = "/Vellum/Plots/Made-up School Addition/M-102 - Layout1 - 2026-09-21 141500 - 0a1b2c3d.pdf"
        rig.onLook { time in
            if time == t0.addingTimeInterval(5) {
                rig.dropbox.changeOnTheLaptop(pdfPath, to: pdfBytes)
                rig.laptop.answerAll("done", pdf: pdfPath, hash: DropboxContentHash.of(pdfBytes), missing: 2,
                                     warning: "2 references couldn't be found, so the PDF is missing them")
            }
        }
        await rig.watch.start()
        await rig.watch.ask(entry)
        await rig.watch.settled()
        let done = await rig.watch.current[entry.id]
        XCTAssertEqual(done?.stage, .done)
        XCTAssertEqual(done?.note, "2 references couldn't be found, so the PDF is missing them.")
    }

    func testTheRequestIsNeverDeletedBeforeThePDFIsDown() async throws {
        let rig = try Rig(t0, test: self)
        let entry = IndexFixture.entry("E-201")
        let pdfBytes = Array("%PDF-1.4 made-up (example)\n%%EOF\n".utf8)
        let pdfPath = "/Vellum/Plots/Made-up Plant Upgrade/E-201 - Layout1 - x.pdf"
        rig.onLook { time in
            // Done, but its PDF not in Dropbox yet: the download fails, and the request must stay.
            if time == t0.addingTimeInterval(5) {
                rig.laptop.answerAll("done", pdf: pdfPath, hash: DropboxContentHash.of(pdfBytes))
            }
            if time > t0.addingTimeInterval(5), rig.dropbox.allFiles[pdfPath] == nil {
                XCTAssertFalse(rig.dropbox.requests.contains { $0.hasPrefix("delete") })
                XCTAssertEqual(rig.dropbox.allFiles.keys.filter { PlotRequestFormat.isRequestPath($0) }.count, 1)
                rig.dropbox.changeOnTheLaptop(pdfPath, to: pdfBytes)
            }
        }
        await rig.watch.start()
        await rig.watch.ask(entry)
        await rig.watch.settled()
        let requests = rig.dropbox.requests
        let deleted = try XCTUnwrap(requests.firstIndex { $0.hasPrefix("delete") })
        let downloads = requests.indices.filter { requests[$0] == "download \(pdfPath)" }
        XCTAssertGreaterThanOrEqual(downloads.count, 2, "tried, failed, tried again")
        XCTAssertLessThan(downloads.last!, deleted)
        XCTAssertEqual(rig.pdfs.bytesDownloaded, pdfBytes.count, "kept once")
    }

    func testOfflineTheRequestWaitsOnThisDuoThroughARelaunchAndGoesWhenOnline() async throws {
        let rig = try Rig(t0, test: self)
        let entry = IndexFixture.entry("E-201")
        await rig.watch.setOnline(false)
        await rig.watch.start()
        let asked = await rig.watch.ask(entry)
        XCTAssertEqual(asked?.stage, .queuedOnThisDuo)
        await rig.watch.settled()
        XCTAssertTrue(rig.dropbox.requests.isEmpty, "nothing tried offline")
        XCTAssertEqual(rig.ledger.load().open.map(\.sent), [nil], "kept in the outbox on the Duo")

        // The app is killed and launched again, still offline: the request is still queued.
        let relaunched = try Rig(t0, test: self, dropbox: rig.dropbox, ledger: rig.ledger, pdfs: rig.pdfs)
        relaunched.onLook { time in
            if time == t0.addingTimeInterval(5) { relaunched.laptop.answerAll("failed", reason: "the DWG couldn't be read") }
        }
        await relaunched.watch.setOnline(false)
        await relaunched.watch.start()
        let queued = await relaunched.watch.current[entry.id]
        XCTAssertEqual(queued?.stage, .queuedOnThisDuo)
        // Asking again offline reuses it.
        let again = await relaunched.watch.ask(entry)
        XCTAssertEqual(again?.request, asked?.request)
        XCTAssertEqual(relaunched.ledger.load().open.count, 1)

        await relaunched.watch.setOnline(true)
        await relaunched.watch.settled()
        let uploads = rig.dropbox.requests.filter { $0.hasPrefix("upload") }
        XCTAssertEqual(uploads, ["upload \(PlotRequestFormat.requestPath(asked!.request))"])
        XCTAssertEqual(relaunched.reports.stages(entry.id).removingRepeats.first, .queuedOnThisDuo)
        XCTAssertTrue(relaunched.reports.stages(entry.id).contains(.asking), "sent")
    }

    func testAStaleCheckInIsWaitingForTheLaptopUntilItIsBack() async throws {
        let rig = try Rig(t0, test: self)
        let entry = IndexFixture.entry("E-201")
        let off = t0.addingTimeInterval(-720)
        rig.dropbox.changeOnTheLaptop(PlotRequestFormat.checkInPath, to: Laptop.checkIn, at: off)
        rig.onLook { time in
            if time == t0.addingTimeInterval(5) {
                let waiting = await rig.watch.current[entry.id]
                XCTAssertEqual(waiting?.stage, .waitingForLaptop(lastSeen: off))
                // The laptop comes back: it checks in and answers.
                rig.dropbox.changeOnTheLaptop(PlotRequestFormat.checkInPath, to: Laptop.checkIn, at: time)
                rig.laptop.answerAll("queued")
            }
            if time == t0.addingTimeInterval(10) {
                let plotting = await rig.watch.current[entry.id]
                XCTAssertEqual(plotting?.stage, .plotting)
                rig.laptop.answerAll("failed", reason: "the layout isn't in the DWG any more")
            }
        }
        await rig.watch.start()
        await rig.watch.ask(entry)
        await rig.watch.settled()
        XCTAssertEqual(rig.reports.stages(entry.id).removingRepeats,
                       [.asking, .waitingForLaptop(lastSeen: off), .plotting, .failed(reason: "The layout isn't in the DWG any more.")])
    }

    func testAFailureSaysTheLaptopsReasonAndAskingAgainIsANewRequest() async throws {
        let rig = try Rig(t0, test: self)
        let entry = IndexFixture.entry("E-201")
        let pdfBytes = Array("%PDF-1.4 made-up (example)\n%%EOF\n".utf8)
        let pdfPath = "/Vellum/Plots/Made-up Plant Upgrade/E-201 - Layout1 - y.pdf"
        rig.onLook { time in
            if time == t0.addingTimeInterval(5) {
                rig.laptop.answerAll("failed", reason: "timed out: AutoCAD took longer than 5 minutes, so the plot was stopped")
            }
        }
        await rig.watch.start()
        let first = await rig.watch.ask(entry)
        await rig.watch.settled()
        let failed = await rig.watch.current[entry.id]
        XCTAssertEqual(failed?.stage,
                       .failed(reason: "Timed out: AutoCAD took longer than 5 minutes, so the plot was stopped."))
        let firstPath = PlotRequestFormat.requestPath(first!.request)
        XCTAssertTrue(rig.dropbox.requests.contains("delete \(firstPath)"), "read a final answer: request deleted")
        XCTAssertNotNil(rig.dropbox.allFiles[PlotRequestFormat.answerPath(first!.request)], "the answer stays")

        // Ask again: a new request, a new name.
        rig.onLook { _ in
            rig.dropbox.changeOnTheLaptop(pdfPath, to: pdfBytes)
            rig.laptop.answerAll("done", pdf: pdfPath, hash: DropboxContentHash.of(pdfBytes))
        }
        let second = await rig.watch.ask(entry)
        XCTAssertNotEqual(second?.request, first?.request)
        XCTAssertEqual(second?.stage, .asking)
        await rig.watch.settled()
        let done = await rig.watch.current[entry.id]
        XCTAssertEqual(done?.stage, .done)
        let ledger = await rig.watch.ledgerNow
        XCTAssertNil(ledger.failed[entry.id])
        XCTAssertEqual(rig.dropbox.requests.filter { $0.hasPrefix("upload") }.count, 2)
    }

    func testOneRequestPerEntryWhileOpenAndTwoDuosNeverCollide() async throws {
        let rig = try Rig(t0, test: self)
        let entry = IndexFixture.entry("E-201")
        await rig.watch.start()
        let first = await rig.watch.ask(entry)
        let second = await rig.watch.ask(entry)
        XCTAssertEqual(first?.request, second?.request)
        let other = await rig.watch.ask(IndexFixture.entry("M-102"))
        XCTAssertNotEqual(other?.request, first?.request)
        rig.onLook { _ in await rig.watch.setActive(false) }
        await rig.watch.settled()
        XCTAssertEqual(rig.dropbox.requests.filter { $0.hasPrefix("upload") }.count, 2, "one per entry")

        // A second Duo on the same Dropbox asks for the same drawing: its own file, no conflict.
        let duo = try Rig(t0, test: self, dropbox: rig.dropbox)
        duo.onLook { _ in await duo.watch.setActive(false) }
        await duo.watch.start()
        let theirs = await duo.watch.ask(entry)
        await duo.watch.settled()
        XCTAssertNotEqual(theirs?.request, first?.request)
        XCTAssertEqual(rig.dropbox.allFiles.keys.filter { PlotRequestFormat.isRequestPath($0) }.count, 3)
        // Fresh UUIDs, so no two taps on any Duo share a name, and every one is a name the laptop takes.
        var names = Set<String>()
        for _ in 0..<2000 {
            let request = PlotRequest.asking(for: entry, at: t0)!
            XCTAssertTrue(PlotRequestFormat.isRequestPath(request.dropboxPath))
            names.insert(request.request)
        }
        XCTAssertEqual(names.count, 2000)
    }

    func testWaitingLooksQuicklyAtFirstThenSlowlyAndStopsWhenNothingIsOpen() async throws {
        let rig = try Rig(t0, test: self)
        let samples = Box<[(Double, Int)]>([])
        rig.onLook { time in
            let seconds = time.timeIntervalSince(t0)
            // The laptop keeps checking in every 2 minutes, and never answers.
            if Int(seconds) % 120 == 0 {
                rig.dropbox.changeOnTheLaptop(PlotRequestFormat.checkInPath, to: Laptop.checkIn, at: time)
            }
            samples.change { $0.append((seconds, rig.dropbox.requests.count)) }
            if seconds >= 600 { await rig.watch.setActive(false) }
        }
        await rig.watch.start()
        await rig.watch.ask(IndexFixture.entry("E-201"))
        await rig.watch.settled()
        let taken = samples.value
        func requests(from start: Double, to end: Double) -> Int {
            let a = taken.first { $0.0 == start }!.1
            let b = taken.first { $0.0 == end }!.1
            return b - a
        }
        let quick = requests(from: 60, to: 120)
        let slow = requests(from: 300, to: 360)
        XCTAssertEqual(quick, 13, "12 answer looks and one check-in a minute while the request is new")
        XCTAssertEqual(slow, 3, "2 answer looks and one check-in a minute after that")
        let waits = await rig.watch.waits
        XCTAssertEqual(Set(waits), [PlotWatch.quickLook, PlotWatch.slowLook])
        PlotBudget.check("plot_wait_requests_per_minute_first_2_min", quick)
        PlotBudget.check("plot_wait_requests_per_minute_after", slow)

        // Off the screen it doesn't look; and with nothing open it never starts.
        let count = rig.dropbox.requests.count
        await rig.watch.setOnline(false)
        await rig.watch.setOnline(true)
        XCTAssertEqual(rig.dropbox.requests.count, count)
        let idle = try Rig(t0, test: self, dropbox: MadeUpDropbox())
        await idle.watch.start()
        await idle.watch.settled()
        let watching = await idle.watch.isWatching
        XCTAssertFalse(watching)
        XCTAssertTrue(idle.dropbox.requests.isEmpty)
    }
}

// MARK: - The rig

/// A made-up Dropbox, a plot watch on it with a made-up clock, and the laptop played by the test. Each wait between
/// looks moves the clock on by the wait and then runs `onLook` with the new time, before the next look.
private final class Rig: @unchecked Sendable {
    let dropbox: MadeUpDropbox
    let session: DropboxSession
    let ledger: PlotLedgerMemory
    let pdfs: SheetPDFs
    let laptop: Laptop
    let reports = Reports()
    private(set) var watch: PlotWatch!
    private let lock = NSLock()
    private let start: Date
    private var time: Date
    private var look: (@Sendable (Date) async -> Void)?

    init(_ start: Date, test: XCTestCase, dropbox: MadeUpDropbox? = nil, ledger: PlotLedgerMemory? = nil,
         pdfs: SheetPDFs? = nil) throws {
        self.start = start
        time = start
        let dropbox = dropbox ?? MadeUpDropbox()
        self.dropbox = dropbox
        self.ledger = ledger ?? PlotLedgerMemory()
        if let pdfs {
            self.pdfs = pdfs
        } else {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-plots-\(UUID().uuidString)")
            test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            self.pdfs = SheetPDFs(folder: folder)
        }
        laptop = Laptop(dropbox)
        let key = DropboxAppKey(buildSetting: "madeupplotkey01")!
        let tokens = DropboxTokens(accessToken: "made-up", refreshToken: "made-up", expiresAt: .distantFuture)
        session = DropboxSession(appKey: key, transport: dropbox, store: DropboxMemoryTokenStore(tokens))
        dropbox.clock = { [unowned self] in self.now }
        if dropbox.allFiles[PlotRequestFormat.checkInPath] == nil {
            dropbox.changeOnTheLaptop(PlotRequestFormat.checkInPath, to: Laptop.checkIn, at: start.addingTimeInterval(-30))
        }
        let reports = self.reports
        watch = PlotWatch(session: session, ledger: self.ledger, pdfs: self.pdfs,
                          sleep: { [unowned self] seconds in await self.wait(seconds) },
                          now: { [unowned self] in self.now },
                          report: { reports.add($0) })
    }

    var now: Date { lock.withLock { time } }

    func onLook(_ look: @escaping @Sendable (Date) async -> Void) { lock.withLock { self.look = look } }

    private func wait(_ seconds: Double) async {
        let (now, look) = lock.withLock { () -> (Date, (@Sendable (Date) async -> Void)?) in
            time = time.addingTimeInterval(seconds)
            return (time, self.look)
        }
        await look?(now)
        // However a test goes, the watch stops within a made-up day.
        if now.timeIntervalSince(start) > 86400 { await watch.setActive(false) }
    }
}

/// Every report the app would hear.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[String: PlotProgress]] = []

    func add(_ report: [String: PlotProgress]) { lock.withLock { all.append(report) } }

    func stages(_ entry: String) -> [PlotStage] { lock.withLock { all.compactMap { $0[entry]?.stage } } }
}

/// The laptop indexer's side, as `plot_requests.py` writes it: an answer beside each request, and the check-in.
private final class Laptop: @unchecked Sendable {
    let dropbox: MadeUpDropbox

    init(_ dropbox: MadeUpDropbox) { self.dropbox = dropbox }

    static let checkIn = Array(#"{"every": 120, "format": 1, "indexer": "1.1.0", "seen": "2026-11-07T12:00:00Z", "staleAfter": 300}"#.utf8)

    /// Answers every request in `requests/` with `state`, as `Answer.to_json` writes it.
    func answerAll(_ state: String, pdf: String? = nil, hash: String? = nil, pageSetup: String? = nil,
                   reason: String? = nil, missing: Int? = nil, warning: String? = nil) {
        for (name, bytes) in dropbox.files(in: PlotRequestFormat.requestsFolder) {
            guard name.hasSuffix(".json"), !name.hasSuffix(".answer.json"),
                  let body = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { continue }
            let request = String(name.dropLast(".json".count))
            dropbox.changeOnTheLaptop(PlotRequestFormat.answerPath(request), to: Self.answer(
                request, body["id"] as? String, state, pdf: pdf, hash: hash,
                pageSetup: pageSetup ?? (state == "done" ? "saved" : nil), reason: reason,
                missing: missing ?? (state == "done" ? 0 : nil), warning: warning))
        }
    }

    static func answer(_ request: String, _ id: String?, _ state: String, pdf: String? = nil, hash: String? = nil,
                       pageSetup: String? = nil, reason: String? = nil, missing: Int? = nil,
                       warning: String? = nil) -> [UInt8] {
        func json(_ value: Any?) -> Any { value ?? NSNull() }
        let object: [String: Any] = [
            "format": 1, "request": request, "id": json(id), "state": state, "updated": "2026-11-07T12:00:09Z",
            "pdf": json(pdf), "contentHash": json(hash), "pageSetup": json(pageSetup),
            "reason": json(reason), "missingReferences": json(missing), "warning": json(warning),
        ]
        return [UInt8]((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
    }
}

/// `decode` and `request_name` in `laptop/src/vellum_indexer/plot_requests.py`, as docs/plot-requests.md states them:
/// the reason the laptop would refuse a request, or nil when it would take it.
private enum LaptopRules {
    static func refusal(name: String, data: [UInt8]) -> String? {
        if name.hasSuffix(".answer.json") || !matches(name, #"^[A-Za-z0-9][A-Za-z0-9-]{7,63}\.json$"#) {
            return "not a request's name"
        }
        if data.count > 4096 { return "too big" }
        guard let body = try? JSONSerialization.jsonObject(with: Data(data)) as? [String: Any] else { return "unreadable" }
        guard (body["format"] as? NSNumber)?.intValue == 1 else { return "format" }
        guard let id = body["id"] as? String, text(id, 16), matches(id, "^[0-9a-f]{16}$") else { return "id" }
        guard let path = body["path"] as? String, text(path, 1024) else { return "path" }
        guard path.hasPrefix("/"), path.lowercased().hasSuffix(".dwg") else { return "no DWG" }
        if path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." })
            || path.contains("\\") { return "path" }
        if let layout = body["layout"], !(layout is NSNull) {
            guard let layout = layout as? String, text(layout, 255) else { return "layout" }
        }
        guard let asked = body["asked"] as? String, text(asked, 40),
              matches(asked, #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$"#) else { return "asked" }
        return nil
    }

    private static func text(_ value: String, _ limit: Int) -> Bool {
        !value.isEmpty && value.count <= limit
            && !value.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// A value shared with the rig's closures.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Value

    init(_ value: Value) { held = value }

    var value: Value { lock.withLock { held } }
    func change(_ body: (inout Value) -> Void) { lock.withLock { body(&held) } }
}

private extension Array where Element: Equatable {
    var removingRepeats: [Element] {
        var out: [Element] = []
        for element in self where out.last != element { out.append(element) }
        return out
    }
}

// MARK: - Baselines (docs/perf/baselines/plot-requests.json)

enum PlotBudget {
    struct Entry: Decodable {
        let metric: String
        let kind: String
        let value: Double
        let unit: String
    }

    static let all: [String: Entry] = {
        struct File: Decodable { let entries: [Entry] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../docs/perf/baselines/plot-requests.json").standardizedFileURL
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [:] }
        return Dictionary(file.entries.map { ($0.metric, $0) }) { $1 }
    }()

    static func check(_ metric: String, _ measured: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = all[metric], entry.kind == "count" else {
            return XCTFail("no count baseline named \(metric) in docs/perf/baselines/plot-requests.json (measured \(measured))",
                           file: file, line: line)
        }
        print("PERF plot-requests \(metric)=\(measured) \(entry.unit) (budget \(Int(entry.value)))")
        XCTAssertLessThanOrEqual(Double(measured), entry.value,
                                 "\(metric) is over its budget in docs/perf/baselines/plot-requests.json", file: file, line: line)
        if Double(measured) < entry.value {
            print("PERF plot-requests \(metric) came in under its budget: lower it in docs/perf/baselines/plot-requests.json")
        }
    }
}
