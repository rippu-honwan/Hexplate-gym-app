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

# One set's own menu: ops on an entry's rows.
side = lambda w, l, r, done=False: {'w': w, 'r': l + r, 'done': done, 'sides': {'L': {'w': w, 'r': l, 'done': done}, 'R': {'w': w, 'r': r, 'done': done, 'rir': 2}}}
rows = [{'w': 20, 'r': 10, 'done': True, 'phase': 'warmup', 'warmup': True},
        {'w': 60, 'r': 8, 'done': True, 'at': 5000, 'weightOrigin': 'manual', 'rir': 2},
        {'w': 60, 'r': 8, 'done': False, 'type': 'dropset', 'drops': [{'w': 45, 'r': 6}]},
        {'w': 60, 'r': 8, 'done': False}]
timed = [{'sec': 30, 'w': 0, 'done': True, 'side': 'L', 'planSec': 30}, {'sec': 30, 'w': 0, 'done': False, 'side': 'R', 'planSec': 30},
         {'sec': 30, 'w': 0, 'done': False, 'side': 'L'}, {'sec': 30, 'w': 0, 'done': False, 'side': 'R'}]
cases += [
    {'name': 'set: failure on and off', 'rows': rows, 'ops': [['failure', 1], ['failure', 3], ['failure', 1], ['failure', 0]]},
    {'name': 'set: failure on a timed pair', 'rows': timed, 'ops': [['failure', 1], ['failure', 0]]},
    {'name': 'set: warm-up and back', 'rows': rows, 'ops': [['warmup', 3], ['warmup', 2], ['work', 1], ['work', 0], ['warmup', 0]]},
    {'name': 'set: per side warm-up', 'rows': [side(10, 8, 8, True), side(10, 8, 7)], 'ops': [['warmup', 1], ['copy', 0], ['copy', 2]]},
    {'name': 'set: own rest', 'rows': timed, 'ops': [['rest', 1, 75.4], ['rest', 2, 0], ['rest', 0, 2000], ['rest', 1, None], ['rest', 3, -5]]},
    {'name': 'set: notes', 'rows': rows, 'ops': [['note', 1, '  felt easy\tgo up '], ['note', 1, '   '], ['note', 2, 'x' * 150]]},
    {'name': 'set: copy', 'rows': rows, 'ops': [['copy', 1], ['copy', 3], ['copy', 0]]},
    {'name': 'set: copy a timed pair', 'rows': timed, 'ops': [['copy', 1], ['copy', 2]]},
    {'name': 'set: remove', 'rows': rows, 'ops': [['remove', 1], ['remove', 0], ['remove', 1], ['remove', 0]]},
    {'name': 'set: remove a timed pair', 'rows': timed, 'ops': [['remove', 1], ['remove', 0]]},
]
print(json.dumps(cases, indent=1))
