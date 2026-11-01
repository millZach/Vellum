import Foundation
import XCTest
@testable import VellumCore

// Every key, code and token here is made up for the test.
private let key = DropboxAppKey(buildSetting: "abcdefgh1234567")!

final class DropboxAppKeyTests: XCTestCase {
    func testARealLookingKeyIsAccepted() {
        XCTAssertEqual(key.value, "abcdefgh1234567")
        XCTAssertEqual(key.callbackScheme, "db-abcdefgh1234567")
        XCTAssertEqual(key.redirectURI, "db-abcdefgh1234567://2/token")
    }

    func testABuildWithoutAKeyIsNotSetUp() {
        XCTAssertNil(DropboxAppKey(buildSetting: nil))
        XCTAssertNil(DropboxAppKey(buildSetting: ""))
        XCTAssertNil(DropboxAppKey(buildSetting: DropboxAppKey.placeholder))
        XCTAssertNil(DropboxAppKey(buildSetting: "$(DROPBOX_APP_KEY)"))
        XCTAssertNil(DropboxAppKey(buildSetting: "ABCDEFGH1234567"))
        XCTAssertNil(DropboxAppKey(buildSetting: "short"))
    }
}

final class DropboxPKCETests: XCTestCase {
    func testSHA256MatchesPublishedVectors() {
        func hex(_ text: String) -> String { SHA256.hash(Array(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hex(String(repeating: "a", count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    /// RFC 7636, appendix B.
    func testTheChallengeIsTheRFCExample() {
        let pkce = DropboxPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAVerifierIs64UnreservedCharactersAndFresh() {
        let one = DropboxPKCE.random(), two = DropboxPKCE.random()
        XCTAssertEqual(one.verifier.count, 64)
        XCTAssertNotEqual(one.verifier, two.verifier)
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(one.verifier.allSatisfy(unreserved.contains))
    }
}

final class DropboxSignInTests: XCTestCase {
    let attempt = DropboxSignInAttempt(appKey: key, pkce: DropboxPKCE(verifier: "made-up-verifier"), state: "s1")

    func testTheAuthorizePageAsksForOfflineAccessWithS256AndNoSecret() throws {
        let url = attempt.authorizeURL
        XCTAssertEqual(url.host, "www.dropbox.com")
        XCTAssertEqual(url.path, "/oauth2/authorize")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, [
            "client_id": "abcdefgh1234567",
            "response_type": "code",
            "code_challenge": DropboxPKCE(verifier: "made-up-verifier").challenge,
            "code_challenge_method": "S256",
            "token_access_type": "offline",
            "redirect_uri": "db-abcdefgh1234567://2/token",
            "state": "s1",
        ])
    }

    func testTheCallbackGivesTheCode() throws {
        let code = try attempt.code(fromCallback: URL(string: "db-abcdefgh1234567://2/token?code=c0de&state=s1")!)
        XCTAssertEqual(code, "c0de")
    }

    func testACallbackFromAnotherAttemptIsRefused() {
        XCTAssertThrowsError(try attempt.code(fromCallback: URL(string: "db-abcdefgh1234567://2/token?code=c&state=s2")!)) {
            XCTAssertEqual($0 as? DropboxError, .signInDidNotFinish)
        }
    }

    func testCallbackErrorsSayWhatHappened() {
        func error(_ query: String) -> DropboxError? {
            do {
                _ = try attempt.code(fromCallback: URL(string: "db-abcdefgh1234567://2/token?\(query)")!)
                return nil
            } catch { return error }
        }
        XCTAssertEqual(error("error=access_denied&state=s1"), .accessDenied)
        XCTAssertEqual(error("error=invalid_request&error_description=Invalid%20redirect_uri&state=s1"), .redirectRefused)
        XCTAssertEqual(error("state=s1"), .signInDidNotFinish)
    }

    func testTheCodeIsTradedWithTheVerifierAndNoSecret() {
        let request = attempt.tokenRequest(code: "c0de")
        XCTAssertEqual(request.url.absoluteString, "https://api.dropboxapi.com/oauth2/token")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(request.formFields, [
            "code": "c0de",
            "grant_type": "authorization_code",
            "code_verifier": "made-up-verifier",
            "client_id": "abcdefgh1234567",
            "redirect_uri": "db-abcdefgh1234567://2/token",
        ])
        XCTAssertNil(request.formFields["client_secret"])
    }
}

final class DropboxTokensTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testATokenReplyIsRead() throws {
        let body = #"{"access_token":"sl.access","expires_in":14400,"token_type":"bearer","refresh_token":"refresh","scope":"files.metadata.read","uid":"1","account_id":"dbid:x"}"#
        let tokens = try DropboxTokens.parse(DropboxHTTPResponse(status: 200, body: Data(body.utf8)), now: start)
        XCTAssertEqual(tokens, DropboxTokens(accessToken: "sl.access", refreshToken: "refresh",
                                             expiresAt: start.addingTimeInterval(14400)))
    }

    func testARefreshReplyKeepsTheRefreshToken() throws {
        let body = #"{"access_token":"sl.new","expires_in":14400,"token_type":"bearer"}"#
        let tokens = try DropboxTokens.parse(DropboxHTTPResponse(status: 200, body: Data(body.utf8)), now: start,
                                             refreshing: "refresh")
        XCTAssertEqual(tokens.refreshToken, "refresh")
        XCTAssertEqual(tokens.accessToken, "sl.new")
    }

    func testAFirstReplyWithoutARefreshTokenIsRefused() {
        let body = #"{"access_token":"sl.access","expires_in":14400}"#
        XCTAssertThrowsError(try DropboxTokens.parse(DropboxHTTPResponse(status: 200, body: Data(body.utf8)), now: start)) {
            XCTAssertEqual($0 as? DropboxError, .unexpectedReply)
        }
    }

    func testTokenErrorsSayWhatHappened() {
        func error(_ status: Int, _ body: String, refreshing: Bool) -> DropboxError {
            DropboxTokens.tokenError(DropboxHTTPResponse(status: status, body: Data(body.utf8)), refreshing: refreshing)
        }
        XCTAssertEqual(error(400, #"{"error":"invalid_grant","error_description":"refresh token is invalid or revoked"}"#,
                             refreshing: true), .signInExpired)
        XCTAssertEqual(error(400, #"{"error":"invalid_grant","error_description":"redirect_uri mismatch"}"#,
                             refreshing: false), .redirectRefused)
        XCTAssertEqual(error(400, #"{"error":"invalid_grant","error_description":"code has expired"}"#,
                             refreshing: false), .signInDidNotFinish)
        XCTAssertEqual(error(503, "", refreshing: true), .dropboxUnavailable)
    }

    func testRefreshIsDueFiveMinutesBeforeExpiry() {
        let tokens = DropboxTokens(accessToken: "a", refreshToken: "r", expiresAt: start.addingTimeInterval(3600))
        XCTAssertFalse(tokens.needsRefresh(at: start))
        XCTAssertFalse(tokens.needsRefresh(at: start.addingTimeInterval(3600 - 301)))
        XCTAssertTrue(tokens.needsRefresh(at: start.addingTimeInterval(3600 - 300)))
        XCTAssertTrue(tokens.needsRefresh(at: start.addingTimeInterval(7200)))
    }

    func testPrintingTokensNeverShowsThem() {
        let tokens = DropboxTokens(accessToken: "sl.secretaccess", refreshToken: "secretrefresh", expiresAt: start)
        for text in [String(describing: tokens), String(reflecting: tokens), "\(tokens)",
                     { var out = ""; dump(tokens, to: &out); return out }()] {
            XCTAssertFalse(text.contains("secret"), text)
        }
    }

    func testEveryErrorIsPlainWords() {
        let all: [DropboxError] = [.notSetUp, .notSignedIn, .offline, .cancelled, .accessDenied, .redirectRefused,
                                   .signInDidNotFinish, .signInExpired, .dropboxUnavailable, .unexpectedReply,
                                   .couldNotKeepSignIn, .couldNotRemoveSignIn]
        for error in all {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertNil(error.message.range(of: #"\d{3}|_"#, options: .regularExpression), error.message)
        }
        XCTAssertEqual(DropboxError.notSetUp.message, "Dropbox isn't set up in this build.")
        XCTAssertTrue(DropboxError.redirectRefused.message.hasPrefix("Dropbox refused the redirect."))
    }
}

// MARK: - The session against a scripted Dropbox

private typealias MemoryStore = DropboxMemoryTokenStore

/// Answers each request with the next scripted reply and records what was sent.
private final class ScriptedDropbox: DropboxTransport, @unchecked Sendable {
    enum Reply { case http(Int, String), fail(DropboxError) }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var sent: [DropboxHTTPRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: DropboxHTTPRequest) async throws -> DropboxHTTPResponse {
        let reply: Reply = lock.withLock {
            sent.append(request)
            return replies.isEmpty ? .fail(.unexpectedReply) : replies.removeFirst()
        }
        switch reply {
        case let .http(status, body): return DropboxHTTPResponse(status: status, body: Data(body.utf8))
        case let .fail(error): throw error
        }
    }
    var requests: [DropboxHTTPRequest] { lock.withLock { sent } }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let fresh = DropboxTokens(accessToken: "access1", refreshToken: "refresh1", expiresAt: now.addingTimeInterval(3600))
private let stale = DropboxTokens(accessToken: "access1", refreshToken: "refresh1", expiresAt: now.addingTimeInterval(60))
private let renewed = #"{"access_token":"access2","expires_in":14400,"token_type":"bearer"}"#
private let topLevel = #"""
{"entries":[
 {".tag":"folder","name":"projects","path_display":"/projects","id":"id:2"},
 {".tag":"file","name":"notes.txt","path_display":"/notes.txt","id":"id:3"},
 {".tag":"folder","name":"Archive","path_display":"/Archive","id":"id:1"}],
 "cursor":"c1","has_more":true}
"""#
private let secondPage = #"{"entries":[{".tag":"folder","name":"Vellum","path_display":"/Vellum","id":"id:4"}],"cursor":"c2","has_more":false}"#

final class DropboxSessionTests: XCTestCase {
    private func session(_ store: MemoryStore, _ dropbox: any DropboxTransport) -> DropboxSession {
        DropboxSession(appKey: key, transport: dropbox, store: store, now: { now })
    }

    func testSigningInKeepsTheTokens() async throws {
        let store = MemoryStore()
        let dropbox = ScriptedDropbox([.http(200, #"{"access_token":"a","expires_in":14400,"refresh_token":"r"}"#)])
        let session = session(store, dropbox)
        let attempt = session.beginSignIn()
        try await session.finishSignIn(attempt, callback: URL(string: "db-abcdefgh1234567://2/token?code=c&state=\(attempt.state)")!)
        XCTAssertEqual(try store.load(), DropboxTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(14400)))
        let signedIn = await session.isSignedIn
        XCTAssertTrue(signedIn)
    }

    func testTopLevelFoldersAreListedByNameAcrossPages() async throws {
        let dropbox = ScriptedDropbox([.http(200, topLevel), .http(200, secondPage)])
        let folders = try await session(MemoryStore(fresh), dropbox).topLevelFolders()
        XCTAssertEqual(folders.map(\.name), ["Archive", "projects", "Vellum"])
        XCTAssertEqual(folders.map(\.path), ["/Archive", "/projects", "/Vellum"])
        let requests = dropbox.requests
        XCTAssertEqual(requests.map(\.url.lastPathComponent), ["list_folder", "continue"])
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer access1")
        let body = try JSONSerialization.jsonObject(with: requests[0].body!) as? [String: Any]
        XCTAssertEqual(body?["path"] as? String, "")
    }

    func testATokenAboutToLapseIsRenewedFirst() async throws {
        let store = MemoryStore(stale)
        let dropbox = ScriptedDropbox([.http(200, renewed), .http(200, secondPage)])
        _ = try await session(store, dropbox).topLevelFolders()
        let requests = dropbox.requests
        XCTAssertEqual(requests[0].formFields, ["grant_type": "refresh_token", "refresh_token": "refresh1",
                                                "client_id": "abcdefgh1234567"])
        XCTAssertEqual(requests[1].headers["Authorization"], "Bearer access2")
        XCTAssertEqual(try store.load()?.accessToken, "access2")
        XCTAssertEqual(try store.load()?.refreshToken, "refresh1")
    }

    func testA401RenewsOnceAndRetries() async throws {
        let dropbox = ScriptedDropbox([.http(401, #"{"error_summary":"expired_access_token/"}"#), .http(200, renewed),
                                       .http(200, secondPage)])
        let folders = try await session(MemoryStore(fresh), dropbox).topLevelFolders()
        XCTAssertEqual(folders.map(\.name), ["Vellum"])
        XCTAssertEqual(dropbox.requests.count, 3)
    }

    func testARefusedRefreshSignsOutAndSaysSo() async {
        let store = MemoryStore(stale)
        let dropbox = ScriptedDropbox([.http(400, #"{"error":"invalid_grant","error_description":"revoked"}"#)])
        await assertThrows(.signInExpired) { _ = try await self.session(store, dropbox).topLevelFolders() }
        XCTAssertNil(try store.load())
    }

    func testOfflineKeepsTheTokens() async {
        let store = MemoryStore(stale)
        await assertThrows(.offline) {
            _ = try await self.session(store, ScriptedDropbox([.fail(.offline)])).topLevelFolders()
        }
        XCTAssertEqual(try store.load(), stale)
    }

    func testNotSignedInSaysSo() async {
        await assertThrows(.notSignedIn) { _ = try await self.session(MemoryStore(), ScriptedDropbox([])).topLevelFolders() }
    }

    func testSigningOutRevokesAndForgets() async throws {
        let store = MemoryStore(fresh)
        let dropbox = ScriptedDropbox([.http(200, "null")])
        let outcome = await (try await session(store, dropbox).signOut()).outcome
        XCTAssertEqual(outcome, .revoked)
        XCTAssertNil(outcome.message)
        XCTAssertNil(try store.load())
        XCTAssertEqual(dropbox.requests.map(\.url.absoluteString), ["https://api.dropboxapi.com/2/auth/token/revoke"])
        XCTAssertEqual(dropbox.requests.first?.headers["Authorization"], "Bearer access1")
    }

    func testSigningOutWithALapsedTokenRenewsItFirst() async throws {
        let store = MemoryStore(stale)
        let dropbox = ScriptedDropbox([.http(200, renewed), .http(200, "null")])
        let outcome = await (try await session(store, dropbox).signOut()).outcome
        XCTAssertEqual(outcome, .revoked)
        XCTAssertEqual(dropbox.requests.map(\.url.lastPathComponent), ["token", "revoke"])
        XCTAssertEqual(dropbox.requests[1].headers["Authorization"], "Bearer access2")
        XCTAssertNil(try store.load())
    }

    func testSigningOutRenewsOnceWhenDropboxSaysTheTokenExpired() async throws {
        let store = MemoryStore(fresh)
        let dropbox = ScriptedDropbox([.http(401, #"{"error_summary":"expired_access_token/"}"#), .http(200, renewed),
                                       .http(200, "null")])
        let outcome = await (try await session(store, dropbox).signOut()).outcome
        XCTAssertEqual(outcome, .revoked)
        XCTAssertEqual(dropbox.requests.map(\.url.lastPathComponent), ["revoke", "token", "revoke"])
        XCTAssertEqual(dropbox.requests[2].headers["Authorization"], "Bearer access2")
    }

    func testARefusedRevokeStillForgetsAndSaysSo() async throws {
        let store = MemoryStore(fresh)
        let outcome = await (try await session(store, ScriptedDropbox([.http(400, "bad")])).signOut()).outcome
        XCTAssertEqual(outcome, .notRevoked(.unexpectedReply))
        XCTAssertNotNil(outcome.message)
        XCTAssertNil(try store.load())
    }

    func testARefusedRenewalMeansDropboxAlreadyEndedIt() async throws {
        let store = MemoryStore(stale)
        let dropbox = ScriptedDropbox([.http(400, #"{"error":"invalid_grant","error_description":"revoked"}"#)])
        let outcome = await (try await session(store, dropbox).signOut()).outcome
        XCTAssertEqual(outcome, .revoked)
        XCTAssertNil(try store.load())
    }

    func testSigningOutOfflineStillForgetsAndSaysDropboxWasntTold() async throws {
        let store = MemoryStore(fresh)
        let outcome = await (try await session(store, ScriptedDropbox([.fail(.offline)])).signOut()).outcome
        XCTAssertEqual(outcome, .notRevoked(.offline))
        XCTAssertTrue(outcome.message?.contains("offline") == true)
        XCTAssertNil(try store.load())
    }

    func testAKeychainThatWontDeleteIsReported() async {
        struct Stuck: Error {}
        let store = MemoryStore(fresh, deleteFailure: Stuck())
        await assertThrows(.couldNotRemoveSignIn) {
            _ = try await self.session(store, ScriptedDropbox([.http(200, "null")])).signOut()
        }
        XCTAssertEqual(try store.load(), fresh)
    }

    // MARK: Signing out wins every race

    func testARefreshInFlightCannotUndoSigningOut() async throws {
        let store = MemoryStore(stale)
        let dropbox = SuspendingDropbox(expecting: 3)
        let session = session(store, dropbox)
        let load = Task { try await session.topLevelFolders() }
        try await dropbox.waitForRequests(1)                       // the folder load's refresh, held
        let signOut = Task { await (try await session.signOut()).outcome }
        try await dropbox.waitForRequests(2)                       // sign-out renews too
        XCTAssertNil(try store.load(), "the tokens go before Dropbox is told")
        dropbox.answer(1, .http(200, renewed))
        try await dropbox.waitForRequests(3)
        dropbox.answer(2, .http(200, "null"))                      // revoked
        let outcome = try await signOut.value
        XCTAssertEqual(outcome, .revoked)
        XCTAssertNil(try store.load())
        dropbox.answer(0, .http(200, renewed))                     // the late refresh comes back
        await assertThrows(.notSignedIn) { _ = try await load.value }
        XCTAssertNil(try store.load())
        XCTAssertEqual(dropbox.requests.count, 3, "the stale load went no further")
    }

    func testASignInFinishingLateCannotUndoSigningOut() async throws {
        let store = MemoryStore()
        let dropbox = SuspendingDropbox(expecting: 1)
        let session = session(store, dropbox)
        let attempt = session.beginSignIn()
        let callback = URL(string: "db-abcdefgh1234567://2/token?code=c&state=\(attempt.state)")!
        let signIn = Task { try await session.finishSignIn(attempt, callback: callback) }
        try await dropbox.waitForRequests(1)
        _ = try await session.signOut()
        dropbox.answer(0, .http(200, #"{"access_token":"a","expires_in":14400,"refresh_token":"r"}"#))
        await assertThrows(.notSignedIn) { try await signIn.value }
        XCTAssertNil(try store.load())
    }

    func testAFolderLoadFinishingLateReturnsNothing() async throws {
        let store = MemoryStore(fresh)
        let dropbox = SuspendingDropbox(expecting: 2)
        let session = session(store, dropbox)
        let load = Task { try await session.topLevelFolders() }
        try await dropbox.waitForRequests(1)
        let signOut = Task { await (try await session.signOut()).outcome }
        try await dropbox.waitForRequests(2)
        dropbox.answer(1, .http(200, "null"))
        _ = try await signOut.value
        dropbox.answer(0, .http(200, secondPage))
        await assertThrows(.notSignedIn) { _ = try await load.value }
        XCTAssertNil(try store.load())
    }

    func testALoadStartedWhileDropboxIsBeingToldSendsNothing() async throws {
        let store = MemoryStore(fresh)
        let dropbox = SuspendingDropbox(expecting: 1)
        let session = session(store, dropbox)
        let signOut = try await session.signOut()
        try await dropbox.waitForRequests(1)                       // the revoke, held
        await assertThrows(.notSignedIn) { _ = try await session.topLevelFolders() }
        XCTAssertEqual(dropbox.requests.count, 1, "the load sent nothing")
        dropbox.answer(0, .http(200, "null"))
        let outcome = await signOut.outcome
        XCTAssertEqual(outcome, .revoked)
        XCTAssertNil(try store.load())
    }

    private func assertThrows(_ expected: DropboxError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DropboxError, expected, file: file, line: line)
        }
    }
}

/// Holds each of the first `expected` requests until the test answers it, so a test can sign out while a call is in
/// flight. Any request after those is refused at once, so a stale call that goes further fails the test, not hangs it.
private final class SuspendingDropbox: DropboxTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let expected: Int
    private var held: [(request: DropboxHTTPRequest, reply: CheckedContinuation<DropboxHTTPResponse, any Error>?)] = []

    init(expecting expected: Int) { self.expected = expected }

    func send(_ request: DropboxHTTPRequest) async throws -> DropboxHTTPResponse {
        try await withCheckedThrowingContinuation { reply in
            let refuse = lock.withLock {
                let extra = held.count >= expected
                held.append((request, extra ? nil : reply))
                return extra
            }
            if refuse { reply.resume(throwing: DropboxError.unexpectedReply) }
        }
    }

    var requests: [DropboxHTTPRequest] { lock.withLock { held.map(\.request) } }

    /// Waits, up to five seconds, until `count` requests have arrived.
    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<5000 {
            if lock.withLock({ held.count }) >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("only \(lock.withLock { held.count }) of \(count) requests arrived")
        throw CancellationError()
    }

    func answer(_ index: Int, _ reply: ScriptedDropbox.Reply) {
        guard let continuation = lock.withLock({ held[index].reply }) else { return XCTFail("request \(index) was refused") }
        switch reply {
        case let .http(status, body): continuation.resume(returning: DropboxHTTPResponse(status: status, body: Data(body.utf8)))
        case let .fail(error): continuation.resume(throwing: error)
        }
    }
}

// MARK: - The screen's state

@MainActor
final class DropboxConnectionTests: XCTestCase {
    private func connection(_ store: MemoryStore, _ dropbox: any DropboxTransport) -> DropboxConnection {
        DropboxConnection(session: DropboxSession(appKey: key, transport: dropbox, store: store, now: { now }))
    }

    func testNotSignedInBeforeSignInFinishes() async throws {
        let store = MemoryStore()
        let dropbox = SuspendingDropbox(expecting: 2)
        let connection = connection(store, dropbox)
        await connection.appeared()
        XCTAssertEqual(connection.phase, .signedOut)
        let signIn = Task {
            await connection.signIn { page, _ in
                let state = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "state" }?.value ?? ""
                return URL(string: "db-abcdefgh1234567://2/token?code=c&state=\(state)")!
            }
        }
        try await dropbox.waitForRequests(1)                       // the code is being traded
        XCTAssertEqual(connection.phase, .signingIn)
        XCTAssertFalse(connection.isSignedIn)
        dropbox.answer(0, .http(200, #"{"access_token":"a","expires_in":14400,"refresh_token":"r"}"#))
        try await dropbox.waitForRequests(2)                       // now the folders
        XCTAssertEqual(connection.phase, .loadingFolders)
        XCTAssertTrue(connection.isSignedIn)
        dropbox.answer(1, .http(200, secondPage))
        await signIn.value
        XCTAssertEqual(connection.phase, .signedIn([DropboxFolder(id: "id:4", name: "Vellum", path: "/Vellum")]))
    }

    func testClosingTheSignInPageSaysCancelled() async {
        let connection = connection(MemoryStore(), ScriptedDropbox([]))
        await connection.appeared()
        await connection.signIn { _, _ in throw DropboxError.cancelled }
        XCTAssertEqual(connection.phase, .signedOut)
        XCTAssertEqual(connection.problem, .cancelled)
    }

    func testAFolderLoadFinishingLateCannotBringBackTheSignedInScreen() async throws {
        let store = MemoryStore(fresh)
        let dropbox = SuspendingDropbox(expecting: 2)
        let connection = connection(store, dropbox)
        let load = Task { await connection.refresh() }
        try await dropbox.waitForRequests(1)
        await connection.signOut()
        XCTAssertEqual(connection.phase, .signedOut, "signed out before Dropbox answers")
        XCTAssertFalse(connection.isSigningOut)
        try await dropbox.waitForRequests(2)
        dropbox.answer(1, .http(200, "null"))
        await connection.signOutReported()
        XCTAssertEqual(connection.phase, .signedOut)
        dropbox.answer(0, .http(200, secondPage))
        await load.value
        XCTAssertEqual(connection.phase, .signedOut)
        XCTAssertNil(connection.problem)
        XCTAssertNil(try store.load())
    }

    func testSigningOutOfflineSaysDropboxWasntTold() async {
        let store = MemoryStore(fresh)
        let connection = connection(store, ScriptedDropbox([.http(200, secondPage), .fail(.offline)]))
        await connection.refresh()
        await connection.signOut()
        XCTAssertEqual(connection.phase, .signedOut)
        await connection.signOutReported()
        XCTAssertEqual(connection.notice, DropboxSignOutOutcome.notRevoked(.offline).message)
        XCTAssertNil(try store.load())
    }

    func testAKeychainThatWontDeleteKeepsTheSignedInScreenAndSaysSo() async {
        struct Stuck: Error {}
        let store = MemoryStore(fresh, deleteFailure: Stuck())
        let connection = connection(store, ScriptedDropbox([.http(200, secondPage), .http(200, "null")]))
        await connection.refresh()
        await connection.signOut()
        XCTAssertEqual(connection.phase, .signedIn([DropboxFolder(id: "id:4", name: "Vellum", path: "/Vellum")]))
        XCTAssertEqual(connection.problem, .couldNotRemoveSignIn)
        XCTAssertNil(connection.notice)
    }

    private func assertThrows(_ expected: DropboxError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DropboxError, expected, file: file, line: line)
        }
    }
}

// MARK: - Keeping traffic small

/// A clock the test moves on by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = now
    var time: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// A token store that counts how often it is read and written, as the Keychain would be.
private final class CountingStore: DropboxTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: MemoryStore
    private var counts = (loads: 0, saves: 0)
    init(_ tokens: DropboxTokens?) { inner = MemoryStore(tokens) }
    var loads: Int { lock.withLock { counts.loads } }
    var saves: Int { lock.withLock { counts.saves } }
    func load() throws -> DropboxTokens? { lock.withLock { counts.loads += 1 }; return try inner.load() }
    func save(_ tokens: DropboxTokens) throws { lock.withLock { counts.saves += 1 }; try inner.save(tokens) }
    func delete() throws { try inner.delete() }
}

private let onePage = #"{"entries":[{".tag":"folder","name":"Archive","path_display":"/Archive","id":"id:1"}],"cursor":"c1","has_more":false}"#
private let noChanges = #"{"entries":[],"cursor":"c2","has_more":false}"#

final class DropboxTrafficTests: XCTestCase {
    private func session(_ store: any DropboxTokenStore, _ dropbox: any DropboxTransport, clock: TestClock = TestClock(),
                         listings: DropboxMemoryListingStore = DropboxMemoryListingStore(),
                         revokeDeadline: Duration = .seconds(4)) -> DropboxSession {
        DropboxSession(appKey: key, transport: dropbox, store: store, listings: listings, revokeDeadline: revokeDeadline,
                       now: { clock.time })
    }

    private func names(_ requests: [DropboxHTTPRequest]) -> [String] { requests.map(\.url.lastPathComponent) }

    private func cursor(_ request: DropboxHTTPRequest) -> String? {
        (try? JSONSerialization.jsonObject(with: request.body ?? Data())) .flatMap { $0 as? [String: Any] }?["cursor"]
            as? String
    }

    // Fetch only what changed

    func testARecentRevisitSendsNothingAndALaterOneAsksOnlyForChanges() async throws {
        let clock = TestClock()
        let dropbox = ScriptedDropbox([.http(200, topLevel), .http(200, secondPage), .http(200, noChanges)])
        let session = session(MemoryStore(fresh), dropbox, clock: clock)
        let first = try await session.topLevelFolders(freshness: .recent)
        XCTAssertEqual(first.map(\.name), ["Archive", "projects", "Vellum"])
        XCTAssertEqual(names(dropbox.requests), ["list_folder", "continue"])

        clock.advance(DropboxSession.recentCheck - 1)
        let recent = try await session.topLevelFolders(freshness: .recent)
        XCTAssertEqual(recent, first)
        XCTAssertEqual(dropbox.requests.count, 2, "a revisit within the recent check sends nothing")

        clock.advance(2)
        let later = try await session.topLevelFolders(freshness: .recent)
        XCTAssertEqual(later, first)
        XCTAssertEqual(names(dropbox.requests), ["list_folder", "continue", "continue"])
        XCTAssertEqual(cursor(dropbox.requests[2]), "c2", "asks from the last cursor")
    }

    func testChangesAreMergedIntoTheKeptListing() async throws {
        let changes = #"""
        {"entries":[
         {".tag":"deleted","name":"projects","path_lower":"/projects","path_display":"/projects"},
         {".tag":"folder","name":"Clients","path_display":"/Clients","id":"id:5"},
         {".tag":"file","name":"plan.pdf","path_display":"/plan.pdf","id":"id:6"}],
         "cursor":"c3","has_more":false}
        """#
        let dropbox = ScriptedDropbox([.http(200, topLevel), .http(200, secondPage), .http(200, changes),
                                       .http(200, noChanges)])
        let session = session(MemoryStore(fresh), dropbox)
        _ = try await session.topLevelFolders()
        let merged = try await session.topLevelFolders()
        XCTAssertEqual(merged.map(\.name), ["Archive", "Clients", "Vellum"])
        _ = try await session.topLevelFolders()
        XCTAssertEqual(cursor(dropbox.requests[3]), "c3")
    }

    func testAResetCursorListsTheFolderAgain() async throws {
        let dropbox = ScriptedDropbox([.http(200, onePage),
                                       .http(409, #"{"error_summary":"reset/..","error":{".tag":"reset"}}"#),
                                       .http(200, secondPage)])
        let session = session(MemoryStore(fresh), dropbox)
        _ = try await session.topLevelFolders()
        let again = try await session.topLevelFolders()
        XCTAssertEqual(again.map(\.name), ["Vellum"])
        XCTAssertEqual(names(dropbox.requests), ["list_folder", "continue", "list_folder"])
    }

    func testTheListingOutlastsALaunchAndGoesWithSigningOut() async throws {
        let listings = DropboxMemoryListingStore()
        let store = MemoryStore(fresh)
        let clock = TestClock()
        _ = try await session(store, ScriptedDropbox([.http(200, onePage)]), clock: clock, listings: listings)
            .topLevelFolders()

        clock.advance(DropboxSession.recentCheck + 1)
        let dropbox = ScriptedDropbox([.http(200, noChanges), .http(200, "null")])
        let relaunched = session(store, dropbox, clock: clock, listings: listings)
        let kept = await relaunched.keptState()
        XCTAssertEqual(kept, .signedIn(keptFolders: [DropboxFolder(id: "id:1", name: "Archive", path: "/Archive")]))
        XCTAssertEqual(dropbox.requests.count, 0, "the kept folders show before any request")
        _ = try await relaunched.topLevelFolders(freshness: .recent)
        XCTAssertEqual(names(dropbox.requests), ["continue"])

        _ = await (try await relaunched.signOut()).outcome
        XCTAssertEqual(listings.load(), [:])
        let state = await relaunched.keptState()
        XCTAssertEqual(state, .signedOut)
    }

    // One request chain at a time

    func testCallersListingAtOnceShareOneChain() async throws {
        let dropbox = SuspendingDropbox(expecting: 1)
        let session = session(MemoryStore(fresh), dropbox)
        let one = Task { try await session.topLevelFolders() }
        try await dropbox.waitForRequests(1)
        let two = Task { try await session.topLevelFolders() }
        try await Task.sleep(nanoseconds: 20_000_000)
        dropbox.answer(0, .http(200, onePage))
        let first = try await one.value, second = try await two.value
        XCTAssertEqual(first, second)
        XCTAssertEqual(dropbox.requests.count, 1)
    }

    func testCallersRenewingAtOnceShareOneRenewal() async throws {
        let store = CountingStore(stale)
        let dropbox = SuspendingDropbox(expecting: 3)
        let session = session(store, dropbox)
        let top = Task { try await session.folders(in: "") }
        try await dropbox.waitForRequests(1)
        let inner = Task { try await session.folders(in: "/Archive") }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(names(dropbox.requests), ["token"], "the second caller waits for the first renewal")
        dropbox.answer(0, .http(200, renewed))
        try await dropbox.waitForRequests(3)
        dropbox.answer(1, .http(200, onePage))
        dropbox.answer(2, .http(200, onePage))
        _ = try await top.value
        _ = try await inner.value
        XCTAssertEqual(names(dropbox.requests).filter { $0 == "token" }.count, 1)
        XCTAssertTrue(dropbox.requests.dropFirst().allSatisfy { $0.headers["Authorization"] == "Bearer access2" })
        XCTAssertEqual(store.saves, 1)
    }

    func testTwo401sAtOnceRenewOnce() async throws {
        let dropbox = SuspendingDropbox(expecting: 5)
        let session = session(MemoryStore(fresh), dropbox)
        let top = Task { try await session.folders(in: "") }
        try await dropbox.waitForRequests(1)
        let inner = Task { try await session.folders(in: "/Archive") }
        try await dropbox.waitForRequests(2)
        dropbox.answer(0, .http(401, #"{"error_summary":"expired_access_token/"}"#))
        try await dropbox.waitForRequests(3)                       // the renewal
        dropbox.answer(1, .http(401, #"{"error_summary":"expired_access_token/"}"#))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(dropbox.requests.count, 3, "the second 401 waits for the renewal under way")
        dropbox.answer(2, .http(200, renewed))
        try await dropbox.waitForRequests(5)
        dropbox.answer(3, .http(200, onePage))
        dropbox.answer(4, .http(200, onePage))
        _ = try await top.value
        _ = try await inner.value
        XCTAssertEqual(names(dropbox.requests).filter { $0 == "token" }.count, 1)
    }

    // The tokens are cached in the session

    func testTheStoreIsReadOnceAndWrittenOnlyWhenTheTokensChange() async throws {
        let store = CountingStore(fresh)
        let dropbox = ScriptedDropbox([.http(200, topLevel), .http(200, secondPage), .http(200, noChanges),
                                       .http(200, noChanges)])
        let session = session(store, dropbox)
        _ = await session.isSignedIn
        _ = try await session.topLevelFolders()
        _ = try await session.topLevelFolders()
        _ = try await session.topLevelFolders()
        XCTAssertEqual(dropbox.requests.count, 4)
        XCTAssertEqual(store.loads, 1)
        XCTAssertEqual(store.saves, 0)
    }

    // Sign-out is instant

    func testSigningOutDoesNotWaitForAStalledRevoke() async throws {
        let store = MemoryStore(fresh)
        let dropbox = SuspendingDropbox(expecting: 1)               // Dropbox never answers
        let session = session(store, dropbox, revokeDeadline: .milliseconds(200))
        let start = Date()
        let signOut = try await session.signOut()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        XCTAssertNil(try store.load())
        let signedIn = await session.isSignedIn
        XCTAssertFalse(signedIn)
        let outcome = await signOut.outcome
        XCTAssertEqual(outcome, .notRevoked(.dropboxUnavailable))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "the revoke gives up at its deadline")
        XCTAssertEqual(names(dropbox.requests), ["revoke"])
    }

    func testAKeychainThatWontDeleteTellsDropboxNothing() async {
        struct Stuck: Error {}
        let dropbox = ScriptedDropbox([])
        do {
            _ = try await session(MemoryStore(fresh, deleteFailure: Stuck()), dropbox).signOut()
            XCTFail("expected couldNotRemoveSignIn")
        } catch {
            XCTAssertEqual(error, .couldNotRemoveSignIn)
        }
        XCTAssertEqual(dropbox.requests.count, 0)
    }
}

@MainActor
final class DropboxConnectionTrafficTests: XCTestCase {
    private func connection(_ store: any DropboxTokenStore, _ dropbox: any DropboxTransport,
                            clock: TestClock = TestClock(), revokeDeadline: Duration = .seconds(4)) -> DropboxConnection {
        DropboxConnection(session: DropboxSession(appKey: key, transport: dropbox, store: store,
                                                  revokeDeadline: revokeDeadline, now: { clock.time }))
    }

    func testBuildingTheConnectionReadsNoKeychain() async {
        let store = CountingStore(fresh)
        let connection = connection(store, ScriptedDropbox([.http(200, onePage)]))
        XCTAssertEqual(connection.phase, .checkingSignIn)
        XCTAssertEqual(store.loads, 0)
        await connection.appeared()
        XCTAssertEqual(connection.phase, .signedIn([DropboxFolder(id: "id:1", name: "Archive", path: "/Archive")]))
        XCTAssertEqual(store.loads, 1)
    }

    func testSignedOutShowsWithoutARequest() async {
        let dropbox = ScriptedDropbox([])
        let connection = connection(MemoryStore(), dropbox)
        await connection.appeared()
        XCTAssertEqual(connection.phase, .signedOut)
        XCTAssertEqual(dropbox.requests.count, 0)
    }

    func testTabVisitsCostOneListingThenNothingThenOneSmallCheck() async {
        let clock = TestClock()
        let dropbox = ScriptedDropbox([.http(200, onePage), .http(200, noChanges)])
        let connection = connection(MemoryStore(fresh), dropbox, clock: clock)
        await connection.appeared()
        XCTAssertEqual(dropbox.requests.count, 1)
        await connection.appeared()
        XCTAssertEqual(dropbox.requests.count, 1, "a revisit within the recent check sends nothing")
        clock.advance(DropboxSession.recentCheck)
        await connection.appeared()
        XCTAssertEqual(dropbox.requests.map(\.url.lastPathComponent), ["list_folder", "continue"])
        XCTAssertEqual(connection.phase, .signedIn([DropboxFolder(id: "id:1", name: "Archive", path: "/Archive")]))
    }

    func testRefreshingWhileAnUpdateRunsJoinsIt() async throws {
        let dropbox = SuspendingDropbox(expecting: 1)
        let connection = connection(MemoryStore(fresh), dropbox)
        let appear = Task { await connection.appeared() }
        try await dropbox.waitForRequests(1)
        let pull = Task { await connection.refresh() }
        try await Task.sleep(nanoseconds: 20_000_000)
        dropbox.answer(0, .http(200, onePage))
        await appear.value
        await pull.value
        XCTAssertEqual(dropbox.requests.count, 1)
    }

    func testTheFirstPageShowsBeforeTheRest() async throws {
        let dropbox = SuspendingDropbox(expecting: 2)
        let connection = connection(MemoryStore(fresh), dropbox)
        let appear = Task { await connection.appeared() }
        try await dropbox.waitForRequests(1)
        XCTAssertEqual(connection.phase, .loadingFolders)
        dropbox.answer(0, .http(200, topLevel))
        try await dropbox.waitForRequests(2)
        XCTAssertEqual(connection.phase.folderNames, ["Archive", "projects"], "the first page shows while the second loads")
        dropbox.answer(1, .http(200, secondPage))
        await appear.value
        XCTAssertEqual(connection.phase.folderNames, ["Archive", "projects", "Vellum"])
    }

    func testSigningOutIsInstantWhenDropboxStalls() async throws {
        let store = MemoryStore(fresh)
        let dropbox = SuspendingDropbox(expecting: 2)
        let connection = connection(store, dropbox, revokeDeadline: .milliseconds(300))
        let appear = Task { await connection.appeared() }
        try await dropbox.waitForRequests(1)
        dropbox.answer(0, .http(200, onePage))
        await appear.value
        let start = Date()
        await connection.signOut()                                 // the revoke never comes back
        let took = Date().timeIntervalSince(start)
        XCTAssertLessThan(took, 0.1)
        XCTAssertEqual(connection.phase, .signedOut)
        XCTAssertNil(connection.notice)
        XCTAssertNil(try store.load())
        await connection.signOutReported()
        XCTAssertEqual(connection.notice, DropboxSignOutOutcome.notRevoked(.dropboxUnavailable).message)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}

private extension DropboxConnection.Phase {
    var folderNames: [String]? {
        if case .signedIn(let folders) = self { folders.map(\.name) } else { nil }
    }
}

// MARK: - Baselines (docs/perf/baselines/dropbox.json)

/// One entry of an area's baseline file.
private struct Baseline: Decodable {
    let metric: String
    let kind: String
    let value: Double
    let unit: String
    let tolerance: Double

    /// The Dropbox area's baselines, read from the repository, so the file is the one place each number lives.
    static let dropbox: [String: Baseline] = {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // Tests/VellumCoreTests
            .appendingPathComponent("../../../../docs/perf/baselines/dropbox.json").standardizedFileURL
        guard let data = try? Data(contentsOf: file), let all = try? JSONDecoder().decode([Baseline].self, from: data)
        else { return [:] }
        return Dictionary(all.map { ($0.metric, $0) }) { $1 }
    }()
}

/// A transport that answers each request after `delay` with the next reply, as a slow network would.
private final class SlowDropbox: DropboxTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private let delay: UInt64
    init(delayMilliseconds: UInt64, _ replies: [String]) {
        self.replies = replies
        delay = delayMilliseconds * 1_000_000
    }
    func send(_ request: DropboxHTTPRequest) async throws -> DropboxHTTPResponse {
        try await Task.sleep(nanoseconds: delay)
        let body = lock.withLock { replies.isEmpty ? "" : replies.removeFirst() }
        return DropboxHTTPResponse(status: 200, body: Data(body.utf8))
    }
}

@MainActor
final class DropboxBudgetTests: XCTestCase {
    /// Fails when a count is over its budget; says so when it has come in under, so the budget can be tightened.
    private func assertWithinBudget(_ metric: String, _ measured: Int, file: StaticString = #filePath,
                                    line: UInt = #line) {
        guard let baseline = Baseline.dropbox[metric], baseline.kind == "count" else {
            return XCTFail("no count baseline named \(metric) in docs/perf/baselines/dropbox.json", file: file, line: line)
        }
        print("PERF dropbox \(metric)=\(measured) \(baseline.unit) (budget \(Int(baseline.value)))")
        XCTAssertLessThanOrEqual(Double(measured), baseline.value,
                                 "\(metric) is over its budget in docs/perf/baselines/dropbox.json", file: file, line: line)
        if Double(measured) < baseline.value {
            print("PERF dropbox \(metric) came in under its budget: lower it in docs/perf/baselines/dropbox.json")
        }
    }

    /// Records a timing and warns, never fails, when it is worse than its baseline by more than the tolerance.
    private func record(_ metric: String, milliseconds measured: Double, file: StaticString = #filePath,
                        line: UInt = #line) {
        guard let baseline = Baseline.dropbox[metric], baseline.kind == "time" else {
            return XCTFail("no time baseline named \(metric) in docs/perf/baselines/dropbox.json", file: file, line: line)
        }
        let shown = String(format: "%.1f", measured)
        print("PERF dropbox \(metric)=\(shown) ms (baseline \(baseline.value) ms)")
        if measured > baseline.value * (1 + baseline.tolerance) {
            print("::warning title=Performance (dropbox)::\(metric) took \(shown) ms, more than "
                + "\(Int(baseline.tolerance * 100))% over its \(baseline.value) ms baseline")
        }
    }

    private func connection(_ store: any DropboxTokenStore, _ dropbox: any DropboxTransport, clock: TestClock = TestClock(),
                            revokeDeadline: Duration = .seconds(4)) -> DropboxConnection {
        DropboxConnection(session: DropboxSession(appKey: key, transport: dropbox, store: store,
                                                  revokeDeadline: revokeDeadline, now: { clock.time }))
    }

    func testTheBaselineFileIsRead() {
        XCTAssertFalse(Baseline.dropbox.isEmpty, "docs/perf/baselines/dropbox.json is missing or unreadable")
    }

    func testRequestsPerDrawingsVisit() async {
        let clock = TestClock()
        let dropbox = ScriptedDropbox([.http(200, onePage), .http(200, noChanges)])
        let connection = connection(MemoryStore(fresh), dropbox, clock: clock)
        await connection.appeared()
        assertWithinBudget("requests-first-drawings-visit", dropbox.requests.count)
        await connection.appeared()
        assertWithinBudget("requests-unchanged-revisit-within-recent-check", dropbox.requests.count - 1)
        clock.advance(DropboxSession.recentCheck)
        await connection.appeared()
        assertWithinBudget("requests-unchanged-revisit-later", dropbox.requests.count - 1)
    }

    func testKeychainReadsAndWrites() async throws {
        let store = CountingStore(fresh)
        let clock = TestClock()
        let dropbox = ScriptedDropbox([.http(200, topLevel), .http(200, secondPage), .http(200, noChanges)])
        let connection = connection(store, dropbox, clock: clock)
        await connection.appeared()                                // two pages
        clock.advance(DropboxSession.recentCheck)
        await connection.refresh()                                 // one page of changes
        assertWithinBudget("keychain-reads-per-session", store.loads)
        assertWithinBudget("keychain-reads-per-listing-page", (store.loads - 1) / dropbox.requests.count)
        assertWithinBudget("keychain-writes-per-listing", store.saves)
    }

    func testOneRenewalPerConcurrentBurst() async throws {
        let dropbox = SuspendingDropbox(expecting: 5)
        let session = DropboxSession(appKey: key, transport: dropbox, store: MemoryStore(fresh), now: { now })
        let top = Task { try await session.folders(in: "") }
        try await dropbox.waitForRequests(1)
        let inner = Task { try await session.folders(in: "/Archive") }
        try await dropbox.waitForRequests(2)
        dropbox.answer(0, .http(401, #"{"error_summary":"expired_access_token/"}"#))
        try await dropbox.waitForRequests(3)
        dropbox.answer(1, .http(401, #"{"error_summary":"expired_access_token/"}"#))
        try await Task.sleep(nanoseconds: 20_000_000)
        dropbox.answer(2, .http(200, renewed))
        try await dropbox.waitForRequests(5)
        dropbox.answer(3, .http(200, onePage))
        dropbox.answer(4, .http(200, onePage))
        _ = try await top.value
        _ = try await inner.value
        assertWithinBudget("token-renewals-per-concurrent-burst",
                           dropbox.requests.filter { $0.url.lastPathComponent == "token" }.count)
    }

    func testOneChainForConcurrentListingsOfOneFolder() async throws {
        let dropbox = SuspendingDropbox(expecting: 1)
        let session = DropboxSession(appKey: key, transport: dropbox, store: MemoryStore(fresh), now: { now })
        let one = Task { try await session.topLevelFolders() }
        try await dropbox.waitForRequests(1)
        let two = Task { try await session.topLevelFolders() }
        try await Task.sleep(nanoseconds: 20_000_000)
        dropbox.answer(0, .http(200, onePage))
        _ = try await one.value
        _ = try await two.value
        assertWithinBudget("requests-concurrent-listings-of-one-folder", dropbox.requests.count)
    }

    func testSignOutShownWithAStalledNetwork() async throws {
        let dropbox = SuspendingDropbox(expecting: 2)
        let connection = connection(MemoryStore(fresh), dropbox)
        let appear = Task { await connection.appeared() }
        try await dropbox.waitForRequests(1)
        dropbox.answer(0, .http(200, onePage))
        await appear.value
        let start = Date()
        await connection.signOut()                                 // the revoke never comes back
        let took = Date().timeIntervalSince(start) * 1000
        XCTAssertEqual(connection.phase, .signedOut)
        record("sign-out-shown-stalled-network", milliseconds: took)
    }

    func testFirstFolderShownWithASlowTransport() async throws {
        let first = #"{"entries":[{".tag":"folder","name":"Archive","path_display":"/Archive","id":"id:1"}],"cursor":"c1","has_more":true}"#
        let second = #"{"entries":[{".tag":"folder","name":"Clients","path_display":"/Clients","id":"id:2"}],"cursor":"c2","has_more":true}"#
        let third = #"{"entries":[{".tag":"folder","name":"Vellum","path_display":"/Vellum","id":"id:3"}],"cursor":"c3","has_more":false}"#
        let connection = connection(MemoryStore(fresh), SlowDropbox(delayMilliseconds: 200, [first, second, third]))
        let start = Date()
        let appear = Task { await connection.appeared() }
        var shown: TimeInterval?
        while shown == nil, Date().timeIntervalSince(start) < 5 {
            if case .signedIn(let folders) = connection.phase, !folders.isEmpty { shown = Date().timeIntervalSince(start) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await appear.value
        let firstShown = try XCTUnwrap(shown, "no folder was shown")
        XCTAssertEqual(connection.phase.folderNames, ["Archive", "Clients", "Vellum"])
        record("first-folder-shown-slow-transport", milliseconds: firstShown * 1000)
    }
}
