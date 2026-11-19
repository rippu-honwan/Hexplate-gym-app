"""Cases for Report (lib/report.js reportData): five months of training, every range kind."""
import json, os, datetime as dt

def s(w=None, r=None, done=True, **kw):
    o = {"done": done}
    if w is not None: o["w"] = w
    if r is not None: o["r"] = r
    o.update(kw)
    return o

def ms(day, hour, minute=0):
    d = dt.datetime.fromisoformat(day).replace(hour=hour, minute=minute, tzinfo=dt.timezone.utc)
    return int(d.timestamp() * 1000)

workouts = []
day = dt.date(2026, 1, 5)
i = 0
while day <= dt.date(2026, 5, 29):
    d = day.isoformat()
    k = i * 2.5
    if i % 2 == 0:
        entries = [
            {"id": "0025", "sets": [s(40, 10, warmup=True), s(60 + k, 8), s(60 + k, 8), s(60 + k, 6, done=i % 5 != 0)]},
            {"id": "0043", "sets": [s(80 + k, 5), s(80 + k, 5), s(80 + k, 5)]},
            {"id": "0017", "target": {"assisted": True}, "sets": [s(30 - i % 10, 8), s(30 - i % 10, 8)]},
        ]
        prs = ["0025", "0043"] if i % 6 == 0 else []
        name = "Upper A"
    else:
        entries = [
            {"id": "0032", "sets": [s(60, 5, warmup=True), s(100 + k, 5), s(100 + k, 4)]},
            {"id": "0652", "sets": [s(0, 8 + i % 4), s(0, 7)]},
            {"id": "0336", "sets": [{"sides": {"L": {"w": 12, "r": 10, "done": True}, "R": {"w": 12, "r": 10, "done": i % 3 != 0}}, "w": 12, "r": 10}]},
        ]
        if i % 4 == 1: entries.append({"id": "0685", "target": {"mode": "cardio"}, "sets": [s(min=20, km=4)]})
        prs = ["0032", "0032"] if i % 7 == 1 else []
        name = "Lower B"
    w = {"id": f"w{i}", "d": d, "name": name, "entries": entries, "prs": prs}
    if i % 3 != 2: w.update(start=ms(d, 7 + i % 12), end=ms(d, 8 + i % 12, 10))
    workouts.append(w)
    # Two a day now and then; a gap of a week in March; mostly every two or three days.
    if i % 11 == 5: workouts.append({"id": f"w{i}b", "d": d, "name": "Extra", "entries": [{"id": "0031", "sets": [s(30, 12), s(30, 10)]}], "prs": []})
    i += 1
    day += dt.timedelta(days=9 if d == "2026-03-09" else 2 + i % 2)

bodyweight = []
day = dt.date(2026, 1, 3)
n = 0
while day <= dt.date(2026, 5, 30):
    b = {"d": day.isoformat(), "w": round(72 - n * 0.15 + (n % 3) * 0.1, 1)}
    if n % 2: b["t"] = ms(b["d"], 6, 30)
    bodyweight.append(b)
    n += 1
    day += dt.timedelta(days=5)

base = {"unit": "kg", "workouts": workouts, "bodyweight": bodyweight}
states = [base, dict(base, weekStart=0, volumeWarmups=True, oneRmFormula="brzycki")]

cases = [
    ("7 days", 0, "7d", None, None, "2026-05-30"),
    ("4 weeks", 0, "4w", None, None, "2026-05-30"),
    ("3 months", 0, "3m", None, None, "2026-05-30"),
    ("3 months from a month end", 0, "3m", None, None, "2026-05-31"),
    ("3 months clamps to February", 1, "3m", None, None, "2026-05-30"),
    ("custom by months", 0, "custom", "2026-01-01", "2026-05-30", "2026-05-30"),
    ("custom swapped ends", 0, "custom", "2026-04-10", "2026-03-01", "2026-05-30"),
    ("custom future end", 1, "custom", "2026-05-01", "2026-07-01", "2026-05-30"),
    ("custom bad from", 0, "custom", "2026-02-30", "2026-04-15", "2026-05-30"),
    ("one day", 0, "custom", "2026-03-02", "2026-03-02", "2026-05-30"),
    ("past range, Sunday weeks", 1, "4w", None, None, "2026-03-20"),
    ("nothing in range", 0, "7d", None, None, "2026-07-30"),
]
out = {"states": states, "cases": [{"name": c[0], "state": c[1], "range": c[2], "from": c[3], "to": c[4], "today": c[5]} for c in cases]}
p = os.path.join(os.path.dirname(__file__), "../HexplateCore/Tests/HexplateCoreTests/Fixtures/report-cases.json")
with open(p, "w") as f: json.dump(out, f, indent=1)
print("wrote", len(cases), "cases,", len(workouts), "workouts")
