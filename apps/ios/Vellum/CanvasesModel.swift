import Foundation
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

    /// Finds (and makes, the first time) the canvases' folder, off the main thread.
    func prepare() async {
        guard library == nil else { return }
        guard let library = await Task.detached(priority: .userInitiated, operation: { try? CanvasLibrary.onThisDevice() }).value else {
            problem = "Vellum could not find its folder on this Duo."
            return
        }
        self.library = library
        let thumbnails = PreviewThumbnails(didWrite: { [weak self] id in
            Task { @MainActor in self?.thumbnailDidChange(id) }
        })
        savers = CanvasSavers(library: library, thumbnails: thumbnails, report: { [weak self] id, state in
            Task { @MainActor in self?.saveStateDidChange(id, state) }
        })
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
        } catch {
            problem = "That canvas could not be opened: \(error)"
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
        }
        Task { await refresh() }
    }

    func rename(_ id: UUID, to name: String) async {
        guard let library else { return }
        do {
            _ = try await Task.detached { try library.rename(id, to: name) }.value
            await refresh()
        } catch {
            problem = "The canvas could not be renamed: \(error.localizedDescription)"
        }
    }

    /// Deletes a canvas once everything still being written to it has finished.
    func delete(_ id: UUID) async {
        guard let savers else { return }
        do {
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
    func appWillLeaveScreen() {
        // A text box being typed in is saved first, so its text is flushed with everything else.
        openEditor?.finishTextEditing()
        guard let savers else { return }
        let task = BackgroundTask.begin()
        savers.flushAll { task.end() }
    }

    /// The app is being terminated: flush every canvas, waiting a moment for it. The flushing runs on the savers'
    /// queues; the main thread only waits, since after this there is no later.
    func appWillTerminate() {
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
