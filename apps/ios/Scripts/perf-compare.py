#!/usr/bin/env python3
"""Compares timings measured in CI with an area's baseline (docs/perf/README.md).

usage: perf-compare.py <area> <measurements.json>

The measurements file holds {"measurements": [{"metric": "...", "value": n}, ...]}. Each one is compared with the
"time" entry of the same metric in docs/perf/baselines/<area>.json; one more than its tolerance (25% by default) worse
emits a GitHub warning annotation. Timings never fail the build: hosted runners are noisy. Counts are enforced by the
VellumCore budget tests, not here. Writes a table to the job summary when GITHUB_STEP_SUMMARY is set.
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
            baseline = {e["metric"]: e for e in json.load(f)["entries"] if e.get("kind") == "time"}
    except (OSError, ValueError, KeyError):
        baseline = {}
        print(f"No timing baseline at {baseline_path}; recording only.")

    rows = ["| Metric | Measured | Baseline | Change |", "|---|---|---|---|"]
    for metric in sorted(measured):
        value = measured[metric]
        entry = baseline.get(metric)
        if entry is None:
            rows.append(f"| {metric} | {value:.2f} | – | new |")
            continue
        base = float(entry["value"])
        tolerance = float(entry.get("tolerance", 0.25))
        change = (value - base) / base if base > 0 else 0.0
        flag = ""
        if value > base * (1 + tolerance):
            flag = " ⚠️"
            print(f"::warning title=Perf regression ({area})::{metric} is {value:.2f} {entry.get('unit', '')}, "
                  f"{change:+.0%} against the baseline {base:.2f} (tolerance {tolerance:.0%}). Explain it in the PR.")
        rows.append(f"| {metric} | {value:.2f} | {base:.2f} | {change:+.0%}{flag} |")
    table = "\n".join(rows)
    print(table)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(f"### Perf timings: {area}\n\n{table}\n\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
