# The pinch stalls over a placed sheet, and the Speed check (#42)

What CI proved, and what waits for the real Duo. Every number below comes from GitHub's hosted `xcode-27` runners, on the iPhone Duo simulator (iOS 27.1), on the made-up 10,000-stroke canvas and the made-up 1/4" plan; nothing here is a client drawing.

## Proved before merge

CAUSE_AND_NUMBERS

### The Speed check

- **The summary and the copied line** (`SpeedCheckTests`, VellumCore): frames drawn, frames missed (for each gap longer than one and a half frames, the frames it spans less the one drawn), the worst gap and gaps over 50 ms, from made-up timestamps at 120 Hz and 60 Hz, with exact numbers; the rate in whole frames a second; what ran on the main thread before a frame, its parts and "other"; and the line Copy all puts on the pasteboard, which starts with the build, the Duo's posture and the display's rate, names a sheet only as "a sheet", and ends with the worst frames.
- **What it costs**: COST
- **Captures** (Duo simulator captures job, unfolded, light and dark): `unfolded-settings-speed-check-{light,dark}.png`, Settings with the switch on and two made-up gestures listed under it with Copy all and Clear, and `unfolded-canvas-speed-check-{light,dark}.png`, the canvas with the red dot and "Speed check" in its status bar. The status bar walk ran twice, with the Speed check off and on, and the full sheet and frame count held beside the three longer prompts both times (`status-bar-walk.txt`, `status-bar-walk-speed-check.txt`).

## The hand test on the Duo, from a TestFlight build after merge

Unchecked until done. Unfolded.

- [ ] Open Settings (the gear on the canvas's top bar, or on the Drawings tab). Under Speed, turn on Speed check. The footer says Vellum times each pan and pinch and keeps only the numbers, never the drawing. Below the switch: "No gestures timed yet."
- [ ] Close Settings. Open a canvas with a placed sheet. The status bar shows a red dot and "Speed check" at the right of the prompt, and the position, the scale bar, the prompt and the sheet and frame count still read in full.
- [ ] Pinch in and out over the sheet a few times, then pan across it once. Nothing on the canvas shows numbers.
- [ ] Open Settings. The gestures are listed newest first: "Pinch over a sheet" and "Pan over a sheet", each with its time, length, frames missed (red when any) and worst gap.
- [ ] Tap Copy all, and paste into #42. Each line starts "Vellum speed check, build …, Duo unfolded, 120 Hz".
- [ ] Tap Clear: the list empties. Turn Speed check off: the list and the dot go.
- [ ] Quit Vellum from the app switcher and reopen it with Speed check on: no gestures are listed.
