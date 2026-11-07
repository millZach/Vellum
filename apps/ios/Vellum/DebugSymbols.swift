#if DEBUG
import UIKit
import VellumCore

/// Debug-only launch arguments for the symbol captures (#41). The simulator cannot hold a Pencil, so these tap through
/// the canvas view's own placing path (`InkCanvasUIView.placeSymbol`), the way a tap does, and log what landed to
/// `sheets.txt` in Documents, which `capture-duo.sh` prints:
///
/// - `--ui-symbols flyout` (on the fixture): a gate valve and a ball valve placed with Symbols, then Symbols tapped again,
///   so the rail shows the symbol picked and its flyout is open with the library.
/// - `--ui-symbols bubble` (on a new canvas): the made-up 1/4" plan placed and zoomed in to, a gate valve placed on it,
///   then an instrument bubble, which waits for its tag with the pop-up beside it, prefilled FT 101.
@MainActor
enum DebugSymbols {
    private static var started = false

    static func attach(_ view: InkCanvasUIView, editor: CanvasEditor) {
        guard let what = DebugLaunch.argument("--ui-symbols"), !started, view.bounds.width > 0 else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            switch what {
            case "flyout": await flyout(view, editor)
            case "bubble": await bubble(view, editor)
            default: break
            }
        }
    }

    private static func log(_ line: String) { DebugSheetSource.log("symbols: " + line) }

    private static func place(_ id: String, at point: CGPoint, _ view: InkCanvasUIView, _ editor: CanvasEditor) {
        editor.symbolID = id
        let before = editor.ink.count
        view.placeSymbol(at: point)
        let added = editor.ink.strokes.suffix(editor.ink.count - before)
        let across = CanvasRect.union(added.compactMap(\.pathBounds)).map { editor.canvas.format(.real($0.size.width)) }
        log("\(id) at \(Int(point.x)), \(Int(point.y)): \(added.count) strokes, \(across ?? "nothing") across, "
            + "\(editor.lastSymbolLabel ?? "no label"), tag \(editor.pendingTag.map { "\($0.letters) \($0.number)" } ?? "none")")
    }

    private static func flyout(_ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        editor.tool = .symbols
        try? await Task.sleep(for: .seconds(0.3))
        place("gate", at: CGPoint(x: view.bounds.midX + 40, y: view.bounds.midY - 60), view, editor)
        place("ball", at: CGPoint(x: view.bounds.midX + 140, y: view.bounds.midY - 60), view, editor)
        editor.showsSymbolFlyout = true
        log("flyout open with \(SymbolShelf.shared.symbols.count) symbols, prompt "
            + CanvasTool.symbolsPrompt(named: editor.symbol?.name ?? ""))
    }

    private static func bubble(_ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        guard let sheet = await DebugSheets.placeForCapture(view, editor, file: 1, page: 0) else {
            return log("no sheet placed")
        }
        // About 20 feet across the free width, round the middle of the sheet, so a 3/8" bubble is about 80 points.
        let centre = sheet.centre
        editor.zoom(to: CanvasRect(origin: centre.offsetBy(dx: .feet(-10), dy: .feet(-7)),
                                   size: CanvasSize(width: .feet(20), height: .feet(14))))
        view.viewportJumped()
        try? await Task.sleep(for: .seconds(0.5))
        editor.tool = .symbols
        try? await Task.sleep(for: .seconds(0.3))
        let y = view.bounds.midY - 20
        place("gate", at: CGPoint(x: view.bounds.midX - 160, y: y), view, editor)
        place("bubble", at: CGPoint(x: view.bounds.midX - 30, y: y), view, editor)
        log("on \(sheet.label), \(editor.sheets.count) placed, step \(editor.toolStep)")
    }
}
#endif
