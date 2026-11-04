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
| Placed sheets: tiles drawn and kept, PDF downloads | `baselines/sheets.json` | #11 |
| Syncing canvases to Dropbox: requests and bytes per sync, the folder check and re-upload after a deleted folder, leaving a canvas | `baselines/sync.json` | #12, #37 |

Later areas (`jobs`) add their own file the same way. The pan, pinch and draw frame times over a placed sheet are timings in `canvas-rendering.json` (`sheet_pan_*`, `sheet_pinch_*`, `sheet_draw_*`), since the same benchmark records them.

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

## Comparing timings in CI

```sh
python3 apps/ios/Scripts/perf-compare.py <area> <measurements.json>
```

The measurements file is `{ "measurements": [ { "metric": "...", "value": n }, ... ] }`. The script prints a table (and appends it to the job summary), warns for each timing more than its tolerance worse, and always exits 0. The canvas-rendering timings come from the Debug-only benchmark (`apps/ios/Vellum/DebugBenchmark.swift`), which `apps/ios/Scripts/capture-duo.sh` runs on the iPhone Duo simulator: the Debug build in the **Duo simulator captures** job, the optimised (Release, BENCHMARK) build in the **Duo release benchmark** job (split off in #8, when the captures outgrew one job).

### How the canvas timings are judged (#32)

Hosted runners do not come in a fast and a slow kind that a baseline could pick between. Their speed runs continuously between the two ends and moves within a job, so one run can be fast in one scenario and slow in the next. So:

- **The speed probe says how fast the runner is just now.** Before each scenario the benchmark strokes a fixed path into a bitmap five times and takes the median; the median over the scenarios is `speed_probe_ms_release`. No Vellum code is in it, so a change to Vellum cannot slow it, and a slowdown across every scenario still shows. A timing's baseline is stated for the runner in the `reference` entry, and the comparison is against baseline × measured probe / reference probe. A measurements file without the probe is compared unscaled. The Debug timings are not scaled: the probe read fast in the captures job while the frame times stayed at their usual level, so scaling there raised ten false warnings on its first run. Debug only logs the probe.
- **The Release job runs three launches and keeps each timing's median** (`Scripts/perf-passes.py`). They are separate launches on a fresh canvas, because the scenarios change the canvas (the eraser removes strokes). Each launch takes about 90 seconds inside its own 240-second wait. `BENCHMARK_PASSES` changes the number.
- **What warns.** Release p50 at 25% worse and Release p95 at 40%, since a p95 moves more between runs. Debug p50 at 25%: the captures job runs one Debug launch, whose p95 one stall can set. Everything else only records (`"warn": false`), every max included: one 30-80 ms stall on the main thread sets a max on any commit (#42).
- **A baseline is the upper quartile of several samples.** Release: at least six samples, each the median of three launches and scaled to the reference runner by its probe. Debug: at least a dozen runs of the captures job itself, unscaled. Debug `drag` p50 and p95 are the exception: they come from the benchmark running alone (run 41764008766), since the fix changed them and the captures job's history predates it. Re-baseline the same way when the runner image, Xcode or simulator runtime changes, or when a change means to move a timing.
- **`settled_ms` is not a timing to compare.** The benchmark stops waiting for tiles after 5 seconds and then logs `settled_ms>=5000.00 still_pending=N`, a lower bound and not a measurement. It stays in the log only.

Scored leaving each sample's own job out of its baseline, over 12 Release samples: 3 of the 12 raised any warning (0.7 warnings of 20 on average), a single p50 made 50% worse warned 75% of the time, a single p95 made 50% worse warned 40% of the time and 72% at double, and with everything 50% worse every sample warned. The same quartile with no probe caught a single p50 49% of the time. So a warning is a question, not a verdict: rerun the job before reading much into a lone one.
