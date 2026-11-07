# A Select tool that picks up any object with a tap (#64)

What CI proved, and what waits for the real Duo. Every number below comes from GitHub's hosted `xcode-27` runners, on the iPhone Duo simulator (iOS 27.1), on made-up canvases, the made-up 10,000-stroke canvas and the made-up D-501 detail sheet; nothing here is a client drawing.

## Proved before merge

### The tap test (`SelectTap`, VellumCore)

`SelectTapTests`, with exact numbers at one screen point to the canvas inch (the 10-point reach is 10 inches there):

- **Ink over a sheet** picks the ink; the same sheet's bare paper picks the sheet; empty canvas picks nothing.
- **Overlapping sheets** pick the one placed last where they overlap, the one under where it shows, and with the lower one selected a tap on the upper one's paper picks the upper one (fixed after review); a sheet turned a quarter is picked where its paper now stands.
- **A thin stroke** (1/4 inch wide) is picked at 10 1/8 inches from its line, the reach plus half its ink, and not at 10 1/4; four times closer at 2 5/8 and not 2 3/4; a thousand times further out at 10,000 inches. Of two strokes in reach, the later is on top.
- **A text box** is picked anywhere on it and 4 points round it, over the ink running through it; the ink past that is picked.
- **A dimension** is picked by its line, out to the reach (10 inches, and not 10 1/4), and by its length's box, 19 inches off its line; the points it measures are not the dimension.
- **A frame** is picked within the reach of its dashed edge, inside or out (10 inches out, not 10 1/4), and never in the middle of what it takes in, so the ink inside it can be tapped.
- **Tap to add**: a tap on another thing adds it, a tap on what is selected leaves the selection as it was, and a tap on empty canvas lets go of everything. A sheet is selected alone: a tap on one lets go of the ink, a tap on ink lets go of the sheet. Inside the selection's dashed box a tap is a tap like any other (fixed after review): on the blank between two selected strokes it lets go, on a sheet's bare paper it picks the sheet, on a selected stroke it keeps the selection, on another it adds it. A drag from inside the box still moves the selection.
- **The tool**: Select sits in the lasso's group as Select, lasso, text box; its prompts are "Tap anything to select it", then "Drag the selection" or "Twist or drag the sheet", and after a drag on empty canvas "Loop several with the Lasso" or "Tap the sheet, then drag it", each 28 characters or fewer.

### Speed

- **A tap looks only near itself.** `CanvasRenderingBudgetTests.testASelectTapLooksOnlyAtStrokesNearIt` taps a 10 by 10 grid over the made-up 10,000-stroke canvas at everything and again four times closer, 200 taps, 139 of them on ink. Each pick is the one a plain scan of every stroke, topmost first, finds. The worst tap compared 212 strokes' cached bounds and read 2,011 stroke points (run 42313174862); a plain scan compares 10,000 and reads 794,528. Both are budgets now, `select_tap_strokes_visited` 212 and `select_tap_points_inspected` 2,011 in `docs/perf/baselines/canvas-rendering.json`, so a change that walks every stroke fails CI. Sheets are found through the sheet index the same way (`SheetIndex.sheet(at:)`). The text boxes, dimensions and frames are read in full, as the lasso reads them; a canvas holds them by the dozen.
- **Once a tap, nothing per Pencil sample.** The tap test runs once, when the Pencil or a finger touches down with Select (or when a finger's tap is recognised). While the tip moves, a press costs one distance check a batch of samples until it becomes a drag, and the drag is the lasso's own: the same lifted layer and one transform a frame. Nothing is drawn or lifted for a tap.
- **The benchmark is unchanged in what it runs.** It has no Select scenario; the pen, pan, pinch and drag scenarios run through the same code as before, which gained one comparison of the tool in hand at touch-down. The PR gives the final run's timings against main's merge run for 06c50cd.

### Captures

CAPTURES

## The hand test on the Duo, from a TestFlight build after merge

Unchecked until done. Unfolded, with the Apple Pencil, on a canvas with a placed sheet and some markups on it and beside it.

- [ ] The rail shows Select (the arrow) above the Lasso. Take Select: the status bar says "Tap anything to select it".
- [ ] Tap a stroke: it is selected with the dashed box and corner handles, and the status bar says "Drag the selection".
- [ ] Tap a text box: it is added, and the box grows round both. Tap a dimension, by its length and then by its line far from it: added. Tap a frame's dashed edge: added. The menu counts four.
- [ ] Tap the stroke again: nothing changes. Tap the blank inside the dashed box, between the things selected: everything is let go. Select them again and tap empty canvas: everything is let go.
- [ ] Tap ink lying on the sheet: the ink is picked, not the sheet. Tap the sheet's bare paper: the sheet's edge turns the accent and its strip shows under the top bar; the ink is let go.
- [ ] Where a second sheet lies over the selected one, tap the second sheet's bare paper: the second sheet is picked. Tap the first sheet's own paper again. With it selected, press 90° left, then drag the sheet with the Pencil, and twist it with two fingers: it turns and moves as it does after a Lasso tap, its markups with it. Press Done.
- [ ] Press on a stroke not selected and drag straight away: it moves at once. Drag a corner handle of a selection: it resizes. Duplicate and Delete from the menu.
- [ ] Drag from empty canvas with Select: nothing happens, and the status bar says "Loop several with the Lasso". From the bare paper of a sheet not selected: "Tap the sheet, then drag it".
- [ ] Undo after each move, turn, resize, duplicate and delete: each is one step, and the selection stays.
- [ ] Take the Lasso: the selection stays. Loop round some ink, and tap a sheet with the Lasso: both work as before. Take the pen: the selection goes.
- [ ] Turn on Draw with finger, take Select, and tap a stroke with a finger: picked, as with the Pencil. Turn it off: a finger's tap still picks it, and a finger's drag pans.
