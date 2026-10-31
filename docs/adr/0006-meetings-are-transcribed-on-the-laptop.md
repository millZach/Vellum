# Meetings are recorded on the Duo and transcribed and summarized on the laptop

Vellum records in-person meetings through the Duo's microphone and takes phone call recordings shared in from the Phone app, since iOS lets no other app record a call while it is happening. The audio goes to Dropbox, and the laptop transcribes it with speaker names and summarizes it the way Meeting Coach (`millZach/meeting-coach`, private) does for Teams and Phone Link calls, and the summary comes back into Vellum. We considered Apple's on-device speech on the Duo, which works offline and live but is weaker at telling speakers apart. One pipeline for every meeting keeps the summaries the same.

## Consequences

- A meeting's summary waits until the laptop is reachable. The recording itself never waits: it is written to the Duo as it is made.
- The whole transcript goes to Anthropic for the summary, as Meeting Coach's does, so a summary runs only when Zach asks for one, unless he says otherwise.
- Teams and Zoom calls on the laptop stay Meeting Coach's job.
- A call shared in from the Phone app asks which canvas it belongs to, offering the most recent, or starts a new canvas named for the call.
