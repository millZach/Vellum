# The drawing index on the Duo, and search on the Drawings tab (#68)

November 7, 2026, on `feat/drawing-search` (PR #75). Every drawing, project, path and file here is made up: the laptop
indexer's own fixture (`laptop/tests/fixtures/drawing-index`) and a generated 20,000-drawing index.

## What CI proved

On GitHub's hosted `xcode-27` image (Xcode 27.2, the iPhone Duo simulator on iOS 27.1). The runs and their final
head are linked from PR #75; the counts below are deterministic, and the timings are from run
[42411209467](https://github.com/millZach/Vellum/actions/runs/42411209467) at ddcb731, before the review round, which
changed no search code beyond sharing the keystroke policy with the app.

- **VellumCore tests (macOS).** `DrawingIndexTests` covers the following, each exactly:
  - decoding the laptop indexer's own fixture: manifest, shards, every content name;
  - refusing another format, a damaged file and a manifest that names a file outside the index;
  - the refresh plan: first time, no change, one shard changed, thumbnails added and removed, a half-done refresh never
    swaps, the format bump;
  - the keeper against the made-up Dropbox:
    - first, no-change and one-shard refreshes;
    - cut short and offline, keeping the copy whole;
    - a damaged shard refused;
    - a newer-format manifest, and (after review) a correctly named shard that can't be read or is format 2, each
      keeping the copy;
    - no index yet;
    - thumbnails downloaded once;
  - markers for every fixture case online and offline, `read: false` and "Not on this Duo" included;
  - the quiet row for an unread entry even when the indexer took a number from its file name (after review);
  - search ranking and matching by number, title, project, case and punctuation;
  - the one keystroke policy the app and the timings share.
- **Refresh budgets** (the fixture, three projects):
  - a first refresh is 5 requests and 8,744 file bytes;
  - a no-change refresh is 1 request (the listing) and 0 file bytes;
  - one drawing changed is 3 requests (the manifest's bytes and that shard's);
  - no thumbnail comes down with a refresh, and one thumbnail ever comes down once.
- **Search on a made-up 20,000-drawing index.** Budgets:
  - search structure: 2,497,673 bytes;
  - entries: 15,870,066 bytes estimated;
  - entries looked at while typing "pump house": 50,680; "E-123": 32,463; "made-up project 042": 361,800.

  Optimised timings: a keystroke 0.60 ms at the median and 1.50 ms at worst, a full scan 0.77 ms, loading the copy
  370.56 ms (decode 220.74 + build), 15.30 MB resident. All are within their baselines (`perf-compare.py
  drawing-index`), and the job keeps them as the `drawing-search-timings` artifact.
- **iOS simulator build (macOS)**: built unsigned; no warning from this change's files.
- **Duo simulator captures**:
  - `drawings-search`, the fixture refreshed, then offline, with "plant" typed and E-210 picked, so every marker shows;
  - `drawings-no-index` and `drawings-offline-no-copy`;
  - each unfolded (2853 × 2007) and folded on the cover screen (1398 × 2034), light and dark.

  The 12 captures take about 4 minutes of the job.
- **Duo sheet and sync captures**, **Duo release benchmark** and **Laptop indexer tests (Windows)**: unchanged by this
  work, and green.

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
- [ ] An online-only file the laptop has not read yet (the external drive unplugged) shows "Not read yet" as a quiet
      row: its file name and path, no fields.
- [ ] Search something most drawings match (a project's name, "plan"): the count says how many, and scrolling to the end
      of the list keeps bringing more rows until the last match.
- [ ] Airplane mode off: the line drops "Offline" and the copy refreshes by itself.
- [ ] Change one drawing on the laptop (save its DWG, let the indexer rewrite its project's shard). Pull to refresh on
      the Drawings tab: the change shows. In the Dropbox web activity or the laptop indexer's log, only `index.json` and
      that project's shard were downloaded by the Duo; a pull to refresh with nothing changed downloads nothing but the
      folder listing.
