/// Why something with Dropbox did not work, each said in plain words with no codes.
public enum DropboxError: Error, Equatable, Sendable {
    /// The build has no Dropbox app key (PR, local and capture builds).
    case notSetUp
    /// No tokens in the Keychain.
    case notSignedIn
    /// No connection to Dropbox.
    case offline
    /// Zach closed the sign-in sheet.
    case cancelled
    /// Zach chose not to allow Vellum on Dropbox's page.
    case accessDenied
    /// Dropbox would not send the sign-in back to Vellum, because its app console does not list Vellum's redirect URI.
    case redirectRefused
    /// The sign-in came back incomplete or from another attempt, or its code had expired.
    case signInDidNotFinish
    /// The access token expired and Dropbox refused to renew it (revoked, or the app's access was removed).
    case signInExpired
    /// Dropbox answered with a server error or asked Vellum to slow down.
    case dropboxUnavailable
    /// Dropbox answered with something Vellum could not read.
    case unexpectedReply
    /// The Keychain would not keep the tokens.
    case couldNotKeepSignIn
    /// The Keychain would not delete the tokens, so Vellum is still signed in on the Duo.
    case couldNotRemoveSignIn

    /// One or two sentences for the screen.
    public var message: String {
        switch self {
        case .notSetUp:
            "Dropbox isn't set up in this build."
        case .notSignedIn:
            "Vellum isn't connected to Dropbox."
        case .offline:
            "You're offline. Connect to the internet to reach Dropbox."
        case .cancelled:
            "Sign-in was cancelled. If Dropbox showed an error page instead of asking to allow Vellum, Dropbox refused the redirect."
        case .accessDenied:
            "You didn't allow Vellum to use your Dropbox."
        case .redirectRefused:
            "Dropbox refused the redirect. Vellum's redirect URI has to be added in the Dropbox app console."
        case .signInDidNotFinish:
            "Sign-in didn't finish. Try connecting again."
        case .signInExpired:
            "Your Dropbox sign-in expired and couldn't be renewed. Connect Dropbox again."
        case .dropboxUnavailable:
            "Dropbox isn't answering right now. Try again in a minute."
        case .unexpectedReply:
            "Dropbox sent a reply Vellum couldn't read. Try again."
        case .couldNotKeepSignIn:
            "Vellum couldn't keep your Dropbox sign-in on the Duo. Try connecting again."
        case .couldNotRemoveSignIn:
            "Vellum couldn't remove the Dropbox sign-in from this Duo, so it is still signed in. Restart Vellum and sign out again."
        }
    }
}
