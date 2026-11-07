import Foundation

/// The bytes of one symbol's file, `<id>.vsym` (ADR-0016): small JSON a person or the laptop can read and write, kept
/// on the Duo and mirrored to `Dropbox/Vellum/Symbols`. The keys are sorted and every number written exactly (the
/// shortest digits that read back as the same number), so a symbol reads back exactly, and the same symbol always has
/// the same bytes: a sync compares files by their content hash alone.
///
/// ```json
/// {"format":1,"id":"…","name":"Y-strainer","printedSize":0.5,"tagLetters":"FT",
///  "parts":[{"line":[[-0.5,0],[0.5,0]]},{"circle":[0,0,0.5]},{"arc":[0,-0.55,0.28,3.14159,6.28318]},
///           {"text":[0,0,0.3],"letters":"JB"},{"tag":[0,0,0.24]}]}
/// ```
///
/// Coordinates are in units of the symbol's width, centred on (0, 0), y running down. `printedSize` is in printed
/// inches. A text part may carry `"box":[width,height]`, its text box's size when it was saved from one.
public enum SymbolFile {
    /// The format this Vellum writes, and the newest it reads.
    public static let format = 1
    /// A symbol file's extension.
    public static let fileExtension = "vsym"

    public struct Malformed: Error, CustomStringConvertible {
        public let reason: String
        public var description: String { "Malformed symbol file: \(reason)" }
    }

    /// A saved symbol's file name: its id and the extension.
    public static func fileName(for id: String) -> String { "\(id).\(fileExtension)" }

    /// The id a file name holds, or nil when it isn't a symbol file's name.
    public static func id(fromFileName name: String) -> String? {
        let suffix = "." + fileExtension
        guard name.lowercased().hasSuffix(suffix), name.count > suffix.count else { return nil }
        let id = String(name.dropLast(suffix.count))
        guard !id.hasPrefix("."), !id.contains("/") else { return nil }
        return id
    }

    public static func encode(_ symbol: Symbol) -> [UInt8] {
        let file = Contents(format: format, id: symbol.id, name: symbol.name, printedSize: symbol.printedSize.inches,
                            tagLetters: symbol.tagLetters, parts: symbol.parts.map(Part.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array((try? encoder.encode(file)) ?? Data())
    }

    /// The symbol in a file's bytes. `fileID`, from the file's name, wins over the id inside, so a file the laptop
    /// copied under a new name is a new symbol rather than a second copy of one.
    public static func decode(_ bytes: [UInt8], fileID: String? = nil) throws -> Symbol {
        let file: Contents
        do {
            file = try JSONDecoder().decode(Contents.self, from: Data(bytes))
        } catch {
            throw Malformed(reason: "not a symbol's JSON")
        }
        guard file.format <= format else { throw Malformed(reason: "format \(file.format), newer than this Vellum") }
        guard file.printedSize.isFinite, file.printedSize > 0 else { throw Malformed(reason: "no printed size") }
        let parts = try file.parts.map { try $0.symbolPart() }
        guard !parts.isEmpty else { throw Malformed(reason: "nothing to draw") }
        let name = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Symbol(id: fileID ?? file.id, name: name.isEmpty ? "Symbol" : name,
                      printedSize: .inches(file.printedSize), tagLetters: file.tagLetters, parts: parts)
    }

    // MARK: The JSON

    private struct Contents: Codable {
        var format: Int
        var id: String
        var name: String
        var printedSize: Double
        var tagLetters: String?
        var parts: [Part]
    }

    /// One part: exactly one of its keys is set.
    private struct Part: Codable {
        var line: [[Double]]?
        var circle: [Double]?
        var arc: [Double]?
        var text: [Double]?
        var letters: String?
        var box: [Double]?
        var tag: [Double]?

        init(_ part: SymbolPart) {
            switch part {
            case .line(let points): line = points.map { [$0.x, $0.y] }
            case .circle(let c, let r): circle = [c.x, c.y, r]
            case .arc(let c, let r, let start, let end): arc = [c.x, c.y, r, start, end]
            case .text(let c, let h, let text, let w, let bh):
                self.text = [c.x, c.y, h]
                letters = text
                if let w, let bh { box = [w, bh] }
            case .tag(let c, let h): tag = [c.x, c.y, h]
            }
        }

        func symbolPart() throws -> SymbolPart {
            func numbers(_ values: [Double]?, _ count: Int) throws -> [Double] {
                guard let values, values.count == count, values.allSatisfy(\.isFinite) else {
                    throw Malformed(reason: "a part's numbers")
                }
                return values
            }
            if let line {
                guard !line.isEmpty, line.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
                    throw Malformed(reason: "a line's points")
                }
                return .line(line.map { SymbolPoint($0[0], $0[1]) })
            }
            if circle != nil {
                let v = try numbers(circle, 3)
                guard v[2] > 0 else { throw Malformed(reason: "a circle's radius") }
                return .circle(centre: SymbolPoint(v[0], v[1]), radius: v[2])
            }
            if arc != nil {
                let v = try numbers(arc, 5)
                guard v[2] > 0 else { throw Malformed(reason: "an arc's radius") }
                return .arc(centre: SymbolPoint(v[0], v[1]), radius: v[2], start: v[3], end: v[4])
            }
            if text != nil {
                let v = try numbers(text, 3)
                guard v[2] > 0, let letters, !letters.isEmpty else { throw Malformed(reason: "a text part") }
                let b = box == nil ? nil : try numbers(box, 2)
                return .text(centre: SymbolPoint(v[0], v[1]), height: v[2], text: letters, width: b?[0],
                             boxHeight: b?[1])
            }
            if tag != nil {
                let v = try numbers(tag, 3)
                guard v[2] > 0 else { throw Malformed(reason: "a tag's height") }
                return .tag(centre: SymbolPoint(v[0], v[1]), height: v[2])
            }
            throw Malformed(reason: "a part of no known kind")
        }
    }
}
