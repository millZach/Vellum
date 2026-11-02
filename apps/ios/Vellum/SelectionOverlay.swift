import UIKit
import VellumCore

/// The lasso on the canvas (#7), as the prototype at `prototype/canvas-screen` draws it: the loop being drawn as a
/// dashed line; the selection as a dashed box 6 points outside it, with a handle at each corner for resizing; and a
/// dark menu under it with the count, Duplicate and Delete.
///
/// Everything here is in screen points and placed again from the selection's bounds when the view or the selection
/// changes: a few layers and one rectangle, never the selected ink, so a pan or a pinch with a selection costs what it
/// did without one.
@MainActor
final class SelectionOverlay {
    /// How far outside the selection's ink the dashed box sits.
    static let padding: CGFloat = 6
    static let handleSize: CGFloat = 10
    /// How near a corner handle the Pencil must land to take it.
    static let handleReach: CGFloat = 22

    /// The loop being drawn.
    let loopLayer = CAShapeLayer()
    private let boxLayer = CAShapeLayer()
    private var handleLayers: [CAShapeLayer] = []
    let menu: SelectionMenu
    /// The dashed box on screen, when there is a selection.
    private(set) var box: CGRect?

    init(duplicate: @escaping @MainActor () -> Void, delete: @escaping @MainActor () -> Void) {
        menu = SelectionMenu(duplicate: duplicate, delete: delete)
        for shape in [loopLayer, boxLayer] {
            shape.actions = noAnimations
            shape.fillColor = nil
            shape.lineWidth = 1.2
            shape.lineDashPattern = [5, 4]
        }
        for _ in 0..<4 {
            let handle = CAShapeLayer()
            handle.actions = noAnimations
            handle.lineWidth = 1.2
            handle.path = UIBezierPath(roundedRect: CGRect(x: -Self.handleSize / 2, y: -Self.handleSize / 2,
                                                           width: Self.handleSize, height: Self.handleSize),
                                       cornerRadius: 2).cgPath
            handleLayers.append(handle)
        }
        menu.isHidden = true
    }

    /// Adds the layers and the menu to the canvas view, above the ink.
    func install(in view: UIView) {
        view.layer.addSublayer(loopLayer)
        view.layer.addSublayer(boxLayer)
        for handle in handleLayers { view.layer.addSublayer(handle) }
        view.addSubview(menu)
    }

    /// Keeps the layers above live ink drawn after them.
    func bringToFront(in view: UIView) {
        for sublayer in [loopLayer, boxLayer] + handleLayers { view.layer.addSublayer(sublayer) }
        view.bringSubviewToFront(menu)
    }

    func setDark(_ dark: Bool) {
        let accent = Palette.selection(dark: dark).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loopLayer.strokeColor = accent
        boxLayer.strokeColor = accent
        for handle in handleLayers {
            handle.strokeColor = accent
            handle.fillColor = Palette.ground(dark: dark).cgColor
        }
        CATransaction.commit()
    }

    /// Shows the selection around `ink` (its bounds on screen), or nothing; the menu only when `showsMenu`.
    func show(ink: CGRect?, count: Int, showsMenu: Bool, in bounds: CGRect) {
        // Nothing selected and nothing shown: a pan or a pinch without a selection touches no layer.
        if ink == nil || count == 0, box == nil { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let ink, count > 0 else {
            box = nil
            boxLayer.path = nil
            for handle in handleLayers { handle.isHidden = true }
            menu.isHidden = true
            return
        }
        let rect = ink.insetBy(dx: -Self.padding, dy: -Self.padding)
        box = rect
        boxLayer.path = UIBezierPath(rect: rect).cgPath
        for (i, handle) in handleLayers.enumerated() {
            handle.isHidden = false
            handle.position = Self.corner(i, of: rect)
        }
        menu.isHidden = !showsMenu
        guard showsMenu else { return }
        menu.count = count
        let size = menu.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let chrome = CanvasEditor.chromeInsets
        let (top, left, bottom, right) = (CGFloat(chrome.top), CGFloat(chrome.left), CGFloat(chrome.bottom),
                                          CGFloat(chrome.right))
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 10)
        // Clear of the status bar at the foot, above the box when it would not fit under it.
        if origin.y + size.height > bounds.height - bottom - 6 {
            origin.y = rect.minY - 10 - size.height
        }
        origin.x = min(max(origin.x, left + 6), bounds.width - right - size.width - 6)
        origin.y = min(max(origin.y, top + 6), bounds.height - size.height - 6)
        menu.frame = CGRect(origin: origin, size: size)
    }

    /// The corner handle near a screen point (0 top left, then clockwise), if any.
    func handle(at point: CGPoint) -> Int? {
        guard let box else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for i in 0..<4 {
            let c = Self.corner(i, of: box)
            let d = hypot(point.x - c.x, point.y - c.y)
            if d <= Self.handleReach, d < (best?.distance ?? .infinity) { best = (i, d) }
        }
        return best?.index
    }

    /// Whether a screen point is on the selection, to drag it.
    func contains(_ point: CGPoint) -> Bool {
        box?.insetBy(dx: -8, dy: -8).contains(point) ?? false
    }

    static func corner(_ i: Int, of rect: CGRect) -> CGPoint {
        switch i {
        case 0: CGPoint(x: rect.minX, y: rect.minY)
        case 1: CGPoint(x: rect.maxX, y: rect.minY)
        case 2: CGPoint(x: rect.maxX, y: rect.maxY)
        default: CGPoint(x: rect.minX, y: rect.maxY)
        }
    }
}

/// The selection's menu: how many things are selected, Duplicate and Delete. Dark in both modes, as the prototype's
/// pop-up is.
@MainActor
final class SelectionMenu: UIView {
    private let countLabel = UILabel()
    private let duplicateAction: @MainActor () -> Void
    private let deleteAction: @MainActor () -> Void

    var count = 0 {
        didSet { countLabel.text = "\(count) selected" }
    }

    init(duplicate: @escaping @MainActor () -> Void, delete: @escaping @MainActor () -> Void) {
        duplicateAction = duplicate
        deleteAction = delete
        super.init(frame: .zero)
        backgroundColor = UIColor(hex: 0x1D1D1F)
        layer.cornerRadius = 10
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = UIColor(hex: 0xAAAAAA)
        let stack = UIStackView(arrangedSubviews: [
            countLabel,
            button("Duplicate", hint: "Copies the selection beside it", action: #selector(duplicateTapped(_:))),
            button("Delete", hint: "Deletes the selection", action: #selector(deleteTapped(_:))),
        ])
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = "Selection"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func button(_ title: String, hint: String, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 12, weight: .medium)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityHint = hint
        return button
    }

    @objc private func duplicateTapped(_ sender: UIButton) { duplicateAction() }
    @objc private func deleteTapped(_ sender: UIButton) { deleteAction() }
}
