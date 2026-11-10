import Foundation
import XCTest
@testable import VellumCore
#if canImport(Darwin)
import Darwin
#endif

/// The drawing search on a made-up index of 20,000 drawings (#68, docs/perf/baselines/drawing-index.json): its memory
/// and the work a keystroke does are budgets checked on every run; its timings are measured in CI's optimised run
/// (`VELLUM_PERF_OUT` set, `swift test -c release`) and compared by perf-compare.py.
final class DrawingSearchTimingTests: XCTestCase {
    static let size = 20_000
    /// What the timings type, a keystroke at a time: a title, a drawing number and a project.
    static let typed = ["pump house", "E-123", "made-up project 042"]

    func testTheSearchOfTwentyThousandDrawingsStaysInItsBudgets() {
        let entries = MadeUpDrawingIndex.shards(count: Self.size).flatMap(\.drawings)
        XCTAssertEqual(entries.count, Self.size)
        let index = DrawingSearchIndex(entries)
        IndexBudget.check("search_index_bytes_20000", index.memoryBytes)
        IndexBudget.check("index_copy_bytes_20000", Self.estimatedBytes(entries))
        for text in Self.typed {
            var scanned = 0
            var last: DrawingSearchResult?
            for query in Self.keystrokes(text) {
                let result = Self.search(index, query, after: last)
                scanned += result.scanned
                last = result
            }
            IndexBudget.check("search_entries_scanned_typing_" + Self.slug(text), scanned)
        }
    }

    func testTimings() throws {
        guard let out = ProcessInfo.processInfo.environment["VELLUM_PERF_OUT"] else {
            throw XCTSkip("Timings run in CI's optimised run, with VELLUM_PERF_OUT set")
        }
        let shards = MadeUpDrawingIndex.shards(count: Self.size)
        let bytes = shards.map(MadeUpDrawingIndex.bytes(of:))
        let before = Self.residentBytes()

        // Loading the copy: every shard read, then the search built, as the app does once per generation.
        var started = Date()
        var entries: [DrawingEntry] = []
        for shard in bytes { entries += try DrawingIndexFormat.shard(from: shard).drawings }
        let decoded = Date().timeIntervalSince(started) * 1000
        started = Date()
        let index = DrawingSearchIndex(entries)
        let built = Date().timeIntervalSince(started) * 1000
        let resident = Double(Self.residentBytes() - before) / 1_048_576

        var keystrokes: [Double] = []
        for text in Self.typed {
            var last: DrawingSearchResult?
            for query in Self.keystrokes(text) {
                let start = Date()
                last = Self.search(index, query, after: last)
                keystrokes.append(Date().timeIntervalSince(start) * 1000)
            }
        }
        started = Date()
        let everything = index.search("plan")
        let fullScan = Date().timeIntervalSince(started) * 1000
        XCTAssertGreaterThan(everything.matches.count, 0)
        keystrokes.sort()
        let measurements: [(String, Double)] = [
            ("index_load_20000_ms", decoded + built),
            ("index_decode_20000_ms", decoded),
            ("search_build_20000_ms", built),
            ("search_keystroke_p50_ms", keystrokes[keystrokes.count / 2]),
            ("search_keystroke_max_ms", keystrokes.last ?? 0),
            ("search_full_scan_ms", fullScan),
            ("index_resident_20000_mb", resident),
        ]
        for (metric, value) in measurements { print("PERF drawing-index \(metric)=\(String(format: "%.2f", value))") }
        // The index download's timings (#98) go in the same file.
        try PerfOut.append(measurements, to: out)
        withExtendedLifetime((entries, index)) {}
    }

    /// The queries typing `text` makes, one per keystroke.
    static func keystrokes(_ text: String) -> [String] {
        (1...text.count).map { String(text.prefix($0)) }
    }

    /// One keystroke's search, as the app makes it (`DrawingSearchIndex.keystroke`).
    static func search(_ index: DrawingSearchIndex, _ query: String, after last: DrawingSearchResult?)
        -> DrawingSearchResult {
        index.keystroke(query, after: last)
    }

    static func slug(_ text: String) -> String {
        DrawingSearchText.words(text).map { String(decoding: $0, as: UTF8.self) }.joined(separator: "_")
    }

    /// What the copy's entries hold in memory, estimated: each entry's own size and the bytes of every string longer
    /// than Swift keeps inline (15 UTF-8 bytes).
    static func estimatedBytes(_ entries: [DrawingEntry]) -> Int {
        func text(_ s: String?) -> Int {
            guard let s, s.utf8.count > 15 else { return 0 }
            return s.utf8.count
        }
        var total = entries.count * MemoryLayout<DrawingEntry>.stride
        for e in entries {
            total += [e.id, e.path, e.name, e.layout, e.folder, e.project, e.projectPath, e.number, e.title, e.revision,
                      e.scale, e.date, e.fieldsFrom, e.pairedBy, e.thumbnail].map(text).reduce(0, +)
            total += text(e.dwg?.path) + text(e.dwg?.modified)
            total += text(e.pdf?.path) + text(e.pdf?.modified) + text(e.pdf?.contentHash)
            total += (e.otherPdfs ?? []).map(text).reduce(0, +)
        }
        return total
    }

    static func residentBytes() -> Int {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task_self_trap(), task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
        #else
        return 0
        #endif
    }
}
