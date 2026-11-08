import Foundation
import VellumCore

/// Starts the drawing index's copy and search on the app's Dropbox session; in Debug captures (`--ui-index`), on a
/// made-up Dropbox (`DebugDrawingIndex`).
enum DrawingIndexSetup {
    @MainActor
    static func start(_ model: DrawingIndexModel) async {
        #if DEBUG
        if await DebugDrawingIndex.start(model) { return }
        #endif
        await model.start(session: DropboxConnection.app.downloads)
    }
}

#if DEBUG
/// Debug-only launch arguments for the drawing index's captures (#68). None of them exist in a TestFlight build.
///
/// - `--ui-index fixture`: a made-up Dropbox holding the laptop indexer's made-up index, which the capture script
///   copies into the app's Documents folder (`capture-index`); the Duo's copy starts empty and is refreshed from it.
/// - `--ui-index fixture-offline`: the same, then the Duo goes offline, so rows say "Not on this Duo".
/// - `--ui-index none`: Dropbox holds no index yet.
/// - `--ui-index offline`: offline, with no copy on the Duo yet.
/// - `--ui-search <text>`: types it in the search field. `--ui-select <number>`: picks that drawing, unfolded.
/// - `--ui-viewer <number>` (#69): opens that drawing in the viewer, as a tap on its row does. The made-up Dropbox holds
///   a made-up PDF (`MadeUpPDF`) at every PDF path the fixture names: the three-page set for M-501, the 1/4" plan for the
///   rest. With `--ui-viewer-step picker`, Place on a canvas… is tapped once the PDF is open; with `place`, the newest
///   canvas is picked, so the Canvases tab shows the sheet waiting in tap-to-place; with `new`, Open in a new canvas.
/// - `--ui-viewer-timing` (#69): opens a made-up twelve-page E-size set already on the Duo three times, logging each
///   time from the tap to its first page's first tile to `viewer.txt`, and their median to `viewer-timing.json`.
///
/// - `--ui-plot <laptop>` (#70): the plot watch keeps its requests in memory, and a made-up laptop answers them on the
///   made-up Dropbox as the laptop indexer would: `plotting` (queued, then plotting, never done), `waiting` (its
///   check-in 12 minutes old, never answering), `queued` (the Duo goes offline before the drawing opens), `failed` (the
///   laptop's reason), `done` (queued, plotting, then a made-up PDF), `done-warning` (the same, with 2 references
///   missing) and `done-fitted` (the same, plotted to fit the page, not to scale, as a Model-tab DWG's fallback is,
///   #92). Use with `--ui-viewer E-201`, the fixture's DWG with no PDF. `--ui-plot-leave` switches to the Canvases
///   tab once the request is asked, so the banner calls Zach back when the plot is in.
///
/// Use with `--ui-dropbox folders`, so the Drawings tab is signed in.
@MainActor
enum DebugDrawingIndex {
    static func start(_ model: DrawingIndexModel) async -> Bool {
        guard let state = DebugLaunch.argument("--ui-index") else { return false }
        let viewerPDFs = DebugLaunch.has("--ui-viewer")
        let dropbox = await Task.detached { () -> MadeUpDropbox in
            // Every capture starts with no copy on the Duo.
            if let root = try? DrawingIndexKeeper.folderOnThisDevice() { try? FileManager.default.removeItem(at: root) }
            let dropbox = MadeUpDropbox()
            if state.hasPrefix("fixture"), let documents = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                let folder = documents.appendingPathComponent("capture-index", isDirectory: true)
                for sub in ["", "shards", "thumbnails"] {
                    let dir = sub.isEmpty ? folder : folder.appendingPathComponent(sub, isDirectory: true)
                    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                        guard name.hasSuffix(".json") || name.hasSuffix(".png"),
                              let bytes = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
                        let path = "/Vellum/Index/" + (sub.isEmpty ? "" : sub + "/") + name
                        dropbox.changeOnTheLaptop(path, to: [UInt8](bytes))
                        // The viewer's captures: a made-up PDF at each PDF path the fixture names (#69).
                        if sub == "shards", viewerPDFs,
                           let shard = try? DrawingIndexFormat.shard(from: [UInt8](bytes)) {
                            for entry in shard.drawings {
                                guard let pdf = entry.pdf else { continue }
                                let made = MadeUpPDF.data(entry.number == "M-501" ? 0 : 1)
                                dropbox.changeOnTheLaptop(pdf.path, to: [UInt8](made))
                            }
                        }
                    }
                }
            }
            return dropbox
        }.value
        let key = DropboxAppKey(buildSetting: "capturekey00000")!
        let tokens = DropboxTokens(accessToken: "capture", refreshToken: "capture", expiresAt: .distantFuture)
        let session = DropboxSession(appKey: key, transport: dropbox, store: DropboxMemoryTokenStore(tokens))
        model.followsConnection = false
        let plot = DebugLaunch.argument("--ui-plot")
        if let plot {
            model.plotLedger = PlotLedgerMemory()
            DebugPlotLaptop.run(dropbox, mode: plot)
        }
        if state == "offline" {
            dropbox.offline = true
            model.debugSetOnline(false)
        }
        await model.start(session: session)
        if state.hasPrefix("fixture"), let keeper = model.keeper {
            // Thumbnails come down as rows show them; the captures take them all first, so the offline one has them.
            for name in model.debugThumbnailNames() { _ = await keeper.thumbnail(name, online: true) }
        }
        if state == "fixture-offline" {
            dropbox.offline = true
            model.debugSetOnline(false)
        }
        if let query = DebugLaunch.argument("--ui-search") { model.query = query }
        if let number = DebugLaunch.argument("--ui-select") { model.debugSelect(number: number) }
        if plot == "queued" {
            dropbox.offline = true
            model.debugSetOnline(false)
            try? await Task.sleep(for: .milliseconds(300))
        }
        if let number = DebugLaunch.argument("--ui-viewer") { model.debugOpen(number: number) }
        if plot != nil, DebugLaunch.has("--ui-plot-leave") {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                model.debugTab = .canvases
            }
        }
        if DebugLaunch.has("--ui-viewer-timing") { Task { await DebugDrawingViewer.time(model) } }
        return true
    }
}

/// The viewer's Debug-only steps for the captures (#69), driven through the viewer's own buttons' paths.
@MainActor
enum DebugDrawingViewer {
    private static var drove = false
    /// The confirm step the viewer last opened.
    static weak var asked: AddSheetModel?

    /// Waits for the confirm step to read its page, logs what it starts on, and taps its Place.
    private static func confirm() async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let asked else { return log("no confirm step") }
        log("confirm step: \(asked.placeLabel), starting on \(asked.prefilled?.description ?? "a scale to pick")")
        await asked.debugConfirm()
    }

    static func log(_ line: String) {
        print("viewer: " + line)
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("viewer.txt")
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// `--ui-viewer-step`, once the viewer's PDF is open.
    static func drive(_ view: DrawingViewerView, ready: Bool) async {
        guard ready, !drove, let step = DebugLaunch.argument("--ui-viewer-step") else { return }
        drove = true
        try? await Task.sleep(for: .seconds(0.8))
        log("open \(view.model.entry.number ?? "?"), \(view.model.pageCount) pages, first page in "
            + (view.model.firstPageMilliseconds.map { String(format: "%.0f ms", $0) } ?? "not yet")
            + ", note: \(view.model.placingNote)")
        switch step {
        case "picker":
            view.showPicker()
        case "place":
            guard let canvases = view.handoff?.canvases else { return }
            for _ in 0..<100 where canvases.summaries.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
            guard let newest = canvases.summaries.first else { return log("no canvas to place on") }
            log("placing on \(newest.name)")
            view.go(.canvas(newest.id, name: newest.name, units: newest.units))
            await confirm()
            for _ in 0..<60 where canvases.openEditor?.placingSheet == nil { try? await Task.sleep(for: .milliseconds(50)) }
            if let pending = canvases.openEditor?.placingSheet {
                log("waiting to place \(pending.sheet.page?.title ?? "?") at \(pending.sheet.scale), covering "
                    + "\(canvases.openEditor?.covers(pending.sheet) ?? "?"), areas \(pending.sheet.areas.map(\.label))")
            }
        case "new":
            view.go(.newCanvas)
            await confirm()
            guard let canvases = view.handoff?.canvases else { return }
            for _ in 0..<60 where canvases.openEditor?.sheets.isEmpty ?? true { try? await Task.sleep(for: .milliseconds(50)) }
            if let editor = canvases.openEditor, let sheet = editor.sheets.first {
                log("new canvas \(editor.canvas.name) with \(sheet.page?.title ?? "?") at \(sheet.scale), "
                    + "\(editor.covers(sheet)), centred at \(sheet.centre)")
            }
        default:
            break
        }
    }

    /// `--ui-viewer-timing`: the time to the first page of a made-up twelve-page E-size set already on the Duo.
    static func time(_ model: DrawingIndexModel) async {
        guard let pdfs = SheetPDFs.app else { return }
        let entry = await Task.detached(priority: .utility) { () -> DrawingEntry? in
            let bytes = MadeUpPDF.eSizeSet(pages: 12)
            let hash = DropboxContentHash.of([UInt8](bytes))
            try? FileManager.default.createDirectory(at: pdfs.folder, withIntermediateDirectories: true)
            guard (try? bytes.write(to: pdfs.url(keptName: hash), options: .atomic)) != nil else { return nil }
            return DrawingEntry(
                id: "madeup-e-size", path: "/Made-up (example)/X-901.dwg", name: "X-901.dwg", layout: "Layout1",
                number: "X-901", title: "Made-up E-size set (example)", revision: "0", scale: "1/8\" = 1'-0\"",
                dwg: .init(path: "/Made-up (example)/X-901.dwg"),
                pdf: .init(path: "/Made-up (example)/X-901.pdf", size: bytes.count, contentHash: hash, pages: 12,
                           paperInches: [44, 34]))
        }.value
        guard let entry else { return log("couldn't keep the made-up E-size set") }
        await model.notePDFsOnThisDuo()
        log("made-up E-size set: 12 pages of 44 x 34 in, \(entry.pdf?.size ?? 0) bytes, on the Duo")
        var times: [Double] = []
        for run in 1...3 {
            model.closeViewer()
            try? await Task.sleep(for: .seconds(1))
            model.open(entry)
            for _ in 0..<400 where model.viewer?.firstPageMilliseconds == nil {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard let viewer = model.viewer, let ms = viewer.firstPageMilliseconds else {
                log("run \(run): no first page in 10 s")
                continue
            }
            times.append(ms)
            log(String(format: "run %d: first page in %.1f ms, downloaded %@", run, ms, viewer.downloaded ? "yes" : "no"))
        }
        guard !times.isEmpty else { return }
        let median = times.sorted()[times.count / 2]
        log(String(format: "viewer_first_page_ms_debug %.1f", median))
        let json = #"{"measurements":[{"metric":"viewer_first_page_ms_debug","value":\#(String(format: "%.1f", median))}]}"#
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("viewer-timing.json")
        try? json.write(to: file, atomically: true, encoding: .utf8)
        log("done")
    }
}
#endif

#if DEBUG
/// The made-up laptop for the plot captures (#70): it checks in, and answers each request in
/// `Dropbox/Vellum/Plots/requests` as `laptop/src/vellum_indexer/plot_requests.py` does, on the made-up Dropbox. Every
/// path and reason is made up.
enum DebugPlotLaptop {
    static let checkIn = Array(#"{"every": 120, "format": 1, "indexer": "1.1.0", "seen": "2026-11-07T12:00:00Z", "staleAfter": 300}"#.utf8)
    static let reason = "the layout has no page setup that plots to PDF, and its paper size (500 x 700 mm) isn't one DWG To PDF has"

    static func run(_ dropbox: MadeUpDropbox, mode: String) {
        let seen = mode == "waiting" ? Date().addingTimeInterval(-720) : Date()
        dropbox.changeOnTheLaptop(PlotRequestFormat.checkInPath, to: checkIn, at: seen)
        guard mode != "waiting" else { return }
        Task.detached(priority: .utility) {
            var looks: [String: Int] = [:]
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                for (name, bytes) in dropbox.files(in: PlotRequestFormat.requestsFolder)
                where name.hasSuffix(".json") && !name.hasSuffix(".answer.json") {
                    let request = String(name.dropLast(".json".count))
                    let id = (try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])?["id"] as? String
                    let look = (looks[request] ?? 0) + 1
                    looks[request] = look
                    answer(dropbox, request: request, id: id, mode: mode, look: look)
                }
            }
        }
    }

    private static func answer(_ dropbox: MadeUpDropbox, request: String, id: String?, mode: String, look: Int) {
        var object: [String: Any] = ["format": 1, "request": request, "id": id.map { $0 as Any } ?? NSNull(),
                                     "updated": PlotRequestFormat.time(Date()),
                                     "pdf": NSNull(), "contentHash": NSNull(), "pageSetup": NSNull(), "reason": NSNull(),
                                     "missingReferences": NSNull(), "warning": NSNull()]
        switch mode {
        case "failed":
            guard look == 2 else { return }
            object["state"] = "failed"
            object["reason"] = reason
        case "plotting", "queued":
            guard look == 1 || look == 3 else { return }
            object["state"] = look == 1 ? "queued" : "plotting"
        default:
            guard [1, 2, 4].contains(look) else { return }
            object["state"] = look == 1 ? "queued" : look == 2 ? "plotting" : "done"
            if look == 4 {
                let pdf = MadeUpPDF.data(1)
                let path = "/Vellum/Plots/Made-up Plant Upgrade/E-201 - Layout1 - 2026-09-21 141500 - 5c0e1d2a.pdf"
                dropbox.changeOnTheLaptop(path, to: [UInt8](pdf))
                object["pdf"] = path
                object["contentHash"] = DropboxContentHash.of([UInt8](pdf))
                object["pageSetup"] = "saved"
                object["missingReferences"] = mode == "done-warning" ? 2 : 0
                object["fitted"] = mode == "done-fitted"
                if mode == "done-warning" { object["warning"] = "2 references couldn't be found, so the PDF is missing them" }
                if mode == "done-fitted" {
                    object["pageSetup"] = "fallback"
                    object["reason"] = "the Model tab has no page setup that plots to PDF, so its extents were plotted "
                        + "with DWG To PDF to fit the page, not to scale"
                }
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        dropbox.changeOnTheLaptop(PlotRequestFormat.answerPath(request), to: [UInt8](data))
    }
}
#endif
