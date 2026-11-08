import CoreGraphics
import Foundation
import Observation
import VellumCore

/// The drawing viewer (#69, prototype/drawing-search variant B): one drawing from the Drawings tab's search, its PDF's
/// pages and zoom, with Place on a canvas and Open in a new canvas. Just looking makes no canvas.
///
/// The PDF comes from `SheetPDFs`, the same download Add sheet and placing use, so a PDF opened once is on the Duo for
/// good (until the system clears Caches) and opens offline with no download. Downloading, opening the PDF and drawing
/// its pages all run off the main thread; the main thread only takes the answers. A page is drawn in tiles as they come
/// into view (`DrawingPageView`), so a large set opens on its first page without drawing the rest.
@MainActor
@Observable
final class DrawingViewerModel {
    enum State: Equatable {
        /// Downloading the PDF from Dropbox, with how much has come when Dropbox says.
        case downloading(fraction: Double?)
        /// Opening the PDF on the Duo.
        case opening
        /// Open, with its page count.
        case ready(pages: Int)
        /// A DWG with no plot: nothing to show until the laptop plots it (#70).
        case noPDFYet
        /// Something went wrong, in plain words.
        case failed(String)
    }

    /// The zoom steps, as the prototype has them: fit, then 150% up to 600%.
    static let zooms: [Double] = [1, 1.5, 2, 3, 4, 6]

    let entry: DrawingEntry
    let pdf: DrawingOpening.PDF?
    private(set) var state: State
    /// The page shown, counting from 0.
    var page = 0 {
        didSet { if page != oldValue { zoom = 1 } }
    }
    /// The zoom, 1 for the page fitted to the view.
    var zoom: Double = 1
    /// The PDF on the Duo, once it is.
    private(set) var kept: KeptPDF?
    /// The open PDF, for the page view.
    @ObservationIgnored private(set) var document: DrawingPDFDocument?
    /// Reads pages' text and draws thumbnails off the main thread, as Add sheet does.
    @ObservationIgnored private(set) var reader: SheetPDFReader?
    /// From the tap to the first page's first tile drawn, in milliseconds (docs/perf/baselines/sheets.json).
    private(set) var firstPageMilliseconds: Double?
    /// Whether a download was needed to open it.
    private(set) var downloaded = false
    @ObservationIgnored private let tapped = ContinuousClock.now

    init(entry: DrawingEntry) {
        self.entry = entry
        pdf = DrawingOpening.pdf(for: entry)
        state = pdf == nil ? .noPDFYet : .opening
    }

    var pageCount: Int {
        if case .ready(let pages) = state { return pages }
        return pdf?.pages ?? 1
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// Opens the PDF: from the Duo when it is kept there, else downloaded once through `session`.
    func open(session: DropboxSession?) async {
        guard let pdf else { return }
        guard let pdfs = SheetPDFs.app else {
            state = .failed("Vellum couldn't find its folder for PDFs on this Duo.")
            return
        }
        let held = await Task.detached(priority: .userInitiated) {
            pdf.keptName.map { pdfs.holds(keptName: $0, size: pdf.size) } ?? false
        }.value
        if !held { state = .downloading(fraction: nil) }
        downloaded = !held
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.downloadProgressed(fraction) }
        }
        do {
            let kept = try await pdfs.pdf(at: pdf.path, contentHash: pdf.contentHash, size: pdf.size) {
                guard let session else { throw DropboxError.notSetUp }
                let reply = try await session.downloadPDF(path: pdf.path, progress: progress)
                guard let reply else { throw DrawingViewerProblem.goneFromDropbox }
                return reply
            }
            self.kept = kept
            state = .opening
            let url = kept.url
            let document = await Task.detached(priority: .userInitiated) { DrawingPDFDocument(url: url) }.value
            guard let document, document.pageCount > 0 else {
                state = .failed("Vellum couldn't read \(pdf.name) as a PDF.")
                return
            }
            self.document = document
            reader = SheetPDFReader(url: url)
            page = min(page, document.pageCount - 1)
            state = .ready(pages: document.pageCount)
        } catch DrawingViewerProblem.goneFromDropbox {
            state = .failed("\(pdf.name) isn't in Dropbox at \(pdf.path) any more. The laptop updates the index when it next sees the change.")
        } catch let error as DropboxError {
            state = .failed(error == .offline ? DrawingOpening.notOnThisDuoText(number: entry.number) : error.message)
        } catch {
            state = .failed("The PDF couldn't be kept on this Duo. \(error.localizedDescription)")
        }
    }

    private func downloadProgressed(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(fraction: fraction)
    }

    /// The page view drew the first tile of the first page shown.
    func firstPageDrawn() {
        guard firstPageMilliseconds == nil else { return }
        let elapsed = ContinuousClock.now - tapped
        firstPageMilliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
    }

    func zoomIn() { zoom = Self.zooms.first { $0 > zoom + 0.001 } ?? Self.zooms.last! }
    func zoomOut() { zoom = Self.zooms.last { $0 < zoom - 0.001 } ?? 1 }

    // MARK: Placing

    /// The drawing scale the index gives, or nil when Vellum asks for it first (AS NOTED, unreadable).
    var indexScale: Sheet.Scale? { DrawingOpening.scale(indexText: entry.scale) }

    /// What the viewer's foot says about placing it: the scale it opens at and what it covers on a new canvas, or that
    /// Zach picks the scale.
    var placingNote: String {
        if entry.pdf != nil, entry.dwg == nil, indexScale == nil {
            return "PDF only: mark it up; a redline can't go back to a DWG. You pick the scale when you place it."
        }
        let prefix = entry.pdf != nil && entry.dwg == nil ? "PDF only, so a redline can't go back to a DWG. " : ""
        guard let scale = indexScale else {
            return prefix + "\(entry.scale.map { "The title block says \($0)" } ?? "The index has no scale"); you pick the scale when you place it."
        }
        if scale == .notToScale { return prefix + "Opens NTS, at its printed size." }
        guard let inches = entry.pdf?.paperInches, inches.count == 2 else { return prefix + "Opens at \(scale)." }
        let sheet = Sheet(paper: .inches(inches[0], by: inches[1]), scale: scale)
        return prefix + "Opens at \(scale), covering \(CanvasEditor.covers(sheet, units: .default))."
    }
}

private enum DrawingViewerProblem: Error {
    case goneFromDropbox
}

extension SheetPDFs {
    /// The app's one download cache for the drawing viewer, so two opens of one PDF share a download.
    static let app: SheetPDFs? = try? SheetPDFs.inCaches()
}

/// A PDF opened with Core Graphics for the viewer's tiled pages: its pages are drawn from any thread, as the tiles
/// ask (`CGPDFDocument` is immutable once open).
final class DrawingPDFDocument: @unchecked Sendable {
    let document: CGPDFDocument

    init?(url: URL) {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        self.document = document
    }

    var pageCount: Int { document.numberOfPages }

    /// A page, counting from 0.
    func page(_ index: Int) -> CGPDFPage? { document.page(at: index + 1) }

    /// A page's size as it is viewed, turned by its rotation, in points.
    static func viewedSize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let turned = abs(page.rotationAngle) % 180 == 90
        return turned ? CGSize(width: box.height, height: box.width) : box.size
    }
}
