import Foundation
import XCTest
@testable import VellumCore

// Every drawing, project, path, key and token here is made up.
private let downloadKey = DropboxAppKey(buildSetting: "madeupindexkey2")!
private let renewedAccess = "made-up-access"

/// The made-up Dropbox behind a stand-in network (#98): every request waits `delay`, as a round trip does; shard
/// downloads in flight are counted; and chosen shard requests fail as a timed-out or dropped request does (the app's
/// transport maps `.timedOut` and `.networkConnectionLost` to `DropboxError.offline`), or every request after a point
/// fails as with no connection at all.
final class StandInIndexNetwork: DropboxTransport, @unchecked Sendable {
    let dropbox: MadeUpDropbox
    let delay: Duration
    private let lock = NSLock()
    private var inFlight = 0
    private var _peak = 0
    private var _shardRequests = 0
    private var _tokenRequests = 0
    private var _dropped: Set<String> = []
    /// Every `dropEvery`th shard request fails once, as a timed-out or dropped request.
    var dropEvery: Int?
    /// After this many shard requests, the connection is gone: every request after fails as offline.
    var offlineAfter: Int?
    /// Shard downloads with an access token other than the renewed one get a 401, as an expired token does.
    var refuseOldTokens = false
    private var _online = true

    init(_ dropbox: MadeUpDropbox, delay: Duration) {
        self.dropbox = dropbox
        self.delay = delay
    }

    /// Whether the connection is there, as `NWPathMonitor` would say.
    var online: Bool { lock.withLock { _online } }
    var peakInFlight: Int { lock.withLock { _peak } }
    var shardRequests: Int { lock.withLock { _shardRequests } }
    var tokenRequests: Int { lock.withLock { _tokenRequests } }
    var dropped: Int { lock.withLock { _dropped.count } }

    func send(_ request: DropboxHTTPRequest) async throws -> DropboxHTTPResponse {
        // JSONSerialization writes "/" as "\/" in the header.
        let argument = (request.headers["Dropbox-API-Arg"] ?? "").replacingOccurrences(of: "\\/", with: "/")
        let isShard = request.url.path == "/2/files/download" && argument.contains("/shards/")
        let (failure, counted): (DropboxError?, Bool) = lock.withLock {
            if request.url.path == "/oauth2/token" { _tokenRequests += 1 }
            guard _online else { return (.offline, false) }
            guard isShard else { return (nil, false) }
            inFlight += 1
            _peak = max(_peak, inFlight)
            _shardRequests += 1
            if let offlineAfter, _shardRequests > offlineAfter {
                _online = false
                return (.offline, true)
            }
            if let dropEvery, _shardRequests % dropEvery == 0, _dropped.insert(argument).inserted {
                return (.offline, true)
            }
            return (nil, true)
        }
        defer { if counted { lock.withLock { inFlight -= 1 } } }
        // A request on its way is answered even if the refresh stops meanwhile; the keeper asks nothing more.
        try? await Task.sleep(for: delay)
        if let failure { throw failure }
        if isShard, refuseOldTokens, request.headers["Authorization"] != "Bearer \(renewedAccess)" {
            return DropboxHTTPResponse(status: 401, body: Data("expired_access_token".utf8))
        }
        return try await dropbox.send(request)
    }
}

/// A made-up index of `shards` projects, one drawing each, as the laptop writes it.
struct MadeUpShardedIndex {
    let manifest: [UInt8]
    let files: [String: [UInt8]]
    let entries: Int

    init(shards count: Int, generation: Int = 1) {
        var files: [String: [UInt8]] = [:]
        var lines: [DrawingIndexManifest.Shard] = []
        var entries = 0
        for shard in MadeUpDrawingIndex.shards(count: count, projects: count) {
            let bytes = MadeUpDrawingIndex.bytes(of: shard)
            let file = "shards/\(DrawingIndexFormat.contentName(of: bytes)).json"
            files[file] = bytes
            lines.append(.init(project: shard.project, projectPath: shard.projectPath, file: file,
                               drawings: shard.drawings.count, bytes: bytes.count))
            entries += shard.drawings.count
        }
        let manifest = DrawingIndexManifest(generation: generation, updated: "2026-11-10T08:00:00Z", drawings: entries,
                                            shards: lines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.manifest = [UInt8](try! encoder.encode(manifest))
        self.files = files
        self.entries = entries
    }

    func put(in dropbox: MadeUpDropbox) {
        for (file, bytes) in files { dropbox.changeOnTheLaptop("/Vellum/Index/" + file, to: bytes) }
        dropbox.changeOnTheLaptop("/Vellum/Index/index.json", to: manifest)
        dropbox.resetCounts()
    }
}

/// The answer of `work`, or nil once `seconds` pass: a refresh that stops answering fails its test by name instead of
/// stalling the suite.
func withDeadline<Value: Sendable>(_ seconds: Int = 60, _ work: @escaping @Sendable () async -> Value) async -> Value? {
    let race = Race<Value?>()
    return await withCheckedContinuation { continuation in
        race.waiting(continuation)
        Task { race.give(await work()) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            race.give(nil)
        }
    }
}

private final class Race<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var answer: Value?
    private var answered = false

    func waiting(_ continuation: CheckedContinuation<Value, Never>) {
        let ready: Value? = lock.withLock {
            if answered { return answer }
            self.continuation = continuation
            return nil
        }
        if answered, let ready { continuation.resume(returning: ready) }
    }

    func give(_ value: Value) {
        let waiting: CheckedContinuation<Value, Never>? = lock.withLock {
            guard !answered else { return nil }
            answered = true
            answer = value
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}

final class DrawingIndexDownloadTests: XCTestCase {
    static let size = 2_500
    /// Retries wait nothing in the tests; the app's waits are `DrawingIndexKeeper.retryDelays`.
    static let noWaits: [Duration] = [.zero, .zero, .zero, .zero]

    override func setUp() {
        super.setUp()
        // Unbuffered, so a stalled test is named in the log even though XCTest's own lines wait in stdout's buffer.
        FileHandle.standardError.write(Data("\(name) started\n".utf8))
    }

    /// A refresh, failing the test with the network's counts if it hasn't answered in a minute.
    private func refresh(_ keeper: DrawingIndexKeeper, _ network: StandInIndexNetwork,
                         file: StaticString = #filePath, line: UInt = #line) async -> DrawingIndexRefresh? {
        let result = await withDeadline { await keeper.refresh() }
        if result == nil {
            XCTFail("the refresh didn't answer in 60 s: \(network.shardRequests) shard requests, peak \(network.peakInFlight)",
                    file: file, line: line)
        }
        return result
    }

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drawing-index-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeNetwork(_ index: MadeUpShardedIndex, delay: Duration = .milliseconds(1)) -> StandInIndexNetwork {
        let dropbox = MadeUpDropbox()
        index.put(in: dropbox)
        return StandInIndexNetwork(dropbox, delay: delay)
    }

    private func makeKeeper(_ network: StandInIndexNetwork, _ root: URL, inFlight: Int = DrawingIndexKeeper.shardsInFlight,
                        tokens: DropboxTokens = DropboxTokens(accessToken: renewedAccess, refreshToken: "made-up",
                                                              expiresAt: .distantFuture)) -> DrawingIndexKeeper {
        DrawingIndexKeeper(session: DropboxSession(appKey: downloadKey, transport: network,
                                                   store: DropboxMemoryTokenStore(tokens)),
                           root: root, connected: { network.online }, inFlight: inFlight, retryDelays: Self.noWaits)
    }

    /// Every shard the copy names is on the Duo, readable and named by its bytes.
    private func assertEveryShardVerified(_ keeper: DrawingIndexKeeper, _ index: MadeUpShardedIndex,
                                          file: StaticString = #filePath, line: UInt = #line) async {
        let held = await keeper.heldShards()
        XCTAssertEqual(held, Set(index.files.keys), file: file, line: line)
        for name in held {
            let bytes = [UInt8]((try? Data(contentsOf: keeper.root.appendingPathComponent(name))) ?? Data())
            XCTAssertEqual(DrawingIndexFormat.contentName(of: bytes), DrawingIndexFormat.namedHash(name),
                           file: file, line: line)
        }
    }

    func testTheFirstRefreshOfTwoAndAHalfThousandShardsCompletesSixAtATime() async throws {
        let index = MadeUpShardedIndex(shards: Self.size)
        XCTAssertEqual(index.files.count, Self.size)
        let network = makeNetwork(index)
        let keeper = makeKeeper(network, temporaryFolder())
        let result = await refresh(keeper, network)
        XCTAssertEqual(result, .updated)
        let copyRead = await keeper.load()
        let copy = try XCTUnwrap(copyRead)
        XCTAssertEqual(copy.entries.count, Self.size)
        XCTAssertEqual(copy.manifest.shards.count, Self.size)
        XCTAssertEqual(network.shardRequests, Self.size)
        // The listing, the manifest and one download per shard.
        XCTAssertEqual(network.dropbox.requests.count, Self.size + 2)
        XCTAssertEqual(network.peakInFlight, DrawingIndexKeeper.shardsInFlight)
        IndexBudget.check("index_requests_first_refresh_2500", network.dropbox.requests.count)
        IndexBudget.check("index_shard_downloads_in_flight", network.peakInFlight)
        await assertEveryShardVerified(keeper, index)
    }

    func testADroppedRequestEveryFewHundredIsRetriedAndTheRefreshCompletes() async throws {
        let index = MadeUpShardedIndex(shards: Self.size)
        let network = makeNetwork(index)
        network.dropEvery = 300
        let keeper = makeKeeper(network, temporaryFolder())
        let result = await refresh(keeper, network)
        XCTAssertEqual(result, .updated)
        // Requests 300, 600 … 2,400 failed once each and were asked again.
        XCTAssertEqual(network.dropped, 8)
        XCTAssertEqual(network.shardRequests, Self.size + 8)
        XCTAssertLessThanOrEqual(network.peakInFlight, DrawingIndexKeeper.shardsInFlight)
        let copyRead = await keeper.load()
        let copy = try XCTUnwrap(copyRead)
        XCTAssertEqual(copy.entries.count, Self.size)
        IndexBudget.check("index_shard_requests_first_refresh_2500_eight_dropped", network.shardRequests)
        await assertEveryShardVerified(keeper, index)
    }

    func testWithNoConnectionTheRefreshIsOfflineAndTheCopyIsKept() async throws {
        let first = MadeUpShardedIndex(shards: 50)
        let network = makeNetwork(first)
        let root = temporaryFolder()
        let keeper = makeKeeper(network, root)
        let swapped = await refresh(keeper, network)
        XCTAssertEqual(swapped, .updated)

        // A new generation in Dropbox, and the connection gone before its first shard.
        let second = MadeUpShardedIndex(shards: 60, generation: 2)
        second.put(in: network.dropbox)
        network.offlineAfter = network.shardRequests
        let offline = await refresh(keeper, network)
        XCTAssertEqual(offline, .offline)
        let kept = await keeper.load()
        XCTAssertEqual(kept?.manifest.generation, 1)
        XCTAssertEqual(kept?.entries.count, 50)
    }

    func testARefreshCutShortCarriesOnWithOnlyTheShardsItLacks() async throws {
        let index = MadeUpShardedIndex(shards: Self.size)
        let network = makeNetwork(index)
        network.offlineAfter = 1_000
        let root = temporaryFolder()
        let keeper = makeKeeper(network, root)
        let cut = await refresh(keeper, network)
        XCTAssertEqual(cut, .offline)
        let none = await keeper.load()
        XCTAssertNil(none)
        let held = await keeper.heldShards()
        XCTAssertEqual(held.count, 1_000)

        // Back online: the listing, the manifest and the 1,500 shards still missing.
        let back = StandInIndexNetwork(network.dropbox, delay: .milliseconds(1))
        network.dropbox.resetCounts()
        let again = makeKeeper(back, root)
        let carried = await refresh(again, back)
        XCTAssertEqual(carried, .updated)
        XCTAssertEqual(back.shardRequests, 1_500)
        XCTAssertEqual(network.dropbox.requests.count, 1_502)
        IndexBudget.check("index_requests_carry_on_after_1000_of_2500", network.dropbox.requests.count)
        let copy = await again.load()
        XCTAssertEqual(copy?.entries.count, Self.size)
        await assertEveryShardVerified(again, index)
    }

    func testAnInterruptedRefreshSwapsNothingAndTheNextFetchesTheRest() async throws {
        let index = MadeUpShardedIndex(shards: 300)
        let network = makeNetwork(index, delay: .milliseconds(5))
        let root = temporaryFolder()
        let keeper = makeKeeper(network, root)
        let running = Task { await keeper.refresh() }
        let deadline = Date().addingTimeInterval(60)
        while network.shardRequests < 60, Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        await keeper.interrupt()
        let result = await withDeadline { await running.value }
        XCTAssertEqual(result, .interrupted)
        let none = await keeper.load()
        XCTAssertNil(none)
        let held = await keeper.heldShards().count
        XCTAssertGreaterThan(held, 0)
        XCTAssertLessThan(held, 300)

        let before = network.shardRequests
        let carried = await refresh(keeper, network)
        XCTAssertEqual(carried, .updated)
        XCTAssertEqual(network.shardRequests - before, 300 - held)
        await assertEveryShardVerified(keeper, index)
    }

    func testAShardWhoseBytesDoNotMatchItsNameIsStillRefused() async throws {
        let index = MadeUpShardedIndex(shards: 200)
        let network = makeNetwork(index)
        let damaged = index.files.keys.sorted()[137]
        var bytes = index.files[damaged]!
        bytes[bytes.count / 2] ^= 0x01
        network.dropbox.changeOnTheLaptop("/Vellum/Index/" + damaged, to: bytes)
        let keeper = makeKeeper(network, temporaryFolder())
        let result = await refresh(keeper, network)
        XCTAssertEqual(result, .failed)
        let copy = await keeper.load()
        XCTAssertNil(copy)
        let held = await keeper.heldShards()
        XCTAssertFalse(held.contains(damaged))
        for name in held {
            let kept = [UInt8]((try? Data(contentsOf: keeper.root.appendingPathComponent(name))) ?? Data())
            XCTAssertEqual(DrawingIndexFormat.contentName(of: kept), DrawingIndexFormat.namedHash(name))
        }
    }

    /// Six downloads in flight when the access token lapses, or when Dropbox refuses it: one renewal between them, and
    /// every download carries on with the new token.
    func testDownloadsInFlightShareOneTokenRenewal() async throws {
        for expired in [true, false] {
            let index = MadeUpShardedIndex(shards: 60)
            let network = makeNetwork(index, delay: .milliseconds(5))
            network.refuseOldTokens = true
            let tokens = DropboxTokens(accessToken: "made-up-old", refreshToken: "made-up",
                                       expiresAt: expired ? .distantPast : .distantFuture)
            let session = DropboxSession(appKey: downloadKey, transport: network, store: DropboxMemoryTokenStore(tokens))
            let files = index.files.keys.sorted().prefix(DrawingIndexKeeper.shardsInFlight)
            let downloaded = await withDeadline { () -> [Bool] in await withTaskGroup(of: Bool.self) { group in
                for file in files {
                    let path = "/Vellum/Index/" + file
                    let dropboxFile = DropboxFile(id: path, name: file, path: path, size: index.files[file]!.count,
                                                  contentHash: "", rev: "")
                    group.addTask { (try? await session.download(dropboxFile)).map { [UInt8]($0) } == index.files[file]! }
                }
                var all: [Bool] = []
                for await same in group { all.append(same) }
                return all
            } }
            XCTAssertEqual(downloaded, Array(repeating: true, count: files.count), "expired: \(expired)")
            XCTAssertEqual(network.tokenRequests, 1, "expired: \(expired)")
            XCTAssertEqual(network.peakInFlight, files.count, "expired: \(expired)")
        }
    }

    /// The first refresh's time against the stand-in network's 5 ms round trip, one shard at a time as before #98 and
    /// `shardsInFlight` at a time. Measured in CI's optimised run (`VELLUM_PERF_OUT`), compared by perf-compare.py.
    func testTimings() async throws {
        guard let out = ProcessInfo.processInfo.environment["VELLUM_PERF_OUT"] else {
            throw XCTSkip("Timings run in CI's optimised run, with VELLUM_PERF_OUT set")
        }
        let index = MadeUpShardedIndex(shards: Self.size)
        var measurements: [(String, Double)] = []
        for (metric, inFlight) in [("index_first_refresh_2500_one_at_a_time_ms", 1),
                                   ("index_first_refresh_2500_ms", DrawingIndexKeeper.shardsInFlight)] {
            let network = makeNetwork(index, delay: .milliseconds(5))
            let keeper = makeKeeper(network, temporaryFolder(), inFlight: inFlight)
            let started = Date()
            // One at a time takes over a minute on a runner: each shard's durable write costs more than its round trip.
            let result = await withDeadline(600) { await keeper.refresh() }
            let elapsed = Date().timeIntervalSince(started) * 1000
            XCTAssertEqual(result, .updated)
            measurements.append((metric, elapsed))
        }
        for (metric, value) in measurements { print("PERF drawing-index \(metric)=\(String(format: "%.2f", value))") }
        try PerfOut.append(measurements, to: out)
    }
}

/// The optimised run's measurements file, which several timing tests add to.
enum PerfOut {
    static func append(_ measurements: [(String, Double)], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        var all: [[String: Any]] = []
        if let data = try? Data(contentsOf: url),
           let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let kept = read["measurements"] as? [[String: Any]] {
            let replaced = Set(measurements.map(\.0))
            all = kept.filter { !replaced.contains($0["metric"] as? String ?? "") }
        }
        all += measurements.map { ["metric": $0.0, "value": $0.1] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["measurements": all], options: [.sortedKeys, .prettyPrinted])
            .write(to: url)
    }
}
