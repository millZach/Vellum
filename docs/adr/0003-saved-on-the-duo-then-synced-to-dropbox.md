# Canvases are saved on the Duo first, then synced to Dropbox, with full Dropbox access

Pen work cannot be lost to a dropped connection, and the laptop's agents have to read what Zach drew. So every change is saved on the Duo first, and a canvas is synced to a Vellum folder in Zach's Dropbox, which the laptop already mirrors to its disk. We considered iCloud Drive, which the laptop would need iCloud for Windows to read, and keeping canvases only on the Duo, which would leave the laptop nothing to read until a send.

Vellum asks for full Dropbox access rather than an app folder, because the PDFs Zach marks up already live in his project folders. Sign-in uses Dropbox's OAuth flow with PKCE, which needs no app secret, so the public repository holds no Dropbox secret. The app key is kept out of the repository anyway.
