# Rotate a placed sheet (#44)

What is proved by the VellumCore tests and the Duo simulator captures, and what waits for hands on the real Duo. The sheets are the made-up ones in `MadeUpSheets`; nothing here is a client drawing.

## The hand test on the Duo, from a TestFlight build after merge

The feel with fingers and the Pencil can't be proved on the simulator, whose captures drive the same input paths with made-up samples. Place the IFC set's D-501 at 1/2" = 1'-0" or any sheet at hand. Unchecked until done.

Selecting:

- [ ] With the lasso in hand, tap the sheet with a finger: its edge shows in blue and the strip appears under the top bar, reading 0°. The status bar says "Twist or drag the sheet".
- [ ] Tap Done, then tap the sheet with the Pencil: it selects the same way. Tap off it with the Pencil: it lets go.
- [ ] With the pen in hand, a pinch on the sheet zooms and no finger gesture turns it.

The twist against an ordinary pinch:

- [ ] With the sheet selected and zoomed to show blank canvas beside it, put two fingers on the sheet and twist: it turns about its centre under the fingers, the view holds still, and the status bar reads the angle.
- [ ] Put one finger on the sheet and one off it, and pinch: the canvas zooms, and the sheet doesn't turn.
- [ ] Put two fingers off the sheet and pinch and pan: the canvas zooms and pans as usual.
- [ ] Put two fingers on the sheet and pinch without twisting. Say whether it feels right that this barely turns it and never zooms. Zoomed in with the sheet filling the screen, try to zoom out: this needs Done first. Say whether that gets in the way.
- [ ] Twist, then lift one finger and keep moving the other: the turn stops where it was, and nothing pans.

The 3° catch:

- [ ] Twist slowly past each of 90°, 180°, 270° and 0°: within 3° the sheet pulls onto the quarter turn, the teal guide shows, the status bar says "Caught at 90°", and the haptic marks it. At 4° off it turns freely again. Say whether 3° feels too sticky or too loose.
- [ ] Land a twist at 33° or so, and tap 90° left and 90° right: the angle reads 123° and back, one undo step a tap.

Moving, with a finger and with the Pencil:

- [ ] Drag the selected sheet with one finger: it follows, and a stroke, text box and dimension on it come along, while a stroke mostly off it stays and a frame over it stays.
- [ ] Drag it the same way with the Pencil.
- [ ] Rest a finger or the Pencil on it without dragging: nothing moves and no undo step appears.
- [ ] Undo once: the sheet and everything that came along go back together. Redo: they return.

Scale, lengths and saving:

- [ ] Change scale to another scale: the sheet takes the new size about its centre, its markups stay on the same spots of the paper, and a measure over a printed dimension reads what the new scale says.
- [ ] Measure a printed dimension at 0°, at a quarter turn and at an angle: it reads the same, and matches the page. In a scale area it reads the area's scale; on an NTS sheet, marked NTS.
- [ ] Turn a sheet, force-quit Vellum and reopen: it stands where it was, and undo still takes the turn back.
- [ ] Open a canvas placed before this build: its sheets stand at 0°.
- [ ] Turn a sheet, leave the canvas, and watch Dropbox: only log parts change, and the PDF's modified time in `sheets` doesn't.
- [ ] In dark mode, turn a dimmed sheet (a scan) and draw sketch ink on and just beside its corner: dark over the paper, light beside it.
