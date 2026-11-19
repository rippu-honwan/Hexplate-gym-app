"""Cases for SetTrend (lib/set-trend.js): today's entry against last time's, every branch."""
import json, os

def s(w=None, r=None, done=True, **kw):
    o = {"done": done}
    if w is not None: o["w"] = w
    if r is not None: o["r"] = r
    o.update(kw)
    return o

def entry(sets, **target): return {"id": "0043", "target": target, "sets": sets}

last = {"sets": [s(100, 5), s(100, 5), s(100, 5)], "target": {}}
cases = [
    ("heavier same reps", entry([s(102.5, 5), s(100, 5), s(97.5, 5)]), last),
    ("more reps", entry([s(100, 6), s(100, 4), s(100, 5)]), last),
    ("heavier fewer reps e1rm", entry([s(110, 4), s(90, 8), s(105, 4)]), last),
    ("warmups skipped and not done", entry([s(40, 10, warmup=True), s(100, 6), s(100, 5, done=False), s(100, 5)]), last),
    ("extra set has no counterpart", entry([s(100, 5), s(100, 5), s(100, 5), s(100, 5)]), last),
    ("bodyweight reps", entry([s(0, 12), s(0, 10)]), {"sets": [s(0, 10), s(0, 10)], "target": {}}),
    ("assisted less help", entry([s(20, 8), s(30, 8), s(20, 6)], assisted=True), {"sets": [s(25, 8)] * 3, "target": {"assisted": True}}),
    ("timed holds", entry([s(sec=45), s(sec=30), s(sec=40)], mode="time"), {"sets": [s(sec=40)] * 3, "target": {"mode": "time"}}),
    ("cardio", entry([s(min=20, speed=10), s(min=20, speed=9), s(min=20)], mode="cardio"), {"sets": [s(min=20, speed=9.5), s(min=20, speed=9.5), s(min=20)], "target": {"mode": "cardio"}}),
    ("mode changed", entry([s(sec=45)], mode="time"), last),
    ("no last time", entry([s(100, 5)]), None),
    ("side set", entry([{"sides": {"L": {"w": 20, "r": 10, "done": True}, "R": {"w": 20, "r": 10, "done": True}}, "w": 22, "r": 10}]), {"sets": [{"w": 20, "r": 10, "done": True}], "target": {}}),
    ("side set half done", entry([{"sides": {"L": {"w": 20, "r": 10, "done": True}, "R": {"w": 20, "r": 10}}, "w": 22, "r": 10}]), {"sets": [{"w": 20, "r": 10, "done": True}], "target": {}}),
]
out = [{"name": n, "entry": e, "last": l, "formula": f} for (n, e, l) in cases for f in ("epley", "brzycki")]
p = os.path.join(os.path.dirname(__file__), "../HexplateCore/Tests/HexplateCoreTests/Fixtures/trend-cases.json")
json.dump(out, open(p, "w"), indent=1)
print(len(out), "cases")
