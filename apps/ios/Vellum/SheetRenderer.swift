import QuartzCore
import UIKit
import VellumCore

/// Draws placed sheets (#11): each sheet's PDF page in cached tiles, under the ink.
///
/// Which tiles to draw and which to keep is `SheetTileBook`'s to decide (VellumCore, so the budgets count the real
/// work); this class turns its plans into layers and drawings. Tiles are drawn off the main thread, one at a time, on
/// a queue of their own, from the PDF kept in the canvas folder. Each sheet has a paper layer, its page's colour,
/// shown at once so a sheet never blinks in, and one container layer per level of detail whose transform maps the
/// level onto the screen: a pan or a pinch changes those transforms and draws nothing already drawn. The level last
/// covering the screen stays up under a new one until the new one's tiles are drawn.
///
/// In dark mode a line drawing is drawn inverted, light lines on the dark ground, and a page that inverts badly is
/// drawn as printed, on white paper (`SheetDisplay`, ADR-0011, #100); changing mode draws the tiles again in the new one.
///
/// A sheet's angle (#44) is one more transform, on the layer holding its paper and levels. Tiles are keyed by the paper, so
/// they keep through a turn, a move and a scale change. While one is under way the sheet is a `preview`: each frame moves
/// that transform and draws nothing, and only every few degrees or screen points are the tiles newly in view asked for.
@MainActor
final class SheetRenderer {
    typealias Key = SheetTileBook.Key

    let layer = CALayer()
    private var book: SheetTileBook
    private var sheets: [Sheet] = []
    /// Sheets being turned or moved, as they stand now, in place of how they are saved.
    private var previews: [SheetID: Sheet] = [:]
    /// Where a sheet being turned or moved stood when its tiles were last asked for.
    private var plannedPreview: Sheet?
    private var viewport: Viewport?
    /// Where each sheet's PDF is, asked when its first tile is drawn.
    private let pdfURL: @MainActor (Sheet) -> URL?
    private var holders: [SheetID: SheetLayers] = [:]
    private var inFlight = 0
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Vellum sheet tiles"
        // One thread: CGPDFDocument is read from one thread at a time, and ink tiles keep their two.
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// Every tile asked for, for the benchmark's log.
    private(set) var tilesDrawn = 0

    /// Tile drawings waiting or in flight.
    var pendingCount: Int { inFlight }

    var isDark = false {
        didSet { if isDark != oldValue { redrawEverything() } }
    }
    var displayScale: CGFloat = 3 {
        didSet {
            guard displayScale != oldValue else { return }
            book = SheetTileBook(displayScale: Double(displayScale))
            redrawEverything()
        }
    }

    init(pdfURL: @escaping @MainActor (Sheet) -> URL?) {
        self.pdfURL = pdfURL
        book = SheetTileBook(displayScale: 3)
        layer.actions = noAnimations
    }

    /// How a sheet shows in the mode now.
    func display(of sheet: Sheet) -> SheetDisplay { SheetDisplay.display(dark: isDark, invertsBadly: sheet.invertsBadly) }

    /// The sheets whose paper shows light, for ink colours over them (`SheetDisplay.paperIsLight`,
    /// `MarkupColour.rgb(dark:overLightPaper:)`). Empty in light mode, where the canvas is light anyway.
    var lightPaper: [Sheet] {
        isDark ? sheets.filter { display(of: $0).paperIsLight } : []
    }

    // MARK: The sheets

    /// The sheets on the canvas changed: placed, or taken away by an undo.
    func setSheets(_ new: [Sheet]) {
        let gone = Set(sheets.map(\.id)).subtracting(new.map(\.id))
        sheets = new
        withoutAnimation {
            for id in gone {
                _ = book.forget(sheet: id)
                holders.removeValue(forKey: id)?.container.removeFromSuperlayer()
            }
            // Later sheets on top.
            for sheet in sheets {
                let holder = holders[sheet.id] ?? makeHolder(for: sheet)
                layer.addSublayer(holder.container)
            }
        }
        if let viewport { show(viewport) }
    }

    /// A turn or move under way: the sheet as it stands this frame. One transform; nothing already drawn is drawn again.
    func preview(_ sheet: Sheet) {
        previews[sheet.id] = sheet
        guard let viewport, let holder = holders[sheet.id] else { return }
        withoutAnimation { place(holder, sheet, viewport) }
        let turned = plannedPreview.map { was -> Double in
            let difference = SheetAngle.normalized(sheet.angle - was.angle)
            return min(difference, 360 - difference)
        } ?? .infinity
        let moved = plannedPreview.map { was -> Double in
            (was.origin.distance(to: sheet.origin).inches) * viewport.pointsPerInch
        } ?? .infinity
        if turned >= Self.previewPlanDegrees || moved >= Self.previewPlanPoints {
            plannedPreview = sheet
            show(viewport)
        }
    }

    /// The turn or move ended: the sheet is as the session says, which `setSheets` hears when it changed.
    func endPreview() {
        previews.removeAll()
        plannedPreview = nil
        if let viewport { show(viewport) }
    }

    /// How far a sheet being turned or moved goes before the tiles newly in view are asked for.
    private static let previewPlanDegrees = 5.0
    private static let previewPlanPoints = 64.0

    private func makeHolder(for sheet: Sheet) -> SheetLayers {
        let holder = SheetLayers()
        holders[sheet.id] = holder
        holder.paper.backgroundColor = paperColour(display(of: sheet))
        return holder
    }

    // MARK: The view

    /// Places every sheet for a view of the canvas and asks for the tiles that came into view.
    func show(_ viewport: Viewport) {
        self.viewport = viewport
        guard !sheets.isEmpty else { return }
        let ledger = MainThreadLedger.begin()
        defer { MainThreadLedger.end(.sheetPlan, ledger) }
        let dark = isDark
        let standing = previews.isEmpty ? sheets : sheets.map { previews[$0.id] ?? $0 }
        let plan = book.plan(standing, viewport: viewport) { SheetDisplay.display(dark: dark, invertsBadly: $0.invertsBadly) }
        tilesDrawn = book.tilesDrawn
        withoutAnimation {
            for key in plan.evict { holders[key.sheet]?.removeTile(key) }
            let shown = Dictionary(plan.showing.map { ($0.sheet, $0) }, uniquingKeysWith: { a, _ in a })
            for sheet in standing {
                guard let holder = holders[sheet.id] else { continue }
                place(holder, sheet, viewport)
                guard let showing = shown[sheet.id] else {
                    holder.container.isHidden = true
                    continue
                }
                holder.container.isHidden = false
                let level = holder.level(showing.level)
                for key in showing.keys where holder.tiles[key] == nil { holder.addTile(key, to: level) }
                // A level that covers the screen lets go of the others; until then the last one stays under it.
                holder.show(level: showing.level, covered: showing.covered)
            }
        }
        for key in plan.draw { draw(key) }
    }

    /// Puts a sheet's paper and levels where the view shows them.
    private func place(_ holder: SheetLayers, _ sheet: Sheet, _ viewport: Viewport) {
        let origin = viewport.screenPoint(for: sheet.origin)
        let ppi = viewport.pointsPerInch
        let size = sheet.size
        holder.paper.frame = CGRect(x: origin.x, y: origin.y, width: size.width.inches * ppi,
                                    height: size.height.inches * ppi)
        // The shadow's shape is given, so the render server need not work it out afresh from the layer at each angle.
        let paperBounds = CGRect(origin: .zero, size: holder.paper.bounds.size)
        if holder.paper.shadowPath?.boundingBox != paperBounds { holder.paper.shadowPath = CGPath(rect: paperBounds, transform: nil) }
        holder.container.setAffineTransform(Self.turn(sheet, viewport))
        for (level, container) in holder.levels {
            let k = ppi * sheet.canvasPerPrinted / SheetTileBook.scale(level: level)
            container.container.transform = CATransform3DMakeAffineTransform(
                CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: origin.x, ty: origin.y))
        }
    }

    /// The sheet's angle on screen: a turn about its centre, counter-clockwise, with y running down the screen.
    private static func turn(_ sheet: Sheet, _ viewport: Viewport) -> CGAffineTransform {
        guard sheet.angle != 0 else { return .identity }
        let centre = viewport.screenPoint(for: sheet.centre)
        let (c, s) = SheetAngle.cosineAndSine(sheet.angle)
        return CGAffineTransform(a: c, b: -s, c: s, d: c, tx: centre.x - centre.x * c - centre.y * s,
                                 ty: centre.y + centre.x * s - centre.y * c)
    }

    /// Dark mode changed, or the screen: every tile is drawn again for the new mode.
    private func redrawEverything() {
        _ = book.forget()
        withoutAnimation {
            for (id, holder) in holders {
                holder.removeAllTiles()
                if let sheet = sheets.first(where: { $0.id == id }) {
                    holder.paper.backgroundColor = paperColour(display(of: sheet))
                }
            }
        }
        if let viewport { show(viewport) }
    }

    private func paperColour(_ display: SheetDisplay) -> CGColor {
        switch display {
        case .asPrinted: UIColor.white.cgColor
        case .inverted: Self.invertedPaper.cgColor
        }
    }

    /// An inverted sheet's paper: a shade lighter than the dark ground, so its edge shows.
    static let invertedPaper = UIColor(hex: 0x232428)

    // MARK: Drawing tiles

    private func draw(_ key: Key) {
        guard let sheet = sheets.first(where: { $0.id == key.sheet }), let holder = holders[key.sheet],
              let tile = holder.tiles[key], let url = pdfURL(sheet) else {
            book.didFail(key)
            return
        }
        let job = SheetTileJob(url: url, page: sheet.page?.index ?? 0, key: key, paper: sheet.paper,
                               displayScale: displayScale, cancelled: tile.cancelled)
        inFlight += 1
        queue.addOperation { [weak self] in
            let image = SheetTileJob.draw(job)
            let box = SheetImage(image: image)
            Task { @MainActor [weak self] in self?.finish(key, box) }
        }
    }

    private func finish(_ key: Key, _ box: SheetImage) {
        let ledger = MainThreadLedger.begin()
        defer { MainThreadLedger.end(.sheetTilesLanded, ledger) }
        inFlight -= 1
        guard let holder = holders[key.sheet], let tile = holder.tiles[key], !tile.cancelled.isSet else { return }
        guard let image = box.image else {
            book.didFail(key)
            return
        }
        book.didDraw(key)
        withoutAnimation { tile.layer.contents = image }
        // The level may cover the screen now, letting the old one go.
        if let viewport, inFlight == 0 || holder.levels.count > 1 { show(viewport) }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    #if DEBUG || BENCHMARK
    /// Sheet tiles kept, for the benchmark's log.
    var debugCachedTiles: Int { book.cachedCount }
    #endif
}

/// One sheet's layers: its paper, and a container per level of detail holding that level's tiles.
@MainActor
private final class SheetLayers {
    let container = CALayer()
    let paper = CALayer()
    private(set) var levels: [Int: LevelLayer] = [:]
    private(set) var tiles: [SheetTileBook.Key: TileLayer] = [:]

    init() {
        for layer in [container, paper] { layer.actions = noAnimations }
        container.anchorPoint = .zero
        container.position = .zero
        paper.anchorPoint = .zero
        // A turned sheet's edge stays smooth. Tiles leave theirs off, so no seam shows between them at an angle.
        paper.allowsEdgeAntialiasing = true
        paper.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge, .layerTopEdge, .layerBottomEdge]
        paper.shadowColor = UIColor.black.cgColor
        paper.shadowOpacity = 0.18
        paper.shadowRadius = 4
        paper.shadowOffset = CGSize(width: 0, height: 1)
        container.addSublayer(paper)
    }

    func level(_ level: Int) -> LevelLayer {
        if let existing = levels[level] { return existing }
        let made = LevelLayer()
        levels[level] = made
        container.addSublayer(made.container)
        return made
    }

    func addTile(_ key: SheetTileBook.Key, to level: LevelLayer) {
        let tile = TileLayer()
        let side = SheetTileBook.tileSize
        tile.layer.frame = CGRect(x: Double(key.x) * side, y: Double(key.y) * side, width: side, height: side)
        tiles[key] = tile
        level.container.addSublayer(tile.layer)
    }

    func removeTile(_ key: SheetTileBook.Key) {
        guard let tile = tiles.removeValue(forKey: key) else { return }
        tile.cancelled.set()
        tile.layer.removeFromSuperlayer()
    }

    func removeAllTiles() {
        for key in Array(tiles.keys) { removeTile(key) }
        for level in levels.values { level.container.removeFromSuperlayer() }
        levels.removeAll()
    }

    /// Shows `current` on top; once it covers the screen, the other levels are hidden. Their tiles stay drawn and
    /// kept, as the book counts them, until it lets them go.
    func show(level current: Int, covered: Bool) {
        guard let top = levels[current] else { return }
        top.container.isHidden = false
        if container.sublayers?.last !== top.container { container.addSublayer(top.container) }
        for (level, layer) in levels where level != current { layer.container.isHidden = covered }
    }
}

/// A drawn tile handed back to the main thread.
private struct SheetImage: @unchecked Sendable { let image: CGImage? }

/// Everything a tile drawing needs, read on the tile thread.
private struct SheetTileJob: @unchecked Sendable {
    let url: URL
    let page: Int
    let key: SheetTileBook.Key
    let paper: PaperSize
    let displayScale: CGFloat
    let cancelled: Flag

    /// The PDF documents open on the tile thread, one per file.
    nonisolated(unsafe) private static var documents: [URL: CGPDFDocument] = [:]

    /// Draws one tile: the page on white paper at the tile's level, then inverted for dark mode if it is a line drawing.
    static func draw(_ job: SheetTileJob) -> CGImage? {
        guard !job.cancelled.isSet else { return nil }
        let document: CGPDFDocument
        if let open = documents[job.url] {
            document = open
        } else {
            guard let opened = CGPDFDocument(job.url as CFURL) else { return nil }
            if documents.count > 8 { documents.removeAll() }
            documents[job.url] = opened
            document = opened
        }
        guard let page = document.page(at: job.page + 1) else { return nil }
        let pixels = Int((SheetTileBook.tileSize * job.displayScale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        let tile = job.key.paperRect
        // Pixels per printed inch at this level.
        let scale = SheetTileBook.scale(level: job.key.level) * Double(job.displayScale)
        // A tile at the page's edge runs past it: only the page is painted, the rest stays clear (y up in pixels).
        let pageArea = CGRect(x: -tile.minX * scale, y: Double(pixels) - (job.paper.height.inches - tile.minY) * scale,
                          width: job.paper.width.inches * scale, height: job.paper.height.inches * scale)
        context.clear(full)
        context.clip(to: pageArea.intersection(full))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(full)
        context.saveGState()
        // y down from the tile's top-left, in printed inches.
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        context.translateBy(x: CGFloat(-tile.minX), y: CGFloat(-tile.minY))
        // Points, y up from the shown page's bottom-left, then the page's own space, turned by its rotation.
        let width = job.paper.width.inches * 72, height = job.paper.height.inches * 72
        context.translateBy(x: 0, y: CGFloat(job.paper.height.inches))
        context.scaleBy(x: 1 / 72, y: -1 / 72)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                     rotate: 0, preserveAspectRatio: true))
        context.interpolationQuality = .high
        context.drawPDFPage(page)
        context.restoreGState()
        guard !job.cancelled.isSet else { return nil }
        switch job.key.display {
        case .asPrinted:
            break
        case .inverted:
            // White to black and black to white, then the black paper lifted to the inverted paper's shade.
            context.setBlendMode(.difference)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(full)
            context.setBlendMode(.lighten)
            context.setFillColor(SheetRenderer.invertedPaperComponents)
            context.fill(full)
        }
        return context.makeImage()
    }
}

extension SheetRenderer {
    /// The inverted paper as a CGColor made off the main thread.
    nonisolated(unsafe) static let invertedPaperComponents = CGColor(srgbRed: 0x23 / 255, green: 0x24 / 255, blue: 0x28 / 255,
                                                             alpha: 1)
}
