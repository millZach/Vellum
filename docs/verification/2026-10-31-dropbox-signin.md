# Dropbox sign-in verification

October 31, 2026, on `feat/dropbox-signin` (#10, PR #20). Captured by the CI job **Duo simulator captures**, [run 41258314759](https://github.com/millZach/Vellum/actions/runs/41258314759), on GitHub's hosted `xcode-27` image with Xcode 27.2, on the iPhone Duo simulator with the iOS 27.1 runtime, booted headless and unfolded the way `2026-10-31-ios-skeleton.md` describes. Each capture is 2853 × 2007 pixels, 951 × 669 points at 3×. The same run's **iOS simulator build** job checked the built app's Info.plist carries `DropboxAppKey = not-set-up` and the callback scheme `db-not-set-up`, so the build had no app key.

## What the captures show

`artifacts/2026-10-31-dropbox-signin/`, each in light and dark:

1. `unfolded-drawings-*.png`: the Drawings tab of this build, which has no app key: "Dropbox isn't set up in this build", with the Settings gear in the toolbar.
2. `unfolded-drawings-dropbox-connect-*.png`: launched with the Debug-only `--ui-dropbox connect` (a made-up key, nothing in the store): Connect Dropbox, its one line on why, and the Connect Dropbox button.
3. `unfolded-drawings-dropbox-folders-*.png`: launched with `--ui-dropbox folders`, which signs in to a Debug-only made-up transport: "Your Dropbox" listing five made-up top-level folders by name (Archive, Clients, Plant Drawings, Standards, Vellum), a file in no list.
4. `unfolded-drawings-dropbox-settings-*.png`: the same, with `--ui-settings` opening the Settings sheet: "Connected. Vellum can read and write your whole Dropbox." and Sign Out of Dropbox.

No capture talks to Dropbox; the folders are made up for the capture.

## Not checked

- A real sign-in and Zach's real folders: the token exchange needs his Dropbox login on the Duo, through a TestFlight build. Whether Dropbox's console accepts the redirect URI `db-<key>://2/token` is unconfirmed until then.
- The sign-in sheet, the error lines and the Sign Out confirmation, which need taps.
- Folded, on the cover screen.
