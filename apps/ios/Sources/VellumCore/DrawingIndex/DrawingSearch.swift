import Foundation

/// How search text is compared (#68): lower case, accents folded, and split into words of letters and digits, so
/// `E-201`, `e201` and `E 201` are the same drawing number, and punctuation never has to be typed.
public enum DrawingSearchText {
    /// The words of `text`, each as UTF-8 bytes.
    public static func words(_ text: String) -> [[UInt8]] {
        var words: [[UInt8]] = []
        var word: [UInt8] = []
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            // The usual case, kept off Foundation: drawing numbers, titles and paths are nearly always ASCII.
            for byte in text.utf8 {
                switch byte {
                case 0x30...0x39, 0x61...0x7A: word.append(byte)
                case 0x41...0x5A: word.append(byte + 0x20)
                default:
                    if !word.isEmpty { words.append(word); word.removeAll(keepingCapacity: true) }
                }
            }
        } else {
            let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            for character in folded {
                if character.isLetter || character.isNumber {
                    word.append(contentsOf: character.utf8)
                } else if !word.isEmpty {
                    words.append(word)
                    word.removeAll(keepingCapacity: true)
                }
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }

    /// The words run together: what a drawing number is compared by.
    public static func compact(_ text: String) -> [UInt8] { words(text).flatMap { $0 } }

    /// The parts of `text` a row highlights for `query`: the start of each word that a query word begins, or the whole
    /// of `text` when `number` is true and its compact form begins with the query's.
    public static func highlights(in text: String, query: String, number: Bool = false) -> [Range<String.Index>] {
        let tokens = words(query)
        guard !tokens.isEmpty else { return [] }
        if number {
            let whole = compact(text)
            let typed = tokens.flatMap { $0 }
            if whole.starts(with: typed) { return [text.startIndex..<text.endIndex] }
        }
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter || text[index].isNumber else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, text[end].isLetter || text[end].isNumber { end = text.index(after: end) }
            let word = words(String(text[index..<end])).first ?? []
            if let longest = tokens.filter({ word.starts(with: $0) }).map(\.count).max() {
                // The token's bytes from the word's start, as characters of the original text.
                var stop = index
                var bytes = 0
                while stop < end, bytes < longest {
                    bytes += words(String(text[stop])).first?.count ?? 0
                    stop = text.index(after: stop)
                }
                ranges.append(index..<stop)
            }
            index = end
        }
        return ranges
    }
}

/// Why a drawing matched a search, best first (#68). Results are ordered by this, then by drawing number in natural
/// order (`E-2` before `E-10`), then by project and path.
public enum DrawingSearchRank: UInt8, Sendable, Comparable {
    /// The drawing number (or its DWG layout's name) is what was typed, punctuation aside.
    case exactNumber = 0
    /// The drawing number (or layout name) starts with what was typed.
    case numberPrefix = 1
    /// Every word typed starts a word of the number, title, project, layout or file name.
    case words = 2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A search's answer: the matching entries, best first, as indexes into the entries the index was built from.
public struct DrawingSearchResult: Sendable, Equatable {
    public let query: String
    public let matches: [Int32]
    /// Entries looked at to answer it; a keystroke that adds to the last query looks only at the last matches.
    public let scanned: Int
}

/// The drawing index made searchable (#68): built once per index generation, off the main thread, as flat arrays of
/// bytes, so a keystroke is one pass over packed memory with no allocation per entry. A query that adds to the last
/// one (typing on) looks only at the last one's matches.
public struct DrawingSearchIndex: Sendable {
    public let count: Int
    /// Every entry's words, deduplicated per entry, packed end to end.
    private let wordBytes: [UInt8]
    private let wordEnds: [Int32]
    /// Entry `e`'s words are `entryWords[e]..<entryWords[e + 1]` in `wordEnds`.
    private let entryWords: [Int32]
    /// Every entry's numbers (drawing number and layout name) in compact form, packed the same way.
    private let numberBytes: [UInt8]
    private let numberEnds: [Int32]
    private let entryNumbers: [Int32]
    /// Each entry's place in natural order, and the entries in that order.
    private let rank: [Int32]
    private let inOrder: [Int32]

    public init(_ entries: [DrawingEntry]) {
        count = entries.count
        var wordBytes: [UInt8] = []
        var wordEnds: [Int32] = []
        var entryWords: [Int32] = [0]
        var numberBytes: [UInt8] = []
        var numberEnds: [Int32] = []
        var entryNumbers: [Int32] = [0]
        var keys: [[UInt8]] = []
        keys.reserveCapacity(entries.count)
        entryWords.reserveCapacity(entries.count + 1)
        entryNumbers.reserveCapacity(entries.count + 1)
        for entry in entries {
            var seen: Set<[UInt8]> = []
            let stem = entry.name.split(separator: ".").dropLast().joined(separator: ".")
            for field in [entry.number, entry.layout, entry.title, entry.project, stem.isEmpty ? entry.name : stem] {
                guard let field else { continue }
                for word in DrawingSearchText.words(field) where seen.insert(word).inserted {
                    wordBytes += word
                    wordEnds.append(Int32(wordBytes.count))
                }
            }
            entryWords.append(Int32(wordEnds.count))
            var numbers: Set<[UInt8]> = []
            for field in [entry.number, entry.layout] {
                guard let field else { continue }
                let compact = DrawingSearchText.compact(field)
                if !compact.isEmpty, numbers.insert(compact).inserted {
                    numberBytes += compact
                    numberEnds.append(Int32(numberBytes.count))
                }
            }
            entryNumbers.append(Int32(numberEnds.count))
            keys.append(Self.orderKey(entry))
        }
        let sorted = (0..<entries.count).sorted { a, b in
            keys[a] == keys[b] ? a < b : keys[a].lexicographicallyPrecedes(keys[b])
        }
        var rank = [Int32](repeating: 0, count: entries.count)
        for (place, entry) in sorted.enumerated() { rank[entry] = Int32(place) }
        self.wordBytes = wordBytes
        self.wordEnds = wordEnds
        self.entryWords = entryWords
        self.numberBytes = numberBytes
        self.numberEnds = numberEnds
        self.entryNumbers = entryNumbers
        self.rank = rank
        inOrder = sorted.map { Int32($0) }
    }

    /// The bytes the search structure holds, for the memory budget.
    public var memoryBytes: Int {
        wordBytes.count + numberBytes.count
            + 4 * (wordEnds.count + entryWords.count + numberEnds.count + entryNumbers.count + rank.count + inOrder.count)
    }

    /// The entries matching `query`, best first. `within`, the last query's matches, narrows the search when `query`
    /// adds to that query (`DrawingSearchIndex.narrows`); an empty query lists every entry in natural order.
    public func search(_ query: String, within: [Int32]? = nil) -> DrawingSearchResult {
        let tokens = DrawingSearchText.words(query)
        guard !tokens.isEmpty else { return DrawingSearchResult(query: query, matches: inOrder, scanned: 0) }
        let typed = tokens.flatMap { $0 }
        var keys: [UInt64] = []
        var scanned = 0
        wordBytes.withUnsafeBufferPointer { words in
            numberBytes.withUnsafeBufferPointer { numbers in
                func look(_ e: Int) {
                    scanned += 1
                    if let found = tier(e, typed: typed, tokens: tokens, words: words, numbers: numbers) {
                        keys.append(UInt64(found.rawValue) << 32 | UInt64(UInt32(rank[e])))
                    }
                }
                if let within {
                    for e in within { look(Int(e)) }
                } else {
                    for e in 0..<count { look(e) }
                }
            }
        }
        keys.sort()
        return DrawingSearchResult(query: query, matches: keys.map { inOrder[Int($0 & 0xFFFF_FFFF)] }, scanned: scanned)
    }

    /// Whether `query`'s matches are all among `previous`'s: true when it is `previous` with more typed on the end,
    /// so every word of `previous` is a word of `query` or the start of one.
    public static func narrows(_ query: String, from previous: String) -> Bool {
        let now = DrawingSearchText.words(query)
        let before = DrawingSearchText.words(previous)
        guard !before.isEmpty, now.count >= before.count else { return false }
        for (i, word) in before.enumerated() {
            if i == before.count - 1 {
                guard now[i].starts(with: word) else { return false }
            } else {
                guard now[i] == word else { return false }
            }
        }
        // A number typed on (`E2` then `E20`) also narrows: the compact query only grew at its end.
        return now.flatMap { $0 }.starts(with: before.flatMap { $0 })
    }

    /// Why entry `e` matches, or nil.
    public func rank(of e: Int, for query: String) -> DrawingSearchRank? {
        let tokens = DrawingSearchText.words(query)
        guard !tokens.isEmpty else { return nil }
        return wordBytes.withUnsafeBufferPointer { words in
            numberBytes.withUnsafeBufferPointer { numbers in
                tier(e, typed: tokens.flatMap { $0 }, tokens: tokens, words: words, numbers: numbers)
            }
        }
    }

    private func tier(_ e: Int, typed: [UInt8], tokens: [[UInt8]], words: UnsafeBufferPointer<UInt8>,
                      numbers: UnsafeBufferPointer<UInt8>) -> DrawingSearchRank? {
        var best: DrawingSearchRank?
        var n = Int(entryNumbers[e])
        while n < Int(entryNumbers[e + 1]) {
            let start = n == 0 ? 0 : Int(numberEnds[n - 1])
            let end = Int(numberEnds[n])
            if Self.starts(numbers, start, end, with: typed) {
                if end - start == typed.count { return .exactNumber }
                best = .numberPrefix
            }
            n += 1
        }
        if best != nil { return best }
        let first = Int(entryWords[e])
        let last = Int(entryWords[e + 1])
        for token in tokens {
            var found = false
            var w = first
            while w < last {
                let start = w == 0 ? 0 : Int(wordEnds[w - 1])
                if Self.starts(words, start, Int(wordEnds[w]), with: token) {
                    found = true
                    break
                }
                w += 1
            }
            if !found { return nil }
        }
        return .words
    }

    @inline(__always)
    private static func starts(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, with prefix: [UInt8])
        -> Bool {
        guard end - start >= prefix.count else { return false }
        var i = 0
        while i < prefix.count {
            if bytes[start + i] != prefix[i] { return false }
            i += 1
        }
        return true
    }

    /// The key entries are ordered by: the drawing number (else the title, else the file name), then the project and
    /// the path, as lower-case words with each run of digits padded to ten, so `E-2` comes before `E-10`.
    static func orderKey(_ entry: DrawingEntry) -> [UInt8] {
        var key: [UInt8] = []
        for field in [entry.number ?? entry.title ?? entry.name, entry.project ?? "", entry.path, entry.layout ?? ""] {
            for word in DrawingSearchText.words(field) {
                var digits: [UInt8] = []
                func flush() {
                    if !digits.isEmpty {
                        key += [UInt8](repeating: 0x30, count: max(0, 10 - digits.count)) + digits
                        digits.removeAll()
                    }
                }
                for byte in word {
                    if (0x30...0x39).contains(byte) {
                        digits.append(byte)
                    } else {
                        flush()
                        key.append(byte)
                    }
                }
                flush()
                key.append(0x20)
            }
            key.append(0x01)
        }
        return key
    }
}
