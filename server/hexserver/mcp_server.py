"""The MCP server: lets an AI assistant (Claude Code, Claude Desktop) read your training data.

Runs over stdio, started by the assistant (`python -m hexserver mcp`, see the repo's .mcp.json).
Read-only twice over: the database is opened with `mode=ro`, and an authorizer allows reads and
functions only, so not even `ATTACH` (which could write another file) gets through.
"""
import datetime as dt
import json
import sqlite3
import time
from pathlib import Path

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

from .queries import WORK, e1rm, name_of, sessions

ROWS = 500
SECONDS = 5

SCHEMA = """Tables (SQLite). Weights are in the profile's unit (kg unless `unit` says lb); *_ms are
milliseconds since 1970; dates are YYYY-MM-DD.
- workouts(id, date, start_ms, end_ms, name, routine_id, volume, body_weight, session_effort)
- sets(workout_id, entry_idx, set_idx, exercise_id, weight, reps, done, warmup, rir, hr, at_ms,
  started_at_ms, checked, raw) - one row per set; `raw` is the set's JSON as the app stored it.
  Working sets: done = 1 AND warmup = 0. `rir` = reps in reserve.
- bodyweight(date, time, weight)
- motion_files(name, recorded_at, exercise, set_no, kind, bytes, received_at) - the watch's motion
  CSVs; set recordings have kind NULL (other kinds: hr, watchlog, synclog).
- documents(rev, wid, ts, received_at, body) - every full copy the phone sent (body = JSON).
SQL functions: exname(exercise_id) -> the exercise's name; e1rm(weight, reps) -> Epley 1RM."""


def connect(folder: Path):
    """A read-only connection with exname() and e1rm(), refusing anything but reads."""
    db = sqlite3.connect(f"{(Path(folder) / 'hexplate.sqlite3').resolve().as_uri()}?mode=ro", uri=True, check_same_thread=False)
    allowed = {sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_FUNCTION, sqlite3.SQLITE_RECURSIVE}
    db.set_authorizer(lambda action, *_: sqlite3.SQLITE_OK if action in allowed else sqlite3.SQLITE_DENY)
    db.create_function("exname", 1, lambda ex: name_of(ex, latest(db)), deterministic=True)
    db.create_function("e1rm", 2, e1rm, deterministic=True)
    return db


def latest(db):
    row = db.execute("SELECT body FROM documents ORDER BY rev DESC LIMIT 1").fetchone()
    return json.loads(row[0]) if row else None


def query(db, sql: str):
    """Runs one read-only statement: {columns, rows, truncated}, or {error}."""
    deadline = time.monotonic() + SECONDS
    db.set_progress_handler(lambda: time.monotonic() > deadline, 10_000)
    try:
        cur = db.execute(sql)
        rows = cur.fetchmany(ROWS + 1)
    except sqlite3.Error as e:
        return {"error": str(e) if time.monotonic() <= deadline else f"stopped after {SECONDS} s"}
    finally:
        db.set_progress_handler(None, 0)
    return {"columns": [c[0] for c in cur.description or []], "rows": [list(r) for r in rows[:ROWS]], "truncated": len(rows) > ROWS}


def summary(db):
    state = latest(db)
    n, first, last = db.execute("SELECT COUNT(*), MIN(date), MAX(date) FROM workouts").fetchone()
    monday = (dt.date.today() - dt.timedelta(days=dt.date.today().weekday())).isoformat()
    recent = [{"date": d, "name": nm, "volume": v, "minutes": round((e - s) / 60000) if s and e and e > s else None,
               "working_sets": db.execute("SELECT COUNT(*) FROM sets WHERE workout_id = ? AND done AND NOT warmup", (wid,)).fetchone()[0]}
              for wid, d, nm, v, s, e in db.execute(
                  "SELECT id, date, name, volume, start_ms, end_ms FROM workouts ORDER BY date DESC, start_ms DESC LIMIT 5")]
    bw = db.execute("SELECT date, weight FROM bodyweight ORDER BY date DESC, time DESC LIMIT 1").fetchone()
    return {
        "unit": (state or {}).get("unit", "kg"),
        "workouts": n, "first_date": first, "last_date": last,
        "this_week": db.execute("SELECT COUNT(*), COALESCE(SUM(volume), 0) FROM workouts WHERE date >= ?", (monday,)).fetchone(),
        "recent_workouts": recent,
        "body_weight": {"date": bw[0], "weight": bw[1]} if bw else None,
        "motion_sets_recorded": db.execute("SELECT COUNT(*) FROM motion_files WHERE kind IS NULL").fetchone()[0],
    }


def exercise_history(db, name: str, limit: int = 20):
    state = latest(db)
    trained = [ex for ex, in db.execute(f"SELECT DISTINCT s.exercise_id FROM sets s WHERE {WORK}")]
    words = name.lower().split()
    # Every word found in the name; whole-word matches first ("lat" before "lateral"), then the shortest name.
    exact = lambda ex: sum(w in name_of(ex, state).lower().split() for w in words)
    hits = sorted((ex for ex in trained if all(w in name_of(ex, state).lower() for w in words)),
                  key=lambda ex: (-exact(ex), len(name_of(ex, state))))
    if not hits:
        return {"error": f"No trained exercise matches '{name}'.", "trained": sorted(name_of(ex, state) for ex in trained)}
    ex = hits[0]
    rows = sessions(db, ex)[-limit:]
    return {
        "exercise": name_of(ex, state), "exercise_id": ex, "other_matches": [name_of(h, state) for h in hits[1:]],
        "sessions": [{"date": d.isoformat(), "best_e1rm": round(b, 1), "best_set": {"weight": w, "reps": r}, "working_sets": n, "volume": v}
                     for d, b, w, r, n, v in rows],
    }


def routines(db):
    """The saved routines from the latest document: each exercise's planned sets, reps, weight and rest."""
    state = latest(db) or {}
    out = []
    for r in state.get("routines") or []:
        if not isinstance(r, dict):
            continue
        exercises = []
        for e in r.get("ex") or []:
            if not isinstance(e, dict):
                continue
            plan = {k: e[k] for k in ("sets", "reps", "repsMin", "repsMax", "weight", "sec", "min", "restSec", "mode", "note") if e.get(k) not in (None, "")}
            exercises.append({"exercise": name_of(e.get("id"), state), "exercise_id": e.get("id"), **plan})
        out.append({"id": r.get("id"), "name": r.get("name"), "exercises": exercises})
    return {"unit": state.get("unit", "kg"), "routines": out}


def build(folder: Path) -> MCPServer:
    db = connect(folder)
    server = MCPServer("hexplate", instructions="Read-only access to one person's Hexplate workout log: workouts, sets, "
                       "body weight and the Apple Watch rep counter's recordings. Start with `summary`; use `query` for anything else.")
    ro = ToolAnnotations(readOnlyHint=True, idempotentHint=True, openWorldHint=False)

    @server.tool(annotations=ro)
    def get_summary() -> dict:
        """Totals, the last five workouts, this week (count, volume), latest body weight."""
        return summary(db)

    @server.tool(annotations=ro)
    def get_exercise_history(name: str, limit: int = 20) -> dict:
        """One exercise's sessions, oldest first: best set, estimated 1RM (Epley), working sets, volume.
        `name` is matched by words, e.g. "lat pulldown"."""
        return exercise_history(db, name, limit)

    @server.tool(annotations=ro)
    def get_routines() -> dict:
        """The saved routines (the plan): each exercise with its planned sets, reps (or a repsMin–repsMax
        range), weight, hold seconds (`sec`), cardio minutes (`min`), restSec and the lifter's note."""
        return routines(db)

    @server.tool(annotations=ro)
    def get_schema() -> str:
        """The tables and columns `query` can read, units, and the SQL helper functions."""
        return SCHEMA

    @server.tool(annotations=ro)
    def run_query(sql: str) -> dict:
        """One read-only SQLite SELECT (500 rows at most, 5 s). Call get_schema first.
        exname(exercise_id) and e1rm(weight, reps) are available."""
        return query(db, sql)

    return server
