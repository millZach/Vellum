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
///
/// Use with `--ui-dropbox folders`, so the Drawings tab is signed in.
@MainActor
enum DebugDrawingIndex {
    static func start(_ model: DrawingIndexModel) async -> Bool {
        guard let state = DebugLaunch.argument("--ui-index") else { return false }
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
                    }
                }
            }
            return dropbox
        }.value
        let key = DropboxAppKey(buildSetting: "capturekey00000")!
        let tokens = DropboxTokens(accessToken: "capture", refreshToken: "capture", expiresAt: .distantFuture)
        let session = DropboxSession(appKey: key, transport: dropbox, store: DropboxMemoryTokenStore(tokens))
        model.followsConnection = false
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
        return true
    }
}
#endif
