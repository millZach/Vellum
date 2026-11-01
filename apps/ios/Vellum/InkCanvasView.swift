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

    func makeUIView(context: Context) -> InkCanvasUIView {
        InkCanvasUIView(editor: editor)
    }

    func updateUIView(_ view: InkCanvasUIView, context: Context) {
        view.isDark = isDark
        view.units = units
        view.viewportDidChange()
    }
}

/// Draws the canvas and reads the Pencil. The Pencil draws (or erases); fingers pan and pinch. Nothing depends on
/// pressure or hover, which the USB-C Pencil and the Duo don't have (ADR-0001).
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
            applyColours()
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

    /// On the simulator there is no Pencil, so one finger draws and two fingers pan and pinch. On the Duo only the
    /// Pencil draws.
    #if targetEnvironment(simulator)
    private static let fingerDraws = true
    #else
    private static let fingerDraws = false
    #endif

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
    private var lastPinchScale: CGFloat = 1
    private var lastPanTranslation: CGPoint = .zero
    /// The view of the canvas the layers were last placed for.
    private var shownViewport: Viewport?

    /// Runs only while something is moving, asking for 120 Hz.
    private var displayLink: CADisplayLink?
    private var fingersDown = 0
    /// Where the Pencil is, waiting to go to the status bar on the next frame.
    private var pendingPenPosition: CanvasPoint?

    init(editor: CanvasEditor) {
        self.editor = editor
        renderer = InkTileRenderer(index: { [unowned editor] in editor.inkIndex })
        super.init(frame: .zero)
        isOpaque = true
        isMultipleTouchEnabled = true
        for grid in [minorGrid, majorGrid] {
            grid.actions = noAnimations
            grid.fillColor = nil
            layer.addSublayer(grid)
        }
        layer.addSublayer(renderer.layer)
        layer.addSublayer(renderer.pendingInkLayer)
        applyColours()

        editor.onInkChange = { [weak self] change in self?.renderer.inkChanged(change) }

        let directTouches = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = directTouches
        pan.minimumNumberOfTouches = Self.fingerDraws ? 2 : 1
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = directTouches
        pinch.delegate = self
        addGestureRecognizer(pinch)

        isAccessibilityElement = true
        accessibilityLabel = "Canvas"
        accessibilityHint = "Draw with the Apple Pencil. Pan and pinch with your fingers."
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
        CATransaction.commit()
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
        touch.type == .pencil || (Self.fingerDraws && touch.type == .direct)
    }

    private func canvasPoint(_ p: CGPoint) -> CanvasPoint {
        editor.viewport.canvasPoint(for: ScreenPoint(x: Double(p.x), y: Double(p.y)))
    }

    private func location(_ touch: UITouch) -> CGPoint { touch.preciseLocation(in: self) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard liveTouch == nil, let touch = touches.first(where: draws), beginInput(at: location(touch)) else {
            super.touchesBegan(touches, with: event)
            return
        }
        liveTouch = touch
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = liveTouch, touches.contains(touch) else {
            super.touchesMoved(touches, with: event)
            return
        }
        moveInput(samples: (event?.coalescedTouches(for: touch) ?? [touch]).map(location),
                  predicted: (event?.predictedTouches(for: touch) ?? []).map(location))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = liveTouch, touches.contains(touch) else {
            super.touchesEnded(touches, with: event)
            return
        }
        // The final batch can hold several samples since the last move: all of them are the stroke's tail.
        endInput(samples: (event?.coalescedTouches(for: touch) ?? [touch]).map(location), keep: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = liveTouch, touches.contains(touch) else {
            super.touchesCancelled(touches, with: event)
            return
        }
        // A Pencil stroke the system interrupts is still Zach's ink: keep what was drawn, tail included. Only a finger
        // stroke on the simulator, cancelled because it turned into a two-finger pan, is dropped.
        let keep = touch.type == .pencil
        endInput(samples: keep ? (event?.coalescedTouches(for: touch) ?? [touch]).map(location) : [], keep: keep)
    }

    /// The Pencil touched down at a screen point: starts a stroke or an eraser sweep. False when the tool in hand
    /// does neither.
    func beginInput(at location: CGPoint) -> Bool {
        let point = canvasPoint(location)
        if editor.tool == .eraser {
            erasing = true
            editor.beginEraserSweep()
            editor.erase(at: point)
        } else if let stroke = editor.beginStroke(at: point) {
            liveStroke = stroke
            startLive(stroke)
        } else {
            return false
        }
        editor.penPosition = point
        startDisplayLink()
        return true
    }

    /// The Pencil moved: its coalesced samples since the last move, and where it is predicted to go.
    func moveInput(samples: [CGPoint], predicted: [CGPoint]) {
        consume(samples, ending: false)
        if !erasing {
            livePredicted = predicted.map(canvasPoint)
            updateLive()
        }
    }

    /// The Pencil lifted (or was interrupted): its last samples, and whether to keep the stroke.
    func endInput(samples: [CGPoint], keep: Bool) {
        if !samples.isEmpty { consume(samples, ending: true) }
        finishStroke(keep: keep)
    }

    /// Feeds every one of the Pencil's samples to the eraser or the stroke. Samples closer than half a screen point
    /// are thinned, except the last one when the Pencil lifts, so the stroke ends where the Pencil left the glass.
    private func consume(_ samples: [CGPoint], ending: Bool) {
        let spacing = editor.viewport.canvasLength(ofScreen: 0.5)
        for (i, sample) in samples.enumerated() {
            let point = canvasPoint(sample)
            if erasing {
                editor.erase(at: point)
            } else if ending && i == samples.count - 1 {
                liveStroke?.end(at: point)
            } else {
                liveStroke?.add(point, spacing: spacing)
            }
        }
        // The status bar hears about it on the next frame, not on every sample.
        if let last = samples.last { pendingPenPosition = canvasPoint(last) }
    }

    private func finishStroke(keep: Bool) {
        if erasing { editor.endEraserSweep() }
        if let stroke = liveStroke, let base = liveBase {
            // The live layers catch up with the last samples, drop the prediction, and go to the renderer with the
            // committed stroke; it shows them until the stroke's tiles are drawn, so the stroke never blinks.
            livePredicted = []
            updateLive()
            let live = liveLayer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveTailLayer.path = nil
            if keep {
                renderer.commitLive(live, drawnAt: base) { editor.commit(stroke) }
            } else {
                live.removeFromSuperlayer()
            }
            CATransaction.commit()
        }
        liveTouch = nil
        liveStroke = nil
        liveBase = nil
        liveChunkLayers = []
        erasing = false
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
        guard liveTouch == nil, liveStroke == nil, !erasing, fingersDown == 0 else { return }
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        publishPenPosition()
    }

    private func publishPenPosition() {
        guard let point = pendingPenPosition else { return }
        pendingPenPosition = nil
        if editor.penPosition != point { editor.penPosition = point }
    }

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
        startDisplayLink()
    }

    private func gestureEnded() {
        fingersDown = max(0, fingersDown - 1)
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
}

/// The canvas's colours, light and dark (ADR-0011): a warm paper ground in light, a dark ground in dark, and the ink
/// colours from `MarkupColour`.
enum Palette {
    static func ground(dark: Bool) -> UIColor { dark ? UIColor(hex: 0x1C1D20) : UIColor(hex: 0xF3EFE6) }
    static func grid(dark: Bool) -> UIColor { dark ? UIColor.white : UIColor(hex: 0x786E5A) }

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
