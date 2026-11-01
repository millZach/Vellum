import Foundation

/// The Dropbox app's key, which the build injects as the `DROPBOX_APP_KEY` build setting (ADR-0013). It is not a
/// secret, since it ships inside the app, but it stays out of the public repository anyway (ADR-0003). A build made
/// without it carries the placeholder, and Vellum says Dropbox isn't set up in that build.
public struct DropboxAppKey: Sendable, Equatable {
    /// What `project.yml` sets when no key is passed: PR builds, local builds and the simulator captures.
    public static let placeholder = "not-set-up"

    public let value: String

    /// The key from the app's Info.plist, or nil when the build has the placeholder, nothing, an unexpanded
    /// `$(DROPBOX_APP_KEY)`, or anything that is not shaped like a Dropbox app key (lowercase letters and digits).
    public init?(buildSetting: String?) {
        guard let raw = buildSetting?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw != Self.placeholder,
              (10...24).contains(raw.count),
              raw.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) })
        else { return nil }
        value = raw
    }

    /// The URL scheme Dropbox sends the signed-in Duo back to, registered in Info.plist as `db-$(DROPBOX_APP_KEY)`.
    public var callbackScheme: String { "db-\(value)" }

    /// The redirect URI the Dropbox app console has to list under OAuth 2 > Redirect URIs.
    public var redirectURI: String { "\(callbackScheme)://2/token" }
}

/// A PKCE pair (RFC 7636): the verifier stays on the Duo, and only its S256 challenge goes to Dropbox's authorize page,
/// which is why sign-in needs no app secret.
public struct DropboxPKCE: Sendable, Equatable {
    public let verifier: String

    public init(verifier: String) { self.verifier = verifier }

    /// A fresh verifier of 64 characters from RFC 7636's unreserved set.
    public static func random<Generator: RandomNumberGenerator>(using generator: inout Generator) -> DropboxPKCE {
        DropboxPKCE(verifier: randomString(length: 64, using: &generator))
    }

    public static func random() -> DropboxPKCE {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    /// BASE64URL(SHA256(verifier)), without padding.
    public var challenge: String { base64URL(SHA256.hash(Array(verifier.utf8))) }

    static func randomString<Generator: RandomNumberGenerator>(length: Int, using generator: inout Generator) -> String {
        let unreserved = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in unreserved.randomElement(using: &generator)! })
    }
}

func base64URL(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// One sign-in: the authorize page to open, and what to do with the URL Dropbox sends back.
public struct DropboxSignInAttempt: Sendable {
    public let appKey: DropboxAppKey
    public let pkce: DropboxPKCE
    /// Sent to Dropbox and expected back unchanged, so a callback from some other sign-in is refused.
    public let state: String

    public init(appKey: DropboxAppKey, pkce: DropboxPKCE = .random(), state: String? = nil) {
        self.appKey = appKey
        self.pkce = pkce
        if let state {
            self.state = state
        } else {
            var generator = SystemRandomNumberGenerator()
            self.state = DropboxPKCE.randomString(length: 32, using: &generator)
        }
    }

    /// Dropbox's authorize page, asking for a refresh token (`token_access_type=offline`) so the Duo stays signed in
    /// past the four-hour access token.
    public var authorizeURL: URL {
        var components = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: appKey.value),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "redirect_uri", value: appKey.redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// The authorization code in Dropbox's callback, or why there is none.
    public func code(fromCallback url: URL) throws(DropboxError) -> String {
        guard url.scheme?.lowercased() == appKey.callbackScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { throw .signInDidNotFinish }
        func item(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        if let error = item("error") {
            if error == "access_denied" { throw .accessDenied }
            let description = (item("error_description") ?? "").lowercased()
            if description.contains("redirect") { throw .redirectRefused }
            throw .signInDidNotFinish
        }
        guard item("state") == state, let code = item("code"), !code.isEmpty else { throw .signInDidNotFinish }
        return code
    }

    /// Trades the code for tokens: the verifier proves this is the Duo that started the sign-in.
    public func tokenRequest(code: String) -> DropboxHTTPRequest {
        .form(DropboxEndpoint.token, [
            ("code", code),
            ("grant_type", "authorization_code"),
            ("code_verifier", pkce.verifier),
            ("client_id", appKey.value),
            ("redirect_uri", appKey.redirectURI),
        ])
    }
}

enum DropboxEndpoint {
    static let token = URL(string: "https://api.dropboxapi.com/oauth2/token")!
    static let revoke = URL(string: "https://api.dropboxapi.com/2/auth/token/revoke")!
    static let listFolder = URL(string: "https://api.dropboxapi.com/2/files/list_folder")!
    static let listFolderContinue = URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!
}
