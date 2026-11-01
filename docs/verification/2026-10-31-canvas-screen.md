# Canvas screen verification

October 31, 2026, on `feat/canvas-screen` (#6, PR #19). The CI job **Duo simulator captures** took these, [run 41254343034](https://github.com/millZach/Vellum/actions/runs/41254343034) at commit f2eca9a, on GitHub's hosted `xcode-27` image with Xcode 27.2 and the iPhone Duo simulator (iOS 27.1). `apps/ios/Scripts/capture-duo.sh` unfolded it the way the iOS skeleton captures did. Each capture is 2853 × 2007 pixels, which is 951 × 669 points at 3×. `xcrun simctl ui appearance` set light or dark, and the app followed it on its default System setting. The ink comes from the Debug-only fixture (`apps/ios/Vellum/DebugFixture.swift`, opened with `--ui-fixture`). It is a made-up pipe run with a pump, a valve and a tank, marked up in all four markup colours. No real drawing is in it.

## What the captures show

`artifacts/2026-10-31-canvas-screen/unfolded-<capture>-<light|dark>.png`:

- `canvas-empty`: a new canvas. It shows the tool rail with line and shape, lasso, text box, measure, dimension, frame and window dimmed as disabled; the top bar; Add sheet, Record and Send dimmed; and the status bar reading "Not saved yet".
- `canvas-everything`: the fixture zoomed to everything, fitted between the rail, the bars and the tab rail. It shows red (add: a clouded bypass), green (delete: a crossed-out branch), blue (note: a leader and a wavy note), sketch linework and a highlighter stroke.
- `canvas-closeup`: the same canvas close up on the valve, about 2.5 feet across. The valve and its red, blue and sketch strokes drawn close up are at their drawn width. The plant-scale strokes drawn zoomed out are wide, because a stroke's width is real-world (ADR-0012).
- `drawings`, `jobs`, `meetings`: the other tabs, unchanged.

In dark mode, sketch ink is near-white and red, green and blue keep their hue.

What looking at them found:

- The chrome sits clear of the tab rail and the clock, as in the prototype's variant A. Ink passes under the translucent rail and bars.
- The close-up shows the cost of real-world stroke widths. The pipe and the red bypass were drawn zoomed out at 3", and close up on a 2-foot valve they are broad bands. The valve's own strokes, drawn close up, are fine lines. This is the behaviour ADR-0012 chose. It is listed for Zach in the PR.
- The pen's prompt, "Draw with the Pencil. Fingers pan and pinch", was cut off in the status bar. The commit after these captures shortens the working tools' prompts to "Draw with the Pencil" and "Touch ink to erase a stroke", and a test keeps them short enough to fit. That commit's own CI run has the fresh captures.

## Not checked

- Drawing with the Apple Pencil, latency and palm rejection. These need the real Duo through TestFlight.
- Pinch and pan. Each capture is a fresh launch at a set zoom.
- Folded, on the cover screen.
- VoiceOver and the larger text sizes.
