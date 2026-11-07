import Foundation
import Observation
import VellumCore

/// The Drawings tab's search (#68): the Duo's copy of the drawing index, kept fresh with `DrawingIndexKeeper`, and the
/// search over it. Nothing heavy runs on the main thread: reading the copy, building the search and every keystroke's
/// search run off it, and the main thread only takes the answer. Every match is reachable: the list shows `page` rows
/// and shows the next page as it is scrolled to the end.
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

    /// Rows added to the list at a time: the first page as a search's answer comes in, the next as the list reaches its
    /// end, so a keystroke's update stays small however many entries match.
    static let page = 200

    /// The copy's entries with the search's latest answer over them, published as one value, so a row never reads an
    /// answer's offset into another generation's entries.
    struct Listing {
        let entries: [DrawingEntry]
        let index: DrawingSearchIndex
        let result: DrawingSearchResult
        let generation: Int
        let updated: Date?
    }
    private static let toldFormatKey = "drawingIndexToldFormat"
    private static let toldUnreadableKey = "drawingIndexToldUnreadable"

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
    /// The copy and the latest search's answer; nil until a copy is read.
    private(set) var listing: Listing?
    /// How many of the matches the list shows now.
    private(set) var limit = DrawingIndexModel.page
    /// Content hashes of the PDFs kept on the Duo (`SheetPDFs`), for "Not on this Duo".
    private(set) var pdfsOnThisDuo: Set<String> = []
    /// The row picked on the unfolded screen.
    var selection: String?
    /// The drawing open in the viewer (#69); nil when none is.
    private(set) var viewer: DrawingViewerModel?
    /// The viewer fills the screen: always folded, and unfolded when Zach asks.
    var viewerFull = false
    /// Why a tapped drawing didn't open, until it is read.
    var openProblem: String?
    /// The Dropbox session the copy is refreshed on, which the viewer downloads PDFs through.
    @ObservationIgnored private(set) var session: DropboxSession?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private(set) var keeper: DrawingIndexKeeper?
    @ObservationIgnored private var connection: ConnectionWatcher?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var lastStarted = Date.distantPast
    /// Debug captures hold the connection state themselves.
    @ObservationIgnored var followsConnection = true

    init() {}

    /// Every match of the latest search, best first, as offsets into `listing`'s entries.
    var matches: [Int32] { listing?.result.matches ?? [] }
    /// The query the answer is for.
    var resultQuery: String { listing?.result.query ?? "" }
    var matchCount: Int { matches.count }
    /// Entries in the copy.
    var total: Int { listing?.entries.count ?? 0 }
    /// When the laptop wrote the copy's generation.
    var updated: Date? { listing?.updated }

    /// The rows the list shows now: the matches up to `limit`, each with its entry from the same listing.
    var rows: [(offset: Int32, entry: DrawingEntry)] {
        guard let listing else { return [] }
        return listing.result.matches.prefix(limit).map { ($0, listing.entries[Int($0)]) }
    }

    /// The list reached its end: show the next page of matches.
    func showMore() {
        guard limit < matchCount else { return }
        limit += Self.page
    }

    var selectedEntry: DrawingEntry? {
        guard let selection else { return nil }
        return listing?.entries.first { $0.id == selection }
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
        self.session = session
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
            case .unreadableShard(let generation): tellUnreadable(generation)
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

    /// Zach signed in to Dropbox: every sign-in refreshes the copy, as signing out keeps it.
    func signInChanged(signedIn: Bool) {
        guard signedIn else { return }
        Task { await refresh() }
    }

    func setOnline(_ isOnline: Bool) {
        guard isOnline != online else { return }
        online = isOnline
        if isOnline { Task { await refresh() } }
        Task { await notePDFsOnThisDuo() }
    }

    /// Reads the copy, builds its search and searches it for what is typed, all off the main thread, then shows the
    /// entries and the answer together.
    private func reload() async {
        guard let keeper else { return }
        let query = self.query
        typealias Loaded = (DrawingIndexCopy, DrawingSearchIndex, DrawingSearchResult)
        let loaded = await Task.detached(priority: .userInitiated) { () -> Loaded? in
            guard let copy = await keeper.load() else { return nil }
            let index = DrawingSearchIndex(copy.entries)
            return (copy, index, index.keystroke(query, after: nil))
        }.value
        guard let loaded else {
            if copyState != .ready { copyState = .none }
            return
        }
        let (copy, index, result) = loaded
        generation += 1
        listing = Listing(entries: copy.entries, index: index, result: result, generation: generation,
                          updated: copy.manifest.updatedDate)
        limit = Self.page
        copyState = .ready
        if let selection, !copy.entries.contains(where: { $0.id == selection }) { self.selection = nil }
        // A viewer stays on the drawing it opened, even if a refresh dropped it from the index.
        // Typed while it was loading: search again for what is typed now.
        if query != self.query { search() }
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

    /// Says once per manifest generation that the laptop wrote a shard this Vellum can't read; the copy is kept.
    private func tellUnreadable(_ generation: Int) {
        let told = UserDefaults.standard.integer(forKey: Self.toldUnreadableKey)
        guard told != generation else { return }
        UserDefaults.standard.set(generation, forKey: Self.toldUnreadableKey)
        notice = copyState == .ready
            ? "The laptop's latest drawing index has a part this Vellum can't read, so you're searching the copy on this Duo from before it. It updates once the laptop writes the index again."
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

    // MARK: Opening a drawing (#69)

    /// A tap on a row: opens the drawing in the viewer, from the Duo when its PDF is kept here, else downloading it once;
    /// offline with its PDF never opened on this Duo, the viewer doesn't open and the tab says why.
    func open(_ entry: DrawingEntry) {
        selection = entry.id
        openProblem = nil
        if case .notOnThisDuo = DrawingOpening.decide(entry, online: online, pdfsOnThisDuo: pdfsOnThisDuo) {
            openProblem = DrawingOpening.notOnThisDuoText(number: entry.number ?? entry.name)
            closeViewer()
            return
        }
        if let viewer, viewer.entry.id == entry.id, viewer.entry == entry {
            if case .failed = viewer.state {} else { return }
        }
        let viewer = DrawingViewerModel(entry: entry)
        self.viewer = viewer
        let session = self.session
        Task {
            await viewer.open(session: session)
            await notePDFsOnThisDuo()
        }
    }

    /// Back to the list.
    func closeViewer() {
        viewer = nil
        viewerFull = false
    }

    // MARK: Searching

    /// Searches off the main thread with the same keystroke policy the timings measure (`DrawingSearchIndex.keystroke`):
    /// a keystroke that adds to the last query looks only at its matches. Only the latest query's answer is shown, and
    /// only over the entries it was searched in.
    private func search() {
        guard let listing else { return }
        let query = self.query
        let index = listing.index
        let last = listing.result
        searching?.cancel()
        searching = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> DrawingSearchResult in
                index.keystroke(query, after: last)
            }.value
            guard let self, !Task.isCancelled, query == self.query,
                  let current = self.listing, current.generation == listing.generation else { return }
            self.listing = Listing(entries: current.entries, index: current.index, result: result,
                                   generation: current.generation, updated: current.updated)
            limit = Self.page
        }
    }

    #if DEBUG
    /// For the captures: the connection as the capture says, not as the simulator's.
    func debugSetOnline(_ isOnline: Bool) {
        online = isOnline
        Task { await notePDFsOnThisDuo() }
    }

    func debugThumbnailNames() -> [String] { listing?.entries.compactMap(\.thumbnail) ?? [] }

    func debugSelect(number: String) { selection = listing?.entries.first { $0.number == number }?.id }

    /// For the captures: opens a drawing as a tap on its row does.
    func debugOpen(number: String) {
        guard let entry = listing?.entries.first(where: { $0.number == number }) else { return }
        open(entry)
    }
    #endif
}
