import Foundation

/// Dropbox's content hash of a file's bytes, as its listing gives it: the SHA-256 of the SHA-256s of each 4 MB block,
/// in hex. The symbol library's sync (#41) compares the Duo's files with Dropbox's by it, without downloading them.
public enum DropboxContentHash {
    public static let blockSize = 4 * 1024 * 1024

    public static func of(_ bytes: [UInt8]) -> String {
        var joined: [UInt8] = []
        var start = 0
        repeat {
            let end = min(start + blockSize, bytes.count)
            joined += SHA256.hash(Array(bytes[start..<end]))
            start = end
        } while start < bytes.count
        return SHA256.hash(joined).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The library's files on the Duo

/// Where the symbol library's files are kept on the Duo (ADR-0016): one `<id>.vsym` per saved symbol. Every call
/// touches the disk; call it off the main thread.
public protocol SymbolFolderStore: Sendable {
    /// Every symbol file, by file name.
    func files() throws -> [String: [UInt8]]
    /// Writes a file whole, replacing any of that name.
    func write(_ bytes: [UInt8], named name: String) throws
}

/// The library's folder: `Application Support/Symbols`.
public struct SymbolFolder: SymbolFolderStore {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func onThisDevice() throws -> SymbolFolder {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return SymbolFolder(root: support.appendingPathComponent("Symbols", isDirectory: true))
    }

    public func files() throws -> [String: [UInt8]] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
        var files: [String: [UInt8]] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path)
        where SymbolFile.id(fromFileName: name) != nil {
            if let bytes = try DurableFile.read(root.appendingPathComponent(name)) { files[name] = bytes }
        }
        return files
    }

    public func write(_ bytes: [UInt8], named name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try DurableFile.writeAtomically(bytes, to: root.appendingPathComponent(name))
    }
}

/// The library's files in memory, for tests and the captures.
public final class SymbolFolderMemory: SymbolFolderStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: [UInt8]]

    public init(_ files: [String: [UInt8]] = [:]) { stored = files }

    public func files() throws -> [String: [UInt8]] { lock.withLock { stored } }
    public func write(_ bytes: [UInt8], named name: String) throws { lock.withLock { stored[name] = bytes } }
}

extension SymbolFolderStore {
    /// The symbols the files hold, by name; a file that can't be read is skipped, not fatal.
    public func symbols() -> [Symbol] {
        let files = (try? files()) ?? [:]
        return files.compactMap { name, bytes in
            SymbolFile.id(fromFileName: name).flatMap { try? SymbolFile.decode(bytes, fileID: $0) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves a symbol as its file.
    public func save(_ symbol: Symbol) throws {
        try write(SymbolFile.encode(symbol), named: SymbolFile.fileName(for: symbol.id))
    }
}

// MARK: - The ledger

/// What the Duo and Dropbox last agreed each symbol file holds (ADR-0016): its content hash, by file name. It tells a
/// file changed on one side from one changed on the other, so only new or changed files move. Kept beside the canvas
/// sync's ledger, in Application Support.
public struct SymbolSyncLedger: Codable, Hashable, Sendable {
    public static let currentFormat = 1
    public var format = SymbolSyncLedger.currentFormat
    /// Each file's content hash when both sides last held the same bytes.
    public var synced: [String: String] = [:]

    public init(synced: [String: String] = [:]) { self.synced = synced }
}

public protocol SymbolSyncLedgerStore: Sendable {
    func load() -> SymbolSyncLedger
    func save(_ ledger: SymbolSyncLedger) throws
}

/// `Application Support/Sync/symbols.json`.
public struct SymbolSyncLedgerFile: SymbolSyncLedgerStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func onThisDevice() throws -> SymbolSyncLedgerFile {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return SymbolSyncLedgerFile(url: support.appendingPathComponent("Sync", isDirectory: true)
            .appendingPathComponent("symbols.json"))
    }

    public func load() -> SymbolSyncLedger {
        guard let bytes = try? DurableFile.read(url) else { return SymbolSyncLedger() }
        return (try? JSONDecoder().decode(SymbolSyncLedger.self, from: Data(bytes))) ?? SymbolSyncLedger()
    }

    public func save(_ ledger: SymbolSyncLedger) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFile.writeAtomically([UInt8](try encoder.encode(ledger)), to: url)
    }
}

public final class SymbolSyncLedgerMemory: SymbolSyncLedgerStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ledger: SymbolSyncLedger

    public init(_ ledger: SymbolSyncLedger = SymbolSyncLedger()) { self.ledger = ledger }

    public func load() -> SymbolSyncLedger { lock.withLock { ledger } }
    public func save(_ ledger: SymbolSyncLedger) throws { lock.withLock { self.ledger = ledger } }
}

// MARK: - The plan

/// One file's worth of syncing the symbol library.
public enum SymbolSyncStep: Hashable, Sendable {
    /// The Duo's file goes up: new on the Duo, or changed there since the last sync.
    case upload(String)
    /// Dropbox's file comes down: new there (the laptop put it there), or changed there since the last sync.
    case download(String)
    /// Changed on both sides since the last sync, or different on both before any: Dropbox's file comes down under its
    /// name, and the Duo's is kept as a new symbol beside it, which goes up. Nothing is lost.
    case keepBoth(String)
    /// The same bytes on both sides: nothing moves, and the ledger notes that they agree.
    case agree(String)
}

/// What a sync of the symbol library does (ADR-0016): two-way, file by file, comparing content hashes, so only new or
/// changed files move. Nothing is ever deleted by a sync: a file one side lacks is copied from the other.
public enum SymbolSyncPlan {
    /// `local` and `remote` are each side's files' content hashes by file name; `synced` is the ledger's.
    public static func steps(local: [String: String], remote: [String: String], synced: [String: String])
        -> [SymbolSyncStep] {
        // Dropbox is case-insensitive: a laptop's `Strainer.VSYM` is the Duo's `strainer.vsym`.
        var remoteByKey: [String: (name: String, hash: String)] = [:]
        for (name, hash) in remote { remoteByKey[name.lowercased()] = (name, hash) }
        var steps: [SymbolSyncStep] = []
        var seen: Set<String> = []
        for name in local.keys.sorted() {
            let key = name.lowercased()
            seen.insert(key)
            let mine = local[name]!
            guard let theirs = remoteByKey[key] else {
                steps.append(.upload(name))
                continue
            }
            let agreed = synced[name] ?? synced[theirs.name]
            if mine == theirs.hash {
                if agreed != mine { steps.append(.agree(name)) }
            } else if agreed == mine {
                steps.append(.download(theirs.name))
            } else if agreed == theirs.hash {
                steps.append(.upload(name))
            } else {
                steps.append(.keepBoth(name))
            }
        }
        for (key, theirs) in remoteByKey.sorted(by: { $0.key < $1.key }) where !seen.contains(key) {
            steps.append(.download(theirs.name))
        }
        return steps
    }
}

// MARK: - The engine

/// Keeps the Duo's symbol library and `Dropbox/Vellum/Symbols` in step (#41, ADR-0016): new symbols saved on the Duo go
/// up, symbols the laptop puts there come down on the next sync, and only new or changed files move. Offline, nothing
/// moves and nothing changes: the files wait on the Duo, and the next sync with a connection takes them. Every call is
/// off the main thread; `sync` returns whether the library on the Duo changed, so the app reads it again.
public actor SymbolSync {
    /// The Dropbox folder the library is mirrored to.
    public static let folder = SyncPaths.root + "/Symbols"

    private let session: DropboxSession?
    private let store: any SymbolFolderStore
    private let ledgerStore: any SymbolSyncLedgerStore
    private let makeID: @Sendable () -> String
    private var running = false
    private var again = false
    /// Each file's steps taken by the last sync, for the tests.
    public private(set) var lastSteps: [SymbolSyncStep] = []

    public init(session: DropboxSession?, store: any SymbolFolderStore, ledger: any SymbolSyncLedgerStore,
                makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.session = session
        self.store = store
        ledgerStore = ledger
        self.makeID = makeID
    }

    /// Syncs once; a call while one runs makes it run again when it finishes. True when files on the Duo changed.
    @discardableResult
    public func sync() async -> Bool {
        if running {
            again = true
            return false
        }
        running = true
        defer { running = false }
        var changed = false
        repeat {
            again = false
            if await syncOnce() { changed = true }
        } while again
        return changed
    }

    private func syncOnce() async -> Bool {
        guard let session, await session.isSignedIn else { return false }
        let listed: [DropboxFile]
        do {
            listed = try await session.files(in: Self.folder) ?? []
        } catch {
            // Offline, or Dropbox not answering: nothing moves, and the files wait on the Duo for the next sync.
            return false
        }
        guard let localFiles = try? store.files() else { return false }
        let remote = Dictionary(listed.filter { SymbolFile.id(fromFileName: $0.name) != nil }
            .map { ($0.name, $0) }) { a, _ in a }
        var ledger = ledgerStore.load()
        let steps = SymbolSyncPlan.steps(local: localFiles.mapValues(DropboxContentHash.of),
                                         remote: remote.mapValues(\.contentHash), synced: ledger.synced)
        lastSteps = steps
        var changed = false
        for step in steps {
            do {
                switch step {
                case .agree(let name):
                    ledger.synced[name] = DropboxContentHash.of(localFiles[name] ?? [])
                case .upload(let name):
                    guard let bytes = localFiles[name] else { continue }
                    guard case .written = try await session.upload(Data(bytes), to: "\(Self.folder)/\(name)",
                                                                    mode: .overwrite) else { continue }
                    ledger.synced[name] = DropboxContentHash.of(bytes)
                case .download(let name):
                    guard let file = remote[name], let bytes = try await download(file, session) else { continue }
                    try store.write(bytes, named: name)
                    ledger.synced[name] = DropboxContentHash.of(bytes)
                    changed = true
                case .keepBoth(let name):
                    guard let file = remote[name] ?? remote.first(where: { $0.key.lowercased() == name.lowercased() })?.value,
                          let mine = localFiles[name], var symbol = try? SymbolFile.decode(mine),
                          let theirs = try await download(file, session) else { continue }
                    // The Duo's version first becomes a symbol of its own, so the download can't lose it.
                    symbol.id = makeID()
                    symbol.name += " (Duo)"
                    let copy = SymbolFile.encode(symbol)
                    let copyName = SymbolFile.fileName(for: symbol.id)
                    try store.write(copy, named: copyName)
                    try store.write(theirs, named: name)
                    ledger.synced[name] = DropboxContentHash.of(theirs)
                    changed = true
                    if case .written = try await session.upload(Data(copy), to: "\(Self.folder)/\(copyName)", mode: .add) {
                        ledger.synced[copyName] = DropboxContentHash.of(copy)
                    }
                }
                try? ledgerStore.save(ledger)
            } catch {
                // The connection went part way through: what moved is in the ledger; the rest waits.
                try? ledgerStore.save(ledger)
                return changed
            }
        }
        return changed
    }

    /// A file's bytes as listed, checked against its listed hash so a damaged download is never kept.
    private func download(_ file: DropboxFile, _ session: DropboxSession) async throws -> [UInt8]? {
        let bytes = [UInt8](try await session.download(file))
        guard file.contentHash.isEmpty || DropboxContentHash.of(bytes) == file.contentHash else { return nil }
        return bytes
    }
}
