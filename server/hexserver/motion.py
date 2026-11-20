"""Motion data per workout, for the dashboard's Motion page: each set file the watch recorded,
checked for quality the way analysis/motion_check.py checks it (quality() is the same function,
test_motion.py holds them together), joined to the set it belongs to in the saved workout.
"""
import json
import math
import statistics
from pathlib import Path

SAT_G = 15.5     # Series 9 accelerometer range is +-16 g; userAccel near it means clipping
STILL_G = 0.02   # whole-file RMS of userAccel under this: the wrist never moved
NEAR_MS = 5 * 60_000   # a watch-started workout's files fall inside the saved one's span, give or take


def read(path: Path):
    """The file's JSON header and its columns t, ax, ay, az as floats (None for a file that is not a set)."""
    try:
        with open(path) as f:
            first = f.readline()
            if not first.startswith("# "):
                return None, None
            meta = json.loads(first[2:])
            header = f.readline().strip().split(",")
            idx = {k: header.index(k) for k in ("t", "ax", "ay", "az") if k in header}
            if len(idx) < 4:
                return meta, None
            cols = {k: [] for k in idx}
            for line in f:
                parts = line.split(",")
                try:
                    vals = {k: float(parts[i]) for k, i in idx.items()}
                except (ValueError, IndexError):
                    continue
                for k, v in vals.items():
                    cols[k].append(v)
    except (OSError, ValueError):
        return None, None
    return meta, cols


def quality(meta, cols, logged):
    """analysis/motion_check.py quality() on columns: (numbers, flags)."""
    t = cols["t"]
    flags = []
    if len(t) < 2:
        return {"rows": len(t)}, ["empty"]
    dts = [b - a for a, b in zip(t, t[1:])]
    dur = t[-1] - t[0]
    hz = (len(t) - 1) / dur if dur > 0 else 0
    gap = max(dts)
    if abs(hz - meta.get("hz", 50)) > 2:
        flags.append(f"rate {hz:.1f} Hz")
    if gap > 0.1:
        flags.append(f"gap {gap:.2f} s")
    ua = [math.sqrt(x * x + y * y + z * z) for x, y, z in zip(cols["ax"], cols["ay"], cols["az"])]
    if max(ua) >= SAT_G:
        flags.append("saturated")
    rms = math.sqrt(sum(a * a for a in ua) / len(ua))
    if rms < STILL_G:
        flags.append("no movement")
    started = (logged or {}).get("startedAt") or meta.get("startedAt")
    late = (meta["start"] - started) / 1000 if started and meta.get("start") else None
    if late is not None and late > 2:
        flags.append(f"starts {late:.0f} s late")
    reps = (logged or {}).get("r") or meta.get("reps")
    if reps and dur > 0 and not 1.5 <= dur / reps <= 12:
        flags.append(f"{dur / reps:.1f} s per rep")
    k = max(1, min(len(ua), int(hz / 2)))
    c = [0.0]
    for v in ua:
        c.append(c[-1] + v)
    sm = sorted((c[i + k] - c[i]) / k for i in range(len(ua) - k + 1))
    act = sm[int(0.9 * (len(sm) - 1))] or 1e-9
    edge = lambda sel: statistics.mean(u for u, x in zip(ua, t) if sel(x)) / act
    head, tail = edge(lambda x: x < t[0] + 1), edge(lambda x: x > t[-1] - 1)
    first_rep = next((e[0] for e in meta.get("helpers", {}).get("log", [])
                      if isinstance(e[1], str) and e[1].startswith("rep 1 ")), None)
    moving = rms >= STILL_G and dur >= 5
    if moving and head >= 0.6 and first_rep is not None and first_rep < 2:
        flags.append("clipped start")
    if moving and tail >= 0.6:
        flags.append("clipped end")
    return {"rows": len(t), "dur_s": round(dur, 1), "hz": round(hz, 1), "max_gap_s": round(gap, 3),
            "rms_g": round(rms, 3), "late_s": None if late is None else round(late, 1),
            "head": round(head, 2), "tail": round(tail, 2), "first_rep_s": first_rep}, flags


def workout_of(meta, workouts):
    """The saved workout a file belongs to: by id, else (a workout the watch started, `watch-…`)
    the one whose time span holds the file's end."""
    wid, end = meta.get("wid"), meta.get("end")
    for w in workouts:
        if str(w.get("id")) == str(wid):
            return w
    if isinstance(end, (int, float)):
        for w in workouts:
            s, e = w.get("start"), w.get("end")
            if isinstance(s, (int, float)) and isinstance(e, (int, float)) and s - NEAR_MS <= end <= e + NEAR_MS:
                return w
    return None


def logged_set(meta, workout):
    """The logged set behind a file: the one finished within 2 s of the file's end, else the same set number."""
    sets = [s for e in workout.get("entries", []) if str(e.get("id")) == str(meta.get("exId")) for s in e.get("sets", [])
            if isinstance(s, dict) and s.get("phase") != "warmup"]
    end = meta.get("end")
    timed = [s for s in sets if isinstance(s.get("at"), (int, float)) and isinstance(end, (int, float)) and abs(s["at"] - end) <= 2000]
    s = min(timed, key=lambda s: abs(s["at"] - end)) if timed else None
    if s is None:
        n = (meta.get("set") or 0) - 1
        s = sets[n] if 0 <= n < len(sets) else None
    if s and isinstance(s.get("sides"), dict) and meta.get("side") in s["sides"]:
        s = {**s["sides"][meta["side"]], "startedAt": s.get("startedAt")}
    return s


def by_workout(metas, workouts):
    """{workout id: [file header, …]} for the set files that belong to a saved workout, oldest set first."""
    out = {}
    for m in metas:
        w = workout_of(m, workouts)
        if w is not None:
            out.setdefault(str(w.get("id")), []).append(m)
    for fs in out.values():
        fs.sort(key=lambda m: m.get("end") or 0)
    return out


def sets(folder: Path, metas, workout):
    """Each set file of one workout read and checked: header, columns, logged set, numbers, flags."""
    out = []
    for m in metas:
        meta, cols = read(folder / m["file"])
        if meta is None or cols is None:
            continue
        logged = logged_set(meta, workout)
        q, flags = quality(meta, cols, logged)
        reps = (logged or {}).get("r") if isinstance((logged or {}).get("r"), (int, float)) else meta.get("reps")
        out.append({"file": m["file"], "meta": meta, "cols": cols, "q": q, "flags": flags,
                    "reps": reps, "auto": meta.get("auto") if isinstance(meta.get("auto"), int) else None})
    return out


def live_rows(rows):
    """Per exercise, the watch's live count against the logged reps on clean sets:
    (exercise id, sets, mean reps, mean abs error, exact share, bias)."""
    per = {}
    for r in rows:
        if r["flags"] or r["auto"] is None or not isinstance(r["reps"], (int, float)):
            continue
        per.setdefault(str(r["meta"].get("exId")), []).append(r)
    out = []
    for ex, rs in per.items():
        err = [r["auto"] - r["reps"] for r in rs]
        out.append((ex, len(rs), statistics.mean(r["reps"] for r in rs), statistics.mean(abs(e) for e in err),
                    sum(e == 0 for e in err) / len(rs), statistics.mean(err)))
    return sorted(out, key=lambda r: -r[1])


def smooth(values, n=25):
    """Centred rolling mean (pandas rolling(n, center=True).mean() without the NaN ends)."""
    h = n // 2
    c = [0.0]
    for v in values:
        c.append(c[-1] + v)
    return [(c[min(len(values), i + h + 1)] - c[max(0, i - h)]) / (min(len(values), i + h + 1) - max(0, i - h)) for i in range(len(values))]
