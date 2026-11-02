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

/// The three calls syncing a canvas needs (#12, ADR-0013's amendment): upload a file, move a folder, delete one. Each
/// is one request, renewed on a 401 as every call is, and signing out wins every race as it does for listing.
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
        guard let header = Self.apiArgument(["path": path, "mode": modeArgument, "autorename": false, "mute": true,
                                             "strict_conflict": false]) else { throw .unexpectedReply }
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
