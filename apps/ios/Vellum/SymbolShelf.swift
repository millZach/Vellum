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
    /// Each symbol's drawing for the flyout and the rail, made once per symbol rather than per layout: its lines and
    /// where its letters go, fitted to a unit square.
    @ObservationIgnored private var drawings: [String: Fitted] = [:]
    /// Symbols saved in this session that a read of the files has not caught up with yet. A reload started before their
    /// file landed keeps them, so a sync finishing mid-save never drops one from the flyout.
    @ObservationIgnored private var savedHere: [String: Symbol] = [:]
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

    /// Reads the files off the main thread. A symbol saved in this session that the read doesn't hold yet stays.
    private func reload() async {
        guard let store else { return }
        let saved = await Task.detached(priority: .utility) { store.symbols() }.value
        let read = Set(saved.map(\.id))
        for id in savedHere.keys where read.contains(id) { savedHere[id] = nil }
        let kept = savedHere.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        symbols = Symbol.starters + saved.filter { !$0.isStarter } + kept
        drawings = [:]
    }

    /// Why a symbol wasn't saved, for the status bar (28 characters at most) and VoiceOver.
    struct SaveFailure: Error {
        let outOfSpace: Bool
        var statusBar: String { outOfSpace ? "Symbol not saved: Duo full" : "Symbol not saved: disk error" }
        var spoken: String {
            outOfSpace ? "The symbol was not saved: this Duo is full."
                : "The symbol was not saved: its file could not be written. Try again."
        }
    }

    /// Saves a new symbol: in the library at once, its file written off the main thread, then synced. If the file can't
    /// be written it leaves the library again, and `failed` hears why.
    func save(_ symbol: Symbol, failed: @escaping @MainActor (SaveFailure) -> Void) {
        symbols.append(symbol)
        savedHere[symbol.id] = symbol
        guard let store else { return }
        Task { [weak self] in
            let error: (any Error)? = await Task.detached(priority: .userInitiated) { () -> (any Error)? in
                do { try store.save(symbol) } catch { return error }
                return nil
            }.value
            guard let self else { return }
            if let error {
                self.savedHere[symbol.id] = nil
                self.symbols.removeAll { $0.id == symbol.id }
                let outOfSpace = (error as? any StorageFailure)?.isOutOfSpace == true
                    || (error as NSError).code == NSFileWriteOutOfSpaceError
                failed(SaveFailure(outOfSpace: outOfSpace))
                return
            }
            self.syncNow()
        }
    }

    /// A symbol's lines and letters fitted to a unit square with a little room round them, worked out from its extent once.
    struct Fitted {
        var lines: Path
        var letters: [(text: String, centre: CGPoint, height: CGFloat)]
    }

    /// The symbol's drawing, made once and kept: its extent is walked here, not on every layout.
    func fitted(_ symbol: Symbol) -> Fitted {
        if let made = drawings[symbol.id] { return made }
        let e = symbol.extent
        let side = max(e.maxX - e.minX, e.maxY - e.minY, 1e-9) * 1.12
        let cx = (e.minX + e.maxX) / 2, cy = (e.minY + e.maxY) / 2
        func fit(_ p: SymbolPoint) -> CGPoint { CGPoint(x: (p.x - cx) / side + 0.5, y: (p.y - cy) / side + 0.5) }
        var path = Path()
        for line in symbol.polylines {
            for (i, p) in line.enumerated() {
                if i == 0 { path.move(to: fit(p)) } else { path.addLine(to: fit(p)) }
            }
        }
        let letters = symbol.parts.compactMap { part -> (text: String, centre: CGPoint, height: CGFloat)? in
            switch part {
            case .text(let c, let h, let text, _, _):
                return (text, fit(c), CGFloat(h / side))
            case .tag(let c, let h):
                return ("\(symbol.tagLetters ?? "")\n\(SymbolTag.first)", fit(c), CGFloat(h / side))
            default:
                return nil
            }
        }
        let made = Fitted(lines: path, letters: letters)
        drawings[symbol.id] = made
        return made
    }
}

/// A symbol's drawing, as the flyout and the rail show it: its lines, and its letters.
struct SymbolMark: View {
    let symbol: Symbol
    var lineWidth: CGFloat = 1.4

    var body: some View {
        let fitted = SymbolShelf.shared.fitted(symbol)
        let path = fitted.lines
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack(alignment: .topLeading) {
                path.applying(CGAffineTransform(scaleX: side, y: side))
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                ForEach(Array(fitted.letters.enumerated()), id: \.offset) { _, letter in
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
