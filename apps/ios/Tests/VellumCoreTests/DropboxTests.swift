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
                                   .couldNotKeepSignIn]
        for error in all {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertNil(error.message.range(of: #"\d{3}|_"#, options: .regularExpression), error.message)
        }
        XCTAssertEqual(DropboxError.notSetUp.message, "Dropbox isn't set up in this build.")
        XCTAssertTrue(DropboxError.redirectRefused.message.hasPrefix("Dropbox refused the redirect."))
    }
}

// MARK: - The session against a scripted Dropbox

private final class MemoryStore: DropboxTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: DropboxTokens?
    init(_ tokens: DropboxTokens? = nil) { self.tokens = tokens }
    func load() throws -> DropboxTokens? { lock.withLock { tokens } }
    func save(_ tokens: DropboxTokens) throws { lock.withLock { self.tokens = tokens } }
    func delete() throws { lock.withLock { tokens = nil } }
}

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
    private func session(_ store: MemoryStore, _ dropbox: ScriptedDropbox) -> DropboxSession {
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
        await session(store, dropbox).signOut()
        XCTAssertNil(try store.load())
        XCTAssertEqual(dropbox.requests.map(\.url.absoluteString), ["https://api.dropboxapi.com/2/auth/token/revoke"])
        XCTAssertEqual(dropbox.requests.first?.headers["Authorization"], "Bearer access1")
    }

    func testSigningOutOfflineStillForgets() async throws {
        let store = MemoryStore(fresh)
        await session(store, ScriptedDropbox([.fail(.offline)])).signOut()
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
