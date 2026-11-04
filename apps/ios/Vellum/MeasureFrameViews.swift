import UIKit
import VellumCore

/// The magnifier above the Pencil or finger while a measure or dimension point is being found (#8, "snap with a
/// loupe"), as the prototype draws it: a circle 120 points across, 104 points above the tip (beside it near the top
/// of the screen), showing the canvas under the tip three times larger, with cross hairs at the tip and the snap
/// marker where the point will be taken.
///
/// It never draws the canvas a second time. Its ink is the tile images the renderer has already drawn for the view
/// (`InkTileRenderer.drawnTiles`), shown again in a few layers of its own under one magnifying transform, so moving
/// it costs a lookup of the handful of tiles under it and one transform, once a display frame.
@MainActor
final class Loupe {
    static let radius: CGFloat = 60
    static let magnification: CGFloat = 3
    /// How far above the tip its centre sits.
    static let lift: CGFloat = 104

    /// What goes on screen: the shadowed ring, holding the clipped view.
    let layer = CALayer()
    private let clip = CALayer()
    private let tiles = CALayer()
    private var tileLayers: [CALayer] = []
    private let crossHairs = CAShapeLayer()
    private let marker = CAShapeLayer()

    init() {
        let side = Self.radius * 2
        for item in [layer, clip, tiles] {
            item.actions = noAnimations
        }
        layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 8
        layer.shadowPath = CGPath(ellipseIn: layer.bounds, transform: nil)
        layer.isHidden = true
        clip.frame = layer.bounds
        clip.cornerRadius = Self.radius
        clip.masksToBounds = true
        clip.borderWidth = 2
        tiles.anchorPoint = .zero
        tiles.position = .zero
        tiles.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        clip.addSublayer(tiles)
        for shape in [crossHairs, marker] {
            shape.actions = noAnimations
            shape.fillColor = nil
            clip.addSublayer(shape)
        }
        crossHairs.lineWidth = 1
        crossHairs.opacity = 0.7
        crossHairs.path = AnnotationOverlay.crossHairs(at: CGPoint(x: Self.radius, y: Self.radius))
        marker.lineWidth = 2
        layer.addSublayer(clip)
    }

    /// Shows the loupe for a tip at a screen point, what it snaps to, over the tiles drawn for `viewport`.
    func show(tip: CGPoint, target: PointSnap.Target, viewport: Viewport, renderer: InkTileRenderer, in bounds: CGRect,
              dark: Bool) {
        let r = Self.radius, m = Self.magnification
        var centre = CGPoint(x: tip.x, y: tip.y - Self.lift)
        if centre.y - r < 4 {
            centre = CGPoint(x: tip.x + (tip.x < bounds.midX ? 110 : -110), y: tip.y)
        }
        centre.x = min(max(centre.x, r + 4), bounds.width - r - 4)
        centre.y = min(max(centre.y, r + 4), bounds.height - r - 4)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.isHidden = false
        layer.position = centre
        clip.backgroundColor = Palette.ground(dark: dark).cgColor
        clip.borderColor = (dark ? UIColor(hex: 0xE6E6E6) : UIColor(hex: 0x3A3A3A)).cgColor
        crossHairs.strokeColor = clip.borderColor
        marker.strokeColor = Palette.snap(dark: dark).cgColor

        // The canvas within the loupe's reach of the tip, and the tiles already drawn there.
        let tipPoint = viewport.canvasPoint(for: ScreenPoint(x: Double(tip.x), y: Double(tip.y)))
        let reach = Double(r / m) / viewport.pointsPerInch
        let box = InkIndex.Box(minX: tipPoint.x.inches, minY: tipPoint.y.inches, maxX: tipPoint.x.inches,
                               maxY: tipPoint.y.inches).grown(by: reach)
        let drawn = renderer.drawnTiles(touching: box)
        let found = drawn?.tiles ?? []
        while tileLayers.count < found.count {
            let tile = CALayer()
            tile.actions = noAnimations
            tile.contentsGravity = .resize
            tiles.addSublayer(tile)
            tileLayers.append(tile)
        }
        let side = InkTiling.tileSize
        for (i, tile) in tileLayers.enumerated() {
            guard i < found.count else {
                tile.isHidden = true
                tile.contents = nil
                continue
            }
            tile.isHidden = false
            tile.contents = found[i].image
            tile.frame = CGRect(x: Double(found[i].key.x) * side, y: Double(found[i].key.y) * side, width: side,
                                height: side)
        }
        // Level points to the loupe's own: the level's mapping onto the screen, then magnified about the tip.
        if let tiling = drawn?.tiling {
            let k = viewport.pointsPerInch / tiling.scale
            let anchor = viewport.screenPoint(for: CanvasPoint(x: .inches(tiling.anchorX), y: .inches(tiling.anchorY)))
            tiles.transform = CATransform3DMakeAffineTransform(CGAffineTransform(
                a: m * k, b: 0, c: 0, d: m * k, tx: m * (anchor.x - tip.x) + r, ty: m * (anchor.y - tip.y) + r))
        }

        // The snap marker where the point will be taken, magnified with the canvas.
        let s = viewport.screenPoint(for: target.point)
        let local = CGPoint(x: m * (s.x - tip.x) + r, y: m * (s.y - tip.y) + r)
        marker.path = target.kind == nil ? nil
            : CGPath(rect: CGRect(x: local.x - 7, y: local.y - 7, width: 14, height: 14), transform: nil)
    }

    func hide() {
        guard !layer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        for tile in tileLayers { tile.contents = nil }
        CATransaction.commit()
    }
}

/// A menu item that can't be used yet, faded blue on the window menu's pill (#33). A label, not a disabled `UIButton`,
/// because UIKit chose a disabled button's title colour itself: dark grey and nearly invisible in light, or white once
/// told not to update it. Same font and insets as the menu's buttons; touches fall through to the menu, as a disabled
/// button's do, and VoiceOver hears a dimmed button with its hint.
@MainActor
private final class DisabledMenuItem: UILabel {
    init(title: String, hint: String) {
        super.init(frame: .zero)
        text = title
        font = UIFont.systemFont(ofSize: 12, weight: .medium)
        textAlignment = .center
        textColor = UIColor { traits in
            UIColor(hex: ChromeColourPair.windowMenuDisabled(dark: traits.userInterfaceStyle == .dark).text)
        }
        setContentHuggingPriority(.required, for: .horizontal)
        accessibilityTraits = [.button, .notEnabled]
        accessibilityHint = hint
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 18, height: size.height + 12)
    }
}

/// What to do with a window dragged on the canvas (#8): zoom to it, make a frame of it, or send it (which comes with
/// sending jobs, so it is shown and disabled), or close it. Dark, like the selection's menu.
@MainActor
final class WindowMenu: UIView {
    private let zoomAction: @MainActor () -> Void
    private let frameAction: @MainActor () -> Void
    private let closeAction: @MainActor () -> Void
    private let stack = UIStackView()

    init(zoom: @escaping @MainActor () -> Void, makeFrame: @escaping @MainActor () -> Void,
         close: @escaping @MainActor () -> Void) {
        zoomAction = zoom
        frameAction = makeFrame
        closeAction = close
        super.init(frame: .zero)
        backgroundColor = UIColor { traits in
            UIColor(hex: ChromeColourPair.windowMenuDisabled(dark: traits.userInterfaceStyle == .dark).fill)
        }
        layer.cornerRadius = 10
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        let send = DisabledMenuItem(title: "Send… (later)",
                                    hint: "Not available yet. Sending a window to an agent comes in a later update.")
        let close = button("✕", hint: "Closes the window", action: #selector(closeTapped(_:)))
        close.accessibilityLabel = "Close"
        for view in [
            button("Zoom to window", hint: "Zooms the canvas to the window", action: #selector(zoomTapped(_:))),
            button("Make a frame here", hint: "Places a frame on the paper in hand at the scale that covers the window",
                   action: #selector(frameTapped(_:))),
            send,
            close,
        ] { stack.addArrangedSubview(view) }
        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        stack.distribution = .fill
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = "Window"
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func button(_ title: String, subtitle: String? = nil, hint: String, action: Selector?) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.subtitle = subtitle
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 12, weight: .medium)
            return attributes
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 10)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.setContentHuggingPriority(.required, for: .horizontal)
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
        button.accessibilityHint = hint
        return button
    }

    /// Places the menu under a window's rectangle on screen (above it when it would not fit), clear of the chrome.
    func place(under rect: CGRect, in bounds: CGRect) {
        // Each button at its own width on one line, with the stack's spacing and margins round them.
        let buttons = stack.arrangedSubviews.map { $0.intrinsicContentSize }
        let size = CGSize(width: buttons.reduce(0) { $0 + $1.width } + stack.spacing * CGFloat(max(buttons.count - 1, 0)) + 8,
                          height: (buttons.map(\.height).max() ?? 30) + 8)
        let chrome = CanvasEditor.chromeInsets
        let (top, left, bottom, right) = (CGFloat(chrome.top), CGFloat(chrome.left), CGFloat(chrome.bottom),
                                          CGFloat(chrome.right))
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 10)
        if origin.y + size.height > bounds.height - bottom - 6 { origin.y = rect.minY - 10 - size.height }
        origin.x = min(max(origin.x, left + 6), bounds.width - right - size.width - 6)
        origin.y = min(max(origin.y, top + 6), bounds.height - bottom - size.height - 6)
        frame = CGRect(origin: origin, size: size)
    }

    @objc private func zoomTapped(_ sender: UIButton) { zoomAction() }
    @objc private func frameTapped(_ sender: UIButton) { frameAction() }
    @objc private func closeTapped(_ sender: UIButton) { closeAction() }
}
