# Writes HexplateCore's "Your year" golden cases (synthetic, no personal data).
# Run: python3 app/scripts/wrapped-cases.py > app/HexplateCore/Tests/HexplateCoreTests/Fixtures/wrapped-cases.json
import json
from datetime import datetime

SQUAT, BENCH, ROW, CURL, PULLUP, PUSHUP, RUN, RAISE, ASSIST, LEGPRESS = '0043', '0025', '0027', '0031', '0652', '0662', '3556', '0334', '0017', '0739'
n = 0


def sets(w, reps, **extra):
    return [{'w': w, 'r': r, 'done': True, **extra} for r in reps]


def wo(d, hour, minutes, entries, prs=()):
    global n
    n += 1
    start = int(datetime.strptime(f'{d} {hour:02d}:10', '%Y-%m-%d %H:%M').timestamp() * 1000) if hour is not None else None
    w = {'id': f'w{n}', 'd': d, 'entries': entries, 'prs': list(prs)}
    if start is not None:
        w['start'] = start
        if minutes:
            w['end'] = start + minutes * 60000
    return w


legs = [{'id': SQUAT, 'sets': sets(100, [5, 5, 5])}, {'id': LEGPRESS, 'sets': sets(180, [10, 10])}]
push = [{'id': BENCH, 'sets': [{'w': 40, 'r': 10, 'done': True, 'phase': 'warmup'}] + sets(70, [8, 8])}, {'id': PUSHUP, 'sets': sets(0, [20])}]
pull = [{'id': ROW, 'sets': sets(60, [10, 10])}, {'id': PULLUP, 'sets': sets(0, [8, 7])}, {'id': ASSIST, 'sets': sets(30, [8])},
        {'id': RAISE, 'sets': [{'w': 8, 'r': 24, 'done': True, 'sides': {'L': {'w': 8, 'r': 12, 'done': True}, 'R': {'w': 8, 'r': 12, 'done': False}}}]}]
cardio = [{'id': RUN, 'sets': [{'min': 25, 'speed': 9, 'done': True}]}]

workouts = [wo('2025-11-03', 18, 60, [{'id': BENCH, 'sets': sets(60, [5])}, {'id': SQUAT, 'sets': sets(90, [5])}]),
            wo('2025-12-29', 7, 50, legs)]
days = ['2026-01-05', '2026-01-07', '2026-01-12', '2026-01-19', '2026-01-26', '2026-02-02', '2026-02-14', '2026-02-15', '2026-03-02',
        '2026-03-09', '2026-03-16', '2026-04-11', '2026-05-04', '2026-05-30', '2026-06-01', '2026-08-03', '2026-08-04', '2026-10-31']
for i, d in enumerate(days):
    kind = [legs, push, pull, cardio][i % 4]
    hour = [6, 7, 19, 21, 12, None][i % 6]
    prs = [BENCH] if i == 5 else [SQUAT, ASSIST] if i == 8 else [LEGPRESS] if i == 12 else []
    entries = [dict(e, sets=[dict(s, w=s['w'] + i) if 'w' in s and s.get('w') else s for s in e['sets']]) for e in kind]
    workouts.append(wo(d, hour, [45, 80, 30, 0, 95, 0][i % 6], entries, prs))
bw = [{'d': '2026-01-02', 'w': 82.4, 't': 2}, {'d': '2026-01-02', 'w': 82.0, 't': 1}, {'d': '2026-06-10', 'w': 80.1}, {'d': '2026-12-01', 'w': 79.9},
      {'d': '2025-12-31', 'w': 90}]
base = {'unit': 'kg', 'workouts': workouts, 'bodyweight': bw}
cases = [
    {'name': '2026', 'state': base, 'year': 2026, 'now': '2026-12-05T10:00'},
    {'name': '2026 mid-year', 'state': base, 'year': 2026, 'now': '2026-11-10T10:00'},
    {'name': '2025', 'state': base, 'year': 2025, 'now': '2026-01-10T10:00'},
    {'name': 'no workouts that year', 'state': base, 'year': 2024, 'now': '2026-12-05T10:00'},
    {'name': 'lb', 'state': {**base, 'unit': 'lb'}, 'year': 2026, 'now': '2026-12-05T10:00'},
    {'name': 'sunday weeks, body off', 'state': {**base, 'weekStart': 0, 'wrappedBody': False}, 'year': 2026, 'now': '2026-12-05T10:00'},
    {'name': 'opened', 'state': {**base, 'wrapped': {'opened': [2026, 2020, 2021, 2022, 2023, 2024]}}, 'year': 2026, 'now': '2027-01-20T10:00'},
    {'name': 'dismissed, notify off', 'state': {**base, 'wrapped': {'dismissed': [2026]}, 'wrappedNotify': False}, 'year': 2026, 'now': '2026-12-01T09:00'},
    {'name': 'out of season', 'state': base, 'year': 2026, 'now': '2026-10-01T09:00'},
    {'name': 'notify planned', 'state': base, 'year': 2026, 'now': '2026-11-30T09:00'},
]
print(json.dumps(cases, indent=1))
