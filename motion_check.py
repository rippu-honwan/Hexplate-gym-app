#!/usr/bin/env python3
"""Label the watch's motion CSVs and check their quality (rep counter, Stage B / Phase 3).

Each set CSV (`<stamp>_<exId>_s<n>.csv`, header line `# {json}`, then t,ax,ay,az,...) is joined to
the set the app logged: same workout (`wid`), exercise and set number, preferring the set whose
`at` equals the CSV's `end`. The logged reps are the label (the user corrects them); the watch's
own count (`reps`, `auto`) stays beside it. A CSV whose workout is not in the given states (a test,
a discarded workout) gets no label and is left out of the label file.

Quality flags per file: sample rate off 50 Hz, gaps, a recording that starts after the set did,
accelerometer saturation, no movement at all.

    python3 analysis/motion_check.py --state STATE.json [--state ...] [--wrist L] DIR [DIR ...]

Until the app uploads (Stage C), copy the phone's files and state with devicectl first:

    xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
      --domain-identifier com.rippuhonwan.mygym --source Documents/motion --destination data/motion-phone
    (and --source "Library/Application Support/Hexplate/state.json" for the state)

Writes data/motion-labels.csv (git-ignored: motion data is personal data) and prints a summary.
ponytail: stdlib only, whole files in memory (a set is ~200 KB); pandas when the notebook comes.
"""
import argparse, csv, glob, json, math, os, re, statistics, sys

NAME = re.compile(r"_(?P<ex>[^_]+)_s(?P<set>\d+)\.csv$")
SAT_G = 15.5     # Series 9 accelerometer range is +-16 g; userAccel near it means clipping
STILL_G = 0.02   # whole-file RMS of userAccel under this: the wrist never moved


def read_csv(path):
    with open(path) as f:
        first = f.readline()
        if not first.startswith("# "):
            return None, []
        meta = json.loads(first[2:])
        rows = [r for r in csv.DictReader(f)]
    return meta, rows


SPANS = []  # (start, end) ms of every saved workout, for files whose sets were not saved


def index_sets(states):
    """wid -> exId -> list of logged sets, from every workout in the given state files."""
    out = {}
    for path in states:
        s = json.load(open(path))
        for w in s.get("workouts", []):
            if w.get("start") and w.get("end"):
                SPANS.append((w["start"], w["end"]))
            for e in w.get("entries", []):
                out.setdefault(w["id"], {}).setdefault(e["id"], e.get("sets", []))
    return out


def join(meta, sets_by_wid):
    sets = sets_by_wid.get(meta.get("wid"), {}).get(meta.get("exId"))
    end = meta.get("end")
    if sets is None:
        # A workout the watch started carries the watch's id (`watch-...`) in its files and is
        # saved under the phone's: same exercise, a set finished within 2 s of the file's end.
        near = [s for w in sets_by_wid.values() for s in w.get(meta.get("exId"), [])
                if end is not None and s.get("at") is not None and abs(s["at"] - end) <= 2000]
        if near:
            return min(near, key=lambda s: abs(s["at"] - end)), "time"
        # Before 2026-11-18 the phone could log its own ticks instead of the watch's sets: the
        # watch's count is the label when the lifter checked it (edited or rated) and the file
        # falls inside a saved workout (5 min margin); tests and discarded workouts do not.
        if meta.get("checked") and end and any(a - 300_000 <= end <= b + 300_000 for a, b in SPANS):
            return {"r": meta.get("reps"), "w": meta.get("w"), "startedAt": meta.get("startedAt")}, "watch"
        return None, "no workout"
    for s in sets:
        if end is not None and s.get("at") is not None and abs(s["at"] - end) <= 1:
            return s, "at"
    n = meta.get("set", 0) - 1
    return (sets[n], "set no.") if 0 <= n < len(sets) else (None, "no set")


def quality(meta, rows, logged):
    t = [float(r["t"]) for r in rows]
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
    ua = [math.sqrt(float(r["ax"]) ** 2 + float(r["ay"]) ** 2 + float(r["az"]) ** 2) for r in rows]
    if max(ua) >= SAT_G:
        flags.append("saturated")
    rms = math.sqrt(sum(a * a for a in ua) / len(ua))
    if rms < STILL_G:
        flags.append("no movement")
    # The set began before the window did: its first reps are missing from the file.
    started = (logged or {}).get("startedAt") or meta.get("startedAt")
    late = (meta["start"] - started) / 1000 if started and meta.get("start") else None
    if late is not None and late > 2:
        flags.append(f"starts {late:.0f} s late")
    # Cut at an edge: moving in the first (last) second as much as during the set. A busy start
    # alone is the walk to the machine; with a rep counted in the first 2 s, the window began
    # mid-set. Thresholds from the 74 clean sets to 2026-11-18 (start median 0.36, end 0.04-0.25).
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
    moving = rms >= STILL_G and dur >= 5  # a still or tiny file is "busy" at its edges too
    if moving and head >= 0.6 and first_rep is not None and first_rep < 2:
        flags.append("clipped start")
    if moving and tail >= 0.6:
        flags.append("clipped end")
    return {"rows": len(t), "dur_s": round(dur, 1), "hz": round(hz, 1), "max_gap_s": round(gap, 3),
            "rms_g": round(rms, 3), "late_s": None if late is None else round(late, 1),
            "head": round(head, 2), "tail": round(tail, 2), "first_rep_s": first_rep}, flags


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--state", action="append", required=True)
    ap.add_argument("--wrist", default="L", help="wrist for files recorded before the header had it")
    ap.add_argument("--out", default="data/motion-labels.csv")
    a = ap.parse_args()

    sets_by_wid = index_sets(a.state)
    # A file can be in two folders (the phone's copy and the server's): once, by name.
    files = sorted({os.path.basename(p): p for d in a.dirs for p in glob.glob(os.path.join(d, "**", "*.csv"), recursive=True)
                    if NAME.search(p) and not re.search(r"_(watchlog|synclog|hr)_", p)}.items())
    files = [p for _, p in files]
    labels, flagged, unjoined, rates = [], [], 0, []
    for p in files:
        meta, rows = read_csv(p)
        if meta is None:
            continue
        logged, how = join(meta, sets_by_wid)
        q, flags = quality(meta, rows, logged)
        if q.get("hz"):
            rates.append(q["hz"])
        if flags:
            flagged.append((os.path.basename(p), flags))
        if logged is None:
            unjoined += 1
            continue
        # Matched by set number only, and the counts disagree: maybe not the same set.
        if how == "set no." and not meta.get("checked") and logged.get("r") != meta.get("reps"):
            flags.append("check label")
            flagged.append((os.path.basename(p), ["check label"]))
        side = meta.get("side")
        part = (logged.get("sides") or {}).get(side, {}) if side else {}
        labels.append({
            "file": os.path.basename(p), "date": os.path.basename(p)[:8], "wid": meta.get("wid"),
            "exId": meta.get("exId"), "name": meta.get("name"), "bodyPart": meta.get("bodyPart"),
            "set": meta.get("set"), "side": side or "", "wrist": meta.get("wrist", a.wrist),
            "reps": part.get("r", logged.get("r")), "w": part.get("w", logged.get("w")),
            "rir": part.get("rir", logged.get("rir")), "watch_reps": meta.get("reps"),
            "watch_auto": meta.get("auto"), "checked": meta.get("checked"), "join": how,
            "flags": "; ".join(flags), **q,
        })

    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(labels[0]) if labels else ["file"])
        w.writeheader()
        w.writerows(labels)

    print(f"{len(files)} set files, {len(labels)} labelled, {unjoined} without a logged set (tests, discarded)")
    by = {}
    for r in labels:
        by[r["join"]] = by.get(r["join"], 0) + 1
    print("joined by:", ", ".join(f"{k} {v}" for k, v in sorted(by.items())))
    if rates:
        print(f"sample rate: median {statistics.median(rates):.1f} Hz, min {min(rates):.1f}, max {max(rates):.1f}")
    exact = [r for r in labels if r["watch_auto"] is not None and r["reps"] is not None and not r["flags"]]
    if exact:
        hit = sum(1 for r in exact if r["watch_auto"] == r["reps"])
        mae = statistics.mean(abs(r["watch_auto"] - r["reps"]) for r in exact)
        print(f"live count (clean sets) vs logged reps: exact {hit}/{len(exact)}, MAE {mae:.2f}")
    per, names = {}, {}
    for r in labels:
        if not r["flags"]:
            per[r["exId"]] = per.get(r["exId"], 0) + 1
            if (r["name"] or "").isascii() or r["exId"] not in names:
                names[r["exId"]] = r["name"]
    print("clean labelled sets per exercise:")
    for k, v in sorted(per.items(), key=lambda x: -x[1]):
        print(f"  {v:3d}  {k} {names[k]}")
    print(f"{len(flagged)} files flagged:")
    for name, fl in flagged:
        print(f"  {name}: {', '.join(fl)}")
    print(f"labels -> {a.out}")


if __name__ == "__main__":
    sys.exit(main())
