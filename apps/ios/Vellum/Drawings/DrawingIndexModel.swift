import Foundation
import Observation
import UIKit
import VellumCore

/// The Drawings tab's search (#68): the Duo's copy of the drawing index, kept fresh with `DrawingIndexKeeper`, and the
/// search over it. Nothing heavy runs on the main thread: reading the copy, building the search and every keystroke's
/// search run off it, and the main thread only takes the answer. Every match is reachable: the list shows `page` rows
/// and shows the next page as it is scrolled to the end.
///
/// The copy is refreshed on launch, when the app comes back to the screen, when the connection returns, when Zach
/// signs in to Dropbox and on a pull to refresh; one refresh runs at a time, and one asked for meanwhile runs after it.
/// A refresh asks iOS for background time, so leaving the app mid-download keeps it going while iOS allows (#98); one
/// cut short carries on by itself when the app comes back or the connection returns.
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
    /// The lower-cased Dropbox paths those PDFs came from, so one opened under a stale or missing index hash is found.
    private(set) var pdfPathsOnThisDuo: Set<String> = []
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

    /// What each entry's plot has got to (#70), by entry id: asked, plotting, waiting, failed, or done and on the Duo
    /// until the index lists it.
    private(set) var plots: [String: PlotProgress] = [:]
    /// Entries whose plot came in this session, which their rows mark "PDF plotted", as the prototype does.
    private(set) var plottedThisSession: Set<String> = []
    /// A plot that came in while Zach was elsewhere: the banner that calls him back to it.
    var plotBanner: DrawingEntry?
    /// How many drawing viewers on the screen show each entry, as the viewers say when they appear and go: a viewer
    /// kept while Zach browses Dropbox or another tab is not on the screen, and the banner shows.
    @ObservationIgnored private var viewersOnScreen: [String: Int] = [:]
    /// Asks the laptop for plots and waits for them, off the main thread (`PlotWatch`).
    @ObservationIgnored private(set) var plotWatch: PlotWatch?
    /// Where the plot watch keeps its requests: Application Support, or memory in the captures.
    @ObservationIgnored var plotLedger: (any PlotLedgerStore)?
    /// The Debug captures' way to switch tabs, which the tab bar follows; always nil in the app.
    var debugTab: AppTab?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private(set) var keeper: DrawingIndexKeeper?
    @ObservationIgnored private var connection: ConnectionWatcher?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var lastStarted = Date.distantPast
    /// The last refresh didn't finish (stopped as background time ran out, offline, or a failure): the next time the
    /// app comes back it carries on at once, however recently it started.
    @ObservationIgnored private var cutShort = false
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

    /// Whether a PDF at a Dropbox path is a plot fitted to the page, not to scale (#94), for Add sheet: the copy's entries
    /// and the plots on the Duo as they are now, read off the main thread when it asks.
    func fittedPlotCheck() -> @Sendable (String) async -> Bool {
        let entries = listing?.entries ?? []
        let plots = Array(self.plots.values)
        return { path in
            await Task.detached(priority: .userInitiated) {
                DrawingOpening.isFittedPlot(path: path, entries: entries, plots: plots)
            }.value
        }
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
        // Dropbox's `offline` also means a request that timed out or dropped; the keeper retries those while the Duo
        // has a connection, which `NWPathMonitor` says (#98).
        let keeper = DrawingIndexKeeper(session: session, root: root, connected: { [weak self] in
            await self?.online ?? false
        })
        self.keeper = keeper
        self.session = session
        await startPlotWatch(session: session)
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
        // iOS ending the background time stops the refresh; the shards that came down stay for the next.
        let background = BackgroundTime("Drawing index refresh") { Task { await keeper.interrupt() } }
        defer { background.end() }
        repeat {
            again = false
            let outcome = await keeper.refresh()
            if outcome == .busy { continue }
            cutShort = [DrawingIndexRefresh.interrupted, .offline, .failed].contains(outcome)
            // Stopped part way: the screen stays as it was, and the app coming back carries on.
            if outcome == .interrupted { break }
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

    /// The app came back to the screen: the plot watch looks again, and the copy is refreshed unless a refresh started
    /// moments ago (launch makes the app active too) and wasn't cut short.
    func appBecameActive() {
        let plotWatch = self.plotWatch
        Task { await plotWatch?.setActive(true) }
        guard cutShort || Date().timeIntervalSince(lastStarted) > 10 else { return }
        Task { await refresh() }
        Task { await notePDFsOnThisDuo() }
    }

    /// The app left the screen: the plot watch stops looking until it is back.
    func appLeftScreen() {
        let plotWatch = self.plotWatch
        Task { await plotWatch?.setActive(false) }
    }

    /// Zach signed in to Dropbox: every sign-in refreshes the copy, as signing out keeps it.
    func signInChanged(signedIn: Bool) {
        let plotWatch = self.plotWatch
        Task { await plotWatch?.signInChanged() }
        guard signedIn else { return }
        Task { await refresh() }
    }

    func setOnline(_ isOnline: Bool) {
        guard isOnline != online else { return }
        online = isOnline
        let plotWatch = self.plotWatch
        Task { await plotWatch?.setOnline(isOnline) }
        if isOnline { Task { await refresh() } }
        Task { await notePDFsOnThisDuo() }
    }

    /// Reads the copy, builds its search and searches it for what is typed, all off the main thread, then shows the
    /// entries and the answer together.
    private func reload() async {
        guard let keeper else { return }
        let query = self.query
        // Plots kept on the Duo, and failures, for entries the index may now list a PDF for (#70).
        let plotted = Set(plots.filter { !$0.value.stage.isWaiting }.keys)
        typealias Loaded = (DrawingIndexCopy, DrawingSearchIndex, DrawingSearchResult, [String: String])
        let loaded = await Task.detached(priority: .userInitiated) { () -> Loaded? in
            guard let copy = await keeper.load() else { return nil }
            let index = DrawingSearchIndex(copy.entries)
            var listed: [String: String] = [:]
            if !plotted.isEmpty {
                for entry in copy.entries where plotted.contains(entry.id) {
                    if let pdf = entry.pdf { listed[entry.id] = pdf.path }
                }
            }
            return (copy, index, index.keystroke(query, after: nil), listed)
        }.value
        guard let loaded else {
            if copyState != .ready { copyState = .none }
            return
        }
        let (copy, index, result, listed) = loaded
        if !listed.isEmpty, let plotWatch {
            Task { await plotWatch.indexLists(listed) }
        }
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

    /// The content hashes of the PDFs kept on the Duo, and the Dropbox paths they came from, read off the main thread.
    func notePDFsOnThisDuo() async {
        let (hashes, paths) = await Task.detached(priority: .utility) { () -> (Set<String>, Set<String>) in
            guard let pdfs = SheetPDFs.app,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: pdfs.folder.path) else { return ([], []) }
            return (Set(names.filter { $0.hasSuffix(".pdf") }.map { String($0.dropLast(4)) }), pdfs.keptPaths())
        }.value
        if hashes != pdfsOnThisDuo { pdfsOnThisDuo = hashes }
        if paths != pdfPathsOnThisDuo { pdfPathsOnThisDuo = paths }
    }

    // MARK: Opening a drawing (#69)

    /// A tap on a row: opens the drawing in the viewer, from the Duo when its PDF is kept here, else downloading it once;
    /// offline with its PDF never opened on this Duo, the viewer doesn't open and the tab says why. A DWG with no PDF
    /// yet opens waiting for its plot, and asks the laptop for one unless it is already asked or the laptop said why it
    /// can't (#70).
    func open(_ entry: DrawingEntry) {
        selection = entry.id
        openProblem = nil
        if plotBanner?.id == entry.id { plotBanner = nil }
        if entry.pdf == nil, entry.dwg != nil {
            openForPlot(entry)
            return
        }
        if case .notOnThisDuo = DrawingOpening.decide(entry, online: online, pdfsOnThisDuo: pdfsOnThisDuo,
                                                         pdfPathsOnThisDuo: pdfPathsOnThisDuo) {
            openProblem = DrawingOpening.notOnThisDuoText(number: entry.number ?? entry.name)
            closeViewer()
            return
        }
        if let viewer, viewer.entry.id == entry.id, viewer.entry == entry {
            if case .failed = viewer.state {} else { return }
        }
        let viewer = DrawingViewerModel(entry: entry, plot: plots[entry.id])
        self.viewer = viewer
        let session = self.session
        Task {
            await viewer.open(session: session)
            await notePDFsOnThisDuo()
        }
    }

    /// A DWG with no PDF in the index: the viewer shows its plot when the Duo has one, else waits for it.
    private func openForPlot(_ entry: DrawingEntry) {
        if let viewer, viewer.entry.id == entry.id, viewer.entry == entry {
            if case .failed = viewer.state {} else { return }
        }
        let plot = plots[entry.id]
        let viewer = DrawingViewerModel(entry: entry, plot: plot)
        self.viewer = viewer
        if viewer.pdf != nil {
            let session = self.session
            Task { await viewer.open(session: session) }
            return
        }
        if case .failed? = plot?.stage { return }
        ask(entry)
    }

    /// Asks the laptop to plot `entry` (Ask again after a failure, too); an open request is reused.
    func ask(_ entry: DrawingEntry) {
        guard let plotWatch else { return }
        Task { await plotWatch.ask(entry) }
    }

    // MARK: Plots (#70)

    private func startPlotWatch(session: DropboxSession?) async {
        guard plotWatch == nil else { return }
        let store = plotLedger
        let ledger: any PlotLedgerStore = await Task.detached(priority: .utility) { () -> any PlotLedgerStore in
            if let store { return store }
            // A ledger that can't be opened is a failure the Duo shows (each ask says it couldn't be saved), never a
            // quiet ledger in memory that a relaunch would lose.
            return (try? PlotLedgerFile.onThisDevice()) ?? PlotLedgerUnavailable()
        }.value
        let watch = PlotWatch(session: session, ledger: ledger, pdfs: SheetPDFs.app, report: { [weak self] progress in
            Task { @MainActor in self?.plotsChanged(progress) }
        })
        plotWatch = watch
        if !online { await watch.setOnline(false) }
        await watch.start()
    }

    /// The plot watch's news. A plot that has just come in fills the viewer showing it, or, when Zach isn't looking at
    /// that drawing on the Drawings tab, puts up the banner; and the index is refreshed, so it lists the plot.
    private func plotsChanged(_ progress: [String: PlotProgress]) {
        let before = plots
        plots = progress
        var arrived = false
        for (id, plot) in progress where plot.stage == .done && before[id].map({ $0.stage != .done }) ?? false {
            arrived = true
            plottedThisSession.insert(id)
            if let viewer, viewer.entry.id == id {
                viewer.plotArrived(plot, session: session)
            }
            if (viewersOnScreen[id] ?? 0) == 0,
               let entry = viewer?.entry.id == id ? viewer?.entry : listing?.entries.first(where: { $0.id == id }) {
                plotBanner = entry
            }
        }
        if arrived {
            Task { await notePDFsOnThisDuo() }
            Task { await refresh() }
        }
    }

    /// A drawing viewer showing `entry` came onto the screen, or went.
    func viewerOnScreen(_ entry: String, _ shown: Bool) {
        let count = max(0, (viewersOnScreen[entry] ?? 0) + (shown ? 1 : -1))
        viewersOnScreen[entry] = count == 0 ? nil : count
    }

    /// View, on the banner: back to the Drawings tab's viewer, showing the plot.
    func viewBanner() {
        guard let entry = plotBanner else { return }
        plotBanner = nil
        let current = listing?.entries.first { $0.id == entry.id } ?? entry
        if let viewer, viewer.entry.id == current.id, viewer.pdf != nil { return }
        viewer = nil
        open(current)
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
        let plotWatch = self.plotWatch
        Task { await plotWatch?.setOnline(isOnline) }
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

/// Background time from iOS for one piece of work (#98): asked for when the work starts, and given back when it ends or
/// when iOS says the time is up, after `expired` has asked the work to stop. Given back once.
@MainActor
final class BackgroundTime {
    private var task = UIBackgroundTaskIdentifier.invalid

    init(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) {
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // iOS calls this on the main thread, and ends the app if the time isn't given back before it returns.
            MainActor.assumeIsolated {
                expired()
                self?.end()
            }
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
