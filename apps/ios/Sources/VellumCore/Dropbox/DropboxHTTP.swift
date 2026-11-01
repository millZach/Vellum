import Foundation

/// An HTTP request to Dropbox as plain values, so VellumCore builds and tests every request without URLSession. The
/// app's transport turns it into a URLRequest.
public struct DropboxHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "POST", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// A form-encoded POST, the shape of Dropbox's OAuth token endpoint.
    static func form(_ url: URL, _ fields: [(String, String)]) -> DropboxHTTPRequest {
        let body = fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        return DropboxHTTPRequest(url: url, headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                  body: Data(body.utf8))
    }

    /// The fields of a form-encoded body, decoded; for tests.
    public var formFields: [String: String] {
        guard let body, let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return fields
    }

    private static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

public struct DropboxHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Sends one request. The app's implementation uses URLSession and throws `DropboxError.offline` when the Duo has no
/// connection; tests answer from a script.
public protocol DropboxTransport: Sendable {
    func send(_ request: DropboxHTTPRequest) async throws -> DropboxHTTPResponse
}

/// Where the tokens are kept: the iOS Keychain in the app, memory in tests. Never UserDefaults or a file.
public protocol DropboxTokenStore: Sendable {
    func load() throws -> DropboxTokens?
    func save(_ tokens: DropboxTokens) throws
    func delete() throws
}
