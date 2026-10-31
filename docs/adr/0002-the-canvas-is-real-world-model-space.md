# The canvas is real-world model space, and sheets are placed at their drawing scale

Zach asked for a canvas he can "zoom way out" on, "like in AutoCAD model view", with PDFs placed "in the dimensions they would print in". We considered a canvas measured in printed inches, where every sheet sits at its paper size side by side, and chose a canvas measured in real-world lengths instead, as AutoCAD's model space is. A sheet is placed at its drawing scale, so a 1/4" = 1'-0" sheet of a 24 × 36 drawing covers 96 × 144 feet, and ink drawn over it is in the same real units as the plant it shows. Measures and dimensions read real lengths directly.

## Consequences

- Sheets at different drawing scales come out at very different sizes on one canvas. That is the model working, not a bug.
- Every sheet needs a drawing scale before it is placed. How Vellum gets it, and what happens to a sheet that is not to scale (a loop drawing marked NTS), is its own decision.
- "Print size" means a sheet prints at its paper size when it is printed at its drawing scale.
