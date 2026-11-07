import Foundation
import Network
import Observation
import UIKit
import VellumCore

/// The Canvases tab: every canvas on the Duo, the one selected in the list, and the one open on the canvas screen.
/// No file work runs on the main thread: finding the library, listing it, opening, closing and deleting all run off
/// it, and every canvas's files belong to its one saver (`CanvasSavers`), so reopening or deleting a canvas waits for
/// what is still being written to it.
@MainActor
@Observable
final class CanvasesModel {
    private(set) var summaries: [CanvasSummary] = []
    private(set) var previews: [UUID: CanvasPreviews.Info] = [:]
    /// Changes when a canvas's thumbnail has been redrawn, so the preview pane reloads it.
    private(set) var previewRevision = 0
    var selection: UUID?
    /// The canvas on the canvas screen, or nil for the list.
    private(set) var openEditor: CanvasEditor?
    /// The made-up 10,000-stroke test canvas while it is shown in place of `openEditor` (`TestCanvas`). It has no
    /// saver: it is never saved, never listed, and never remembered as the canvas to reopen.
    private(set) var testEditor: CanvasEditor?
    /// Set while a canvas is being opened, so the list shows it is on its way.
    private(set) var opening: UUID?
    private(set) var hasLoaded = false
    /// Set once launch has reopened the last canvas or decided to show the list.
    private(set) var hasLaunched = false
    /// A problem to show, in plain words.
    var problem: String?
    /// Canvases whose changes are not yet all written to the Duo, and why: shown on the list until they are, because
    /// their saver keeps the changes and keeps trying.
    private(set) var unsaved: [UUID: SaveState] = [:]

    /// Where each canvas's sync to Dropbox stands (#12), as the sync engine last said.
    private(set) var syncReport = SyncReport.off
    /// Mirrors the canvases to `Dropbox/Vellum` off the main thread; nil until launch has found the library.
    @ObservationIgnored private(set) var sync: CanvasSync?
    @ObservationIgnored private var connection: ConnectionWatcher?

    /// Found off the main thread at launch; nil until then, or when the Duo has no folder for Vellum.
    private(set) var library: CanvasLibrary?
    @ObservationIgnored private(set) var savers: CanvasSavers?
    /// Where the open canvas is remembered, so the app reopens it after it is closed or killed.
    private static let lastOpenKey = "lastOpenCanvas"

    init() {}

    var lastOpened: UUID? {
        get { UserDefaults.standard.string(forKey: Self.lastOpenKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.lastOpenKey) }
    }

    /// Finds (and makes, the first time) the canvases' folder, off the main thread, and starts syncing.
    func prepare() async {
        guard library == nil else { return }
        guard let found = await Task.detached(priority: .userInitiated, operation: { () -> (CanvasLibrary, SyncLedgerFile?)? in
            guard let library = try? CanvasLibrary.onThisDevice() else { return nil }
            return (library, try? SyncLedgerFile.onThisDevice())
        }).value else {
            problem = "Vellum could not find its folder on this Duo."
            return
        }
        let (library, ledger) = found
        self.library = library
        let thumbnails = PreviewThumbnails(didWrite: { [weak self] id in
            Task { @MainActor in self?.thumbnailDidChange(id) }
        })
        let savers = CanvasSavers(library: library, thumbnails: thumbnails, report: { [weak self] id, state in
            Task { @MainActor in self?.saveStateDidChange(id, state) }
        })
        self.savers = savers
        startSync(savers: savers, ledger: ledger)
    }

    // MARK: Syncing to Dropbox (#12)

    /// Starts the sync engine over the app's Dropbox session (or, in Debug captures, the made-up Dropbox), and the
    /// connection watcher that tells it when the Duo is online. Nothing here waits for it.
    private func startSync(savers: CanvasSavers, ledger: SyncLedgerFile?) {
        let (session, madeUp) = SyncSetup.session()
        startSymbols(session: session)
        guard let ledger else { return }
        let sync = CanvasSync(session: session, source: savers, ledger: ledger, report: { [weak self] report in
            Task { @MainActor in self?.syncReport = report }
        })
        self.sync = sync
        if session != nil, !madeUp {
            // Any path will do, Wi-Fi or cellular, Low Data Mode or not (Zach's decision 2).
            connection = ConnectionWatcher { online in
                Task { await sync.setOnline(online) }
                // The symbol library syncs when the connection returns too (#41).
                if online { Task { @MainActor in SymbolShelf.shared.syncNow() } }
            }
        }
        Task { await sync.start() }
    }

    /// Reads the symbol library every canvas shares and starts its sync with `Dropbox/Vellum/Symbols` (#41), off the
    /// main thread. In Debug captures with the made-up Dropbox (`--ui-sync`) the library syncs to it as well.
    private func startSymbols(session: DropboxSession?) {
        Task {
            guard let found = await Task.detached(priority: .utility, operation: {
                () -> (SymbolFolder, SymbolSyncLedgerFile)? in
                guard let folder = try? SymbolFolder.onThisDevice(), let ledger = try? SymbolSyncLedgerFile.onThisDevice()
                else { return nil }
                return (folder, ledger)
            }).value else { return }
            let sync = SymbolSync(session: session, store: found.0, ledger: found.1)
            await SymbolShelf.shared.start(store: found.0, sync: sync)
        }
    }

    /// The sync state of a canvas, for the status bar and the list.
    func syncState(of id: UUID?) -> CanvasSyncState {
        guard let id else { return .off }
        return syncReport.state(of: id)
    }

    /// The list's line about syncing, or nil.
    var syncBanner: SyncStatusLine? {
        let names = Dictionary(summaries.map { ($0.id, $0.name) }) { $1 }
        return SyncStatusLine.listBanner(syncReport, canvases: summaries.map(\.id), names: names)
    }

    /// Retry, from the status bar or the list.
    func retrySync() {
        guard let sync else { return }
        Task { await sync.retryNow() }
    }

    /// Zach signed in or out of Dropbox.
    func dropboxSignInChanged() {
        SymbolShelf.shared.syncNow()
        guard let sync else { return }
        Task { await sync.signInChanged() }
    }

    /// Reads the list off the main thread.
    func refresh() async {
        guard let library else { return }
        let result = await Task.detached(priority: .userInitiated) { () -> ([CanvasSummary], [UUID: CanvasPreviews.Info]) in
            library.removeLeftovers()
            let summaries = (try? library.list()) ?? []
            var previews: [UUID: CanvasPreviews.Info] = [:]
            for summary in summaries { previews[summary.id] = CanvasPreviews.info(for: summary.id) }
            return (summaries, previews)
        }.value
        summaries = result.0
        previews = result.1
        previewRevision += 1
        if selection == nil || !summaries.contains(where: { $0.id == selection }) { selection = summaries.first?.id }
        hasLoaded = true
    }

    /// On launch: reopen the canvas that was open when the app was last closed or killed, else show the list.
    func launch() async {
        await prepare()
        await refresh()
        if let last = lastOpened, summaries.contains(where: { $0.id == last }) {
            await open(last)
        }
        hasLaunched = true
    }

    /// For debug launches that open their own canvas.
    func finishLaunch() { hasLaunched = true }

    func newCanvas() async {
        guard let library else { return }
        do {
            let made = try await Task.detached { try library.create() }.value
            await refresh()
            selection = made.id
            await open(made.id)
        } catch {
            problem = "The new canvas could not be made: \(error.localizedDescription)"
        }
    }

    /// Opens a canvas on the canvas screen: by default zoomed to everything on it, or at the origin when it is empty.
    /// A canvas still being written since it was closed opens with everything handed to it, from the same saver.
    func open(_ id: UUID, startingView: CanvasEditor.StartingView? = nil) async {
        guard let savers, opening == nil else { return }
        opening = id
        defer { opening = nil }
        do {
            let (manifest, session, saver) = try await savers.open(id)
            let canvas = VellumCore.Canvas(name: manifest.name, units: manifest.canvasUnits)
            // The renderer's index of a large canvas takes a while to build: off the main thread.
            let index = await Task.detached(priority: .userInitiated) { InkIndex(session.ink) }.value
            let editor = CanvasEditor(canvas: canvas, session: session, index: index, saver: saver,
                                      startingView: startingView ?? (session.ink.isEmpty ? .origin : .everything))
            if let state = unsaved[id] { editor.saveStateDidChange(state) }
            openEditor = editor
            selection = id
            lastOpened = id
            if let sync { Task { await sync.canvasOpened(id) } }
        } catch {
            problem = "That canvas could not be opened: \(error)"
        }
    }

    // MARK: From the drawing viewer (#69)

    /// Place on a canvas: opens the canvas picked (closing the one open, if another), where the sheet waits as a
    /// true-size outline for a tap, exactly as Add sheet's last step leaves it.
    func place(_ pending: CanvasEditor.PendingSheet, on id: UUID) async {
        testEditor = nil
        if openEditor?.canvasID != id {
            if openEditor != nil { closeCanvas() }
            await open(id)
        }
        guard let editor = openEditor, editor.canvasID == id else { return }
        editor.cancelPlacing()
        editor.beginPlacing(pending)
    }

    /// Open in a new canvas: makes a canvas named after the drawing and opens it with the sheet placed in its middle,
    /// at its scale, as one step; the view starts on the sheet.
    func openNewCanvas(named name: String, with pending: CanvasEditor.PendingSheet) async {
        guard let library else { return }
        testEditor = nil
        if openEditor != nil { closeCanvas() }
        do {
            let made = try await Task.detached { try library.create(name: name) }.value
            await refresh()
            selection = made.id
            let size = pending.sheet.size
            let room = CanvasRect(origin: CanvasPoint(x: -size.width / 2, y: -size.height / 2), size: size)
            await open(made.id, startingView: .region(room))
            guard let editor = openEditor, editor.canvasID == made.id else { return }
            _ = await editor.place(pending, centredAt: .origin)
        } catch {
            problem = "The new canvas could not be made: \(error.localizedDescription)"
        }
    }

    /// Opens the test canvas, built off the main thread, over whatever canvas is open, or closes it and goes back to
    /// that canvas.
    func toggleTestCanvas() {
        if testEditor != nil {
            testEditor = nil
        } else {
            Task { await openTestCanvas() }
        }
    }

    func openTestCanvas() async {
        guard testEditor == nil else { return }
        let (canvas, index) = await Task.detached(priority: .userInitiated) { () -> (VellumCore.Canvas, InkIndex) in
            let canvas = TestCanvas.make()
            return (canvas, InkIndex(canvas.ink))
        }.value
        let editor = TestCanvas.editor(for: canvas, index: index)
        testEditor = editor
    }

    /// Back to the list. The canvas's saver writes and flushes what it was handed and redraws the thumbnail; if the
    /// Duo is full it keeps the changes and keeps trying, and the list says so.
    func closeCanvas() {
        // From the test canvas, the list's chevron closes it and the canvas under it, which is saved as always.
        testEditor = nil
        guard let editor = openEditor else { return }
        editor.finishTextEditing()
        openEditor = nil
        lastOpened = nil
        if let saver = editor.saver, let savers {
            savers.close(saver) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            // Queued behind the saver's flush (the sync reads through the same saver); leaving waits for neither.
            if let sync { Task { await sync.canvasLeft(saver.id) } }
        }
        Task { await refresh() }
    }

    func rename(_ id: UUID, to name: String) async {
        guard let library else { return }
        do {
            _ = try await Task.detached { try library.rename(id, to: name) }.value
            if let sync { Task { await sync.canvasChanged(id) } }
            await refresh()
        } catch {
            problem = "The canvas could not be renamed: \(error.localizedDescription)"
        }
    }

    /// Deletes a canvas once everything still being written to it has finished.
    func delete(_ id: UUID) async {
        guard let savers else { return }
        do {
            // Queued first, so a crash after the delete still moves the Dropbox copy to Vellum/.deleted.
            await sync?.canvasWillBeDeleted(id)
            try await savers.delete(id)
            unsaved[id] = nil
            if lastOpened == id { lastOpened = nil }
            if selection == id { selection = nil }
            await refresh()
        } catch {
            problem = "The canvas could not be deleted: \(error.localizedDescription)"
        }
    }

    /// What the list says about canvases whose changes are not all written yet, in plain words; nil when every
    /// change is on the Duo.
    var unsavedMessage: String? {
        let waiting = unsaved.filter { $0.key != openEditor?.canvasID }
        guard !waiting.isEmpty else { return nil }
        let names = waiting.keys.compactMap { id in summaries.first { $0.id == id }?.name }.sorted()
        let which = names.isEmpty ? "A canvas" : names.map { "“\($0)”" }.joined(separator: ", ")
        let full = waiting.values.contains(.notSaved(outOfSpace: true))
        return full
            ? "\(which) is not fully saved: this Duo is full. Free up some space; Vellum keeps the ink and keeps trying."
            : "\(which) is not fully saved yet. Vellum keeps the ink and keeps trying."
    }

    private func saveStateDidChange(_ id: UUID, _ state: SaveState) {
        if state.isSaved { unsaved[id] = nil } else { unsaved[id] = state }
        if let editor = openEditor, editor.canvasID == id { editor.saveStateDidChange(state) }
    }

    private func thumbnailDidChange(_ id: UUID) {
        previews[id] = nil
        Task {
            let info = await Task.detached { CanvasPreviews.info(for: id) }.value
            previews[id] = info
            previewRevision += 1
        }
    }

    /// The app is leaving the screen: flush every canvas still being written to storage while iOS still lets it run.
    /// Going to the background (not just inactive, as under Control Center) also syncs every canvas waiting to.
    func appWillLeaveScreen(background: Bool) {
        // A text box being typed in is saved first, so its text is flushed with everything else.
        openEditor?.finishTextEditing()
        guard let savers else { return }
        let task = BackgroundTask.begin()
        let sync = sync
        savers.flushAll {
            // Then every canvas waiting to sync, the one on screen too, in the time iOS gives; what doesn't finish
            // waits in the outbox.
            guard background, let sync else { return task.end() }
            Task {
                await sync.setInBackground(true)
                await sync.drained()
                task.end()
            }
        }
    }

    /// The app is back on screen: the canvas on screen waits again until Zach leaves it.
    func appDidBecomeActive() {
        // A symbol the laptop put in Dropbox comes down when the app comes back (#41).
        SymbolShelf.shared.syncNow()
        guard let sync else { return }
        Task { await sync.setInBackground(false) }
    }

    #if DEBUG
    /// For the sync captures (#12): a canvas shown as not fully saved, beside the sync states.
    func debugMarkUnsaved(_ id: UUID, _ state: SaveState) { unsaved[id] = state }
    #endif

    /// The app is being terminated: flush every canvas, waiting a moment for it. The flushing runs on the savers'
    /// queues; the main thread only waits, since after this there is no later.
    func appWillTerminate() {
        // A tag or a text box still being typed is saved first, as when the app leaves the screen.
        openEditor?.finishTextEditing()
        guard let savers else { return }
        let finished = DispatchSemaphore(value: 0)
        savers.flushAll { finished.signal() }
        _ = finished.wait(timeout: .now() + 3)
    }
}

/// Asks iOS for a moment to finish writing after the app leaves the screen.
final class BackgroundTask: @unchecked Sendable {
    private var id: UIBackgroundTaskIdentifier = .invalid
    private let lock = NSLock()

    @MainActor
    static func begin() -> BackgroundTask {
        let task = BackgroundTask()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "Save canvas") { task.end() }
        return task
    }

    func end() {
        lock.lock()
        let id = self.id
        self.id = .invalid
        lock.unlock()
        guard id != .invalid else { return }
        Task { @MainActor in UIApplication.shared.endBackgroundTask(id) }
    }
}

/// Tells the sync engine whether the Duo has a connection, from `NWPathMonitor`, on its own queue.
final class ConnectionWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()

    init(_ changed: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in changed(path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "com.millzach.vellum.connection", qos: .utility))
    }

    deinit { monitor.cancel() }
}

/// The Dropbox session sync runs on: the app's own (`DropboxConnection.app`), so signing out stops it; in Debug
/// builds, the made-up Dropbox when `--ui-sync` asks for it. Returns whether it is made up.
enum SyncSetup {
    @MainActor
    static func session() -> (DropboxSession?, Bool) {
        #if DEBUG
        if let session = DebugSync.session() { return (session, true) }
        // The sheet captures' made-up Dropbox only lists and downloads, so syncing to it would fail behind the sheet.
        if DebugLaunch.argument("--ui-dropbox") != nil { return (nil, false) }
        #endif
        return (DropboxConnection.app.downloads, false)
    }
}
