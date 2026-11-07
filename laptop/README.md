# The laptop indexer

The **laptop indexer** runs on Zach's Windows laptop. It scans the laptop's Dropbox folder for DWGs and PDFs, pairs
each PDF with the DWG it was plotted from, reads each drawing's title block fields (drawing number, title, revision,
scale, date), makes a thumbnail, and keeps the **drawing index** in `Dropbox\Vellum\Index`, where the Duo reads it
(#68). It starts at logon and watches Dropbox, so a saved PDF is in the index within seconds.

It needs no Dropbox API token: it reads the folder the Dropbox desktop app keeps in sync. It only reads project
files; it never changes, moves or deletes them, and it writes only inside `Dropbox\Vellum\Index`.

The index's format is [`docs/drawing-index-format.md`](../docs/drawing-index-format.md), decided in
[ADR-0017](../docs/adr/0017-the-drawing-index-is-a-manifest-of-project-shards.md).

## Install

On the laptop, with Python 3.12 or newer installed (python.org, "Add python.exe to PATH" or the `py` launcher):

```powershell
powershell -ExecutionPolicy Bypass -File laptop\scripts\install.ps1
```

It makes a virtual environment in `%LOCALAPPDATA%\Vellum\indexer\venv`, installs the pinned dependencies from
`requirements.lock`, checks it can find Dropbox, registers the scheduled task `\Vellum\Vellum laptop indexer` to start
at logon (below-normal priority, on battery too, restarted within a minute if it stops), and starts it.

- `-DropboxPath D:\Dropbox` names the Dropbox folder instead of Dropbox's `info.json`.
- `-NoStart` registers the task without starting it.

Uninstall with `laptop\scripts\uninstall.ps1`; add `-Purge` to delete the state file, log and settings too. Neither
touches `Dropbox\Vellum\Index`.

By hand, from a checkout: `python -m pip install -r laptop\requirements.lock` and `python -m pip install --no-deps
laptop`, then `vellum-indexer where` (prints where everything is), `vellum-indexer scan` (one scan, then exit) or
`vellum-indexer run` (scan, then watch; what the task runs).

## Where things are on the laptop

| What | Where |
|---|---|
| Dropbox folder | from `%APPDATA%\Dropbox\info.json` or `%LOCALAPPDATA%\Dropbox\info.json` (the personal account, else business), unless `--dropbox` or `dropbox_path` names it |
| The index the Duo reads | `<Dropbox>\Vellum\Index\` (`index.json`, `shards\`, `thumbnails\`) |
| State file | `%LOCALAPPDATA%\Vellum\indexer\state.sqlite` |
| Log | `%LOCALAPPDATA%\Vellum\indexer\indexer.log` (5 MB, three old logs kept) |
| Settings | `%LOCALAPPDATA%\Vellum\indexer\settings.toml` (optional) |
| Work copies of DWGs for AutoCAD | `%LOCALAPPDATA%\Vellum\indexer\work\` (emptied after each drawing) |

`settings.toml`, every key optional:

```toml
dropbox_path = 'D:\Dropbox'           # instead of info.json
dropbox_account = 'business'          # which account in info.json
projects_roots = ['/Projects']        # Dropbox folders whose top folders are projects
exclude = ['/Personal/**', '**/Archive/**']   # globs on Dropbox paths, any case
accoreconsole = 'C:\Program Files\Autodesk\AutoCAD 2026\accoreconsole.exe'
debounce_seconds = 2                  # quiet time before an update
rescan_hours = 6                      # a full, stat-only rescan this often

[title_block_tags]                    # more attribute tags, per field
number = ['SHT_ID']
title = ['HEADING']
```

## What it scans

All of Dropbox, for `.dwg` and `.pdf` files, except:

- `Dropbox\Vellum` itself (canvases, symbols and the index);
- Dropbox's own folders (`.dropbox.cache`, `.dropbox`) at any depth;
- temp, lock and backup files: `~$*`, `.~*`, `*.dwl`, `*.dwl2`, `*.bak`, `*.sv$`, `*.tmp`;
- anything `exclude` names.

### Online-only files are never pulled down

A Dropbox file set to online-only is a Windows cloud-files placeholder (`FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS`,
`FILE_ATTRIBUTE_RECALL_ON_OPEN` or `FILE_ATTRIBUTE_OFFLINE`). Opening one makes Dropbox download it, and across all of
Dropbox that could be the whole account. The indexer reads each file's attributes from the directory listing, which
does not download anything, and **never opens an online-only file**: it lists it in the index by its path and name,
with `"read": false` and its fields unread (only a drawing number taken from its file name), and it can still pair
with a DWG by name. Once the file is local (opened, or made available offline), its attributes change, and the
indexer reads it then, once.

## How it reads a drawing

- **PDF:** PDFium (through pypdfium2) reads its metadata (the plot's Title), page count, the first page's paper size
  and text, and renders the first page for the thumbnail. The Dropbox content hash is worked out from the bytes, so
  the Duo can tell which drawings it already has (it names cached PDFs by that hash).
- **DWG title block attributes: AutoCAD's own core console (`accoreconsole.exe`).** AutoCAD is already on the laptop,
  and ADR-0007 plots with the same console, so nothing else is installed. For each DWG the indexer copies the file to
  its work folder, runs `accoreconsole /i <copy> /s <script>` at below-normal priority with a 3-minute limit, and a
  small AutoLISP routine writes every block insert that carries attributes (layout, block, tag, value) to a text
  file, which the indexer reads back. AutoCAD never opens the file in the project folder, so its `.dwl` lock files
  land in the work folder, and nothing is saved. The newest `C:\Program Files\Autodesk\AutoCAD*\accoreconsole.exe` is
  used, or the one `accoreconsole` names. With no AutoCAD, DWGs are listed with their fields from their PDF; they are
  read again once AutoCAD is there. The console takes a few seconds a drawing, so a first scan of thousands of DWGs
  takes hours; it runs in the background and carries on after a restart.
- **The title block** is the insert whose attribute tags name the most fields (`DWG_NO`, `DWGNO`, `DRAWING_NUMBER`,
  `SHEET_NO`; `TITLE`, `TITLE1`..`TITLE3`, `DWG_TITLE`; `REV`, `REVISION`; `SCALE`; `DATE`, and more), a paper space
  layout before Model space. `title_block_tags` adds tags.
- **Fields** come from the DWG's attributes first; any the DWG lacks come from the paired PDF's first page text,
  read by its labels (`DWG NO`, `REV`, `SCALE`, `DATE`, `TITLE`, the value beside or below); a drawing number still
  missing comes from a file name that looks like one (`M-101`).
- **Thumbnail:** the PDF's first page, 128 pixels on its long side (the Duo's search rows are 62 x 42 points at most:
  124 x 84 pixels at 2x). A DWG with no PDF uses the preview AutoCAD saves in its header (PNG or BMP), if it has one.
  Thumbnails are named by their bytes, so an unchanged drawing never writes a new one.

### Pairing a PDF with its DWG

The first rule that finds a DWG wins; each PDF pairs with at most one DWG.

1. **Plot metadata:** the PDF's Title (AutoCAD sets it to the drawing and often its layout: `M-101-Layout1`) names a
   nearby DWG's stem, alone or followed by a separator (` - `, `-`, `_`, space) and more.
2. **Same name:** the PDF's name is a nearby DWG's name, alone or followed by a separator and more
   (`M-101 - Layout1.pdf`, `M-101_Rev C.pdf`).
3. **Same drawing number:** the number from the PDF's text is the number from exactly one DWG's attributes in the
   same project (letters and digits only: `E 201` is `E-201`).

Nearby: the two folders meet at most two folders up from each, inside the same project folder. The longest matching
stem wins, then the nearest DWG, then the first by path. A DWG with several PDFs shows the newest; the rest are in its
entry's `otherPdfs`. A PDF with no DWG is listed as "PDF only, no DWG"; a DWG with no PDF as having none yet.

### The project

Under a projects root (`/Projects` by default), the project is the root's top folder. Elsewhere it is the folder
holding the drawing's discipline and format folders: walking up past folders named like `DWG`, `CAD`, `PDF`, `Plots`,
`Mechanical`, `Electrical`, `Issued`, `Rev C`, the first other folder is the project. A drawing at Dropbox's top has
none.

## Gentle on the laptop

- Windows background mode (low CPU, disk and memory priority) for the indexer, below-normal priority for AutoCAD's
  console; one file read at a time.
- On start it lists Dropbox (sizes, times and attributes only) and reads only files whose size, modified time or
  online-only state changed since the state file last saw them. Each file's result is committed as it is read, so a
  first scan stopped part way carries on where it stopped. Progress goes to the log every 30 seconds, and a long
  first scan publishes what it has every 10 minutes.
- Then it watches Dropbox (watchdog, `ReadDirectoryChangesW`), and gathers changes until Dropbox has been quiet for 2
  seconds (at most 30), so copying a folder of drawings is one update. A full stat-only rescan runs every 6 hours in
  case a notification was lost.
- It writes to Dropbox only what changed: the project shard that changed, new thumbnails and a small manifest; a
  rescan with nothing changed writes nothing. Timings and counts are in
  [`docs/perf/baselines/laptop-indexer.json`](../docs/perf/baselines/laptop-indexer.json).

## Dependencies

All permissively licensed, pinned in `pyproject.toml`, with every transitive pin in `requirements.lock` (run) and
`requirements-test.lock` (tests), made with `uv pip compile --universal`.

| Package | Licence | Why |
|---|---|---|
| [pypdfium2](https://github.com/pypdfium2-team/pypdfium2) 5.15.0 (bundles PDFium) | Apache-2.0 or BSD-3-Clause; PDFium BSD-3-Clause | PDF metadata, text, paper size and thumbnails |
| [Pillow](https://python-pillow.org) 13.0.0 | MIT-CMU (HPND) | PNG thumbnails, DWG preview bitmaps |
| [watchdog](https://github.com/gorakhargosh/watchdog) 7.1.0 | Apache-2.0 | watching Dropbox |
| Tests only: pytest 9.2.0 (MIT), ezdxf 1.4.5 (MIT; with numpy BSD-3-Clause, fonttools MIT, pyparsing MIT, typing-extensions PSF-2.0), ruff 0.17.4 (MIT) | | made-up DXF title blocks, lint |

PyMuPDF was passed over (AGPL). AutoCAD is Zach's own licensed install and is not a dependency of this code.

## Tests

```sh
cd laptop
python -m pip install -r requirements-test.lock && python -m pip install --no-deps -e .
python -m pytest
python -m ruff check src tests scripts
python scripts/bench.py           # timings on a made-up 5,000-file Dropbox
python scripts/make_fixture_index.py   # rebuilds tests/fixtures/drawing-index
```

Every drawing in the tests is made up by the tests: PDFs written by hand, DXF title blocks made with ezdxf standing in
for DWGs, DWG headers with made-up previews, and a stand-in for `accoreconsole.exe`. `tests/fixtures/drawing-index` is
a made-up index for the Duo's tests (#68). CI runs all of it on GitHub's Windows runner ("Laptop indexer tests
(Windows)"), including `install.ps1` and `uninstall.ps1` against a made-up Dropbox folder.
