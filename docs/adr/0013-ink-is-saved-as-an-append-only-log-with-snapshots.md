# Ink is saved as an append-only log with snapshots, written as it happens and flushed in batches

AGENTS.md says nothing loses a stroke, and ADR-0003 says every change is saved on the Duo first. Zach also put speed first: saving must never make the Pencil feel slower, and as little data as possible should move. We considered rewriting the whole canvas file after each stroke, which is simple but writes megabytes per stroke once a canvas holds thousands of strokes, and a database, which brings a dependency and a format the laptop cannot read without it. We chose an append-only log of ink changes beside a periodic snapshot, in a small binary format of our own in `VellumCore` (`InkStore`, `InkCodec`).

## The format

A canvas is one folder, named by the canvas's id so a rename never moves it, under `Application Support/Canvases/` in the app's own container (not iCloud, not the Files app):

- `canvas.json`: the canvas's name and canvas units, plain JSON. It is replaced whole (write, flush, rename) when either changes.
- `ink.snapshot`: the ink and its undo history at the last compaction, as one record.
- `ink.log`: every change since, one record each: a stroke drawn, strokes erased (by id, with whether they join the sweep in progress), an undo, a redo.

Both ink files start with a 16-byte header (magic, version, generation) and hold records framed by their length and a CRC-32. Replaying the log's events on the snapshot through `InkSession.apply` rebuilds the ink and the undo history exactly. On reopen, a last record cut short or failing its checksum is dropped and the log is trimmed back to the last whole record. That is never an error.

A stroke's points are kept on an ink grid of 1/65,536 inch, about 0.4 micrometres and a hundredth of a point at the canvas's closest zoom (ADR-0012). The first point is stored as whole grid units and each later point as its step from the one before, as zigzag varints. The ink in memory is snapped to the same grid when it is drawn, so what reopens is exactly what was drawn, with no drift. A stroke's width stays a 64-bit float. A typical 120-point stroke takes 582 bytes, about 4.8 bytes a point (16 bytes as raw doubles). A 10,000-stroke canvas of such strokes takes about 5.2 MB.

## When bytes reach storage

- **Each change is appended as it happens**, with one plain `write` of that change's bytes on the saver's serial queue, never on the main thread. A stroke commit costs the main thread a queue hand-off, 1.7 µs on average on a 10,000-stroke canvas (release build on Forge).
- **Flushing to storage is batched.** `fsync` runs at most every 3 seconds while Zach draws, and at once when the app leaves the screen or is terminated. A change in the kernel's file cache already survives an app crash, a force-quit and iOS killing the app. Only a sudden power cut, the battery dying or the phone being forced off, can lose what has not been flushed yet. So:
  - a crash, a force-quit or iOS killing the app loses at most the stroke still being drawn;
  - a power cut loses at most the last 3 seconds of changes, and nothing drawn before the app last left the screen.

  An `F_FULLFSYNC` after every stroke would close that window. It costs milliseconds of storage work per stroke and wears the flash, for a case (the Duo dying on the instant) the battery warning nearly always heads off.
- **Compaction** writes the ink and undo history as a new snapshot and starts an empty log, once the log is larger than both 1 MB and the snapshot, so a canvas's bytes stay within about twice its ink. It runs on the saver's queue at a quiet moment, only when the Pencil is up. The snapshot is written to a temporary file, flushed with `F_FULLFSYNC` and renamed under the next generation, then the new log likewise. A crash between the two leaves the old log behind with an older generation, which the next open recognises as already in the snapshot and discards.

## Undo

Undo and redo survive a relaunch. Replaying the log rebuilds them for free, and the snapshot stores the undo and redo steps with the ink. The history keeps the last 500 steps (`InkSession.undoLimit`). Undo covers drawing and erasing, as ADR-0012 says; renaming a canvas and changing its units are not undo steps.

## Consequences

- #12 can sync a canvas by uploading only what changed: the log's new tail between compactions, and the occasional new snapshot and `canvas.json`. The folder holds only those three files. The Canvases list's thumbnails and stroke counts are made from the ink and live in the app's Caches folder, so they are never synced.
- The Canvases list reads only `canvas.json` files and cached thumbnails, never ink, so it is quick whatever the canvases hold. A thumbnail is redrawn in the background after a batch of edits and when a canvas is closed.
- A record that passes its checksum but does not decode, from a newer Vellum or damage, stops the replay there. Everything before it opens. A damaged snapshot is reported rather than overwritten.
- If a write fails because the Duo is full, the log is trimmed back to before the attempt. The changes stay in memory and are written with the next change, and the status bar says "Not saved: this Duo is full".
- Sheets and frames are not saved yet, because nothing places them. The ticket that places sheets adds them as their own log events.
- Measured on Forge's Linux box (release build, ext4 on SSD): 10,000 strokes of 120 points append in 6 µs each (write only), a batched `fsync` takes about 4 ms, and the canvas reopens in 32 ms. Compacting it takes about 400 ms, off the main thread, while the Pencil is up.
