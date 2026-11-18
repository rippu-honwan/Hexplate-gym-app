# Writes HexplateCore's Live Activity golden cases (synthetic, no personal data).
# Run: python3 app/scripts/live-cases.py > app/HexplateCore/Tests/HexplateCoreTests/Fixtures/live-cases.json
import json

SQUAT, BENCH, RAISE, PLANK, ROW = '0043', '0025', '0334', '0463', '0861'
done = lambda w, r, **x: {'w': w, 'r': r, 'done': True, **x}
todo = lambda w, r, **x: {'w': w, 'r': r, 'done': False, **x}
entries = [
    {'id': BENCH, 'sg': 'a', 'target': {'id': BENCH, 'sets': 3, 'reps': 8, 'weight': 60, 'restSec': 120, 'sgRest': 100},
     'sets': [{'w': 30, 'r': 8, 'done': True, 'phase': 'warmup'}, done(60, 8), todo(60, 8), todo(60, 8)]},
    {'id': ROW, 'sg': 'a', 'target': {'id': ROW, 'sets': 2, 'reps': 10, 'weight': 50}, 'sets': [done(50, 10), todo(50, 10)]},
    {'id': RAISE, 'target': {'id': RAISE, 'sets': 2, 'reps': 12, 'weight': 6, 'side': True},
     'sets': [todo(6, 12, sides={'L': todo(6, 6), 'R': todo(6, 6)}), todo(6, 12, sides={'L': todo(6, 6), 'R': todo(6, 6)})]},
    {'id': SQUAT, 'target': {'id': SQUAT, 'sets': 2, 'reps': 5, 'weight': 100, 'restOff': True},
     'sets': [{'w': 40, 'r': 5, 'done': False, 'phase': 'warmup'}, todo(100, 5), todo(100, 5)]},
    {'id': PLANK, 'target': {'id': PLANK, 'sets': 2, 'sec': 45, 'mode': 'time', 'restSec': 30}, 'sets': [{'sec': 45, 'w': 0, 'done': False}, {'sec': 45, 'w': 0, 'done': False}]},
    {'id': 'gone', 'name': 'Old thing', 'target': {}, 'sets': [todo(10, 10)]},
]
active = {'id': 'live', 'd': '2026-11-15', 'start': 50_000, 'routineIds': ['r1'], 'name': 'Upper', 'cur': 0, 'entries': entries}
base = {'unit': 'kg', 'restSec': 90, 'routines': [], 'workouts': [], 'active': active}
alldone = {**active, 'entries': [{**e, 'sets': [{**s, 'done': True} for s in e['sets']]} for e in entries]}
cases = [
    {'name': 'superset first, rest running', 'state': base, 'timer': {'endsAt': 1_800_000_000_000, 'total': 100}},
    {'name': 'from the squat, hold running', 'state': {**base, 'active': {**active, 'cur': 3}}, 'hold': {'work': {'endsAt': 1_800_000_000_000, 'total': 45}}},
    {'name': 'no default rest, lb', 'state': {**base, 'unit': 'lb', 'restSec': 0, 'active': {**active, 'cur': 2}}},
    {'name': 'all done', 'state': {**base, 'active': alldone}},
    {'name': 'editing a saved workout', 'state': {**base, 'active': {**active, 'editingWorkoutId': 'w1'}}},
    {'name': 'nothing running', 'state': {**base, 'active': None}},
    {'name': 'next from the superset', 'op': 'next', 'state': base, 'from': 1},
    {'name': 'next wraps around', 'op': 'next', 'state': {**base, 'active': {**active, 'cur': 5}}, 'from': 5},
    {'name': 'next from a unit no longer current', 'op': 'next', 'state': base, 'from': 3},
    {'name': 'next with nothing else open', 'op': 'next', 'state': {**base, 'active': alldone}, 'from': 0},
]
print(json.dumps(cases, indent=1))
