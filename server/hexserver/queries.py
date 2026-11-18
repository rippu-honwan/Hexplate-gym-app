"""Reads shared by the dashboard and the MCP server: exercise names and per-session bests."""
import datetime as dt
import json
from functools import cache
from pathlib import Path

CATALOGUE = Path(__file__).resolve().parents[2] / "app/HexplateCore/Sources/HexplateCore/Resources/exercises.json"

# Done working sets with a weight and reps: what estimated 1RM and volume count.
WORK = "s.done AND NOT s.warmup AND s.weight > 0 AND s.reps > 0"


def e1rm(weight, reps):
    """Epley: weight × (1 + reps / 30)."""
    return weight * (1 + reps / 30) if weight and reps else None


@cache
def catalogue_names() -> dict:
    return {e["id"]: e["n"] for e in json.loads(CATALOGUE.read_text())["exercises"]} if CATALOGUE.exists() else {}


def name_of(ex_id, state=None) -> str:
    """The exercise's name: the profile's custom exercises first, then the app's catalogue."""
    custom = {str(c.get("id")): c.get("name") or c.get("n") for c in (state or {}).get("customEx") or [] if isinstance(c, dict)}
    n = custom.get(str(ex_id)) or catalogue_names().get(str(ex_id)) or str(ex_id)
    return " ".join(w[:1].upper() + w[1:] for w in str(n).split(" "))


def sessions(db, ex):
    """Each workout with this exercise, oldest first: (date, best e1RM, its weight, its reps, sets, volume)."""
    out = []
    for d, best, n, vol, wid in db.execute(f"""SELECT w.date, MAX(s.weight * (1 + s.reps / 30.0)), COUNT(*), SUM(s.weight * s.reps), w.id
                                               FROM sets s JOIN workouts w ON w.id = s.workout_id
                                               WHERE s.exercise_id = ? AND {WORK} GROUP BY w.id ORDER BY w.date""", (ex,)).fetchall():
        weight, reps = db.execute(f"""SELECT s.weight, s.reps FROM sets s WHERE s.workout_id = ? AND s.exercise_id = ? AND {WORK}
                                      ORDER BY s.weight * (1 + s.reps / 30.0) DESC LIMIT 1""", (wid, ex)).fetchone()
        out.append((dt.date.fromisoformat(d), best, weight, reps, n, vol))
    return out
