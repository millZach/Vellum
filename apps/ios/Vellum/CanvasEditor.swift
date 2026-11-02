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
    /// Changes whenever the ink does, for views that show something about it. An eraser sweep changes it once, when
    /// the sweep ends, so no SwiftUI view updates on every hit; the renderer hears at once, through `onInkChange`.
    private(set) var inkRevision = 0
    /// Where every stroke is, kept in step with the ink, for the eraser and the renderer (ADR-0012).
    @ObservationIgnored private(set) var inkIndex: InkIndex
    /// Told what changed whenever the ink does, so the renderer redraws only that, without waiting on SwiftUI.
    @ObservationIgnored var onInkChange: (@MainActor (InkIndex.Change) -> Void)?
    /// Set once the view has its size and the starting zoom has been applied.
    @ObservationIgnored private var hasPlacedView = false
    private let startingView: StartingView

    /// What the view shows when it first has a size.
    enum StartingView {
        case origin
        case everything
        case region(CanvasRect)
    }

    /// `index`, built off the main thread for a large canvas, must be of the session's ink; nil builds it here.
    init(canvas: VellumCore.Canvas = VellumCore.Canvas(), session: InkSession? = nil, index: InkIndex? = nil,
         saver: CanvasSaver? = nil, startingView: StartingView = .origin) {
        var canvas = canvas
        let session = session ?? InkSession(ink: canvas.ink)
        canvas.ink = Ink()
        self.canvas = canvas
        self.session = session
        inkIndex = index ?? InkIndex(session.ink)
        canUndo = session.canUndo
        canRedo = session.canRedo
        self.saver = saver
        viewport = Viewport(pointsPerInch: Self.startingPointsPerInch, screenWidth: 951, screenHeight: 669)
        self.startingView = startingView
        // Only the test canvas and previews have no saver; the status bar must not say they are saved.
        if saver == nil { saveState = .neverSaved }
    }

    /// The ink, for drawing it. Read it alongside `inkRevision`, which is what changes when it does.
    var ink: Ink { session.ink }
    /// True during an eraser sweep, which bumps `inkRevision` once, when it ends (`endEraserSweep`).
    @ObservationIgnored private var sweeping = false

    /// The rectangle everything on the canvas covers, its ink and text boxes included.
    var extents: CanvasRect? {
        CanvasRect.union([canvas.extents, session.ink.bounds].compactMap { $0 } + session.texts.map(\.rect))
    }

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

    /// The tool in hand. Putting the lasso down lets go of its selection.
    var tool: CanvasTool {
        get { pen.tool }
        set {
            pen.tool = newValue
            if newValue != .lasso { select(.empty) }
        }
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
        sweeping = true
    }

    /// Ends a sweep of the eraser and tells the views reading `inkRevision` what it erased, once.
    func endEraserSweep() {
        guard sweeping else { return }
        sweeping = false
        inkRevision += 1
    }

    /// Erases whole strokes under the eraser: within 8 screen points of the Pencil's tip at this zoom.
    func erase(at point: CanvasPoint) {
        session.erase(at: point, tolerance: viewport.canvasLength(ofScreen: 8), index: inkIndex)
        syncInk()
    }

    func undo() {
        willChangeHistory?()
        endEraserSweep()
        cancelLift()
        session.undo()
        syncInk()
    }

    func redo() {
        willChangeHistory?()
        endEraserSweep()
        cancelLift()
        session.redo()
        syncInk()
    }

    /// Told just before an undo or redo, so a text box being typed in is finished first and its edit is the step
    /// undone.
    @ObservationIgnored var willChangeHistory: (@MainActor () -> Void)?
    /// Told to finish typing in a text box: when the canvas closes or the app leaves the screen.
    @ObservationIgnored var onFinishTextEditing: (@MainActor () -> Void)?

    /// Finishes a text box being typed in, saving its text.
    func finishTextEditing() { onFinishTextEditing?() }

    // MARK: The selection (#7)

    /// What the lasso has selected: not saved, and kept through undo and redo. The status bar's prompt follows it;
    /// the canvas view hears through `onSelectionChange`.
    private(set) var selection = CanvasSelection.empty
    @ObservationIgnored var onSelectionChange: (@MainActor () -> Void)?
    /// Told what each change did to the text boxes, so the canvas view shows them.
    @ObservationIgnored var onTextsChange: (@MainActor (InkChange) -> Void)?
    /// The selection's strokes while they are lifted out of the index to be dragged, and their bounds then.
    @ObservationIgnored private var lifted: [InkStroke]?
    @ObservationIgnored private var liftedBounds: CanvasRect?

    /// The text boxes on the canvas, in the order placed.
    var texts: [TextBox] { session.texts }
    func text(_ id: TextBoxID) -> TextBox? { session.text(id) }

    func select(_ new: CanvasSelection) {
        guard new != selection else { return }
        selection = new
        onSelectionChange?()
    }

    /// Selects what a lasso loop takes (`Lasso`): looked up in the index, never the whole canvas.
    func selectInLoop(_ points: [CanvasPoint]) {
        guard let lasso = Lasso(points) else { return select(.empty) }
        select(lasso.select(in: inkIndex, texts: session.texts))
    }

    /// The rectangle the selection covers, from the index's cached bounds and the text boxes; nil with nothing
    /// selected.
    var selectionBounds: CanvasRect? {
        if let liftedBounds { return liftedBounds }
        var rects: [CanvasRect] = []
        if let box = inkIndex.bounds(of: selection.strokes) { rects.append(box.rect) }
        for id in selection.texts { if let box = session.text(id) { rects.append(box.rect) } }
        return CanvasRect.union(rects)
    }

    /// Takes the selection's strokes out of the index, so the tiles redraw without them, and returns them to be
    /// dragged on a layer of their own. `dropSelection` puts them back, moved or not.
    func liftSelection() -> [InkStroke] {
        cancelLift()
        let bounds = selectionBounds
        let strokes = selection.strokes.compactMap { inkIndex.stroke($0) }
        liftedBounds = bounds
        lifted = strokes
        if !strokes.isEmpty { onInkChange?(inkIndex.apply(InkChange(removed: strokes.map(\.id)))) }
        return strokes
    }

    /// Ends a drag: the selection moved or resized by `transform` as one undo step, saved as its ids and the
    /// transform; an identity transform puts the strokes back as they were.
    func dropSelection(_ transform: CanvasTransform) {
        guard let strokes = lifted else { return }
        lifted = nil
        liftedBounds = nil
        if !transform.isIdentity, session.transform(selection, by: transform) {
            syncInk()
        } else if !strokes.isEmpty {
            onInkChange?(inkIndex.apply(InkChange(added: strokes)))
        }
    }

    private func cancelLift() { dropSelection(.identity) }

    /// Duplicates the selection, the copies 30 points down and right at this zoom, and selects the copies.
    func duplicateSelection() {
        let offset = viewport.canvasLength(ofScreen: 30)
        session.duplicate(selection, by: .translation(dx: offset, dy: offset))
        syncInk()
    }

    func deleteSelection() {
        session.delete(selection)
        syncInk()
    }

    // MARK: Text boxes (#7)

    /// Places a text box with its text, in the markup colour in hand. Empty text places nothing.
    @discardableResult
    func addText(_ text: String, at origin: CanvasPoint, width: Length, height: Length, fontSize: Length) -> TextBox? {
        let box = session.addText(text, at: origin, size: CanvasSize(width: width, height: height), fontSize: fontSize,
                                  colour: pen.colour)
        syncInk()
        return box
    }

    /// Changes a text box's text and height; emptied, it is deleted.
    func editText(_ id: TextBoxID, text: String, height: Length) {
        session.editText(id, text: text, height: height)
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
        onDebugOpenStroke?(stroke)
    }

    /// Set by the ink view, which shows the open stroke in its live layers.
    @ObservationIgnored var onDebugOpenStroke: ((StrokeInProgress) -> Void)?
    #endif

    /// Follows the change the session just made: the index and the renderer take its delta (strokes added, ids
    /// taken away) without reading the rest of the ink, and the change goes to the saver.
    private func syncInk() {
        // Nothing to follow when the change did nothing (an empty stroke, undo with nothing to undo).
        guard !session.unsavedEvents.isEmpty else { return }
        let change = session.lastChange
        inkDidChange?(change)
        onInkChange?(inkIndex.apply(change))
        if change.touchesText { onTextsChange?(change) }
        if let after = session.selectionAfterLastChange {
            select(after)
        } else if !selection.isEmpty, !change.removed.isEmpty || !change.removedTexts.isEmpty {
            // Whatever a change took away is no longer selected.
            select(CanvasSelection(strokes: selection.strokes.filter { inkIndex.contains($0) },
                                   texts: selection.texts.filter { session.text($0) != nil }))
        }
        if !sweeping { inkRevision += 1 }
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
            Task { @MainActor in self?.didSave(state) }
        }
        // Only say "Saving…" if the write is still going after a moment; most take well under a millisecond.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.savesInFlight > 0, self.saveState == .savedOnThisDuo else { return }
            self.saveState = .saving
        }
    }

    /// The saver's state changed on its own: a failed write or flush retried and written, or failing again.
    func saveStateDidChange(_ state: SaveState) {
        if !state.isSaved {
            saveState = state
        } else if savesInFlight == 0 {
            saveState = .savedOnThisDuo
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
