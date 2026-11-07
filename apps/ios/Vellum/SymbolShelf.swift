import Foundation
import Observation
import SwiftUI
import VellumCore

/// The symbol library every canvas shares (#41, CONTEXT.md "Symbol library"): the six starter symbols built into the
/// app, then the symbols saved on this Duo or put in `Dropbox/Vellum/Symbols` by the laptop. The files are read and
/// written off the main thread (`SymbolFolder`), and the library syncs with Dropbox after each save and whenever the
/// canvases sync starts or the app comes back, through Vellum's own Dropbox client (`SymbolSync`, ADR-0016).
@MainActor
@Observable
final class SymbolShelf {
    static let shared = SymbolShelf()

    /// The starters first, then the saved symbols by name.
    private(set) var symbols: [Symbol] = Symbol.starters
    /// Each symbol's drawing for the flyout and the rail, made once per symbol rather than per frame.
    @ObservationIgnored private var drawings: [String: Path] = [:]
    @ObservationIgnored private var store: (any SymbolFolderStore)?
    @ObservationIgnored private var sync: SymbolSync?

    private init() {}

    func symbol(_ id: String) -> Symbol? { symbols.first { $0.id == id } }

    /// Reads the library's files and starts its sync. Nothing here runs on the main thread but the hand-over.
    func start(store: any SymbolFolderStore, sync: SymbolSync?) async {
        guard self.store == nil else { return }
        self.store = store
        self.sync = sync
        await reload()
        syncNow()
    }

    /// Syncs with Dropbox off the main thread, and reads the files again if any came down.
    func syncNow() {
        guard let sync else { return }
        Task { [weak self] in
            if await sync.sync() { await self?.reload() }
        }
    }

    private func reload() async {
        guard let store else { return }
        let saved = await Task.detached(priority: .utility) { store.symbols() }.value
        symbols = Symbol.starters + saved.filter { !$0.isStarter }
        drawings = [:]
    }

    /// Saves a new symbol: in the library at once, its file written off the main thread, then synced.
    func save(_ symbol: Symbol) {
        symbols.append(symbol)
        guard let store else { return }
        Task { [weak self] in
            await Task.detached(priority: .userInitiated) { try? store.save(symbol) }.value
            self?.syncNow()
        }
    }

    /// The symbol's drawing in a unit square: its lines, fitted with a little room round them. Text and the tag are
    /// drawn by the flyout's own labels.
    func drawing(of symbol: Symbol) -> Path {
        if let made = drawings[symbol.id] { return made }
        let e = symbol.extent
        let side = max(e.maxX - e.minX, e.maxY - e.minY, 1e-9) * 1.12
        let cx = (e.minX + e.maxX) / 2, cy = (e.minY + e.maxY) / 2
        var path = Path()
        for line in symbol.polylines {
            for (i, p) in line.enumerated() {
                let point = CGPoint(x: (p.x - cx) / side + 0.5, y: (p.y - cy) / side + 0.5)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        drawings[symbol.id] = path
        return path
    }

    /// Where each of the symbol's letters goes in the unit square the drawing is fitted to, with their height there.
    func letters(of symbol: Symbol) -> [(text: String, centre: CGPoint, height: CGFloat)] {
        let e = symbol.extent
        let side = max(e.maxX - e.minX, e.maxY - e.minY, 1e-9) * 1.12
        let cx = (e.minX + e.maxX) / 2, cy = (e.minY + e.maxY) / 2
        return symbol.parts.compactMap { part in
            switch part {
            case .text(let c, let h, let text, _, _):
                return (text, CGPoint(x: (c.x - cx) / side + 0.5, y: (c.y - cy) / side + 0.5), CGFloat(h / side))
            case .tag(let c, let h):
                return ("\(symbol.tagLetters ?? "")\n\(SymbolTag.first)",
                        CGPoint(x: (c.x - cx) / side + 0.5, y: (c.y - cy) / side + 0.5), CGFloat(h / side))
            default:
                return nil
            }
        }
    }
}

/// A symbol's drawing, as the flyout and the rail show it: its lines, and its letters.
struct SymbolMark: View {
    let symbol: Symbol
    var lineWidth: CGFloat = 1.4

    var body: some View {
        let shelf = SymbolShelf.shared
        let path = shelf.drawing(of: symbol)
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack(alignment: .topLeading) {
                path.applying(CGAffineTransform(scaleX: side, y: side))
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                ForEach(Array(shelf.letters(of: symbol).enumerated()), id: \.offset) { _, letter in
                    Text(letter.text)
                        .font(.system(size: max(4, letter.height * side), weight: .medium))
                        .multilineTextAlignment(.center)
                        .lineSpacing(0)
                        .fixedSize()
                        .position(x: letter.centre.x * side, y: letter.centre.y * side)
                }
            }
            .frame(width: side, height: side)
        }
        .accessibilityHidden(true)
    }
}
