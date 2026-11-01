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

/// Vellum's connection to Zach's Dropbox: signs in with PKCE, keeps the tokens in its store, renews the access token
/// before it lapses (or once when Dropbox says it has), lists folders and signs out. The transport does the HTTP, so
/// every decision here runs in `swift test`.
public actor DropboxSession {
    public let appKey: DropboxAppKey
    private let transport: any DropboxTransport
    private let store: any DropboxTokenStore
    private let now: @Sendable () -> Date

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

    /// Trades the callback's code for tokens and keeps them.
    public func finishSignIn(_ attempt: DropboxSignInAttempt, callback: URL) async throws(DropboxError) {
        let code = try attempt.code(fromCallback: callback)
        let response = try await send(attempt.tokenRequest(code: code))
        let tokens = try DropboxTokens.parse(response, now: now())
        try keep(tokens)
    }

    /// The folders at the top of Zach's Dropbox, by name.
    public func topLevelFolders() async throws(DropboxError) -> [DropboxFolder] {
        try await folders(in: "")
    }

    /// The folders directly inside `path` ("" is the top of the Dropbox), by name, following Dropbox's paging.
    public func folders(in path: String) async throws(DropboxError) -> [DropboxFolder] {
        var page = try await listPage(try authorizedJSON(DropboxEndpoint.listFolder,
                                                         ["path": path, "recursive": false, "include_deleted": false]))
        var folders = page.folders
        while page.hasMore {
            page = try await listPage(try authorizedJSON(DropboxEndpoint.listFolderContinue, ["cursor": page.cursor]))
            folders += page.folders
        }
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Revokes the token with Dropbox when it can and always removes it from the store, so signing out works offline.
    public func signOut() async {
        if let tokens = (try? store.load()) ?? nil {
            let revoke = DropboxHTTPRequest(url: DropboxEndpoint.revoke,
                                            headers: ["Authorization": "Bearer \(tokens.accessToken)"])
            _ = try? await transport.send(revoke)
        }
        try? store.delete()
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
    private func authorizedJSON(_ url: URL, _ arguments: [String: any Sendable]) async throws(DropboxError)
        -> DropboxHTTPResponse {
        guard let body = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else {
            throw .unexpectedReply
        }
        var tokens = try current()
        if tokens.needsRefresh(at: now()) { tokens = try await refresh(tokens) }
        var response = try await send(request(url, body, tokens))
        if response.status == 401 {
            tokens = try await refresh(tokens)
            response = try await send(request(url, body, tokens))
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

    /// Renews the access token. A refusal removes the tokens, since they will never work again; being offline keeps
    /// them for when the Duo is back online.
    private func refresh(_ tokens: DropboxTokens) async throws(DropboxError) -> DropboxTokens {
        let request = DropboxHTTPRequest.form(DropboxEndpoint.token, [
            ("grant_type", "refresh_token"),
            ("refresh_token", tokens.refreshToken),
            ("client_id", appKey.value),
        ])
        let response = try await send(request)
        do {
            let renewed = try DropboxTokens.parse(response, now: now(), refreshing: tokens.refreshToken)
            try keep(renewed)
            return renewed
        } catch {
            if error == .signInExpired { try? store.delete() }
            throw error
        }
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
