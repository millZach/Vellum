#!/bin/sh
# Captures the canvas screen, the Canvases list, a kill-and-reopen of a canvas being drawn, Draw with finger, and every other tab of Vellum on a headless iPhone Duo simulator, unfolded, in light and dark, without the Simulator
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

# shot <name>: screenshot the inner display as it is now.
shot() {
  file="$out/unfolded-$1-$appearance.png"
  xcrun simctl io "$udid" screenshot --display=$display "$file"
  printf '%s ' "$file"; sips -g pixelWidth -g pixelHeight "$file" | tail -2 | tr '\n' ' '; echo
}

# Saving (#9): draw the Debug-only fixture into a new canvas stroke by stroke through the canvas screen, leave one
# stroke open as if the Pencil were still down, kill the app with SIGKILL, relaunch it with no arguments, and capture
# what it reopened: everything but the open stroke.
kill_and_reopen() {
  xcrun simctl spawn "$udid" "$tool" -position=open -duration=0.3 -wait >/dev/null
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  launched=$(xcrun simctl launch "$udid" "$bundle" --ui-tab canvases --ui-reset --ui-draw-fixture)
  pid=${launched##*: }
  echo "Drawing the fixture in process $pid"
  sleep "${DRAW_WAIT:-10}"
  shot saving-before-kill
  # The simulator's apps are processes on the Mac, so this is the same SIGKILL iOS uses to kill an app.
  kill -9 "$pid"
  echo "Killed $pid with SIGKILL"
  sleep 2
  data=$(xcrun simctl get_app_container "$udid" "$bundle" data)
  echo "Canvas folders after the kill:"
  ls -lR "$data/Library/Application Support/Canvases" | sed "s|$data|<app data>|"
  xcrun simctl launch "$udid" "$bundle" >/dev/null
  sleep "${WAIT:-6}"
  shot saving-after-reopen
  # Back to the list: the canvas is listed with its stroke count and its thumbnail.
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
}

for appearance in light dark; do
  xcrun simctl ui "$udid" appearance "$appearance"
  # The canvas screen: a new empty canvas, then the Debug-only fixture (ink in all four markup colours) zoomed to
  # everything and close up on its valve. Each starts from no canvases (--ui-reset).
  capture canvas-empty --ui-tab canvases --ui-reset --ui-new-canvas
  capture canvas-everything --ui-tab canvases --ui-reset --ui-fixture
  capture canvas-closeup --ui-tab canvases --ui-reset --ui-fixture --ui-zoom closeup
  # The made-up 10,000-stroke test canvas (#21), zoomed to everything, given longer for its first render. It is
  # never saved, so it needs no reset.
  saved_wait=${WAIT:-6}; WAIT=${LARGE_WAIT:-12}
  capture canvas-large --ui-tab canvases --ui-fixture-large
  WAIT=$saved_wait
  # The Canvases list with made-up canvases and the selected one's preview, and with none.
  capture canvases-list --ui-tab canvases --ui-reset --ui-seed-list
  capture canvases-none --ui-tab canvases --ui-reset
  kill_and_reopen
  for tab in drawings jobs meetings; do
    capture "$tab" --ui-tab "$tab"
  done
done

# The Drawings tab's Dropbox states (#10). The build has no app key, so plain launches above show "isn't set up";
# these Debug-only launch arguments use a made-up key: signed out (Connect Dropbox), signed in to made-up folders, and
# the Settings sheet with Sign Out.
for appearance in light dark; do
  xcrun simctl ui "$udid" appearance "$appearance"
  for state in connect folders settings; do
    case "$state" in
      settings) set -- --ui-dropbox folders --ui-settings ;;
      *) set -- --ui-dropbox "$state" ;;
    esac
    xcrun simctl spawn "$udid" "$tool" -position=open -duration=0.3 -wait >/dev/null
    xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$bundle" --ui-tab drawings "$@" >/dev/null
    sleep "${WAIT:-6}"
    file="$out/unfolded-drawings-dropbox-$state-$appearance.png"
    xcrun simctl io "$udid" screenshot --display=$display "$file"
    sips -g pixelWidth -g pixelHeight "$file" | tail -2 | tr '\n' ' '; echo
  done
done

# Draw with finger (#24), in light and dark. The Debug-only `--ui-draw-with-finger` turns the switch on for that
# launch only (a registered default, never saved). The Settings sheet with the switch on, and a new canvas where the
# Debug-only `--ui-finger-stroke` drives the canvas view's finger path, since the simulator cannot touch the glass: a
# finger cancelled by a second one 50 ms in, which leaves no ink, then a wave drawn with one finger, which is kept.
for appearance in light dark; do
  xcrun simctl ui "$udid" appearance "$appearance"
  capture settings-draw-with-finger --ui-tab drawings --ui-settings --ui-draw-with-finger
  capture canvas-finger-stroke --ui-tab canvases --ui-reset --ui-new-canvas --ui-finger-stroke --ui-draw-with-finger
done

# Settings from the canvas (#28): the gear at the end of the top bar opens the same Settings sheet as the Drawings tab's
# gear. The Debug-only `--ui-canvas-settings` opens the canvas with the sheet up.
for appearance in light dark; do
  xcrun simctl ui "$udid" appearance "$appearance"
  capture canvas-settings --ui-tab canvases --ui-reset --ui-new-canvas --ui-canvas-settings
done

# Frame timing on the 10,000-stroke canvas (#21): the benchmark pans, pinches, draws and erases through the canvas
# view's input paths and writes benchmark.txt and benchmark.json to the app's Documents folder. Simulator numbers are
# indicative. benchmark <suffix>: runs the installed app's benchmark and keeps benchmark<suffix>.txt and .json.
benchmark() {
  xcrun simctl ui "$udid" appearance light
  xcrun simctl spawn "$udid" "$tool" -position=open -duration=0.3 -wait >/dev/null
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  data=$(xcrun simctl get_app_container "$udid" "$bundle" data)
  rm -f "$data/Documents/benchmark.txt" "$data/Documents/benchmark.json"
  xcrun simctl launch "$udid" "$bundle" --ui-tab canvases --ui-fixture-large --ui-benchmark >/dev/null
  waited=0
  while [ "$waited" -lt 240 ] && ! grep -q '^done' "$data/Documents/benchmark.txt" 2>/dev/null; do
    sleep 5; waited=$((waited + 5))
  done
  cp "$data/Documents/benchmark.txt" "$out/benchmark$1.txt" 2>/dev/null || echo "The benchmark wrote no results" > "$out/benchmark$1.txt"
  cp "$data/Documents/benchmark.json" "$out/benchmark$1.json" 2>/dev/null || true
  echo "Benchmark$1 (simulator, indicative only):"
  cat "$out/benchmark$1.txt"
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
}
benchmark ""

# The Home Screen, to show the installed app icon. Vellum has to be on the first page: if SpringBoard put it on a later
# page, it swaps places with the first page's first app in SpringBoard's saved layout while the simulator is shut down.
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
xcrun simctl shutdown "$udid"
layout="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/SpringBoard/IconState.plist"
if [ -f "$layout" ]; then
  pages=$(plutil -extract iconLists raw -o - "$layout")
  page=0; found=""
  while [ "$page" -lt "$pages" ] && [ -z "$found" ]; do
    count=$(plutil -extract "iconLists.$page" raw -o - "$layout")
    item=0
    while [ "$item" -lt "$count" ]; do
      if [ "$(plutil -extract "iconLists.$page.$item" raw -o - "$layout" 2>/dev/null)" = "$bundle" ]; then
        found="$page.$item"; break
      fi
      item=$((item + 1))
    done
    page=$((page + 1))
  done
  echo "Home Screen: $pages pages; Vellum at page.slot ${found:-nowhere}"
  case "$found" in
    0.*) ;;
    "") echo "Vellum is not in SpringBoard's layout; the Home Screen captures may not show it" ;;
    *)
      first=$(plutil -extract iconLists.0.0 raw -o - "$layout")
      plutil -replace iconLists.0.0 -string "$bundle" "$layout"
      plutil -replace "iconLists.$found" -string "$first" "$layout"
      echo "Moved Vellum to page 0, slot 0 (swapped with $first)" ;;
  esac
else
  echo "No SpringBoard layout at $layout; the Home Screen captures show wherever SpringBoard put Vellum"
fi
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 || true
for appearance in light dark; do
  xcrun simctl ui "$udid" appearance "$appearance"
  xcrun simctl spawn "$udid" "$tool" -position=open -duration=0.3 -wait >/dev/null
  sleep "${WAIT:-6}"
  file="$out/unfolded-home-$appearance.png"
  xcrun simctl io "$udid" screenshot --display=$display "$file"
  sips -g pixelWidth -g pixelHeight "$file" | tail -2 | tr '\n' ' '; echo
done

# The icon images Xcode compiled into the app bundle, and what its asset catalog holds (the default, dark and tinted
# appearances live in Assets.car).
mkdir -p "$out/bundle-icons"
cp "$app"/AppIcon*.png "$out/bundle-icons/" 2>/dev/null || echo "No AppIcon PNGs at the top of the app bundle"
ls -l "$out/bundle-icons"
xcrun --sdk iphonesimulator assetutil --info "$app/Assets.car" > "$out/bundle-icons/Assets.car.json" || echo "assetutil could not read Assets.car"
grep -E "\"(Name|Appearance|RenditionName|PixelWidth)\"" "$out/bundle-icons/Assets.car.json" | head -40 || true

# The same benchmark in an optimised build: Release, with the BENCHMARK flag that compiles the benchmark and the
# --ui-fixture-large launch argument in (TestFlight builds have neither). Its metrics end in _release.
xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build-native CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) BENCHMARK' build -quiet
xcrun simctl install "$udid" .build-native/Build/Products/Release-iphonesimulator/Vellum.app
benchmark "-release"
