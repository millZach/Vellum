#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation

/// Writing files so a crash, a kill or a dead battery leaves either the old contents or the new, never half of each
/// (ADR-0014). Plain POSIX calls, so it behaves the same on the Duo and on Linux, where the tests run.
enum DurableFile {
    struct Failure: Error, CustomStringConvertible {
        let operation: String
        let path: String
        let code: Int32

        var description: String { "\(operation) \(path): \(String(cString: strerror(code)))" }

        /// Whether the Duo is out of space, which the status bar says plainly.
        var isOutOfSpace: Bool { code == ENOSPC || code == EDQUOT }
    }

    /// Failures the tests inject into the file calls, to prove a failure at any step loses nothing. Never set in the
    /// app.
    enum Fault: Sendable {
        enum Operation: Sendable { case open, write, fsync, flushFolder, rename, truncate }

        /// The call fails with this error and does nothing.
        case error(Int32)
        /// A write puts down this many bytes, then fails with this error: a torn record.
        case shortWrite(Int, Int32)

        private static let lock = NSLock()
        nonisolated(unsafe) private static var handler: (@Sendable (Operation, String) -> Fault?)?

        /// Sets (or clears, with nil) what decides each call's fault.
        static func inject(_ decide: (@Sendable (Operation, String) -> Fault?)?) {
            lock.lock()
            handler = decide
            lock.unlock()
        }

        static func injected(_ operation: Operation, _ path: String) -> Fault? {
            lock.lock()
            let decide = handler
            lock.unlock()
            return decide?(operation, path)
        }

        /// The error to fail a call with, when one is injected.
        static func check(_ operation: Operation, _ path: String) -> Int32? {
            switch injected(operation, path) {
            case .error(let code)?, .shortWrite(_, let code)?: code
            case nil: nil
            }
        }
    }

    /// Replaces a file's contents in one step: writes a temporary file beside it, flushes it to storage, renames it over
    /// the old one and flushes the folder, so the rename itself survives a power loss.
    static func writeAtomically(_ bytes: [UInt8], to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).writing")
        let fd = try open(temporary, flags: O_WRONLY | O_CREAT | O_TRUNC)
        do {
            try write(bytes, to: fd, path: temporary.path)
            try flush(fd, path: temporary.path)
        } catch {
            close(fd)
            unlink(temporary.path)
            throw error
        }
        close(fd)
        do {
            try move(temporary, to: url)
        } catch {
            unlink(temporary.path)
            throw error
        }
        try flushFolder(url.deletingLastPathComponent())
    }

    /// Renames a file over another in one step: afterwards the name holds either the old file or the new one.
    static func move(_ from: URL, to url: URL) throws {
        if let code = Fault.check(.rename, url.path) { throw Failure(operation: "rename", path: url.path, code: code) }
        FileWork.note()
        guard rename(from.path, url.path) == 0 else { throw Failure(operation: "rename", path: url.path, code: errno) }
    }

    static func open(_ url: URL, flags: Int32) throws -> Int32 {
        if let code = Fault.check(.open, url.path) { throw Failure(operation: "open", path: url.path, code: code) }
        let fd = url.path.withCString { systemOpen($0, flags | O_CLOEXEC, 0o644) }
        guard fd >= 0 else { throw Failure(operation: "open", path: url.path, code: errno) }
        return fd
    }

    static func write(_ bytes: [UInt8], to fd: Int32, path: String) throws {
        var limit = bytes.count
        var injected: Int32?
        switch Fault.injected(.write, path) {
        case .error(let code)?: throw Failure(operation: "write", path: path, code: code)
        case .shortWrite(let count, let code)?: (limit, injected) = (min(count, bytes.count), code)
        case nil: break
        }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < limit {
                let written = systemWrite(fd, buffer.baseAddress! + offset, limit - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Failure(operation: "write", path: path, code: errno)
                }
                offset += written
            }
        }
        if let injected { throw Failure(operation: "write", path: path, code: injected) }
    }

    /// Flushes a file to storage. `full` (the default) asks for `F_FULLFSYNC` on Apple platforms, which reaches the
    /// flash itself rather than the drive's cache: a plain `fsync` there does not promise the bytes survive a power
    /// cut. Every flush Vellum makes is full, the ink log's batched one included (ADR-0014).
    static func flush(_ fd: Int32, path: String, full: Bool = true) throws {
        if let code = Fault.check(.fsync, path) { throw Failure(operation: "fsync", path: path, code: code) }
        FileWork.note(fsync: true)
        #if canImport(Darwin)
        if full, fcntl(fd, F_FULLFSYNC) == 0 { return }
        #endif
        guard fsync(fd) == 0 else { throw Failure(operation: "fsync", path: path, code: errno) }
    }

    static func flushFolder(_ url: URL) throws {
        if let code = Fault.check(.flushFolder, url.path) { throw Failure(operation: "fsync", path: url.path, code: code) }
        let fd = url.path.withCString { systemOpen($0, O_RDONLY | O_CLOEXEC, 0) }
        guard fd >= 0 else { throw Failure(operation: "open", path: url.path, code: errno) }
        defer { close(fd) }
        FileWork.note(fsync: true)
        #if canImport(Darwin)
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        #endif
        // Some file systems refuse fsync on a folder; the rename has still happened.
        if fsync(fd) != 0, errno != EINVAL, errno != EBADF {
            throw Failure(operation: "fsync", path: url.path, code: errno)
        }
    }

    static func truncate(_ fd: Int32, to length: Int, path: String) throws {
        if let code = Fault.check(.truncate, path) { throw Failure(operation: "truncate", path: path, code: code) }
        FileWork.note()
        guard ftruncate(fd, off_t(length)) == 0 else { throw Failure(operation: "truncate", path: path, code: errno) }
    }

    static func size(of fd: Int32, path: String) throws -> Int {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure(operation: "stat", path: path, code: errno) }
        return Int(info.st_size)
    }

    /// A whole file's bytes, or nil when it does not exist.
    static func read(_ url: URL) throws -> [UInt8]? {
        let fd = url.path.withCString { systemOpen($0, O_RDONLY | O_CLOEXEC, 0) }
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw Failure(operation: "open", path: url.path, code: errno)
        }
        defer { close(fd) }
        let length = try size(of: fd, path: url.path)
        var bytes = [UInt8](repeating: 0, count: length)
        var offset = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while offset < length {
                let count = systemRead(fd, buffer.baseAddress! + offset, length - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Failure(operation: "read", path: url.path, code: errno)
                }
                if count == 0 { break }
                offset += count
            }
        }
        return offset == length ? bytes : Array(bytes[..<offset])
    }
}

/// A count of the file work Vellum's storage has done, for the budget tests (`docs/perf/baselines/storage.json`):
/// every open, read, write, flush, truncate and rename, how many of them ran on the main thread, how many were flushes
/// to storage, and how many bytes were written. It costs a lock per system call, nothing next to the call itself.
public enum FileWork {
    public struct Counts: Hashable, Sendable {
        public var operations = 0
        public var onMainThread = 0
        public var fsyncs = 0
        public var bytesWritten = 0

        public static func - (lhs: Counts, rhs: Counts) -> Counts {
            Counts(operations: lhs.operations - rhs.operations, onMainThread: lhs.onMainThread - rhs.onMainThread,
                   fsyncs: lhs.fsyncs - rhs.fsyncs, bytesWritten: lhs.bytesWritten - rhs.bytesWritten)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts = Counts()

    /// The counts since launch. Take the difference of two readings to count one piece of work.
    public static var current: Counts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /// Set by the app in debug builds: storage file work on the main thread then stops the app at once, so a change
    /// that puts it there is caught the first time it runs. Release builds count it and carry on.
    nonisolated(unsafe) public static var trapsOnMainThread = false

    static func note(fsync: Bool = false, bytesWritten: Int = 0) {
        let main = Thread.isMainThread
        if main, trapsOnMainThread { assertionFailure("Storage file work on the main thread") }
        lock.lock()
        counts.operations += 1
        if main { counts.onMainThread += 1 }
        if fsync { counts.fsyncs += 1 }
        counts.bytesWritten += bytesWritten
        lock.unlock()
    }
}

// The C calls, named so they don't collide with `DurableFile`'s own `open`, `write` and `read`.
private func systemOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 {
    FileWork.note()
    #if canImport(Glibc)
    return Glibc.open(path, flags, mode)
    #else
    return Darwin.open(path, flags, mode)
    #endif
}

private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    FileWork.note(bytesWritten: count)
    #if canImport(Glibc)
    return Glibc.write(fd, buffer, count)
    #else
    return Darwin.write(fd, buffer, count)
    #endif
}

private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    FileWork.note()
    #if canImport(Glibc)
    return Glibc.read(fd, buffer, count)
    #else
    return Darwin.read(fd, buffer, count)
    #endif
}

/// A write to the Duo's storage that failed, saying whether it was for want of space so the status bar can say so.
public protocol StorageFailure: Error {
    var isOutOfSpace: Bool { get }
}

extension DurableFile.Failure: StorageFailure {}
