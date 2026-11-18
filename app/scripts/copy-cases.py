# Writes HexplateCore's Save as routine / Repeat today golden cases (synthetic, no personal data).
# Run: python3 app/scripts/copy-cases.py > app/HexplateCore/Tests/HexplateCoreTests/Fixtures/copy-cases.json
import json

BENCH, SQUAT, ROW, CURL, ASSIST, RUN, PLANK = '0025', '0043', '0027', '0031', '0017', '0685', '4170'


def rows(w, reps, done=True, **extra):
    return [{'w': w, 'r': r, 'done': done, **extra} for r in reps]


def warm(w, r):
    return {'w': w, 'r': r, 'done': True, 'phase': 'warmup', 'warmup': True}


def side(lw, lr, rw, rr, ld=True, rd=True):
    return {'w': max(lw, rw), 'r': lr + rr, 'done': ld and rd, 'sides': {'L': {'w': lw, 'r': lr, 'done': ld}, 'R': {'w': rw, 'r': rr, 'done': rd}}}


def workout(entries, **extra):
    return {'id': 'w1', 'd': '2026-10-05', 'start': 1_790_000_000_000, 'end': 1_790_003_600_000, 'name': 'Push', 'routineIds': ['r1'], 'entries': entries, **extra}


state = {'unit': 'kg', 'routines': [{'id': 'r1', 'name': 'Push', 'prog': 'double', 'ex': []}, {'id': 'r2', 'name': 'Pull', 'ex': []}], 'workouts': []}
lb = {**state, 'unit': 'lb'}

cases = [
    {'name': 'warm-ups, a superset, an unticked set', 'state': state, 'w': workout([
        {'id': BENCH, 'target': {'id': BENCH, 'sets': 3, 'reps': 8, 'weight': 60, 'mode': 'reps'}, 'sets': [warm(30, 8), warm(45, 5)] + rows(60, [8, 8, 7]) + rows(60, [8], done=False)},
        {'id': SQUAT, 'sg': 'a', 'target': {'id': SQUAT, 'sets': 2, 'reps': 5}, 'sets': rows(100, [5, 5])},
        {'id': ROW, 'sg': 'a', 'target': {'id': ROW, 'sets': 2, 'reps': 10, 'rid': 'r1', 'noProg': True}, 'sets': rows(70, [10, 9])},
        {'id': CURL, 'target': {'id': CURL}, 'sets': []},
    ])},
    {'name': 'planned entry keeps the plan', 'state': state, 'w': workout([
        {'id': BENCH, 'rid': 'r1', 'planned': {'sets': 4, 'reps': 12, 'repsMin': 8}, 'target': {'id': BENCH, 'sets': 5, 'reps': 9, 'repsMin': 9, 'weight': 62.5, 'rowReps': [9, 9]}, 'sets': rows(62.5, [9, 9, 9, 9, 8])},
        {'id': SQUAT, 'rid': 'r2', 'planned': {'sets': 0, 'reps': 0}, 'target': {'id': SQUAT, 'sets': 3, 'reps': 5}, 'sets': rows(110, [5, 5, 5])},
    ])},
    {'name': 'per side reps, one side short', 'state': state, 'w': workout([
        {'id': CURL, 'target': {'id': CURL, 'sets': 3, 'reps': 20, 'side': True}, 'sets': [side(12, 10, 12, 9), side(12, 8, 14, 8), side(12, 7, 12, 0, rd=False)]},
        {'id': ROW, 'target': {'id': ROW, 'sets': 2, 'reps': 15, 'side': True}, 'sets': [side(20, 8, 20, 8, ld=False, rd=False)]},
    ])},
    {'name': 'timed per side, cardio, numeric groups', 'state': state, 'w': workout([
        {'id': PLANK, 'sg': 3, 'target': {'id': PLANK, 'mode': 'time', 'sets': 2, 'sec': 30, 'side': True}, 'sets': [{'sec': 40, 'w': 0, 'side': s, 'done': True} for s in 'LRLR']},
        {'id': CURL, 'sg': 3, 'target': {'id': CURL, 'sets': 1, 'reps': 10}, 'sets': rows(10, [12])},
        {'id': RUN, 'target': {'id': RUN, 'min': 20, 'speed': 8}, 'sets': [{'min': 32, 'speed': 9.5, 'incline': 2, 'done': True}, {'min': 5, 'speed': 6, 'done': True, 'phase': 'warmup'}]},
    ])},
    {'name': 'deleted half of a superset, assisted warm-up', 'state': lb, 'w': workout([
        {'id': 'custom-gone', 'sg': 'x', 'target': {'id': 'custom-gone', 'sets': 2, 'reps': 10}, 'sets': rows(20, [10, 10])},
        {'id': ASSIST, 'sg': 'x', 'target': {'id': ASSIST, 'sets': 2, 'reps': 8}, 'sets': [warm(60, 8)] + rows(40, [8, 8])},
        {'id': SQUAT, 'target': {'id': SQUAT, 'sets': 3, 'reps': 5}, 'sets': [warm(95, 5), warm(135, 3)] + rows(225, [5, 5, 5])},
    ], name='  ')},
    {'name': 'a workout that does not count', 'state': state, 'w': workout([
        {'id': BENCH, 'target': {'id': BENCH, 'sets': 2, 'reps': 5, 'weight': 50}, 'sets': rows(80, [5, 5])},
    ], excludeFromProgression=True)},
    {'name': 'nothing logged', 'state': state, 'w': workout([{'id': BENCH, 'sets': []}])},
]
print(json.dumps(cases, indent=1))
