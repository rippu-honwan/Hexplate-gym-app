# Writes HexplateCore's recovery golden cases (synthetic, no personal data).
# Run: python3 native/scripts/recovery-cases.py > native/HexplateCore/Tests/HexplateCoreTests/Fixtures/recovery-cases.json
# Workouts carry only a day (read as local noon), so the cases do not depend on the time zone.
import json

SQUAT, BENCH, ROW, PUSHUP, CHIN, ASSIST, RAISE, RUN, CURL, DLIFT = '0043', '0025', '0027', '0662', '1326', '0017', '0334', '0685', '0031', '0032'
TODAY = '2026-11-15'  # a Sunday


def sets(w, reps, **extra):
    return [{'w': w, 'r': r, 'done': True, **extra} for r in reps]


def workout(i, d, entries, **extra):
    return {'id': f'w{i}', 'd': d, 'entries': entries, **extra}


def day(n):  # n days before TODAY
    return f'2026-11-{15 - n:02d}' if n < 15 else f'2026-10-{46 - n:02d}'


legs = lambda i, n, w=120: workout(i, day(n), [{'id': SQUAT, 'sets': sets(w, [5, 5, 5, 5, 5])}, {'id': DLIFT, 'sets': sets(140, [5, 5, 5])}])
upper = lambda i, n: workout(i, day(n), [{'id': BENCH, 'sets': sets(80, [8, 8, 8, 8])}, {'id': ROW, 'sets': sets(70, [10, 10, 10, 10])}, {'id': RAISE, 'sets': sets(10, [15, 15, 15])}])
light = lambda i, n: workout(i, day(n), [{'id': CURL, 'sets': sets(30, [10, 10])}])

basic = [legs(0, 12), upper(1, 10), legs(2, 8), upper(3, 6), legs(4, 3), upper(5, 2)]
effort = [
    workout(0, day(20), [{'id': BENCH, 'sets': sets(100, [3])}]),
    workout(1, day(2), [{'id': BENCH, 'sets': [{'w': 80, 'r': 8, 'done': True, 'rir': 0}, {'w': 80, 'r': 8, 'done': True, 'rpe': 6},
                                                 {'w': 80, 'r': 6, 'done': True, 'failure': True}, {'w': 60, 'r': 8, 'done': True},
                                                 {'w': 40, 'r': 10, 'done': True, 'failure': True, 'phase': 'warmup'}, {'w': 82.5, 'r': 5, 'done': False}]}]),
    workout(2, day(1), [{'id': BENCH, 'sets': [{'w': 30, 'r': 12, 'done': True, 'phase': ' Warm-Up '}, {'w': 40, 'r': 10, 'done': True, 'warmup': True},
                                                 {'w': 50, 'r': 10, 'done': True, 'warmup': True, 'phase': 'work'},
                                                 {'w': 70, 'r': 8, 'done': True, 'type': 'dropset', 'drops': [{'w': 55, 'r': 6}, {'w': 40, 'r': 8, 'rir': 0}]},
                                                 {'w': 70, 'r': 8, 'done': False, 'type': 'dropset', 'drops': [{'w': 55, 'r': 6}]},
                                                 {'w': 70, 'r': 8, 'done': True, 'drops': [{'w': 55, 'r': 6}]}]}]),
]
bodyweight = [
    workout(0, day(9), [{'id': CHIN, 'sets': sets(0, [10, 8])}, {'id': PUSHUP, 'sets': sets(0, [20, 20])}]),
    workout(1, day(4), [{'id': CHIN, 'sets': sets(20, [6, 6])}, {'id': PUSHUP, 'sets': sets(10, [15])}], bw=176),
    workout(2, day(2), [{'id': CHIN, 'target': {'bodyweight': False}, 'sets': sets(0, [12])}, {'id': ASSIST, 'sets': sets(30, [10, 10])},
                        {'id': PUSHUP, 'bodyweight': True, 'sets': sets('5', ['12'], unit='kg')}]),
    workout(3, day(1), [{'id': CHIN, 'sets': sets(25, [5, 5], unit='lbs')}, {'id': SQUAT, 'sets': sets('225', [5, 5], weightUnit='Pounds')}], bodyweight='80', bwUnit='kg'),
]
cardio_sides = [
    workout(0, day(3), [{'id': RUN, 'sets': [{'min': 45, 'done': True}, {'min': None, 'done': True}, {'done': True}, {'min': '15', 'done': True}]}]),
    workout(1, day(1), [{'id': RAISE, 'sets': [{'w': 10, 'r': 24, 'done': True, 'sides': {'L': {'w': 10, 'r': 12, 'done': True}, 'R': {'w': 10, 'r': 12, 'done': False, 'rir': 1}}}]},
                        {'id': 'custom-x', 'muscleWeights': {'chest': 1, 'triceps': 0.5, 'nope': 1}, 'sets': sets(20, [10, 10])},
                        {'id': 'custom-y', 'sets': sets(20, [10])}]),
]
spike = [light(i, n) for i, n in enumerate((27, 24, 21, 18))] + [legs(10 + i, n, 100) for i, n in enumerate((6, 5, 4, 3, 2, 1))]

cases = [
    {'name': 'fatigue: alternating split', 'op': 'fatigue', 'today': TODAY, 'unit': 'kg', 'bodyweightKg': 80, 'workouts': basic},
    {'name': 'fatigue: hours later', 'op': 'fatigue', 'today': TODAY, 'hours': 30, 'unit': 'kg', 'workouts': basic},
    {'name': 'fatigue: effort, warm-ups and drop sets', 'op': 'fatigue', 'today': TODAY, 'unit': 'kg', 'workouts': effort},
    {'name': 'fatigue: body weight and units', 'op': 'fatigue', 'today': TODAY, 'unit': 'lb', 'bodyweightKg': 72, 'workouts': bodyweight},
    {'name': 'fatigue: body weight, no profile weight', 'op': 'fatigue', 'today': TODAY, 'unit': 'kg', 'workouts': bodyweight},
    {'name': 'fatigue: cardio, sides, custom', 'op': 'fatigue', 'today': TODAY, 'unit': 'kg', 'workouts': cardio_sides},
    {'name': 'fatigue: a sudden heavy week', 'op': 'fatigue', 'today': TODAY, 'unit': 'kg', 'workouts': spike},
    {'name': 'fatigue: nothing', 'op': 'fatigue', 'today': TODAY, 'unit': 'kg', 'workouts': []},
]

A = {'id': 'ra', 'name': 'Legs', 'ex': [{'id': SQUAT, 'sets': 4, 'reps': 5, 'weight': 100}, {'id': CURL, 'sets': 2}]}
B = {'id': 'rb', 'name': 'Push', 'ex': [{'id': BENCH, 'sets': 3, 'reps': 8, 'weight': 60}, {'id': RAISE}]}
C = {'id': 'rc', 'name': 'Empty', 'ex': []}
recent_legs = [upper(0, 9), light(1, 8), upper(2, 5), legs(3, 1)]
recent_both = [upper(0, 3), upper(1, 2), upper(2, 1), legs(3, 1)]
old_chest = [upper(0, 12), legs(1, 8), light(2, 7), light(3, 5), light(4, 3)]
base = {'unit': 'kg', 'routines': [A, B, C], 'week': {}, 'dayPlan': {}}


def hint(name, workouts, **extra):
    return {'name': name, 'op': 'hint', 'today': TODAY, 'bodyweightKg': 80, 'state': {**base, 'workouts': workouts, **extra}}


cases += [
    hint('hint: rest day, legs recovering', recent_legs, week={'1': 'ra', '3': ['rb']}),
    hint('hint: rest day, nothing recovering', old_chest, week={'1': 'ra'}),
    hint('hint: rest on the day plan', recent_legs, dayPlan={TODAY: 'rest'}),
    hint('hint: lighter, legs today', recent_legs, week={'0': 'ra'}),
    hint('hint: lighter, two routines', recent_both, week={'0': ['rb', 'ra', 'rc']}),
    hint('hint: today light on the tired part', recent_legs, week={'0': 'rb'}),
    hint('hint: covered, chest is back', old_chest, week={'0': 'rb'}),
    hint('hint: empty routine, nothing recovering', old_chest, week={'0': 'rc'}),
    hint('hint: split, legs recovering', recent_legs),
    hint('hint: both recovering', recent_both),
    hint('hint: neglect', old_chest),
    hint('hint: queue counts as a plan', recent_legs, queue={'ids': ['rb'], 'at': 0}),
    hint('hint: off', recent_legs, recoveryHint=False),
    hint('hint: hidden today', recent_legs, recoveryHintDay=TODAY),
    hint('hint: during a workout', recent_legs, active={'id': 'x'}),
    hint('hint: trained today', recent_legs + [light(9, 0)]),
    hint('hint: too few recent', [legs(0, 1), upper(1, 40)]),
]
print(json.dumps(cases, indent=1))
