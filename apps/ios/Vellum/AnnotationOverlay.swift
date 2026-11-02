import UIKit
import VellumCore

/// Dimensions and frames on the canvas (#8), as the prototype at `prototype/measure-frame` draws them, and what the
/// measure, dimension, frame and window tools show while they are used.
///
/// Kept dimensions and frames sit in one layer drawn in screen points of a view of the canvas (`base`), which a pan
/// or a pinch moves and scales with one transform, as the text boxes do; they are drawn again only when the zoom has
/// moved by more than a factor of two, or when the pinch ends, so a pan draws nothing. A dimension's lines and text
/// are sized from its text height, a real-world length, so it zooms with the ink; its text is hidden when it would be
/// smaller than `smallestText` points on screen. A frame's label is chrome-sized, as in the prototype.
///
/// What the tools show while in use (a measure, the first point, the rubber band to the second, the dimension being
/// pulled off, the frame or window being dragged, the snap marker) is a handful of layers in screen points, placed
/// again at most once a display frame.
@MainActor
final class AnnotationOverlay {
    /// Dimension text smaller than this on screen, in points, is not shown.
    static let smallestText = 4.0
    /// The largest dimension text, in screen points, laid out; larger is scaled.
    static let largestText = 96.0

    private unowned let editor: CanvasEditor
    /// Kept dimensions and frames, in screen points of `base`.
    let keptLayer = CALayer()
    /// What the tools show while in use, in screen points of the view now.
    let toolLayer = CALayer()
    private var base: Viewport?
    private var viewport: Viewport?
    private var items: [Item: CALayer] = [:]
    /// A drag of the selection under way: its transform and what it moves.
    private var dragging: (transform: CanvasTransform, selection: CanvasSelection)?
    /// Whether a pinch or pan is under way: the kept layer waits for it to end before it is drawn again.
    var isGesturing = false

    var isDark = false {
        didSet {
            guard isDark != oldValue else { return }
            rebuildAll()
            showTool()
        }
    }

    enum Item: Hashable {
        case dimension(DimensionID)
        case frame(FrameID)
    }

    /// What the tool in hand is showing (screen points are worked out from these at each update).
    struct ToolState {
        /// A finished measure, until the next one starts or the tool changes.
        var measure: (CanvasPoint, CanvasPoint)?
        /// The first point of a measure or dimension.
        var firstPoint: CanvasPoint?
        /// Where the tip is and what it snaps to, while it is down for a point.
        var tip: (raw: CanvasPoint, target: PointSnap.Target)?
        /// Whether the rubber band from the first point is a measure's (orange) or a dimension's.
        var isMeasure = true
        /// A dimension being pulled off its two points.
        var pulling: CanvasDimension?
        /// A frame being dragged: the rectangle, and the frame it makes.
        var frameDrag: (CanvasRect, Frame)?
        /// A window being dragged or chosen.
        var window: CanvasRect?
    }

    var tool = ToolState() {
        didSet { showTool() }
    }

    // Tool layers, reused.
    private let measureLine = CAShapeLayer()
    private let measurePill = Pill()
    private let bandLine = CAShapeLayer()
    private let bandPill = Pill()
    private let pullingLayer = CALayer()
    private let ghostDrag = CAShapeLayer()
    private let ghostFrame = CAShapeLayer()
    private let ghostLabel = Pill()
    private let windowShape = CAShapeLayer()
    private let firstDot = CAShapeLayer()
    private let marker = CAShapeLayer()
    private let markerPill = Pill()

    init(editor: CanvasEditor) {
        self.editor = editor
        for container in [keptLayer, toolLayer, pullingLayer] {
            container.actions = noAnimations
            container.anchorPoint = .zero
            container.position = .zero
        }
        for shape in [measureLine, bandLine, ghostDrag, ghostFrame, windowShape, firstDot, marker] {
            shape.actions = noAnimations
            shape.fillColor = nil
            shape.lineWidth = 1.2
            toolLayer.addSublayer(shape)
        }
        toolLayer.addSublayer(pullingLayer)
        for pill in [measurePill, bandPill, ghostLabel, markerPill] { toolLayer.addSublayer(pill.layer) }
        measureLine.lineDashPattern = [6, 4]
        bandLine.lineDashPattern = [6, 4]
        ghostDrag.lineDashPattern = [5, 4]
        ghostFrame.lineDashPattern = [8, 5]
        ghostFrame.lineWidth = 1.5
        windowShape.lineDashPattern = [5, 4]
        marker.lineWidth = 2
        applyToolColours()
    }

    /// Adds the layers to the canvas view, above the ink and below the selection.
    func install(in view: UIView) {
        view.layer.addSublayer(keptLayer)
        view.layer.addSublayer(toolLayer)
        resize(to: view.bounds)
    }

    func resize(to bounds: CGRect) {
        for container in [keptLayer, toolLayer, pullingLayer] { container.bounds = bounds }
    }

    // MARK: Kept dimensions and frames

    /// Places the kept layer for a view of the canvas, drawing it again when the zoom has moved far from the one it
    /// was drawn at.
    func show(_ viewport: Viewport) {
        self.viewport = viewport
        if items.isEmpty && editor.dimensions.isEmpty && editor.frames.isEmpty {
            base = viewport
            withoutAnimation { keptLayer.transform = CATransform3DIdentity }
        } else if let base {
            let ratio = viewport.pointsPerInch / base.pointsPerInch
            if ratio < 0.5 || ratio > 2 { rebuildAll() } else { placeKept() }
        } else {
            rebuildAll()
        }
        showTool()
    }

    /// The pinch or pan ended: draw the kept layer again, crisp, if the zoom moved.
    func settle() {
        isGesturing = false
        guard let base, let viewport, viewport.pointsPerInch != base.pointsPerInch else { return }
        rebuildAll()
    }

    /// Follows a change to the dimensions and frames: what it took away goes, what it added is drawn.
    func annotationsChanged(_ change: InkChange) {
        guard base != nil else { return rebuildAll() }
        withoutAnimation {
            for id in change.removedDimensions { items.removeValue(forKey: .dimension(id))?.removeFromSuperlayer() }
            for id in change.removedFrames { items.removeValue(forKey: .frame(id))?.removeFromSuperlayer() }
            for dimension in change.addedDimensions where editor.dimension(dimension.id) != nil { build(dimension) }
            for frame in change.addedFrames where editor.frame(frame.id) != nil { build(frame) }
        }
    }

    /// The canvas units changed: every dimension reads again.
    func unitsChanged() { rebuildAll() }

    /// A drag of the selection moves its dimensions and frames by its transform; nil ends it.
    func drag(_ transform: CanvasTransform?, selection: CanvasSelection) {
        dragging = transform.map { ($0, selection) }
        placeDragged(selection)
    }

    private func rebuildAll() {
        guard let viewport else { return }
        base = viewport
        withoutAnimation {
            for layer in items.values { layer.removeFromSuperlayer() }
            items.removeAll()
            for frame in editor.frames { build(frame) }
            for dimension in editor.dimensions { build(dimension) }
            keptLayer.transform = CATransform3DIdentity
        }
        if let dragging { placeDragged(dragging.selection) }
    }

    private func placeKept() {
        guard let base, let viewport else { return }
        withoutAnimation { keptLayer.transform = InkTileRenderer.transform(from: base, to: viewport) }
    }

    private func placeDragged(_ selection: CanvasSelection) {
        guard let base else { return }
        let move = dragging.map { InkCanvasUIView.transform(from: base, to: base, applying: $0.transform) }
        withoutAnimation {
            for id in selection.dimensions { items[.dimension(id)]?.transform = move ?? CATransform3DIdentity }
            for id in selection.frames { items[.frame(id)]?.transform = move ?? CATransform3DIdentity }
        }
    }

    private func itemLayer(_ item: Item) -> CALayer {
        items.removeValue(forKey: item)?.removeFromSuperlayer()
        let layer = CALayer()
        layer.actions = noAnimations
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.bounds = keptLayer.bounds
        items[item] = layer
        if case .frame = item {
            // Frames go under dimensions.
            keptLayer.insertSublayer(layer, at: 0)
        } else {
            keptLayer.addSublayer(layer)
        }
        return layer
    }

    private func build(_ dimension: CanvasDimension) {
        guard let base else { return }
        let layer = itemLayer(.dimension(dimension.id))
        Self.draw(dimension, label: editor.label(for: dimension), on: base, into: layer, dark: isDark, alpha: 1)
    }

    private func build(_ frame: Frame) {
        guard let base else { return }
        let layer = itemLayer(.frame(frame.id))
        Self.draw(frame, on: base, into: layer, dark: isDark, ghost: false)
    }

    // MARK: Drawing a dimension and a frame

    /// A dimension in screen points of `viewport`: extension lines from just off each point to just past the
    /// dimension line, the line with a tick across each end, and its length in a box at its middle (on the line when
    /// it runs steeply, just above it otherwise). Gaps, overshoots and ticks are a quarter, two fifths and half of
    /// its text height.
    static func draw(_ dimension: CanvasDimension, label: String, on viewport: Viewport, into layer: CALayer, dark: Bool,
                     alpha: Float) {
        let ppi = viewport.pointsPerInch
        let text = dimension.textHeight.inches * ppi
        let gap = text * 0.25, over = text * 0.4, tick = text * 0.5
        let screen = { (p: CanvasPoint) -> CGPoint in
            let s = viewport.screenPoint(for: p)
            return CGPoint(x: s.x, y: s.y)
        }
        let (a, b) = (screen(dimension.start), screen(dimension.end))
        let (d1, d2) = (screen(dimension.line.0), screen(dimension.line.1))
        let path = CGMutablePath()
        for (p, q) in [(a, d1), (b, d2)] {
            let (vx, vy) = (q.x - p.x, q.y - p.y)
            let length = hypot(vx, vy)
            guard length > 4 else { continue }
            let (ux, uy) = (vx / length, vy / length)
            path.move(to: CGPoint(x: p.x + ux * gap, y: p.y + uy * gap))
            path.addLine(to: CGPoint(x: q.x + ux * over, y: q.y + uy * over))
        }
        path.move(to: d1)
        path.addLine(to: d2)
        let length = max(hypot(d2.x - d1.x, d2.y - d1.y), 1e-9)
        let (nx, ny) = (-(d2.y - d1.y) / length, (d2.x - d1.x) / length)
        for p in [d1, d2] {
            path.move(to: CGPoint(x: p.x + nx * tick, y: p.y + ny * tick))
            path.addLine(to: CGPoint(x: p.x - nx * tick, y: p.y - ny * tick))
        }
        let shape = CAShapeLayer()
        shape.actions = noAnimations
        shape.path = path
        shape.fillColor = nil
        shape.strokeColor = Palette.ink(dimension.colour, dark: dark).cgColor
        shape.lineWidth = 1.2
        shape.opacity = alpha
        layer.addSublayer(shape)

        guard text >= smallestText else { return }
        let pill = Pill()
        let size = min(text, largestText)
        pill.set(label, size: size, colour: Palette.ink(dimension.colour, dark: dark),
                 fill: Palette.dimensionBox(dark: dark), weight: .semibold)
        let middle = CGPoint(x: (d1.x + d2.x) / 2, y: (d1.y + d2.y) / 2)
        let steep = abs(d2.y - d1.y) > abs(d2.x - d1.x)
        let box = pill.layer.bounds.size
        pill.layer.position = steep ? middle : CGPoint(x: middle.x, y: middle.y - box.height / 2 - size * 0.15)
        if size < text {
            let k = text / size
            pill.layer.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
            if !steep { pill.layer.position.y = middle.y - box.height * k / 2 - text * 0.15 }
        }
        pill.layer.opacity = alpha
        layer.addSublayer(pill.layer)
    }

    /// A frame in screen points of `viewport`: a dashed rectangle, with its paper and scale under its bottom-left
    /// corner. A ghost (a frame being dragged) is tinted inside.
    static func draw(_ frame: Frame, on viewport: Viewport, into layer: CALayer, dark: Bool, ghost: Bool) {
        let shape = CAShapeLayer()
        configureFrame(shape, frame, on: viewport, dark: dark, ghost: ghost)
        layer.addSublayer(shape)
        let pill = Pill()
        placeFrameLabel(pill, frame, on: viewport, dark: dark)
        layer.addSublayer(pill.layer)
    }

    private static func screenRect(_ rect: CanvasRect, _ viewport: Viewport) -> CGRect {
        let a = viewport.screenPoint(for: rect.origin)
        return CGRect(x: a.x, y: a.y, width: rect.size.width.inches * viewport.pointsPerInch,
                      height: rect.size.height.inches * viewport.pointsPerInch).standardized
    }

    private static func configureFrame(_ shape: CAShapeLayer, _ frame: Frame, on viewport: Viewport, dark: Bool,
                                       ghost: Bool) {
        shape.actions = noAnimations
        shape.path = CGPath(rect: screenRect(frame.bounds, viewport), transform: nil)
        shape.strokeColor = Palette.frame(dark: dark).cgColor
        shape.fillColor = ghost ? Palette.frame(dark: dark).withAlphaComponent(0.07).cgColor : nil
        shape.lineWidth = 1.5
        shape.lineDashPattern = [8, 5]
        shape.opacity = ghost ? 0.85 : 1
    }

    private static func placeFrameLabel(_ pill: Pill, _ frame: Frame, on viewport: Viewport, dark: Bool) {
        pill.set("Frame · \(frame.label)", size: 11, colour: Palette.frameText(dark: dark),
                 fill: Palette.ground(dark: dark).withAlphaComponent(0.8), weight: .semibold, padding: 2, radius: 2)
        let rect = screenRect(frame.bounds, viewport)
        pill.layer.anchorPoint = CGPoint(x: 0, y: 0)
        pill.layer.position = CGPoint(x: rect.minX + 2, y: rect.maxY + 3)
    }

    // MARK: What the tools show

    private func applyToolColours() {
        withoutAnimation {
            measureLine.strokeColor = Palette.measureLine(dark: isDark).cgColor
            bandLine.strokeColor = Palette.measureLine(dark: isDark).cgColor
            ghostDrag.strokeColor = Palette.selection(dark: isDark).cgColor
            windowShape.strokeColor = Palette.selection(dark: isDark).cgColor
            windowShape.fillColor = Palette.selection(dark: isDark).withAlphaComponent(0.08).cgColor
            marker.strokeColor = Palette.snap(dark: isDark).cgColor
        }
    }

    /// Places what the tool in hand is showing for the view now.
    private func showTool() {
        guard let viewport else { return }
        applyToolColours()
        let screen = { (p: CanvasPoint) -> CGPoint in
            let s = viewport.screenPoint(for: p)
            return CGPoint(x: s.x, y: s.y)
        }
        withoutAnimation {
            // A finished measure: dashed orange, ticked, its length in an orange box.
            if let measure = tool.measure {
                let (a, b) = measure
                measureLine.path = Self.tickedLine(screen(a), screen(b))
                measurePill.set(editor.measureText(from: a, to: b), size: 12, colour: .white,
                                fill: Palette.measurePill, weight: .semibold)
                measurePill.layer.position = Self.labelPosition(screen(a), screen(b),
                                                                height: measurePill.layer.bounds.height)
                measurePill.layer.isHidden = false
            } else {
                measureLine.path = nil
                measurePill.layer.isHidden = true
            }

            // The first point, and the band from it to where the tip is.
            if let first = tool.firstPoint {
                let s = screen(first)
                firstDot.path = CGPath(ellipseIn: CGRect(x: s.x - 3.5, y: s.y - 3.5, width: 7, height: 7), transform: nil)
                firstDot.fillColor = (tool.isMeasure ? Palette.measurePill : Palette.ink(editor.colour, dark: isDark))
                    .cgColor
            } else {
                firstDot.path = nil
            }
            if let first = tool.firstPoint, let tip = tool.tip, tool.pulling == nil {
                let (a, b) = (screen(first), screen(tip.target.point))
                if hypot(b.x - a.x, b.y - a.y) > 2 {
                    bandLine.path = Self.tickedLine(a, b)
                    bandLine.strokeColor = (tool.isMeasure ? Palette.measureLine(dark: isDark)
                        : Palette.ink(editor.colour, dark: isDark)).cgColor
                    bandPill.set(editor.measureText(from: first, to: tip.target.point), size: 12,
                                 colour: tool.isMeasure ? .white : Palette.ink(editor.colour, dark: isDark),
                                 fill: tool.isMeasure ? Palette.measurePill : Palette.dimensionBox(dark: isDark),
                                 weight: .semibold)
                    bandPill.layer.position = Self.labelPosition(a, b, height: bandPill.layer.bounds.height)
                    bandPill.layer.opacity = 0.9
                    bandPill.layer.isHidden = false
                } else {
                    bandLine.path = nil
                    bandPill.layer.isHidden = true
                }
            } else {
                bandLine.path = nil
                bandPill.layer.isHidden = true
            }

            // The dimension being pulled off, as it will be kept, a little faded.
            pullingLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            if let pulling = tool.pulling {
                Self.draw(pulling, label: editor.label(for: pulling), on: viewport, into: pullingLayer, dark: isDark,
                          alpha: 0.75)
            }

            // A frame being dragged: the drag, and the frame it makes, with its paper and scale.
            if let frameDrag = tool.frameDrag {
                let (rect, frame) = frameDrag
                ghostDrag.path = CGPath(rect: Self.screenRect(rect, viewport), transform: nil)
                Self.configureFrame(ghostFrame, frame, on: viewport, dark: isDark, ghost: true)
                Self.placeFrameLabel(ghostLabel, frame, on: viewport, dark: isDark)
                ghostLabel.layer.isHidden = false
            } else {
                ghostDrag.path = nil
                ghostFrame.path = nil
                ghostLabel.layer.isHidden = true
            }

            windowShape.path = tool.window.map { CGPath(rect: Self.screenRect($0, viewport), transform: nil) }

            // Where the tip snaps: a square on an end, corner or centre, with its name up and to the right; cross
            // hairs on blank canvas.
            if let tip = tool.tip {
                let s = screen(tip.target.point)
                if let kind = tip.target.kind {
                    marker.path = CGPath(rect: CGRect(x: s.x - 6, y: s.y - 6, width: 12, height: 12), transform: nil)
                    markerPill.set(kind.title, size: 11, colour: Palette.snapText(dark: isDark),
                                   fill: Palette.snap(dark: isDark), weight: .semibold, radius: 8)
                    markerPill.layer.anchorPoint = .zero
                    markerPill.layer.position = CGPoint(x: s.x + 14, y: max(4, s.y - 42))
                    markerPill.layer.isHidden = false
                } else {
                    marker.path = Self.crossHairs(at: s)
                    markerPill.layer.isHidden = true
                }
            } else {
                marker.path = nil
                markerPill.layer.isHidden = true
            }
        }
    }

    /// A line with a short tick across each end.
    private static func tickedLine(_ a: CGPoint, _ b: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        let length = max(hypot(b.x - a.x, b.y - a.y), 1e-9)
        let (nx, ny) = (-(b.y - a.y) / length * 6, (b.x - a.x) / length * 6)
        for p in [a, b] {
            path.move(to: CGPoint(x: p.x + nx, y: p.y + ny))
            path.addLine(to: CGPoint(x: p.x - nx, y: p.y - ny))
        }
        return path
    }

    /// Where a length's box goes on a line: on it when the line runs steeply, just above it otherwise.
    private static func labelPosition(_ a: CGPoint, _ b: CGPoint, height: CGFloat) -> CGPoint {
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        return abs(b.y - a.y) > abs(b.x - a.x) ? middle : CGPoint(x: middle.x, y: middle.y - height / 2 - 2)
    }

    static func crossHairs(at s: CGPoint) -> CGPath {
        let path = CGMutablePath()
        for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1)] {
            path.move(to: CGPoint(x: s.x + dx * 3, y: s.y + dy * 3))
            path.addLine(to: CGPoint(x: s.x + dx * 10, y: s.y + dy * 10))
        }
        return path
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    #if DEBUG
    /// The labels the kept dimensions and frames show, for the captures' console.
    var debugLabels: [String] {
        editor.dimensions.map { "dimension \($0.orientation.rawValue) \(editor.label(for: $0))" }
            + editor.frames.map { "frame \($0.label)" }
    }
    #endif
}

/// A line of text in a rounded box: a dimension's length, a measure's, a frame's paper and scale, a snap's name. A
/// box layer holding a text layer; `layer` is what goes on screen.
@MainActor
final class Pill {
    /// The screen's scale, which text is drawn at; the canvas view sets it.
    static var displayScale: CGFloat = 3

    let layer = CALayer()
    private let textLayer = CATextLayer()

    init() {
        layer.actions = noAnimations
        textLayer.actions = noAnimations
        textLayer.contentsScale = Self.displayScale
        textLayer.alignmentMode = .center
        layer.addSublayer(textLayer)
    }

    /// Sets the text, its size in points and colours, and sizes the box round it.
    func set(_ text: String, size: CGFloat, colour: UIColor, fill: UIColor, weight: UIFont.Weight,
             padding: CGFloat? = nil, radius: CGFloat? = nil) {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
        let measured = attributed.size()
        let pad = padding ?? size * 0.42
        textLayer.contentsScale = Self.displayScale
        textLayer.string = attributed
        textLayer.frame = CGRect(x: pad, y: size * 0.2, width: ceil(measured.width), height: ceil(measured.height))
        layer.bounds = CGRect(x: 0, y: 0, width: ceil(measured.width) + pad * 2,
                              height: ceil(measured.height) + size * 0.4)
        layer.backgroundColor = fill.cgColor
        layer.cornerRadius = radius ?? size * 0.33
        self.text = text
    }

    /// What the pill says.
    private(set) var text = ""
}

extension Palette {
    /// A measure's line: orange, a little lighter on the dark ground (the prototype's).
    static func measureLine(dark: Bool) -> UIColor { dark ? UIColor(hex: 0xF0703A) : UIColor(hex: 0xC2410C) }
    /// A measure's length box.
    static var measurePill: UIColor { UIColor(hex: 0xC2410C) }
    /// The box behind a dimension's length.
    static func dimensionBox(dark: Bool) -> UIColor {
        dark ? UIColor(red: 40 / 255, green: 41 / 255, blue: 45 / 255, alpha: 0.94) : UIColor(white: 1, alpha: 0.94)
    }
    /// A frame's dashed edge, and its label.
    static func frame(dark: Bool) -> UIColor { dark ? UIColor(hex: 0xB892EA) : UIColor(hex: 0x7A4FB3) }
    static func frameText(dark: Bool) -> UIColor { dark ? UIColor(hex: 0xB892EA) : UIColor(hex: 0x5B3191) }
    /// Where a tap snaps: teal.
    static func snap(dark: Bool) -> UIColor { dark ? UIColor(hex: 0x2DD4BF) : UIColor(hex: 0x0F766E) }
    static func snapText(dark: Bool) -> UIColor { dark ? UIColor(hex: 0x0B1F1D) : .white }
}
