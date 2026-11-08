# The laptop indexer

The **laptop indexer** runs on Zach's Windows laptop. It scans the laptop's Dropbox folder for DWGs and PDFs, pairs
each PDF with the DWG it was plotted from, reads each drawing's title block fields (drawing number, title, revision,
scale, date), makes a thumbnail, and keeps the **drawing index** in `Dropbox\Vellum\Index`, where the Duo reads it
(#68). It starts at logon and watches Dropbox, so a saved PDF is in the index within seconds. When Vellum asks for a
plot of a drawing with no PDF, it plots it with AutoCAD's own core console and keeps the PDF in `Dropbox\Vellum\Plots`
(see "Plotting on request").

It reads the folder the Dropbox desktop app keeps in sync. Only for files Dropbox keeps online-only does it use the
Dropbox API, to download a copy to a scratch folder on the external drive, read it and delete it (see "Online-only
files"). It only reads project files; it never changes, moves or deletes them, and it writes to Dropbox only inside
`Dropbox\Vellum\Index` and `Dropbox\Vellum\Plots`.

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

- `-DropboxAppKey <key>` puts Vellum's Dropbox app key (docs/dropbox.md) in `settings.toml` on the laptop and signs
  the laptop in to Dropbox: it prints Dropbox's page, Zach allows Vellum there, and pastes back the code Dropbox
  shows. That lets it download online-only files. `vellum-indexer sign-in` does the same later; `vellum-indexer
  sign-out` signs out.
- `-ScratchPath E:\Vellum scratch` puts the scratch folder somewhere other than `D:\Vellum indexer\scratch`.
- `-DropboxPath D:\Dropbox` names the Dropbox folder instead of Dropbox's `info.json`.
- `-NoStart` registers the task without starting it.

Uninstall with `laptop\scripts\uninstall.ps1`; add `-Purge` to sign out of Dropbox and delete the state file, log
and settings too. Neither touches `Dropbox\Vellum\Index` or `Dropbox\Vellum\Plots`.

**Updating the installed indexer.** In the checkout it was installed from (`C:\Users\zache\Projects\Vellum` on
Zach's laptop), `git pull`, then run `install.ps1` again with no options (settings.toml and the Dropbox sign-in are
kept): it stops the running task, installs the new version into the same environment, and starts the task again.
`vellum-indexer where` then names the plots folder, and the log's first line names the version (1.1.0 plots on
request).

By hand, from a checkout: `python -m pip install -r laptop\requirements.lock` and `python -m pip install --no-deps
laptop`, then `vellum-indexer where` (prints where everything is), `vellum-indexer scan` (one scan, then exit) or
`vellum-indexer run` (scan, then watch; what the task runs).

## Where things are on the laptop

| What | Where |
|---|---|
| Dropbox folder | from `%APPDATA%\Dropbox\info.json` or `%LOCALAPPDATA%\Dropbox\info.json` (the personal account, else business), unless `--dropbox` or `dropbox_path` names it |
| The index the Duo reads | `<Dropbox>\Vellum\Index\` (`index.json`, `shards\`, `thumbnails\`) |
| Plot requests and answers | `<Dropbox>\Vellum\Plots\requests\` (`<request>.json` from the Duo, `<request>.answer.json` from the laptop) |
| Plots made on request | `<Dropbox>\Vellum\Plots\<project>\` |
| The check-in | `<Dropbox>\Vellum\Plots\laptop.json`, rewritten every 2 minutes while it runs |
| State file | `%LOCALAPPDATA%\Vellum\indexer\state.sqlite` |
| Log | `%LOCALAPPDATA%\Vellum\indexer\indexer.log` (5 MB, three old logs kept) |
| Settings | `%LOCALAPPDATA%\Vellum\indexer\settings.toml` (optional) |
| Work copies of DWGs for AutoCAD | `%LOCALAPPDATA%\Vellum\indexer\work\` (emptied after each drawing) |
| Online-only files being read | `D:\Vellum indexer\scratch\Vellum indexer copies\` (in `scratch_folder`), one `vellum-dl-*` copy at a time, deleted once what was read is saved; AutoCAD's work copy of such a DWG stays there too |
| Dropbox sign-in | the refresh token in Windows Credential Manager ("Vellum laptop indexer"); never in a file, the state file or the log |
| Dropbox app key | `dropbox_app_key` in `settings.toml`, on the laptop only, never in this repository |

`settings.toml`, every key optional:

```toml
dropbox_path = 'D:\Dropbox'           # instead of info.json
dropbox_account = 'business'          # which account in info.json
projects_roots = ['/Projects']        # Dropbox folders whose top folders are projects
exclude = ['/Personal/**', '**/Archive/**']   # globs on Dropbox paths, any case
accoreconsole = 'C:\Program Files\Autodesk\AutoCAD 2026\accoreconsole.exe'
debounce_seconds = 2                  # quiet time before an update
rescan_hours = 6                      # a full, stat-only rescan this often
dropbox_app_key = '<Vellum app key>'  # to download online-only files (install.ps1 -DropboxAppKey)
scratch_folder = 'D:\Vellum indexer\scratch'   # where they are downloaded, read and deleted
scratch_min_free_gb = 5               # leave this much free on that drive; wait rather than fill it
retry_unread_minutes = 10             # try unread online-only files again this often
plot_timeout_minutes = 5              # a plot on request is stopped after this long, and answered failed

[title_block_tags]                    # more attribute tags, per field
number = ['SHT_ID']
title = ['HEADING']
```

## What it scans

All of Dropbox, for `.dwg` and `.pdf` files, except:

- `Dropbox\Vellum` itself (canvases, symbols, the index and plots made on request, which the indexer lists itself);
- Dropbox's own folders (`.dropbox.cache`, `.dropbox`) at any depth;
- temp, lock and backup files: `~$*`, `.~*`, `*.dwl`, `*.dwl2`, `*.bak`, `*.sv$`, `*.tmp`;
- anything `exclude` names.

### Online-only files: downloaded to the external drive, read, and deleted

A Dropbox file set to online-only is a Windows cloud-files placeholder (`FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS`,
`FILE_ATTRIBUTE_RECALL_ON_OPEN` or `FILE_ATTRIBUTE_OFFLINE`). Opening one makes Dropbox download it into the laptop's
Dropbox folder, and across all of Dropbox that could be the whole account. Zach's decision (2026-11-07): download
them to the external drive, read them, and delete the copy.

- The indexer reads each file's attributes from the directory listing, which downloads nothing, and **never opens the
  placeholder**. A change the watcher reports is looked up in its folder's listing too, not with `os.stat`, which on
  Windows opens a handle to the file.
- Right before opening a local file it looks at the file's attributes again, from a fresh listing of its folder, so a
  file made online-only since its change was noticed is downloaded rather than opened.
- It downloads the file through the Dropbox API (`files/download`) straight into its own subfolder of the scratch
  folder, `D:\Vellum indexer\scratch\Vellum indexer copies` by default, never through the Dropbox folder on C:. The
  copy is checked against Dropbox's size and content hash and read like any local file (title block, pairing,
  thumbnail). For a DWG, AutoCAD's work copy goes in that subfolder too, never to C:. What was read is saved to the
  state file first and **then the copy is deleted**, so a crash never downloads it again. Nothing is ever deleted
  from Dropbox or the Dropbox folder, and the placeholder stays online-only.
- **The scratch folder is kept apart from Dropbox.** A scratch folder inside the Dropbox folder, or one that reaches
  it through a junction or symlink (both resolved first), is refused, and the log says so; online-only files then
  stay unread. The indexer deletes only inside the subfolder it made, which carries its marker file
  (`.created-by-vellum-indexer`), never by a name pattern alone: a folder of that name it did not make, and anything
  beside it, is left alone.
- One file at a time, so the subfolder holds one copy at most. Copies and AutoCAD work folders a crash left (in the
  subfolder, and in `%LOCALAPPDATA%\Vellum\indexer\work` for local DWGs) are deleted at the next start. When the
  drive has less than `scratch_min_free_gb` free (5 GB) beyond the file, it waits instead of filling it.
- An online-only file that has not changed (same size and modified time on its placeholder) is never downloaded
  again. One that changes, or is added later, goes the same way.
- Busy answers (429, 5xx) are retried with backoff, honouring `Retry-After`, and so is a download that breaks off part
  way (a reset connection, an incomplete read); a failed download leaves nothing in the scratch folder, keeps the
  file `"read": false`, and is tried again within `retry_unread_minutes`. A file deleted while it waits in the queue
  is dropped from the queue, so it never comes back. The first scan's downloads are resumable through
  the state file.
- **Signing in.** The laptop signs in to Vellum's own Dropbox app (docs/dropbox.md: full Dropbox, `files.content.read`)
  once, with PKCE and no app secret, as the Duo does (ADR-0013): `install.ps1 -DropboxAppKey` or `vellum-indexer
  sign-in` prints Dropbox's page and asks for the code it shows. The refresh token goes to Windows Credential Manager
  through `keyring`; the access token lives only in memory; neither is ever written to a file, the state file or the
  log. The app key lives in `settings.toml` on the laptop, never in this repository. `vellum-indexer sign-out` (and
  `uninstall.ps1 -Purge`) removes the token and asks Dropbox to end the sign-in; if Credential Manager won't let go
  of the token, it says so and exits with an error, after asking Dropbox to end the sign-in anyway.
- **When D: isn't there** (the drive unplugged), the laptop isn't signed in, or the drive is short of space:
  online-only files stay listed by path and name with `"read": false` and their fields unread (a drawing number can
  still come from the file name, and they can still pair by name). The log says why once, not once per file. Local
  files are read as always. Every `retry_unread_minutes` the indexer checks again, and reads them once the drive and
  the sign-in are back.

## How it reads a drawing

- **PDF:** PDFium (through pypdfium2) reads its metadata (the plot's Title), page count, the first page's paper size
  and text, and renders the first page for the thumbnail. The Dropbox content hash is worked out from the bytes, so
  the Duo can tell which drawings it already has (it names cached PDFs by that hash).
- **DWG title block attributes: AutoCAD's own core console (`accoreconsole.exe`).** AutoCAD is already on the laptop,
  and ADR-0007 plots with the same console, so nothing else is installed. For each DWG the indexer copies the file to
  its work folder, runs `accoreconsole /i <copy> /s <script>` at below-normal priority with a 3-minute limit, and a
  small AutoLISP routine writes every block insert that carries attributes (layout, block, tag, value) to a text
  file, which the indexer reads back. AutoCAD never opens the file in the project folder, so its `.dwl` lock files
  land in the work folder, and nothing is saved. The routine is typed into the script itself, one form per line,
  rather than saved as a `.lsp` file and loaded: AutoCAD's `SECURELOAD` (1 by default) asks before loading a file from
  a folder it does not trust, the core console can't answer, and Zach's AutoCAD security settings stay as they are.
  Nothing is loaded, so `SECURELOAD` never asks. The newest `C:\Program Files\Autodesk\AutoCAD*\accoreconsole.exe` is
  used, or the one `accoreconsole` names. With no AutoCAD, DWGs are listed with their fields from their PDF; they are
  read again once AutoCAD is there. The console takes a few seconds a drawing, so a first scan of thousands of DWGs
  takes hours; it runs in the background and carries on after a restart.
- **Title blocks, one per layout.** In each paper space layout the title block is the insert whose attribute tags
  name the most fields (`DWG_NO`, `DWGNO`, `DRAWING_NUMBER`, `SHEET_NO`; `TITLE`, `TITLE1`..`TITLE3`, `DWG_TITLE`;
  `REV`, `REVISION`; `SCALE`; `DATE`, and more); Model space counts only when no layout has one. A DWG with several
  titled layouts (E-201 at 1:20 and E-202 at 1:50 in one file) is several drawings in the index, one per layout, each
  with its own fields and its own PDF. `title_block_tags` adds tags.
- **Fields** come from the DWG's attributes first; any the DWG lacks come from the paired PDF's first page text,
  read by its labels (`DWG NO`, `REV`, `SCALE`, `DATE`, `TITLE`, the value beside or below); a drawing number still
  missing comes from a file name that looks like one (`M-101`).
- **Thumbnail:** the PDF's first page, 128 pixels on its long side (the Duo's search rows are 62 x 42 points at most:
  124 x 84 pixels at 2x). A DWG with no PDF uses the preview AutoCAD saves in its header (PNG or BMP), if it has one.
  Thumbnails are named by their bytes, so an unchanged drawing never writes a new one.

### Pairing a PDF with its DWG

The first rule that finds a DWG wins; each PDF pairs with at most one DWG layout.

1. **Plot metadata:** the PDF's Title (AutoCAD sets it to the drawing and often its layout: `M-101-Layout1`) names a
   nearby DWG's stem, alone or followed by a separator (` - `, `-`, `_`, space) and more.
2. **Same name:** the PDF's name is a nearby DWG's name, alone or followed by a separator and more
   (`M-101 - Layout1.pdf`, `M-101_Rev C.pdf`).
3. **Same drawing number:** the number from the PDF's text is the number from title blocks of exactly one DWG in the
   same project (letters and digits only: `E 201` is `E-201`).

Nearby: the two folders meet at most two folders up from each, inside the same project folder. A wrong pair is worse
than none, since a redline would go to the wrong DWG:

- A name or title match whose title block numbers contradict (the PDF's text says `E-201-1`, the DWG's title block
  `E-201`) is no match.
- The longest matching stem wins, then the nearest DWG. Two DWGs equally near are told apart by the PDF's drawing
  number; when it can't tell them apart, the PDF stays unpaired, "PDF only, no DWG".

Within a DWG with several layouts, a PDF pairs with the layout its metadata title, else its file name, names after
the DWG's name (AutoCAD's `Power-E-202`), else the layout with its drawing number. When none of those picks one, the
PDF pairs with the DWG itself and takes no layout's fields, so no wrong scale: a guessed layout would bring one. A layout with several
PDFs shows the newest; the rest are in its entry's `otherPdfs`. A PDF with no DWG is listed as "PDF only, no DWG"; a
DWG layout with no PDF as having none yet.

### The project

Under a projects root (`/Projects` by default), the project is the root's top folder. Elsewhere it is the folder
holding the drawing's discipline and format folders: walking up past folders named like `DWG`, `CAD`, `PDF`, `Plots`,
`Mechanical`, `Electrical`, `Issued`, `Rev C`, the first other folder is the project. A drawing at Dropbox's top has
none.

## Plotting on request

Opening a DWG with no PDF on the Duo writes a plot request to `Dropbox\Vellum\Plots\requests`; the indexer plots it
and answers beside it. The format, the answers, the naming and the cleanup are
[`docs/plot-requests.md`](../docs/plot-requests.md), decided in
[ADR-0018](../docs/adr/0018-plot-requests-are-files-answered-beside-them.md).

- **Seen within seconds.** A thread of its own answers a new request `queued` the moment it is seen: the watcher
  tells it when Dropbox writes one (a request is not debounced), and it lists the requests folder every 2 seconds
  anyway, since a change notice can be lost. It never waits for a read or plot in progress. Requests then go ahead
  of everything the scan is waiting to read, between any two files and every 256 files of a listing, so even during
  a first scan of hours a request is plotted as soon as the read in progress ends.
- **Checked against the index.** A request must name an entry the index holds, by its `id`, DWG path and layout; the
  plot then uses only the index's own path and layout name. Every string in it must be valid Unicode with no control
  characters and a sane length. A malformed or unknown request is answered `failed` with the reason, and no request,
  however made, stops the indexer.
- **On a copy, with its own page setup.** The DWG is copied to a job folder in `%LOCALAPPDATA%\Vellum\indexer\work`
  (an online-only DWG is downloaded to the scratch folder and plotted there, then the copy deleted), and the core
  console runs `-PLOT` on the layout at below-normal priority, stopped after 5 minutes: with the layout's saved
  plotter, paper, area, scale and plot style when that plotter writes PDFs (a `.pc3` with PDF in its name), so the PDF
  is what AutoCAD prints. A layout with no such page setup is plotted again with `DWG To PDF.pc3` on the sheet that
  matches its paper size, its layout area at 1:1, and the answer says so. The plot answers "No" to saving its
  settings, and the console quits without saving; the DWG in the project folder is never opened.
- **References still found.** Before plotting, the script makes the copy's relative xref, raster image and PDF, DWF
  or DGN underlay paths absolute against the original DWG's folder, on the copy only, so the PDF has them. References
  still not found are counted, and the `done` answer says so ("2 references couldn't be found").
- **One at a time,** oldest first, one plot a turn: after each plot the watcher's changes and the next file to read
  come first, so a backlog of plots never holds up the index. The same layout asked for again with its DWG unchanged
  gets the PDF already made.
- **Kept in `Dropbox\Vellum\Plots\<project>\`**, named `<DWG name> - <layout> - <DWG saved> - <8 hex>.pdf`, read as any
  PDF (content hash, pages, paper size, thumbnail), and listed as the entry's `pdf` with `pairedBy` `plotted` before the
  answer says `done`. The 8 hex digits cover the DWG's bytes, so a re-plot of a changed DWG is a new file even
  within the same second, and the older plot moves to `otherPdfs`. A plot made before the DWG's layouts were read
  moves to the right layout's entry once they are. The indexer never deletes a plot, nor a request; it deletes an
  answer an hour after it first sees the Duo has deleted its request.
- **The check-in,** `Dropbox\Vellum\Plots\laptop.json`, is rewritten every 2 minutes on a thread of its own, so the Duo
  can say "Waiting for the laptop" when it is more than 5 minutes old.

## Gentle on the laptop

- Windows background mode (low CPU, disk and memory priority) for the indexer, below-normal priority for AutoCAD's
  console; one file read at a time.
- On start it lists Dropbox (sizes, times and attributes only) and reads only files whose size, modified time or
  online-only state changed since the state file last saw them. Each file's result is committed as it is read, so a
  first scan stopped part way carries on where it stopped. Progress goes to the log every 30 seconds, and a long
  first scan publishes what it has every 10 minutes. It reads PDFs before DWGs (a PDF takes a moment, a DWG a few
  seconds in AutoCAD), so every plotted drawing is searchable early, and it takes the watcher's changes between
  files, so a PDF saved during a first scan of hours is still in the index within seconds.
- Then it watches Dropbox (watchdog, `ReadDirectoryChangesW`), and gathers changes until Dropbox has been quiet for 2
  seconds (at most 30), so copying a folder of drawings is one update, and each file in it is read once however many
  events reported it. A full stat-only rescan runs every 6 hours in case a notification was lost.
- The scan and the watcher share one collector and one work queue. The queue reads one file at a time and, between
  files, takes the watcher's newest changes ahead of the rest, PDFs first, publishing them as soon as they are read:
  a PDF saved while hundreds of copied DWGs wait for AutoCAD is in the index within seconds. A folder that can't be
  listed for a moment (a sharing violation) keeps its drawings, in the scan and the watcher alike.
- With no state file (after `uninstall.ps1 -Purge`, or on a new laptop) it carries on from the generation of the
  index already in `Dropbox\Vellum\Index`, and shards and thumbnails that come out the same are not written again.
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
| [keyring](https://github.com/jaraco/keyring) 25.7.0 (with jaraco.classes, jaraco.context, jaraco.functools, more-itertools: MIT; pywin32-ctypes on Windows: BSD-3-Clause; SecretStorage BSD-3-Clause, jeepney MIT, cryptography Apache-2.0 or BSD-3-Clause, cffi MIT, pycparser BSD-3-Clause on Linux) | MIT | the Dropbox refresh token in Windows Credential Manager |
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
for DWGs, DWG headers with made-up previews, stand-ins for `accoreconsole.exe` (reading title blocks, and plotting:
`tests/fake_plot_console.py` reads a made-up DXF's saved page setup and writes a made-up PDF), and a scripted Dropbox API (made-up
tokens, no network) for online-only downloads. `tests/fixtures/drawing-index` is
a made-up index for the Duo's tests (#68). CI runs all of it on GitHub's Windows runner ("Laptop indexer tests
(Windows)"), including `install.ps1` and `uninstall.ps1` against a made-up Dropbox folder.
