#!/bin/sh
# Captures every tab of Vellum on a headless iPhone Duo simulator, unfolded, in light and dark, without the Simulator
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

for appearance in light dark; do
  xcrun simctl ui "$udid" appearance "$appearance"
  for tab in canvases drawings jobs meetings; do
    xcrun simctl spawn "$udid" "$tool" -position=open -duration=0.3 -wait >/dev/null
    xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$bundle" --ui-tab "$tab" >/dev/null
    sleep "${WAIT:-6}"
    file="$out/unfolded-$tab-$appearance.png"
    xcrun simctl io "$udid" screenshot --display=$display "$file"
    sips -g pixelWidth -g pixelHeight "$file" | tail -2 | tr '\n' ' '; echo
  done
done

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
