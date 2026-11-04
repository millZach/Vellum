import UIKit
import VellumCore

/// The line and shape tool's own drawing (#40): the shape part way through, its preview, the angle guide, the tag that shows
/// a finished shape's size, the number pad that corrects it, and a polyline's Done.
///
/// The canvas view hands it the tip. Nothing here runs per Pencil sample: the tip is noted, and once a display frame it is
/// snapped through the index, caught on an angle if nothing snapped, and the preview's few layers are placed. A shape becomes
/// ink only when it is finished; a polyline part way through is not yet ink, so a crash loses at most that one, as a crash
/// loses the stroke still being drawn. Leaving the canvas or putting the tool down finishes it.
@MainActor
final class ShapeDrawing {
    private let editor: CanvasEditor
    private weak var host: InkCanvasUIView?
    private let previewLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let dotsLayer = CAShapeLayer()
    private let label = Pill()
    private let tagButton = UIButton(type: .custom)
    private let padView = NumberPadView(frame: .zero)
    private let doneButton = UIButton(type: .custom)
    private var isDark = false

    private var draft: ShapeDraft?
    /// The tip while it is down.
    private(set) var isDown = false
    /// Whether it has gone far enough from where it touched down not to be a tap, or a finger resting.
    private(set) var hasMoved = false
    private(set) var tipMoved = false
    private var downAt: CGPoint = .zero
    private var tip: CGPoint = .zero
    /// The point a drag's start took, while nothing has been placed for it.
    private var downPoint: CanvasPoint?
    private var placedByThisDrag = false
    private var aimed: (point: CanvasPoint, guide: Double?)?

    /// The shape the tag is showing, and the stroke it became; nil while it is a polyline still being drawn.
    private var tagged: (shape: DrawnShape, stroke: StrokeID?)?
    private var pad: NumberPad?

    /// How far a tip moves on screen, in points, before it is a drag and not a tap, as on the prototype.
    private static let dragReach: CGFloat = 6

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    func install(in view: InkCanvasUIView, below loupe: CALayer) {
        host = view
        for layer in [previewLayer, guideLayer, dotsLayer] {
            layer.actions = noAnimations
            layer.lineCap = .round
            layer.lineJoin = .round
            view.layer.insertSublayer(layer, below: loupe)
        }
        previewLayer.fillColor = nil
        guideLayer.fillColor = nil
        guideLayer.lineWidth = 1
        guideLayer.lineDashPattern = [5, 5]
        view.layer.insertSublayer(label.layer, below: loupe)
        label.layer.anchorPoint = .zero
        label.layer.isHidden = true

        tagButton.layer.cornerRadius = 9
        tagButton.layer.borderWidth = 1
        tagButton.titleLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        tagButton.isHidden = true
        tagButton.accessibilityHint = "Opens the number pad to correct the shape"
        tagButton.addAction(Self.action { [weak self] in self?.openPad() }, for: .touchUpInside)
        view.addSubview(tagButton)

        doneButton.layer.cornerRadius = 9
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 13.5, weight: .semibold)
        doneButton.isHidden = true
        doneButton.accessibilityHint = "Finishes the polyline"
        doneButton.addAction(Self.action { [weak self] in self?.finishDraft() }, for: .touchUpInside)
        view.addSubview(doneButton)

        padView.isHidden = true
        padView.onKey = { [weak self] key in self?.padKey(key) }
        padView.onBackspace = { [weak self] in self?.padBackspace() }
        padView.onEnter = { [weak self] in self?.padEnter() }
        padView.onSelect = { [weak self] field in self?.padSelect(field) }
        view.addSubview(padView)
        applyColours()
    }

    private static func action(_ body: @escaping @MainActor @Sendable () -> Void) -> UIAction {
        UIAction { _ in MainActor.assumeIsolated { body() } }
    }

    /// Whether a view is one of this tool's, whose touches aren't the canvas's.
    func owns(_ view: UIView) -> Bool {
        view.isDescendant(of: tagButton) || view.isDescendant(of: padView) || view.isDescendant(of: doneButton)
    }

    func setDark(_ dark: Bool) {
        isDark = dark
        applyColours()
        render()
    }

    private func applyColours() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guideLayer.strokeColor = Palette.snap(dark: isDark).cgColor
        dotsLayer.fillColor = Palette.snap(dark: isDark).cgColor
        dotsLayer.strokeColor = nil
        CATransaction.commit()
        let accent = Palette.selection(dark: isDark)
        tagButton.backgroundColor = isDark ? UIColor(hex: 0x242529) : UIColor(hex: 0xFBF9F5)
        tagButton.layer.borderColor = accent.cgColor
        tagButton.setTitleColor(accent, for: .normal)
        doneButton.backgroundColor = accent
        doneButton.setTitleColor(isDark ? UIColor(hex: 0x1F2023) : UIColor(hex: 0xFFFDF9), for: .normal)
        padView.applyColours(dark: isDark)
    }

    // MARK: The tip

    /// The tip touched down with a shape in hand: the first point, or the next.
    func down(at location: CGPoint) {
        if draft == nil { draft = ShapeDraft(kind: editor.lineShape) }
        isDown = true
        hasMoved = false
        placedByThisDrag = false
        downAt = location
        tip = location
        downPoint = nil
        hideTagForNow()
        tick()
    }

    func moved(to location: CGPoint) {
        tip = location
        tipMoved = true
    }

    /// Once a display frame while the tip is down: snap it, catch it, and show where it would land.
    func tick() {
        tipMoved = false
        guard isDown, let host, var current = draft else { return }
        if !hasMoved, hypot(tip.x - downAt.x, tip.y - downAt.y) > Self.dragReach {
            hasMoved = true
            // A drag: the first point is where it touched down, and lifting takes the next.
            if current.placed.isEmpty, let downPoint {
                _ = current.place(downPoint, screenDistance: distanceOnScreen)
                placedByThisDrag = true
                draft = current
                publishStep()
            }
        }
        let raw = host.canvasPointForShape(tip)
        let target = editor.snapTarget(at: raw, anchor: current.anchor)
        aimed = current.resolve(target)
        if downPoint == nil { downPoint = aimed?.point }
        host.showShapeLoupe(tip: tip, raw: raw, target: target)
        render()
    }

    /// The tip lifted (`keep`) or was taken away: places the point, and finishes the shape if that was its last.
    func up(at location: CGPoint?, keep: Bool) {
        guard isDown, let host else { return }
        if let location { tip = location }
        isDown = false
        tipMoved = false
        host.hideShapeLoupe()
        guard keep, var current = draft else {
            if placedByThisDrag { draft?.removeLast() }
            if draft?.placed.isEmpty == true { draft = nil }
            aimed = nil
            restoreTag()
            render()
            publishStep()
            return
        }
        let raw = host.canvasPointForShape(tip)
        let point = current.resolve(editor.snapTarget(at: raw, anchor: current.anchor)).point
        let placement = current.place(point, screenDistance: distanceOnScreen)
        aimed = nil
        switch placement {
        case .waiting:
            draft = current
            if current.kind == .polyline, let drawn = current.finish() {
                show(tag: drawn, stroke: nil)
            }
        case .finished(let shape):
            draft = nil
            commit(shape)
        }
        render()
        publishStep()
    }

    private var distanceOnScreen: (CanvasPoint, CanvasPoint) -> Double {
        let ppi = editor.viewport.pointsPerInch
        return { $0.distance(to: $1).inches * ppi }
    }

    private func commit(_ shape: DrawnShape) {
        guard let host, let stroke = host.commitShape(shape.shape) else { return }
        show(tag: shape, stroke: stroke.id)
        UIAccessibility.post(notification: .announcement, argument: "\(shape.shape.name): \(shape.tag(units: editor.canvas.units))")
    }

    /// Finishes a polyline part way through, which is ink from then on; any other shape not finished goes, having only a
    /// point or two to its name. Done, the tool put down, another shape picked, or the canvas left.
    func finishDraft() {
        guard let current = draft else { return }
        draft = nil
        aimed = nil
        if isDown {
            isDown = false
            host?.hideShapeLoupe()
        }
        if current.kind == .polyline, let shape = current.finish() {
            commit(shape)
        } else if tagged?.stroke == nil {
            clearTag()
        }
        render()
        publishStep()
    }

    /// An undo with a shape part way through takes its last point back, as on the prototype. False when there is none, so
    /// the undo is the ink's.
    func undoLastPoint() -> Bool {
        guard var current = draft, !isDown else { return false }
        current.removeLast()
        draft = current.placed.isEmpty ? nil : current
        clearTag()
        if let draft, draft.kind == .polyline, let drawn = draft.finish() { show(tag: drawn, stroke: nil) }
        render()
        publishStep()
        return true
    }

    private func publishStep() {
        let step: CanvasTool.Step
        if let draft, !draft.placed.isEmpty {
            step = .drawing(draft.prompt)
        } else if editor.placingSheet != nil {
            step = .placeSheet
        } else {
            step = .start
        }
        if editor.toolStep != step { editor.toolStep = step }
        editor.setDraftInProgress(draft != nil && draft?.placed.isEmpty == false)
    }

    // MARK: Showing it

    /// Places the preview, the guide, the placed points and the running size for the view now: a few layers, at most 73 points.
    func render() {
        guard let host else { return }
        let viewport = editor.viewport
        let screen = { (point: CanvasPoint) -> CGPoint in
            let s = viewport.screenPoint(for: point)
            return CGPoint(x: s.x, y: s.y)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        doneButton.isHidden = !(draft?.kind == .polyline && (draft?.placed.count ?? 0) > 1 && !isDown)
        if !doneButton.isHidden {
            let origin = host.exactPlacement.doneOrigin(width: 72, height: 34)
            doneButton.frame = CGRect(x: origin.x, y: origin.y, width: 72, height: 34)
            if host.subviews.last !== doneButton { host.bringSubviewToFront(doneButton) }
        }
        guard let draft else {
            previewLayer.path = nil
            guideLayer.path = nil
            dotsLayer.path = nil
            label.layer.isHidden = true
            updateTagPlace()
            return
        }
        let shape: DrawnShape? = aimed.flatMap { draft.preview(to: $0.point) } ?? draft.finish()
        if let shape {
            let path = CGMutablePath()
            let points = shape.shape.points
            if let first = points.first {
                path.move(to: screen(first))
                for point in points.dropFirst() { path.addLine(to: screen(point)) }
            }
            previewLayer.path = path
            previewLayer.strokeColor = Palette.ink(editor.colour, dark: isDark).cgColor
            previewLayer.lineWidth = editor.weight.screenWidth(for: .pen)
        } else {
            previewLayer.path = nil
        }
        if let guide = aimed?.guide, let anchor = draft.anchor {
            let a = screen(anchor)
            let turn = SheetAngle.cosineAndSine(guide)
            let (c, s) = (CGFloat(turn.cos) * 2000, CGFloat(turn.sin) * 2000)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: a.x - c, y: a.y + s))
            path.addLine(to: CGPoint(x: a.x + c, y: a.y - s))
            guideLayer.path = path
        } else {
            guideLayer.path = nil
        }
        let dots = CGMutablePath()
        for point in draft.placed {
            let s = screen(point)
            dots.addEllipse(in: CGRect(x: s.x - 3, y: s.y - 3, width: 6, height: 6))
        }
        dotsLayer.path = dots
        if isDown, let shape, !draft.placed.isEmpty {
            label.set(shape.tag(units: editor.canvas.units), size: 12, colour: Palette.ground(dark: isDark),
                      fill: Palette.sheetText(dark: isDark).withAlphaComponent(0.9), weight: .semibold)
            let spot = aimed.map { screen($0.point) } ?? tip
            let size = label.layer.bounds.size
            let free = host.exactPlacement
            let x = max(CGFloat(free.left), min(spot.x + 14, CGFloat(free.right) - size.width))
            var y = max(CGFloat(free.top), min(spot.y - 34, CGFloat(free.bottom) - size.height))
            // Under the tip instead when the loupe is where it would go.
            let loupe = free.loupeCentre(tip: ScreenPoint(x: Double(tip.x), y: Double(tip.y)), radius: Double(Loupe.radius),
                                         lift: Double(Loupe.lift))
            let loupeRect = CGRect(x: loupe.x - Double(Loupe.radius), y: loupe.y - Double(Loupe.radius),
                                   width: Double(Loupe.radius) * 2, height: Double(Loupe.radius) * 2)
            if loupeRect.intersects(CGRect(x: x, y: y, width: size.width, height: size.height)) {
                y = min(spot.y + 16, CGFloat(free.bottom) - size.height)
            }
            label.layer.position = CGPoint(x: x, y: y)
            label.layer.isHidden = false
        } else {
            label.layer.isHidden = true
        }
        updateTagPlace()
    }

    /// The view of the canvas changed, or its size: everything follows, and the tip now means another point.
    func viewChanged() {
        if isDown { tipMoved = true }
        guard draft != nil || tagged != nil else { return }
        render()
        placePad()
    }

    // MARK: The tag

    /// Shows a finished shape's size: Draw it's, or one this tool drew.
    func showTag(for shape: DrawnShape, stroke: StrokeID) { show(tag: shape, stroke: stroke) }

    private func show(tag shape: DrawnShape, stroke: StrokeID?) {
        tagged = (shape, stroke)
        pad = nil
        padView.isHidden = true
        tagButton.isHidden = false
        refreshTag()
    }

    /// Set the tag's words, in the canvas units.
    func refreshTag() {
        guard let tagged else { return }
        let text = tagged.shape.tag(units: editor.canvas.units)
        tagButton.setTitle(text, for: .normal)
        tagButton.accessibilityLabel = "Shape size \(text)"
        updateTagPlace()
    }

    private func updateTagPlace() {
        guard let host, let tagged, !tagButton.isHidden else { return }
        let size = ((tagButton.currentTitle ?? "") as NSString).size(withAttributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
        ])
        let w = Double(ceil(size.width)) + 18, h = 28.0
        let s = editor.viewport.screenPoint(for: tagged.shape.spot)
        let centre = host.exactPlacement.tagCentre(spot: s, width: w, height: h)
        tagButton.frame = CGRect(x: centre.x - w / 2, y: centre.y - h / 2, width: w, height: h)
        if host.subviews.last !== tagButton { host.bringSubviewToFront(tagButton) }
    }

    /// The tip came down: the tag and any open pad go. A polyline's comes back after the bend.
    private func hideTagForNow() {
        pad = nil
        padView.isHidden = true
        tagButton.isHidden = true
    }

    private func restoreTag() {
        guard draft?.kind == .polyline, tagged != nil else {
            clearTag()
            return
        }
        tagButton.isHidden = false
        updateTagPlace()
    }

    /// The next thing has started: the tag goes, because ink keeps no shape to come back to.
    func clearTag() {
        tagged = nil
        pad = nil
        tagButton.isHidden = true
        padView.isHidden = true
    }

    /// Anything else the Pencil starts.
    func nextThingStarted() {
        guard draft == nil || draft?.kind != .polyline else { return }
        clearTag()
    }

    // MARK: The number pad

    private func openPad() {
        guard let tagged else { return }
        pad = NumberPad(shape: tagged.shape, units: editor.canvas.units)
        tagButton.isHidden = true
        padView.isHidden = false
        showPad()
        placePad()
    }

    private func showPad() {
        guard let pad else { return }
        padView.show(pad)
    }

    private func placePad() {
        guard let host, let tagged, pad != nil else { return }
        let size = padView.bounds.size
        let origin = host.exactPlacement.padOrigin(spot: editor.viewport.screenPoint(for: tagged.shape.spot),
                                                   width: Double(size.width), height: Double(size.height))
        padView.frame.origin = CGPoint(x: origin.x, y: origin.y)
        if host.subviews.last !== padView { host.bringSubviewToFront(padView) }
    }

    private func padKey(_ key: String) {
        pad?.press(key)
        showPad()
    }

    private func padBackspace() {
        pad?.backspace()
        showPad()
    }

    private func padSelect(_ field: DrawnShape.Field) {
        pad?.select(field)
        showPad()
    }

    /// Enter: the shape takes what was typed, as its own undo step, or the pad stays open with the field marked.
    private func padEnter() {
        guard var current = pad, let tagged else { return }
        guard let corrected = current.enter() else {
            pad = current
            showPad()
            UIAccessibility.post(notification: .announcement, argument: "Can't read that")
            return
        }
        if corrected != tagged.shape {
            if let stroke = tagged.stroke {
                editor.correct(stroke, to: corrected.shape.points)
            } else if var drawing = draft {
                drawing.replacePoints(corrected.shape.points)
                draft = drawing
                render()
            }
        }
        // A correction that goes into the session clears nothing here: the tag stays until the next thing starts.
        show(tag: corrected, stroke: tagged.stroke)
        UIAccessibility.post(notification: .announcement, argument: "Corrected: \(corrected.tag(units: editor.canvas.units))")
    }

    #if DEBUG
    /// Taps the tag, for the captures.
    func debugOpenPad() { openPad() }

    /// Presses the pad's keys, for the captures.
    func debugPress(_ keys: [String]) {
        for key in keys { padKey(key) }
    }

    func debugSelect(_ field: DrawnShape.Field) { padSelect(field) }
    func debugEnter() { padEnter() }
    var debugTag: String { tagged?.shape.tag(units: editor.canvas.units) ?? "none" }
    #endif
}

/// The number pad, after the prototype's, with `-` so a fraction can follow a whole number. Touches anywhere on it are its
/// own, so the Pencil never reaches the canvas through a gap between keys.
@MainActor
final class NumberPadView: UIView {
    var onKey: (@MainActor (String) -> Void)?
    var onBackspace: (@MainActor () -> Void)?
    var onEnter: (@MainActor () -> Void)?
    var onSelect: (@MainActor (DrawnShape.Field) -> Void)?

    private final class FieldRow: UIControl {
        let title = UILabel()
        let value = UILabel()
        var field = DrawnShape.Field.length

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.cornerRadius = 8
            layer.borderWidth = 1.5
            title.font = .systemFont(ofSize: 12)
            value.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
            value.textAlignment = .right
            value.adjustsFontSizeToFitWidth = true
            value.minimumScaleFactor = 0.7
            title.isUserInteractionEnabled = false
            value.isUserInteractionEnabled = false
            addSubview(title)
            addSubview(value)
            isAccessibilityElement = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            title.frame = CGRect(x: 8, y: 0, width: 54, height: bounds.height)
            value.frame = CGRect(x: 60, y: 0, width: bounds.width - 68, height: bounds.height)
        }
    }

    private static let width: CGFloat = 162
    private static let inset: CGFloat = 7
    private static let rowHeight: CGFloat = 32
    private static let keyGap: CGFloat = 3
    private var rows: [FieldRow] = []
    private var keys: [UIButton] = []
    private var backspace = UIButton(type: .custom)
    private var enter = UIButton(type: .custom)
    private var isDark = false
    private var shown: NumberPad?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 2)
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = "Number pad"
        for key in NumberPad.keys {
            let button = UIButton(type: .custom)
            button.setTitle(key, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15)
            button.layer.cornerRadius = 7
            button.layer.borderWidth = 1
            button.accessibilityLabel = Self.spoken(key)
            button.addAction(Self.tap { [weak self] in self?.onKey?(key) }, for: .touchUpInside)
            addSubview(button)
            keys.append(button)
        }
        backspace.setTitle("⌫", for: .normal)
        backspace.titleLabel?.font = .systemFont(ofSize: 15)
        backspace.layer.cornerRadius = 7
        backspace.layer.borderWidth = 1
        backspace.accessibilityLabel = "Delete"
        backspace.addAction(Self.tap { [weak self] in self?.onBackspace?() }, for: .touchUpInside)
        addSubview(backspace)
        enter.setTitle("Enter", for: .normal)
        enter.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        enter.layer.cornerRadius = 7
        enter.addAction(Self.tap { [weak self] in self?.onEnter?() }, for: .touchUpInside)
        addSubview(enter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func tap(_ body: @escaping @MainActor @Sendable () -> Void) -> UIAction {
        UIAction { _ in MainActor.assumeIsolated { body() } }
    }

    private static func spoken(_ key: String) -> String {
        switch key {
        case "'": "Feet"
        case "\"": "Inches"
        case "/": "Over"
        case ".": "Point"
        case "-": "Hyphen"
        default: key
        }
    }

    // Everything on the pad is the pad's, gaps included.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    /// Shows what has been typed; lays the pad out again only when its fields change.
    func show(_ pad: NumberPad) {
        let fields = pad.shape.fields
        if rows.map(\.field) != fields {
            for row in rows { row.removeFromSuperview() }
            rows = fields.map { field in
                let row = FieldRow(frame: .zero)
                row.field = field
                row.title.text = field.title
                row.addAction(Self.tap { [weak self] in self?.onSelect?(field) }, for: .touchUpInside)
                addSubview(row)
                return row
            }
            layoutPad()
        }
        shown = pad
        for row in rows {
            let text = pad.text(of: row.field)
            row.value.text = text
            row.accessibilityLabel = row.field.title
            row.accessibilityValue = text
        }
        applyColours(dark: isDark)
    }

    private func layoutPad() {
        let inset = Self.inset, side = Self.width - inset * 2, gap = Self.keyGap, h = Self.rowHeight
        var y = inset
        for row in rows {
            row.frame = CGRect(x: inset, y: y, width: side, height: h)
            y += h + 4
        }
        y += 1
        let keyWidth = (side - gap * 2) / 3
        for (i, key) in keys.enumerated() {
            let (r, c) = (i / 3, i % 3)
            key.frame = CGRect(x: inset + CGFloat(c) * (keyWidth + gap), y: y + CGFloat(r) * (h + gap), width: keyWidth, height: h)
        }
        let last = y + CGFloat(keys.count / 3) * (h + gap)
        backspace.frame = CGRect(x: inset, y: last, width: keyWidth, height: h)
        enter.frame = CGRect(x: inset + keyWidth + gap, y: last, width: keyWidth * 2 + gap, height: h)
        bounds = CGRect(x: 0, y: 0, width: Self.width, height: last + h + inset)
    }

    func applyColours(dark: Bool) {
        isDark = dark
        let panel = dark ? UIColor(hex: 0x242529) : UIColor(hex: 0xFBF9F5)
        let card = dark ? UIColor(hex: 0x1F2023) : UIColor(hex: 0xFFFDF9)
        let line = dark ? UIColor(hex: 0x3A3B40) : UIColor(hex: 0xD9D4C9)
        let ink = dark ? UIColor(hex: 0xE8E6E1) : UIColor(hex: 0x1D1D1F)
        let mute = dark ? UIColor(hex: 0xA9A9AE) : UIColor(hex: 0x6B6B70)
        let accent = Palette.selection(dark: dark)
        let problem = dark ? UIColor(hex: 0xE0A458) : UIColor(hex: 0x9A5B00)
        let selected = dark ? UIColor(hex: 0x2C3A4A) : UIColor(hex: 0xE6EDF5)
        backgroundColor = panel
        layer.borderColor = line.cgColor
        for key in keys + [backspace] {
            key.backgroundColor = card
            key.layer.borderColor = line.cgColor
            key.setTitleColor(ink, for: .normal)
        }
        enter.backgroundColor = accent
        enter.setTitleColor(card, for: .normal)
        for row in rows {
            let isActive = shown?.active == row.field
            row.layer.borderColor = (shown?.problem == row.field ? problem : isActive ? accent : line).cgColor
            row.backgroundColor = isActive ? selected : .clear
            row.title.textColor = mute
            row.value.textColor = shown?.problem == row.field ? problem : ink
        }
    }
}
