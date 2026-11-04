# Vellum

Vellum is Zach's drawing and markup app for the iPhone Duo, unfolded, drawn on with the Apple Pencil. These are the words the code, the docs and the agent jobs use.

## Canvas

**Canvas**:
One unbounded drawing surface measured in real-world lengths, the way AutoCAD's model space is. Everything Zach draws, writes or places on it lives at a real-world position and size.
_Avoid_: page, board, document, sheet (a sheet is a placed PDF)

**Ink**:
What the pen leaves on the canvas: lines and handwriting, kept as strokes rather than pixels.
_Avoid_: drawing (a drawing is a CAD file), sketch, annotation

**Stroke**:
One continuous line of ink, from where the pen touched down to where it lifted: its points in real-world lengths, its markup colour, the pen it came from (pen or highlighter) and its width. The eraser takes a stroke away whole.
_Avoid_: line (a line is the line tool's), path, mark

**Line weight**:
How heavy a pen draws, chosen on the pen (fine, medium or bold, in the weight picker for the pen and highlighter and at the foot of the shape flyout for line and shape), never from how hard the Pencil presses. A stroke keeps the weight it was drawn at as a real-world width, so it zooms with what it marks.
_Avoid_: thickness, pressure, size

**Snap**:
A stroke straightened into a line, a rectangle or a circle (or an ellipse): the pen snaps one when the Pencil holds still at its end for half a second, and the line and shape tool's Draw it snaps every stroke when it lifts. A snapped stroke is ink like any other, with the shape's points.
_Avoid_: shape recognition, auto-shape, perfect shape

**Shape flyout**:
The panel beside the rail that opens when line and shape is tapped while in hand: Draw it, Line, Polyline, Rectangle, Circle, Arc and Polygon, with the line weight at its foot. The rail button shows the shape picked. Draw it draws by hand and straightens on lift. Line, Rectangle, Circle and Polygon take a drag or two taps, Polyline a tap per bend, finished with Done, by tapping the last point again or by closing on the first, and Arc its start, its end, then the bulge. Every shape becomes a stroke's points; Vellum stores no separate geometry.
_Avoid_: shape picker, palette, toolbar

**Angle catch**:
A line, a polyline's segment or a polygon's first corner within 4° of 0°, 45° or 90° or their multiples pulling onto that angle, with a guide showing. There is no lock button; other angles close to those are typed. Angles read counter-clockwise from east, as in AutoCAD. A snap point beats it.
_Avoid_: ortho, polar tracking, angle lock

**Tag**:
The small label that shows a shape's size just after it is drawn: length and angle for a line or a polyline's last segment, W × H for a rectangle, ⌀ and diameter for a circle, sides × side length for a polygon, R and radius for an arc. Tapping it opens the number pad. It goes away when the next thing starts, because ink keeps no shape to come back to.
_Avoid_: label, chip, badge, dimension (a dimension stays on the canvas)

**Number pad**:
The small pad a tag opens, which corrects a shape to typed values as its own undo step. A bare number means inches on a feet-and-inches canvas, like AutoCAD (`12` is 12 inches, `12'` is 12 feet, `12'6` is 12'-6"), and the canvas's own unit on any other: feet in decimal feet, millimetres in metric. What it can't read stays on the pad, marked, and changes nothing.
_Avoid_: keypad, keyboard, command line

**Lasso**:
The tool that selects by drawing a loop: it takes every stroke at least half inside the loop, every text box whose centre is inside, every dimension whose text is inside, and every frame wholly inside. A tap with it picks up the topmost sheet under the tap instead; a loop never takes a sheet.
_Avoid_: marquee, selection tool, window (a window is a dragged rectangle)

**Selection**:
The strokes, text boxes, dimensions and frames the lasso has taken, shown with a dashed box and corner handles, which can be moved, resized from a corner, duplicated or deleted, each as one undo step; or the one sheet a tap took, shown with its edge in the accent and a strip under the top bar, which can be turned, moved or changed in scale. It is not saved, and it stays selected through undo and redo.
_Avoid_: group, highlight

**Draw with finger**:
The switch in Settings, off by default and kept on the Duo, that lets one finger draw, erase or use the selected tool as the Pencil does, with two fingers left to pan and pinch. A finger stroke is ink only once it is clearly one finger: a second finger landing within 130 ms of the first cancels it and becomes a pan or pinch, with nothing saved.
_Avoid_: finger mode, touch drawing, palm rejection (the Pencil needs none of this)

**Markup colour**:
What a colour of ink means to an agent: red is something to add, green is something to delete, blue is a note. Ink in other colours is a sketch.
_Avoid_: pen colour, highlight

**Ink log**:
The record on the Duo of every change to a canvas's ink, text boxes, dimensions, frames and sheets since its last snapshot (a stroke drawn, a shape corrected through its tag, strokes erased, a selection moved, resized, duplicated or deleted, a text box placed or edited, a dimension, frame or sheet placed, a sheet turned, moved or changed in scale, an undo, a redo), each written as it happens, so a crash loses at most the stroke still being drawn (ADR-0014).
_Avoid_: journal, history file, autosave

**Canvas saver**:
The one owner of a canvas's files while anything is being written to them (`CanvasSaver`). Opening, closing, reopening and deleting the canvas all go through it, and it outlives the canvas screen until every change it was handed is on the Duo (ADR-0014).
_Avoid_: writer, persistence manager, autosaver

**Canvas folder**:
The folder on the Duo that holds one canvas: its name and canvas units (`canvas.json`), its ink snapshot and its ink log (which hold its text boxes, dimensions, frames and sheets too), and a `sheets` folder with the PDFs its sheets show, one per PDF, and nothing else, so #12 can mirror it to Dropbox as it is.
_Avoid_: document, package, bundle

**Canvas's Dropbox folder**:
The folder in `Dropbox/Vellum` a canvas folder is mirrored to, named `<name> <short id>` (such as "Boiler 4 walkdown 7f3a") when the canvas is made and never renamed, so the laptop's paths stay put. Its log is kept in log parts.
_Avoid_: remote copy, cloud copy, backup

**Folder check**:
One request asking Dropbox whether any canvas's Dropbox folder is missing a file the sync ledger says it holds (deleted on the laptop), made by the first sync with something to upload after the app starts, comes back to the foreground or gets its connection back. A canvas it finds incomplete is uploaded whole once (ADR-0003).
_Avoid_: scan, poll, health check

**Log part**:
One upload of an ink log's new records, named by the log's generation and the byte offset it starts at; a generation's parts joined in order are the Duo's ink log (ADR-0014).
_Avoid_: chunk, segment, delta file

**Sync**:
Mirroring a canvas folder to its Dropbox folder, uploading only what changed, when Zach leaves the canvas or the app goes to the background; never while he draws. Deleting a canvas moves its Dropbox folder to `Vellum/.deleted` (ADR-0003).
_Avoid_: backup, upload (one request), save (saving is on the Duo)

**Sync outbox**:
The uploads and deletes still to do in Dropbox, kept on the Duo with the sync ledger so they survive a crash or a relaunch, and sent when a connection returns (ADR-0010).
_Avoid_: queue, upload queue, outbox (alone; a job folder is not an outbox)

**Text box**:
Typed text placed on the canvas, with a position and a size, its letters a real-world height so it zooms with the ink, and a markup colour. It is typed with the keyboard or written with the Pencil, which turns the handwriting into its text.
_Avoid_: label, note

**Sheet**:
A PDF page placed on the canvas at its drawing scale, so that its contents sit at real-world size and line up with anything else drawn at the same place. It is placed from Add sheet: a PDF picked in Dropbox, a page picked from its page grid, its scale confirmed, then a tap where it goes. A canvas holds any number, the last placed on top. Selected, it can be turned, moved or changed in scale; it never takes a free resize, which would make every length on it wrong.
_Avoid_: PDF (the file), page, underlay

**Sheet angle**:
How far a sheet is turned about its centre, read counter-clockwise from 0° up to 360°, to a tenth of a degree. It shows on the selected sheet and can't be typed. A two-finger twist turns it freely and catches on 0°, 90°, 180° or 270° within 3°, with a guide showing the catch; the turn buttons step it a quarter turn. A length read on a sheet is the same at any angle.
_Avoid_: rotation, orientation (a dimension has an orientation), bearing

**Markups that come along**:
What goes with a sheet when it turns, moves or changes scale, chosen at the start of each: ink and dimensions with more than half their length on it, and text boxes with their centre on it. Marks mostly off it stay, and so do frames, which stay square to the canvas. One undo puts it all back. A text box's text stays level; a dimension's axes turn with the sheet, so it reads the same length.
_Avoid_: attached ink, children, bound markups

**Sheet number**:
The number a sheet's title block gives it, such as M-101, read off the PDF page's text; the page grid and a placed sheet's label show it.
_Avoid_: drawing number (a drawing's number is the index's), page number

**Scale area**:
A region of a sheet drawn at a scale of its own, such as a detail marked `SCALE: 1 1/2" = 1'-0"` on an AS NOTED sheet. The sheet is placed at its main scale; inside a scale area, Measure and Dimension read the area's scale, or printed inches marked NTS in an NTS area. Vellum finds them from the scales written under the details and outlines them on the sheet. They are on the paper, so they always turn with it, and their labels stay level.
_Avoid_: viewport, detail sheet, crop

**Drawing scale**:
The ratio between a sheet's printed size and the real world, such as 1/4" = 1'-0". It is what turns a printed length into a real one. A sheet has one main drawing scale, which sets its size on the canvas, and its scale areas can have others.
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
A rectangle on the canvas with a paper size and a drawing scale, such as 24 × 36 at 1/4" = 1'-0", that Zach lays work out inside. A frame prints, exports or goes to an agent as one sheet, like a layout viewport in AutoCAD. It is placed by picking a paper size and dragging a box: Vellum picks the largest standard drawing scale whose paper still covers the drag, and labels the frame with its paper and scale. A canvas holds any number.
_Avoid_: layout, viewport, page, border

**Canvas units**:
The units a canvas shows lengths in, chosen per canvas: feet and inches (to the nearest 1/16"), decimal feet (to the hundredth) or metric (to the millimetre).
_Avoid_: precision, format

**Measure**:
A length read off the canvas between two points, in real-world units, that is not kept. Two taps, each taking a snap point.
_Avoid_: dimension (a dimension stays on the canvas)

**Dimension**:
A kept annotation on the canvas that shows a real-world length between two points, like AutoCAD's linear dimension: two taps, then a third point pulls its dimension line off them. Pulled above or below the points it reads the horizontal distance, beside them the vertical, out at an angle the straight (aligned) distance. It is drawn in the markup colour in hand, its text zooms with the ink, and the lasso selects, moves and deletes it like ink.
_Avoid_: measurement, measure

**Dimension line**:
The line of a dimension that carries its length, pulled off the points dimensioned, with a tick across each end.
_Avoid_: leader, arrow

**Extension line**:
A line of a dimension that runs from just off a point dimensioned to just past the dimension line, so the dimension can sit clear of the object.
_Avoid_: witness line, projection line

**Snap point**:
A point on the ink that a measure, dimension or shape's tap takes when it lands within 20 screen points of one: an end, corner, centre, mid, intersection, perpendicular or tangent, all always on, the nearest winning; otherwise the tap takes the point under the tip. Perpendicular and tangent work from a point already placed, so a first point has neither. Snap points are worked out from a stroke's points, on the ink and never on a sheet's or scale area's edge.
_Avoid_: snap (a snap straightens a stroke), osnap, grip

**Loupe**:
The magnifier that shows the canvas under the Pencil or finger, three times larger, while a measure's, dimension's or shape's point is being found, with the snap point marked and named. It moves aside rather than sliding under the chrome. The point is taken when the tip lifts.
_Avoid_: magnifier, zoom lens

**Window**:
A rectangle dragged on the canvas to choose a region: to zoom to it, to make a frame of it, or to choose what is exported or sent.
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
