import Foundation
import Observation
import VellumCore

/// The Drawings tab's search (#68): the Duo's copy of the drawing index, kept fresh with `DrawingIndexKeeper`, and the
/// search over it. Nothing heavy runs on the main thread: reading the copy, building the search and every keystroke's
/// search run off it, and the main thread only takes the answer, at most `shown` rows of it.
///
/// The copy is refreshed on launch, when the app comes back to the screen, when the connection returns, when Zach
/// signs in to Dropbox and on a pull to refresh; one refresh runs at a time, and one asked for meanwhile runs after it.
@MainActor
@Observable
final class DrawingIndexModel {
    enum CopyState: Equatable {
        /// Reading the copy from the Duo.
        case loading
        /// No copy on the Duo yet.
        case none
        case ready
    }

    /// The most rows shown at once: a query that matches more says how many and asks for more letters.
    static let shown = 300
    private static let toldFormatKey = "drawingIndexToldFormat"

    private(set) var copyState = CopyState.loading
    /// What the last refresh found; nil until one has finished.
    private(set) var lastRefresh: DrawingIndexRefresh?
    private(set) var refreshing = false
    /// Whether the Duo has a connection, from `NWPathMonitor`.
    private(set) var online = true
    /// A newer index format the laptop wrote, said once per format.
    var notice: String?

    /// What is typed in the search field.
    var query = "" {
        didSet { if query != oldValue { search() } }
    }
    /// The rows shown for `resultQuery`, best first, as indexes into the copy's entries.
    private(set) var results: [Int32] = []
    private(set) var resultQuery = ""
    /// How many entries match `resultQuery`, shown or not.
    private(set) var matchCount = 0
    /// Entries in the copy.
    private(set) var total = 0
    /// When the laptop wrote the copy's generation.
    private(set) var updated: Date?
    /// Goes up each time a new copy is read, so rows reload.
    private(set) var generation = 0
    /// Content hashes of the PDFs kept on the Duo (`SheetPDFs`), for "Not on this Duo".
    private(set) var pdfsOnThisDuo: Set<String> = []
    /// The row picked on the unfolded screen.
    var selection: String?

    @ObservationIgnored private var entries: [DrawingEntry] = []
    @ObservationIgnored private var index: DrawingSearchIndex?
    @ObservationIgnored private var lastResult: DrawingSearchResult?
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private(set) var keeper: DrawingIndexKeeper?
    @ObservationIgnored private var connection: ConnectionWatcher?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var lastStarted = Date.distantPast
    /// Debug captures hold the connection state themselves.
    @ObservationIgnored var followsConnection = true

    init() {}

    func entry(_ index: Int32) -> DrawingEntry { entries[Int(index)] }

    var selectedEntry: DrawingEntry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    // MARK: Starting and refreshing

    /// Finds the copy's folder, reads the copy and refreshes it, all off the main thread; `session` is the app's
    /// Dropbox session (a made-up one in the Debug captures).
    func start(session: DropboxSession?) async {
        guard keeper == nil else { return }
        guard let root = await Task.detached(priority: .utility, operation: {
            try? DrawingIndexKeeper.folderOnThisDevice()
        }).value else {
            copyState = .none
            return
        }
        let keeper = DrawingIndexKeeper(session: session, root: root)
        self.keeper = keeper
        await reload()
        await notePDFsOnThisDuo()
        if followsConnection {
            connection = ConnectionWatcher { [weak self] online in
                Task { @MainActor in self?.setOnline(online) }
            }
        }
        await refresh()
    }

    /// Pull to refresh, Try Again, and every refresh the app asks for.
    func refresh() async {
        guard let keeper else { return }
        if refreshing {
            again = true
            return
        }
        refreshing = true
        lastStarted = Date()
        repeat {
            again = false
            let outcome = await keeper.refresh()
            if outcome == .busy { continue }
            lastRefresh = outcome
            switch outcome {
            case .updated: await reload()
            case .newerFormat(let format): tell(format)
            default: break
            }
        } while again
        refreshing = false
    }

    /// The app came back to the screen: refresh, unless a refresh started moments ago (launch makes the app active too).
    func appBecameActive() {
        guard Date().timeIntervalSince(lastStarted) > 10 else { return }
        Task { await refresh() }
        Task { await notePDFsOnThisDuo() }
    }

    /// Zach signed in to Dropbox (or out): a refresh that found no sign-in runs again.
    func signInChanged(signedIn: Bool) {
        guard signedIn, lastRefresh == nil || lastRefresh == .notSignedIn else { return }
        Task { await refresh() }
    }

    func setOnline(_ isOnline: Bool) {
        guard isOnline != online else { return }
        online = isOnline
        if isOnline { Task { await refresh() } }
        Task { await notePDFsOnThisDuo() }
    }

    /// Reads the copy and builds its search off the main thread, then searches it again for what is typed.
    private func reload() async {
        guard let keeper else { return }
        let loaded = await Task.detached(priority: .userInitiated) { () -> (DrawingIndexCopy, DrawingSearchIndex)? in
            guard let copy = await keeper.load() else { return nil }
            return (copy, DrawingSearchIndex(copy.entries))
        }.value
        guard let loaded else {
            if copyState != .ready { copyState = .none }
            return
        }
        let (copy, index) = loaded
        entries = copy.entries
        self.index = index
        lastResult = nil
        total = copy.entries.count
        updated = copy.manifest.updatedDate
        generation += 1
        copyState = .ready
        if let selection, !entries.contains(where: { $0.id == selection }) { self.selection = nil }
        search()
    }

    /// Says once per format that the laptop wrote one this Vellum can't read.
    private func tell(_ format: Int) {
        let told = UserDefaults.standard.integer(forKey: Self.toldFormatKey)
        guard told != format else { return }
        UserDefaults.standard.set(format, forKey: Self.toldFormatKey)
        notice = copyState == .ready
            ? "The laptop now writes the drawing index in format \(format), newer than this Vellum reads. You're searching the copy on this Duo; install the latest Vellum to see what changed."
            : nil
    }

    /// The content hashes of the PDFs kept on the Duo, read off the main thread.
    func notePDFsOnThisDuo() async {
        let hashes = await Task.detached(priority: .utility) { () -> Set<String> in
            guard let folder = try? SheetPDFs.inCaches().folder,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
            return Set(names.filter { $0.hasSuffix(".pdf") }.map { String($0.dropLast(4)) })
        }.value
        if hashes != pdfsOnThisDuo { pdfsOnThisDuo = hashes }
    }

    // MARK: Searching

    /// Searches off the main thread; a keystroke that adds to the last query looks only at its matches. Only the
    /// latest query's answer is shown.
    private func search() {
        guard let index else { return }
        let query = self.query
        let last = lastResult
        searching?.cancel()
        searching = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> DrawingSearchResult in
                if let last, DrawingSearchIndex.narrows(query, from: last.query) {
                    return index.search(query, within: last.matches)
                }
                return index.search(query)
            }.value
            guard let self, !Task.isCancelled, query == self.query else { return }
            lastResult = result
            results = Array(result.matches.prefix(Self.shown))
            matchCount = result.matches.count
            resultQuery = query
        }
    }

    #if DEBUG
    /// For the captures: the connection as the capture says, not as the simulator's.
    func debugSetOnline(_ isOnline: Bool) {
        online = isOnline
        Task { await notePDFsOnThisDuo() }
    }

    func debugThumbnailNames() -> [String] { entries.compactMap(\.thumbnail) }

    func debugSelect(number: String) { selection = entries.first { $0.number == number }?.id }
    #endif
}
