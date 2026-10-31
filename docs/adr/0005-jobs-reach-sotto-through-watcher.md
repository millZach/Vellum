# A job reaches Sotto through Watcher, with its files in Dropbox

A job has to become a Sotto thread in the right folder on the laptop, where AutoCAD and Dropbox live. Vellum pairs with the laptop's Sotto the way Sotto's iPhone client does (an eight-character code, over Tailscale, host protocol version 1). It writes the job's files to a job folder in Dropbox, then asks Watcher to start a worker in the job's project folder with a brief that names the job folder. Watcher takes text only, so files never go through Sotto. Vellum reads the thread's status back over the same connection. Sotto's own Swift client package, `SottoCore` in the public Sotto repository, is the protocol code to reuse.

## Considered options

- **Share the job into the Sotto iPhone app**, where Zach picks the project and presses Send. Nothing new in Sotto, but an extra step on every job and no status in Vellum.
- **Sotto watches a Dropbox inbox** and starts threads on its own. Nothing to pair, but it is a new way into Sotto with no client to answer to, and needs a Sotto ADR.

## Consequences

- The laptop has to be on, with Sotto's phone access and Tailscale running, for a job to start. Until then the job waits on the Duo.
- Vellum suggests the project folder from the Dropbox folder the job's PDFs came from, and Zach confirms or changes it on the send screen.
- Sotto pairing currently grants answer rights (Sotto ADR-0033, October 30 amendment). Whether Vellum needs that, or a jobs-only pairing, is its own decision.
