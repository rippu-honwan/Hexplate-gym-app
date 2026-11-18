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
```

Data lives in `server/data/` (git-ignored; `HEXPLATE_DATA` moves it): `hexplate.sqlite3` keeps every
pushed document (`documents`) and the latest one split into `workouts`, `sets` and `bodyweight`;
`motion/` holds the watch's CSV files.
