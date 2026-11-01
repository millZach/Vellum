import Foundation

/// A folder in Zach's Dropbox.
public struct DropboxFolder: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// The folder's path with Dropbox's capitalisation, such as `/Projects`.
    public let path: String

    public init(id: String, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// How a sign-out went. The tokens are gone from the Duo either way; this says whether Dropbox ended the sign-in too.
public enum DropboxSignOutOutcome: Sendable, Equatable {
    /// Dropbox ended the sign-in (or it had already ended there).
    case revoked
    /// Vellum couldn't tell Dropbox, for this reason, so the sign-in still stands at Dropbox's end.
    case notRevoked(DropboxError)

    /// What the screen says after signing out, or nil when there is nothing to add to "Not connected".
    public var message: String? {
        switch self {
        case .revoked:
            nil
        case .notRevoked(let reason):
            (reason == .offline ? "Signed out on this Duo while offline, so Dropbox wasn't told. "
                : "Signed out on this Duo, but Dropbox didn't confirm it ended the sign-in. ")
                + "To end it there, remove Vellum from the connected apps in your Dropbox account settings."
        }
    }
}

/// Vellum's connection to Zach's Dropbox: signs in with PKCE, keeps the tokens in its store, renews the access token
/// before it lapses (or once when Dropbox says it has), lists folders and signs out. The transport does the HTTP, so
/// every decision here runs in `swift test`.
///
/// Signing out wins every race. Each call notes the sign-out generation when it starts and checks it after every
/// `await`; signing out moves the generation on when it starts and again when it ends, so a refresh, sign-in or folder
/// load still in flight never writes tokens back or returns results, and throws `notSignedIn` instead.
public actor DropboxSession {
    public let appKey: DropboxAppKey
    private let transport: any DropboxTransport
    private let store: any DropboxTokenStore
    private let now: @Sendable () -> Date
    private var generation = 0

    public init(appKey: DropboxAppKey, transport: any DropboxTransport, store: any DropboxTokenStore,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.appKey = appKey
        self.transport = transport
        self.store = store
        self.now = now
    }

    /// True when the store holds tokens. It does not ask Dropbox, so it answers offline.
    public var isSignedIn: Bool { ((try? store.load()) ?? nil) != nil }

    public nonisolated func beginSignIn() -> DropboxSignInAttempt { DropboxSignInAttempt(appKey: appKey) }

    /// Trades the callback's code for tokens and keeps them, unless Zach signed out meanwhile.
    public func finishSignIn(_ attempt: DropboxSignInAttempt, callback: URL) async throws(DropboxError) {
        let started = generation
        let code = try attempt.code(fromCallback: callback)
        let response = try await send(attempt.tokenRequest(code: code))
        try still(started)
        let tokens = try DropboxTokens.parse(response, now: now())
        try keep(tokens)
    }

    /// The folders at the top of Zach's Dropbox, by name.
    public func topLevelFolders() async throws(DropboxError) -> [DropboxFolder] {
        try await folders(in: "")
    }

    /// The folders directly inside `path` ("" is the top of the Dropbox), by name, following Dropbox's paging.
    public func folders(in path: String) async throws(DropboxError) -> [DropboxFolder] {
        let started = generation
        var page = try await listPage(try authorizedJSON(DropboxEndpoint.listFolder,
                                                         ["path": path, "recursive": false, "include_deleted": false],
                                                         started: started))
        var folders = page.folders
        while page.hasMore {
            page = try await listPage(try authorizedJSON(DropboxEndpoint.listFolderContinue, ["cursor": page.cursor],
                                                         started: started))
            folders += page.folders
        }
        try still(started)
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Asks Dropbox to end the sign-in, renewing the access token first when it has lapsed, then removes the tokens
    /// from the store. Being offline or refused by Dropbox still removes them and says so in the outcome; only a store
    /// that won't delete them throws (`couldNotRemoveSignIn`), so a success always means the tokens are gone.
    public func signOut() async throws(DropboxError) -> DropboxSignOutOutcome {
        generation += 1
        defer { generation += 1 }
        let outcome: DropboxSignOutOutcome
        if let tokens = (try? store.load()) ?? nil {
            outcome = await revoke(tokens)
        } else {
            outcome = .revoked
        }
        do { try store.delete() } catch { throw .couldNotRemoveSignIn }
        return outcome
    }

    // MARK: - Signing out

    private func revoke(_ tokens: DropboxTokens) async -> DropboxSignOutOutcome {
        var tokens = tokens
        var renewed = false
        do {
            if tokens.needsRefresh(at: now()) {
                tokens = try await renew(tokens)
                renewed = true
            }
            var response = try await send(revokeRequest(tokens))
            if response.status == 401, !renewed {
                tokens = try await renew(tokens)
                response = try await send(revokeRequest(tokens))
            }
            switch response.status {
            case 200: return .revoked
            case 429, 500...: return .notRevoked(.dropboxUnavailable)
            default: return .notRevoked(.unexpectedReply)
            }
        } catch {
            // A refused renewal means Dropbox has already ended the sign-in.
            return error == .signInExpired ? .revoked : .notRevoked(error)
        }
    }

    private func revokeRequest(_ tokens: DropboxTokens) -> DropboxHTTPRequest {
        DropboxHTTPRequest(url: DropboxEndpoint.revoke, headers: ["Authorization": "Bearer \(tokens.accessToken)"])
    }

    // MARK: - Requests

    private struct Page {
        var folders: [DropboxFolder]
        var cursor: String
        var hasMore: Bool
    }

    private func listPage(_ response: DropboxHTTPResponse) throws(DropboxError) -> Page {
        struct Reply: Decodable {
            struct Entry: Decodable {
                let tag: String
                let id: String?
                let name: String
                let path_display: String?
                enum CodingKeys: String, CodingKey { case tag = ".tag", id, name, path_display }
            }
            let entries: [Entry]
            let cursor: String
            let has_more: Bool
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: response.body) else { throw .unexpectedReply }
        let folders = reply.entries.filter { $0.tag == "folder" }.map {
            DropboxFolder(id: $0.id ?? $0.path_display ?? $0.name, name: $0.name, path: $0.path_display ?? "/\($0.name)")
        }
        return Page(folders: folders, cursor: reply.cursor, hasMore: reply.has_more)
    }

    /// An authorized JSON call to Dropbox's API. Renews the access token first when it is about to lapse, and once more
    /// if Dropbox answers 401; a second 401 means the sign-in is gone.
    private func authorizedJSON(_ url: URL, _ arguments: [String: any Sendable], started: Int) async throws(DropboxError)
        -> DropboxHTTPResponse {
        guard let body = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else {
            throw .unexpectedReply
        }
        try still(started)
        var tokens = try current()
        if tokens.needsRefresh(at: now()) { tokens = try await refresh(tokens, started: started) }
        var response = try await send(request(url, body, tokens))
        try still(started)
        if response.status == 401 {
            tokens = try await refresh(tokens, started: started)
            response = try await send(request(url, body, tokens))
            try still(started)
            if response.status == 401 {
                try? store.delete()
                throw .signInExpired
            }
        }
        guard response.status == 200 else {
            throw response.status == 429 || response.status >= 500 ? .dropboxUnavailable : .unexpectedReply
        }
        return response
    }

    private func request(_ url: URL, _ body: Data, _ tokens: DropboxTokens) -> DropboxHTTPRequest {
        DropboxHTTPRequest(url: url, headers: ["Authorization": "Bearer \(tokens.accessToken)",
                                               "Content-Type": "application/json"], body: body)
    }

    private func current() throws(DropboxError) -> DropboxTokens {
        guard let tokens = (try? store.load()) ?? nil else { throw .notSignedIn }
        return tokens
    }

    /// Renews the access token and keeps it, unless Zach signed out meanwhile. A refusal removes the tokens, since they
    /// will never work again; being offline keeps them for when the Duo is back online.
    private func refresh(_ tokens: DropboxTokens, started: Int) async throws(DropboxError) -> DropboxTokens {
        do {
            let renewed = try await renew(tokens)
            try still(started)
            try keep(renewed)
            return renewed
        } catch {
            try still(started)
            if error == .signInExpired { try? store.delete() }
            throw error
        }
    }

    /// Asks Dropbox for a new access token; keeps nothing.
    private func renew(_ tokens: DropboxTokens) async throws(DropboxError) -> DropboxTokens {
        let request = DropboxHTTPRequest.form(DropboxEndpoint.token, [
            ("grant_type", "refresh_token"),
            ("refresh_token", tokens.refreshToken),
            ("client_id", appKey.value),
        ])
        let response = try await send(request)
        return try DropboxTokens.parse(response, now: now(), refreshing: tokens.refreshToken)
    }

    /// Throws `notSignedIn` when Zach signed out after the call that noted `started` began.
    private func still(_ started: Int) throws(DropboxError) {
        guard generation == started else { throw .notSignedIn }
    }

    private func keep(_ tokens: DropboxTokens) throws(DropboxError) {
        do { try store.save(tokens) } catch { throw .couldNotKeepSignIn }
    }

    private func send(_ request: DropboxHTTPRequest) async throws(DropboxError) -> DropboxHTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as DropboxError {
            throw error
        } catch {
            throw .dropboxUnavailable
        }
    }
}
