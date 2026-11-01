/// How the stroke being drawn is split for drawing, so each Pencil sample costs the same however long the stroke
/// has grown (ADR-0012).
///
/// The stroke's confirmed points are cut into chunks of at most `chunkSize` points. Each chunk starts on the point the
/// one before it ended on, so together they draw every segment exactly once. A full chunk is frozen: its points never
/// change, so the renderer builds its path once. Only the open chunk at the end is rebuilt as samples arrive, and the
/// predicted tail, from the last confirmed point through the Pencil's predicted touches, is replaced on every sample.
public struct LiveStrokeChunks: Hashable, Sendable {
    public static let defaultChunkSize = 64

    /// The most points a chunk holds, its first (shared) point included.
    public let chunkSize: Int
    /// The point ranges of the frozen chunks, in order.
    public private(set) var frozen: [Range<Int>] = []
    /// How many confirmed points the chunks cover.
    public private(set) var pointCount = 0

    public init(chunkSize: Int = LiveStrokeChunks.defaultChunkSize) {
        precondition(chunkSize >= 2, "a chunk needs at least one segment")
        self.chunkSize = chunkSize
    }

    /// Where the open chunk starts: the last point of the last frozen chunk, or the first point.
    public var openStart: Int { frozen.last.map { $0.upperBound - 1 } ?? 0 }

    /// The point range of the open chunk, the one still growing.
    public var open: Range<Int> { openStart..<max(openStart, pointCount) }

    /// What one `update` changed: chunks newly frozen, which the renderer draws once, and the open chunk.
    public struct Update: Hashable, Sendable {
        public var newlyFrozen: [Range<Int>]
        public var open: Range<Int>
    }

    /// Takes in the stroke's confirmed points, which only ever grow. The work is proportional to the points added,
    /// never to the stroke's length.
    public mutating func update(pointCount newCount: Int) -> Update {
        precondition(newCount >= pointCount, "a stroke in progress only grows")
        pointCount = newCount
        var newlyFrozen: [Range<Int>] = []
        // Freeze a chunk once it is full and the stroke has gone on past it.
        while pointCount - openStart > chunkSize {
            let chunk = openStart..<(openStart + chunkSize)
            frozen.append(chunk)
            newlyFrozen.append(chunk)
        }
        return Update(newlyFrozen: newlyFrozen, open: open)
    }

    /// The predicted tail: the last confirmed point and then the Pencil's predicted points. Empty without a
    /// prediction, since the open chunk already ends on the last confirmed point.
    public static func tail(confirmed points: [CanvasPoint], predicted: [CanvasPoint]) -> [CanvasPoint] {
        guard let last = points.last, !predicted.isEmpty else { return [] }
        return [last] + predicted
    }
}
