import Foundation
import Observation

/// What the Drawings tab and the Settings sheet show about Dropbox, and the actions they offer. The decisions about
/// Dropbox live in `DropboxSession`; this holds the screen's state, so it is tested here too.
///
/// It never touches the Keychain or the network itself, so building it and drawing the first frame wait for neither:
/// it starts out `checkingSignIn` and asks the session (off the main actor) when the tab appears. Only one update runs
/// at a time; asking again while one is in flight waits for it.
///
/// Signing out wins every race here as well: it moves the generation on, and a sign-in or folder load that started
/// before then publishes nothing when its `await` returns.
@MainActor @Observable
public final class DropboxConnection {
    public enum Phase: Equatable, Sendable {
        /// The build has no Dropbox app key.
        case notSetUp
        /// Vellum hasn't yet looked whether it holds a sign-in; the screen shows nothing for this moment.
        case checkingSignIn
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
    /// True only while the tokens are being removed from the Duo, which takes no network.
    public private(set) var isSigningOut = false
    private let session: DropboxSession?
    private var generation = 0
    private var updating: Task<Void, Never>?
    private var signOutReport: Task<Void, Never>?

    public init(session: DropboxSession?) {
        self.session = session
        phase = session == nil ? .notSetUp : .checkingSignIn
    }

    /// True once the tokens are kept, whether or not the folders have arrived.
    public var isSignedIn: Bool {
        switch phase {
        case .loadingFolders, .signedIn: true
        case .notSetUp, .checkingSignIn, .signedOut, .signingIn: false
        }
    }

    /// The Drawings tab appeared: find out whether Vellum is signed in, show the folders kept from last time, and ask
    /// Dropbox what changed unless it was asked within `DropboxSession.recentCheck`.
    public func appeared() async { await update(.recent) }

    /// Pull to refresh and Try Again: ask Dropbox what changed now.
    public func refresh() async { await update(.now) }

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

    /// Ends the sign-in. The screen says signed out as soon as the tokens are gone from the Duo, without waiting for
    /// Dropbox; whether Dropbox confirmed arrives afterwards as `notice`, only when it didn't. If the tokens couldn't
    /// be removed it stays signed in and says so.
    public func signOut() async {
        guard let session, isSignedIn, !isSigningOut else { return }
        generation += 1
        isSigningOut = true
        updating = nil
        defer { isSigningOut = false }
        do {
            let signOut = try await session.signOut()
            generation += 1
            phase = .signedOut
            problem = nil
            notice = nil
            let ended = generation
            signOutReport = Task {
                let message = await signOut.outcome.message
                guard ended == self.generation, self.phase == .signedOut else { return }
                self.notice = message
            }
        } catch {
            generation += 1
            problem = error
            if phase == .loadingFolders { phase = .signedIn([]) }
        }
    }

    /// Waits until the last sign-out has heard from Dropbox (or given up); for tests.
    public func signOutReported() async { await signOutReport?.value }

    private func update(_ freshness: DropboxFreshness) async {
        if let updating { return await updating.value }
        let task = Task { await self.performUpdate(freshness) }
        updating = task
        await task.value
        if updating == task { updating = nil }
    }

    private func performUpdate(_ freshness: DropboxFreshness) async {
        guard let session, !isSigningOut else { return }
        let started = generation
        if phase == .checkingSignIn {
            let state = await session.keptState()
            guard started == generation, phase == .checkingSignIn else { return }
            switch state {
            case .signedOut:
                phase = .signedOut
                return
            case .signedIn(let kept):
                phase = kept.map(Phase.signedIn) ?? .loadingFolders
            }
        }
        guard isSignedIn else { return }
        do {
            let folders = try await session.folders(in: "", freshness: freshness) { [weak self] folders in
                await self?.show(folders, ifStill: started)
            }
            guard started == generation else { return }
            show(folders, ifStill: started)
            if problem != nil { problem = nil }
        } catch {
            guard started == generation else { return }
            let signedIn = await session.isSignedIn
            guard started == generation else { return }
            show(error, signedIn: signedIn)
        }
    }

    /// Shows a listing, or a first page of one, unless Zach signed out since; an unchanged listing changes nothing.
    private func show(_ folders: [DropboxFolder], ifStill started: Int) {
        guard started == generation, isSignedIn, phase != .signedIn(folders) else { return }
        phase = .signedIn(folders)
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
