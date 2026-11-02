# Everything but laptop work works offline

Zach marks up drawings in plants and basements with no signal. Drawing, text boxes, measuring, dimensions, recording meetings, opening any sheet or drawing already on the Duo and searching the drawing index all work offline. Anything that needs the laptop (sending a job, plotting a drawing to PDF, transcribing and summarizing a meeting) waits on the Duo and goes when the Duo is online and the laptop is reachable. Pinning project folders for offline in advance was considered and left for later; what Zach has opened stays on the Duo.

Vellum edits a canvas only on the Duo. The laptop adds results beside a canvas and never changes the canvas itself, so a canvas has one writer and syncing it to Dropbox has no conflicts to resolve.

## Amendment (#11): a placed sheet's PDF stays on the Duo

A PDF picked in Add sheet is downloaded once, into the app's Caches folder, named by its Dropbox content hash (`SheetPDFs`), so picking it again, from any canvas, downloads nothing. Placing a sheet copies it into the canvas folder (ADR-0014's #11 amendment), and the sheet is drawn from that copy ever after, so a placed sheet opens offline and reopening a canvas never downloads anything. Caches may be cleared by the system; that costs only a download the next time the PDF is picked.
