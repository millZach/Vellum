# The canvas screen is a drafting rail, in light and dark

Zach picked the drafting rail from three canvas-screen designs (drafting rail, a floating pen palette, and an AutoCAD-style ribbon with a sheet set), kept at the tag `prototype/canvas-screen`. The tools run down a rail on the left: pen, highlighter, eraser, line and shape, then lasso and text box, then measure, dimension, frame and window, with the four markup colours at its foot. A bar across the top holds the canvas name, its units, light or dark, undo, and a gear for Settings (#28), with Add sheet, Record and Send at the right. A status bar along the bottom shows the pen's position in canvas units, a scale bar, what the current tool expects next, the sheet and frame count, zoom to everything, and whether the canvas is saved and synced. The iOS tab rail at the right edge holds Canvases, Drawings, Jobs and Meetings. The Pencil draws and fingers pan and pinch.

Vellum follows the Duo's light or dark setting, and its settings can pin it to Light, Dark or System, as Sotto's iPhone client does. In dark mode the canvas and chrome go dark and sheets are inverted to light linework on dark, the way AutoCAD shows model space; a sheet that inverts badly (a coloured or scanned PDF) can be shown dimmed instead. Sketch ink and dimensions flip between dark and light to stay readable over what is under them, like AutoCAD's colour 7. Red, green and blue ink keep their meaning in both modes.

## Considered options

- **A floating pen palette** gave the most drawing room but hid most tools behind a More button.
- **A ribbon with a sheet list and a command line** felt most like AutoCAD but left the least drawing area on a 951 × 669 point screen.

## Amendment (#24): Draw with finger

"The Pencil draws and fingers pan and pinch" stays the default. A **Draw with finger** switch in Settings (the sheet the gear at the end of the canvas top bar and the Drawings tab both open, #28), off by default as in Apple Notes and kept on the Duo, lets one finger draw, erase or use whichever tool is selected, exactly as the Pencil does, for when the Pencil isn't to hand; two fingers then pan and pinch, and the Pencil is unchanged. A finger stroke is drawn live at once but is held pending until it is clearly one finger: a second finger within 130 ms of touchdown (`FingerStrokeGate.secondFingerWindow`, in `VellumCore`) cancels it, leaving no ink, no saved change and no undo step, and the fingers pan and pinch. A second finger after that ends the stroke where it is, kept. The Pencil landing during a finger stroke takes over: a confirmed finger stroke is kept, a pending one dropped. A finger's eraser sweep holds its samples while pending and erases them once confirmed, so a cancelled sweep erases nothing. The canvas reads the switch only when it changes, so with it off a touch does no more work than before. The simulator no longer draws with a finger by default; the captures turn the switch on with the Debug-only `--ui-draw-with-finger` launch argument, for that launch only.

## Amendment (#7): line and shape, lasso and text box

The line and shape tool, the lasso and the text box tool now work. The line and shape tool draws pen ink that snaps to a straight line, a rectangle or a circle when it lifts (the pen snaps too, when the Pencil holds still at the end of a stroke). The lasso draws a dashed loop in the chrome's accent and shows what it selected as the prototype does: a dashed box 6 points outside the selection, with a handle at each corner for resizing, and a dark menu under it with the count, Duplicate and Delete; the status bar then says to drag the selection. The prototype's menu also offers Send…, which comes with sending jobs; and its glow on selected ink is left out, since it would mean redrawing the selection's tiles. A tap with the text box tool places a text box or edits the one tapped, and writing with the Pencil places one where the writing starts.

## Amendment (#8): measure, dimension, frame and window

Every tool on the rail now works, as Zach picked them from the prototype at the tag `prototype/measure-frame`:

- **Measure**: two taps; the length shows in an orange box on a dashed line until the next measure or another tool, and is not kept.
- **Dimension**: two taps, then a third drag or tap pulls the dimension line off the points, with extension lines; kept, in the markup colour in hand.
- **Finding points**: a measure or dimension tap snaps to an ink end, corner or circle centre within about 20 screen points, found through the ink index. While the tip is down a loupe 120 points across shows the canvas under it three times larger, 104 points above the tip (beside it near the top), with a teal marker on the snap point and its name; the point is taken on lift. The loupe shows the ink tiles already drawn (ADR-0012), never a second drawing of the canvas.
- **Frame**: a "Frame paper" picker sits under the top bar while the tool is in hand; dragging a box shows the frame it makes and its label (paper and scale) live, and lifting places it. The status bar counts frames.
- **Window**: dragging a box offers a dark menu like the selection's: Zoom to window, Make a frame here, and Send… (disabled, "later", until sending jobs exist).
- The status bar's prompt follows each step: "Tap the second point", "Drag or tap to place line", "Zoom to it or make a frame".
- As with every tool, the Pencil uses them and fingers pan and pinch; with Draw with finger on, one finger uses them too.
- The top bar gives the canvas name layout priority, so it shows in full whenever it fits beside the actions.

## Amendment (#11): Add sheet, and who dims a sheet

Add sheet at the right of the top bar now works, as Zach picked it from the prototype at the tag `prototype/place-sheets`: it opens Dropbox's folders down to the PDFs; a PDF of several pages opens as a grid of thumbnails, each captioned with its sheet number and the scale read; a confirm step names the scale read and what the sheet will cover, with Cancel, Change scale and Place sheet, or asks for a scale; and the sheet then waits as a true-size outline for a tap where it goes, with a pill under the top bar saying so and offering Cancel. The status bar says "Tap where the sheet goes" meanwhile, whatever the tool, and its sheet count counts placed sheets.

**Vellum decides which sheets dim (question 4, A).** There is no switch. When a page is confirmed, Vellum renders it once, 96 pixels on its long side, off the main thread, and dims it in dark mode when it has no text (a scan), more than 3% of its pixels clearly coloured (coloured fills), more than 25% darker than mid grey (large dark fills), or a median brightness under 225 of 255 (paper that is not white: a scan or a photocopy) (`SheetTone`, in `VellumCore`). The answer is kept with the sheet. Any other page is drawn inverted: light lines on a paper a shade lighter than the dark ground. Sketch ink starting over a dimmed sheet keeps its dark colour (`SheetDisplay.paperIsLight`, `MarkupColour.rgb(dark:overLightPaper:)`).

## Amendment (#33): the status bar at its longest, and disabled Send

The pen's position is 11 pt monospaced on one line at full 1/16" precision. Its width is set, room for any position under 100', so the pen moving lays out only its own text; the first position longer than that widens it for good to three-digit feet, and it grows further only for longer still (`StatusBarText`, in `VellumCore`). To make the room the status bar's items sit 8 points apart and the scale bar is at most 60 points long. At the long width the sheet and frame count shortens to the first wording that fits ("1 sheet · 0 frames", "1 sh · 0 fr", "1 · 0"), so the position, prompt and status stay whole; VoiceOver always hears the full count.

Send in the top bar and the window menu's "Send… (later)" are faded blue while disabled, as Place sheet is (#35), and Send takes Place sheet's capsule shape with it, at its old width so the canvas name keeps its room. The menu's label is a plain label, since UIKit picks a disabled button's title colour itself, and uses `ChromeColourPair.windowMenuDisabled`, lighter than `disabledButton`, whose light text reaches only 2.9:1 on the near-black pill.

## Amendment (#45): the full count beside the longer prompts

The sheet and frame count reads in full beside "Draw a line, box or circle", "Dimension: tap first point" and "Tap where the sheet goes" at ordinary coordinates, as Zach chose. The room comes from the scale readout, which kept 120 points whatever it showed. It now keeps the bar's 60 points, its 6-point gap and 40 points for the label, enough for any label up to `50'-0"`. A longer label widens the readout by what it needs, so it is never cut or wrapped; that moves the prompt once as the label changes, and past the room the count shortens to the first wording that fits. The width follows the label and not the bar, so a pinch lays out only the bar between labels. `Scripts/status-bar-check.py` fails the captures job if a usual label beside one of the three prompts loses the full count.
