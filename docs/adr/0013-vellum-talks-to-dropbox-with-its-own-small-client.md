# Vellum talks to Dropbox with its own small client, not SwiftyDropbox

Vellum signs in to Dropbox and calls its API with a small client of its own rather than Dropbox's SwiftyDropbox SDK. Sign-in is OAuth 2 with PKCE (ADR-0003): `ASWebAuthenticationSession` opens Dropbox's authorize page with an S256 challenge and `token_access_type=offline`, Dropbox sends the code back to `db-<app key>://2/token`, and the code and the verifier are traded for a four-hour access token and a refresh token. No app secret is used anywhere. Everything that decides something (the verifier and its SHA-256 challenge, the authorize URL, reading the callback, reading token replies, when to renew, renewing once on a 401, listing folders across pages, signing out offline) lives in `VellumCore`'s `DropboxSession` and runs in `swift test` on Forge's Linux Swift, against a scripted Dropbox. The app adds only the Keychain store, a `URLSession` transport and the sign-in sheet.

The tokens are one Keychain item, readable after first unlock on this device only, and are never written to UserDefaults, a file or a log; their printed descriptions are redacted. Signing out revokes the token with Dropbox when the Duo is online and always removes it from the Keychain.

The app key reaches the app only as the `DROPBOX_APP_KEY` build setting. `.github/workflows/testflight.yml` passes the repository secret of that name, and `Scripts/testflight.sh` refuses to archive without one; every other build (pull requests, local builds, the simulator captures) keeps `project.yml`'s placeholder `not-set-up`, and the app says "Dropbox isn't set up in this build" instead of failing. The key is not a secret, since it ships inside the app, but it stays out of the public repository as ADR-0003 asks.

## Considered options

- **SwiftyDropbox** covers the whole API and handles PKCE itself, but it is a large generated runtime dependency that Vellum would be locked to for every later Dropbox ticket, it cannot be built or tested on Forge's Linux Swift, and its sign-in and token storage are its own, so ADR-0003's and the brief's Keychain and no-secret rules would have to be checked inside someone else's code. Vellum needs a handful of endpoints: the token endpoint, token revoke, `files/list_folder` and later download, upload and longpoll for #11 and syncing canvases. Each is one JSON POST that the same client takes on.
- **Adding swift-crypto for SHA-256** was passed over: CryptoKit is not on Linux, and one hash per sign-in is a 60-line function checked against the published test vectors.

## Consequences

Each later Dropbox call (download a PDF, upload a canvas, content-hash checks) is written into `DropboxSession` with its own tests. Dropbox's upload sessions for large files and its rate-limit backoff are Vellum's to write when they are needed.
