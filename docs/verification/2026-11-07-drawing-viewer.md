# The drawing viewer, and placing from search (#69)

November 7 and 8, 2026, on `feat/drawing-viewer` (PR #77). Every drawing, PDF, project and canvas here is made up: the laptop indexer's made-up fixture index (`laptop/tests/fixtures/drawing-index`), the made-up PDFs of `MadeUpSheets`, and a made-up twelve-page E-size set drawn in the Debug build.

## What CI proved

Run [42430195816](https://github.com/millZach/Vellum/actions/runs/42430195816) at dccb02b, on GitHub's hosted `xcode-27` image with Xcode 27.2 and the iPhone Duo simulator (iOS 27.1).. All six jobs green.

- **VellumCore tests (macOS)**: 633 tests, 0 failures, 1 skipped (as on main). `DrawingOpeningTests` (26) covers, exactly:
  - **which PDF opens**: an entry's own `pdf`; each layout of a DWG with two titled layouts (`Pump house.dwg`: E-210 and E-211) opens its own plot; a three-page set says its pages; a DWG with no plot has none (`noPDFYet`); a PDF the laptop has not read opens by its path online;
  - **offline and not on the Duo**: a kept PDF opens with no download online or off; one never opened downloads online and is refused offline; across every fixture entry, online and off, with none, three or all PDFs kept, the viewer refuses exactly the rows marked "Not on this Duo" (8 + 5 + 1 refusals);
  - **found by its path**: a PDF opened once under a stale index hash, and under a missing one, opens again offline, its row loses "Not on this Duo", a second open downloads nothing, and a fresh `SheetPDFs` over the same folder (as after a relaunch) still finds it;
  - **one download**: Add sheet and the viewer asking for one path at once start one download between them; two opens at once share one;
  - **the index's scale text**, every form it can take: architectural (`1/4" = 1'-0"`, `1/4"=1'-0"`, `SCALE: …`, typographic primes, `1/8"`, `1 1/2"`, `3/32"`), engineering (`1" = 20'`, `1" = 20'-0"`, `1"=100'`), metric ratios (`1:20`, `1:50`, ` 1 : 100 `), `FULL SIZE`, NTS (`NTS`, `N.T.S.`, `nts`, `NOT TO SCALE`, `SCALE: NTS`); and asking for AS NOTED, AS SHOWN, AS INDICATED, VARIES, blank, missing and garbage (`1/4 = 1`, `1:`, `:20`, `1/4" = `, `SEE PLAN`, two scales, `nan:1`, `-1:20`);
  - **Zach confirms it**: the confirm step is prefilled with the index's scale (M-101 1/4" = 1'-0", E-210 1:20, I-301 NTS) and asks for M-501 (AS NOTED) and an unreadable scale;
  - **placed from search lands as placed through Add sheet**, the same `Sheet`, compared whole:
    - 1/4" = 1'-0", 36 × 24: 1728" × 1152" (144'-0" × 96'-0"), no scale areas, its printed 6" reads 24'-0";
    - 1:20, 36 × 24: 720" × 480" (18.288 m × 12.192 m), no scale areas;
    - NTS, 11 × 8.5: 11" × 8.5" at printed size, no scale areas;
    - AS NOTED, given 1/8" = 1'-0", 17 × 11: 1632" × 1056" (136'-0" × 88'-0"), scale areas Detail 1 at 1" = 1'-0", Detail 2 at 1 1/2" = 1'-0", Detail 3 NTS, the same as Add sheet's;
  - **a new canvas's name**: `E-210 Pump house power plan`, the number once when the title starts with it, the number or title alone, the file name without `.dwg`/`.pdf`, else "Untitled canvas";
  - **a new canvas with its sheet**: made with the sheet in its ink log and its PDF in `sheets/`, centred on the origin (1:20, 720" × 480", origin -360", -240"), nothing half made beside it; when the PDF can't be kept, nothing is listed.
- **iOS simulator build (macOS)**: built unsigned.
- **Duo sheet and sync captures**: green, 40:25. The viewer's captures, unfolded, light and dark:
  - `viewer`: M-501's three pages in the viewer beside the list, its header from the index, the page strip, Fit, and the AS NOTED note;
  - `viewer-picker`: Place M-101 on a canvas: New canvas, named "M-101 First floor HVAC plan", then the made-up canvases newest first;
  - `viewer-placing`: after picking the newest and confirming 1/4" = 1'-0" on Add sheet's step, the Canvases tab with "Tap where M-101 goes" and its true-size outline, 144'-0" × 96'-0";
  - `viewer-e-size`: the made-up E-size set open, light.
  - **Time to first page** of the made-up twelve-page E-size set already on the Duo (no download): 113.9 ms (cold), 40.3 ms and 39.4 ms; median 40.3 ms against its new baseline of 90.3 ms (−55%), set from run 42425474253 (229.4, 84.2 and 90.3 ms; median 90.3), at 50% tolerance while it rests on one sample. M-101 from the made-up Dropbox, downloaded and opened: 150 to 165 ms to its first page.
  - The viewer's log: the confirm step opened as "Place on “Boiler 4 walkdown (example)”, starting on 1/4" = 1'-0"", and the placing capture shows "Tap where M-101 goes" with the outline labelled `M-101 · 1/4" = 1'-0" · 144'-0" × 96'-0"`.
  - Run 42425474253's viewer capture showed the header's project line overlapping the PDF path; it is one line of text now, and this run's capture shows it clear.
- **Duo simulator captures** (47:26) and **Duo release benchmark** (24:11): green, with no timing warnings; every existing capture block still runs.
- **Laptop indexer tests (Windows)**: green.

### Warnings on the final run

- **VellumCore tests**: one timing warning, `append-hand-off-calling-thread` 49.6 µs against its 35.6 µs baseline (storage, which this PR doesn't touch). Main's merge run for a74029f warned on the same timing at 73.1 µs, and on `search_keystroke_p50_ms` at 1.14 ms (+103%); here that keystroke is 0.68 ms (+22%), under its tolerance.
- **Compiler warnings, new in this PR**: one, in the Release build only: `DrawingViewerView.swift:590: 'PageTiledLayer' inherits an unavailable 'Sendable' conformance`. Follow-up: drop the `@unchecked Sendable` on the tiled layer.
- **Compiler warnings already on main**, unchanged: `CanvasSync.swift:441` ('as' test is always true), `AddSheetFlow.swift:66` (conditional cast always succeeds), `SheetTests.swift:582` (the same), `CanvasListScreen.swift:139` (`+` on Text deprecated), `InkTileRenderer.swift:338` and `SheetRenderer.swift:406` (unneeded `nonisolated(unsafe)`), `Scripts/duo/posture.m:26` (performSelector), and the AppIntents metadata note.

### Job times against main's merge run for a74029f (42421546529)

| Job | main, a74029f | this PR, dccb02b |
|---|---|---|
| VellumCore tests (macOS) | 4:12 | 4:03 |
| iOS simulator build (macOS) | 2:13 | 1:22 |
| Duo simulator captures | 53:05 | 47:26 |
| Duo sheet and sync captures | 40:53 | 40:25 |
| Duo release benchmark | 14:17 | 24:11 |
| Laptop indexer tests (Windows) | 2:13 | 2:52 |

The viewer's captures add about 3 minutes to the sheet and sync job (23:59:53 to 00:02:59 in run 42425474253). That job ran 58:13 of its 60 minutes on run 42425474253, on a slow runner, and 40:25 here. With so little room, the next ticket that adds captures there should split it: the sync and drawing tools' captures into a job of their own, leaving the sheet and viewer captures together.

## Hand test on the Duo, from the TestFlight build after merge

With the Apple Pencil, the Duo unfolded unless it says folded. Unchecked until done.

- [ ] **Search and open.** On Drawings, type a drawing number. Tap its row: the viewer opens beside the list with its number, title, rev, scale, date and project, and the PDF's first page. A PDF never opened shows "Downloading …" with a bar first; a second open of it shows the page at once.
- [ ] **Page and zoom.** On a set of several pages, tap Next, Previous and a page in the strip. Tap Zoom in up to 600%, pan, pinch, then Fit. The page stays sharp as it zooms. Tap Full screen and back.
- [ ] **Folded.** Fold the Duo and tap a row: the viewer fills the cover screen; "Drawings" goes back to the list.
- [ ] **Place on an existing canvas.** On a 1/4" = 1'-0" drawing tap Place on a canvas…: New canvas first, then the canvases newest first. Pick one: Add sheet's confirm step opens on the page shown, saying "The title block says SCALE: 1/4" = 1'-0"", with Place on “…”; tap it, and the Canvases tab opens on that canvas with "Tap where … goes" and the true-size outline. Tap to place, then Measure a dimension printed on the sheet: it reads what is printed.
- [ ] **Open in a new canvas.** On another drawing tap Open in a new canvas: confirm the scale on Add sheet's step, and a canvas named "<number> <title>" opens with the sheet in its middle at its scale (New canvas in the picker does the same). Measure a printed dimension.
- [ ] **AS NOTED asks.** On an AS NOTED drawing tap either button: Add sheet's confirm step asks for the scale, with the scales to pick and the details outlined as scale areas; its button reads "Place on “…”" or "Open in a new canvas". Pick one and place it; Measure inside a scale area reads that detail's scale.
- [ ] **Airplane mode.** Turn on airplane mode. A drawing opened before opens at once. One never opened says "Not on this Duo" on its row; tapping it says "<number>'s PDF isn't on this Duo yet. It downloads when you're back online; searching works offline." and no viewer opens.
- [ ] **Opened once, plotted again.** Open a drawing, then on the laptop plot it again (the index updates). Turn on airplane mode: it still opens, from the copy on the Duo.
- [ ] **No PDF yet.** Tap a DWG with no plot: the viewer shows "No PDF yet" and both buttons are off.
