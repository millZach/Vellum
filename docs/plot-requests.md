# Plot requests, format 1

The Duo (#70) writes a plot request; the laptop indexer (`laptop/`, #67) plots the drawing with AutoCAD's own
`accoreconsole` and answers. Why it is shaped this way: [ADR-0018](adr/0018-plot-requests-are-files-answered-beside-them.md).
Every example here is made up.

## Files

```
Dropbox/Vellum/Plots/
  laptop.json                                 the laptop's check-in
  requests/<request>.json                     a plot request, written by the Duo
  requests/<request>.answer.json              the laptop's answer to it
  <project>/<plot>.pdf                        the plots themselves (below)
  ~$*.tmp, requests/~$*.tmp                   a file being written; ignore
```

All JSON is UTF-8. Paths are Dropbox paths as in the drawing index (`docs/drawing-index-format.md`): from the Dropbox
root, starting `/`. Times are UTC, `YYYY-MM-DDTHH:MM:SSZ`. Both sides ignore keys they do not know.

## A request

`<request>` is the request's own id, a fresh random UUID per tap (`6F1C2B9A-0D3E-4A5B-8C7D-1E2F3A4B5C6D`), so two Duos
or two taps never write the same file. The laptop takes as a request only a name of 8 to 64 letters, digits and
hyphens, starting with a letter or digit, ending `.json` and not `.answer.json`.

```json
{
 "format": 1,
 "id": "dd0bdad0ab9b9082",
 "path": "/Projects/Made-up Plant Upgrade/CAD/E-202.dwg",
 "layout": "Layout1",
 "asked": "2026-11-07T12:00:00Z"
}
```

| Key | Meaning |
|---|---|
| `format` | 1. The laptop answers any other number `failed`. |
| `id` | The drawing index entry's `id`. |
| `path` | The entry's `dwg.path`. |
| `layout` | The entry's `layout`, or `null` (a DWG whose title blocks are not read yet: the layout it was saved on is plotted). |
| `asked` | When Zach asked, on the Duo's clock. |

A request is at most 4 KB. The Duo writes it once and never changes it (`files/upload`, mode `add`).

**What the laptop trusts.** Nothing in a request is used to plot. The laptop looks the DWG up in its own index by
`path`, and goes ahead only when that DWG has a layout with exactly this `layout` whose entry `id` is this `id`. From
then on it uses only the path and layout name its index holds, so nothing from a request reaches AutoCAD's script,
and nothing outside Dropbox is plotted. A path with `..`, `.` or `\` in it, or one not ending `.dwg`, is refused
before it is looked up.

## An answer

`requests/<request>.answer.json`, written by the laptop, rewritten as the state moves on, always whole (written to a
`~$` temp file and renamed over the old one, as the index is):

```json
{
 "format": 1,
 "request": "6F1C2B9A-0D3E-4A5B-8C7D-1E2F3A4B5C6D",
 "id": "dd0bdad0ab9b9082",
 "state": "done",
 "updated": "2026-11-07T12:00:09Z",
 "pdf": "/Vellum/Plots/Made-up Plant Upgrade/E-202 - Layout1 - 2026-09-21 141500 - 5c0e1d2a.pdf",
 "contentHash": "85a8840345de4e26c4bff449341350969d9599d516462abb9940cd750debaeda",
 "pageSetup": "saved",
 "reason": null,
 "missingReferences": 0,
 "warning": null
}
```

| Key | Meaning |
|---|---|
| `state` | `queued`, `plotting`, `done` or `failed` (below). |
| `request`, `id` | The request's id, and the entry's `id` (`null` when the request could not be read at all). |
| `updated` | When the laptop wrote this state. |
| `pdf`, `contentHash` | On `done`: the PDF's Dropbox path and its Dropbox content hash, as the index lists it. Else `null`. |
| `pageSetup` | On `done`: `saved` when the layout was plotted with its own page setup, `fallback` when with DWG To PDF at its paper size (below). Else `null`. |
| `reason` | On `failed`, why, in plain words to show Zach as it is. On a `fallback` `done`, a sentence saying so. Else `null`. |
| `missingReferences` | On `done`: how many of the DWG's xrefs, raster images and PDF, DWF or DGN underlays couldn't be found, so are missing from the PDF (0 when all were found). Else `null`. |
| `warning` | On `done` with references missing, a sentence to show Zach as it is: "2 references couldn't be found, so the PDF is missing them". Else `null`. The PDF is still the layout's plot. |

### The states

| State | Seen on the Duo as | Means |
|---|---|---|
| no answer yet | "Asking the laptop…", or "Waiting for the laptop" when the check-in is stale | The request is in Dropbox; the laptop has not seen it. |
| `queued` | "Plotting on the laptop" | The laptop has seen the request and will plot it once what it is doing ends (a long read of another DWG, or another plot). Written within seconds of the request arriving, whatever else the laptop is doing. |
| `plotting` | "Plotting on the laptop" | The laptop has checked the request against its index and is plotting it now. |
| `done` | the PDF opens | The PDF is in `Dropbox/Vellum/Plots` and the drawing index already lists it as the entry's `pdf`: the laptop publishes the index before it writes `done`. |
| `failed` | the reason | It will not be plotted. Asking again is a new request. |

The Duo's own "Queued on this Duo" (offline, the request not uploaded yet) is the Duo's alone and never reaches
Dropbox.

Reasons the laptop gives, among others: "AutoCAD isn't installed on the laptop", "the DWG couldn't be read", "the
layout isn't in the DWG any more", "the layout has no page setup that plots to PDF, and its paper size (500 x 700 mm)
isn't one DWG To PDF has", "timed out: AutoCAD took longer than 5 minutes, so the plot was stopped", "the drawing
isn't in the drawing index", "the request doesn't match the drawing index (the drawing's layouts may have changed)",
"the DWG is online-only, and the laptop can't download it now: …", "the request couldn't be read".

### How the laptop works through requests

- It makes `requests/` at start if it is not there. A thread of its own answers each new request `queued` the moment
  it is seen: when the watcher sees one arrive (within half a second of Dropbox writing it), and from a listing of
  the folder every 2 seconds anyway, since a change notice can be lost. It never waits for a read or a plot in
  progress, and it never writes over an answer already there. A request that can't be read at all is answered
  `failed` there and then.
- The indexer then plots requests ahead of everything the scan is waiting to read, even during a first scan's
  listing of all of Dropbox, so one is plotted as soon as the read in progress ends (a few seconds, at most that read's
  3-minute limit).
- One plot at a time, oldest request first, through AutoCAD's console at below-normal priority, stopped after 5
  minutes (`plot_timeout_minutes`). After each plot the watcher's changes and the next file to read come first, so a
  backlog of plots never holds up the index: ten plots that each time out cost the index ten reads' delay, not 50
  minutes.
- Every string in a request is checked before it is used: valid Unicode (no lone surrogate, which JSON's `\ud800`
  escape can make), no control characters, `path` at most 1024 characters and `layout` at most 255. Anything else is
  answered `failed` with the reason. No request, however made, stops the indexer: an error handling one is answered
  `failed` ("the laptop couldn't handle this request") and the next is taken.
- A request with a `done` or `failed` answer is never plotted again. One answered only `plotting` (the laptop stopped
  part way) is plotted again.
- The same layout asked for again while its DWG is unchanged gets the PDF already plotted, without plotting again.
- A request that does not parse yet and is under 10 seconds old is left for a moment, in case it is still arriving;
  after that it is answered `failed`.

## The plot

- AutoCAD's console plots a copy of the DWG, never the file in the project folder, in the indexer's work folder on
  the laptop (`%LOCALAPPDATA%\Vellum\indexer\work`). An online-only DWG is downloaded to the scratch folder on the
  external drive first (Zach's E:), plotted there and the copy deleted, as reading one is. Nothing is ever saved into
  the DWG: the plot answers "No" to saving its settings to the page setup, and the console quits without saving.
- **Its own page setup.** The layout is plotted with its saved plotter, paper, area, scale and plot style, which is
  what AutoCAD's Plot dialog prints, when its saved plotter writes PDFs (a `.pc3` with PDF in its name, such as
  `DWG To PDF.pc3`). A saved printer is never used, so a plot never sends paper to a printer.
- **The fallback.** A layout whose saved plotter is not a PDF one (None, or a printer) is plotted with
  `DWG To PDF.pc3` on that plotter's sheet that matches the layout's paper size (ANSI A to E, ARCH A to E1, ISO A4
  to A0, within 2 mm either way round), the layout's area at 1:1, its plot style kept. The answer's `pageSetup` is
  `fallback` and its `reason` says so. A paper size none of those sheets match fails, rather than guess a scale.
- **References.** The copy is in a job folder, so a reference saved with a relative path would not resolve there.
  Before plotting, the script makes each top-level xref's, raster image's and PDF, DWF or DGN underlay's relative
  path absolute against the original DWG's folder in Dropbox (for an online-only DWG too, not the scratch folder), on
  the copy only: xrefs with `-XREF Path`, images and underlays by changing their definition, then images reloaded. A
  path is relative unless it starts with a drive (`C:`), `\` or `/`. Nested xrefs resolve from their parent's path,
  now absolute. The original is never changed, nothing is written beside it, and the copy is never saved. Each
  reference is then checked (an xref resolved, a file found), and any still missing are counted in the answer's
  `missingReferences` and `warning`; the answer is still `done`.

## Where a plot goes

`/Vellum/Plots/<project>/<DWG name> - <layout> - <DWG saved> - <8 hex>.pdf`, never beside the original:

- `<project>` is the drawing's project in the index, or `No project`.
- `<DWG name>` is the DWG's name less `.dwg`; `<layout>` its layout (left out for a `null` layout).
- `<DWG saved>` is the DWG's modified time, UTC, `YYYY-MM-DD HHMMSS`, to read at a glance.
- `<8 hex>` is the first 8 hex digits of the SHA-256 of the DWG's path in lower case, `#`, the layout in lower case,
  `#` and the SHA-256 of the DWG's bytes: two DWGs of one name in different folders of a project never clash, and a
  re-plot of a changed DWG is a new file beside the older plot, never over it, even when both were saved within the
  same second.
- Characters Windows or Dropbox refuse (`<>:"/\|?*` and control characters) become `_`; leading dots and `~$`, and
  trailing dots and spaces, are dropped; reserved names (`CON`, `NUL`, …) get a leading `_`.

Example: `/Vellum/Plots/Made-up Plant Upgrade/E-202 - Layout1 - 2026-09-21 141500 - 5c0e1d2a.pdf`.

**In the index** (no format change): the plot is the entry's `pdf`, `pairedBy` `"plotted"`, with its content hash,
pages, paper size and a thumbnail as for any PDF. The newest PDF of a layout is its `pdf`, so a re-plot of a changed
DWG takes the older plot's place and the older one moves to `otherPdfs`. A plot deleted from `Dropbox/Vellum/Plots`
leaves the index at the next scan. The laptop never deletes a plot.

A plot made for an entry with a `null` layout (its title blocks not read yet) stays when a later read finds the DWG's
layouts. It becomes the plot of the layout AutoCAD plotted (the one the DWG was saved on), else the DWG's one layout,
else the layout with the plot's drawing number, else the DWG's own entry with no layout's fields. It is never
dropped while its DWG is there.

## The check-in

`Dropbox/Vellum/Plots/laptop.json`, rewritten every 2 minutes while the indexer runs (on its own thread, so a long
plot or a long listing never holds it up), written whole as the index is:

```json
{"every": 120, "format": 1, "indexer": "1.1.0", "seen": "2026-11-07T12:00:00Z", "staleAfter": 300}
```

It holds only a time, the interval and the indexer's version: nothing about any drawing.

**The staleness rule for the Duo:** the laptop is off, and a request with no answer shows "Waiting for the laptop",
when the check-in is older than `staleAfter` seconds (300: two intervals and a minute for Dropbox to sync). Measure
its age by the file's `server_modified` in its Dropbox metadata, which is Dropbox's clock, not the laptop's, against
the Duo's own clock; `seen` is for a person reading the file. No check-in at all means the laptop has never run the
plotting indexer.

Two minutes is 30 uploads of about 100 bytes an hour, which Dropbox does not notice, and lets the Duo say the laptop
is off within five minutes of it going off. Every 30 seconds would tell sooner but upload four times as often for a
state that rarely changes; every 10 minutes would leave a plot request looking merely slow for up to 21 minutes.

## Cleaning up

- **The Duo deletes its own request** (`files/delete_v2`) once it has read a `done` or `failed` answer. That is how
  the laptop knows the answer was seen.
- **The laptop never deletes a request**, answered or not.
- **The laptop deletes an answer an hour after it first sees its request gone**, however old the answer is, so a
  second Duo part way through reading it still finds it. When a request was first seen gone is kept in memory, so
  after a restart the hour starts again: an answer is kept longer, never shorter.
- Plots in `Dropbox/Vellum/Plots` are kept; they are Zach's to delete.

A request whose Duo never came back for its answer (a reinstalled app) stays with its answer: two files of a few
hundred bytes, safe to delete by hand.

## Changing the format

As the index's: adding a key or a reason is not a new format. Removing a key, changing its meaning, a new state or
another way of naming files is format 2, in a new ADR, with the laptop updated to read it before the Duo writes it.
