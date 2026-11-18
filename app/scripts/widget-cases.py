# Writes HexplateCore's widget snapshot golden cases (synthetic, no personal data).
# Run: python3 app/scripts/widget-cases.py > app/HexplateCore/Tests/HexplateCoreTests/Fixtures/widget-cases.json
import json

BENCH, SQUAT, ROW, CURL = '0025', '0043', '0027', '0031'


def workout(i, d, rid, entries, prs=(), end=0):
    return {'id': f'w{i}', 'd': d, 'start': end - 3_600_000, 'end': end, 'routineIds': [rid], 'routineId': rid, 'name': rid,
            'entries': entries, 'prs': list(prs)}


def entry(id, w, reps):
    return {'id': id, 'target': {'id': id, 'sets': len(reps), 'reps': reps[0]}, 'sets': [{'w': w, 'r': r, 'done': True} for r in reps]}


routines = [
    {'id': 'ra', 'name': 'Push', 'ex': [{'id': BENCH, 'sets': 3, 'reps': 8, 'weight': 60}, {'id': CURL, 'sets': 2, 'reps': 12, 'repsMin': 8}]},
    {'id': 'rb', 'name': 'Legs', 'ex': [{'id': SQUAT, 'sets': 3, 'reps': 5, 'weight': 100}]},
    {'id': 'rc', 'name': 'Empty', 'ex': []},
]
T = 1_790_000_000_000
# Weeks trained: a run, a gap a freeze covers, a run, this week.
days = ['2026-09-07', '2026-09-14', '2026-09-21', '2026-09-28', '2026-10-12', '2026-10-19', '2026-11-02', '2026-11-09', '2026-11-10', '2026-11-16']
workouts = [workout(i, d, 'ra' if i % 2 else 'rb', [entry(BENCH, 60 + i, [8, 8])] if i % 2 else [entry(SQUAT, 100 + i, [5, 5])],
                    prs=[BENCH] if i in (5, 7) else [], end=T + i * 86_400_000) for i, d in enumerate(days)]
base = {'unit': 'kg', 'weekStart': 1, 'routines': routines, 'week': {'1': ['ra'], '3': ['rb', 'rc'], '5': ['ra', 'rb']}, 'dayPlan': {},
        'workouts': workouts, 'bodyweight': [{'d': f'2026-11-{d:02d}', 'w': 80 - d / 10, 't': T} for d in range(1, 11)], 'targetW': 78}

import datetime
long = [workout(100 + i, (datetime.date(2026, 6, 1) + datetime.timedelta(weeks=i)).isoformat(), 'ra', [entry(BENCH, 50, [5])], end=T)
        for i in list(range(13)) + [16, 17]]

cases = [
    {'name': 'a long run, three weeks missed', 'today': '2026-09-28', 'state': {**base, 'workouts': long}},
    {'name': 'a trained week with a plan', 'today': '2026-11-16', 'state': base},
    {'name': 'a running workout, no goal, lb', 'today': '2026-11-18', 'state': {**base, 'unit': 'lb', 'targetW': None,
        'active': {'id': 'a1', 'name': 'Legs', 'start': T, 'entries': [{'id': SQUAT, 'sets': [{'done': True}, {'done': False}]}]}}},
    {'name': 'a broken streak, day plan', 'today': '2026-12-20', 'state': {**base, 'dayPlan': {'2026-12-21': 'rest', '2026-12-22': 'rb'}}},
    {'name': 'nothing at all', 'today': '2026-11-16', 'state': {'unit': 'kg', 'routines': [], 'week': {}, 'workouts': [], 'bodyweight': []}},
]
print(json.dumps(cases, indent=1))
