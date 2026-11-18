# Writes HexplateCore's session golden cases (synthetic histories, no personal data).
# Run: python3 app/scripts/session-cases.py > app/HexplateCore/Tests/HexplateCoreTests/Fixtures/session-cases.json
import json

SQUAT, BENCH, PUSHUP, PLANK, ASSIST, RAISE, ROW, RUN = '0043', '0025', '0662', '0463', '0017', '0334', '0861', '0685'
DAY = 86400000


def planned(cfg):
    out = {'sets': max(1, cfg.get('sets', 1))}
    for k in ('reps', 'repsMin', 'sec', 'setsMax'):
        if cfg.get(k): out[k] = cfg[k]
    if 'weight' in cfg: out['weight'] = cfg['weight']
    return out


def entry(cfg, sets, rid='r1', plan=True):
    e = {'id': cfg['id'], 'target': dict(cfg), 'sets': sets, 'rid': rid}
    if plan: e['planned'] = planned(cfg)
    return e


def rows(w, reps, side=False):
    if side:
        return [{'w': w, 'r': r, 'done': True, 'sides': {'L': {'w': w, 'r': r // 2, 'done': True}, 'R': {'w': w, 'r': r - r // 2, 'done': True}}} for r in reps]
    return [{'w': w, 'r': r, 'done': True, 'at': 1000 * i} for i, r in enumerate(reps)]


def history(*entries_by_day):
    return [{'id': f'w{i}', 'd': f'2026-10-{i + 1:02d}', 'start': i * DAY, 'end': i * DAY + 3600000, 'routineIds': ['r1'], 'routineId': 'r1', 'entries': es}
            for i, es in enumerate(entries_by_day)]


def case(name, ex, workouts=(), **settings):
    routine = {'id': 'r1', 'name': 'A', 'ex': ex}
    if settings.pop('noProg', False): routine['excludeFromProgression'] = True
    state = {'unit': 'kg', 'progDefault': 'linear', 'startFrom': 'plan', 'lastFrom': 'routine', 'exWeights': {}, 'routines': [routine], 'workouts': list(workouts), **settings}
    return {'name': name, 'op': 'start', 'state': state, 'routineId': 'r1'}


sq = {'id': SQUAT, 'sets': 3, 'reps': 5, 'weight': 60}
bench = {'id': BENCH, 'sets': 3, 'reps': 8, 'weight': 50}
dbl = {'id': BENCH, 'sets': 3, 'reps': 12, 'repsMin': 8, 'weight': 40, 'prog': 'double'}
push = {'id': PUSHUP, 'sets': 3, 'reps': 10, 'repsMax': 12}
plank = {'id': PLANK, 'sets': 2, 'sec': 30, 'mode': 'time', 'prog': 'time'}
raise_ = {'id': RAISE, 'sets': 2, 'reps': 12, 'weight': 6, 'side': True}
assist = {'id': ASSIST, 'sets': 3, 'reps': 8, 'weight': 30}

cases = [
    case('first time', [sq]),
    case('first time, remembered weight', [sq], exWeights={SQUAT: {'w': 72.5, 'd': '2026-10-01'}}),
    case('linear: every rep, weight up', [sq], history([entry(sq, rows(60, [5, 5, 5]))])),
    case('linear: one miss, hold', [sq], history([entry(sq, rows(60, [5, 5, 4]))])),
    case('linear: three misses, deload', [sq], history(*[[entry(sq, rows(60, [5, 4, 3]))]] * 3)),
    case('linear: lighter lift steps 2.5', [bench], history([entry(bench, rows(50, [8, 8, 8]))])),
    case('linear: start from last', [bench], history([entry(bench, rows(50, [9, 8, 8]))]), startFrom='last'),
    case('double: climb reps', [dbl], history([entry(dbl, rows(40, [10, 10, 9]))])),
    case('double: top of range, weight up', [dbl], history([entry(dbl, rows(40, [12, 12, 12]))])),
    case('double: stuck, deload', [dbl], history(*[[entry(dbl, rows(40, [8, 7, 6]))]] * 3)),
    case('bodyweight: one more rep', [push], history([entry(push, rows(0, [10, 10, 10]))])),
    case('bodyweight: top, add a set', [push], history([entry({**push, 'reps': 12}, rows(0, [12, 12, 12]), plan=False)])),
    case('time: held, add seconds', [plank], history([entry(plank, [{'sec': 30, 'w': 0, 'done': True}] * 2)])),
    case('time: short three times, deload', [plank], history(*[[entry(plank, [{'sec': 20, 'w': 0, 'done': True}] * 2)]] * 3)),
    case('per side: weight up', [raise_], history([entry(raise_, rows(6, [12, 12], side=True))])),
    case('plan changed', [{**sq, 'reps': 3}], history([entry(sq, rows(60, [5, 5, 5]))])),
    case('assisted: less help', [assist], history([entry(assist, rows(30, [8, 8, 8]))])),
    case('no progression', [{**sq, 'prog': 'off'}], history([entry(sq, rows(70, [5, 5, 5]))])),
    case('routine excluded from progression', [sq], history([entry(sq, rows(60, [5, 5, 5]))]), noProg=True),
    case('greyskull double jump', [{**sq, 'prog': 'greyskull'}], history([entry(sq, rows(60, [5, 5, 10]))])),
    case('superset pair', [{**bench, 'sg': 'a'}, {'id': ROW, 'sets': 3, 'reps': 10, 'weight': 40, 'sg': 'a'}]),
    case('borrowed from another routine', [sq], history([entry(sq, rows(60, [5, 5, 5]), rid='r2')])),
    case('borrowed, last across routines', [sq], history([entry(sq, rows(60, [5, 5, 5]), rid='r2')]), lastFrom='any'),
    case('cardio', [{'id': RUN, 'sets': 1, 'min': 25, 'speed': 9}]),
    case('warm-up rows are not history', [sq], history([entry(sq, [{'w': 20, 'r': 8, 'done': True, 'phase': 'warmup'}] + rows(60, [5, 5, 5]))])),
    case('lb unit', [sq], history([entry(sq, rows(135, [5, 5, 5]))]), unit='lb'),
]

DLIFT, CURL = '0032', '0031'
cases += [
    case('warm-ups: compounds, heavy squat on a bar', [sq], history([entry(sq, rows(100, [5, 5, 5]))]), warmupAuto='compounds'),
    case('warm-ups: compounds skip an isolation lift', [{'id': CURL, 'sets': 3, 'reps': 10, 'weight': 30}], warmupAuto='compounds'),
    case('warm-ups: all, light isolation', [{'id': CURL, 'sets': 3, 'reps': 10, 'weight': 30}, raise_], warmupAuto='all'),
    case('warm-ups: mid compound', [{'id': DLIFT, 'sets': 3, 'reps': 5, 'weight': 40}, bench], warmupAuto='compounds'),
    case('warm-ups: light compound and bodyweight', [{'id': BENCH, 'sets': 3, 'reps': 8, 'weight': 25}, push, {'id': ASSIST, 'sets': 2, 'reps': 8, 'weight': 30}], warmupAuto='all'),
    case('warm-ups: own bar setting and lb', [sq, {'id': ROW, 'sets': 3, 'reps': 10, 'weight': 150}], warmupAuto='all', unit='lb', barWeights={SQUAT: 0}),
    case('warm-ups: slot says none, module off', [{**sq, 'warmup': 'none'}, {**bench, 'warmup': 'auto'}], warmupAuto='all'),
    case('warm-ups: plates module off', [sq], warmupAuto='all', modules={'plates': False}),
]

side = {'w': 6, 'r': 12, 'done': True, 'sides': {'L': {'w': 6, 'r': 6, 'done': True, 'weightOrigin': 'manual'}, 'R': {'w': 6, 'r': 6, 'done': True}}}
active = {
    'id': 'live', 'd': '2026-11-15', 'start': 1000, 'routineIds': ['r1'], 'name': 'A', 'bw': 70, 'cur': 0, 'note': '  good day ',
    'entries': [
        {'id': SQUAT, 'rid': 'r1', 'sg': 'a', 'target': sq, 'planned': planned(sq), 'plan': {'policy': 'linear', 'kind': 'up', 'weight': 65}, 'note': ' knees ',
         'sets': [{'w': 20, 'r': 8, 'done': True, 'phase': 'warmup', 'at': 60000}, {'w': 65, 'r': 5, 'done': True, 'at': 200000, 'weightOrigin': 'manual', 'restSec': 120},
                  {'w': 65, 'r': 5, 'done': False}]},
        {'id': RAISE, 'rid': 'r1', 'sg': 'a', 'target': raise_, 'sets': [{**side, 'at': 400000}, {'w': 6, 'r': 12, 'done': False, 'sides': {'L': {'w': 6, 'r': 6, 'done': False}, 'R': {'w': 6, 'r': 6, 'done': False}}}]},
        {'id': PLANK, 'rid': 'r1', 'target': plank, 'sets': [{'sec': 25, 'w': 0, 'done': True, 'at': 2000000, 'planSec': 30}, {'sec': 10, 'w': 0, 'done': False, 'planSec': 30}]},
        {'id': BENCH, 'rid': 'r1', 'target': bench, 'sets': [{'w': 50, 'r': 8, 'done': False}]},
    ],
}
cases += [
    {'name': 'finish: on time', 'op': 'finish', 'active': active, 'now': 2100000},
    {'name': 'finish: forgotten', 'op': 'finish', 'active': active, 'now': 2000000 + 25 * 60000 + 30000},
    {'name': 'finish: nothing logged', 'op': 'finish', 'active': {**active, 'note': '', 'entries': [active['entries'][3]]}, 'now': 5000},
    {'name': 'finish: all excluded', 'op': 'finish', 'active': {**active, 'entries': [{**active['entries'][0], 'noProg': True}]}, 'now': 300000},
]
print(json.dumps(cases, indent=1))
