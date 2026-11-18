# Writes HexplateCore's CSV export golden cases (synthetic, no personal data): the history fixture
# with body data added, over several date ranges.
# Run: python3 app/scripts/csv-cases.py > app/HexplateCore/Tests/HexplateCoreTests/Fixtures/csv-cases.json
import json, os

here = os.path.dirname(os.path.abspath(__file__))
state = json.load(open(os.path.join(here, '../HexplateCore/Tests/HexplateCoreTests/Fixtures/history-state.json')))
state['bodyweight'] = state['bodyweight'] + [
    {'d': '2026-03-05', 'w': 71.2, 'ins': [{'id': 'b', 'at': '21:10', 'w': 71.6, 't': 5}, {'id': 'a', 'at': '7:05', 'w': 71.2, 't': 9},
                                           {'id': 'c', 'w': 71.4, 't': 1}, {'id': None, 'w': 70}, {'id': 'd', 'w': 0}]},
    {'d': '2026-03-12', 'w': 0},
    {'d': '2026-03-25', 'w': 72.25, 't': 1},
]
state['measurements'] = [
    {'d': '2026-03-05', 'waist': 82.5, 'upperArmLeft': 35, 'bodyFat': 0, 'other': [
        {'id': 'grip', 'value': 50, 'unit': 'kg'}, {'id': 'neckin', 'value': 38.1, 'unit': 'in'}, {'id': 'score', 'value': 7, 'unit': 'none'},
        {'id': 'old', 'value': 12, 'name': 'Old field'}, {'id': 'gone', 'value': None}]},
    {'d': '2026-03-18', 'chest': 101.3, 'other': [{'id': 'grip', 'value': 52.123}, {'id': 'lbf', 'value': 10, 'unit': 'lb'}]},
    {'d': '2026-03-18', 'chest': 101.4},
    {'d': '2026-03-28', 'hips': 99, 'other': []},
]
state['customMeasurements'] = [{'id': 'grip', 'name': 'Grip', 'unit': 'kg'}, {'id': 'neckin', 'name': '=Neck, in', 'unit': 'in'},
                               {'id': 'score', 'name': 'Sleep score', 'unit': 'none'}, {'id': 'lbf', 'name': '', 'unit': 'lb'}]
lb = {**state, 'unit': 'lb'}
cases = [
    {'name': 'all', 'state': state, 'from': None, 'to': None},
    {'name': 'from only', 'state': state, 'from': '2026-03-10', 'to': None},
    {'name': 'to only', 'state': state, 'from': None, 'to': '2026-03-05'},
    {'name': 'one day', 'state': state, 'from': '2026-03-18', 'to': '2026-03-18'},
    {'name': 'nothing', 'state': state, 'from': '2027-01-01', 'to': '2027-01-31'},
    {'name': 'lb', 'state': lb, 'from': None, 'to': None},
]
print(json.dumps(cases, indent=1))
