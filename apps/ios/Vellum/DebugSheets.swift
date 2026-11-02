#if DEBUG || BENCHMARK
import UIKit
import VellumCore

/// The made-up PDFs of `MadeUpSheets`, drawn with `UIGraphicsPDFRenderer` (#11), for the simulator captures and the
/// benchmark. Nothing here is anyone's drawing: the title blocks, numbers and lines are invented. Each file is drawn
/// once and kept in memory, so its size is the same in the made-up Dropbox's listing and its download.
enum MadeUpPDF {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [Int: Data] = [:]

    /// The PDF of `MadeUpSheets.files[index]`.
    static func data(_ index: Int) -> Data {
        if let known = lock.withLock({ made[index] }) { return known }
        let data = draw(MadeUpSheets.files[index])
        lock.withLock { made[index] = data }
        return data
    }

    /// The made-up file as the made-up Dropbox lists it.
    static func dropboxFile(_ index: Int) -> DropboxFile {
        let file = MadeUpSheets.files[index]
        return DropboxFile(id: "id:madeup\(index)", name: file.name, path: MadeUpSheets.folder + "/" + file.name,
                           size: data(index).count, contentHash: file.contentHash, rev: "madeup\(index)")
    }

    private static func draw(_ file: MadeUpSheets.File) -> Data {
        let first = file.pages[0].paper
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: first.width.inches * 72,
                                                            height: first.height.inches * 72))
        return renderer.pdfData { context in
            for page in file.pages {
                let bounds = CGRect(x: 0, y: 0, width: page.paper.width.inches * 72, height: page.paper.height.inches * 72)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                if page.isScan {
                    drawScan(page, in: bounds)
                } else {
                    drawPage(page, in: context.cgContext)
                }
            }
        }
    }

    private static func pt(_ p: PaperPoint) -> CGPoint { CGPoint(x: p.x.inches * 72, y: p.y.inches * 72) }

    private static func drawPage(_ page: MadeUpSheets.Page, in context: CGContext) {
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineCap(.round)
        // The border and the title block's box.
        context.setLineWidth(2)
        context.stroke(CGRect(x: 36, y: 36, width: page.paper.width.inches * 72 - 72,
                              height: page.paper.height.inches * 72 - 72))
        let box = MadeUpSheets.titleBlockBox(page.paper)
        context.stroke(CGRect(x: box.minX * 72, y: box.minY * 72, width: box.width.inches * 72,
                              height: box.height.inches * 72))
        context.setLineWidth(1.2)
        for segment in page.drawing {
            context.setStrokeColor(segment.coloured ? UIColor.systemBlue.cgColor : UIColor.black.cgColor)
            context.move(to: pt(segment.from))
            context.addLine(to: pt(segment.to))
            context.strokePath()
        }
        // Each printed dimension: its line with a tick at each end and short extension lines.
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(0.8)
        for dimension in page.dimensions {
            let a = pt(dimension.from), b = pt(dimension.to)
            context.move(to: a)
            context.addLine(to: b)
            for end in [a, b] {
                context.move(to: CGPoint(x: end.x - 4, y: end.y + 4))
                context.addLine(to: CGPoint(x: end.x + 4, y: end.y - 4))
                context.move(to: CGPoint(x: end.x, y: end.y - 8))
                context.addLine(to: CGPoint(x: end.x, y: end.y + 14))
            }
            context.strokePath()
        }
        for text in page.texts {
            let size = text.rect.height.inches * 72
            let font = UIFont(name: "Helvetica", size: size) ?? UIFont.systemFont(ofSize: size)
            (text.text as NSString).draw(at: CGPoint(x: text.rect.minX * 72, y: text.rect.minY * 72),
                                         withAttributes: [.font: font, .foregroundColor: UIColor.black])
        }
    }

    /// A scan: one picture of yellowed paper with soft grey lines, and no text.
    private static func drawScan(_ page: MadeUpSheets.Page, in bounds: CGRect) {
        let dpi = 40.0
        let size = CGSize(width: page.paper.width.inches * dpi, height: page.paper.height.inches * dpi)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let c = context.cgContext
            c.setFillColor(UIColor(red: 0.80, green: 0.78, blue: 0.71, alpha: 1).cgColor)
            c.fill(CGRect(origin: .zero, size: size))
            c.setStrokeColor(UIColor(white: 0.28, alpha: 0.9).cgColor)
            c.setLineWidth(3)
            for segment in page.drawing {
                c.move(to: CGPoint(x: segment.from.x.inches * dpi, y: segment.from.y.inches * dpi))
                c.addLine(to: CGPoint(x: segment.to.x.inches * dpi, y: segment.to.y.inches * dpi))
            }
            c.strokePath()
            // Speckle, as a photocopy has.
            var seed: UInt64 = 2026_1102
            c.setFillColor(UIColor(white: 0.35, alpha: 0.5).cgColor)
            for _ in 0..<1_500 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let x = Double(seed >> 40) / Double(1 << 24) * size.width
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let y = Double(seed >> 40) / Double(1 << 24) * size.height
                c.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5))
            }
        }
        image.draw(in: bounds)
    }
}

/// Builds a sheet waiting to be placed from one of the made-up PDFs, the way Add sheet does: kept in the download
/// cache, read by `SheetPDFReader`, at the scale it reads (or `scale`).
@MainActor
enum DebugSheetSource {
    /// A line for the captures' log: the console, and `sheets.txt` in Documents, which `capture-duo.sh` prints.
    static func log(_ line: String) {
        print("sheets: " + line)
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sheets.txt")
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func pending(file index: Int, page: Int, scale: Sheet.Scale? = nil) async -> CanvasEditor.PendingSheet? {
        let file = MadeUpPDF.dropboxFile(index)
        guard let pdfs = try? SheetPDFs.inCaches(),
              let url = try? await pdfs.pdf(for: file, download: { MadeUpPDF.data(index) }) else { return nil }
        let reader = SheetPDFReader(url: url)
        guard let info = await reader.info(page: page) else { return nil }
        for line in await reader.lines(page: page) {
            log(String(format: "  text %@ at %.2f, %.2f size %.2f x %.2f", line.text, line.rect.minX, line.rect.minY,
                       line.rect.width.inches, line.rect.height.inches))
        }
        let chosen = scale ?? info.reading.suggestedScale ?? .drawn(.architectural(inchesPerFoot: 0.125))
        let invertsBadly = await reader.invertsBadly(page: page)
        for detail in info.reading.details {
            log(String(format: "  %@ %@ area %.2f, %.2f to %.2f, %.2f", detail.name, detail.scale.description,
                       detail.area.minX, detail.area.minY, detail.area.maxX, detail.area.maxY))
        }
        log("read \(info.reading.sheetNumber ?? "no number") \(info.reading.caption), placed at \(chosen), "
              + "areas \(info.reading.areas(placedAt: chosen).map(\.label)), invertsBadly \(invertsBadly)")
        let sheet = Sheet(paper: info.paper, scale: chosen,
                          page: SheetPage(file: file.keptName, name: file.name, path: file.path, index: page,
                                          number: info.reading.sheetNumber),
                          areas: info.reading.areas(placedAt: chosen), invertsBadly: invertsBadly)
        return CanvasEditor.PendingSheet(sheet: sheet, pdf: url, keptName: file.keptName)
    }
}
#endif

#if DEBUG
/// The made-up Dropbox for the sheet captures (`--ui-dropbox sheets`): a made-up project's drawings folder holding the
/// made-up PDFs, behind the same transport seam the live client uses, so Add sheet lists and downloads them through
/// `DropboxSession` exactly as it would Zach's.
struct CaptureSheetsTransport: DropboxTransport {
    func send(_ request: DropboxHTTPRequest) async throws -> DropboxHTTPResponse {
        switch request.url.lastPathComponent {
        case "download":
            let arg = request.headers["Dropbox-API-Arg"] ?? ""
            guard let index = MadeUpSheets.files.indices.first(where: { arg.contains("\"rev:madeup\($0)\"") }) else {
                return DropboxHTTPResponse(status: 409, body: Data())
            }
            return DropboxHTTPResponse(status: 200, body: MadeUpPDF.data(index))
        case "continue":
            return reply([], cursor: "c")
        default:
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
            let path = ((body?["path"] as? String) ?? "").lowercased()
            return reply(entries(in: path), cursor: "c")
        }
    }

    private func folder(_ path: String) -> [String: Any] {
        [".tag": "folder", "name": String(path.split(separator: "/").last ?? ""), "path_display": path, "id": "id:" + path]
    }

    private func entries(in path: String) -> [[String: Any]] {
        let project = "/Projects (example)", plant = project + "/Riverside Plant (example)"
        switch path {
        case "": return [folder("/Archive (example)"), folder(project), folder("/Standards (example)")]
        case project.lowercased(): return [folder(plant)]
        case plant.lowercased(): return [folder(MadeUpSheets.folder)]
        case MadeUpSheets.folder.lowercased():
            return [folder(MadeUpSheets.folder + "/" + MadeUpSheets.subfolder)] + MadeUpSheets.files.indices.map { i in
                let file = MadeUpPDF.dropboxFile(i)
                let entry: [String: Any] = [".tag": "file", "name": file.name, "path_display": file.path, "id": file.id,
                                            "size": file.size, "content_hash": file.contentHash, "rev": file.rev]
                return entry
            }
        default: return []
        }
    }

    private func reply(_ entries: [[String: Any]], cursor: String) -> DropboxHTTPResponse {
        let json: [String: Any] = ["entries": entries, "cursor": cursor, "has_more": false]
        return DropboxHTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }
}

/// Debug-only launch arguments for the sheet captures (#11). The simulator cannot hold a Pencil, so these drive the
/// canvas view's own input paths with made-up PDFs (`MadeUpSheets`), on a new canvas, so placing goes through the
/// canvas saver as it does on the Duo:
///
/// - `--ui-sheets outline`: the 1/4" plan confirmed, its true-size outline following the Pencil, held before the tap.
/// - `--ui-sheets quarter`: the 1/4" plan placed with a tap, zoomed to, and its printed 24'-0" dimension measured.
/// - `--ui-sheets asnoted`: the AS NOTED detail sheet placed at 1" = 1'-0" with its two scale areas, Detail 2's
///   printed 2'-0" measured inside its area.
/// - `--ui-sheets nts`: the NTS loop diagram placed at printed size, its 4" dimension measured: 4" NTS.
/// - `--ui-sheets scan`: the scan placed at 1/8" = 1'-0" beside the 1/4" plan: in dark mode the plan inverts and the
///   scan dims.
@MainActor
enum DebugSheets {
    private static var started = false

    static func log(_ line: String) { DebugSheetSource.log(line) }

    static func attach(_ view: InkCanvasUIView, editor: CanvasEditor) {
        guard let what = DebugLaunch.argument("--ui-sheets"), !started, view.bounds.width > 0 else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            switch what {
            case "outline":
                guard let pending = await DebugSheetSource.pending(file: 1, page: 0) else { return }
                editor.beginPlacing(pending)
                view.viewportDidChange()
                try? await Task.sleep(for: .seconds(0.5))
                let from = CGPoint(x: view.bounds.midX - 120, y: view.bounds.midY + 60)
                let to = CGPoint(x: view.bounds.midX + 90, y: view.bounds.midY - 30)
                guard view.beginInput(at: from) else { return }
                for i in 1...30 {
                    let t = CGFloat(i) / 30
                    try? await Task.sleep(for: .milliseconds(12))
                    view.moveInput(samples: [CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)],
                                   predicted: [])
                }
                log("outline waiting, step \(editor.toolStep)")
            case "quarter":
                await placeAndMeasure(view, editor, file: 1, page: 0, dimension: 0)
            case "asnoted":
                await placeAndMeasure(view, editor, file: 0, page: 1, dimension: 1)
            case "nts":
                await placeAndMeasure(view, editor, file: 0, page: 2, dimension: 0)
            case "scan":
                _ = await place(view, editor, file: 1, page: 0, at: CGPoint(x: view.bounds.midX - 150, y: view.bounds.midY))
                _ = await place(view, editor, file: 2, page: 0, scale: .drawn(.architectural(inchesPerFoot: 0.125)),
                                at: CGPoint(x: view.bounds.midX + 200, y: view.bounds.midY))
                editor.zoomToEverything()
                view.viewportDidChange()
            default:
                break
            }
            log("\(editor.sheets.count) placed, step \(editor.toolStep), shown \(view.debugAnnotationLabels)")
        }
    }

    /// Confirms a made-up page and taps where it goes, through the canvas view's input path; returns the placed sheet.
    private static func place(_ view: InkCanvasUIView, _ editor: CanvasEditor, file: Int, page: Int,
                              scale: Sheet.Scale? = nil, at point: CGPoint? = nil) async -> Sheet? {
        guard let pending = await DebugSheetSource.pending(file: file, page: page, scale: scale) else { return nil }
        editor.beginPlacing(pending)
        view.viewportDidChange()
        try? await Task.sleep(for: .seconds(0.4))
        let at = point ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard view.beginInput(at: at) else { return nil }
        try? await Task.sleep(for: .milliseconds(60))
        view.endInput(samples: [at], keep: true)
        // The PDF is kept in the canvas folder before the sheet goes on.
        for _ in 0..<40 where editor.placingSheet != nil { try? await Task.sleep(for: .milliseconds(50)) }
        return editor.sheets.last
    }

    /// Places a made-up page, zooms to it, and measures one of its printed dimensions with two taps of Measure.
    private static func placeAndMeasure(_ view: InkCanvasUIView, _ editor: CanvasEditor, file: Int, page: Int,
                                        dimension: Int) async {
        guard let sheet = await place(view, editor, file: file, page: page) else { return }
        editor.zoom(to: sheet.bounds)
        view.viewportDidChange()
        try? await Task.sleep(for: .seconds(0.6))
        let printed = MadeUpSheets.files[file].pages[page].dimensions[dimension]
        editor.tool = .measure
        for end in [printed.from, printed.to] {
            let s = editor.viewport.screenPoint(for: sheet.canvasPoint(at: end))
            let at = CGPoint(x: s.x, y: s.y)
            guard view.beginInput(at: at) else { return }
            try? await Task.sleep(for: .milliseconds(60))
            view.endInput(samples: [at], keep: true)
            try? await Task.sleep(for: .milliseconds(150))
        }
        let measured = editor.measureText(from: sheet.canvasPoint(at: printed.from), to: sheet.canvasPoint(at: printed.to))
        log("\(sheet.label) printed \(printed.text), measured \(measured)"
              + (measured == printed.text ? " (matches)" : " (DOES NOT MATCH)"))
    }
}
#endif
