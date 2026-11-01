# Dropbox

Vellum signs in to Zach's Dropbox with its own small client (ADR-0013): OAuth 2 with PKCE, no app secret, tokens in the Duo's Keychain. This page says where the Dropbox app and its key live and how a build gets the key.

## The Dropbox app

Zach's Dropbox app has Scoped access to the Full Dropbox, the permissions `account_info.read`, `files.metadata.read`, `files.metadata.write`, `files.content.read` and `files.content.write`, public clients (PKCE) allowed, and the redirect URI `db-<app key>://2/token`. `apps/ios/Scripts/setup-dropbox.sh` walks through creating it and saves the app key as the repository secret: run `bash apps/ios/Scripts/setup-dropbox.sh` where `gh` is signed in to `millZach/Vellum`. It holds nothing secret; the key goes straight to the secret and is remembered only in `~/.config/vellum/dropbox.env`, outside the repository. The app secret is never asked for or used.

If sign-in on the Duo ends on a Dropbox error page and Vellum says Dropbox refused the redirect, the redirect URI is missing from the app's OAuth 2 settings.

## How a build gets the app key

The key reaches the app only as the `DROPBOX_APP_KEY` build setting, which puts it in Info.plist and the `db-<key>` callback scheme.

- **TestFlight builds:** `.github/workflows/testflight.yml` passes the `DROPBOX_APP_KEY` repository secret to `Scripts/testflight.sh`, which sets it on the `xcodebuild` command line, refuses to archive without one, and checks the archived Info.plist carries it without printing it.
- **Pull request and CI builds:** `apps/ios/Config/Vellum.xcconfig` sets the placeholder `not-set-up`, and the app says "Dropbox isn't set up in this build". CI checks the built app carries the placeholder.
- **A local build on a Mac:** create `apps/ios/Secrets.xcconfig` (`.gitignore` already lists it) holding one line, `DROPBOX_APP_KEY = <the app key>`. `Config/Vellum.xcconfig` includes it when it exists, so `sh apps/ios/Scripts/build-simulator.sh` and Xcode builds pick it up with no command-line override. Run `generate-project.sh` again after creating it the first time. A key on the `xcodebuild` command line still wins over the file.

The key is not a secret, since it ships inside the app, but it stays out of the public repository (ADR-0003).

## Signing out

Sign Out, in the Settings sheet on the Drawings tab, removes the tokens (and the kept folder listings) from the Duo at once and shows Connect Dropbox, then asks Dropbox in the background to end the sign-in, renewing the access token first if it has lapsed, and gives it four seconds. Offline, or if Dropbox doesn't confirm in time, Vellum quietly says Dropbox wasn't told; Zach can end the sign-in from the connected apps in his Dropbox account settings. If the Keychain won't remove the tokens, Vellum stays signed in and says so. A refresh, sign-in or folder load still in flight when Zach signs out never brings the sign-in back.
