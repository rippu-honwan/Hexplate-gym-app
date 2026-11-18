# Writes HexplateCore's saved-workout edit golden cases (synthetic, no personal data).
# Run: python3 app/scripts/workout-edit-cases.py > app/HexplateCore/Tests/HexplateCoreTests/Fixtures/workout-edit-cases.json
import json

BENCH, SQUAT, ASSIST = '0025', '0043', '0017'


def entry(id, w, reps=(8, 8), **extra):
    return {'id': id, 'target': {'id': id, 'sets': len(reps), 'reps': reps[0]}, 'sets': [{'w': w, 'r': r, 'done': True} for r in reps], 'topW': w, **extra}


def workout(i, d, entries, prs=(), **extra):
    return {'id': f'w{i}', 'd': d, 'start': 1_790_000_000_000 + i * 86_400_000, 'end': 1_790_000_000_000 + i * 86_400_000 + 3_600_000,
            'routineIds': ['r1'], 'routineId': 'r1', 'name': 'Push', 'bw': 80, 'entries': entries, 'prs': list(prs), 'vol': 0, **extra}


history = [
    workout(0, '2026-10-01', [entry(BENCH, 60), entry(SQUAT, 100)], prs=[BENCH, SQUAT]),
    workout(1, '2026-10-03', [entry(BENCH, 65, note='felt good')], prs=[BENCH], note=' solid '),
    workout(2, '2026-10-05', [entry(BENCH, 62), entry(ASSIST, 30)], prs=[ASSIST]),
    workout(3, '2026-10-07', [entry(ASSIST, 25), entry(SQUAT, 90)], prs=[ASSIST]),
]
state = {'unit': 'kg', 'workouts': history, 'exWeights': {BENCH: {'w': 65, 'd': '2026-10-03'}, SQUAT: {'w': 100, 'd': '2026-10-01'}, ASSIST: {'w': 25, 'd': '2026-10-07'}}}

cases = [
    {'name': 'raise an old weight to a record', 'state': state, 'key': 'w0', 'ops': [['set', ['entries', 0, 'sets', 0, 'w'], 70]]},
    {'name': 'lower the record holder', 'state': state, 'key': 'w1', 'ops': [['set', ['entries', 0, 'sets', 0, 'w'], 55], ['set', ['entries', 0, 'sets', 1, 'w'], 55]]},
    {'name': 'nothing changed', 'state': state, 'key': 'w2', 'ops': []},
    {'name': 'rename, note, drop an exercise', 'state': state, 'key': 'w0', 'ops': [['set', ['name'], 'Heavy day'], ['set', ['note'], '  new note '], ['del', ['entries', 1]]]},
    {'name': 'untick everything', 'state': state, 'key': 'w1', 'ops': [['set', ['entries', 0, 'sets', 0, 'done'], False], ['set', ['entries', 0, 'sets', 1, 'done'], False]]},
    {'name': 'assisted gets easier', 'state': state, 'key': 'w3', 'ops': [['set', ['entries', 0, 'sets', 0, 'w'], 35], ['set', ['entries', 0, 'sets', 1, 'w'], 35]]},
    {'name': 'kept out of progression', 'state': {**state, 'workouts': history[:3] + [{**history[3], 'excludeFromProgression': True}]}, 'key': 'w3',
     'ops': [['set', ['entries', 1, 'sets', 0, 'r'], 10]]},
    {'name': 'old record without an id', 'state': {**state, 'workouts': [{k: v for k, v in history[0].items() if k != 'id'}] + history[1:]},
     'key': '2026-10-01|1790000000000', 'ops': [['set', ['entries', 0, 'sets', 1, 'r'], 9]]},
    {'name': 'busy', 'state': {**state, 'active': {'id': 'live', 'entries': []}}, 'key': 'w0', 'ops': []},
    {'name': 'gone', 'state': state, 'key': 'nope', 'ops': []},
]

# A saved workout's date and time, length and note, from its detail page.
cases += [
    {'name': 'move earlier: records follow', 'state': state, 'detail': ['move', 'w1', '2026-09-28', '07:30']},
    {'name': 'move later, same day as another', 'state': state, 'detail': ['move', 'w0', '2026-10-05', '20:15']},
    {'name': 'move an old record without an id', 'state': {**state, 'workouts': [{k: v for k, v in history[0].items() if k != 'id'}] + history[1:]},
     'detail': ['move', '2026-10-01|1790000000000', '2026-10-04', '06:00']},
    {'name': 'move a missing one', 'state': state, 'detail': ['move', 'nope', '2026-10-04', '06:00']},
    {'name': 'duration', 'state': state, 'detail': ['duration', 'w2', 75.4]},
    {'name': 'duration unchanged', 'state': state, 'detail': ['duration', 'w2', 60]},
    {'name': 'duration bounds', 'state': state, 'detail': ['duration', 'w3', 5000]},
    {'name': 'duration at least a minute', 'state': state, 'detail': ['duration', 'w3', 0]},
    {'name': 'note', 'state': state, 'detail': ['note', 'w0', '  quick one  ']},
    {'name': 'note cleared', 'state': state, 'detail': ['note', 'w1', '   ']},
    {'name': 'note the same', 'state': state, 'detail': ['note', 'w1', 'solid']},
]
print(json.dumps(cases, indent=1))
