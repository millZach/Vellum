#!/bin/sh
# Captures the canvas screen and every other tab of Vellum on a headless iPhone Duo simulator, unfolded, in light and dark, without the Simulator
# app. The fold is moved by Scripts/duo/posture.m, a simulator-side tool that calls SpringBoard's display tool service,
# the way Sotto captured its Duo layouts (Sotto tag prototype/iphone-duo-layout).
# usage: capture-duo.sh [output folder]   (default .build-captures)
set -eu
cd "$(dirname "$0")/.."
out=${1:-.build-captures}
mkdir -p "$out"
bundle=com.millzach.vellum

sh Scripts/build-simulator.sh
app=.build-native/Build/Products/Debug-iphonesimulator/Vellum.app

udid=$(xcrun simctl list devices available | grep 'iPhone Duo (' | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$udid" ]; then echo "No iPhone Duo simulator available" >&2; exit 1; fi
echo "iPhone Duo simulator: $udid"
xcrun simctl list devices available | grep -B20 "$udid" | grep -E '^-- ' | tail -1

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$udid" "$app"

tool=Scripts/duo/.build/posture
if [ ! -x "$tool" ]; then
  mkdir -p Scripts/duo/.build
  # The simulator reads the tool's entitlements from this section; an ad-hoc signature is enough.
  xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc -framework Foundation \
    Scripts/duo/posture.m -o "$tool" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker Scripts/duo/posture-entitlements.plist
  codesign -f -s - "$tool"
fi

echo "Unfolding:"
xcrun simctl spawn "$udid" "$tool" -position=open -duration=0.3 -wait
sleep 2
# The unfolded inner screen is display 3; the cover screen, folded, is display 1.
display=3

# capture <name> <launch arguments...>: relaunch the app unfolded and screenshot the inner display.
capture() {
  name=$1; shift
  xcrun simctl spawn "$udid" "$tool" -position=open -duration=0.3 -wait >/dev/null
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
  sleep "${WAIT:-6}"
  file="$out/unfolded-$name-$appearance.png"
  xcrun simctl io "$udid" screenshot --display=$display "$file"
  printf '%s ' "$file"; sips -g pixelWidth -g pixelHeight "$file" | tail -2 | tr '\n' ' '; echo
}

for appearance in light dark; do
  xcrun simctl ui "$udid" appearance "$appearance"
  # The canvas screen: a new empty canvas, then the Debug-only fixture (ink in all four markup colours) zoomed to
  # everything and close up on its valve.
  capture canvas-empty --ui-tab canvases
  capture canvas-everything --ui-tab canvases --ui-fixture
  capture canvas-closeup --ui-tab canvases --ui-fixture --ui-zoom closeup
  for tab in drawings jobs meetings; do
    capture "$tab" --ui-tab "$tab"
  done
done
