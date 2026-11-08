# The drawing index is a file in Dropbox, built on the laptop and searched on the Duo

A redline needs the DWG behind a PDF, and Zach wants to find and open any drawing he has. File names alone do not say which DWG a PDF came from, so a laptop indexer scans Zach's Dropbox and keeps a drawing index in `Dropbox/Vellum`: each drawing's file, folder and project, its title block fields (drawing number, title, revision, scale, date), which PDF is its plot, and a thumbnail. Vellum keeps a copy and searches it on the Duo, offline too. Choosing a drawing from a search opens it in Vellum.

A drawing with no PDF is plotted when Zach first opens it in Vellum, with AutoCAD's own `accoreconsole` so the PDF matches what AutoCAD prints, and the PDF is kept in `Dropbox/Vellum`, not beside the original, so project folders stay as Zach keeps them. Plotting everything up front was considered and rejected as a long first run for drawings he may never open.

## Considered options

- **A small service on the laptop answering searches live.** Always current, but no search while the laptop is off.
- **Dropbox's own file search.** No index to build, but it knows file names, not title blocks or DWG–PDF pairs.

## Consequences

- The laptop indexer's code lives in this public repository, under `laptop/`. The index, thumbnails and plotted PDFs never do: they are client data and live only in Dropbox.
- Vellum asks for a plot by writing a request to `Dropbox/Vellum`, which the laptop indexer answers. That is mechanical work, so it does not start a Sotto thread.
- Building a full index of every drawing is a project of its own. The first version is the part Vellum needs to search and open drawings.

## Amendment (#66): the laptop indexer and the index's format

The laptop indexer is built (`laptop/`, its README says how it works). The index is not one file but the folder `Dropbox/Vellum/Index`: a small manifest, one content-named shard per project and content-named thumbnails, so a refresh on the Duo downloads only what changed (ADR-0017, `docs/drawing-index-format.md`). The indexer reads DWG title block attributes with the same `accoreconsole` this ADR plots with, on a copy of the DWG outside Dropbox, so project folders stay as Zach keeps them. It scans all of Dropbox and keeps its own state on the laptop, not in Dropbox.

Online-only files, Zach's decision on 2026-11-07 ("Download and read them … to my external drive, once done go ahead and delete what's been read, not from Dropbox but from the external drive"): the indexer never opens the placeholder in the laptop's Dropbox folder, which would make Dropbox download the file there. It downloads the file through the Dropbox API (`files/download`) to a scratch folder on the external drive (`D:\Vellum indexer\scratch` by default), reads it, and deletes the copy, one file at a time; nothing is deleted from Dropbox. The laptop signs in to Vellum's own Dropbox app once, with PKCE and no app secret as the Duo does (ADR-0013); the refresh token lives in Windows Credential Manager and the app key in the laptop's settings, neither in the repository. With the drive unplugged or no sign-in, online-only files stay listed unread and are read when both are back.

The AutoLISP that dumps title block attributes is typed into the core console's script rather than loaded from a file, so AutoCAD's `SECURELOAD` never asks, and Zach's AutoCAD security settings are left alone. A DWG with several titled layouts is one index entry per layout (ADR-0017).

## Amendment (#67): plotting on request

Built as ADR-0018 says, in plot request format 1 (`docs/plot-requests.md`): the Duo writes one file per request to
`Dropbox/Vellum/Plots/requests`, the laptop indexer answers beside it (`plotting`, `done` with the PDF's path, or
`failed` with a reason), and keeps a check-in in `Dropbox/Vellum/Plots/laptop.json` so the Duo can tell it is off. The
PDF goes to `Dropbox/Vellum/Plots/<project>/`, plotted with the layout's own page setup on a copy of the DWG, or with
DWG To PDF at its paper size when the layout has none that plots to PDF.
