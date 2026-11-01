import AuthenticationServices
import Foundation
import Observation
import SwiftUI
import VellumCore

/// What the Drawings tab and the Settings sheet show about Dropbox, and the actions they offer. The decisions live in
/// VellumCore's `DropboxSession`; this holds the screen's state.
@MainActor @Observable
final class DropboxConnection {
    enum Phase: Equatable {
        /// The build has no Dropbox app key.
        case notSetUp
        case signedOut
        case working
        case signedIn([DropboxFolder])
    }

    private(set) var phase: Phase
    /// The last thing that went wrong, in plain words, until the next action.
    private(set) var problem: DropboxError?
    private let session: DropboxSession?

    init(session: DropboxSession?, signedIn: Bool) {
        self.session = session
        phase = session == nil ? .notSetUp : (signedIn ? .working : .signedOut)
    }

    var isSignedIn: Bool {
        switch phase {
        case .signedIn, .working: true
        case .notSetUp, .signedOut: false
        }
    }

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
                                                                 store: MemoryTokenStore()), signedIn: false)
            case "folders":
                let tokens = DropboxTokens(accessToken: "capture", refreshToken: "capture", expiresAt: .distantFuture)
                return DropboxConnection(session: DropboxSession(appKey: key, transport: CaptureDropboxTransport(),
                                                                 store: MemoryTokenStore(tokens)), signedIn: true)
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

    /// Lists the top-level folders when signed in; called when the Drawings tab appears and on pull to refresh.
    func refresh() async {
        guard let session, isSignedIn else { return }
        do {
            let folders = try await session.topLevelFolders()
            phase = .signedIn(folders)
            problem = nil
        } catch {
            show(error, signedIn: await session.isSignedIn)
        }
    }

    /// Opens Dropbox's sign-in sheet, then lists the folders.
    func signIn(with webAuthentication: WebAuthenticationSession) async {
        guard let session else { return }
        let attempt = session.beginSignIn()
        problem = nil
        phase = .working
        do {
            let callback = try await webAuthentication.authenticate(using: attempt.authorizeURL,
                                                                    callbackURLScheme: attempt.appKey.callbackScheme)
            try await session.finishSignIn(attempt, callback: callback)
            await refresh()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            show(.cancelled, signedIn: false)
        } catch let error as DropboxError {
            show(error, signedIn: await session.isSignedIn)
        } catch {
            show(.signInDidNotFinish, signedIn: false)
        }
    }

    /// Revokes and forgets the tokens; works offline too.
    func signOut() async {
        guard let session else { return }
        await session.signOut()
        problem = nil
        phase = .signedOut
    }

    private func show(_ error: DropboxError, signedIn: Bool) {
        problem = error
        if !signedIn {
            phase = .signedOut
        } else if phase == .working {
            phase = .signedIn([])
        }
    }
}
