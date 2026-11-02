# Placing sheets (#11): verification

Every PDF, title block, project and number here is made up (`MadeUpSheets`, drawn by `MadeUpPDF` in Debug builds). No client drawing is in the repository or the captures.

## The "done when": each made-up PDF measures its printed dimension

Placed at the scale Vellum reads off its title block, a Measure between the ends of each printed dimension reads what is printed on it. This is proven twice: in VellumCore (`MadeUpSheetTests`, over the same title-block text the PDFs draw), and in the app on the Duo simulator, through PDFKit's text, the canvas saver and the canvas view's input paths (`DebugSheets`, the sheet captures' log):

| Sheet | Title block | Read as | Printed | Measured |
|---|---|---|---|---|
| M-101, 36 × 24 | `SCALE: 1/4" = 1'-0"` | 1/4" = 1'-0", covers 144'-0" × 96'-0" | 24'-0" | 24'-0" |
| D-501, 17 × 11, Detail 1 | `SCALE: AS NOTED` | placed at 1" = 1'-0" (the first detail's) | 3'-0" | 3'-0" (VellumCore) |
| D-501, Detail 2 (scale area) | `SCALE: 1 1/2" = 1'-0"` under it | scale area at 1 1/2" = 1'-0" | 2'-0" | 2'-0" |
| D-501, Detail 3 (scale area) | `SCALE: NTS` under it | NTS scale area | 2" NTS | 2" NTS (VellumCore) |
| L-1042, 11 × 8.5 | `SCALE: NTS` | NTS, at printed size | 4" NTS | 4" NTS |
| M-001, a scan | no text | asks; the captures pick 1/8" = 1'-0" | – | dims in dark mode |

The captures' log (Duo sheet captures job) prints each page's reading, each detail's guessed area (D-501: Detail 1 0.50–5.00", Detail 2 5.00–9.26", Detail 3 9.26–12.70" across, 0.50–7.88" down) and each measure beside its printed text.

## What the captures show

`duo-sheet-captures`, light and dark, unfolded (951 × 669): `add-sheet-browser` (the made-up project's Drawings folder, a folder then its PDFs), `add-sheet-grid` (the IFC set's three pages with sheet numbers and scale tags), `add-sheet-confirm` (M-101: the scale read and what it will cover), `add-sheet-asnoted` (D-501: the scales on the sheet first, its two scale areas outlined on the page), `add-sheet-scan` (asking for a scale), `sheet-outline` (the true-size outline following the Pencil, the pill and the status bar's "Tap where the sheet goes"), `sheet-quarter`, `sheet-asnoted` (the scale areas dashed in purple with their labels), `sheet-nts`, and `sheet-scan` (in dark mode the plan inverts and the scan dims).

## What was found and fixed on the way

- PDFKit's `page.string` indices drift from `characterBounds(at:)` where it adds spaces and line breaks, so a title block's scale read off the sheet number's boxes. Pages are now read by PDFKit's line selections, split where a strip of the line selects no text; split pieces of one line are joined before reading (`SheetReading.joinFragments`).
- A tile at a page's edge painted paper across its whole square, so dimmed and inverted sheets overhung their pages. Each tile now clips to the page.
- At 3x, a first view and a screen's pan (44 tiles) are two over the 96 MB tile cache, so panning back draws the two least recently shown again; the pan-back budget is measured at 2x and says so.

## Timings

Frame work in ms, p50 / p95, on GitHub's xcode-27 image, Xcode 27.2, iPhone Duo simulator iOS 27.1, run 41455734328. Simulator numbers are indicative; Release timings on the separate benchmark job are noisy (#32), so the sheet scenarios are compared with the bare-canvas scenarios of the same run.

| Scenario | Release | Debug |
|---|---|---|
| pan (bare canvas, 10,000 strokes) | 2.27 / 3.79 | 2.36 / 3.69 |
| sheet_pan (over a placed 1/4" sheet) | 2.30 / 3.77 | 2.48 / 4.75 |
| pinch | 3.09 / 5.87 | 5.52 / 8.96 |
| sheet_pinch | 3.32 / 6.16 | 4.56 / 8.06 |
| draw | 3.06 / 4.77 | 3.17 / 5.35 |
| sheet_draw (ink over the sheet) | 3.73 / 6.57 | 3.31 / 6.38 |
