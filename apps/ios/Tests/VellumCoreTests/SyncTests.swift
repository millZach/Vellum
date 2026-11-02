import Foundation
import XCTest
@testable import VellumCore

// Every canvas, stroke, PDF, name, key and token here is made up for the test.
private let syncKey = DropboxAppKey(buildSetting: "madeupsynckey01")!
private let syncTokens = DropboxTokens(accessToken: "made-up", refreshToken: "made-up", expiresAt: .distantFuture)

/// The last report the sync engine gave.
final class SyncReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [SyncReport] = []
    func add(_ report: SyncReport) { lock.withLock { reports.append(report) } }
    var last: SyncReport? { lock.withLock { reports.last } }
    func state(_ id: UUID) -> CanvasSyncState? { last?.state(of: id) }
}

/// Syncing canvases to Dropbox (#12), through the app's savers and the made-up Dropbox behind the live client's
/// transport seam.
final class SyncTests: XCTestCase {
    private var root: URL!
    private var library: CanvasLibrary!
    private var savers: CanvasSavers!
    private var dropbox: MadeUpDropbox!
    private var reports: SyncReports!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-sync-\(UUID().uuidString)")
        library = CanvasLibrary(root: root.appendingPathComponent("Canvases"))
        savers = CanvasSavers(library: library, clock: VirtualClock())
        dropbox = MadeUpDropbox()
        reports = SyncReports()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func engine(ledger: any SyncLedgerStore = SyncLedgerMemory(), tokens: DropboxTokens? = syncTokens,
                        sleep: @escaping @Sendable (Double) async -> Void = { _ in }) -> (CanvasSync, DropboxSession) {
        let session = DropboxSession(appKey: syncKey, transport: dropbox, store: DropboxMemoryTokenStore(tokens))
        let reports = reports!
        let sync = CanvasSync(session: session, source: savers, ledger: ledger, sleep: sleep,
                              report: { reports.add($0) })
        return (sync, session)
    }

    /// Draws strokes on a canvas through its saver, as the canvas screen does, and leaves it.
    private func draw(_ range: Range<Int>, on id: UUID) async throws {
        let (_, opened, saver) = try await savers.open(id)
        var session = opened
        for i in range {
            session.draw(CanvasSaverTests.wave(i), tool: .pen, colour: .red, width: .inches(0.5))
            saver.save(session.takeEvents())
        }
        savers.close(saver)
        await saver.idle()
    }

    private func duoFile(_ id: UUID, _ name: String) throws -> [UInt8]? {
        try DurableFile.read(library.folder(for: id).appendingPathComponent(name))
    }

    private func folder(_ sync: CanvasSync, _ id: UUID) async -> String {
        await sync.ledgerNow[id]?.folder ?? "?"
    }

    /// Rebuilds the canvas from what the made-up Dropbox holds, as the laptop does, and checks it is the Duo's canvas
    /// byte for byte, and opens to the same ink.
    private func assertDropboxRebuildsTheDuosCanvas(_ sync: CanvasSync, _ id: UUID,
                                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let files = dropbox.files(in: SyncPaths.folder(await folder(sync, id)))
        let rebuilt = try SyncedCanvasFolder.rebuild(files)
        XCTAssertEqual(rebuilt.manifest, try duoFile(id, CanvasManifest.fileName), file: file, line: line)
        XCTAssertEqual(rebuilt.snapshot, try duoFile(id, InkStore.snapshotName), file: file, line: line)
        XCTAssertEqual(rebuilt.log, try duoFile(id, InkStore.logName), "the log reassembled from its parts", file: file, line: line)
        let copy = root.appendingPathComponent("laptop-\(UUID().uuidString)")
        try SyncedCanvasFolder.write(rebuilt, to: copy)
        XCTAssertEqual(try InkStore(folder: copy).session, try InkStore(folder: library.folder(for: id)).session,
                       "the laptop's copy opens to exactly the Duo's ink and undo history", file: file, line: line)
    }

    // MARK: Folder names

    func testFolderNamesAreTheNameAndAShortIDMadeSafeForDropboxAndWindows() {
        let id = UUID(uuidString: "7F3A0000-0000-4000-8000-000000000001")!
        XCTAssertEqual(SyncFolderName.make(name: "Boiler 4 walkdown", id: id), "Boiler 4 walkdown 7f3a")
        XCTAssertEqual(SyncFolderName.safeName("Valve: A/B <check> \"1\" | 2? *"), "Valve- A-B -check- -1- - 2- -")
        XCTAssertEqual(SyncFolderName.safeName("Trailing dots... "), "Trailing dots")
        XCTAssertEqual(SyncFolderName.safeName("..hidden"), "hidden")
        XCTAssertEqual(SyncFolderName.safeName(".deleted"), "deleted", "never the deleted canvases' folder")
        XCTAssertEqual(SyncFolderName.safeName("  two\tlines\nhere  "), "two lines here")
        XCTAssertEqual(SyncFolderName.safeName("bell\u{07}"), "bell-")
        XCTAssertEqual(SyncFolderName.safeName(" ... "), "Canvas")
        XCTAssertEqual(SyncFolderName.safeName("Café"), "Café")
        let long = String(repeating: "Feedwater ", count: 20)
        XCTAssertEqual(SyncFolderName.safeName(long).count, 59, "cut to 60 and its trailing space dropped")
        let wide = String(repeating: "🔧", count: 70)
        XCTAssertLessThanOrEqual(SyncFolderName.safeName(wide).utf8.count, SyncFolderName.maximumBytes)
    }

    func testASecondCanvasOfTheSameNameAndShortIDGetsALongerOne() {
        let id = UUID(uuidString: "7F3A1B2C-0000-4000-8000-000000000001")!
        XCTAssertEqual(SyncFolderName.make(name: "Site", id: id, taken: ["site 7F3A"]), "Site 7f3a1b")
        XCTAssertEqual(SyncFolderName.make(name: "Site", id: id, taken: ["Other 7f3a"]), "Site 7f3a")
    }

    func testANewCanvasFixesItsFolderAndARenameNeverMovesIt() async throws {
        let made = try library.create(name: "Boiler 4 walkdown")
        let fixed = try XCTUnwrap(library.manifest(for: made.id).dropboxFolder)
        XCTAssertTrue(fixed.hasPrefix("Boiler 4 walkdown "))
        let (sync, _) = engine()
        await sync.start()
        await sync.settled()
        _ = try library.rename(made.id, to: "Boiler 4 after the outage")
        dropbox.resetCounts()
        await sync.canvasChanged(made.id)
        await sync.settled()
        XCTAssertEqual(try library.manifest(for: made.id).dropboxFolder, fixed, "the folder name stays put")
        XCTAssertEqual(dropbox.requests, ["upload /Vellum/\(fixed)/canvas.json"], "a rename uploads canvas.json only")
        XCTAssertEqual(dropbox.folders(in: "/Vellum"), [fixed])
        let json = String(decoding: dropbox.files(in: "/Vellum/\(fixed)")["canvas.json"] ?? [], as: UTF8.self)
        XCTAssertTrue(json.contains("Boiler 4 after the outage"), "the current name lives in canvas.json")
    }

    func testACanvasMadeBeforeSyncTakesItsNameAtItsFirstSync() async throws {
        let made = try library.create(name: "Old canvas")
        // As a canvas made before #12: no folder in its canvas.json.
        var manifest = try library.manifest(for: made.id)
        manifest.dropboxFolder = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: library.folder(for: made.id).appendingPathComponent("canvas.json"))
        _ = try library.rename(made.id, to: "Renamed before its first sync")
        let (sync, _) = engine()
        await sync.start()
        await sync.settled()
        let folder = await folder(sync, made.id)
        XCTAssertTrue(folder.hasPrefix("Renamed before its first sync "), folder)
        _ = try library.rename(made.id, to: "Renamed again")
        await sync.canvasChanged(made.id)
        await sync.settled()
        let after = await self.folder(sync, made.id)
        XCTAssertEqual(after, folder, "fixed at its first sync")
        XCTAssertEqual(dropbox.folders(in: "/Vellum"), [folder])
    }

    func testANameBeyondASCIIGoesInTheHeaderEscaped() throws {
        let header = try XCTUnwrap(DropboxSession.apiArgument(["path": "/Vellum/Café 🔧 7f3a/canvas.json"]))
        XCTAssertTrue(header.allSatisfy(\.isASCII), header)
        XCTAssertTrue(header.contains("Caf\\u00e9"), header)
        let decoded = try JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: String]
        XCTAssertEqual(decoded?["path"], "/Vellum/Café 🔧 7f3a/canvas.json")
    }

    // MARK: Only what changed

    func testSyncsUploadOnlyWhatChanged() async throws {
        let id = try library.create(name: "Delta").id
        try await draw(0..<20, on: id)
        let (sync, _) = engine()
        await sync.start()
        await sync.settled()
        let folder = "/Vellum/\(await self.folder(sync, id))"
        XCTAssertEqual(Set(dropbox.requests), ["upload \(folder)/canvas.json",
                                                "upload \(folder)/ink.log.parts/0/000000000000.part"],
                       "a first sync: canvas.json and the whole log as one part")
        try await assertDropboxRebuildsTheDuosCanvas(sync, id)

        // Nothing changed: nothing is asked.
        dropbox.resetCounts()
        await sync.canvasLeft(id)
        await sync.settled()
        XCTAssertEqual(dropbox.requests, [])
        SyncBudget.check("requests-no-change", dropbox.requests.count)

        // New strokes: the log's new tail, one part.
        let before = try XCTUnwrap(duoFile(id, InkStore.logName)).count
        try await draw(20..<30, on: id)
        let after = try XCTUnwrap(duoFile(id, InkStore.logName)).count
        dropbox.resetCounts()
        await sync.canvasLeft(id)
        await sync.settled()
        XCTAssertEqual(dropbox.requests, ["upload \(folder)/\(SyncPlan.logPartFile(generation: 0, offset: before))"])
        SyncBudget.check("requests-after-new-strokes", dropbox.requests.count)
        SyncBudget.check("bytes-beyond-log-tail-after-new-strokes", dropbox.bytesUploaded - (after - before))
        print("PERF sync bytes-after-10-strokes=\(dropbox.bytesUploaded) bytes (the log tail, \(after - before) bytes)")
        try await assertDropboxRebuildsTheDuosCanvas(sync, id)
    }

    func testACompactionUploadsItsSnapshotOnceAndDropsTheOldParts() async throws {
        let id = try library.create(name: "Compacted").id
        try await draw(0..<40, on: id)
        let (sync, _) = engine()
        await sync.start()
        await sync.settled()
        try await draw(40..<60, on: id)
        await sync.canvasLeft(id)
        await sync.settled()
        let folder = "/Vellum/\(await self.folder(sync, id))"
        XCTAssertEqual(dropbox.folders(in: "\(folder)/ink.log.parts"), ["0"])

        // The canvas is closed and its saver has let go, so compacting it here is what the saver would do.
        let store = try library.openInk(id)
        try store.compact()
        store.closeFiles()
        try await draw(60..<62, on: id)
        let snapshot = try XCTUnwrap(duoFile(id, InkStore.snapshotName))
        let log = try XCTUnwrap(duoFile(id, InkStore.logName))
        dropbox.resetCounts()
        await sync.canvasLeft(id)
        await sync.settled()
        XCTAssertEqual(dropbox.requests, ["upload \(folder)/ink.log.parts/1/000000000000.part",
                                          "upload \(folder)/ink.snapshot",
                                          "delete \(folder)/ink.log.parts/0"],
                       "the new log's first part, then the snapshot that needs it, then the replaced parts")
        SyncBudget.check("requests-after-compaction", dropbox.requests.count)
        SyncBudget.check("bytes-beyond-snapshot-and-new-log-after-compaction",
                         dropbox.bytesUploaded - snapshot.count - log.count)
        XCTAssertEqual(dropbox.folders(in: "\(folder)/ink.log.parts"), ["1"])
        try await assertDropboxRebuildsTheDuosCanvas(sync, id)

        // The snapshot goes once.
        try await draw(62..<64, on: id)
        dropbox.resetCounts()
        await sync.canvasLeft(id)
        await sync.settled()
        XCTAssertEqual(dropbox.requests.count, 1)
        XCTAssertFalse(dropbox.requests.contains { $0.hasSuffix("ink.snapshot") })
        try await assertDropboxRebuildsTheDuosCanvas(sync, id)
    }

    func testASheetsPDFUploadsOnceEver() async throws {
        let id = try library.create(name: "With a sheet").id
        let pdf = root.appendingPathComponent("made-up.pdf")
        try Data("%PDF-1.7 made-up sheet for the test".utf8).write(to: pdf)
        try library.keepSheetPDF(from: pdf, named: "madeuphash01", in: id)
        let (sync, _) = engine()
        await sync.start()
        await sync.settled()
        let folder = "/Vellum/\(await self.folder(sync, id))"
        SyncBudget.check("sheet-pdf-uploads-first-sync",
                         dropbox.requests.filter { $0 == "upload \(folder)/sheets/madeuphash01.pdf" }.count)
        XCTAssertEqual(dropbox.files(in: folder)["sheets/madeuphash01.pdf"], [UInt8](try Data(contentsOf: pdf)))
        try await draw(0..<3, on: id)
        dropbox.resetCounts()
        await sync.canvasLeft(id)
        await sync.settled()
        SyncBudget.check("sheet-pdf-uploads-later-syncs", dropbox.requests.filter { $0.contains("/sheets/") }.count)
        XCTAssertEqual(try SyncedCanvasFolder.rebuild(dropbox.files(in: folder)).sheets["madeuphash01"],
                       [UInt8](try Data(contentsOf: pdf)))
    }

    func testAFirstSyncOfANewCanvasIsTwoRequests() async throws {
        let id = try library.create(name: "New").id
        let (sync, _) = engine()
        await sync.start()
        await sync.settled()
        SyncBudget.check("requests-first-sync-new-canvas", dropbox.requests.count)
        try await assertDropboxRebuildsTheDuosCanvas(sync, id)
    }

    func testAPlanIsOnlyWhatChanged() {
        var record = CanvasSyncRecord(folder: "F 0000")
        let manifest: [UInt8] = Array("{}".utf8)
        record.uploaded = SyncedPosition(snapshotGeneration: nil, logGeneration: 0, logOffset: 100,
                                         manifestDigest: SyncPlan.digest(manifest), sheets: ["a"])
        let unchanged = CanvasSyncCapture(manifest: CanvasManifest(id: UUID(), name: "F", units: .default, created: Date()),
                                          manifestBytes: manifest, snapshotGeneration: 0, snapshotBytes: nil,
                                          logGeneration: 0, logOffset: 100, logBytes: [], logRestarted: false,
                                          sheets: ["a"])
        XCTAssertEqual(SyncPlan.steps(for: unchanged, record: record), [])
        var grown = unchanged
        grown.logBytes = [1, 2, 3]
        grown.sheets = ["a", "b"]
        XCTAssertEqual(SyncPlan.steps(for: grown, record: record), [.sheet("b"), .logPart(generation: 0, offset: 100)])
    }

    // MARK: Offline, the outbox, retries

    func testTheOutboxSurvivesACrashAndGoesWhenTheConnectionReturns() async throws {
        let ledgerFile = SyncLedgerFile(url: root.appendingPathComponent("Sync/ledger.json"))
        let kept = try library.create(name: "Kept").id
        let deleted = try library.create(name: "Deleted offline").id
        let (first, _) = engine(ledger: ledgerFile)
        await first.start()
        await first.settled()
        let deletedFolder = await folder(first, deleted)

        // Airplane mode: an edit and a delete wait.
        dropbox.offline = true
        await first.setOnline(false)
        try await draw(0..<5, on: kept)
        await first.canvasLeft(kept)
        await first.canvasWillBeDeleted(deleted)
        try await savers.delete(deleted)
        XCTAssertEqual(reports.state(kept), .waitingForConnection)
        // The app crashes: nothing of the first engine survives but its ledger on the Duo.
        let onDisk = ledgerFile.load()
        XCTAssertEqual(onDisk.pending, [kept])
        XCTAssertEqual(onDisk.deletes.map(\.folder), [deletedFolder])

        savers = CanvasSavers(library: library, clock: VirtualClock())
        let (relaunched, _) = engine(ledger: ledgerFile)
        await relaunched.setOnline(false)
        await relaunched.start()
        await relaunched.settled()
        XCTAssertEqual(reports.state(kept), .waitingForConnection, "still waiting after the relaunch")

        dropbox.offline = false
        await relaunched.setOnline(true)
        await relaunched.settled()
        XCTAssertEqual(reports.state(kept), .synced)
        XCTAssertEqual(dropbox.folders(in: SyncPaths.deleted), [deletedFolder], "moved to Vellum/.deleted, not erased")
        XCTAssertFalse(dropbox.folders(in: "/Vellum").contains(deletedFolder))
        try await assertDropboxRebuildsTheDuosCanvas(relaunched, kept)
        XCTAssertEqual(ledgerFile.load().deletes, [])
    }

    func testAFailedUploadIsRetriedWithBackoffAndLosesNothing() async throws {
        let id = try library.create(name: "Retried").id
        try await draw(0..<10, on: id)
        let logBefore = try duoFile(id, InkStore.logName)
        dropbox.failing = true
        let waits = Counter()
        let dropbox = dropbox!
        let (sync, _) = engine(sleep: { _ in
            waits.next()
            if waits.value == 3 { dropbox.failing = false }
        })
        await sync.start()
        await sync.settled()
        let delays = await sync.retryDelays
        XCTAssertEqual(delays, [5, 10, 20], "waits double after each failure")
        XCTAssertEqual(reports.state(id), .synced)
        XCTAssertEqual(try duoFile(id, InkStore.logName), logBefore, "syncing never changes the canvas's files")
        try await assertDropboxRebuildsTheDuosCanvas(sync, id)
        XCTAssertEqual((1...12).map { CanvasSync.backoff(afterFailures: $0) },
                       [5, 10, 20, 40, 80, 160, 300, 300, 300, 300, 300, 300])
    }

    func testRetryGoesAtOnceAndAFailureSaysSo() async throws {
        let id = try library.create(name: "Fails").id
        dropbox.failing = true
        let (sync, _) = engine(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        await sync.start()
        await sync.drained()
        XCTAssertEqual(reports.state(id), .failed)
        dropbox.failing = false
        await sync.retryNow()
        await sync.drained()
        XCTAssertEqual(reports.state(id), .synced)
    }

    func testTheCanvasOnScreenNeverUploadsUntilItIsLeftOrTheAppIsInTheBackground() async throws {
        let id = try library.create(name: "On screen").id
        let (sync, _) = engine()
        await sync.setOnline(false)
        await sync.start()
        await sync.canvasOpened(id)
        try await draw(0..<5, on: id)
        await sync.setOnline(true)
        await sync.settled()
        XCTAssertEqual(dropbox.requests, [], "nothing uploads while Zach draws")
        await sync.setInBackground(true)
        await sync.settled()
        XCTAssertEqual(reports.state(id), .synced)
        try await assertDropboxRebuildsTheDuosCanvas(sync, id)
    }

    func testADeleteMovesTheFolderToDeletedAndADeleteOfTheSameNameKeepsBoth() async throws {
        let id = try library.create(name: "Twice").id
        let (sync, _) = engine()
        await sync.start()
        await sync.settled()
        let folder = await self.folder(sync, id)
        dropbox.changeOnTheLaptop("\(SyncPaths.deleted)/\(folder)/canvas.json", to: Array("{}".utf8))
        await sync.canvasWillBeDeleted(id)
        try await savers.delete(id)
        await sync.settled()
        XCTAssertEqual(dropbox.folders(in: SyncPaths.deleted), [folder, "\(folder) (1)"])
        XCTAssertTrue(dropbox.folders(in: "/Vellum").isSuperset(of: [".deleted"]))
        XCTAssertFalse(dropbox.folders(in: "/Vellum").contains(folder))
    }

    // MARK: The Duo is the only writer

    func testAFileChangedInDropboxUnderneathIsReplacedByTheDuosAndNoted() async throws {
        let id = try library.create(name: "Changed underneath").id
        try await draw(0..<8, on: id)
        let (sync, _) = engine()
        await sync.start()
        await sync.settled()
        let folder = "/Vellum/\(await self.folder(sync, id))"
        dropbox.changeOnTheLaptop("\(folder)/canvas.json", to: Array(#"{"name":"edited on the laptop"}"#.utf8))
        dropbox.removeOnTheLaptop("\(folder)/ink.log.parts")
        let duoLog = try duoFile(id, InkStore.logName)
        _ = try library.rename(id, to: "Renamed on the Duo")
        await sync.canvasChanged(id)
        await sync.settled()
        XCTAssertEqual(reports.state(id), .synced)
        let replaced = await sync.ledgerNow[id]?.replaced.map(\.file)
        XCTAssertEqual(replaced, ["canvas.json"], "noted")
        XCTAssertEqual(try duoFile(id, InkStore.logName), duoLog, "the Duo's ink is untouched")
        try await assertDropboxRebuildsTheDuosCanvas(sync, id)
    }

    // MARK: Signed out

    func testSignedOutSaysSoAndSigningInUploadsEverything() async throws {
        let id = try library.create(name: "Waits for a sign-in").id
        let (sync, session) = engine(tokens: nil)
        await sync.start()
        await sync.settled()
        XCTAssertEqual(reports.state(id), .signedOut)
        XCTAssertEqual(dropbox.requests, [])
        let attempt = session.beginSignIn()
        try await session.finishSignIn(attempt, callback: URL(string: "\(syncKey.redirectURI)?code=c&state=\(attempt.state)")!)
        await sync.signInChanged()
        await sync.settled()
        XCTAssertEqual(reports.state(id), .synced)
        try await assertDropboxRebuildsTheDuosCanvas(sync, id)
    }

    // MARK: Leaving the canvas

    @MainActor
    func testLeavingACanvasWaitsOnNothingAndDoesNoFileWorkOnTheCallingThread() async throws {
        XCTAssertTrue(Thread.isMainThread, "leaving a canvas is a tap on the main thread")
        let id = try library.create(name: "Leaving").id
        let (sync, _) = engine()
        await sync.start()
        await sync.settled()
        var timings: [String: Double] = [:]
        for syncing in [false, true] {
            var total = 0.0
            for round in 0..<20 {
                let (_, opened, saver) = try await savers.open(id)
                var session = opened
                for i in 0..<50 {
                    session.draw(CanvasSaverTests.wave(round * 50 + i), tool: .pen, colour: .blue, width: .inches(0.5))
                    saver.save(session.takeEvents())
                }
                await saver.appendsIdle()
                let work = FileWork.current
                let start = DispatchTime.now().uptimeNanoseconds
                savers.close(saver)
                if syncing { Task { await sync.canvasLeft(id) } }
                total += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e3
                SyncBudget.check("file-work-on-calling-thread-leaving-canvas", (FileWork.current - work).onMainThread)
                await saver.idle()
                await sync.settled()
            }
            timings[syncing ? "leave-canvas-sync-on" : "leave-canvas-sync-off"] = total / 20
        }
        for (metric, value) in timings.sorted(by: { $0.key < $1.key }) { SyncBudget.time(metric, value, unit: "µs") }
        try await assertDropboxRebuildsTheDuosCanvas(sync, id)
    }
}

// MARK: - Wording

final class SyncStatusLineTests: XCTestCase {
    private let all: [CanvasSyncState] = [.off, .synced, .pending, .uploading, .waitingForConnection, .failed, .signedOut]

    func testEachStateSaysItInTheStatusBar() {
        func bar(_ state: CanvasSyncState, edited: Bool = false, online: Bool = true) -> SyncStatusLine {
            SyncStatusLine.statusBar(save: .savedOnThisDuo, sync: state, edited: edited, online: online)
        }
        XCTAssertEqual(bar(.synced).text, "Synced to Dropbox")
        XCTAssertEqual(bar(.synced, edited: true).text, "Saved on this Duo", "an edit syncs when Zach leaves")
        XCTAssertEqual(bar(.synced, edited: true, online: false).text, "Saved · offline")
        XCTAssertEqual(bar(.synced, online: false).text, "Synced to Dropbox", "nothing waits, so nothing to warn of")
        XCTAssertEqual(bar(.waitingForConnection).tone, .offline)
        XCTAssertTrue(bar(.waitingForConnection).showsWarning)
        XCTAssertEqual(bar(.failed).text, "Sync failed")
        XCTAssertEqual(bar(.failed).action, .retry)
        XCTAssertEqual(bar(.signedOut).text, "Signed out")
        XCTAssertEqual(bar(.signedOut).action, .signIn)
        XCTAssertEqual(bar(.off).text, "Saved on this Duo", "a build without Dropbox says nothing of it")
        XCTAssertEqual(bar(.pending).text, "Saved on this Duo")
    }

    func testNotSavedComesFirstAndNeverReadsLikeWaitingOffline() {
        for state in all {
            let line = SyncStatusLine.statusBar(save: .notSaved(outOfSpace: false), sync: state, edited: true, online: false)
            XCTAssertEqual(line.text, "Not saved: will retry")
            XCTAssertEqual(line.tone, .notSaved)
        }
        let offline = SyncStatusLine.statusBar(save: .savedOnThisDuo, sync: .waitingForConnection, edited: true, online: false)
        XCTAssertTrue(offline.text.hasPrefix("Saved"), "waiting offline says the ink is saved")
        XCTAssertFalse(offline.text.localizedCaseInsensitiveContains("not saved"))
        XCTAssertFalse(offline.accessibilityLabel.localizedCaseInsensitiveContains("not saved"))
    }

    /// The sync wording takes no more room than "Saved on this Duo" did, so every tool prompt (at most 28 characters,
    /// `CanvasToolPromptTests`) still shows in full, "Draw with the Pencil" included.
    func testTheStatusBarWordingLeavesThePromptItsRoom() {
        for state in all {
            for edited in [false, true] {
                for online in [false, true] {
                    let line = SyncStatusLine.statusBar(save: .savedOnThisDuo, sync: state, edited: edited, online: online)
                    XCTAssertLessThanOrEqual(line.statusBarLength, SyncStatusLine.longestStatusBar, line.text)
                    XCTAssertFalse(line.accessibilityLabel.isEmpty)
                }
            }
        }
        XCTAssertEqual(SyncStatusLine.longestStatusBar, 17)
    }

    func testTheListSaysEachStateInFullWithItsAction() {
        XCTAssertNil(SyncStatusLine.listNote(.synced))
        XCTAssertNil(SyncStatusLine.listNote(.off))
        XCTAssertEqual(SyncStatusLine.listNote(.waitingForConnection)?.text, "waiting for Dropbox")
        XCTAssertEqual(SyncStatusLine.listNote(.waitingForConnection)?.tone, .offline)
        XCTAssertEqual(SyncStatusLine.listNote(.failed)?.text, "sync failed · will retry")
        XCTAssertEqual(SyncStatusLine.listNote(.signedOut)?.text, "Dropbox signed out")
        XCTAssertEqual(SyncStatusLine.listNote(.uploading)?.text, "uploading…")
        for state in all { XCTAssertFalse(SyncStatusLine.listNote(state)?.accessibilityLabel.isEmpty ?? false) }

        let a = UUID(), b = UUID()
        let offline = SyncReport(available: true, online: false, signedOut: false,
                                 states: [a: .waitingForConnection, b: .waitingForConnection])
        XCTAssertEqual(SyncStatusLine.listBanner(offline, canvases: [a, b], names: [:])?.text,
                       "Offline. 2 canvases aren’t in Dropbox yet. They sync when a connection returns.")
        let failed = SyncReport(available: true, online: true, signedOut: false, states: [a: .failed, b: .synced])
        let banner = SyncStatusLine.listBanner(failed, canvases: [a, b], names: [a: "Boiler 4 walkdown (example)"])
        XCTAssertEqual(banner?.text, "Sync failed for “Boiler 4 walkdown (example)”. Vellum will retry.")
        XCTAssertEqual(banner?.action, .retry)
        let signedOut = SyncReport(available: true, online: true, signedOut: true, states: [:])
        XCTAssertEqual(SyncStatusLine.listBanner(signedOut, canvases: [a], names: [:])?.action, .signIn)
        XCTAssertNil(SyncStatusLine.listBanner(.off, canvases: [a], names: [:]))
        let synced = SyncReport(available: true, online: true, signedOut: false, states: [a: .synced])
        XCTAssertNil(SyncStatusLine.listBanner(synced, canvases: [a], names: [:]))
    }
}

// MARK: - Baselines

/// The sync area's baselines (`docs/perf/baselines/sync.json`): counts held to their budgets, timings recorded.
enum SyncBudget {
    struct Entry: Decodable {
        let metric: String
        let kind: String
        let value: Double
        let unit: String
        let tolerance: Double
    }

    static let all: [String: Entry] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../docs/perf/baselines/sync.json").standardizedFileURL
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        return Dictionary(entries.map { ($0.metric, $0) }) { $1 }
    }()

    static func check(_ metric: String, _ measured: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = all[metric], entry.kind == "count" else {
            return XCTFail("no count baseline named \(metric) in docs/perf/baselines/sync.json", file: file, line: line)
        }
        print("PERF sync \(metric)=\(measured) \(entry.unit) (budget \(Int(entry.value)))")
        XCTAssertLessThanOrEqual(Double(measured), entry.value, "\(metric) is over its budget in docs/perf/baselines/sync.json",
                                 file: file, line: line)
        if Double(measured) < entry.value {
            print("PERF sync \(metric) came in under its budget: lower it in docs/perf/baselines/sync.json")
        }
    }

    static func time(_ metric: String, _ measured: Double, unit: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = all[metric], entry.kind == "time" else {
            return XCTFail("no time baseline named \(metric) in docs/perf/baselines/sync.json", file: file, line: line)
        }
        XCTAssertEqual(entry.unit, unit, file: file, line: line)
        let shown = String(format: "%.1f", measured)
        print("PERF sync \(metric)=\(shown) \(unit) (baseline \(entry.value) \(unit))")
        if measured > entry.value * (1 + entry.tolerance) {
            print("::warning title=Performance (sync)::\(metric) took \(shown) \(unit), more than "
                + "\(Int(entry.tolerance * 100))% over its \(entry.value) \(unit) baseline")
        }
    }
}
