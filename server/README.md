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
`get_exercise_history`, `get_routines`, `get_schema` and `run_query` (one SQLite SELECT, 500 rows, 5 s, with
`exname()` and `e1rm()`). The database is opened read-only and an authorizer refuses anything but
reads. Claude Code picks it up from the repo's `.mcp.json` (run from the repo root, after the venv
above exists). For Claude Desktop, add the same command with the absolute paths:

```json
{ "mcpServers": { "hexplate": { "command": "<repo>/server/.venv/bin/python", "args": ["-m", "hexserver", "mcp"],
  "env": { "PYTHONPATH": "<repo>/server" } } } }
```

The dashboard's Connect page shows this config with this Mac's paths filled in.

## Webhooks

Dashboard › Connect adds them: a URL (Home Assistant, n8n, Node-RED, ntfy…), the events
(`workout.finished`, `workout.pr`, `weighin.logged`) and a signing secret shown once. When the
phone syncs, what is new since the last copy and from the last seven days is POSTed as openGym's
payload (`{version, id, type, createdAt, data}`), with `X-Hexplate-Event`, `X-Hexplate-Delivery` and
`X-Hexplate-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<body>">`. Three tries over
about a minute; redirects are not followed. `node server/scripts/webhook-golden.mjs` rebuilds the
test fixture from openGym's own code (needs `frontend/` linked to the openGym checkout).
