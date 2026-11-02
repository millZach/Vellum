import Foundation

/// A canvas as the sync engine needs to know it before reading it.
public struct CanvasSyncEntry: Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var dropboxFolder: String?

    public init(id: UUID, name: String, dropboxFolder: String?) {
        self.id = id
        self.name = name
        self.dropboxFolder = dropboxFolder
    }
}

/// Where the sync engine reads canvases from: the app's canvas savers, so a read waits behind every write.
public protocol CanvasSyncSource: Sendable {
    func captureForSync(_ id: UUID, since known: SyncedPosition) async throws -> CanvasSyncCapture
    /// A sheet's PDF in a canvas's folder. PDFs never change once kept, so this needs no saver.
    func sheetPDFBytes(named name: String, in id: UUID) throws -> Data
    /// Every canvas on the Duo.
    func canvasesOnDuo() -> [CanvasSyncEntry]
}

extension CanvasSavers: CanvasSyncSource {
    public func sheetPDFBytes(named name: String, in id: UUID) throws -> Data {
        guard let bytes = try DurableFile.read(library.sheetPDF(named: name, in: id)) else {
            throw CanvasSyncReadError.gone
        }
        return Data(bytes)
    }

    public func canvasesOnDuo() -> [CanvasSyncEntry] {
        ((try? library.list()) ?? []).compactMap { summary in
            guard let manifest = try? library.manifest(for: summary.id) else { return nil }
            return CanvasSyncEntry(id: summary.id, name: manifest.name, dropboxFolder: manifest.dropboxFolder)
        }
    }
}

/// Where one canvas's sync stands, as the status bar and the Canvases list say it (`SyncStatusLine`).
public enum CanvasSyncState: Hashable, Sendable {
    /// This build has no Dropbox (no app key): nothing syncs, and nothing says it does.
    case off
    /// Dropbox has every change the Duo has.
    case synced
    /// Changes are waiting to upload: when Zach leaves the canvas, or next in line.
    case pending
    /// Uploading now.
    case uploading
    /// Changes are waiting and the Duo is offline: they go when a connection returns.
    case waitingForConnection
    /// The last upload failed; Vellum will retry.
    case failed
    /// Vellum isn't signed in to Dropbox, so nothing can upload until it is.
    case signedOut
}

/// What the engine tells the screen whenever something changes.
public struct SyncReport: Hashable, Sendable {
    /// Whether this build syncs at all.
    public var available: Bool
    public var online: Bool
    public var signedOut: Bool
    public var states: [UUID: CanvasSyncState]

    public init(available: Bool, online: Bool, signedOut: Bool, states: [UUID: CanvasSyncState]) {
        self.available = available
        self.online = online
        self.signedOut = signedOut
        self.states = states
    }

    /// No Dropbox, before the engine has said anything.
    public static let off = SyncReport(available: false, online: true, signedOut: false, states: [:])

    /// A canvas's state; one the engine hasn't heard of (a canvas made since it last reported) is waiting to upload.
    public func state(of id: UUID) -> CanvasSyncState {
        guard available else { return .off }
        if signedOut { return .signedOut }
        return states[id] ?? (online ? .pending : .waitingForConnection)
    }
}

/// Mirrors every canvas folder to `Dropbox/Vellum/<name> <short id>` (#12, ADR-0003), and keeps an outbox of what is
/// still to do there that survives a crash or a relaunch.
///
/// - **When**: a canvas is queued when Zach leaves it, and every canvas when the app goes to the background; never
///   while he draws (the canvas on screen is skipped until then). Saving on the Duo is not changed by any of this.
/// - **What**: only what changed (`SyncPlan`), read through the canvas's saver so it waits behind every write.
/// - **Offline**: work waits in the outbox and goes when the connection returns (`setOnline`), over Wi-Fi or
///   cellular alike. A failure is retried after `backoff(afterFailures:)`, up to five minutes; Retry goes at once.
/// - **Deletes** are queued like uploads, and move the canvas's folder to `Vellum/.deleted`.
/// - **The Duo is the only writer**, so a file Dropbox holds that isn't the one the Duo last wrote (changed or removed
///   on the laptop) is replaced: the whole canvas goes up again, Dropbox keeps the replaced version in its history, and
///   the ledger notes it (`CanvasSyncRecord.replaced`).
///
/// Sync only ever reads the canvas's files: a failed or half-done sync changes nothing on the Duo, and every step
/// leaves Dropbox's copy whole.
public actor CanvasSync {
    /// How long to wait before retrying after `failures` failures in a row: 5 s, doubling, at most five minutes.
    public static func backoff(afterFailures failures: Int) -> Double {
        min(5 * Double(1 << min(max(failures - 1, 0), 10)), 300)
    }

    private let session: DropboxSession?
    private let source: any CanvasSyncSource
    private let store: any SyncLedgerStore
    private let sleep: @Sendable (Double) async -> Void
    private let now: @Sendable () -> Date
    private let report: @Sendable (SyncReport) -> Void

    private var ledger = SyncLedger()
    /// Whether `ledger` has been read from the store: every change waits for that, so one made before `start` (a
    /// canvas left at once after launch) never writes an empty ledger over the outbox kept on the Duo.
    private var loaded = false
    private var started = false
    private var online = true
    private var inBackground = false
    private var onScreen: UUID?
    private var signedOut = false
    private var current: UUID?
    /// Canvases whose last upload failed (not for being offline).
    private var failed: Set<UUID> = []
    private var lastFailureWasOffline = false
    private var failures = 0
    private var draining: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    /// The delays the engine has waited before retrying, for the tests.
    public private(set) var retryDelays: [Double] = []

    public init(session: DropboxSession?, source: any CanvasSyncSource, ledger: any SyncLedgerStore,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                now: @escaping @Sendable () -> Date = { Date() },
                report: @escaping @Sendable (SyncReport) -> Void = { _ in }) {
        self.session = session
        self.source = source
        store = ledger
        self.sleep = sleep
        self.now = now
        self.report = report
    }

    // MARK: What the app tells it

    /// Reads the ledger, queues every canvas Dropbox has never had (canvases made before #12 among them), and starts on
    /// the outbox. Off the main thread, as everything here is.
    public func start() async {
        guard !started else { return }
        started = true
        loadLedger()
        guard let session else { return publish() }
        signedOut = !(await session.isSignedIn)
        if signedOut { forgetUploads() }
        for entry in source.canvasesOnDuo() where ledger[entry.id] == nil { queue(entry.id, entry: entry) }
        persist()
        publish()
        kick()
    }

    /// A canvas is on screen: it is not uploaded while it is, unless the app goes to the background.
    public func canvasOpened(_ id: UUID) {
        onScreen = id
        publish()
    }

    /// Zach left a canvas: queue it and upload it. The caller doesn't wait for any of it.
    public func canvasLeft(_ id: UUID) {
        if onScreen == id { onScreen = nil }
        queue(id)
        persist()
        publish()
        kick()
    }

    /// A canvas changed off its screen (renamed from the list): queue it.
    public func canvasChanged(_ id: UUID) {
        queue(id)
        persist()
        publish()
        kick()
    }

    /// Call before a canvas is deleted from the Duo: its Dropbox folder is queued to move to `Vellum/.deleted`, and
    /// nothing more of it uploads.
    public func canvasWillBeDeleted(_ id: UUID) {
        if onScreen == id { onScreen = nil }
        loadLedger()
        guard let record = ledger[id] else { return }
        ledger[id] = nil
        failed.remove(id)
        if !ledger.deletes.contains(where: { $0.folder.lowercased() == record.folder.lowercased() }) {
            ledger.deletes.append(PendingDelete(id: id, folder: record.folder))
        }
        persist()
        publish()
        kick()
    }

    /// The connection came or went (`NWPathMonitor`). Coming back starts on the outbox at once.
    public func setOnline(_ isOnline: Bool) {
        guard isOnline != online else { return }
        online = isOnline
        if isOnline {
            failures = 0
            lastFailureWasOffline = false
            retry?.cancel()
            retry = nil
            kick()
        }
        publish()
    }

    /// The app went to the background (or came back): in the background the canvas on screen uploads too.
    public func setInBackground(_ background: Bool) {
        inBackground = background
        if background { kick() }
    }

    /// Retry: try the outbox now rather than after the wait.
    public func retryNow() async {
        failures = 0
        failed.removeAll()
        lastFailureWasOffline = false
        retry?.cancel()
        retry = nil
        if let session { signedOut = !(await session.isSignedIn) }
        publish()
        kick()
    }

    /// Zach signed in or out of Dropbox.
    public func signInChanged() async {
        guard let session else { return }
        let isSignedIn = await session.isSignedIn
        if isSignedIn, signedOut {
            signedOut = false
            failures = 0
            kick()
        } else if !isSignedIn, !signedOut {
            signedOut = true
            forgetUploads()
            persist()
        }
        publish()
    }

    /// Waits until the outbox has been worked through as far as it can be now (done, or stopped offline, signed out
    /// or failed); for the background task.
    public func drained() async {
        while let draining { await draining.value }
    }

    /// Waits until nothing is running and no retry is due; for the tests, whose sleep returns at once.
    public func settled() async {
        while draining != nil || retry != nil {
            if let draining { await draining.value }
            if let retry { await retry.value }
        }
    }

    /// The ledger as it stands; for the tests.
    public var ledgerNow: SyncLedger { ledger }

    // MARK: The outbox

    private func loadLedger() {
        guard !loaded else { return }
        ledger = store.load()
        loaded = true
    }

    private func queue(_ id: UUID, entry: CanvasSyncEntry? = nil) {
        loadLedger()
        if var record = ledger[id] {
            record.pending = true
            record.queued += 1
            ledger[id] = record
            return
        }
        guard let entry = entry ?? source.canvasesOnDuo().first(where: { $0.id == id }) else { return }
        let taken = Set(ledger.canvases.values.map(\.folder)).union(source.canvasesOnDuo().compactMap(\.dropboxFolder))
        // A canvas made before #12 takes its name at its first sync.
        let folder = entry.dropboxFolder ?? SyncFolderName.make(name: entry.name, id: id, taken: taken)
        ledger[id] = CanvasSyncRecord(folder: folder)
    }

    /// After a sign-out the next sign-in may be another Dropbox: forget what was uploaded, so every canvas goes up
    /// whole, replacing whatever it finds.
    private func forgetUploads() {
        loadLedger()
        for (key, var record) in ledger.canvases {
            record.uploaded = .nothing
            record.manifestRev = nil
            record.snapshotRev = nil
            record.staleLogGenerations = []
            record.pending = true
            record.replaceAll = true
            ledger.canvases[key] = record
        }
    }

    private func persist() {
        guard loaded else { return }
        try? store.save(ledger)
    }

    private func kick() {
        guard draining == nil, started else { return }
        draining = Task { await self.drain() }
    }

    private func drain() async {
        defer {
            draining = nil
            publish()
        }
        while let session, !signedOut, online {
            if let delete = ledger.deletes.first {
                do {
                    try await perform(delete, session)
                    ledger.deletes.removeAll { $0 == delete }
                    persist()
                    succeeded()
                } catch {
                    return didFail(error, nil)
                }
                continue
            }
            let waiting = ledger.pending.filter { inBackground || $0 != onScreen }
                .sorted { $0.uuidString < $1.uuidString }
            guard let id = waiting.first(where: { !failed.contains($0) }) ?? waiting.first else { return }
            current = id
            publish()
            do {
                try await sync(id, session)
                current = nil
                failed.remove(id)
                succeeded()
            } catch {
                current = nil
                return didFail(error, id)
            }
        }
    }

    private func succeeded() {
        failures = 0
        lastFailureWasOffline = false
        publish()
    }

    private func didFail(_ error: Error, _ id: UUID?) {
        switch error as? SyncFailure ?? .failed {
        case .signedOut:
            signedOut = true
            forgetUploads()
            persist()
            return publish()
        case .offline:
            lastFailureWasOffline = true
        case .failed, .gone, .restart:
            if let id { failed.insert(id) }
        }
        failures += 1
        let delay = Self.backoff(afterFailures: failures)
        retryDelays.append(delay)
        retry?.cancel()
        retry = Task {
            await self.sleep(delay)
            guard !Task.isCancelled else { return }
            self.retryFired()
        }
        publish()
    }

    private func retryFired() {
        retry = nil
        kick()
    }

    // MARK: Syncing one canvas

    private enum SyncFailure: Error {
        case offline, signedOut, failed, gone
        /// Dropbox's copy changed underneath: start again, replacing it all.
        case restart
    }

    private static func failure(_ error: DropboxError) -> SyncFailure {
        switch error {
        case .offline: .offline
        case .notSignedIn, .signInExpired, .notSetUp: .signedOut
        default: .failed
        }
    }

    private func perform(_ delete: PendingDelete, _ session: DropboxSession) async throws {
        do {
            _ = try await session.move(SyncPaths.folder(delete.folder), to: "\(SyncPaths.deleted)/\(delete.folder)")
        } catch {
            throw Self.failure(error)
        }
    }

    private func sync(_ id: UUID, _ session: DropboxSession) async throws {
        for _ in 0..<2 {
            do {
                return try await syncOnce(id, session)
            } catch SyncFailure.restart {
                continue
            }
        }
        throw SyncFailure.failed
    }

    private func syncOnce(_ id: UUID, _ session: DropboxSession) async throws {
        guard var record = ledger[id] else { return }
        let ticket = record.queued
        if record.replaceAll {
            record.uploaded = .nothing
            record.manifestRev = nil
            record.snapshotRev = nil
            ledger[id] = record
        }
        let capture: CanvasSyncCapture
        do {
            capture = try await source.captureForSync(id, since: record.uploaded)
        } catch CanvasSyncReadError.gone {
            // Deleted on the Duo without being told: treat it as a delete.
            canvasWillBeDeleted(id)
            return
        } catch {
            throw SyncFailure.failed
        }
        for step in SyncPlan.steps(for: capture, record: record) {
            guard ledger[id] != nil else { return }  // deleted meanwhile; the delete moves what is there
            try await perform(step, capture, id, session)
            persist()
        }
        guard var done = ledger[id] else { return }
        done.replaceAll = false
        if done.queued == ticket { done.pending = false }
        ledger[id] = done
        persist()
    }

    private func perform(_ step: SyncStep, _ capture: CanvasSyncCapture, _ id: UUID, _ session: DropboxSession)
        async throws {
        guard let record = ledger[id] else { return }
        let base = SyncPaths.folder(record.folder)
        let replace = record.replaceAll
        do {
            switch step {
            case .sheet(let name):
                let bytes: Data
                do { bytes = try source.sheetPDFBytes(named: name, in: id) } catch { throw SyncFailure.failed }
                // Named by its content hash: a file already there under the name holds the same bytes.
                _ = try await session.upload(bytes, to: "\(base)/\(SyncPlan.sheetFile(name))",
                                             mode: replace ? .overwrite : .add)
                ledger[id]?.uploaded.sheets.insert(name)
            case .manifest:
                let mode: DropboxWriteMode = replace ? .overwrite : record.manifestRev.map { DropboxWriteMode.update(rev: $0) } ?? .add
                switch try await session.upload(Data(capture.manifestBytes), to: "\(base)/\(SyncPlan.manifestFile)",
                                                mode: mode) {
                case .written(let rev):
                    ledger[id]?.manifestRev = rev
                    ledger[id]?.uploaded.manifestDigest = SyncPlan.digest(capture.manifestBytes)
                case .conflict:
                    throw changedUnderneath(id, SyncPlan.manifestFile)
                }
            case .logPart(let generation, let offset):
                _ = try await session.upload(Data(capture.logBytes),
                                             to: "\(base)/\(SyncPlan.logPartFile(generation: generation, offset: offset))",
                                             mode: .overwrite)
                guard var updated = ledger[id] else { return }
                if let old = updated.uploaded.logGeneration, old != generation, !updated.staleLogGenerations.contains(old) {
                    updated.staleLogGenerations.append(old)
                }
                updated.uploaded.logGeneration = generation
                updated.uploaded.logOffset = capture.logEnd
                ledger[id] = updated
            case .snapshot(let generation):
                guard let bytes = capture.snapshotBytes else { return }
                let mode: DropboxWriteMode = replace ? .overwrite : record.snapshotRev.map { DropboxWriteMode.update(rev: $0) } ?? .add
                switch try await session.upload(Data(bytes), to: "\(base)/\(SyncPlan.snapshotFile)", mode: mode) {
                case .written(let rev):
                    ledger[id]?.snapshotRev = rev
                    ledger[id]?.uploaded.snapshotGeneration = generation
                case .conflict:
                    throw changedUnderneath(id, SyncPlan.snapshotFile)
                }
            case .deleteLogGeneration(let generation):
                _ = try await session.delete("\(base)/\(SyncPlan.logGenerationFolder(generation))")
                ledger[id]?.staleLogGenerations.removeAll { $0 == generation }
            }
        } catch let error as DropboxError {
            throw Self.failure(error)
        }
    }

    /// Dropbox's copy of a file is not the one this Duo last wrote. The Duo is the only writer, so its copy wins: note
    /// it, and upload the whole canvas again, replacing what is there.
    private func changedUnderneath(_ id: UUID, _ file: String) -> SyncFailure {
        ledger[id]?.replaced.append(SyncReplacement(file: file, at: now()))
        ledger[id]?.replaceAll = true
        persist()
        return .restart
    }

    // MARK: Telling the screen

    private func publish() {
        var states: [UUID: CanvasSyncState] = [:]
        for (key, record) in ledger.canvases {
            guard let id = UUID(uuidString: key) else { continue }
            states[id] = state(id, record)
        }
        report(SyncReport(available: session != nil, online: online, signedOut: signedOut, states: states))
    }

    private func state(_ id: UUID, _ record: CanvasSyncRecord) -> CanvasSyncState {
        if signedOut { return .signedOut }
        if !record.pending { return .synced }
        if current == id { return .uploading }
        if !online || lastFailureWasOffline { return .waitingForConnection }
        if failed.contains(id) { return .failed }
        return .pending
    }
}
