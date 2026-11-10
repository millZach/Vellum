# Performance baselines

How Vellum keeps the speed it has won (ADR-0015, AGENTS.md "Speed is the product"). Every area that matters for how fast the app feels has a baseline file, and two kinds of number in it.

## Two kinds of metric

1. **Work counts (`"kind": "count"`) are budgets.** Deterministic counts of work measured by VellumCore tests on made-up fixtures: paths rebuilt per redraw, points inspected per eraser sample, requests per action, bytes written per stroke, copies per edit. They run on Forge's Linux Swift and in CI. A count above its budget fails the test. Tolerance is 0.
2. **Timings (`"kind": "time"`) are compared.** Wall-clock numbers measured in CI: frame times on the 10,000-stroke canvas, storage append and reopen times, sign-out with a stalled network. CI records them in the job log, the job summary and an artifact, and `apps/ios/Scripts/perf-compare.py` emits a GitHub warning annotation when one is more than its tolerance worse than its baseline on that runner (see "Comparing timings in CI"). Timings never fail the build, because hosted runners are noisy, but a warning is explained in the PR.

## Where they live

One JSON file per area, so work on different areas never conflicts:

| Area | File | Issue |
|---|---|---|
| Canvas rendering, input and eraser | `baselines/canvas-rendering.json` | #21 |
| Saving ink on the Duo | `baselines/storage.json` | #9 |
| Dropbox | `baselines/dropbox.json` | #20, #10 |
| Placed sheets: tiles drawn and kept, PDF downloads, and the drawing viewer's time to its first page | `baselines/sheets.json` | #11, #69 |
| Syncing canvases to Dropbox: requests and bytes per sync, the folder check and re-upload after a deleted folder, leaving a canvas | `baselines/sync.json` | #12, #37 |
| The laptop indexer: files read and index files written per rescan and per change, updates per folder copy, scan timings on a made-up 5,000-file Dropbox; plotting on request: files written per plot, console runs, check-in writes an hour, and the time from seeing a request to its answer | `baselines/laptop-indexer.json` | #66, #67 |
| The Duo's copy of the drawing index and its search: requests and bytes per refresh, thumbnails per refresh and per row, the search's memory and entries looked at per keystroke on a made-up 20,000-drawing index, and its load, keystroke and full-scan times | `baselines/drawing-index.json` | #68 |
| Plot requests on the Duo: uploads and bytes per ask, requests a minute while waiting for the laptop, PDF downloads per plot | `baselines/plot-requests.json` | #70 |

Later areas (`jobs`) add their own file the same way. The pan, pinch, draw and turn frame times over a placed sheet are timings in `canvas-rendering.json` (`sheet_pan_*`, `sheet_pinch_*`, `sheet_draw_*`, `sheet_turn_*`), since the same benchmark records them. The `sheet_turn` scenario twists the placed sheet two fingers' worth, 1.5° a frame for 240 frames, through its catches, and logs `tiles_drawn_during_turn`, which should be 0. The `shape` scenario (#40) is the line tool's second point wandering over the 10,000-stroke canvas: each frame a snap lookup with a point to work from, the angle catch, the loupe and the preview. Its timings record until a change gives them samples enough for a baseline. The `sheet_snap` scenario (#57), run last, is the measure tool's Pencil wandering back and forth across the placed sheet's left edge from corner to corner: each frame a snap lookup through the ink index and the sheet index, catching a sheet corner, a sheet edge or the ink, and the loupe. Its timings record the same way until there are samples enough.

Each file is `{ "area": "...", "entries": [ ... ] }`, and each entry:

```json
{
  "metric": "eraser_points_inspected_per_sample",
  "kind": "count",
  "value": 350,
  "before": 724153,
  "unit": "points",
  "tolerance": 0,
  "measured": "<commit or branch> <date> <machine: runner image, Xcode, simulator runtime, or Linux Swift>",
  "note": "what exactly is measured, and why the value is what it is"
}
```

`before` is optional: the value before the change that set the baseline, so the first baseline shows the improvement.

A timing may also carry `"scaled_by"`, naming a `"kind": "reference"` entry (its baseline is stated for the runner whose reference reads that entry's value), and `"warn": false`, which records it without warning.

## Rules

- **The file is the single source.** A budget test reads its area's file (found from `#filePath`, so it works on Linux and macOS) rather than repeating the number.
- **Budgets only tighten.** When a change makes a count smaller, lower its value in the same PR. Raising one needs its reason in the PR and in the entry's `note`.
- **Report numbers in the PR.** A PR that touches drawing, storage, sync or the network gives before and after for its area's metrics in its body and says which budgets tightened.
- **Timings say where they were measured.** A new runner image, Xcode or simulator runtime moves timings; re-baseline then, and say so.

The drawing index's counts are budgets in `DrawingIndexTests`, `DrawingIndexDownloadTests` and `DrawingSearchTimingTests`. `DrawingIndexDownloadTests.testTimings` (#98) times the first refresh of a made-up 2,500-shard index against a stand-in network that answers each request after 5 ms, one shard at a time (`index_first_refresh_2500_one_at_a_time_ms`, the way before #98, recorded only) and six at a time (`index_first_refresh_2500_ms`), in an optimised run of its own after the search's, adding to the same measurements file. On the first sample (run 42897344798) it went from 69.3 s to 13.4 s; most of the runner's time is the durable writes, not the stand-in round trips. A Mac runner with a 5 ms round trip, not the Duo on Wi-Fi, where a round trip is a few hundred milliseconds and the gain is nearer sixfold. Its timings come from `DrawingSearchTimingTests` run again in an optimised build (`swift test -c release`, with `VELLUM_PERF_OUT` naming the measurements file) in the **VellumCore tests (macOS)** job, compared with `perf-compare.py drawing-index`: a Debug build's search is many times slower than the app's, so it would say little. They are a Mac runner's numbers for the search code alone, not the Duo's; the Duo's own feel is checked by hand on the TestFlight build. The job keeps the measurements as the `drawing-search-timings` artifact.

The laptop indexer's counts are budgets in its pytest suite (`laptop/tests/test_incremental.py` and `test_watch.py` read the file the same way), and its timings come from `laptop/scripts/bench.py` in the **Laptop indexer tests (Windows)** job on `windows-latest`, compared with `perf-compare.py laptop-indexer`. They are measured with a stand-in DWG reader, since CI has no AutoCAD: on the laptop, a first scan's time is mostly AutoCAD's core console, a few seconds a DWG. Online-only downloads are counted and timed against a scripted Dropbox API, so they show the indexer's own work, not the network's. The job keeps its measurements as the `laptop-indexer-timings` artifact.

## Comparing timings in CI

```sh
python3 apps/ios/Scripts/perf-compare.py <area> <measurements.json>
```

The measurements file is `{ "measurements": [ { "metric": "...", "value": n }, ... ] }`. The script prints a table (and appends it to the job summary), warns for each timing more than its tolerance worse, and always exits 0. The canvas-rendering timings come from the Debug-only benchmark (`apps/ios/Vellum/DebugBenchmark.swift`), which `apps/ios/Scripts/capture-duo.sh` runs on the iPhone Duo simulator: the Debug build in the **Duo captures: canvas tools and benchmark** job (until #80, the **Duo simulator captures** job, which ran the same benchmark after the tab captures as well), the optimised (Release, BENCHMARK) build in the **Duo release benchmark** job (split off in #8, when the captures outgrew one job). The drawing viewer's time to its first page (`sheets`, `viewer-timing.json`) comes from the **Duo captures: sheets and drawing viewer** job (until #80, **Duo sheet and sync captures**).

### How the canvas timings are judged (#32)

Hosted runners do not come in a fast and a slow kind that a baseline could pick between. Their speed runs continuously between the two ends and moves within a job, so one run can be fast in one scenario and slow in the next. So:

- **The speed probe says how fast the runner is just now.** Before each scenario the benchmark strokes a fixed path into a bitmap five times and takes the median; the median over the scenarios is `speed_probe_ms_release`. No Vellum code is in it, so a change to Vellum cannot slow it, and a slowdown across every scenario still shows. A timing's baseline is stated for the runner in the `reference` entry, and the comparison is against baseline × measured probe / reference probe. A measurements file without the probe is compared unscaled. The Debug timings are not scaled: the probe read fast in the captures job while the frame times stayed at their usual level, so scaling there raised ten false warnings on its first run. Debug only logs the probe.
- **The Release job runs three launches and keeps each timing's median** (`Scripts/perf-passes.py`). They are separate launches on a fresh canvas, because the scenarios change the canvas (the eraser removes strokes). Each launch takes about 90 seconds inside its own 240-second wait. `BENCHMARK_PASSES` changes the number.
- **What warns.** Release p50 at 25% worse and Release p95 at 40%, since a p95 moves more between runs. Debug p50 at 25%: the canvas captures job runs one Debug launch, whose p95 one stall can set. Everything else only records (`"warn": false`), every max included: one 30-80 ms stall on the main thread sets a max on any commit (#42).
- **A baseline is the upper quartile of several samples.** Release: at least six samples, each the median of three launches and scaled to the reference runner by its probe. Debug: at least a dozen runs of the job that runs the Debug benchmark (the canvas captures job since #80, the Duo simulator captures job before), unscaled. Debug `drag` p50 and p95 are the exception: they come from the benchmark running alone (run 41764008766), since the fix changed them and the captures job's history predates it. Re-baseline the same way when the runner image, Xcode or simulator runtime changes, or when a change means to move a timing.
- **`settled_ms` is not a timing to compare.** The benchmark stops waiting for tiles after 5 seconds and then logs `settled_ms>=5000.00 still_pending=N`, a lower bound and not a measurement. It stays in the log only.

### What ran on the main thread (#42)

The benchmark also counts what the main thread did between frames (`apps/ios/Vellum/MainThreadLedger.swift`): how long it was awake, and how much of that went to sheet tiles landing, the sheet plan, ink tiles landing and starting, the ink plan, the canvas view moving its layers, and Core Animation's commit; the rest is "other" (SwiftUI, UIKit, the system). After each scenario's `slow work` line, `main busy_ms` and `cpu_ms` give the awake time and the CPU time per frame, with each part's count, total and most in one frame, and a `gap n:` line names what ran before every long gap, with the main thread's CPU time beside its awake time. A long gap with little of Vellum's named work before it, and the main thread awake far longer than it ran on a core, is a wait, not work: the runner keeping the thread off a core, or a synchronous wait (a lock, a commit waiting on the render server), which these numbers alone can't tell apart. The Duo's Speed check tells them apart: a wait on the Duo is Vellum's to find. The same ledger feeds the Speed check on the Duo, so a copy from the Duo answers the same question; the log ends with `speed_check_us_per_frame`, what the Speed check adds to a frame's main-thread work.

Scored leaving each sample's own job out of its baseline, over 12 Release samples: 3 of the 12 raised any warning (0.7 warnings of 20 on average), a single p50 made 50% worse warned 75% of the time, a single p95 made 50% worse warned 40% of the time and 72% at double, and with everything 50% worse every sample warned. The same quartile with no probe caught a single p50 49% of the time. So a warning is a question, not a verdict: rerun the job before reading much into a lone one.
