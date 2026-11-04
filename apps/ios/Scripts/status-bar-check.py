#!/usr/bin/env python3
"""Holds the status bar's full sheet and frame count beside the longer prompts (#45).

usage: status-bar-check.py <status-bar-walk.txt>

Reads what `--ui-status-walk` wrote (Vellum/DebugStatusBar.swift): units, position, prompt, scale label, count wording.
Exits 1 if a usual feet-and-inches label at ordinary coordinates, beside one of the three prompts, showed anything but
the full count, or if the walk did not finish. Prints where the count shortened, for the PR.
"""
import sys

PROMPTS = ["Draw a line, box or circle", "Dimension: tap first point", "Tap where the sheet goes"]
# StatusBarTextTests holds that the usual zooms show just these.
USUAL_LABELS = ["0'-1\"", "0'-2\"", "0'-3\"", "0'-6\"", "1'-0\"", "2'-0\"", "5'-0\"", "10'-0\"", "20'-0\"", "50'-0\""]


def main(path):
    with open(path, encoding="utf-8") as file:
        lines = file.read().splitlines()
    if not lines or lines[-1] != "done":
        print(f"::error::The status bar walk did not finish: {len(lines)} lines in {path}")
        return 1
    rows = [line.split("\t") for line in lines[:-1]]
    shown = {tuple(row[:4]): row[4] for row in rows}

    failures = []
    for prompt in PROMPTS:
        for label in USUAL_LABELS:
            wording = shown.get(("feetAndInches", "usual", prompt, label), "missing")
            if wording != "full":
                failures.append(f'"{prompt}" at {label}: {wording}')

    for units, position, prompt, label, wording in rows:
        if wording != "full":
            print(f"{units}\t{position}\t{prompt}\t{label}\t{wording}")
    if failures:
        for failure in failures:
            print(f"::error::The full count did not hold: {failure}")
        return 1
    print(f"The full count held beside {len(PROMPTS)} prompts at {len(USUAL_LABELS)} scale labels ({len(rows)} rows walked).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
