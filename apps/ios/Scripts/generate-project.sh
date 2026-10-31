#!/bin/sh
# Generates Vellum.xcodeproj from project.yml with a pinned XcodeGen, downloaded once into .tools/ and checked
# against its published SHA-256 before it runs.
set -eu
cd "$(dirname "$0")/.."
XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
tool=".tools/xcodegen-$XCODEGEN_VERSION/xcodegen/bin/xcodegen"
if [ ! -x "$tool" ]; then
  rm -rf ".tools/xcodegen-$XCODEGEN_VERSION"
  mkdir -p ".tools/xcodegen-$XCODEGEN_VERSION"
  zip=".tools/xcodegen-$XCODEGEN_VERSION.zip"
  curl -fsSL -o "$zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
  echo "$XCODEGEN_SHA256  $zip" | shasum -a 256 -c -
  unzip -q "$zip" -d ".tools/xcodegen-$XCODEGEN_VERSION"
  rm "$zip"
fi
"$tool" generate --spec project.yml
