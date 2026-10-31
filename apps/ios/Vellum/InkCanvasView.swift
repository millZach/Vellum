import SwiftUI
import UIKit
import VellumCore

/// The canvas itself: the grid, the ink, and the Pencil drawing on it. Ink is drawn by Vellum's own renderer rather
/// than PencilKit (ADR-0012), so every stroke lives in model space and is drawn through one `Viewport`.
struct InkCanvasView: UIViewRepresentable {
    let editor: CanvasEditor
    let isDark: Bool
    /// Passed in so SwiftUI calls `updateUIView` whenever the ink or the view of it changes.
    let inkRevision: Int
    let viewport: Viewport

    func makeUIView(context: Context) -> InkCanvasUIView {
        InkCanvasUIView(editor: editor)
    }

    func updateUIView(_ view: InkCanvasUIView, context: Context) {
        view.isDark = isDark
        view.setNeedsDisplay()
    }
}

/// Draws the canvas and reads the Pencil. The Pencil draws (or erases); fingers pan and pinch. Nothing depends on
/// pressure or hover, which the USB-C Pencil and the Duo don't have (ADR-0001).
///
/// The stroke being drawn is a separate shape layer updated on every touch, with the Pencil's coalesced and predicted
/// touches, so it keeps up with the pen; finished ink is drawn once into the view and only redrawn when the ink or
/// the view changes.
final class InkCanvasUIView: UIView, UIGestureRecognizerDelegate {
    private let editor: CanvasEditor
    var isDark = false {
        didSet { if isDark != oldValue { setNeedsDisplay() } }
    }

    /// On the simulator there is no Pencil, so one finger draws and two fingers pan and pinch. On the Duo only the
    /// Pencil draws.
    #if targetEnvironment(simulator)
    private static let fingerDraws = true
    #else
    private static let fingerDraws = false
    #endif

    private let liveLayer = CAShapeLayer()
    private var liveTouch: UITouch?
    private var livePoints: [CanvasPoint] = []
    private var liveInk: InkTool?
    private var erasing = false
    private var lastPinchScale: CGFloat = 1
    private var lastPanTranslation: CGPoint = .zero

    init(editor: CanvasEditor) {
        self.editor = editor
        super.init(frame: .zero)
        isOpaque = true
        contentMode = .redraw
        isMultipleTouchEnabled = true
        liveLayer.fillColor = nil
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
        layer.addSublayer(liveLayer)

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
        liveLayer.frame = bounds
        editor.viewDidResize(width: Double(bounds.width), height: Double(bounds.height))
        setNeedsDisplay()
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let viewport = editor.viewport
        context.setFillColor(Palette.ground(dark: isDark).cgColor)
        context.fill(bounds)
        drawGrid(in: context, viewport: viewport)

        let visible = viewport.visibleRect
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in editor.ink.strokes {
            guard let box = stroke.bounds, box.intersects(visible) else { continue }
            draw(stroke, in: context, viewport: viewport)
        }
    }

    private func draw(_ stroke: InkStroke, in context: CGContext, viewport: Viewport) {
        let path = Self.path(for: stroke.points, viewport: viewport)
        context.saveGState()
        context.setAlpha(stroke.tool.opacity)
        context.setStrokeColor(Palette.ink(stroke.colour, dark: isDark).cgColor)
        // Never thinner than a hairline, so zoomed-out ink never vanishes.
        context.setLineWidth(max(stroke.width.inches * viewport.pointsPerInch, 0.75))
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// Minor and major grid lines at round lengths in the canvas units, faint enough to sit under ink.
    private func drawGrid(in context: CGContext, viewport: Viewport) {
        let units = editor.canvas.units
        let minor = ScaleBar.length(fitting: 40, pointsPerInch: viewport.pointsPerInch, units: units).inches
        let major = ScaleBar.length(fitting: 240, pointsPerInch: viewport.pointsPerInch, units: units).inches
        let visible = viewport.visibleRect
        for (step, alpha) in [(minor, isDark ? 0.05 : 0.10), (major, isDark ? 0.10 : 0.20)] {
            guard step * viewport.pointsPerInch >= 8 else { continue }
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
            context.setStrokeColor(Palette.grid(dark: isDark).withAlphaComponent(alpha).cgColor)
            context.setLineWidth(1 / max(1, traitCollection.displayScale))
            context.addPath(path)
            context.strokePath()
        }
    }

    private static func path(for points: [CanvasPoint], viewport: Viewport) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        let start = viewport.screenPoint(for: first)
        path.move(to: CGPoint(x: start.x, y: start.y))
        if points.count == 1 {
            // A dot: a zero-length line with round caps.
            path.addLine(to: CGPoint(x: start.x, y: start.y))
        }
        for point in points.dropFirst() {
            let s = viewport.screenPoint(for: point)
            path.addLine(to: CGPoint(x: s.x, y: s.y))
        }
        return path
    }

    // MARK: The Pencil

    private func draws(_ touch: UITouch) -> Bool {
        touch.type == .pencil || (Self.fingerDraws && touch.type == .direct)
    }

    private func canvasPoint(_ touch: UITouch) -> CanvasPoint {
        let p = touch.preciseLocation(in: self)
        return editor.viewport.canvasPoint(for: ScreenPoint(x: Double(p.x), y: Double(p.y)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard liveTouch == nil, let touch = touches.first(where: draws) else {
            super.touchesBegan(touches, with: event)
            return
        }
        let point = canvasPoint(touch)
        editor.penPosition = point
        if editor.tool == .eraser {
            liveTouch = touch
            erasing = true
            editor.erase(at: point, continuing: false)
        } else if let ink = editor.tool.inkTool {
            liveTouch = touch
            liveInk = ink
            livePoints = [point]
            styleLiveLayer(for: ink)
            updateLiveLayer(predicted: [])
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = liveTouch, touches.contains(touch) else {
            super.touchesMoved(touches, with: event)
            return
        }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for sample in samples {
            let point = canvasPoint(sample)
            if erasing {
                editor.erase(at: point, continuing: true)
            } else if let last = livePoints.last,
                      last.distance(to: point).inches * editor.viewport.pointsPerInch >= 0.5 {
                livePoints.append(point)
            }
        }
        if let last = samples.last { editor.penPosition = canvasPoint(last) }
        if !erasing {
            let predicted = (event?.predictedTouches(for: touch) ?? []).map(canvasPoint)
            updateLiveLayer(predicted: predicted)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = liveTouch, touches.contains(touch) else {
            super.touchesEnded(touches, with: event)
            return
        }
        if !erasing, let last = event?.coalescedTouches(for: touch)?.last {
            let point = canvasPoint(last)
            if livePoints.last != point { livePoints.append(point) }
        }
        finishStroke(keep: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = liveTouch, touches.contains(touch) else {
            super.touchesCancelled(touches, with: event)
            return
        }
        // A Pencil stroke the system interrupts is still Zach's ink: keep what was drawn. Only a finger stroke on the
        // simulator, cancelled because it turned into a two-finger pan, is dropped.
        finishStroke(keep: touch.type == .pencil)
    }

    private func finishStroke(keep: Bool) {
        if keep, !erasing, let ink = liveInk, !livePoints.isEmpty {
            editor.draw(livePoints, with: ink)
        }
        liveTouch = nil
        liveInk = nil
        livePoints = []
        erasing = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.path = nil
        CATransaction.commit()
        setNeedsDisplay()
    }

    private func styleLiveLayer(for ink: InkTool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.strokeColor = Palette.ink(editor.colour, dark: isDark).cgColor
        liveLayer.opacity = Float(ink.opacity)
        liveLayer.lineWidth = (editor.weights[ink] ?? .default).screenWidth(for: ink)
        CATransaction.commit()
    }

    private func updateLiveLayer(predicted: [CanvasPoint]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.path = Self.path(for: livePoints + predicted, viewport: editor.viewport)
        CATransaction.commit()
    }

    // MARK: Fingers

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            lastPanTranslation = .zero
        case .changed:
            let t = pan.translation(in: self)
            editor.viewport.pan(dx: Double(t.x - lastPanTranslation.x), dy: Double(t.y - lastPanTranslation.y))
            lastPanTranslation = t
        default:
            break
        }
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            lastPinchScale = 1
        case .changed:
            let at = pinch.location(in: self)
            editor.viewport.zoom(by: Double(pinch.scale / lastPinchScale), about: ScreenPoint(x: Double(at.x), y: Double(at.y)))
            lastPinchScale = pinch.scale
        default:
            break
        }
    }

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
