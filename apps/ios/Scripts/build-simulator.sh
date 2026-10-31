#!/bin/sh
# Builds the Vellum app for the iOS simulator, unsigned, the way CI's "iOS simulator build" job does.
set -eu
cd "$(dirname "$0")/.."
sh Scripts/generate-project.sh
xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build-native CODE_SIGNING_ALLOWED=NO build
