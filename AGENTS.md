# Vellum

Vellum is a native iOS app for one person on one device: Zach's iPhone Duo, used unfolded, drawn on with the Apple Pencil. It is a blank canvas for drawing, notes and text boxes. You can zoom far out and measure on it the way AutoCAD's model space works, and it places PDFs from Dropbox at the size they would print. It records meetings and turns them into summarized notes. It sends a marked-up canvas to an agent: Sotto's Watcher turns the job into a thread in the right folder on the laptop, where AutoCAD and Dropbox live.

This is a brief, not a specification. It names what is expensive to get wrong and leaves the rest to you. Where it does not reach, work out what Vellum would do from `CONTEXT.md`, the ADRs and the running app, and say in the PR what you worked out.

## What is expensive to get wrong

- **The repository is public.** No keys, tokens, Dropbox app secrets, signing files, team IDs beyond what Xcode already requires, or client drawings, PDFs, meeting audio or transcripts, ever, including in tests, fixtures, screenshots and verification notes. Fixtures are drawings made up for the test. Secrets reach CI only as GitHub Actions secrets, and reach the app only through a file `.gitignore` already lists. A change that needs a new secret says in the PR where it lives and how it gets there.
- **Scale is the product.** A PDF placed on the canvas is the size it prints, and a dimension read off the canvas is a real length. A change that touches units, zoom or PDF placement proves its numbers in a test, not by eye.
- **The pen's ink is Zach's work.** Nothing loses a stroke: not a crash, not a sync, not a send to an agent. Saving comes before anything clever.
- **Speed is the product.** How fast and smooth Vellum feels comes first. Nothing heavy runs on the main thread or once per Pencil sample; disk writes and network transfers are kept to the minimum the job needs. Every PR that touches drawing, storage or sync reports its measured numbers, before and after, against the baselines in `docs/perf/README.md`.
- **Agent work goes through Sotto.** Vellum does not drive AutoCAD or the laptop itself. It hands a job to Sotto, and the thread Sotto starts does the work (`CONTEXT.md` names the parts once the grill settles them).

## Read first

- `CONTEXT.md` is the glossary. Write in its terms; when the work needs a word it has not got, add the entry in the same PR.
- `docs/adr/` records decisions. Read the ones that touch your area before changing it, and amend or supersede one you contradict. `docs/agents/domain.md` has the rules.

## Where things are

- `apps/ios/Vellum/`: the SwiftUI app, the iOS tab bar with Canvases, Drawings, Jobs and Meetings. Bundle identifier `com.millzach.vellum`, iPhone only, iOS 27.1 and up.
- `apps/ios/Sources/VellumCore/` and `apps/ios/Tests/VellumCoreTests/`: the `VellumCore` Swift package (`apps/ios/Package.swift`), everything testable without a device (canvas model, canvas units, sheet placement, the job format sent to Sotto), with its XCTest suite. It imports neither SwiftUI nor UIKit, so it also builds with Forge's Linux Swift.
- `apps/ios/project.yml`: the XcodeGen spec. `apps/ios/Scripts/generate-project.sh` generates `Vellum.xcodeproj` from it with a pinned, checksummed XcodeGen; the project is gitignored, so change `project.yml`, never a `.pbxproj`.
- `.github/workflows/ci.yml`: CI. Sotto's `apps/ios/` is the pattern it and the app follow.

## Run, test and prove

Forge has no Mac. iOS builds and tests run on GitHub's macOS runners, the way Sotto's iPhone client does. CI never runs on Zach's laptop.

- Unit tests: `swift test` in `apps/ios` runs the `VellumCore` suite. It runs on Forge too; run it there before pushing.
- Build: `sh apps/ios/Scripts/build-simulator.sh` generates the project and builds the app for the iOS simulator, unsigned (`CODE_SIGNING_ALLOWED=NO`).
- `sh apps/ios/Scripts/verify.sh` runs both, the same gates CI runs, for someone on a Mac.
- CI runs on GitHub's hosted `xcode-27` image with Xcode 27.2 (the iOS 27.2 SDK), selected with `DEVELOPER_DIR`. That image's iPhone Duo simulator is iOS 27.1, which is why the app targets iOS 27.1.
- Prove a visible change on the iPhone Duo simulator, unfolded (951×669 points). Prove anything that touches drawing on the real Duo with the Apple Pencil, through a TestFlight build.
- A build reaches the Duo through TestFlight: `.github/workflows/testflight.yml` archives, signs, uploads and waits for App Store Connect to process the build on every push to `main` that changes `apps/ios/` or the workflow, or by hand with `gh workflow run testflight.yml --ref <branch>`. `docs/testflight.md` says where its secrets live, how the build number is formed and how the Duo installs the build; `apps/ios/Scripts/setup-testflight.sh` sets it up.

## The merge bar

Both macOS jobs in `.github/workflows/ci.yml` are green on the pull request's latest commit before merge: **VellumCore tests (macOS)** and **iOS simulator build (macOS)**.

Pull requests go through the merge train: post `READY TO MERGE #N`, wait for `GO MERGE`, merge, then post `MERGED #N <sha>`. After pushing, end your turn rather than watching CI.

## Commits and pull requests

- Commit subject: one plain-English imperative sentence, no type prefix, no trailing period. Body: prose on what changed and why.
- Branch from `main` as `feat/`, `fix/`, `chore/`, `test/`, `perf/` or `prototype/` plus a short slug. One PR closes one issue.
- PR body: `docs/agents/pull-requests.md`.

## Agent skills

### Issue tracker

Issues are GitHub Issues on `millZach/Vellum`, through `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the root. See `docs/agents/domain.md`.
