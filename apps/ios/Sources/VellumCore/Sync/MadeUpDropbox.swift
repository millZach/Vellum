import Foundation

/// A made-up Dropbox, in memory, that answers the requests syncing makes (`files/upload`, `files/move_v2`,
/// `files/delete_v2` and token renewal) the way Dropbox does, behind the same transport seam the live client uses.
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
        }
    }

    public func removeOnTheLaptop(_ path: String) {
        lock.withLock { _ = remove(path) }
    }

    // MARK: Answering

    public func send(_ request: DropboxHTTPRequest) async throws -> DropboxHTTPResponse {
        try lock.withLock { try answer(request) }
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
            switch argument["mode"] {
            case let mode as String where mode == "add":
                if existing != nil { return Self.conflict("path/conflict/file/") }
            case let mode as String where mode == "overwrite":
                break
            case let mode as [String: Any]:
                guard mode[".tag"] as? String == "update", let rev = mode["update"] as? String else { return Self.badRequest }
                if existing?.rev != rev { return Self.conflict("path/conflict/file/") }
            default:
                return Self.badRequest
            }
            revisions += 1
            let file = File(path: path, bytes: bytes, rev: Self.rev(revisions))
            files[path.lowercased()] = file
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
            }
            return Self.json(["metadata": ["path_display": to]])
        case "/2/files/delete_v2":
            guard let body = request.body,
                  let argument = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let path = argument["path"] as? String else { return Self.badRequest }
            _requests.append("delete \(path)")
            guard !remove(path).isEmpty else { return Self.conflict("path_lookup/not_found/") }
            return Self.json(["metadata": ["path_display": path]])
        default:
            return Self.badRequest
        }
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
