# Writes HexplateCore's watch-link golden cases (synthetic, no personal data).
# Run: python3 native/scripts/watch-cases.py > native/HexplateCore/Tests/HexplateCoreTests/Fixtures/watch-cases.json
import json

SQUAT, BENCH, RAISE, PLANK, ROW, ASSIST, RUN = '0043', '0025', '0334', '0463', '0861', '0017', '0685'
routines = [
    {'id': 'r1', 'name': 'Upper', 'ex': [{'id': BENCH, 'sets': 3, 'reps': 8, 'weight': 60, 'restSec': 120, 'sg': 'a'}, {'id': ROW, 'sets': 3, 'reps': 10, 'weight': 50, 'sg': 'a'},
                                        {'id': RAISE, 'sets': 2, 'reps': 12, 'weight': 6, 'side': True}]},
    {'id': 'r2', 'name': 'Lower', 'ex': [{'id': SQUAT, 'sets': 3, 'reps': 5, 'weight': 100}, {'id': PLANK, 'sets': 2, 'sec': 45, 'mode': 'time'}, {'id': ASSIST, 'sets': 2, 'reps': 8, 'weight': 30}]},
    {'id': 'r3', 'name': 'Cardio', 'ex': [{'id': RUN, 'sets': 1, 'min': 20, 'speed': 9}]},
]
done = lambda w, r, **x: {'w': w, 'r': r, 'done': True, **x}
workouts = [
    {'id': 'w1', 'd': '2026-11-10', 'start': 1000, 'routineIds': ['r1'], 'routineId': 'r1', 'entries': [
        {'id': BENCH, 'rid': 'r1', 'target': routines[0]['ex'][0], 'sets': [done(57.5, 8, at=5000), done(57.5, 8, at=6000), done(57.5, 7, at=7000, hr={'avg': 120, 'max': 140})]},
        {'id': RAISE, 'rid': 'r1', 'target': routines[0]['ex'][2], 'sets': [{'w': 6, 'r': 12, 'done': True, 'at': 8000, 'sides': {'L': done(6, 6), 'R': done(6, 6)}}]}]},
    {'id': 'w2', 'd': '2026-11-12', 'start': 2000, 'routineIds': ['r2'], 'routineId': 'r2', 'entries': [
        {'id': SQUAT, 'rid': 'r2', 'target': routines[1]['ex'][0], 'sets': [{'w': 40, 'r': 8, 'done': True, 'phase': 'warmup'}, done(100, 5, at=9000), done(100, 5, at=9500, rir=2)]},
        {'id': PLANK, 'rid': 'r2', 'target': routines[1]['ex'][1], 'sets': [{'sec': 45, 'w': 0, 'done': True}]}]},
]
active = {'id': 'live', 'd': '2026-11-15', 'start': 50_000, 'routineIds': ['r1'], 'name': 'Upper', 'cur': 7, 'entries': [
    {'id': BENCH, 'rid': 'r1', 'sg': 'a', 'target': {**routines[0]['ex'][0], 'weight': 60}, 'sets': [{'w': 30, 'r': 8, 'done': True, 'phase': 'warmup', 'at': 51_000}, done(60, 8, at=52_000), {'w': 60, 'r': 8, 'done': False}]},
    {'id': RAISE, 'rid': 'r1', 'target': routines[0]['ex'][2], 'sets': [{'w': 6, 'r': 12, 'done': False, 'sides': {'L': {'w': 6, 'r': 6, 'done': False}, 'R': {'w': 6, 'r': 6, 'done': False}}}]}]}
base = {'unit': 'kg', 'restSec': 90, 'routines': routines, 'workouts': workouts, 'scheduleMode': 'week', 'week': {'0': ['r1'], '1': ['r2']}, 'dayPlan': {}}
cases = [
    {'name': 'idle, Sunday plan', 'op': 'snapshot', 'today': '2026-11-15', 'state': base},
    {'name': 'idle, nothing planned', 'op': 'snapshot', 'today': '2026-11-17', 'state': {**base, 'unit': 'lb'}},
    {'name': 'running', 'op': 'snapshot', 'today': '2026-11-15', 'state': {**base, 'active': active}},
    {'name': 'patch a saved set', 'op': 'patch', 'state': base, 'ref': {'wid': 'w1', 'exId': BENCH, 'entryIdx': 0, 'setIdx': 2}, 'fields': {'w': 60, 'r': 8, 'done': True}, 'ifNewer': None},
    {'name': 'patch a newer saved set keeps it', 'op': 'patch', 'state': base, 'ref': {'wid': 'w1', 'exId': BENCH, 'entryIdx': 0, 'setIdx': 2}, 'fields': {'w': 70, 'r': 3, 'hr': {'avg': 130, 'max': 150}, 'rpe': 8}, 'ifNewer': 6500},
    {'name': 'patch by exercise when the index moved', 'op': 'patch', 'state': base, 'ref': {'wid': 'w2', 'exId': PLANK, 'entryIdx': 0, 'setIdx': 0}, 'fields': {'restHr': {'avg': 90, 'max': 100}}, 'ifNewer': None},
    {'name': 'patch a warm-up marks it edited', 'op': 'patch', 'state': base, 'ref': {'wid': 'w2', 'exId': SQUAT, 'entryIdx': 0, 'setIdx': 0}, 'fields': {'w': 50}, 'ifNewer': None},
    {'name': 'patch one side', 'op': 'patch', 'state': {**base, 'active': active}, 'ref': {'wid': 'live', 'exId': RAISE, 'entryIdx': 1, 'setIdx': 0, 'side': 'L'}, 'fields': {'w': 7, 'r': 6, 'done': True, 'at': 60_000}, 'ifNewer': None},
    {'name': 'patch an unknown workout', 'op': 'patch', 'state': base, 'ref': {'wid': 'nope', 'exId': BENCH, 'entryIdx': 0, 'setIdx': 0}, 'fields': {'w': 1}, 'ifNewer': None},
]
print(json.dumps(cases, indent=1))
