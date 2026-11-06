/// What a tap with Select picks up (#64, CONTEXT.md "Select"): the one thing under the tap, the topmost first. Text
/// boxes lie over dimensions and frames, which lie over ink, which lies over the placed sheets, so where ink lies over a
/// sheet the tap picks the ink, and only bare paper picks the sheet. Among things of one kind the latest is on top.
///
/// A stroke is hit within `reach` screen points of its ink, a dimension within `reach` of its dimension line or on the box
/// its length sits in, a frame within `reach` of its dashed edge, a text box anywhere on it or within `boxSlack` of it,
/// and a sheet anywhere on its paper. The reach is in screen points, so a thin line can be tapped at any zoom.
///
/// The test runs once a tap, never per Pencil sample. Strokes are found through the `InkIndex` and sheets through the
/// `SheetIndex`, so it looks only at what lies near the tap, never at every stroke on the canvas; the text boxes,
/// dimensions and frames, which a canvas holds by the dozen, are read as the lasso reads them.
public enum SelectTap {
    /// How near a stroke, a dimension line or a frame's edge a tap must land, in screen points.
    public static let reach = 10.0
    /// How far outside a text box or a dimension's length a tap still picks it, in screen points.
    public static let boxSlack = 4.0

    /// The one thing a tap picks.
    public enum Pick: Hashable, Sendable {
        case stroke(StrokeID)
        case text(TextBoxID)
        case dimension(DimensionID)
        case frame(FrameID)
        case sheet(SheetID)
    }

    /// What a tap at a canvas point picks at a zoom of `pointsPerInch` screen points to the canvas inch; nil on empty
    /// canvas. What it looked at is counted in `work`.
    public static func pick(at point: CanvasPoint, pointsPerInch: Double, ink: InkIndex, texts: [TextBox],
                            dimensions: [CanvasDimension], frames: [Frame], sheets: SheetIndex,
                            work: inout InkIndex.Work) -> Pick? {
        guard pointsPerInch > 0, pointsPerInch.isFinite else { return nil }
        let x = point.x.inches, y = point.y.inches
        let reach = Self.reach / pointsPerInch, slack = Self.boxSlack / pointsPerInch
        for box in texts.reversed() where InkIndex.Box(box.rect).grown(by: slack).holds(x, y) {
            return .text(box.id)
        }
        for dimension in dimensions.reversed() where hits(dimension, x, y, reach: reach, slack: slack) {
            return .dimension(dimension.id)
        }
        for frame in frames.reversed() where onEdge(InkIndex.Box(frame.bounds), x, y, reach: reach) {
            return .frame(frame.id)
        }
        if let stroke = ink.strokes(hitAt: point, tolerance: .inches(reach), work: &work).first {
            return .stroke(stroke.id)
        }
        if let sheet = sheets.sheet(at: point, work: &work) { return .sheet(sheet.id) }
        return nil
    }

    public static func pick(at point: CanvasPoint, pointsPerInch: Double, ink: InkIndex, texts: [TextBox] = [],
                            dimensions: [CanvasDimension] = [], frames: [Frame] = [],
                            sheets: SheetIndex = SheetIndex()) -> Pick? {
        var work = InkIndex.Work()
        return pick(at: point, pointsPerInch: pointsPerInch, ink: ink, texts: texts, dimensions: dimensions,
                    frames: frames, sheets: sheets, work: &work)
    }

    /// The selection after a tap that picked `pick`, given what was selected:
    ///
    /// - on empty canvas (nil), nothing: the tap lets go of everything;
    /// - on a sheet, that sheet alone, as a lasso tap picks one up, so its strip turns, moves and rescales it;
    /// - on a stroke, text box, dimension or frame already selected, the selection as it was, left to be dragged;
    /// - on another one, the selection with it added; but a sheet is selected alone, so with a sheet selected the tap
    ///   lets go of it and selects the thing alone.
    ///
    /// `onSelection` says the tap landed inside the selection's dashed box: there a tap on nothing, or on the paper of a
    /// sheet under it, is a tap on the selection and keeps it.
    public static func selection(after pick: Pick?, given current: CanvasSelection,
                                 onSelection: Bool = false) -> CanvasSelection {
        if onSelection, current.sheet == nil, !current.isEmpty {
            switch pick {
            case nil, .sheet?: return current
            default: break
            }
        }
        guard let pick else { return .empty }
        if case .sheet(let id) = pick { return CanvasSelection(sheet: id) }
        if current.sheet != nil { return CanvasSelection(pick) }
        if current.contains(pick) { return current }
        return current.adding(pick)
    }

    /// Whether a point is within `reach` of a dimension's line, or on the box its length sits in: centred on the middle of
    /// the line, three text heights each way across and one and a half up and down, which takes in the length drawn just
    /// above a level line or on a steep one, grown by `slack`.
    static func hits(_ dimension: CanvasDimension, _ x: Double, _ y: Double, reach: Double, slack: Double) -> Bool {
        let (a, b) = dimension.line
        if distanceSquared(x, y, a.x.inches, a.y.inches, b.x.inches, b.y.inches) <= reach * reach { return true }
        let text = dimension.textPosition, height = dimension.textHeight.inches
        return InkIndex.Box(minX: text.x.inches - height * 3, minY: text.y.inches - height * 1.5,
                            maxX: text.x.inches + height * 3, maxY: text.y.inches + height * 1.5)
            .grown(by: slack).holds(x, y)
    }

    /// Whether a point is within `reach` of a rectangle's edge, inside it or out.
    static func onEdge(_ box: InkIndex.Box, _ x: Double, _ y: Double, reach: Double) -> Bool {
        // The box shrunk by `reach` turns inside out on a frame smaller than two reaches, which holds nothing: all of
        // such a frame is near its edge.
        box.grown(by: reach).holds(x, y) && !box.grown(by: -reach).holds(x, y)
    }

    /// The squared distance from a point to the segment from (ax, ay) to (bx, by).
    static func distanceSquared(_ x: Double, _ y: Double, _ ax: Double, _ ay: Double, _ bx: Double,
                                _ by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        var t = lengthSquared == 0 ? 0 : ((x - ax) * dx + (y - ay) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        let cx = ax + t * dx - x, cy = ay + t * dy - y
        return cx * cx + cy * cy
    }
}

extension InkIndex.Box {
    /// Whether a point is inside the box or on its edge.
    func holds(_ x: Double, _ y: Double) -> Bool { x >= minX && x <= maxX && y >= minY && y <= maxY }
}

extension CanvasSelection {
    /// A selection of the one thing a tap picked.
    public init(_ pick: SelectTap.Pick) {
        switch pick {
        case .stroke(let id): self.init(strokes: [id])
        case .text(let id): self.init(texts: [id])
        case .dimension(let id): self.init(dimensions: [id])
        case .frame(let id): self.init(frames: [id])
        case .sheet(let id): self.init(sheet: id)
        }
    }

    /// Whether the selection holds what a tap picked.
    public func contains(_ pick: SelectTap.Pick) -> Bool {
        switch pick {
        case .stroke(let id): strokes.contains(id)
        case .text(let id): texts.contains(id)
        case .dimension(let id): dimensions.contains(id)
        case .frame(let id): frames.contains(id)
        case .sheet(let id): sheet == id
        }
    }

    /// The selection with what a tap picked added. A sheet is selected alone, so adding one gives that sheet.
    public func adding(_ pick: SelectTap.Pick) -> CanvasSelection {
        switch pick {
        case .stroke(let id): CanvasSelection(strokes: strokes + [id], texts: texts, dimensions: dimensions, frames: frames)
        case .text(let id): CanvasSelection(strokes: strokes, texts: texts + [id], dimensions: dimensions, frames: frames)
        case .dimension(let id):
            CanvasSelection(strokes: strokes, texts: texts, dimensions: dimensions + [id], frames: frames)
        case .frame(let id): CanvasSelection(strokes: strokes, texts: texts, dimensions: dimensions, frames: frames + [id])
        case .sheet(let id): CanvasSelection(sheet: id)
        }
    }
}
