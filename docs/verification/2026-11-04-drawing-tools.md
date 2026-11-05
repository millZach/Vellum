# Exact drawing, more snap points and more shapes (#40)

What is proved by the VellumCore tests and the Duo simulator captures, and what waits for hands on the real Duo. The drawings here are all made up for the test; nothing is a client drawing.

The prototype is a browser mock-up, so the feel with the Pencil is still unproven. These are the checks only the Pencil can make.

## The Pencil test on the Duo, from a TestFlight build after merge

Use a new canvas, unfolded, in feet and inches.

The catch at 4°:

- [ ] Pick Line from the flyout. Draw lines a little off level, off plumb and off 45°: within about 4° the line pulls on, and the teal guide shows through the first point. Say whether 4° feels too wide or too narrow with the Pencil.
- [ ] Try to hold a line at about 88° by hand: it can't be held there, and the tag's pad types it. Say whether that gets in the way of sketching.
- [ ] Draw a line ending on a snap point within 4° of level: the snap point wins, with no guide.

The snap radius with every kind on:

- [ ] Draw a rectangle, a circle and two lines crossing, then use Line over them. Say whether 20 points still feels right now that mids, intersections, perpendiculars and tangents are on, and whether the nearest point is the one wanted most of the time.
- [ ] The loupe names each: End, Corner, Centre, Mid, Intersection, and from a first point, Perpendicular and Tangent. Say whether the name can be read with a hand over the glass.
- [ ] Measure and Dimension take the same points, with perpendicular and tangent on the second only.
- [ ] Near the top bar and the rail, the loupe moves aside and is never under them.
- [ ] Hold the Pencil still near several points: nothing changes. Say whether you wanted a way to get the second-nearest, or whether zooming in is enough.

Reaching the tag:

- [ ] Draw each shape. Tap its tag with the Pencil and with a finger: the pad opens beside the shape, clear of the chrome. Say whether the tag is big enough to reach with the Pencil, and whether reaching for it ever starts a stroke by mistake.
- [ ] Tap between the pad's keys with the Pencil: nothing is drawn.
- [ ] Type `12'6`, then 30 in the angle, and Enter: a measure along the line reads 12'-6". A bare `12` is 12 inches. `6-1/2` is 6 1/2 inches, and `61/2` is refused, with the field marked.
- [ ] Pan and pinch with the tag up: it follows the shape and stays. Touch the canvas with the Pencil: it goes.

The shapes:

- [ ] Draw it: draw by hand as before: it straightens on lift, then shows a tag. The pen's hold-to-snap works as it did, with no tag.
- [ ] Line, Rectangle, Circle and Polygon, each by a drag and by two taps. A polygon has 6 sides until 8 is typed.
- [ ] Arc: tap the start, the end, then the bulge. Correct its radius: its ends stay put.
- [ ] Polyline: tap each bend, then finish once each way: Done, tapping the last point again, and closing on the first. The tag shows the last segment. Correct it part way through and go on drawing.
- [ ] Undo with a polyline part way through: it takes the last bend back, and after a correction it puts the size back first. With Draw with finger on, rest a finger, then use the Pencil: the Pencil takes over and nothing lands under the finger.

Ink and saving:

- [ ] Correct a shape, undo: the shape as drawn comes back. Undo again: it goes. Redo twice: the correction returns.
- [ ] Correct a shape, force-quit Vellum and reopen: it stands as corrected, and undo still takes the correction back.
- [ ] Leave a polyline part way through and switch to Measure, the lasso and the highlighter, or leave the canvas: it is kept as ink, a pen stroke in its first colour and width, one undo step. Change colour part way: it stays in its first. Force-quit part way through: at most that polyline is lost, with any correction made to it, as a stroke still being drawn is.
- [ ] Correct a shape, leave the canvas, and watch Dropbox: only a new log part appears.

The flyout:

- [ ] With line and shape in hand, tap it: the flyout opens beside the rail with line weight at its foot. The rail button shows the shape picked. Change the weight: the next shape draws at it. The pen's second tap still opens its own picker.
- [ ] In dark mode, each of these reads clearly.

Speed:

- [ ] On the 10,000-stroke test canvas, hold Line's second point and wander: it follows with no hitch. Say if it feels any slower than Measure's loupe.

## What the simulator and the tests prove

- `ExactDrawingTests`, `PointSnapKindsTests` and `CanvasToolPromptTests` in VellumCore prove the numbers: every form the pad accepts, every length shown down to 1/16" read back exactly, the catch either side of 4° at every multiple of 45°, each shape and correction, each snap kind, where the tag, pad and loupe go, and the correction through the log, the snapshot and a relaunch. `SyncTests` proves it reaches Dropbox as the log's tail.
- `capture-duo.sh` captures `unfolded-drawing-*` in light and dark, on a made-up scene: the flyout, the tag, the pad, the tag after Enter, the guide, the loupe naming each new kind, each shape, the tag, pad and loupe clear of the chrome, and the longest prompt.
