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
    /// A selected sheet's edge (#44), turned with it, and the guide showing a twist has caught on a quarter turn.
    private let sheetEdge = CAShapeLayer()
    private let catchGuide = CAShapeLayer()
    private var showsSheet = false
    let menu: SelectionMenu
    /// The dashed box on screen, when there is a selection.
    private(set) var box: CGRect?

    init(duplicate: @escaping @MainActor () -> Void, delete: @escaping @MainActor () -> Void,
         saveSymbol: @escaping @MainActor () -> Void) {
        menu = SelectionMenu(duplicate: duplicate, delete: delete, saveSymbol: saveSymbol)
        for shape in [loopLayer, boxLayer] {
            shape.actions = noAnimations
            shape.fillColor = nil
            shape.lineWidth = 1.2
            shape.lineDashPattern = [5, 4]
        }
        sheetEdge.actions = noAnimations
        sheetEdge.fillColor = nil
        sheetEdge.lineWidth = 2
        sheetEdge.lineJoin = .miter
        catchGuide.actions = noAnimations
        catchGuide.fillColor = nil
        catchGuide.lineWidth = 1.4
        catchGuide.lineDashPattern = [8, 5]
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
        view.layer.addSublayer(sheetEdge)
        view.layer.addSublayer(catchGuide)
        for handle in handleLayers { view.layer.addSublayer(handle) }
        view.addSubview(menu)
    }

    /// Keeps the layers above live ink drawn after them.
    func bringToFront(in view: UIView) {
        for sublayer in [loopLayer, boxLayer, sheetEdge, catchGuide] + handleLayers { view.layer.addSublayer(sublayer) }
        view.bringSubviewToFront(menu)
    }

    func setDark(_ dark: Bool) {
        let accent = Palette.selection(dark: dark).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loopLayer.strokeColor = accent
        boxLayer.strokeColor = accent
        sheetEdge.strokeColor = accent
        catchGuide.strokeColor = Palette.snap(dark: dark).cgColor
        for handle in handleLayers {
            handle.strokeColor = accent
            handle.fillColor = Palette.ground(dark: dark).cgColor
        }
        CATransaction.commit()
    }

    /// Shows the selection around `ink` (its bounds on screen), or nothing; the menu only when `showsMenu`, with Save as
    /// symbol when `canSaveSymbol` (ink or text selected, #41).
    func show(ink: CGRect?, count: Int, showsMenu: Bool, canSaveSymbol: Bool = false, in bounds: CGRect) {
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
        menu.canSaveSymbol = canSaveSymbol
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

    /// Shows a selected sheet's edge from its corners on screen, and, while a twist has caught on a quarter turn, the guide
    /// through its centre along the sheet's edges (`angle` degrees counter-clockwise); nothing without a sheet. A few
    /// points, so a turn pays for one short path a frame.
    func showSheet(corners: [CGPoint]?, centre: CGPoint, catchAngle: Double?, in bounds: CGRect) {
        if corners == nil, !showsSheet { return }
        showsSheet = corners != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let corners, let first = corners.first else {
            sheetEdge.path = nil
            catchGuide.path = nil
            return
        }
        let edge = CGMutablePath()
        edge.move(to: first)
        for corner in corners.dropFirst() { edge.addLine(to: corner) }
        edge.closeSubpath()
        sheetEdge.path = edge
        guard let catchAngle else {
            catchGuide.path = nil
            return
        }
        let (c, s) = SheetAngle.cosineAndSine(catchAngle)
        let reach = max(bounds.width, bounds.height) * 2
        let guide = CGMutablePath()
        guide.move(to: CGPoint(x: centre.x - c * reach, y: centre.y + s * reach))
        guide.addLine(to: CGPoint(x: centre.x + c * reach, y: centre.y - s * reach))
        guide.move(to: CGPoint(x: centre.x - s * reach, y: centre.y - c * reach))
        guide.addLine(to: CGPoint(x: centre.x + s * reach, y: centre.y + c * reach))
        catchGuide.path = guide
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

/// The selection's menu: how many things are selected, Duplicate and Delete, and since #41 Save as symbol when ink or
/// text is selected. Dark, as the prototype's pop-up is, and a lighter grey on the dark canvas so it stands off it.
@MainActor
final class SelectionMenu: UIView {
    private let countLabel = UILabel()
    private let duplicateAction: @MainActor () -> Void
    private let deleteAction: @MainActor () -> Void
    private let saveSymbolAction: @MainActor () -> Void
    private var saveSymbolButton: UIButton!

    var count = 0 {
        didSet { countLabel.text = "\(count) selected" }
    }

    /// Whether Save as symbol shows: ink or text is selected, not a sheet (#41).
    var canSaveSymbol = false {
        didSet { if canSaveSymbol != oldValue { saveSymbolButton.isHidden = !canSaveSymbol } }
    }

    init(duplicate: @escaping @MainActor () -> Void, delete: @escaping @MainActor () -> Void,
         saveSymbol: @escaping @MainActor () -> Void) {
        duplicateAction = duplicate
        deleteAction = delete
        saveSymbolAction = saveSymbol
        super.init(frame: .zero)
        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: 0x3A3B40) : UIColor(hex: 0x1D1D1F)
        }
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
        saveSymbolButton = button("Save as symbol", hint: "Keeps the selected ink in the symbol library, for every canvas",
                                  action: #selector(saveSymbolTapped(_:)))
        saveSymbolButton.isHidden = true
        stack.addArrangedSubview(saveSymbolButton)
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
    @objc private func saveSymbolTapped(_ sender: UIButton) { saveSymbolAction() }
}

/// What sits under the top bar while a sheet is selected (#44), as the prototype at `prototype/sheet-rotate` has it: the
/// sheet's angle, which can't be tapped, 90° left and 90° right, Change scale, and Done. A plot fitted to the page, not
/// to scale, stays NTS, so its strip has no Change scale (#96).
@MainActor
final class SheetStrip: UIView {
    private let angleLabel = UILabel()
    private let angleBox = UIView()
    private let turnLeft: UIButton
    private let turnRight: UIButton
    private let changeScale: UIButton
    private let done: UIButton
    private var shownAngle: String?

    /// `scaleMenu` builds the Change scale menu when it is opened, so a selected sheet reads nothing until then.
    init(turn: @escaping @MainActor @Sendable (Double) -> Void,
         scaleMenu: @escaping @MainActor @Sendable () async -> [UIMenuElement],
         done doneAction: @escaping @MainActor @Sendable () -> Void) {
        turnLeft = SheetStrip.button("90° left", symbol: "rotate.left", hint: "Turns the sheet a quarter turn left") { turn(90) }
        turnRight = SheetStrip.button("90° right", symbol: "rotate.right", hint: "Turns the sheet a quarter turn right") { turn(-90) }
        changeScale = SheetStrip.button("Change scale", symbol: nil, hint: "Picks another drawing scale. The sheet takes the size that scale gives it") {}
        done = SheetStrip.button("Done", symbol: nil, hint: "Lets go of the sheet", filled: true) { doneAction() }
        super.init(frame: .zero)
        changeScale.showsMenuAsPrimaryAction = true
        changeScale.menu = UIMenu(title: "Drawing scale. The sheet takes the size this scale gives it.", children: [
            UIDeferredMenuElement.uncached { completion in
                Task { @MainActor in completion(await scaleMenu()) }
            },
        ])
        angleLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        angleLabel.textAlignment = .center
        angleLabel.translatesAutoresizingMaskIntoConstraints = false
        angleBox.translatesAutoresizingMaskIntoConstraints = false
        angleBox.layer.cornerRadius = 10
        angleBox.layer.borderWidth = 1
        angleBox.addSubview(angleLabel)
        // Wide enough for 359.9°, so the buttons beside it hold still through a turn.
        NSLayoutConstraint.activate([
            angleBox.widthAnchor.constraint(equalToConstant: 72),
            angleBox.heightAnchor.constraint(equalToConstant: 44),
            angleLabel.centerXAnchor.constraint(equalTo: angleBox.centerXAnchor),
            angleLabel.centerYAnchor.constraint(equalTo: angleBox.centerYAnchor),
        ])
        let stack = UIStackView(arrangedSubviews: [angleBox, turnLeft, turnRight, changeScale, done])
        stack.axis = .horizontal
        stack.spacing = 5
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = "Selected sheet"
        angleBox.isAccessibilityElement = true
        applyColours(dark: traitCollection.userInterfaceStyle == .dark)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func button(_ title: String, symbol: String?, hint: String, filled: Bool = false,
                               action: @escaping @MainActor @Sendable () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        if let symbol { configuration.image = UIImage(systemName: symbol) }
        configuration.imagePadding = 5
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 11)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 13.5, weight: filled ? .semibold : .regular)
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in MainActor.assumeIsolated { action() } })
        button.layer.cornerRadius = 10
        button.layer.borderWidth = 1
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.12
        button.layer.shadowRadius = 4
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.accessibilityHint = hint
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    /// The prototype's panel, line and accent.
    func applyColours(dark: Bool) {
        let panel = dark ? UIColor(hex: 0x242529) : UIColor(hex: 0xFBF9F5)
        let line = dark ? UIColor(hex: 0x3A3B40) : UIColor(hex: 0xD9D4C9)
        let ink = dark ? UIColor(hex: 0xE8E6E1) : UIColor(hex: 0x1D1D1F)
        let accent = Palette.selection(dark: dark)
        angleBox.backgroundColor = panel
        angleBox.layer.borderColor = line.cgColor
        angleLabel.textColor = ink
        for button in [turnLeft, turnRight, changeScale] {
            button.backgroundColor = panel
            button.layer.borderColor = line.cgColor
            button.configuration?.baseForegroundColor = ink
        }
        done.backgroundColor = accent
        done.layer.borderColor = accent.cgColor
        done.configuration?.baseForegroundColor = dark ? UIColor(hex: 0x1F2023) : UIColor(hex: 0xFFFDF9)
    }

    /// Shows the strip with the sheet's angle, under the top bar; nil hides it. The angle's text is set only when it reads
    /// differently, and its box holds its width, so a turn lays out one label. `offersScaleChange` is false for a fitted
    /// plot, whose strip goes without Change scale (#96).
    func show(angle: Double?, offersScaleChange: Bool, in bounds: CGRect) {
        guard let angle else {
            if !isHidden { isHidden = true }
            return
        }
        var resize = isHidden
        if changeScale.isHidden == offersScaleChange {
            changeScale.isHidden = !offersScaleChange
            resize = true
        }
        let text = SheetAngle.reading(angle)
        if text != shownAngle {
            shownAngle = text
            angleLabel.text = text
            angleBox.accessibilityLabel = "Angle \(text), counter-clockwise"
        }
        if resize {
            isHidden = false
            let size = systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let chrome = CanvasEditor.chromeInsets
            frame = CGRect(x: CGFloat(chrome.left) + 6, y: CGFloat(chrome.top) + 4, width: size.width, height: size.height)
        }
    }
}
