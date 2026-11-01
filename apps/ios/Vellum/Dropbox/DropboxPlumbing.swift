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
/// No connection becomes `DropboxError.offline`.
struct URLSessionDropboxTransport: DropboxTransport {
    private let session = URLSession(configuration: .ephemeral)

    func send(_ request: DropboxHTTPRequest) async throws -> DropboxHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: 30)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return DropboxHTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
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
