import Foundation

/// A folder in Zach's Dropbox.
public struct DropboxFolder: Codable, Sendable, Equatable, Identifiable {
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

/// How a sign-out went at Dropbox's end. The tokens are already gone from the Duo; this says whether Dropbox ended the
/// sign-in too.
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

/// A sign-out that has already removed the tokens from the Duo, with Dropbox being told in the background.
public struct DropboxSignOut: Sendable {
    private let report: Task<DropboxSignOutOutcome, Never>

    init(_ report: Task<DropboxSignOutOutcome, Never>) { self.report = report }

    /// Whether Dropbox ended the sign-in; answers within the session's revoke deadline.
    public var outcome: DropboxSignOutOutcome { get async { await report.value } }
}

/// What Vellum knows about the sign-in without asking Dropbox.
public enum DropboxKeptState: Sendable, Equatable {
    case signedOut
    /// Signed in, with the folders kept from the last visit, or nil when none are kept.
    case signedIn(keptFolders: [DropboxFolder]?)
}

/// Vellum's connection to Zach's Dropbox: signs in with PKCE, keeps the tokens in its store, renews the access token
/// before it lapses (or once when Dropbox says it has), lists folders and signs out. The transport does the HTTP, so
/// every decision here runs in `swift test`.
///
/// It keeps traffic small. The tokens are read from the store once and written only when they change. A folder's
/// listing and Dropbox's cursor for it are kept, so a later look asks only for what changed, and none at all within
/// `recentCheck` of the last. Callers that ask at the same time share one listing and one token renewal.
///
/// Signing out wins every race. Each call notes the sign-out generation when it starts and checks it after every
/// `await`; signing out moves the generation on, so a refresh, sign-in or folder load still in flight never writes
/// tokens back or returns results, and throws `notSignedIn` instead. Signing out removes the tokens at once and tells
/// Dropbox afterwards, giving it `revokeDeadline` to confirm.
public actor DropboxSession {
    /// How long a listing Dropbox confirmed counts as fresh enough to show without asking again.
    public static let recentCheck: TimeInterval = 60

    public let appKey: DropboxAppKey
    private let transport: any DropboxTransport
    private let store: any DropboxTokenStore
    private let listingStore: any DropboxListingStore
    private let now: @Sendable () -> Date
    private let revokeDeadline: Duration
    private var generation = 0

    private enum Kept { case unread, none, some(DropboxTokens) }
    private typealias Shared<Value: Sendable> = (generation: Int, task: Task<Result<Value, DropboxError>, Never>)
    private var kept = Kept.unread
    private var listings: [String: DropboxListing]?
    private var renewal: Shared<DropboxTokens>?
    private var listingsInFlight: [String: Shared<[DropboxFolder]>] = [:]

    public init(appKey: DropboxAppKey, transport: any DropboxTransport, store: any DropboxTokenStore,
                listings: any DropboxListingStore = DropboxMemoryListingStore(), revokeDeadline: Duration = .seconds(4),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.appKey = appKey
        self.transport = transport
        self.store = store
        listingStore = listings
        self.revokeDeadline = revokeDeadline
        self.now = now
    }

    /// True when Vellum holds tokens. It does not ask Dropbox, so it answers offline.
    public var isSignedIn: Bool { tokens() != nil }

    /// Whether Vellum is signed in, and the folders it kept for `path` from the last visit; asks Dropbox nothing.
    public func keptState(in path: String = "") -> DropboxKeptState {
        guard isSignedIn else { return .signedOut }
        return .signedIn(keptFolders: keptListing(path)?.folders)
    }

    public nonisolated func beginSignIn() -> DropboxSignInAttempt { DropboxSignInAttempt(appKey: appKey) }

    /// Trades the callback's code for tokens and keeps them, unless Zach signed out meanwhile.
    public func finishSignIn(_ attempt: DropboxSignInAttempt, callback: URL) async throws(DropboxError) {
        let started = generation
        let code = try attempt.code(fromCallback: callback)
        let response = try await send(attempt.tokenRequest(code: code))
        try still(started)
        let tokens = try DropboxTokens.parse(response, now: now())
        forgetListings()
        try keep(tokens)
    }

    /// The folders at the top of Zach's Dropbox, by name.
    public func topLevelFolders(freshness: DropboxFreshness = .now) async throws(DropboxError) -> [DropboxFolder] {
        try await folders(in: "", freshness: freshness)
    }

    /// The folders directly inside `path` ("" is the top of the Dropbox), by name. With a kept listing it asks Dropbox
    /// only what changed, and nothing within `recentCheck` of the last check when `freshness` is `.recent`; without
    /// one it lists the folder, following Dropbox's paging, and hands each page to `partial` as it arrives (merged with
    /// the pages before it) so the screen can show the first page at once. A call made while another for the same
    /// path is in flight waits for that one instead of starting its own; only the first caller's `partial` hears pages.
    public func folders(in path: String, freshness: DropboxFreshness = .now,
                        partial: (@Sendable ([DropboxFolder]) async -> Void)? = nil) async throws(DropboxError)
        -> [DropboxFolder] {
        let started = generation
        guard isSignedIn else { throw .notSignedIn }
        if freshness == .recent, let kept = keptListing(path), now().timeIntervalSince(kept.checkedAt) < Self.recentCheck {
            return kept.folders
        }
        let result: Result<[DropboxFolder], DropboxError>
        if let shared = listingsInFlight[path], shared.generation == started {
            result = await shared.task.value
        } else {
            let task = Task { await self.list(path, started: started, partial: partial) }
            listingsInFlight[path] = (started, task)
            result = await task.value
            if listingsInFlight[path]?.task == task { listingsInFlight[path] = nil }
        }
        try still(started)
        return try result.get()
    }

    /// Removes the tokens and kept listings from the Duo at once, then asks Dropbox in the background to end the
    /// sign-in, renewing the access token first when it has lapsed. Only a store that won't delete the tokens throws
    /// (`couldNotRemoveSignIn`), and then Dropbox is not told either, so a success always means the tokens are gone.
    /// Being offline, refused, or slower than `revokeDeadline` shows in the outcome.
    public func signOut() throws(DropboxError) -> DropboxSignOut {
        generation += 1
        renewal = nil
        listingsInFlight = [:]
        let tokens = tokens()
        do { try store.delete() } catch { throw .couldNotRemoveSignIn }
        kept = .none
        forgetListings()
        guard let tokens else { return DropboxSignOut(Task { .revoked }) }
        let deadline = revokeDeadline
        return DropboxSignOut(Task.detached { [self] in
            await Self.first(of: { await self.revoke(tokens) }, orAfter: deadline,
                             .notRevoked(.dropboxUnavailable))
        })
    }

    // MARK: - Signing out

    private nonisolated func revoke(_ tokens: DropboxTokens) async -> DropboxSignOutOutcome {
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

    private nonisolated func revokeRequest(_ tokens: DropboxTokens) -> DropboxHTTPRequest {
        DropboxHTTPRequest(url: DropboxEndpoint.revoke, headers: ["Authorization": "Bearer \(tokens.accessToken)"])
    }

    /// The answer of `work`, or `fallback` once `deadline` passes, whichever comes first; a late `work` is cancelled.
    private static func first<Value: Sendable>(of work: @escaping @Sendable () async -> Value, orAfter deadline: Duration,
                                               _ fallback: Value) async -> Value {
        let answer = FirstAnswer<Value>()
        return await withCheckedContinuation { continuation in
            answer.waiting = continuation
            let working = Task { answer.give(await work()) }
            let timer = Task {
                try? await Task.sleep(for: deadline)
                answer.give(fallback)
                working.cancel()
            }
            Task {
                _ = await working.value
                timer.cancel()
            }
        }
    }

    // MARK: - Listing

    private func list(_ path: String, started: Int, partial: (@Sendable ([DropboxFolder]) async -> Void)?) async
        -> Result<[DropboxFolder], DropboxError> {
        do {
            var listing: DropboxListing
            if let previous = keptListing(path), let changed = try await changes(since: previous, started: started, partial: partial) {
                listing = changed
            } else {
                listing = try await fullListing(path, started: started, partial: keptListing(path) == nil ? partial : nil)
            }
            try still(started)
            listing.checkedAt = now()
            var all = listings ?? [:]
            all[path] = listing
            listings = all
            listingStore.save(all)
            return .success(listing.folders)
        } catch {
            return .failure(error)
        }
    }

    private func fullListing(_ path: String, started: Int, partial: (@Sendable ([DropboxFolder]) async -> Void)?)
        async throws(DropboxError) -> DropboxListing {
        var page = try listPage(try await authorizedJSON(
            DropboxEndpoint.listFolder, ["path": path, "recursive": false, "include_deleted": false], started: started))
        var folders: [String: DropboxFolder] = [:]
        page.apply(to: &folders)
        while page.hasMore {
            await partial?(Self.sorted(folders))
            try still(started)
            page = try listPage(try await authorizedJSON(DropboxEndpoint.listFolderContinue, ["cursor": page.cursor],
                                                         started: started))
            page.apply(to: &folders)
        }
        return DropboxListing(folders: Self.sorted(folders), cursor: page.cursor, checkedAt: now())
    }

    /// The kept listing with Dropbox's changes since its cursor applied, or nil when Dropbox says the cursor has to
    /// be reset, so the folder has to be listed again.
    private func changes(since kept: DropboxListing, started: Int, partial: (@Sendable ([DropboxFolder]) async -> Void)?)
        async throws(DropboxError) -> DropboxListing? {
        var folders = Dictionary(kept.folders.map { (Self.key($0.path), $0) }) { $1 }
        var cursor = kept.cursor
        var first = true
        while true {
            if !first {
                await partial?(Self.sorted(folders))
                try still(started)
            }
            first = false
            let response = try await authorizedJSON(DropboxEndpoint.listFolderContinue, ["cursor": cursor],
                                                    started: started, acceptingConflict: true)
            if response.status == 409 {
                guard String(decoding: response.body, as: UTF8.self).contains("reset") else { throw .unexpectedReply }
                return nil
            }
            let page = try listPage(response)
            page.apply(to: &folders)
            cursor = page.cursor
            if !page.hasMore { break }
        }
        return DropboxListing(folders: Self.sorted(folders), cursor: cursor, checkedAt: now())
    }

    private func keptListing(_ path: String) -> DropboxListing? {
        if listings == nil { listings = listingStore.load() }
        return listings?[path]
    }

    private func forgetListings() {
        listings = [:]
        listingStore.delete()
    }

    private static func key(_ path: String) -> String { path.lowercased() }

    private static func sorted(_ folders: [String: DropboxFolder]) -> [DropboxFolder] {
        folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct Page {
        enum Entry {
            case folder(DropboxFolder)
            /// Anything at this path that is no longer a folder: deleted, or a file now.
            case gone(String)
        }
        var entries: [Entry]
        var cursor: String
        var hasMore: Bool

        func apply(to folders: inout [String: DropboxFolder]) {
            for entry in entries {
                switch entry {
                case .folder(let folder): folders[DropboxSession.key(folder.path)] = folder
                case .gone(let key): folders[key] = nil
                }
            }
        }
    }

    private func listPage(_ response: DropboxHTTPResponse) throws(DropboxError) -> Page {
        struct Reply: Decodable {
            struct Entry: Decodable {
                let tag: String
                let id: String?
                let name: String
                let path_display: String?
                let path_lower: String?
                enum CodingKeys: String, CodingKey { case tag = ".tag", id, name, path_display, path_lower }
            }
            let entries: [Entry]
            let cursor: String
            let has_more: Bool
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: response.body) else { throw .unexpectedReply }
        let entries: [Page.Entry] = reply.entries.map {
            let path = $0.path_display ?? "/\($0.name)"
            guard $0.tag == "folder" else { return .gone($0.path_lower ?? Self.key(path)) }
            return .folder(DropboxFolder(id: $0.id ?? path, name: $0.name, path: path))
        }
        return Page(entries: entries, cursor: reply.cursor, hasMore: reply.has_more)
    }

    // MARK: - Requests

    /// An authorized JSON call to Dropbox's API. Renews the access token first when it is about to lapse, and once more
    /// if Dropbox answers 401; a second 401 means the sign-in is gone. A 409 comes back to the caller when it asks.
    private func authorizedJSON(_ url: URL, _ arguments: [String: any Sendable], started: Int,
                                acceptingConflict: Bool = false) async throws(DropboxError) -> DropboxHTTPResponse {
        guard let body = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else {
            throw .unexpectedReply
        }
        try still(started)
        guard var tokens = tokens() else { throw .notSignedIn }
        if tokens.needsRefresh(at: now()) { tokens = try await refresh(tokens, started: started) }
        var response = try await send(request(url, body, tokens))
        try still(started)
        if response.status == 401 {
            tokens = try await refresh(tokens, started: started)
            response = try await send(request(url, body, tokens))
            try still(started)
            if response.status == 401 {
                forgetSignIn()
                throw .signInExpired
            }
        }
        if response.status == 200 || (acceptingConflict && response.status == 409) { return response }
        throw response.status == 429 || response.status >= 500 ? .dropboxUnavailable : .unexpectedReply
    }

    private func request(_ url: URL, _ body: Data, _ tokens: DropboxTokens) -> DropboxHTTPRequest {
        DropboxHTTPRequest(url: url, headers: ["Authorization": "Bearer \(tokens.accessToken)",
                                               "Content-Type": "application/json"], body: body)
    }

    /// The tokens, read from the store the first time only. A store that can't be read now (a Keychain before the
    /// first unlock) is asked again next time.
    private func tokens() -> DropboxTokens? {
        switch kept {
        case .some(let tokens): return tokens
        case .none: return nil
        case .unread:
            let loaded: DropboxTokens?
            do { loaded = try store.load() } catch { return nil }
            kept = loaded.map(Kept.some) ?? .none
            return loaded
        }
    }

    /// Renews the access token and keeps it, unless Zach signed out meanwhile. Callers renewing at the same time share
    /// one renewal, and a caller holding tokens another call has already renewed gets the new ones without asking. A
    /// refusal removes the tokens, since they will never work again; being offline keeps them for when the Duo is back
    /// online.
    private func refresh(_ tokens: DropboxTokens, started: Int) async throws(DropboxError) -> DropboxTokens {
        if case .some(let current) = kept, current.accessToken != tokens.accessToken, !current.needsRefresh(at: now()) {
            return current
        }
        let result: Result<DropboxTokens, DropboxError>
        if let shared = renewal, shared.generation == started {
            result = await shared.task.value
        } else {
            let task = Task { await self.performRefresh(tokens, started: started) }
            renewal = (started, task)
            result = await task.value
            if renewal?.task == task { renewal = nil }
        }
        try still(started)
        return try result.get()
    }

    private func performRefresh(_ tokens: DropboxTokens, started: Int) async -> Result<DropboxTokens, DropboxError> {
        do {
            let renewed = try await renew(tokens)
            try still(started)
            try keep(renewed)
            return .success(renewed)
        } catch {
            if generation == started, error == .signInExpired { forgetSignIn() }
            return .failure(generation == started ? error : .notSignedIn)
        }
    }

    /// Asks Dropbox for a new access token; keeps nothing.
    private nonisolated func renew(_ tokens: DropboxTokens) async throws(DropboxError) -> DropboxTokens {
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
        kept = .some(tokens)
    }

    /// Dropbox refused the tokens for good: forget them and what they listed.
    private func forgetSignIn() {
        try? store.delete()
        kept = .none
        forgetListings()
    }

    private nonisolated func send(_ request: DropboxHTTPRequest) async throws(DropboxError) -> DropboxHTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as DropboxError {
            throw error
        } catch {
            throw .dropboxUnavailable
        }
    }
}

/// Hands a waiting continuation the first value it is given and drops the rest.
private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var answered = false

    var waiting: CheckedContinuation<Value, Never>? {
        get { lock.withLock { continuation } }
        set { lock.withLock { continuation = newValue } }
    }

    func give(_ value: Value) {
        let waiting: CheckedContinuation<Value, Never>? = lock.withLock {
            guard !answered else { return nil }
            answered = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
