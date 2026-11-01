# Performance baselines

How Vellum keeps the speed it has won (ADR-0015, AGENTS.md "Speed is the product"). Every area that matters for how fast the app feels has a baseline file, and two kinds of number in it.

## Two kinds of metric

1. **Work counts (`"kind": "count"`) are budgets.** Deterministic counts of work measured by VellumCore tests on made-up fixtures: paths rebuilt per redraw, points inspected per eraser sample, requests per action, bytes written per stroke, copies per edit. They run on Forge's Linux Swift and in CI. A count above its budget fails the test. Tolerance is 0.
2. **Timings (`"kind": "time"`) are compared.** Wall-clock numbers measured in CI: frame times on the 10,000-stroke canvas, storage append and reopen times, sign-out with a stalled network. CI records them in the job log, the job summary and an artifact, and `apps/ios/Scripts/perf-compare.py` emits a GitHub warning annotation when one is more than its tolerance (25%) worse than its baseline. Timings never fail the build, because hosted runners are noisy, but a warning is explained in the PR.

## Where they live

One JSON file per area, so work on different areas never conflicts:

| Area | File | Issue |
|---|---|---|
| Canvas rendering, input and eraser | `baselines/canvas-rendering.json` | #21 |
| Saving ink on the Duo | `baselines/storage.json` | #9 |
| Dropbox | `baselines/dropbox.json` | #20, #10 |

Later areas (`sheets`, `sync`, `jobs`) add their own file the same way.

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

## Rules

- **The file is the single source.** A budget test reads its area's file (found from `#filePath`, so it works on Linux and macOS) rather than repeating the number.
- **Budgets only tighten.** When a change makes a count smaller, lower its value in the same PR. Raising one needs its reason in the PR and in the entry's `note`.
- **Report numbers in the PR.** A PR that touches drawing, storage, sync or the network gives before and after for its area's metrics in its body and says which budgets tightened.
- **Timings say where they were measured.** A new runner image, Xcode or simulator runtime moves timings; re-baseline then, and say so.

## Comparing timings in CI

```sh
python3 apps/ios/Scripts/perf-compare.py <area> <measurements.json>
```

The measurements file is `{ "measurements": [ { "metric": "...", "value": n }, ... ] }`. The script prints a table (and appends it to the job summary), warns for each timing more than its tolerance worse, and always exits 0. The canvas-rendering timings come from the Debug-only benchmark (`apps/ios/Vellum/DebugBenchmark.swift`), which `apps/ios/Scripts/capture-duo.sh` runs on the iPhone Duo simulator in the **Duo simulator captures** job.
