# Writes HexplateCore's programme golden cases (synthetic, no personal data).
# Run: python3 native/scripts/programme-cases.py > native/HexplateCore/Tests/HexplateCoreTests/Fixtures/programme-cases.json
# Each case runs ops on one state; every op's result is recorded.
import json

BENCH, SQUAT, ROW, PUSHUP = '0025', '0043', '0027', '0662'


def workout(i, d, entries):
    return {'id': f'w{i}', 'd': d, 'start': 1_790_000_000_000 + i * 86_400_000, 'routineIds': ['r1'], 'name': 'A', 'entries': entries, 'prs': []}


def entry(id, w, reps, rid='r1'):
    return {'id': id, 'rid': rid, 'target': {'id': id, 'sets': len(reps), 'reps': reps[0]}, 'sets': [{'w': w, 'r': r, 'done': True} for r in reps]}


routines = [
    {'id': 'r1', 'name': 'Push', 'ex': [{'id': BENCH, 'sets': 3, 'reps': 5, 'weight': 80}, {'id': PUSHUP, 'sets': 2, 'reps': 15}]},
    {'id': 'r2', 'name': 'Legs', 'ex': [{'id': SQUAT, 'sets': 3, 'reps': 5, 'weight': 100}]},
    {'id': 'r3', 'name': 'Pull', 'ex': [{'id': ROW, 'sets': 3, 'reps': 8, 'weight': 60}]},
]
programmes = {
    'p1': {'id': 'p1', 'name': '  Strength block ', 'at': 2, 'days': {'1': ['r1'], '4': ['r2', 'gone'], '9': ['r3']},
           'weeks': [{'t': {BENCH: {'pct': 80}, SQUAT: {'pct': 77.3}}}, {'rpe': 8, 't': {'r1:' + BENCH: {'pct': 85, 'rpe': 9}, ROW: {'pct': 200}}},
                     {'deload': True}, {'rpe': 5.5, 't': {'': {'pct': 70}, PUSHUP: {'rpe': 8.75}}}]},
    'p2': {'id': 'p2', 'name': 'Loop', 'at': 5, 'sequence': ['r1', 'rest', 'r3', 'gone'], 'weeks': [{}, {'deload': True, 'rpe': 7}], 'extra': {'kept': 1}},
    'p3': {'id': 'p3', 'name': 'Empty', 'at': 1, 'sequence': ['rest'], 'weeks': []},
    'bad': {'name': 'no id'},
}
history = [workout(0, '2026-10-20', [entry(BENCH, 100, [5, 5, 4]), entry(SQUAT, 140, [5, 5])]), workout(1, '2026-10-27', [entry(BENCH, 102.5, [3])])]
base = {'unit': 'kg', 'weekStart': 1, 'routines': routines, 'programmes': programmes, 'workouts': history, 'week': {'1': ['r1'], '3': ['r2']}, 'scheduleMode': None, 'rotation': None}
loop = {**base, 'scheduleMode': 'rotation', 'rotation': {'id': 'rotA', 'sequence': ['r2', 'r3']}, 'queue': {'ids': ['r2', 'r3'], 'at': 0, 'rotationId': 'rotA', 'startsOn': '2026-11-01'}}

cases = [
    {'name': 'list and tidy', 'state': base, 'ops': [['list'], ['resize', 'p1', 6], ['resize', 'p1', 2], ['step', 'p1', 0], ['step', 'p1', 1], ['schedule']]},
    {'name': 'weekdays, through the weeks', 'state': base, 'ops': [
        ['start', 'p1', '2026-11-16'], ['status', '2026-11-16'], ['slot', 'r1', BENCH, '2026-11-16'], ['entries', 'r1', '2026-11-16'],
        ['slot', 'r1', BENCH, '2026-11-24'], ['entries', 'r1', '2026-11-24'], ['slot', 'r3', ROW, '2026-11-24'],
        ['status', '2026-12-01'], ['entries', 'r1', '2026-12-01'], ['entries', 'r2', '2026-12-01'],
        ['slot', 'r1', PUSHUP, '2026-12-08'], ['status', '2026-12-15'], ['slot', 'r1', BENCH, '2026-12-15']]},
    {'name': 'pause, resume, again, end', 'state': base, 'ops': [
        ['start', 'p1', '2026-11-11'], ['pause', '2026-11-18'], ['status', '2026-12-02'], ['slot', 'r1', BENCH, '2026-12-02'], ['resume', '2026-12-02'],
        ['status', '2026-12-02'], ['again', '2026-12-03', 2.5], ['slot', 'r1', BENCH, '2026-12-03'], ['end', '2026-12-04']]},
    {'name': 'a loop over a loop', 'state': loop, 'ops': [['schedule'], ['start', 'p2', '2026-11-16'], ['status', '2026-11-16'], ['start', 'p1', '2026-11-17'], ['end', '2026-11-18']]},
    {'name': 'one with nothing to schedule', 'state': base, 'ops': [['start', 'p3', '2026-11-16'], ['start', 'nope', '2026-11-16'], ['delete', 'p3', '2026-11-17'], ['list']]},
]
print(json.dumps(cases, indent=1))
