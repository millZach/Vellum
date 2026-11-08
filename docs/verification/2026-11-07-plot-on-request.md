# Plotting on request (#67)

November 7, 2026, on `feat/plot-on-request`. Every drawing, request and PDF here is made up; nothing comes from Zach's
Dropbox or the private automated-drawing-generator (ADR-0004).

## What CI and Forge proved

- **pytest on Forge** (Linux, Python 3.12): 221 passed, 1 skipped (the credential store test, which needs Windows
  Credential Manager). `ruff check src tests scripts`: clean. CI runs the same on `windows-latest` (the PR names the
  run).
- **The new tests** (`laptop/tests/test_plot_requests.py`), through `tests/fake_plot_console.py`, a stand-in for
  `accoreconsole.exe` that reads a made-up DXF's saved page setup with ezdxf and writes a made-up PDF:
  - **Requests decode and refuse:** a good request, and each way one is refused with its reason: another format, an id
    that isn't an entry's, a path not starting `/`, not a DWG, with `..`, `.` or `\`, too long, a layout of the wrong
    type, no `asked`, unreadable bytes, over 4 KB. A half-written request under 10 s old waits and is looked at again
    in 2 s. Which file names are requests (answers, `~$` temps and odd names are not).
  - **The state machine:** answered `plotting` then `done`; not plotted again once answered, nor after a restart; one
    answered only `plotting` (a stop part way) is plotted again; asked twice (and a third time once plotted), plotted
    once.
  - **Page setups:** a layout saved with `DWG To PDF.pc3` takes one console run with its own setup; one with no
    plotter (A3) takes the fallback, DWG To PDF on `ISO full bleed A3`, millimetres, landscape, and the answer says
    so; a paper size DWG To PDF hasn't got fails rather than guess. The script types only what the indexer chose,
    answers "No" to saving the page setup, and a layout name with a quote, backslash or control character is refused.
  - **Failures:** a hung console stopped at its limit and answered "timed out: …"; a console that makes no PDF, or
    something that isn't one; no AutoCAD; a request for a DWG or layout the index doesn't hold, or with a mismatched
    id, refused before AutoCAD starts. The job folder is emptied either way.
  - **Jumping the queue:** a request written while the scan reads twenty DWGs is answered before the next DWG; one
    seen during a first scan's listing of 300 PDFs is answered before any of them is read.
  - **Online-only:** an online-only DWG is downloaded to the scratch folder, plotted there and the copy deleted; with
    the drive unplugged the answer says why.
  - **Where the PDF goes and the index:** the name (project, DWG name, layout, the DWG's saved time, 8 hex; two layouts,
    two folders and a changed DWG never clash; Windows' reserved characters and names); the entry's `pdf` becomes the
    plot with `pairedBy` `plotted`, its content hash, paper size and a thumbnail; a re-plot of a changed DWG takes the
    place and the older plot moves to `otherPdfs`; a plot deleted by hand leaves the index.
  - **The check-in** is written whole on its own thread and kept fresh, holding only `format`, `seen`, `indexer`,
    `every` and `staleAfter`.
  - **Cleanup** keeps every request, answered or not, and deletes only an answer an hour after its request is gone.
  - **Nothing outside `Dropbox/Vellum`:** a plot and three hostile requests (paths climbing out of Dropbox, a layout
    carrying a command) change nothing outside `Dropbox/Vellum/Plots`, `Dropbox/Vellum/Index` and the indexer's own
    folder, and no project file.
  - **The watcher**, with real watchdog: a request dropped while it runs is answered `done` within seconds, and the
    check-in keeps being rewritten. On the Windows runner the watcher's notice for a request did not come, so the
    acknowledger also lists the requests folder every 2 seconds; a unit test shows which events wake it.
- **Review round 2** (each test below failed against the code at dc399f0 and passes now):
  - **References:** a made-up DWG with a relative xref (`..\Xrefs\base.dwg`, there), a relative image (missing) and
    an underlay in its own folder: the script is handed the original's folder, not the job folder; the answer is
    `done` with `missingReferences` 1 and "1 reference couldn't be found, so the PDF is missing it"; the original
    and its folder are unchanged. An online-only DWG's references are found from its Dropbox folder, not scratch.
  - **Queued during a long read:** while a stalled read holds the indexer, a new request is answered `queued` and
    nothing is plotted; once the read ends it is plotted and answered `done`. The acknowledger answers garbage
    `failed` and never writes over an answer already there.
  - **A plot backlog:** three requests whose consoles all time out take one plot a turn, and in a scan a file is
    read between plots (plot, read, plot, read).
  - **Malformed strings:** a lone surrogate and a NUL in the path, and a 10,000-character path, are answered `failed`
    and the next request is still plotted; a layout, `asked` and `id` are checked the same way; an unexpected error
    while handling one request is answered `failed` and the next is plotted.
  - **The same second:** a DWG plotted, changed and plotted again within one second gives two PDFs; the older
    stays, in `otherPdfs`.
  - **A layout found later:** a DWG plotted while its title blocks were unread keeps its plot when a later read
    finds its layouts: on its one layout, or on the layout AutoCAD plotted of two.
  - **Cleanup:** a day-old answer whose request has just gone stays for an hour from then.
- **The Model tab and answers out of step (#87)** (each test failed against the code at 126827a and passes now):
  the stand-in console walks the script's `-PLOT` answers through AutoCAD 2026's prompts, which differ on the Model
  tab, and cancels an answer out of step without writing `PLOTTED`, then sits as the real console did. A Model-tab DWG
  through the fallback is plotted, its extents at 1:1, with exactly the Model tab's answers; a paper layout's fallback
  answers are unchanged; the Model tab given the paper layout's answers is answered `failed` within seconds with the
  plain reason, not "timed out"; a console that writes `END` and does not quit is stopped and its PDF kept.
- **Budgets** (`docs/perf/baselines/laptop-indexer.json`, read by those tests): one plot writes 7 files to Dropbox (the
  PDF, the answer three times: queued, plotting, done; a shard, a thumbnail, the manifest; raised from 6 for the
  queued answer); 1 console run with a page setup, 2 for the fallback;
  asked twice, plotted once; 30 check-in writes an hour.
- **Timing** (`scripts/bench.py`, on the made-up 5,000-file Dropbox): from the laptop seeing a request to its `done`
  answer, 0.43 s on Forge, of which 0.26 s in the stand-in console and 0.17 s the indexer's own work, mostly
  publishing the index. On `windows-latest` (run 42453869932, the baseline): 0.85 s, of which 0.48 s in the
  stand-in console and 0.37 s the indexer's own. On the laptop, add AutoCAD's own plot.

## The hand test on the laptop

After merge, by the manager, on Zach's laptop with the installed indexer (`C:\Users\zache\Projects\Vellum`, task
`\Vellum\Vellum laptop indexer`). Unchecked until done.

- [ ] Update the installed indexer: `git pull` in `C:\Users\zache\Projects\Vellum`, then
      `powershell -ExecutionPolicy Bypass -File laptop\scripts\install.ps1` in Zach's own PowerShell (task
      registration needs his logon session). The log's first new line says `Vellum laptop indexer 1.1.1` (1.1.0
      before #87), and
      `vellum-indexer where` names the plots folder.
- [ ] The check-in: `Dropbox\Vellum\Plots\laptop.json` appears within seconds of the start. Note its `seen`; two to
      three minutes later it has moved on.
- [ ] Pick a real DWG with no PDF from the index (an entry in a shard of `Dropbox\Vellum\Index` with a `dwg` and
      `"pdf": null`). Drop a made-up request for it in `Dropbox\Vellum\Plots\requests\`, a file named
      `A0000000-0000-4000-8000-000000000001.json` holding
      `{"format": 1, "id": "<the entry's id>", "path": "<its dwg.path>", "layout": <its layout, quoted, or null>,
      "asked": "2026-11-07T12:00:00Z"}`.
- [ ] Within seconds `A0000000-0000-4000-8000-000000000001.answer.json` says `queued` or `plotting`, then `done` with
      a `pdf` under `/Vellum/Plots/<project>/`. Note its `pageSetup`: `saved`, or `fallback` with the reason, and its
      `missingReferences`.
- [ ] The PDF is in `Dropbox\Vellum\Plots\<project>\`, and opened it is what AutoCAD's Plot dialog prints for that
      layout (paper, scale, plot style). The DWG in the project folder is unchanged (its modified time) and has no
      `.dwl` beside it.
- [ ] The index lists it: the entry's `pdf.path` is the plot, `pairedBy` is `plotted`, it has a thumbnail.
- [ ] A DWG with a relative xref: pick a real DWG with no PDF whose xref is attached with a relative path (AutoCAD's
      External References palette shows its saved path starting `.\` or `..\`), and request it as above. The PDF
      shows the xref's linework as AutoCAD's own plot does, `missingReferences` is 0, and the DWG's modified time is
      unchanged. If the DWG has an image or underlay with a relative path, check it shows too. If something is
      missing, note what the answer's `warning` says and what the log says.
- [ ] A DWG saved on the Model tab (#87): pick a real DWG with no PDF whose index entry's layout is `Model` and
      whose Model tab has no PDF plotter saved, and request it as above. Within a minute the answer is `done`,
      `pageSetup` `fallback`, with the reason "the Model tab has no page setup that plots to PDF, so its extents were
      plotted with DWG To PDF at 1:1", and the PDF holds the model's extents at 1:1 on the DWG To PDF sheet for the
      Model tab's paper (a large model can run off the sheet: that is the 1:1 Zach chose). If AutoCAD asks something
      else the answer is `failed`, "AutoCAD stopped at a question the laptop didn't expect while plotting", within
      seconds, never "timed out", and the log names AutoCAD's message.
- [ ] A request for a bad path (`"path": "/Projects/Nowhere/X-1.dwg"`, any 16 hex digits as `id`) is answered `failed`,
      "the drawing isn't in the drawing index".
- [ ] Delete the two test requests by hand (as the Duo would); their answers are deleted an hour later.
- [ ] If a fallback was hit, or a plot failed, the log (`%LOCALAPPDATA%\Vellum\indexer\indexer.log`) says why.

The PDFs and DWGs on the laptop are Zach's client drawings: none of them, their names or their paths go into this
repository, the PR or the issue. The results say "a DWG with no PDF in project X" in made-up words.
