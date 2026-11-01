# Ink is saved as an append-only log with snapshots, written as it happens and flushed in batches

AGENTS.md says nothing loses a stroke, and ADR-0003 says every change is saved on the Duo first. Zach also put speed first: saving must never make the Pencil feel slower, and as little data as possible should move. We considered rewriting the whole canvas file after each stroke, which is simple but writes megabytes per stroke once a canvas holds thousands of strokes, and a database, which brings a dependency and a format the laptop cannot read without it. We chose an append-only log of ink changes beside a periodic snapshot, in a small binary format of our own in `VellumCore` (`InkStore`, `InkCodec`).

## The format

A canvas is one folder, named by the canvas's id so a rename never moves it, under `Application Support/Canvases/` in the app's own container (not iCloud, not the Files app):

- `canvas.json`: the canvas's name and canvas units, plain JSON. It is replaced whole (write, flush, rename) when either changes.
- `ink.snapshot`: the ink and its undo history at the last compaction, as one record. Its header also says where in the previous log it was taken.
- `ink.log`: every change since, one record each: a stroke drawn, strokes erased (by id, with whether they join the sweep in progress), an undo, a redo.

Both ink files start with a header (magic, version, generation; the snapshot's adds where in the previous generation's log it was taken, 24 bytes against the log's 16) and hold records framed by their length and a CRC-32. Replaying the log's events on the snapshot through `InkSession.apply` rebuilds the ink and the undo history exactly. On reopen, a last record cut short or failing its checksum is dropped and the log is trimmed back to the last whole record. That is never an error.

A stroke's points are kept on an ink grid of 1/65,536 inch, about 0.4 micrometres and a hundredth of a point at the canvas's closest zoom (ADR-0012). The first point is stored as whole grid units and each later point as its step from the one before, as zigzag varints. The ink in memory is snapped to the same grid when it is drawn, so what reopens is exactly what was drawn, with no drift. A stroke's width stays a 64-bit float. A typical 120-point stroke takes 582 bytes, about 4.8 bytes a point (16 bytes as raw doubles). A 10,000-stroke canvas of such strokes takes about 5.8 MB on disk, snapshot and log together. In the snapshot, an undo or redo step names a stroke that is on the canvas by its id and writes whole only the strokes the history alone holds (erased strokes, undone strokes).

## When bytes reach storage

- **Each change is appended as it happens**, with one plain `write` of that change's bytes on the canvas saver's append queue, never on the main thread. A stroke commit costs the main thread a queue hand-off, 1.7 µs on average on a 10,000-stroke canvas (release build on Forge).
- **Flushing to storage is batched.** The log is flushed with `F_FULLFSYNC` at most every 3 seconds while Zach draws, and at once when the app leaves the screen or is terminated. On Apple platforms a plain `fsync` only hands the bytes to the drive, whose own cache a power cut can still lose; `F_FULLFSYNC` reaches the flash. It costs milliseconds, which is fine once per batch on the saver's queue. A flush that fails is reported in the status bar and tried again, so the bound below holds rather than being assumed. A change in the kernel's file cache already survives an app crash, a force-quit and iOS killing the app. Only a sudden power cut, the battery dying or the phone being forced off, can lose what has not been flushed yet. So:
  - a crash, a force-quit or iOS killing the app loses at most the stroke still being drawn;
  - a power cut loses at most the last 3 seconds of changes, and nothing drawn before the app last left the screen.

  An `F_FULLFSYNC` after every stroke would close that window. It costs milliseconds of storage work per stroke and wears the flash, for a case (the Duo dying on the instant) the battery warning nearly always heads off.
- **Compaction** writes the ink and undo history as a new snapshot and starts a new log, once the log is larger than both 1 MB and the snapshot, so a canvas's bytes stay within about twice its ink. It starts when the Pencil is up, in three steps:
  1. On the append queue, it takes the ink and history as they stand and notes the log's length there.
  2. On a separate maintenance queue, it encodes the snapshot and writes it to a temporary file, flushed with `F_FULLFSYNC`. This is the slow step, and strokes finished meanwhile are appended to the log at once, not queued behind it.
  3. Back on the append queue, once the Pencil is up, it renames the snapshot into place under the next generation. That rename is the commit. It then writes the new log (header plus the changes appended since step 1) under a temporary name, opens it, flushes it and renames it over the old log. Appends switch to the new file in the same step, so nothing is ever appended to a log that has been replaced.

  Every step leaves files that reopen with every change. A failure or crash before the snapshot's rename leaves the old snapshot and log as they were. After it, the new snapshot records where in the old log it was taken, so opening replays the old log's later changes on top and carries them into a new log. If the new log can't be written, appends go on into the old log, which still reopens correctly; the next flush tries the new log again, and no new compaction starts until it is in place. Tests inject a failure, and separately a crash, at every file call of a compaction.
- **A torn append** (a write that fails part way, as on a full Duo) is trimmed back before anything else is appended. If the trim fails too, the log refuses appends until a later attempt trims it, so a torn record never sits in front of a later change.

## The canvas saver

One canvas saver per canvas (`CanvasSaver`, handed out by `CanvasSavers`, both in `VellumCore` so the tests drive the app's own saver) owns its files. Opening, closing, reopening and deleting all run in order on its append queue:

- reopening a canvas that is still being written reuses its saver and sees every change handed to it;
- deleting waits for pending writes and any compaction, then lets go of the files;
- going back to the list keeps the saver, and any change it could not write, until everything is on the Duo. A write that keeps failing (the Duo is full) is retried, waiting longer each time up to 15 seconds, and the Canvases list says in plain words which canvas is not fully saved and why.

No storage file work runs on the main thread. The canvas screen only hands changes to the saver; finding the canvases' folder, listing, opening, closing and deleting run off it, and so do the debug fixtures. When the app is terminated, the main thread waits up to 3 seconds for the savers to flush, but does none of the work itself. `FileWork` counts any storage call on the main thread for the budget tests, and debug builds stop on one.

## Undo

Undo and redo survive a relaunch. Replaying the log rebuilds them for free, and the snapshot stores the undo and redo steps with the ink. The history keeps the last 500 steps (`InkSession.undoLimit`), and fewer when the ink only it holds would pass a million points, about 16 MB (`InkSession.historyPointBudget`). That ink is erased strokes in undo steps and undone strokes in redo steps; both count. Over the budget, the redo steps furthest from the ink go first, then the oldest undo steps. The newest step is always kept, however big, so a sweep that erases the whole canvas can still be undone. We considered paging older steps back from the log on disk instead, but that puts a file read on the undo button, and compaction folds the log away anyway; a budget bounds memory without either.

## The ink in memory

One value owns a canvas's ink on the canvas screen: the editor's `InkSession`. The canvas model beside it holds no copy, since two values sharing the stroke list make every change copy the whole canvas. Each change reports what it added and took away (`InkChange`), so anything kept in step with the ink follows the change rather than the canvas. The saver keeps its own replica, built from the same changes on its queue; the two share the ink as read at opening, so the first edit after opening copies the stroke list once, and no edit after that does.

Strokes are numbered in the order drawn and never renumbered, and every change keeps the ink in that order, so a stroke is found by binary search, and erasing or restoring any number of strokes is one pass over the strokes after the first one touched. Undo steps hold strokes, not positions. `docs/perf/baselines/storage.json` holds the work counts this costs (copies per edit, strokes moved per bulk erase, history points) as budgets. Undo covers drawing and erasing, as ADR-0012 says; renaming a canvas and changing its units are not undo steps.

## Consequences

- #12 can sync a canvas by uploading only what changed: the log's new tail between compactions, and the occasional new snapshot and `canvas.json`. The folder holds only those three files. The Canvases list's thumbnails and stroke counts are made from the ink and live in the app's Caches folder, so they are never synced.
- The Canvases list reads only `canvas.json` files and cached thumbnails, never ink, so it is quick whatever the canvases hold. A thumbnail records which saved ink it shows. It is redrawn on the maintenance queue after a batch of edits, when a canvas is closed, and when a canvas opens with its thumbnail missing or stale.
- A record that passes its checksum but does not decode, from a newer Vellum or damage, stops the replay there. Everything before it opens. A damaged snapshot is reported rather than overwritten.
- If a write fails because the Duo is full, the log is trimmed back to before the attempt. The changes stay in memory with the canvas saver, which writes them with the next change or on its retry timer, whichever comes first, even after the canvas is closed. Meanwhile the status bar says "Not saved: this Duo is full".
- Sheets and frames are not saved yet, because nothing places them. The ticket that places sheets adds them as their own log events.
- Measured on Forge's Linux box (release build, ext4 on SSD): 10,000 strokes of 120 points append in 6 µs each (write only), a batched flush takes about 4 ms, and the canvas reopens in 32 ms. Compacting it takes about 400 ms on the maintenance queue, and appends carry on throughout.

## Amendment (#7): moves, resizes, duplicates, deletes and text boxes

The lasso moves, resizes, duplicates and deletes a selection of strokes and text boxes, and text boxes are placed and edited; each is one undo step, saved as its own event in the same log. The ink files are now version 2, with five more kinds of event (codes are never reused: 1 to 4 are version 1's):

- **A move or a resize** (5) records the selection's ids and the transform, never the moved strokes' points: the stroke ids as a varint count, the first id and each later id as its step from the one before (a byte a stroke for strokes drawn one after another), the same for text box ids, then the scale and the offset in inches as three 64-bit floats. Resizing is uniform from a corner, so handwriting and circles keep their shape; a stroke's width and a text box's letters scale with it. Replay works the moved points out again, on the ink grid, with the same arithmetic the canvas used, so they reopen exactly. Moving 1,000 strokes appends 1,036 bytes, however many points they have; rewriting them would append about 582 KB.
- **A duplicate** (6) records the same, plus the first new stroke id and text box id; replay numbers the copies in order from there.
- **A delete** (7) records the ids. The eraser keeps its own event.
- **A text box placed** (8) and **edited** (9) record the whole box: its id, its top-left corner, width, height and letter height in inches as 64-bit floats, its markup colour, and its text as UTF-8. Emptying a text box deletes it.

Strokes keep their ids when they move, so the undo history keeps what the canvas no longer shows: a move's step holds its strokes and text boxes as they were (and redoing it works the moved ones out again from them), a duplicate's step holds the copies, a delete's step holds what it took. A move's old points are held by the history alone, and count toward `InkSession.historyPointBudget` like erased strokes do. In the snapshot, an undo step names a stroke by its id only when that very stroke, points and all, is on the canvas; a moved stroke's earlier self is written whole.

A snapshot of a canvas that has never had a text box is written exactly as version 1 wrote it, byte for byte, so a canvas of ink alone costs what it did. A canvas with text boxes adds them after the undo history, with the next text box id. A version 1 snapshot reads as one with no text boxes, and a version 1 log replays as before; new events appended to a version 1 log replay too, since every event says what kind it is, and the next compaction writes version 2 files. The canvas folder still holds only `canvas.json`, `ink.snapshot` and `ink.log`.

A text box being typed in is saved when the typing ends: a tap away from it, another tool, undo or redo, closing the canvas, or the app leaving the screen. A crash while typing loses the text being typed, as a crash loses the stroke still being drawn.
