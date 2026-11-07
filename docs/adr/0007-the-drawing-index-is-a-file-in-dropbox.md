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

The laptop indexer is built (`laptop/`, its README says how it works). The index is not one file but the folder `Dropbox/Vellum/Index`: a small manifest, one content-named shard per project and content-named thumbnails, so a refresh on the Duo downloads only what changed (ADR-0017, `docs/drawing-index-format.md`). The indexer reads DWG title block attributes with the same `accoreconsole` this ADR plots with, on a copy of the DWG outside Dropbox, so project folders stay as Zach keeps them. It scans all of Dropbox, never opens an online-only file (opening one downloads it), and keeps its own state on the laptop, not in Dropbox.
