# The canvas is real-world model space, and sheets are placed at their drawing scale

Zach asked for a canvas he can "zoom way out" on, "like in AutoCAD model view", with PDFs placed "in the dimensions they would print in". We considered a canvas measured in printed inches, where every sheet sits at its paper size side by side, and chose a canvas measured in real-world lengths instead, as AutoCAD's model space is. A sheet is placed at its drawing scale, so a 1/4" = 1'-0" sheet of a 24 × 36 drawing covers 96 × 144 feet, and ink drawn over it is in the same real units as the plant it shows. Measures and dimensions read real lengths directly.

## Consequences

- Sheets at different drawing scales come out at very different sizes on one canvas. That is the model working, not a bug.
- Every sheet needs a drawing scale before it is placed. Vellum reads the SCALE from the PDF's title block and Zach confirms it. When there is none it can read (a scan, "AS NOTED", several scales on one sheet), Vellum asks him to type one, offering common scales.
- A sheet that is not to scale is an NTS sheet: placed at its printed size, its lengths shown as printed lengths marked NTS.
- Each canvas chooses its units: feet and inches, decimal feet or metric. A new canvas starts in feet and inches.
- A frame (a paper size at a drawing scale) is how a region of model space becomes one printable, sendable sheet again, as a layout viewport does in AutoCAD.
- "Print size" means a sheet prints at its paper size when it is printed at its drawing scale.

## Amendment (#8): measures, dimensions and frames read the model

Zach's picks from the prototype at the tag `prototype/measure-frame` settle how lengths are read and regions framed:

- **Lengths round in the canvas units.** Feet and inches round to the nearest 1/16" (Zach picked 1/16" over 1/2", 1/4" and 1"); decimal feet and metric stay as the canvas units already set them (hundredths of a foot, millimetres). A measure or dimension with either point on an NTS sheet reads printed inches marked NTS in every canvas units (`Canvas.measure`). A dimension's length is never stored: it is read from its points whenever it is drawn, so changing the canvas units changes it.
- **A dimension is pulled off, the AutoCAD way.** Two taps, then a third point: above or below the two points reads the horizontal distance (DIMLINEAR), beside them the vertical, out at an angle or between them the straight distance (DIMALIGNED). Its points are kept on the ink grid, so it reopens exactly.
- **A frame is a dragged box.** Zach picks the paper (8.5 × 11, 11 × 17, 24 × 36 or 30 × 42); the paper is turned the way the drag is, and the frame takes the largest standard drawing scale whose paper still covers the drag (the fewest real inches to the printed inch), centred on it (`Frame.fitting`). The scales tried are full size, the architectural scales and the engineering scales on a feet canvas, and 1:1 to 1:5000 in 1-2-5 steps on a metric one. A window offers "Make a frame here", which fits a frame to it the same way.

## Amendment (#11): sheets are placed, and a sheet can hold scale areas

Zach's picks from the prototype at the tag `prototype/place-sheets` settle how a PDF page becomes a sheet:

- **One drawing scale per sheet no longer holds.** An AS NOTED sheet, or one with several scales, goes on as one sheet at its main scale (the title block's, or the first scale written under a detail), which sets its size on the canvas. Every detail written at another scale becomes a **scale area** (CONTEXT.md): Vellum outlines it, and inside it Measure and Dimension read the area's scale, as the printed length the two points span on the sheet turned into a real length, or printed inches marked NTS in an NTS area (`Canvas.measure`, `Sheet.area(at:)`). A length with either point in an NTS area or on an NTS sheet reads NTS first, as before; otherwise the first point's scale area wins, then the second's, the topmost sheet first. Ink and other sheets over a scale area are not at its real size; that is the price of keeping the sheet whole. Cutting each detail out as a sheet of its own (question 2, B) was considered and left for later.
- **Reading the scale.** Only lines of the page's text that say SCALE, NTS or NOT TO SCALE are read (`SheetReading`, in `VellumCore`), so a dimension's text is never taken for a scale. The title block's is the one nearest the bottom-right corner; the rest are details'. A detail's area is Vellum's guess from where its scale line sits, since details are titled underneath: from the line up to the next detail's title above (or the top margin) and across to halfway to the details either side (or the margins, stopping short of the title block). Vellum asks for a scale, offering the ones written on the sheet first, for AS NOTED, several scales, no scale, a scale it can't read, and a scan; it starts on the main scale where it has one, and on nothing for no scale or a scan.
- **Placing.** After the confirm step the view zooms out and a true-size outline of the sheet waits in the middle of the view; the Pencil (or a finger drawing, with Draw with finger on) moves it and lifting places it, and a finger's tap places it where it lands. Panning and pinching meanwhile keep the outline where it is on screen. Moving a placed sheet and calibrating a half-size print from a known dimension are not part of this.

## Amendment (#35): a sheet's labels are fitted, never cut

Zach's picks from the prototype at the tag `prototype/sheet-labels`. A scale area's label sits inside the area's top-left corner at full size: its name over its scale, or its scale alone if the two lines don't fit, or only the outline if the scale doesn't, so part of a scale never shows (`SheetLabelLayout`, in `VellumCore`; the app measures the text). A sheet's name sits on a small backing inside the sheet's top-left corner, moving with the sheet, so it can pass behind the top bar and no longer matches a frame's label. A sheet narrower or shorter than its name hides the name rather than clip it. Where a scale area starts in that corner, its label drops below the sheet's name inside the area, with the same fallbacks; an area's label drops below an earlier area's in the same way, so no label covers another.
