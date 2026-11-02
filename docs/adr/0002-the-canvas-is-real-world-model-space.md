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
