#!/bin/sh
# Prints the next TestFlight build number (CFBundleVersion): the UTC date and time of the upload, as
# <yyyymmdd>.<hhmmss> with the time's leading zeros dropped, for example 20261031.230512 or 20261101.5 (00:00:05).
# App Store Connect takes up to three period-separated integers and compares them as numbers, so a later upload always
# has a larger build number, even when an old run is retried after a newer one has uploaded; the run number would not.
# Uploads are one at a time (the workflow's concurrency group), so two never share a second.
set -eu
set -- $(date -u '+%Y%m%d %H%M%S')
time=$(printf '%s' "$2" | sed 's/^0*//')
printf '%s.%s\n' "$1" "${time:-0}"
