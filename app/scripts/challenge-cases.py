# Writes HexplateCore's streak and monthly challenge golden cases (synthetic, no personal data).
# Run: python3 app/scripts/challenge-cases.py > app/HexplateCore/Tests/HexplateCoreTests/Fixtures/challenge-cases.json
import json

SQUAT, BENCH, ROW, CURL, PULLUP, CHINUP, PUSHUP, RUN, PLANK, RAISE = '0043', '0025', '0027', '0031', '0652', '1326', '0662', '3556', '0464', '0334'


def sets(w, reps, **extra):
    return [{'w': w, 'r': r, 'done': True, **extra} for r in reps]


n = 0


def wo(d, entries, prs=()):
    global n
    n += 1
    return {'id': f'w{n}', 'd': d, 'start': 1_780_000_000_000 + n * 3_600_000, 'entries': entries, 'prs': list(prs)}


workouts = []
for month, days in (('2026-07', [2, 9, 16, 23, 30]), ('2026-08', [3, 6, 10, 13, 17, 24, 27]), ('2026-09', [1, 3, 8, 15, 22, 29]),
                    ('2026-10', [5, 7, 12, 14, 19, 26, 28]), ('2026-11', [2, 4, 9, 11])):
    for i, d in enumerate(days):
        day = f'{month}-{d:02d}'
        if i % 2 == 0:
            entries = [{'id': SQUAT, 'sets': sets(100 + i, [5, 5, 5])}, {'id': BENCH, 'sets': [{'w': 40, 'r': 10, 'done': True, 'phase': 'warmup'}] + sets(70, [8, 8])},
                       {'id': PULLUP, 'sets': sets(0, [8, 7, 6])}, {'id': RUN, 'sets': [{'min': 12, 'speed': 9, 'done': True}]}]
        else:
            entries = [{'id': ROW, 'sets': sets(60, [10, 10])}, {'id': PUSHUP, 'sets': sets(0, [20, 18]) + [{'r': 15, 'done': False}]},
                       {'id': CURL, 'sets': sets(30, [12, 10])},
                       {'id': RAISE, 'sets': [{'w': 8, 'r': 24, 'done': True, 'sides': {'L': {'w': 8, 'r': 12, 'done': True}, 'R': {'w': 8, 'r': 11, 'done': False}}}]}]
        if month == '2026-11' and i == 3:
            entries.append({'id': CHINUP, 'sets': sets(0, [6, 5])})
        workouts.append(wo(day, entries, prs=[SQUAT] * (i % 3) + ([BENCH] if i == 1 else [])))

bodyweight = [{'d': d, 'w': 80} for d in ('2026-09-02', '2026-09-09', '2026-09-20', '2026-10-01', '2026-10-15', '2026-10-16', '2026-11-03', '2026-11-05')]
base = {'unit': 'kg', 'workouts': workouts, 'bodyweight': bodyweight}
stored = {'2026-10': {'picked': [{'id': 'workouts', 'n': 7}, {'id': 'volume', 'n': 20000, 'u': 'kg'}, {'id': 'newex', 'n': 3}], 'done': ['workouts', 'bogus'], 'at': 5},
          '2026-09': {'picked': [{'id': 'weeks', 'n': 4}, {'id': 'prs', 'n': 2}, {'id': 'weighins', 'n': 4}], 'done': ['weeks', 'prs', 'weighins'], 'at': 4},
          '2026-13': {'picked': [{'id': 'workouts', 'n': 1}]}, 'junk': 1,
          '2026-06': {'picked': [{'id': 'Bad Id', 'n': 3}, {'id': 'prs', 'n': -1}], 'done': []}}

cases = []
for key in ('2026-06', '2026-07', '2026-08', '2026-09', '2026-10', '2026-11', '2026-12'):
    cases.append({'name': 'fresh ' + key, 'state': base, 'month': key, 'today': key + '-15'})
cases += [
    {'name': 'stored months', 'state': {**base, 'challenges': stored}, 'month': '2026-10', 'today': '2026-10-31'},
    {'name': 'lb profile', 'state': {**base, 'unit': 'lb'}, 'month': '2026-11', 'today': '2026-11-15'},
    {'name': 'lb profile, kg target', 'state': {**base, 'unit': 'lb', 'challenges': stored}, 'month': '2026-10', 'today': '2026-10-15'},
    {'name': 'sunday weeks', 'state': {**base, 'weekStart': 0}, 'month': '2026-11', 'today': '2026-11-15'},
    {'name': 'nothing at all', 'state': {'unit': 'kg', 'workouts': []}, 'month': '2026-11', 'today': '2026-11-15'},
    # streak: a gap covered by a freeze, then a broken run
    {'name': 'streak with gaps', 'state': {**base, 'workouts': [w for w in workouts if not w['d'].startswith('2026-09')]}, 'month': '2026-11', 'today': '2026-11-12'},
    {'name': 'streak, one week frozen', 'state': {**base, 'workouts': [w for w in workouts if w['d'] not in ('2026-10-12', '2026-10-14')],
                                                   'streakSeen': {'badge': 12, 'wk': '2026-11-02'}}, 'month': '2026-11', 'today': '2026-11-12'},
    {'name': 'streak, this week open', 'state': base, 'month': '2026-11', 'today': '2026-11-20'},
]
print(json.dumps(cases, indent=1))
