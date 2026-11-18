# Hexplate

A native iPhone and Apple Watch workout logger with a rep counter, plus the small server it syncs
with on your own Mac.

- `app/`: the SwiftUI app, the watch app and widgets (xcodegen, see `app/project.yml`).
- `server/`: Python FastAPI + SQLite server: sync, motion files, dashboard, MCP.
- `analysis/`: motion data checks and notebooks for the rep counter.

Licensed under the GNU AGPL v3.0; see [NOTICE.md](NOTICE.md) for where the code comes from.
