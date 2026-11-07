import SwiftUI
import UIKit
import VellumCore

/// Where the drawing viewer hands a sheet to the Canvases tab: the canvases to pick from, newest first, and the tab to
/// show once the sheet is on its way.
@MainActor
struct DrawingHandoff {
    let canvases: CanvasesModel
    let showCanvases: () -> Void
}

/// The drawing viewer (#69), as variant B of prototype/drawing-search has it: the drawing's number and title, its rev,
/// scale, date and project from the index, its file and markers; the page and zoom tools; the pages when there are
/// several; the page; and Place on a canvas… and Open in a new canvas at its foot. Unfolded it sits beside the list
/// and can fill the screen; folded it fills the screen, with a way back to Drawings.
struct DrawingViewerView: View {
    let model: DrawingViewerModel
    let index: DrawingIndexModel
    let handoff: DrawingHandoff?
    /// Filling the screen, with the back button.
    let full: Bool
    /// Folded: no full-screen button, since it always fills the screen.
    let folded: Bool
    let back: () -> Void
    let toggleFull: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var picking = false
    @State private var asking: AddSheetModel?
    @State private var handing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            tools
            if model.isReady, model.pageCount > 1 { DrawingPageStrip(model: model) }
            pageArea
            foot
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: folded && full ? 0 : 14))
        .overlay {
            if !(folded && full) {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color(uiColor: .separator))
            }
        }
        .sheet(isPresented: $picking) {
            PlaceOnCanvasPicker(model: model, canvases: handoff?.canvases.summaries ?? [],
                                pick: { choice in
                                    picking = false
                                    Task { await go(choice) }
                                },
                                cancel: { picking = false })
        }
        .sheet(item: $asking) { model in AddSheetFlow(model: model) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawing-viewer")
        #if DEBUG
        .task(id: model.isReady) { await DebugDrawingViewer.drive(self, ready: model.isReady) }
        #endif
    }

    // MARK: Parts

    private var header: some View {
        let text = DrawingRowText(model.entry)
        let markers = DrawingMarker.of(model.entry, online: index.online, pdfsOnThisDuo: index.pdfsOnThisDuo)
            .filter { $0 != .notOnThisDuo || !model.isReady }
        return VStack(alignment: .leading, spacing: 3) {
            if full {
                Button(action: back) {
                    Label("Drawings", systemImage: "chevron.left").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 4)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let number = text.number { Text(number).font(.system(size: 17, weight: .bold)) }
                Text(text.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            }
            DrawingFlow(spacing: 10) {
                if let revision = model.entry.revision { meta("Rev", revision) }
                if let scale = model.entry.scale { meta("Scale", scale) }
                if let date = model.entry.date { Text(date) }
                if let project = model.entry.project { Text(project) }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            Text(model.pdf?.path ?? model.entry.path)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !markers.isEmpty {
                DrawingFlow(spacing: 4) {
                    ForEach(markers, id: \.self) { DrawingMarkerChip(marker: $0) }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 8, trailing: 14))
    }

    private func meta(_ label: String, _ value: String) -> Text {
        Text("\(label) \(Text(value).fontWeight(.semibold).foregroundStyle(.primary))")
    }

    private var tools: some View {
        HStack(spacing: 6) {
            if model.pageCount > 1 {
                ToolButton(systemImage: "chevron.left", label: "Previous page", disabled: !model.isReady || model.page == 0) {
                    model.page -= 1
                }
                Text("Page \(model.page + 1) of \(model.pageCount)").monospacedDigit()
                ToolButton(systemImage: "chevron.right", label: "Next page",
                           disabled: !model.isReady || model.page >= model.pageCount - 1) {
                    model.page += 1
                }
            } else {
                Text("1 page")
            }
            Spacer(minLength: 4)
            ToolButton(systemImage: "minus", label: "Zoom out", disabled: !model.isReady || model.zoom <= 1) {
                model.zoomOut()
            }
            Text(model.zoom <= 1 ? "Fit" : "\(Int((model.zoom * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 42)
            ToolButton(systemImage: "plus", label: "Zoom in",
                       disabled: !model.isReady || model.zoom >= DrawingViewerModel.zooms.last!) { model.zoomIn() }
            ToolButton(systemImage: "arrow.down.right.and.arrow.up.left.square", label: "Fit the page",
                       disabled: !model.isReady) { model.zoom = 1 }
            if !folded {
                ToolButton(systemImage: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           label: full ? "Back to the list" : "Full screen", disabled: false, action: toggleFull)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var pageArea: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            switch model.state {
            case .ready:
                if let document = model.document {
                    DrawingPageView(document: document, page: model.page, zoom: model.zoom,
                                    dark: colorScheme == .dark,
                                    zoomed: { model.zoom = $0 },
                                    firstTile: { model.firstPageDrawn() })
                        .accessibilityLabel("Page \(model.page + 1) of \(model.entry.number ?? "the drawing")")
                }
            case .downloading(let fraction):
                waitCard {
                    Text("Downloading \(model.entry.number ?? model.pdf?.name ?? "the PDF")").font(.system(size: 15, weight: .semibold))
                    Text("\(sizeText)from Dropbox. Opened once, it stays on this Duo for offline.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    if let fraction {
                        ProgressView(value: fraction).tint(Color.accentColor)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            case .opening:
                ProgressView()
            case .noPDFYet:
                waitCard {
                    Label("No PDF yet", systemImage: "laptopcomputer").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DrawingIndexColors.plot)
                    Text("Nobody has plotted \(model.entry.number ?? model.entry.name) yet, so there is no PDF to show or place. Asking the laptop to plot it from here comes in a later update.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            case .failed(let problem):
                waitCard {
                    Label("Can't open it", systemImage: "exclamationmark.triangle").font(.system(size: 15, weight: .semibold))
                    Text(problem).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var sizeText: String {
        guard let size = model.pdf?.size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " "
    }

    private func waitCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            DrawingThumbnailView(model: index, name: model.entry.thumbnail, width: 300, height: 200)
                .opacity(0.22)
            VStack(alignment: .leading, spacing: 6, content: content)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                .frame(maxWidth: 380, alignment: .leading)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(uiColor: .separator)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .padding(16)
    }

    private var foot: some View {
        let note = Text(model.state == .noPDFYet ? "Place and open come on once the laptop has plotted it." : model.placingNote)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        let buttons = HStack(spacing: 8) {
            Button {
                picking = true
            } label: {
                Label("Place on a canvas…", systemImage: "rectangle.stack.badge.plus")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Pick a canvas, then tap where the sheet goes")
            Button {
                Task { await go(.newCanvas) }
            } label: {
                Text("Open in a new canvas").bold()
            }
            .buttonStyle(ChromePrimaryButtonStyle())
            .accessibilityHint("Makes a canvas named after the drawing, with the sheet in its middle at its scale")
        }
        .font(.system(size: 14))
        .disabled(!model.isReady || handing || handoff == nil)
        .fixedSize()
        return Group {
            if folded {
                VStack(alignment: .leading, spacing: 8) { note; buttons }
            } else {
                HStack(spacing: 8) { note; buttons }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: To a canvas

    enum Choice: Hashable {
        case newCanvas
        case canvas(UUID, name: String, units: CanvasUnits)
    }

    /// Place on a canvas, or Open in a new canvas: at the index's scale, or for AS NOTED (or a scale Vellum can't read)
    /// after asking, with Add sheet's own question; then to the canvas.
    func go(_ choice: Choice) async {
        guard let handoff, !handing else { return }
        handing = true
        defer { handing = false }
        if let scale = model.indexScale {
            guard let pending = await model.pendingSheet(at: scale) else { return }
            hand(pending, to: choice, handoff)
            return
        }
        guard let pdf = model.pdf, let kept = model.kept else { return }
        let units: CanvasUnits
        let label: String
        switch choice {
        case .newCanvas:
            units = .default
            label = "Open in a new canvas"
        case .canvas(_, let name, let canvasUnits):
            units = canvasUnits
            label = "Place on “\(name)”"
        }
        let ask = AddSheetModel(dropbox: .app, units: units, covers: { CanvasEditor.covers($0, units: units) })
        ask.confirm(pdf, kept: kept, page: model.page, number: model.entry.number, placeLabel: label)
        ask.onPlace = { pending in
            asking = nil
            hand(pending, to: choice, handoff)
        }
        ask.close = { asking = nil }
        asking = ask
    }

    private func hand(_ pending: CanvasEditor.PendingSheet, to choice: Choice, _ handoff: DrawingHandoff) {
        let name = DrawingOpening.canvasName(for: model.entry)
        handoff.showCanvases()
        Task {
            switch choice {
            case .newCanvas: await handoff.canvases.openNewCanvas(named: name, with: pending)
            case .canvas(let id, _, _): await handoff.canvases.place(pending, on: id)
            }
        }
    }

    /// For the captures: opens the picker as a tap on Place on a canvas… does.
    func showPicker() { picking = true }
}

/// A small square tool button, as the prototype's viewer tools are.
private struct ToolButton: View {
    let systemImage: String
    let label: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 28)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(label)
    }
}

/// The pages of a set, each a thumbnail drawn off the main thread as it scrolls into view.
private struct DrawingPageStrip: View {
    let model: DrawingViewerModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(0..<model.pageCount, id: \.self) { page in
                    Button { model.page = page } label: {
                        DrawingPageThumb(model: model, page: page, selected: page == model.page)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Page \(page + 1)")
                    .accessibilityAddTraits(page == model.page ? .isSelected : [])
                }
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        }
        .frame(height: 86)
    }
}

private struct DrawingPageThumb: View {
    let model: DrawingViewerModel
    let page: Int
    let selected: Bool
    @State private var image: UIImage?
    @State private var number: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                Color(uiColor: colorScheme == .dark ? UIColor(white: 0.15, alpha: 1) : .white)
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .modifier(DarkInvert(dark: colorScheme == .dark))
                }
            }
            .frame(width: 82, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("p\(page + 1)" + (number.map { " \($0)" } ?? "")).font(.system(size: 11)).lineLimit(1)
        }
        .padding(4)
        .frame(width: 92)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color(uiColor: .separator),
                                                                 lineWidth: selected ? 2 : 1))
        .task {
            guard let reader = model.reader else { return }
            image = await reader.thumbnail(page: page, side: 120)?.image
            number = await reader.info(page: page)?.reading.sheetNumber
        }
    }
}

/// Place on a canvas: New canvas, named after the drawing, then the Canvases list's canvases, newest first (#69).
struct PlaceOnCanvasPicker: View {
    let model: DrawingViewerModel
    let canvases: [CanvasSummary]
    let pick: (DrawingViewerView.Choice) -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        pick(.newCanvas)
                    } label: {
                        row(icon: "plus", title: "New canvas",
                            detail: "Named “\(DrawingOpening.canvasName(for: model.entry))”")
                    }
                }
                Section {
                    ForEach(canvases) { canvas in
                        Button {
                            pick(.canvas(canvas.id, name: canvas.name, units: canvas.units))
                        } label: {
                            row(icon: "square.on.square", title: canvas.name,
                                detail: Self.when.localizedString(for: canvas.modified, relativeTo: Date()).capitalizedFirst,
                                chevron: true)
                        }
                    }
                } footer: {
                    Text("On a canvas you pick, the sheet waits as a true-size outline: tap where it goes.")
                }
            }
            .navigationTitle("Place \(model.entry.number ?? "it") on a canvas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            }
        }
        .tint(Chrome.accent)
    }

    private func row(icon: String, title: String, detail: String, chevron: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Chrome.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if chevron { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }

    static let when: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: The page, in tiles

/// One page of the PDF, fitted to the view and zoomable to 600% with the buttons or a pinch. It is drawn in tiles as
/// they come into view, off the main thread, so a large page opens at once and stays sharp at any zoom.
struct DrawingPageView: UIViewRepresentable {
    let document: DrawingPDFDocument
    let page: Int
    let zoom: Double
    let dark: Bool
    let zoomed: (Double) -> Void
    let firstTile: () -> Void

    func makeUIView(context: Context) -> DrawingPageScrollView { DrawingPageScrollView() }

    func updateUIView(_ view: DrawingPageScrollView, context: Context) {
        view.zoomed = zoomed
        view.firstTile = firstTile
        view.show(document, page: page, dark: dark)
        view.zoom(to: zoom)
    }
}

final class DrawingPageScrollView: UIScrollView, UIScrollViewDelegate {
    private let pageView = TiledPageView()
    private var shown: (document: ObjectIdentifier, page: Int)?
    private var pageSize = CGSize(width: 3, height: 2)
    private var laidOutFor = CGSize.zero
    var zoomed: ((Double) -> Void)?
    var firstTile: (() -> Void)? {
        didSet { pageView.setFirstTile(firstTile) }
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = CGFloat(DrawingViewerModel.zooms.last!)
        bouncesZoom = true
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = true
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        addSubview(pageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ document: DrawingPDFDocument, page: Int, dark: Bool) {
        let id = ObjectIdentifier(document)
        if shown?.document != id || shown?.page != page {
            shown = (id, page)
            let pdfPage = document.page(page)
            pageSize = pdfPage.map(DrawingPDFDocument.viewedSize) ?? CGSize(width: 3, height: 2)
            setZoomScale(1, animated: false)
            laidOutFor = .zero
            pageView.show(pdfPage, dark: dark)
            setNeedsLayout()
        } else {
            pageView.setDark(dark)
        }
    }

    func zoom(to zoom: Double) {
        guard !isZooming, !isZoomBouncing, abs(Double(zoomScale) - zoom) > 0.001 else { return }
        setZoomScale(CGFloat(zoom), animated: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if laidOutFor != bounds.size {
            laidOutFor = bounds.size
            let zoom = zoomScale
            setZoomScale(1, animated: false)
            let room = bounds.insetBy(dx: 14, dy: 14).size
            let fit = min(room.width / pageSize.width, room.height / pageSize.height)
            let size = CGSize(width: (pageSize.width * fit).rounded(), height: (pageSize.height * fit).rounded())
            if pageView.frame.size != size {
                pageView.frame = CGRect(origin: .zero, size: size)
                pageView.layer.setNeedsDisplay()
            }
            contentSize = size
            setZoomScale(zoom, animated: false)
        }
        centre()
    }

    /// Keeps the page in the middle while it is smaller than the view.
    private func centre() {
        let size = pageView.frame.size
        let x = max((bounds.width - size.width) / 2, 0)
        let y = max((bounds.height - size.height) / 2, 0)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != inset { contentInset = inset }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        zoomed?(Double(scale))
    }
}

/// The page itself: a view backed by `PageTiledLayer`, which draws the PDF page tile by tile.
private final class TiledPageView: UIView {
    override class var layerClass: AnyClass { PageTiledLayer.self }
    private var tiled: PageTiledLayer { layer as! PageTiledLayer }
    private var firstTile: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        tiled.tellFirstTile = { [weak self] in
            Task { @MainActor in self?.firstTile?() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ page: CGPDFPage?, dark: Bool) {
        tiled.show(page, dark: dark)
    }

    func setDark(_ dark: Bool) { tiled.setDark(dark) }

    func setFirstTile(_ firstTile: (() -> Void)?) { self.firstTile = firstTile }
}

/// A tiled layer that draws a PDF page on Core Animation's own threads, tile by tile as they come into view, at the
/// detail the zoom needs, with no fade: white paper and black ink, and in dark mode the two turned over, as a row's
/// thumbnail is. It tells `tellFirstTile` once the first tile of a page is drawn.
private final class PageTiledLayer: CATiledLayer, @unchecked Sendable {
    private let lock = NSLock()
    private var page: CGPDFPage?
    private var dark = false
    private var told = false
    /// Set once, before any tile is drawn.
    var tellFirstTile: (@Sendable () -> Void)?

    override class func fadeDuration() -> CFTimeInterval { 0 }

    override init() {
        super.init()
        tileSize = CGSize(width: 512, height: 512)
        levelsOfDetail = 4
        levelsOfDetailBias = 3
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? PageTiledLayer {
            let (page, dark) = other.lock.withLock { (other.page, other.dark) }
            self.page = page
            self.dark = dark
            told = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ page: CGPDFPage?, dark: Bool) {
        lock.withLock {
            self.page = page
            self.dark = dark
            told = false
        }
        contents = nil
        setNeedsDisplay()
    }

    func setDark(_ dark: Bool) {
        let changed: Bool = lock.withLock {
            defer { self.dark = dark }
            return self.dark != dark
        }
        if changed { setNeedsDisplay() }
    }

    override func draw(in context: CGContext) {
        let (page, dark) = lock.withLock { (self.page, self.dark) }
        let size = bounds.size
        let clip = context.boundingBoxOfClipPath
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(clip)
        guard let page, size.width > 0 else { return }
        let viewed = DrawingPDFDocument.viewedSize(of: page)
        let scale = size.width / viewed.width
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: scale, y: -scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: viewed), rotate: 0,
                                                     preserveAspectRatio: true))
        context.clip(to: page.getBoxRect(.cropBox))
        context.drawPDFPage(page)
        context.restoreGState()
        if dark {
            context.setBlendMode(.difference)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(clip)
        }
        let first: Bool = lock.withLock {
            guard !told, self.page === page else { return false }
            told = true
            return true
        }
        if first { tellFirstTile?() }
    }
}

/// Turns a picture over in dark mode, as placed sheets are.
struct DarkInvert: ViewModifier {
    let dark: Bool
    func body(content: Content) -> some View {
        if dark { content.colorInvert() } else { content }
    }
}
