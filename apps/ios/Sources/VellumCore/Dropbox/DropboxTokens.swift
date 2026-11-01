import Foundation

/// A short-lived access token and the refresh token that renews it. Its descriptions are redacted, so printing,
/// logging or a crash report never shows a token.
public struct DropboxTokens: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    /// How long before expiry Vellum renews the access token, so a request never sets out with one about to lapse.
    public static let refreshMargin: TimeInterval = 5 * 60

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// True when the access token has expired or will within the refresh margin.
    public func needsRefresh(at now: Date) -> Bool {
        now.addingTimeInterval(Self.refreshMargin) >= expiresAt
    }

    public var description: String { "DropboxTokens(redacted, expires \(expiresAt))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["expiresAt": expiresAt]) }

    /// Reads a reply from Dropbox's token endpoint. A refresh reply carries no refresh token, so the one being used is
    /// kept. Errors say what went wrong in `DropboxError`'s words.
    public static func parse(_ response: DropboxHTTPResponse, now: Date, refreshing previous: String? = nil)
        throws(DropboxError) -> DropboxTokens {
        guard response.status == 200 else { throw tokenError(response, refreshing: previous != nil) }
        struct Reply: Decodable {
            let access_token: String
            let expires_in: Double
            let refresh_token: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: response.body),
              let refreshToken = reply.refresh_token ?? previous,
              !reply.access_token.isEmpty, !refreshToken.isEmpty
        else { throw .unexpectedReply }
        return DropboxTokens(accessToken: reply.access_token, refreshToken: refreshToken,
                             expiresAt: now.addingTimeInterval(reply.expires_in))
    }

    static func tokenError(_ response: DropboxHTTPResponse, refreshing: Bool) -> DropboxError {
        if response.status == 429 || response.status >= 500 { return .dropboxUnavailable }
        struct Reply: Decodable {
            let error: String?
            let error_description: String?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: response.body)
        let description = (reply?.error_description ?? "").lowercased()
        if !refreshing, description.contains("redirect") { return .redirectRefused }
        if reply?.error == "invalid_grant" { return refreshing ? .signInExpired : .signInDidNotFinish }
        return refreshing ? .signInExpired : .unexpectedReply
    }
}
