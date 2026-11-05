# The pinch stalls over a placed sheet, and the Speed check (#42)

What CI proved, and what waits for the real Duo. Every number below comes from GitHub's hosted `xcode-27` runners, on the iPhone Duo simulator (iOS 27.1), on the made-up 10,000-stroke canvas and the made-up 1/4" plan; nothing here is a client drawing.

## Proved before merge

### What holds the main thread in the stalled frames: the runner, not Vellum

The benchmark now counts what the main thread does between frames (`MainThreadLedger`, `docs/perf/README.md`): how long it was awake, its own CPU time, and how much went to each part Vellum can name (sheet tiles landing, the sheet plan, ink tiles landing and starting, the ink plan, the view moving its layers, Core Animation's commit). For every frame after a long gap it logs what ran before it.

- **Across every scenario** of the Release job's three launches on 2dd47df (run 42090600428): 302 long gaps. Before them the main thread was awake for 8,578 ms but ran on a core for only 1,301 ms of it, and Vellum's named work came to 46.1 ms in all. No gap had more than 16.7 ms (one frame at the runner's 60 Hz) of main-thread CPU before it, and none had CPU time over half its gap. The 70 gaps over 50 ms had 1.8 to 13.5 ms of main-thread CPU before them.
- **The pinch over a placed sheet** (`sheet_pinch`), three launches: 3, 2 and 0 long gaps (5 in all), the worst 37.6 ms. Before them the main thread was awake 14.5 to 22.5 ms and ran 3.5 to 8.9 ms; Vellum's named work was 0.3 to 4.0 ms. Each launch lands 330 sheet tiles on the main thread in 55 to 74 ms in all, the most in one frame 4.4 to 9.7 ms, and none of those frames came before a gap.
- **Push 1** (079c6bf, run 42083548261, the ledger without the CPU clock) said the same from the other side: 319 long gaps over three launches, Vellum's named work 58.6 ms in all before them and at most 7.7 ms before any one, 191 of them with the main thread idle for more than a frame of the gap.
- **The same gaps fall in scenarios with no sheet**: drawing (`draw`, `sheet_draw`), the loupe, the shape tool, dragging a selection; and at random frames on each launch. Main's merge run for 6612aaa (run 42072450040) had 225 long gaps over its three launches, this branch 319 and 302.

So in a stalled frame the main thread is waiting, not working: awake but off a core, or blocked in the system, on a shared hosted runner whose simulator shares the machine with the render server and everything else. Nothing in Vellum was changed to fix it, and no budget was raised.

**Against main's merge run for 6612aaa** (run 42072450040), Release, three launches each, the median of the three as `perf-compare.py` keeps it:

| | main 6612aaa | this branch 2dd47df |
|---|---|---|
| `sheet_pinch` long gaps per launch | 0, 0, 0 | 3, 2, 0 |
| `sheet_pinch` worst gap | 16.67 ms | 37.57 ms |
| `sheet_pinch` p50 / p95 / max frame work | 2.70 / 6.28 / 17.67 ms | 3.01 / 6.17 / 15.57 ms |
| `pinch` long gaps per launch | 0, 0, 1 | 0, 0, 0 |
| `pinch` p50 / p95 / max frame work | 3.23 / 6.27 / 12.72 ms | 2.72 / 5.53 / 9.79 ms |
| long gaps, all scenarios | 225 | 302 |
| speed probe | 2.30 ms (1.24x the reference runner) | 2.22 ms (1.20x) |

The frame work is the same within the runners' noise. The long gaps move from run to run and scenario to scenario with no Vellum work before them; 0 against 5 in the sheet pinch is the same random stall #42 found, not something this branch added (the ledger costs under 2 µs a frame, below).

Still open: whether the pinch stalls on the real Duo at all. The Speed check below is how that is measured.

### The Speed check

- **The summary and the copied line** (`SpeedCheckTests`, VellumCore): frames drawn, frames missed (for each gap longer than one and a half frames, the frames it spans less the one drawn), the worst gap and gaps over 50 ms, from made-up timestamps at 120 Hz and 60 Hz, with exact numbers; the rate in whole frames a second; what ran on the main thread before a frame, its parts and "other"; and the line Copy all puts on the pasteboard, which starts with the build, the Duo's posture and the display's rate, names a sheet only as "a sheet", and ends with the worst frames.
- **What it costs**: the benchmark runs a gesture's per-frame bookkeeping, three parts timed and the three run loop observers' work 20,000 times on the main thread at the end of each launch: 1.60, 1.86 and 1.67 µs a frame on run 42090600428 (1.14, 1.01 and 1.53 µs on push 1, before the CPU clock). That is about 0.02% of a frame at 120 Hz. Nothing runs per Pencil sample. With the switch off no display link of its own runs (it reads the canvas's own, which runs only while a finger or the Pencil is down) and each hook is one branch on `MainThreadLedger.isOn`.
- **Captures** (Duo simulator captures job, unfolded, light and dark): `unfolded-settings-speed-check-{light,dark}.png`, Settings with the switch on and two made-up gestures listed under it with Copy all and Clear, and `unfolded-canvas-speed-check-{light,dark}.png`, the canvas with the Speed check's mark in its status bar.
- **The status bar keeps its room**: the status bar walk runs twice, with the Speed check off and on (`status-bar-walk.txt`, `status-bar-walk-speed-check.txt`), and the full sheet and frame count must hold beside the three longer prompts at every usual scale label both times. On 2dd47df the mark was laid out beside the prompt; its 16 points (an 8-point dot and its gap) shortened the count beside all three prompts at all ten labels, and the job failed. The mark is now drawn over the bar and takes no room: "Speed check" with a dot at the right of the room the prompt leaves when it fits there, and otherwise a small red dot in the gap before the count.

## The hand test on the Duo, from a TestFlight build after merge

Unchecked until done. Unfolded.

- [ ] Open Settings (the gear on the canvas's top bar, or on the Drawings tab). Under Speed, turn on Speed check. The footer says Vellum times each pan and pinch and keeps only the numbers, never the drawing. Below the switch: "No gestures timed yet."
- [ ] Close Settings. Open a canvas with a placed sheet. The status bar shows a red dot: with "Speed check" beside it at the right of the prompt where there is room, or alone just before the sheet and frame count where there is not. The position, the scale bar, the prompt and the count still read in full.
- [ ] Pinch in and out over the sheet a few times, then pan across it once. Nothing on the canvas shows numbers.
- [ ] Open Settings. The gestures are listed newest first: "Pinch over a sheet" and "Pan over a sheet", each with its time, length, frames missed (red when any) and worst gap.
- [ ] Tap Copy all, and paste into #42. Each line starts "Vellum speed check, build …, Duo unfolded, 120 Hz".
- [ ] Tap Clear: the list empties. Turn Speed check off: the list and the dot go.
- [ ] Quit Vellum from the app switcher and reopen it with Speed check on: no gestures are listed.
