@testable import VellumCore

/// Stands in for the app's tile renderer around an `InkTileBook`: records what the book asks to draw, and draws it
/// the way the renderer does (find the tile's strokes in the index, get each one's path from the cache), without
/// layers or images.
final class InkTileHarness {
    typealias Book = InkTileBook<Void, Void>

    private(set) var book: Book!
    var index: InkIndex
    let paths = StrokePathCache<Int> { points, _ in points.count }
    private(set) var requests: [(tile: Book.Tile, level: Book.Level, adding: [InkStroke]?)] = []
    private(set) var levelsDiscarded = 0

    init(index: InkIndex) {
        self.index = index
        book = Book(minimumWidth: 1, hooks: Book.Hooks(
            makeLevel: { _ in }, makeTile: { _, _ in },
            discardLevel: { [unowned self] _ in levelsDiscarded += 1 }, discardTile: { _, _ in },
            draw: { [unowned self] tile, level, adding in requests.append((tile, level, adding)) }))
    }

    /// Draws everything asked for, and anything those drawings ask for in turn.
    func drawAll() {
        while !requests.isEmpty {
            let batch = requests
            requests = []
            for (tile, level, adding) in batch {
                let epoch = tile.epoch
                let strokes: [InkStroke]
                if let adding {
                    strokes = adding
                } else {
                    guard book.begin(tile, in: level) else { continue }
                    let tiling = level.tiling
                    strokes = index.strokes(in: tiling.box(of: tile.key).grown(by: tiling.margin(minimumWidth: 1)))
                }
                for stroke in strokes { _ = paths.path(for: stroke) }
                book.finished(tile, in: level, epoch: epoch, drewImage: true)
            }
        }
    }
}
