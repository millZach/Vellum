#!/usr/bin/env python3
"""Keeps the median of each timing across a benchmark's passes (docs/perf/README.md).

usage: perf-passes.py <combined.json> <pass.json>...

Each pass file holds {"measurements": [{"metric": "...", "value": n}, ...]}. The combined file has the same shape, for
perf-compare.py, and says how many passes each value came from. A pass that wrote nothing is left out. Always exits 0:
timings never fail the build.
"""
import json
import statistics
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 0
    values: dict[str, list[float]] = {}
    for path in sys.argv[2:]:
        try:
            with open(path) as f:
                for measurement in json.load(f)["measurements"]:
                    values.setdefault(measurement["metric"], []).append(float(measurement["value"]))
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f"::warning title=Perf timings::No measurements read from {path}: {error}")
    combined = {
        "passes": len(sys.argv) - 2,
        "measurements": [
            {"metric": metric, "value": round(statistics.median(values[metric]), 2), "passes": values[metric]}
            for metric in sorted(values)
        ],
    }
    with open(sys.argv[1], "w") as f:
        json.dump(combined, f, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
