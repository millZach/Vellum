import UIKit
import VellumCore

/// The text boxes on the canvas (#7): each a label at its model-space position and size, panning and zooming with
/// the ink, and the one being typed in a text view, which takes the keyboard and the Pencil's handwriting (Scribble:
/// a `UITextView` turns writing over it into text by itself).
///
/// A label's text is laid out once, at a zoom, and a pan or a pinch then moves and scales it with its transform; it is
/// laid out again only when the zoom has moved by more than a factor of two or the pinch ends, so a pan does no text
/// layout. Letters are laid out no larger than `largestLaidOutFont` points and scaled up past it, so a label zoomed
/// right in never needs a huge bitmap; it is a little soft there. Labels off screen are hidden.
@MainActor
final class TextBoxOverlay: NSObject, UITextViewDelegate {
    /// The largest letter height, in screen points, text is laid out at.
    static let largestLaidOutFont = 96.0
    /// Text smaller than this on screen, in points, is not shown: it would be a smudge.
    static let smallestShownFont = 1.5

    private unowned let editor: CanvasEditor
    private weak var host: UIView?
    private var labels: [TextBoxID: Shown] = [:]
    private var viewport: Viewport?
    /// Whether a pinch or pan is under way, so labels wait for it to end before they are laid out again.
    var isGesturing = false

    var isDark = false {
        didSet {
            guard isDark != oldValue else { return }
            for (id, shown) in labels { if let box = editor.text(id) { shown.label.textColor = colour(box) } }
            editing?.view.textColor = editing.map { Palette.ink($0.colour, dark: isDark) }
        }
    }

    /// One label and the zoom its text was laid out at.
    private struct Shown {
        let label: UILabel
        var pointsPerInch: Double
        /// The laid-out letters' size against the box's at that zoom: below 1 when capped.
        var fontScale: Double
    }

    /// The text box being typed in: a new one (no id yet) or an existing one.
    struct Editing {
        let id: TextBoxID?
        let origin: CanvasPoint
        let width: Length
        let fontSize: Length
        let colour: MarkupColour
        let view: UITextView
        /// The zoom the text view was laid out at.
        let pointsPerInch: Double
    }

    private(set) var editing: Editing?
    /// A drag of the selection under way: its transform and the text boxes it moves.
    private var dragging: (transform: CanvasTransform, ids: Set<TextBoxID>)?

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    func install(in view: UIView) {
        host = view
    }

    // MARK: Showing

    /// Places every label for a view of the canvas.
    func show(_ viewport: Viewport) {
        self.viewport = viewport
        guard host != nil else { return }
        let current = Set(editor.texts.map(\.id))
        for id in labels.keys where !current.contains(id) { labels.removeValue(forKey: id)?.label.removeFromSuperview() }
        for box in editor.texts { place(box) }
        placeEditing()
    }

    /// Follows a change to the text boxes: what it took away goes, what it added is shown.
    func textsChanged(_ change: InkChange) {
        for id in change.removedTexts { labels.removeValue(forKey: id)?.label.removeFromSuperview() }
        for box in change.addedTexts { if editor.text(box.id) != nil { place(box) } }
    }

    /// The pinch or pan ended: lay out anything scaled far from its zoom again, crisp.
    func settle() {
        isGesturing = false
        for box in editor.texts { place(box) }
    }

    private func colour(_ box: TextBox) -> UIColor { Palette.ink(box.colour, dark: isDark) }

    private func place(_ original: TextBox) {
        guard let host, let viewport else { return }
        // A drag of the selection moves and scales the label by its transform; the text is laid out as saved.
        let dragScale = dragging.flatMap { $0.ids.contains(original.id) ? $0.transform.scale : nil }
        let moving = dragScale != nil
        let box = dragging.map { moving ? original.transformed(by: $0.transform) : original } ?? original
        let fontOnScreen = box.fontSize.inches * viewport.pointsPerInch
        let screenRect = rect(box.rect, viewport)
        let onScreen = screenRect.intersects(host.bounds.insetBy(dx: -40, dy: -40))
        let hidden = !onScreen || fontOnScreen < Self.smallestShownFont || editing?.id == original.id
        var shown = labels[original.id]
        if hidden {
            shown?.label.isHidden = true
            return
        }
        let ratio = viewport.pointsPerInch / (shown?.pointsPerInch ?? 0)
        let stale = shown == nil || shown!.label.text != original.text
            || (!moving && (ratio < 0.5 || ratio > 2 || (!isGesturing && ratio != 1)))
        if stale {
            let label = shown?.label ?? makeLabel(in: host)
            let font = original.fontSize.inches * viewport.pointsPerInch
            let size = rect(original.rect, viewport).size
            let scale = min(1, Self.largestLaidOutFont / max(font, 1e-9))
            label.transform = .identity
            label.text = original.text
            label.font = .systemFont(ofSize: font * scale)
            label.textColor = colour(original)
            label.bounds = CGRect(x: 0, y: 0, width: size.width * CGFloat(scale), height: size.height * CGFloat(scale))
            label.accessibilityLabel = original.text
            shown = Shown(label: label, pointsPerInch: viewport.pointsPerInch, fontScale: scale)
            labels[original.id] = shown
        }
        guard let shown else { return }
        let k = viewport.pointsPerInch / shown.pointsPerInch / shown.fontScale * (dragScale ?? 1)
        shown.label.isHidden = false
        shown.label.transform = CGAffineTransform(scaleX: k, y: k)
        shown.label.center = CGPoint(x: screenRect.midX, y: screenRect.midY)
    }

    private func makeLabel(in host: UIView) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isUserInteractionEnabled = false
        label.isAccessibilityElement = true
        label.accessibilityTraits = .staticText
        host.addSubview(label)
        return label
    }

    private func rect(_ rect: CanvasRect, _ viewport: Viewport) -> CGRect {
        let a = viewport.screenPoint(for: rect.origin)
        return CGRect(x: a.x, y: a.y, width: rect.size.width.inches * viewport.pointsPerInch,
                      height: rect.size.height.inches * viewport.pointsPerInch)
    }

    /// The topmost text box under a screen point.
    func box(at point: CGPoint) -> TextBox? {
        guard let viewport else { return nil }
        let canvasPoint = viewport.canvasPoint(for: ScreenPoint(x: Double(point.x), y: Double(point.y)))
        return editor.texts.last { $0.rect.contains(canvasPoint) }
    }

    // MARK: Dragging with the selection

    /// Moves the selected text boxes' labels with a drag of the selection, by a transform, or puts them back (nil).
    func drag(_ transform: CanvasTransform?, ids: [TextBoxID]) {
        dragging = transform.map { ($0, Set(ids)) }
        for id in ids { if let box = editor.text(id) { place(box) } }
    }

    // MARK: Typing

    /// Starts a new text box with its top-left corner at a canvas point, at the zoom in hand.
    func beginNew(at origin: CanvasPoint) {
        guard let viewport else { return }
        finishEditing()
        let fontSize = viewport.canvasLength(ofScreen: TextBox.screenFontSize)
        let width = viewport.canvasLength(ofScreen: TextBox.screenWidth)
        startEditing(Editing(id: nil, origin: origin, width: width, fontSize: fontSize, colour: editor.colour,
                             view: makeTextView(), pointsPerInch: viewport.pointsPerInch), text: "")
    }

    /// Starts typing in an existing text box.
    func beginEditing(_ box: TextBox) {
        guard let viewport else { return }
        finishEditing()
        startEditing(Editing(id: box.id, origin: box.origin, width: box.size.width, fontSize: box.fontSize,
                             colour: box.colour, view: makeTextView(), pointsPerInch: viewport.pointsPerInch),
                     text: box.text)
        if let shown = labels[box.id] { shown.label.isHidden = true }
    }

    private func startEditing(_ editing: Editing, text: String) {
        guard let host else { return }
        self.editing = editing
        let view = editing.view
        let font = editing.fontSize.inches * editing.pointsPerInch
        view.font = .systemFont(ofSize: font)
        view.textColor = Palette.ink(editing.colour, dark: isDark)
        view.text = text
        host.addSubview(view)
        layOutEditing()
        placeEditing()
        view.becomeFirstResponder()
    }

    private func makeTextView() -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = self
        view.layer.borderWidth = 1
        view.layer.borderColor = Palette.selection(dark: isDark).withAlphaComponent(0.6).cgColor
        view.layer.cornerRadius = 3
        view.accessibilityLabel = "Text box"
        view.accessibilityHint = "Type, or write with the Pencil"
        return view
    }

    /// Sizes the text view to its width at the zoom it was laid out at, and the height its text needs.
    private func layOutEditing() {
        guard let editing else { return }
        let width = CGFloat(editing.width.inches * editing.pointsPerInch)
        let fits = editing.view.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let line = (editing.view.font?.lineHeight ?? 16)
        editing.view.bounds = CGRect(x: 0, y: 0, width: width, height: max(fits.height, line))
    }

    private func placeEditing() {
        guard let editing, let viewport else { return }
        let k = CGFloat(viewport.pointsPerInch / editing.pointsPerInch)
        let corner = viewport.screenPoint(for: editing.origin)
        let size = editing.view.bounds.size
        editing.view.transform = CGAffineTransform(scaleX: k, y: k)
        editing.view.center = CGPoint(x: CGFloat(corner.x) + size.width * k / 2, y: CGFloat(corner.y) + size.height * k / 2)
    }

    func textViewDidChange(_ textView: UITextView) {
        layOutEditing()
        placeEditing()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard editing?.view === textView else { return }
        finishEditing()
    }

    /// Saves the text box being typed in, as one undo step: a new box with text is placed, an edited one changed, an
    /// emptied one deleted, and a new box left empty is never placed.
    func finishEditing() {
        guard let editing else { return }
        self.editing = nil
        let text = editing.view.text ?? ""
        let height = Length.inches(Double(editing.view.bounds.height) / editing.pointsPerInch)
        editing.view.delegate = nil
        editing.view.resignFirstResponder()
        editing.view.removeFromSuperview()
        if let id = editing.id {
            editor.editText(id, text: text, height: height)
            if let box = editor.text(id) { place(box) }
        } else if !text.isEmpty {
            editor.addText(text, at: editing.origin, width: editing.width, height: height, fontSize: editing.fontSize)
        }
    }

    #if DEBUG
    /// Types into the text box being edited, as the keyboard would: for the simulator captures.
    func debugType(_ text: String) {
        editing?.view.insertText(text)
    }
    #endif
}

// MARK: - Scribble

/// Writing with the Pencil anywhere on the canvas with the text box tool places a text box where the writing starts
/// and turns the handwriting into its text (#7, ADR-0012: Scribble brought in for text boxes). The canvas is one
/// element; focusing it starts a text box at the Pencil, or keeps the one being typed in.
@MainActor
final class CanvasScribble: NSObject, UIIndirectScribbleInteractionDelegate {
    typealias ElementIdentifier = String
    private static let element = "canvas"

    private unowned let overlay: TextBoxOverlay
    private weak var host: UIView?
    /// Whether writing places text: only with the text box tool in hand.
    var isActive = false
    private let place: @MainActor (CGPoint) -> Void

    init(overlay: TextBoxOverlay, host: UIView, place: @escaping @MainActor (CGPoint) -> Void) {
        self.overlay = overlay
        self.host = host
        self.place = place
    }

    func indirectScribbleInteraction(_ interaction: any UIInteraction, requestElementsIn rect: CGRect,
                                     completion: @escaping ([String]) -> Void) {
        completion(isActive ? [Self.element] : [])
    }

    func indirectScribbleInteraction(_ interaction: any UIInteraction, isElementFocused elementIdentifier: String) -> Bool {
        overlay.editing?.view.isFirstResponder ?? false
    }

    func indirectScribbleInteraction(_ interaction: any UIInteraction, frameForElement elementIdentifier: String) -> CGRect {
        host?.bounds ?? .zero
    }

    func indirectScribbleInteraction(_ interaction: any UIInteraction, focusElementIfNeeded elementIdentifier: String,
                                     referencePoint focusReferencePoint: CGPoint,
                                     completion: @escaping ((any UIResponder & UITextInput)?) -> Void) {
        if overlay.editing == nil { place(focusReferencePoint) }
        completion(overlay.editing?.view)
    }
}
