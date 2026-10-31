# Vellum is a native iOS app for the iPhone Duo and the USB-C Apple Pencil

Vellum is for one device: Zach's iPhone Duo, used unfolded, drawn on with the Apple Pencil (USB-C), which the Duo supports from iOS 27.2 (October 26, 2026). We build it as a native SwiftUI app because pen latency, PDF rendering and background audio recording are the product, and a web app or a cross-platform toolkit would be fighting the platform for each of them. Forge has no Mac, so builds and tests run on GitHub's macOS runners, the way Sotto's iPhone client does, and the real device is reached through TestFlight.

## Consequences

- The USB-C Pencil has no pressure and the Duo has no hover. Line weight comes from the tool chosen, not from how hard the pen presses, and nothing in the UI depends on hover.
- The layout is designed for the unfolded inner screen at regular width. Folded, the cover screen only has to show the app readably; drawing is not designed for it.
- The Apple Pencil Pro and earlier Pencils do not work on the Duo, so nothing is built for squeeze, barrel roll or double tap beyond what the USB-C Pencil offers.
