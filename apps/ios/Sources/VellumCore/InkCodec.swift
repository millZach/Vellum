/// The bytes of Vellum's ink files (ADR-0014): little-endian integers, points as varint steps on the ink grid (exact,
/// so a stroke reopens at exactly the real-world position it was drawn at), and records each framed by their length
/// and a CRC-32, so a record cut short by a crash is recognised and dropped.
enum InkCodec {
    struct Malformed: Error, CustomStringConvertible {
        let reason: String
        var description: String { "Malformed ink data: \(reason)" }
    }

    /// A record's frame: its payload's length and CRC-32, 8 bytes, before the payload.
    static let frameSize = 8

    /// Frames a payload as one record.
    static func frame(_ payload: [UInt8], into out: inout [UInt8]) {
        var writer = ByteWriter()
        writer.u32(UInt32(payload.count))
        writer.u32(CRC32.checksum(payload))
        out += writer.bytes
        out += payload
    }

    /// The records in `bytes` from `offset`, up to the first one that is cut short or fails its checksum. Returns the
    /// payloads and where the last whole record ends.
    static func unframe(_ bytes: [UInt8], from offset: Int) -> (payloads: [ArraySlice<UInt8>], end: Int) {
        var payloads: [ArraySlice<UInt8>] = []
        var position = offset
        while bytes.count - position >= frameSize {
            var reader = ByteReader(bytes[position..<(position + frameSize)])
            guard let length = try? reader.u32(), let crc = try? reader.u32() else { break }
            let start = position + frameSize
            guard Int(length) <= bytes.count - start else { break }
            let payload = bytes[start..<(start + Int(length))]
            guard CRC32.checksum(payload) == crc else { break }
            payloads.append(payload)
            position = start + Int(length)
        }
        return (payloads, position)
    }

    // MARK: Events

    /// Each kind of event's code. Codes are never reused: 1 to 4 are version 1's, 5 to 9 came with #7.
    private enum EventTag: UInt8 {
        case draw = 1, erase = 2, undo = 3, redo = 4
        case transform = 5, duplicate = 6, delete = 7, addText = 8, editText = 9
    }

    static func encode(_ event: InkEvent) -> [UInt8] {
        var w = ByteWriter()
        switch event {
        case .draw(let stroke):
            w.u8(EventTag.draw.rawValue)
            w.stroke(stroke)
        case .erase(let ids, let continuing):
            w.u8(EventTag.erase.rawValue)
            w.u8(continuing ? 1 : 0)
            w.u32(UInt32(ids.count))
            for id in ids { w.i64(Int64(id.value)) }
        case .undo:
            w.u8(EventTag.undo.rawValue)
        case .redo:
            w.u8(EventTag.redo.rawValue)
        case .transform(let selection, let transform):
            w.u8(EventTag.transform.rawValue)
            w.selection(selection)
            w.transform(transform)
        case .duplicate(let selection, let transform, let firstStroke, let firstText):
            w.u8(EventTag.duplicate.rawValue)
            w.selection(selection)
            w.transform(transform)
            w.varint(UInt64(max(firstStroke.value, 0)))
            w.varint(UInt64(max(firstText.value, 0)))
        case .delete(let selection):
            w.u8(EventTag.delete.rawValue)
            w.selection(selection)
        case .addText(let box):
            w.u8(EventTag.addText.rawValue)
            w.textBox(box)
        case .editText(let box):
            w.u8(EventTag.editText.rawValue)
            w.textBox(box)
        }
        return w.bytes
    }

    static func decodeEvent(_ payload: ArraySlice<UInt8>) throws -> InkEvent {
        var r = ByteReader(payload)
        guard let tag = EventTag(rawValue: try r.u8()) else { throw Malformed(reason: "unknown event") }
        let event: InkEvent
        switch tag {
        case .draw:
            event = .draw(try r.stroke())
        case .erase:
            let continuing = try r.u8() == 1
            let count = try r.count(each: 8)
            var ids: [StrokeID] = []
            ids.reserveCapacity(count)
            for _ in 0..<count { ids.append(StrokeID(Int(try r.i64()))) }
            event = .erase(ids, continuingSweep: continuing)
        case .undo:
            event = .undo
        case .redo:
            event = .redo
        case .transform:
            event = .transform(try r.selection(), try r.transform())
        case .duplicate:
            let selection = try r.selection()
            let transform = try r.transform()
            let firstStroke = StrokeID(Int(clamping: try r.varint()))
            let firstText = TextBoxID(Int(clamping: try r.varint()))
            event = .duplicate(selection, transform, firstStroke: firstStroke, firstText: firstText)
        case .delete:
            event = .delete(try r.selection())
        case .addText:
            event = .addText(try r.textBox())
        case .editText:
            event = .editText(try r.textBox())
        }
        guard r.isAtEnd else { throw Malformed(reason: "trailing bytes after an event") }
        return event
    }

    // MARK: Snapshots

    /// A session's ink, text boxes and undo history, the payload of a snapshot: the next stroke id, the strokes, the
    /// undo and redo steps, then, in version 2 and only on a canvas that has ever had a text box, the next text box id
    /// and the text boxes. A canvas of ink alone is written exactly as version 1 wrote it, byte for byte.
    static func encode(_ session: InkSession) -> [UInt8] {
        var w = ByteWriter()
        w.i64(Int64(session.nextID))
        w.u32(UInt32(session.ink.strokes.count))
        for stroke in session.ink.strokes { w.stroke(stroke) }
        for stack in [session.undoStack, session.redoStack] {
            w.u32(UInt32(stack.count))
            for edit in stack { w.edit(edit, on: session.ink) }
        }
        if session.nextTextID > 1 || !session.texts.isEmpty {
            w.varint(UInt64(max(session.nextTextID, 1)))
            w.u32(UInt32(session.texts.count))
            for box in session.texts { w.textBox(box) }
        }
        return w.bytes
    }

    /// A snapshot's payload, in the version its header gives.
    static func decodeSession(_ payload: ArraySlice<UInt8>, version: UInt16 = InkStore.version) throws -> InkSession {
        var r = ByteReader(payload)
        let nextID = Int(try r.i64())
        let strokeCount = try r.count(each: 14)
        var strokes: [InkStroke] = []
        strokes.reserveCapacity(strokeCount)
        for _ in 0..<strokeCount { strokes.append(try r.stroke()) }
        var stacks: [[InkSession.Edit]] = []
        let ink = Ink(strokes: strokes)
        for _ in 0..<2 {
            let count = try r.count(each: 1)
            var stack: [InkSession.Edit] = []
            stack.reserveCapacity(count)
            for _ in 0..<count { stack.append(try r.edit(on: ink)) }
            stacks.append(stack)
        }
        var nextTextID = 1
        var texts: [TextBox] = []
        if version >= 2, !r.isAtEnd {
            nextTextID = Int(clamping: try r.varint())
            let textCount = try r.count(each: 43)
            texts.reserveCapacity(textCount)
            for _ in 0..<textCount { texts.append(try r.textBox()) }
        }
        guard r.isAtEnd else { throw Malformed(reason: "trailing bytes after a snapshot") }
        return InkSession(ink: ink, texts: texts, undoStack: stacks[0], redoStack: stacks[1], nextID: nextID,
                          nextTextID: nextTextID)
    }
}

// MARK: - Bytes

struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func i64(_ value: Int64) { u64(UInt64(bitPattern: value)) }
    mutating func f64(_ value: Double) { u64(value.bitPattern) }

    mutating func raw(_ value: [UInt8]) { bytes += value }

    /// An unsigned LEB128 varint: 7 bits a byte, low bits first.
    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    /// A signed varint, zigzag-encoded so small negative numbers stay short.
    mutating func signedVarint(_ value: Int64) {
        varint(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    /// id, pen, markup colour, width, then the points on the ink grid (`CanvasPoint.gridUnitsPerInch`): the first as
    /// whole grid units, every other as its step from the one before, all as varints. A Pencil stroke's samples are a
    /// fraction of an inch to a few feet apart, so a point usually takes 4 to 6 bytes.
    mutating func stroke(_ stroke: InkStroke) {
        varint(UInt64(max(stroke.id.value, 0)))
        u8(InkCodecTables.toolCode(stroke.tool))
        u8(InkCodecTables.colourCode(stroke.colour))
        f64(stroke.width.inches)
        varint(UInt64(stroke.points.count))
        bytes.reserveCapacity(bytes.count + stroke.points.count * 6)
        var lastX: Int64 = 0, lastY: Int64 = 0
        for point in stroke.points {
            let x = CanvasPoint.gridUnits(point.x), y = CanvasPoint.gridUnits(point.y)
            signedVarint(x &- lastX)
            signedVarint(y &- lastY)
            lastX = x
            lastY = y
        }
    }

    /// An undo or redo step. A stroke the step names that is on the canvas exactly as the step holds it is written as
    /// its id, since the snapshot already holds it; strokes the history alone holds (erased, undone, or as they were
    /// before a move) are written whole. Text boxes are always written whole.
    mutating func edit(_ edit: InkSession.Edit, on ink: Ink) {
        switch edit {
        case .draw(let stroke):
            u8(EditTag.draw.rawValue)
            historyStroke(stroke, on: ink)
        case .erase(let strokes):
            u8(EditTag.erase.rawValue)
            historyStrokes(strokes, on: ink)
        case .transform(let strokes, let boxes, let transform):
            u8(EditTag.transform.rawValue)
            historyStrokes(strokes, on: ink)
            textBoxes(boxes)
            self.transform(transform)
        case .duplicate(let strokes, let boxes, let sources):
            u8(EditTag.duplicate.rawValue)
            historyStrokes(strokes, on: ink)
            textBoxes(boxes)
            selection(sources)
        case .delete(let strokes, let boxes):
            u8(EditTag.delete.rawValue)
            historyStrokes(strokes, on: ink)
            textBoxes(boxes)
        case .addText(let box):
            u8(EditTag.addText.rawValue)
            textBox(box)
        case .editText(let before, let after):
            u8(EditTag.editText.rawValue)
            textBox(before)
            textBox(after)
        }
    }

    private mutating func historyStrokes(_ strokes: [InkStroke], on ink: Ink) {
        u32(UInt32(strokes.count))
        for item in strokes { historyStroke(item, on: ink) }
    }

    private mutating func textBoxes(_ boxes: [TextBox]) {
        u32(UInt32(boxes.count))
        for box in boxes { textBox(box) }
    }

    /// A selection: its stroke ids, then its text box ids, each as a varint count, the first id, and every later id
    /// as its step from the one before. A selection is in ascending order, so a run of strokes drawn one after
    /// another takes a byte an id.
    mutating func selection(_ selection: CanvasSelection) {
        ids(selection.strokes.map(\.value))
        ids(selection.texts.map(\.value))
    }

    private mutating func ids(_ values: [Int]) {
        varint(UInt64(values.count))
        var last = 0
        for value in values {
            varint(UInt64(max(value - last, 0)))
            last = value
        }
    }

    /// A transform: its scale, then its offset in inches, as 64-bit floats.
    mutating func transform(_ transform: CanvasTransform) {
        f64(transform.scale)
        f64(transform.dx.inches)
        f64(transform.dy.inches)
    }

    /// A text box: id, corner and size in inches, letter height, markup colour, then its text as UTF-8.
    mutating func textBox(_ box: TextBox) {
        varint(UInt64(max(box.id.value, 0)))
        f64(box.origin.x.inches)
        f64(box.origin.y.inches)
        f64(box.size.width.inches)
        f64(box.size.height.inches)
        f64(box.fontSize.inches)
        u8(InkCodecTables.colourCode(box.colour))
        let utf8 = Array(box.text.utf8)
        varint(UInt64(utf8.count))
        raw(utf8)
    }

    private mutating func historyStroke(_ stroke: InkStroke, on ink: Ink) {
        // A moved stroke keeps its id, so the id alone says nothing: only the very stroke on the canvas goes by id.
        if let index = ink.index(of: stroke.id), ink.strokes[index] == stroke {
            u8(1)
            varint(UInt64(max(stroke.id.value, 0)))
        } else {
            u8(0)
            self.stroke(stroke)
        }
    }
}

/// How an undo or redo step is stored in a snapshot. Each stroke it names follows as 1 and its id when the stroke is
/// on the canvas, or 0 and the whole stroke when only the history holds it.
enum EditTag: UInt8 {
    case draw = 1
    case erase = 2
    case transform = 3
    case duplicate = 4
    case delete = 5
    case addText = 6
    case editText = 7
}

struct ByteReader {
    private let bytes: ArraySlice<UInt8>
    private var position: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        position = bytes.startIndex
    }

    var isAtEnd: Bool { position == bytes.endIndex }
    private var remaining: Int { bytes.endIndex - position }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count <= remaining else { throw InkCodec.Malformed(reason: "cut short") }
        defer { position += count }
        return bytes[position..<(position + count)]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }

    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        return UInt32(littleEndian: b.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }

    mutating func u64() throws -> UInt64 {
        let b = try take(8)
        return UInt64(littleEndian: b.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
    }

    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    mutating func raw(_ count: Int) throws -> [UInt8] { Array(try take(count)) }

    /// A count of items each at least `each` bytes long, refused when the bytes left could not hold that many, so a
    /// damaged count never asks for a huge allocation.
    mutating func count(each: Int) throws -> Int {
        let count = Int(try u32())
        guard count <= remaining / max(each, 1) else { throw InkCodec.Malformed(reason: "count past the end") }
        return count
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try u8()
            guard shift < 64 else { throw InkCodec.Malformed(reason: "varint too long") }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    mutating func signedVarint() throws -> Int64 {
        let raw = try varint()
        return Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
    }

    /// A varint count of items each at least `each` bytes long, refused when the bytes left could not hold them.
    mutating func varintCount(each: Int) throws -> Int {
        let raw = try varint()
        guard raw <= UInt64(remaining / max(each, 1)) else { throw InkCodec.Malformed(reason: "count past the end") }
        return Int(raw)
    }

    mutating func stroke() throws -> InkStroke {
        let id = StrokeID(Int(clamping: try varint()))
        guard let tool = InkCodecTables.tool(try u8()) else { throw InkCodec.Malformed(reason: "unknown pen") }
        guard let colour = InkCodecTables.colour(try u8()) else { throw InkCodec.Malformed(reason: "unknown colour") }
        let width = Length(inches: try f64())
        let count = try varintCount(each: 2)
        var points: [CanvasPoint] = []
        points.reserveCapacity(count)
        var x: Int64 = 0, y: Int64 = 0
        for _ in 0..<count {
            x &+= try signedVarint()
            y &+= try signedVarint()
            points.append(CanvasPoint(x: CanvasPoint.length(gridUnits: x), y: CanvasPoint.length(gridUnits: y)))
        }
        return InkStroke(id: id, tool: tool, colour: colour, width: width, points: points)
    }

    mutating func edit(on ink: Ink) throws -> InkSession.Edit {
        switch EditTag(rawValue: try u8()) {
        case .draw:
            return .draw(try historyStroke(on: ink))
        case .erase:
            return .erase(try historyStrokes(on: ink))
        case .transform:
            let strokes = try historyStrokes(on: ink)
            let boxes = try textBoxes()
            return .transform(strokes, boxes, try transform())
        case .duplicate:
            let strokes = try historyStrokes(on: ink)
            let boxes = try textBoxes()
            return .duplicate(strokes, boxes, sources: try selection())
        case .delete:
            let strokes = try historyStrokes(on: ink)
            return .delete(strokes, try textBoxes())
        case .addText:
            return .addText(try textBox())
        case .editText:
            let before = try textBox()
            return .editText(before: before, after: try textBox())
        case nil:
            throw InkCodec.Malformed(reason: "unknown undo step")
        }
    }

    private mutating func historyStrokes(on ink: Ink) throws -> [InkStroke] {
        let count = try self.count(each: 2)
        var strokes: [InkStroke] = []
        strokes.reserveCapacity(count)
        for _ in 0..<count { strokes.append(try historyStroke(on: ink)) }
        return strokes
    }

    private mutating func textBoxes() throws -> [TextBox] {
        let count = try self.count(each: 43)
        var boxes: [TextBox] = []
        boxes.reserveCapacity(count)
        for _ in 0..<count { boxes.append(try textBox()) }
        return boxes
    }

    mutating func selection() throws -> CanvasSelection {
        let strokes = try ids().map(StrokeID.init)
        let texts = try ids().map(TextBoxID.init)
        return CanvasSelection(strokes: strokes, texts: texts)
    }

    private mutating func ids() throws -> [Int] {
        let count = try varintCount(each: 1)
        var values: [Int] = []
        values.reserveCapacity(count)
        var last = 0
        for _ in 0..<count {
            last = last.addingReportingOverflow(Int(clamping: try varint())).partialValue
            values.append(last)
        }
        return values
    }

    mutating func transform() throws -> CanvasTransform {
        let scale = try f64(), dx = try f64(), dy = try f64()
        guard scale.isFinite, scale > 0, dx.isFinite, dy.isFinite else {
            throw InkCodec.Malformed(reason: "a transform that is not a finite move and resize")
        }
        return CanvasTransform(scale: scale, dx: .inches(dx), dy: .inches(dy))
    }

    /// The text box's fixed part is 42 bytes and its text at least one more for the length, so a damaged count is
    /// caught by `count(each: 43)`.
    mutating func textBox() throws -> TextBox {
        let id = TextBoxID(Int(clamping: try varint()))
        let x = try f64(), y = try f64(), width = try f64(), height = try f64(), fontSize = try f64()
        guard let colour = InkCodecTables.colour(try u8()) else { throw InkCodec.Malformed(reason: "unknown colour") }
        let length = try varintCount(each: 1)
        let text = String(decoding: try raw(length), as: UTF8.self)
        return TextBox(id: id, origin: CanvasPoint(x: .inches(x), y: .inches(y)),
                       size: CanvasSize(width: .inches(width), height: .inches(height)), fontSize: .inches(fontSize),
                       colour: colour, text: text)
    }

    private mutating func historyStroke(on ink: Ink) throws -> InkStroke {
        switch try u8() {
        case 0:
            return try stroke()
        case 1:
            let id = StrokeID(Int(try varint()))
            guard let index = ink.index(of: id) else {
                throw InkCodec.Malformed(reason: "an undo step names \(id), which is not on the canvas")
            }
            return ink.strokes[index]
        default:
            throw InkCodec.Malformed(reason: "unknown stroke reference")
        }
    }
}

/// The codes pens and markup colours are stored as. They are fixed: a new pen or colour gets a new code, and a code is
/// never reused.
enum InkCodecTables {
    static func toolCode(_ tool: InkTool) -> UInt8 {
        switch tool {
        case .pen: 1
        case .highlighter: 2
        }
    }

    static func tool(_ code: UInt8) -> InkTool? {
        switch code {
        case 1: .pen
        case 2: .highlighter
        default: nil
        }
    }

    static func colourCode(_ colour: MarkupColour) -> UInt8 {
        switch colour {
        case .red: 1
        case .green: 2
        case .blue: 3
        case .sketch: 4
        }
    }

    static func colour(_ code: UInt8) -> MarkupColour? {
        switch code {
        case 1: .red
        case 2: .green
        case 3: .blue
        case 4: .sketch
        default: nil
        }
    }
}

/// CRC-32 (IEEE 802.3, the zlib and PNG checksum).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { table in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension CanvasPoint {
    /// The ink grid: a stroke's points are kept to the nearest 1/65,536 inch (ADR-0014), about 0.4 micrometres and a
    /// hundredth of a point at the canvas's closest zoom. A grid point is exactly representable as a `Double` and as an
    /// integer, so ink saves and reopens without drift and its points are stored as small integer steps.
    public static let gridUnitsPerInch = 65_536.0

    /// The largest coordinate kept, in grid units: 2^50, about 270,000 miles, inside `Double`'s exact integers.
    static let gridLimit = Double(1 << 50)

    /// The point moved to the nearest point on the ink grid.
    public var onInkGrid: CanvasPoint {
        CanvasPoint(x: Self.length(gridUnits: Self.gridUnits(x)), y: Self.length(gridUnits: Self.gridUnits(y)))
    }

    static func gridUnits(_ length: Length) -> Int64 {
        let units = (length.inches * gridUnitsPerInch).rounded()
        guard units.isFinite else { return 0 }
        return Int64(min(max(units, -gridLimit), gridLimit))
    }

    static func length(gridUnits: Int64) -> Length { .inches(Double(gridUnits) / gridUnitsPerInch) }
}
