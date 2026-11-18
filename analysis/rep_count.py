#!/usr/bin/env python3
"""Count reps from the watch's motion CSVs and evaluate against the logged reps (Stage D).

Every method starts the same way: one motion channel (gravity = wrist orientation, userAccel or
rotation rate), band-passed to rep speed (0.1-1.2 Hz) and projected on its main axis (PCA).

- peaks: peaks standing out by a share of the set's range, at least 1 / 0.8 Hz apart.
- acf:   the set's own rep period from its autocorrelation; peaks at least 0.6 period apart.
- span:  the active stretch (envelope above a share of its top) divided by that period.

Each method has a small grid. Leave-one-workout-out: the best grid point on the other workouts
predicts this one, so no set is scored with parameters it helped pick. With ~65 sets a big grid
overfits (seen: 1.2 in-sample, 1.9 held out), so keep grids small.

    python3 analysis/rep_count.py [--labels data/motion-labels.csv] [--motion server/data/motion]

Labels come from motion_check.py (sets it flags are left out). Needs numpy and scipy.
"""
import argparse, csv, itertools, json, os, statistics
from functools import cache

import numpy as np
from scipy.signal import butter, find_peaks, sosfiltfilt

COLS = {"gravity": ["gx", "gy", "gz"], "accel": ["ax", "ay", "az"], "rotation": ["rx", "ry", "rz"]}
LO, HI = 0.1, 1.2           # Hz: a rep takes 0.8-10 s
PERIOD = (1.2, 10.0)        # s: rep periods the autocorrelation may pick
CLIP = 2.0                  # x the 90th percentile: what is left of a spike after clipping
DATA = {}                   # file -> columns, filled by main()


def load(path):
    with open(path) as f:
        meta = json.loads(f.readline()[2:])
        rows = list(csv.DictReader(f))
    return meta, {k: np.array([float(r[k]) for r in rows]) for k in rows[0]}


@cache
def channel(f, signal, hi=HI):
    """The band-passed channel projected on its main axis: one number per sample, and the rate."""
    d = DATA[f]
    hz = (len(d["t"]) - 1) / (d["t"][-1] - d["t"][0])
    x = np.column_stack([d[c] for c in COLS[signal]])
    x = sosfiltfilt(butter(2, [LO, hi], btype="band", fs=hz, output="sos"), x - x.mean(0), axis=0)
    # Grabbing and letting go of the handle swing far more than a rep: clip them so they set
    # neither the main axis nor the scale.
    lim = CLIP * np.percentile(np.abs(x), 90, axis=0)
    x = np.clip(x, -lim, lim)
    _, _, vt = np.linalg.svd(x, full_matrices=False)
    return x @ vt[0], hz


def peaks(s, prom, distance):
    """Peaks and troughs each mark a rep; their mean does not depend on the axis' sign."""
    amp = np.percentile(s, 95) - np.percentile(s, 5)
    return round(sum(len(find_peaks(v, prominence=prom * amp, distance=max(1, int(distance)))[0]) for v in (s, -s)) / 2)


def period(s, hz):
    """Seconds per rep: the first autocorrelation peak nearly as high as the highest
    (a multiple of the period can score as high, the first one is the rep)."""
    n = len(s)
    ac = np.fft.irfft(np.abs(np.fft.rfft(s - s.mean(), 2 * n)) ** 2)[:n]
    ac /= ac[0] or 1
    lo, hi = int(PERIOD[0] * hz), min(int(PERIOD[1] * hz), n // 2)
    p, _ = find_peaks(ac[:hi])
    p = p[p >= lo]
    if not len(p):
        return None, 0
    top = ac[p].max()
    if top <= 0:
        return None, 0   # nothing repeats
    return p[ac[p] >= 0.8 * top][0] / hz, top


def m_peaks(f, signal, prom):
    s, hz = channel(f, signal, 0.8)
    return peaks(s, prom, hz / 0.8)


def m_acf(f, signal, prom):
    s, hz = channel(f, signal)
    T, _ = period(s, hz)
    return peaks(s, prom, 0.6 * T * hz if T else hz / HI)


def m_span(f, signal, level):
    s, hz = channel(f, signal)
    T, _ = period(s, hz)
    if not T:
        return 0
    k = max(1, int(T * hz))
    env = np.sqrt(np.convolve(s * s, np.ones(k) / k, "same"))
    on = np.flatnonzero(env >= level * np.percentile(env, 90))
    return round((on[-1] - on[0]) / hz / T) if len(on) else 0


def m_auto(f, prom):
    """The channel that repeats best, then peaks that stand out by `prom` of a typical rep's:
    the median prominence of the biggest duration / period peaks (as if the whole set were reps)."""
    cands = []
    for sig in COLS:
        s, hz = channel(f, sig)
        T, h = period(s, hz)
        cands.append((h, s, hz, T))
    _, s, hz, T = max(cands, key=lambda c: c[0])
    if not T:
        return 0
    n = []
    for v in (s, -s):
        _, pr = find_peaks(v, distance=int(0.6 * T * hz), prominence=0)
        pr = np.sort(pr["prominences"])[::-1]
        ref = np.median(pr[:max(1, int(len(s) / hz / T))]) if len(pr) else 0
        n.append(int((pr >= prom * ref).sum()))
    return round(sum(n) / 2)


METHODS = {
    "auto": (m_auto, {"prom": [0.2, 0.3, 0.4, 0.5]}),
    "peaks": (m_peaks, {"signal": list(COLS), "prom": [0.4, 0.5, 0.6, 0.7, 0.8, 0.9]}),
    "acf": (m_acf, {"signal": list(COLS), "prom": [0.1, 0.2, 0.3, 0.4]}),
    "span": (m_span, {"signal": list(COLS), "level": [0.2, 0.3, 0.4, 0.5]}),
}


def score(pairs):
    err = [abs(p - y) for p, y in pairs]
    return statistics.mean(err), sum(e == 0 for e in err), sum(e <= 1 for e in err)


def line(label, pairs):
    m, e, w = score(pairs)
    n = len(pairs)
    return f"  {label:<18} MAE {m:.2f}  exact {e:2d}/{n} ({e / n:.0%})  within 1 {w:2d}/{n}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--labels", default="data/motion-labels.csv")
    ap.add_argument("--motion", default="server/data/motion")
    a = ap.parse_args()

    sets = [r for r in csv.DictReader(open(a.labels)) if not r["flags"] and r["reps"]]
    DATA.update({r["file"]: load(os.path.join(a.motion, r["file"]))[1] for r in sets})
    y = {r["file"]: int(r["reps"]) for r in sets}
    workouts = sorted({r["wid"] for r in sets})
    print(f"{len(sets)} clean labelled sets, {len(workouts)} workouts, leave-one-workout-out")

    held = {}
    for name, (fn, grid) in METHODS.items():
        keys = [dict(zip(grid, v)) for v in itertools.product(*grid.values())]
        pred = {f: [fn(f, **k) for k in keys] for f in y}
        out, chosen = {}, set()
        for w in workouts:
            train = [r["file"] for r in sets if r["wid"] != w]
            i = min(range(len(keys)), key=lambda i: score([(pred[f][i], y[f]) for f in train]))
            chosen.add(tuple(keys[i].values()))
            out.update({r["file"]: pred[r["file"]][i] for r in sets if r["wid"] == w})
        held[name] = out
        print(line(name + " (held out)", [(out[f], y[f]) for f in y]) + f"  picked {sorted(chosen)}")

    med = statistics.median(y.values())
    print(line(f"always {med:g}", [(med, y[f]) for f in y]))
    live = [(int(r["watch_auto"]), y[r["file"]]) for r in sets if r["watch_auto"]]
    print(line("watch live count", live) + "  (sets the watch counted)")

    best = min(held, key=lambda m: score([(held[m][f], y[f]) for f in y]))
    out = held[best]
    print(f"per exercise, {best} (held out): sets, MAE, exact")
    by = {}
    for r in sets:
        by.setdefault(r["name"].split("(")[-1].rstrip(")"), []).append((out[r["file"]], y[r["file"]]))
    for name, pairs in sorted(by.items(), key=lambda x: -len(x[1])):
        m, e, _ = score(pairs)
        print(f"  {len(pairs):2d}  {m:4.1f}  {e}/{len(pairs)}  {name}")
    worst = sorted(out, key=lambda f: -abs(out[f] - y[f]))[:8]
    print("largest misses:", ", ".join(f"{f} {out[f]} vs {y[f]}" for f in worst))


if __name__ == "__main__":
    main()
