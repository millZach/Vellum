# The drawing index is a small manifest, one content-named shard per project, and content-named thumbnails

ADR-0007 put the drawing index in `Dropbox/Vellum`, written by the laptop indexer and searched on the Duo. #66 builds the laptop side and #68 the Duo's, so the file format is shared by two programs in two languages and outlives both tickets. Zach's decisions on #13 (2026-11-06): the indexer scans all of Dropbox, runs always on and watches Dropbox, reads title blocks from the DWG's attributes with the PDF's text as the fallback, and lists PDFs with no DWG.

All of Dropbox may hold tens of thousands of drawings, and the Duo refreshes over a phone connection in a plant, so the format is built so the Duo downloads the minimum: one small read says whether anything changed, and only what changed comes down.

## The decision

The index is the folder `Dropbox/Vellum/Index`, format 1, set out in `docs/drawing-index-format.md`:

- **`index.json`, the manifest.** The format number, a generation that goes up by one with each change, the drawing count, and one line per project: its name, its project folder's path, its shard's file name, its drawing count and its size in bytes. A few hundred bytes per project. It is rewritten only when a shard changed, so the Duo learns whether anything changed from the manifest's Dropbox `rev` or content hash alone (`files/get_metadata`, or the listing of `Vellum/Index` it already keeps a cursor for, ADR-0013) and downloads it only when it changed.
- **`shards/<hash>.json`, one per project.** That project's drawings, each with its Dropbox path, folder, project, title block fields, its DWG and its PDF (path, size, modified time; for the PDF its Dropbox content hash, pages and paper size), what paired them, other PDFs of the same DWG, and its thumbnail's name. A shard is named by the first 32 hex digits of the SHA-256 of its bytes, and its bytes are deterministic (sorted keys, entries sorted by path), so an unchanged project keeps its name: the Duo downloads only shards whose names it has not got, and a change in one project costs one shard.
- **`thumbnails/<hash>.png`, one per drawing,** named the same way, so an unchanged drawing never writes a new one, two identical drawings share one, and the Duo fetches only names it has not got, when it needs them.
- **Every file is written atomically:** to a temp file named `~$<name>.<pid>.tmp` beside it (Dropbox does not sync `~$` files), flushed to disk, then renamed over the old one, so Dropbox never syncs half a file. Shards and thumbnails are written before the manifest that names them, so a Duo that has read a manifest finds everything it names. Files no longer named are deleted an hour after they stop being named, so a Duo part way through a refresh still finds them.
- **An entry is a titled sheet, not a file.** A DWG with several layouts, each with its own title block (E-201 at 1:20 and E-202 at 1:50 in one file), is one entry per layout: the DWG's path plus the layout's name (`layout`), each with its own number, title, scale and PDF, so every title block is searchable. A DWG with one titled layout is one entry with that layout's name; a DWG whose title blocks are not read (no AutoCAD, or online-only and not downloaded yet) is one entry with no layout; a PDF with no DWG is one entry with no layout. We considered one entry per DWG with a list of sheets, which keeps the DWG as the unit, but search, the Duo's rows and a PDF's pairing are all per sheet, and every reader of the index would have to unfold the list.
- **A newer format is a new number.** The Duo reads format 1 and refuses another, keeping the copy it has. Adding a key to an entry is not a new format; a reader ignores keys it does not know. Removing or changing the meaning of one is.

## Considered options

- **One index file.** Simplest for both sides, but every saved PDF anywhere re-uploads and re-downloads every drawing: about 800 bytes a drawing, so megabytes per change at Zach's scale.
- **One file per drawing.** The smallest change, but a first refresh would be tens of thousands of requests, and the Duo would have to list the folder to learn what changed.
- **A changes log the Duo replays.** Smallest downloads, but the laptop and the Duo would have to agree on compaction, and a Duo that missed a compaction would have to start over anyway; content-named shards give most of the saving with nothing to replay.
- **Compressing shards.** JSON compresses well, but shards are already small, and plain JSON is something Zach or an agent can open in Dropbox to see why a drawing is or isn't found. Left for a later format if shards grow.

## Consequences

- The Duo's refresh (#68): read the manifest's metadata; if it changed, download the manifest, then each shard it names that the Duo lacks, then drop shards no longer named. Thumbnails come down by name, and a drawing whose thumbnail is not on the Duo yet shows none.
- "No PDF yet" is an entry with a `dwg` and no `pdf`; "PDF only, no DWG" one with a `pdf` and no `dwg`; "Not on this Duo" is a `pdf` whose `contentHash` is not among the Duo's cached PDFs, which are named by that hash (ADR-0010's #11 amendment). An entry whose file the laptop has not read yet has `"read": false` and its fields unread.
- The indexer's state (what it read from each file, at what size and time) is its own, on the laptop, never in Dropbox, so the index holds only what the Duo needs. Losing it (a purge, a new laptop) does not reset the generation: the indexer carries on from the manifest already in Dropbox, and shards that come out the same keep their names and are not written again.
- `"read": false` now means only that the file is online-only on the laptop and has not been downloaded yet (the external drive unplugged, the laptop not signed in, or a download that failed and will be retried); Zach's #66 decision is to download and read every online-only file.
- Plotting on request (#67) adds its PDFs in `Dropbox/Vellum` (ADR-0007) as entries' `pdf` without a new format.
