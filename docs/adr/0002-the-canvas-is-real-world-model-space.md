# The canvas is real-world model space, and sheets are placed at their drawing scale

Zach asked for a canvas he can "zoom way out" on, "like in AutoCAD model view", with PDFs placed "in the dimensions they would print in". We considered a canvas measured in printed inches, where every sheet sits at its paper size side by side, and chose a canvas measured in real-world lengths instead, as AutoCAD's model space is. A sheet is placed at its drawing scale, so a 1/4" = 1'-0" sheet of a 24 × 36 drawing covers 96 × 144 feet, and ink drawn over it is in the same real units as the plant it shows. Measures and dimensions read real lengths directly.

## Consequences

- Sheets at different drawing scales come out at very different sizes on one canvas. That is the model working, not a bug.
- Every sheet needs a drawing scale before it is placed. Vellum reads the SCALE from the PDF's title block and Zach confirms it. When there is none it can read (a scan, "AS NOTED", several scales on one sheet), Vellum asks him to type one, offering common scales.
- A sheet that is not to scale is an NTS sheet: placed at its printed size, its lengths shown as printed lengths marked NTS.
- Each canvas chooses its units: feet and inches, decimal feet or metric. A new canvas starts in feet and inches.
- A frame (a paper size at a drawing scale) is how a region of model space becomes one printable, sendable sheet again, as a layout viewport does in AutoCAD.
- "Print size" means a sheet prints at its paper size when it is printed at its drawing scale.
