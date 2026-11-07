# The drawing index on the Duo, and search on the Drawings tab (#68)

November 7, 2026, on `feat/drawing-search` (PR #75). Every drawing, project, path and file here is made up: the laptop
indexer's own fixture (`laptop/tests/fixtures/drawing-index`) and a generated 20,000-drawing index.

## What CI proved

RUN_SUMMARY

## Hand test on the Duo, from the TestFlight build after merge

With the laptop indexer running on the laptop and its index in `Dropbox/Vellum/Index`, the Duo signed in to Dropbox.
Unchecked until done.

- [ ] Open Drawings. The search screen shows the field, "N drawings in the index · updated by the laptop … ago" and the
      rows with their thumbnails coming in. Unfolded, the list is on the left and "Pick a drawing to see it here" on the
      right; tapping a row shows its number, title, scale and file paths there. Folded, the list alone; a tap does
      nothing yet (opening is #69).
- [ ] Search a drawing number, with and without its dash (`E-201`, `e201`): that drawing is first, then the ones whose
      numbers start with it.
- [ ] Search a word from a title, then a project's name: the matching rows, highlighted.
- [ ] Typing is smooth on the whole index; scrolling a long result list is smooth, thumbnails filling in.
- [ ] A DWG with no plot says "No PDF yet"; a vendor PDF says "PDF only · no DWG".
- [ ] Airplane mode on. The line says "Offline · searching the copy on this Duo". Search again: the same results. A
      drawing whose PDF was never opened on the Duo says "Not on this Duo"; one placed on a canvas from Add sheet before
      does not.
- [ ] An online-only file the laptop has not read yet (the external drive unplugged) shows "Not read yet", by file name
      and folder when it has no title block fields.
- [ ] Airplane mode off: the line drops "Offline" and the copy refreshes by itself.
- [ ] Change one drawing on the laptop (save its DWG, let the indexer rewrite its project's shard). Pull to refresh on
      the Drawings tab: the change shows. In the Dropbox web activity or the laptop indexer's log, only `index.json` and
      that project's shard were downloaded by the Duo; a pull to refresh with nothing changed downloads nothing but the
      folder listing.
