import Foundation

/// How an upload treats a file already at its path (#12), as Dropbox's `WriteMode` says it.
public enum DropboxWriteMode: Sendable, Hashable {
    /// Only if nothing is there; a file already there is a conflict.
    case add
    /// Whatever is there.
    case overwrite
    /// Only if the file there is still the revision Vellum last wrote; anything else (changed on the laptop, or
    /// gone) is a conflict.
    case update(rev: String)
}

/// What an upload did.
public enum DropboxWriteResult: Sendable, Hashable {
    /// Written; Dropbox's revision of the file now.
    case written(rev: String)
    /// Not written: the path holds something the mode does not allow overwriting.
    case conflict
}

/// Whether a move or delete found what it was asked to move or delete.
public enum DropboxPathResult: Sendable, Hashable {
    case done
    case notFound
}

/// One entry of a recursive listing or of what changed since one (#37), its path lower-cased as Dropbox gives it.
public struct DropboxTreeEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case file, folder
        /// Something used to be at the path and is gone; for a folder, everything in it went too.
        case deleted
    }

    public var path: String
    public var kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// A recursive listing, or what changed since an earlier one, and the cursor to ask from next time.
public struct DropboxTree: Sendable, Hashable {
    public var entries: [DropboxTreeEntry]
    public var cursor: String
}

/// The calls syncing a canvas needs (#12, ADR-0013's amendments): upload a file, move a folder, delete one, and (#37)
/// list `Vellum/` or what changed in it. Each is one request (a listing follows Dropbox's paging), renewed on a 401 as every call is, and signing out wins every race as it does for listing.
extension DropboxSession {
    /// Writes `bytes` to `path` in one request (`files/upload`, up to 150 MB, far more than any canvas file).
    public func upload(_ bytes: Data, to path: String, mode: DropboxWriteMode) async throws(DropboxError)
        -> DropboxWriteResult {
        let started = generation
        guard isSignedIn else { throw .notSignedIn }
        let modeArgument: Any
        switch mode {
        case .add: modeArgument = "add"
        case .overwrite: modeArgument = "overwrite"
        case .update(let rev): modeArgument = [".tag": "update", "update": rev]
        }
        // `strict_conflict` with `update`: without it Dropbox writes a file that has been removed (WriteMode: "if
        // the target path doesn't refer to anything, the file is always written"), so a `canvas.json` deleted on the
        // laptop would come back alone instead of being noticed (#37).
        var strict = false
        if case .update = mode { strict = true }
        guard let header = Self.apiArgument(["path": path, "mode": modeArgument, "autorename": false, "mute": true,
                                             "strict_conflict": strict]) else { throw .unexpectedReply }
        let response = try await authorized(started: started, acceptingConflict: true) { tokens in
            DropboxHTTPRequest(url: DropboxEndpoint.upload, headers: [
                "Authorization": "Bearer \(tokens.accessToken)",
                "Content-Type": "application/octet-stream",
                "Dropbox-API-Arg": header,
            ], body: bytes)
        }
        if response.status == 409 {
            guard Self.summary(response).contains("conflict") else { throw .unexpectedReply }
            return .conflict
        }
        struct Reply: Decodable { let rev: String }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: response.body) else { throw .unexpectedReply }
        return .written(rev: reply.rev)
    }

    /// Moves a file or folder (`files/move_v2`). When something is already at `to`, Dropbox picks a free name beside it
    /// (`autorename`), so a canvas deleted twice under one name keeps both copies.
    public func move(_ from: String, to: String) async throws(DropboxError) -> DropboxPathResult {
        let started = generation
        guard isSignedIn else { throw .notSignedIn }
        let response = try await authorizedJSON(DropboxEndpoint.move, [
            "from_path": from, "to_path": to, "autorename": true, "allow_ownership_transfer": false,
        ], started: started, acceptingConflict: true)
        if response.status == 409 {
            guard Self.summary(response).contains("from_lookup/not_found") else { throw .unexpectedReply }
            return .notFound
        }
        return .done
    }

    /// Deletes a file or folder (`files/delete_v2`); Dropbox keeps it among its deleted files.
    public func delete(_ path: String) async throws(DropboxError) -> DropboxPathResult {
        let started = generation
        guard isSignedIn else { throw .notSignedIn }
        let response = try await authorizedJSON(DropboxEndpoint.delete, ["path": path], started: started,
                                                acceptingConflict: true)
        if response.status == 409 {
            guard Self.summary(response).contains("not_found") else { throw .unexpectedReply }
            return .notFound
        }
        return .done
    }

    /// Every file and folder under `path` at any depth (`files/list_folder`, recursive, following its paging), and
    /// the cursor that asks later for what changed since; nil when nothing is at `path` (#37).
    public func tree(under path: String) async throws(DropboxError) -> DropboxTree? {
        let started = generation
        guard isSignedIn else { throw .notSignedIn }
        let first = try await authorizedJSON(DropboxEndpoint.listFolder, [
            "path": path, "recursive": true, "include_deleted": false,
        ], started: started, acceptingConflict: true)
        if first.status == 409 {
            guard Self.summary(first).contains("not_found") else { throw .unexpectedReply }
            return nil
        }
        var page = try Self.treePage(first)
        var entries = page.entries
        while page.hasMore {
            guard let next = try await treePage(after: page.cursor, started: started) else { throw .unexpectedReply }
            page = next
            entries += page.entries
        }
        return DropboxTree(entries: entries, cursor: page.cursor)
    }

    /// Every file directly inside `path` with its size, content hash and revision (`files/list_folder`, following its
    /// paging), for the symbol library's sync (#41); nil when nothing is at `path`.
    public func files(in path: String) async throws(DropboxError) -> [DropboxFile]? {
        let started = generation
        guard isSignedIn else { throw .notSignedIn }
        var response = try await authorizedJSON(DropboxEndpoint.listFolder, [
            "path": path, "recursive": false, "include_deleted": false,
        ], started: started, acceptingConflict: true)
        if response.status == 409 {
            guard Self.summary(response).contains("not_found") else { throw .unexpectedReply }
            return nil
        }
        var files: [DropboxFile] = []
        while true {
            struct Reply: Decodable {
                struct Entry: Decodable {
                    let tag: String
                    let id: String?
                    let name: String
                    let path_display: String?
                    let size: Int?
                    let content_hash: String?
                    let rev: String?
                    enum CodingKeys: String, CodingKey { case tag = ".tag", id, name, path_display, size, content_hash, rev }
                }
                let entries: [Entry]
                let cursor: String
                let has_more: Bool
            }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: response.body) else { throw .unexpectedReply }
            for entry in reply.entries where entry.tag == "file" {
                guard let size = entry.size else { continue }
                let filePath = entry.path_display ?? "\(path)/\(entry.name)"
                files.append(DropboxFile(id: entry.id ?? filePath, name: entry.name, path: filePath, size: size,
                                         contentHash: entry.content_hash ?? "", rev: entry.rev ?? ""))
            }
            guard reply.has_more else { return files }
            response = try await authorizedJSON(DropboxEndpoint.listFolderContinue, ["cursor": reply.cursor],
                                                started: started)
        }
    }

    /// The file at `path` as it is now (`files/download`, one request), for the drawing index's shards and thumbnails
    /// (#68), whose names are the hash of their bytes, so the caller checks what came down by its name; nil when
    /// nothing is at `path`.
    public func download(path: String) async throws(DropboxError) -> Data? {
        let started = generation
        guard isSignedIn else { throw .notSignedIn }
        guard let header = Self.apiArgument(["path": path]) else { throw .unexpectedReply }
        let response = try await authorized(started: started, acceptingConflict: true) { tokens in
            DropboxHTTPRequest(url: DropboxEndpoint.download, headers: [
                "Authorization": "Bearer \(tokens.accessToken)",
                "Dropbox-API-Arg": header,
            ])
        }
        if response.status == 409 {
            guard Self.summary(response).contains("not_found") else { throw .unexpectedReply }
            return nil
        }
        return response.body
    }

    /// A drawing's PDF at `path` as it is now (`files/download`, one request), with the content hash Dropbox gives for
    /// exactly those bytes in the reply's `Dropbox-API-Result` (#69): the drawing index names its PDF by path and the
    /// hash it had when the laptop read it, so the bytes that came down are kept under the hash Dropbox says they have,
    /// even if the PDF changed since. `progress` hears how much of it has come. Nil when nothing is at `path`.
    public func downloadPDF(path: String, progress: (@Sendable (Double) -> Void)? = nil) async throws(DropboxError)
        -> DropboxDownload? {
        let started = generation
        guard isSignedIn else { throw .notSignedIn }
        guard let header = Self.apiArgument(["path": path]) else { throw .unexpectedReply }
        let response = try await authorized(started: started, acceptingConflict: true, progress: progress) { tokens in
            DropboxHTTPRequest(url: DropboxEndpoint.download, headers: [
                "Authorization": "Bearer \(tokens.accessToken)",
                "Dropbox-API-Arg": header,
            ])
        }
        if response.status == 409 {
            guard Self.summary(response).contains("not_found") else { throw .unexpectedReply }
            return nil
        }
        struct Result: Decodable {
            let content_hash: String?
            let size: Int?
        }
        let result = response.headers["dropbox-api-result"].flatMap {
            try? JSONDecoder().decode(Result.self, from: Data($0.utf8))
        }
        if let size = result?.size, size != response.body.count { throw .unexpectedReply }
        return DropboxDownload(bytes: response.body, contentHash: result?.content_hash)
    }

    /// What changed under the listed folder since `cursor` (`files/list_folder/continue`, following its paging), in
    /// Dropbox's order, deletions included; nil when Dropbox can't say (the cursor was reset, or the folder is gone),
    /// so the folder has to be listed again (#37).
    public func treeChanges(since cursor: String) async throws(DropboxError) -> DropboxTree? {
        let started = generation
        guard isSignedIn else { throw .notSignedIn }
        var entries: [DropboxTreeEntry] = []
        var cursor = cursor
        while true {
            guard let page = try await treePage(after: cursor, started: started) else { return nil }
            entries += page.entries
            cursor = page.cursor
            if !page.hasMore { return DropboxTree(entries: entries, cursor: cursor) }
        }
    }

    private struct TreePage {
        var entries: [DropboxTreeEntry]
        var cursor: String
        var hasMore: Bool
    }

    private func treePage(after cursor: String, started: Int) async throws(DropboxError) -> TreePage? {
        let response = try await authorizedJSON(DropboxEndpoint.listFolderContinue, ["cursor": cursor],
                                                started: started, acceptingConflict: true)
        if response.status == 409 {
            let summary = Self.summary(response)
            guard summary.contains("reset") || summary.contains("not_found") else { throw .unexpectedReply }
            return nil
        }
        return try Self.treePage(response)
    }

    private static func treePage(_ response: DropboxHTTPResponse) throws(DropboxError) -> TreePage {
        struct Reply: Decodable {
            struct Entry: Decodable {
                let tag: String
                let name: String
                let path_lower: String?
                enum CodingKeys: String, CodingKey { case tag = ".tag", name, path_lower }
            }
            let entries: [Entry]
            let cursor: String
            let has_more: Bool
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: response.body) else { throw .unexpectedReply }
        let entries = reply.entries.compactMap { entry -> DropboxTreeEntry? in
            guard let path = entry.path_lower else { return nil }
            switch entry.tag {
            case "file": return DropboxTreeEntry(path: path, kind: .file)
            case "folder": return DropboxTreeEntry(path: path, kind: .folder)
            case "deleted": return DropboxTreeEntry(path: path, kind: .deleted)
            default: return nil
            }
        }
        return TreePage(entries: entries, cursor: reply.cursor, hasMore: reply.has_more)
    }

    private static func summary(_ response: DropboxHTTPResponse) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    /// A `Dropbox-API-Arg` header: the JSON with every character past ASCII escaped as `\uXXXX`, as Dropbox requires of
    /// a header, so a canvas named "Café" or with an emoji uploads.
    static func apiArgument(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        var out = ""
        out.reserveCapacity(json.utf8.count)
        for unit in json.utf16 {
            if unit < 0x7F {
                out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            } else {
                out += String(format: "\\u%04x", unit)
            }
        }
        return out
    }
}

/// A file downloaded whole, with the content hash Dropbox gave for its bytes, or nil when the reply didn't say.
public struct DropboxDownload: Sendable, Equatable {
    public var bytes: Data
    public var contentHash: String?

    public init(bytes: Data, contentHash: String?) {
        self.bytes = bytes
        self.contentHash = contentHash
    }
}
