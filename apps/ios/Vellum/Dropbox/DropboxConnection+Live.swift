import AuthenticationServices
import Foundation
import SwiftUI
import VellumCore

/// The app's side of VellumCore's `DropboxConnection`: building it from the app key, the Keychain and URLSession, and
/// signing in through the system's web authentication sheet.
extension DropboxConnection {
    /// The connection the app runs with: the app key from Info.plist, the Keychain and URLSession. Debug builds accept
    /// `--ui-dropbox connect` (a made-up key, signed out) and `--ui-dropbox folders` (made-up folders) for the captures.
    static func live() -> DropboxConnection {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--ui-dropbox"), flag + 1 < arguments.count {
            let key = DropboxAppKey(buildSetting: "capturekey00000")!
            switch arguments[flag + 1] {
            case "connect":
                return DropboxConnection(session: DropboxSession(appKey: key, transport: CaptureDropboxTransport(),
                                                                 store: DropboxMemoryTokenStore()), signedIn: false)
            case "folders":
                let tokens = DropboxTokens(accessToken: "capture", refreshToken: "capture", expiresAt: .distantFuture)
                return DropboxConnection(session: DropboxSession(appKey: key, transport: CaptureDropboxTransport(),
                                                                 store: DropboxMemoryTokenStore(tokens)), signedIn: true)
            default:
                return DropboxConnection(session: nil, signedIn: false)
            }
        }
        #endif
        let setting = Bundle.main.object(forInfoDictionaryKey: "DropboxAppKey") as? String
        guard let key = DropboxAppKey(buildSetting: setting) else { return DropboxConnection(session: nil, signedIn: false) }
        let store = KeychainTokenStore()
        let signedIn = ((try? store.load()) ?? nil) != nil
        return DropboxConnection(session: DropboxSession(appKey: key, transport: URLSessionDropboxTransport(), store: store),
                                 signedIn: signedIn)
    }

    /// Opens Dropbox's sign-in sheet, then lists the folders. Closing the sheet is `DropboxError.cancelled`.
    func signIn(with webAuthentication: WebAuthenticationSession) async {
        await signIn { page, scheme in
            do {
                return try await webAuthentication.authenticate(using: page, callbackURLScheme: scheme)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                throw DropboxError.cancelled
            }
        }
    }
}
