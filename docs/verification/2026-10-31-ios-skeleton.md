# iOS skeleton verification

October 31, 2026, on `feat/ios-skeleton` (#3, PR #16). Captured by the CI job **Duo simulator captures**, [run 41237858561](https://github.com/millZach/Vellum/actions/runs/41237858561), on GitHub's hosted `xcode-27` image with Xcode 27.2 (27B48), on the iPhone Duo simulator with the iOS 27.1 runtime, the only Duo runtime on that image. The simulator was booted headless. `apps/ios/Scripts/capture-duo.sh` unfolded it with SpringBoard's display tool service, through `apps/ios/Scripts/duo/posture.m` (Sotto's tool from the tag `prototype/iphone-duo-layout`), and screenshotted the inner display. Each capture is 2853 × 2007 pixels, which is 951 × 669 points at 3×, the Duo unfolded. The Debug-only `--ui-tab <name>` launch argument opened each tab, and `xcrun simctl ui appearance` set light or dark.

## What the captures show

`artifacts/2026-10-31-ios-skeleton/unfolded-<tab>-<light|dark>.png`, for Canvases, Drawings, Jobs and Meetings:

1. Unfolded, iOS draws the tab bar as a rail at the right edge, as ADR-0011 has it. The rail shows the four symbols without their names, and the selected tab is highlighted.
2. Each tab's screen shows its name and its one line saying what it will hold, centred.
3. Dark follows the simulator's appearance.

## Not checked

- Folded, on the cover screen.
- Tapping between tabs. Each capture is a fresh launch on the tab named by `--ui-tab`.
- VoiceOver and the larger text sizes.
- The real Duo.
