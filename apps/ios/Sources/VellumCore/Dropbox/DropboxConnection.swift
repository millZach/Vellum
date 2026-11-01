import Foundation
import Observation

/// What the Drawings tab and the Settings sheet show about Dropbox, and the actions they offer. The decisions about
/// Dropbox live in `DropboxSession`; this holds the screen's state, so it is tested here too.
///
/// Signing out wins every race here as well: it moves the generation on when it starts and when it ends, and a sign-in
/// or folder load that started before then publishes nothing when its `await` returns.
@MainActor @Observable
public final class DropboxConnection {
    public enum Phase: Equatable, Sendable {
        /// The build has no Dropbox app key.
        case notSetUp
        case signedOut
        /// Dropbox's sign-in page is up or its code is being traded for tokens; not signed in yet.
        case signingIn
        /// Signed in, and the folders are on their way.
        case loadingFolders
        case signedIn([DropboxFolder])
    }

    public private(set) var phase: Phase
    /// The last thing that went wrong, in plain words, until the next action.
    public private(set) var problem: DropboxError?
    /// What the last sign-out has to add, such as that Dropbox couldn't be told because the Duo was offline.
    public private(set) var notice: String?
    public private(set) var isSigningOut = false
    private let session: DropboxSession?
    private var generation = 0

    public init(session: DropboxSession?, signedIn: Bool) {
        self.session = session
        phase = session == nil ? .notSetUp : (signedIn ? .loadingFolders : .signedOut)
    }

    /// True once the tokens are kept, whether or not the folders have arrived.
    public var isSignedIn: Bool {
        switch phase {
        case .loadingFolders, .signedIn: true
        case .notSetUp, .signedOut, .signingIn: false
        }
    }

    /// Lists the top-level folders when signed in; called when the Drawings tab appears and on pull to refresh.
    public func refresh() async {
        guard let session, isSignedIn, !isSigningOut else { return }
        let started = generation
        do {
            let folders = try await session.topLevelFolders()
            guard started == generation else { return }
            phase = .signedIn(folders)
            problem = nil
        } catch {
            guard started == generation else { return }
            let signedIn = await session.isSignedIn
            guard started == generation else { return }
            show(error, signedIn: signedIn)
        }
    }

    /// Signs in, then lists the folders. `authenticate` shows Dropbox's sign-in page at the URL and returns the
    /// callback that comes back on the scheme, throwing `DropboxError.cancelled` when Zach closes the page.
    public func signIn(authenticate: @MainActor (_ page: URL, _ callbackScheme: String) async throws -> URL) async {
        guard let session, phase == .signedOut else { return }
        let attempt = session.beginSignIn()
        problem = nil
        notice = nil
        phase = .signingIn
        let started = generation
        do {
            let callback = try await authenticate(attempt.authorizeURL, attempt.appKey.callbackScheme)
            guard started == generation else { return }
            try await session.finishSignIn(attempt, callback: callback)
            guard started == generation else { return }
            phase = .loadingFolders
        } catch {
            guard started == generation else { return }
            problem = error as? DropboxError ?? .signInDidNotFinish
            phase = .signedOut
            return
        }
        await refresh()
    }

    /// Ends the sign-in. The screen says signed out only once the tokens are gone from the Duo; if they couldn't be
    /// removed it stays signed in and says so.
    public func signOut() async {
        guard let session, isSignedIn, !isSigningOut else { return }
        generation += 1
        isSigningOut = true
        defer {
            isSigningOut = false
            generation += 1
        }
        do {
            let outcome = try await session.signOut()
            phase = .signedOut
            problem = nil
            notice = outcome.message
        } catch {
            problem = error
            if phase == .loadingFolders { phase = .signedIn([]) }
        }
    }

    private func show(_ error: DropboxError, signedIn: Bool) {
        problem = error
        if !signedIn {
            phase = .signedOut
        } else if phase == .loadingFolders {
            phase = .signedIn([])
        }
    }
}
