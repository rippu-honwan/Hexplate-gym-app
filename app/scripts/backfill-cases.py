# Writes HexplateCore's log-a-past-workout golden cases (synthetic, no personal data).
# Run: python3 native/scripts/backfill-cases.py > native/HexplateCore/Tests/HexplateCoreTests/Fixtures/backfill-cases.json
# Each case: begin a session logged into the past, tick every set, finish it. Day starts are
# given as epoch ms so the cases do not depend on the time zone.
import json

BENCH, SQUAT, CURL = '0025', '0043', '0031'
DAY = 86_400_000
T0 = 1_790_000_000_000


def workout(i, d, at, entries, prs=(), **extra):
    return {'id': f'w{i}', 'd': d, 'start': at, 'end': at + 3_600_000, 'routineIds': ['r1'], 'routineId': 'r1', 'name': 'Push',
            'bw': 80, 'entries': entries, 'prs': list(prs), 'vol': 0, **extra}


def entry(id, w, reps=(8, 8)):
    return {'id': id, 'target': {'id': id, 'sets': len(reps), 'reps': reps[0]}, 'sets': [{'w': w, 'r': r, 'done': True} for r in reps], 'topW': w}


routines = [
    {'id': 'r1', 'name': 'Push', 'ex': [{'id': BENCH, 'sets': 2, 'reps': 8, 'weight': 50}, {'id': CURL, 'sets': 1, 'reps': 12, 'weight': 10, 'side': True}]},
    {'id': 'r2', 'name': 'Legs', 'ex': [{'id': SQUAT, 'sets': 2, 'reps': 5, 'weight': 100}]},
]
history = [
    workout(0, '2026-10-01', T0, [entry(BENCH, 60)], prs=[BENCH]),
    workout(1, '2026-10-05', T0 + 4 * DAY, [entry(BENCH, 70), entry(SQUAT, 120)], prs=[BENCH, SQUAT], note='old note'),
    workout(2, '2026-10-09', T0 + 8 * DAY, [entry(BENCH, 65)]),
]
state = {'unit': 'kg', 'routines': routines, 'workouts': history,
         'exWeights': {BENCH: {'w': 70, 'd': '2026-10-05'}, SQUAT: {'w': 120, 'd': '2026-10-05'}, CURL: {'w': 12}}}

cases = [
    {'name': 'between two workouts', 'state': state, 'iso': '2026-10-03', 'start': T0 + 2 * DAY, 'dur': 45, 'routineIds': ['r1'], 'replaceId': None},
    {'name': 'before everything, two routines', 'state': state, 'iso': '2026-09-20', 'start': T0 - 11 * DAY, 'dur': 0, 'routineIds': ['r1', 'r2'], 'replaceId': None},
    {'name': 'replace a day, note carried', 'state': state, 'iso': '2026-10-05', 'start': T0 + 4 * DAY + 600_000, 'dur': 50, 'routineIds': ['r1'], 'replaceId': 'w1'},
    {'name': 'same moment as an existing one', 'state': state, 'iso': '2026-10-09', 'start': T0 + 8 * DAY, 'dur': 30, 'routineIds': ['r1'], 'replaceId': None},
    {'name': 'replace with a note of its own', 'state': state, 'iso': '2026-10-05', 'start': T0 + 4 * DAY, 'dur': 60, 'routineIds': [], 'replaceId': 'w1', 'note': 'today'},
]
print(json.dumps(cases, indent=1))
