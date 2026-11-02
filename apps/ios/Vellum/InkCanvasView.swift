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

    func makeUIView(context: Context) -> InkCanvasUIView {
        InkCanvasUIView(editor: editor)
    }

    func updateUIView(_ view: InkCanvasUIView, context: Context) {
        view.isDark = isDark
        view.units = units
        view.fingerDraws = fingerDraws
        view.tool = tool
        view.viewportDidChange()
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
            renderer.isDark = isDark
            textOverlay.isDark = isDark
            selectionOverlay.setDark(isDark)
            applyColours()
        }
    }

    /// The tool in hand, set by SwiftUI when it changes. Putting the text box tool down finishes the text being typed;
    /// only the text box tool places text with a tap or the Pencil's handwriting.
    var tool: CanvasTool = .pen {
        didSet {
            guard tool != oldValue else { return }
            textTap.isEnabled = tool == .textBox
            scribble?.isActive = tool == .textBox
            if oldValue == .textBox { textOverlay.finishEditing() }
        }
    }

    /// The grid steps by round lengths in the canvas units, so it is redrawn when they change.
    var units: CanvasUnits = .default {
        didSet {
            guard units != oldValue else { return }
            shownViewport = nil
            viewportDidChange()
        }
    }

    /// The Draw with finger switch, set when it changes, never looked up per touch. Off, fingers only pan and pinch
    /// and a touch costs what it did before the switch existed.
    var fingerDraws = FingerDrawingSetting.default {
        didSet {
            guard fingerDraws != oldValue else { return }
            pan.minimumNumberOfTouches = fingerDraws ? 2 : 1
            accessibilityHint = FingerDrawingSetting.accessibilityHint(fingerDraws: fingerDraws)
            fingersOnGlass = 0
        }
    }
    private let pan = UIPanGestureRecognizer()
    /// With Draw with finger on: whether the finger stroke in progress is ink yet.
    private var fingerGate = FingerStrokeGate()
    /// With Draw with finger on: fingers on the canvas, so a finger only starts a stroke alone.
    private var fingersOnGlass = 0
    /// A finger's eraser sweep, while it is pending, holds its samples here and erases them once it is confirmed.
    private var holdsEraser = false
    private var heldEraserPoints: [CanvasPoint] = []

    private let renderer: InkTileRenderer
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

    init(editor: CanvasEditor) {
        self.editor = editor
        renderer = InkTileRenderer(index: { [unowned editor] in editor.inkIndex })
        textOverlay = TextBoxOverlay(editor: editor)
        super.init(frame: .zero)
        isOpaque = true
        isMultipleTouchEnabled = true
        heldEraserPoints.reserveCapacity(256)
        for grid in [minorGrid, majorGrid] {
            grid.actions = noAnimations
            grid.fillColor = nil
            layer.addSublayer(grid)
        }
        layer.addSublayer(renderer.layer)
        layer.addSublayer(renderer.pendingInkLayer)
        textOverlay.install(in: self)
        selectionOverlay.install(in: self)
        selectionOverlay.setDark(isDark)
        applyColours()

        editor.onInkChange = { [weak self] change in
            self?.renderer.inkChanged(change)
            self?.updateSelectionOverlay()
        }
        editor.onSelectionChange = { [weak self] in self?.selectionDidChange() }
        editor.onTextsChange = { [weak self] change in self?.textOverlay.textsChanged(change) }
        editor.willChangeHistory = { [weak self] in self?.textOverlay.finishEditing() }
        editor.onFinishTextEditing = { [weak self] in self?.textOverlay.finishEditing() }
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

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
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
        for sublayer in [minorGrid, majorGrid, renderer.layer, renderer.pendingInkLayer] {
            sublayer.frame = bounds
        }
        CATransaction.commit()
        renderer.displayScale = traitCollection.displayScale
        editor.viewDidResize(width: Double(bounds.width), height: Double(bounds.height))
        shownViewport = nil
        viewportDidChange()
        #if DEBUG || BENCHMARK
        DebugBenchmark.attach(self, editor: editor)
        #endif
        #if DEBUG
        DebugFingerStroke.attach(self)
        DebugSelection.attach(self, editor: editor)
        #endif
    }

    // MARK: Showing the canvas

    /// Places everything for the editor's view of the canvas, if it changed: one transform per level of tiles, the
    /// grid's few lines, and one transform for the stroke being drawn, so nothing lags a pan or a pinch.
    func viewportDidChange() {
        let viewport = editor.viewport
        guard viewport != shownViewport, bounds.width > 0 else { return }
        shownViewport = viewport
        renderer.show(viewport)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGrid(viewport)
        if let liveBase { liveLayer.transform = InkTileRenderer.transform(from: liveBase, to: viewport) }
        if let lassoBase { selectionOverlay.loopLayer.transform = InkTileRenderer.transform(from: lassoBase, to: viewport) }
        if let drag {
            drag.layer.transform = Self.transform(from: drag.base, to: viewport, applying: drag.transform)
        }
        CATransaction.commit()
        textOverlay.show(viewport)
        updateSelectionOverlay()
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
                endInput(samples: [], keep: fingerGate.interrupted())
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
        let point = canvasPoint(location)
        lastSample = location
        if editor.tool == .lasso {
            beginLasso(at: location, point: point)
        } else if editor.tool == .eraser {
            erasing = true
            if holdingEraser {
                holdsEraser = true
                heldEraserPoints.append(point)
            } else {
                editor.beginEraserSweep()
                editor.erase(at: point)
            }
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
        if lassoing || drag != nil {
            lassoMoved(samples)
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
        if lassoing || drag != nil {
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveTailLayer.path = nil
            if keep {
                renderer.commitLive(live, drawnAt: base) { editor.commit(committed) }
            } else {
                live.removeFromSuperlayer()
            }
            CATransaction.commit()
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
        guard liveTouch == nil, liveStroke == nil, !erasing, !lassoing, drag == nil, fingersDown == 0 else { return }
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        // A finger held still on the eraser is confirmed by time passing, not by a move.
        if holdsEraser { fingerTick(at: link.timestamp) }
        // Holding still at the end of a stroke snaps it: looked at once a frame, never per sample, and recognised
        // once, when the hold is long enough.
        if liveSnaps, snappedShape == nil, let at = lastSample,
           hold.update(at: ScreenPoint(x: Double(at.x), y: Double(at.y)), time: link.timestamp) {
            snapLiveStroke()
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
        case .changed:
            let t = pan.translation(in: self)
            panBy(dx: t.x - lastPanTranslation.x, dy: t.y - lastPanTranslation.y)
            lastPanTranslation = t
        case .ended, .cancelled, .failed:
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
        case .changed:
            zoomBy(pinch.scale / lastPinchScale, about: pinch.location(in: self))
            lastPinchScale = pinch.scale
        case .ended, .cancelled, .failed:
            gestureEnded()
        default:
            break
        }
    }

    private func gestureBegan() {
        fingersDown += 1
        textOverlay.isGesturing = true
        startDisplayLink()
    }

    private func gestureEnded() {
        fingersDown = max(0, fingersDown - 1)
        if fingersDown == 0 { textOverlay.settle() }
        stopDisplayLinkIfIdle()
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
    /// Tile drawings still in flight, for the Debug benchmark.
    var pendingRenderCount: Int { renderer.pendingCount }
    #endif

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Touches on the text being typed and on the selection's menu are theirs, not the canvas's.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view, view !== self else { return true }
        if let typing = textOverlay.editing?.view, view.isDescendant(of: typing) { return false }
        return !view.isDescendant(of: selectionOverlay.menu)
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

    // MARK: The lasso

    /// The Pencil touched down with the lasso: on a corner handle it resizes the selection, on the selection it moves
    /// it, anywhere else it starts a new loop and lets go of the selection.
    private func beginLasso(at location: CGPoint, point: CanvasPoint) {
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
        updateSelectionOverlay()
    }

    /// The Pencil lifted from a drag: the move or resize becomes one undo step, saved as ids and a transform. The
    /// drag layer stays until the moved strokes' tiles are drawn, so the ink never blinks.
    private func finishDrag(keep: Bool) {
        guard let finished = drag else { return }
        drag = nil
        editor.dropSelection(keep ? finished.transform : .identity)
        textOverlay.drag(nil, ids: editor.selection.texts)
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
    private func updateSelectionOverlay() {
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
