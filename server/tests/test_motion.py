import importlib.util
import json
import math
from pathlib import Path

from hexserver import motion as M

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "app/HexplateCore/Tests/HexplateCoreTests/Fixtures/history-state.json"


def reference():
    """analysis/motion_check.py, the check the Motion page ports."""
    spec = importlib.util.spec_from_file_location("motion_check", ROOT / "analysis" / "motion_check.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def csv_text(meta, n=600, hz=50, gap_at=None, amp=0.3, busy_end=False):
    """A set file: a sine on x at 0.4 Hz with a still last 1.5 s, optionally a gap and a busy end."""
    lines = ["# " + json.dumps(meta), "t,ax,ay,az,rx,ry,rz,gx,gy,gz"]
    t = 0.02
    for i in range(n):
        t += 1 / hz + (0.4 if i == gap_at else 0)
        a = 1.5 if busy_end and i > n - hz else 0 if i > n - 1.5 * hz else amp * math.sin(2 * math.pi * 0.4 * t)
        lines.append(f"{t:.3f},{a:.4f},0.0100,-0.0100,0,0,0,0,0,-1")
    return "\n".join(lines) + "\n"


def test_quality_matches_motion_check(tmp_path):
    ref = reference()
    start = 1_794_000_000_000
    log = {"log": [[1.0, "rep 1 at 1.0"], [3.5, "rep 2"]]}
    cases = [
        ({"hz": 50, "start": start, "reps": 5}, {}, {"r": 5}),
        ({"hz": 50, "start": start, "startedAt": start - 9000, "reps": 3, "helpers": log}, {"gap_at": 200}, None),
        ({"hz": 50, "start": start, "reps": 4, "helpers": log}, {"busy_end": True, "hz": 40}, {"r": 2, "startedAt": start}),
        ({"hz": 50, "reps": 8}, {"amp": 0.001}, None),
        ({"hz": 50, "reps": 8}, {"n": 1}, None),
    ]
    for i, (meta, shape, logged) in enumerate(cases):
        path = tmp_path / f"{i}.csv"
        path.write_text(csv_text(meta, **shape))
        m, cols = M.read(path)
        with open(path) as f:
            f.readline()
            import csv
            rows = list(csv.DictReader(f))
        assert M.quality(m, cols, logged) == ref.quality(meta, rows, logged), i


def test_files_join_their_workout_and_set():
    w = {"id": "w1", "start": 1000, "end": 600_000, "entries": [
        {"id": "0025", "sets": [{"phase": "warmup", "r": 12}, {"r": 10, "at": 100_000}, {"r": 8, "at": 200_000}]}]}
    assert M.workout_of({"wid": "w1"}, [w]) is w
    assert M.workout_of({"wid": "watch-x", "end": 650_000}, [w]) is w        # inside the span, give or take 5 min
    assert M.workout_of({"wid": "watch-x", "end": 999_999_999}, [w]) is None
    assert M.logged_set({"exId": "0025", "end": 201_000, "set": 1}, w)["r"] == 8   # by time first
    assert M.logged_set({"exId": "0025", "set": 1}, w)["r"] == 10                   # warm-ups not counted
    assert M.smooth([0, 0, 3, 0, 0], n=3) == [0, 1, 1, 1, 0]


def test_motion_pages_in_both_languages(client):
    store = client.app.state.store
    state = json.loads(FIXTURE.read_text())
    store.put(state)
    w = state["workouts"][0]
    ex = str(w["entries"][0]["id"])
    for n in (1, 2):
        meta = {"wid": w["id"], "exId": ex, "set": n, "hz": 50, "reps": 6, "auto": 5 + n, "end": 1_794_000_000_000 + n,
                "helpers": {"log": [[2.0, "rep 1 at 2"], [4.5, "rep 2"]]}}
        assert store.save_motion(f"20261118-12000{n}_{ex}_s{n}.csv", csv_text(meta, gap_at=100 if n == 2 else None))
    wid = w["id"]
    assert f'href="/motion/{wid}"' in client.get("/motion").text
    assert f'href="/motion/{wid}"' in client.get(f"/history/{wid}").text
    html = client.get(f"/motion/{wid}").text
    assert "1 of 2 sets are clean." in html and "gap 0.42 s" in html and "reps logged, 6 counted live" in html
    assert html.count("<svg") >= 6
    client.post("/settings/lang", data={"lang": "zh"}, headers={"Origin": "http://testserver"})
    html = client.get(f"/motion/{wid}").text
    assert "動作數據" in html and "2 組中有 1 組沒有問題" in html and "斷層 0.42 秒" in html
    assert "找不到" in client.get("/motion/nope").text
