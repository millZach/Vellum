import Foundation

/// The plot watch (#70, ADR-0018, `docs/plot-requests.md`): asks the laptop to plot a drawing with no PDF yet, and
/// waits for it.
///
/// - **Asking** writes one plot request in format 1 to `Dropbox/Vellum/Plots/requests/<UUID>.json` (`files/upload`,
///   mode `add`), the UUID fresh per ask so two Duos or two taps never write one file. Asking again for an entry while
///   its request is open gives the open one back. Offline, the request waits in the sync outbox (the plot ledger, kept
///   in Application Support) and goes when the connection returns, retried after `CanvasSync.backoff` on a failure.
/// - **Waiting** looks while any request is open, and only then: each look downloads each open request's answer
///   (`files/download`, a few hundred bytes, or a short not-found), and the check-in's metadata (`files/get_metadata`)
///   at most once every `checkInEvery` and whenever an answer moves on. It looks every `quickLook` for the first
///   `quickFor` after a request goes, when a plot is usually answered, then every `slowLook` for as long as it stays
///   open. It stops while the Duo is offline, signed out or the app is off the screen, and starts again at once when
///   it is back.
/// - **Done**: the PDF is downloaded once from the answer's path through the app's one `SheetPDFs`, under the
///   answer's content hash, and only then is the request deleted (`files/delete_v2`). The plot is remembered per entry
///   until the drawing index lists it, so the row never goes back to "No PDF yet" meanwhile.
/// - **Failed**: the request is deleted and the laptop's reason kept for the entry, until Zach asks again.
///
/// The Duo writes nothing but its own requests, in `requests/` alone, and deletes nothing but those
/// (`PlotRequestFormat.isRequestPath`). Everything here runs off the main thread; the app hears what changed
/// through `report`.
public actor PlotWatch {
    /// How often it looks while a request is new.
    public static let quickLook: Double = 5
    /// How long a request counts as new after it goes: the laptop answers `queued` within seconds, and a plot is
    /// usually done in under a minute.
    public static let quickFor: Double = 120
    /// How often it looks after that, for as long as the request stays open.
    public static let slowLook: Double = 30
    /// The check-in changes every 2 minutes and is stale after 5, so a look a minute at most says the laptop is off
    /// within a minute of the rule.
    public static let checkInEvery: Double = 60

    private let session: DropboxSession?
    private let store: any PlotLedgerStore
    private let pdfs: SheetPDFs?
    private let sleep: @Sendable (Double) async -> Void
    private let now: @Sendable () -> Date
    private let report: @Sendable ([String: PlotProgress]) -> Void

    private var ledger = PlotLedger()
    private var loaded = false
    private var started = false
    private var online = true
    private var active = true
    private var signedIn = true
    /// The check-in's `server_modified`, and when it was last looked at; nil until it has been.
    private var checkedIn: Date?
    private var checkInLooked: Date?
    private var failures = 0
    private var running: Task<Void, Never>?
    private var nap: Task<Void, Never>?
    /// Something asked for a look while a pass was running: the next pass starts without waiting.
    private var poked = false
    private var lastReport: [String: PlotProgress]?
    /// By entry id: an ask the ledger couldn't save, with why; never queued, never sent.
    private var notKept: [String: String] = [:]
    /// Every wait between looks, for the tests.
    public private(set) var waits: [Double] = []

    public init(session: DropboxSession?, ledger: any PlotLedgerStore, pdfs: SheetPDFs?,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                now: @escaping @Sendable () -> Date = { Date() },
                report: @escaping @Sendable ([String: PlotProgress]) -> Void = { _ in }) {
        self.session = session
        store = ledger
        self.pdfs = pdfs
        self.sleep = sleep
        self.now = now
        self.report = report
    }

    // MARK: What the app tells it

    /// Reads the ledger and carries on with whatever was open when the app last stopped.
    public func start() async {
        guard !started else { return }
        started = true
        load()
        if let session { signedIn = await session.isSignedIn }
        publish()
        wake()
    }

    /// Asks the laptop to plot `entry`, or gives back the request already open for it. Nil for an entry with no DWG.
    /// An ask counts only once the plot ledger has kept it (ADR-0010: a queued request survives a crash or a
    /// relaunch); when the ledger can't be saved, nothing is queued or sent, and the entry says why
    /// (`PlotStage.notKept`) until Zach tries again.
    @discardableResult
    public func ask(_ entry: DrawingEntry) -> PlotProgress? {
        load()
        if let open = ledger.open.last(where: { $0.request.id == entry.id && $0.reusable }) {
            return progress(of: open)
        }
        guard let request = PlotRequest.asking(for: entry, at: now()) else { return nil }
        var asked = ledger
        asked.failed[entry.id] = nil
        asked.open.append(OpenPlot(request: request))
        do {
            try store.save(asked)
        } catch {
            notKept[entry.id] = "This Duo couldn't save the request to plot it, so it isn't queued and hasn't gone to "
                + "the laptop. Try again; if it keeps happening, the Duo may be out of storage."
            publish()
            return lastReport?[entry.id]
        }
        ledger = asked
        notKept[entry.id] = nil
        publish()
        wake()
        return lastReport?[entry.id]
    }

    /// The connection came or went (`NWPathMonitor`). Coming back sends the outbox and looks at once.
    public func setOnline(_ isOnline: Bool) {
        guard isOnline != online else { return }
        online = isOnline
        if isOnline { failures = 0 }
        publish()
        wake()
    }

    /// The app came to the screen or left it. Off the screen it doesn't look: iOS would suspend it anyway, and it looks
    /// again the moment the app is back.
    public func setActive(_ isActive: Bool) {
        guard isActive != active else { return }
        active = isActive
        if isActive { checkInLooked = nil }
        wake()
    }

    /// Zach signed in or out of Dropbox.
    public func signInChanged() async {
        guard let session else { return }
        signedIn = await session.isSignedIn
        failures = 0
        wake()
    }

    /// The drawing index now lists a PDF for these entries, by entry id, its Dropbox path. Any old failure is
    /// forgotten. A plot the Duo kept is kept while the index lists that same PDF, so its note (missing references,
    /// the fallback page setup) stays with it however the drawing is opened; once the index lists another PDF (a
    /// re-plot, a PDF saved by hand), the plot and its note are forgotten.
    public func indexLists(_ pdfs: [String: String]) {
        load()
        var changed = false
        for (id, path) in pdfs {
            if ledger.failed[id] != nil {
                ledger.failed[id] = nil
                changed = true
            }
            if let plot = ledger.plotted[id], plot.path.lowercased() != path.lowercased() {
                ledger.plotted[id] = nil
                changed = true
            }
        }
        guard changed else { return }
        persist()
        publish()
    }

    /// What each entry's plot has got to.
    public var current: [String: PlotProgress] { snapshot() }

    /// The ledger as it stands; for the tests.
    public var ledgerNow: PlotLedger { ledger }

    /// Whether it is looking, or will after its wait; for the tests.
    public var isWatching: Bool { running != nil }

    /// Waits until it has stopped: nothing open, or offline, signed out or off the screen; for the tests.
    public func settled() async {
        while let running { await running.value }
    }

    // MARK: Watching

    private func load() {
        guard !loaded else { return }
        ledger = store.load()
        loaded = true
    }

    private func persist() {
        guard loaded else { return }
        try? store.save(ledger)
    }

    /// Starts the watch, or cuts its wait short when it is running.
    private func wake() {
        guard started else { return }
        if running != nil {
            poked = true
            nap?.cancel()
            return
        }
        guard canWork, !ledger.open.isEmpty else { return }
        running = Task { await self.watch() }
    }

    private var canWork: Bool { session != nil && online && active && signedIn }

    /// Thrown before a transfer once the watch may no longer work (off the screen, offline, signed out): the pass ends
    /// there, with nothing more sent or fetched, and that is not a failure.
    private struct Stopped: Error {}

    /// Called before every transfer in a pass, not only between passes.
    private func mayGo() throws {
        guard canWork else { throw Stopped() }
    }

    private func watch() async {
        defer {
            running = nil
            publish()
        }
        while canWork, !ledger.open.isEmpty {
            let ok = await pass()
            publish()
            guard canWork, !ledger.open.isEmpty else { return }
            let wait: Double
            if ok {
                failures = 0
                wait = nextLook()
            } else {
                failures += 1
                wait = CanvasSync.backoff(afterFailures: failures)
            }
            if poked {
                poked = false
                continue
            }
            waits.append(wait)
            let sleep = self.sleep
            let nap = Task { await sleep(wait) }
            self.nap = nap
            await nap.value
            self.nap = nil
            poked = false
        }
    }

    /// The wait before the next look: `quickLook` while any open request went within `quickFor`, else `slowLook`; none
    /// while one is still to send.
    private func nextLook() -> Double {
        let time = now()
        if ledger.open.contains(where: { $0.sent == nil }) { return Self.quickLook }
        let newest = ledger.open.compactMap(\.sent).max() ?? .distantPast
        return time.timeIntervalSince(newest) < Self.quickFor ? Self.quickLook : Self.slowLook
    }

    /// One pass: sends what waits in the outbox, reads the answers, and finishes what the laptop has answered. False
    /// when a request to Dropbox failed.
    private func pass() async -> Bool {
        guard let session else { return false }
        do {
            var justSent: Set<String> = []
            for request in ledger.open.filter({ $0.sent == nil }).map(\.request) {
                try mayGo()
                try await send(request, session)
                justSent.insert(request.request)
            }
            var moved = false
            let looking = ledger.open.filter { $0.answer?.isFinal != true && !justSent.contains($0.request.request) }
            for open in looking {
                try mayGo()
                guard let bytes = try await session.download(path: PlotRequestFormat.answerPath(open.request.request)),
                      let answer = PlotAnswer.read([UInt8](bytes)), answer != open.answer else { continue }
                if let index = ledger.open.firstIndex(where: { $0.request.request == open.request.request }) {
                    if answer.state != ledger.open[index].answer?.state { moved = true }
                    ledger.open[index].answer = answer
                }
            }
            if moved { persist() }
            let time = now()
            let pending = ledger.open.contains { $0.sent != nil && $0.answer?.isFinal != true }
            // At most once a minute, whatever the answers do (ADR-0010's #70 amendment).
            if pending, checkInLooked.map({ time.timeIntervalSince($0) >= Self.checkInEvery }) ?? true {
                try mayGo()
                checkedIn = try await session.serverModified(of: PlotRequestFormat.checkInPath)
                checkInLooked = time
            }
            publish()
            for open in ledger.open where open.answer?.isFinal == true {
                try mayGo()
                try await finish(open.request.request, session)
            }
            return true
        } catch is Stopped {
            return true
        } catch let error as DropboxError {
            if error == .notSignedIn || error == .signInExpired { signedIn = false }
            return false
        } catch {
            return false
        }
    }

    private func send(_ request: PlotRequest, _ session: DropboxSession) async throws {
        guard PlotRequestFormat.isRequestPath(request.dropboxPath), request.bytes.count <= PlotRequestFormat.maxRequestBytes
        else {
            // Never written: dropped, with the reason kept, rather than written anywhere else.
            ledger.open.removeAll { $0.request.request == request.request }
            ledger.failed[request.id] = "Vellum couldn't write a plot request for this drawing."
            persist()
            return
        }
        // A conflict means a file already has this fresh UUID's name: this Duo's own earlier upload, whose reply was
        // lost. Either way the request is in Dropbox.
        _ = try await session.upload(Data(request.bytes), to: request.dropboxPath, mode: .add)
        if let at = ledger.open.firstIndex(where: { $0.request.request == request.request }) {
            ledger.open[at].sent = now()
            persist()
            publish()
        }
    }

    /// A final answer read: for `done`, its PDF down first; then the request deleted, and the plot or the reason kept
    /// for the entry.
    private func finish(_ requestID: String, _ session: DropboxSession) async throws {
        guard let open = ledger.open.first(where: { $0.request.request == requestID }), let answer = open.answer,
              answer.isFinal else { return }
        let entry = open.request.id
        var plotted: PlottedPDF?
        var reason = answer.reason.map(PlotAnswer.sentence) ?? "The laptop couldn't plot it."
        if answer.state == .done, answer.pdf == nil { reason = "The laptop said it plotted it, but not where the PDF is." }
        if answer.state == .done, let path = answer.pdf {
            // Through SheetPDFs every time, never on the name saved in the ledger alone: after a relaunch the system may
            // have cleared Caches, and then the PDF comes down again before the request goes.
            guard let pdfs else { throw DropboxError.unexpectedReply }
            let kept = try await pdfs.pdf(at: path, contentHash: answer.contentHash, size: nil) {
                guard let reply = try await session.downloadPDF(path: path) else { throw DropboxError.unexpectedReply }
                return reply
            }
            let keptName = kept.keptName
            guard pdfs.holds(keptName: keptName, size: nil) else { throw DropboxError.unexpectedReply }
            if let index = ledger.open.firstIndex(where: { $0.request.request == requestID }),
               ledger.open[index].keptName != keptName {
                ledger.open[index].keptName = keptName
                persist()
            }
            publish()
            try mayGo()
            plotted = PlottedPDF(path: path, contentHash: answer.contentHash, keptName: keptName, note: answer.note)
        }
        let path = open.request.dropboxPath
        if PlotRequestFormat.isRequestPath(path) { _ = try await session.delete(path) }
        ledger.open.removeAll { $0.request.request == requestID }
        if let plotted {
            ledger.plotted[entry] = plotted
            ledger.failed[entry] = nil
        } else if ledger.open.allSatisfy({ $0.request.id != entry }) {
            ledger.failed[entry] = reason
        }
        persist()
    }

    // MARK: Telling the app

    private func progress(of open: OpenPlot) -> PlotProgress {
        let stage = PlotStage.of(sent: open.sent != nil, answer: open.answer, checkedIn: checkedIn,
                                 checkInKnown: checkInLooked != nil, online: online, pdfKept: open.keptName != nil,
                                 now: now())
        return PlotProgress(entry: open.request.id, request: open.request.request, stage: stage,
                            pdfPath: open.answer?.pdf, contentHash: open.answer?.contentHash, keptName: open.keptName,
                            note: open.answer?.note)
    }

    private func snapshot() -> [String: PlotProgress] {
        var out: [String: PlotProgress] = [:]
        for (entry, reason) in notKept {
            out[entry] = PlotProgress(entry: entry, request: "", stage: .notKept(reason: reason))
        }
        for (entry, reason) in ledger.failed {
            out[entry] = PlotProgress(entry: entry, request: "", stage: .failed(reason: reason))
        }
        for (entry, plot) in ledger.plotted {
            out[entry] = PlotProgress(entry: entry, request: "", stage: .done, pdfPath: plot.path,
                                      contentHash: plot.contentHash, keptName: plot.keptName, note: plot.note)
        }
        // Oldest first, so an entry's newest request has the last word.
        for open in ledger.open { out[open.request.id] = progress(of: open) }
        return out
    }

    private func publish() {
        let now = snapshot()
        guard now != lastReport else { return }
        lastReport = now
        report(now)
    }
}
