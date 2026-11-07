# The laptop indexer (#66)

November 7, 2026, on `feat/laptop-indexer` (PR #74). Every drawing, project, title block and Dropbox folder here is made up; nothing comes from Zach's Dropbox or the private automated-drawing-generator (ADR-0004).

## What CI proved

RUN_PLACEHOLDER

## Hand test on the laptop

CI cannot run AutoCAD or Dropbox, so these steps need the laptop. Each says what to look for. The log is `%LOCALAPPDATA%\Vellum\indexer\indexer.log`; `Get-Content -Wait` follows it.

- [ ] **Install.** In a checkout of `main` after merge, in PowerShell: `powershell -ExecutionPolicy Bypass -File laptop\scripts\install.ps1`. It prints the Dropbox folder it found (from Dropbox's `info.json`), the index folder (`<Dropbox>\Vellum\Index`), `DWG reader: AutoCAD core console at C:\Program Files\Autodesk\AutoCAD 20xx\accoreconsole.exe`, then "Registered the task \Vellum\Vellum laptop indexer" and "Started it". If the Dropbox folder is wrong, run it again with `-DropboxPath`.
- [ ] **It starts at logon.** Task Scheduler shows `\Vellum\Vellum laptop indexer`, trigger "At log on of" Zach's account, Running. Sign out and back in (or restart): it is Running again, and the log has a new "Vellum laptop indexer 1.0.0" line.
- [ ] **Watch the first scan's log.** "Listed N drawings and PDFs in X s; M to read", then "Read i of M (p%)" every 30 seconds, and "Published generation g: … drawings in … shards" every 10 minutes and at the end. Task Manager shows `pythonw.exe` and, while DWGs are read, `accoreconsole.exe`, at low priority; the laptop stays usable. Note how long the first scan takes and how many DWGs it read; that number is the laptop's real first-scan baseline.
- [ ] **Restart part way.** During the first scan, end the task in Task Scheduler and run it again. The next "Listed" line has fewer to read: what was read is not read again.
- [ ] **Find a known drawing in the index.** Open `<Dropbox>\Vellum\Index\index.json`, find the project's shard in `shards`, open that file and search for the drawing's number. Check its title, revision, scale and date match its title block, `fieldsFrom` is `dwg`, its `pdf.path` is the PDF plotted from it, and its `thumbnail` names a file in `thumbnails` that shows its first page. Check a vendor PDF shows `"dwg": null`, and a DWG never plotted `"pdf": null`.
- [ ] **No writes in project folders.** In a project folder the indexer has read, no new `.dwl`, `.dwl2`, `.bak` or other file has appeared, and Dropbox's recent activity shows only `Vellum/Index` changes from the laptop.
- [ ] **Save a changed PDF and see the index update within seconds.** Plot a drawing again over its PDF (or save any PDF in a project folder). Within a few seconds the log has "Updated 1 files and 0 folders in … s" and "Published generation g+1", and that project's shard has a new name in `index.json`; every other shard's name is unchanged.
- [ ] **Copy a folder in.** Copy a folder of several drawings into a project. The log shows one "Updated N files" line for the copy, not one per file.
- [ ] **An online-only file was not downloaded.** In File Explorer, pick a PDF in a project folder and choose Dropbox → Make online-only (its status shows a cloud). Restart the task. The file still shows the cloud (not a green tick): it was not downloaded. Its entry in the shard has `"read": false` and no title. Open the PDF in Explorer, so Dropbox downloads it: within seconds the log has an update, and its entry now has `"read": true` and its fields.
- [ ] **Uninstall.** `laptop\scripts\uninstall.ps1`. It prints "Removed the task" and "Deleted …\venv"; Task Scheduler no longer lists the task, no `pythonw.exe` runs, and `Dropbox\Vellum\Index` is still there. Install again to keep it running.
