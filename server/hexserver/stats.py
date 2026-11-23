"""What the dashboard shows, read from the latest document the phone sent (the same numbers the
app shows, by the same rules: openGym's lib/history.js, muscles.js and muscle-targets.js).

Volume is the workout's own `vol`, as the app saved it (warm-ups and body weight counted or not,
by your settings). Work sets are ticked sets that are not warm-ups, a per-side set once per side.
"""
import datetime as dt
import json
import math
from functools import cache

from .i18n import exercise, t
from .queries import CATALOGUE, name_of

# lib/muscle-targets.js DEFAULT_TARGETS, in body order: weekly working sets per main muscle.
DEFAULT_TARGETS = [("chest", (10, 20)), ("upper-back", (10, 20)), ("deltoids", (8, 20)), ("biceps", (8, 18)), ("triceps", (6, 16)),
                   ("quadriceps", (8, 18)), ("hamstring", (6, 16)), ("gluteal", (4, 16)), ("calves", (8, 16)), ("abs", (6, 16))]


@cache
def catalogue() -> dict:
    return json.loads(CATALOGUE.read_text()) if CATALOGUE.exists() else {"exercises": [], "meta": {}}


@cache
def exercise_index() -> dict:
    return {e["id"]: e for e in catalogue()["exercises"]}


def muscle_name(slug: str) -> str:
    return t(catalogue()["meta"].get("muscleNames", {}).get(slug) or slug.replace("-", " ").title())


def js_round1(x: float) -> float:
    return math.floor(x * 10 + 0.5) / 10


def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) else None


# MARK: sets and workouts

def is_warmup(s) -> bool:
    s = s if isinstance(s, dict) else {}
    phase = s.get("phase")
    return phase == "warmup" if phase not in (None, "") else s.get("warmup") is True


def is_side(s) -> bool:
    sides = s.get("sides") if isinstance(s, dict) else None
    return isinstance(sides, dict) and bool(sides.get("L")) and bool(sides.get("R"))


def done_units(s) -> int:
    if is_side(s):
        return int(s["sides"]["L"].get("done") is True) + int(s["sides"]["R"].get("done") is True)
    return int(isinstance(s, dict) and s.get("done") is True)


def work_sets(w) -> int:
    return sum(done_units(s) for e in entries(w) for s in sets(e) if not is_warmup(s))


def entries(w):
    return [e for e in (w.get("entries") or []) if isinstance(e, dict)]


def sets(e):
    return [s for s in (e.get("sets") or []) if isinstance(s, dict)]


def workouts(state):
    """Logged workouts with a valid day, newest first (later-stored first within a day)."""
    ws = [(i, w) for i, w in enumerate((state or {}).get("workouts") or []) if isinstance(w, dict) and day(w)]
    return [w for _, w in sorted(ws, key=lambda p: (day(p[1]), p[0]), reverse=True)]


def day(w):
    d = w.get("d")
    try:
        return d if isinstance(d, str) and dt.date.fromisoformat(d).isoformat() == d else None
    except ValueError:
        return None


def minutes(w):
    s, e = num(w.get("start")), num(w.get("end"))
    return round((e - s) / 60000) if s and e and e > s else None


def volume(w) -> float:
    return num(w.get("vol")) or 0


def unit(state) -> str:
    return "lb" if (state or {}).get("unit") == "lb" else "kg"


def ex_name(ex_id, state, entry=None) -> str:
    """The catalogue's or your own name, else what the entry saved, else the id; in Chinese the
    way the phone shows it (i18n.exercise)."""
    n = name_of(ex_id, state)
    if n == str(ex_id) and entry:
        saved = (entry.get("exercise") or entry.get("ex") or {}).get("n") if isinstance(entry.get("exercise") or entry.get("ex"), dict) else None
        return saved or n
    return exercise(ex_id, n, state)


# MARK: weeks

def week_start(state) -> int:
    """0 = Sunday, 1 = Monday (the profile's `weekStart`)."""
    return 0 if (state or {}).get("weekStart") == 0 else 1


def week_key(iso: str, ws: int) -> str | None:
    try:
        d = dt.date.fromisoformat(iso)
    except (TypeError, ValueError):
        return None
    weekday = (d.weekday() + 1) % 7          # 0 = Sunday, like JavaScript's getDay
    return (d - dt.timedelta(days=(weekday - ws) % 7)).isoformat()




# MARK: muscles

def muscle_weights(ex_id, state) -> dict:
    ex = exercise_index().get(str(ex_id))
    if ex:
        return {k: v for k, v in (ex.get("mw") or {}).items() if v > 0}
    # ponytail: your own exercises count only by the muscle weights they state (no name guessing).
    own = next((c for c in (state or {}).get("customEx") or [] if isinstance(c, dict) and str(c.get("id")) == str(ex_id)), {})
    return {k: v for k, v in (own.get("muscleWeights") or {}).items() if isinstance(v, (int, float)) and 0 < v <= 1}


def load_of(ws, state) -> dict:
    """Effective sets per muscle: ticked work sets × each exercise's muscle weights (loadOfWorkouts)."""
    load = {}
    for w in ws:
        for e in entries(w):
            n = sum(1 for s in sets(e) if s.get("done") is True and not is_warmup(s))
            if n:
                for slug, share in muscle_weights(e.get("id"), state).items():
                    load[slug] = load.get(slug, 0) + share * n
    return load


def target_of(state, slug, fallback):
    own = ((state or {}).get("muscleTargets") or {}).get(slug)
    if isinstance(own, list) and len(own) == 2 and all(num(x) is not None for x in own):
        lo, hi = math.floor(own[0] + 0.5), math.floor(own[1] + 0.5)
        if 0 <= lo <= hi <= 40:
            return lo, hi
    return fallback


def weekly_muscle_sets(state, today: str):
    """Every main muscle's working sets this week against its range (weeklyMuscleSets)."""
    ws = week_start(state)
    wk = week_key(today, ws)
    load = load_of([w for w in workouts(state) if week_key(day(w), ws) == wk], state)
    out = []
    for slug, fallback in DEFAULT_TARGETS:
        lo, hi = target_of(state, slug, fallback)
        n = js_round1(load.get(slug, 0))
        out.append({"slug": slug, "name": muscle_name(slug), "sets": n, "lo": lo, "hi": hi,
                    "status": "below" if n < lo - 1e-9 else "above" if n > hi + 1e-9 else "in"})
    return out


# MARK: one-rep max (Epley, as the dashboard has always shown it)

def e1rm(w, r):
    return w * (1 + r / 30) if w and r and w > 0 and r > 0 else None


def best_set(e):
    """The work set with the highest Epley estimate: (estimate, weight, reps), or None."""
    best = None
    for s in sets(e):
        if is_warmup(s):
            continue
        rows = [s["sides"]["L"], s["sides"]["R"]] if is_side(s) else [s]
        for x in rows:
            if x.get("done") is True and num(x.get("w")) and num(x.get("r")):
                est = e1rm(x["w"], x["r"])
                if est and (best is None or est > best[0]):
                    best = (est, x["w"], x["r"])
    return best


def exercise_sessions(state, ex_id):
    """Each workout with this exercise, oldest first: {d, id, est, w, r, sets, volume}."""
    out = []
    for w in reversed(workouts(state)):
        es = [e for e in entries(w) if str(e.get("id")) == str(ex_id)]
        if not es:
            continue
        b = max((x for x in (best_set(e) for e in es) if x), default=None)
        n = sum(done_units(s) for e in es for s in sets(e) if not is_warmup(s))
        v = sum((num(x.get("w")) or 0) * (num(x.get("r")) or 0) for e in es for s in sets(e) if not is_warmup(s)
                for x in ([s["sides"]["L"], s["sides"]["R"]] if is_side(s) else [s]) if x.get("done") is True)
        if n:
            out.append({"d": day(w), "id": w.get("id"), "est": b[0] if b else None, "w": b[1] if b else None, "r": b[2] if b else None,
                        "sets": n, "volume": v, "pr": str(ex_id) in [str(p) for p in (w.get("prs") or [])]})
    return out


def trained_exercises(state):
    """(id, sessions, last day) of every exercise with a work set, most recent first."""
    seen = {}
    for w in workouts(state):
        for e in entries(w):
            if any(done_units(s) for s in sets(e) if not is_warmup(s)):
                i = str(e.get("id"))
                n, last = seen.get(i, (0, day(w)))
                seen[i] = (n + 1, last)
    return sorted(((i, n, last) for i, (n, last) in seen.items()), key=lambda t: (t[2], t[1]), reverse=True)


# MARK: body

def weigh_ins(state):
    """(day, weight) of every weigh-in, oldest first."""
    out = []
    for b in (state or {}).get("bodyweight") or []:
        if isinstance(b, dict) and num(b.get("w")) and isinstance(b.get("d"), str):
            out.append((b["d"][:10], b["w"]))
    return sorted(out)


def measurements(state):
    """[(day, {name: (value, unit)})], oldest first: the tape (cm), body fat and the scale's readings."""
    tape = {"neck": "Neck", "chest": "Chest", "waist": "Waist", "abdomen": "Abdomen", "hips": "Hips", "bicepLeft": "Left arm",
            "bicepRight": "Right arm", "forearmLeft": "Left forearm", "forearmRight": "Right forearm", "thighLeft": "Left thigh",
            "thighRight": "Right thigh", "calfLeft": "Left calf", "calfRight": "Right calf", "ankleLeft": "Left ankle", "ankleRight": "Right ankle"}
    out = []
    for m in (state or {}).get("measurements") or []:
        if not isinstance(m, dict) or not isinstance(m.get("d"), str):
            continue
        vals = {}
        if num(m.get("bodyFat")) is not None:
            vals["Body fat"] = (m["bodyFat"], "%")
        for k, label in tape.items():
            if num(m.get(k)) is not None:
                vals[label] = (m[k], "cm")
        for o in m.get("other") or []:
            if isinstance(o, dict) and num(o.get("value")) is not None and o.get("name"):
                vals[o["name"]] = (o["value"], "" if o.get("unit") in (None, "none") else o["unit"])
        if vals:
            out.append((m["d"][:10], vals))
    return sorted(out, key=lambda t: t[0])


# MARK: plan

def routines(state):
    return [r for r in (state or {}).get("routines") or [] if isinstance(r, dict) and r.get("id") is not None]
