#!/bin/sh
# The gates CI runs, for someone on a Mac: the VellumCore tests, then the unsigned simulator build.
# CI selects Xcode 27.2 with DEVELOPER_DIR; set it the same way locally if Xcode 27.2 is not the selected Xcode.
set -eu
cd "$(dirname "$0")/.."
swift test
sh Scripts/build-simulator.sh
