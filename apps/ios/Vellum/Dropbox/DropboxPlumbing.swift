import Foundation
import Security
import VellumCore

/// Keeps the Dropbox tokens in the iOS Keychain as one item readable after the first unlock, on this device only, so
/// they never reach a backup, UserDefaults or a file.
struct KeychainTokenStore: DropboxTokenStore {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.millzach.vellum.dropbox",
            kSecAttrAccount as String: "tokens",
        ]
    }

    struct Failure: Error {
        let status: OSStatus
    }

    func load() throws -> DropboxTokens? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure(status: status) }
        return try JSONDecoder().decode(DropboxTokens.self, from: data)
    }

    func save(_ tokens: DropboxTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(update) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

/// Keeps the folder listings and Dropbox's cursors in one small file in Caches, so the first visit after a launch
/// shows the folders at once and asks Dropbox only what changed. It holds no token; the system may clear it, which
/// only costs one full listing. The session reads and writes it off the main actor.
struct CachesListingStore: DropboxListingStore {
    private var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dropbox-listings.json")
    }

    func load() -> [String: DropboxListing] {
        guard let data = try? Data(contentsOf: file),
              let listings = try? JSONDecoder().decode([String: DropboxListing].self, from: data)
        else { return [:] }
        return listings
    }

    func save(_ listings: [String: DropboxListing]) {
        guard let data = try? JSONEncoder().encode(listings) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func delete() {
        try? FileManager.default.removeItem(at: file)
    }
}

/// Sends VellumCore's Dropbox requests with an ephemeral URLSession, so no reply carrying a token is cached on disk.
/// No connection becomes `DropboxError.offline`. A download that reports progress (a drawing's PDF, #69) goes to a
/// temporary file rather than memory as it comes, and is read back once whole.
struct URLSessionDropboxTransport: DropboxTransport {
    private let session = URLSession(configuration: .ephemeral)

    func send(_ request: DropboxHTTPRequest) async throws -> DropboxHTTPResponse {
        try await Self.mapErrors {
            let (data, response) = try await session.data(for: urlRequest(request))
            return Self.response(response, data)
        }
    }

    func send(_ request: DropboxHTTPRequest, progress: @escaping @Sendable (Double) -> Void) async throws
        -> DropboxHTTPResponse {
        try await Self.mapErrors {
            let delegate = DownloadProgress(progress)
            let (file, response) = try await session.download(for: urlRequest(request), delegate: delegate)
            defer { try? FileManager.default.removeItem(at: file) }
            let data = try Data(contentsOf: file)
            progress(1)
            return Self.response(response, data)
        }
    }

    private func urlRequest(_ request: DropboxHTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: 30)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        return urlRequest
    }

    /// The status, the body and the headers, their names in lower case.
    private static func response(_ response: URLResponse, _ data: Data) -> DropboxHTTPResponse {
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return DropboxHTTPResponse(status: http?.statusCode ?? 0, body: data, headers: headers)
    }

    private static func mapErrors(_ send: () async throws -> DropboxHTTPResponse) async throws -> DropboxHTTPResponse {
        do {
            return try await send()
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                throw DropboxError.offline
            case .cancelled:
                throw DropboxError.cancelled
            default:
                throw DropboxError.dropboxUnavailable
            }
        }
    }
}

/// Tells a download's progress as it comes, at most once per percent.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var told = -1.0

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            self?.tell(progress.fractionCompleted)
        }
        lock.withLock { self.observation = observation }
    }

    private func tell(_ fraction: Double) {
        let shouldTell: Bool = lock.withLock {
            guard fraction >= told + 0.01 || (fraction >= 1 && told < 1) else { return false }
            told = fraction
            return true
        }
        if shouldTell { report(min(max(fraction, 0), 1)) }
    }

    deinit { observation?.invalidate() }
}

#if DEBUG
/// Made-up Dropbox replies for the simulator captures (`--ui-dropbox folders`). Nothing here is anyone's real Dropbox.
struct CaptureDropboxTransport: DropboxTransport {
    func send(_ request: DropboxHTTPRequest) async throws -> DropboxHTTPResponse {
        let names = ["Archive", "Clients", "Plant Drawings", "Standards", "Vellum"]
        let entries = names.enumerated().map { index, name in
            #"{".tag":"folder","name":"\#(name)","path_display":"/\#(name)","id":"id:\#(index)"}"#
        }
        let body = #"{"entries":[\#(entries.joined(separator: ","))],"cursor":"c","has_more":false}"#
        return DropboxHTTPResponse(status: 200, body: Data(body.utf8))
    }
}
#endif
