# Writes HexplateCore's reminder golden cases (synthetic, no personal data).
# Run: python3 app/scripts/reminder-cases.py > app/HexplateCore/Tests/HexplateCoreTests/Fixtures/reminder-cases.json
import json

routines = [{'id': 'ra', 'name': 'Upper A', 'ex': [{'id': '0025'}]}, {'id': 'rb', 'name': 'Lower A', 'ex': [{'id': '0043'}]},
            {'id': 'rc', 'name': 'Arms', 'ex': [{'id': '0031'}]}, {'id': 'rd', 'name': '', 'ex': [{'id': '0334'}]}]
week = {'1': 'ra', '3': 'rb', '5': ['ra', 'rb', 'rc'], '6': 'rd'}   # Mon, Wed, Fri (three), Sat (no name)


def w(d):
    return {'id': 'w' + d, 'd': d, 'start': 0, 'entries': []}


base = {'routines': routines, 'week': week, 'workouts': [w('2026-11-02'), w('2026-11-04')],
        'reminder': {'on': True, 'time': '08:00'}}
now = '2026-11-09T07:30'    # a Monday morning
cases = [
    {'name': 'off', 'now': now, 'state': {**base, 'reminder': {'on': False, 'time': '08:00'}}},
    {'name': 'reminder only', 'now': now, 'state': base},
    {'name': 'today passed', 'now': '2026-11-09T09:00', 'state': base},
    {'name': 'logged and noted days', 'now': now, 'state': {**base, 'workouts': base['workouts'] + [w('2026-11-11')],
                                                             'dayNotes': {'2026-11-13': {'tag': 'sick', '_ts': 1}, '2026-11-16': {'text': '  ', '_ts': 1},
                                                                          '2026-11-18': {'text': 'trip', '_ts': 1}}}},
    {'name': 'day plan override and rest', 'now': now, 'state': {**base, 'dayPlan': {'2026-11-10': 'rc', '2026-11-11': 'rest'}}},
    {'name': 'odd time', 'now': now, 'state': {**base, 'reminder': {'on': True, 'time': '8:30'}}},
    {'name': 'broken time', 'now': now, 'state': {**base, 'reminder': {'on': True, 'time': 'later'}}},
    {'name': 'truthy on', 'now': now, 'state': {**base, 'reminder': {'on': 1, 'time': '07:45', 'nudge': 'yes'}}},
]
for tone in ('friendly', 'guilt', 'drill', 'unknown'):
    cases.append({'name': 'nudge ' + tone, 'now': now, 'state': {**base, 'reminder': {'on': True, 'time': '08:00', 'nudge': True, 'tone': tone}}})
cases += [
    {'name': 'nudge after a late reminder', 'now': now, 'state': {**base, 'reminder': {'on': True, 'time': '19:30', 'nudge': True}}},
    {'name': 'nudge too late', 'now': now, 'state': {**base, 'reminder': {'on': True, 'time': '20:00', 'nudge': True}}},
    {'name': 'nudge back-off after a break', 'now': now, 'state': {**base, 'workouts': [w('2026-10-20')],
                                                                    'reminder': {'on': True, 'time': '08:00', 'nudge': True}}},
    {'name': 'nudge, session running', 'now': now, 'state': {**base, 'active': {'id': 'x', 'entries': []},
                                                              'reminder': {'on': True, 'time': '08:00', 'nudge': True}}},
    {'name': 'nudge, evening already', 'now': '2026-11-09T20:30', 'state': {**base, 'reminder': {'on': True, 'time': '08:00', 'nudge': True}}},
    {'name': 'queue: day after a workout is rest', 'now': now,
     'state': {**base, 'week': {}, 'scheduleMode': 'rotation', 'rotation': {'id': 'rot', 'sequence': ['ra', 'rb']},
               'queue': {'ids': ['ra', 'rb'], 'at': 0, 'rotationId': 'rot', 'startsOn': '2026-11-08'},
               'workouts': [w('2026-11-08')], 'reminder': {'on': True, 'time': '08:00', 'nudge': True}}},
]
print(json.dumps(cases, indent=1))
