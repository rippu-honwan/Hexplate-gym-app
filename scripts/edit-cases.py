# Writes HexplateCore's live-session edit golden cases (synthetic, no personal data).
# Run: python3 native/scripts/edit-cases.py > native/HexplateCore/Tests/HexplateCoreTests/Fixtures/edit-cases.json
import json


def e(id, done=False, **extra):
    return {'id': id, 'target': {'id': id, 'sets': 2}, 'planned': {'sets': 2}, 'plan': None, 'rid': 'r1',
            'sets': [{'w': 20, 'r': 8, 'done': done}, {'w': 20, 'r': 8, 'done': False}], **extra}


def active(*entries, cur=0, **extra):
    return {'id': 'live', 'd': '2026-11-16', 'cur': cur, 'entries': list(entries), **extra}


new = {'id': '0031', 'target': {'id': '0031', 'sets': 3}, 'plan': None, 'planned': {'sets': 3}, 'sets': [{'w': 30, 'r': 10, 'done': False}]}
plain = active(e('A'), e('B'), e('C'), e('D'), cur=1)
grouped = active(e('A'), e('B', sg='s1', sgName='Arms', sgRest=90), e('C', sg='s1', sgName='Arms', sgRest=90), e('D'), cur=2)

cases = [
    {'name': 'move down and up', 'active': plain, 'ops': [['move', 0, 1], ['move', 3, -1], ['move', 0, -1], ['move', 3, 1]]},
    {'name': 'move a superset as one', 'active': grouped, 'ops': [['move', 3, -1], ['move', 0, 1]]},
    {'name': 'swap inside a superset', 'active': {**grouped, 'cur': 0}, 'ops': [['move', 1, 1], ['move', 2, -1]]},
    {'name': 'swap blocked across the marker', 'active': grouped, 'ops': [['canMove', 1, 1], ['move', 1, 1], ['canMove', 2, -1], ['canMove', 0, -1]]},
    {'name': 'pair and unpair', 'active': plain, 'ops': [['pair', 0, 1], ['pair', 1, 2], ['unpair', 1], ['unpair', 0]]},
    {'name': 'pair into a group', 'active': grouped, 'ops': [['pair', 2, 3], ['pair', 0, 1]]},
    {'name': 'remove before, at and after the marker', 'active': plain, 'ops': [['remove', 0], ['remove', 0], ['remove', 1], ['remove', 0], ['remove', 0]]},
    {'name': 'remove breaks a superset', 'active': grouped, 'ops': [['remove', 1]]},
    {'name': 'swap, nothing logged', 'active': grouped, 'ops': [['swap', 1, new, False], ['swap', 3, new, False]]},
    {'name': 'swap, logged', 'active': active(e('A', True), e('B'), noProg=True), 'ops': [['swap', 0, new, False]]},
    {'name': 'swap, logged in a superset, keep', 'active': active(e('A'), e('B', True, sg='s1'), e('C', sg='s1'), e('D')), 'ops': [['swap', 1, new, True]]},
    {'name': 'swap, logged in a superset, after', 'active': active(e('A'), e('B', True, sg='s1'), e('C', sg='s1'), e('D')), 'ops': [['swap', 1, new, False]]},
    {'name': 'progression on and off', 'active': {**plain, 'noProg': True}, 'ops': [['noProg', 1, True], ['noProg', 2, True], ['noProg', 1, False]]},
]
print(json.dumps(cases, indent=1))
