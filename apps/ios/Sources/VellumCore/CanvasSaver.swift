import Foundation

/// Makes the Canvases list's thumbnail of a canvas's ink. The app draws PNGs into Caches; the tests count calls.
public protocol CanvasThumbnails: Sendable {
    /// Whether the thumbnail on the Duo already shows this saved version of the ink.
    func isCurrent(_ id: UUID, version: String) -> Bool
    /// Draws the thumbnail and records which saved version it shows. Runs on the maintenance queue.
    func write(_ id: UUID, ink: Ink, version: String)
    /// Forgets a deleted canvas's thumbnail.
    func remove(_ id: UUID)
}

/// When the saver's timed work (the batched flush, retrying a failed write) runs. The app uses the clock; the budget
/// tests use a virtual one, so a minute of drawing takes no real minute.
public protocol SaverClock: Sendable {
    /// Calls `work` once `seconds` have passed, on any thread.
    func after(_ seconds: Double, _ work: @escaping @Sendable () -> Void)
}

/// The real clock.
public struct DispatchClock: SaverClock {
    public init() {}
    public func after(_ seconds: Double, _ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Saves one canvas on the Duo, entirely off the main thread (ADR-0014), and is the one owner of that canvas's files
/// while it exists: `CanvasSavers` hands out one per canvas, and opening, closing, reopening and deleting it all run
/// in order on its queue.
///
/// Two serial queues: `appends`, where every change is written to the ink log as soon as it arrives, and
/// `maintenance`, where the slow work (encoding and writing a compaction's snapshot, drawing the thumbnail) runs, so a
/// stroke finished during compaction is written at once rather than waiting behind it.
///
/// A change that can't be written (the Duo is full) is kept in memory and written again on a timer until it is, and
/// the saver stays alive until it is: closing the canvas never drops it.
public final class CanvasSaver: @unchecked Sendable {
    /// How long appended changes may sit in the file cache before they are flushed to storage. They already survive a
    /// crash or a kill; this bounds what a sudden power cut could take.
    public static let flushInterval = FlushSchedule.interval
    /// How soon a failed write or flush is tried again, the first time and at most.
    static let firstRetry = 1.0, longestRetry = 15.0

    public let id: UUID
    let library: CanvasLibrary
    let appends: DispatchQueue
    private let maintenance: DispatchQueue
    private let clock: SaverClock
    private let thumbnails: CanvasThumbnails?
    private let compactionThreshold: Int
    /// Told the canvas's save state whenever it changes, on any thread.
    private let report: @Sendable (UUID, SaveState) -> Void
    /// Asked, on `appends`, whether nothing holds the saver any more, so it can let go of the canvas's files.
    private let canRelease: @Sendable (CanvasSaver) -> Bool

    // Everything below is touched only on `appends`.
    private var store: InkStore?
    /// Changes a failed write left unsaved, written again ahead of the next ones.
    private var unwritten: [InkEvent] = []
    private var flushSchedule = FlushSchedule()
    private var retrying = false
    /// Whether the last flush to storage failed, so "saved" waits for one to succeed.
    private var flushFailing = false
    private var retryDelay = CanvasSaver.firstRetry
    private var pencilDown = false
    /// A compaction's snapshot, written, waiting for the Pencil to lift before it is put in place.
    private var preparedSnapshot: InkStore.PreparedSnapshot?
    private var compactionRunning = false
    /// Whether the thumbnail may not show the saved ink: true until it is confirmed current.
    private var thumbnailIsStale = true
    private var state = SaveState.savedOnThisDuo
    private var released = false
    private(set) var isDeleted = false

    /// Test hook: runs on the maintenance queue after a compaction's snapshot is written, before it is put in place.
    var afterSnapshotWritten: (@Sendable () -> Void)?

    init(id: UUID, library: CanvasLibrary, clock: SaverClock, thumbnails: CanvasThumbnails?, compactionThreshold: Int,
         report: @escaping @Sendable (UUID, SaveState) -> Void, canRelease: @escaping @Sendable (CanvasSaver) -> Bool) {
        self.id = id
        self.library = library
        self.clock = clock
        self.thumbnails = thumbnails
        self.compactionThreshold = compactionThreshold
        self.report = report
        self.canRelease = canRelease
        appends = DispatchQueue(label: "com.millzach.vellum.saving.\(id.uuidString.prefix(8))", qos: .userInitiated)
        maintenance = DispatchQueue(label: "com.millzach.vellum.maintenance.\(id.uuidString.prefix(8))", qos: .utility)
    }

    // MARK: Opening

    /// The canvas's name and units, and its ink with its undo history as it stands: everything handed to the saver
    /// before this call, written or still waiting to be. Opens the files the first time.
    func openSession() async throws -> (CanvasManifest, InkSession) {
        try await onAppends { [self] in
            if isDeleted { throw CocoaError(.fileNoSuchFile) }
            let manifest = try library.manifest(for: id)
            if store == nil {
                store = try library.openInk(id, compactionThreshold: compactionThreshold)
                released = false
                refreshThumbnailIfStale()
            }
            var session = store!.session
            for event in unwritten { session.apply(event) }
            session.dropUnsavedEvents()
            return (manifest, session)
        }
    }

    // MARK: Saving

    /// Hands changes to the queue to be written: a queue hand-off, so the Pencil never waits on storage. `done` is
    /// told the canvas's save state once they are written, or why not.
    public func save(_ events: [InkEvent], done: (@Sendable (SaveState) -> Void)? = nil) {
        guard !events.isEmpty else { return }
        appends.async { [self] in
            unwritten += events
            writeUnwritten()
            done?(state)
        }
    }

    /// Whether the Pencil is on the glass. A compaction's last step waits for it to lift; appends never do.
    public func setPencilDown(_ down: Bool) {
        appends.async { [self] in
            pencilDown = down
            guard !down else { return }
            if let prepared = preparedSnapshot {
                preparedSnapshot = nil
                finishCompaction(prepared)
            }
            compactIfDue()
        }
    }

    public func setUnits(_ units: CanvasUnits) {
        appends.async { [self] in try? library.setUnits(id, to: units) }
    }

    /// Writes anything a failed write left behind, flushes everything to storage and brings the thumbnail up to date:
    /// for when the app leaves the screen or the canvas is closed. Returns the save state after.
    @discardableResult
    public func flushNow() async -> SaveState {
        await withCheckedContinuation { continuation in
            flushNow { continuation.resume(returning: $0) }
        }
    }

    /// The same, calling `done` on the queue when it is finished.
    public func flushNow(done: @escaping @Sendable (SaveState) -> Void) {
        appends.async { [self] in
            writeOutAndFlush()
            refreshThumbnailIfStale()
            releaseIfDone()
            done(state)
        }
    }

    /// Waits until both queues have nothing more to do: for the tests.
    func idle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            appends.async { [self] in maintenance.async { [self] in appends.async { continuation.resume() } } }
        }
    }

    /// Waits until every change handed over so far has been through `appends`: for the tests.
    func appendsIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            appends.async { continuation.resume() }
        }
    }

    // MARK: Deleting

    /// Waits for every pending write and the maintenance in progress, lets go of the files and deletes the canvas.
    /// Anything handed to the saver after this is refused.
    func delete() async throws {
        try await onAppends { [self] in
            isDeleted = true
            unwritten.removeAll()
            preparedSnapshot = nil
            maintenance.sync {}  // a compaction's snapshot or a thumbnail being written; never waits on `appends`
            store?.closeFiles()
            store = nil
            released = true
            try library.delete(id)
            thumbnails?.remove(id)
            setState(.savedOnThisDuo)
        }
    }

    // MARK: On the queue

    /// Runs `work` on `appends` and waits for it without blocking the caller's thread.
    private func onAppends<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            appends.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// The one drain-and-write: appends what is waiting. Throws why it could not.
    private func appendUnwritten() throws {
        guard !unwritten.isEmpty else { return }
        guard !isDeleted else { return unwritten.removeAll() }
        guard let store else { throw InkStore.WriterLost(reason: "the canvas is not open") }
        try store.append(unwritten)
        unwritten.removeAll()
        thumbnailIsStale = true
    }

    /// Appends what is waiting and, when there is anything, schedules the batched flush. On failure, keeps it and
    /// retries.
    private func writeUnwritten() {
        do {
            try appendUnwritten()
            scheduleFlush()
            if !flushFailing { setState(.savedOnThisDuo) }
        } catch {
            fail(error)
        }
    }

    /// The one drain-and-flush: appends what is waiting, then flushes the log and any unfinished compaction step to
    /// storage. Records the outcome and retries a failure.
    private func writeOutAndFlush() {
        do {
            try appendUnwritten()
        } catch {
            return fail(error)
        }
        do {
            try store?.flush()
            flushFailing = false
            retryDelay = Self.firstRetry
            setState(.savedOnThisDuo)
        } catch {
            flushFailing = true
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        setState(.notSaved(outOfSpace: (error as? any StorageFailure)?.isOutOfSpace ?? false))
        scheduleRetry()
    }

    private func setState(_ new: SaveState) {
        guard new != state else { return }
        state = new
        report(id, new)
    }

    private func scheduleFlush() {
        guard flushSchedule.didAppend() else { return }
        clock.after(Self.flushInterval) { [self] in
            appends.async { [self] in
                flushSchedule.didFlush()
                writeOutAndFlush()
                compactIfDue()
                refreshThumbnailIfStale()
                releaseIfDone()
            }
        }
    }

    /// Tries a failed write or flush again, waiting longer each time up to `longestRetry`, until it succeeds.
    private func scheduleRetry() {
        guard !retrying, !isDeleted else { return }
        retrying = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.longestRetry)
        clock.after(delay) { [self] in
            appends.async { [self] in
                retrying = false
                writeOutAndFlush()
                releaseIfDone()
            }
        }
    }

    /// Starts a compaction when the log has outgrown the snapshot and the Pencil is up. The snapshot is written on the
    /// maintenance queue; appends carry on meanwhile.
    private func compactIfDue() {
        guard !pencilDown, !compactionRunning, !isDeleted, let store, store.needsCompaction,
              let plan = store.beginCompaction() else { return }
        compactionRunning = true
        maintenance.async { [self] in
            let result = Result { try InkStore.writeSnapshot(plan) }
            afterSnapshotWritten?()
            appends.async { [self] in
                switch result {
                case .success(let prepared):
                    if pencilDown { preparedSnapshot = prepared } else { finishCompaction(prepared) }
                case .failure:
                    // Nothing changed on disk; the next quiet moment tries again.
                    self.store?.cancelCompaction()
                    compactionRunning = false
                }
            }
        }
    }

    private func finishCompaction(_ prepared: InkStore.PreparedSnapshot) {
        compactionRunning = false
        guard let store, !isDeleted else { return }
        do {
            try store.finishCompaction(prepared)
        } catch {
            // The ink is safe either way: the old log still holds what the new one could not yet. The flush retries.
            fail(error)
        }
        releaseIfDone()
    }

    /// Redraws the thumbnail on the maintenance queue when it may not show the saved ink.
    private func refreshThumbnailIfStale() {
        guard thumbnailIsStale, !isDeleted, let store, let thumbnails else { return }
        thumbnailIsStale = false
        let ink = store.session.ink, version = store.savedVersion, id = id
        maintenance.async {
            if !thumbnails.isCurrent(id, version: version) { thumbnails.write(id, ink: ink, version: version) }
        }
    }

    /// Lets go of the canvas's files once nothing is waiting to be written and nothing holds the saver.
    private func releaseIfDone() {
        guard !released, unwritten.isEmpty, !(store?.needsFlush ?? false), !compactionRunning, preparedSnapshot == nil,
              canRelease(self) else { return }
        store?.closeFiles()
        store = nil
        released = true
    }
}

/// The one saver per canvas. Opening, closing, reopening and deleting a canvas all go through here, so two savers
/// never write the same canvas: reopening a canvas that is still being saved reuses its saver (and waits behind its
/// pending writes), and deleting waits for them. A closed canvas's saver lives on until everything it was handed is
/// written to storage.
public final class CanvasSavers: @unchecked Sendable {
    public let library: CanvasLibrary
    private let clock: SaverClock
    private let thumbnails: CanvasThumbnails?
    private let compactionThreshold: Int
    private let report: @Sendable (UUID, SaveState) -> Void

    private let lock = NSLock()
    private var savers: [UUID: CanvasSaver] = [:]
    /// How many open editors hold each saver.
    private var holds: [UUID: Int] = [:]

    public init(library: CanvasLibrary, clock: SaverClock = DispatchClock(), thumbnails: CanvasThumbnails? = nil,
                compactionThreshold: Int = 1 << 20, report: @escaping @Sendable (UUID, SaveState) -> Void = { _, _ in }) {
        self.library = library
        self.clock = clock
        self.thumbnails = thumbnails
        self.compactionThreshold = compactionThreshold
        self.report = report
    }

    /// The saver for a canvas, made if there is none yet, held so it is not let go until `letGo`.
    private func hold(_ id: UUID) -> CanvasSaver {
        lock.lock()
        defer { lock.unlock() }
        holds[id, default: 0] += 1
        if let saver = savers[id] { return saver }
        let saver = CanvasSaver(id: id, library: library, clock: clock, thumbnails: thumbnails,
                                compactionThreshold: compactionThreshold, report: report,
                                canRelease: { [weak self] saver in self?.forget(saver) ?? true })
        savers[id] = saver
        return saver
    }

    /// Forgets a saver nothing holds. Called on its queue.
    private func forget(_ saver: CanvasSaver) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard holds[saver.id, default: 0] == 0 else { return false }
        if savers[saver.id] === saver { savers[saver.id] = nil }
        return true
    }

    /// Opens a canvas for drawing on: its name, units, ink and undo history, and the saver to hand changes to. Hold it
    /// until `close`.
    public func open(_ id: UUID) async throws -> (CanvasManifest, InkSession, CanvasSaver) {
        let saver = hold(id)
        do {
            let (manifest, session) = try await saver.openSession()
            return (manifest, session, saver)
        } catch {
            letGo(id)
            await saver.flushNow()  // lets go of the saver, which never opened the canvas
            throw error
        }
    }

    /// The editor is done with the saver. It writes and flushes what it was handed, then lets go of the files; if
    /// that fails, it keeps the changes and retries until they are written.
    public func close(_ saver: CanvasSaver, done: (@Sendable (SaveState) -> Void)? = nil) {
        letGo(saver.id)
        saver.flushNow { done?($0) }
    }

    private func letGo(_ id: UUID) {
        lock.lock()
        holds[id] = max(0, holds[id, default: 0] - 1)
        if holds[id] == 0 { holds[id] = nil }
        lock.unlock()
    }

    /// Deletes a canvas from the Duo once every write handed to its saver has finished.
    public func delete(_ id: UUID) async throws {
        let saver = hold(id)
        defer { letGo(id) }
        try await saver.delete()
        forgetDeleted(saver)
    }

    private func forgetDeleted(_ saver: CanvasSaver) {
        lock.lock()
        if savers[saver.id] === saver { savers[saver.id] = nil }
        lock.unlock()
    }

    /// Flushes every canvas with a saver, open or closed and still writing: for when the app leaves the screen.
    public func flushAll(done: @escaping @Sendable () -> Void) {
        lock.lock()
        let all = Array(savers.values)
        lock.unlock()
        let group = DispatchGroup()
        for saver in all {
            group.enter()
            saver.flushNow { _ in group.leave() }
        }
        group.notify(queue: .global(qos: .userInitiated), execute: done)
    }

    public func flushAll() async {
        await withCheckedContinuation { continuation in flushAll { continuation.resume() } }
    }

    /// The canvases with a saver: open, or closed with changes still being written.
    public var active: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(savers.keys)
    }
}
