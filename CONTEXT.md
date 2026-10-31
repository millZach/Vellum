# Vellum

Vellum is Zach's drawing and markup app for the iPhone Duo, unfolded, drawn on with the Apple Pencil. These are the words the code, the docs and the agent jobs use.

## Canvas

**Canvas**:
One unbounded drawing surface measured in real-world lengths, the way AutoCAD's model space is. Everything Zach draws, writes or places on it lives at a real-world position and size.
_Avoid_: page, board, document, sheet (a sheet is a placed PDF)

**Ink**:
What the pen leaves on the canvas: lines and handwriting, kept as strokes rather than pixels.
_Avoid_: drawing (a drawing is a CAD file), sketch, annotation

**Markup colour**:
What a colour of ink means to an agent: red is something to add, green is something to delete, blue is a note. Ink in other colours is a sketch.
_Avoid_: pen colour, highlight

**Text box**:
Typed text placed on the canvas, with a position and a size.
_Avoid_: label, note

**Sheet**:
A PDF page placed on the canvas at its drawing scale, so that its contents sit at real-world size and line up with anything else drawn at the same place.
_Avoid_: PDF (the file), page, underlay

**Drawing scale**:
The ratio between a sheet's printed size and the real world, such as 1/4" = 1'-0". It is what turns a printed length into a real one.
_Avoid_: zoom, ratio

**Printed length**:
A length as it is printed on paper, such as the 3 1/2" between two marks on a sheet. A drawing scale turns it into a real length; on an NTS sheet it stays a printed length and is shown marked NTS.
_Avoid_: paper length, plotted length

**Paper size**:
The printed width and height of a sheet's PDF page or of a frame, such as 24 × 36 or 8.5 × 11.
_Avoid_: sheet size, page size

**NTS sheet**:
A sheet that is not to scale, such as a loop drawing or a schematic. It is placed at its printed size, and lengths read on it are printed lengths marked NTS, never real ones.
_Avoid_: unscaled PDF

**Frame**:
A rectangle on the canvas with a paper size and a drawing scale, such as 24 × 36 at 1/4" = 1'-0", that Zach lays work out inside. A frame prints, exports or goes to an agent as one sheet, like a layout viewport in AutoCAD.
_Avoid_: layout, viewport, page, border

**Canvas units**:
The units a canvas shows lengths in, chosen per canvas: feet and inches, decimal feet or metric.
_Avoid_: precision, format

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

**Project folder**:
The Dropbox folder of the job a sheet's PDF came from, such as a client project's folder. A job's thread runs there.
_Avoid_: workspace, repo, directory

## Agent work

**Job**:
One request Zach sends from Vellum for agent work, such as summarize or create drawing, with the canvas content it is about. A job becomes one thread in Sotto.
_Avoid_: task, request, ticket

**Job folder**:
The Dropbox folder that holds what a job sends (its sheets, frames, ink and notes) and what its thread returns.
_Avoid_: inbox, outbox, export

**Job kind**:
What a job asks for: summarize, create drawing, redline, or a free-text instruction Zach writes himself.
_Avoid_: action, mode, command

**Redline**:
A job that applies Zach's markups on a sheet to the DWG the sheet came from, in a new revision of that DWG with each change in a revision cloud. The original DWG is never changed.
_Avoid_: markup (the markup is Zach's ink), update, edit

**Template drawing**:
The DWG Zach picks for a create-drawing job whose title block, layers and drafting standards the new drawing copies.
_Avoid_: seed file, template (alone), standard

**Watcher**:
Sotto's per-computer agent, which starts and watches threads. Vellum hands it each job.
_Avoid_: dispatcher, orchestrator

## Drawings

**Drawing**:
A CAD file (DWG) in Zach's Dropbox, with any PDF plotted from it.
_Avoid_: sheet (a sheet is a placed PDF page), file, plan

**Drawing index**:
The searchable list of every drawing in Zach's Dropbox: where it is, its project, its title block fields, which PDF is its plot, and a thumbnail. Choosing a drawing from a search opens it in Vellum.
_Avoid_: catalog, database, register

**Laptop indexer**:
The tool on the laptop that keeps the drawing index up to date and plots a drawing to PDF when Vellum asks for one that has none.
_Avoid_: agent (agents run jobs), sync, service

## Meetings

**Meeting**:
A recording Vellum makes through the Duo's microphone, or a phone call recording shared into it, with the transcript and summary made from it.
_Avoid_: call (a call is recorded by the Phone app or Meeting Coach), session, note

**Canvas meeting**:
A meeting recorded on the canvas Zach is taking notes on. Its summary reads that canvas's ink and text boxes as well as the transcript, and lands on the canvas.
_Avoid_: attached recording

**Meeting summary**:
The notes made from a meeting's transcript on the laptop, the way Meeting Coach summarizes a call.
_Avoid_: minutes, recap
