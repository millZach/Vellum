import Foundation

/// The Duo's plot requests (#70): those still open, in the sync outbox until they are in Dropbox and then watched until
/// the laptop's final answer is read and the request deleted; and, per drawing index entry, the plot the Duo has kept
/// until the index lists it, or the laptop's reason for not plotting it. Kept in one small JSON file in Application
/// Support (`PlotLedgerFile`), not Caches, so a request asked offline survives a crash or a relaunch (ADR-0010). It holds
/// request ids, entry ids, DWG paths and layout names, never a token or a drawing.
public struct PlotLedger: Codable, Hashable, Sendable {
    public static let currentFormat = 1

    public var format = PlotLedger.currentFormat
    /// Open requests, oldest first.
    public var open: [OpenPlot] = []
    /// By entry id: the plot the Duo has on it, until the index lists the entry's PDF.
    public var plotted: [String: PlottedPDF] = [:]
    /// By entry id: why the laptop wouldn't plot it, until Zach asks again.
    public var failed: [String: String] = [:]

    public init() {}
}

/// One request the Duo wrote and hasn't finished with.
public struct OpenPlot: Codable, Hashable, Sendable {
    public var request: PlotRequest
    /// When it went to Dropbox; nil while it waits in the outbox.
    public var sent: Date?
    /// The laptop's latest answer read.
    public var answer: PlotAnswer?
    /// On `done`: the name its PDF is kept under in `SheetPDFs`, once it is down.
    public var keptName: String?

    public init(request: PlotRequest) { self.request = request }

    /// Asking again while this is open reuses it: anything but a `failed` answer.
    public var reusable: Bool { answer?.state != .failed }
}

/// A plot on the Duo, from the laptop's `done` answer.
public struct PlottedPDF: Codable, Hashable, Sendable {
    public var path: String
    public var contentHash: String?
    public var keptName: String
    /// `PlotAnswer.note`: its warning or fallback line.
    public var note: String?

    public init(path: String, contentHash: String?, keptName: String, note: String?) {
        self.path = path
        self.contentHash = contentHash
        self.keptName = keptName
        self.note = note
    }
}

/// Where the plot ledger is kept.
public protocol PlotLedgerStore: Sendable {
    /// The ledger kept, or an empty one when there is none (or it can't be read).
    func load() -> PlotLedger
    func save(_ ledger: PlotLedger) throws
}

/// The ledger in a file, written whole and flushed to storage each time, as the sync ledger is.
public struct PlotLedgerFile: PlotLedgerStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `Application Support/Plots/requests.json`.
    public static func onThisDevice() throws -> PlotLedgerFile {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return PlotLedgerFile(url: support.appendingPathComponent("Plots", isDirectory: true)
            .appendingPathComponent("requests.json"))
    }

    public func load() -> PlotLedger {
        guard let bytes = try? DurableFile.read(url) else { return PlotLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PlotLedger.self, from: Data(bytes))) ?? PlotLedger()
    }

    public func save(_ ledger: PlotLedger) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ledger)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFile.writeAtomically([UInt8](data), to: url)
    }
}

/// A ledger in memory, for tests and the captures.
public final class PlotLedgerMemory: PlotLedgerStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ledger: PlotLedger
    public private(set) var saves = 0

    public init(_ ledger: PlotLedger = PlotLedger()) { self.ledger = ledger }

    public func load() -> PlotLedger { lock.withLock { ledger } }
    public func save(_ ledger: PlotLedger) throws {
        lock.withLock {
            self.ledger = ledger
            saves += 1
        }
    }
}
