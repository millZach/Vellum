# Vellum

Vellum is Zach's drawing and markup app for the iPhone Duo, unfolded, drawn on with the Apple Pencil. These are the words the code, the docs and the agent jobs use.

## Canvas

**Canvas**:
One unbounded drawing surface measured in real-world lengths, the way AutoCAD's model space is. Everything Zach draws, writes or places on it lives at a real-world position and size.
_Avoid_: page, board, document, sheet (a sheet is a placed PDF)

**Ink**:
What the pen leaves on the canvas: lines and handwriting, kept as strokes rather than pixels.
_Avoid_: drawing (a drawing is a CAD file), sketch, annotation

**Text box**:
Typed text placed on the canvas, with a position and a size.
_Avoid_: label, note

**Sheet**:
A PDF page placed on the canvas at its drawing scale, so that its contents sit at real-world size and line up with anything else drawn at the same place.
_Avoid_: PDF (the file), page, underlay

**Drawing scale**:
The ratio between a sheet's printed size and the real world, such as 1/4" = 1'-0". It is what turns a printed length into a real one.
_Avoid_: zoom, ratio

**Measure**:
A length read off the canvas between two points, in real-world units, that is not kept.
_Avoid_: dimension (a dimension stays on the canvas)

**Dimension**:
A kept annotation on the canvas that shows a real-world length between two points, like AutoCAD's linear dimension.
_Avoid_: measurement, measure

**Window**:
A rectangle dragged on the canvas to choose a region: to zoom to it, or to choose what is exported or sent.
_Avoid_: selection box, lasso

## Places

**Duo**:
Zach's iPhone Duo, the one device Vellum runs on. Unfolded, it is a 951 × 669 point landscape screen.

**Laptop**:
Zach's Windows laptop, where AutoCAD, Dropbox and Sotto run, and where agent work happens.
_Avoid_: PC, desktop, computer (in Sotto, a computer is any machine with a host)
