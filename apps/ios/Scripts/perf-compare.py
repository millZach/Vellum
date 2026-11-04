#!/usr/bin/env python3
"""Compares timings measured in CI with an area's baseline (docs/perf/README.md).

usage: perf-compare.py <area> <measurements.json>

The measurements file holds {"measurements": [{"metric": "...", "value": n}, ...]}. Each one is compared with the
"time" entry of the same metric in docs/perf/baselines/<area>.json. An entry with "scaled_by" names a "reference" entry,
a measurement of how fast the runner was: what this runner should take is the baseline times measured reference /
baseline reference. A timing more than its tolerance (25% by default) worse than that emits a GitHub warning annotation,
unless its entry says "warn": false, which only records it. Timings never fail the build: hosted runners are noisy.
Counts are enforced by the VellumCore budget tests, not here. Writes a table to the job summary when GITHUB_STEP_SUMMARY
is set.
"""
import json
import os
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 0
    area, path = sys.argv[1], sys.argv[2]
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
    baseline_path = os.path.join(root, "docs", "perf", "baselines", f"{area}.json")
    try:
        with open(path) as f:
            measured = {m["metric"]: float(m["value"]) for m in json.load(f)["measurements"]}
    except (OSError, ValueError, KeyError) as error:
        print(f"::warning title=Perf timings ({area})::No measurements read from {path}: {error}")
        return 0
    try:
        with open(baseline_path) as f:
            entries = json.load(f)["entries"]
    except (OSError, ValueError, KeyError, TypeError):
        entries = []
        print(f"No timing baseline at {baseline_path}; recording only.")
    baseline = {e["metric"]: e for e in entries if e.get("kind") == "time"}
    references = {e["metric"]: e for e in entries if e.get("kind") == "reference"}

    def scale(entry: dict) -> float:
        """How much longer than the baseline this runner should take; 1 when it did not measure the reference."""
        reference = references.get(entry.get("scaled_by"))
        now = measured.get(entry.get("scaled_by"))
        if not reference or not now or now <= 0 or float(reference["value"]) <= 0:
            return 1.0
        return now / float(reference["value"])

    rows = ["| Metric | Measured | Baseline | On this runner | Change |", "|---|---|---|---|---|"]
    for metric in sorted(measured):
        value = measured[metric]
        if metric in references:
            base = float(references[metric]["value"])
            rows.append(f"| {metric} | {value:.2f} | {base:.2f} | – | {value / base:.2f}x the reference runner |")
            continue
        entry = baseline.get(metric)
        if entry is None:
            rows.append(f"| {metric} | {value:.2f} | – | – | new |")
            continue
        base = float(entry["value"])
        expected = base * scale(entry)
        tolerance = float(entry.get("tolerance", 0.25))
        change = (value - expected) / expected if expected > 0 else 0.0
        flag = ""
        if not entry.get("warn", True):
            flag = " (recorded)"
        elif value > expected * (1 + tolerance):
            flag = " ⚠️"
            print(f"::warning title=Perf regression ({area})::{metric} is {value:.2f} {entry.get('unit', '')}, "
                  f"{change:+.0%} against {expected:.2f} on this runner, from the baseline {base:.2f} "
                  f"(tolerance {tolerance:.0%}). Explain it in the PR.")
        rows.append(f"| {metric} | {value:.2f} | {base:.2f} | {expected:.2f} | {change:+.0%}{flag} |")
    table = "\n".join(rows)
    print(table)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(f"### Perf timings: {area}\n\n{table}\n\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
