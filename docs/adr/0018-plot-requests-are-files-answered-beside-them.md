# Plot requests are small files in Dropbox/Vellum/Plots, answered beside them, with a check-in

ADR-0007 has Vellum ask for a plot by writing a request to `Dropbox/Vellum`, which the laptop indexer answers without
a Sotto thread, and keeps the PDF in `Dropbox/Vellum`, never beside the original. Zach's decisions on #13
(2026-11-06): a DWG with no PDF opens a waiting state on the Duo, "Plotting on the laptop", "Waiting for the laptop"
when it's off, or queued while the Duo is offline, filled in when the PDF arrives; the indexer runs always on, so a
request is answered within seconds while the laptop is on. The laptop (#67) and the Duo (#70) are built in two
tickets, in two languages, so the request format is a lasting decision of its own.

## The decision

Plot request format 1, set out in `docs/plot-requests.md`:

- **One file per request,** `Dropbox/Vellum/Plots/requests/<UUID>.json`, a fresh UUID per tap, so two Duos or two taps
  never collide and Dropbox never has two writers for one file. It names the index entry's `id`, its DWG's `path`, its
  `layout`, when it was asked, and the format.
- **The laptop answers beside it,** `<UUID>.answer.json`: `queued` the moment it is seen, on a thread of its own so
  no read or plot in progress delays it, then `plotting`, then `done` with the PDF's Dropbox path and content hash
  (and how many references, if any, couldn't be found), or `failed` with a reason in plain words. The Duo reads it with one small download, or sees it arrive in the
  listing of `Vellum/Plots/requests` it keeps a cursor for. The laptop publishes the index before it writes `done`, so
  the Duo finds the PDF in the index when it looks.
- **The laptop trusts nothing in a request.** It plots only a DWG and layout its own index holds whose entry has the
  request's `id`, using the index's path and layout name, so nothing from a request reaches AutoCAD's script.
- **The layout's own page setup,** plotted on a copy of the DWG, when its saved plotter writes PDFs; else DWG To PDF
  at the layout's paper size, said so in the answer. A DWG on its Model tab, which has no layout area, falls back to
  its extents on that sheet (amended for #87), fitted to the page, not to scale (amended for #92), and the answer and
  the index mark that plot `fitted`. Relative xref, image and underlay paths are made absolute against
  the original's folder on the copy, so the PDF has them. Nothing is ever saved into the DWG.
- **One plot a turn.** Between plots the indexer takes the watcher's changes and the next file to read, so a backlog
  of plots never holds up the index.
- **Plots go to `Dropbox/Vellum/Plots/<project>/<DWG name> - <layout> - <DWG saved> - <8 hex>.pdf`**, the 8 hex
  digits covering the DWG's path, layout and bytes so no two versions share a name, and are the
  entry's `pdf` in the index, `pairedBy` `"plotted"`, with no change to the index's format (ADR-0017). A re-plot of a
  changed DWG is a new file; the older plot moves to `otherPdfs`.
- **A check-in,** `Dropbox/Vellum/Plots/laptop.json`, a time and the indexer's version, rewritten every 2 minutes
  while the indexer runs. The Duo shows "Waiting for the laptop" when it is more than 5 minutes old by Dropbox's own
  `server_modified`.
- **The Duo deletes its request once it has read a final answer; the laptop never deletes a request,** and deletes an
  answer an hour after it first sees the request gone.

## Amendment (#92): a Model-tab plot is fitted to the page, not to scale

#87's fallback plotted a Model-tab DWG's extents at 1:1, and the laptop hand test on 1.1.1 showed a real Model-tab
drawing cut off on its 8.5 x 11 sheet. Zach's decision (2026-11-08): **"Fit to page, not to scale: Extents fitted to
the sheet; the Duo says "plotted to fit, not to scale" and places it as an NTS sheet, so no measuring off it."**

- The Model tab's `-PLOT` answers `_F` (Fit) to the scale prompt instead of `1:1`; every other answer is #87's, and
  paper layouts and a saved page setup are unchanged.
- **The signal is one boolean, `fitted`,** chosen as the smallest change both old readers ignore: on a `done` answer
  (`true` for a fitted plot, `false` for any other, `null` before `done`), and on the index entry's `pdf` (`true` only
  for a fitted plot, absent on every other PDF, so no other shard changes). `pageSetup` could not carry it: a
  paper layout's fallback is also `fallback` and is to scale. A new value for `scale` could not either, since `scale`
  is the title block's text, which an older Duo would show and parse as written. The format stays 1: an older Duo
  ignores the key and reads everything else as before, and an older laptop's answers and index, having no `fitted`,
  read as plots to scale.
- The Duo places a fitted plot as an NTS sheet, through the same path as an index `scale` of `NTS`, and its viewer
  says "Plotted to fit, not to scale" in place of the fallback line.
- A plot 1.1.1 made of the Model tab at 1:1 (`fallback`, Model, not `fitted`) is never handed out again: the next
  request for it plots again, fitted. The fitted plot's name carries `fit` in its 8 hex digits' hash, so it never
  takes the 1:1 plot's name; it becomes the entry's `pdf` and the 1:1 plot moves to `otherPdfs`.

## Considered options

- **One shared queue file.** One file to read, but two Duos, or the Duo and the laptop, would write it at once, and
  Dropbox would keep a conflicted copy rather than merge.
- **Answers in the request file itself.** One file per request, but the Duo and the laptop would both write it, so a
  rewrite by one could cross the other's in Dropbox. Separate files give each file one writer.
- **The laptop deletes requests once answered.** Tidier, but a Duo offline at that moment would never see the answer.
  Only the Duo knows it has read one, so only the Duo deletes its request.
- **Answering through the index alone** (the entry gaining its `pdf`). No answer files, but a failure would have
  nowhere to say why, and "plotting" could not be told from "not seen".
- **A check-in every 30 seconds.** The Duo would know the laptop is off sooner, but at four times the uploads for a
  state that rarely changes.

## Consequences

- #70 writes requests in this format through the sync outbox, reads answers and the check-in, deletes its requests
  once answered, and shows the prototype's waiting states from them.
- The laptop indexer now writes to `Dropbox/Vellum/Plots` as well as `Dropbox/Vellum/Index`, and nowhere else in
  Dropbox.
- Plots are kept in Dropbox until Zach deletes them; one deleted by hand leaves the index at the next scan.
- The fallback's prompts are typed for AutoCAD 2026's `-PLOT`; a later AutoCAD that asks them differently fails a
  fallback plot with a reason, never prints or saves anything, and is seen in the hand test. Since #87 that reason comes within
  seconds: the script catches a cancelled `-PLOT` and the laptop stops a console that hasn't quit after its report.
