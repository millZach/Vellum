# The drawing index, format 1

The laptop indexer (`laptop/`, #66) writes it; the Duo (#68) reads it. Why it is shaped this way: ADR-0017. A made-up
example, written by the indexer itself, is `laptop/tests/fixtures/drawing-index` (`laptop/scripts/make_fixture_index.py`
rebuilds it; a test checks it is current).

## Files

```
Dropbox/Vellum/Index/
  index.json                      the manifest
  shards/<32 hex>.json            one per project, named by the SHA-256 of its bytes (first 32 hex digits)
  thumbnails/<32 hex>.png         one per drawing, named the same way
  ~$*.tmp                         a file being written; ignore
```

All JSON is UTF-8. Paths are Dropbox paths as the Duo's Dropbox client names them: from the Dropbox root, starting
`/`, with `/` between folders, in the case the laptop's disk shows (Dropbox compares them without case). Times are UTC,
`YYYY-MM-DDTHH:MM:SSZ`.

## `index.json`

```json
{
 "format": 1,
 "generation": 42,
 "updated": "2026-11-07T12:00:00Z",
 "drawings": 8,
 "thumbnailBox": 128,
 "shards": [
  { "project": "Made-up Plant Upgrade", "projectPath": "/Projects/Made-up Plant Upgrade",
    "file": "shards/38c3b6829f7d277cce83bebda6e4fcbe.json", "drawings": 4, "bytes": 3121 }
 ]
}
```

| Key | Meaning |
|---|---|
| `format` | 1. A reader refuses any other number and keeps what it has. |
| `generation` | Goes up by one each time the manifest is written, which is only when a shard changed. |
| `updated` | When this generation was written. |
| `drawings` | Entries across every shard. |
| `thumbnailBox` | Thumbnails fit in this many pixels square (128). |
| `shards` | One per project, sorted with no-project first, then by project path. `project` and `projectPath` are `null` for drawings at Dropbox's top. `file` is relative to `Index/`. `bytes` is the shard's size. |

## A shard

```json
{ "format": 1, "project": "Made-up Plant Upgrade", "projectPath": "/Projects/Made-up Plant Upgrade",
  "drawings": [ <entry>, ... ] }
```

Entries are sorted by `path`, then `layout`, without case. Keys are sorted and the JSON is compact, so the same drawings always give
the same bytes and the same name.

## An entry

```json
{
 "id": "dd0bdad0ab9b9082",
 "path": "/Projects/Made-up Plant Upgrade/CAD/E-201.dwg",
 "name": "E-201.dwg",
 "layout": "Layout1",
 "folder": "/Projects/Made-up Plant Upgrade/CAD",
 "project": "Made-up Plant Upgrade",
 "projectPath": "/Projects/Made-up Plant Upgrade",
 "number": "E-201",
 "title": "Boiler room power plan",
 "revision": "A",
 "scale": "1/4\" = 1'-0\"",
 "date": "2026-10-02",
 "fieldsFrom": "dwg",
 "dwg": { "path": "/Projects/Made-up Plant Upgrade/CAD/E-201.dwg", "size": 17767,
          "modified": "2026-09-21T14:13:20Z", "read": true },
 "pdf": { "path": "/Projects/Made-up Plant Upgrade/PDF/E-201.pdf", "size": 1184,
          "modified": "2026-09-21T14:15:20Z", "read": true,
          "contentHash": "85a8840345de4e26c4bff449341350969d9599d516462abb9940cd750debaeda",
          "pages": 1, "paperInches": [36.0, 24.0] },
 "otherPdfs": [],
 "pairedBy": "metadata",
 "thumbnail": "1b3fb51c4d8888378af18a70fa63a047.png"
}
```

| Key | Meaning |
|---|---|
| `id` | Stable while the drawing's `path` and `layout` stay: the first 16 hex digits of the SHA-256 of `path` in lower case, followed by `#` and `layout` in lower case when there is a layout. |
| `path`, `name`, `folder` | The drawing's file: its DWG when it has one, else its PDF. |
| `layout` | The DWG layout whose title block this entry is, or `null` (a PDF with no DWG, or a DWG whose title blocks are not read yet). A DWG with several titled layouts has one entry per layout, all with the same `path` and `dwg`, each with its own fields and `pdf`. |
| `project`, `projectPath` | Its project folder's name and path, or `null`. |
| `number`, `title`, `revision`, `scale`, `date` | Title block fields as written in the title block (not parsed), each `null` when unknown. `scale` is text such as `1/4" = 1'-0"`, `1:20`, `NTS` or `AS NOTED`; the Duo parses it (an AS NOTED drawing asks for its scale before it is placed). |
| `fieldsFrom` | Where the fields came from: `dwg` (its title block attributes, with any it lacks from the PDF), `pdf` (the PDF's first page text), `name` (only a drawing number, from the file name), or `null`. |
| `dwg` | The DWG, or `null`. `read` is `false` only while the file is online-only on the laptop and has not been downloaded and read yet (the external drive unplugged, the laptop not signed in to Dropbox, or a failed download waiting to be retried). |
| `pdf` | The PDF shown for it, or `null`. Its `path` is in the project folder, or under `/Vellum/Plots` for a plot made on request. `contentHash` is Dropbox's content hash, `pages` the page count, `paperInches` the first page's width and height in inches as it is viewed (a page turned by `/Rotate` 90° reports its turned size); all three are `null` while `read` is `false`. |
| `pdf.fitted` | `true` for a plot the laptop fitted to the page, not to scale (a Model-tab DWG's fallback, `docs/plot-requests.md`, #92); absent on every other PDF, and on every PDF in an index from before indexer 1.1.2. The Duo places a fitted PDF as an NTS sheet whatever `scale` says, and its viewer says "Plotted to fit, not to scale". A reader that doesn't know the key ignores it. |
| `otherPdfs` | Paths of other PDFs plotted from the same layout (older plots), newest first after `pdf`. A plot made on request is listed with the rest, by its modified time, so a re-plot of a changed DWG is `pdf` and the older plot moves here. |
| `pairedBy` | Why `pdf` belongs to `dwg`: `metadata`, `name` or `number` (laptop/README.md, "Pairing"), `plotted` (the laptop plotted it on request, into `/Vellum/Plots`: `docs/plot-requests.md`), or `null`. A reader treats a value it does not know as paired. |
| `thumbnail` | Its file in `thumbnails/`, or `null`: the PDF's first page, else the DWG's saved preview. |

## What the Duo's markers read (#68)

| Marker | Entry |
|---|---|
| No PDF yet | `dwg` and no `pdf` |
| PDF only, no DWG | `pdf` and no `dwg` |
| Not on this Duo | a `pdf` whose `contentHash` is not among the Duo's cached PDFs (ADR-0010), or is `null` |
| Not read yet (online-only on the laptop, not downloaded yet) | `dwg.read` or `pdf.read` is `false` |

## Refreshing on the Duo

1. Ask Dropbox for `Vellum/Index/index.json`'s metadata (or read the `Vellum/Index` listing's changes). Same `rev`
   as last time: nothing changed; stop.
2. Download `index.json`. Refuse a `format` other than 1.
3. Download each shard named whose file name the Duo has not got. A shard's name is the hash of its bytes, so a
   download that does not hash to its name is refused.
4. Drop kept shards no longer named.
5. Download thumbnails by name as rows need them; a name the Duo has is never downloaded again.

The laptop writes shards and thumbnails before the manifest that names them, and deletes files an hour after they
stop being named, so steps 3 and 5 find what a just-read manifest names.

## When the laptop loses its state

After a purge or on a new laptop the indexer carries on from the `generation` in the manifest already in Dropbox, so
the Duo never sees the generation go back. Shards and thumbnails that come out the same keep their names.

## Changing the format

Adding a key is not a new format: readers ignore keys they do not know. Removing a key, changing a key's meaning or
changing how files are named is format 2, in a new ADR, and the Duo is updated to read it before the laptop writes it.
