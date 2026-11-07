# The laptop indexer (#66)

November 7, 2026, on `feat/laptop-indexer` (PR #74). Every drawing, project, title block and Dropbox folder here is made up; nothing comes from Zach's Dropbox or the private automated-drawing-generator (ADR-0004).

## What CI proved

The numbers below are from run [42362227818](https://github.com/millZach/Vellum/actions/runs/42362227818) at 74bd602, job **Laptop indexer tests (Windows)** on GitHub's `windows-latest` with Python 3.12, green in 1 min 58 s. The PR's final run (named in the PR) runs the same job again with the timing baselines in place, alongside the five macOS jobs.

- **Lint:** `ruff check src tests scripts`, clean.
- **pytest:** 111 passed in 16.5 s, every one on made-up drawings. The exact cases cover:
  - **Skip rules:** `Dropbox/Vellum`, `.dropbox.cache` at any depth, `~$`, `.dwl`, `.dwl2`, `.bak`, `.sv$`, `.~`, settings excludes, and files that are not drawings.
  - **Online-only files**, with the attribute faked: each attribute bit; they are listed with `read: false` and never handed to the PDF reader, the AutoCAD reader or the preview reader; they still pair by name; they are read once local and not again; and a watched change to one does not open it.
  - **Pairing:** by plot metadata, by name in the same folder, in a PDF or Plots folder and in cousin folders, by layout and revision suffixes, and by unique drawing number. Also the longest stem, the nearest DWG, too far apart, another project, and case.
  - **Fields:** from made-up DXF title blocks via ezdxf, paper space before Model space, title lines, blank and `####` values, extra tags from settings, the PDF-text fallback from a made-up title block PDF, refused values, and numbers from file names.
  - **Projects:** projects roots, the walk-up past discipline and format folders, and no project.
  - **The index:** the format and its round trip, content names, atomic writes (a failed rename leaves the old file and no temp file; the temp name starts `~$`), nothing written outside `Vellum/Index` and no project file changed, the hour's grace before deletes, another format refused, and a deleted thumbnail written again.
  - **Incremental updates:** an unchanged file is not read again, also after a restart; a changed PDF or DWG is read alone; a deleted one leaves the index; folders moved in or deleted; a first scan stopped part way carries on; PDFs are read first, with watched changes taken between files; a folder that fails to list keeps its drawings.
  - **Thumbnails:** 128 px on the long side, the same drawing gives the same name, a changed one a new name, one file for identical drawings, DWG PNG and BMP previews, and the PDF's thumbnail over the DWG's preview.
  - **The AutoCAD reader**, through a stand-in console: the DWG is read from a copy, the project folder is unchanged and the work folder is emptied; a cut or missing dump is an error; a hung console is stopped.
  - **The watcher**, with real watchdog on Windows: a saved PDF reached the index within 10 s, and copying in a folder of 40 PDFs was one update.
  - **The fixture index** is current.
- **Budgets** (`docs/perf/baselines/laptop-indexer.json`, enforced by those tests), all met: rescan with nothing changed 0 files read, 0 index files written, 0 thumbnails made; one PDF changed 1 file read, 3 index files written; a folder copy 1 update.
- **Timings** on a made-up 5,000-file Dropbox (`scripts/bench.py`: 2,000 DWGs with previews, 2,000 PDFs, 1,000 skipped files, 50 projects; a stand-in DWG reader because CI has no AutoCAD). These set the first baselines:

  | Metric | windows-latest | Forge (Linux, for comparison) |
  |---|---|---|
  | First scan | 23.6 s | 13.1 s |
  | Rescan, nothing changed | 0.59 s | 0.30 s |
  | Rescan, one PDF changed | 0.62 s | 0.30 s |
  | Watcher update for one saved PDF (after the 2 s debounce) | 0.27 s | 0.16 s |

  The first scan wrote 1,072 index files (3.3 MB): 50 shards, about 1,020 thumbnails and the manifest (9,678 bytes for 2,500 drawings). A one-PDF change wrote 47 KB. Nothing came before this PR, so there is no "before".
- **install.ps1 and uninstall.ps1, for real**, against a made-up Dropbox folder holding one made-up PDF:
  - The installer made the venv, installed the pins and found the Dropbox folder. It registered `\Vellum\Vellum laptop indexer` with an `MSFT_TaskLogonTrigger` running `venv\Scripts\pythonw.exe -m vellum_indexer run`, and started it.
  - The task ran: its log reads "Listed 1 drawings and PDFs … Published generation 1", and the index appeared.
  - `uninstall.ps1 -Purge` removed the task and the indexer's folder and left `Dropbox\Vellum\Index`.
  - The runner has no AutoCAD, so the log says `DWG reader none`.

### The second round: online-only downloads and the review fixes

The PR's final run proves this round on `windows-latest`. Locally on Forge (Linux, Python 3.12): 135 passed and 1 skipped; the skipped test is the credential store test, which needs Windows Credential Manager, so it runs only in CI. New exact cases:

- **Online-only downloads**, against a scripted Dropbox API with made-up tokens and no network:
  - an online-only file is downloaded to the scratch folder, read and its copy deleted, and every reader is handed the copy, never the placeholder;
  - an unchanged one is not downloaded again, and a changed one is;
  - freeing an already-read file to online-only, or making it local again, downloads and reads nothing;
  - a crash's leftover `vellum-dl-*` copy is deleted at start, and nothing else is;
  - with no drive or no sign-in, files are listed `read: false`, the log says why once, and they are read when both are back;
  - a failed download leaves nothing in scratch and is retried;
  - a download cut short or not matching its content hash is not kept;
  - 429 and 503 are retried (`Retry-After`, then backoff), and a lapsed token is renewed;
  - the token is never in the log or in any file under the test's folders;
  - the refresh token round-trips through Windows Credential Manager.
- **Pairing:** equidistant same-named DWGs are told apart by the PDF's number or left unpaired; contradicting numbers are no pair; a contradicted near DWG gives way to a farther one that agrees.
- **Layouts:** a two-layout DWG with two PDFs gives two drawings, each with its own number, scale and PDF.
- **AutoCAD:** the script loads no file, and the work folder holds only the copy and the script while AutoCAD runs.
- **The watcher:** a folder copy reads each file once; a save during a 30-DWG batch is in the index by the 10th DWG; a watched folder that can't be listed keeps its drawings.
- **Rotated paper:** a 36 × 24 page at 0°, 90°, 180° and 270° gives 36 × 24, 24 × 36, 36 × 24 and 24 × 36.
- **Lost state:** losing the state file carries on from the manifest's generation, writing nothing unchanged.
- **New budgets:** downloads on a rescan with nothing changed 0; downloads when one online-only file changed 1; files left in scratch after a scan 0.

## Hand test on the laptop

CI cannot run AutoCAD or Dropbox, so these steps need the laptop. Each says what to look for. The log is `%LOCALAPPDATA%\Vellum\indexer\indexer.log`; `Get-Content -Wait` follows it.

- [ ] **Install and sign in.** In a checkout of `main` after merge, with the external drive plugged in as D:, in PowerShell: `powershell -ExecutionPolicy Bypass -File laptop\scripts\install.ps1 -DropboxAppKey <Vellum's app key>`. It prints Dropbox's page: open it, allow Vellum, paste the code. "Signed in" follows. Credential Manager (Windows Credentials) lists "Vellum laptop indexer"; `settings.toml` holds the app key and no token. It prints the Dropbox folder it found (from Dropbox's `info.json`), the index folder (`<Dropbox>\Vellum\Index`), `DWG reader: AutoCAD core console at C:\Program Files\Autodesk\AutoCAD 20xx\accoreconsole.exe`, then "Registered the task \Vellum\Vellum laptop indexer" and "Started it". If the Dropbox folder is wrong, run it again with `-DropboxPath`.
- [ ] **It starts at logon.** Task Scheduler shows `\Vellum\Vellum laptop indexer`, trigger "At log on of" Zach's account, Running. Sign out and back in (or restart): it is Running again, and the log has a new "Vellum laptop indexer 1.0.0" line.
- [ ] **Watch the first scan's log.** "Listed N drawings and PDFs in X s; M to read", then "Read i of M (p%)" every 30 seconds, and "Published generation g: … drawings in … shards" every 10 minutes and at the end. Task Manager shows `pythonw.exe` and, while DWGs are read, `accoreconsole.exe`, at low priority; the laptop stays usable. Note how long the first scan takes and how many DWGs it read; that number is the laptop's real first-scan baseline.
- [ ] **Restart part way.** During the first scan, end the task in Task Scheduler and run it again. The next "Listed" line has fewer to read: what was read is not read again.
- [ ] **Find a known drawing in the index.** Open `<Dropbox>\Vellum\Index\index.json`, find the project's shard in `shards`, open that file and search for the drawing's number. Check its title, revision, scale and date match its title block, `fieldsFrom` is `dwg`, its `pdf.path` is the PDF plotted from it, and its `thumbnail` names a file in `thumbnails` that shows its first page. Check a vendor PDF shows `"dwg": null`, and a DWG never plotted `"pdf": null`.
- [ ] **No writes in project folders.** In a project folder the indexer has read, no new `.dwl`, `.dwl2`, `.bak` or other file has appeared, and Dropbox's recent activity shows only `Vellum/Index` changes from the laptop.
- [ ] **Save a changed PDF and see the index update within seconds.** Plot a drawing again over its PDF (or save any PDF in a project folder). Within a few seconds the log has "Updated 1 files and 0 folders in … s" and "Published generation g+1", and that project's shard has a new name in `index.json`; every other shard's name is unchanged.
- [ ] **Copy a folder in.** Copy a folder of several drawings into a project. The log shows one "Updated N files" line for the copy, not one per file.
- [ ] **An online-only file is read from D: and the Dropbox folder's copy stays online-only.** In File Explorer, make a project's PDF folder online-only (Dropbox → Make online-only; the files show a cloud). The log has an update and downloads nothing: they were read before, and only their attributes changed. Then on dropbox.com (or another computer) upload a new version of one of those PDFs, say with a new revision. Within seconds `D:\Vellum indexer\scratch` holds a `vellum-dl-….pdf` for a moment and is empty again, and its entry in the shard has the new revision and `"read": true`. In Explorer the PDF still shows the cloud (not a green tick): the Dropbox folder's copy was not downloaded. An online-only folder the first scan met is read the same way.
- [ ] **Unplug D:.** Eject the external drive and upload a new version of another online-only PDF on dropbox.com. The log says once "Online-only files stay unread for now: the scratch drive D:\ is not there", and that PDF's entry has `"read": false`. Plug the drive back in: within ten minutes the log has an update and the entry reads `true`, and the scratch folder is empty.
- [ ] **AutoCAD's SECURELOAD left alone.** With AutoCAD's `SECURELOAD` at its usual 1, the log shows DWGs read ("Read i of M") and no title block errors; AutoCAD's options are unchanged.
- [ ] **A two-layout DWG.** For a DWG whose layouts are separate sheets, the shard has one entry per layout, each with its own number, scale and PDF.
- [ ] **Uninstall.** `laptop\scripts\uninstall.ps1`. It prints "Removed the task" and "Deleted …\venv"; Task Scheduler no longer lists the task, no `pythonw.exe` runs, and `Dropbox\Vellum\Index` is still there. Install again to keep it running.
