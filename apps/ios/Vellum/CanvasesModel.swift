import Foundation
import Observation
import UIKit
import VellumCore

/// The Canvases tab: every canvas on the Duo, the one selected in the list, and the one open on the canvas screen.
/// File work runs off the main thread; the list reads only canvas.json files and cached previews, never ink.
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
    /// Set while a canvas is being opened, so the list shows it is on its way.
    private(set) var opening: UUID?
    private(set) var hasLoaded = false
    /// Set once launch has reopened the last canvas or decided to show the list.
    private(set) var hasLaunched = false
    /// A problem to show, in plain words.
    var problem: String?

    let library: CanvasLibrary?
    /// Where the open canvas is remembered, so the app reopens it after it is closed or killed.
    private static let lastOpenKey = "lastOpenCanvas"

    init(library: CanvasLibrary? = try? CanvasLibrary.onThisDevice()) {
        self.library = library
        if library == nil { problem = "Vellum could not find its folder on this Duo." }
    }

    var lastOpened: UUID? {
        get { UserDefaults.standard.string(forKey: Self.lastOpenKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.lastOpenKey) }
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
    func open(_ id: UUID, startingView: CanvasEditor.StartingView? = nil) async {
        guard let library, opening == nil else { return }
        opening = id
        defer { opening = nil }
        do {
            let (manifest, session, saver) = try await CanvasSaver.open(id, in: library)
            let canvas = VellumCore.Canvas(name: manifest.name, units: manifest.canvasUnits)
            openEditor = CanvasEditor(canvas: canvas, session: session, saver: saver,
                                      startingView: startingView ?? (session.ink.isEmpty ? .origin : .everything))
            selection = id
            lastOpened = id
        } catch {
            problem = "That canvas could not be opened: \(error)"
        }
    }

    /// Back to the list. The canvas's changes are already written; this flushes them and redraws its thumbnail.
    func closeCanvas() {
        guard let editor = openEditor else { return }
        openEditor = nil
        lastOpened = nil
        editor.saver?.flushNow { [weak self] in
            Task { @MainActor in await self?.refresh() }
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

    func delete(_ id: UUID) async {
        guard let library else { return }
        do {
            try await Task.detached {
                try library.delete(id)
                CanvasPreviews.remove(for: id)
            }.value
            if lastOpened == id { lastOpened = nil }
            if selection == id { selection = nil }
            await refresh()
        } catch {
            problem = "The canvas could not be deleted: \(error.localizedDescription)"
        }
    }

    /// The app is leaving the screen: flush the open canvas to storage while iOS still lets it run.
    func appWillLeaveScreen() {
        guard let saver = openEditor?.saver else { return }
        let task = BackgroundTask.begin()
        saver.flushNow { task.end() }
    }

    /// The app is being terminated: flush and wait.
    func appWillTerminate() {
        openEditor?.saver?.flushAndWait()
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
