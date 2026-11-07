import Foundation
import XCTest
@testable import VellumCore

// Every drawing, project, path, key and token here is made up: the fixture is the one the laptop indexer wrote for
// its own tests (laptop/tests/fixtures/drawing-index), and the rest is made up in place.
private let indexKey = DropboxAppKey(buildSetting: "madeupindexkey1")!
private let indexTokens = DropboxTokens(accessToken: "made-up", refreshToken: "made-up", expiresAt: .distantFuture)

/// The fixture index, read from the repository.
enum IndexFixture {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../laptop/tests/fixtures/drawing-index").standardizedFileURL

    static func bytes(_ file: String) -> [UInt8] {
        [UInt8]((try? Data(contentsOf: folder.appendingPathComponent(file))) ?? Data())
    }

    static var manifestBytes: [UInt8] { bytes("index.json") }
    static var manifest: DrawingIndexManifest { try! DrawingIndexFormat.manifest(from: manifestBytes) }

    /// Every file of the index, by its path inside `Index/`.
    static var files: [String: [UInt8]] {
        var files = ["index.json": manifestBytes]
        for folder in ["shards", "thumbnails"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: self.folder.appendingPathComponent(folder).path)) ?? []
            for name in names { files["\(folder)/\(name)"] = bytes("\(folder)/\(name)") }
        }
        return files
    }

    static var entries: [DrawingEntry] {
        manifest.shards.flatMap { try! DrawingIndexFormat.shard(from: bytes($0.file)).drawings }
    }

    static func entry(_ number: String) -> DrawingEntry { entries.first { $0.number == number }! }
}

final class DrawingIndexTests: XCTestCase {
    // MARK: The format

    func testTheFixtureManifestAndShardsDecode() throws {
        let manifest = IndexFixture.manifest
        XCTAssertEqual(manifest.format, 1)
        XCTAssertEqual(manifest.generation, 1)
        XCTAssertEqual(manifest.drawings, 10)
        XCTAssertEqual(manifest.thumbnailBox, 128)
        XCTAssertEqual(manifest.updated, "2026-11-07T12:00:00Z")
        XCTAssertEqual(manifest.updatedDate, Date(timeIntervalSince1970: 1_794_052_800))
        XCTAssertEqual(manifest.shards.map(\.project), [nil, "Made-up Plant Upgrade", "Made-up School Addition"])
        XCTAssertEqual(manifest.shards.map(\.drawings), [1, 6, 3])
        for shard in manifest.shards {
            let bytes = IndexFixture.bytes(shard.file)
            XCTAssertEqual(bytes.count, shard.bytes)
            // Named by the hash of its bytes, as the Duo checks every download.
            XCTAssertEqual(DrawingIndexFormat.contentName(of: bytes), DrawingIndexFormat.namedHash(shard.file))
        }
        let entries = IndexFixture.entries
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries.compactMap(\.number),
                       ["E-201", "E-210", "E-211", "I-301", "I-302", "V-12", "M-101", "M-102", "M-501"])

        let pump = IndexFixture.entry("E-210")
        XCTAssertEqual(pump.layout, "E-210")
        XCTAssertEqual(pump.name, "Pump house.dwg")
        XCTAssertEqual(pump.scale, "1:20")
        XCTAssertEqual(pump.pdf?.paperInches, [36, 24])
        XCTAssertEqual(pump.pdf?.contentHash, "352facefd971f6798bd8c7b50af413aac01a340201b49c9ee66225d88b1bd88a")
        XCTAssertEqual(pump.dwg?.read, true)
        let unread = IndexFixture.entry("I-302")
        XCTAssertEqual(unread.pdf?.read, false)
        XCTAssertNil(unread.pdf?.contentHash)
        XCTAssertNil(unread.pdf?.pages)
        XCTAssertEqual(IndexFixture.entry("I-301").otherPdfs,
                       ["/Projects/Made-up Plant Upgrade/Instrumentation/PDF/I-301 - Rev 0 issued.pdf"])
        for entry in entries {
            let thumbnail = try XCTUnwrap(entry.thumbnail)
            XCTAssertTrue(DrawingIndexFormat.isThumbnailName(thumbnail))
            let bytes = IndexFixture.bytes("thumbnails/" + thumbnail)
            XCTAssertEqual(DrawingIndexFormat.contentName(of: bytes), DrawingIndexFormat.namedHash(thumbnail))
        }
    }

    func testAnotherFormatOrAStrangeFileIsRefused() {
        XCTAssertThrowsError(try DrawingIndexFormat.manifest(from: Array(#"{"format":2,"generation":9,"shards":[]}"#.utf8))) {
            XCTAssertEqual($0 as? DrawingIndexError, .newerFormat(2))
        }
        XCTAssertThrowsError(try DrawingIndexFormat.shard(from: Array(#"{"format":2,"drawings":[]}"#.utf8))) {
            XCTAssertEqual($0 as? DrawingIndexError, .newerFormat(2))
        }
        XCTAssertThrowsError(try DrawingIndexFormat.manifest(from: Array("not json".utf8))) {
            XCTAssertEqual($0 as? DrawingIndexError, .unreadable)
        }
        // A manifest may only name shards inside the index's folder.
        let outside = #"{"format":1,"generation":1,"drawings":0,"shards":[{"file":"../../secret.json","drawings":0,"bytes":1}]}"#
        XCTAssertThrowsError(try DrawingIndexFormat.manifest(from: Array(outside.utf8))) {
            XCTAssertEqual($0 as? DrawingIndexError, .unreadable)
        }
        XCTAssertFalse(DrawingIndexFormat.isShardFile("shards/3A8C2BF6283E632BE11888C49BEC4904.json"))
        XCTAssertFalse(DrawingIndexFormat.isThumbnailName("../0de96a74540e44fa136bddcd97c4d840.png"))
        XCTAssertTrue(DrawingIndexFormat.isShardFile("shards/3a8c2bf6283e632be11888c49bec4904.json"))
        // A key the reader does not know is not a new format.
        let added = #"{"format":1,"generation":3,"drawings":0,"shards":[],"somethingNew":true}"#
        XCTAssertEqual(try DrawingIndexFormat.manifest(from: Array(added.utf8)).generation, 3)
    }

    // MARK: The refresh plan

    private let a = "shards/" + String(repeating: "a", count: 32) + ".json"
    private let b = "shards/" + String(repeating: "b", count: 32) + ".json"
    private let b2 = "shards/" + String(repeating: "c", count: 32) + ".json"
    private let d = "shards/" + String(repeating: "d", count: 32) + ".json"

    private func manifest(_ generation: Int, _ files: [String]) -> DrawingIndexManifest {
        DrawingIndexManifest(generation: generation, updated: nil, drawings: files.count, shards: files.map {
            DrawingIndexManifest.Shard(project: nil, projectPath: nil, file: $0, drawings: 1, bytes: 1)
        })
    }

    func testTheFirstRefreshFetchesEveryShardThenSwaps() {
        XCTAssertEqual(DrawingIndexPlan.check(listedHash: "h1", keptHash: nil), .downloadManifest)
        XCTAssertEqual(DrawingIndexPlan.step(.success(manifest(1, [a, b])), held: []), .fetch([a, b]))
        XCTAssertEqual(DrawingIndexPlan.step(.success(manifest(1, [a, b])), held: [a, b]), .swap(delete: []))
    }

    func testANoChangeRefreshStopsAtTheListing() {
        XCTAssertEqual(DrawingIndexPlan.check(listedHash: "h1", keptHash: "h1"), .unchanged)
        XCTAssertEqual(DrawingIndexPlan.check(listedHash: nil, keptHash: "h1"), .noIndex)
        XCTAssertEqual(DrawingIndexPlan.check(listedHash: nil, keptHash: nil), .noIndex)
    }

    func testOneShardChangedFetchesOnlyThatShardAndDropsTheOldOne() {
        XCTAssertEqual(DrawingIndexPlan.check(listedHash: "h2", keptHash: "h1"), .downloadManifest)
        XCTAssertEqual(DrawingIndexPlan.step(.success(manifest(2, [a, b2])), held: [a, b]), .fetch([b2]))
        XCTAssertEqual(DrawingIndexPlan.step(.success(manifest(2, [a, b2])), held: [a, b, b2]), .swap(delete: [b]))
        // A project gone and one new: the gone one's shard goes after the swap; a leftover of an earlier refresh too.
        XCTAssertEqual(DrawingIndexPlan.step(.success(manifest(3, [b2])), held: [a, b2, d]), .swap(delete: [a, d]))
    }

    func testAHalfDoneRefreshNeverSwaps() {
        // Two new shards, one arrived before the connection went: still a fetch, never a swap, and nothing deleted.
        XCTAssertEqual(DrawingIndexPlan.step(.success(manifest(2, [b2, d])), held: [a, b, b2]), .fetch([d]))
        XCTAssertEqual(DrawingIndexPlan.step(.success(manifest(2, [b2, d])), held: [a, b, b2, d]), .swap(delete: [a, b]))
    }

    func testANewerFormatKeepsTheCopy() {
        XCTAssertEqual(DrawingIndexPlan.step(.failure(.newerFormat(2)), held: [a, b]), .refuse(format: 2))
        XCTAssertEqual(DrawingIndexPlan.step(.failure(.unreadable), held: [a, b]), .keep)
    }

    func testThumbnailsComeDownWhenNeededAndGoWhenNoLongerNamed() {
        let t1 = String(repeating: "1", count: 32) + ".png"
        let t2 = String(repeating: "2", count: 32) + ".png"
        let t3 = String(repeating: "3", count: 32) + ".png"
        // Added: t2 is named and not here, so a row showing it downloads it; t1 is here and never downloads again.
        XCTAssertTrue(DrawingIndexPlan.thumbnailFetch(t2, referenced: [t1, t2], held: [t1], online: true))
        XCTAssertFalse(DrawingIndexPlan.thumbnailFetch(t1, referenced: [t1, t2], held: [t1], online: true))
        XCTAssertFalse(DrawingIndexPlan.thumbnailFetch(t2, referenced: [t1, t2], held: [t1], online: false))
        XCTAssertFalse(DrawingIndexPlan.thumbnailFetch(t3, referenced: [t1, t2], held: [t1], online: true))
        XCTAssertFalse(DrawingIndexPlan.thumbnailFetch("../x.png", referenced: ["../x.png"], held: [], online: true))
        // Removed: t3 is here and nothing names it.
        XCTAssertEqual(DrawingIndexPlan.thumbnailsToDelete(referenced: [t1, t2], held: [t1, t3]), [t3])
    }

    // MARK: The keeper against a made-up Dropbox

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drawing-index-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func dropboxWithFixture() -> MadeUpDropbox {
        let dropbox = MadeUpDropbox()
        for (file, bytes) in IndexFixture.files { dropbox.changeOnTheLaptop("/Vellum/Index/" + file, to: bytes) }
        dropbox.resetCounts()
        return dropbox
    }

    private func makeKeeper(_ dropbox: MadeUpDropbox, _ root: URL) -> DrawingIndexKeeper {
        DrawingIndexKeeper(session: DropboxSession(appKey: indexKey, transport: dropbox,
                                                   store: DropboxMemoryTokenStore(indexTokens)), root: root)
    }

    /// The fixture's School shard with one title changed, and a manifest naming it in place of the old one.
    private func changedSchool() -> (manifest: [UInt8], shardFile: String, shard: [UInt8], old: String) {
        let old = IndexFixture.manifest.shards[2].file
        var shard = try! DrawingIndexFormat.shard(from: IndexFixture.bytes(old))
        shard.drawings[1].title = "Second floor HVAC plan, revised"
        let bytes = MadeUpDrawingIndex.bytes(of: shard)
        let file = "shards/\(DrawingIndexFormat.contentName(of: bytes)).json"
        var manifest = IndexFixture.manifest
        manifest.generation = 2
        manifest.shards[2].file = file
        manifest.shards[2].bytes = bytes.count
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ([UInt8](try! encoder.encode(manifest)), file, bytes, old)
    }

    func testRefreshingDownloadsOnlyWhatChanged() async throws {
        let dropbox = dropboxWithFixture()
        let root = temporaryFolder()
        let keeper = makeKeeper(dropbox, root)
        let empty = await keeper.load()
        XCTAssertNil(empty)

        // First refresh: the listing, the manifest and the three shards; no thumbnail.
        let first = await keeper.refresh()
        XCTAssertEqual(first, .updated)
        let shardFiles = IndexFixture.manifest.shards.map(\.file)
        XCTAssertEqual(dropbox.requests.count, 5)
        XCTAssertEqual(dropbox.requests.first, "list /Vellum/Index")
        XCTAssertEqual(Array(dropbox.requests.suffix(3)), shardFiles.map { "download /Vellum/Index/" + $0 })
        let firstBytes = await keeper.bytesDownloaded
        XCTAssertEqual(firstBytes, 666 + 630 + 4938 + 2510)
        IndexBudget.check("index_requests_first_refresh", dropbox.requests.count)
        IndexBudget.check("index_bytes_first_refresh", firstBytes)
        IndexBudget.check("index_thumbnails_downloaded_per_refresh",
                          dropbox.requests.filter { $0.contains("/thumbnails/") }.count)
        let copyRead = await keeper.load()
        let copy = try XCTUnwrap(copyRead)
        XCTAssertEqual(copy.entries.count, 10)
        XCTAssertEqual(copy.manifest.generation, 1)
        XCTAssertEqual(copy.thumbnails.count, 10)

        // Nothing changed: the listing alone.
        dropbox.resetCounts()
        let second = await keeper.refresh()
        XCTAssertEqual(second, .unchanged)
        XCTAssertEqual(dropbox.requests, ["list /Vellum/Index"])
        let afterSecond = await keeper.bytesDownloaded
        IndexBudget.check("index_requests_no_change_refresh", dropbox.requests.count)
        IndexBudget.check("index_bytes_no_change_refresh", afterSecond - firstBytes)

        // One drawing changed on the laptop: the manifest and that project's shard; the old shard goes.
        let changed = changedSchool()
        dropbox.changeOnTheLaptop("/Vellum/Index/" + changed.shardFile, to: changed.shard)
        dropbox.changeOnTheLaptop("/Vellum/Index/index.json", to: changed.manifest)
        dropbox.resetCounts()
        let third = await keeper.refresh()
        XCTAssertEqual(third, .updated)
        XCTAssertEqual(dropbox.requests.count, 3)
        XCTAssertEqual(dropbox.requests.last, "download /Vellum/Index/" + changed.shardFile)
        let thirdBytes = await keeper.bytesDownloaded - afterSecond
        XCTAssertEqual(thirdBytes, changed.manifest.count + changed.shard.count)
        IndexBudget.check("index_requests_one_shard_changed", dropbox.requests.count)
        let updatedRead = await keeper.load()
        let updated = try XCTUnwrap(updatedRead)
        XCTAssertEqual(updated.manifest.generation, 2)
        XCTAssertEqual(updated.entries.first { $0.number == "M-102" }?.title, "Second floor HVAC plan, revised")
        let held = await keeper.heldShards()
        XCTAssertEqual(held, Set(updated.manifest.shards.map(\.file)))
        XCTAssertFalse(held.contains(changed.old))
    }

    func testARefreshCutShortKeepsTheCopyWhole() async throws {
        let dropbox = dropboxWithFixture()
        let keeper = makeKeeper(dropbox, temporaryFolder())
        _ = await keeper.refresh()
        let changed = changedSchool()
        // The manifest names a shard that is not in Dropbox (as when the connection drops before it comes down).
        dropbox.changeOnTheLaptop("/Vellum/Index/index.json", to: changed.manifest)
        let cut = await keeper.refresh()
        XCTAssertEqual(cut, .failed)
        let keptRead = await keeper.load()
        let kept = try XCTUnwrap(keptRead)
        XCTAssertEqual(kept.manifest.generation, 1)
        XCTAssertEqual(kept.entries.first { $0.number == "M-102" }?.title, "Second floor HVAC plan")

        // Offline: nothing changes either.
        dropbox.changeOnTheLaptop("/Vellum/Index/" + changed.shardFile, to: changed.shard)
        dropbox.offline = true
        let offline = await keeper.refresh()
        XCTAssertEqual(offline, .offline)
        let stillKept = await keeper.load()
        XCTAssertEqual(stillKept?.manifest.generation, 1)

        // Back online, the refresh carries on and swaps.
        dropbox.offline = false
        let back = await keeper.refresh()
        XCTAssertEqual(back, .updated)
        let swapped = await keeper.load()
        XCTAssertEqual(swapped?.manifest.generation, 2)
    }

    func testADamagedShardIsNeverKept() async {
        let dropbox = dropboxWithFixture()
        let keeper = makeKeeper(dropbox, temporaryFolder())
        let file = IndexFixture.manifest.shards[1].file
        var bytes = IndexFixture.bytes(file)
        bytes[10] ^= 0x01
        dropbox.changeOnTheLaptop("/Vellum/Index/" + file, to: bytes)
        let result = await keeper.refresh()
        XCTAssertEqual(result, .failed)
        let copy = await keeper.load()
        XCTAssertNil(copy)
        let held = await keeper.heldShards()
        XCTAssertFalse(held.contains(file))
    }

    func testANewerFormatKeepsTheCopyTheDuoHas() async {
        let dropbox = dropboxWithFixture()
        let keeper = makeKeeper(dropbox, temporaryFolder())
        _ = await keeper.refresh()
        dropbox.changeOnTheLaptop("/Vellum/Index/index.json",
                                  to: Array(#"{"format":2,"generation":7,"index":"elsewhere"}"#.utf8))
        let result = await keeper.refresh()
        XCTAssertEqual(result, .newerFormat(2))
        let copy = await keeper.load()
        XCTAssertEqual(copy?.manifest.generation, 1)
        XCTAssertEqual(copy?.entries.count, 10)
    }

    /// A new generation whose shard is named right but can't be read keeps the copy: nothing is swapped in.
    func testAShardThatCannotBeReadIsNeverSwappedIn() async throws {
        let dropbox = dropboxWithFixture()
        let keeper = makeKeeper(dropbox, temporaryFolder())
        _ = await keeper.refresh()
        for (bytes, expected) in [
            (Array(#"{"format":1,"drawings":"not a list"}"#.utf8), DrawingIndexRefresh.unreadableShard(generation: 2)),
            (Array(#"{"format":2,"drawings":[]}"#.utf8), DrawingIndexRefresh.newerFormat(2)),
        ] {
            let file = "shards/\(DrawingIndexFormat.contentName(of: bytes)).json"
            var manifest = IndexFixture.manifest
            manifest.generation = 2
            manifest.shards[2].file = file
            manifest.shards[2].bytes = bytes.count
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            dropbox.changeOnTheLaptop("/Vellum/Index/" + file, to: bytes)
            dropbox.changeOnTheLaptop("/Vellum/Index/index.json", to: [UInt8](try encoder.encode(manifest)))
            let result = await keeper.refresh()
            XCTAssertEqual(result, expected)
            let copy = await keeper.load()
            XCTAssertEqual(copy?.manifest.generation, 1)
            XCTAssertEqual(copy?.entries.count, 10)
            XCTAssertEqual(copy?.entries.filter { $0.project == "Made-up School Addition" }.count, 3)
        }
    }

    func testNoIndexInDropboxYet() async {
        let dropbox = MadeUpDropbox()
        let keeper = makeKeeper(dropbox, temporaryFolder())
        let none = await keeper.refresh()
        XCTAssertEqual(none, .noIndex)
        // The folder there, but the manifest not yet written.
        dropbox.changeOnTheLaptop("/Vellum/Index/~$index.json.123.tmp", to: Array("{".utf8))
        let stillNone = await keeper.refresh()
        XCTAssertEqual(stillNone, .noIndex)
        let signedOut = DrawingIndexKeeper(session: nil, root: temporaryFolder())
        let result = await signedOut.refresh()
        XCTAssertEqual(result, .notSignedIn)
    }

    func testThumbnailsComeDownOnceWhenARowNeedsThem() async throws {
        let dropbox = dropboxWithFixture()
        let keeper = makeKeeper(dropbox, temporaryFolder())
        _ = await keeper.refresh()
        _ = await keeper.load()
        let name = IndexFixture.entry("E-201").thumbnail!
        dropbox.resetCounts()
        let offline = await keeper.thumbnail(name, online: false)
        XCTAssertNil(offline)
        XCTAssertEqual(dropbox.requests, [])
        let urlRead = await keeper.thumbnail(name, online: true)
        let url = try XCTUnwrap(urlRead)
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), IndexFixture.bytes("thumbnails/" + name))
        let again = await keeper.thumbnail(name, online: true)
        XCTAssertEqual(again, url)
        XCTAssertEqual(dropbox.requests, ["download /Vellum/Index/thumbnails/" + name])
        IndexBudget.check("index_thumbnail_downloads_per_thumbnail", dropbox.requests.count)
        // One no entry names is never asked for.
        let stranger = await keeper.thumbnail(String(repeating: "e", count: 32) + ".png", online: true)
        XCTAssertNil(stranger)
        XCTAssertEqual(dropbox.requests.count, 1)

        // After a swap that no longer names it, loading the copy deletes it.
        var manifest = IndexFixture.manifest
        var shard = try DrawingIndexFormat.shard(from: IndexFixture.bytes(manifest.shards[1].file))
        shard.drawings.removeAll { $0.thumbnail == name }
        let bytes = MadeUpDrawingIndex.bytes(of: shard)
        let file = "shards/\(DrawingIndexFormat.contentName(of: bytes)).json"
        manifest.generation = 2
        manifest.shards[1].file = file
        manifest.shards[1].bytes = bytes.count
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        dropbox.changeOnTheLaptop("/Vellum/Index/" + file, to: bytes)
        dropbox.changeOnTheLaptop("/Vellum/Index/index.json", to: [UInt8](try encoder.encode(manifest)))
        let result = await keeper.refresh()
        XCTAssertEqual(result, .updated)
        _ = await keeper.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Markers and rows

    func testMarkersForEveryFixtureCase() {
        let all = Set(IndexFixture.entries.compactMap(\.pdf?.contentHash))
        func markers(_ entry: DrawingEntry, online: Bool, onDuo: Set<String> = []) -> [DrawingMarker] {
            DrawingMarker.of(entry, online: online, pdfsOnThisDuo: onDuo)
        }
        let sketch = IndexFixture.entries.first { $0.number == nil }!
        let expected: [(DrawingEntry, online: [DrawingMarker], offline: [DrawingMarker])] = [
            (IndexFixture.entry("E-201"), [.noPDFYet], [.noPDFYet]),
            (IndexFixture.entry("M-102"), [.noPDFYet], [.noPDFYet]),
            (IndexFixture.entry("E-210"), [], [.notOnThisDuo]),
            (IndexFixture.entry("E-211"), [], [.notOnThisDuo]),
            (IndexFixture.entry("I-301"), [], [.notOnThisDuo]),
            (IndexFixture.entry("M-101"), [], [.notOnThisDuo]),
            (IndexFixture.entry("M-501"), [], [.notOnThisDuo]),
            (IndexFixture.entry("V-12"), [.pdfOnly], [.pdfOnly, .notOnThisDuo]),
            (sketch, [.pdfOnly], [.pdfOnly, .notOnThisDuo]),
            // The PDF is online-only on the laptop and unread: no content hash, so never on this Duo.
            (IndexFixture.entry("I-302"), [.notReadYet], [.notReadYet, .notOnThisDuo]),
        ]
        XCTAssertEqual(expected.count, IndexFixture.entries.count)
        for (entry, online, offline) in expected {
            XCTAssertEqual(markers(entry, online: true), online, entry.name)
            XCTAssertEqual(markers(entry, online: false), offline, entry.name)
            // A PDF opened on the Duo before opens offline, so it is not marked.
            XCTAssertEqual(markers(entry, online: false, onDuo: all), offline.filter { $0 != .notOnThisDuo }
                + (entry.number == "I-302" ? [.notOnThisDuo] : []), entry.name)
        }
        // Only the PDF kept counts.
        let pump = IndexFixture.entry("E-210")
        XCTAssertEqual(markers(pump, online: false, onDuo: [IndexFixture.entry("E-211").pdf!.contentHash!]), [.notOnThisDuo])
    }

    func testAnUnreadEntryIsAQuietRowByNameAndPath() {
        // A DWG online-only on the laptop and not downloaded yet. The indexer fills its number in from the file name
        // (fieldsFrom "name"); the row is still the quiet one, by name and path, because the file is unread.
        let unread = DrawingEntry(id: "0123456789abcdef", path: "/Projects/Made-up Plant Upgrade/Electrical/E-299.dwg",
                                  name: "E-299.dwg", folder: "/Projects/Made-up Plant Upgrade/Electrical",
                                  project: "Made-up Plant Upgrade", projectPath: "/Projects/Made-up Plant Upgrade",
                                  number: "E-299", fieldsFrom: "name",
                                  dwg: DrawingEntry.DWG(path: "/Projects/Made-up Plant Upgrade/Electrical/E-299.dwg",
                                                        size: 900, read: false))
        XCTAssertEqual(DrawingMarker.of(unread, online: true, pdfsOnThisDuo: []), [.noPDFYet, .notReadYet])
        XCTAssertEqual(DrawingRowText(unread), DrawingRowText(
            number: nil, title: "E-299.dwg", details: nil,
            place: "/Projects/Made-up Plant Upgrade/Electrical/E-299.dwg", quiet: true))
        // The fixture's I-302: its DWG is read, its PDF is not, so it is quiet too, as the format's table says.
        XCTAssertEqual(DrawingRowText(IndexFixture.entry("I-302")), DrawingRowText(
            number: nil, title: "I-302.dwg", details: nil,
            place: "/Projects/Made-up Plant Upgrade/Instrumentation/I-302.dwg", quiet: true))
        XCTAssertEqual(DrawingMarker.allCases.map(\.text), ["No PDF yet", "PDF only · no DWG", "Not read yet", "Not on this Duo"])
    }

    func testRowText() {
        let boiler = DrawingRowText(IndexFixture.entry("E-201"))
        XCTAssertEqual(boiler, DrawingRowText(number: "E-201", title: "Boiler room power plan",
                                              details: "Rev A · 1/4\" = 1'-0\" · 2026-09-14", place: "Made-up Plant Upgrade",
                                              quiet: false))
        let sketch = DrawingRowText(IndexFixture.entries.first { $0.number == nil }!)
        XCTAssertEqual(sketch, DrawingRowText(number: nil, title: "Made-up loose sketch", details: nil, place: "/",
                                              quiet: false))
    }

    // MARK: Search

    private func numbers(_ query: String, in entries: [DrawingEntry] = IndexFixture.entries) -> [String] {
        let index = DrawingSearchIndex(entries)
        return index.search(query).matches.map { entries[Int($0)].number ?? entries[Int($0)].name }
    }

    func testSearchByNumberTitleAndProject() {
        XCTAssertEqual(numbers("E-201"), ["E-201"])
        XCTAssertEqual(numbers("E-2"), ["E-201", "E-210", "E-211"])
        XCTAssertEqual(numbers("pump"), ["E-210", "E-211", "V-12"])
        XCTAssertEqual(numbers("school"), ["M-101", "M-102", "M-501"])
        XCTAssertEqual(numbers("plant"), ["E-201", "E-210", "E-211", "I-301", "I-302", "V-12"])
        XCTAssertEqual(numbers("loop lt"), ["I-302"])
        XCTAssertEqual(numbers("hvac second"), ["M-102"])
        XCTAssertEqual(numbers("sketch"), ["Made-up loose sketch.pdf"])
        XCTAssertEqual(numbers("nothing like this"), [])
        // The empty query lists everything, in natural order of number (title or name when there is none).
        XCTAssertEqual(numbers(""), ["E-201", "E-210", "E-211", "I-301", "I-302", "M-101", "M-102", "M-501",
                                     "Made-up loose sketch.pdf", "V-12"])
    }

    func testCaseAndPunctuationDoNotMatter() {
        for query in ["E-201", "e201", "E201", "e 201", "E_201", "e.201", " E-201 "] {
            XCTAssertEqual(numbers(query), ["E-201"], query)
        }
        XCTAssertEqual(numbers("BOILER"), ["E-201"])
        XCTAssertEqual(numbers("Pump-House"), ["E-210", "E-211"])
        // The layout's name is a number too (a DWG with several titled sheets).
        let pump = IndexFixture.entries.firstIndex { $0.number == "E-210" }!
        XCTAssertEqual(DrawingSearchIndex(IndexFixture.entries).rank(of: pump, for: "e210"), .exactNumber)
    }

    func testExactNumberFirstThenPrefixThenWords() {
        func made(_ number: String?, _ title: String, _ path: String) -> DrawingEntry {
            DrawingEntry(id: path, path: path, name: (path as NSString).lastPathComponent, project: "Made-up Rank Test",
                         number: number, title: title)
        }
        let entries = [
            made("E-201", "Made-up feeder plan", "/p/E-201.dwg"),
            made("X-1", "Area E 2 survey", "/p/X-1.dwg"),
            made("E-20", "Made-up panel schedule", "/p/E-20.dwg"),
            made("E-2", "Made-up site plan", "/p/E-2.dwg"),
            made("E-10", "Made-up riser", "/p/E-10.dwg"),
            made("E-9", "Made-up details", "/p/E-9.dwg"),
        ]
        XCTAssertEqual(numbers("E-2", in: entries), ["E-2", "E-20", "E-201", "X-1"])
        let index = DrawingSearchIndex(entries)
        XCTAssertEqual(index.rank(of: 3, for: "E-2"), .exactNumber)
        XCTAssertEqual(index.rank(of: 2, for: "E-2"), .numberPrefix)
        XCTAssertEqual(index.rank(of: 1, for: "E-2"), .words)
        XCTAssertNil(index.rank(of: 4, for: "E-2"))
        // Natural order within a rank: E-2, E-9, E-10, not E-10 first.
        XCTAssertEqual(numbers("E", in: entries), ["E-2", "E-9", "E-10", "E-20", "E-201", "X-1"])
    }

    /// The one keystroke policy the app and the timings share: narrow to the last matches when the query adds to the
    /// last one, else search everything.
    func testAKeystrokeNarrowsOnlyWhenItAddsToTheLastQuery() {
        let index = DrawingSearchIndex(IndexFixture.entries)
        let first = index.keystroke("E", after: nil)
        XCTAssertEqual(first.scanned, 10)
        let typedOn = index.keystroke("E-2", after: first)
        XCTAssertEqual(typedOn.scanned, first.matches.count)
        XCTAssertEqual(typedOn.matches, index.search("E-2").matches)
        let backspaced = index.keystroke("E", after: typedOn)
        XCTAssertEqual(backspaced.scanned, 10)
        XCTAssertEqual(backspaced.matches, first.matches)
    }

    func testTypingOnNarrowsTheLastMatches() {
        let entries = IndexFixture.entries
        let index = DrawingSearchIndex(entries)
        XCTAssertTrue(DrawingSearchIndex.narrows("E-2", from: "E"))
        XCTAssertTrue(DrawingSearchIndex.narrows("E-20", from: "E-2"))
        XCTAssertTrue(DrawingSearchIndex.narrows("pump h", from: "pump"))
        XCTAssertFalse(DrawingSearchIndex.narrows("E", from: "E-2"))
        XCTAssertFalse(DrawingSearchIndex.narrows("pumq", from: "pump"))
        XCTAssertFalse(DrawingSearchIndex.narrows("pump", from: ""))
        let first = index.search("E")
        let narrowed = index.search("E-2", within: first.matches)
        XCTAssertEqual(narrowed.matches, index.search("E-2").matches)
        XCTAssertEqual(narrowed.scanned, first.matches.count)
        XCTAssertEqual(index.search("E-2").scanned, entries.count)
    }

    func testHighlights() {
        func marked(_ text: String, _ query: String, number: Bool = false) -> [String] {
            DrawingSearchText.highlights(in: text, query: query, number: number).map { String(text[$0]) }
        }
        XCTAssertEqual(marked("Pump house power plan", "pu ho"), ["Pu", "ho"])
        XCTAssertEqual(marked("Pump house power plan", "p"), ["P", "p", "p"])
        XCTAssertEqual(marked("E-201", "e20", number: true), ["E-201"])
        XCTAssertEqual(marked("Made-up Plant Upgrade", "plant"), ["Plant"])
        XCTAssertEqual(marked("Anything", ""), [])
    }
}

// MARK: - Baselines (docs/perf/baselines/drawing-index.json)

/// The drawing index's baselines: counts held to their budgets, timings recorded for perf-compare.py.
enum IndexBudget {
    struct Entry: Decodable {
        let metric: String
        let kind: String
        let value: Double
        let unit: String
    }

    static let all: [String: Entry] = {
        struct File: Decodable { let entries: [Entry] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../docs/perf/baselines/drawing-index.json").standardizedFileURL
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [:] }
        return Dictionary(file.entries.map { ($0.metric, $0) }) { $1 }
    }()

    static func check(_ metric: String, _ measured: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = all[metric], entry.kind == "count" else {
            return XCTFail("no count baseline named \(metric) in docs/perf/baselines/drawing-index.json (measured \(measured))",
                           file: file, line: line)
        }
        print("PERF drawing-index \(metric)=\(measured) \(entry.unit) (budget \(Int(entry.value)))")
        XCTAssertLessThanOrEqual(Double(measured), entry.value,
                                 "\(metric) is over its budget in docs/perf/baselines/drawing-index.json", file: file, line: line)
        if Double(measured) < entry.value {
            print("PERF drawing-index \(metric) came in under its budget: lower it in docs/perf/baselines/drawing-index.json")
        }
    }
}
