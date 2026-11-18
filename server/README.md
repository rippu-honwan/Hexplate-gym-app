# Hexplate server

Python FastAPI + SQLite, on your own Mac. Speaks the few routes the phone app uses (pairing, the
state document, motion files), so Hexplate syncs with it as it did with openGym's server.

```sh
cd server
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt -r requirements-dev.txt
.venv/bin/python -m hexserver serve            # port 8765, reachable on your Wi-Fi
.venv/bin/python -m hexserver pair             # one-time code for the app (Settings > Server)
.venv/bin/python -m hexserver import state.json motion/   # JSON backups and folders of motion CSVs
.venv/bin/python -m pytest -q
./launchd.sh install                           # keep it running in the background from login on
```

The dashboard is at http://127.0.0.1:8765 on the Mac only. The phone pairs from it (Data, New
pairing code) with the address `http://<LocalHostName>.local:8765`. If macOS asks whether Python
may accept incoming connections, allow it, or the phone cannot reach the server. While the Mac
sleeps the phone cannot sync; it keeps its changes and motion files and sends them later.

Data lives in `server/data/` (git-ignored; `HEXPLATE_DATA` moves it): `hexplate.sqlite3` keeps every
pushed document (`documents`) and the latest one split into `workouts`, `sets` and `bodyweight`;
`motion/` holds the watch's CSV files.

## MCP (for an AI assistant)

`python -m hexserver mcp` is a read-only MCP server over stdio: `get_summary`,
`get_exercise_history`, `get_schema` and `run_query` (one SQLite SELECT, 500 rows, 5 s, with
`exname()` and `e1rm()`). The database is opened read-only and an authorizer refuses anything but
reads. Claude Code picks it up from the repo's `.mcp.json` (run from the repo root, after the venv
above exists). For Claude Desktop, add the same command with the absolute paths:

```json
{ "mcpServers": { "hexplate": { "command": "<repo>/server/.venv/bin/python", "args": ["-m", "hexserver", "mcp"],
  "env": { "PYTHONPATH": "<repo>/server" } } } }
```
