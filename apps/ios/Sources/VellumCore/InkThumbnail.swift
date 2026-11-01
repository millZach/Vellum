/// A small picture of a canvas's ink for the Canvases list (ADR-0013): every stroke fitted into a thumbnail and
/// thinned to the points a thumbnail can show, so drawing it is cheap. The app makes one in the background after the
/// ink changes and caches the picture; the list never decodes a canvas to show it.
public struct InkThumbnail: Hashable, Sendable {
    /// One stroke in the thumbnail's own points, origin at the top left, y down.
    public struct Line: Hashable, Sendable {
        public var tool: InkTool
        public var colour: MarkupColour
        public var width: Double
        public var xs: [Double]
        public var ys: [Double]
    }

    public var width: Double
    public var height: Double
    public var lines: [Line]
    /// How many strokes the canvas holds, all of them, for the list's "312 strokes".
    public var strokeCount: Int

    /// Fits the ink into `width` × `height` points with `padding` all round, keeping its proportions, and drops points
    /// closer than `spacing` points to the last one kept. Strokes are never drawn thinner than `minimumWidth`.
    public init(ink: Ink, width: Double, height: Double, padding: Double = 12, spacing: Double = 0.75,
                minimumWidth: Double = 0.75) {
        self.width = width
        self.height = height
        strokeCount = ink.strokes.count
        guard let bounds = ink.bounds else {
            lines = []
            return
        }
        let room = (max(width - 2 * padding, 1), max(height - 2 * padding, 1))
        let spanX = max(bounds.size.width.inches, 1e-9), spanY = max(bounds.size.height.inches, 1e-9)
        let scale = min(room.0 / spanX, room.1 / spanY)
        // Centred in the thumbnail; canvas y grows down the screen as it does on the canvas screen.
        let offsetX = (width - spanX * scale) / 2 - bounds.minX.inches * scale
        let offsetY = (height - spanY * scale) / 2 - bounds.minY.inches * scale
        let spacingSquared = spacing * spacing
        var lines: [Line] = []
        lines.reserveCapacity(ink.strokes.count)
        for stroke in ink.strokes {
            var xs: [Double] = [], ys: [Double] = []
            for (i, point) in stroke.points.enumerated() {
                let x = point.x.inches * scale + offsetX, y = point.y.inches * scale + offsetY
                if let lx = xs.last, let ly = ys.last, i != stroke.points.count - 1 {
                    let (dx, dy) = (x - lx, y - ly)
                    if dx * dx + dy * dy < spacingSquared { continue }
                }
                xs.append(x)
                ys.append(y)
            }
            lines.append(Line(tool: stroke.tool, colour: stroke.colour,
                              width: max(stroke.width.inches * scale, minimumWidth), xs: xs, ys: ys))
        }
        self.lines = lines
    }

    /// How many points the thumbnail draws in all.
    public var pointCount: Int { lines.reduce(0) { $0 + $1.xs.count } }
}
