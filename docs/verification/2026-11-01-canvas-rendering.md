# Canvas rendering verification

November 1, 2026, on `perf/canvas-rendering` (#21, PR #23). The CI job **Duo simulator captures** took the captures and ran the Debug-only benchmark on GitHub's hosted `xcode-27` image with Xcode 27.2 and the iPhone Duo simulator (iOS 27.1), unfolded, through `apps/ios/Scripts/capture-duo.sh`. The canvas is the made-up 10,000-stroke fixture (`MadeUpInk.largeWalkdown`, opened with `--ui-fixture-large`): about 795,000 points of scribbles in all four markup colours over a made-up plant about 400 × 280 feet. No real drawing is in it.

- **Before**: main's renderer with only the benchmark added (commits a861465 and e7be8e8), [run 41274235624](https://github.com/millZach/Vellum/actions/runs/41274235624).
- **After**: the tile renderer at commit 0bb7dc2, [run 41278556468](https://github.com/millZach/Vellum/actions/runs/41278556468).

## Frame times

Main-thread busy time per display frame, from the display link's tick until the run loop slept, in milliseconds. The budget at 120 Hz is 8.3 ms. These are **indicative only**: a Debug build (VellumCore unoptimised) on a shared runner's simulator, which runs at 60 Hz whatever the app asks for (`maximumFramesPerSecond=60` with the ProMotion opt-in present). The Duo is the judge.

| Scenario | Before p50 / p95 / max | After p50 / p95 / max | After frames over 8.3 ms |
|---|---|---|---|
| Pan at everything | 7,439 / 7,750 / 7,750 (3 frames in 20 s) | 1.62 / 2.90 / 5.14 | 0 of 239 |
| Pinch in 11× and out | 6,542 / 6,911 / 6,911 (4 frames in 20 s) | 5.05 / 7.71 / 11.61 | 7 of 239 |
| Draw a stroke | 1.47 / 3.56 / 20.50 | 1.66 / 3.11 / 4.00 | 0 of 239 |
| Eraser sweep | 5,947 / 6,231 / 6,231 (4 frames in 20 s) | 7.69 / 13.55 / 24.35 | 102 of 239 |

Before, main redrew all 10,000 strokes on every frame of a pan or pinch and for every eraser hit, so each frame took six to seven seconds and the benchmark's 20-second cap stopped each scenario after three or four frames. Drawing was already cheap on main because the stroke in progress was a shape layer; its cost came after the Pencil lifted, when the whole view was redrawn (5.6 s to settle).

After, the eraser sweep is the one scenario over budget at p95. It erases about 1,860 strokes in 240 frames, so most frames carry a hit; each hit queues the tiles it touches to be redrawn, and the main thread spends up to 2 ms a frame finding their strokes. On forge's Linux Swift (Debug), one hit costs the ink session about 0.4 ms and the index about 0.008 ms; the rest of the frame is that queue, SwiftUI updating the views that read the canvas, and the Core Animation commit, which this benchmark does not separate. The pinch's frames over budget are where it changes level of detail.

The work counts behind these numbers are budgets in `docs/perf/baselines/canvas-rendering.json`, enforced by `CanvasRenderingBudgetTests`.

## Captures

`artifacts/2026-11-01-canvas-rendering/`, each 2853 × 2007 pixels (951 × 669 points at 3×), the fixture zoomed to everything:

- `before-unfolded-canvas-large-light.png`, `before-unfolded-canvas-large-dark.png`: main's renderer.
- `after-unfolded-canvas-large-light.png`, `after-unfolded-canvas-large-dark.png`: the tiles.
- `benchmark-before.txt`, `benchmark-after.txt`: the benchmark's logs.

The tiles draw the same ink as main: the mean pixel difference between before and after is 0.7% in light and dark, from hairlines drawn at a level of detail up to √2 finer than the screen and then scaled. The small fixture's captures (`canvas-everything`, `canvas-closeup`) differ from main's by about 0.01%. Sketch ink flips to near-white in dark mode and red, green and blue keep their hue, as before.

## After the review fixes

[Run 41322007076](https://github.com/millZach/Vellum/actions/runs/41322007076), commit 402cf05, same image and simulator. Every scenario now reports all 240 frames, the Pencil's lift and the stroke's commit included. The benchmark also runs in an optimised Release build (`capture-duo.sh` builds it with a `BENCHMARK` compilation condition that TestFlight builds never set). Milliseconds, p50 / p95 / max, frames over 8.3 ms:

| Scenario | Debug | Release |
|---|---|---|
| Pan at everything | 1.45 / 1.87 / 4.36, 0 over | 1.87 / 3.03 / 4.76, 0 over |
| Pinch in 11× and out | 4.44 / 7.11 / 9.97, 4 over | 3.16 / 6.05 / 17.29, 4 over |
| Draw a stroke | 1.28 / 1.46 / 4.27, 0 over | 2.52 / 4.73 / 31.91, 4 over |
| Eraser sweep | 4.78 / 8.00 / 14.93, 7 over | 1.81 / 5.03 / 32.00, 4 over |

The eraser's p95 is now inside 8.3 ms in both builds (it was 13.55 ms, 102 frames over). Most of what was left was not drawing: every hit wrote the ink back to the canvas, which copied all 10,000 strokes on the next hit (the canvas and the session shared the array) and updated every SwiftUI view that reads the canvas. The canvas now gets the ink once, when the sweep ends; undo and redo availability are their own observed values. What remains on an eraser frame is finding the touched tiles' strokes (at most 2 ms a frame) and the Core Animation commit of redrawn tiles.

The Release maxima of about 32 ms are single frames, each also a two- or three-frame display interval in the same log, and the Debug build of the same code peaks at 4.27 ms (draw) and 14.93 ms (erase); they look like the shared runner rather than the app, and the confirmation run on the next commit (in the PR) shows whether they repeat. The pinch's frames over budget are where it changes level of detail.

Captures of the test canvas after the fixes: `review-fixes-unfolded-canvas-large-light.png` and `-dark.png`; logs: `benchmark-review-fixes-debug.txt` and `-release.txt`.

## Not checked

- The real Duo at 120 Hz with the Apple Pencil. The simulator runs at 60 Hz, so the ProMotion opt-in is only shown to be present in the app's Info.plist (`promotionOptIn=true`). This is the PR's last hand-test item, through TestFlight.
- The long press on the canvas name that opens the test canvas in TestFlight builds: the simulator tools here cannot long-press, so it is proved by building only.
- Folded, on the cover screen.
