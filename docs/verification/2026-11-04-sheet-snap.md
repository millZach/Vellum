# Snap to a placed sheet's outline (#57, #49)

What is proved by the VellumCore tests and the Duo simulator captures, and what waits for the Pencil on the real Duo. The sheets in the tests and captures are made up (`MadeUpSheets`, and 10 × 10 sheets in `SheetSnapTests`); nothing here is a client drawing.

## Proved before merge

- **Every corner and every edge, at any angle** (`SheetSnapTests`): a tip by each of the four corners takes the corner, exactly, though it is nearer an edge; a tip by each of the four edges takes the foot on the edge, within half an ink-grid step, at 0°, 90°, 33.5° and 123.4°. The middle of an edge is no point: the foot under the tip is taken. Out of reach, and inside the sheet away from its outline, nothing catches.
- **What a snapped mark reads**: printed 2" from a snapped corner to a snapped edge point along a 1:24 scale area on a 1:48 sheet reads 4'-0" at every angle; with no area, the sheet's own 8'-0"; on an NTS sheet, or in an NTS area along the edge, 2" NTS. A hundredth of a printed inch outside a sheet or area reads outside, at 1:48, at full size and NTS.
- **Many turns and a scale change (#49)**: the same mark, kept as a dimension, through 1,000 turns to angles in tenths of a degree, a scale change to 1:50 and 1,000 more turns, reads 4'-0" in the 1:24 area and 2" NTS in an NTS area and on an NTS sheet at every one of the 2,000 steps, and its points stay on the sheet and in the area.
- **A point beats an edge**: an ink corner 0.63 printed inch from the tip wins over the sheet edge 0.15 inch from it; a perpendicular wins too; an ink end on a sheet's corner is named End.
- **Touching and overlapping sheets**: a mark on the edge two sheets share, or on either sheet's edge where they overlap, reads the topmost sheet's scale area (2'-0", not the lower sheet's 4'-0"); swapped, the other. With an NTS sheet touching, the shared edge reads NTS whichever is on top. Among edges equally near, the topmost sheet's is taken.
- **Speed**: 1,000 sheets far from the tip are never looked at; the crowded snap budget's lookups compare 2 sheets of 1,002 (`point_snap_crowded_sheets_visited_per_lookup`). The benchmark's `sheet_snap` scenario times the loupe wandering along a sheet's edge.
- **Captures**: `unfolded-sheet-snap-corner-{light,dark}.png` and `unfolded-sheet-snap-edge-{light,dark}.png` in the sheet captures job show the loupe naming "Sheet corner" by the 1/4" plan's corner and "Sheet edge" by the left edge of the AS NOTED sheet turned to 33.5°.

## The hand test on the Duo, from a TestFlight build after merge

The feel with the Pencil can't be proved on the simulator. Unchecked until done. Start from the Canvases tab, unfolded.

Setting up:

- [ ] Make a new canvas. Tap Add sheet, pick any PDF in Dropbox whose scale you know, pick a page, confirm its scale, and tap to place it. Zoom so the whole sheet shows with blank canvas round it.

Corners and edges:

- [ ] Take Measure. Put the Pencil down near the sheet's top-left corner and hold it there: the loupe shows a teal square on the corner and says "Sheet corner". Lift: the first point is the corner.
- [ ] Put the Pencil down near the middle of the sheet's left edge, a little off it, and hold: the loupe shows a short teal line along the edge with a tick across and says "Sheet edge". Move the Pencil up and down along the edge: the mark slides along it. Lift: the measure reads the length from the corner, at the sheet's scale.
- [ ] Hold the Pencil near the middle of an edge: there is no separate mark for the middle; the mark sits under the tip.
- [ ] Hold the Pencil inside the sheet, well away from its edges: the loupe shows cross hairs and no name.
- [ ] Do the same with Dimension, and with the line and shape tool's Line: both catch the same corners and edges.

A point beats an edge:

- [ ] Draw a short line with the line and shape tool ending a finger's width inside the sheet's edge. Take Measure and hold the Pencil between the line's end and the edge, nearer the edge: it takes the line's end, named End, not the edge.
- [ ] Hold the Pencil at the sheet's corner: it says "Sheet corner", never "Sheet edge".

Turned sheets and scale:

- [ ] With the lasso, tap the sheet and twist it to about 30°. Tap Done. With Measure, catch one corner and a point along the next edge: the loupe names each, and the length matches the page's printed size along that edge at the sheet's scale.
- [ ] Turn the sheet to 90° with the turn button, and measure from corner to corner along an edge: it reads the page's full width or height at its scale.
- [ ] Place a dimension from one corner to the next. Select the sheet and turn it a few times, back and forth, then change its scale and back: the dimension reads the same each time.
- [ ] On a sheet with a detail drawn at its own scale near the sheet's edge, measure along that edge inside the detail's outline: it reads the detail's scale.

Touching sheets:

- [ ] Place a second sheet so it overlaps the first. With Measure, catch the top sheet's edge where it lies over the first sheet: it says "Sheet edge", and the length reads the top sheet's scale.
- [ ] With Measure, keep the Pencil down and run it slowly round all four edges of a turned sheet: the loupe keeps up, its mark switches between "Sheet edge" and "Sheet corner" at the corners, and nothing stutters.
