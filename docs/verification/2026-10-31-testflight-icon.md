# TestFlight app icon verification

October 31, 2026, on `feat/testflight` (#4, PR #17). Captured by the CI job **Duo simulator captures**, [run 41252013556](https://github.com/millZach/Vellum/actions/runs/41252013556), on GitHub's hosted `xcode-27` image with Xcode 27.2, on the iPhone Duo simulator with the iOS 27.1 runtime, booted headless and unfolded the way `2026-10-31-ios-skeleton.md` describes. `apps/ios/Scripts/capture-duo.sh` installed the Debug simulator build, shut the simulator down and, because SpringBoard had put Vellum on the second Home Screen page (page.slot 1.0), swapped it with Settings in SpringBoard's saved layout (`IconState.plist`) so it sits on the first page. It booted the simulator again, unfolded it, and screenshotted the inner display in light and then dark appearance (`xcrun simctl ui appearance`). Each capture is 2853 × 2007 pixels, 951 × 669 points at 3×.

## What the captures show

`artifacts/2026-10-31-testflight-icon/`:

1. `unfolded-home-light.png`: the unfolded Home Screen with Vellum's icon, design C "Drafting V" (a white V on blue, a dimension line above it and a red point at its vertex), labelled "Vellum", next to Settings.
2. `unfolded-home-dark.png`: the same Home Screen in dark appearance. The wallpaper and the Screen Time widget turn dark, **but the icon is still the default (blue) one, not the dark variant**, and Settings keeps its light icon too. The simulator's Home Screen icon style evidently stays at Light whatever the system appearance is; the script does not change that setting, so this capture does not prove the dark icon.
3. `AppIcon60x60@2x.png` and `AppIcon76x76@2x~ipad.png`: the icon images Xcode compiled into the top of `Vellum.app`, copied out of the bundle. They are the default appearance.
4. `Assets.car.json`: `assetutil --info` on the bundle's `Assets.car`. It lists `AppIcon` at 1024 × 1024 for the phone in three renditions: `AppIcon-1024.png` (any appearance), `AppIcon-1024-dark.png` (`UIAppearanceDark`) and `AppIcon-1024-tinted.png` (`ISAppearanceTintable`). So the dark and tinted icons are compiled into the app; only showing them on the Home Screen is unproved.

## Not checked

- The dark and tinted icons on a Home Screen. On the Duo: long-press the Home Screen, Edit > Customize, and pick Dark or Tinted.
- The icon from a TestFlight install on the real Duo (the PR's last hand-test item).
- Folded, on the cover screen.
