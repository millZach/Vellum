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

**Symbol**:
A drawing kept in the Symbol library to place again and again: a gate valve, an instrument bubble, a motor. It has a name and a printed size, the width it prints across (a 3/8" bubble), and is drawn its printed size on the paper at the drawing scale under the tap: a Scale area's inside one, else the Sheet's, an NTS sheet at its printed size, a Frame's off a sheet, and 1/4" = 1'-0" on bare canvas. Placed, it is plain Ink and Text boxes in the pen's markup colour, which the Lasso and Select take like any other; nothing links it back to the library, so changing the library never changes what is already placed. An instrument bubble asks for its Instrument tag as it lands.
_Avoid_: block, stamp, cell

**Instrument tag**:
The letters over the number inside an instrument bubble, `FT` over `101`. It is typed as the bubble lands, in a pop-up beside it that starts on the bubble's letters and the number after the highest of those letters on the canvas, from 101; once placed it is an ordinary Text box, changed with the Text box tool. Not the Tag that shows a shape's size.
_Avoid_: tag (alone), label

**Symbol library**:
Every symbol a canvas can place, shared by every canvas: the six Vellum starts with, built into the app, and each one saved with Save as symbol or put in `Dropbox/Vellum/Symbols` by the Laptop, one small `.vsym` file each. It is kept on the Duo so it works offline, and synced both ways with that folder: only new or changed files move, and a sync never deletes one.
_Avoid_: block library, palette

**Select**:
The tool beside the Lasso on the rail that picks up one thing with a tap: a stroke, a text box, a dimension, a frame or a sheet, the topmost under the tap. Text boxes lie over dimensions and frames, which lie over ink, which lies over sheets, so where ink lies over a sheet a tap picks the ink and bare paper picks the sheet. A stroke, a dimension's line or a frame's edge is picked within 10 screen points, a text box or a dimension's length on it, a sheet anywhere on its paper. With something selected, a tap on another thing adds it, a tap on what is selected leaves it to be dragged, and a tap on empty canvas lets go of everything; a sheet is always selected alone. Pressing on a thing and dragging moves it at once. A drag from empty canvas does nothing, and the status bar says to loop with the Lasso.
_Avoid_: pointer, arrow tool, selection tool

**Lasso**:
The tool that selects by drawing a loop: it takes every stroke at least half inside the loop, every text box whose centre is inside, every dimension whose text is inside, and every frame wholly inside. A tap with it picks up the topmost sheet under the tap instead; a loop never takes a sheet.
_Avoid_: marquee, window (a window is a dragged rectangle), Select (which takes one thing a tap)

**Selection**:
The strokes, text boxes, dimensions and frames the Lasso or Select has taken, shown with a dashed box and corner handles, which can be moved, resized from a corner (scaled by a factor about the opposite corner, the factor shown in the status bar and caught at ½×, 1×, 2×, 3× and 4×), duplicated or deleted, each as one undo step, and whose ink and text boxes can be kept in the Symbol library with Save as symbol; or the one sheet a tap took, shown with its edge in the accent and a strip under the top bar, which can be turned, moved or changed in scale. It is not saved, it stays selected through undo and redo, and it stays when Select and the Lasso are swapped; any other tool lets go of it.
_Avoid_: group, highlight

**Draw with finger**:
The switch in Settings, off by default and kept on the Duo, that lets one finger draw, erase or use the selected tool as the Pencil does, with two fingers left to pan and pinch. A finger stroke is ink only once it is clearly one finger: a second finger landing within 130 ms of the first cancels it and becomes a pan or pinch, with nothing saved.
_Avoid_: finger mode, touch drawing, palm rejection (the Pencil needs none of this)

**Speed check**:
The switch in Settings, off by default and kept on the Duo, that times each pan and pinch on a canvas from touch-down to the fingers lifting: frames drawn, frames missed, the worst gap, gaps over 50 ms, and what ran on the main thread before the worst few frames. It keeps only the numbers, the last ten gestures in memory and never the drawing, and Settings lists them with Copy all for pasting into an issue. While it is on the status bar shows a red dot.
_Avoid_: profiler, benchmark (the benchmark is CI's), diagnostics

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
A region of a sheet drawn at a scale of its own, such as a detail marked `SCALE: 1 1/2" = 1'-0"` on an AS NOTED sheet. The sheet is placed at its main scale; inside a scale area, Measure and Dimension read the area's scale, or printed inches marked NTS in an NTS area. Where sheets overlap, a scale area reads only where its sheet is the topmost under the point, except that an NTS area reads NTS under any sheet. Vellum finds them from the scales written under the details and outlines them on the sheet. They are on the paper, so they always turn with it, and their labels stay level.
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
A point that a measure, dimension or shape's tap takes when it lands within 20 screen points of one: on the ink an end, corner, centre, mid, intersection, perpendicular or tangent, and a placed sheet's sheet corner, all always on, the nearest winning. Where no point is in reach, a sheet edge catches; otherwise the tap takes the point under the tip. Perpendicular and tangent work from a point already placed, so a first point has neither. Ink's snap points are worked out from a stroke's points. A sheet gives only its outline: lines printed in its PDF and its scale areas' edges are never snapped to.
_Avoid_: snap (a snap straightens a stroke), osnap, grip

**Sheet corner**:
One of the four corners of a placed sheet's paper, at whatever angle the sheet stands, taken as a snap point like an ink corner. The loupe names it "Sheet corner".

**Sheet edge**:
Anywhere along one of a placed sheet's four edges, taken by a tap within 20 screen points of it when no snap point is in reach: a point beats an edge, since the tip is nearly always nearer a whole line than a point beside it. The nearest edge wins, the topmost sheet's on a tie. The middle of an edge is not a point of its own. The loupe names it "Sheet edge". A mark on an edge reads the sheet's scale, or its scale area's where one runs along it, and comes along when the sheet turns, moves or changes scale, through any number of turns and any scale change: a point within 1/1024 printed inch of a sheet's or scale area's edge counts as on it.
_Avoid_: border, page edge

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
The Dropbox folder of the job a sheet's PDF came from, such as a client project's folder. A job's thread runs there. For the drawing index, a drawing's project folder is the top folder under a projects root (`/Projects` unless the laptop indexer's settings name others), or elsewhere the folder holding its discipline and format folders (`Electrical`, `CAD`, `PDF`, `Issued`).
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
The searchable list of every drawing in Zach's Dropbox: where it is, its project, its title block fields, which PDF is its plot, and a thumbnail. A DWG with several titled layouts is one entry per layout, each with its own title block and plot. Choosing a drawing from a search opens it in Vellum.
_Avoid_: catalog, database, register

**Laptop indexer**:
The tool on the laptop (`laptop/`) that keeps the drawing index up to date and plots a drawing to PDF when Vellum asks for one that has none. It starts at logon, scans all of Dropbox, reads only files whose size, modified time or online-only state changed, and watches Dropbox so a saved PDF is in the index within seconds.
_Avoid_: agent (agents run jobs), sync, service

**Index manifest**:
`Dropbox/Vellum/Index/index.json`: the drawing index's format number, its generation and one line per project's index shard. It is rewritten only when a shard changed, so the Duo learns from one small read whether anything did (ADR-0017).
_Avoid_: index file, header, catalog

**Index shard**:
One project's drawings in the drawing index, a file in `Vellum/Index/shards` named by the hash of its bytes, so an unchanged project keeps its name and the Duo downloads only shards it has not got.
_Avoid_: page, chunk, part (a log part is the ink log's)

**Index copy**:
The Duo's copy of the drawing index, in the app's Application Support folder: the index manifest it was last swapped in with, the index shards it names and the thumbnails rows have shown. It is searched on the Drawings tab, offline too, and refreshed with the minimum download; a refresh swaps a new generation in only once every shard it names is on the Duo (ADR-0010's #68 amendment).
_Avoid_: cache (the system may clear Caches; the copy is not there), local index, mirror

**Drawing marker**:
A short label on a row of the Drawings tab's search saying what opening that drawing will meet: "No PDF yet" (a DWG with no plot), "PDF only · no DWG", "Not read yet" (its file is an online-only file the laptop indexer has not read yet; a row with no title block fields shows its file name and folder instead) and, offline, "Not on this Duo" (its PDF has never been downloaded to the Duo).
_Avoid_: badge, tag (a tag is the number shown while drawing), status

**Drawing viewer**:
What a tap on a row of the Drawings tab's search opens: the drawing's PDF, its pages and zoom, with its number, title, rev and scale from the drawing index, and **Place on a canvas** (an existing canvas, newest first, or a new one) and **Open in a new canvas**. Just looking makes no canvas. Its PDF is downloaded once into the same Duo copy Add sheet uses, so it opens offline after; offline, a drawing whose PDF was never opened on the Duo doesn't open and its row says "Not on this Duo". Placing from it follows Add sheet's rules: the index's scale text is the drawing scale, an AS NOTED drawing (or one whose scale can't be read) asks for its scale first with Add sheet's question, an NTS drawing is an NTS sheet, and on an existing canvas the sheet waits as a true-size outline for a tap.
_Avoid_: preview, reader, PDF view

**Plot**:
The PDF a drawing's DWG was plotted to, which the drawing index pairs with it: by the PDF's plot metadata naming the DWG, by the same name nearby, or by the same drawing number in the same project. A drawing with none has no PDF yet; a PDF with no DWG is "PDF only, no DWG".
_Avoid_: print, export, sheet (a sheet is a placed PDF page)

**Online-only file**:
A Dropbox file the laptop keeps only in the cloud, a placeholder until it is opened. The laptop indexer never opens the placeholder, because that downloads the file into the laptop's Dropbox folder: it downloads a copy through the Dropbox API to the scratch folder, reads it and deletes the copy. While it can't (the drive unplugged, not signed in), the file is listed unread by its path and name.
_Avoid_: cloud file, smart sync file, placeholder (alone)

**Scratch folder**:
The folder on Zach's external drive (`D:\Vellum indexer\scratch`) where the laptop indexer downloads an online-only file to read it, one at a time, deleting each copy once what was read is saved. The indexer works only in its own marked subfolder of it, `Vellum indexer copies`, and refuses a scratch folder inside the Dropbox folder.
_Avoid_: cache, temp folder, download folder

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
