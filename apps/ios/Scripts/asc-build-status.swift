// Waits until App Store Connect has processed an uploaded build, and fails if it rejects it.
// Usage: swift Scripts/asc-build-status.swift <bundle id> <build number>
// Reads KEY_ID, ISSUER_ID and KEY_PATH (the App Store Connect .p8 key) from the environment, the same key the upload
// used. Run by Scripts/testflight.sh on a macOS runner; it needs CryptoKit, so it does not run on Linux.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: asc-build-status.swift <bundle id> <build number>\n".utf8))
    exit(2)
}
let bundleID = arguments[1]
let buildNumber = arguments[2]
let environment = ProcessInfo.processInfo.environment
guard let keyID = environment["KEY_ID"], let issuerID = environment["ISSUER_ID"],
      let keyPath = environment["KEY_PATH"] else {
    FileHandle.standardError.write(Data("KEY_ID, ISSUER_ID and KEY_PATH must be set\n".utf8))
    exit(2)
}
let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: keyPath, encoding: .utf8))

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// A fresh token for every request: App Store Connect accepts tokens that live at most 20 minutes, and the wait is longer.
func token() throws -> String {
    let now = Int(Date().timeIntervalSince1970)
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let claims = try JSONSerialization.data(withJSONObject: [
        "iss": issuerID, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1",
    ] as [String: Any])
    let signingInput = base64URL(header) + "." + base64URL(claims)
    let signature = try key.signature(for: Data(signingInput.utf8))
    return signingInput + "." + base64URL(signature.rawRepresentation)
}

func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
    var components = URLComponents(string: "https://api.appstoreconnect.apple.com" + path)!
    components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer " + (try token()), forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
        throw NSError(domain: "AppStoreConnect", code: status, userInfo: [
            NSLocalizedDescriptionKey: "GET \(path) returned \(status): \(String(decoding: data, as: UTF8.self))",
        ])
    }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

let apps = try await get("/v1/apps", ["filter[bundleId]": bundleID, "fields[apps]": "bundleId"])
guard let appID = (apps["data"] as? [[String: Any]])?.first?["id"] as? String else {
    print("App Store Connect has no app with bundle ID \(bundleID)")
    exit(1)
}

// A build shows up in the API a few minutes after the upload, as PROCESSING, and then turns VALID, or FAILED or INVALID.
let deadline = Date().addingTimeInterval(40 * 60)
var lastState = ""
while Date() < deadline {
    let builds = try await get("/v1/builds", [
        "filter[app]": appID, "filter[version]": buildNumber,
        "fields[builds]": "version,processingState,uploadedDate",
    ])
    let build = (builds["data"] as? [[String: Any]])?.first
    let attributes = build?["attributes"] as? [String: Any]
    let state = attributes?["processingState"] as? String ?? "NOT YET LISTED"
    if state != lastState {
        print("\(Date()) build \(buildNumber): \(state)")
        lastState = state
    }
    switch state {
    case "VALID":
        print("App Store Connect processed build \(buildNumber) (build id \(build?["id"] as? String ?? "?")); TestFlight offers it now.")
        exit(0)
    case "FAILED", "INVALID":
        print("App Store Connect rejected build \(buildNumber): \(state). Its email to the account holder says why.")
        exit(1)
    default:
        try await Task.sleep(nanoseconds: 30_000_000_000)
    }
}
print("Build \(buildNumber) was still \(lastState) after 40 minutes; check App Store Connect.")
exit(1)
