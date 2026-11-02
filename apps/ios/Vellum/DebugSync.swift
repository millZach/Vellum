#if DEBUG
import Foundation
import VellumCore

/// Debug-only launch arguments for the sync captures and the airplane-mode proof (#12). The simulator has no Dropbox
/// key, so they sync to VellumCore's made-up Dropbox (`MadeUpDropbox`), in memory, behind the same transport seam the
/// live client uses, with an offline switch. None of this exists in a TestFlight build.
///
/// - `--ui-sync synced|offline|failed|signedout|notsaved`: the fixture canvas (or, with `--ui-sync-list`, the made-up
///   canvases of `--ui-seed-list`) in that state, on the canvas screen (or the Canvases list). Offline edits the canvas
///   with the Dropbox switched off; not saved shows "Not saved: will retry" on a synced canvas, for contrast.
/// - `--ui-sync airplane`: the done-when proof. A canvas drawn with the Dropbox offline, left (the list says it waits),
///   the connection returned (it syncs), and the files the made-up Dropbox holds rebuilt as the laptop would, checked
///   byte for byte against the Duo's. It logs each step to `sync.txt` in Documents, which `capture-duo.sh` waits on.
@MainActor
enum DebugSync {
    static var isOn: Bool { DebugLaunch.argument("--ui-sync") != nil }
    static let dropbox = MadeUpDropbox()

    /// The made-up session, or nil without `--ui-sync`.
    static func session() -> DropboxSession? {
        guard let state = DebugLaunch.argument("--ui-sync") else { return nil }
        let key = DropboxAppKey(buildSetting: "capturekey00000")!
        let tokens = DropboxTokens(accessToken: "capture", refreshToken: "capture", expiresAt: .distantFuture)
        dropbox.failing = state == "failed"
        return DropboxSession(appKey: key, transport: dropbox,
                              store: DropboxMemoryTokenStore(state == "signedout" ? nil : tokens))
    }

    static func log(_ line: String) {
        print("sync: " + line)
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sync.txt")
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func run(_ model: CanvasesModel, library: CanvasLibrary) async -> Bool {
        guard let state = DebugLaunch.argument("--ui-sync"), let sync = model.sync else { return false }
        await Task.detached {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("sync.txt")
            try? FileManager.default.removeItem(at: file)
        }.value
        await sync.start()
        if state == "airplane" {
            await airplane(model, library: library, sync: sync)
            return true
        }
        let list = DebugLaunch.has("--ui-sync-list")
        var ids: [UUID] = []
        if list {
            let full = DebugFixture.session
            await Task.detached { DebugLaunch.seedList(full, in: library) }.value
            await model.refresh()
            ids = model.summaries.map(\.id)
        } else {
            let fixture = DebugFixture.session
            guard let id = await Task.detached(operation: { DebugLaunch.save(fixture, named: DebugFixture.name, in: library) }).value
            else { return false }
            await model.refresh()
            ids = [id]
        }
        switch state {
        case "offline":
            dropbox.offline = true
            await sync.setOnline(false)
            for id in ids { await sync.canvasLeft(id) }
        case "synced", "failed", "notsaved":
            for id in ids { await sync.canvasLeft(id) }
            await sync.drained()
        default:
            break  // signed out: nothing can go
        }
        if list {
            if state == "notsaved", let first = ids.first { model.debugMarkUnsaved(first, .notSaved(outOfSpace: false)) }
        } else if let id = ids.first {
            await model.open(id, startingView: .everything)
            if let editor = model.openEditor {
                if state == "offline", let stroke = DebugFixture.session.ink.strokes.first {
                    // An edit made in airplane mode.
                    var live = StrokeInProgress(tool: stroke.tool, colour: stroke.colour, width: stroke.width,
                                                start: stroke.points[0])
                    for p in stroke.points.dropFirst() { live.add(p) }
                    editor.commit(live)
                }
                if state == "notsaved" { editor.saveStateDidChange(.notSaved(outOfSpace: false)) }
            }
        }
        model.finishLaunch()
        log("state \(state) \(list ? "list" : "canvas") ready")
        return true
    }

    /// Airplane mode, then the connection back, then the laptop's view of the folder.
    private static func airplane(_ model: CanvasesModel, library: CanvasLibrary, sync: CanvasSync) async {
        dropbox.offline = true
        await sync.setOnline(false)
        guard let made = await Task.detached(operation: { try? library.create(name: "Airplane mode test (example)") }).value
        else { return log("could not make the canvas") }
        await model.refresh()
        let extents = DebugFixture.canvas.extents
            ?? CanvasRect(origin: .origin, size: CanvasSize(width: .feet(10), height: .feet(10)))
        await model.open(made.id, startingView: .region(extents))
        model.finishLaunch()
        guard let editor = model.openEditor else { return log("could not open the canvas") }
        for stroke in DebugFixture.session.ink.strokes {
            var live = StrokeInProgress(tool: stroke.tool, colour: stroke.colour, width: stroke.width, start: stroke.points[0])
            for p in stroke.points.dropFirst() { live.add(p) }
            editor.commit(live)
            try? await Task.sleep(for: .milliseconds(40))
        }
        log("offline: drew \(DebugFixture.session.ink.strokes.count) strokes with the Dropbox switched off")
        try? await Task.sleep(for: .seconds(2))
        log("offline canvas ready")
        try? await Task.sleep(for: .seconds(6))
        model.closeCanvas()
        try? await Task.sleep(for: .seconds(2))
        log("offline: left the canvas; it reads \(model.syncState(of: made.id)) and Dropbox holds \(dropbox.allFiles.count) files")
        log("offline list ready")
        try? await Task.sleep(for: .seconds(8))

        dropbox.offline = false
        await sync.setOnline(true)
        await sync.drained()
        try? await Task.sleep(for: .seconds(1))
        let folder = await sync.ledgerNow[made.id]?.folder ?? "?"
        log("online: \(model.syncState(of: made.id)) after \(dropbox.requests.count) requests, \(dropbox.bytesUploaded) bytes")
        let files = dropbox.files(in: SyncPaths.folder(folder))
        for (path, bytes) in files.sorted(by: { $0.key < $1.key }) {
            log("  Dropbox/Vellum/\(folder)/\(path)  \(bytes.count) bytes")
        }
        let duo = library.folder(for: made.id)
        let fixtureStrokes = DebugFixture.session.ink.count
        let report = await Task.detached { () -> [String] in
            var lines: [String] = []
            do {
                let rebuilt = try SyncedCanvasFolder.rebuild(files)
                func duoBytes(_ name: String) -> [UInt8]? {
                    (try? Data(contentsOf: duo.appendingPathComponent(name))).map { [UInt8]($0) }
                }
                lines.append("laptop: canvas.json matches the Duo's byte for byte: \(rebuilt.manifest == duoBytes(CanvasManifest.fileName))")
                lines.append("laptop: ink.snapshot matches: \(rebuilt.snapshot == duoBytes(InkStore.snapshotName))")
                lines.append("laptop: ink.log rebuilt from its parts matches the Duo's byte for byte: \(rebuilt.log == duoBytes(InkStore.logName)) (\(rebuilt.log.count) bytes)")
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("laptop-\(UUID().uuidString)")
                try SyncedCanvasFolder.write(rebuilt, to: copy)
                let opened = try InkStore(folder: copy)
                lines.append("laptop: the rebuilt canvas opens with \(opened.session.ink.count) strokes; the fixture has \(fixtureStrokes)")
                opened.closeFiles()
                try? FileManager.default.removeItem(at: copy)
            } catch {
                lines.append("laptop: could not rebuild the canvas: \(error)")
            }
            return lines
        }.value
        for line in report { log(line) }
        log("online list ready")
    }
}
#endif
