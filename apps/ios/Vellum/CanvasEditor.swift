import Foundation
import Observation
import VellumCore

/// One canvas open on the canvas screen: what is on it, what part of it is on screen, and the tool in hand. Every
/// change to the ink is handed to its `CanvasSaver` as it is made and written on the Duo off the main thread
/// (ADR-0014); the status bar says "Saved on this Duo" once it is.
@MainActor
@Observable
final class CanvasEditor {
    /// The space the drafting rail's chrome takes from the canvas view, for fitting things into what is left: the tool
    /// rail on the left, the top bar, the status bar, and the iOS tab rail on the right.
    static let chromeInsets = ScreenInsets(top: 56, left: 70, bottom: 50, right: 92)

    /// Where a new canvas opens: about 45 feet across the Duo's free width.
    static let startingPointsPerInch = 1.5

    /// The canvas's name, units, sheets and frames. Its ink is not kept here but in `session`, the one owner of the
    /// ink: two values sharing the stroke list would make every change copy the whole canvas.
    var canvas: VellumCore.Canvas
    /// The ink and its undo history. Not observed: SwiftUI's observation would read it out and write it back on every
    /// change, sharing the stroke list for that moment and copying it. Views follow `inkRevision`, `canUndo` and
    /// `canRedo` instead.
    @ObservationIgnored private var session: InkSession
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// Told what each change did to the ink (strokes added, strokes taken away), for anything kept in step with it.
    @ObservationIgnored var inkDidChange: ((InkChange) -> Void)?
    var viewport: Viewport
    /// The tool, markup colour and line weights in hand. A stroke takes them at touchdown (`beginStroke`).
    var pen = PenSettings()
    /// Where the Pencil last touched the canvas. The Duo has no hover, so this is the last touch, not a live cursor.
    var penPosition: CanvasPoint?
    /// Whether every change is written on the Duo. "Saving…" only shows when a write takes long enough to notice.
    private(set) var saveState = SaveState.savedOnThisDuo
    /// Whether the canvas has changed since it was opened: Dropbox gets the changes when Zach leaves it (#12), so the
    /// status bar stops saying "Synced to Dropbox". Set once, by the first change.
    private(set) var hasEdits = false
    /// Changes handed to the saver and not yet written.
    @ObservationIgnored private var savesInFlight = 0
    /// Saves the canvas; nil for a canvas that is only in memory (previews).
    let saver: CanvasSaver?
    /// The canvas's id on the Duo; nil for one only in memory.
    var canvasID: UUID? { saver?.id }
    /// Changes whenever the ink does, for views that show something about it. An eraser sweep changes it once, when
    /// the sweep ends, so no SwiftUI view updates on every hit; the renderer hears at once, through `onInkChange`.
    private(set) var inkRevision = 0
    /// Where every stroke is, kept in step with the ink, for the eraser and the renderer (ADR-0012).
    @ObservationIgnored private(set) var inkIndex: InkIndex
    /// Where each placed sheet's outline is, for snapping to sheets near the tip (#57). Built again only when the sheets
    /// change, never per frame.
    @ObservationIgnored private(set) var sheetIndex: SheetIndex
    /// Told what changed whenever the ink does, so the renderer redraws only that, without waiting on SwiftUI.
    @ObservationIgnored var onInkChange: (@MainActor (InkIndex.Change) -> Void)?
    /// Set once the view has its size and the starting zoom has been applied.
    @ObservationIgnored private var hasPlacedView = false
    private let startingView: StartingView

    /// What the view shows when it first has a size.
    enum StartingView {
        case origin
        case everything
        case region(CanvasRect)
    }

    /// `index`, built off the main thread for a large canvas, must be of the session's ink; nil builds it here.
    init(canvas: VellumCore.Canvas = VellumCore.Canvas(), session: InkSession? = nil, index: InkIndex? = nil,
         saver: CanvasSaver? = nil, startingView: StartingView = .origin) {
        var canvas = canvas
        let session = session ?? InkSession(ink: canvas.ink, sheets: canvas.sheets)
        canvas.ink = Ink()
        // The session owns the sheets (#11); the canvas keeps a copy for measuring and zoom to everything.
        canvas.sheets = session.sheets
        self.canvas = canvas
        self.session = session
        inkIndex = index ?? InkIndex(session.ink)
        sheetIndex = SheetIndex(session.sheets)
        canUndo = session.canUndo
        canRedo = session.canRedo
        frameCount = session.frames.count
        self.saver = saver
        viewport = Viewport(pointsPerInch: Self.startingPointsPerInch, screenWidth: 951, screenHeight: 669)
        self.startingView = startingView
        // Only the test canvas and previews have no saver; the status bar must not say they are saved.
        if saver == nil { saveState = .neverSaved }
    }

    /// The ink, for drawing it. Read it alongside `inkRevision`, which is what changes when it does.
    var ink: Ink { session.ink }
    /// True during an eraser sweep, which bumps `inkRevision` once, when it ends (`endEraserSweep`).
    @ObservationIgnored private var sweeping = false

    /// The rectangle everything on the canvas covers, its ink, text boxes, dimensions and frames included.
    var extents: CanvasRect? {
        CanvasRect.union([canvas.extents, session.ink.bounds].compactMap { $0 } + session.texts.map(\.rect)
            + session.dimensions.map(\.bounds) + session.frames.map(\.bounds))
    }

    /// The canvas units, saved with the canvas's name when they change.
    var units: CanvasUnits {
        get { canvas.units }
        set {
            guard newValue != canvas.units else { return }
            canvas.units = newValue
            saver?.setUnits(newValue)
            if !hasEdits { hasEdits = true }
            inkRevision += 1  // the grid follows the units
        }
    }

    /// The tool in hand. Putting down Select or the lasso for any tool but the other lets go of the selection (#64); any tool change starts the next one afresh.
    /// A sheet waiting to be placed keeps waiting whatever the tool.
    var tool: CanvasTool {
        get { pen.tool }
        set {
            // A bubble's tag being typed goes on as typed before anything else happens (#41).
            finishTag()
            pen.tool = newValue
            if !newValue.selects { select(.empty) }
            toolStep = placingSheet == nil ? .start : .placeSheet
            if showsShapeFlyout { showsShapeFlyout = false }
            if showsSymbolFlyout { showsSymbolFlyout = false }
        }
    }

    /// Where a measure, dimension or window is up to, for the status bar's prompt (#8). The canvas view sets it.
    var toolStep = CanvasTool.Step.start

    /// What the line and shape tool draws, picked from its flyout (#40). Picking another finishes the shape in hand.
    var lineShape = LineShape.default {
        didSet { if lineShape != oldValue { onLineShapeChange?() } }
    }
    /// Whether the flyout beside the rail is open.
    var showsShapeFlyout = false
    @ObservationIgnored var onLineShapeChange: (@MainActor () -> Void)?
    /// Asked first by an undo: true when it took a point back from a shape part way through.
    @ObservationIgnored var undoShapePoint: (@MainActor () -> Bool)?
    /// A shape part way through has points to take back, so Undo is on with nothing else to undo.
    @ObservationIgnored private var draftInProgress = false

    func setDraftInProgress(_ inProgress: Bool) {
        draftInProgress = inProgress
        let can = session.canUndo || inProgress
        if canUndo != can { canUndo = can }
    }

    var colour: MarkupColour {
        get { pen.colour }
        set { pen.colour = newValue }
    }

    var weight: LineWeight {
        get { pen.weight }
        set { pen.weight = newValue }
    }

    /// Called by the ink view whenever its size changes.
    func viewDidResize(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        if viewport.screenWidth != width || viewport.screenHeight != height {
            viewport.screenWidth = width
            viewport.screenHeight = height
        }
        guard !hasPlacedView else { return }
        hasPlacedView = true
        switch startingView {
        case .origin:
            viewport.centre = .origin
        case .everything:
            zoomToEverything()
        case .region(let rect):
            viewport.fit(rect, insets: Self.chromeInsets)
        }
    }

    /// Starts a stroke where the Pencil touched down, with the pen, colour, weight and zoom as they are now; nil when
    /// the tool in hand leaves no ink.
    func beginStroke(at point: CanvasPoint) -> StrokeInProgress? {
        pen.beginStroke(at: point, pointsPerInch: viewport.pointsPerInch)
    }

    /// Tells the saver whether the Pencil is on the glass, so tidying the saved ink waits for it to lift.
    func pencilDidTouch(_ down: Bool) {
        saver?.setPencilDown(down)
    }

    /// Adds a stroke the Pencil has finished to the ink, and returns it.
    @discardableResult
    func commit(_ stroke: StrokeInProgress) -> InkStroke? {
        let committed = session.commit(stroke)
        syncInk()
        return committed
    }

    /// Corrects a shape just drawn through its tag (#40), as its own undo step, written to the ink log like any change.
    func correct(_ id: StrokeID, to points: [CanvasPoint]) {
        session.correct(id, to: points)
        syncInk()
    }

    /// Starts a sweep of the eraser, which undoes as one step.
    func beginEraserSweep() {
        session.beginEraserSweep()
        sweeping = true
    }

    /// Ends a sweep of the eraser and tells the views reading `inkRevision` what it erased, once.
    func endEraserSweep() {
        guard sweeping else { return }
        sweeping = false
        inkRevision += 1
    }

    /// Erases whole strokes under the eraser: within 8 screen points of the Pencil's tip at this zoom.
    func erase(at point: CanvasPoint) {
        session.erase(at: point, tolerance: viewport.canvasLength(ofScreen: 8), index: inkIndex)
        syncInk()
    }

    func undo() {
        if undoShapePoint?() == true { return }
        // The tag typed so far joins its bubble, so the undo takes both (#41).
        finishTag()
        willChangeHistory?()
        endEraserSweep()
        cancelLift()
        dropSheet(to: nil, motion: nil)
        session.undo()
        syncInk()
    }

    func redo() {
        finishTag()
        willChangeHistory?()
        endEraserSweep()
        cancelLift()
        dropSheet(to: nil, motion: nil)
        session.redo()
        syncInk()
    }

    /// Told just before an undo or redo, so a text box being typed in is finished first and its edit is the step
    /// undone.
    @ObservationIgnored var willChangeHistory: (@MainActor () -> Void)?
    /// Told to finish typing in a text box: when the canvas closes or the app leaves the screen.
    @ObservationIgnored var onFinishTextEditing: (@MainActor () -> Void)?

    /// Finishes a text box being typed in, saving its text.
    func finishTextEditing() { onFinishTextEditing?() }

    // MARK: The selection (#7)

    /// What the lasso has selected: not saved, and kept through undo and redo. The status bar's prompt follows it;
    /// the canvas view hears through `onSelectionChange`.
    private(set) var selection = CanvasSelection.empty
    @ObservationIgnored var onSelectionChange: (@MainActor () -> Void)?
    /// Told what each change did to the text boxes, so the canvas view shows them.
    @ObservationIgnored var onTextsChange: (@MainActor (InkChange) -> Void)?
    /// The selection's strokes while they are lifted out of the index to be dragged, and their bounds then.
    @ObservationIgnored private var lifted: [InkStroke]?
    @ObservationIgnored private var liftedBounds: CanvasRect?

    /// The text boxes on the canvas, in the order placed.
    var texts: [TextBox] { session.texts }
    func text(_ id: TextBoxID) -> TextBox? { session.text(id) }

    func select(_ new: CanvasSelection) {
        guard new != selection else { return }
        selection = new
        onSelectionChange?()
    }

    /// Selects what a lasso loop takes (`Lasso`): looked up in the index, never the whole canvas.
    func selectInLoop(_ points: [CanvasPoint]) {
        guard let lasso = Lasso(points) else { return select(.empty) }
        select(lasso.select(in: inkIndex, texts: session.texts, dimensions: session.dimensions,
                            frames: session.frames))
    }

    /// What a tap with Select at a canvas point picks up (`SelectTap`, #64): looked up in the ink and sheet indexes at
    /// this zoom, never the whole canvas. Once a tap, never per Pencil sample.
    func selectPick(at point: CanvasPoint) -> SelectTap.Pick? {
        var work = InkIndex.Work()
        return SelectTap.pick(at: point, pointsPerInch: viewport.pointsPerInch, ink: inkIndex, texts: session.texts,
                              dimensions: session.dimensions, frames: session.frames, sheets: sheetIndex, work: &work)
    }

    /// The rectangle the selection covers, from the index's cached bounds and the text boxes; nil with nothing
    /// selected.
    var selectionBounds: CanvasRect? {
        if let liftedBounds { return liftedBounds }
        var rects: [CanvasRect] = []
        if let box = inkIndex.bounds(of: selection.strokes) { rects.append(box.rect) }
        for id in selection.texts { if let box = session.text(id) { rects.append(box.rect) } }
        for id in selection.dimensions { if let dimension = session.dimension(id) { rects.append(dimension.bounds) } }
        for id in selection.frames { if let frame = session.frame(id) { rects.append(frame.bounds) } }
        return CanvasRect.union(rects)
    }

    /// Takes the selection's strokes out of the index, so the tiles redraw without them, and returns them to be
    /// dragged on a layer of their own. `dropSelection` puts them back, moved or not.
    func liftSelection() -> [InkStroke] {
        cancelLift()
        let bounds = selectionBounds
        let strokes = selection.strokes.compactMap { inkIndex.stroke($0) }
        liftedBounds = bounds
        lifted = strokes
        if !strokes.isEmpty { onInkChange?(inkIndex.apply(InkChange(removed: strokes.map(\.id)))) }
        return strokes
    }

    /// Ends a drag: the selection moved or resized by `transform` as one undo step, saved as its ids and the
    /// transform; an identity transform puts the strokes back as they were.
    func dropSelection(_ transform: CanvasTransform) {
        guard let strokes = lifted else { return }
        lifted = nil
        liftedBounds = nil
        if !transform.isIdentity, session.transform(selection, by: transform) {
            syncInk()
        } else if !strokes.isEmpty {
            onInkChange?(inkIndex.apply(InkChange(added: strokes)))
        }
    }

    private func cancelLift() { dropSelection(.identity) }

    /// Duplicates the selection, the copies 30 points down and right at this zoom, and selects the copies.
    func duplicateSelection() {
        let offset = viewport.canvasLength(ofScreen: 30)
        session.duplicate(selection, by: .translation(dx: offset, dy: offset))
        syncInk()
    }

    func deleteSelection() {
        session.delete(selection)
        syncInk()
    }

    /// Scales the selection by a factor about its centre, as one undo step (#41): any selection, symbols or not.
    func scaleSelection(by factor: Double) {
        guard factor > 0, factor.isFinite, factor != 1, let box = selectionBounds else { return }
        cancelLift()
        session.transform(selection, by: .scaling(by: factor, about: box.center))
        syncInk()
    }

    // MARK: Symbols (#41)

    /// The symbol a tap with Symbols places, picked from its flyout. It starts on the gate valve.
    var symbolID = Symbol.starters[0].id {
        didSet { if symbolID != oldValue { finishTag() } }
    }
    /// Whether the symbol library's flyout is open beside the rail.
    var showsSymbolFlyout = false
    /// What the last symbol placed said about its size: `3/8" printed · 1'-6" in M-201`.
    private(set) var lastSymbolLabel: String?

    /// A bubble just placed, waiting for its tag: where the tag goes, the letters and number typed so far, and where
    /// the bubble is, so the pop-up and the keyboard stay off it.
    struct PendingTag: Equatable {
        var slot: PlacedSymbol.Tag
        var letters: String
        var number: String
        var bubble: CanvasRect
    }
    /// The tag being typed as a bubble lands; nil when none is.
    var pendingTag: PendingTag?

    /// The symbol picked, from the library every canvas shares.
    var symbol: Symbol? { SymbolShelf.shared.symbol(symbolID) ?? Symbol.starters.first }

    /// The scale a symbol lands at, at a canvas point (`SymbolScale`).
    func symbolScale(at point: CanvasPoint) -> SymbolScale {
        SymbolScale.at(point, sheets: session.sheets, frames: session.frames)
    }

    /// Places the symbol picked centred on a canvas point, upright, at its printed size at the scale there, as one undo
    /// step: plain strokes in the pen's colour and weight, and text boxes for its letters, saved like any drawn stroke
    /// before anything else. A symbol with a tag slot then waits for its tag. Once a tap, never per Pencil sample.
    @discardableResult
    func placeSymbol(at point: CanvasPoint) -> PlacedSymbol? {
        finishTag()
        guard let symbol else { return nil }
        let scale = symbolScale(at: point)
        let lineWidth = Length.inches(pen.weight(for: .pen).screenWidth(for: .pen) / viewport.pointsPerInch)
        let placed = symbol.placed(at: point, size: scale.canvasSize(of: symbol.printedSize), lineWidth: lineWidth)
        let selection = session.place(strokes: placed.strokes, texts: placed.texts, colour: pen.colour)
        guard !selection.isEmpty else { return nil }
        syncInk()
        lastSymbolLabel = scale.label(for: symbol.printedSize, units: canvas.units)
        if let slot = placed.tag {
            let letters = slot.letters
            pendingTag = PendingTag(slot: slot, letters: letters,
                                    number: String(SymbolTag.next(letters: letters, in: session.texts)),
                                    bubble: placed.bounds)
            toolStep = .drawing(CanvasTool.tagPrompt)
        } else {
            // The size it landed at stays in the status bar until the next thing happens; 28 characters at most.
            let short = scale.shortLabel(for: symbol.printedSize, units: canvas.units)
            toolStep = .hint(short.count <= 28 ? short : SymbolScale.printedText(symbol.printedSize) + " printed")
        }
        return placed
    }

    /// Puts the tag typed on its bubble, as part of the bubble's undo step, and closes the pop-up. Empty letters and
    /// number put no tag. Nothing waiting, nothing happens.
    func finishTag() {
        guard let pending = pendingTag else { return }
        pendingTag = nil
        if case .drawing(CanvasTool.tagPrompt) = toolStep { toolStep = .start }
        guard let text = pending.slot.text(letters: pending.letters.uppercased(), number: pending.number) else { return }
        session.place(strokes: [], texts: [text], colour: pen.colour, joiningLast: true)
        syncInk()
    }

    /// Leaves the bubble with no tag.
    func skipTag() {
        guard pendingTag != nil else { return }
        pendingTag = nil
        if case .drawing(CanvasTool.tagPrompt) = toolStep { toolStep = .start }
    }

    /// What Save as symbol starts from: the selection's ink as a drawing, and the printed size it measures at the scale
    /// under its middle. Nil with no ink or text selected.
    struct SymbolDraft {
        var drawing: SymbolDrawing
        var printed: PrintedLength
        var place: String
    }

    /// Save as symbol's draft while its name and size are asked for; nil otherwise.
    var savingSymbol: SymbolDraft?

    /// Opens Save as symbol for the selection, from the selection's menu.
    func beginSavingSymbol() {
        savingSymbol = symbolDraft()
    }

    func symbolDraft() -> SymbolDraft? {
        let strokes = selection.strokes.compactMap { inkIndex.stroke($0) }
        let texts = selection.texts.compactMap { session.text($0) }
        guard selection.sheet == nil, let drawing = SymbolDrawing.of(strokes: strokes, texts: texts) else { return nil }
        let scale = symbolScale(at: drawing.centre)
        return SymbolDraft(drawing: drawing, printed: scale.printed(of: drawing.unit),
                           place: scale.place ?? "off a sheet, at \(scale.reading)")
    }

    /// Saves a drafted symbol to the library, where every canvas has it, and picks it. The ink selected stays as it is.
    func saveSymbol(_ draft: SymbolDraft, name: String, printed: PrintedLength) {
        let symbol = Symbol(id: UUID().uuidString.lowercased(), name: name, printedSize: printed,
                            tagLetters: draft.drawing.tagLetters, parts: draft.drawing.parts)
        SymbolShelf.shared.save(symbol)
        symbolID = symbol.id
    }

    // MARK: Text boxes (#7)

    /// Places a text box with its text, in the markup colour in hand. Empty text places nothing.
    @discardableResult
    func addText(_ text: String, at origin: CanvasPoint, width: Length, height: Length, fontSize: Length) -> TextBox? {
        let box = session.addText(text, at: origin, size: CanvasSize(width: width, height: height), fontSize: fontSize,
                                  colour: pen.colour)
        syncInk()
        return box
    }

    /// Changes a text box's text and height; emptied, it is deleted.
    func editText(_ id: TextBoxID, text: String, height: Length) {
        session.editText(id, text: text, height: height)
        syncInk()
    }

    // MARK: Sheets (#11)

    /// A sheet confirmed in Add sheet, waiting for a tap where it goes: the sheet (its origin still to come), the PDF
    /// it shows, downloaded, and the name it is kept under in the canvas folder.
    struct PendingSheet {
        var sheet: Sheet
        var pdf: URL
        var keptName: String
    }

    /// The sheets on the canvas, in the order placed, the last on top.
    var sheets: [Sheet] { session.sheets }
    func sheet(_ id: SheetID) -> Sheet? { session.sheet(id) }
    /// The sheet waiting to be placed, while it waits (#11).
    private(set) var placingSheet: PendingSheet?
    /// Told when a sheet starts or stops waiting to be placed.
    @ObservationIgnored var onPlacingChange: (@MainActor () -> Void)?
    /// Told what each change did to the sheets, so the canvas view draws them.
    @ObservationIgnored var onSheetsChange: (@MainActor (InkChange) -> Void)?
    /// What went wrong placing a sheet, in plain words, until it is read.
    var sheetProblem: String?
    /// PDFs of sheets on a canvas with no saver (previews, the test canvas, the benchmark), by kept name.
    @ObservationIgnored private var unsavedPDFs: [String: URL] = [:]

    /// Where a sheet's PDF is on the Duo: in the canvas folder, or for a canvas with no saver, where it was put.
    func pdfURL(for sheet: Sheet) -> URL? {
        guard let name = sheet.page?.file else { return nil }
        if let saver { return saver.sheetPDF(named: name) }
        return unsavedPDFs[name]
    }

    /// What a sheet covers on the canvas, for the confirm step and the outline: `144'-0" × 96'-0"` in the canvas
    /// units, or for an NTS sheet its paper at printed size.
    func covers(_ sheet: Sheet) -> String {
        if sheet.isNotToScale { return "\(sheet.paper.name) at printed size" }
        let size = sheet.size
        return "\(canvas.units.format(size.width)) × \(canvas.units.format(size.height))"
    }

    /// Starts placing a confirmed sheet: the view zooms out to show where it could go beside everything else, and a
    /// true-size outline waits, centred in the view, for a tap (#11, "tap to place").
    func beginPlacing(_ pending: PendingSheet) {
        select(.empty)
        placingSheet = pending
        toolStep = .placeSheet
        let size = pending.sheet.size
        let centre = viewport.centre
        let room = CanvasRect(origin: CanvasPoint(x: centre.x - size.width * 0.8, y: centre.y - size.height * 0.8),
                              size: CanvasSize(width: size.width * 1.6, height: size.height * 1.6))
        viewport.fit(CanvasRect.union([room] + [extents].compactMap { $0 }) ?? room, insets: Self.chromeInsets,
                     fill: 0.92)
        onPlacingChange?()
    }

    /// The sheet waiting to be placed, centred on a canvas point, as it would go there.
    func sheetToPlace(centredAt point: CanvasPoint) -> Sheet? {
        guard var sheet = placingSheet?.sheet else { return nil }
        let size = sheet.size
        sheet.origin = CanvasPoint(x: point.x - size.width / 2, y: point.y - size.height / 2).onInkGrid
        return sheet
    }

    /// Places the waiting sheet centred on a canvas point, as one undo step. Its PDF is kept in the canvas folder,
    /// flushed to storage, before the sheet is placed (`CanvasSaver.keepSheetPDF`), so a placed sheet never names a
    /// PDF the Duo could lose. When the PDF can't be kept, nothing is placed and the sheet waits for another tap.
    func placeSheet(centredAt point: CanvasPoint) async -> Sheet? {
        guard let pending = placingSheet, let sheet = sheetToPlace(centredAt: point) else { return nil }
        if let saver {
            do {
                try await saver.keepSheetPDF(from: pending.pdf, named: pending.keptName)
            } catch {
                sheetProblem = "The PDF couldn't be kept on this Duo, so the sheet wasn't placed. "
                    + ((error as? any StorageFailure)?.isOutOfSpace == true ? "This Duo is full." : "Try again.")
                return nil
            }
        } else {
            unsavedPDFs[pending.keptName] = pending.pdf
        }
        // The tap may have been cancelled while the PDF was being kept.
        guard placingSheet != nil else { return nil }
        placingSheet = nil
        toolStep = .start
        onPlacingChange?()
        let placed = session.addSheet(sheet)
        syncInk()
        return placed
    }

    /// Stops placing the waiting sheet; nothing is placed.
    func cancelPlacing() {
        guard placingSheet != nil else { return }
        placingSheet = nil
        if toolStep == .placeSheet { toolStep = .start }
        onPlacingChange?()
    }

    // MARK: Turning, moving and changing the scale of a sheet (#44)

    /// The sheet the lasso has picked up, while it has.
    var selectedSheet: Sheet? { selection.sheet.flatMap { session.sheet($0) } }

    /// The topmost sheet under a canvas point.
    func sheet(at point: CanvasPoint) -> Sheet? { session.sheets.last { $0.contains(point) } }

    /// What a turn, move or scale change under way started from: the sheet, and the markups chosen then to come along,
    /// their strokes out of the index until it ends.
    struct SheetLift {
        let sheet: Sheet
        let markups: CanvasSelection
        let strokes: [InkStroke]
    }

    @ObservationIgnored private var sheetLift: SheetLift?

    /// Starts a turn, move or scale change of the selected sheet: chooses what comes along (more than half its length on
    /// the sheet, through the index), and takes those strokes out of the index, so the tiles redraw without them.
    func liftSheet() -> SheetLift? {
        cancelLift()
        dropSheet(to: nil, motion: nil)
        guard let sheet = selectedSheet else { return nil }
        let markups = sheet.markups(in: inkIndex, texts: session.texts, dimensions: session.dimensions)
        let strokes = markups.strokes.compactMap { inkIndex.stroke($0) }
        let lift = SheetLift(sheet: sheet, markups: markups, strokes: strokes)
        sheetLift = lift
        if !strokes.isEmpty { onInkChange?(inkIndex.apply(InkChange(removed: strokes.map(\.id)))) }
        return lift
    }

    /// Ends a turn, move or scale change: the sheet where it went and its markups moved by `motion`, as one undo step
    /// saved as ids and the motion. Nil, or nothing changed, puts the strokes back as they were.
    func dropSheet(to after: Sheet?, motion: SheetMotion?) {
        guard let lift = sheetLift else { return }
        sheetLift = nil
        if let after, let motion, session.changeSheet(to: after, markups: lift.markups, motion: motion) {
            syncInk()
        } else if !lift.strokes.isEmpty {
            onInkChange?(inkIndex.apply(InkChange(added: lift.strokes)))
        }
    }

    /// The scales the selected sheet can change to, as Add sheet's confirm step offers them, its details' first. Reads the
    /// page off the main thread.
    func scalesOffered(for sheet: Sheet) async -> [Sheet.Scale] {
        let reading = await reading(of: sheet)
        return SheetReading.offeredScales(details: reading?.detailScales ?? [], units: canvas.units)
    }

    /// The selected sheet at another drawing scale, with the size it gives it: its markups scale with it about its centre,
    /// as one undo step. Its page is read again, so a detail now at another scale than the sheet's becomes a scale area
    /// (ADR-0002); a page that can't be read keeps the areas it has.
    func changeSelectedSheetScale(to scale: Sheet.Scale) async -> (sheet: Sheet, motion: SheetMotion)? {
        guard let sheet = selectedSheet, scale != sheet.scale else { return nil }
        let reading = await reading(of: sheet)
        guard let current = selectedSheet, current.id == sheet.id else { return nil }
        return current.rescaled(to: scale, areas: reading?.areas(placedAt: scale))
    }

    private func reading(of sheet: Sheet) async -> SheetReading? {
        guard let url = pdfURL(for: sheet), let index = sheet.page?.index else { return nil }
        return await SheetPDFReader(url: url).info(page: index)?.reading
    }

    // MARK: Measures, dimensions, frames and windows (#8)

    /// The dimensions on the canvas, in the order placed.
    var dimensions: [CanvasDimension] { session.dimensions }
    /// The frames on the canvas, in the order placed.
    var frames: [Frame] { session.frames }
    func dimension(_ id: DimensionID) -> CanvasDimension? { session.dimension(id) }
    func frame(_ id: FrameID) -> Frame? { session.frame(id) }
    /// How many frames the canvas holds, for the status bar.
    private(set) var frameCount = 0
    /// Told what each change did to the dimensions and frames, so the canvas view shows them.
    @ObservationIgnored var onAnnotationsChange: (@MainActor (InkChange) -> Void)?
    /// The paper a new frame is drawn on, chosen beside the top bar while the frame tool is in hand.
    var framePaper = PaperSize.defaultFrame

    /// Where a tap at a canvas point lands: the nearest snap point within 20 screen points, found through the index, else
    /// the nearest point on a placed sheet's edge (#57), or the point itself. `anchor` is the point being worked from, which
    /// perpendicular and tangent need (#40).
    func snapTarget(at point: CanvasPoint, anchor: CanvasPoint? = nil) -> PointSnap.Target {
        PointSnap.target(at: point, pointsPerInch: viewport.pointsPerInch, in: inkIndex, sheets: sheetIndex, anchor: anchor)
    }

    /// A length between two points as the canvas shows it: in its units, or printed inches marked NTS on an NTS sheet.
    func measureText(from start: CanvasPoint, to end: CanvasPoint) -> String {
        canvas.format(canvas.measure(from: start, to: end))
    }

    /// What a dimension reads, in the canvas units.
    func label(for dimension: CanvasDimension) -> String { canvas.format(canvas.measure(dimension)) }

    /// Places a dimension pulled off two points by a third, in the markup colour in hand, its text the dimension
    /// text height at this zoom. Nil when the two points are the same.
    @discardableResult
    func addDimension(start: CanvasPoint, end: CanvasPoint, through: CanvasPoint) -> CanvasDimension? {
        let dimension = session.addDimension(start: start, end: end, through: through, colour: pen.colour,
                                             textHeight: viewport.canvasLength(ofScreen: CanvasDimension.screenTextHeight))
        syncInk()
        return dimension
    }

    /// The frame a dragged rectangle makes on the paper in hand (`Frame.fitting`), not yet placed.
    func frame(fitting rect: CanvasRect) -> Frame {
        Frame.fitting(rect, paper: framePaper, units: canvas.units)
    }

    /// Places the frame a dragged rectangle makes, as one undo step.
    @discardableResult
    func addFrame(fitting rect: CanvasRect) -> Frame {
        let fitted = frame(fitting: rect)
        let frame = session.addFrame(paper: fitted.paper, scale: fitted.scale, origin: fitted.origin)
        syncInk()
        return frame
    }

    /// Fits a window into the part of the canvas the chrome leaves free.
    func zoom(to rect: CanvasRect) {
        viewport.fit(rect, insets: Self.chromeInsets, fill: 0.95)
    }

    func zoomToEverything() {
        if let extents {
            viewport.fit(extents, insets: Self.chromeInsets)
        } else {
            viewport = Viewport(pointsPerInch: Self.startingPointsPerInch, screenWidth: viewport.screenWidth,
                                screenHeight: viewport.screenHeight)
        }
    }

    #if DEBUG
    /// A stroke shown as if the Pencil were still drawing it, never committed: for the kill-and-reopen captures.
    private(set) var debugOpenStroke: StrokeInProgress?

    func showDebugOpenStroke(_ stroke: StrokeInProgress) {
        debugOpenStroke = stroke
        onDebugOpenStroke?(stroke)
    }

    /// Set by the ink view, which shows the open stroke in its live layers.
    @ObservationIgnored var onDebugOpenStroke: ((StrokeInProgress) -> Void)?
    #endif

    /// Follows the change the session just made: the index and the renderer take its delta (strokes added, ids
    /// taken away) without reading the rest of the ink, and the change goes to the saver.
    private func syncInk() {
        // Nothing to follow when the change did nothing (an empty stroke, undo with nothing to undo).
        guard !session.unsavedEvents.isEmpty else { return }
        let change = session.lastChange
        // First, so a dimension drawn again below reads against the sheets as they now stand (#44).
        if change.touchesSheets {
            canvas.sheets = session.sheets
            sheetIndex = SheetIndex(session.sheets)
        }
        inkDidChange?(change)
        onInkChange?(inkIndex.apply(change))
        if change.touchesText { onTextsChange?(change) }
        if change.touchesAnnotations {
            onAnnotationsChange?(change)
            if frameCount != session.frames.count { frameCount = session.frames.count }
        }
        if change.touchesSheets { onSheetsChange?(change) }
        if let after = session.selectionAfterLastChange {
            // A sheet is picked up only with Select or the lasso in hand, so undoing its turn with the pen selects nothing.
            if after.sheet == nil || tool.selects { select(after) }
        } else if !selection.isEmpty, !change.removed.isEmpty || !change.removedTexts.isEmpty
                    || !change.removedDimensions.isEmpty || !change.removedFrames.isEmpty
                    || !change.removedSheets.isEmpty {
            // Whatever a change took away is no longer selected.
            select(CanvasSelection(strokes: selection.strokes.filter { inkIndex.contains($0) },
                                   texts: selection.texts.filter { session.text($0) != nil },
                                   dimensions: selection.dimensions.filter { session.dimension($0) != nil },
                                   frames: selection.frames.filter { session.frame($0) != nil },
                                   sheet: selection.sheet.flatMap { session.sheet($0)?.id }))
        }
        if !sweeping { inkRevision += 1 }
        let can = session.canUndo || draftInProgress
        if canUndo != can { canUndo = can }
        if canRedo != session.canRedo { canRedo = session.canRedo }
        save()
    }

    /// Hands the changes just made to the saver: a queue hand-off, so the Pencil never waits on storage.
    private func save() {
        let events = session.takeEvents()
        guard !events.isEmpty, let saver else { return }
        if !hasEdits { hasEdits = true }
        savesInFlight += 1
        saver.save(events) { [weak self] state in
            Task { @MainActor in self?.didSave(state) }
        }
        // Only say "Saving…" if the write is still going after a moment; most take well under a millisecond.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.savesInFlight > 0, self.saveState == .savedOnThisDuo else { return }
            self.saveState = .saving
        }
    }

    /// The saver's state changed on its own: a failed write or flush retried and written, or failing again.
    func saveStateDidChange(_ state: SaveState) {
        if !state.isSaved {
            saveState = state
        } else if savesInFlight == 0 {
            saveState = .savedOnThisDuo
        }
    }

    private func didSave(_ state: SaveState) {
        savesInFlight = max(0, savesInFlight - 1)
        if !state.isSaved {
            saveState = state
        } else if savesInFlight == 0 {
            saveState = .savedOnThisDuo
        }
    }
}
