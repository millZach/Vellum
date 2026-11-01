import Observation
import VellumCore

/// One canvas open on the canvas screen: what is on it, what part of it is on screen, and the tool in hand. Ink is
/// kept in memory for the session; saving it is #9, and the status bar says "Not saved yet" until then.
@MainActor
@Observable
final class CanvasEditor {
    /// The space the drafting rail's chrome takes from the canvas view, for fitting things into what is left: the tool
    /// rail on the left, the top bar, the status bar, and the iOS tab rail on the right.
    static let chromeInsets = ScreenInsets(top: 56, left: 70, bottom: 50, right: 92)

    /// Where a new canvas opens: about 45 feet across the Duo's free width.
    static let startingPointsPerInch = 1.5

    var canvas: VellumCore.Canvas
    private(set) var session: InkSession
    var viewport: Viewport
    /// The tool, markup colour and line weights in hand. A stroke takes them at touchdown (`beginStroke`).
    var pen = PenSettings()
    /// Where the Pencil last touched the canvas. The Duo has no hover, so this is the last touch, not a live cursor.
    var penPosition: CanvasPoint?
    let saveState = SaveState.notSavedYet
    /// Changes whenever the ink does, so the ink view knows to redraw.
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

    init(canvas: VellumCore.Canvas = VellumCore.Canvas(), startingView: StartingView = .origin) {
        self.canvas = canvas
        session = InkSession(ink: canvas.ink)
        inkIndex = InkIndex(canvas.ink)
        viewport = Viewport(pointsPerInch: Self.startingPointsPerInch, screenWidth: 951, screenHeight: 669)
        self.startingView = startingView
    }

    var ink: Ink { session.ink }
    var canUndo: Bool { session.canUndo }
    var canRedo: Bool { session.canRedo }

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
        let erased = session.erase(at: point, tolerance: viewport.canvasLength(ofScreen: 8), index: inkIndex)
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
        if let extents = canvas.extents {
            viewport.fit(extents, insets: Self.chromeInsets)
        } else {
            viewport = Viewport(pointsPerInch: Self.startingPointsPerInch, screenWidth: viewport.screenWidth,
                                screenHeight: viewport.screenHeight)
        }
    }

    private func syncInk() {
        canvas.ink = session.ink
        inkRevision += 1
        let change = inkIndex.sync(with: session.ink)
        onInkChange?(change)
    }
}
