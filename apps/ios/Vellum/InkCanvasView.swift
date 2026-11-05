import SwiftUI
import UIKit
import VellumCore

/// The canvas itself: the grid, the ink, and the Pencil drawing on it. Ink is drawn by Vellum's own renderer rather
/// than PencilKit (ADR-0012), so every stroke lives in model space and is drawn through one `Viewport`.
///
/// SwiftUI only tells the view about a new view of the canvas (zoom to everything) and light or dark; ink changes
/// reach it straight from the editor, and its own pans and pinches it applies itself, so neither waits on SwiftUI.
struct InkCanvasView: UIViewRepresentable {
    let editor: CanvasEditor
    let isDark: Bool
    let viewport: Viewport
    let units: CanvasUnits
    /// The Draw with finger switch (#24).
    let fingerDraws: Bool
    /// The tool in hand, so the view can finish typing or drop a lasso when it changes.
    let tool: CanvasTool
    /// The Speed check switch (#42).
    let speedCheck: Bool

    func makeUIView(context: Context) -> InkCanvasUIView {
        InkCanvasUIView(editor: editor)
    }

    func updateUIView(_ view: InkCanvasUIView, context: Context) {
        view.isDark = isDark
        view.units = units
        view.fingerDraws = fingerDraws
        view.tool = tool
        view.speedCheck = speedCheck
        view.viewportJumped()
    }
}

/// Draws the canvas and reads the Pencil. The Pencil draws (or erases); fingers pan and pinch. With Draw with finger
/// on (#24), one finger draws as the Pencil does and two fingers pan and pinch; a finger stroke goes through a
/// `FingerStrokeGate`, so a second finger landing just after the first cancels it. Nothing depends on pressure or
/// hover, which the USB-C Pencil and the Duo don't have (ADR-0001).
///
/// Nothing is drawn in `draw(_:)`. The ground is the layer's colour, the grid is two shape layers of a few dozen
/// lines, and finished ink is cached tiles (`InkTileRenderer`) that a pan or pinch moves without redrawing. The
/// stroke being drawn is chunked shape layers (`LiveStrokeChunks`) in screen points of the view at touchdown: full
/// chunks are built once, each Pencil move rebuilds only the open chunk and the predicted tail, so a move costs the
/// same however long the stroke is, and a pan or pinch mid-stroke changes one transform. When the Pencil lifts, the
/// layers go to the renderer, which shows them until the stroke's tiles are drawn. While
/// a finger or the Pencil is down a display link asks for ProMotion's 120 Hz and publishes the pen's position to the
/// status bar at most once a frame; it stops when the canvas is still.
final class InkCanvasUIView: UIView, UIGestureRecognizerDelegate {
    private let editor: CanvasEditor
    var isDark = false {
        didSet {
            guard isDark != oldValue else { return }
            sheetRenderer.isDark = isDark
            renderer.lightPaper = sheetRenderer.lightPaper
            renderer.isDark = isDark
            textOverlay.isDark = isDark
            annotationOverlay.isDark = isDark
            selectionOverlay.setDark(isDark)
            sheetStrip.applyColours(dark: isDark)
            shapeDrawing.setDark(isDark)
            applyColours()
        }
    }

    /// The tool in hand, set by SwiftUI when it changes. Putting the text box tool down finishes the text being typed;
    /// only the text box tool places text with a tap or the Pencil's handwriting.
    var tool: CanvasTool = .pen {
        didSet {
            guard tool != oldValue else { return }
            textTap.isEnabled = tool == .textBox && editor.placingSheet == nil
            updateSheetTap()
            scribble?.isActive = tool == .textBox
            if oldValue == .textBox { textOverlay.finishEditing() }
            // A polyline part way through is finished, not lost; the tag goes with the tool.
            if oldValue == .lineAndShape {
                shapeDrawing.finishDraft()
                shapeDrawing.clearTag()
            }
            // A measure, a dimension half placed, a window: each belongs to its tool and goes when it is put down.
            // SwiftUI hands the tool over a moment after the editor took it, so state the new tool already started
            // stays.
            if let owner = regionTool, owner != tool { resetLengthsAndRegions(keepingMeasure: false) }
        }
    }

    /// The grid steps by round lengths in the canvas units, so it is redrawn when they change.
    var units: CanvasUnits = .default {
        didSet {
            guard units != oldValue else { return }
            shownViewport = nil
            annotationOverlay.unitsChanged()
            shapeDrawing.refreshTag()
            viewportDidChange()
        }
    }

    /// The Draw with finger switch, set when it changes, never looked up per touch. Off, fingers only pan and pinch
    /// and a touch costs what it did before the switch existed.
    var fingerDraws = FingerDrawingSetting.default {
        didSet {
            guard fingerDraws != oldValue else { return }
            pan.minimumNumberOfTouches = fingerDraws ? 2 : 1
            placeTap.isEnabled = editor.placingSheet != nil && !fingerDraws
            updateSheetTap()
            accessibilityHint = FingerDrawingSetting.accessibilityHint(fingerDraws: fingerDraws)
            fingersOnGlass = 0
        }
    }
    /// The Speed check switch (#42), set when it changes. Off, a gesture costs one branch more than before it existed.
    var speedCheck = SpeedCheckSetting.default {
        didSet {
            guard speedCheck != oldValue, !speedCheck else { return }
            gestureTiming?.cancel()
            gestureTiming = nil
            fingerDownAt = nil
        }
    }
    /// With the Speed check on: the pan or pinch being timed, from touch-down to the fingers lifting.
    private var gestureTiming: GestureTiming?
    /// With the Speed check on: when the first finger of the next gesture touched down.
    private var fingerDownAt: Double?
    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    /// With Draw with finger on: whether the finger stroke in progress is ink yet.
    private var fingerGate = FingerStrokeGate()
    /// With Draw with finger on: fingers on the canvas, so a finger only starts a stroke alone.
    private var fingersOnGlass = 0
    /// A finger's eraser sweep, while it is pending, holds its samples here and erases them once it is confirmed.
    private var holdsEraser = false
    private var heldEraserPoints: [CanvasPoint] = []

    private let renderer: InkTileRenderer
    /// Placed sheets, under the ink (#11).
    private let sheetRenderer: SheetRenderer
    // Placing a sheet (#11): the screen point the waiting sheet's outline is centred on, whether the Pencil (or a
    // finger drawing) is down moving it, whether it moved since the last display frame, and a finger's tap.
    private var placingTip: CGPoint?
    private var placingDown = false
    private var placingMoved = false
    private let placeTap = UITapGestureRecognizer()
    private let minorGrid = CAShapeLayer()
    private let majorGrid = CAShapeLayer()
    /// The stroke being drawn: one layer per chunk, with the group's opacity so a highlighter's chunks don't darken
    /// where they meet, in screen points of `liveBase`, the view at touchdown.
    private var liveLayer = CALayer()
    private var liveChunkLayers: [CAShapeLayer] = []
    private var liveTailLayer = CAShapeLayer()
    private var liveBase: Viewport?
    private var liveChunks = LiveStrokeChunks()
    private var livePredicted: [CanvasPoint] = []
    private var liveTouch: UITouch?
    /// The stroke being drawn, with the pen, colour and width it took at touchdown.
    private var liveStroke: StrokeInProgress?
    private var erasing = false
    /// Whether the saver has been told the Pencil is on the glass.
    private var pencilIsDown = false
    private var lastPinchScale: CGFloat = 1
    private var lastPanTranslation: CGPoint = .zero
    /// The view of the canvas the layers were last placed for.
    private var shownViewport: Viewport?

    /// Runs only while something is moving, asking for 120 Hz.
    private var displayLink: CADisplayLink?
    private var fingersDown = 0
    /// Where the Pencil is, waiting to go to the status bar on the next frame.
    private var pendingPenPosition: CanvasPoint?
    /// The last screen point the Pencil reached, for the hold that snaps a stroke.
    private var lastSample: CGPoint?

    // Snapping (#7): a stroke with the pen or the line and shape tool snaps to a line or a shape when the Pencil holds
    // still at its end; the line tool also snaps when it lifts.
    private var hold = StrokeHold()
    private var liveSnaps = false
    private var liveIsLineTool = false
    private var snappedShape: SnappedShape?

    // The lasso (#7).
    private lazy var selectionOverlay = SelectionOverlay(
        duplicate: { [weak self] in self?.editor.duplicateSelection() },
        delete: { [weak self] in self?.editor.deleteSelection() })
    private var lassoing = false
    private var lassoPoints: [CanvasPoint] = []
    private var lassoBase: Viewport?
    private var lassoPath = CGMutablePath()
    private var lastLassoScreen: CGPoint = .zero
    private var drag: SelectionDrag?

    // A selected sheet (#44): the strip under the top bar, a finger's tap that picks one up, and the turn or move under way.
    private lazy var sheetStrip = SheetStrip(
        turn: { [weak self] quarter in self?.turnSelectedSheet(by: quarter) },
        scaleMenu: { [weak self] in await self?.sheetScaleMenu() ?? [] },
        done: { [weak self] in self?.editor.select(.empty) })
    private let sheetTap = UITapGestureRecognizer()
    private var sheetDrag: SheetDrag?
    /// What the fingers' pan is doing: panning the canvas, or the selected sheet's turn or move.
    private var fingerGesture = FingerGesture.panning
    /// The angle waiting to go to the status bar on the next frame.
    private var pendingTurnStep: CanvasTool.Step?

    private enum FingerGesture {
        case panning
        case sheet
        /// A twist's finger lifted: the rest of the gesture does nothing.
        case finished
    }

    /// A selected sheet's turn or move under way. The sheet's layers, its markups' lifted strokes, text boxes and
    /// dimensions each take one transform a frame; nothing is drawn. It becomes one undo step when it ends.
    private struct SheetDrag {
        enum Kind {
            /// From a canvas point; `moved` once it has gone far enough not to be a tap.
            case move(start: CanvasPoint, moved: Bool)
            /// From the fingers' angle, in degrees; `moved` once it has turned far enough not to be a pair of fingers resting.
            case twist(from: Double, moved: Bool)
        }
        var kind: Kind
        let lift: CanvasEditor.SheetLift
        let base: Viewport
        let layer: CALayer
        var after: Sheet
        var motion: SheetMotion
        var caught = false
        let byFinger: Bool
    }

    /// A drag of the selection: moving it, or resizing it from a corner about the opposite one. The selected strokes
    /// are lifted out of the tiles onto `layer`, in screen points of `base`, and the drag changes only its transform.
    private struct SelectionDrag {
        enum Kind {
            case move
            case resize(anchor: CanvasPoint, corner: CanvasPoint)
        }
        let kind: Kind
        let start: CanvasPoint
        let base: Viewport
        let layer: CALayer
        var transform = CanvasTransform.identity
    }

    // Text boxes (#7).
    private let textOverlay: TextBoxOverlay
    private var scribble: CanvasScribble?
    private let textTap = UITapGestureRecognizer()

    /// The line and shape tool's shapes, tag and number pad (#40).
    private let shapeDrawing: ShapeDrawing

    // Measure, dimension, frame and window (#8).
    private let annotationOverlay: AnnotationOverlay
    private let loupe = Loupe()
    private lazy var windowMenu = WindowMenu(
        zoom: { [weak self] in self?.zoomToWindow() },
        makeFrame: { [weak self] in self?.makeFrameFromWindow() },
        close: { [weak self] in self?.closeWindow() })
    /// The Pencil (or a finger) down with one of these tools, and what it is doing.
    private var regionInput: RegionInput?
    /// Where the tip is now, waiting for the next display frame to be snapped and shown.
    private var regionTip: CGPoint?
    private var regionTipMoved = false
    /// A measure's or dimension's points so far.
    private var firstTarget: PointSnap.Target?
    private var secondPoint: CanvasPoint?
    /// The window chosen, waiting for what to do with it.
    private var chosenWindow: CanvasRect?
    /// The tool whose measure, points, dimension or window is showing; nil when none is.
    private var regionTool: CanvasTool?

    /// What the Pencil is doing with the measure, dimension, frame or window tool while it is down.
    private enum RegionInput {
        /// Finding a measure's or dimension's point: snapped, shown in the loupe, taken on lift.
        case point
        /// Pulling a dimension's line off its two points.
        case pull
        /// Dragging a frame's box from a canvas point.
        case frame(from: CanvasPoint)
        /// Dragging a window from a canvas point.
        case window(from: CanvasPoint)
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        renderer = InkTileRenderer(index: { [unowned editor] in editor.inkIndex })
        sheetRenderer = SheetRenderer(pdfURL: { [unowned editor] sheet in editor.pdfURL(for: sheet) })
        textOverlay = TextBoxOverlay(editor: editor)
        annotationOverlay = AnnotationOverlay(editor: editor)
        shapeDrawing = ShapeDrawing(editor: editor)
        super.init(frame: .zero)
        isOpaque = true
        isMultipleTouchEnabled = true
        heldEraserPoints.reserveCapacity(256)
        for grid in [minorGrid, majorGrid] {
            grid.actions = noAnimations
            grid.fillColor = nil
            layer.addSublayer(grid)
        }
        layer.addSublayer(sheetRenderer.layer)
        layer.addSublayer(renderer.layer)
        layer.addSublayer(renderer.pendingInkLayer)
        annotationOverlay.install(in: self)
        textOverlay.install(in: self)
        selectionOverlay.install(in: self)
        layer.addSublayer(loupe.layer)
        addSubview(windowMenu)
        addSubview(sheetStrip)
        shapeDrawing.install(in: self, below: loupe.layer)
        selectionOverlay.setDark(isDark)
        applyColours()

        editor.onInkChange = { [weak self] change in
            self?.renderer.inkChanged(change)
            self?.updateSelectionOverlay()
        }
        editor.onSelectionChange = { [weak self] in self?.selectionDidChange() }
        editor.onTextsChange = { [weak self] change in self?.textOverlay.textsChanged(change) }
        editor.onAnnotationsChange = { [weak self] change in
            self?.annotationOverlay.annotationsChanged(change)
            self?.updateSelectionOverlay()
        }
        editor.onSheetsChange = { [weak self] change in self?.sheetsDidChange(change) }
        editor.onPlacingChange = { [weak self] in self?.placingDidChange() }
        sheetRenderer.setSheets(editor.sheets)
        editor.onLineShapeChange = { [weak self] in
            self?.shapeDrawing.finishDraft()
            self?.shapeDrawing.clearTag()
        }
        editor.undoShapePoint = { [weak self] in self?.shapeDrawing.undoLastPoint() ?? false }
        editor.willChangeHistory = { [weak self] in
            self?.shapeDrawing.clearTag()
            self?.textOverlay.finishEditing()
            self?.finishSheetDrag(keep: false)
            // Undo part way through a dimension or measure starts it again, as the prototype does.
            self?.resetLengthsAndRegions(keepingMeasure: true)
        }
        editor.onFinishTextEditing = { [weak self] in
            self?.textOverlay.finishEditing()
            self?.shapeDrawing.finishDraft()
        }
        #if DEBUG
        editor.onDebugOpenStroke = { [weak self] stroke in self?.showOpenStroke(stroke) }
        #endif

        let directTouches = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = directTouches
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)

        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = directTouches
        pinch.delegate = self
        addGestureRecognizer(pinch)

        // The text box tool: a tap with a finger or the Pencil places a text box or edits the one tapped; writing with
        // the Pencil places one where the writing starts (Scribble).
        textTap.addTarget(self, action: #selector(handleTextTap(_:)))
        textTap.allowedTouchTypes = directTouches + [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        textTap.isEnabled = false
        textTap.delegate = self
        addGestureRecognizer(textTap)

        // A finger's tap places a sheet waiting to be placed (#11); the Pencil's goes through the touches below.
        placeTap.addTarget(self, action: #selector(handlePlaceTap(_:)))
        placeTap.allowedTouchTypes = directTouches
        placeTap.isEnabled = false
        placeTap.delegate = self
        addGestureRecognizer(placeTap)

        // With the lasso in hand, a finger's tap picks up a sheet (#44); the Pencil's goes through the touches below.
        sheetTap.addTarget(self, action: #selector(handleSheetTap(_:)))
        sheetTap.allowedTouchTypes = directTouches
        sheetTap.isEnabled = false
        sheetTap.delegate = self
        addGestureRecognizer(sheetTap)
        let scribble = CanvasScribble(overlay: textOverlay, host: self) { [weak self] point in self?.placeText(at: point) }
        addInteraction(UIIndirectScribbleInteraction(delegate: scribble))
        self.scribble = scribble

        isAccessibilityElement = true
        accessibilityLabel = "Canvas"
        accessibilityHint = FingerDrawingSetting.accessibilityHint(fingerDraws: fingerDraws)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [minorGrid, majorGrid, sheetRenderer.layer, renderer.layer, renderer.pendingInkLayer] {
            sublayer.frame = bounds
        }
        CATransaction.commit()
        annotationOverlay.resize(to: bounds)
        Pill.displayScale = traitCollection.displayScale
        renderer.displayScale = traitCollection.displayScale
        sheetRenderer.displayScale = traitCollection.displayScale
        editor.viewDidResize(width: Double(bounds.width), height: Double(bounds.height))
        shownViewport = nil
        viewportDidChange()
        #if DEBUG || BENCHMARK
        DebugBenchmark.attach(self, editor: editor)
        #endif
        #if DEBUG
        DebugFingerStroke.attach(self)
        DebugSelection.attach(self, editor: editor)
        DebugMeasureFrame.attach(self, editor: editor)
        DebugSheets.attach(self, editor: editor)
        DebugStatusBar.attach(self, editor: editor)
        DebugDrawingTools.attach(self, editor: editor)
        #endif
    }

    // MARK: Showing the canvas

    /// Places everything for a view of the canvas that the fingers didn't move: zoom to everything, zoom to a window,
    /// the view zooming out for a sheet to be placed. No pinch will end to draw the kept dimensions, frames and labels
    /// again, so they are drawn at the new zoom here (#35). A finger's pan or pinch has already shown its viewport, so
    /// SwiftUI's update following it finds nothing moved and costs one comparison.
    func viewportJumped() {
        let moved = editor.viewport != shownViewport
        viewportDidChange()
        if moved, fingersDown == 0, bounds.width > 0 { annotationOverlay.settle() }
    }

    /// Places everything for the editor's view of the canvas, if it changed: one transform per level of tiles, the
    /// grid's few lines, and one transform for the stroke being drawn, so nothing lags a pan or a pinch.
    func viewportDidChange() {
        let viewport = editor.viewport
        guard viewport != shownViewport, bounds.width > 0 else { return }
        shownViewport = viewport
        let ledger = MainThreadLedger.begin()
        defer { MainThreadLedger.end(.viewMoved, ledger) }
        sheetRenderer.show(viewport)
        renderer.show(viewport)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGrid(viewport)
        if let liveBase { liveLayer.transform = InkTileRenderer.transform(from: liveBase, to: viewport) }
        if let lassoBase { selectionOverlay.loopLayer.transform = InkTileRenderer.transform(from: lassoBase, to: viewport) }
        if let drag {
            drag.layer.transform = Self.transform(from: drag.base, to: viewport, applying: drag.transform)
        }
        if let sheetDrag {
            sheetDrag.layer.transform = Self.transform(from: sheetDrag.base, to: viewport, applying: sheetDrag.motion)
        }
        CATransaction.commit()
        textOverlay.show(viewport)
        annotationOverlay.show(viewport)
        if let chosenWindow { windowMenu.place(under: screenRect(chosenWindow), in: bounds) }
        if case .point? = regionInput { regionTipMoved = true }
        if editor.placingSheet != nil { updatePlacingOutline() }
        updateSelectionOverlay()
        keepSheetDragUnderTip()
        shapeDrawing.viewChanged()
    }

    private func applyColours() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = Palette.ground(dark: isDark).cgColor
        minorGrid.strokeColor = Palette.grid(dark: isDark).withAlphaComponent(isDark ? 0.05 : 0.10).cgColor
        majorGrid.strokeColor = Palette.grid(dark: isDark).withAlphaComponent(isDark ? 0.10 : 0.20).cgColor
        CATransaction.commit()
    }

    /// Minor and major grid lines at round lengths in the canvas units, faint enough to sit under ink.
    private func updateGrid(_ viewport: Viewport) {
        let units = editor.canvas.units
        let minor = ScaleBar.length(fitting: 40, pointsPerInch: viewport.pointsPerInch, units: units).inches
        let major = ScaleBar.length(fitting: 240, pointsPerInch: viewport.pointsPerInch, units: units).inches
        let visible = viewport.visibleRect
        let hairline = 1 / max(1, traitCollection.displayScale)
        for (grid, step) in [(minorGrid, minor), (majorGrid, major)] {
            grid.lineWidth = hairline
            guard step * viewport.pointsPerInch >= 8 else { grid.path = nil; continue }
            let path = CGMutablePath()
            var x = (visible.minX.inches / step).rounded(.down) * step
            while x <= visible.maxX.inches {
                let sx = viewport.screenPoint(for: CanvasPoint(x: .inches(x), y: .zero)).x
                path.move(to: CGPoint(x: sx, y: 0))
                path.addLine(to: CGPoint(x: sx, y: Double(bounds.height)))
                x += step
            }
            var y = (visible.minY.inches / step).rounded(.down) * step
            while y <= visible.maxY.inches {
                let sy = viewport.screenPoint(for: CanvasPoint(x: .zero, y: .inches(y))).y
                path.move(to: CGPoint(x: 0, y: sy))
                path.addLine(to: CGPoint(x: Double(bounds.width), y: sy))
                y += step
            }
            grid.path = path
        }
    }

    // MARK: The stroke being drawn

    private func configure(_ shape: CAShapeLayer) {
        shape.actions = noAnimations
        shape.fillColor = nil
        shape.lineCap = .round
        shape.lineJoin = .round
    }

    private func screenPath(_ points: ArraySlice<CanvasPoint>, _ viewport: Viewport) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        let start = viewport.screenPoint(for: first)
        path.move(to: CGPoint(x: start.x, y: start.y))
        if points.count == 1 { path.addLine(to: CGPoint(x: start.x, y: start.y)) }
        for point in points.dropFirst() {
            let s = viewport.screenPoint(for: point)
            path.addLine(to: CGPoint(x: s.x, y: s.y))
        }
        return path
    }

    private func startLive(_ stroke: StrokeInProgress) {
        let base = editor.viewport
        liveBase = base
        liveChunks = LiveStrokeChunks()
        livePredicted = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A fresh group for each stroke: the last one went to the renderer with its stroke.
        liveLayer = CALayer()
        liveLayer.actions = noAnimations
        liveLayer.allowsGroupOpacity = true
        liveLayer.anchorPoint = .zero
        liveLayer.position = .zero
        liveLayer.bounds = bounds
        liveLayer.opacity = Float(stroke.tool.opacity)
        layer.addSublayer(liveLayer)
        liveTailLayer = CAShapeLayer()
        configure(liveTailLayer)
        liveLayer.addSublayer(liveTailLayer)
        let open = CAShapeLayer()
        configure(open)
        liveLayer.insertSublayer(open, below: liveTailLayer)
        liveChunkLayers = [open]
        let width = max(stroke.width.inches * base.pointsPerInch, InkTileRenderer.minimumWidth)
        for shape in liveChunkLayers + [liveTailLayer] {
            shape.strokeColor = Palette.ink(stroke.colour, dark: isDark).cgColor
            shape.lineWidth = width
        }
        CATransaction.commit()
        updateLive()
    }

    /// Brings the layers up to the stroke's points: freezes chunks that filled, rebuilds the open chunk, and replaces
    /// the predicted tail. The work is the open chunk and the tail, never the whole stroke.
    private func updateLive() {
        guard let stroke = liveStroke, let base = liveBase else { return }
        let update = liveChunks.update(pointCount: stroke.points.count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for range in update.newlyFrozen {
            // The open layer becomes this frozen chunk; a fresh layer takes over as the open one.
            let frozen = liveChunkLayers[liveChunkLayers.count - 1]
            frozen.path = screenPath(stroke.points[range], base)
            let open = CAShapeLayer()
            configure(open)
            open.strokeColor = frozen.strokeColor
            open.lineWidth = frozen.lineWidth
            liveLayer.insertSublayer(open, below: liveTailLayer)
            liveChunkLayers.append(open)
        }
        let open = liveChunkLayers[liveChunkLayers.count - 1]
        open.path = screenPath(stroke.points[update.open], base)
        let tail = LiveStrokeChunks.tail(confirmed: stroke.points, predicted: livePredicted)
        liveTailLayer.path = tail.isEmpty ? nil : screenPath(tail[...], base)
        CATransaction.commit()
    }

    // MARK: The Pencil

    private func draws(_ touch: UITouch) -> Bool {
        touch.type == .pencil || (fingerDraws && touch.type == .direct)
    }

    private func canvasPoint(_ p: CGPoint) -> CanvasPoint {
        editor.viewport.canvasPoint(for: ScreenPoint(x: Double(p.x), y: Double(p.y)))
    }

    private func location(_ touch: UITouch) -> CGPoint { touch.preciseLocation(in: self) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if speedCheck, fingersDown == 0, let finger = touches.first(where: { $0.type == .direct }) {
            fingerDownAt = finger.timestamp
        }
        if fingerDraws {
            var landed = 0, landedAt = 0.0
            for touch in touches where touch.type == .direct {
                landed += 1
                landedAt = touch.timestamp
            }
            fingersOnGlass += landed
            if landed > 0, let live = liveTouch, live.type == .direct { secondFingerDown(at: landedAt) }
            // The Pencil takes over from a finger (a resting hand, most often): a confirmed finger stroke is kept, a
            // pending one dropped, and the Pencil draws as always.
            if let live = liveTouch, live.type == .direct, touches.contains(where: { $0.type == .pencil }) {
                // With a shape in hand, a finger that only rested places nothing: the Pencil takes over (#40).
                let stands = shapeDrawing.isDown ? fingerGate.takenOverByPencil(moved: shapeDrawing.hasMoved)
                    : fingerGate.interrupted()
                endInput(samples: [], keep: stands)
            }
        }
        // A finger starts a stroke only alone on the glass; the Pencil always does.
        guard liveTouch == nil, let touch = touches.first(where: draws),
              touch.type == .pencil || fingersOnGlass == 1 else {
            super.touchesBegan(touches, with: event)
            return
        }
        if touch.type == .pencil {
            guard beginInput(at: location(touch)) else { return super.touchesBegan(touches, with: event) }
        } else {
            guard fingerDown(at: location(touch), time: touch.timestamp) else {
                return super.touchesBegan(touches, with: event)
            }
        }
        liveTouch = touch
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = liveTouch, touches.contains(touch) else {
            super.touchesMoved(touches, with: event)
            return
        }
        if touch.type == .direct { fingerTick(at: touch.timestamp) }
        moveInput(samples: (event?.coalescedTouches(for: touch) ?? [touch]).map(location),
                  predicted: (event?.predictedTouches(for: touch) ?? []).map(location))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if fingerDraws { fingersLifted(touches) }
        guard let touch = liveTouch, touches.contains(touch) else {
            super.touchesEnded(touches, with: event)
            return
        }
        // A finger stroke lifted inside the window was still one finger, so it is kept like the Pencil's.
        let keep = touch.type == .pencil || fingerGate.lift()
        // The final batch can hold several samples since the last move: all of them are the stroke's tail.
        endInput(samples: (event?.coalescedTouches(for: touch) ?? [touch]).map(location), keep: keep)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if fingerDraws { fingersLifted(touches) }
        guard let touch = liveTouch, touches.contains(touch) else {
            super.touchesCancelled(touches, with: event)
            return
        }
        // A Pencil stroke the system interrupts is still Zach's ink: keep what was drawn, tail included. So is a
        // confirmed finger stroke; a pending one is most likely the start of a pan, and is dropped.
        let keep = touch.type == .pencil || fingerGate.interrupted()
        endInput(samples: keep ? (event?.coalescedTouches(for: touch) ?? [touch]).map(location) : [], keep: keep)
    }

    private func fingersLifted(_ touches: Set<UITouch>) {
        for touch in touches where touch.type == .direct { fingersOnGlass -= 1 }
        fingersOnGlass = max(0, fingersOnGlass)
    }

    /// The Pencil touched down at a screen point: starts a stroke or an eraser sweep. False when the tool in hand
    /// does neither.
    func beginInput(at location: CGPoint) -> Bool {
        beginInput(at: location, holdingEraser: false)
    }

    private func beginInput(at location: CGPoint, holdingEraser: Bool) -> Bool {
        if editor.placingSheet != nil {
            // A sheet waits to be placed (#11): the Pencil moves its outline, and lifting places it.
            placingDown = true
            placingTip = location
            placingMoved = true
            startDisplayLink()
            return true
        }
        let point = canvasPoint(location)
        lastSample = location
        // The next thing has started: the tag goes (#40), and the flyout closes.
        shapeDrawing.nextThingStarted()
        if editor.showsShapeFlyout { editor.showsShapeFlyout = false }
        if editor.tool == .lasso {
            beginLasso(at: location, point: point)
        } else if editor.tool.group == .lengthsAndRegions {
            beginRegionInput(at: location, point: point)
        } else if editor.tool == .eraser {
            erasing = true
            if holdingEraser {
                holdsEraser = true
                heldEraserPoints.append(point)
            } else {
                editor.beginEraserSweep()
                editor.erase(at: point)
            }
        } else if editor.tool == .lineAndShape, editor.lineShape != .drawIt {
            shapeDrawing.down(at: location)
        } else if let stroke = editor.beginStroke(at: point) {
            liveStroke = stroke
            liveSnaps = editor.tool == .pen || editor.tool == .lineAndShape
            liveIsLineTool = editor.tool == .lineAndShape
            hold = StrokeHold()
            snappedShape = nil
            startLive(stroke)
        } else {
            return false
        }
        editor.penPosition = point
        // Tidying the saved ink (compaction) waits for the Pencil to lift (ADR-0014).
        editor.pencilDidTouch(true)
        pencilIsDown = true
        startDisplayLink()
        return true
    }

    // MARK: A finger, with Draw with finger on

    /// One finger touched down alone, with Draw with finger on: starts a pending stroke, drawn live at once, or a
    /// pending eraser sweep, which holds its samples. False when the tool in hand does neither.
    func fingerDown(at location: CGPoint, time: Double) -> Bool {
        guard beginInput(at: location, holdingEraser: true) else { return false }
        fingerGate.fingerDown(at: time)
        return true
    }

    /// The finger moved or a frame passed: once the window has passed with one finger the stroke is ink, and a held
    /// eraser sweep erases what it held.
    func fingerTick(at time: Double) {
        guard fingerGate.isPending, fingerGate.tick(at: time) else { return }
        releaseHeldEraser()
    }

    /// A second finger landed while a finger stroke is in progress: inside the window the stroke is dropped, after it
    /// the stroke ends where it is, kept. Either way the fingers go on to pan and pinch.
    func secondFingerDown(at time: Double) {
        switch fingerGate.secondFinger(at: time) {
        case .cancel: endInput(samples: [], keep: false)
        case .end: endInput(samples: [], keep: true)
        case .none: break
        }
    }

    /// The finger lifted, with its last samples.
    func fingerUp(samples: [CGPoint]) {
        endInput(samples: samples, keep: fingerGate.lift())
    }

    private func releaseHeldEraser() {
        guard holdsEraser else { return }
        holdsEraser = false
        editor.beginEraserSweep()
        for point in heldEraserPoints { editor.erase(at: point) }
        heldEraserPoints.removeAll(keepingCapacity: true)
    }

    /// The Pencil moved: its coalesced samples since the last move, and where it is predicted to go.
    func moveInput(samples: [CGPoint], predicted: [CGPoint]) {
        if placingDown {
            if let last = samples.last {
                placingTip = last
                placingMoved = true
            }
            return
        }
        if lassoing || drag != nil || sheetDrag != nil {
            lassoMoved(samples)
            return
        }
        if regionInput != nil {
            regionMoved(samples)
            return
        }
        if shapeDrawing.isDown {
            if let last = samples.last {
                shapeDrawing.moved(to: last)
                pendingPenPosition = canvasPoint(last)
            }
            return
        }
        if snappedShape != nil {
            // Snapped: the shape stays as it is until the Pencil lifts.
            if let last = samples.last {
                pendingPenPosition = canvasPoint(last)
                lastSample = last
            }
            return
        }
        consume(samples, ending: false)
        if !erasing {
            livePredicted = predicted.map(canvasPoint)
            updateLive()
        }
    }

    /// The Pencil lifted (or was interrupted): its last samples, and whether to keep the stroke.
    func endInput(samples: [CGPoint], keep: Bool) {
        if placingDown {
            placingDown = false
            if let last = samples.last { placingTip = last }
            if keep, let tip = placingTip { placeSheet(at: tip) } else { updatePlacingOutline() }
            finishStroke(keep: false)
            return
        }
        if regionInput != nil {
            regionMoved(samples)
            finishRegionInput(keep: keep)
        } else if shapeDrawing.isDown {
            if let last = samples.last { pendingPenPosition = canvasPoint(last) }
            shapeDrawing.up(at: samples.last, keep: keep)
        } else if lassoing || drag != nil || sheetDrag != nil {
            lassoMoved(samples)
        } else if !samples.isEmpty, snappedShape == nil {
            consume(samples, ending: true)
        }
        finishStroke(keep: keep)
    }

    /// Feeds every one of the Pencil's samples to the eraser or the stroke. Samples closer than half a screen point
    /// are thinned, except the last one when the Pencil lifts, so the stroke ends where the Pencil left the glass.
    private func consume(_ samples: [CGPoint], ending: Bool) {
        let spacing = editor.viewport.canvasLength(ofScreen: 0.5)
        for (i, sample) in samples.enumerated() {
            let point = canvasPoint(sample)
            if erasing {
                if holdsEraser { heldEraserPoints.append(point) } else { editor.erase(at: point) }
            } else if ending && i == samples.count - 1 {
                liveStroke?.end(at: point)
            } else {
                liveStroke?.add(point, spacing: spacing)
            }
        }
        // The status bar hears about it on the next frame, not on every sample; the hold looks once a frame too.
        if let last = samples.last {
            pendingPenPosition = canvasPoint(last)
            lastSample = last
        }
    }

    private func finishStroke(keep: Bool) {
        if holdsEraser {
            // A finger's sweep that was never confirmed: erased once kept, forgotten once dropped.
            if keep {
                releaseHeldEraser()
            } else {
                holdsEraser = false
                heldEraserPoints.removeAll(keepingCapacity: true)
            }
        }
        if erasing { editor.endEraserSweep() }
        if lassoing { finishLoop(keep: keep) }
        if drag != nil { finishDrag(keep: keep) }
        if let sheetDrag, !sheetDrag.byFinger { finishSheetDrag(keep: keep) }
        if var stroke = liveStroke, let base = liveBase {
            // The line and shape tool snaps when it lifts, to a line, a rectangle or an ellipse, or else a straight
            // line from end to end; the pen only when it was held still.
            var shape = snappedShape
            if shape == nil, keep, liveIsLineTool {
                let smallest = editor.viewport.canvasLength(ofScreen: ShapeSnap.minimumScreenSize)
                shape = ShapeSnap.recognize(stroke.points, minimumSize: smallest) ?? ShapeSnap.straightLine(stroke.points)
            }
            // The live layers catch up with the last samples (or show the shape), drop the prediction, and go to the
            // renderer with the committed stroke; it shows them until the stroke's tiles are drawn, so the stroke
            // never blinks.
            livePredicted = []
            if let shape {
                stroke = stroke.snapped(to: shape)
                showSnapped(shape)
            } else {
                updateLive()
            }
            let committed = stroke
            let live = liveLayer
            var added: InkStroke?
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveTailLayer.path = nil
            if keep {
                renderer.commitLive(live, drawnAt: base) { added = editor.commit(committed) }
            } else {
                live.removeFromSuperlayer()
            }
            CATransaction.commit()
            // Draw it's shape shows its size in a tag (#40); the pen's hold-to-snap stays as it was.
            if liveIsLineTool, let shape, let added { shapeDrawing.showTag(for: DrawnShape(shape), stroke: added.id) }
        }
        if pencilIsDown {
            editor.pencilDidTouch(false)
            pencilIsDown = false
        }
        liveTouch = nil
        liveStroke = nil
        liveBase = nil
        liveChunkLayers = []
        erasing = false
        snappedShape = nil
        liveSnaps = false
        liveIsLineTool = false
        lastSample = nil
        if fingerDraws { fingerGate = FingerStrokeGate() }
        publishPenPosition()
        stopDisplayLinkIfIdle()
    }

    // MARK: Frames

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLinkIfIdle() {
        guard liveTouch == nil, liveStroke == nil, !erasing, !lassoing, drag == nil, sheetDrag == nil, regionInput == nil,
              !shapeDrawing.isDown, fingersDown == 0 else { return }
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        if gestureTiming != nil { gestureTiming?.frame(timestamp: link.timestamp, interval: link.targetTimestamp - link.timestamp) }
        // A finger held still on the eraser is confirmed by time passing, not by a move.
        if holdsEraser { fingerTick(at: link.timestamp) }
        // Holding still at the end of a stroke snaps it: looked at once a frame, never per sample, and recognised
        // once, when the hold is long enough.
        if liveSnaps, snappedShape == nil, let at = lastSample,
           hold.update(at: ScreenPoint(x: Double(at.x), y: Double(at.y)), time: link.timestamp) {
            snapLiveStroke()
        }
        // A measure's or dimension's point, a dimension's line, a frame or a window: followed once a frame, never
        // per sample.
        if regionTipMoved { regionTick() }
        if shapeDrawing.tipMoved { shapeDrawing.tick() }
        if placingMoved {
            placingMoved = false
            updatePlacingOutline()
        }
        // A twist's angle reaches the status bar at most once a frame.
        if let step = pendingTurnStep {
            pendingTurnStep = nil
            if sheetDrag != nil, editor.toolStep != step { editor.toolStep = step }
        }
        publishPenPosition()
    }

    private func publishPenPosition() {
        guard let point = pendingPenPosition else { return }
        pendingPenPosition = nil
        if editor.penPosition != point { editor.penPosition = point }
    }

    #if DEBUG
    /// Shows a stroke as if it were being drawn, never committed, for the kill-and-reopen captures, which kill the app
    /// with it on screen.
    func showOpenStroke(_ stroke: StrokeInProgress) {
        guard liveTouch == nil, liveStroke == nil, !erasing else { return }
        liveStroke = stroke
        startLive(stroke)
        liveStroke = nil
    }
    #endif

    // MARK: Fingers

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            lastPanTranslation = .zero
            gestureBegan()
            fingerGesture = beginSheetFingers(pan) ? .sheet : .panning
            // A selected sheet's turn or move by fingers is not a pan of the canvas: it is not timed.
            if fingerGesture == .sheet, let timing = gestureTiming {
                timing.cancel()
                gestureTiming = nil
            }
        case .changed:
            let t = pan.translation(in: self)
            switch fingerGesture {
            case .panning:
                panBy(dx: t.x - lastPanTranslation.x, dy: t.y - lastPanTranslation.y)
            case .sheet:
                sheetFingersMoved(pan)
            case .finished:
                break
            }
            lastPanTranslation = t
        case .ended, .cancelled, .failed:
            if fingerGesture == .sheet, sheetDrag?.byFinger == true { finishSheetDrag(keep: pan.state == .ended) }
            fingerGesture = .panning
            gestureEnded()
        default:
            break
        }
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            lastPinchScale = 1
            gestureBegan()
            gestureTiming?.kind = .pinch
        case .changed:
            // A selected sheet's turn or move by fingers holds the view still; the Pencil's leaves the other hand free.
            if sheetDrag?.byFinger != true { zoomBy(pinch.scale / lastPinchScale, about: pinch.location(in: self)) }
            lastPinchScale = pinch.scale
        case .ended, .cancelled, .failed:
            gestureEnded()
        default:
            break
        }
    }

    private func gestureBegan() {
        if speedCheck, fingersDown == 0 { startGestureTiming() }
        fingersDown += 1
        if editor.showsShapeFlyout { editor.showsShapeFlyout = false }
        textOverlay.isGesturing = true
        annotationOverlay.isGesturing = true
        startDisplayLink()
    }

    private func gestureEnded() {
        fingersDown = max(0, fingersDown - 1)
        if fingersDown == 0 {
            textOverlay.settle()
            annotationOverlay.settle()
            if let timing = gestureTiming { finishGestureTiming(timing) }
        }
        stopDisplayLinkIfIdle()
    }

    // MARK: The Speed check (#42)

    /// Starts timing a pan or pinch from its first finger's touch-down, or from now when that was not seen.
    private func startGestureTiming() {
        gestureTiming?.cancel()
        let now = CACurrentMediaTime()
        let start = fingerDownAt.map { now - $0 < 1 ? $0 : now } ?? now
        fingerDownAt = nil
        gestureTiming = GestureTiming(start: start, overSheet: sheetOnScreen)
    }

    private func finishGestureTiming(_ timing: GestureTiming) {
        var timing = timing
        gestureTiming = nil
        if !timing.overSheet { timing.overSheet = sheetOnScreen }
        SpeedCheckRecorder.shared.add(timing.finish(end: CACurrentMediaTime()))
    }

    /// Whether a placed sheet shows on screen: looked at when a timed gesture starts and ends, never per frame.
    private var sheetOnScreen: Bool {
        let visible = editor.viewport.visibleRect
        return editor.sheets.contains { $0.bounds.intersects(visible) }
    }

    /// Moves the canvas with the fingers, by a distance in screen points.
    func panBy(dx: CGFloat, dy: CGFloat) {
        editor.viewport.pan(dx: Double(dx), dy: Double(dy))
        viewportDidChange()
    }

    /// Zooms by a factor about a screen point, as a pinch does.
    func zoomBy(_ factor: CGFloat, about at: CGPoint) {
        editor.viewport.zoom(by: Double(factor), about: ScreenPoint(x: Double(at.x), y: Double(at.y)))
        viewportDidChange()
    }

    #if DEBUG || BENCHMARK
    /// Each drawing of the kept layer so far, for the Debug benchmark.
    var debugKeptRedraws: [String] { annotationOverlay.debugRedraws }

    /// Tile drawings still in flight, for the Debug benchmark.
    var pendingRenderCount: Int { renderer.pendingCount + sheetRenderer.pendingCount }
    /// Sheet tiles asked for and kept, for the benchmark's log.
    var debugSheetTiles: (drawn: Int, kept: Int) { (sheetRenderer.tilesDrawn, sheetRenderer.debugCachedTiles) }
    #endif

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Touches on the text being typed and on the selection's menu are theirs, not the canvas's.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view, view !== self else { return true }
        if let typing = textOverlay.editing?.view, view.isDescendant(of: typing) { return false }
        return !view.isDescendant(of: selectionOverlay.menu) && !view.isDescendant(of: windowMenu)
            && !view.isDescendant(of: sheetStrip) && !shapeDrawing.owns(view)
    }

    /// Two fingers both on the selected sheet twist it, so they never pinch the canvas (#44), and a move by a finger holds
    /// the view still. Any others pinch as they do today, and so do any two fingers while the Pencil moves the sheet, as
    /// during a selection's drag: they start no twist then (`beginSheetFingers`).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pinch {
            if let sheetDrag {
                if sheetDrag.byFinger { return false }
            } else if fingersAreOnSelectedSheet(pinch) {
                return false
            }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// The canvas's colours, light and dark (ADR-0011): a warm paper ground in light, a dark ground in dark, and the ink
/// colours from `MarkupColour`.
enum Palette {
    static func ground(dark: Bool) -> UIColor { dark ? UIColor(hex: 0x1C1D20) : UIColor(hex: 0xF3EFE6) }
    static func grid(dark: Bool) -> UIColor { dark ? UIColor.white : UIColor(hex: 0x786E5A) }

    /// The lasso's loop and the selection's box and handles: the chrome's accent.
    static func selection(dark: Bool) -> UIColor { dark ? UIColor(hex: 0x9CC4EC) : UIColor(hex: 0x2F5D8A) }

    static func ink(_ colour: MarkupColour, dark: Bool) -> UIColor {
        let rgb = colour.rgb(dark: dark)
        return UIColor(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Snapping, the lasso and text boxes (#7)

extension InkCanvasUIView {
    // MARK: Snapping

    /// The Pencil has held still at the end of the stroke: recognise it once, and show the shape it snaps to, if any,
    /// in place of the stroke until the Pencil lifts.
    private func snapLiveStroke() {
        guard let stroke = liveStroke else { return }
        let smallest = editor.viewport.canvasLength(ofScreen: ShapeSnap.minimumScreenSize)
        guard let shape = ShapeSnap.recognize(stroke.points, minimumSize: smallest) else { return }
        snappedShape = shape
        showSnapped(shape)
        UISelectionFeedbackGenerator().selectionChanged()
        UIAccessibility.post(notification: .announcement, argument: "Snapped to a \(shape.name)")
    }

    /// Shows a shape on the live layers in place of the stroke drawn so far.
    private func showSnapped(_ shape: SnappedShape) {
        guard let base = liveBase else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, chunk) in liveChunkLayers.enumerated() {
            chunk.path = i == 0 ? screenPath(shape.points[...], base) : nil
        }
        liveTailLayer.path = nil
        CATransaction.commit()
    }

    // MARK: The shape tools (#40)

    /// A shape finished with the line and shape tool, as ink, with the pen, colour and width it started with: shown at once
    /// through the live layers, which go to the renderer with the committed stroke, as a stroke's do, so it never blinks. The
    /// stroke, or nil when nothing was added.
    func commitShape(_ stroke: StrokeInProgress) -> InkStroke? {
        liveStroke = stroke
        startLive(stroke)
        defer {
            liveStroke = nil
            liveBase = nil
            liveChunkLayers = []
        }
        guard let base = liveBase else { return nil }
        let live = liveLayer
        var added: InkStroke?
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveTailLayer.path = nil
        renderer.commitLive(live, drawnAt: base) { added = editor.commit(stroke) }
        CATransaction.commit()
        return added
    }

    func canvasPointForShape(_ location: CGPoint) -> CanvasPoint { canvasPoint(location) }

    /// Shows the loupe and the snap marker for a shape's point being found.
    func showShapeLoupe(tip: CGPoint, raw: CanvasPoint, target: PointSnap.Target) {
        annotationOverlay.tool.tip = (raw, target)
        loupe.show(tip: tip, target: target, viewport: editor.viewport, renderer: renderer, placement: exactPlacement, dark: isDark)
    }

    func hideShapeLoupe() {
        annotationOverlay.tool.tip = nil
        loupe.hide()
    }

    /// The free part of the screen: clear of the rail, the top bar, the status bar and the tab rail, and below any strip open
    /// under the top bar (the frame paper picker, the waiting sheet's pill, the selected sheet's strip).
    var exactPlacement: ExactPlacement {
        let safe = safeAreaInsets, base = CanvasEditor.chromeInsets
        let chrome = ScreenInsets(top: Double(safe.top) + base.top, left: Double(safe.left) + base.left,
                                  bottom: Double(safe.bottom) + base.bottom, right: max(base.right, Double(safe.right) + 8))
        var strip: Double?
        if editor.selectedSheet != nil {
            strip = Double(sheetStrip.frame.maxY)
        } else if editor.placingSheet != nil {
            strip = chrome.top + 40
        } else if editor.tool == .frame {
            strip = chrome.top + 36
        }
        return ExactPlacement(width: Double(bounds.width), height: Double(bounds.height), chrome: chrome, stripBottom: strip)
    }

    #if DEBUG
    var debugShapeDrawing: ShapeDrawing { shapeDrawing }
    #endif

    // MARK: The lasso

    /// The Pencil touched down with the lasso: on a corner handle it resizes the selection, on the selection it moves
    /// it, anywhere else it starts a new loop and lets go of the selection.
    private func beginLasso(at location: CGPoint, point: CanvasPoint) {
        // On a selected sheet the Pencil moves it (#44); anywhere else lets go of it and starts a loop.
        if let sheet = editor.selectedSheet, sheet.contains(point) {
            beginSheetDrag(.move(start: point, moved: false), byFinger: false)
            return
        }
        if !editor.selection.isEmpty, let bounds = editor.selectionBounds {
            if let corner = selectionOverlay.handle(at: location) {
                let corners = [CanvasPoint(x: bounds.minX, y: bounds.minY), CanvasPoint(x: bounds.maxX, y: bounds.minY),
                               CanvasPoint(x: bounds.maxX, y: bounds.maxY), CanvasPoint(x: bounds.minX, y: bounds.maxY)]
                startDrag(.resize(anchor: corners[(corner + 2) % 4], corner: corners[corner]), at: point)
                return
            }
            if selectionOverlay.contains(location) {
                startDrag(.move, at: point)
                return
            }
        }
        editor.select(.empty)
        lassoing = true
        lassoPoints = [point]
        lassoBase = editor.viewport
        lassoPath = CGMutablePath()
        lassoPath.move(to: location)
        lastLassoScreen = location
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionOverlay.loopLayer.transform = CATransform3DIdentity
        selectionOverlay.loopLayer.path = lassoPath
        CATransaction.commit()
    }

    /// The Pencil moved with the lasso: the loop grows (a point every 2 screen points), or the drag follows.
    private func lassoMoved(_ samples: [CGPoint]) {
        guard let last = samples.last else { return }
        pendingPenPosition = canvasPoint(last)
        if sheetDrag != nil {
            lastSample = last
            moveSheetDrag(to: canvasPoint(last))
            return
        }
        if drag != nil {
            dragTo(canvasPoint(last))
            return
        }
        guard lassoing, let base = lassoBase else { return }
        var grew = false
        for sample in samples where hypot(sample.x - lastLassoScreen.x, sample.y - lastLassoScreen.y) >= 2 {
            let point = canvasPoint(sample)
            lassoPoints.append(point)
            let onBase = base.screenPoint(for: point)
            lassoPath.addLine(to: CGPoint(x: onBase.x, y: onBase.y))
            lastLassoScreen = sample
            grew = true
        }
        guard grew else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionOverlay.loopLayer.path = lassoPath
        CATransaction.commit()
    }

    /// The loop is closed: select what it takes, through the index.
    private func finishLoop(keep: Bool) {
        lassoing = false
        lassoBase = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionOverlay.loopLayer.path = nil
        CATransaction.commit()
        // A tap, not a loop: picks up the sheet under it (#44).
        if keep, let first = lassoPoints.first, lassoPoints.allSatisfy({ point in
            editor.viewport.canvasLength(ofScreen: Self.sheetTapReach) >= first.distance(to: point)
        }) {
            lassoPoints = []
            pickUpSheet(at: first)
            return
        }
        if keep, lassoPoints.count >= 3 {
            editor.selectInLoop(lassoPoints)
            let count = editor.selection.count
            UIAccessibility.post(notification: .announcement, argument: count == 0 ? "Nothing selected" : "\(count) selected")
        }
        lassoPoints = []
    }

    /// Lifts the selection's strokes out of the tiles onto a layer of their own, which the drag moves by its
    /// transform: one transform a frame, however many strokes.
    private func startDrag(_ kind: SelectionDrag.Kind, at point: CanvasPoint) {
        let strokes = editor.liftSelection()
        let base = editor.viewport
        let layer = dragLayer(for: strokes, drawnAt: base)
        // A move only slides the ink, so the render server draws it once and slides the image, rather than stroking
        // every path again each frame with the main thread waiting on it (#32). A resize stays as paths, to stay sharp.
        if case .move = kind {
            layer.shouldRasterize = true
            layer.rasterizationScale = traitCollection.displayScale
        }
        self.layer.addSublayer(layer)
        selectionOverlay.bringToFront(in: self)
        drag = SelectionDrag(kind: kind, start: point, base: base, layer: layer)
        updateSelectionOverlay()
    }

    /// The selected strokes drawn once, in screen points of `base`: one shape layer for each colour, pen and width,
    /// so a thousand strokes are a handful of layers.
    private func dragLayer(for strokes: [InkStroke], drawnAt base: Viewport) -> CALayer {
        struct Group: Hashable {
            let colour: MarkupColour
            let tool: InkTool
            let quarterPoints: Int
        }
        var paths: [Group: CGMutablePath] = [:]
        for stroke in strokes {
            let width = max(stroke.width.inches * base.pointsPerInch, InkTileRenderer.minimumWidth)
            let group = Group(colour: stroke.colour, tool: stroke.tool, quarterPoints: Int((width * 4).rounded()))
            let path = paths[group] ?? CGMutablePath()
            path.addPath(screenPath(stroke.points[...], base))
            paths[group] = path
        }
        let container = CALayer()
        container.actions = noAnimations
        container.anchorPoint = .zero
        container.position = .zero
        container.bounds = bounds
        for (group, path) in paths {
            let shape = CAShapeLayer()
            configure(shape)
            shape.path = path
            shape.strokeColor = Palette.ink(group.colour, dark: isDark).cgColor
            shape.lineWidth = Double(group.quarterPoints) / 4
            shape.opacity = Float(group.tool.opacity)
            container.addSublayer(shape)
        }
        return container
    }

    /// The Pencil dragged the selection to a canvas point: a move by the distance from where it touched down, or a
    /// resize about the opposite corner by how far along the diagonal the corner is.
    private func dragTo(_ point: CanvasPoint) {
        guard var current = drag else { return }
        switch current.kind {
        case .move:
            current.transform = .translation(dx: point.x - current.start.x, dy: point.y - current.start.y)
        case .resize(let anchor, let corner):
            let (vx, vy) = (corner.x.inches - anchor.x.inches, corner.y.inches - anchor.y.inches)
            let (px, py) = (point.x.inches - anchor.x.inches, point.y.inches - anchor.y.inches)
            let lengthSquared = vx * vx + vy * vy
            let factor = lengthSquared > 0 ? (px * vx + py * vy) / lengthSquared : 1
            current.transform = .scaling(by: max(factor, 0.05), about: anchor)
        }
        drag = current
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        current.layer.transform = Self.transform(from: current.base, to: editor.viewport, applying: current.transform)
        CATransaction.commit()
        textOverlay.drag(current.transform, ids: editor.selection.texts)
        annotationOverlay.drag(current.transform, selection: editor.selection)
        updateSelectionOverlay()
    }

    /// The Pencil lifted from a drag: the move or resize becomes one undo step, saved as ids and a transform. The
    /// drag layer stays until the moved strokes' tiles are drawn, so the ink never blinks.
    private func finishDrag(keep: Bool) {
        guard let finished = drag else { return }
        drag = nil
        editor.dropSelection(keep ? finished.transform : .identity)
        textOverlay.drag(nil, ids: editor.selection.texts)
        annotationOverlay.drag(nil, selection: editor.selection)
        updateSelectionOverlay()
        let layer = finished.layer
        Task { @MainActor [weak self] in
            let started = CACurrentMediaTime()
            while let self, self.renderer.pendingCount > 0, CACurrentMediaTime() - started < 1 {
                try? await Task.sleep(for: .milliseconds(16))
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeFromSuperlayer()
            CATransaction.commit()
        }
    }

    /// The transform taking screen points of `base` to screen points of `viewport`, with a sheet's turn, move or scale
    /// change of the canvas between: a turn, a scale and an offset.
    static func transform(from base: Viewport, to viewport: Viewport, applying motion: SheetMotion) -> CATransform3D {
        let k = motion.scale * viewport.pointsPerInch / base.pointsPerInch
        let (c, s) = SheetAngle.cosineAndSine(motion.turn)
        let origin = viewport.screenPoint(for: motion.apply(base.canvasPoint(for: ScreenPoint(x: 0, y: 0))))
        return CATransform3DMakeAffineTransform(CGAffineTransform(a: k * c, b: -k * s, c: k * s, d: k * c, tx: origin.x, ty: origin.y))
    }

    /// The transform taking screen points of `base` to screen points of `viewport`, with a move or resize of the
    /// canvas between: a scale and an offset.
    static func transform(from base: Viewport, to viewport: Viewport, applying move: CanvasTransform) -> CATransform3D {
        let k = move.scale * viewport.pointsPerInch / base.pointsPerInch
        let origin = viewport.screenPoint(for: move.apply(base.canvasPoint(for: ScreenPoint(x: 0, y: 0))))
        return CATransform3DMakeAffineTransform(CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: origin.x, ty: origin.y))
    }

    private func selectionDidChange() {
        selectionOverlay.bringToFront(in: self)
        updateSelectionOverlay()
    }

    /// Places the selection's box, handles and menu from its bounds (moved with a drag in progress).
    func updateSelectionOverlay() {
        guard bounds.width > 0 else { return }
        let viewport = editor.viewport
        var rect: CGRect?
        if var selected = editor.selectionBounds {
            if let drag { selected = drag.transform.apply(selected) }
            let a = viewport.screenPoint(for: selected.origin)
            rect = CGRect(x: a.x, y: a.y, width: selected.size.width.inches * viewport.pointsPerInch,
                          height: selected.size.height.inches * viewport.pointsPerInch)
        }
        selectionOverlay.show(ink: rect, count: editor.selection.count, showsMenu: drag == nil, in: bounds)
        updateSelectedSheet()
    }

    #if DEBUG
    /// Draws a lasso loop through screen points and lifts, as the Pencil would: for the simulator captures.
    func debugLasso(_ points: [CGPoint]) {
        guard let first = points.first, beginInput(at: first) else { return }
        moveInput(samples: Array(points.dropFirst()), predicted: [])
        endInput(samples: [], keep: true)
    }

    /// The text overlay, for the simulator captures.
    var debugTextOverlay: TextBoxOverlay { textOverlay }
    #endif

    // MARK: Text boxes

    @objc private func handleTextTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, tool == .textBox else { return }
        let location = tap.location(in: self)
        if textOverlay.editing != nil {
            // A tap away from the text being typed finishes it; the next tap places another.
            textOverlay.finishEditing()
        } else if let box = textOverlay.box(at: location) {
            textOverlay.beginEditing(box)
        } else {
            placeText(at: location)
        }
    }

    /// Starts a new text box whose first line is centred on a screen point.
    func placeText(at location: CGPoint) {
        let halfLine = CGFloat(TextBox.screenFontSize * 0.6)
        textOverlay.beginNew(at: canvasPoint(CGPoint(x: location.x, y: location.y - halfLine)))
    }
}

// MARK: - Measure, dimension, frame and window (#8)

extension InkCanvasUIView {
    /// A drag shorter than this on screen, in points, is a tap, and makes no frame or window.
    private static let smallestDrag: CGFloat = 8

    /// The Pencil touched down with the measure, dimension, frame or window tool.
    private func beginRegionInput(at location: CGPoint, point: CanvasPoint) {
        if let owner = regionTool, owner != editor.tool { resetLengthsAndRegions(keepingMeasure: false) }
        regionTool = editor.tool
        regionTip = location
        switch editor.tool {
        case .measure, .dimension:
            if secondPoint != nil {
                regionInput = .pull
            } else {
                regionInput = .point
                // A new measure starts: the last one goes.
                if editor.tool == .measure, firstTarget == nil { annotationOverlay.tool.measure = nil }
            }
        case .frame:
            regionInput = .frame(from: point)
        case .window:
            closeWindow()
            regionInput = .window(from: point)
        default:
            return
        }
        regionTick()
    }

    private func regionMoved(_ samples: [CGPoint]) {
        guard let last = samples.last else { return }
        regionTip = last
        regionTipMoved = true
        pendingPenPosition = canvasPoint(last)
    }

    /// Follows the tip, once a display frame: snaps it and shows the loupe, pulls the dimension's line, or sizes the
    /// frame or window.
    private func regionTick() {
        regionTipMoved = false
        guard let input = regionInput, let tip = regionTip else { return }
        let point = canvasPoint(tip)
        switch input {
        case .point:
            // The second point works from the first, so it has perpendicular and tangent too (#40).
            let target = editor.snapTarget(at: point, anchor: firstTarget?.point)
            var state = annotationOverlay.tool
            state.tip = (point, target)
            state.isMeasure = editor.tool == .measure
            annotationOverlay.tool = state
            loupe.show(tip: tip, target: target, viewport: editor.viewport, renderer: renderer, placement: exactPlacement,
                       dark: isDark)
        case .pull:
            guard let first = firstTarget?.point, let second = secondPoint else { return }
            annotationOverlay.tool.pulling = CanvasDimension.pulled(
                id: DimensionID(0), start: first, end: second, through: point, colour: editor.colour,
                textHeight: editor.viewport.canvasLength(ofScreen: CanvasDimension.screenTextHeight))
        case .frame(let from):
            let rect = Self.rect(from, point)
            annotationOverlay.tool.frameDrag = (rect, editor.frame(fitting: rect))
        case .window(let from):
            annotationOverlay.tool.window = Self.rect(from, point)
        }
    }

    /// The Pencil lifted (`keep`) or was taken away: takes the point, places the dimension or frame, or offers the
    /// window's menu.
    private func finishRegionInput(keep: Bool) {
        guard let input = regionInput, let tip = regionTip else { return }
        regionInput = nil
        regionTipMoved = false
        loupe.hide()
        annotationOverlay.tool.tip = nil
        let point = canvasPoint(tip)
        guard keep else {
            annotationOverlay.tool.frameDrag = nil
            annotationOverlay.tool.window = nil
            return
        }
        switch input {
        case .point:
            takePoint(editor.snapTarget(at: point, anchor: firstTarget?.point))
        case .pull:
            guard let first = firstTarget?.point, let second = secondPoint else { return }
            let placed = editor.addDimension(start: first, end: second, through: point)
            resetLengthsAndRegions(keepingMeasure: true)
            if let placed { announce("Dimension kept: \(editor.label(for: placed))") }
        case .frame(let from):
            annotationOverlay.tool.frameDrag = nil
            guard isDrag(from, point) else { return }
            let frame = editor.addFrame(fitting: Self.rect(from, point))
            announce("Frame: \(frame.label)")
        case .window(let from):
            guard isDrag(from, point) else {
                annotationOverlay.tool.window = nil
                return
            }
            let rect = Self.rect(from, point)
            chosenWindow = rect
            annotationOverlay.tool.window = rect
            windowMenu.place(under: screenRect(rect), in: bounds)
            windowMenu.isHidden = false
            bringSubviewToFront(windowMenu)
            editor.toolStep = .chooseWindowAction
        }
    }

    /// A measure's or dimension's point, taken on lift.
    private func takePoint(_ target: PointSnap.Target) {
        guard let first = firstTarget else {
            firstTarget = target
            annotationOverlay.tool.firstPoint = target.point
            annotationOverlay.tool.isMeasure = editor.tool == .measure
            editor.toolStep = .secondPoint
            return
        }
        let a = editor.viewport.screenPoint(for: first.point), b = editor.viewport.screenPoint(for: target.point)
        guard hypot(b.x - a.x, b.y - a.y) >= 2 else {
            resetLengthsAndRegions(keepingMeasure: true)
            announce("Same point twice. Try again.")
            return
        }
        if editor.tool == .measure {
            resetLengthsAndRegions(keepingMeasure: false)
            regionTool = .measure
            annotationOverlay.tool.measure = (first.point, target.point)
            announce("Measured \(editor.measureText(from: first.point, to: target.point))")
        } else {
            secondPoint = target.point
            editor.toolStep = .pullOff
            annotationOverlay.tool.pulling = CanvasDimension.pulled(
                id: DimensionID(0), start: first.point, end: target.point, through: target.point,
                colour: editor.colour, textHeight: editor.viewport.canvasLength(ofScreen: CanvasDimension.screenTextHeight))
        }
    }

    /// Starts the tool in hand afresh: no points, no dimension being pulled, no window; the last measure stays only
    /// with `keepingMeasure`.
    func resetLengthsAndRegions(keepingMeasure: Bool) {
        firstTarget = nil
        secondPoint = nil
        regionInput = nil
        regionTipMoved = false
        loupe.hide()
        var state = AnnotationOverlay.ToolState()
        if keepingMeasure { state.measure = annotationOverlay.tool.measure }
        annotationOverlay.tool = state
        regionTool = state.measure == nil ? nil : .measure
        chosenWindow = nil
        windowMenu.isHidden = true
        let step: CanvasTool.Step = editor.placingSheet == nil ? .start : .placeSheet
        if editor.toolStep != step { editor.toolStep = step }
    }

    private func zoomToWindow() {
        guard let rect = chosenWindow else { return }
        closeWindow()
        editor.zoom(to: rect)
        viewportJumped()
    }

    private func makeFrameFromWindow() {
        guard let rect = chosenWindow else { return }
        closeWindow()
        let frame = editor.addFrame(fitting: rect)
        announce("Frame: \(frame.label)")
    }

    private func closeWindow() {
        chosenWindow = nil
        annotationOverlay.tool.window = nil
        windowMenu.isHidden = true
        if editor.toolStep == .chooseWindowAction { editor.toolStep = .start }
    }

    private func isDrag(_ from: CanvasPoint, _ to: CanvasPoint) -> Bool {
        let a = editor.viewport.screenPoint(for: from), b = editor.viewport.screenPoint(for: to)
        return hypot(b.x - a.x, b.y - a.y) >= Self.smallestDrag
    }

    private static func rect(_ a: CanvasPoint, _ b: CanvasPoint) -> CanvasRect {
        let x0 = min(a.x.inches, b.x.inches), y0 = min(a.y.inches, b.y.inches)
        return CanvasRect(origin: CanvasPoint(x: .inches(x0), y: .inches(y0)),
                          size: CanvasSize(width: .inches(abs(a.x.inches - b.x.inches)),
                                           height: .inches(abs(a.y.inches - b.y.inches))))
    }

    private func screenRect(_ rect: CanvasRect) -> CGRect {
        let viewport = editor.viewport
        let a = viewport.screenPoint(for: rect.origin)
        return CGRect(x: a.x, y: a.y, width: rect.size.width.inches * viewport.pointsPerInch,
                      height: rect.size.height.inches * viewport.pointsPerInch)
    }

    private func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    #if DEBUG
    /// The labels shown on the canvas, for the captures' console.
    var debugAnnotationLabels: [String] { annotationOverlay.debugLabels }
    #endif
}

// MARK: - Sheets (#11)

extension InkCanvasUIView {
    /// The sheets changed: placed, or taken away or put back by undo and redo.
    fileprivate func sheetsDidChange(_ change: InkChange) {
        sheetRenderer.setSheets(editor.sheets)
        renderer.lightPaper = sheetRenderer.lightPaper
        annotationOverlay.sheetsChanged(change)
        // An undo or redo of a turn moves a selected sheet's edge with it.
        updateSelectedSheet()
    }

    /// A sheet started or stopped waiting to be placed: its outline shows in the middle of the view until the Pencil
    /// or a finger moves it, and a finger's tap places it.
    fileprivate func placingDidChange() {
        let placing = editor.placingSheet != nil
        placingTip = nil
        placingDown = false
        placeTap.isEnabled = placing && !fingerDraws
        updateSheetTap()
        textTap.isEnabled = tool == .textBox && !placing
        if placing { resetLengthsAndRegions(keepingMeasure: false) }
        shownViewport = nil
        viewportDidChange()
        updatePlacingOutline()
        accessibilityHint = placing ? CanvasTool.placeSheetHint
            : FingerDrawingSetting.accessibilityHint(fingerDraws: fingerDraws)
    }

    /// Shows the waiting sheet's true-size outline centred where the Pencil or finger last was, or the middle of the
    /// view; nothing when no sheet waits.
    fileprivate func updatePlacingOutline() {
        guard editor.placingSheet != nil else {
            if annotationOverlay.tool.placingSheet != nil { annotationOverlay.tool.placingSheet = nil }
            return
        }
        let tip = placingTip ?? CGPoint(x: bounds.midX, y: bounds.midY)
        guard let sheet = editor.sheetToPlace(centredAt: canvasPoint(tip)) else { return }
        annotationOverlay.tool.placingSheet = (sheet, editor.covers(sheet))
    }

    @objc fileprivate func handlePlaceTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, editor.placingSheet != nil else { return }
        placeSheet(at: tap.location(in: self))
    }

    /// Places the waiting sheet centred on a screen point, once its PDF is kept on the Duo.
    func placeSheet(at tip: CGPoint) {
        placingTip = tip
        updatePlacingOutline()
        let point = canvasPoint(tip)
        Task { @MainActor [weak self] in
            guard let self, let placed = await self.editor.placeSheet(centredAt: point) else { return }
            UIAccessibility.post(notification: .announcement, argument: "Placed \(placed.label)")
        }
    }
}

// MARK: - Turning and moving a selected sheet (#44)

extension InkCanvasUIView {
    /// How far a tap may wander, in screen points, and still be a tap.
    fileprivate static let sheetTapReach = 8.0
    /// How far a sheet's move or twist must go, in screen points and degrees, before it is one and not a rested tip.
    private static let sheetMoveThreshold = 5.0
    private static let twistThreshold = 0.5

    /// A finger's tap only picks up a sheet with the lasso in hand; with Draw with finger on it goes the Pencil's way.
    fileprivate func updateSheetTap() {
        sheetTap.isEnabled = tool == .lasso && editor.placingSheet == nil && !fingerDraws
    }

    @objc fileprivate func handleSheetTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, editor.tool == .lasso, editor.placingSheet == nil else { return }
        let location = tap.location(in: self)
        // A tap on ink already selected leaves it to be dragged.
        if editor.selection.sheet == nil, selectionOverlay.contains(location) { return }
        pickUpSheet(at: canvasPoint(location))
    }

    /// Selects the topmost sheet under a canvas point, keeping the selected one if the point is on it; off every sheet,
    /// lets go of a selected one.
    fileprivate func pickUpSheet(at point: CanvasPoint) {
        if let selected = editor.selectedSheet, selected.contains(point) { return }
        if let sheet = editor.sheet(at: point) {
            editor.select(CanvasSelection(sheet: sheet.id))
            UIAccessibility.post(notification: .announcement,
                                 argument: "Selected \(sheet.label), at \(SheetAngle.reading(sheet.angle))")
        } else if editor.selection.sheet != nil {
            editor.select(.empty)
        }
    }

    private func fingers(_ gesture: UIGestureRecognizer) -> (CGPoint, CGPoint)? {
        guard gesture.numberOfTouches == 2 else { return nil }
        return (gesture.location(ofTouch: 0, in: self), gesture.location(ofTouch: 1, in: self))
    }

    /// Whether two fingers are both on the selected sheet.
    fileprivate func fingersAreOnSelectedSheet(_ gesture: UIGestureRecognizer) -> Bool {
        guard let sheet = editor.selectedSheet, let (a, b) = fingers(gesture) else { return false }
        return sheet.contains(canvasPoint(a)) && sheet.contains(canvasPoint(b))
    }

    private static func fingerAngle(_ a: CGPoint, _ b: CGPoint) -> Double {
        atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / .pi
    }

    /// The fingers' pan began: on the selected sheet, two fingers twist it and one moves it. False leaves them to pan and
    /// zoom the canvas as they do today.
    fileprivate func beginSheetFingers(_ pan: UIPanGestureRecognizer) -> Bool {
        guard sheetDrag == nil, let sheet = editor.selectedSheet else { return false }
        if let (a, b) = fingers(pan) {
            guard fingersAreOnSelectedSheet(pan) else { return false }
            return beginSheetTwist(fingerAngle: Self.fingerAngle(a, b))
        }
        guard !fingerDraws, pan.numberOfTouches == 1 else { return false }
        let t = pan.translation(in: self)
        let now = pan.location(in: self)
        let start = canvasPoint(CGPoint(x: now.x - t.x, y: now.y - t.y))
        guard sheet.contains(start) else { return false }
        beginSheetDrag(.move(start: start, moved: false), byFinger: true)
        return sheetDrag != nil
    }

    /// The fingers moved during a sheet's turn or move. A second finger landing on a move drops it and twists, or pans and
    /// zooms if it isn't on the sheet, as the first would have; a finger lifting from a twist ends it, and the other
    /// finger then does nothing until it lifts.
    fileprivate func sheetFingersMoved(_ pan: UIPanGestureRecognizer) {
        guard let current = sheetDrag else { return }
        switch current.kind {
        case .move:
            if pan.numberOfTouches >= 2 {
                finishSheetDrag(keep: false)
                if let (a, b) = fingers(pan), fingersAreOnSelectedSheet(pan) {
                    _ = beginSheetTwist(fingerAngle: Self.fingerAngle(a, b))
                } else {
                    fingerGesture = .panning
                }
                return
            }
            moveSheetDrag(to: canvasPoint(pan.location(in: self)))
        case .twist:
            guard let (a, b) = fingers(pan) else {
                finishSheetDrag(keep: true)
                fingerGesture = .finished
                return
            }
            twistSheet(fingerAngle: Self.fingerAngle(a, b))
        }
    }

    /// Lifts the selected sheet's markups onto a layer of their own and starts following it. The choosing and the layer
    /// are built once, here; each frame after is transforms.
    private func beginSheetDrag(_ kind: SheetDrag.Kind, byFinger: Bool) {
        guard sheetDrag == nil, let lift = editor.liftSheet() else { return }
        let base = editor.viewport
        let inkLayer = dragLayer(for: lift.strokes, drawnAt: base)
        // Many strokes turn as one image, as a selection's move slides as one (#32); a few stay as paths, sharp and whole
        // when ones off screen turn into view.
        if lift.strokes.count > Self.rasterizedStrokes {
            inkLayer.shouldRasterize = true
            inkLayer.rasterizationScale = traitCollection.displayScale
        }
        layer.addSublayer(inkLayer)
        selectionOverlay.bringToFront(in: self)
        sheetDrag = SheetDrag(kind: kind, lift: lift, base: base, layer: inkLayer, after: lift.sheet,
                              motion: SheetMotion(centre: lift.sheet.centre), byFinger: byFinger)
        annotationOverlay.beginSheetChange(lift.sheet, markups: lift.markups)
        startDisplayLink()
    }

    private static var rasterizedStrokes: Int { 200 }

    /// The Pencil or a finger took a selected sheet to a canvas point: a move by the distance from where it touched down.
    private func moveSheetDrag(to point: CanvasPoint) {
        guard var current = sheetDrag, case .move(let start, var moved) = current.kind else { return }
        if !moved {
            let distance = start.distance(to: point).inches * editor.viewport.pointsPerInch
            guard distance >= Self.sheetMoveThreshold else { return }
            moved = true
            current.kind = .move(start: start, moved: true)
        }
        let change = current.lift.sheet.moved(dx: point.x - start.x, dy: point.y - start.y)
        current.after = change.sheet
        current.motion = change.motion
        sheetDrag = current
        showSheetDrag(current)
    }

    /// The other hand panned or pinched under the Pencil's move. A sheet being moved stays under the tip, which is now over
    /// another canvas point; one not yet moved stays put, and goes on from that point, so a rested tip never makes a move.
    fileprivate func keepSheetDragUnderTip() {
        guard var current = sheetDrag, !current.byFinger, let tip = lastSample,
              case .move(_, let moved) = current.kind else { return }
        let point = canvasPoint(tip)
        if moved {
            moveSheetDrag(to: point)
        } else {
            current.kind = .move(start: point, moved: false)
            sheetDrag = current
        }
    }

    /// Starts a twist of the selected sheet from the fingers' angle, in degrees. False with nothing selected.
    @discardableResult
    func beginSheetTwist(fingerAngle: Double) -> Bool {
        beginSheetDrag(.twist(from: fingerAngle, moved: false), byFinger: true)
        return sheetDrag != nil
    }

    /// The fingers' angle, in degrees: it turns freely and catches on a quarter turn. Fingers going clockwise on screen
    /// turn the sheet clockwise, so its counter-clockwise angle falls.
    func twistSheet(fingerAngle: Double) {
        guard var current = sheetDrag, case .twist(let from, var moved) = current.kind else { return }
        let difference = SheetAngle.normalized(fingerAngle - from)
        if !moved {
            guard min(difference, 360 - difference) > Self.twistThreshold else { return }
            moved = true
            current.kind = .twist(from: from, moved: true)
        }
        let shaped = SheetAngle.shaped(current.lift.sheet.angle - difference)
        let change = current.lift.sheet.turned(to: shaped.angle)
        if shaped.caught, !current.caught { UISelectionFeedbackGenerator().selectionChanged() }
        current.caught = shaped.caught
        current.after = change.sheet
        current.motion = change.motion
        sheetDrag = current
        pendingTurnStep = shaped.caught ? .caughtSheet(shaped.angle) : .turningSheet(shaped.angle)
        showSheetDrag(current)
    }

    /// One transform for the sheet, one for its strokes, one each for what else comes along, the level labels placed
    /// again, and the edge and the strip's angle: no tile and no stroke is drawn.
    private func showSheetDrag(_ current: SheetDrag) {
        // One commit for the frame: each commit after the first waits on the render server, which on a slow one held the
        // main thread for two display frames (#44).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheetRenderer.preview(current.after)
        current.layer.transform = Self.transform(from: current.base, to: editor.viewport, applying: current.motion)
        textOverlay.dragWithSheet(current.motion, ids: current.lift.markups.texts)
        annotationOverlay.moveSheet(current.after, motion: current.motion)
        updateSelectedSheet()
        CATransaction.commit()
    }

    /// The turn or move ends: one undo step, or, if it went nowhere or was dropped, the sheet as it was. The strokes' layer
    /// stays until their tiles are drawn, so the ink never blinks.
    func finishSheetDrag(keep: Bool) {
        guard let finished = sheetDrag else { return }
        sheetDrag = nil
        pendingTurnStep = nil
        if keep, finished.after != finished.lift.sheet {
            editor.dropSheet(to: finished.after, motion: finished.motion)
            announceSheet(finished.after)
        } else {
            editor.dropSheet(to: nil, motion: nil)
        }
        settleSheetDrag(finished)
    }

    private func settleSheetDrag(_ finished: SheetDrag) {
        sheetRenderer.endPreview()
        textOverlay.dragWithSheet(nil, ids: finished.lift.markups.texts)
        annotationOverlay.endSheetChange()
        switch editor.toolStep {
        case .turningSheet, .caughtSheet: editor.toolStep = .start
        default: break
        }
        updateSelectedSheet()
        stopDisplayLinkIfIdle()
        let layer = finished.layer
        Task { @MainActor [weak self] in
            let started = CACurrentMediaTime()
            while let self, self.renderer.pendingCount > 0, CACurrentMediaTime() - started < 1 {
                try? await Task.sleep(for: .milliseconds(16))
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeFromSuperlayer()
            CATransaction.commit()
        }
    }

    private func announceSheet(_ sheet: Sheet) {
        UIAccessibility.post(notification: .announcement,
                             argument: "\(sheet.label), at \(SheetAngle.reading(sheet.angle))")
    }

    /// A turn button: a quarter turn left (90) or right (-90), one undo step, through the same lift so the ink never
    /// blinks.
    fileprivate func turnSelectedSheet(by quarter: Double) {
        guard let sheet = editor.selectedSheet else { return }
        applySheetChange(sheet.turned(to: SheetAngle.stepped(sheet.angle, by: quarter)))
    }

    /// Puts a change made in one go in place: a turn button's, or a scale change's.
    private func applySheetChange(_ change: (sheet: Sheet, motion: SheetMotion)) {
        guard sheetDrag == nil else { return }
        beginSheetDrag(.move(start: .origin, moved: true), byFinger: true)
        guard var current = sheetDrag else { return }
        current.after = change.sheet
        current.motion = change.motion
        sheetDrag = current
        showSheetDrag(current)
        finishSheetDrag(keep: true)
    }

    /// Picks another drawing scale for the selected sheet (`CanvasEditor.changeSelectedSheetScale`).
    func changeSelectedSheetScale(to scale: Sheet.Scale) async {
        guard let change = await editor.changeSelectedSheetScale(to: scale) else { return }
        applySheetChange(change)
    }

    /// The Change scale menu: read when it opens, with the scale in hand ticked.
    fileprivate func sheetScaleMenu() async -> [UIMenuElement] {
        guard let sheet = editor.selectedSheet else { return [] }
        let scales = await editor.scalesOffered(for: sheet)
        return scales.map { scale in
            UIAction(title: scale.description, state: scale == sheet.scale ? .on : .off) { [weak self] _ in
                Task { @MainActor in await self?.changeSelectedSheetScale(to: scale) }
            }
        }
    }

    /// Places the selected sheet's edge, its catch guide and the strip's angle.
    fileprivate func updateSelectedSheet() {
        let sheet = sheetDrag?.after ?? editor.selectedSheet
        let viewport = editor.viewport
        let screen = { (point: CanvasPoint) -> CGPoint in
            let s = viewport.screenPoint(for: point)
            return CGPoint(x: s.x, y: s.y)
        }
        let caught = sheetDrag?.caught == true
        selectionOverlay.showSheet(corners: sheet?.corners.map(screen), centre: sheet.map { screen($0.centre) } ?? .zero,
                                   catchAngle: caught ? sheet?.angle : nil, in: bounds)
        sheetStrip.show(angle: sheet?.angle, in: bounds)
        if sheet != nil, subviews.last !== sheetStrip { bringSubviewToFront(sheetStrip) }
    }

    #if DEBUG || BENCHMARK
    /// How many strokes came along with the turn or move under way, for the benchmark's log.
    var debugSheetDragStrokes: Int { sheetDrag?.lift.strokes.count ?? 0 }
    #endif

    #if DEBUG
    /// A tap of the Pencil at a canvas point, as a tap with the lasso in hand: for the captures.
    func debugTap(at point: CanvasPoint) {
        let s = editor.viewport.screenPoint(for: point)
        let at = CGPoint(x: s.x, y: s.y)
        guard beginInput(at: at) else { return }
        endInput(samples: [at], keep: true)
    }

    /// A turn button's tap, for the captures.
    func debugTurn(by quarter: Double) { turnSelectedSheet(by: quarter) }

    /// A drag of the Pencil on the selected sheet, by a distance on screen: for the captures.
    func debugDragSheet(by dx: CGFloat, _ dy: CGFloat) {
        guard let sheet = editor.selectedSheet else { return }
        let s = editor.viewport.screenPoint(for: sheet.centre)
        let from = CGPoint(x: s.x, y: s.y)
        guard beginInput(at: from) else { return }
        moveInput(samples: [CGPoint(x: from.x + dx / 2, y: from.y + dy / 2)], predicted: [])
        endInput(samples: [CGPoint(x: from.x + dx, y: from.y + dy)], keep: true)
    }

    /// The top of the kept labels' fits, read on the canvas as they are: for the captures' log.
    func debugSheetLabelLines() -> [String] { annotationOverlay.debugLabels }
    #endif
}
