# Writes HexplateCore's stats and body golden cases (synthetic, no personal data).
# Run: python3 native/scripts/stats-cases.py > native/HexplateCore/Tests/HexplateCoreTests/Fixtures/stats-cases.json
import json

SQUAT, BENCH, DB_BENCH, ROW, CURL, PUSHUP, ASSIST, RAISE = '0043', '0025', '0289', '0027', '0031', '0662', '0017', '0334'


def sets(w, reps, **extra):
    return [{'w': w, 'r': r, 'done': True, **extra} for r in reps]


def workout(i, d, entries):
    return {'id': f'w{i}', 'd': d, 'start': 1_790_000_000_000 + i * 86_400_000, 'entries': entries}


workouts = [
    workout(0, '2026-10-05', [{'id': SQUAT, 'sets': sets(100, [5, 5, 4])}, {'id': BENCH, 'sets': sets(70, [8, 8, 7])},
                              {'id': ROW, 'sets': sets(60, [10, 10])}]),
    workout(1, '2026-10-07', [{'id': DB_BENCH, 'sets': sets(26, [10, 9])}, {'id': CURL, 'sets': sets(35, [12, 10, 13])},
                              {'id': PUSHUP, 'sets': sets(0, [20, 18])}]),
    workout(2, '2026-10-12', [{'id': SQUAT, 'sets': sets(105, [5, 5, 5])}, {'id': BENCH, 'sets': [{'w': 40, 'r': 10, 'done': True, 'phase': 'warmup'}] + sets(72.5, [6, 6])},
                              {'id': ASSIST, 'sets': sets(30, [8, 8])}]),
    workout(3, '2026-10-14', [{'id': BENCH, 'sets': sets(80, [1]) + sets(75, [5], rir=2) + [{'w': 90, 'r': 1, 'done': False}]},
                              {'id': RAISE, 'sets': [{'w': 8, 'r': 24, 'done': True, 'sides': {'L': {'w': 8, 'r': 12, 'done': True}, 'R': {'w': 8, 'r': 12, 'done': True}}}]}]),
    workout(4, '2026-10-15', [{'id': SQUAT, 'sets': sets(110, [3, 3])}, {'id': CURL, 'sets': sets(37.5, [8])}]),
]
bodyweight = [{'d': '2026-10-01', 'w': 80, 't': 1}, {'d': '2026-10-14', 'w': 79.4, 't': 2, 'ins': [{'id': 'a', 'at': '07:10', 'w': 79.4, 't': 2}]}]
base = {'unit': 'kg', 'workouts': workouts, 'bodyweight': bodyweight}

cases = [
    {'name': 'epley, no profile', 'op': 'stats', 'today': '2026-10-15', 'state': base},
    {'name': 'female, 52', 'op': 'stats', 'today': '2026-10-15', 'state': {**base, 'sex': 'female', 'birthYear': 1974}},
    {'name': 'male, brzycki', 'op': 'stats', 'today': '2026-10-15', 'state': {**base, 'sex': 'male', 'oneRmFormula': 'brzycki'}},
    {'name': 'weighted formula', 'op': 'stats', 'today': '2026-10-12', 'state': {**base, 'oneRmFormula': 'weighted', 'weekStart': 0}},
    {'name': 'own muscle targets', 'op': 'stats', 'today': '2026-10-07', 'state': {**base, 'muscleTargets': {'chest': [4, 8], 'biceps': [1, 2]}}},
    {'name': 'no body weight', 'op': 'stats', 'today': '2026-10-15', 'state': {**base, 'bodyweight': []}},
    {'name': 'one-rep table', 'op': 'estimate',
     'rows': [[w, r, f, rir] for w in (60, 100) for r in (1, 3, 8, 12, 13, 16) for f in ('epley', 'brzycki', 'lombardi', 'oconner', 'mayhew', 'wathan', 'lander', 'weighted') for rir in (None, 2)]},
    {'name': 'weigh-ins', 'op': 'weigh', 'state': {'bodyweight': [{'d': '2026-10-01', 'w': 80, 't': 1}]},
     'adds': [{'d': '2026-10-03', 'at': '07:00', 'w': 79.84, 't': 100, 'id': 'r1'}, {'d': '2026-10-03', 'at': '21:00', 'w': 80.6, 't': 200, 'id': 'r2'},
              {'d': '2026-10-02', 'at': None, 'w': 80.2, 't': 300, 'id': 'r3'}, {'d': '2026-10-03', 'at': '06:00', 'w': 79.5, 't': 400, 'id': 'r4'},
              {'d': '2026-10-03', 'at': '06:00', 'w': 79.6, 't': 500, 'id': 'r5'}, {'d': '2026-10-04', 'at': None, 'w': 0, 't': 600, 'id': 'r6'}]},
    {'name': 'weigh-ins, last of day', 'op': 'weigh', 'state': {'bwDaily': 'last', 'bodyweight': []},
     'adds': [{'d': '2026-10-03', 'at': '07:00', 'w': 79.8, 't': 100, 'id': 'r1'}, {'d': '2026-10-03', 'at': '21:00', 'w': 80.6, 't': 200, 'id': 'r2'}]},
    {'name': 'weigh-ins, average', 'op': 'weigh', 'state': {'bwDaily': 'avg', 'bodyweight': []},
     'adds': [{'d': '2026-10-03', 'at': '07:00', 'w': 79.8, 't': 100, 'id': 'r1'}, {'d': '2026-10-03', 'at': '21:00', 'w': 80.65, 't': 200, 'id': 'r2'}]},
]
inv_default = [{'w': w, 'n': 6} for w in (25, 20, 15, 10, 5, 2.5, 1.25)]
inv_odd = [{'w': 20, 'n': 1}, {'w': 15, 'n': 2}, {'w': 10, 'n': 1}, {'w': 2.5, 'n': 3}, {'w': 1.25, 'n': 1}]
cases.append({'name': 'plate stacks', 'op': 'plates', 'rows': [[w, inv] for inv in (inv_default, inv_odd, []) for w in (0, 1, 12.5, 30, 41.25, 47.5, 52.6, 61.25, 200)]})
print(json.dumps(cases, indent=1))
