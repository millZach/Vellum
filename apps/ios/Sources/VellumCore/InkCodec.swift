/// The bytes of Vellum's ink files (ADR-0013): little-endian integers, points as varint steps on the ink grid (exact,
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

    private enum EventTag: UInt8 {
        case draw = 1, erase = 2, undo = 3, redo = 4
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
        }
        guard r.isAtEnd else { throw Malformed(reason: "trailing bytes after an event") }
        return event
    }

    // MARK: Snapshots

    /// A session's ink and undo history, the payload of a snapshot.
    static func encode(_ session: InkSession) -> [UInt8] {
        var w = ByteWriter()
        w.i64(Int64(session.nextID))
        w.u32(UInt32(session.ink.strokes.count))
        for stroke in session.ink.strokes { w.stroke(stroke) }
        for stack in [session.undoStack, session.redoStack] {
            w.u32(UInt32(stack.count))
            for edit in stack { w.edit(edit) }
        }
        return w.bytes
    }

    static func decodeSession(_ payload: ArraySlice<UInt8>) throws -> InkSession {
        var r = ByteReader(payload)
        let nextID = Int(try r.i64())
        let strokeCount = try r.count(each: 14)
        var strokes: [InkStroke] = []
        strokes.reserveCapacity(strokeCount)
        for _ in 0..<strokeCount { strokes.append(try r.stroke()) }
        var stacks: [[InkSession.Edit]] = []
        for _ in 0..<2 {
            let count = try r.count(each: 1)
            var stack: [InkSession.Edit] = []
            stack.reserveCapacity(count)
            for _ in 0..<count { stack.append(try r.edit()) }
            stacks.append(stack)
        }
        guard r.isAtEnd else { throw Malformed(reason: "trailing bytes after a snapshot") }
        return InkSession(ink: Ink(strokes: strokes), undoStack: stacks[0], redoStack: stacks[1], nextID: nextID)
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

    mutating func edit(_ edit: InkSession.Edit) {
        switch edit {
        case .draw(let stroke, let index):
            u8(1)
            u32(UInt32(index))
            self.stroke(stroke)
        case .erase(let removed):
            u8(2)
            u32(UInt32(removed.count))
            for item in removed {
                u32(UInt32(item.index))
                stroke(item.stroke)
            }
        }
    }
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

    mutating func edit() throws -> InkSession.Edit {
        switch try u8() {
        case 1:
            let index = Int(try u32())
            return .draw(try stroke(), index: index)
        case 2:
            let count = try self.count(each: 18)
            var removed: [InkSession.Removal] = []
            for _ in 0..<count {
                let index = Int(try u32())
                removed.append(InkSession.Removal(index: index, stroke: try stroke()))
            }
            return .erase(removed)
        default:
            throw InkCodec.Malformed(reason: "unknown undo step")
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
    /// The ink grid: a stroke's points are kept to the nearest 1/65,536 inch (ADR-0013), about 0.4 micrometres and a
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
