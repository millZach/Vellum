# TestFlight

`.github/workflows/testflight.yml` puts a Vellum build on TestFlight, which is how the app reaches the Duo.

## When a build goes up

- Every push to `main` that changes `apps/ios/` or the workflow, so each merged app change reaches the Duo. The workflow file is in the trigger on purpose: a change to how builds are made is proved by a real build.
- By hand: Actions > TestFlight > Run workflow, or `gh workflow run testflight.yml` (add `--ref <branch>` to build a branch).
- Never on a pull request: pull requests cannot read the signing secrets, and an unreviewed build should not reach the Duo.

The run archives the app, signs it with Xcode's automatic signing, uploads it and then waits until App Store Connect reports the build processed. A green run means App Store Connect has processed the build for TestFlight; it reaches the Duo through the testing group below.

The build number (`CFBundleVersion`) is the UTC date and time the run started its upload step, `<yyyymmdd>.<hhmmss>` with the time's leading zeros dropped: `20261101.143005` for 14:30:05, `20261101.5` for 00:00:05. `apps/ios/Scripts/build-number.sh` makes it, and the run's log prints it. App Store Connect compares build numbers as integers, part by part, so each upload's number is larger than the last, even when an old run is retried after a newer one has uploaded (a run number would repeat the old run's number). Uploads are one at a time, so two never share a second. The version (`MARKETING_VERSION`) comes from `apps/ios/project.yml`.

## Setting it up

`apps/ios/Scripts/setup-testflight.sh` walks through everything only Zach can do: registering the bundle ID, creating the app record in App Store Connect, the four secrets below, and the TestFlight testing group. Run it with `bash apps/ios/Scripts/setup-testflight.sh` where `gh` is signed in to `millZach/Vellum`. It holds nothing secret: what is pasted goes straight to the repository secrets, and only the non-secret answers are remembered, in `~/.config/vellum/testflight.env`.

## Where the secrets live

Repository secrets on `millZach/Vellum` (Settings > Secrets and variables > Actions), never in a file:

- `APPLE_TEAM_ID`: passed to `xcodebuild` as `DEVELOPMENT_TEAM` when archiving and to the export options, which are written on the runner and deleted.
- `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_ID` and `APP_STORE_CONNECT_KEY` (the `.p8` contents): an App Store Connect API key with the Admin role, which automatic signing needs to use Apple's cloud-managed distribution certificate. The key is written to the runner's temporary folder and removed at the end of the run, pass or fail.

- `DROPBOX_APP_KEY`: the Dropbox app's key, passed to `xcodebuild` as the `DROPBOX_APP_KEY` build setting, which puts it in the app's Info.plist and its `db-<key>` callback scheme (ADR-0013). `Scripts/testflight.sh` refuses to archive without a key shaped like one and checks the archived Info.plist carries it, without printing it. Every other build has the placeholder `not-set-up` and says Dropbox isn't set up. The Dropbox app itself (full Dropbox access, public clients allowed for PKCE, the redirect URI `db-<key>://2/token`) is set up in Dropbox's app console; no Dropbox app secret is used or kept anywhere.

No certificate or provisioning profile is kept anywhere.

## Installing on the Duo

A processed build reaches the Duo only through a TestFlight testing group. Set up once (the wizard's last stage):

1. In App Store Connect, open the app (named "Vellum Canvas"), then TestFlight > Internal Testing, and add an internal group with Zach in it as a tester.
2. Turn on automatic distribution for the group, so every new processed build is given to it without approving each one.
3. On the Duo, install TestFlight from the App Store, signed in with Zach's Apple account, and accept the invitation.

After that each build shows in TestFlight on the Duo and installs with one tap, or by itself if automatic updates are on for Vellum in TestFlight.
