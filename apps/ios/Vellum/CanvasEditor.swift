import Foundation
import Observation
import VellumCore

/// One canvas open on the canvas screen: what is on it, what part of it is on screen, and the tool in hand. Every
/// change to the ink is handed to its `CanvasSaver` as it is made and written on the Duo off the main thread
/// (ADR-0014); the status bar says "Saved on this Duo" once it is.
@MainActor
@Observable
final class CanvasEditor {
    /// The space the drafting rail's chrome takes from the canvas view, for fitting things into what is left: the tool
    /// rail on the left, the top bar, the status bar, and the iOS tab rail on the right.
    static let chromeInsets = ScreenInsets(top: 56, left: 70, bottom: 50, right: 92)

    /// Where a new canvas opens: about 45 feet across the Duo's free width.
    static let startingPointsPerInch = 1.5

    /// The canvas's name, units, sheets and frames. Its ink is not kept here but in `session`, the one owner of the
    /// ink: two values sharing the stroke list would make every change copy the whole canvas.
    var canvas: VellumCore.Canvas
    /// The ink and its undo history. Not observed: SwiftUI's observation would read it out and write it back on every
    /// change, sharing the stroke list for that moment and copying it. Views follow `inkRevision`, `canUndo` and
    /// `canRedo` instead.
    @ObservationIgnored private var session: InkSession
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// Told what each change did to the ink (strokes added, strokes taken away), for anything kept in step with it.
    @ObservationIgnored var inkDidChange: ((InkChange) -> Void)?
    var viewport: Viewport
    /// The tool, markup colour and line weights in hand. A stroke takes them at touchdown (`beginStroke`).
    var pen = PenSettings()
    /// Where the Pencil last touched the canvas. The Duo has no hover, so this is the last touch, not a live cursor.
    var penPosition: CanvasPoint?
    /// Whether every change is written on the Duo. "Saving…" only shows when a write takes long enough to notice.
    private(set) var saveState = SaveState.savedOnThisDuo
    /// Changes handed to the saver and not yet written.
    @ObservationIgnored private var savesInFlight = 0
    /// Saves the canvas; nil for a canvas that is only in memory (previews).
    let saver: CanvasSaver?
    /// The canvas's id on the Duo; nil for one only in memory.
    var canvasID: UUID? { saver?.id }
    /// Changes whenever the ink does, so the ink view knows to redraw.
    private(set) var inkRevision = 0
    /// Set once the view has its size and the starting zoom has been applied.
    @ObservationIgnored private var hasPlacedView = false
    private let startingView: StartingView

    /// What the view shows when it first has a size.
    enum StartingView {
        case origin
        case everything
        case region(CanvasRect)
    }

    init(canvas: VellumCore.Canvas = VellumCore.Canvas(), session: InkSession? = nil, saver: CanvasSaver? = nil,
         startingView: StartingView = .origin) {
        var canvas = canvas
        let session = session ?? InkSession(ink: canvas.ink)
        canvas.ink = Ink()
        self.canvas = canvas
        self.session = session
        canUndo = session.canUndo
        canRedo = session.canRedo
        self.saver = saver
        viewport = Viewport(pointsPerInch: Self.startingPointsPerInch, screenWidth: 951, screenHeight: 669)
        self.startingView = startingView
    }

    /// The ink, for drawing it. Read it alongside `inkRevision`, which is what changes when it does.
    var ink: Ink { session.ink }

    /// The rectangle everything on the canvas covers, its ink included.
    var extents: CanvasRect? { CanvasRect.union([canvas.extents, session.ink.bounds].compactMap { $0 }) }

    /// The canvas units, saved with the canvas's name when they change.
    var units: CanvasUnits {
        get { canvas.units }
        set {
            guard newValue != canvas.units else { return }
            canvas.units = newValue
            saver?.setUnits(newValue)
            inkRevision += 1  // the grid follows the units
        }
    }

    var tool: CanvasTool {
        get { pen.tool }
        set { pen.tool = newValue }
    }

    var colour: MarkupColour {
        get { pen.colour }
        set { pen.colour = newValue }
    }

    var weight: LineWeight {
        get { pen.weight }
        set { pen.weight = newValue }
    }

    /// Called by the ink view whenever its size changes.
    func viewDidResize(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        if viewport.screenWidth != width || viewport.screenHeight != height {
            viewport.screenWidth = width
            viewport.screenHeight = height
        }
        guard !hasPlacedView else { return }
        hasPlacedView = true
        switch startingView {
        case .origin:
            viewport.centre = .origin
        case .everything:
            zoomToEverything()
        case .region(let rect):
            viewport.fit(rect, insets: Self.chromeInsets)
        }
    }

    /// Starts a stroke where the Pencil touched down, with the pen, colour, weight and zoom as they are now; nil when
    /// the tool in hand leaves no ink.
    func beginStroke(at point: CanvasPoint) -> StrokeInProgress? {
        pen.beginStroke(at: point, pointsPerInch: viewport.pointsPerInch)
    }

    /// Tells the saver whether the Pencil is on the glass, so tidying the saved ink waits for it to lift.
    func pencilDidTouch(_ down: Bool) {
        saver?.setPencilDown(down)
    }

    /// Adds a stroke the Pencil has finished to the ink.
    func commit(_ stroke: StrokeInProgress) {
        session.commit(stroke)
        syncInk()
    }

    /// Starts a sweep of the eraser, which undoes as one step.
    func beginEraserSweep() {
        session.beginEraserSweep()
    }

    /// Erases whole strokes under the eraser: within 8 screen points of the Pencil's tip at this zoom.
    func erase(at point: CanvasPoint) {
        let erased = session.erase(at: point, tolerance: viewport.canvasLength(ofScreen: 8))
        if !erased.isEmpty { syncInk() }
    }

    func undo() {
        session.undo()
        syncInk()
    }

    func redo() {
        session.redo()
        syncInk()
    }

    func zoomToEverything() {
        if let extents {
            viewport.fit(extents, insets: Self.chromeInsets)
        } else {
            viewport = Viewport(pointsPerInch: Self.startingPointsPerInch, screenWidth: viewport.screenWidth,
                                screenHeight: viewport.screenHeight)
        }
    }

    #if DEBUG
    /// A stroke shown as if the Pencil were still drawing it, never committed: for the kill-and-reopen captures.
    private(set) var debugOpenStroke: StrokeInProgress?

    func showDebugOpenStroke(_ stroke: StrokeInProgress) {
        debugOpenStroke = stroke
        inkRevision += 1
    }
    #endif

    private func syncInk() {
        // Nothing to follow when the change did nothing (an empty stroke, undo with nothing to undo).
        guard !session.unsavedEvents.isEmpty else { return }
        inkDidChange?(session.lastChange)
        inkRevision += 1
        if canUndo != session.canUndo { canUndo = session.canUndo }
        if canRedo != session.canRedo { canRedo = session.canRedo }
        save()
    }

    /// Hands the changes just made to the saver: a queue hand-off, so the Pencil never waits on storage.
    private func save() {
        let events = session.takeEvents()
        guard !events.isEmpty, let saver else { return }
        savesInFlight += 1
        saver.save(events) { [weak self] state in
            self?.didSave(state)
        }
        // Only say "Saving…" if the write is still going after a moment; most take well under a millisecond.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.savesInFlight > 0, self.saveState == .savedOnThisDuo else { return }
            self.saveState = .saving
        }
    }

    private func didSave(_ state: SaveState) {
        savesInFlight = max(0, savesInFlight - 1)
        if !state.isSaved {
            saveState = state
        } else if savesInFlight == 0 {
            saveState = .savedOnThisDuo
        }
    }
}
