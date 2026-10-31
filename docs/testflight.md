# TestFlight

`.github/workflows/testflight.yml` puts a Vellum build on TestFlight, which is how the app reaches the Duo.

## When a build goes up

- Every push to `main` that changes `apps/ios/` or the workflow, so each merged app change reaches the Duo.
- By hand: Actions > TestFlight > Run workflow, or `gh workflow run testflight.yml` (add `--ref <branch>` to build a branch).
- Never on a pull request: pull requests cannot read the signing secrets, and an unreviewed build should not reach the Duo.

The run archives the app, signs it with Xcode's automatic signing, uploads it and then waits until App Store Connect reports the build processed. A green run means TestFlight offers the build. The build number is `<run number>.<attempt>`, shown in the run's log and in TestFlight; the version (`MARKETING_VERSION`) comes from `apps/ios/project.yml`.

## Where the secrets live

Repository secrets on `millZach/Vellum` (Settings > Secrets and variables > Actions), never in a file:

- `APPLE_TEAM_ID`: passed to `xcodebuild` as `DEVELOPMENT_TEAM` when archiving and to the export options, which are written on the runner and deleted.
- `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_ID` and `APP_STORE_CONNECT_KEY` (the `.p8` contents): an App Store Connect API key with the Admin role, which automatic signing needs to use Apple's cloud-managed distribution certificate. The key is written to the runner's temporary folder and removed at the end of the run, pass or fail.

No certificate or provisioning profile is kept anywhere.

## Installing on the Duo

The first time: install TestFlight from the App Store on the Duo, signed in with the Apple account that owns the App Store Connect team; Vellum appears there as an internal test app. After that, each processed build shows in TestFlight and installs with one tap, or automatically if automatic updates are on for Vellum in TestFlight.
