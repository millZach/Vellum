import Foundation

/// A made-up Dropbox, in memory, that answers the requests syncing makes (`files/upload`, `files/move_v2`,
/// `files/delete_v2`, `files/list_folder` and `list_folder/continue`, `files/download` since #41, and token renewal) the way Dropbox does, behind
/// the same transport seam the live client uses.
/// The tests sync through it, and Debug builds use it for the simulator's sync captures (`--ui-sync`), since the
/// simulator has no Dropbox key. It can be switched offline, made to fail, and have a file changed "on the laptop".
/// Nothing in it is anyone's real Dropbox.
public final class MadeUpDropbox: DropboxTransport, @unchecked Sendable {
    public struct File: Hashable, Sendable {
        public var path: String
        public var bytes: [UInt8]
        public var rev: String
    }

    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var revisions = 0
    private var _offline = false
    private var _failing = false
    private var _requests: [String] = []
    private var _bytesUploaded = 0
    /// Every change, in order, for `list_folder/continue`: a file written, or a path removed.
    private var changes: [DropboxTreeEntry] = []
    /// What each cursor handed out still has to give: the folder it lists, the change it lists from, and entries of a
    /// listing still to page through.
    private var cursors: [String: (folder: String, from: Int, queued: [DropboxTreeEntry])] = [:]
    private var _pageSize = 2000
    private var cursorsMade = 0
    private var removals: [(after: Int, path: String)] = []

    public init() {}

    /// While true, every request fails as it does with no connection.
    public var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }

    /// While true, every request gets a 503, as from a Dropbox that isn't answering.
    public var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    /// The most entries a listing page holds.
    public var pageSize: Int {
        get { lock.withLock { _pageSize } }
        set { lock.withLock { _pageSize = max(1, newValue) } }
    }

    /// Forgets every cursor handed out, so `list_folder/continue` answers `reset`, as Dropbox may.
    public func resetCursors() {
        lock.withLock { cursors = [:] }
    }

    /// Removes `path` on the laptop after `requests` more requests are answered: a folder deleted mid-sync.
    public func removeOnTheLaptop(_ path: String, afterRequests requests: Int) {
        lock.withLock { removals.append((requests, path)) }
    }

    /// Each request answered, as "<endpoint> <path>", token renewals excepted.
    public var requests: [String] { lock.withLock { _requests } }
    /// The bytes of every upload answered.
    public var bytesUploaded: Int { lock.withLock { _bytesUploaded } }

    public func resetCounts() {
        lock.withLock {
            _requests = []
            _bytesUploaded = 0
        }
    }

    /// Every file, by its path as written.
    public var allFiles: [String: [UInt8]] {
        lock.withLock { Dictionary(uniqueKeysWithValues: files.values.map { ($0.path, $0.bytes) }) }
    }

    /// The files inside a folder, by their path inside it.
    public func files(in folder: String) -> [String: [UInt8]] {
        let prefix = folder.lowercased() + "/"
        return lock.withLock {
            var out: [String: [UInt8]] = [:]
            for (key, file) in files where key.hasPrefix(prefix) { out[String(file.path.dropFirst(prefix.count))] = file.bytes }
            return out
        }
    }

    /// The folders directly inside `folder`, by name.
    public func folders(in folder: String) -> Set<String> {
        let prefix = folder + "/"
        return lock.withLock {
            Set(files.values.compactMap { file -> String? in
                guard file.path.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
                let rest = file.path.dropFirst(prefix.count)
                guard let slash = rest.firstIndex(of: "/") else { return nil }
                return String(rest[..<slash])
            })
        }
    }

    /// A file written by something other than the Duo, as an edit on the laptop would.
    public func changeOnTheLaptop(_ path: String, to bytes: [UInt8]) {
        lock.withLock {
            revisions += 1
            files[path.lowercased()] = File(path: path, bytes: bytes, rev: Self.rev(revisions))
            changes.append(DropboxTreeEntry(path: path.lowercased(), kind: .file))
        }
    }

    public func removeOnTheLaptop(_ path: String) {
        lock.withLock { _ = remove(path) }
    }

    // MARK: Answering

    public func send(_ request: DropboxHTTPRequest) async throws -> DropboxHTTPResponse {
        try lock.withLock {
            let response = try answer(request)
            if request.url.path != "/oauth2/token" { removeWhenDue() }
            return response
        }
    }

    private func removeWhenDue() {
        removals = removals.map { (after: $0.after - 1, path: $0.path) }
        for removal in removals where removal.after <= 0 { _ = remove(removal.path) }
        removals.removeAll { $0.after <= 0 }
    }

    private func answer(_ request: DropboxHTTPRequest) throws -> DropboxHTTPResponse {
        if _offline { throw DropboxError.offline }
        let endpoint = request.url.path
        if endpoint == "/oauth2/token" {
            return Self.json(["access_token": "made-up-access", "refresh_token": "made-up-refresh", "expires_in": 14400,
                              "token_type": "bearer"])
        }
        if _failing { return DropboxHTTPResponse(status: 503, body: Data("made-up outage".utf8)) }
        switch endpoint {
        case "/2/files/upload":
            guard let header = request.headers["Dropbox-API-Arg"],
                  let argument = try? JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any],
                  let path = argument["path"] as? String else { return Self.badRequest }
            _requests.append("upload \(path)")
            let bytes = [UInt8](request.body ?? Data())
            _bytesUploaded += bytes.count
            let existing = files[path.lowercased()]
            let mode = argument["mode"]
            let strict = argument["strict_conflict"] as? Bool ?? false
            // As Dropbox's WriteMode says: nothing at the path is always written; a file with the same bytes is
            // left as it is, with no conflict, unless `strict_conflict`.
            if let existing, existing.bytes == bytes, !strict {
                return Self.json(["name": (path as NSString).lastPathComponent, "path_display": existing.path,
                                  "rev": existing.rev, "size": bytes.count])
            }
            if let tag = mode as? String, tag == "add" {
                if existing != nil { return Self.conflict("path/conflict/file/") }
            } else if let tag = mode as? String, tag == "overwrite" {
                // Whatever is there.
            } else if let update = mode as? [String: Any], update[".tag"] as? String == "update",
                      let rev = update["update"] as? String {
                // `strict_conflict` makes a removed file a conflict too; without it the file is written again.
                if let existing, existing.rev != rev { return Self.conflict("path/conflict/file/") }
                if existing == nil, strict { return Self.conflict("path/conflict/file/") }
            } else {
                return Self.badRequest
            }
            revisions += 1
            let file = File(path: path, bytes: bytes, rev: Self.rev(revisions))
            files[path.lowercased()] = file
            changes.append(DropboxTreeEntry(path: path.lowercased(), kind: .file))
            return Self.json(["name": (path as NSString).lastPathComponent, "path_display": path, "rev": file.rev,
                              "size": bytes.count])
        case "/2/files/move_v2":
            guard let body = request.body,
                  let argument = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let from = argument["from_path"] as? String, var to = argument["to_path"] as? String
            else { return Self.badRequest }
            _requests.append("move \(from)")
            if exists(to) {
                var n = 1
                while exists("\(to) (\(n))") { n += 1 }
                to = "\(to) (\(n))"
            }
            let moved = remove(from)
            guard !moved.isEmpty else { return Self.conflict("from_lookup/not_found/") }
            for file in moved {
                let path = to + file.path.dropFirst(from.count)
                files[path.lowercased()] = File(path: path, bytes: file.bytes, rev: file.rev)
                changes.append(DropboxTreeEntry(path: path.lowercased(), kind: .file))
            }
            return Self.json(["metadata": ["path_display": to]])
        case "/2/files/delete_v2":
            guard let body = request.body,
                  let argument = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let path = argument["path"] as? String else { return Self.badRequest }
            _requests.append("delete \(path)")
            guard !remove(path).isEmpty else { return Self.conflict("path_lookup/not_found/") }
            return Self.json(["metadata": ["path_display": path]])
        case "/2/files/list_folder":
            guard let body = request.body,
                  let argument = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let path = argument["path"] as? String else { return Self.badRequest }
            _requests.append("list \(path)")
            let folder = path.lowercased()
            guard folder.isEmpty || exists(folder) else { return Self.conflict("path/not_found/") }
            let recursive = argument["recursive"] as? Bool ?? false
            var entries: [DropboxTreeEntry] = []
            var folders: Set<String> = []
            for key in files.keys.sorted() where key.hasPrefix(folder + "/") {
                let rest = key.dropFirst(folder.count + 1).split(separator: "/").map(String.init)
                for depth in 1..<rest.count where recursive || depth == 1 {
                    folders.insert(folder + "/" + rest[0..<depth].joined(separator: "/"))
                }
                if recursive || rest.count == 1 { entries.append(DropboxTreeEntry(path: key, kind: .file)) }
            }
            entries = folders.sorted().map { DropboxTreeEntry(path: $0, kind: .folder) } + entries
            return page(entries, folder: folder, from: changes.count)
        case "/2/files/download":
            guard let header = request.headers["Dropbox-API-Arg"],
                  let argument = try? JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any],
                  let path = argument["path"] as? String else { return Self.badRequest }
            _requests.append("download \(path)")
            let file = path.hasPrefix("rev:") ? files.values.first { "rev:" + $0.rev == path } : files[path.lowercased()]
            guard let file else { return Self.conflict("path/not_found/") }
            // As Dropbox does, the file's metadata rides in a header beside its bytes.
            let result = ["path_display": file.path, "rev": file.rev, "size": file.bytes.count,
                          "content_hash": DropboxContentHash.of(file.bytes)] as [String: Any]
            let resultHeader = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return DropboxHTTPResponse(status: 200, body: Data(file.bytes), headers: ["dropbox-api-result": resultHeader])
        case "/2/files/list_folder/continue":
            guard let body = request.body,
                  let argument = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let cursor = argument["cursor"] as? String else { return Self.badRequest }
            _requests.append("list/continue")
            guard let state = cursors[cursor] else { return Self.conflict("reset/") }
            if !state.queued.isEmpty { return page(state.queued, folder: state.folder, from: state.from) }
            let changed = changes[state.from...].filter { SyncFolderCheck.within($0.path, state.folder) }
            return page(Array(changed), folder: state.folder, from: changes.count)
        default:
            return Self.badRequest
        }
    }

    /// One page of `entries` and a new cursor that gives the rest, then the changes from `from` on.
    private func page(_ entries: [DropboxTreeEntry], folder: String, from: Int) -> DropboxHTTPResponse {
        let shown = Array(entries.prefix(_pageSize))
        let rest = Array(entries.dropFirst(_pageSize))
        cursorsMade += 1
        let cursor = "made-up-cursor-\(cursorsMade)"
        cursors[cursor] = (folder, from, rest)
        let tags: [DropboxTreeEntry.Kind: String] = [.file: "file", .folder: "folder", .deleted: "deleted"]
        let listed: [[String: Any]] = shown.map {
            var entry: [String: Any] = [".tag": tags[$0.kind] ?? "file", "name": ($0.path as NSString).lastPathComponent,
                                        "path_lower": $0.path, "path_display": $0.path]
            // A file's metadata, as Dropbox lists it (#41).
            if $0.kind == .file, let file = files[$0.path] {
                entry["id"] = "id:" + $0.path
                entry["size"] = file.bytes.count
                entry["content_hash"] = DropboxContentHash.of(file.bytes)
                entry["rev"] = file.rev
            }
            return entry
        }
        return Self.json(["entries": listed, "cursor": cursor, "has_more": !rest.isEmpty])
    }

    private func exists(_ path: String) -> Bool {
        let key = path.lowercased()
        return files.keys.contains { $0 == key || $0.hasPrefix(key + "/") }
    }

    /// Removes a file, or a folder and everything in it; returns what it removed.
    private func remove(_ path: String) -> [File] {
        let key = path.lowercased()
        let gone = files.filter { $0.key == key || $0.key.hasPrefix(key + "/") }
        for key in gone.keys { files[key] = nil }
        if !gone.isEmpty { changes.append(DropboxTreeEntry(path: key, kind: .deleted)) }
        return Array(gone.values)
    }

    private static func rev(_ n: Int) -> String {
        let hex = String(n, radix: 16)
        return String(repeating: "0", count: max(0, 9 - hex.count)) + hex
    }

    private static func json(_ object: [String: Any]) -> DropboxHTTPResponse {
        DropboxHTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private static func conflict(_ summary: String) -> DropboxHTTPResponse {
        json409(["error_summary": summary])
    }

    private static func json409(_ object: [String: Any]) -> DropboxHTTPResponse {
        DropboxHTTPResponse(status: 409, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private static let badRequest = DropboxHTTPResponse(status: 400, body: Data("made-up bad request".utf8))
}
